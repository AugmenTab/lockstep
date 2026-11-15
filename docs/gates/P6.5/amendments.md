# C-P6.5 — amendments and contract text corrections

No frozen test was changed. The remediation tests are added in `review.md` (R-P6.5), with the shared runner's new
digest.

## Contract text corrections (from the independent review, R-P6.5)

| Decision | Correction |
|---|---|
| S4 | The idempotency key is fixed by the project, the **revision's identity** and the unit, not by the revision's digest. A later revision may repeat a digest (migration 25, R-P6.4-4). Inside the hand-over's transaction the decision is made again and must still choose this unit of this revision: `not-next` otherwise (R-P6.5-3, R-P6.5-4), and `stale-plan-revision` when the revision is no longer effective. Both refusals write nothing. |
| S7 | Two more waiting reasons. `stopped`: the unit's fix was stopped, so it is never handed over again; the person cancels the task or changes the plan. `refused`: its last hand-over was refused, and it is tried again on each pass. A refused hand-over is recorded in `lockstep_plan_dispatch_refusals` (migration 27) only when it differs from the last one for that unit, so it is reported and logged once. A unit whose task does not replay is `unknown` (never left out). Races (`not-next`, `stale-plan-revision`, `stale-revision`) are not recorded. |
| S8 | When the basis stage runs, every prerequisite must still be satisfied (S1), else the fix halts `prerequisite-unsatisfied`. The candidates are the prerequisites reached by a **technical plan edge** whose fix has an accepted commit, whether still Accepted or marked Done since. An Accepted or Done fix without an accepted commit is an integrity violation. A fix built on an accepted commit does not check the person's checkout: its basis is that commit, not the checkout. Its provenance rows are written in the same database transaction as its basis. **Limitation:** a prerequisite through an untyped task dependency (no plan edge) gives the checkout. Lockstep merges nothing, so the person brings that work into their checkout. |
| §2 | Persistence also has migration 27 and `Persistence.Dispatch` refusals. `Application.Tasks` exports `basisCandidates` (in place of `acceptedBases`). |

## Known gap carried to P6.7

Not done on an accepted ancestor halts a dependent fix that has not reached its basis (`prerequisite-unsatisfied`).
Descendants already built on that ancestor keep running. Revoking them and invalidating their evidence is P6.7's
rejection and invalidation.
