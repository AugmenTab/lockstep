# C-P6.7 — amendments and contract text corrections

No frozen test was changed. The remediation tests are added in `review.md` (R-P6.7), with the shared runners' new
digests.

## Contract text corrections (from the independent review, R-P6.7)

| Decision | Correction |
|---|---|
| V3 | The person's Done is refused while any fix it was built on is not Done (`ancestor-not-done`), as well as while its acceptance no longer counts (`acceptance-invalidated`). Both are checked under the fix's row lock. Recording an invalidation takes the same lock, so neither can slip past the other (R-P6.7-1, R-P6.7-9). |
| V4 | Before every stage, a fix whose recorded bases no longer count halts `basis-stale` (Stop only), not only at acceptance. The step that records an acceptance checks the invalidation and the bases again under the row lock (R-P6.7-2, R-P6.7-5). If that late check fails, the work branch may already point at the candidate. That ref stays, and the fix is not accepted. |
| V2 | At most one invalidation per fix (migration 30), its first cause. |
| V6 | A rework keeps the kind its task was last handed over with, and the Profile its plan unit names (R-P6.7-3). The dispatches' one-per-task constraint is **kept**: only the person hands a task over again. A project's hand-overs are read newest first. |

## Limitations recorded

- A fix halted for another reason and then invalidated keeps its older halt request open. Answering it is ignored,
  and no stage runs.
- An invalidated fix still under way shows as `handed-over` until it halts (at its next stage) and is stopped.
- A plan change to a unit that is handed over but not yet started records no invalidation. Its fix reads the
  task's current text.
- A plan unit first handed over by a person, not the scheduler, runs as a bug fix (C-P6.4 M6, frozen).
- Progress shows the latest fix, but does not show *invalidated*; the Plan page does.
