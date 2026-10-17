#!/bin/sh
# Run inside debian:bookworm-slim with this directory mounted read-only at /probe.
set -e
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends chromium firefox-esr python3 >/dev/null 2>&1
chromium --version; firefox --version
TOKEN=PROBEtoken0123456789abcdefghijklmnopqrstuvw
URL="http://127.0.0.1:8411/operator/sign-in?token=$TOKEN"
for policy in origin no-referrer; do
  python3 /probe/referrer-origin-probe-server.py 8411 "$policy" > /tmp/out.txt 2>&1 &
  pid=$!; sleep 1
  echo "## policy=$policy chromium"
  timeout 30 chromium --headless --no-sandbox --disable-gpu --virtual-time-budget=5000 --dump-dom "$URL" >/dev/null 2>&1 || true
  tr -d "\000" < /tmp/out.txt | awk "!seen[\$0]++"
  echo "token occurrences outside the GET sign-in request line: $(grep -av '^GET /operator/sign-in?token=' /tmp/out.txt | grep -ac "$TOKEN" || true)"
  kill $pid; sleep 1
  python3 /probe/referrer-origin-probe-server.py 8411 "$policy" > /tmp/out.txt 2>&1 &
  pid=$!; sleep 1
  echo "## policy=$policy firefox"
  rm -rf /tmp/ff; mkdir /tmp/ff
  timeout 30 firefox --headless --profile /tmp/ff --screenshot /tmp/s.png "$URL" >/dev/null 2>&1 || true
  tr -d "\000" < /tmp/out.txt | awk "!seen[\$0]++"
  echo "token occurrences outside the GET sign-in request line: $(grep -av '^GET /operator/sign-in?token=' /tmp/out.txt | grep -ac "$TOKEN" || true)"
  kill $pid; sleep 1
done
