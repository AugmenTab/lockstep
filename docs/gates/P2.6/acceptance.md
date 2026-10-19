# P2.6 — verification record (C-P2.6@v1)

- Status: **`VERIFIED — awaiting human acceptance`** at `ef2c429`. This is the writing agent's
  verification, not an acceptance.
- Recorded by: manual agent session (writing agent / Implementer), 2026-10-19.
- Contract: `contract.md` (FROZEN at `3f9b693`).

## 1. Commits

| Commit | What |
|---|---|
| `3f9b693` | freeze: Contract, three test files (Kernel recovery, adapters, executor integration), runner lines, baselines |
| `ef2c429` | implementation (tested commit): `Kernel.Recovery`, `Effects.Executor`, `Effects.Scripted`, `Application.Executor`, Ledger and Persistence additions, migration 0009, doc notes |

## 2. Criteria → evidence

| Criterion | Result | Evidence |
|---|---|---|
| X1 typed adapters, exact spec | PASSED | `adapter-mismatch` for the same name with another class; `no-adapter` |
| X2 invocation: one run; timeout, failure, malformed → unknown; async exceptions propagate | PASSED | Invocation unit cases, including the outer-cancellation case |
| X3 scripted destinations; idempotent deduplication by operation id | PASSED | Scripted unit cases; integration "crash after the effect, idempotent": **one** application after recovery |
| X4 executor configuration | PASSED | `invalid-record` for a lease of 0, a timeout not below the lease, an empty owner |
| X5 claim, marker, effect, conclusion; only for an active order | PASSED | "an order that is not active executes nothing, even when it halts after the claim"; "no effect without a marker" holds in every case |
| X6 conclusion: refused observations kept; halts | PASSED | delayed worker (`stale-claim`, `accepted = false`); abandoned mid-flight (`already-settled`, kept); budgets (`retries-exhausted operation=…`); ambiguous answers (`outcome-unknown operation=…`) |
| X7/§3 recovery table | PASSED | every row, budgets and dispatch counts, the lease boundary, the check order (unit) |
| X8 durable recovery, records | PASSED | `redispatch generation=2 owner="w2"` at generation 1; `unknown reason=…`; immutable records |
| X9 crash windows W2–W7 | PASSED | crash before dispatch (reclaim after the lease, applied once); crash after dispatch (redispatch); crash after the effect, by class; D never re-executed |
| X10 selection and the restart pass | PASSED | "restart pass": recover, then execute, then nothing without an adapter |
| X11 faults library-only | PASSED | guard step (d): the binary refuses a fault plan; `ExecutorFaults` not referenced by `app/` |
| X12 migration 0009 | PASSED | the recovery-record case; the backup/restore check over the migrated schema |
| X13 no new commands | PASSED | no change under `app/` or `Foundation.Cli` |
| Purity | PASSED | `check-kernel-boundary`: scan clean over 14 Kernel files (now covers `Recovery`) |
| Static rules before the freeze | PASSED | §10 of the Contract (R-P2.5-1 lesson) |
| Frozen digests | PASSED | no test or script file changed since `3f9b693`; C-P1.1–C-P2.5 files unchanged |
| Licenses | PASSED | no dependency change since P2.5 (the `lockstep.cabal` diff adds module names only), so the inventory cannot change; `scripts/licenses` not re-run |

## 3. Runs

| Run | Result | Log |
|---|---|---|
| Pre-freeze unit baseline | 25/550 fail, all new; the fixtures pass against the stubs | `evidence/prefreeze-unit-baseline.log` |
| Pre-freeze integration baseline | 16/110 fail at the first stub call; the scenario setup case passes | `evidence/prefreeze-integration-baseline.log` |
| First implementation runs | 550/550 unit; 110/110 integration (one attempt) | `evidence/first-implementation-unit-run.log`, `evidence/first-implementation-integration-run.log` |
| `scripts/check --integration`, clean tree at `ef2c429` | all 6 steps PASSED; 550 unit, 110 integration | `evidence/check-integration.log` |
| Linux clone at `ef2c429` | format, lint, build, unit, integration PASSED; case-sensitive | `evidence/linux-clone.log` |

## 4. Notes for the owner

- The first `scripts/check` run, at the first implementation commit `9cf763f`, failed the lint
  step on one hlint hint (infix `elem`). I had not linted before committing. I fixed it and
  amended the commit to `ef2c429`, which was not pushed; the green run above is at `ef2c429`.
- Scripted destinations are in-process stand-ins for external systems. A simulated crash is an
  exception at a fixed point, so the destination survives it as an external system would.
  Real separate processes are C-P2.7.
- A queryable (class C) effect whose dispatch was interrupted becomes `outcome-unknown` until
  C-P2.7 adds a lookup. Requirement 3 then decides when a negative lookup may count as not
  applied.
- Unknown outcomes halt the Work Order. A human resolution path is C-P2.7. Until then,
  `abandonIntent` and a Human `requeue` are the only ways forward, both by a Human.
- Migration 0009 adds one table. The operator database migration (with a backup) is recorded
  with the installed-service run in P2.9.
