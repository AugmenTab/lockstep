# C-P6.7 — full check, independent review and remediation (R-P6.7)

- Reviewed: `f3b3c71` (implementation) against `C-P6.7@v1` and its freeze commit `3ca8c4b`.
- Reviewer: an independent read-only agent, 2026-11-15 (nothing built or run by it).

## Full check of `f3b3c71`

`scripts/check --integration` on `f3b3c71`: format, lint/static, build, unit **1042/1042**, no-live-model guard,
integration **673/673**, backup/restore — **all PASSED** (`.local/evals/phase-06/p67-full-check.log`).

## Review findings and dispositions

The review confirmed these hold:
- the Not done propagation, inside the Stop's own database transaction;
- `FixAcceptanceInvalidated`, and the halt before each stage;
- the Stop-only choices, and the basis check at acceptance;
- the rework check under the task lock, with `already-admitted` while the latest fix is live;
- the latest hand-over by identity;
- no deletion or rewriting of history.

| # | Finding | Disposition |
|---|---|---|
| 1 (high) | Done read the invalidation outside the fix's row lock, and recording an invalidation locked nothing. A Done racing a rejection or plan approval could end Done with an invalidation row, and its dependents would build on it. | **Fix (R-P6.7-1):** recording an invalidation first locks the fix's row. Done checks the invalidation inside its own locked step and refuses `acceptance-invalidated`. Both sides serialize on the row lock. |
| 2 | Acceptance checked the basis and the invalidation before its Git work, and nothing again before recording the acceptance. | **Fix (R-P6.7-2):** both are checked again in the step that records the acceptance. If either fails, the fix halts there instead (`basis-stale`, or the invalidation's code). The work branch may already point at the candidate; that ref stays, as history, and the fix is not accepted. |
| 3 | A rework hand-over by the person was always a bug fix, dropping the plan unit's kind and Profile. | **Fix (R-P6.7-3):** a task that is a unit of its project's effective revision is handed over with that unit's kind and named Profile, whoever hands it over. |
| 4 | Progress picked the first hand-over of a task, not the latest. | **Fix:** a project's hand-overs are read newest first, so Progress shows the latest fix. **Limitation:** Progress does not show *invalidated*; the Plan page does. |
| 5 | A rejection committed while a descendant was in its basis stage recorded no invalidation for it. It then ran every stage up to acceptance. | **Fix (R-P6.7-5):** before every stage, the fix's recorded bases are checked as at acceptance (`basis-stale`, Stop only). |
| 6 | A fix already halted for another reason is halted again for the invalidation. The older halt's request stays open and still offers retry. | **Limitation (recorded):** answering the older request is ignored, because the engine reads only the latest halt's request, so no stage runs. Withdrawing requests is not part of P6.7. |
| 7 | One fix could get two invalidation rows, read in no order. | **Fix (migration 30):** at most one invalidation per fix (a unique index), recorded under the row lock. |
| 8 | §2 said the dispatches' one-per-task constraint was dropped; it was not. | **Contract text corrected:** it is kept. Only the person hands a task over again (V6). |
| 9 | Invalidation went through a Done fix but was ignored there, so a Done fix could stand on a rejected change. | **Decision (R-P6.7-9):** the person's Done is refused while any fix it was built on is not Done (`ancestor-not-done`), so a Done fix never stands on a provisional or rejected one. |
| 10 | An invalidated fix that is still running shows as `handed-over` until it halts. | **Recorded:** it halts at its next stage (Stop only), and once stopped it is `stopped`. |
| 11 | A plan change on a unit handed over but not yet started records nothing. | **Limitation (recorded):** its fix reads the task's current text when its roles run. Its kind is the one it was handed over with. |
| 12 | A stopped unit's words did not mention rework. | **Fix:** they say the task can be handed over again. |

## Remediation tests (frozen with this record)

| File | sha256 |
|---|---|
| `test/unit/Lockstep/Kernel/InvalidationReviewTest.hs` | `9eccca67781c0f1fa5bdfb62e2c6489f90990af7fc7b1fbb1155ea069fba1443` |
| `test/integration/Lockstep/ProvisionalReviewTest.hs` | `6a8ff91d36c92b7bd3b69e441ba173c3e0d0109fd03326edf4287dfa00f22291` |
| `test/integration/Main.hs` (shared runner; supersedes C-P6.7 §5, additive) | `bc1e99c0a58110421083691f976141a087ea91d0b0a851b56b5bb46f6bd1556f` |
| `test/unit/Main.hs` (shared runner; supersedes C-P6.7 §5, additive) | `e5d23ddd507a2101b1dd49369678a568bd98a0f794ad2445ffe76ce5d73eb8b8` |

Formatted and linted before the digests were taken. Baseline against `f3b3c71`:
- **Unit: 1 of 1 fails.** The stopped words lack the rework path.
- **Integration: 2 of 3 fail.** R-P6.7-9: Done is allowed before its ancestor's. R-P6.7-3: the rework is a bug fix.
- **Kept as a guard** (it passes): the plan-change cascade, where a changed unit and the fix built on it are both
  invalidated, the latter `ancestor-rejected` with its cause, and an invalidated fix is not handed over again before
  it is stopped.
- The races in #1, #2 and #5 are not reproducible by a scripted test. Their fixes are checked by reading, and the
  full check runs every other test against them.
- Logs: `.local/evals/phase-06/p67r-baseline-*.log`.

## After remediation

(filled after the trial and the full check)
