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
  --fault-path, -f   URL prefix that triggers fault injection; a
                     comma-separated list of prefixes is accepted (default: /tests/)
  --fault-mode, -m   Failure mode: 503 | 404 | reset | partial | partial_cl |
                     challenge | challenge_no_accept | any 3-digit status code
                     (default: 503)
  --fail-times, -t   How many initial requests to fault-inject     (default: 2)
  --partial-bytes    Bytes to stream before TCP RST (partial mode) (default: 64)
  --retry-after      Retry-After value for injected status responses:
                     an integer is used as-is, "date:+N" renders an HTTP date
                     N seconds in the future, anything else is sent verbatim.
                     Also allowed with 404.  (default: none)
  --header-log       Path to append one line per request:
                     "METHOD PATH accept=<v|-> ua=<v|->".  Never logs API keys.
                     (default: none)
  --pass-redirects   Do not follow backend redirects: a backend 302 + Location
                     reaches the client as-is.  (default: follow)
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

import email.utils
import http.client
import http.server
import argparse
import os
import socket
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import urllib.response

# Per-path hit counters: path -> int
_hit_counts = {}

# Response headers that are always forwarded to the client, in addition to the
# base set (content-length, content-type, x-api-*).  The gatekeeper tests
# (GAT-*) need retry-after / refresh / set-cookie / location to reach the
# client so retry and challenge behaviour can be observed.
_EXTRA_FORWARD_HEADERS = ("location", "retry-after", "refresh", "set-cookie")

# Body of the Anubis-style bot challenge page served by the "challenge" modes.
# Sized around 4 KB to match the page o3's Anubis gatekeeper returns.
_CHALLENGE_BODY = b"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="refresh" content="2; url=/tests/1/asset/hdd/cirros-0.6.3-x86_64-disk.qcow2">
<title>Verifying your browser | Anubis</title>
<style>
body { font-family: system-ui, sans-serif; background: #111; color: #eee;
       display: flex; align-items: center; justify-content: center;
       min-height: 100vh; margin: 0; }
