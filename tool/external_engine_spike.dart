// ignore_for_file: avoid_print
//
// Protocol spike for the Lichess External Engine API.
//
// This is a throwaway validation tool (see docs/external-engine.md), not app code.
// It exercises the two client-side calls the app makes, against real servers:
//
//  1. listing the account's registered external engines (OAuth, `engine:read` scope)
//  2. streaming an analysis request from the broker and cancelling it by closing the
//     HTTP connection
//
// Usage:
//   export LICHESS_API_TOKEN=lip_...   # personal access token with engine:read
//   dart run tool/external_engine_spike.dart list
//   dart run tool/external_engine_spike.dart list --signed  # test the HMAC-signed bearer form
//   dart run tool/external_engine_spike.dart analyse [engineId] [--cancel-after=5]
//
// While `analyse` runs, watch the provider logs to verify that closing the connection
// stops the engine.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:lichess_mobile/src/model/auth/bearer.dart';

const lichessHost = String.fromEnvironment('LICHESS_HOST', defaultValue: 'lichess.org');
const engineHost = String.fromEnvironment(
  'LICHESS_ENGINE_HOST',
  defaultValue: 'engine.lichess.ovh',
);

/// A position where black is clearly winning (white queen is gone), to verify the point of
/// view of `cp` scores: negative `cp` here means scores are from white's point of view
/// (verified live 2026-07-15: the broker streams ~-800); positive would mean side-to-move
/// point of view as in raw UCI, requiring a flip in the app.
const povCheckFen = 'rnb1kbnr/pppp1ppp/8/4p3/6q1/5P2/PPPPP1PP/RNB1KBNR b KQkq - 0 3';

Future<void> main(List<String> args) async {
  final token = Platform.environment['LICHESS_API_TOKEN'];
  if (token == null) {
    print('Set LICHESS_API_TOKEN to a personal access token with the engine:read scope.');
    print('Create one at https://lichess.org/account/oauth/token/create');
    exit(1);
  }

  final command = args.firstOrNull ?? 'list';
  switch (command) {
    case 'list':
      await listEngines(token, signed: args.contains('--signed'));
    case 'analyse':
      final engineId = args.elementAtOrNull(1);
      final cancelAfterArg = args.firstWhere(
        (a) => a.startsWith('--cancel-after='),
        orElse: () => '--cancel-after=8',
      );
      final cancelAfter = int.parse(cancelAfterArg.split('=')[1]);
      await analyse(
        token,
        engineId: engineId,
        cancelAfter: Duration(seconds: cancelAfter),
      );
    default:
      print('Unknown command: $command (expected `list` or `analyse`)');
      exit(1);
  }
}

Future<List<Map<String, dynamic>>> listEngines(String token, {bool signed = false}) async {
  final bearer = signed ? signBearerToken(token) : token;
  print('GET https://$lichessHost/api/external-engine (${signed ? 'signed' : 'raw'} bearer)');
  final response = await http.get(
    Uri.https(lichessHost, '/api/external-engine'),
    headers: {'Authorization': 'Bearer $bearer'},
  );
  print('HTTP ${response.statusCode}');
  if (response.statusCode != 200) {
    print(response.body);
    exit(1);
  }
  final engines = (jsonDecode(response.body) as List<dynamic>).cast<Map<String, dynamic>>();
  for (final engine in engines) {
    print(
      '- ${engine['id']}: ${engine['name']} '
      '(maxThreads: ${engine['maxThreads']}, maxHash: ${engine['maxHash']}, '
      'variants: ${engine['variants']})',
    );
  }
  return engines;
}

Future<void> analyse(String token, {String? engineId, required Duration cancelAfter}) async {
  final engines = await listEngines(token);
  final engine = engineId != null ? engines.firstWhere((e) => e['id'] == engineId) : engines.first;
  print(
    '\nAnalysing PoV-check position with ${engine['name']} '
    '(black to move, black winning: negative cp = white PoV as observed live, '
    'positive cp = side-to-move PoV)',
  );

  final client = http.Client();
  final request = http.Request(
    'POST',
    Uri.https(engineHost, '/api/external-engine/${engine['id']}/analyse'),
  );
  request.headers['Content-Type'] = 'application/json';
  request.body = jsonEncode({
    'clientSecret': engine['clientSecret'],
    'work': {
      'sessionId': 'spike-${DateTime.now().millisecondsSinceEpoch}',
      'threads': engine['maxThreads'],
      'hash': engine['maxHash'],
      'movetime': 60000,
      'multiPv': 2,
      'variant': 'chess',
      'initialFen': povCheckFen,
      'moves': <String>[],
    },
  });

  final watch = Stopwatch()..start();
  print('POST ${request.url} (will cancel after ${cancelAfter.inSeconds}s)');

  Timer(cancelAfter, () {
    print(
      '\n[${watch.elapsedMilliseconds}ms] closing connection now — '
      'check the provider logs: the engine should stop shortly',
    );
    client.close();
  });

  try {
    final response = await client.send(request);
    print('[${watch.elapsedMilliseconds}ms] HTTP ${response.statusCode}');
    await for (final line
        in response.stream
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .where((l) => l.isNotEmpty)) {
      print('[${watch.elapsedMilliseconds}ms] $line');
    }
    print('[${watch.elapsedMilliseconds}ms] stream closed by server');
  } on http.ClientException catch (e) {
    print('[${watch.elapsedMilliseconds}ms] connection closed: $e');
  }
}
