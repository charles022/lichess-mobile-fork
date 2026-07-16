#!/usr/bin/env python3
"""Control server for the external engine E2E workflow.

Lets the integration test running on the Android emulator pause and resume the external
engine provider process on the workflow host (reachable from the emulator at 10.0.2.2), to
exercise the app's offline fallback and retry paths.

SIGSTOP/SIGCONT are used instead of kill/restart so the provider keeps its engine
registration (and id) — the app's Retry action re-dispatches work to the same engine id.

Usage: e2e_provider_control.py <provider-pid> [port]
"""

import http.server
import os
import signal
import sys

PROVIDER_PID = int(sys.argv[1])
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8899


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/pause":
            os.kill(PROVIDER_PID, signal.SIGSTOP)
        elif self.path == "/resume":
            os.kill(PROVIDER_PID, signal.SIGCONT)
        elif self.path == "/health":
            pass
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
    print(f"control server on :{PORT}, provider pid {PROVIDER_PID}", flush=True)
    http.server.HTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
