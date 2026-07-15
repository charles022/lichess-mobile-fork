import 'dart:async';
import 'dart:convert';

import 'package:dartchess/dartchess.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/common/uci.dart';
import 'package:lichess_mobile/src/model/engine/external/external_engine.dart';
import 'package:lichess_mobile/src/model/engine/external/external_engine_repository.dart';
import 'package:lichess_mobile/src/model/engine/work.dart';
import 'package:lichess_mobile/src/network/http.dart';
import 'package:multistockfish/multistockfish.dart';

import '../../../test_container.dart';

const testSpec = ExternalEngineWorkSpec(
  id: 'eei_testEngine',
  name: 'Stockfish on home server',
  clientSecret: 'ees_secret',
  maxThreads: 8,
  maxHash: 512,
);

EvalWork makeWork({
  Position? initialPosition,
  IList<Step>? steps,
  bool threatMode = false,
  int multiPv = 1,
  Duration searchTime = const Duration(seconds: 4),
  Variant variant = Variant.standard,
}) {
  return EvalWork(
    id: const StringId('test'),
    stockfishFlavor: StockfishFlavor.sf16,
    variant: variant,
    threads: 1,
    path: UciPath.empty,
    searchTime: searchTime,
    multiPv: multiPv,
    initialPosition: initialPosition ?? Chess.initial,
    steps: steps ?? const IListConst<Step>([]),
    threatMode: threatMode,
    externalEngine: testSpec,
  );
}

/// A position with black to move (after 1. e4).
final blackToMovePosition = Chess.fromSetup(
  Setup.parseFen('rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1'),
);

