#!/usr/bin/env python3
"""Real-browser driver for the Lockstep form tests (C-P1.7-R1 R3).

Starts headless Chromium with a private profile and drives it through the
Chrome DevTools Protocol, using only the Python standard library. Pages are
opened by navigation, text is typed into focused fields, and buttons are
pressed with real mouse events. Every request is built and sent by the
browser itself; this script only reports what the browser sent and received.

Input: a JSON list of steps on stdin. Output: one "key<TAB>value" line per
observation on stdout; on failure an "error<TAB>message" line and exit 1.

Steps:
  {"op": "serve", "port": N, "html": "...", "headers": {"Name": "value"},
   "fill": {"PLACEHOLDER": "selector"}}
      serve a static page at http://127.0.0.1:N/ (another origin); each
      PLACEHOLDER in the HTML is replaced by the value of the element that
      matches its selector on the page the browser currently shows
  {"op": "open", "label": L, "url": U}
  {"op": "type", "selector": S, "text": T}
  {"op": "set_dom_value", "selector": S, "value": V}
  {"op": "click", "label": L, "selector": S}
For "open" and "click", the driver waits for the resulting page load and reports:
  L.url, L.status, L.referrer_policy, L.csp, L.x_frame_options, L.text,
and for each form POST the browser sent during the step:
  L.post.url, L.post.origin, L.post.referer, L.post.sec_fetch_site,
  L.post.status, L.post.location
"""

import base64
import http.server
import json
import os
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request


def emit(key, value):
    text = "" if value is None else str(value)
    text = text.replace("\t", " ").replace("\r", " ").replace("\n", " ")
    sys.stdout.write(key + "\t" + text + "\n")
    sys.stdout.flush()


class WebSocket:
    """A minimal RFC 6455 client: text frames, client masking, fragmentation."""

    def __init__(self, url):
        assert url.startswith("ws://")
        rest = url[len("ws://"):]
        hostport, path = rest.split("/", 1)
        host, port = hostport.split(":")
        self.sock = socket.create_connection((host, int(port)), timeout=30)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (
            "GET /" + path + " HTTP/1.1\r\n"
            "Host: " + hostport + "\r\n"
            "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: " + key + "\r\nSec-WebSocket-Version: 13\r\n\r\n"
        )
        self.sock.sendall(request.encode())
        response = b""
        while b"\r\n\r\n" not in response:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise RuntimeError("websocket handshake: connection closed")
            response += chunk
        head, self.buffer = response.split(b"\r\n\r\n", 1)
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise RuntimeError("websocket handshake refused: " + head.decode(errors="replace"))

    def _read(self, n):
        while len(self.buffer) < n:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("websocket closed")
            self.buffer += chunk
        data, self.buffer = self.buffer[:n], self.buffer[n:]
        return data

    def send(self, text):
        payload = text.encode()
        header = bytearray([0x81])
        n = len(payload)
        if n < 126:
            header.append(0x80 | n)
        elif n < 65536:
            header.append(0x80 | 126)
            header += struct.pack(">H", n)
        else:
            header.append(0x80 | 127)
            header += struct.pack(">Q", n)
        mask = os.urandom(4)
        masked = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
        self.sock.sendall(bytes(header) + mask + masked)

    def recv(self):
        message = b""
        while True:
            b1, b2 = self._read(2)
            opcode, final = b1 & 0x0F, b1 & 0x80
            n = b2 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            payload = self._read(n)
            if opcode == 0x8:
                raise RuntimeError("websocket closed by the browser")
            if opcode in (0x9, 0xA):
                continue
            message += payload
            if final:
                return message.decode()


