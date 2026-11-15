# C-P6.8 — full check, independent review and remediation (R-P6.8)

- Reviewed: `9c5fb65` (implementation) against `C-P6.8@v1` and its freeze commit `2342245`.
- Reviewer: an independent read-only agent, 2026-11-15 (nothing built or run by it).

## Full check of `9c5fb65`

`scripts/check --integration` on `9c5fb65`: format, lint/static, build, unit **1060/1060**, no-live-model guard,
integration **682/682**, backup/restore — **all PASSED** (`.local/evals/phase-06/p68-full-check.log`).

## Review findings and dispositions

The review confirmed these hold:
- no review is `not-run`, and a review needing a person is never `approved`;
- accepted is `verified`, never `done`, and nothing is called published;
- unknown usage stays unknown, and no money is shown;
- the intervention codes cover every Stop-only halt;
- making a summary writes nothing;
- agent text never reaches a category or an outcome;
- agent text on the page is escaped.

| # | Finding | Disposition |
|---|---|---|
| 1 (high) | The latest verification or review record of the whole transaction was used, whatever commit it was about. After a rework inside the transaction, an earlier candidate's result was shown as the fix's. | **Fix (R-P6.8-1):** a verification or review counts only when it is about the fix's current candidate commit; otherwise it is `not-run`. This is the rule acceptance applies. |
| 2 | If the latest record of a kind did not decode, an older one was used. | **Fix:** only the latest record of a kind counts. If it does not decode, the outcome is `not-run`. |
| 3 | Only the task's latest fix was read, so after a rework the earlier fix's interventions and usage disappeared. | **Fix (R-P6.8-3):** interventions and usage come from every fix of the task; the category comes from the latest. |
| 4 | A task handed over but not started was `eligible`. | **Fix (R-P6.8-4):** it is `waiting`. |
| 5 | Pending decisions were not shown on the page. A halted fix's evidence named neither its halt nor its request. | **Fix (R-P6.8-5):** the page lists the decisions waiting, with their requests. A halted fix's evidence adds its halt record and its open request. |
| 6 | Usage is read from the last 2000 characters of a run's output. A long final message can push the CLI's one-line result out, and the run then counts as usage-unknown. | **Limitation (recorded):** the outcome is honest, since the run is unknown and never zero. Recording usage when a run finishes, from its full output, is left to a later phase; it needs a new column. |
| 7 | The reads are per task (N+1), and the summary is made on every Progress render. | **Limitation (recorded):** correct, and in one transaction for the fixes. Batching the reads is left to later; Phase 6 projects are small. |
| 8 | A verification that could not run (a missing program, or a run that did not end) was shown as `failed`. | **Fix (R-P6.8-8):** it is `not-run` when the fix halted with `verification-environment-missing` or `verification-run-failed`. |
| 9 | Freshness compares the plan revision only. | **Recorded:** the page always makes a fresh summary. The summary also names how many records it was made from. |
| 10 | A canceled task with a fix under way was not `canceled`. A blocked, unstartable or unrecognised plan unit was `planned`. | **Fix:** canceled first; `planned` only for a unit not yet ready or waiting for prerequisites. |
| 11 | The page said usage was not recorded even when the summary had counted runs that reported nothing. | **Fix:** it says how many role runs reported nothing. |
| 12 | Evidence ids are plain text, and the two record ids are not labelled. | **Fix:** labelled (`verification record n`, `review record n`). Links to a fix's own page wait for a route for it. |
| 13 | Role runs were told apart from commands by the adapter name. | **Fix:** by the role names. |
| 14 | A resume was paired with the latest halt that decoded. | **Recorded:** halts are written by the engine itself, and an undecodable one is reported `unknown`. Pairing by request is left as is. |
| 15 | An unknown but well-formed project id gave an empty summary. | **Fix:** Nothing. |

## Remediation tests (frozen with this record)

| File | sha256 |
|---|---|
| `test/unit/Lockstep/Kernel/SummaryReviewTest.hs` | `060e9bc173f7ed8696d8e508ec4d8cadbbf18551b988c3242d237c1bb59fbecb` |
| `test/integration/Lockstep/SummaryReviewTest.hs` | `c509bd206d75a0e56b41d07f85349fbf6d8f5f4f62eb9a079ab976163c67e2e8` |
| `test/integration/Main.hs` (shared runner; supersedes C-P6.8 §5, additive) | `da8181e851c02485d14dc7f1e3a0803ec05b1d69d9ac19dc0307895db85197e6` |
| `test/unit/Main.hs` (shared runner; supersedes C-P6.8 §5, additive) | `debc37655e9be0302694e04c7f4f6c739733055aa0ed3db5056312681606d464` |

Formatted and linted before the digests were taken. Baseline against `9c5fb65`: **unit 2 of 2 fail** and
**integration 5 of 5 fail**, each at its defect:
- R-P6.8-1: the earlier candidate's rejection is shown as the review.
- R-P6.8-4: a queued fix is `eligible`.
- R-P6.8-5: there is no request in the evidence.
- R-P6.8-8: `failed`.
- R-P6.8-3: the intervention is gone after the rework.
- R-P6.8-10: canceled under way, and planned while blocked.

Logs: `.local/evals/phase-06/p68r-baseline-*.log`.

## After remediation

- Trial of the frozen remediation tests against the remediation: unit 175/175, integration 104/104 (the C-P6.8
  and R-P6.8 groups).
- Full check of `543f9d6` (`scripts/check --integration`): all passed: build, unit tests (1062), no-live-model
  guard, integration + backup/restore (687). Log: `.local/evals/phase-06/p68r-full-check.log`.
- C-P6.8 is locally qualified; owner acceptance is pending.
