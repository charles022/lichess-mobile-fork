import 'dart:async';
import 'dart:convert';

import 'package:dartchess/dartchess.dart';
import 'package:fake_async/fake_async.dart';
import 'package:fast_immutable_collections/fast_immutable_collections.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/common/uci.dart';
import 'package:lichess_mobile/src/model/engine/evaluation_service.dart';
import 'package:lichess_mobile/src/model/engine/external/external_engine.dart';
import 'package:lichess_mobile/src/model/engine/external/external_engine_client.dart';
import 'package:lichess_mobile/src/model/engine/work.dart';
import 'package:lichess_mobile/src/network/http.dart';
import 'package:multistockfish/multistockfish.dart';

import '../../../binding.dart';
import '../../../network/fake_http_client_factory.dart';
import '../../../test_container.dart';
import '../fake_stockfish.dart';

const testSpec = ExternalEngineWorkSpec(
  id: 'eei_testEngine',
  name: 'Home server',
  clientSecret: 'ees_secret',
  maxThreads: 8,
  maxHash: 512,
);

EvalWork makeExternalWork({StringId? id, ExternalEngineWorkSpec? spec}) {
  return EvalWork(
    id: id ?? const StringId('test'),
    stockfishFlavor: StockfishFlavor.sf16,
    variant: Variant.standard,
    threads: 1,
    path: UciPath.empty,
    searchTime: const Duration(seconds: 1),
    multiPv: 1,
    initialPosition: Chess.initial,
    steps: const IListConst<Step>([]),
    threatMode: false,
    externalEngine: spec ?? testSpec,
  );
}

List<int> snapshotLine({int depth = 20, int cp = 35, int time = 500, int nodes = 100000}) {
  return utf8.encode(
    '${jsonEncode({
      'time': time,
      'depth': depth,
      'nodes': nodes,
      'pvs': [
        {
          'moves': ['e2e4'],
          'cp': cp,
          'depth': depth,
        },
      ],
    })}\n',
  );
}

