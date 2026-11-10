test -e /work/repo/after-snapshot.txt && echo marker-present || echo marker-absent
test -f /work/repo/src/calc.c && echo source-back
