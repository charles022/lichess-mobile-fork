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
/// - after the provider is back, long-press → Retry resumes external analysis;
/// - "Go deeper" requests a deeper external search from the popup;
/// - rapid move scrubbing cancels work cleanly and evals recover;
/// - backgrounding (simulated app lifecycle pause/resume) leaves no stuck state;
/// - a variant the engine doesn't support silently uses the local engine;
/// - deleting the engine server-side falls back to the local engine;
/// - airplane mode on the emulator: the local engine keeps working with no network.
///
/// Deliberately NOT covered: signing out (the app's sign-out revokes its token via
/// `DELETE /api/token`, which would destroy the CI secret), and the `web:mobile` OAuth scope
/// question, which needs a real login session (see docs/external-engine.md).
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
import 'package:flutter_riverpod/flutter_riverpod.dart';
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
import 'package:lichess_mobile/src/model/engine/evaluation_service.dart';
import 'package:lichess_mobile/src/model/user/user.dart';
import 'package:lichess_mobile/src/utils/string.dart';
import 'package:lichess_mobile/src/view/analysis/analysis_screen.dart';
import 'package:lichess_mobile/src/view/engine/engine_button.dart';
import 'package:lichess_mobile/src/view/settings/engine_settings_screen.dart';
import 'package:lichess_mobile/src/widgets/buttons.dart';
import 'package:logging/logging.dart';

const kE2EToken = String.fromEnvironment('E2E_LICHESS_TOKEN');
const kE2EEngineName = String.fromEnvironment('E2E_ENGINE_NAME', defaultValue: 'E2E CI');
const kE2EControlUrl = String.fromEnvironment(
  'E2E_CONTROL_URL',
  defaultValue: 'http://10.0.2.2:8899',
);

/// An offbeat line of rook shuffling, so the positions under test have no cloud eval and the
/// engine actually has to compute (the app prefers a cloud eval over engine work when one
/// exists — see `EvaluationMixin`).
///
/// The line is 20 plies long on purpose: every phase asserting the external engine's label
/// runs at ply >= 16, and the app never requests a cloud eval at ply >= 15 (`_canCloudEval`).
/// This matters because `EvaluationService.evaluate` treats a `CloudEval` of ANY depth as
/// cache — it then starts no engine work at all, silently cancelling any in-flight external
/// request, so the external label can never appear. At low plies the test poisons itself: its
/// own mid-scrub `evalGet` fetched a cloud eval for the scrub-end position and the final
/// (debounced) eval request was served from it (run 29522926846, ply 5).
const kObscurePgn =
    '1. h4 a5 2. Rh3 Ra6 3. Rg3 Rh6 4. Ra3 Rg6 5. Rb3 Rf6 6. Rc3 Re6 '
    '7. Rd3 Rd6 8. Re3 Rc6 9. Rf3 Rb6 10. Rg3 Ra6';

