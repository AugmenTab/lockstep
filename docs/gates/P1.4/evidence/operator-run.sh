#!/usr/bin/env bash
# P1.4 operator run (C-P1.4 §6): the real binary against the operator database
# (scripts/db, network lockstep-net); CLI commands and browser-shaped requests
# with curl. Run in the dev container with the checkout at /work and BACKUP set
# to a fresh scripts/db backup path. Session cookies are shown as <SESSION>.
set -uo pipefail
cd /work
bin=$(ls -d .stack-work/install/*/*/*/bin/lockstep | head -n 1)
export LOCKSTEP_CONFIG=.local/config/lockstep.json
out=/tmp/run; mkdir -p "$out"
run() { echo "\$ lockstep $*"; "$bin" "$@"; echo "[exit $?]"; }

run db status
run workspace show
run db migrate
run db migrate --backup "$BACKUP"
run workspace show
run workspace rename --expected-revision 0 --idempotency-key p14-operator-key-0001 "Operator Workspace"
run workspace rename --expected-revision 0 --idempotency-key p14-operator-key-0001 "Operator Workspace"
run workspace rename --expected-revision 1 --idempotency-key p14-operator-key-0001 "Different"
run workspace rename --expected-revision 0 --idempotency-key p14-operator-key-0002 "Stale"
run workspace rename --expected-revision 1 --idempotency-key p14-operator-key-0003 "   "
run workspace show

"$bin" serve > "$out/serve.log" 2>&1 &
serve=$!
for _ in $(seq 1 50); do curl -s -o /dev/null http://127.0.0.1:8000/api/health_check && break; sleep 0.2; done
base=http://127.0.0.1:8000
url=$("$bin" operator sign-in); token=${url#*token=}
curl -s -D "$out/x.h" -o /dev/null -X POST -H "Origin: $base" --data "token=$token" "$base/operator/sign-in"
session=$(grep -i '^set-cookie:' "$out/x.h" | sed -E 's/.*lockstep_session=([A-Za-z0-9_-]*);.*/\1/')
cookie="Cookie: lockstep_session=$session"
curl -s -o "$out/operator.b" -H "$cookie" "$base/operator"
field() { grep -oE "<input[^>]*name=\"$1\"[^>]*>" "$out/operator.b" | grep -oE 'value="[^"]*"' | cut -d'"' -f2; }
csrf=$(field csrf | tail -n 1); key=$(field idempotency_key); expected=$(field expected_revision)
echo "-- operator page: $(grep -oE 'Name: <strong>[^<]*</strong> \(revision [0-9]+\)' "$out/operator.b"); form expected_revision=$expected, key length ${#key}"
post() { # label, key, expected, name, extra curl args...
  local label=$1 k=$2 e=$3 n=$4; shift 4
  curl -s -D "$out/$label.h" -o "$out/$label.b" -X POST -H "Origin: $base" -H "$cookie" "$@" \
    --data-urlencode "name=$n" --data "expected_revision=$e&idempotency_key=$k&csrf=$csrf" "$base/operator/commands/rename-workspace"
  echo "-- POST rename ($label): $(head -n 1 "$out/$label.h" | tr -d '\r') $(grep -i '^location:' "$out/$label.h" | tr -d '\r')"
}
post browser "$key" "$expected" "Browser Workspace"
post browser-again "$key" "$expected" "Browser Workspace"
post shared-cli-key p14-operator-key-0001 0 "Operator Workspace"
post stale p14-operator-key-0004 0 "Too Old"
post conflict "$key" "$expected" "Other"
post empty p14-operator-key-0005 2 ""
curl -s -D "$out/noorigin.h" -o /dev/null -X POST -H "$cookie" --data "name=X&expected_revision=2&idempotency_key=p14-operator-key-0006&csrf=$csrf" "$base/operator/commands/rename-workspace"
echo "-- POST rename without Origin: $(head -n 1 "$out/noorigin.h" | tr -d '\r')"
loc=$(grep -i '^location:' "$out/browser.h" | tr -d '\r' | cut -d' ' -f2)
curl -s -o "$out/receipt.b" -H "$cookie" "$base$loc"
echo "-- GET $loc: $(grep -oE '<dt>[^<]*</dt><dd><code>[^<]*</code>' "$out/receipt.b" | sed -E 's/<dt>([^<]*)<\/dt><dd><code>([^<]*)<\/code>/\1=\2/' | tr '\n' ' ')"
kill -TERM "$serve"; wait "$serve"; echo "serve exit: $?"
run workspace show
echo "-- server log"; cat "$out/serve.log"
password=$(sed -E 's/.*"password":"([^"]*)".*/\1/' "$LOCKSTEP_CONFIG")
echo "database password occurrences in all outputs: $(cat "$out"/* | grep -o -F "$password" | wc -l)"
echo "sign-in token occurrences in all outputs: $(cat "$out"/* | grep -o -F "$token" | wc -l)"
