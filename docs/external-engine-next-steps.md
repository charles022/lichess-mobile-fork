# External engine — testing status and next steps

> **Current status (2026-07-17): the E2E workflow is green** (run 29549888431, all ten
> phases). The current hardware-test status lives in `external-engine-status.md`; the
> bugs the pipeline caught and their fixes are recorded below.

Status: the feature is merged (`219c7e1`) and its 23 unit tests pass. Real-network
validation and the core on-device E2E flows are now automated in GitHub Actions (see
below); what remains manual is a short list of device-specific checks in
`docs/external-engine.md`.

## Bugs the E2E pipeline caught (and their fixes)

The pipeline paid for itself: it caught two real app bugs and two test-harness design
traps before the feature ever ran on a phone.

1. **Android streaming bug (the big one)**: with the platform-default cronet client, the
   analyse ND-JSON stream never delivered a single eval line to Dart — cronet buffers
   small streamed chunks, so every request died on the 8s first-line watchdog and fell
   back to the local engine. Fix: `HttpClientFactory.createStreamingClient()`, a
   `dart:io` `IOClient` used by `ExternalEngineClient` for the analyse request on all
   platforms (`66ca4af`). Verified on the pipeline: first eval line in 1.2–5.3s, ~20
   evals over the 4s movetime, and closing the client still cancels the analysis at the
   broker (dart:io force-closes the connection). The sideload APK is built with
   `cronetHttpNoPlay=true`, so a real phone would have hit the same bug.
2. **Unhandled refresh errors on the home tab**: `HomeTabScreen._refreshData` (fired
   unawaited on focus-regained and connectivity-restored) had no error handling on its
   `Future.wait` of `ref.refresh(...)` futures, so any failing refresh — a network blip,
   or the CI token's expected `/api/mobile/home` 403 — escaped as an uncaught zone
   error. Fixed by catching the error; each provider already surfaces its failure
   through its own `AsyncValue` (`ce3c1b8`).
3. **Test-harness trap — lifecycle pump deadlock**: `AppLifecycleState.paused` disables
   frame scheduling, and on the live binding `pump` only completes on a real frame, so
   pumping while paused deadlocks the test (and the on-device `testWidgets` timeout is
   NOT enforced, so this burned 45-minute step timeouts). The backgrounding dwell uses
   `Future.delayed`, and the lifecycle walks the legal
   `resumed→inactive→hidden→paused` chain and back (`092d810`, `ce3c1b8`).
4. **Test-harness trap — cloud-eval cache poisoning**: `EvaluationService.evaluate`
   treats a `CloudEval` of any depth as cache (no engine work, in-flight external
   request silently cancelled), and the test's own mid-scrub `evalGet` could fetch one
   for the scrub-end position. All label assertions now run at ply ≥ 16, where the app
   never requests cloud evals (`_canCloudEval` cuts off at ply 15) (`092d810`).

Diagnosability lesson baked into the runner script: `flutter test` buffers all
device-side prints until a test finishes, so a wedged test produces an empty step log.
`run_e2e_test.sh` now streams logcat's `flutter` tag live into the step output and
bounds `flutter test` with a host-side 35-minute `timeout` so diagnostics always run.

## Test environment decision

**GitHub Actions on this fork is the execution environment for all automated testing.**
Evaluated against containers, VMs and cloud instances (Cloudflare was the stated
preference if a cloud were needed), Actions wins on every axis that matters here:

- Already enabled and proven on the fork: the `Build sideload APK` workflow has run
  successfully, and the `Tests` workflow runs on every push.
- Runners have unrestricted egress to `lichess.org` and `engine.lichess.ovh` (the
  agent sandbox proxy blocks both, so live tests can *only* run in CI or on user
  hardware).
- Repository secrets keep the Lichess token out of agent/sandbox hands entirely.
- Linux runners expose `/dev/kvm`, so a hardware-accelerated Android emulator is
  available if automated on-device tests are built later (the agent sandbox has no
  KVM).
