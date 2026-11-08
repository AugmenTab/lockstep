# Probe for the P3.1 trust model (design request DR-P3.1, decision S): which browser state an
# unrelated service on another 127.0.0.1 port can obtain or use. One process serves two origins:
#   A = http://127.0.0.1:8521  stands for a Lockstep pane
#   B = http://127.0.0.1:8522  stands for an unrelated local web service
# Every request either origin receives is logged (method, target, Origin, Referer, Cookie,
# X-Lockstep-Session, body). The pages drive themselves with nonce'd inline scripts (a headless
# browser cannot click); the real pane would load a same-origin script instead.
#
# Flow: A/sign-in#TOKEN -> A exchanges TOKEN (fetch POST) for SESSION, stores SESSION in
# localStorage and also receives a cookie -> B/ (hostile page) reports what it can see and tries
# to act on A -> A/check reads localStorage and acts with the header -> A/done.
# The run script then starts the browser again on the same profile at A/check (a restart).
import http.server, socketserver, sys, threading

A, B = 8521, 8522
ORIGIN_A, ORIGIN_B = f"http://127.0.0.1:{A}", f"http://127.0.0.1:{B}"
TOKEN = "PROBEtoken0123456789abcdefghijklmnopqrstuvw"
SESSION = "PROBEsession0123456789abcdefghijklmnopqrst"
CSP = "default-src 'none'; connect-src 'self'; script-src 'nonce-probe'; base-uri 'none'; frame-ancestors 'none'"
lock = threading.Lock()


def log(port, line):
    with lock:
        print(("A " if port == A else "B ") + line, flush=True)


def page(script):
    return ("<!doctype html><html><body><p>probe</p><script nonce=probe>" + script +
            "</script></body></html>").encode()


SIGN_IN = page("""
var t = location.hash.slice(1);
history.replaceState(null, '', '/sign-in');
fetch('/exchange', {method: 'POST', headers: {'Content-Type': 'text/plain'}, body: t})
  .then(function (r) { return r.text(); })
  .then(function (s) { localStorage.setItem('lockstep-session', s); location.href = '%s/'; });
""" % ORIGIN_B)

HOSTILE = page("""
function report(k, v) { return fetch('/report?' + k + '=' + encodeURIComponent(v)); }
var seen = localStorage.getItem('lockstep-session');
report('b.localStorage', String(seen))
  .then(function () { return report('b.document_cookie', document.cookie || '(empty)'); })
  .then(function () {
    return fetch('%(a)s/act', {method: 'POST', headers: {'X-Lockstep-Session': 'guess'}, body: 'x'})
      .then(function () { return report('b.header_fetch', 'response readable'); },
            function (e) { return report('b.header_fetch', 'blocked: ' + e.name); });
  })
  .then(function () {
    return fetch('%(a)s/act', {method: 'POST', mode: 'no-cors', credentials: 'include', body: 'y'})
      .then(function () { return report('b.nocors_post', 'sent (opaque)'); },
            function (e) { return report('b.nocors_post', 'blocked: ' + e.name); });
  })
  .then(function () { location.href = '%(a)s/check'; });
""" % {"a": ORIGIN_A})

CHECK = page("""
var s = localStorage.getItem('lockstep-session');
fetch('/act', {method: 'POST', headers: {'X-Lockstep-Session': String(s)}, body: 'z'})
  .then(function (r) { return r.text(); })
  .then(function (v) { return fetch('/report?a.check=' + encodeURIComponent(v)); })
  .then(function () { location.href = '/done' + location.search; });
""")


def handler_for(port):
    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def record(self, body=b""):
            h = self.headers
            log(port, f"{self.command} {self.path} Origin={h.get('Origin')!r} "
                      f"Referer={h.get('Referer')!r} Cookie={h.get('Cookie')!r} "
                      f"X-Lockstep-Session={h.get('X-Lockstep-Session')!r} "
                      f"Access-Control-Request-Headers={h.get('Access-Control-Request-Headers')!r} "
                      f"body={body.decode(errors='replace')!r}")

        def send(self, code, body, headers=()):
            self.send_response(code)
            for k, v in headers:
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def html(self, body):
            # The unrelated service B sets no policy of its own: nothing restricts its script.
            policy = [("Content-Security-Policy", CSP)] if port == A else []
            self.send(200, body, [("Content-Type", "text/html"), ("Cache-Control", "no-store"),
                                  ("Referrer-Policy", "no-referrer")] + policy)

        def do_GET(self):
            self.record()
            if port == A and self.path == "/sign-in":
                self.html(SIGN_IN)
            elif port == A and self.path in ("/check", "/check?restart"):
                self.html(CHECK)
            elif port == A and self.path in ("/done", "/done?restart"):
                self.html(page(""))
                log(port, "DONE restart" if self.path.endswith("restart") else "DONE first")
            elif port == B and self.path == "/":
                self.html(HOSTILE)
            elif self.path.startswith("/report?"):
                self.send(204, b"")
            else:
                self.send(404, b"")

        def do_OPTIONS(self):
            # No CORS headers: the preflight fails and the browser must not send the request.
            self.record()
            self.send(204, b"")

        def do_POST(self):
            body = self.rfile.read(int(self.headers.get("Content-Length", 0)))
            self.record(body)
            if port == A and self.path == "/exchange":
                if self.headers.get("Origin") == ORIGIN_A and body.decode() == TOKEN:
                    self.send(200, SESSION.encode(),
                              [("Content-Type", "text/plain"), ("Cache-Control", "no-store"),
                               ("Set-Cookie", "lockstep_session=PROBEcookie; Path=/; HttpOnly; SameSite=Strict")])
                else:
                    self.send(403, b"refused")
            elif port == A and self.path == "/act":
                ok = (self.headers.get("Origin") == ORIGIN_A and
                      self.headers.get("X-Lockstep-Session") == SESSION)
                log(port, "ACT " + ("accepted" if ok else "refused"))
                self.send(200 if ok else 403, b"accepted" if ok else b"refused",
                          [("Content-Type", "text/plain")])
            else:
                self.send(404, b"")
    return H


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True


for p in (A, B):
    threading.Thread(target=Server(("127.0.0.1", p), handler_for(p)).serve_forever, daemon=True).start()
log(A, "LISTENING")
threading.Event().wait()
