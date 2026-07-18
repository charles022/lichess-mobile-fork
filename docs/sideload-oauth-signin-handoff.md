# Sideload sign-in handoff — OAuth "Something went wrong"

Written 2026-07-18, at the point where phone-based verification of the external-engine
OAuth-scope question (see `docs/external-engine-next-steps.md`, hurdle 1) hit a blocker:
**signing into the sideloaded app fails**, before that question could even be tested.
**Read this first when picking the work back up on a machine with the phone connected via
USB.**

## Goal (why we're here)

`docs/external-engine-next-steps.md` hurdle 1 is still open: whether the app's OAuth
session (scope `web:mobile`, see `oauthScopes` in `lib/src/model/auth/auth_repository.dart:22`)
is sufficient for `GET /api/external-engine`, or whether the app needs to request
`engine:read` explicitly. This can only be answered with a real device login — a
personal-access-token shortcut was tried and ruled out (lichess's token-creation page
redirects to a generic page when `scopes[]=web:mobile` is requested; `web:mobile` isn't
grantable to a PAT). The plan was: sideload the fork, sign in for real, and check whether
a registered external engine shows up in Settings → Chess engine → External engines.

**That plan is blocked at the sign-in step.**

## Current blocker

1. Fresh sideload APK installed (see "Build info" below), official Play Store app
   uninstalled first (both share package id `org.lichess.mobileV2`).
2. Tapped **Sign in** on the app's home screen → opens the system browser, already
   logged into lichess.org as **m0ranmcharles**.
