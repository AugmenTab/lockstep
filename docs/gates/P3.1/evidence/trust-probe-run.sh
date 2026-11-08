#!/bin/sh
# Run inside debian:bookworm-slim with this directory mounted read-only at /probe (DR-P3.1).
# For each browser: a first run from the sign-in link, then a restart on the same profile.
set -e
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends chromium firefox-esr python3 procps >/dev/null 2>&1
chromium --version
firefox-esr --version
TOKEN=PROBEtoken0123456789abcdefghijklmnopqrstuvw

wait_done() { # $1 = first or restart
  i=0
  while ! grep -q "^A DONE $1" /tmp/out.txt && [ $i -lt 60 ]; do
    sleep 0.5
    i=$((i + 1))
  done
}

run_browser() { # $1 = browser, $2 = profile, $3 = URL
  case $1 in
    chromium) chromium --headless=new --no-sandbox --disable-gpu --no-first-run --user-data-dir="$2" "$3" >/dev/null 2>&1 & ;;
    firefox) firefox-esr --headless --profile "$2" "$3" >/dev/null 2>&1 & ;;
  esac
}

stop_browser() { # $1 = profile; every process of that profile, then wait until none is left
  pkill -f -- "$1" || true
  i=0
  while pgrep -f -- "$1" >/dev/null && [ $i -lt 40 ]; do
    sleep 0.25
    i=$((i + 1))
  done
}

for browser in chromium firefox; do
  python3 /probe/trust-probe-server.py > /tmp/out.txt 2>&1 &
  server=$!
  sleep 1
  profile=/tmp/profile-$browser
  rm -rf "$profile"
  mkdir -p "$profile"
  # Firefox: no crash-restore of the stopped session, so the restart loads only its own URL.
  echo 'user_pref("browser.sessionstore.resume_from_crash", false);' > "$profile/user.js"
  echo "## $browser: first run from the sign-in link"
  run_browser $browser "$profile" "http://127.0.0.1:8521/sign-in#$TOKEN"
  wait_done first
  sleep 5 # let the browser write its storage to the profile before it is stopped
  stop_browser "$profile"
  echo "## $browser: restart on the same profile"
  run_browser $browser "$profile" "http://127.0.0.1:8521/check?restart"
  wait_done restart
  stop_browser "$profile"
  kill "$server"
  tr -d '\000' < /tmp/out.txt
  echo "token occurrences outside the exchange POST body: $(grep -v '^A POST /exchange ' /tmp/out.txt | grep -c "$TOKEN" || true)"
done