void main() {
  TestLichessBinding.ensureInitialized();

  setUp(() {
    testBinding.stockfish = FakeStockfish();
  });

  group('EvaluationService with external engine', () {
    test('routes external work to the broker and reports evals', () async {
      final requests = <http.BaseRequest>[];
      final mockClient = MockClient.streaming((request, bodyStream) async {
        requests.add(request);
        return http.StreamedResponse(
          Stream.fromIterable([snapshotLine(depth: 15, cp: 25), snapshotLine(depth: 22, cp: 31)]),
          200,
        );
      });

      final container = await makeContainer(
        overrides: {
          httpClientFactoryProvider: httpClientFactoryProvider.overrideWith((ref) {
            return FakeHttpClientFactory(() => mockClient);
          }),
        },
      );
      final service = container.read(evaluationServiceProvider);

      final work = makeExternalWork();
      final stream = service.evaluate(work);
      expect(stream, isNotNull);

      final results = await stream!.take(2).toList();

      expect(requests.length, 1);
      expect(requests[0].url.path, '/api/external-engine/eei_testEngine/analyse');
      expect(results[0].$1, work);
      expect(results[0].$2.cp, 25);
      expect(results[1].$2.cp, 31);
      expect(service.externalEngineStatus.value, ExternalEngineStatus.connected);
      expect(service.evaluationState.value.engineName, 'Home server');
      expect(service.evaluationState.value.eval?.cp, 31);
    });

    test('a new evaluation cancels the in-flight request before starting', () async {
      final requests = <http.BaseRequest>[];
      final responseControllers = <StreamController<List<int>>>[];
      final mockClient = MockClient.streaming((request, bodyStream) async {
        requests.add(request);
        final controller = StreamController<List<int>>();
        responseControllers.add(controller);
        controller.add(snapshotLine(depth: 15 + requests.length, cp: 10 * requests.length));
        return http.StreamedResponse(controller.stream, 200);
      });

      final container = await makeContainer(
        overrides: {
          httpClientFactoryProvider: httpClientFactoryProvider.overrideWith((ref) {
            return FakeHttpClientFactory(() => mockClient);
          }),
        },
      );
      final service = container.read(evaluationServiceProvider);

      final work1 = makeExternalWork(id: const StringId('one'));
      final stream1 = service.evaluate(work1);
      await stream1!.first;

      final laterResults = <EvalResult>[];
      final subscription = service.evalStream.listen(laterResults.add);

      final work2 = makeExternalWork(id: const StringId('two'));
      final stream2 = service.evaluate(work2);
      final result2 = await stream2!.first;

      expect(requests.length, 2);
      expect(result2.$1, work2);
      expect(service.evaluationState.value.currentWork, work2);

      // a late line from the superseded request must not surface
      responseControllers[0].add(snapshotLine(depth: 30, cp: 99));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(laterResults.where((result) => result.$1 == work1), isEmpty);

      await subscription.cancel();
    });

    test('falls back to the local engine when the broker returns an error', () async {
      var requestCount = 0;
      final mockClient = MockClient.streaming((request, bodyStream) async {
        requestCount++;
        return http.StreamedResponse(const Stream.empty(), 404);
      });

      final container = await makeContainer(
        overrides: {
          httpClientFactoryProvider: httpClientFactoryProvider.overrideWith((ref) {
            return FakeHttpClientFactory(() => mockClient);
          }),
        },
      );
      final service = container.read(evaluationServiceProvider);

      final work = makeExternalWork();
      final stream = service.evaluate(work);

      // the eval comes from the local fake stockfish, tagged with the same work
      final result = await stream!.first;

      expect(requestCount, 1);
      expect(result.$1, work);
      expect(service.externalEngineStatus.value, ExternalEngineStatus.offline);
      expect(service.evaluationState.value.engineName, isNot('Home server'));
    });

    test('offline status is sticky: subsequent work goes straight to the local engine', () async {
      var requestCount = 0;
      final mockClient = MockClient.streaming((request, bodyStream) async {
        requestCount++;
        return http.StreamedResponse(const Stream.empty(), 404);
      });

      final container = await makeContainer(
        overrides: {
          httpClientFactoryProvider: httpClientFactoryProvider.overrideWith((ref) {
            return FakeHttpClientFactory(() => mockClient);
          }),
        },
      );
      final service = container.read(evaluationServiceProvider);

      final work1 = makeExternalWork(id: const StringId('one'));
      await service.evaluate(work1)!.first;
      expect(requestCount, 1);
      expect(service.externalEngineStatus.value, ExternalEngineStatus.offline);

      final work2 = makeExternalWork(id: const StringId('two'));
      final result2 = await service.evaluate(work2)!.first;

      expect(requestCount, 1); // no new broker request
      expect(result2.$1, work2);
    });

    test('quit() resets the external engine status', () async {
      final mockClient = MockClient.streaming((request, bodyStream) async {
        return http.StreamedResponse(const Stream.empty(), 404);
      });

      final container = await makeContainer(
        overrides: {
          httpClientFactoryProvider: httpClientFactoryProvider.overrideWith((ref) {
            return FakeHttpClientFactory(() => mockClient);
          }),
        },
      );
      final service = container.read(evaluationServiceProvider);

      await service.evaluate(makeExternalWork())!.first;
      expect(service.externalEngineStatus.value, ExternalEngineStatus.offline);

      service.quit();

      expect(service.externalEngineStatus.value, ExternalEngineStatus.none);
    });

    test('retryExternalEngine() re-dispatches the current work to the broker', () async {
      var requestCount = 0;
      final mockClient = MockClient.streaming((request, bodyStream) async {
        requestCount++;
        if (requestCount == 1) {
          return http.StreamedResponse(const Stream.empty(), 404);
        }
        return http.StreamedResponse(Stream.fromIterable([snapshotLine(cp: 42)]), 200);
      });

      final container = await makeContainer(
        overrides: {
          httpClientFactoryProvider: httpClientFactoryProvider.overrideWith((ref) {
            return FakeHttpClientFactory(() => mockClient);
          }),
        },
      );
      final service = container.read(evaluationServiceProvider);

      final work = makeExternalWork();
      // failure -> local fallback
      await service.evaluate(work)!.first;
      expect(service.externalEngineStatus.value, ExternalEngineStatus.offline);

      final results = <EvalResult>[];
      final subscription = service.evalStream.listen(results.add);

      service.retryExternalEngine();

      await Future<void>.delayed(const Duration(milliseconds: 300));

      expect(requestCount, 2);
      expect(service.externalEngineStatus.value, ExternalEngineStatus.connected);
      expect(results.map((result) => result.$2.cp), contains(42));

      await subscription.cancel();
    });

    test('local-only work never contacts the broker', () async {
      var requestCount = 0;
      final mockClient = MockClient.streaming((request, bodyStream) async {
        requestCount++;
        return http.StreamedResponse(const Stream.empty(), 200);
      });

      final container = await makeContainer(
        overrides: {
          httpClientFactoryProvider: httpClientFactoryProvider.overrideWith((ref) {
            return FakeHttpClientFactory(() => mockClient);
          }),
        },
      );
      final service = container.read(evaluationServiceProvider);

      const localWork = EvalWork(
        id: StringId('local'),
        stockfishFlavor: StockfishFlavor.sf16,
        variant: Variant.standard,
        threads: 1,
        path: UciPath.empty,
        searchTime: Duration(seconds: 1),
        multiPv: 1,
        initialPosition: Chess.initial,
        steps: IListConst<Step>([]),
        threatMode: false,
      );
      final result = await service.evaluate(localWork)!.first;

      expect(requestCount, 0);
      expect(result.$1, localWork);
      expect(service.externalEngineStatus.value, ExternalEngineStatus.none);
    });
  });

  group('ExternalEngineClient watchdogs', () {
    test('marks the engine offline when no line arrives before the first-line timeout', () {
      fakeAsync((async) {
        final client = ExternalEngineClient(
          clientFactory: FakeHttpClientFactory(
            () => MockClient.streaming((request, bodyStream) async {
              return http.StreamedResponse(StreamController<List<int>>().stream, 200);
            }),
          ),
        );
        Object? failure;
        client.onFailure = (work, error) => failure = error;

        client.start(makeExternalWork());
        async.flushMicrotasks();
        expect(client.status.value, ExternalEngineStatus.connecting);

        async.elapse(kExternalEngineFirstLineTimeout + const Duration(seconds: 1));

        expect(client.status.value, ExternalEngineStatus.offline);
        expect(failure, isA<TimeoutException>());

        client.dispose();
      });
    });

    test('marks the engine offline when the stream stalls mid-analysis', () {
      fakeAsync((async) {
        final responseController = StreamController<List<int>>();
        final client = ExternalEngineClient(
          clientFactory: FakeHttpClientFactory(
            () => MockClient.streaming((request, bodyStream) async {
              return http.StreamedResponse(responseController.stream, 200);
            }),
          ),
        );
        Object? failure;
        client.onFailure = (work, error) => failure = error;

        client.start(makeExternalWork());
        async.flushMicrotasks();

        responseController.add(snapshotLine());
        async.flushMicrotasks();
        expect(client.status.value, ExternalEngineStatus.connected);

        async.elapse(kExternalEngineStallTimeout + const Duration(seconds: 1));

        expect(client.status.value, ExternalEngineStatus.offline);
        expect(failure, isA<TimeoutException>());

        client.dispose();
      });
    });

    test('stop() closes the request and keeps the session', () {
      fakeAsync((async) {
        var requestCount = 0;
        final sessionIds = <String>[];
        final client = ExternalEngineClient(
          clientFactory: FakeHttpClientFactory(
            () => MockClient.streaming((request, bodyStream) async {
              requestCount++;
              final body = jsonDecode(await bodyStream.bytesToString()) as Map<String, dynamic>;
              sessionIds.add(((body['work'] as Map<String, dynamic>)['sessionId']) as String);
              return http.StreamedResponse(StreamController<List<int>>().stream, 200);
            }),
          ),
        );

        client.start(makeExternalWork());
        async.flushMicrotasks();
        client.stop();
        client.start(makeExternalWork());
        async.flushMicrotasks();

        expect(requestCount, 2);
        expect(sessionIds.toSet().length, 1, reason: 'same session across requests');

        client.quit();
        client.start(makeExternalWork());
        async.flushMicrotasks();

        expect(sessionIds.length, 3);
        expect(sessionIds[2], isNot(sessionIds[0]), reason: 'quit starts a new session');

        client.dispose();
      });
    });
  });
}
