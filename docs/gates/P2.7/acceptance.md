# P2.7 — verification record (C-P2.7@v1)

- Status: **`VERIFIED — awaiting human acceptance`** at `2297cfc`. This is the writing agent's
  verification, not an acceptance.
- Recorded by: manual agent session (writing agent / Implementer), 2026-10-19.
- Contract: `contract.md` (FROZEN at `1730ebd`).

## 1. Commits

| Commit | What |
|---|---|
| `1730ebd` | freeze: Contract, three test files (reconciliation Kernel, lookups, integration with real worker processes), runner lines, baselines |
| `2297cfc` | implementation (tested commit): `Kernel.Reconciliation`, `Effects.Reconciler`, scripted lookups, `Application.Reconciler`, Ledger and Persistence additions, the R9 conclusion change, migration 0010, doc notes |

## 2. Criteria → evidence

| Criterion | Result | Evidence |
|---|---|---|
| R1 lookups: found, absent; malformed, timeout, failure → failed; async propagates | PASSED | Lookup invocation unit cases |
| R2 scripted lookups from the destination's record | PASSED | Scripted lookup unit cases |
| R3/§3 reconciliation table and checks (requirement 3) | PASSED | Unit table: every row for unknown and dispatched intents; integration: found → settled; authoritative not found → not applied and retried under the same operation id; not authoritative, or late application not excluded → still unknown and never re-executed |
| R4 lookup outside the transaction, applied only at the same generation | PASSED | "lookup failures …": generations 2 and 3, one record each; "a dispatched queryable intent is reconciled directly"; refusals write nothing |
| R5 human resolution, bound to the generation (D-4.6, requirement 5) | PASSED | `stale-claim` for generation 0; attest applied; attest not applied with and without a retry left; a retry only with the duplication risk acknowledged, then the same operation id runs again; a second answer → `not-unknown` / `already-settled` |
| R6 attested is not observed (requirement 6) | PASSED | after an attestation, the observations are only the destination's no-answer; the record's basis is `human-attested`; the settled text begins `human-attested: ` |
| R7/§3 late observations (requirement 4) | PASSED | unit late table; integration: a late application after an authoritative negative lookup is blocked (unknown `late-application`), halts the order and is recorded; the abandoned-then-applied conflict halts the order |
| R8 real cross-process contention (requirement 8) | PASSED | two worker processes drain one order: each of 6 intents applied exactly once; two processes recovering one idempotent intent: one applies, one is refused, one application; two recovering one unqueryable intent: unknown once, never re-executed; a stalled process fenced by a reconciliation completes late: its application is recorded as a conflict and the intent stays unknown |
| R9 the C-P2.6 tests still hold | PASSED | all 17 C-P2.6 integration and 28 unit cases pass at `2297cfc` |
| R10 migration 0010, immutable records | PASSED | "resolution records are immutable"; the backup/restore check over the migrated schema |
| R11 no new commands | PASSED | no change under `app/` or `Foundation.Cli` |
| Purity | PASSED | `check-kernel-boundary`: scan clean over 15 Kernel files (now covers `Reconciliation`) |
| Static rules before the freeze | PASSED | §10 of the Contract |
| Frozen digests | PASSED | no test or script file changed since `1730ebd`; C-P1.1–C-P2.6 files unchanged |
| Licenses | PASSED | no dependency change since P2.6 (module names only), so the inventory cannot change; `scripts/licenses` not re-run |

## 3. Runs

| Run | Result | Log |
|---|---|---|
| Pre-freeze unit baseline | 27/579 fail, all new | `evidence/prefreeze-unit-baseline.log` |
| Pre-freeze integration baseline | 13/128 fail at the stub calls; the setup case with a real child process passes; the three C-P2.6-only contention cases pass | `evidence/prefreeze-integration-baseline.log` |
| First implementation runs | 579/579 unit; 127/128 integration | `evidence/first-implementation-unit-run.log`, `evidence/first-implementation-integration-run.log` |
| Second integration run (attempt 2 for one case) | 128/128 | `evidence/second-implementation-integration-run.log` |
| `scripts/check --integration`, clean tree at `2297cfc` | all 6 steps PASSED; 579 unit, 128 integration | `evidence/check-integration.log` |
| Linux clone at `2297cfc` | format, lint, build, unit, integration PASSED; case-sensitive | `evidence/linux-clone.log` |

## 4. Notes for the owner

- One frozen case needed a second attempt: "reconciliation refusals write nothing". My first
  implementation chose the reconciler before checking the effect's class, so a repeatable intent
  gave `no-reconciler` where the test expects `not-queryable`. R4 lists the refusals without
  fixing their order. The frozen test fixes it: the class first, then the reconciler, then the
  Kernel's state checks. The implementation now follows that order. The test is unchanged.
- The worker processes are the integration test binary itself, started with a tasty pattern. The
  shipped binary has no worker command. The test-owned destination tables live only in the
  disposable test database.
- The contention cases assert the invariants: one application per intent, exactly one winner,
  never a re-execution of an unqueryable effect. They do not assert that the two processes
  actually overlapped in time. Overlap is very likely (300 ms per effect, both started together)
  but not proved. The stalled-process case does prove an interleaving, through its fencing
  handshake.
- A reconciliation of an unknown intent does not un-halt its Work Order. A Human requeues it,
  and the integration cases do exactly that before retrying.