/// The move cursor for [kObscurePgn] analysis screens: the end of the line, ply 20.
const kInitialMoveCursor = 20;

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

      // Surface the external engine client's own log records: the app only prints an
      // allow-list of loggers to the console (see AppLogService), which hides the actual
      // failure reason when an external request dies.
      // Include the record time: the CI runner buffers the whole test output, so its own
      // per-line timestamps are useless for reconstructing in-test timing. EvaluationService
      // records are printed by the app too, but without times — the timestamped copies here
      // are what make the engine-state timeline readable.
      Logger.root.onRecord.listen((record) {
        if (record.loggerName == 'ExternalEngineClient' ||
            record.loggerName == 'EvaluationService') {
          debugPrint(
            '[E2E:${record.loggerName}] ${timestamp(record.time)} ${record.level.name}: '
            '${record.message}${record.error != null ? ' (${record.error})' : ''}',
          );
        }
      });

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

      // Leave the settings screen so its engine tile (which also contains the engine name)
      // cannot satisfy the analysis-screen finders below.
      navigator.pop();
      await tester.pump(const Duration(milliseconds: 500));

      // ---- Fresh analysis session: evals are streamed by the external engine ----

      navigator.push(
        AnalysisScreen.buildRoute(
          const AnalysisOptions.pgn(
            id: StringId('e2e-external-engine'),
            orientation: Side.white,
            pgn: kObscurePgn,
            variant: Variant.standard,
            isComputerAnalysisAllowed: true,
            initialMoveCursor: kInitialMoveCursor,
          ),
        ),
      );

      // Wait for the analysis screen to be fully loaded: its bottom bar (which hosts the
      // engine button) only appears once the controller state has resolved, which involves
      // real network work (socket connection, engine list).
      await pumpUntil(tester, find.byType(EngineButton), timeout: const Duration(minutes: 2));

      // While the external engine computes, its name is shown under the engine chip AND the
      // chip shows a depth number — both at once proves eval lines actually streamed from
      // the external engine (the name alone also shows while merely connecting).
      await pumpUntilAll(tester, [
        find.descendant(
          of: find.byType(EngineButton),
          matching: find.textContaining(kEngineNameLabelPrefix),
        ),
        find.descendant(
          of: find.byType(EngineButton),
          matching: find.textContaining(RegExp(r'^\d{1,2}$')),
        ),
      ], timeout: const Duration(minutes: 1));

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

      await openEnginePopup(tester);
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
      await dismissPopover(tester);

      // ---- "Go deeper": a deeper external search can be requested from the popup ----

      // Let the retried search finish first: the go-deeper action only appears while the
      // engine is idle, and a provider resumed from SIGSTOP may chew through a backlog, so
      // the search can run well past its nominal 4s.
      await pumpFor(tester, const Duration(seconds: 8));

      // Diagnostics for the attempts below: the engine/eval state comes straight from the
      // service, independent of what the popup renders.
      final evaluationService = ProviderScope.containerOf(
        tester.element(find.byType(Navigator).first),
        listen: false,
      ).read(evaluationServiceProvider);
      void dumpGoDeeperState(int attempt, String when) {
        final evalSt = evaluationService.evaluationState.value;
        debugPrint(
          '[E2E:goDeeper] ${timestamp(DateTime.now())} attempt=$attempt $when: '
          'engineState=${evalSt.state.name} extStatus=${evaluationService.externalEngineStatus.value.name} '
          'work=${evalSt.currentWork != null} isDeeper=${evalSt.currentWork?.isDeeper} '
          'evalDepth=${evalSt.eval?.depth} | widgets: '
          'goDeeperIcon=${find.byIcon(Icons.add_circle_outlined).evaluate().length} '
          'refreshIcon=${find.byIcon(Icons.refresh).evaluate().length} '
          'offlineText=${find.textContaining('is offline').evaluate().length} '
          'popupTiles=${find.byType(ListTile).evaluate().length}',
        );
      }

      var goDeeperVisible = false;
      for (var attempt = 0; attempt < 12 && !goDeeperVisible; attempt++) {
        await openEnginePopup(tester);
        dumpGoDeeperState(attempt, 'after long-press');
        final deadline = DateTime.now().add(const Duration(seconds: 10));
        while (DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 200));
          if (find.byIcon(Icons.add_circle_outlined).evaluate().isNotEmpty) {
            goDeeperVisible = true;
            break;
          }
          // If the engine dropped offline again, use the popup's Retry action.
          if (find.byIcon(Icons.refresh).evaluate().isNotEmpty) {
            await tester.tap(find.byIcon(Icons.refresh));
            await tester.pump(const Duration(milliseconds: 500));
          }
        }
        dumpGoDeeperState(attempt, 'at deadline');
        if (!goDeeperVisible) {
          // Close the popup (if open) before trying again.
          await dismissPopover(tester);
        }
      }
      expect(
        goDeeperVisible,
        isTrue,
        reason: 'the go-deeper action should appear once the engine goes idle',
      );

      await tester.tap(find.byIcon(Icons.add_circle_outlined));
      // The deeper search runs and the popup shows its live depth.
      await pumpUntil(tester, find.textContaining('Depth'), timeout: const Duration(minutes: 1));
      await dismissPopover(tester);

      // ---- Rapid move scrubbing: cancelled work is handled cleanly, evals recover ----

      for (var i = 0; i < 4; i++) {
        await tester.tap(find.byKey(const ValueKey('goto-previous')));
        await tester.pump(const Duration(milliseconds: 150));
      }
      // Scrub forward to ply 19, NOT back to the initial ply 20: ply 20 already has a
      // full-length eval cached from the earlier phases, and the app (by design) serves such
      // positions from cache without starting any engine work — no external work means the
      // label under the chip never shows the external engine and the assertion below could
      // never match (run 29514550666). Ply 19 has never been fully evaluated, and being
      // >= 15 it can't acquire a cloud eval either (see [kObscurePgn]), so the external
      // engine must actually run.
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.byKey(const ValueKey('goto-next')));
        await tester.pump(const Duration(milliseconds: 150));
      }
      // After the dust settles, the current position is evaluated by the external engine.
      await pumpUntil(
        tester,
        find.descendant(
          of: find.byType(EngineButton),
          matching: find.textContaining(kEngineNameLabelPrefix),
        ),
        timeout: const Duration(minutes: 1),
      );

      // ---- Backgrounding (simulated lifecycle): no stuck state after resume ----

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      // Do NOT pump while paused: the paused lifecycle state disables frame scheduling
      // (SchedulerBinding._setFramesEnabledState(false)), and on the live binding `pump` only
      // completes when a real frame fires — so a pump here deadlocks the whole test, before
      // the `resumed` line below can ever re-enable frames. This is what wedged runs #16 and
      // #18 past their 45-minute step timeout (the on-device test timeout is not enforced,
      // and `flutter test` buffers all prints until the test ends, so the step log showed
      // nothing at all). Dart timers and network streams keep running without frames, which
      // is all the background dwell needs.
      await Future<void>.delayed(const Duration(seconds: 15));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(seconds: 1));

      // The app is still responsive after resume: toggling the engine off and on works (the
      // current ply-19 eval is now cached, so this alone starts no external work — see the
      // scrubbing phase note)...
      await tester.tap(find.byType(EngineButton));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byType(EngineButton));
      await tester.pump(const Duration(milliseconds: 500));
      // ...and a fresh evaluation (ply 18 has no cached eval and no cloud eval) reaches the
      // external engine.
      await tester.tap(find.byKey(const ValueKey('goto-previous')));
      await pumpUntil(
        tester,
        find.descendant(
          of: find.byType(EngineButton),
          matching: find.textContaining(kEngineNameLabelPrefix),
        ),
        timeout: const Duration(minutes: 1),
      );

      // ---- Variant not supported by the engine: local engine used silently ----

      navigator.pop();
      await tester.pump(const Duration(milliseconds: 500));
      navigator.push(
        AnalysisScreen.buildRoute(const AnalysisOptions.standalone(variant: Variant.antichess)),
      );
      await pumpUntil(tester, find.byType(EngineButton), timeout: const Duration(minutes: 1));
      // The local engine label appears (Fairy-Stockfish computes variants)...
      await pumpUntil(
        tester,
        find.descendant(of: find.byType(EngineButton), matching: find.textContaining('SF')),
        timeout: const Duration(minutes: 1),
      );
      // ...and the external engine is never involved.
      expect(
        find.descendant(
          of: find.byType(EngineButton),
          matching: find.textContaining(kEngineNameLabelPrefix),
        ),
        findsNothing,
        reason: 'an unsupported variant must not use the external engine',
      );

      // ---- Engine deleted server-side: analysis falls back to the local engine ----

      await deleteEngineServerSide();

      navigator.pop();
      await tester.pump(const Duration(milliseconds: 500));
      navigator.push(
        AnalysisScreen.buildRoute(
          const AnalysisOptions.pgn(
            id: StringId('e2e-after-delete'),
            orientation: Side.white,
            pgn: kObscurePgn,
            variant: Variant.standard,
            isComputerAnalysisAllowed: true,
            initialMoveCursor: kInitialMoveCursor,
          ),
        ),
      );
      await pumpUntil(tester, find.byType(EngineButton), timeout: const Duration(minutes: 1));

      // The engine list is still cached, so the app tries the deleted engine, fails fast,
      // and falls back to the local engine with the offline snackbar.
      await pumpUntil(
        tester,
        find.text('External engine offline — using local engine'),
        timeout: const Duration(minutes: 1),
      );
      await pumpUntil(
        tester,
        find.descendant(of: find.byType(EngineButton), matching: find.text('SF 16')),
        timeout: const Duration(minutes: 1),
      );

      // ---- Airplane mode (emulator): the local engine keeps working with no network ----

      await controlCommand('netdown/25');
      await tester.pump(const Duration(seconds: 3));

      await tester.tap(find.byType(EngineButton));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byType(EngineButton));
      await pumpUntil(
        tester,
        find.descendant(of: find.byType(EngineButton), matching: find.text('SF 16')),
        timeout: const Duration(minutes: 1),
      );
      // A depth number in the chip proves the local engine is actually evaluating.
      await pumpUntil(
        tester,
        find.descendant(
          of: find.byType(EngineButton),
          matching: find.textContaining(RegExp(r'^\d{1,2}$')),
        ),
        timeout: const Duration(minutes: 1),
      );

      // Let the host restore the network before finishing, so teardown is clean.
      await pumpFor(tester, const Duration(seconds: 30));
    },
    timeout: const Timeout(Duration(minutes: 25)),
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

