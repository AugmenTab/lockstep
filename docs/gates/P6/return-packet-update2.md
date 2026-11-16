# Phase 6 — return packet for update 2 (§12)

**Summary.** R6.1–R6.6 are implemented, reviewed and qualified, and DG-08 Phase signoff is implemented as you
decided. Gate D D-01–D-10 pass model-free through the real scheduler, engine, Git and PostgreSQL. In the three-unit
demonstration, one approval drove three dependent units to technical acceptance with no person between them. The
final full check passed at `ff314a2`: unit 1110, integration 739, backup/restore. D-11 is BLOCKED. Gate D acceptance
is yours.

- Branch `phase-6` (local; nothing pushed). Writer: the single Implementer. **Nothing here is accepted on the
  owner's behalf; Gate D is not self-accepted.**
- Authority: `.local/plans/phase-06_update2.md`; owner decisions `docs/gates/P6/update2-decisions.md` (A-U2-1,
  OQ-P6.9-1 → A-U2-2, A-U2-3, OQ-P6.9-2, DG-08 Phase signoff = C with B by default).
- No live provider call, no Caesura transaction, no remote push, no privileged host operation, no host probing.
- Date: 2026-11-15/16.

## 1. Baseline and final revisions

- Baseline: `2dd48b2` (update-1 return packet); latest fully tested before update 2: `6b0a6c6` (unit 1078,
  integration 699). Governing documents and DG-08 unchanged (no edits under `docs/` except new records).
- Carried limitations inspected in the code before any change: `docs/gates/P6-U2/contract.md` "Baseline inspection".
  All were still present; the untyped-basis gap was wider than recorded (human-acceptance and external edges too).
- Commits: `21b39fb` (U2-A freeze) → `aa28633` (U2-A) → `159bd3d` (U2-B freeze) → `4763843` (U2-B) → R-U2 and Gate D
  freeze → R-U2 remediation → packet draft. Final tested revision: `ff314a2` (clean tree).

## 2. R6.1–R6.6 status and changed files

| Item | Status | Where |
|---|---|---|
| R6.1 authoritative basis | implemented, qualified | `Kernel/Dispatch.basisCommits`, `Application/Tasks.basisCandidates`, `Execution.basisHolds`, `Engine.basisStage` |
| R6.2 first-unit Profile | implemented, qualified (A-U2-1) | `Execution.admitBug` |
| R6.3 stale requests, cancellation | implemented, qualified; remediated (R-U2-1, -3, -5, -6) | `Invalidations`, `Conversation.withdrawOpenIn`, `Engine`, `Kernel/Inbox`, `Application/Inbox`, `Cancellation`, migration 32, Decisions and task pages |
| R6.4 floors, visibility | implemented, qualified; remediated (R-U2-7) | `Kernel/WorkPolicy.floorStandings`, `Execution.kindRefusal`, `EffectiveChecks`, task page |
| R6.5 usage evidence | implemented, qualified; remediated (R-U2-4, -9) | `Kernel/Summary`, `Application/Summary`, Progress page |
| R6.6 proposals | implemented, qualified (A-U2-2, A-U2-3) | `Application/Proposals`, `Persistence/Transactions.commitRecorded` |
| DG-08 Phase signoff | implemented (C, B by default); remediated (R-U2-2) | `Kernel/PhaseGate`, `Plans.proposeIn`/`decidePlan`, `PhaseGates` |

Decisions and test mapping: `docs/gates/P6-U2/contract.md`. Operator wording: `docs/OPERATOR_GUIDE.md`.

## 3. Regression baseline and final results

| Run | Result | Log |
|---|---|---|
| U2-A full check, `aa28633` | all passed: unit 1084, integration 707, backup/restore | `.local/evals/phase-06/u2a-full-check.log` |
| U2-B full check, `4763843` | all passed: unit 1110, integration 727, backup/restore | `u2b-full-check.log` |
| Final full check, `ff314a2` (clean) | **all passed**: format, lint/static, build, unit **1110**, no-live-model guard, integration **739**, backup/restore | `final-full-check.log` |

The final integration run includes every P6.1–P6.9 suite (backlog, plan/DAG, scheduler, Profiles, invalidation,
Scribe, proposals), the Phase 4 transaction regressions, the Phase 5 checks that run in the integration step, all U2
suites and Gate D. The Phase 5 capsule VM checks (`check-capsule-vm` etc.) were **NOT_RUN**: they need the host's
virtualization and were not touched by update 2.

