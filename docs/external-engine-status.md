# External engine status

Updated 2026-07-17.

## What we did

- Built automated live-protocol and Android emulator E2E coverage for the external
  engine integration. The E2E workflow passes all ten phases.
- Fixed Android response buffering by using a `dart:io` client for the external-engine
  analysis stream, and fixed uncaught home-refresh errors found by the E2E workflow.
- Reproduced the sideload sign-in failure on a Pixel 10 Pro and traced it through the
  mobile, `lila`, and `lila-ws` authentication paths.
- Configured the production mobile signing value from Lichess's public F-Droid build,
  rebuilt the APK, installed it, and signed in successfully.

## What we found

- The original APK used `somethingElseInProd` because `LICHESS_WS_SECRET` was absent,
  so Lichess rejected `GET /api/account` with 401 after a successful OAuth callback.
- Ordinary OAuth endpoints accept raw bearer tokens, but a token carrying the
  privileged `web:mobile` scope is a signed-client token. Production `lila` requires
  its valid HMAC, and `lila-ws` has no raw-token fallback.
- The signing value is not a maintainer-only credential: Lichess publishes it in the
  official F-Droid build so that those APKs are reproducible. It is a shipped client
  build constant, not an account or server secret.
- The fixed APK has authenticated successfully. Its HTTP log shows 200 responses from
  `/api/account/preferences` and `/api/mobile/home`; a clean socket reconnect reaches
  the established ping/pong state using the same signed bearer authentication path.
- The physical-device request to `GET /api/external-engine` returns 403 with only
  `web:mobile`, confirming that the app must request `engine:read` explicitly.

## What we are doing next

1. Build and install the app with `engine:read` added to its OAuth request.
2. Sign in again and confirm that Settings → Chess engine → External engines lists the
   account's registered provider.
3. Run the remaining physical-device external-engine checks.
