#!/usr/bin/env python3
"""Real-browser driver for the application-shell tests (contract C-P3.4).

It imports the frozen drivers test/browser/cdp.py and
test/browser/control_driver.py unchanged and adds two steps:

  {"op": "key", "key": K}
      press one key with real key events (Tab, Shift+Tab, Enter, Space)
  {"op": "viewport", "width": W, "height": H}
      emulate a window of W x H CSS pixels (e.g. a phone)

Every other step is the earlier drivers' ("serve", "open", "type",
"set_dom_value", "click", "wait_text", "eval", "sleep").
"""

import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import cdp  # noqa: E402  (frozen)
import control_driver  # noqa: E402  (frozen)

KEYS = {
    "Tab": {"key": "Tab", "code": "Tab", "windowsVirtualKeyCode": 9},
    "Enter": {"key": "Enter", "code": "Enter", "windowsVirtualKeyCode": 13, "text": "\r"},
    "Space": {"key": " ", "code": "Space", "windowsVirtualKeyCode": 32, "text": " "},
}


def press(browser, name):
    shift = name.startswith("Shift+")
    base = KEYS[name[6:] if shift else name]
    modifiers = 8 if shift else 0
    down = dict(base, type="keyDown", modifiers=modifiers)
    up = {"type": "keyUp", "key": base["key"], "code": base["code"],
          "windowsVirtualKeyCode": base["windowsVirtualKeyCode"], "modifiers": modifiers}
    browser.cdp.call("Input.dispatchKeyEvent", down)
    browser.cdp.call("Input.dispatchKeyEvent", up)
    time.sleep(0.2)


def main():
    steps = json.loads(sys.stdin.read())
    browser = None
    servers = []
    try:
        browser = cdp.Browser()
        for step in steps:
            op = step["op"]
            if op == "key":
                press(browser, step["key"])
            elif op == "viewport":
                browser.cdp.call("Emulation.setDeviceMetricsOverride", {
                    "width": int(step["width"]), "height": int(step["height"]),
                    "deviceScaleFactor": 1, "mobile": True})
            elif op == "wait_text":
                control_driver.wait_text(browser, step["label"], step["text"], float(step.get("timeout", 15)))
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
