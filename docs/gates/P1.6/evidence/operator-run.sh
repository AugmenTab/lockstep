#!/usr/bin/env bash
# P1.6 operator run and rendered-UI capture (C-P1.6 §6, E10). Runs in the dev
# container on network lockstep-net with the checkout at /work, BACKUP set to a
# fresh scripts/db backup and OUT set to a writable output directory.
# 1. the operator database: migrate 0005 behind the backup; queue jobs; start serve; capture
#    /operator/center (light and dark).
# 2. a scratch database on the same server (dropped at the end): a succeeded job
#    whose row is edited afterwards, to capture the negative case.
# Pages are fetched by headless Chromium through a local proxy that adds the
# session cookie (Chromium's command line cannot set one).
set -uo pipefail
cd /work
apt-get update -qq >/dev/null && apt-get install -y -qq --no-install-recommends chromium python3 postgresql-client >/dev/null 2>&1
chromium --version
bin=$(ls -d .stack-work/install/*/*/*/bin/lockstep | head -n 1)
export LOCKSTEP_CONFIG=.local/config/lockstep.json
run() { echo "\$ lockstep $*"; "$bin" "$@"; echo "[exit $?]"; }
password=$(sed -E 's/.*"password":"([^"]*)".*/\1/' "$LOCKSTEP_CONFIG")

cat > /tmp/proxy.py <<'PY'
import http.server, sys, urllib.request
TARGET, COOKIE = sys.argv[2], sys.argv[3]
class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        req = urllib.request.Request("http://" + TARGET + self.path, headers={"Host": TARGET, "Cookie": "lockstep_session=" + COOKIE})
        try:
            r = urllib.request.urlopen(req)
        except urllib.error.HTTPError as e:
            r = e
        body = r.read()
        self.send_response(r.status)
        for k, v in r.headers.items():
            if k.lower() not in ("transfer-encoding", "connection", "content-length"):
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers(); self.wfile.write(body)
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY

capture() { # config, label, before-serve hook, after-serve hook
  local config=$1 label=$2
  "$3" "$config"
  LOCKSTEP_CONFIG=$config "$bin" serve --port 8001 > "$OUT/serve-$label.log" 2>&1 &
  local serve=$!
  for _ in $(seq 1 50); do curl -s -o /dev/null http://127.0.0.1:8001/api/health_check && break; sleep 0.2; done
  "$4" "$config"
  local url token session
  url=$(LOCKSTEP_CONFIG=$config "$bin" operator sign-in --port 8001); token=${url#*token=}
  session=$(curl -s -D - -o /dev/null -X POST -H "Origin: http://127.0.0.1:8001" --data "token=$token" http://127.0.0.1:8001/operator/sign-in \
    | sed -n -E 's/^[Ss]et-[Cc]ookie: lockstep_session=([A-Za-z0-9_-]*);.*/\1/p')
  python3 /tmp/proxy.py 8000 127.0.0.1:8001 "$session" & local proxy=$!
  sleep 1
  curl -s -o "$OUT/center-$label.html" http://127.0.0.1:8000/operator/center
  chromium --headless --no-sandbox --disable-gpu --hide-scrollbars --window-size=1280,1400 \
    --screenshot="$OUT/center-$label-light.png" http://127.0.0.1:8000/operator/center >/dev/null 2>&1
  chromium --headless --no-sandbox --disable-gpu --hide-scrollbars --window-size=1280,1400 --force-dark-mode \
    --blink-settings=preferredColorScheme=0 \
    --screenshot="$OUT/center-$label-dark.png" http://127.0.0.1:8000/operator/center >/dev/null 2>&1
  kill "$proxy"; kill -TERM "$serve"; wait "$serve"
  echo "-- $label: dispositions on the page:"
  grep -oE 'data-criterion="[^"]*" data-disposition="[^"]*"' "$OUT/center-$label.html"
  grep -oE 'data-aggregate="[^"]*"' "$OUT/center-$label.html"
  grep -oE 'data-status="[^"]*" data-count="[^"]*"' "$OUT/center-$label.html"
  echo "   password occurrences: $(cat "$OUT/center-$label.html" "$OUT/serve-$label.log" | grep -o -F "$password" | wc -l)"
}

operator_jobs() {
  local rev
  run db migrate
  run db migrate --backup "$BACKUP"
  rev=$("$bin" workspace show | sed -n 's/^revision: //p')
  run job queue --expected-revision "$rev" --steps 2 --step-ms 50 --idempotency-key p16-operator-job-0001
  run job queue --expected-revision "$rev" --steps 20 --step-ms 5000 --idempotency-key p16-operator-job-0002
}
wait_jobs() { sleep 4; }
echo "== operator database"
"$bin" db status
capture "$LOCKSTEP_CONFIG" operator operator_jobs wait_jobs

echo "== scratch database (negative case)"
host=$(sed -E 's/.*"host":"([^"]*)".*/\1/' "$LOCKSTEP_CONFIG"); user=$(sed -E 's/.*"username":"([^"]*)".*/\1/' "$LOCKSTEP_CONFIG")
export PGPASSWORD=$password
psql -q -h "$host" -U "$user" -d lockstep -c "DROP DATABASE IF EXISTS lockstep_p16_negative" -c "CREATE DATABASE lockstep_p16_negative"
sed -E 's/"name":"[^"]*"/"name":"lockstep_p16_negative"/' "$LOCKSTEP_CONFIG" > /tmp/negative.json; chmod 600 /tmp/negative.json
negative_jobs() {
  LOCKSTEP_CONFIG=$1 "$bin" db migrate >/dev/null
  LOCKSTEP_CONFIG=$1 "$bin" job queue --expected-revision 0 --steps 2 --step-ms 50 --idempotency-key p16-negative-job-0001 >/dev/null
  LOCKSTEP_CONFIG=$1 "$bin" job queue --expected-revision 0 --steps 2 --step-ms 50 --idempotency-key p16-negative-job-0002 >/dev/null
  LOCKSTEP_CONFIG=$1 "$bin" job queue --expected-revision 0 --steps 3 --step-ms 50 --fail-at-step 2 --idempotency-key p16-negative-job-0003 >/dev/null
}
negative_edit() {
  sleep 3
  psql -q -h "$host" -U "$user" -d lockstep_p16_negative -c "UPDATE lockstep_jobs SET steps_done = 1 WHERE id = 1" -c "UPDATE lockstep_jobs SET outcome_digest = NULL WHERE id = 2"
  echo "   edited job 1 (steps_done) and cleared job 2's digest"
}
capture /tmp/negative.json negative negative_jobs negative_edit
psql -q -h "$host" -U "$user" -d lockstep -c "DROP DATABASE lockstep_p16_negative WITH (FORCE)"
echo "== done"
