import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' show Client;
import 'package:lichess_mobile/src/model/common/eval.dart';
import 'package:lichess_mobile/src/model/engine/external/external_engine.dart';
import 'package:lichess_mobile/src/model/engine/external/external_engine_repository.dart';
import 'package:lichess_mobile/src/model/engine/work.dart';
import 'package:lichess_mobile/src/network/http.dart';
import 'package:logging/logging.dart';

final _logger = Logger('ExternalEngineClient');

/// How long to wait for the first evaluation line before considering the engine offline.
///
/// The broker holds the request while dispatching the work to the provider, so a dead provider
/// typically manifests as a hang rather than an error response.
const kExternalEngineFirstLineTimeout = Duration(seconds: 8);

/// How long the stream may stay silent mid-analysis before considering the engine offline.
///
/// This must be generous: at high depths the engine can legitimately take a long time between
/// two complete multi-pv snapshots.
const kExternalEngineStallTimeout = Duration(seconds: 30);

/// A client for the analysis endpoint of the external engine broker.
///
/// Maintains at most one in-flight analysis request: starting a new request always tears down
/// the previous one first (closing the HTTP connection is what cancels the analysis on the
/// provider side).
///
/// A session (identified by a `sessionId` sent with every request) spans multiple requests, so
/// that the provider keeps its hash table between positions; the session ends with [quit].
///
/// This class only reports results and failures through [onEval], [onDone] and [onFailure];
/// the owning `EvaluationService` decides what to do with them (fallback to the local engine,
/// state updates, etc.).
class ExternalEngineClient {
  ExternalEngineClient({required this._clientFactory});

  final HttpClientFactory _clientFactory;

  /// Called for each evaluation snapshot received from the broker.
  void Function(EvalResult result)? onEval;

  /// Called when the current analysis stream completes normally.
  void Function()? onDone;

  /// Called when a request fails; the status is set to [ExternalEngineStatus.offline] before
  /// this is invoked. The [work] is the work item the failed request was analysing.
  void Function(EvalWork work, Object error)? onFailure;

  final ValueNotifier<ExternalEngineStatus> _status = ValueNotifier(ExternalEngineStatus.none);

  /// The status of the external engine for the current session.
  ValueListenable<ExternalEngineStatus> get status => _status;

  String? _sessionId;

  /// Incremented for each new request (or teardown) so that late callbacks from a superseded
  /// request are ignored.
  int _generation = 0;

  Client? _client;
  StreamSubscription<LocalEval>? _subscription;
  Timer? _watchdog;

  /// Starts an analysis request for [work], cancelling any request in flight.
  ///
  /// [work] must carry an [EvalWork.externalEngine] spec.
  void start(EvalWork work) {
    assert(work.externalEngine != null);
    stop();
    final spec = work.externalEngine!;
    final sessionId = _sessionId ??= _generateSessionId();
    final generation = _generation;

    _status.value = .connecting;
    // A `dart:io`-backed client, not the platform-native default: cronet (Android) buffers
    // streamed response bodies, so the analyse stream's small ND-JSON lines never arrive in
    // time (see HttpClientFactory.createStreamingClient).
    final client = _client = _clientFactory.createStreamingClient();
    _restartWatchdog(generation, work, kExternalEngineFirstLineTimeout);

    _logger.info(
      'Requesting analysis from external engine ${spec.name} at ply ${work.position.ply} with '
      'options: multiPv=${work.multiPv}, searchTime=${work.searchTime.inMilliseconds}ms, '
      'threatMode=${work.threatMode}',
    );

    final watch = Stopwatch()..start();
    var evalCount = 0;

    externalEngineAnalyseStream(client: client, spec: spec, sessionId: sessionId, work: work).then((
      stream,
    ) {
      if (generation != _generation) return;
      _subscription = stream.listen(
        (eval) {
          if (generation != _generation) return;
          _restartWatchdog(generation, work, kExternalEngineStallTimeout);
          _status.value = .connected;
          evalCount++;
          if (evalCount == 1) {
            _logger.info('First eval line after ${watch.elapsedMilliseconds}ms');
          } else {
            _logger.fine(
              'Eval #$evalCount (depth ${eval.depth}) after ${watch.elapsedMilliseconds}ms',
            );
          }
          onEval?.call((work, eval));
        },
        onError: (Object error) => _fail(generation, work, error),
        onDone: () {
          if (generation != _generation) return;
          _watchdog?.cancel();
          _logger.info(
            'Analysis stream completed after ${watch.elapsedMilliseconds}ms ($evalCount evals)',
          );
          onDone?.call();
        },
      );
    }, onError: (Object error) => _fail(generation, work, error));
  }

  /// Cancels the in-flight request, if any.
  ///
  /// Closing the HTTP client aborts the connection, which the broker detects to stop the
  /// analysis on the provider. The session is kept, so a subsequent [start] reuses it.
  void stop() {
    _generation++;
    _watchdog?.cancel();
    _watchdog = null;
    _subscription?.cancel();
    _subscription = null;
    _client?.close();
    _client = null;
  }

  /// Ends the engine session: cancels the in-flight request and resets the session and status.
  void quit() {
    stop();
    _sessionId = null;
    _status.value = .none;
  }

  /// Resets an [ExternalEngineStatus.offline] status so the next request tries the external
  /// engine again.
  void resetStatus() {
    if (_status.value == .offline) {
      _status.value = .none;
    }
  }

  void dispose() {
    stop();
    _status.dispose();
  }

  void _restartWatchdog(int generation, EvalWork work, Duration timeout) {
    _watchdog?.cancel();
    _watchdog = Timer(timeout, () {
      _fail(generation, work, TimeoutException('No response from external engine', timeout));
    });
  }

  void _fail(int generation, EvalWork work, Object error) {
    if (generation != _generation) return;
    _logger.warning('External engine failure: $error');
    stop();
    _status.value = .offline;
    onFailure?.call(work, error);
  }

  String _generateSessionId() {
    final random = math.Random.secure();
    return List.generate(16, (_) => random.nextInt(16).toRadixString(16)).join();
  }
}
