# C-P6.4 — full check, independent review and remediation (R-P6.4)

- Reviewed: `4c2ad25` (implementation) against `C-P6.4@v1`, its freeze commit and amendment A-P6.4-1.
- Reviewer: an independent read-only agent, 2026-11-14 (nothing built or run by it).

## Full check of `4c2ad25`

`scripts/check --integration` on `4c2ad25`: format, lint/static, build, unit **985/985**, no-live-model guard,
integration **634/634**, backup/restore — **all PASSED** (`.local/evals/phase-06/p64-full-check.log`). The review
below found defects the frozen tests did not cover.

## Review findings and dispositions

| # | Finding | Disposition |
|---|---|---|
| 1 | A later approval rewrote every plan task's title, acceptance, priority and dependencies from the plan, also for **kept** units and over a person's own edits and dependencies. | **Fixed (R-P6.4-1):** a unit's task text is written only when the unit's text changed since the revision that last wrote it; if a person edited that task since, the approval is refused `locally-edited` and nothing is written. A person's dependencies on tasks outside the plan are kept. |
| 2 | A withdrawn unit's task stayed `ready` and could be handed over; a unit that returned reused its task in whatever state it was. | **Fixed (R-P6.4-2):** the approval blocks a withdrawn unit's task ("Withdrawn from the plan by its revision N."), so it is not handed over; when the unit returns, the same task is unblocked. A done or canceled task is left as it is. |
| 3 | M10 promised a draft request "or the plan page", and §2 named `effectiveUnits`; neither exists. | **Contract corrected (`amendments.md` C-P6.4 text corrections):** drafts are requested by the CLI only in this subphase; `effectiveUnits` is not part of P6.4 (P6.5 reads the effective revision itself). |
| 4 | The same plan could never be proposed again: a rejected plan, or an earlier approved one the owner wants back, was `already-proposed` forever. | **Fixed (R-P6.4-4):** `already-proposed` only while a revision with that digest waits for a decision or is in effect; otherwise it becomes a new revision (migration 25 drops the unique (plan, digest) constraint). |
| 5 | An acceptance that would not fit a task (over 4000 characters, control characters) was found only at approval, with a misleading code. | **Fixed (R-P6.4-5):** `validatePlan` refuses it at proposal (`invalid-acceptance`). |
| 6 | A draft could be finished `uncertain` although its revision had been proposed (proposal and finish in two transactions); an uncertain Planner run had the words of a stopped worker. | **Fixed (R-P6.4-6):** a valid draft's revision is proposed and the draft finished in one transaction; an uncertain Planner run is recorded `planner-uncertain`, a stopped worker `worker-stopped`, each with its own words. (Not separately tested: a crash between the two former transactions cannot occur now.) |
| 7 | "Earlier work on it no longer counts" was claimed on the page and in the guide, but P6.4 only records the label. | **Fixed:** the words say the work will need redoing and that Lockstep does not yet enforce it (P6.7 does). |
| 8 | M6's "signoff naming the revision and digest" is not on the Ticket; the decision's actor is the channel, not the session. | **Contract corrected:** the Ticket accept is the plain C-P2.2 accept by principal Human (it carries no signoff); the approval's provenance is the decision row (digest, actor `application` or `command-line`, as the other C-P3/C-P4 decisions record) and `lockstep_plan_units`. |
| 9 | A unit whose criteria cite nothing never changes when its sources change. | **Fixed (R-P6.4-9):** every criterion must cite at least one source (`uncited-criterion`). |
| 10 | A-P6.4-1's record said no other line changed, but a `bugTables` helper was added; the narrowed assertion is weaker (NOT NULL columns and foreign keys of nine named tables only). | **Record corrected** in `amendments.md`. The weaker reach is recorded as a limitation: the case still asserts the bug's claim, its Work Unit with `plan_ref IS NULL`, and its rows. |
| 11 | M9 names "repository" but `Elaboration` has none. | **Contract corrected:** a project has one repository in Phase 6, so an elaboration cannot change it; the field is not needed. `validateElaboration` is not yet called (P6.6/P6.7 use it). |
| 12 | Missing tests: concurrent approvals, edit-then-approve, withdraw-then-return, long acceptance at proposal, crash between draft proposal and finish. | **Added (frozen, RED first)** except the last (made impossible by R-P6.4-6). |

## Remediation tests (frozen with this record)

| File | sha256 |
|---|---|
| `test/integration/Lockstep/PlanReviewTest.hs` | `e7689b511bc4192ad35cf889ac7c54302a71e06af5cdced84db6d19828230a0a` |
| `test/integration/Main.hs` (shared runner; supersedes the C-P6.4 §5 digest, additive) | `24e0bc576098c9bf3ed454e3111353a1f23dd7713b852526a6b0637763437ccf` |

Baseline against `4c2ad25`: **4 of 5 fail**, each at its defect (R-P6.4-1 the person's acceptance overwritten;
R-P6.4-2 the withdrawn task still `ready`; R-P6.4-4 `already-proposed` for a rejected plan; R-P6.4-5/9 the long
acceptance proposed). The concurrent-approvals case passes (the review judged the locking right; it is kept as a
guard). `.local/evals/phase-06/p64r-baseline.log`.

Lint was not run on the remediation test before its freeze; it has one style hint (`Use fromLeft`). As for C-P4.L,
the hint is ignored for that module only in `.hlint.yaml`; the test's content is unchanged.

## After remediation

Trial: P6.4 integration **17/17** (C-P6.4 12, R-P6.4 5), unit **35/35**. Full check: see below.
