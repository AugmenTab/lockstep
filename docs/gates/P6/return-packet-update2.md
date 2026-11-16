# Phase 6 — return packet for update 2 (§12)

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
  freeze → R-U2 remediation (see `git log`). Final revision: FINAL-REVISION.

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
| Final full check, FINAL-REVISION | FINAL-RESULT | `final-full-check.log` |

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

See `docs/gates/P6.11/contract.md`. GATE-D-RESULTS

| Gate | Result |
|---|---|
| D-01 | GD01 |
| D-02 | GD02 |
| D-03 | GD03 |
| D-04 | GD04 |
| D-05 | GD05 |
| D-06 | GD06 |
| D-07 | GD07 |
| D-08 | GD08 |
| D-09 | GD09 |
| D-10 | GD10 (HTTP through the real `lockstep serve`; **no new browser-driven test** — see §16) |
| D-11 | **BLOCKED** (needs P6.10c → D6-SEC → attended M1–M3) |

## 12–13. Three-unit trace; Scheduler, Git and verification records

TRACE

## 14. Adversarial cases (§9.3): expected → observed

| Case | Expected | Test | Observed |
|---|---|---|---|
| Concurrent scheduler claims | one hand-over | `DispatchTest.contenders` | ADV |
| Event replay after settlement | nothing re-dispatched | `DispatchTest.chain` (fresh runtime), `AuthoritativeBasisTest.plannedBasis` | ADV |
| Restart before/after Git commitment | no duplicate, basis kept | `GateDScenariosTest.crashRecovery`; C-P4 `EngineRecoveryTest`, `EngineRecoveryTwoTest` | ADV |
| Blocked high-priority unit | not taken | `DispatchTest.ordering` | ADV |
| Stale Master Plan revision | `stale-plan-revision` | `DispatchTest.staleRevision` | ADV |
| Wrong predecessor Git basis | refused | `AuthoritativeBasisTest.missingBasisRefused`, `legacyAndTypedBases` | ADV |
| Profile mismatch on first planned unit | refused, never a bug fix | `PlanProfileTest.substitutionRefused` | ADV |
| Invalidated ancestor, running descendant | halts, never accepted | `ProvisionalTest.lateRejection` | ADV |
| Obsolete Human Request after invalidation | `request-closed` | `StaleAuthorityTest.rejectionWithdraws` | ADV |
| Unknown provider quota | `usage-unknown` | `DispatchTest.waiting`, `GateDScenariosTest.refusals` | ADV |
| Reviewer incomplete inspection | not accepted | `StabilizationReviewTest.undeclared` (an approval that does not say what it read); unit `ReviewScopeTest` | ADV |
| Frozen-test tampering | refused | C-P4 `protected-test-changed` (`EngineImplementTest`) | ADV |
| Verification failure as completion | never accepted | `GateDScenariosTest.refusals` | ADV |
| Canceled task with live/uncertain fix | stop first / wait | `StaleAuthorityTest.cancel*`, `UpdateTwoReviewTest.uncertainKept` | ADV |
| Human Done inferred from acceptance | never | `GateDThreeUnitTest`, `ProvisionalTest.unlocksWithoutDone` | ADV |
| External publication from a local commit | never | `GateDThreeUnitTest` (no remote, checkout untouched) | ADV |

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
