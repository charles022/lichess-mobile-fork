#!/usr/bin/env bash
# Runs the external engine E2E integration test on the emulator started by
# reactivecircus/android-emulator-runner. That action executes each line of its `script:`
# input as a separate shell invocation, so the whole run lives in this file instead.
#
# Expects LICHESS_API_TOKEN and ENGINE_NAME in the environment; LICHESS_WS_SECRET is optional.
set -uo pipefail

extra_defines=()
if [ -n "${LICHESS_WS_SECRET:-}" ]; then
  extra_defines+=("--dart-define=LICHESS_WS_SECRET=${LICHESS_WS_SECRET}")
fi

flutter test integration_test/external_engine_test.dart \
  -d emulator-5554 \
  --timeout none \
  --dart-define=LICHESS_HOST=lichess.org \
  --dart-define=LICHESS_WS_HOST=socket.lichess.org \
  --dart-define=cronetHttpNoPlay=true \
  --dart-define=E2E_LICHESS_TOKEN="${LICHESS_API_TOKEN}" \
  --dart-define=E2E_ENGINE_NAME="${ENGINE_NAME}" \
  "${extra_defines[@]}"
status=$?

# Keep the device log for the artifact upload, pass or fail.
adb logcat -d > /tmp/logcat.txt || true

exit $status