/// Deletes the E2E engine from the account with the raw bearer token, simulating a
/// server-side removal that the app is not aware of.
Future<void> deleteEngineServerSide() async {
  final client = HttpClient();
  try {
    final listRequest = await client.getUrl(Uri.https(kLichessHost, '/api/external-engine'));
    listRequest.headers.set('authorization', 'Bearer $kE2EToken');
    final listResponse = await listRequest.close();
    final body = await listResponse.transform(utf8.decoder).join();
    if (listResponse.statusCode != 200) {
      throw StateError('GET /api/external-engine failed with ${listResponse.statusCode}: $body');
    }
    final engines = (jsonDecode(body) as List<dynamic>).cast<Map<String, dynamic>>();
    final id = engines.firstWhere((engine) => engine['name'] == kE2EEngineName)['id'] as String;
    final deleteRequest = await client.deleteUrl(
      Uri.https(kLichessHost, '/api/external-engine/$id'),
    );
    deleteRequest.headers.set('authorization', 'Bearer $kE2EToken');
    final deleteResponse = await deleteRequest.close();
    await deleteResponse.drain<void>();
    if (deleteResponse.statusCode != 200) {
      throw StateError('DELETE /api/external-engine/$id failed: ${deleteResponse.statusCode}');
    }
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

/// Formats [time] as `HH:mm:ss.SSS` for in-test diagnostics (the CI runner buffers the whole
/// test output, so its own per-line timestamps all show the flush time).
String timestamp(DateTime time) => time.toIso8601String().substring(11, 23);

/// Long-presses the widget matched by [finder], holding the pointer down for real wall-clock
/// time.
///
/// `tester.longPress` cannot be used here: it holds the pointer via
/// `pump(kLongPressTimeout + kPressTimeout)`, and on the live (on-device) binding a pump's
/// duration is not reliably honored as wall-clock time — when the UI is static the pointer-up
/// arrives before the 500ms long-press timeout, so the gesture resolves as a tap and the
/// long-press recognizer never fires. This is why the engine-popup long-press worked while the
/// UI was animating (spinners force real frame time between pumps) but silently did nothing on
/// an idle screen. Same class of problem as `pumpAndSettle` never settling — see the
/// DateTime-deadline pump helpers below.
Future<void> longPressFor(WidgetTester tester, Finder finder) async {
  final gesture = await tester.startGesture(tester.getCenter(finder));
  // comfortably above kLongPressTimeout (500ms)
  final end = DateTime.now().add(const Duration(milliseconds: 700));
  var jitter = 0.25;
  while (DateTime.now().isBefore(end)) {
    // Micro-moves well within the touch slop (18px): on the live binding, the synthetic
    // pointer stream is only reliably delivered while the pointer stays active and frames
    // render — a stationary hold on a static screen never reaches the recognizer (observed
    // in run 29511726394: identical holds worked while a spinner was animating and did
    // nothing on an idle screen).
    await gesture.moveBy(Offset(jitter, 0));
    jitter = -jitter;
    await tester.pump(const Duration(milliseconds: 50));
  }
  await gesture.up();
  await tester.pump(const Duration(milliseconds: 300));
}

/// Opens the engine popup (the popover shown by long-pressing [EngineButton]).
///
/// Tries the real long-press gesture first; if the popup (its `ListTile` body) is not up
/// after two tries, invokes the button's `onLongPress` callback directly. The gesture
/// mechanics themselves are covered by widget tests (`test/view/engine/engine_button_test.dart`);
/// what this E2E test needs from the popup is its *content* against the real engine state.
Future<void> openEnginePopup(WidgetTester tester) async {
  for (var i = 0; i < 2; i++) {
    await longPressFor(tester, find.byType(EngineButton));
    if (find.byType(ListTile).evaluate().isNotEmpty) return;
  }
  debugPrint('[E2E] long-press gesture did not open the engine popup, invoking onLongPress');
  tester
      .widget<SemanticIconButton>(
        find.descendant(of: find.byType(EngineButton), matching: find.byType(SemanticIconButton)),
      )
      .onLongPress
      ?.call();
  await tester.pump(const Duration(milliseconds: 300));
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

/// Dismisses an open popover by tapping its barrier, at a spot that is harmless when no
/// popover is open: the center of the app bar (an inert area — a blind corner tap could hit
/// the back button and pop the whole screen instead).
Future<void> dismissPopover(WidgetTester tester) async {
  await tester.tapAt(tester.getCenter(find.byType(AppBar).first));
  await tester.pump(const Duration(milliseconds: 500));
}

/// Pumps frames for the given [duration] of real time.
Future<void> pumpFor(WidgetTester tester, Duration duration) async {
  final end = DateTime.now().add(duration);
  while (DateTime.now().isBefore(end)) {
    await tester.pump(const Duration(milliseconds: 500));
  }
}

/// Pumps frames until every finder in [finders] matches in the same frame, or fails after
/// [timeout].
Future<void> pumpUntilAll(
  WidgetTester tester,
  List<Finder> finders, {
  Duration timeout = const Duration(seconds: 30),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (!finders.every((finder) => finder.evaluate().isNotEmpty)) {
    if (DateTime.now().isAfter(deadline)) {
      final missing = finders.where((finder) => finder.evaluate().isEmpty).toList();
      fail('pumpUntilAll timed out after $timeout; still missing: $missing');
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
