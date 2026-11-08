# A-P4.2-1 — amendment request: the process-limit probe in the frozen host check

- Prepared by: the writing agent (Implementer), 2026-10-28. **Not applied**: the frozen bytes are in the tree
  (digest checked after the trial). Needs the owner's authorization.
- File: `scripts/lib/check-runner`, frozen in C-P4.2 §4 at
  `20f710cc4fbc05bbd79c2de382441a61e71acd0e8aef4520fe3203f7b40779fe`.
- Defect (in the probe, not the helper): probe 8 starts 400 `sleep` processes from `/bin/sh` and prints how
  many started at the end. With `--pids-limit 256` the shell **dies** at the first failed fork
  (`/bin/sh: 0: Cannot fork`, exit 2; bash does the same, exit 254), so it never prints the total and the probe
  reports `started: ?` — a FAIL although the limit held. Evidence, outside the check, with the helper's own
  options: printing the counter on each iteration stops at **255** (the shell plus 255 sleeps = 256), then
  `Cannot fork`.
- Change (one line; the check already takes the last line of output):

```diff
@@ -206,7 +206,7 @@
 # 8 bounded processes
-run_probe run-write /bin/sh -c 'n=0; for i in $(seq 1 400); do sleep 4 2>/dev/null & if [ $? -eq 0 ]; then n=$((n+1)); fi; done 2>/dev/null; echo $n'
+run_probe run-write /bin/sh -c 'for i in $(seq 1 400); do sleep 4 & echo $i; done'
 started=$(out_of "$run" | tail -n 1)
 expect "no more than 256 processes (started: ${started:-?})" test "${started:-400}" -lt 400
```

- Digest before: `20f710cc4fbc05bbd79c2de382441a61e71acd0e8aef4520fe3203f7b40779fe`.
  Digest after: `cc3998c29d7365fa39159dca4636bc9f0ff661f6ace466dc2e8915a16b66bb34`.
- Effect: the probe observes the limit instead of requiring the shell to survive it. The assertion is unchanged
  (fewer than 400 started); it now reports the number actually reached.

## Trial record

- Frozen check on the implementation (`p42-check-runner-run1.log`): 43 of 44 PASS; probe 8 FAIL `started: ?`.
- With the change applied temporarily (`p42-check-runner-trial-a1.log`): **44 of 44 PASS**, probe 8
  `started: 255`.
- Restored with `git restore`; digest again `20f710cc…79fe`.

## Decision

**APPROVED** 2026-10-28 by the owner in the session (answer to the amendment question: "Approve"). Applied
exactly; digest after verified `cc3998c29d7365fa39159dca4636bc9f0ff661f6ace466dc2e8915a16b66bb34`. Re-frozen in
C-P4.2 §4.1.