void main() {
  group('externalEngineFromServerJson', () {
    test('maps all fields', () {
      final engine = externalEngineFromServerJson({
        'id': 'eei_aTKImBJOnv6j',
        'name': 'Stockfish 17',
        'clientSecret': 'ees_HAHuLbmhCcqWfCkR',
        'userId': 'test-user',
        'maxThreads': 8,
        'maxHash': 2048,
        'variants': ['chess', 'atomic'],
        'providerData': null,
      });

      expect(engine.id, 'eei_aTKImBJOnv6j');
      expect(engine.name, 'Stockfish 17');
      expect(engine.clientSecret, 'ees_HAHuLbmhCcqWfCkR');
      expect(engine.maxThreads, 8);
      expect(engine.maxHash, 2048);
      expect(engine.variants, const IListConst(['chess', 'atomic']));
      expect(engine.supportsVariant(Variant.standard), isTrue);
      expect(engine.supportsVariant(Variant.chess960), isTrue);
      expect(engine.supportsVariant(Variant.atomic), isTrue);
      expect(engine.supportsVariant(Variant.antichess), isFalse);
    });
  });

  group('externalEngineAnalyseRequestBody', () {
    test('builds a work object with movetime and clamped options', () {
      final body = externalEngineAnalyseRequestBody(
        spec: testSpec,
        sessionId: 'abcd1234',
        work: makeWork(multiPv: 0),
      );

      expect(body['clientSecret'], 'ees_secret');
      final work = body['work'] as Map<String, dynamic>;
      expect(work['sessionId'], 'abcd1234');
      expect(work['threads'], 8);
      expect(work['hash'], 512);
      expect(work['movetime'], 4000);
      expect(work['multiPv'], 1);
      expect(work['variant'], 'chess');
      expect(work['initialFen'], Chess.initial.fen);
      expect(work['moves'], isEmpty);
    });

    test('includes normalized uci moves from steps', () {
      const position = Chess.initial;
      final move = NormalMove.fromUci('e2e4');
      final (newPos, san) = position.makeSan(move);
      final work = makeWork(
        steps: IList([Step(position: newPos, sanMove: SanMove(san, move))]),
      );

      final body = externalEngineAnalyseRequestBody(
        spec: testSpec,
        sessionId: 'abcd1234',
        work: work,
      );

      expect((body['work'] as Map<String, dynamic>)['moves'], ['e2e4']);
    });

    test('threat mode sends the flipped position and no moves', () {
      final work = makeWork(threatMode: true);
      final body = externalEngineAnalyseRequestBody(
        spec: testSpec,
        sessionId: 'abcd1234',
        work: work,
      );

      final workJson = body['work'] as Map<String, dynamic>;
      expect(workJson['initialFen'], contains(' b '));
      expect(workJson['moves'], isEmpty);
    });
  });

  group('externalEngineEvalFromJson', () {
    final snapshot = {
      'time': 1200,
      'depth': 20,
      'nodes': 1500000,
      'pvs': [
        {
          'moves': ['e2e4', 'e7e5'],
          'cp': 35,
          'depth': 20,
        },
        {
          'moves': ['d2d4'],
          'cp': 30,
          'depth': 19,
        },
      ],
    };

    test('maps a white-to-move snapshot', () {
      final eval = externalEngineEvalFromJson(snapshot, work: makeWork());

      expect(eval, isNotNull);
      expect(eval!.cp, 35);
      expect(eval.depth, 19); // min depth across pvs
      expect(eval.nodes, 1500000);
      expect(eval.millis, 1200);
      expect(eval.searchTime, const Duration(milliseconds: 1200));
      expect(eval.pvs.length, 2);
      expect(eval.pvs[0].moves, const IListConst(['e2e4', 'e7e5']));
      expect(eval.pvs[1].cp, 30);
      expect(eval.threatMode, isFalse);
    });

    test('keeps the score unchanged for black to move (broker scores are white-anchored)', () {
      // Verified against the live broker: a black-to-move winning position streams negative
      // cp, so scores are from white's point of view already — unlike raw UCI, no flip.
      final eval = externalEngineEvalFromJson(
        snapshot,
        work: makeWork(initialPosition: blackToMovePosition),
      );

      expect(eval!.cp, 35);
      expect(eval.pvs[1].cp, 30);
    });

    test('keeps mate scores unchanged too', () {
      final mateSnapshot = {
        'time': 500,
        'depth': 30,
        'nodes': 1000,
        'pvs': [
          {
            'moves': ['d8h4'],
            'mate': 1,
            'depth': 30,
          },
        ],
      };

      final whiteToMove = externalEngineEvalFromJson(mateSnapshot, work: makeWork());
      expect(whiteToMove!.mate, 1);
      expect(whiteToMove.cp, isNull);

      final blackToMove = externalEngineEvalFromJson(
        mateSnapshot,
        work: makeWork(initialPosition: blackToMovePosition),
      );
      expect(blackToMove!.mate, 1);
    });

    test('keeps the score unchanged in threat mode', () {
      // the broker analyses the flipped position but still reports white-anchored scores,
      // which is what LocalEval carries in threat mode as well
      final eval = externalEngineEvalFromJson(snapshot, work: makeWork(threatMode: true));

      expect(eval!.cp, 35);
      expect(eval.threatMode, isTrue);
      expect(eval.position.turn, Side.black);
    });

    test('returns null below the minimum depth', () {
      final shallowSnapshot = {
        'time': 10,
        'depth': 4,
        'nodes': 100,
        'pvs': [
          {
            'moves': ['e2e4'],
            'cp': 20,
            'depth': 4,
          },
        ],
      };

      expect(externalEngineEvalFromJson(shallowSnapshot, work: makeWork()), isNull);
    });

    test('returns null for empty pvs', () {
      final emptySnapshot = {'time': 10, 'depth': 0, 'nodes': 0, 'pvs': <dynamic>[]};

      expect(externalEngineEvalFromJson(emptySnapshot, work: makeWork()), isNull);
    });
  });

  group('ExternalEngineRepository.listEngines', () {
    test('fetches and maps the engine list', () async {
      final mockClient = MockClient((request) async {
        if (request.url.path == '/api/external-engine') {
          expect(request.method, 'GET');
          return http.Response(
            jsonEncode([
              {
                'id': 'eei_1',
                'name': 'Engine one',
                'clientSecret': 'ees_1',
                'maxThreads': 4,
                'maxHash': 256,
                'variants': ['chess'],
              },
            ]),
            200,
          );
        }
        return http.Response('', 404);
      });

      final container = await lichessClientContainer(mockClient);
      final client = container.read(lichessClientProvider);

      final engines = await ExternalEngineRepository(client).listEngines();

      expect(engines.length, 1);
      expect(engines[0].id, 'eei_1');
      expect(engines[0].name, 'Engine one');
    });
  });

  group('externalEngineAnalyseStream', () {
    test('posts the request and parses lines split across chunks', () async {
      Map<String, dynamic>? sentBody;
      final line1 = utf8.encode(
        '${jsonEncode({
          'time': 100,
          'depth': 15,
          'nodes': 5000,
          'pvs': [
            {
              'moves': ['e2e4'],
              'cp': 25,
              'depth': 15,
            },
          ],
        })}\n',
      );
      final line2 = utf8.encode(
        '${jsonEncode({
          'time': 900,
          'depth': 22,
          'nodes': 90000,
          'pvs': [
            {
              'moves': ['e2e4', 'e7e5'],
              'cp': 31,
              'depth': 22,
            },
          ],
        })}\n',
      );
      // split in the middle of the first JSON object and coalesce the rest with line 2 to
      // exercise the LineSplitter-based decoding
      final chunk1 = line1.sublist(0, 20);
      final chunk2 = [...line1.sublist(20), ...line2];

      final mockClient = MockClient.streaming((request, bodyStream) async {
        expect(request.method, 'POST');
        expect(request.url.host, 'engine.lichess.ovh');
        expect(request.url.path, '/api/external-engine/eei_testEngine/analyse');
        sentBody = jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
        return http.StreamedResponse(Stream.fromIterable([chunk1, chunk2]), 200);
      });

      final work = makeWork();
      final stream = await externalEngineAnalyseStream(
        client: mockClient,
        spec: testSpec,
        sessionId: 'session1',
        work: work,
      );
      final evals = await stream.toList();

      expect(sentBody!['clientSecret'], 'ees_secret');
      expect(evals.length, 2);
      expect(evals[0].cp, 25);
      expect(evals[1].cp, 31);
      expect(evals[1].depth, 22);
    });

    test('throws a ServerException on error status', () async {
      final mockClient = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(const Stream.empty(), 404);
      });

      await expectLater(
        externalEngineAnalyseStream(
          client: mockClient,
          spec: testSpec,
          sessionId: 'session1',
          work: makeWork(),
        ),
        throwsA(isA<ServerException>()),
      );
    });
  });
}
