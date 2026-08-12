#!/usr/bin/env python3
"""
faultproxy.py — Stateful HTTP fault-injecting reverse proxy.

Sits on a high port (default 9797) and forwards requests to a real backend
(default http://127.0.0.1:80).  For requests whose path starts with
FAULT_PATH it injects failures for the first FAIL_TIMES attempts, then
passes through transparently.  Used by the e2e suite to test retry logic in
zoqa-clone-job and openqa-clone-job without needing CAP_NET_ADMIN.

Configuration via command-line arguments:
  --port, -p         TCP port to listen on                         (default: 9797)
  --backend, -b      Backend base URL                              (default: http://127.0.0.1:80)
  --fault-path, -f   URL prefix that triggers fault injection      (default: /tests/)
  --fault-mode, -m   Failure mode: 503 | 404 | reset | partial | partial_cl (default: 503)
  --fail-times, -t   How many initial requests to fault-inject     (default: 2)
  --partial-bytes    Bytes to stream before TCP RST (partial mode) (default: 64)
  --count-file, -c   Path to write per-path hit counts to; written
                     on each request so the test can poll/read it  (default: /tmp/faultproxy_counts.txt)

Hit counts (per-path):
  On each request the proxy appends one line to COUNT_FILE:
      PATH STATUS_CODE ATTEMPT_NUMBER
  Tests can grep this file to verify how many attempts were made.

Usage (inside the container, non-blocking):
  python3 /app/tests/e2e/fixtures/faultproxy.py --fail-times 2 --fault-path /tests/ &
  PROXY_PID=$!
  # ... run clone-job pointing --from http://127.0.0.1:9797 ...
  kill $PROXY_PID
"""

import http.server
import argparse
import os
import socket
import sys
import urllib.error
import urllib.request

# Per-path hit counters: path -> int
_hit_counts = {}