.card { max-width: 40rem; padding: 2rem; border: 1px solid #333;
        border-radius: .5rem; background: #1a1a1a; }
h1 { font-size: 1.25rem; }
code { background: #222; padding: .1rem .3rem; border-radius: .25rem; }
</style>
</head>
<body>
<div class="card">
<h1>Verifying your browser</h1>
<p>This site is protected by <a href="https://github.com/TecharoHQ/anubis">Anubis</a>.
Your browser must solve a proof-of-work challenge before the requested
resource is served. The page will refresh automatically once the challenge
is solved.</p>
<p>If you are seeing this page for a programmatic client, make sure your
request carries an <code>Accept</code> header. Clients without an
<code>Accept</code> header are challenged by default.</p>
<p>Challenge parameters:</p>
<ul>
<li>hash: sha256</li>
<li>difficulty: 5</li>
<li>max time: 30 s</li>
</ul>
<script>
// Proof-of-work challenge stub (inert in the test fixture).
// The real Anubis page computes a nonce whose hash has the required
// number of leading zero bits, then POSTs it to the challenge endpoint.
(function () {
    var start = Date.now();
    var maxWait = 30000;
    function poll() {
        if (Date.now() - start > maxWait) {
            document.body.innerHTML =
                "<h1>Challenge expired</h1><p>Reload the page to try again.</p>";
            return;
        }
        setTimeout(poll, 500);
    }
    poll();
})();
</script>
<p>Diagnostic context (inert): the gatekeeper scores clients on several
signals. A missing or unusual <code>Accept</code> header, an unknown
User-Agent, and a high request rate all raise the score. When the score
exceeds the threshold the resource is withheld and this page is served
instead. Programmatic clients should identify themselves with a stable
User-Agent and send a meaningful Accept header on every request,
including every redirect hop.</p>
<p>Signals evaluated by the gatekeeper: request rate per source address,
header fingerprint (Accept, User-Agent, Accept-Encoding), TLS fingerprint,
and behavioural heuristics. The score is maintained per source address
and decays over time. A client that is challenged should back off and
retry with the Retry-After delay when one is provided, rather than
repeating the request immediately.</p>
<p>For asset downloads specifically, the gatekeeper cannot distinguish a
challenged client from a successful one by status code alone: the
challenge page is served with status 200 and a Content-Length. Clients
that validate the downloaded payload against the expected asset size or
content type will detect the substitution; clients that do not will
silently store the challenge page as if it were the asset. This is the
failure mode observed on openqa.opensuse.org where a ~4 KB HTML page was
received in place of a multi-megabyte qcow2 image.</p>
</div>
</body>
</html>
"""


class FaultProxyHandler(http.server.BaseHTTPRequestHandler):
    port = 9797
    backend = "http://127.0.0.1:80"
    fault_path = "/tests/"
    fault_mode = "503"
    fail_times = 2
    partial_bytes = 64
    count_file = "/tmp/faultproxy_counts.txt"
    retry_after = None
    header_log = None
    pass_redirects = False

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

    def _log_request_headers(self, method):
        # One line per request: METHOD PATH accept=<v|-> ua=<v|->.
        # Only Accept and User-Agent are logged — never X-API-Key or any
        # other credential-bearing header.
        if not self.header_log:
            return
        accept = self.headers.get("Accept")
        ua = self.headers.get("User-Agent")
        line = "%s %s accept=%s ua=%s\n" % (
            method, self.path, accept if accept is not None else "-",
            ua if ua is not None else "-",
        )
        try:
            with open(self.header_log, "a") as fh:
                fh.write(line)
        except OSError:
            pass

    def do_HEAD(self):
        self._handle("HEAD")

    def do_GET(self):
        self._handle("GET")

    def do_POST(self):
        # GAT-28: POST requests are forwarded to the backend with their body.
        self._handle("POST")

    def _handle(self, method):
        path = self.path
        self._log_request_headers(method)

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
        if not skip_fault and self._path_matches_fault(path):
            attempt = self._record(path, "?")
            if attempt <= self.fail_times:
                self._inject_fault(path, attempt, method)
                return

        # Serve static mock repository content for /ibs/ or /repo/ paths
        if path.startswith("/ibs/") or path.startswith("/repo/"):
            self.send_response(200)
            self.send_header("content-type", "text/plain")
            self.end_headers()
            self.wfile.write(b"mock repo content\n")
            self.wfile.flush()
            sys.stderr.write("[proxy] static 200 for repo: %s\n" % path)
            sys.stderr.flush()
            return

        # Forward to backend
        self._forward(method, path)

    def _path_matches_fault(self, path):
        # --fault-path accepts a comma-separated list of prefixes.
        for prefix in self.fault_path.split(","):
            prefix = prefix.strip()
            if prefix and path.startswith(prefix):
                return True
        return False

    def _handle_assets_no_meta(self, method):
        url = self.backend + self.path
        try:
            with self._open_backend(url, method) as resp:
                body = resp.read()
                if resp.status == 200 and "application/json" in resp.headers.get("content-type", ""):
                    try:
                        import json
                        data = json.loads(body.decode("utf-8"))
                        if isinstance(data, dict) and "assets" in data:
                            # List endpoint: GET /api/v1/assets
                            for asset in data["assets"]:
                                if isinstance(asset, dict) and "size" in asset:
                                    del asset["size"]
                        elif isinstance(data, dict) and "size" in data:
                            # By-name endpoint: GET /api/v1/assets/{type}/{name}
                            del data["size"]
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
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError) as exc:
            self.close_connection = True
            sys.stderr.write("[proxy] client disconnected early (assets) %s: %s\n" % (self.path, exc))
            sys.stderr.flush()
        except urllib.error.HTTPError as exc:
            try:
                self.send_response(exc.code)
                self.end_headers()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                self.close_connection = True
            sys.stderr.write("[proxy] %d forward-assets-error\n" % exc.code)
            sys.stderr.flush()
        except Exception as exc:
            try:
                self.send_response(502)
                self.end_headers()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                self.close_connection = True
            sys.stderr.write("[proxy] 502 forward-assets-exception: %s\n" % exc)
            sys.stderr.flush()

    def _open_backend(self, url, method, follow_redirects=True):
        """Open a backend connection, retrying transient failures.

        Retries the fetch up to 3 times, 0.5 s apart, on connection errors
        only (e.g. Apache connection reset).  Without this, a flaky backend
        fetch returns no body to the client, which sees a different error
        (56) and may retry, making the fault-injection hit count
        non-deterministic.

        Returns the open response object; the caller owns it (context manager
        or explicit close).
        """
        resp = None
        for _backend_attempt in range(3):
            try:
                req = urllib.request.Request(url, method=method)
                for k, v in self.headers.items():
                    if k.lower() not in ("host", "accept-encoding"):
                        req.add_header(k, v)
                if method == "POST":
                    length = int(self.headers.get("Content-Length") or 0)
                    req.data = self.rfile.read(length) if length else b""
                if follow_redirects:
                    resp = urllib.request.urlopen(req, timeout=120)
                else:
                    resp = _NoRedirectOpener().open(req, timeout=120)
                break
            except urllib.error.HTTPError:
                raise
            except Exception as exc:
                if _backend_attempt == 2:
                    raise
                sys.stderr.write(
                    "[proxy] backend-retry %d/3 %s: %s\n"
                    % (_backend_attempt + 1, url, exc)
                )
                sys.stderr.flush()
                time.sleep(0.5)
        return resp

    def _inject_fault(self, path, attempt, method):
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
        elif mode == "challenge":
            self._inject_challenge()
            return
        elif mode == "challenge_no_accept":
            # Challenge when the request carries no Accept header.  A request
            # that sends Accept-Encoding but no Accept (e.g. urllib's default
            # "Accept-Encoding: identity") is still challenged — the gatekeeper
            # scores the absence of an Accept header, not the presence of
            # Accept-Encoding.
            if self.headers.get("Accept") is None:
                self._inject_challenge()
            else:
                # Request carries an Accept header: pass through to the backend.
                self._forward(method, path)
            return
        elif mode == "404":
            self.send_response(404)
            if self.retry_after is not None:
                self.send_header("Retry-After", self.retry_after)
            self.end_headers()
            self.wfile.write(b"injected 404\n")
            sys.stderr.write("[proxy] 404 injected attempt=%d %s\n" % (attempt, path))
        elif mode.isdigit() and 100 <= int(mode) <= 599:
            # Generic status mode: any 3-digit status code (408, 429, 500,
            # 504, ...).  Used by GAT-4/5/6/7/8/9/10/11 and GAT-23..27.
            self.send_response(int(mode))
            if self.retry_after is not None:
                self.send_header("Retry-After", self.retry_after)
            self.end_headers()
            self.wfile.write(("injected %s\n" % mode).encode("utf-8"))
            sys.stderr.write("[proxy] %s injected attempt=%d %s\n" % (mode, attempt, path))
        else:
            # Default: 503 Service Unavailable
            self.send_response(503)
            if self.retry_after is not None:
                self.send_header("Retry-After", self.retry_after)
            self.end_headers()
            self.wfile.write(b"injected 503\n")
            sys.stderr.write("[proxy] 503 injected attempt=%d %s\n" % (attempt, path))
        sys.stderr.flush()

    def _inject_challenge(self):
        """Serve an Anubis-style bot challenge page (200, text/html).

        Used by GAT-3 (challenge on /api/v1/), GAT-21 (challenge_no_accept on
        /tests/ + /assets/), GAT-22 (challenge on asset GET) and GAT-41
        (challenge on the hdd asset only).
        """
        body = _CHALLENGE_BODY
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Refresh", "2; url=%s" % self.path)
        self.send_header("Set-Cookie", "anubis_challenge=1; Path=/; Max-Age=300")
        self.send_header("Set-Cookie", "anubis_score=0; Path=/; Max-Age=300")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        sys.stderr.write("[proxy] challenge injected %s (%dB)\n" % (self.path, len(body)))
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
            with self._open_backend(url, "GET") as resp:
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
            with self._open_backend(url, method, follow_redirects=not self.pass_redirects) as resp:
                body = b"" if method == "HEAD" else resp.read()
                self.send_response(resp.status)
                for k, v in resp.headers.items():
                    if k.lower() in ("content-length", "content-type",
                                     "x-api-microtime", "x-api-key", "x-api-hash") \
                            or k.lower() in _EXTRA_FORWARD_HEADERS:
                        self.send_header(k, v)
                self.end_headers()
                if body:
                    self.wfile.write(body)
                sys.stderr.write("[proxy] %d forward %s (%dB)\n" % (resp.status, path, len(body)))
                sys.stderr.flush()
        except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError) as exc:
            self.close_connection = True
            sys.stderr.write("[proxy] client disconnected early %s: %s\n" % (path, exc))
            sys.stderr.flush()
        except urllib.error.HTTPError as exc:
            try:
                self.send_response(exc.code)
                for k, v in exc.headers.items():
                    if k.lower() in _EXTRA_FORWARD_HEADERS:
                        self.send_header(k, v)
                self.end_headers()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                self.close_connection = True
            sys.stderr.write("[proxy] %d forward-error %s\n" % (exc.code, path))
            sys.stderr.flush()
        except Exception as exc:
            try:
                self.send_response(502)
                self.end_headers()
            except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
                self.close_connection = True
            sys.stderr.write("[proxy] 502 forward-exception %s: %s\n" % (path, exc))
            sys.stderr.flush()

    def log_message(self, *_args):
        pass  # silence default access log; all logging is explicit above


class _NoRedirectHTTPHandler(urllib.request.HTTPHandler):
    """HTTP handler that does not follow redirects (for --pass-redirects).

    3xx responses surface to the caller as urllib.error.HTTPError, so the
    proxy can forward the status + Location header to the client as-is.
    """

    def http_open(self, req):
        parts = urllib.parse.urlsplit(req.full_url)
        host = parts.hostname or "127.0.0.1"
        port = parts.port or 80
        h = http.client.HTTPConnection(host, port, timeout=120)
        try:
            h.request(req.get_method(), req.selector, req.data,
                      dict(req.header_items()))
            resp = h.getresponse()
        except Exception:
            h.close()
            raise
        # resp is already a fully-initialised http.client.HTTPResponse with
        # the socket attached.  Wrap it in addinfourl so urllib's redirect
        # handler (which we have removed) would see it — but since we removed
        # the HTTPRedirectHandler, 3xx responses surface as HTTPError and the
        # proxy forwards status + Location to the client as-is.
        return urllib.response.addinfourl(resp, resp.msg, req.full_url, resp.status)


class _NoRedirectOpener(urllib.request.OpenerDirector):
    """Opener that does not follow redirects (for --pass-redirects).

    Replaces the default HTTPHandler with _NoRedirectHTTPHandler so that
    3xx responses surface as urllib.error.HTTPError instead of being
    silently followed.
    """

    def __init__(self):
        super().__init__()
        self.addheaders = []
        # Remove the default HTTPHandler (which follows redirects) and
        # replace it with our no-redirect version.
        self.handlers = [
            h for h in self.handlers
            if not isinstance(h, urllib.request.HTTPHandler)
            or isinstance(h, _NoRedirectHTTPHandler)
        ]
        self.add_handler(_NoRedirectHTTPHandler())


def _render_retry_after(value):
    """Resolve --retry-after into the header value to send.

    - integer string            -> as-is (delay-seconds form)
    - "date:+N"                 -> HTTP-date N seconds in the future
    - anything else             -> verbatim (e.g. "soon" for the fallback test)
    """
    v = value.strip()
    if v.isdigit():
        return v
    if v.startswith("date:+"):
        try:
            offset = int(v[len("date:+"):])
        except ValueError:
            return v
        return email.utils.formatdate(time.time() + offset, usegmt=True)
    return v


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Stateful HTTP fault-injecting reverse proxy.",
        formatter_class=argparse.RawTextHelpFormatter
    )
    parser.add_argument("--port", "-p", type=int, default=9797, help="TCP port to listen on")
    parser.add_argument("--backend", "-b", default="http://127.0.0.1:80", help="Backend base URL")
    parser.add_argument("--fault-path", "-f", default="/tests/",
                        help="URL prefix (or comma-separated list of prefixes) that triggers fault injection")
    parser.add_argument(
        "--fault-mode", "-m",
        default="503",
        help="""Failure mode to inject:
- 503: Simulates a transient server overload / gateway error.
       Returns HTTP 503 Service Unavailable with a short body.
       Used by: CLO-84 (Perl retry), CLO-85 (Zig retry on 503), CLO-87 (Perl exhausts retries),
                CLO-88 (retry 0 disables), CLO-89 (default retry on BFS).
       Verifies: Transient server errors successfully trigger exponential backoff retries.

- 404: Simulates a permanently missing or deleted asset.
       Returns HTTP 404 Not Found.
       Used by: CLO-86 (terminal error), CLO-80/81/82/83 (ignore-missing-assets),
                GAT-11 (404 + Retry-After is ignored — no retry).
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
              Used by: CLO-98b (Perl length-bearing drop), CLO-99b (Zig length-bearing drop),
                       GAT-40 (persistent truncation on a later asset, formerly CLO-129).
              Verifies: Robust short-read detection and retry mechanisms when bytes received < Content-Length.

- challenge: Simulates an Anubis bot gatekeeper answering EVERY request on the
             fault path with a 200 text/html challenge page (Cache-Control: no-store,
             Refresh, 2x Set-Cookie, ~4 KB body with Content-Length).
             Used by: GAT-3 (challenge on /api/v1/ — API path unchanged),
                      GAT-22 (challenge on asset GET — Zig rejects, Perl saves),
                      GAT-41 (challenge on hdd asset only — likely o3 cause).
             Verifies: R2 — a 200 text/html on an asset download is a permanent
                       error, not a truncated transfer.

- challenge_no_accept: Same challenge page, but only when the request has NO
             Accept header; requests with Accept pass through to the backend.
             Used by: GAT-21 (both implementations must send Accept on asset
                      GETs and redirect hops, or they get challenged).
             Verifies: R1 — every request carries an Accept header.

- <3-digit status>: Generic status mode.  Any 3-digit HTTP status code
             (408, 429, 500, 504, ...) is returned as-is for the first
             --fail-times attempts, optionally with a --retry-after header.
             Used by: GAT-4 (429x2), GAT-5 (408/500/504), GAT-6 (429 always),
                      GAT-7/8/9 (429 + Retry-After forms), GAT-23..27 (clone-job
                      BFS/asset 429/408), GAT-28 (POST 429).
             Verifies: R3 — retry on 408/429/5xx, R4 — Retry-After honoured."""
    )
    parser.add_argument("--fail-times", "-t", type=int, default=2, help="How many initial requests to fault-inject")
    parser.add_argument("--partial-bytes", type=int, default=64, help="Bytes to stream before TCP RST (partial mode only)")
    parser.add_argument("--retry-after", default=None,
                        help="Retry-After value for injected status responses: integer (seconds), "
                             "'date:+N' (HTTP date N seconds in the future), or verbatim string. "
                             "Also allowed with 404.")
    parser.add_argument("--header-log", default=None,
                        help="Path to append one line per request: 'METHOD PATH accept=<v|-> ua=<v|->'. "
                             "Never logs API keys. Used by GAT-1/GAT-2/GAT-20.")
    parser.add_argument("--pass-redirects", action="store_true",
                        help="Do not follow backend redirects: a backend 302 + Location reaches the client as-is. "
                             "Used by GAT-20 to observe Accept on every redirect hop.")
    parser.add_argument("--count-file", "-c", default="/tmp/faultproxy_counts.txt", help="Path to write per-path hit counts to")
    args = parser.parse_args()

    FaultProxyHandler.port = args.port
    FaultProxyHandler.backend = args.backend
    FaultProxyHandler.fault_path = args.fault_path
    FaultProxyHandler.fault_mode = args.fault_mode
    FaultProxyHandler.fail_times = args.fail_times
    FaultProxyHandler.partial_bytes = args.partial_bytes
    FaultProxyHandler.count_file = args.count_file
    FaultProxyHandler.retry_after = _render_retry_after(args.retry_after) if args.retry_after else None
    FaultProxyHandler.header_log = args.header_log
    FaultProxyHandler.pass_redirects = args.pass_redirects

    # Truncate the count file at startup so each test run starts clean.
    try:
        open(FaultProxyHandler.count_file, "w").close()
    except OSError:
        pass
    if FaultProxyHandler.header_log:
        try:
            open(FaultProxyHandler.header_log, "w").close()
        except OSError:
            pass

    # Standard socket reuse address flag to prevent "Address already in use" errors during rapid restarts.
    http.server.HTTPServer.allow_reuse_address = True
    server = http.server.HTTPServer(("127.0.0.1", FaultProxyHandler.port), FaultProxyHandler)
    sys.stderr.write(
        "[proxy] listening on 127.0.0.1:%d  backend=%s  fault_path=%s  "
        "mode=%s  fail_times=%d  partial_bytes=%d  retry_after=%s  "
        "header_log=%s  pass_redirects=%s\n" % (
            FaultProxyHandler.port,
            FaultProxyHandler.backend,
            FaultProxyHandler.fault_path,
            FaultProxyHandler.fault_mode,
            FaultProxyHandler.fail_times,
            FaultProxyHandler.partial_bytes,
            FaultProxyHandler.retry_after,
            FaultProxyHandler.header_log,
            FaultProxyHandler.pass_redirects,
        )
    )
    sys.stderr.flush()
    server.serve_forever()
