# After restoring the 'verify' snapshot and a fresh import (no .stack-work): the marker must be gone, the
# toolchain present, and Brigid's real scripts/test must run (Phase 5 update 2 §6.3).
[ -e "$HOME/after-snapshot-marker" ] && echo marker-survived || echo marker-gone
[ -e /work/tree/.stack-work ] && echo tree-has-build-output || echo tree-fresh
free -g | sed -n 's/^Swap: *\([0-9]*\).*/swap-gib=\1/p'
cd /work/tree
echo "== test start $(date -u +%FT%TZ) at $(git rev-parse HEAD)"
scripts/test > /tmp/brigid-test.log 2>&1
rc=$?
tail -n 3 /tmp/brigid-test.log
echo "== test end $(date -u +%FT%TZ) exit=$rc"
exit $rc
