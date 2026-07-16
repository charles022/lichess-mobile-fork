/// On-device end-to-end test for the external engine feature (Tier 2).
///
/// Runs the real app against the real lichess.org API and broker, on an Android emulator,
/// with an external engine provider running on the workflow host. It automates the parts of
/// the "End-to-end test checklist" in `docs/external-engine.md` that don't need physical
/// hardware:
///
/// - the engine registered by the provider appears in Settings → Chess engine and can be
///   selected;
/// - a fresh analysis session streams evaluations from the external engine (engine name shown
///   while it computes);
/// - when the provider goes down, the offline snackbar appears and analysis falls back to the
///   local engine;
/// - after the provider is back, long-press → Retry resumes external analysis.
///
/// Authentication: instead of driving the OAuth browser flow (impossible from a Flutter test),
/// the test seeds the session storage with a personal access token before the app boots — the
/// same `LICHESS_API_TOKEN` repository secret used by the live protocol workflow. No user
/// login credentials are involved.
///
/// Required dart-defines (see `.github/workflows/external-engine-e2e-test.yml`):
/// - `E2E_LICHESS_TOKEN`: personal access token (needs `engine:read`; the CI secret also has
///   `engine:write` for the provider);
/// - `E2E_ENGINE_NAME`: the name the provider registered the engine under;
/// - `E2E_CONTROL_URL` (optional): the provider control server, reachable from the emulator
///   (defaults to the host loopback `http://10.0.2.2:8899`).
library;

import 'dart:convert';
import 'dart:io';

import 'package:dartchess/dartchess.dart' show Side;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lichess_mobile/main.dart' as app;
import 'package:lichess_mobile/src/binding.dart';
import 'package:lichess_mobile/src/constants.dart';
import 'package:lichess_mobile/src/db/secure_storage.dart';
import 'package:lichess_mobile/src/model/analysis/analysis_controller.dart';
import 'package:lichess_mobile/src/model/auth/auth_controller.dart';
import 'package:lichess_mobile/src/model/auth/auth_storage.dart';
import 'package:lichess_mobile/src/model/common/chess.dart';
import 'package:lichess_mobile/src/model/common/id.dart';
import 'package:lichess_mobile/src/model/user/user.dart';
import 'package:lichess_mobile/src/utils/string.dart';
import 'package:lichess_mobile/src/view/analysis/analysis_screen.dart';
import 'package:lichess_mobile/src/view/engine/engine_button.dart';
import 'package:lichess_mobile/src/view/settings/engine_settings_screen.dart';

const kE2EToken = String.fromEnvironment('E2E_LICHESS_TOKEN');
const kE2EEngineName = String.fromEnvironment('E2E_ENGINE_NAME', defaultValue: 'E2E CI');
const kE2EControlUrl = String.fromEnvironment(
  'E2E_CONTROL_URL',
  defaultValue: 'http://10.0.2.2:8899',
);

/// An offbeat opening line, so the resulting position has no deep cloud eval and the engine
/// actually has to compute (the app prefers a deeper cloud eval over engine work when one
/// exists — see `EvaluationMixin`).
const kObscurePgn = '1. h4 a5 2. Rh3 Ra6 3. Rg3 Rh6';