- Free for a public repo, no new accounts or infrastructure, and an agent session can
  trigger runs and read logs through the GitHub API — so the whole loop (edit → push →
  execute → diagnose) closes without human relay.

Cloudflare specifically has no fitting product: Workers are V8 isolates (no processes,
no Stockfish), and Cloudflare Containers provide neither KVM nor a persistent
Android-capable VM. A generic VPS (any vendor) would work for hosting a *long-lived
provider daemon* later, but adds credential and infrastructure management with no
benefit for test execution.

## Test tiers

| Tier | What | Where | Status |
|------|------|-------|--------|
| 0 | Unit tests (mocked broker/engine) | `Tests` workflow, now also on `claude/**` branches | ✅ automated |
| 1 | Live protocol validation (real provider + broker + API) | `External engine live protocol test` workflow | ✅ automated, needs `LICHESS_API_TOKEN` secret |
| 2 | On-device E2E (UI, session, fallback UX) | `External engine E2E test (emulator)` workflow | ✅ automated (core flows), needs `LICHESS_API_TOKEN` secret |
| 3 | Physical-device / account checks | Sideload APK on a phone | manual, much reduced (see `docs/external-engine.md`) |

### Tier 1: the live protocol workflow

`.github/workflows/external-engine-live-test.yml` installs Stockfish and the reference
provider (`lichess-org/external-engine`), registers a temporary engine named
`CI run <run id>` on the token's account, and drives `tool/external_engine_spike.dart`
against the real API and broker. It automates the validation checklist from
`docs/external-engine.md`:

- `list` with a raw personal access token — **asserted**
- `list --signed` (the app's HMAC-signed bearer form) — **recorded** as a
  notice/warning, not asserted, because the answer decides whether the app needs auth
  changes (hurdle 1 below)
- `analyse` streams eval lines — **asserted**
- `cp` scores are from the side to move's point of view (black-winning position must
  yield positive cp) — **asserted**; this is the assumption behind the app's score flip
- cancellation by closing the connection — provider log uploaded as an artifact for
  inspection
- behavior when the provider is down — **recorded** (exit status + output), to tune the
  app's 8s first-line timeout

CI engines are deleted from the account at the end of every run (including strays from
earlier failed runs).

