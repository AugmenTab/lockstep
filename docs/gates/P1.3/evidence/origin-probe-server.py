# Probe: which Origin / Sec-Fetch-Site / Referer does a browser send on a
# same-origin form POST from a page served with a given Referrer-Policy?
import http.server, sys
POLICY = sys.argv[2]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/done":
            self.send_response(200); self.end_headers(); self.wfile.write(b"done"); return
        body = (b"<!doctype html><html><body><form method=post action='/submit'>"
                b"<input type=hidden name=t value=x></form>"
                b"<script>document.forms[0].submit()</script></body></html>")
        self.send_response(200)
        self.send_header("Content-Type", "text/html")
        self.send_header("Referrer-Policy", POLICY)
        self.end_headers(); self.wfile.write(body)
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0)); self.rfile.read(n)
        print(f"policy={POLICY} Origin={self.headers.get('Origin')!r} "
              f"Sec-Fetch-Site={self.headers.get('Sec-Fetch-Site')!r} "
              f"Referer={self.headers.get('Referer')!r}", flush=True)
        self.send_response(303); self.send_header("Location", "/done"); self.end_headers()
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
