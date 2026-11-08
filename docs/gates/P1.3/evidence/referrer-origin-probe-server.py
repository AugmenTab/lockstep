# Probe for D-2d: the C-P1.3 sign-in flow shape, with the confirm page served under a
# chosen Referrer-Policy. Logs every request the browser makes (method, target, Origin,
# Sec-Fetch-Site, Referer, Cookie) so the run script can check where the token appears.
# Differences from the real page: a nonce'd inline script submits the form (headless
# browsers cannot click), so the CSP adds script-src 'nonce-probe'.
import http.server, sys
PORT = int(sys.argv[1]); POLICY = sys.argv[2]
CSP = ("default-src 'none'; style-src 'self'; form-action 'self'; base-uri 'none'; "
       "frame-ancestors 'none'; script-src 'nonce-probe'")
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def log_req(self):
        h = self.headers
        print(f"{self.command} {self.path} Origin={h.get('Origin')!r} "
              f"Sec-Fetch-Site={h.get('Sec-Fetch-Site')!r} Referer={h.get('Referer')!r} "
              f"Cookie={h.get('Cookie')!r}", flush=True)
    def send(self, code, body, headers):
        self.send_response(code)
        for k, v in headers: self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
    def do_GET(self):
        self.log_req()
        if self.path.startswith("/operator/sign-in?token="):
            token = self.path.split("=", 1)[1].encode()
            body = (b"<!doctype html><html><head><link rel=stylesheet href='/static/lockstep.css'>"
                    b"</head><body><form method=post action='/operator/sign-in'>"
                    b"<input type=hidden name=token value='" + token + b"'>"
                    b"<button type=submit>Sign in</button></form>"
                    b"<script nonce=probe>document.forms[0].submit()</script></body></html>")
            self.send(200, body, [("Content-Type", "text/html"), ("Cache-Control", "no-store"),
                                  ("Referrer-Policy", POLICY), ("Content-Security-Policy", CSP)])
        elif self.path == "/static/lockstep.css":
            self.send(200, b"body{}", [("Content-Type", "text/css")])
        elif self.path == "/operator":
            self.send(200, b"<!doctype html><p>signed in</p>",
                      [("Content-Type", "text/html"), ("Cache-Control", "no-store"),
                       ("Referrer-Policy", "no-referrer")])
        else:
            self.send(404, b"", [])
    def do_POST(self):
        self.log_req()
        n = int(self.headers.get("Content-Length", 0)); self.rfile.read(n)
        self.send(303, b"", [("Location", "/operator"), ("Cache-Control", "no-store"),
                             ("Referrer-Policy", "no-referrer"),
                             ("Set-Cookie", "lockstep_session=probesession; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200")])
http.server.HTTPServer(("127.0.0.1", PORT), H).serve_forever()
