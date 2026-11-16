# Contract — P6.11 model-free Gate D qualification (D-01 to D-10)

- Contract ID: `C-P6.11@v1`
- Status: FROZEN (§3). Gate D itself is the owner's to accept; the Implementer accepts nothing.
- Authority: `.local/plans/phase-06_update2.md` §9; `docs/gates/P6-U2/contract.md`.
- D-11 (host isolation) is **BLOCKED**: it needs P6.10c, which needs D6-SEC and the attended M1–M3. Not run.

## 1. What runs

Everything runs through the real architecture: PostgreSQL, the actual scheduler (`dispatchOnce` inside the engine
worker's pass), the actual engineering pipeline, real Git commits and processes, real plan approval and persistence.
The roles are scripted (no model, no provider). D-10's pages are served by the real `lockstep serve` over HTTP.

| Gate | Where (integration) |
|---|---|
| D-01 PRD → DAG; cycle and contradiction refused | `GateDScenariosTest.prdToDag` (Planner drafts through `draftPlansUntil`) |
| D-02 one approval, first unit eligible, no manual queue | `GateDThreeUnitTest.threeUnits` |
| D-03 three genuinely dependent units through the pipeline | `GateDThreeUnitTest.threeUnits` (syllable counter → line scanner that imports it → command line that uses it; each discovery cites a file only its predecessor's commit has; the final checkout's tests and command line are run) |
| D-04 technical acceptance unlocks without Done | `GateDThreeUnitTest.threeUnits` (no Done, no remote, checkout untouched; hand-over after the predecessor's acceptance record) |
| D-05 rejection invalidates descendants; unrelated eligible | `GateDScenariosTest.rejectionScope` |
| D-06 resource, quota, failed-test, Git-basis, uncertain-effect refusals | `GateDScenariosTest.refusals` (not enabled, usage-unknown, busy writer, failing verification never accepted); Git basis: `AuthoritativeBasisTest.missingBasisRefused`; uncertain effect: `StaleAuthorityTest.cancelUncertain`, `UpdateTwoReviewTest.uncertainKept` |
| D-07 restart/crash without duplicate writer or lost decision | `GateDScenariosTest.crashRecovery` |
| D-08 imported Ticket and plan unit share the pipeline | `GateDScenariosTest.sharedPipeline` |
| D-09 clarification, authenticated decision, safe resumption | `GateDScenariosTest.inboxDecision` |
| D-10 UI and Scribe truthful | `GateDPagesTest.pages` (plan, progress, task, decisions pages over HTTP; the summary) |

## 2. The three-unit trace

When `LOCKSTEP_TEST_CASE_DIR` is set (it is in `scripts/check`), `threeUnits` writes its execution trace (fixes,
bases, records, role runs, branch logs, the final tests' and command line's output) to
`.local/gate-d-trace.txt`.

## 3. Freeze record

| File | sha256 |
|---|---|
| `test/integration/Lockstep/GateDThreeUnitTest.hs` | `c616601ced27edebb182e022e0975865070ed73a76801506e4cf27c24cab7e74` |
| `test/integration/Lockstep/GateDScenariosTest.hs` | `4b84b7ba80b979e106330a58eda322d58cf8a4d1725823520351e06a21a7703c` |
| `test/integration/Lockstep/GateDPagesTest.hs` | `e6f8d1890720b6f5d6efc3f137fe3ebb92a2eef5149a1b1b3cfeefdbff98383b` |
| `test/integration/Main.hs` (shared runner) | `fdef0e9b3948edc3fe6c250fc2926fa2ca47311c6689aeedc42f6fec3f01817f` |

These are qualification tests of behaviour already built, so there is no RED stub. **Disclosed:** in the first trial
(`ru2-red-and-gated-trial1.log`, against `4763843`) 7 of 8 passed; the three-unit fixture put its modules in a
`meter/` folder, which the scripted-role runner cannot create (`no-change`). The fixture was made flat
(`syllables.py`, `scan.py`, `meter.py`) and a failure message that names the fixes' refusals was added; then 8 of 8
(`gated-trial3.log` for the three-unit case). No product code changed for Gate D.
