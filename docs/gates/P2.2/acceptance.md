# P2.2 — verification record (C-P2.2@v1)

- Status: **`VERIFIED — awaiting human acceptance`** at `ed9e160ae6d3e59a03099d38f086c8aedc364425`.
  This record is the writing agent's verification, not an acceptance. The constructor names of §3
  are frozen for Phase 2; the owner's Gate B decision accepts or amends them (PRD §3.2).
- Recorded by: manual agent session (writing agent / Implementer), 2026-10-18.
- Contract: `contract.md` (FROZEN at `6f480c9`).

## 1. Commits

| Commit | What |
|---|---|
| `6f480c9` | freeze: Contract, seven test files, runner, test-only dependency |
| `ed9e160` | implementation (tested commit): `Lockstep.Kernel.{Transition,Evidence,Ticket,WorkOrder,WorkUnitLifecycle,Delivery}` |

## 2. Criteria → evidence

| Criterion | Result | Evidence |
|---|---|---|
| T1 typed principals; Agent never accepted | PASSED | exhaustive tables (Agent column is `agent-assertion` everywhere); "an Agent can never advance any domain"; property "no accepted Agent step" ×4 domains |
| T2 refusal order and codes | PASSED | exhaustive tables over state × input × principal for all four domains; "refusal codes" |
| T3 replay / replayTrace | PASSED | replay tests; property "trace is a chain; refusal leaves state unchanged; replay deterministic" ×4 |
| T4–T7 the §3 tables | PASSED | four exhaustive table tests, plus evidence-refusal cases (`basis-mismatch`, `claim-mismatch`, `kind-forbids`, `attempt-budget-exhausted`, `gates-pending`) |
| T6 uncertain is never passed | PASSED | NotRun/Unknown → Halted `verification-inconclusive`; property "inconclusive never Verified" |
| T8 cross-domain evidence only from the producing lifecycle | PASSED | `AcceptedWorkUnit` / `IntegrationEvidence` / `FrozenContract` exported without constructors (non-record, so no record-update forgery); "accepted evidence exists only for an Accepted Work Unit"; "integration evidence exists only for an Integrated delivery"; end-to-end path to human Done |
| T9 purity | PASSED | `check-kernel-boundary`: scan clean over 9 Kernel modules; Henforcer rows unchanged |
| T10 properties, seeded | PASSED | seed 20261018, "+++ OK, passed 2000 tests" ×4 |
| Frozen digests | PASSED | all 8 C-P2.2 digests and all C-P2.1 digests match at `ed9e160` |

## 3. Runs

| Run | Result | Log |
|---|---|---|
| First implementation unit run | 368/368 (one attempt) | `evidence/first-implementation-unit-run.log` |
| `scripts/check --integration`, clean tree at `ed9e160` | all 6 steps PASSED; 368 unit, 73 integration | `evidence/check-integration.log` |
| Linux clone at `ed9e160` | format, lint, build, unit, integration PASSED | `evidence/linux-clone.log` |
| `scripts/licenses` | identical to P2.1 (the new dependency is test-only) | — |

After the first green run, four hlint hints in the new source were applied: a redundant `fmap`, an
eta reduction, and two hoisted `not`s. Behaviour did not change, and the suite was green again
before the commit.

## 4. Notes for the owner

- P2.2 is pure: nothing is persisted and no effect intents exist yet (P2.5, behind DG-04).
- Work Unit `Halted` is terminal in P2.2. Human-directed recovery from a halt, and the effect
  semantics of halting a running attempt, belong to P2.6/P2.7.
- `Cell`/`decide` in `Lockstep.Kernel.Transition` give the four step functions one shared
  check order. This is an implementation detail; the tests bind only to the step functions.