class FaultProxyHandler(http.server.BaseHTTPRequestHandler):
    port = 9797
    backend = "http://127.0.0.1:80"
    fault_path = "/tests/"
    fault_mode = "503"
    fail_times = 2
    partial_bytes = 64
    count_file = "/tmp/faultproxy_counts.txt"

    def _record(self, path, status):
        # Self-resetting behavior: if the count file is empty or does not exist,
        # clear our in-memory hit counts so tests can reset proxy state instantly
        # simply by truncating the file, avoiding flaky process restarts.
        try:
            if not os.path.exists(self.count_file) or os.path.getsize(self.count_file) == 0:
                _hit_counts.clear()
        except OSError:
            pass

        _hit_counts[path] = _hit_counts.get(path, 0) + 1
        attempt = _hit_counts[path]
        try:
            with open(self.count_file, "a") as fh:
                fh.write("%s %s %d\n" % (path, status, attempt))
        except OSError:
            pass
        sys.stderr.write("[proxy] %s %s attempt=%d\n" % (status, path, attempt))
        sys.stderr.flush()
        return attempt

    def do_HEAD(self):
        self._handle("HEAD")

    def do_GET(self):
        self._handle("GET")

    def _handle(self, method):
        path = self.path

        if self.fault_mode.lower() == "partial_no_meta" and path.startswith("/api/v1/assets"):
            self._handle_assets_no_meta(method)
            return

        if self.fault_mode.lower() == "partial_no_meta_502" and path.startswith("/api/v1/assets"):
            self.send_response(502)
            self.end_headers()
            self.wfile.write(b"502 Bad Gateway - faultproxy injection\n")
            sys.stderr.write("[proxy] 502 injected for assets metadata\n")
            sys.stderr.flush()
            return

        # partial mode only faults GET (body-streaming) requests.
        # HEAD requests always pass through so they do not consume the fault
        # budget — we want the asset GETs to be the ones that get the RST.
        skip_fault = method == "HEAD" and self.fault_mode.lower() in ("partial", "partial_no_meta", "partial_no_meta_502")
        if not skip_fault and path.startswith(self.fault_path):
            attempt = self._record(path, "?")
            if attempt <= self.fail_times:
                self._inject_fault(path, attempt)
                return

        # Forward to backend
        self._forward(method, path)

    def _handle_assets_no_meta(self, method):
        url = self.backend + self.path
        try:
            req = urllib.request.Request(url, method=method)
            for k, v in self.headers.items():
                if k.lower() not in ("host", "accept-encoding"):
                    req.add_header(k, v)
            with urllib.request.urlopen(req, timeout=120) as resp:
                body = resp.read()
                if resp.status == 200 and "application/json" in resp.headers.get("content-type", ""):
                    try:
                        import json
                        data = json.loads(body.decode("utf-8"))
                        if isinstance(data, dict) and "assets" in data:
                            for asset in data["assets"]:
                                if isinstance(asset, dict) and "size" in asset:
                                    del asset["size"]
                        body = json.dumps(data).encode("utf-8")
                    except Exception as e:
                        sys.stderr.write("[proxy] json parse/manipulation error: %s\n" % e)
                        sys.stderr.flush()

                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() in ("content-type", "x-api-microtime", "x-api-key", "x-api-hash"):
                        self.send_header(k, v)
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                sys.stderr.write("[proxy] 200 forwarded assets metadata (stripped size, %dB)\n" % len(body))
                sys.stderr.flush()
        except urllib.error.HTTPError as exc:
            self.send_response(exc.code)
            self.end_headers()
            sys.stderr.write("[proxy] %d forward-assets-error\n" % exc.code)
            sys.stderr.flush()
        except Exception as exc:
            self.send_response(502)
            self.end_headers()
            sys.stderr.write("[proxy] 502 forward-assets-exception: %s\n" % exc)
            sys.stderr.flush()

    def _inject_fault(self, path, attempt):
        mode = self.fault_mode.lower()
        if mode == "reset":
            # Abruptly close the connection — simulates TCP reset / ECONNRESET
            sys.stderr.write("[proxy] reset connection attempt=%d %s\n" % (attempt, path))
            sys.stderr.flush()
            try:
                self.connection.setsockopt(
                    socket.SOL_SOCKET, socket.SO_LINGER,
                    b'\x01\x00\x00\x00\x00\x00\x00\x00'
                )
            except OSError:
                pass
            # Don't send any response — just close
            return
        elif mode in ("partial", "partial_cl", "partial_no_meta"):
            self._inject_partial_reset(path, attempt, preserve_cl=(mode == "partial_cl"))
            return
        elif mode == "404":
            self.send_response(404)
            self.end_headers()
            self.wfile.write(b"injected 404\n")
            sys.stderr.write("[proxy] 404 injected attempt=%d %s\n" % (attempt, path))
        else:
            # Default: 503 Service Unavailable
            self.send_response(503)
            self.end_headers()
            self.wfile.write(b"injected 503\n")
            sys.stderr.write("[proxy] 503 injected attempt=%d %s\n" % (attempt, path))
        sys.stderr.flush()

    def _inject_partial_reset(self, path, attempt, preserve_cl=False):
        """Forward the GET to the backend, stream exactly partial_bytes bytes of
        the response body, then abruptly reset the TCP connection.

        If preserve_cl is True, forwards Content-Length to allow short-read detection.
        Otherwise, omits Content-Length in the forwarded response so the client receives
        CURLE_RECV_ERROR (56) on the TCP RST rather than CURLE_PARTIAL_FILE (18).
        curl retries error 56 with --retry; it does not auto-retry error 18.
        """
        url = self.backend + path
        sent = 0
        try:
            req = urllib.request.Request(url, method="GET")
            for k, v in self.headers.items():
                if k.lower() not in ("host", "accept-encoding"):
                    req.add_header(k, v)
            with urllib.request.urlopen(req, timeout=120) as resp:
                self.send_response(resp.status)
                # Forward headers; optionally include Content-Length.
                allowed_headers = ["content-type", "x-api-microtime", "x-api-key", "x-api-hash"]
                if preserve_cl:
                    allowed_headers.append("content-length")
                for k, v in resp.headers.items():
                    if k.lower() in allowed_headers:
                        self.send_header(k, v)
                self.end_headers()
                to_send = self.partial_bytes
                while to_send > 0:
                    chunk = resp.read(min(8192, to_send))
                    if not chunk:
                        break
                    self.wfile.write(chunk)
                    sent += len(chunk)
                    to_send -= len(chunk)
                try:
                    self.wfile.flush()
                except OSError:
                    pass
        except Exception as exc:
            sys.stderr.write("[proxy] partial-backend-error %s: %s\n" % (path, exc))
            sys.stderr.flush()
            return
        # Apply SO_LINGER(1,0) before returning so the framework closes the
        # socket with RST instead of FIN.  The client sees partial data then
        # ECONNRESET — exactly the mid-transfer drop scenario we want to test.
        sys.stderr.write("[proxy] partial reset after %dB attempt=%d %s\n" % (sent, attempt, path))
        sys.stderr.flush()
        try:
            self.connection.setsockopt(
                socket.SOL_SOCKET, socket.SO_LINGER,
                b'\x01\x00\x00\x00\x00\x00\x00\x00'
            )
        except OSError:
            pass
        self.close_connection = True

    def _forward(self, method, path):
        url = self.backend + path
        try:
            req = urllib.request.Request(url, method=method)
            for k, v in self.headers.items():
                if k.lower() not in ("host", "accept-encoding"):
                    req.add_header(k, v)
            with urllib.request.urlopen(req, timeout=120) as resp:
                body = b"" if method == "HEAD" else resp.read()
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() in ("content-length", "content-type",
                                     "x-api-microtime", "x-api-key", "x-api-hash"):
                        self.send_header(k, v)
                self.end_headers()
                if body:
                    self.wfile.write(body)
                sys.stderr.write("[proxy] %d forward %s (%dB)\n" % (resp.status, path, len(body)))
                sys.stderr.flush()
        except urllib.error.HTTPError as exc:
            self.send_response(exc.code)
            self.end_headers()
            sys.stderr.write("[proxy] %d forward-error %s\n" % (exc.code, path))
            sys.stderr.flush()
        except Exception as exc:
            self.send_response(502)
            self.end_headers()
            sys.stderr.write("[proxy] 502 forward-exception %s: %s\n" % (path, exc))
            sys.stderr.flush()

    def log_message(self, *_args):
        pass  # silence default access log; all logging is explicit above


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Stateful HTTP fault-injecting reverse proxy.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("--port", "-p", type=int, default=9797, help="TCP port to listen on")
    parser.add_argument("--backend", "-b", default="http://127.0.0.1:80", help="Backend base URL")
    parser.add_argument("--fault-path", "-f", default="/tests/", help="URL prefix that triggers fault injection")
    parser.add_argument(
        "--fault-mode", "-m",
        default="503",
        help="""Failure mode to inject:
- 503: Simulates a transient server overload / gateway error.
       Returns HTTP 503 Service Unavailable with a short body.
       Used by: CLO-84 (Perl retry), CLO-85 (Zig retry on 503), CLO-87 (Perl exhausts retries),
                CLO-88 (retry 0 disables), and CLO-89 (default retry on BFS).
       Verifies: Transient server errors successfully trigger exponential backoff retries.

- 404: Simulates a permanently missing or deleted asset.
       Returns HTTP 404 Not Found.
       Used by: CLO-86 (terminal error), CLO-80/81/82/83 (ignore-missing-assets).
       Verifies: Non-transient errors terminate downloads immediately with exit 1 without retrying,
                 or trigger warnings/skips if ignore-missing-assets is configured.

- reset: Simulates a transport-layer connection failure BEFORE response headers are sent.
         Abruptly resets the connection using SO_LINGER(1,0) -> TCP RST with zero bytes sent.
         Used to verify transport-layer error resilience during the request handshake.

- partial: Simulates an abrupt mid-transfer TCP drop on a LENGTH-LESS body.
           Forwards the GET to backend, returns HTTP 200 headers WITHOUT Content-Length,
           streams partial-bytes of the body, then abruptly closes via SO_LINGER (RST).
           Used by: CLO-98 (Perl length-less drop), CLO-99 (Zig length-less drop).
           Verifies: Silent truncation behavior when a length-less body is unexpectedly terminated.

- partial_no_meta: Simulates an abrupt mid-transfer TCP drop on a LENGTH-LESS body with size metadata stripped.
                  Like partial mode, but also intercepts /api/v1/assets GET requests and strips "size" from JSON.
                  Used by: CLO-102 (Strict Mode), CLO-103 (Permissive Mode).

- partial_no_meta_502: Simulates an abrupt mid-transfer TCP drop on a LENGTH-LESS body, but returns HTTP 502 for the metadata endpoint.
                       Used by: CLO-104 (API Unreachable).

- partial_cl: Simulates an abrupt mid-transfer TCP drop on a LENGTH-BEARING body.
              Forwards the GET, returns HTTP 200 headers WITH Content-Length preserved,
              streams partial-bytes of the body, then abruptly closes via SO_LINGER (RST).
              Verifies: Robust short-read detection and retry mechanisms when bytes received < Content-Length."""
    )
    parser.add_argument("--fail-times", "-t", type=int, default=2, help="How many initial requests to fault-inject")
    parser.add_argument("--partial-bytes", type=int, default=64, help="Bytes to stream before TCP RST (partial mode only)")
    parser.add_argument("--count-file", "-c", default="/tmp/faultproxy_counts.txt", help="Path to write per-path hit counts to")
    args = parser.parse_args()

    FaultProxyHandler.port = args.port
    FaultProxyHandler.backend = args.backend
    FaultProxyHandler.fault_path = args.fault_path
    FaultProxyHandler.fault_mode = args.fault_mode
    FaultProxyHandler.fail_times = args.fail_times
    FaultProxyHandler.partial_bytes = args.partial_bytes
    FaultProxyHandler.count_file = args.count_file

    # Truncate the count file at startup so each test run starts clean.
    try:
        open(FaultProxyHandler.count_file, "w").close()
    except OSError:
        pass

    # Standard socket reuse address flag to prevent "Address already in use" errors during rapid restarts.
    http.server.HTTPServer.allow_reuse_address = True
    server = http.server.HTTPServer(("127.0.0.1", FaultProxyHandler.port), FaultProxyHandler)
    sys.stderr.write(
        "[proxy] listening on 127.0.0.1:%d  backend=%s  fault_path=%s  "
        "mode=%s  fail_times=%d  partial_bytes=%d\n" % (
            FaultProxyHandler.port,
            FaultProxyHandler.backend,
            FaultProxyHandler.fault_path,
            FaultProxyHandler.fault_mode,
            FaultProxyHandler.fail_times,
            FaultProxyHandler.partial_bytes,
        )
    )
    sys.stderr.flush()
    server.serve_forever()
