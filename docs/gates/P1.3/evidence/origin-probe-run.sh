#!/bin/sh
set -e
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends chromium firefox-esr python3 >/dev/null 2>&1
chromium --version; firefox --version
for policy in no-referrer same-origin strict-origin-when-cross-origin; do
  python3 /probe/server.py 8411 "$policy" > /tmp/out.txt 2>&1 &
  pid=$!; sleep 1
  timeout 30 chromium --headless --no-sandbox --disable-gpu --virtual-time-budget=5000 --dump-dom "http://127.0.0.1:8411/?token=SECRET" >/dev/null 2>&1 || true
  echo "chromium: $(sort -u /tmp/out.txt)"
  : > /tmp/out.txt
  timeout 30 firefox --headless --screenshot /tmp/s.png "http://127.0.0.1:8411/?token=SECRET" >/dev/null 2>&1 || true
  echo "firefox:  $(sort -u /tmp/out.txt)"
  kill $pid
done
