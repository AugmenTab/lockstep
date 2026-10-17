#!/usr/bin/env bash
# P1.3 operator run (C-P1.3 §6): the real binary against the operator database
# (scripts/db, network lockstep-net), browser-shaped requests with curl. Run in
# the dev container with the checkout at /work and BACKUP set to a fresh
# scripts/db backup path. Every occurrence of a raw token in this script's
# output is replaced by <TOKEN-n>; the counts below are taken before that.
set -uo pipefail
cd /work
bin=$(ls -d .stack-work/install/*/*/*/bin/lockstep | head -n 1)
export LOCKSTEP_CONFIG=.local/config/lockstep.json
out=/tmp/run; mkdir -p "$out"
lockstep() { "$bin" "$@"; }
step() { echo "\$ $*"; }

step "lockstep db status"; lockstep db status; echo "[exit $?]"
step "lockstep operator sign-in (schema behind)"; lockstep operator sign-in; echo "[exit $?]"
step "lockstep db migrate (no backup decision)"; lockstep db migrate; echo "[exit $?]"
step "lockstep db migrate --backup $BACKUP"; lockstep db migrate --backup "$BACKUP"; echo "[exit $?]"
step "lockstep db status"; lockstep db status; echo "[exit $?]"

"$bin" serve > "$out/serve.log" 2>&1 &
serve=$!
for _ in $(seq 1 50); do curl -s -o /dev/null http://127.0.0.1:8000/api/health_check && break; sleep 0.2; done

base=http://127.0.0.1:8000
origin="Origin: $base"
step "lockstep operator sign-in"
url=$(lockstep operator sign-in 2> "$out/signin.err"); echo "[exit $?] stderr bytes: $(wc -c < "$out/signin.err")"
token=${url#*token=}
echo "$url" | sed "s/$token/<TOKEN-1>/"

req() { # name, curl args...
  local name=$1; shift
  curl -s -D "$out/$name.h" -o "$out/$name.b" "$@"
  echo "-- $name: $(head -n 1 "$out/$name.h" | tr -d '\r')"
  grep -iE '^(location|set-cookie|cache-control|referrer-policy|content-security-policy):' "$out/$name.h" | tr -d '\r' \
    | sed -E 's/(lockstep_session=)[A-Za-z0-9_-]{43}/\1<SESSION>/'
}

req confirm "$base/operator/sign-in?token=$token"
echo "   token occurrences in the confirm body: $(grep -o "$token" "$out/confirm.b" | wc -l)"
req null-origin -X POST -H "Origin: null" -H "Sec-Fetch-Site: same-origin" --data "token=$token" "$base/operator/sign-in"
req localhost-host -H "Host: localhost:8000" "$base/"
req exchange -X POST -H "$origin" -H "Referer: $base/" -H "Sec-Fetch-Site: same-origin" --data "token=$token" "$base/operator/sign-in"
session=$(grep -i '^set-cookie:' "$out/exchange.h" | sed -E 's/.*lockstep_session=([A-Za-z0-9_-]*);.*/\1/')
req operator -H "Cookie: lockstep_session=$session" "$base/operator"
csrf=$(grep -oE 'name="csrf" value="[A-Za-z0-9_-]+"|value="[A-Za-z0-9_-]+" name="csrf"' "$out/operator.b" | grep -oE 'value="[^"]+"' | cut -d'"' -f2)
echo "   operator page: $(grep -o 'expires at [^<]*' "$out/operator.b")"
req reuse -X POST -H "$origin" --data "token=$token" "$base/operator/sign-in"
req bad-csrf -X POST -H "$origin" -H "Cookie: lockstep_session=$session" --data "csrf=wrong" "$base/operator/sign-out"
req no-origin -X POST -H "Cookie: lockstep_session=$session" --data "csrf=$csrf" "$base/operator/sign-out"
req sign-out -X POST -H "$origin" -H "Cookie: lockstep_session=$session" --data "csrf=$csrf" "$base/operator/sign-out"
req after -H "Cookie: lockstep_session=$session" "$base/operator"

step "second sign-in, then lockstep operator sign-out-all"
url2=$(lockstep operator sign-in 2>> "$out/signin.err"); token2=${url2#*token=}
req exchange2 -X POST -H "$origin" --data "token=$token2" "$base/operator/sign-in"
session2=$(grep -i '^set-cookie:' "$out/exchange2.h" | sed -E 's/.*lockstep_session=([A-Za-z0-9_-]*);.*/\1/')
lockstep operator sign-out-all; echo "[exit $?]"
req after-all -H "Cookie: lockstep_session=$session2" "$base/operator"

kill -TERM "$serve"; wait "$serve"; echo "serve exit: $?"
echo "-- server log"; cat "$out/serve.log"

echo "-- bounded exposure (raw-token occurrences; expected 0 everywhere listed)"
for t in "$token" "$token2"; do
  n=0
  for f in "$out"/*.h "$out"/serve.log "$out"/signin.err; do
    c=$(grep -o "$t" "$f" | wc -l); n=$((n + c))
  done
  for f in "$out"/*.b; do
    [ "$f" = "$out/confirm.b" ] && continue
    c=$(grep -o "$t" "$f" | wc -l); n=$((n + c))
  done
  echo "token: $n occurrence(s) in all headers, the server log, CLI stderr and every body except the confirm page"
done
password=$(sed -E 's/.*"password":"([^"]*)".*/\1/' "$LOCKSTEP_CONFIG")
echo "database password occurrences in all outputs: $(cat "$out"/* | grep -o -F "$password" | wc -l)"
