# P2.4 — verification record (C-P2.4@v1)

- Status: **`VERIFIED — awaiting human acceptance`** at `cc11ea0`. This is the writing agent's
  verification, not an acceptance.
- Recorded by: manual agent session (writing agent / Implementer), 2026-10-19.
- Contract: `contract.md` (FROZEN at `ed10e11`).

## 1. Commits

| Commit | What |
|---|---|
| `ed10e11` | freeze: Contract, three test files (cases, properties, fixtures), runner lines |
| `cc11ea0` | implementation (tested commit): `Lockstep.Kernel.Scheduler` |

## 2. Criteria → evidence

| Criterion | Result | Evidence |
|---|---|---|
| S1 candidates only `pending`/`eligible` | PASSED | "orders in non-candidate states never appear"; property 3 |
| S2 human-only priority, 0–999 | PASSED | "only a human sets a priority", range cases |
| S3 every reason, in order | PASSED | one case per reason; "every reason is reported, in the S3 order"; property 4 (independent oracle) |
| S4 clarification 1 | PASSED | an unsatisfied `before-acceptance` gate never blocks; an excepted `before-execution` gate does not block |
| S5 clarification 3 | PASSED | two queued orders for one repository are both eligible; `claimed`/`active`/`waiting` reserve; `halted`/`completed`/`superseded`/`canceled` do not |
| S6 unknown resources | PASSED | absent and reported-unknown → `resource-unknown` |
| S7 ordering; blocked highest priority excluded | PASSED | tie-break cases; "a blocked highest-priority order is excluded"; property 3 |
| S8 input integrity | PASSED | every duplicate → `conflicting-input` |
| S9 no preemption | PASSED | active orders never appear in the decision |
| S10 commands | PASSED | commands case; property 5 (each command accepted by `stepWorkOrder`) |
| S11 rendering and digest | PASSED | golden rendering; digest = SHA-256 of the rendering; property 1 (replay), property 2 (permutation) |
| Purity | PASSED | `check-kernel-boundary`: scan clean over 11 Kernel files |
| Frozen digests | PASSED | C-P2.4's four files match; C-P1.1–C-P2.3 files unchanged |
| Licenses | PASSED | identical to P2.3 |

## 3. Runs

| Run | Result | Log |
|---|---|---|
| Pre-freeze unit baseline | 35/489 fail, all new; the fixture test passes against the stub | `evidence/prefreeze-unit-baseline.log` |
| First implementation run | 489/489 (one attempt); properties "+++ OK, passed 1000 tests" ×5 | `evidence/first-implementation-unit-run.log` |
| `scripts/check --integration`, clean tree at `cc11ea0` | all 6 steps PASSED; 489 unit, 79 integration | `evidence/check-integration.log` |
| Linux clone at `cc11ea0` | format, lint, build, unit, integration PASSED | `evidence/linux-clone.log` |

## 4. Notes for the owner

- The scheduler is pure and nothing calls it yet; C-P2.5 runs it durably (`scheduleOnce`) and
  makes the claim.
- Phase 2 has no resource kinds; the resource checks are exercised with test names only.
- `Lockstep.Kernel.Scheduler` keeps its own copy of the artifact names (Profile does not export
  them and C-P2.4 left earlier modules unchanged). The compiler checks that it covers every kind.
- The C-P2.4 draft was committed by mistake with the R-P2.3-1 amendment (`c9100c0`). It was frozen
  later, at `ed10e11`.
