import 'dart:convert';
import 'dart:math' as math;

import 'package:deep_pick/deep_pick.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:http/http.dart' show Client;
import 'package:lichess_mobile/src/constants.dart';
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/model/engine/engine.dart';
import 'package:lichess_mobile/src/model/engine/external/external_engine.dart';
import 'package:lichess_mobile/src/model/engine/uci_protocol.dart';
import 'package:lichess_mobile/src/model/engine/work.dart';
import 'package:lichess_mobile/src/network/http.dart';

/// The maximum number of principal variations accepted by the external engine broker.
const kExternalEngineMaxPv = 5;

/// Repository for the Lichess External Engine API.
///
/// Listing engines goes to the lichess server and requires OAuth (`engine:read` scope), while
/// analysis requests go to the external engine broker ([kLichessEngineHost]) and are
/// authenticated by the engine's `clientSecret` alone.
class ExternalEngineRepository {
  const ExternalEngineRepository(this.client);

  final LichessClient client;

  /// Lists the external engines registered for the current account.
  Future<IList<ExternalEngine>> listEngines() {
    return client.readJsonList(
      lichessUri('/api/external-engine'),
      mapper: externalEngineFromServerJson,
    );
  }
}

/// Maps an engine object from `GET /api/external-engine` to an [ExternalEngine].
ExternalEngine externalEngineFromServerJson(Map<String, dynamic> json) {
  return ExternalEngine(
    id: pick(json, 'id').asStringOrThrow(),
    name: pick(json, 'name').asStringOrThrow(),
    clientSecret: pick(json, 'clientSecret').asStringOrThrow(),
    maxThreads: pick(json, 'maxThreads').asIntOrThrow(),
    maxHash: pick(json, 'maxHash').asIntOrThrow(),
    variants: pick(json, 'variants').asListOrEmpty((v) => v.asStringOrThrow()).toIList(),
  );
}

/// Starts an analysis request on the external engine broker and returns the stream of evals.
///
/// The returned stream emits [LocalEval]s mapped from the broker's ND-JSON eval snapshots.
/// The broker cancels the analysis on the provider when the HTTP connection is closed, so
/// callers stop the analysis by closing [client] (which must be a dedicated [Client] instance
/// for this request).
Future<Stream<LocalEval>> externalEngineAnalyseStream({
  required Client client,
  required ExternalEngineWorkSpec spec,
  required String sessionId,
  required EvalWork work,
}) async {
  final url = Uri.https(kLichessEngineHost, '/api/external-engine/${spec.id}/analyse');
  final stream = await client.postNdJsonStream(
    url,
    headers: {'Content-Type': 'application/json'},
    body: jsonEncode(
      externalEngineAnalyseRequestBody(spec: spec, sessionId: sessionId, work: work),
    ),
    mapper: (json) => externalEngineEvalFromJson(json, work: work),
  );
  return stream.where((eval) => eval != null).map((eval) => eval!);
}

/// Builds the JSON body for a `POST /api/external-engine/{id}/analyse` request.
Map<String, dynamic> externalEngineAnalyseRequestBody({
  required ExternalEngineWorkSpec spec,
  required String sessionId,
  required EvalWork work,
}) {
  return {
    'clientSecret': spec.clientSecret,
    'work': {
      'sessionId': sessionId,
      'threads': math.max(1, spec.maxThreads),
      'hash': math.max(1, spec.maxHash),
      // `movetime` rather than `infinite` so that the provider stops by itself even if the
      // connection close is delayed (e.g. the app is killed mid-stream).
      'movetime': work.searchTime.inMilliseconds,
      'multiPv': work.multiPv.clamp(1, kExternalEngineMaxPv),
      'variant': work.variant.fairy,
      if (work.threatMode)
        'initialFen': threatModePosition(work.position).fen
      else
        'initialFen': work.initialPosition.fen,
      'moves': [
        if (!work.threatMode)
          for (final step in work.steps) step.sanMove.normalizeUci(work.variant),
      ],
    },
  };
}

/// Maps a broker ND-JSON eval snapshot to a [LocalEval].
///
/// Each snapshot has the shape
/// `{"time": 1234, "depth": 20, "nodes": 123456, "pvs": [{"moves": [...], "cp": 30, "depth": 20}]}`
/// where `cp`/`mate` scores are from the white point of view — unlike raw UCI, whose scores are
/// from the side to move's point of view. Verified against the live broker with the reference
/// provider (a black-to-move winning position streams negative cp); the external engine live
/// protocol test workflow asserts this on every run. [LocalEval] scores are white-anchored, so
/// no conversion is needed, in threat mode either (white PoV does not depend on whose turn the
/// analysed position is).
///
/// Returns `null` for snapshots below the minimum depth, which are not worth displaying.
LocalEval? externalEngineEvalFromJson(Map<String, dynamic> json, {required EvalWork work}) {
  final timeMs = pick(json, 'time').asIntOrThrow();
  final nodes = pick(json, 'nodes').asIntOrThrow();

  int depth = pick(json, 'depth').asIntOrThrow();
  final pvs = pick(json, 'pvs').asListOrThrow((pv) {
    depth = math.min(depth, pv('depth').asIntOrThrow());
    return PvData(
      moves: pv('moves').asListOrThrow((move) => move.asStringOrThrow()).toIList(),
      cp: pv('cp').asIntOrNull(),
      mate: pv('mate').asIntOrNull(),
    );
  }).toIList();

  if (pvs.isEmpty || depth < minDepth) return null;

  return LocalEval(
    position: work.threatMode ? threatModePosition(work.position) : work.position,
    searchTime: Duration(milliseconds: timeMs),
    depth: depth,
    nodes: nodes,
    cp: pvs.first.cp,
    mate: pvs.first.mate,
    pvs: pvs,
    millis: math.max(1, timeMs),
    threatMode: work.threatMode,
  );
}
