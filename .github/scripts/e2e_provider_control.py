#!/usr/bin/env python3
"""Control server for the external engine E2E workflow.

Lets the integration test running on the Android emulator drive host-side conditions:

- /pause, /resume: SIGSTOP/SIGCONT the provider process to exercise the app's offline
  fallback and retry paths. Signals are used instead of kill/restart so the provider keeps
  its engine registration (and id) — the app's Retry action re-dispatches to the same id.
- /netdown/<seconds>: turn on airplane mode on the emulator via adb, and automatically
  turn it back off after <seconds>. The auto-restore is host-side because the emulator
  loses its route to this server while airplane mode is on.
- /health: liveness probe.

Usage: e2e_provider_control.py <provider-pid> [port]
"""

import http.server
import os
import shutil
import signal
import subprocess
import sys
import threading

PROVIDER_PID = int(sys.argv[1])
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8899

ADB = (
    shutil.which("adb")
    or os.path.join(os.environ.get("ANDROID_HOME", "/usr/local/lib/android/sdk"), "platform-tools", "adb")
)


def set_airplane_mode(enabled):
    state = "enable" if enabled else "disable"
    result = subprocess.run(
        [ADB, "-s", "emulator-5554", "shell", "cmd", "connectivity", "airplane-mode", state],
        capture_output=True,
        text=True,
        timeout=30,
    )
    sys.stderr.write(
        "control: airplane-mode %s -> rc=%d out=%r err=%r\n"
        % (state, result.returncode, result.stdout.strip(), result.stderr.strip())
    )
    sys.stderr.flush()
    return result.returncode == 0


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        parts = [p for p in self.path.split("/") if p]
        if self.path == "/pause":
            os.kill(PROVIDER_PID, signal.SIGSTOP)
        elif self.path == "/resume":
            os.kill(PROVIDER_PID, signal.SIGCONT)
        elif self.path == "/health":
            pass
        elif len(parts) == 2 and parts[0] == "netdown" and parts[1].isdigit():
            seconds = min(int(parts[1]), 120)
            # Engage after a short delay so this HTTP response reaches the emulator before
            # its network goes away; restore host-side since the emulator can't call back.
            threading.Timer(0.5, set_airplane_mode, args=(True,)).start()
            threading.Timer(0.5 + seconds, set_airplane_mode, args=(False,)).start()
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"ok\n")

    def log_message(self, fmt, *args):
        sys.stderr.write("control: %s\n" % (fmt % args))
        sys.stderr.flush()


if __name__ == "__main__":
    print(f"control server on :{PORT}, provider pid {PROVIDER_PID}, adb {ADB}", flush=True)
    http.server.HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
