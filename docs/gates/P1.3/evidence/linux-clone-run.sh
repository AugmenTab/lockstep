#!/usr/bin/env bash
# Canonical Linux-clone check (case-sensitive filesystem): clone the tested
# commit inside the dev container and run the check steps there, with a
# disposable PostgreSQL on a private network. Usage, from the repo root:
#   docs/gates/P1.3/evidence/linux-clone-run.sh <commit>
set -euo pipefail
commit=$1
net=lockstep-linux-p13
pg=lockstep-linux-p13-pg
password=$(head -c 24 /dev/urandom | base64 | tr -d '/+=\n')
cleanup() {
  docker rm -f "$pg" >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$net" >/dev/null
docker run -d --name "$pg" --network "$net" --env POSTGRES_PASSWORD="$password" \
  "$(cat scripts/lib/postgres-image)" >/dev/null
until docker exec "$pg" pg_isready -q -h 127.0.0.1 -U postgres 2>/dev/null; do sleep 1; done
docker run --rm --network "$net" \
  --env LOCKSTEP_TEST_PG_HOST="$pg" --env LOCKSTEP_TEST_PG_PORT=5432 \
  --env LOCKSTEP_TEST_PG_USER=postgres --env LOCKSTEP_TEST_PG_PASSWORD="$password" \
  --volume "$PWD:/src:ro" --volume lockstep-stack-root:/stack-root \
  lockstep-dev:p1 bash -c "
    set -e
    git config --global --add safe.directory '*'
    git clone -q /src /work && cd /work && git checkout -q $commit
    git rev-parse HEAD
    ls src/Lockstep
    for s in format lint build unit integration; do
      scripts/lib/check-step \$s > /tmp/\$s.log 2>&1 && echo \"\$s PASSED\" || { echo \"\$s FAILED\"; tail -40 /tmp/\$s.log; exit 1; }
    done
    grep -h 'tests passed' /tmp/unit.log /tmp/integration.log
  "
echo "exit=$?"