class DevTools:
    def __init__(self, ws):
        self.ws = ws
        self.next_id = 0
        self.events = []

    def call(self, method, params=None):
        self.next_id += 1
        ident = self.next_id
        self.ws.send(json.dumps({"id": ident, "method": method, "params": params or {}}))
        while True:
            message = json.loads(self.ws.recv())
            if message.get("id") == ident:
                if "error" in message:
                    raise RuntimeError(method + ": " + json.dumps(message["error"]))
                return message.get("result", {})
            if "method" in message:
                self.events.append(message)

    def pump_until(self, predicate, timeout):
        deadline = time.time() + timeout
        self.ws.sock.settimeout(0.5)
        try:
            while time.time() < deadline:
                if any(predicate(e) for e in self.events):
                    return True
                try:
                    message = json.loads(self.ws.recv())
                except socket.timeout:
                    continue
                if "method" in message:
                    self.events.append(message)
            return any(predicate(e) for e in self.events)
        finally:
            self.ws.sock.settimeout(30)

    def evaluate(self, expression):
        result = self.call("Runtime.evaluate", {"expression": expression, "returnByValue": True})
        if "exceptionDetails" in result:
            raise RuntimeError("evaluate failed: " + expression)
        return result.get("result", {}).get("value")


def lower_headers(headers):
    return {k.lower(): v for k, v in (headers or {}).items()}


