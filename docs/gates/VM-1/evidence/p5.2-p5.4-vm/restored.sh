test -e /work/tree/after-snapshot.txt && echo marker-present || echo marker-absent
test -f /work/tree/src/calc.c && echo source-back
