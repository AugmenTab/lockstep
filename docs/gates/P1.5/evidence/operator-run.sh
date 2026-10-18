#!/usr/bin/env bash
# P1.5 operator run (C-P1.5 §6): the real binary against the operator database
# (scripts/db, network lockstep-net). Run in the dev container with the checkout
# at /work and BACKUP set to a fresh scripts/db backup path.
set -uo pipefail
cd /work
bin=$(ls -d .stack-work/install/*/*/*/bin/lockstep | head -n 1)
export LOCKSTEP_CONFIG=.local/config/lockstep.json
out=/tmp/run; mkdir -p "$out"
run() { echo "\$ lockstep $*"; "$bin" "$@"; echo "[exit $?]"; }
start() { "$bin" serve > "$out/serve-$1.log" 2>&1 & serve=$!; for _ in $(seq 1 50); do curl -s -o /dev/null http://127.0.0.1:8000/api/health_check && break; sleep 0.2; done; echo "-- serve $1 started"; }
stop() { kill -TERM "$serve"; wait "$serve"; echo "-- serve stopped (exit $?)"; }
state() { "$bin" job show "$1"; }

run db migrate
run db migrate --backup "$BACKUP"
run workspace show
revision=$("$bin" workspace show | sed -n 's/^revision: //p')
run job queue --expected-revision "$revision" --steps 3 --step-ms 100 --idempotency-key p15-operator-job-0001
echo "-- no service running; after 1 s:"; sleep 1; state 1
start a
sleep 2; echo "-- after 2 s with the service:"; state 1
run job queue --expected-revision "$revision" --steps 3 --step-ms 100 --idempotency-key p15-operator-job-0001
run job queue --expected-revision "$revision" --steps 3 --step-ms 50 --fail-at-step 2 --idempotency-key p15-operator-job-0002
sleep 1; state 2
run job queue --expected-revision "$revision" --steps 10 --step-ms 400 --idempotency-key p15-operator-job-0003
sleep 2; echo "-- mid-job:"; state 3
stop
echo "-- after SIGTERM:"; state 3
start b
sleep 5; echo "-- after restart:"; state 3

base=http://127.0.0.1:8000
url=$("$bin" operator sign-in); token=${url#*token=}
curl -s -D "$out/x.h" -o /dev/null -X POST -H "Origin: $base" --data "token=$token" "$base/operator/sign-in"
session=$(grep -i '^set-cookie:' "$out/x.h" | sed -E 's/.*lockstep_session=([A-Za-z0-9_-]*);.*/\1/')
cookie="Cookie: lockstep_session=$session"
curl -s -o "$out/form.b" -H "$cookie" "$base/operator/jobs/new"
field() { grep -oE "<input[^>]*name=\"$1\"[^>]*>" "$out/form.b" | grep -oE 'value="[^"]*"' | cut -d'"' -f2; }
start_t=$(date +%s%N)
curl -s -D "$out/q.h" -o /dev/null -X POST -H "Origin: $base" -H "$cookie" \
  --data "steps=5&step_ms=300&fail_at_step=&expected_revision=$(field expected_revision)&idempotency_key=$(field idempotency_key)&csrf=$(field csrf)" \
  "$base/operator/commands/queue-noop"
elapsed=$(( ($(date +%s%N) - start_t) / 1000000 ))
echo "-- browser queue: $(head -n 1 "$out/q.h" | tr -d '\r') $(grep -i '^location:' "$out/q.h" | tr -d '\r') in ${elapsed} ms"
loc=$(grep -i '^location:' "$out/q.h" | tr -d '\r' | cut -d' ' -f2)
sleep 3
curl -s -o "$out/r.b" -H "$cookie" "$base$loc"
echo "-- GET $loc: $(grep -oE '<dt>[^<]*</dt><dd><code>[^<]*</code>' "$out/r.b" | sed -E 's/<dt>([^<]*)<\/dt><dd><code>([^<]*)<\/code>/\1=\2/' | tr '\n' ' ')"
stop
for j in 1 2 3 4; do state "$j"; done
echo "-- server logs"; cat "$out"/serve-a.log "$out"/serve-b.log
password=$(sed -E 's/.*"password":"([^"]*)".*/\1/' "$LOCKSTEP_CONFIG")
echo "database password occurrences in all outputs: $(cat "$out"/* | grep -o -F "$password" | wc -l)"
echo "sign-in token occurrences in all outputs: $(cat "$out"/* | grep -o -F "$token" | wc -l)"