class Browser:
    def __init__(self):
        self.profile = tempfile.mkdtemp(prefix="lockstep-browser-")
        self.process = subprocess.Popen(
            [
                "chromium", "--headless=new", "--no-sandbox", "--disable-gpu",
                "--no-first-run", "--no-default-browser-check", "--disable-extensions",
                "--remote-debugging-port=0", "--user-data-dir=" + self.profile, "about:blank",
            ],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        port_file = os.path.join(self.profile, "DevToolsActivePort")
        for _ in range(200):
            if os.path.exists(port_file) and os.path.getsize(port_file) > 0:
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("chromium did not start (no DevToolsActivePort)")
        port = open(port_file).read().split()[0]
        targets = json.loads(urllib.request.urlopen("http://127.0.0.1:" + port + "/json/list").read())
        page = next(t for t in targets if t.get("type") == "page")
        self.cdp = DevTools(WebSocket(page["webSocketDebuggerUrl"]))
        self.cdp.call("Page.enable")
        self.cdp.call("Network.enable")
        self.cdp.call("Runtime.enable")
        emit("browser.version", self.cdp.call("Browser.getVersion").get("product"))

    def close(self):
        try:
            self.process.terminate()
            self.process.wait(timeout=5)
        except Exception:
            self.process.kill()
        shutil.rmtree(self.profile, ignore_errors=True)

    def _await_load(self, label):
        self.cdp.pump_until(lambda e: e["method"] == "Page.loadEventFired", 15)
        time.sleep(0.2)
        self.cdp.pump_until(lambda e: False, 0.3)
        self._report(label)

    def _report(self, label):
        events = self.cdp.events
        self.cdp.events = []
        requests = {}
        for e in events:
            p = e.get("params", {})
            rid = p.get("requestId")
            if e["method"] == "Network.requestWillBeSent":
                entry = requests.setdefault(rid, {"hops": [], "extra": []})
                if p.get("redirectResponse") and entry["hops"]:
                    entry["hops"][-1]["status"] = p["redirectResponse"].get("status")
                    entry["hops"][-1]["headers"] = lower_headers(p["redirectResponse"].get("headers"))
                entry["hops"].append({"method": p["request"]["method"], "url": p["request"]["url"], "type": p.get("type")})
            elif e["method"] == "Network.requestWillBeSentExtraInfo":
                requests.setdefault(rid, {"hops": [], "extra": []})["extra"].append(lower_headers(p.get("headers")))
            elif e["method"] == "Network.responseReceived":
                entry = requests.setdefault(rid, {"hops": [], "extra": []})
                if entry["hops"]:
                    entry["hops"][-1]["status"] = p["response"].get("status")
                    entry["hops"][-1]["headers"] = lower_headers(p["response"].get("headers"))
                    entry["hops"][-1]["final"] = True
        document = None
        for entry in requests.values():
            for i, hop in enumerate(entry["hops"]):
                sent = entry["extra"][i] if i < len(entry["extra"]) else {}
                if hop["method"] == "POST":
                    emit(label + ".post.url", hop["url"])
                    emit(label + ".post.origin", sent.get("origin"))
                    emit(label + ".post.referer", sent.get("referer"))
                    emit(label + ".post.sec_fetch_site", sent.get("sec-fetch-site"))
                    emit(label + ".post.status", hop.get("status"))
                    emit(label + ".post.location", hop.get("headers", {}).get("location"))
                if hop.get("type") == "Document" and hop.get("final"):
                    document = hop
        url = self.cdp.evaluate("location.href")
        emit(label + ".url", url)
        if document is not None:
            headers = document.get("headers", {})
            emit(label + ".status", document.get("status"))
            emit(label + ".referrer_policy", headers.get("referrer-policy"))
            emit(label + ".csp", headers.get("content-security-policy"))
            emit(label + ".x_frame_options", headers.get("x-frame-options"))
        emit(label + ".text", self.cdp.evaluate("document.body ? document.body.innerText : ''"))

    def open(self, label, url):
        self.cdp.events = []
        self.cdp.call("Page.navigate", {"url": url})
        self._await_load(label)

    def _center(self, selector):
        js = (
            "(function(){var el=document.querySelector(" + json.dumps(selector) + ");"
            "if(!el){return null;} el.scrollIntoView({block:'center'});"
            "var r=el.getBoundingClientRect(); return [r.left+r.width/2, r.top+r.height/2];})()"
        )
        point = self.cdp.evaluate(js)
        if not point:
            raise RuntimeError("no element matches " + selector)
        return point

    def type(self, selector, text):
        x, y = self._center(selector)
        self._mouse_click(x, y)
        self.cdp.evaluate("document.activeElement && document.activeElement.select && document.activeElement.select()")
        self.cdp.call("Input.insertText", {"text": text})

    def set_dom_value(self, selector, value):
        ok = self.cdp.evaluate(
            "(function(){var el=document.querySelector(" + json.dumps(selector) + ");"
            "if(!el){return false;} el.value=" + json.dumps(value) + "; return true;})()"
        )
        if not ok:
            raise RuntimeError("no element matches " + selector)

    def _mouse_click(self, x, y):
        for kind in ("mouseMoved", "mousePressed", "mouseReleased"):
            params = {"type": kind, "x": x, "y": y}
            if kind != "mouseMoved":
                params.update({"button": "left", "clickCount": 1})
            self.cdp.call("Input.dispatchMouseEvent", params)

    def click(self, label, selector):
        x, y = self._center(selector)
        self.cdp.events = []
        self._mouse_click(x, y)
        self._await_load(label)


def serve(port, html, headers):
    body = html.encode()

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def do_GET(self):
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            for name, value in (headers or {}).items():
                self.send_header(name, value)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    server = http.server.HTTPServer(("127.0.0.1", port), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


def main():
    steps = json.loads(sys.stdin.read())
    browser = None
    servers = []
    try:
        browser = Browser()
        for step in steps:
            op = step["op"]
            if op == "serve":
                html = step["html"]
                for placeholder, selector in (step.get("fill") or {}).items():
                    value = browser.cdp.evaluate(
                        "(function(){var el=document.querySelector(" + json.dumps(selector) + ");"
                        "return el ? el.value : null;})()"
                    )
                    if value is None:
                        raise RuntimeError("fill: no element matches " + selector)
                    html = html.replace(placeholder, value)
                servers.append(serve(step["port"], html, step.get("headers")))
            elif op == "open":
                browser.open(step["label"], step["url"])
            elif op == "type":
                browser.type(step["selector"], step["text"])
            elif op == "set_dom_value":
                browser.set_dom_value(step["selector"], step["value"])
            elif op == "click":
                browser.click(step["label"], step["selector"])
            else:
                raise RuntimeError("unknown step " + op)
        emit("done", "ok")
        return 0
    except Exception as exc:  # report and fail; the test asserts on "done"
        emit("error", repr(exc))
        return 1
    finally:
        for server in servers:
            server.shutdown()
        if browser is not None:
            browser.close()


if __name__ == "__main__":
    sys.exit(main())