3. Browser shows the OAuth consent screen ("Allow Lichess Mobile to access your
   m0ranmcharles account") → tapped **Sign in with Lichess Mobile**.
4. Browser redirects back into the native app (the custom URI scheme handoff works —
   this lands back on the app's own UI, not a stuck browser page).
5. App shows an orange **"Something went wrong."** snackbar at the bottom and remains
   signed out. No further detail is shown in the UI.

## Root-cause investigation so far (code-level, no device logs yet)

Traced the failure path in the current branch's code:

- `lib/src/model/auth/auth_controller.dart:35-38` — `AuthController.signIn()` calls
  `AuthRepository.signIn()` inside a Riverpod `Mutation`.
- `lib/src/view/auth/sign_in_error.dart:10-13` — **any** exception from that mutation
  other than `SignInCancelledException` (user backing out of the browser) triggers the
  exact generic `mobileSomethingWentWrong` snackbar, with no detail surfaced. This is
  why the UI is uninformative by design.
- `lib/src/model/auth/auth_repository.dart:61-96` — `signIn()` does two things in order:
  1. `_appAuth.authorizeAndExchangeCode(...)` — the OAuth PKCE code exchange against
     `lichess.org/oauth` + `lichess.org/api/token`. This part evidently succeeded (we got
     bounced back into the app, not stuck with an OAuth error).
  2. **`GET /api/account`** (line 90-94) — the first authenticated API call, signed with
     `signBearerToken(token)`.
- `lib/src/model/auth/bearer.dart:8-13` — `signBearerToken` HMAC-signs the token with
  `kLichessWSSecret`, which is `String.fromEnvironment('LICHESS_WS_SECRET', defaultValue:
  'somethingElseInProd')` — i.e. a **placeholder** unless the real secret was passed as a
  `--dart-define` at build time.
- Checked the actual build job log for the APK installed on the phone (run 29616747007,
  job 88003382709, step "Build release APK (arm64)"): the invoked command was
  ```
  flutter build apk --release --target-platform android-arm64 \
    --dart-define=cronetHttpNoPlay=true \
    --dart-define=LICHESS_HOST=lichess.org \
    --dart-define=LICHESS_WS_HOST=socket.lichess.org
  ```
  **No `--dart-define=LICHESS_WS_SECRET=...`** — confirming the `WS_SECRET` repo secret
  isn't configured, so this build shipped with the placeholder secret, not the real one.

**Leading hypothesis**: `GET /api/account` gets rejected by lichess.org because the
HMAC-signed bearer's signature doesn't match (signed with the placeholder secret), the
exception propagates out of `signIn()`, and that's the generic snackbar. This would also
affect every other authenticated call in the app post-login — `signBearerToken` is used
in `lib/src/network/http.dart:366`, `lib/src/network/socket.dart:232`, and
`lib/src/model/correspondence/correspondence_service.dart:144` too, not just this one
call — so if the hypothesis is right, this isn't a login-only problem.

**This is not yet confirmed.** It's not known from this sandbox whether lichess.org's
server actually enforces the HMAC signature strictly (vs. leniently accepting just the
token substring before the `:`). That's genuinely unverified server-side behavior, not
something answerable by reading this repo's code alone.

## Next steps for the picked-up session (needs the phone on USB)

1. Confirm the phone is visible: `adb devices`.
2. Reproduce the sign-in attempt (steps 2-5 above) while tailing logs:
   ```bash
   adb logcat | grep -iE "lichess|AuthRepository|HttpClient|flutter|40[13]"
   ```
   Widen the filter (or drop it and search the raw output) if nothing matches — the goal
   is to find the real HTTP status / exception text behind the generic snackbar, printed
   by the `HttpClient`/`AuthRepository` loggers (`lib/src/model/log/app_log_service.dart`
   lists which loggers print to console).
3. Confirm or rule out the missing-WS-secret hypothesis based on what the log shows:
   - **401/403 from `GET /api/account`** → hypothesis confirmed. Next question: is a
     real `LICHESS_WS_SECRET` obtainable at all for a personal fork (it's presumably not
     public)? If not, this may mean the signed-bearer requirement needs to be worked
     around in app code for the fork specifically (e.g. skip signing when no real secret
     is configured) — that's a design decision, not a quick fix; don't attempt it without
     checking in on the approach.
   - **Something else** (network error, redirect_uri mismatch, JSON parse failure, a
     different status code) → the WS-secret theory is likely wrong; the log content
     itself will point at the real cause. Re-read `auth_repository.dart:61-96` with that
     evidence in hand.
4. Once sign-in succeeds: the external engine provider (see "Provider setup" in
   `docs/external-engine.md`) needs to be running and registered to **m0ranmcharles**
   with its own dedicated personal access token (`engine:read` + `engine:write` — do
   **not** reuse the CI `LICHESS_API_TOKEN` secret, it gets rotated by CI runs). Then
   open Settings → Chess engine → External engines in the app and check whether the
   registered engine appears — that's the actual test that resolves hurdle 1 in
   `docs/external-engine-next-steps.md`.

## Build info (the APK currently installed on the phone)

- Workflow: **Build sideload APK** (`.github/workflows/build-apk.yml`), run
  [29616747007](https://github.com/charles022/lichess-mobile-fork/actions/runs/29616747007)
  (run #3), triggered manually (`workflow_dispatch`).
- Commit: `d23c4b988274cfc7ec0da12bdd63bcfb9418b09b` on `main` (merge of PR #13, "Add setup
  script for the external engine provider machine") — includes all E2E/streaming fixes
  through PR #12.
- Artifact: `lichess-mobile-apk`, id `8420997347`, expires 2026-07-31.
- Signed with an ephemeral per-build key (no `SIDELOAD_KEYSTORE*` secrets configured) —
  a rebuild will require uninstalling before reinstalling again.
- Android's OS-level **Advanced Protection > Apps** "block installs from unknown
  sources" toggle had to be disabled on-device to allow the sideload install.

## Open items this session did NOT get to

- The actual root cause of the sign-in failure (needs device logs, see above).
- Hurdle 1 itself (`web:mobile` scope sufficiency for `GET /api/external-engine`) —
  still blocked behind the sign-in issue.
- Whether a real `LICHESS_WS_SECRET` is obtainable/appropriate for this fork at all.
