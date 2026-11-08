# Contract — P4.7–P4.9 Candidate tests, the challenge before the freeze, and the freeze

- Contract ID: `C-P4.7-9@v1` (one Contract for three sub-phases that share one stage chain)
- Status: **FROZEN** (2026-10-28; §4)
- Authority: Phase 4 handoff P4.7 ("an independent read-only challenger capable of falsifying inadequate
  acceptance tests before freeze … typed dispositions … Prove that deliberately inadequate tests fail the
  adequacy gate even when they are syntactically valid"), P4.8 ("a bounded implementation Contract and
  candidate acceptance tests tied to the Ticket, source basis, effective Profile and authorized paths. Exercise
  fixture setup before freezing. Distinguish a valid expected RED baseline from an invalid test, broken setup,
  missing dependency or unexpectedly green case. Allow governed corrections while candidates remain
  unfrozen"), P4.9 ("Freeze and commit protected test artifacts under Supervisor authority, recording their
  digests, exact commit and allowed future modifications"); **DG-06 ACCEPTED WITH CLARIFICATION** (D-6.1–D-6.6);
  **DG-07 ACCEPTED WITH CLARIFICATION** (D-7.1–D-7.4); DG-17 D-17.9; C-P4.4 (Supervisor commits), C-P4.5
  (roles), C-P4.6 (the transaction); `engine-design.md` §3a.
- Writer: the single writing agent (Implementer, manual).
- Scope: the stages `candidate`, `challenge-pre` and `freeze`. The Implementer and later stages are P4.10
  onward (`stage-not-built` until then). Persistence in the existing style.

## 1. What it delivers

1. **Candidate** (P4.8): the Planner's Contract — criteria grounded in the Ticket and cited in the source,
   allowed implementation paths, verification commands — and candidate tests, each RED or GREEN; checked, then
   run by the Supervisor at the basis and classified.
2. **Challenge** (P4.7): an independent challenger tries to show the tests would accept a wrong fix; the
   Supervisor runs every mutant and demonstration itself and disposes each finding.
3. **Freeze** (P4.9): the Supervisor commits exactly the tests on the work branch and records the Contract,
   its digest and the test digests; from here the tests are protected.

## 2. Decisions

| # | Decision |
|---|---|
| K1 | **Baseline classes** (pure `classifyTest`, D-6.1 as clarified): RED → `red-confirmed` only if it exits non-zero, not 126/127, and its output shows its signature **and** its own name (the file name without directory or extension); exit 0 → `red-unexpectedly-passed`; otherwise `red-wrong-reason`. GREEN → `green-confirmed` on exit 0, else `green-candidate-failed`. Timed out, too much output, held output, cancelled, failed launch → `run-failed`. |
| K2 | **Grounding** (pure `quoteGrounded`, D-6.3): a criterion's quote must appear in the Ticket's title or what done looks like, ignoring case and runs of white space. |
| K3 | **Dispositions** (pure `disposeFinding`, DG-07 as clarified): a mutant whose tests all pass *survives*; `CONFIRMED` only for a survivor whose demonstration fails on it with its signature **and** whose requirement names a criterion of the candidate; a mutant some test fails on is `DISPROVED`; otherwise `NEEDS_HUMAN` if the challenger asked for a person, else `INCONCLUSIVE`. A mutant that changes a path outside the allowed implementation paths is never run (`outside-scope`). |
| K4 | **Kernel additions**: `CandidateRejected code` at `candidate` → another candidate while candidates ≤ 2 (counted), else `candidates-exhausted`; `VerificationInconclusive code` at `candidate` halts with its code. |
| S1 | **Candidate stage**: the Planner (read-only) on the basis; context: Ticket, basis, discovery, reproduction record, earlier baseline/finding/rejection records (its feedback). Before anything runs, `CandidateRejected`: `criterion-not-grounded`, `citation-outside-source` (criteria citations at the basis), `test-path-unusable` (a test path that is a link or a directory at the basis). Then each test runs, by the Supervisor, on a fresh snapshot of the basis with all candidate tests added (command limits, verification profile), recorded as an invocation; classified by K1. A run that cannot start its program (exit 127, or the direct runner's `executable-missing`) → `verification-environment-missing` (halt, D-17.9). A GREEN test the basis already holds with the same bytes that fails → `green-regression-failed` (halt: a genuine pre-existing failure). Otherwise `CandidateClassified` (the Kernel's correction rule). Records: `candidate` (its answer form), `baseline` per test, `candidate-rejected`. |
| S2 | **Challenge stage**: the challenger (read-only) on the basis with the candidate tests; context: Ticket, basis, the candidate Contract and tests, discovery, reproduction record — no Planner or Implementer transcript. For each finding the Supervisor builds a fresh snapshot of the basis + tests + mutant, runs every candidate test, then the demonstration if the mutant survived; K3 disposes. Records `finding` (requirement, claim, grounded, what the mutant did, disposition). `ChallengeDisposed`: `CONFIRMED` → another candidate (budget), `NEEDS_HUMAN` → halted with a decision request, else → freeze. |
| S3 | **Freeze stage**: the work branch must still be at the basis (`supervisor-failed branch-moved` otherwise); the Supervisor commits exactly the candidate tests on top of the basis (C-P4.4, its identity, at the basis's commit time + 1 s, so a retry makes the same commit), moves the branch by compare-and-swap, and records `contract` (basis, freeze commit, criteria, allowed paths, verification, each test's path, SHA-256 and command) and `freeze` (commit, branch, the Contract's SHA-256), and the transaction's freeze commit and Contract digest. The person's checkout is untouched. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Kernel/CandidateTest.hs` | unit | K1 names, RED, GREEN, run failures; K2; K3 every combination; K4 rejections and the environment halt |
| `test/integration/Lockstep/EngineCandidateTest.hs` | integration: real PostgreSQL, Git, processes; scripted Planner and challenger | a grounded candidate reaches the challenge (red-confirmed); ungrounded and out-of-source candidates go back; red-unexpectedly-passed, red-wrong-reason, a failing new GREEN, then candidates-exhausted with a request; an existing failing GREEN halts green-regression-failed; a missing test program halts verification-environment-missing; a special-case mutant that passes the tests and still shows the bug is CONFIRMED and sends the candidate back; killed, ungrounded, out-of-scope and mutant-less findings are not CONFIRMED and the freeze follows; NEEDS_HUMAN blocks with a request; the freeze commit (Supervisor, parent the basis, exactly the test file and its bytes), the Contract with the commit and the test's digest, the freeze record with the Contract's digest, the person's checkout untouched; a moved work branch is never frozen over |

## 3a. Verification record (after implementation)

| Check | Result | Evidence |
|---|---|---|
| C-P4.7-9 integration group, targeted | 10 of 10; build and lint clean | `.local/p47-run1.log` (not committed) |
| Full Mac and Linux qualification | at the next checkpoint (after P4.10–14) | — |

## 4. Freeze record

Frozen 2026-10-28 by the writing agent (manual), before the stages were wired into the engine.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/CandidateTest.hs` | `6c279b2b7e34c12a7814760a0bec090c9daaf9a67d792d1389d16c75931deea6` |
| `test/integration/Lockstep/EngineCandidateTest.hs` | `ea8e433d61740cf8f02157773624ab4eabff8c7d0a03c7a65d737d739267bd98` |
| `test/unit/Main.hs` (runner, additive) | `98d00fecfb2d7bd511acea8bcf9e796b76129e2adcf732cad6241637aa1a1b12` |
| `test/integration/Main.hs` (runner, additive) | `d06c0150ca69555f659fc4fdb528aa136b640a4e3dfa3f76c1b00b1119077080` |

Pre-freeze verification (logs in this directory):

- Written before the freeze: the rules (`Lockstep.Kernel.Candidate`, K4 in `Lockstep.Kernel.Transaction`), the
  stages' documents (`Lockstep.Application.EngineCandidate`), `commitTime`, `JRaw`. The engine was the P4.6
  engine (the three stages `stage-not-built`). Build, format and lint clean (3 hints fixed).
- Unit (`prefreeze-unit.log`): 862 of 862.
- Integration baseline (`prefreeze-integration-baseline.log`): **10 of 10 fail** at the candidate stage
  (`stage-not-built`), after basis, discovery and reproduction ran for real.
- Fixture trial against the full stages (`fixture-trial.log`): **10 of 10 passed** at the first run (no
  assertion needed correcting); the frozen C-P4.6 group still 10 of 10 against the changed engine
  (`p46-regression.log`). The P4.6 engine was put back for this freeze commit.

## 5. Allowed paths

New: `src/Lockstep/Kernel/Candidate.hs`, `src/Lockstep/Application/EngineCandidate.hs` (the stages' documents),
the two test files. Changed: `src/Lockstep/Kernel/Transaction.hs` (K4), `src/Lockstep/Application/Engine.hs`
(the three stages, a recorded command run, extra files in a workspace), `src/Lockstep/Effects/GitSupervisor.hs`
(`commitTime`), `src/Lockstep/Foundation/Json.hs` (`JRaw`: a document rendered earlier, kept as it is),
`lockstep.cabal` (generated), the runners (additive), `docs/gates/P4.7-9/**`,
`docs/gates/C-EXEC/phase-report.md`.

## 6. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Rollback: revert the commits; nothing is migrated.
