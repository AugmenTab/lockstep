# Gate VM-1 packet: Brigid's real scripts/test on the accepted commit, in brigidv restored from 'verify',
# fresh import. Operator-run, model-free. Prints the per-suite summaries and the new HXML tests' lines.
cd /work/tree
echo "== test start $(date -u +%FT%TZ) at $(git rev-parse HEAD)"
[ -e /work/tree/.stack-work ] && echo tree-has-build-output || echo tree-fresh
scripts/test > /tmp/brigid-test.log 2>&1
rc=$?
grep -E 'HXML scrollToInputOffset|scroll-to-input-offset name|both attributes coexist|tests? passed|tests? failed|Test suite .* (passed|failed)|FAIL' /tmp/brigid-test.log
echo "== test end $(date -u +%FT%TZ) exit=$rc"
exit $rc