## 4–9. Evidence per correction

- **Git basis (R6.1):** `AuthoritativeBasisTest` (5 cases) and unit `BasisAuthorityTest` (6): exact predecessor
  commit, never the checkout, also for untyped and human-acceptance edges; a gone commit refuses the hand-over
  (`prerequisite-basis-missing`); restart keeps the basis; busy writer, unrelated repository, standalone work.
- **Greenfield Profile (R6.2):** `PlanProfileTest` (3) and the amended `PlanTest.parity` (A-U2-1).
- **Requests and cancellation (R6.3):** `StaleAuthorityTest` (6), `RequestStandingTest` (8), `UpdateTwoReviewTest`
  R-U2-1/-3/-5.
- **Floors and UI (R6.4):** `ProfileFloorTest` (4), `FloorStrengthTest` (6); task page "Checks this work runs under"
  (also checked over HTTP in D-10).
- **Usage (R6.5):** `UsageEvidenceTest` integration (5) and unit (8); Progress page standing sentence.
- **Proposals (R6.6):** `ProposalIntegrityTest` (3); C-P6.9/R-P6.9 amended cases. Commit evidence is now checked
  against commits recorded by Lockstep's fixes (any project), not against a repository's object store.

## 10. DG-08 Phase signoff disposition

Owner chose **C, with B by default**. A human gate = a human-acceptance edge between units of different phases, part
of the approved digest-bound plan; the scheduler never passes it without the person's Done; other boundaries advance
provisionally; a Planner revision cannot remove a gate when proposed or when approved (`human-gate-removed`); the
owner's own revision may. No `PlanDocument` field was added (it would break frozen fixtures). Tests: `PhaseGateTest`
(unit 4, integration 2), `UpdateTwoReviewTest` R-U2-2. **Open for the owner (narrow):** confirm that expressing a gate
as a cross-phase human-acceptance edge is acceptable, or authorize a plan-document field for explicit gates (would
need frozen-fixture amendments).

## 11. Gate D D-01–D-10

See `docs/gates/P6.11/contract.md`. All results from the final full check at `ff314a2`; model-free; locally qualified,
**owner acceptance pending**.

