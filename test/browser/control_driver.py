#!/usr/bin/env python3
"""Real-browser driver for the control-pane tests (contract C-P3.1 §5).

It imports the frozen driver test/browser/cdp.py unchanged and adds three
steps the control pane needs, because its page renders after asynchronous
requests:

  {"op": "wait_text", "label": L, "text": T, "timeout": S}
      poll the page text until it contains T (at most S seconds); reports
      L.found (yes/no), L.url and L.text
  {"op": "eval", "label": L, "expression": E}
      evaluate E in the page; reports L.value as JSON (an exception thrown
      by E is reported as the string "error: <name>", not as a driver failure)
  {"op": "sleep", "seconds": S}

Every other step ("serve", "open", "type", "set_dom_value", "click") is the
frozen driver's. Input and output are the same as cdp.py's.
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cdp  # noqa: E402  (the frozen driver, unchanged)


def wait_text(browser, label, text, timeout):
    deadline = time.time() + timeout
    found = False
    while time.time() < deadline:
        body = browser.cdp.evaluate("document.body ? document.body.innerText : ''") or ""
        if text in body:
            found = True
            break
        time.sleep(0.2)
    cdp.emit(label + ".found", "yes" if found else "no")
    cdp.emit(label + ".url", browser.cdp.evaluate("location.href"))
    cdp.emit(label + ".text", browser.cdp.evaluate("document.body ? document.body.innerText : ''"))


def main():
    steps = json.loads(sys.stdin.read())
    browser = None
    servers = []
    try:
        browser = cdp.Browser()
        for step in steps:
            op = step["op"]
            if op == "wait_text":
                wait_text(browser, step["label"], step["text"], float(step.get("timeout", 15)))
            elif op == "eval":
                guarded = (
                    "(function(){try{return (" + step["expression"] + ");}"
                    "catch(e){return 'error: ' + e.name;}})()"
                )
                cdp.emit(step["label"] + ".value", json.dumps(browser.cdp.evaluate(guarded)))
            elif op == "sleep":
                time.sleep(float(step["seconds"]))
            elif op == "serve":
                servers.append(cdp.serve(step["port"], step["html"], step.get("headers")))
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
        cdp.emit("done", "ok")
        return 0
    except Exception as exc:  # report and fail; the test asserts on "done"
        cdp.emit("error", repr(exc))
        return 1
    finally:
        for server in servers:
            server.shutdown()
        if browser is not None:
            browser.close()


if __name__ == "__main__":
    sys.exit(main())
