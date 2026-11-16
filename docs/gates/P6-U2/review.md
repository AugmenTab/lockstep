# Review — C-U2 (Update 2 R6.1–R6.6, DG-08)

- Reviewed: U2-A `aa28633` (freeze) + `21b39fb`; U2-B `4763843` (freeze) + `159bd3d`, against `contract.md`.
- Reviewer: an independent read-only agent (no edits, builds or tests), 2026-11-15. The Implementer accepts nothing.
- Found sound: `basisCommits` order and planned/standalone rule; `basisStage` never falls back to the checkout with
  candidates, refuses a missing commit, writes provenance atomically; `basisHolds` covers both hand-overs; `admitBug`
  kind/Profile; `recordOnce` withdraws inside the caller's transaction; `withdrawOpenIn` locks and deletes nothing;
  engine precedence (invalidation before cancel, `stopForCancel` atomic); `requestCancel` replay-safe; settlement
  crash recovery; migration 32; floors via `checkStronger`; `usageStanding`/`runEvidence`; proposals Q1/Q2;
  `humanGates`/`gatesRemoved`; `phaseGatesOf`.

## Findings and dispositions (R-U2)

| # | Severity | Finding | Disposition |
|---|---|---|---|
| R-U2-1 | Medium | An invalidation re-halts an uncertain halt with `ancestor-rejected`; a pending cancel then stops the fix by itself, discarding the uncertain outcome (A4). | **Fix:** "uncertain" is read from the records (a `RecordUncertain` after the latest resume), in the engine and in `cancellationOf`. Remediation test. |
| R-U2-2 | Medium | A Planner revision that removes a gate is checked only when proposed; approving it later, after the owner added a gate, removes the gate (G1). | **Fix:** the check runs again at approval of a Planner revision, against the revision then in effect (`human-gate-removed`). Remediation test. |
| R-U2-3 | Medium | A cancel left unsettled (a stale-revision refusal, or a rework handed over first) stays pending and later cancels the task when a newer fix stops. | **Fix:** a cancel whose fix is no longer the task's latest hand-over settles `not-canceled` ("a newer fix was handed over"). Remediation test. |
| R-U2-4 | Medium | The usage standing counts fix runs only, yet says "no helper has run" / "complete" for the project; Planner drafts and clarifications are not counted. | **Fix (narrowed):** the standing and its words are about the fixes' role runs, and the page says Planner drafting and clarification runs are not counted. |
| R-U2-5 | Low | The "Superseded" withdrawal hits every open request about the work order, every pass, also a newer non-halt request. | **Fix:** only the fix's earlier halt requests (key `halt-<tx>-…`) are superseded. Remediation test. |
| R-U2-6 | Low | A request answered and then overtaken by a cancel stays `answered-not-acted`; a legacy request about an invalidated fix is `superseded`. | **Fix (first part):** an answered request of a fix that has stopped, been accepted or Done counts as acted on. **Kept (second):** the newer halt did supersede it; the withdrawal text says so (pinned by `legacyOpenSuperseded`). |
| R-U2-7 | Low | Effective checks resolve specializations against today's catalog, not the bound versions (F2). | **Fix:** the catalog is built from the Work Order's bound sources at their recorded versions. |
| R-U2-8 | Low | A cancel for a hand-over whose start is refused every pass never settles. | **Recorded limitation:** the task waits until its start succeeds or the owner fixes what refuses it; no fix is hidden (the page shows "stopping"). |
| R-U2-9 | Low | (a) `basisCandidates` gives no basis (the checkout) for a missing task row; (b) `runComplete` compares bytes with a leniently decoded tail. | **Fix:** (a) `unknown-task`; (b) complete only when the tail's own SHA-256 equals the recorded stdout digest. |
| R-U2-10 | Low | Tests claim more than they show (one restart; no test for R-U2-1/2/3). | **Fix:** the remediation tests below cover R-U2-1, -2, -3 and -5; the Gate D suite adds restart cases (D-07). |

R-U2-2 note: an older pending revision is already refused `superseded` on approval, so the reviewer's exact
sequence cannot happen; the open path is an owner's gated revision proposed *before* a Planner revision and approved
first. The remediation test uses that path.

## Full check of U2-B

`4763843` (`scripts/check --integration`): all passed — format, lint, build, unit (1110), no-live-model guard,
integration + backup/restore (727). Log `.local/evals/phase-06/u2b-full-check.log`. (The tree was dirty only with
test files written after the build step; the binaries were HEAD's.)

## After remediation

The R-U2 fixes (one commit after the remediation freeze): R-U2-1 `Kernel.Transaction.uncertainOutstanding` used by
the engine and `cancellationOf`; R-U2-2 the gate check at approval in `decidePlan`; R-U2-3 a superseded cancel settles
`not-canceled`; R-U2-4 usage wording; R-U2-5 `withdrawOpenIn` key prefix; R-U2-6 an ended fix's answered request is
resolved; R-U2-7 bound Profile versions; R-U2-9 `unknown-task`, digest-checked tail. Trial
(`.local/evals/phase-06/ru2-trial.log`): R-U2, Gate D, R6, DG-08, C-P6 and R-P6 — **160/160 passed**.

## Remediation tests (frozen RED against `4763843`)

- `test/integration/Lockstep/UpdateTwoReviewTest.hs` `424b39b9ca4b6707f25b395b5a139d85c2f9a8032152b0351d3346caeefcb060`
- `test/integration/Main.hs` (shared runner, additive; also registers the Gate D suite) `fdef0e9b3948edc3fe6c250fc2926fa2ca47311c6689aeedc42f6fec3f01817f`
- RED (`.local/evals/phase-06/ru2-red-and-gated-trial1.log`): **4 of 4 fail**, each at its defect — the uncertain fix is
  stopped by the cancel (R-U2-1); the Planner revision is approved (R-U2-2); no `not-canceled` settlement (R-U2-3);
  the other open request is withdrawn (R-U2-5).
