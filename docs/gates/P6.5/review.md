# C-P6.5 — full check, independent review and remediation (R-P6.5)

- Reviewed: `58c9ee4` (implementation) against `C-P6.5@v1` and its freeze commit `a510f73`.
- Reviewer: an independent read-only agent, 2026-11-14 (nothing built or run by it).

## Full check of `58c9ee4`

`scripts/check --integration` on `58c9ee4`: format, lint/static, build, unit **1001/1001**, no-live-model guard,
integration **647/647**, backup/restore — **all PASSED** (`.local/evals/phase-06/p65-full-check.log`).

## Interpretation recorded for the owner

The handoff (§10) says "extend the existing deterministic Scheduler". The C-P2 Work Unit scheduler
(`Lockstep.Kernel.Scheduler`) has never driven the coding engine. P6.5 therefore extends the engine worker's
deterministic path: a pure Kernel decision (`Lockstep.Kernel.Dispatch`) followed by the existing hand-over. There is
no second queue and no model. The durable, compare-and-swap-protected **claim** is the admission: one per task
(unique), under the task lock, behind an idempotency key, and recorded in `lockstep_plan_dispatches`.

## Review findings and dispositions

The review found no way to hand a unit over twice, or to hand one over without owner approval.

| # | Finding | Disposition |
|---|---|---|
| 1 | S8's basis was computed from the live state at basis time. If the prerequisite's fix was marked **Done** after the hand-over, it stopped counting, and the dependent silently started from the checkout without the accepted change. If it was marked **Not done**, the dependent still ran. | **Fix (R-P6.5-1):** the candidates are every prerequisite reached by a technical plan edge whose fix has an accepted commit, Accepted or Done. If a prerequisite is no longer satisfied at basis time, the fix halts `prerequisite-unsatisfied`. |
| 2 | A Done prerequisite with no plan edge is never a basis candidate; an Accepted row without an accepted commit was silently skipped. | **Partly fixed:** an Accepted or Done fix without an accepted commit is an integrity violation. **Limitation:** an untyped task dependency (no plan edge) still gives the checkout. Lockstep merges nothing, so the person brings a Done fix into the checkout themselves. |
| 3 | The decision's facts were read outside one transaction, and only the revision digest was checked again under the lock. A concurrent hand-over could give a project two hand-overs in one pass. | **Fix (R-P6.5-3):** the hand-over's guard decides again under the task lock and requires the unit to be the decision's next one (`not-next` otherwise). |
| 4 | `handOverUnit` bypassed the decision (not-local, budgeted, busy writer). | **Fix (R-P6.5-4):** the same guard. |
| 5 | A stopped fix was shown as `handed-over`, "under way". | **Fix (R-P6.5-5):** waiting reason `stopped`, in words telling the person what to do. |
| 6 | A refused hand-over was retried, reported and logged on every pass, and the page still said "Next". | **Fix (R-P6.5-6):** a refusal is recorded (`lockstep_plan_dispatch_refusals`, migration 27) only when it differs from the last one for that unit. It is reported and logged once and shown as `refused`, and it is tried again on each pass. Passing over a refused unit to another one is not done: every lasting refusal (`folder-read-only`, `bug-checks-missing`, ownership, `execution-not-enabled`) holds for the whole project. |
| 7 | A unit whose task does not replay was silently left out. | **Fix:** it is shown as `unknown` and never handed over. |
| 8 | A busy writer whose task does not replay had an empty title. | **Fix:** the task's identity instead. |
| 9 | A dependent fix skips the clean-checkout check. | **Intended, now in the contract (S8):** its basis is an accepted commit, not the checkout, so the person's uncommitted work does not touch it. |
| 10 | Provenance rows and the basis settle were written in separate transactions. | **Fix:** written in the same transaction. |
| 11 | The hand-over key used the revision's digest, which a later revision can repeat (migration 25). | **Fix, contract text corrected (S4):** the key is fixed by the revision's identity and the unit. |
| 12 | Every task view reloaded the effective plan. | **Fix:** a listing loads each project's plan links once. |
| 13 | Not done on an accepted ancestor leaves descendants already built on it running. | **Known gap, P6.7** (rejection and invalidation). |

## Remediation tests (frozen with this record)

| File | sha256 |
|---|---|
| `test/integration/Lockstep/DispatchReviewTest.hs` | `5392632f610593a98c914d206cdd2fe3f6a1a980e373f68add2c81fccb8748e4` |
| `test/integration/Main.hs` (shared runner; supersedes the C-P6.5 §5 digest, additive) | `146031bd060e446a81c8b63a0e611e125e107dba3635fe9d11874dfe0ed8f670` |

Formatted and linted before the digests were taken. Baseline against `58c9ee4`: **5 of 7 fail**, each at its
defect:
- R-P6.5-1 Done: f2 not built on f1's accepted commit.
- R-P6.5-1 Not done: f2 runs on.
- R-P6.5-3/4: `handOverUnit` hands over f2.
- R-P6.5-5: `handed-over`.
- R-P6.5-6: the refusal is reported again.

The diamond case (`basis-ambiguous` through the engine) and the S1 negatives (a technical edge on a unit that is not
provisional; a human-acceptance edge) pass and are kept as guards. `.local/evals/phase-06/p65r-baseline.log`.

## After remediation

Trial: P6.5 integration **15/15** (C-P6.5 8, R-P6.5 7), unit **16/16** (`.local/evals/phase-06/p65r-trial.log`).
Contract text corrections are in `amendments.md`.

Full check of the remediation commit (`fix(dispatch): resolve the independent review of C-P6.5 (R-P6.5)`): format,
lint/static, build, unit **1001/1001**, no-live-model guard, integration **654/654**, backup/restore — **all PASSED**
(`.local/evals/phase-06/p65r-full-check.log`). P6.5 is locally qualified; owner acceptance pending.
