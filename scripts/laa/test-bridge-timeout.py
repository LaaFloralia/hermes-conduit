#!/usr/bin/env python3
"""Run the Bridge client timeout test against a 30-second loopback response.

Usage: python3 scripts/laa/test-bridge-timeout.py <bridge-client-test-binary> <repo-root>
"""

import http.server
import os
import subprocess
import sys
import threading
import time


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        time.sleep(30)
        body = b'{"data":{"items":[],"nextCursor":null},"requestId":"timeout-test"}'
        try:
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionResetError):
            pass  # The default request should have timed out.

    def log_message(self, format, *args):
        pass  # Do not log request headers or bodies.


def main():
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    env = os.environ.copy()
    env["LAA_BRIDGE_TIMEOUT_TEST_URL"] = f"http://127.0.0.1:{server.server_port}"
    try:
        result = subprocess.run([sys.argv[1], sys.argv[2]], env=env, timeout=55, check=False)
        return result.returncode
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__":
    sys.exit(main())
