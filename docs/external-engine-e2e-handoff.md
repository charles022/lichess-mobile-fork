# External engine E2E automation — session handoff

Written 2026-07-16 at the end of the session that built the emulator E2E pipeline
(PR #7, PR #8, and the PR carrying this document). **Read this first when picking the
work back up.**

## RESOLVED (2026-07-17, hang-fix session — branch `claude/android-external-engine-hang-17g3z9`)

**The workflow is green: run 29549888431 (#21, commit `ce3c1b8`) passed all ten phases.**
This document is now history — the live status lives in `docs/external-engine.md` and the
bug/fix record in `docs/external-engine-next-steps.md`. What this session found, for the
record:

- **The step-log premise of the pickup checklist below was wrong**: `flutter test`
  buffers every device-side print until the test finishes, so the hung runs' step logs
  were empty — no `[E2E:...]` line ever appears for a wedged test. The diagnosis came
  from run #17 (29522926846, same test content on main), which failed fast instead of
  hanging. `run_e2e_test.sh` now streams logcat's `flutter` tag live into the step
  output, so this blind spot is gone.
- **The hang (runs #16/#18) was a deterministic deadlock in the backgrounding phase**:
  `AppLifecycleState.paused` disables frame scheduling and live-binding `pump` only
  completes on a real frame, so `pumpFor` during the paused dwell never returned — and
  the `resumed` call that would re-enable frames was never reached. The on-device
  `testWidgets` timeout is not enforced, so the wedge ran into the step timeout.
- **The scrubbing failure (runs #15/#17) was cloud-eval cache poisoning**: the test's
  own mid-scrub `evalGet` fetched a `CloudEval` for the scrub-end position, and
  `evaluate()` treats any-depth cloud evals as cache — silently cancelling the in-flight
  external request (and its watchdog, which is why the logs went dead silent). Label
  assertions now run at ply ≥ 16 (no cloud-eval requests at ply ≥ 15).
- Whether a run hung or failed fast was just the cloud-eval race — one theory covered
  all four runs.
- Two more failures surfaced once the test got further: `AppLifecycleListener`'s debug
  asserts on skipped lifecycle states (test now walks the legal chains), and a real app
  bug — `HomeTabScreen._refreshData`'s unawaited `Future.wait` let the CI token's
  expected `/api/mobile/home` 403 escape as an uncaught zone error (now caught in app
  code).

## Progress update (2026-07-16, streaming-fix session — branch `claude/android-external-engine-stream-tfyfag`)

**The streaming bug below is FIXED** (`66ca4af`): cronet (Android) buffers streamed
response bodies, so the analyse ND-JSON lines never reached Dart. The fix is
`HttpClientFactory.createStreamingClient()` — a `dart:io` `IOClient` used by
`ExternalEngineClient` for the analyse request on all platforms. Verified on the E2E
pipeline: first eval line in 1.2–5.3s, ~19 evals over the 4s movetime, stream completes
~1s after movetime, `stop()` cancellation preserved.

State of the E2E phases as of run #18 (`5bdb0e1`, concluded 2026-07-16 23:29Z):

- **Proven passing** (run #15 attempt 2): settings selection, honest streaming assertion,
  offline fallback + snackbar, retry, go-deeper (popup opens via the `openEnginePopup`
  fallback; deeper request goes out with max search time), scrubbing cancel/restart
  requests.
- **Unproven yet** (rewritten in `a78d378`, awaiting a green run): post-scrub external
  label at ply 5, post-resume label at ply 4, unsupported variant, server-side deletion,
  airplane mode.

Run log of this session, for context on flakiness:

| Run | Commit | Outcome |
|---|---|---|
| #12 | `66ca4af` | streaming fixed; failed at go-deeper (state stuck `computing` — later understood) |
| #13 | `7c888cc` | instrumented; same failure, diagnostics added |
| #14 | `0a317ec` | wall-clock long-press still dead on static screens |
| #15 a1 | `72a8d16` | runner crashed mid-emulator-step (logs 404) — re-ran |
| #15 a2 | `72a8d16` | go-deeper PASSED via fallback; scrubbing failed on the eval-cache rule |
| #16 | `a78d378` | hung to the 90-min job timeout (emulator/tool wedge, phase unknown — its jobs API 503'd; step log worth re-checking later) |
| #18 | `5bdb0e1` | **hang reproduced** — killed by the new 45-min step timeout at 23:29Z (job run 29540298077); artifact again tiny (provider.log+control.log, no logcat), so the test step never finished |

### Picking this up in a fresh session

1. **First: read run 29540298077's step log** (`get_job_logs`, run_id 29540298077,
   `failed_only`, `return_content`, tail ~300 — retry later if the jobs API 503s, which
   it did repeatedly on 2026-07-16). Unlike run #16, this log EXISTS (the step-level
   timeout preserved it). The last `[E2E:...]` timestamped line pinpoints the phase that
   hangs. The 612-byte log artifact (id 8392718477) holds provider.log/control.log —
   the control.log lines show whether `/pause`, `/resume` or `/netdown` were reached
   (the sandbox proxy blocks the artifact blob host; the step log embeds the same info).
2. The hang is in test content introduced/reached via `a78d378` (`5bdb0e1` only added
   the timeout): everything through the retry phase is proven, so suspect the newly
   reachable stretch — post-scrub ply-5 wait, backgrounding (`handleAppLifecycleStateChanged`
   + goto-previous at ply 4), variant switch, server-side deletion, or netdown. Every
   in-test wait is deadline-bounded and the dart-side test timeout is 25 min, so a
   >45 min wedge means the emulator, adb, or `flutter test`'s device connection died —
   check the step log for where output stops.
3. Once fixed and green → update `docs/external-engine.md` (drop the red-workflow status
   caveat) and `docs/external-engine-next-steps.md` (record the cronet→dart:io fix),
   commit, merge to main.
4. Mind gotchas 2 and 3 below when touching label assertions or popups.
5. GitHub API 503s and runner crashes both happened this session — re-run before
   assuming a regression.

Hard-won gotchas from this session (beyond the list at the bottom of this doc):

1. **The workflow does not trigger on `lib/**` pushes** — its `paths` filter only covers
   `integration_test/**`, the workflow, and the scripts. For app-code changes, dispatch it
   manually (`workflow_dispatch`).
2. **Live-binding long-presses are unreliable**: synthetic pointer holds only register
   while the UI is animating/rendering frames. `tester.longPress` (and even a wall-clock
   hold) silently does nothing on a static screen. Use `openEnginePopup` /
   `longPressFor` in the test; the real gesture is covered by
   `test/view/engine/engine_button_test.dart`.
3. **The eval cache defeats label assertions**: a position with a cached eval of
   `searchTime >=` the requested 4s is served from cache — no engine work starts, `work`
   is cleared, and the chip label shows the *local* engine. Phases asserting the external
   engine's label must end on a never-fully-evaluated position.
4. **Runner crashes happen**: run #15 attempt 1 died mid-emulator-step (job failed with
   the test step stuck `in_progress`, logs 404). Just re-run.

Remaining plan: on a green run, update `docs/external-engine.md` (drop the red-workflow
status caveat) and `docs/external-engine-next-steps.md` (record the bug + fix), then merge
to main. The sections below are the original handoff, kept for the full diagnosis record.

## TL;DR

- The on-device E2E pipeline works end-to-end in GitHub Actions (emulator, seeded
  session, live lichess.org + broker, provider control server). Ten checklist phases
  are implemented in `integration_test/external_engine_test.dart`.
- **The pipeline uncovered a real app bug — the current blocker**: on Android
  (emulator, embedded cronet), the external engine analyse stream **never delivers a
  single eval line to the app**. Every request dies on the 8s first-line watchdog and
  falls back to the local engine. The provider demonstrably receives the job and
  streams evals; the bytes just never reach the Dart stream. See "The open bug" below.
- Because of this, the workflow is **red on purpose**: the streaming assertion was made
  honest in `c710839` (it previously passed during the transient "connecting" window,
  which is how earlier runs looked green without streaming ever working).
- Fix the bug first; the later test phases (go deeper, scrubbing, etc.) are all
  downstream of working streaming and were written to match the intended behavior.

## The open bug: external analyse stream yields nothing on Android

### Evidence (run 29476036341, commit c710839 — reproducible on every run)

App side (now printed in the test output as `[E2E:ExternalEngineClient]`):

```
INFO: Requesting analysis from external engine E2E CI ... at ply 6 ...
WARNING: External engine failure: TimeoutException after 0:00:08.000000: No response from external engine
```

Provider side (printed at the end of the "Run the E2E test on the emulator" step):

```
INFO:root:Handling job AeHpQFLWzkCck7YJ
INFO:root:Connection closed while streaming analysis
```

So the request reaches the broker, the broker dispatches to the provider, the provider
runs Stockfish and streams evals back — and the app's `ExternalEngineClient` watchdog
fires after 8s having seen zero lines, closes the connection (that's the provider's
"Connection closed while streaming"), marks the engine offline, and falls back to the
local engine.

Meanwhile, **Tier 1** (`external-engine-live-test.yml`, the spike CLI on the plain Dart
VM on the runner host) streams the same endpoint fine. The difference is the HTTP
stack: the app on Android uses **embedded cronet** (`cronetHttpNoPlay=true` dart-define,
`cronet_http` package); the spike uses `dart:io`.

### Primary hypothesis

Cronet buffers the streamed response body and does not deliver small chunks promptly.
The analyse response is tiny ND-JSON (a few hundred bytes per eval snapshot, a few KB
total over the 4s movetime) — likely below cronet's flush threshold. Note the watchdog
fired at 8s while the provider was *still* streaming, i.e. not even the movetime≈4s
stream end flushed anything — worth verifying whether the broker holds the response
open beyond the provider's last line, or whether the app's repeated attempts confuse
the job timeline (each retry opens a new broker job; the provider log shows several).

### Where the code is

- `lib/src/model/engine/external/external_engine_client.dart` — watchdogs (8s first
  line / 30s stall), request lifecycle. The client is created per-request from
  `HttpClientFactory` (`_clientFactory()`).
- `lib/src/model/engine/external/external_engine_repository.dart` —
  `externalEngineAnalyseStream` builds `POST https://engine.lichess.ovh/api/external-engine/{id}/analyse`
  and parses the ND-JSON stream via `postNdJsonStream` (`lib/src/network/http.dart`,
  `_sendNdJsonStreamRequest`).
- The factory/wiring is in `lib/src/model/engine/evaluation_service.dart` (constructor)
  and `lib/src/network/http.dart` (`httpClientFactoryProvider` — cronet on Android).

### Suggested experiments / fixes (in order)

1. **Swap the analyse request to a `dart:io`-backed client** (`IOClient` from
   `package:http/io_client.dart`) instead of the cronet factory client — just for this
   one streaming request. If streaming then works, that is likely the ship-able fix
   (document why). Cancellation semantics must be preserved: closing the client must
   abort the connection (dart:io `IOClient.close()` does).
2. If preferring to keep cronet: investigate `cronet_http` streaming behavior/issues
   (buffering of `read()` delivery), and whether disabling HTTP response caching or
   setting a smaller read buffer changes anything.
3. Rule out middleboxes: the emulator NATs through the runner; Tier 1 from the same
   host streams fine, so the network path itself is fine.
4. Check iOS/cupertino_http for the same class of problem before calling it done
   (no iOS CI leg exists; that would be a phone check).

**Impact**: the sideload APK (`build-apk.yml`) is built with `cronetHttpNoPlay=true`,
so a real phone almost certainly has the same bug — this is not emulator-specific.
Fixing it is a prerequisite for the feature working at all on Android.

### How earlier runs looked green without streaming working

The engine-name label under the engine chip shows while the status is *connecting* as
well as *connected*; the original assertions matched during that transient window.
`c710839` made the core assertion honest: the label AND a numeric depth must be visible
inside `EngineButton` in the same frame (only true when eval lines actually arrive).
The offline/fallback/retry phases were similarly satisfiable by fast-fail loops. After
the bug fix, all phases should be re-validated against a genuinely streaming engine.

## State of the branches / PRs

- **main**: has PR #7 + PR #8 = the 4-phase E2E pipeline that was "green" (see caveat
  above), workflow fixes, token-scope docs.
- **`claude/automate-e2e-phone-tests-w7kdfw`** (this PR's branch), on top of main:
  - `e8e1fd1` six more checklist phases (go deeper, scrubbing, simulated backgrounding,
    unsupported variant, server-side deletion, emulator airplane mode) + control-server
    `/netdown/<seconds>` endpoint.
  - `8b1a4a0` go-deeper phase waits out post-resume backlogs.
  - `be94dc2` popup dismissal via app-bar tap (a blind corner tap was hitting the back
    button and popping the analysis screen).
  - `c710839` diagnostics + honest streaming assertion (see above).

## How the pipeline works (quick reference)

- **Workflow**: `.github/workflows/external-engine-e2e-test.yml`. Triggers: push to
  `main`/`claude/**` touching `integration_test/**`, the workflow, or the scripts; and
  `workflow_dispatch`. Concurrency group serializes runs (cleanup deletes all
  `E2E CI *` engines on the account). Skips gracefully with a notice if the
  `LICHESS_API_TOKEN` secret is missing.
- **Auth**: no user credentials. The test seeds the app session before boot: writes
  `first_run=false` + an SRI, fetches `/api/account` with the raw token, writes
  `AuthUser` JSON to the `AuthStorage` secure-storage key, then runs the production
  `main()`. Token = `LICHESS_API_TOKEN` repo secret, scopes `engine:read`,
  `engine:write`, `preference:read` (rotated 2026-07-16; the old engine-only token
  caused tolerated 403s on `/api/account/preferences`; `/api/mobile/home` still 403s —
  needs `web:mobile`, tolerated).
- **Provider**: reference `lichess-org/external-engine` + apt Stockfish on the runner
  host, engine named `E2E CI <run id>`.
- **Control server**: `.github/scripts/e2e_provider_control.py` on host port 8899
  (emulator reaches it at `10.0.2.2:8899`). `/pause` `/resume` (SIGSTOP/SIGCONT keeps
  the engine registration), `/netdown/<seconds>` (emulator airplane mode via adb with
  host-side timed restore), `/health`.
- **Test invocation**: `.github/scripts/run_e2e_test.sh` (the emulator-runner action
  executes each `script:` line as a separate shell — don't inline multi-line commands).
  It also dumps provider.log / control.log / logcat excerpts into the step output, so
  failures can be diagnosed without downloading artifacts (the Claude sandbox proxy
  blocks the artifact blob host).
- **Diagnosing**: the app only prints `HttpClient`/`Socket`/`EvaluationService` loggers
  to the console (`_loggersToShowInTerminal` in
  `lib/src/model/log/app_log_service.dart`); the test additionally prints
  `ExternalEngineClient` records itself.

## Hard-won test-writing gotchas (don't relearn these)

1. `pumpAndSettle` never settles (shimmers/spinners) — use the `pumpUntil*` helpers.
2. Route transitions keep the previous screen onstage briefly — pop screens whose text
   could false-match, and scope finders (`find.descendant(of: find.byType(EngineButton), ...)`).
3. Dismiss popovers by tapping the app-bar center (`dismissPopover`), never a corner.
4. The engine label truncates names > 8 chars (`E2E CI 123…` → `E2E CI …`), match the
   prefix.
5. Signing out in a test would revoke the CI token itself (`DELETE /api/token`) — never
   automate logout with the shared secret.
6. Never commit the sandbox-local sqlite3 `hooks:` block that
   `scripts/claude-sandbox-setup.sh` appends to `pubspec.yaml`.
7. Rotating the Lichess token while a run is in flight kills that run mid-way
   ("No such token") — re-run after rotating.

## Suggested plan for the next session

1. Reproduce/fix the streaming bug (experiment 1 above: `dart:io` client for the
   analyse stream). Iterate via pushes to a `claude/**` branch — every push runs the
   E2E workflow; read the step output diagnostics.
2. Once the honest streaming assertion passes, watch the remaining phases; expect some
   timing tuning (they were written against intended behavior but have never run
   against a genuinely streaming engine).
3. When green: update `docs/external-engine.md` (checklist claims are accurate again),
   note the bug + fix in `docs/external-engine-next-steps.md`, merge to main.
4. Then the only genuinely-manual leftovers are: logout/account-switch, real 5-min OS
   backgrounding, real radio airplane mode, settings stale-entry after the 5-min cache,
   threat-mode by eye, and the `web:mobile` OAuth scope question (needs a real login;
   also decide whether to add `engine:read` to the app's requested scopes in
   `lib/src/model/auth/auth_repository.dart`).
