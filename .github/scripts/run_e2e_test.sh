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

# Stream the app's own log lines (debugPrint → logcat tag `flutter`) to the step output as
# they happen: `flutter test` buffers every device-side print until the test finishes, so a
# wedged test otherwise produces NO output at all — runs #16/#18 hung for 45 minutes with an
# empty step log. With this stream, the last `[logcat] ... [E2E:...]` line pinpoints where a
# hang happened, live.
adb logcat -T 1 -v time -s flutter:V 2>/dev/null | sed -u 's/^/[logcat] /' &
logcat_stream_pid=$!

# Bound the test with a host-side timeout: the dart-side `testWidgets` timeout is NOT
# enforced for on-device integration tests, and a wedged `flutter test` would otherwise burn
# the 45-minute step timeout, killing this script before the diagnostics below can run
# (run #18's artifact had no logcat for exactly that reason). 35 minutes leaves ample room
# for the ~10-minute build plus the ~5-minute test, and 10 minutes of slack for diagnostics.
timeout --signal=TERM --kill-after=60 2100 \
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
if [ "$status" -eq 124 ]; then
  echo "::error::flutter test was killed by the 35-minute host-side timeout (wedged run)"
fi

kill "$logcat_stream_pid" 2>/dev/null || true

# Keep the device log for the artifact upload, pass or fail.
adb logcat -d > /tmp/logcat.txt || true

# Host- and device-side diagnostics in the step output, so failures can be diagnosed
# without downloading the artifact.
echo "=== provider.log (tail) ==="
tail -n 100 /tmp/provider.log || true
echo "=== control.log ==="
cat /tmp/control.log || true
echo "=== logcat: external engine lines ==="
grep -i "e2e:\|externalengine\|external engine" /tmp/logcat.txt | tail -n 60 || true

exit $status