**One-time setup (repo owner):** create a Lichess personal access token with the
`engine:read` and `engine:write` scopes (plus `preference:read`, recommended so the
Tier 2 seeded app session can also read account preferences instead of getting a
tolerated 403) at
<https://lichess.org/account/oauth/token/create?scopes[]=engine:read&scopes[]=engine:write&scopes[]=preference:read&description=CI+external+engine>
and save it as the repository secret `LICHESS_API_TOKEN`
(Settings → Secrets and variables → Actions). Then trigger the workflow from the
Actions tab (or push to the workflow's branch). Without the secret the workflow only
verifies that the spike CLI compiles, and skips the live steps with a notice.

## Hurdles — updated

1. **OAuth scope mismatch (open, highest priority).** The app requests only
   `web:mobile` but `GET /api/external-engine` is documented to need `engine:read`.
   The live workflow's `--signed` step provides evidence about the bearer form; the
   scope question itself is only fully answered with a real app session token, i.e. on
   device (or by reading the lila source). If the scope must change,
   `lib/src/model/auth/auth_repository.dart` needs `engine:read` added and users must
   re-login.

2. **Analyse request/response contract (automated — and it found a real bug).** The
   first live run (2026-07-15) proved the broker streams `cp`/`mate` scores from
   **white's point of view**, not the side to move's as the protocol notes assumed: the
   black-to-move winning position streamed cp ≈ -800. The app's UCI-style score flip
   would have inverted the eval whenever black was to move; the flip has been removed
   (`external_engine_repository.dart`) and Tier 1 now asserts the white-anchored
   convention on every run. The same run also showed lichess.org **accepts the app's
   HMAC-signed bearer form** for `/api/external-engine` (relevant to hurdle 1, though
   the `web:mobile` scope question itself still needs a real app session).

3. **Spike CLI coverage (fixed).** The spike could not previously run on the plain
   Dart VM at all: it imported `bearer.dart`, which pulled in the Flutter-only
   `constants.dart`. `kLichessWSSecret` now lives in `bearer.dart` (no Flutter
   dependency) and CI compiles the spike on every relevant push.

4. **Fallback / watchdog edge cases (open).** Connect/stall watchdogs and the
   offline-fallback path are still only tested against synthetic streams. The Tier 1
   provider-down step records real broker behavior to inform timeout tuning; deeper
   edge cases (partial lines, mid-stream errors, session reuse) remain unit-test work.

5. **Sideload build path (validated).** The `Build sideload APK` workflow ran
   successfully on 2026-07-14 (run 1, `main`).

6. **Provider setup ergonomics (improved).** The live workflow doubles as an executable
   version of the provider runbook: its steps are exactly the commands a human needs on
   a server, kept green by CI.

### Also fixed while setting this up

The `Tests` workflow was red on `main`: the (correct) ND-JSON newline-splitting from
`dbbecc9` broke the opening explorer tests, whose mocked `/player` responses were
pretty-printed multi-line JSON. The fixtures are now normalized to single-line ND-JSON
at the mock sites (`test/model/explorer/opening_explorer_repository_test.dart`,
`test/view/explorer/opening_explorer_screen_test.dart`).

## Tier 2: the emulator E2E workflow

`.github/workflows/external-engine-e2e-test.yml` boots the real app on a
hardware-accelerated Android emulator (`reactivecircus/android-emulator-runner`, KVM),
with the reference provider + Stockfish running on the workflow host, and drives the UI
with `integration_test/external_engine_test.dart` against the real lichess.org API and
broker. It covers, from the on-device checklist:

- the registered engine appears in Settings → Chess engine and can be selected;
- a fresh analysis session streams evals from the external engine (name shown under the
  engine chip);
- provider down → offline snackbar and fallback to the local engine;
- provider back + long-press → Retry → external analysis resumes.

Design decisions worth knowing:

- **Authentication without credentials.** The OAuth browser flow cannot be driven by a
  Flutter test, and no app-code backdoor was added. Instead the test *seeds the session*
  before the app boots: it writes an `AuthUser` (user fetched from `/api/account` +
  token) to the exact secure-storage key `AuthStorage` uses, sets `first_run=false` so
  `initializeApp` doesn't wipe secure storage, and then calls the production `main()`.
  The token is the existing `LICHESS_API_TOKEN` secret — lichess accepts the app's
  HMAC-signed bearer form for personal access tokens (verified by Tier 1), and
  `/api/token/test` (the app's session validity check) accepts them too. **No user
  login credentials are ever needed.**
- **Offline fallback is exercised with SIGSTOP/SIGCONT**, not kill/restart, via a tiny
  control server on the host (`.github/scripts/e2e_provider_control.py`, reachable from
  the emulator at `10.0.2.2:8899`). Pausing keeps the provider's engine registration
  (same id), so the app's Retry re-dispatches to the same engine.
- **The analysed position is an offbeat line** (`1. h4 a5 2. Rh3 Ra6 3. Rg3 Rh6`) so no
  deep cloud eval short-circuits the engine work.
- Engines are registered as `E2E CI <run id>` and all `E2E CI *` engines are deleted at
  the end of every run; a concurrency group prevents overlapping runs from deleting each
  other's engines.

The lila-docker alternative (hermetic, no secrets) remains possible but was not needed:
the seeded-session approach required zero app changes and reuses the already-configured
secret.

## Handoff to a hardware/account pass (much reduced)

Still requiring a human with a phone and account:

- The device-specific leftovers of the checklist in `docs/external-engine.md`
  (backgrounding the app for 5 minutes, airplane mode, and a sanity pass of the
  remaining unautomated items).
- Confirming the OAuth scope behavior with a real app session (hurdle 1) — the E2E test
  authenticates with a personal access token, not a `web:mobile` session token, so this
  question is still only answerable with a real login on device (or by reading lila
  source).