| Gate | Result |
|---|---|
| D-01 | PASSED (`prdToDag`: valid draft proposed; cycle named and refused; contradiction refused; nothing approved) |
| D-02 | PASSED (`threeUnits`: one approval; `counter` next with no hand-over until the worker's pass) |
| D-03 | PASSED (`threeUnits`: three dependent units, full pipeline each) |
| D-04 | PASSED (`threeUnits`: hand-over after the predecessor's acceptance record; no Done, no remote) |
| D-05 | PASSED (`rejectionScope`) |
| D-06 | PASSED (`refusals`; Git basis and uncertain effect by the U2 cases named in the P6.11 contract) |
| D-07 | PASSED (`crashRecovery`) |
| D-08 | PASSED (`sharedPipeline`: identical record sequences) |
| D-09 | PASSED (`inboxDecision`) |
| D-10 | PASSED over HTTP through the real `lockstep serve` (`pages`); **no new browser-driven test** — see §16 |
| D-11 | **BLOCKED** (needs P6.10c → D6-SEC → attended M1–M3) |

## 12–13. Three-unit trace; Scheduler, Git and verification records

From the final full check (`.local/evals/phase-06/gate-d-trace.txt`): the application `meter` — `syllables.py`
(counter) → `scan.py` (imports it) → `meter.py` (command line through `scan`). One owner approval; 3 hand-overs, all
by the scheduler.

| Unit | Basis | Accepted commit (work branch head) | Records |
|---|---|---|---|
| counter | `57130c5` (repository start, no predecessor) | `c0ace3f` | started, basis, input, discovery, reproduction, candidate, baseline, contract, freeze, implementation, verification, verification-summary, review, acceptance |
| scanner | `c0ace3f` = counter's accepted commit | `4008069` | same |
| cli | `4008069` = scanner's accepted commit | `e9b9906` | same |

Each fix's runs: discovery/Planner, reproduction (command), candidate/Planner, baseline (command), challenge-pre/
Challenger, implement/Implementer, two verification commands, challenge-post/Challenger, review/Reviewer — all
finished. Each branch: `Lockstep: frozen tests` then `Fix: …` on top of the predecessor's commits. Final checkout of
`cli`'s branch: `python3 -m unittest` ran 4 tests, OK; `python3 -m meter poem.txt` printed `line 1: 3 syllables` /
`line 2: 5 syllables`. Nothing is Done; no remote; the person's checkout is unchanged.

## 14. Adversarial cases (§9.3): expected → observed

| Case | Expected | Test | Observed |
|---|---|---|---|
| Concurrent scheduler claims | one hand-over | `DispatchTest.contenders` | as expected (passed at `ff314a2`) |
| Event replay after settlement | nothing re-dispatched | `DispatchTest.chain` (fresh runtime), `AuthoritativeBasisTest.plannedBasis` | as expected (passed at `ff314a2`) |
| Restart before/after Git commitment | no duplicate, basis kept | `GateDScenariosTest.crashRecovery`; C-P4 `EngineRecoveryTest`, `EngineRecoveryTwoTest` | as expected (passed at `ff314a2`) |
| Blocked high-priority unit | not taken | `DispatchTest.ordering` | as expected (passed at `ff314a2`) |
| Stale Master Plan revision | `stale-plan-revision` | `DispatchTest.staleRevision` | as expected (passed at `ff314a2`) |
| Wrong predecessor Git basis | refused | `AuthoritativeBasisTest.missingBasisRefused`, `legacyAndTypedBases` | as expected (passed at `ff314a2`) |
| Profile mismatch on first planned unit | refused, never a bug fix | `PlanProfileTest.substitutionRefused` | as expected (passed at `ff314a2`) |
| Invalidated ancestor, running descendant | halts, never accepted | `ProvisionalTest.lateRejection` | as expected (passed at `ff314a2`) |
| Obsolete Human Request after invalidation | `request-closed` | `StaleAuthorityTest.rejectionWithdraws` | as expected (passed at `ff314a2`) |
| Unknown provider quota | `usage-unknown` | `DispatchTest.waiting`, `GateDScenariosTest.refusals` | as expected (passed at `ff314a2`) |
| Reviewer incomplete inspection | not accepted | `StabilizationReviewTest.undeclared` (an approval that does not say what it read); unit `ReviewScopeTest` | as expected (passed at `ff314a2`) |
| Frozen-test tampering | refused | C-P4 `protected-test-changed` (`EngineImplementTest`) | as expected (passed at `ff314a2`) |
| Verification failure as completion | never accepted | `GateDScenariosTest.refusals` | as expected (passed at `ff314a2`) |
| Canceled task with live/uncertain fix | stop first / wait | `StaleAuthorityTest.cancel*`, `UpdateTwoReviewTest.uncertainKept` | as expected (passed at `ff314a2`) |
| Human Done inferred from acceptance | never | `GateDThreeUnitTest`, `ProvisionalTest.unlocksWithoutDone` | as expected (passed at `ff314a2`) |
| External publication from a local commit | never | `GateDThreeUnitTest` (no remote, checkout untouched) | as expected (passed at `ff314a2`) |

## 15. Independent review

`docs/gates/P6-U2/review.md`: 10 findings (4 Medium, 6 Low), none High. Fixed RED-first: R-U2-1, -2, -3, -5 (tests),
R-U2-4, -6, -7, -9 (code; covered by existing cases). Recorded: R-U2-8 (a cancel for a hand-over whose start is
refused every pass waits), R-U2-6 second part (kept by design).

## 16. Known limitations and remaining human decisions

- **D-10 browser:** the pages are verified over HTTP from the real service; no new Chromium-driven Gate D test was
  written. Existing browser suites still run in the full check.
- R-U2-8 (above). Commit evidence is checked against Lockstep's recorded commits across projects.
- R6.4: `lockstep-engineering` stays off the checks page's choice list (frozen C-P3.7); it is shown on the task page
  and offered on the Plan page.
- R6.5: usage counts the fixes' role runs; Planner drafting and clarification runs are not counted (stated on the page).
- Ticket-done prerequisites without a Lockstep commit refuse a planned unit (`prerequisite-basis-unrecorded`); that
  path is unit-tested only (no app path reaches a done Ticket without delivery).
- Owner decisions still open: Gate D acceptance; the DG-08 representation (§10); D6-SEC after attended M1–M3;
  acceptance of P6.3–P6.10b and update 2.

## 17. Readiness for D-11 and the Caesura dogfood

D-11 stays BLOCKED until P6.10c is proven (D6-SEC, install, negative controls, re-attestation during a run). The
model-free D-01–D-10 qualification shows the scheduler running a dependency-linked plan end to end without a person
pressing Continue. A real Caesura transaction needs a separate authorization (real provider, unattended host
boundary) and was not run.
