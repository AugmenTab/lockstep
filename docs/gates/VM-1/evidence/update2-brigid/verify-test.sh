# Brigid's real test command at the basis, in the verification capsule (Phase 5 update 2 §6.3).
# The first run also builds and caches every dependency in ~/.stack, which the 'verify' snapshot keeps.
cd /work/tree
echo "== test start $(date -u +%FT%TZ) at $(git rev-parse HEAD)"
scripts/test > /tmp/brigid-test.log 2>&1
rc=$?
tail -n 60 /tmp/brigid-test.log
echo "== test end $(date -u +%FT%TZ) exit=$rc"
exit $rc