/// The engine label under the eval chip truncates names longer than 8 characters
/// (see `EngineButton`); match on the visible prefix.
final String kEngineNameLabelPrefix = kE2EEngineName.length > 8
    ? kE2EEngineName.substring(0, 7)
    : kE2EEngineName;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'external engine: select in settings, analyse, offline fallback, retry',
    (tester) async {
      expect(
        kE2EToken,
        isNotEmpty,
        reason: 'pass --dart-define=E2E_LICHESS_TOKEN=<personal access token>',
      );

      await seedAuthenticatedSession();

      await app.main();
      await pumpUntil(tester, find.byType(Navigator), timeout: const Duration(minutes: 2));

      final navigator = tester.state<NavigatorState>(find.byType(Navigator).first);

      // ---- Settings → Chess engine: the registered engine is listed and selectable ----

      navigator.push(EngineSettingsScreen.buildRoute());
      await pumpUntil(tester, find.text(kE2EEngineName), timeout: const Duration(minutes: 1));

      await tester.tap(find.text(kE2EEngineName));
      await tester.pump(const Duration(milliseconds: 500));

      final engineTile = find.ancestor(
        of: find.text(kE2EEngineName),
        matching: find.byType(ListTile),
      );
      expect(
        find.descendant(of: engineTile, matching: find.byIcon(Icons.check)),
        findsOneWidget,
        reason: 'tapping the engine should select it (check mark on its tile)',
      );

      // ---- Fresh analysis session: evals are streamed by the external engine ----

      navigator.push(
        AnalysisScreen.buildRoute(
          const AnalysisOptions.pgn(
            id: StringId('e2e-external-engine'),
            orientation: Side.white,
            pgn: kObscurePgn,
            variant: Variant.standard,
            isComputerAnalysisAllowed: true,
            initialMoveCursor: 6,
          ),
        ),
      );

      // While the external engine computes, its name is shown under the engine chip.
      await pumpUntil(
        tester,
        find.textContaining(kEngineNameLabelPrefix),
        timeout: const Duration(minutes: 1),
      );

      // ---- Provider goes down: snackbar + fallback to the local engine ----

      await controlCommand('pause');

      // Trigger a fresh evaluation request by toggling the engine off and on.
      await tester.tap(find.byType(EngineButton));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byType(EngineButton));

      // The first-line watchdog (8s) marks the engine offline and shows the snackbar.
      await pumpUntil(
        tester,
        find.text('External engine offline — using local engine'),
        timeout: const Duration(seconds: 45),
      );

      // Analysis continues on the local engine (its label replaces the external engine's).
      await pumpUntil(tester, find.text('SF 16'), timeout: const Duration(seconds: 45));

      // ---- Provider back up: long-press → Retry resumes external analysis ----

      await controlCommand('resume');

      await tester.longPress(find.byType(EngineButton));
      await pumpUntil(tester, find.byIcon(Icons.refresh), timeout: const Duration(seconds: 15));
      expect(
        find.textContaining('is offline'),
        findsOneWidget,
        reason: 'the engine popup should show the offline state with a Retry action',
      );

      await tester.tap(find.byIcon(Icons.refresh));

      // The popup switches to the connected state, titled with the engine's full name.
      await pumpUntil(tester, find.text(kE2EEngineName), timeout: const Duration(minutes: 1));
      await pumpUntilGone(
        tester,
        find.textContaining('is offline'),
        timeout: const Duration(minutes: 1),
      );

      // Dismiss the popup.
      await tester.tapAt(const Offset(10, 100));
      await tester.pump(const Duration(milliseconds: 500));
    },
    timeout: const Timeout(Duration(minutes: 15)),
  );
}

/// Seeds an authenticated session before the app boots, bypassing the OAuth browser flow.
///
/// Writes the session (token + user fetched from `/api/account`) where [AuthStorage] expects
/// it, and disables the first-run logic that would wipe secure storage (see `initializeApp`).
Future<void> seedAuthenticatedSession() async {
  final binding = AppLichessBinding.ensureInitialized();
  await binding.preloadSharedPreferences();
  await binding.sharedPreferences.setBool('first_run', false);
  await SecureStorage.instance.write(key: kSRIStorageKey, value: genRandomString(12));

  final account = await fetchJson(Uri.https(kLichessHost, '/api/account'));
  final user = LightUser(id: UserId(account['id'] as String), name: account['username'] as String);
  await const AuthStorage().write(AuthUser(user: user, token: kE2EToken));
}

/// Fetches a JSON object from the lichess API with the raw bearer token.
Future<Map<String, dynamic>> fetchJson(Uri uri) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(uri);
    request.headers.set('authorization', 'Bearer $kE2EToken');
    final response = await request.close();
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != 200) {
      throw StateError('GET $uri failed with ${response.statusCode}: $body');
    }
    return jsonDecode(body) as Map<String, dynamic>;
  } finally {
    client.close();
  }
}

/// Sends a command to the provider control server running on the workflow host
/// (see `.github/scripts/e2e_provider_control.py`).
Future<void> controlCommand(String command) async {
  final client = HttpClient();
  try {
    final request = await client.getUrl(Uri.parse('$kE2EControlUrl/$command'));
    final response = await request.close();
    await response.drain<void>();
    if (response.statusCode != 200) {
      throw StateError('control command $command failed with ${response.statusCode}');
    }
  } finally {
    client.close();
  }
}

/// Pumps frames until [finder] matches at least one widget, or fails after [timeout].
///
/// `pumpAndSettle` cannot be used here: the app has continuously animating widgets (shimmers,
/// spinners) so it would never settle, and network progress requires real time to pass.
Future<void> pumpUntil(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('pumpUntil timed out after $timeout waiting for $finder');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

/// Pumps frames until [finder] matches nothing, or fails after [timeout].
Future<void> pumpUntilGone(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (finder.evaluate().isNotEmpty) {
    if (DateTime.now().isAfter(deadline)) {
      fail('pumpUntilGone timed out after $timeout waiting for $finder to disappear');
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}
