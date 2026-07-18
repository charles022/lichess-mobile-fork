# External engine status

Updated 2026-07-17.

## What we did

- Built automated live-protocol and Android emulator E2E coverage for the external
  engine integration. The E2E workflow passes all ten phases.
- Fixed Android response buffering by using a `dart:io` client for the external-engine
  analysis stream, and fixed uncaught home-refresh errors found by the E2E workflow.
- Installed the sideload APK on a Pixel 10 Pro and reproduced OAuth sign-in while
  capturing Android and in-app HTTP logs over USB.

## What we found

- The browser authorization and custom-URI callback both succeed.
- Immediately after the callback, `GET /api/account` returns `401 Unauthorized`.
- The APK was built without `LICHESS_WS_SECRET`. It therefore appends an HMAC made with
  the placeholder `somethingElseInProd` to the OAuth token, which Lichess rejects.
- This blocks the remaining physical-device test: whether a real `web:mobile` OAuth
  session can list external engines without also requesting `engine:read`.

## What we are doing next

1. Determine the supported authentication path for personal sideload builds without
   embedding Lichess's private signing secret.
2. Implement and test explicit no-secret behavior instead of generating an invalid
   signed bearer with the placeholder.
3. Build and install a new APK, confirm sign-in and authenticated API calls, then check
   Settings → Chess engine → External engines with a provider registered to the signed-in
   account.
4. Based on that result, either keep `web:mobile` or add `engine:read` to the requested
   OAuth scopes and require users to sign in again.
