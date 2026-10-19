# R-P2.9-1 — frozen-criterion amendment request (C-P2.9 AC-B1-15)

- Prepared by: the writing agent (Implementer), 2026-10-19. Status: `APPROVED` by the human owner ("R-P2.9-1 APPROVED as written", `.local/plans/phase-02_update2.md`); applied and recorded in C-P2.9 §6.1. A frozen
  criterion may change only with the human owner's approval. The protocol is the one used for
  R-P2.3-1 and R-P2.5-1.
- Contract: `C-P2.9@v1`, frozen at `1e59942` together with `scripts/b1`.
- Evidence: B1 run 1, `docs/gates/B/evidence/b1-run1/` (`b1.log`, section "B1-15"). Run 1:
  **16 of 17 checks PASSED**; AC-B1-15 FAILED.

## What happened

AC-B1-15 starts two `supervisor execute-once` processes together for one pending repeatable
sandbox effect:

```
### two concurrent execute-once: exit 0: executed 46aa256f-… applied applied | exit 65: lockstep: refused (dispatched-needs-recovery): DispatchedNeedsRecovery
```

- Process 1 claimed, dispatched and applied the effect.
- Process 2 listed the effect as runnable while it was still pending. When it tried to claim
  it, process 1 had already dispatched it, so the C-P2.5 lifecycle refused the claim
  (`dispatched-needs-recovery`, E5).
- Process 2 executed nothing. The sandbox shows **one** application.

That is the behaviour the criterion is meant to prove. The criterion's wording fails it.

## Why the criterion is wrong

AC-B1-15 says the other process is "`idle` or `refused claim-held`". Depending on when its claim
arrives, the losing process sees one of four outcomes, and none of them executes anything:

| The loser's claim arrives… | Outcome |
|---|---|
| after the winner's conclusion, and it lists runnable intents after that | `idle` |
| after the winner's claim, before its dispatch marker | `refused claim-held` |
| after the winner's dispatch marker, before its conclusion | `refused dispatched-needs-recovery` (run 1) |
| after the winner's conclusion, but it listed runnable intents before it | `refused already-settled` |

I froze an incomplete list. A second, smaller defect is in the script: it captured stdout and
stderr in one file and read the first line, which was stderr. The refusal's stdout line is
`refused dispatched-needs-recovery`.

## Proposed amendment

Contract, AC-B1-15:

```diff
-| AC-B1-15@v1 | Duplicate ownership: two `execute-once` processes started together for one pending effect: one executes it, the other does not (`idle` or `refused claim-held`); one application. | yes |
+| AC-B1-15@v1 | Duplicate ownership: two `execute-once` processes started together for one pending effect: one executes it; the other executes nothing — it is `idle`, or its claim is refused (`claim-held`, `dispatched-needs-recovery` or `already-settled`); one application. | yes |
```

`scripts/b1`, B1-15: keep stdout and stderr apart, and accept exactly those outcomes:

```diff
-scripts/service cli supervisor execute-once > "$work/dup-1.out" 2>&1 &
+scripts/service cli supervisor execute-once > "$work/dup-1.out" 2> "$work/dup-1.err" &
 p1=$!
-scripts/service cli supervisor execute-once > "$work/dup-2.out" 2>&1 &
+scripts/service cli supervisor execute-once > "$work/dup-2.out" 2> "$work/dup-2.err" &
 p2=$!
@@
-echo "### two concurrent execute-once: exit $c1: $d1 | exit $c2: $d2" >> "$log"
+echo "### two concurrent execute-once: exit $c1: $d1 [$(head -n 1 "$work/dup-1.err")] | exit $c2: $d2 [$(head -n 1 "$work/dup-2.err")]" >> "$log"
@@
-check AC-B1-15 "exactly one process executes the effect; the other is idle or refused claim-held; one application" \
-  "$([ "$executed_count" = 1 ] && { [ "$other" = idle ] || [ "$other" = "refused claim-held" ]; } && [ "$applied_e" = 1 ]; echo $?)"
+check AC-B1-15 "exactly one process executes the effect; the other executes nothing (idle, or refused claim-held, dispatched-needs-recovery or already-settled); one application" \
+  "$([ "$executed_count" = 1 ] && case "$other" in idle | "refused claim-held" | "refused dispatched-needs-recovery" | "refused already-settled") true ;; *) false ;; esac && [ "$applied_e" = 1 ]; echo $?)"
```

Unchanged:
- The scenario.
- The requirement that exactly one process executes.
- The requirement of exactly one application.
- Every other criterion.

The accepted outcomes are only the lifecycle's own refusals of a duplicate claim. An error,
another refusal, or a second execution still fails the check.

## Decision requested

Approve R-P2.9-1 as written, or name another wording. If approved, I will:
1. apply both diffs;
2. record the amendment in C-P2.9;
3. re-run B1 from a clean checkout of the new commit (run 2), keeping run 1 as history;
4. then write the Gate B report and the decision packet.
