# P2.5 — verification record (C-P2.5@v1)

- Status: **`VERIFIED — awaiting human acceptance`** at `837ddbc`. This is the writing agent's
  verification, not an acceptance.
- Recorded by: manual agent session (writing agent / Implementer), 2026-10-19.
- Contract: `contract.md` (FROZEN at `5f2d1e2`; amendment R-P2.5-1 approved by the owner and
  recorded in §10.1).

## 1. Commits

| Commit | What |
|---|---|
| `5f2d1e2` | freeze: Contract, four test files (Effect, EventCodec, Ledger, Support.Ledger), runner lines |
| `d8fa98b` | implementation: `Kernel.Effect`, `Kernel.EventCodec`, `Persistence.Ledger`, `Application.Ledger`, migration 0008 |
| `0e7535e` | R-P2.5-1 requested (the frozen purity scan refuses the frozen code `unsafe-retry-budget`) |
| `837ddbc` | R-P2.5-1 applied as approved (tested commit): two `EffectTest` literals, the Kernel string, C-P2.5 E1/§7/§10.1 |

## 2. Criteria → evidence

| Criterion | Result | Evidence |
|---|---|---|
| E1 effect classes, terms, budgets | PASSED | Specs cases; D with budget 1 → `retry-budget-forbidden` |
| E2 stable intent identity | PASSED | Identity cases; atomicity: a repeated decision → `stale-revision`, still two intents |
| E3 lifecycle table (§3) | PASSED | every (state, input) cell, including the lease boundary (equal is expired) |
| E4 fencing | PASSED | unit Fencing cases; integration: reclaim → generation 2, old generation's dispatch and observation → `stale-claim`, the observation stored with `accepted = false` |
| E5 dispatch marker before any effect | PASSED | lifecycle cells; `dispatched` committed and counted by `dispatchIntent` |
| E6 observations; no-answer → unknown | PASSED | Observations cases; integration no-answer → `outcome-unknown` blocks claim and settle; abandon ends it |
| E7 retry budget | PASSED | unit and integration budget-1 sequences → `retries-exhausted`; budget 0 never reclaimable |
| E8 settlement | PASSED | lifecycle cells |
| E9–E11 durable subjects, codec, one transaction | PASSED | Codec round-trips; Atomicity: faults after the event and after the intents leave neither; Replay integrity: SQL-changed projection and tampered Profile source → `LedgerIntegrity` |
| E12–E14 Tickets, Work Orders, gate evidence | PASSED | Tickets and Work Order creation cases, each E13 refusal |
| E15 scheduling run | PASSED | Scheduling cases: claim with generation 1, stored digest = SHA-256 of the stored rendering, `prerequisite-blocked`, generation 2 after halt and requeue, `source-stale` |
| E16 Work Unit admission | PASSED | Work Units cases |
| E17 intent operations, contention | PASSED | two threads claiming one intent: exactly one wins, the other `claim-held` |
| E18 migration 0008, immutability | PASSED | Immutability: UPDATE and DELETE fail with the trigger's own message on every append-only table |
| E19 no effects, no new commands | PASSED | no binary command added; "earlier commands are unchanged" still passes |
| Purity | PASSED | `check-kernel-boundary`: scan clean over 13 Kernel files (now covers `Effect` and `EventCodec`) |
| Frozen digests | PASSED | C-P2.5's files match §10 and §10.1 (`EffectTest` `4ccf32bd…`); no test or script file changed since `5f2d1e2` other than the approved amendment; C-P1.1–C-P2.4 files unchanged |
| Licenses | PASSED | no `build-depends` change since P2.4 (the `lockstep.cabal` diff adds module names only), so the inventory cannot change; `scripts/licenses` not re-run |

## 3. Runs

| Run | Result | Log |
|---|---|---|
| Pre-freeze unit baseline | 27/522 fail, all new; fixture tests pass against the stubs | `evidence/prefreeze-unit-baseline.log` |
| Pre-freeze integration baseline | 13/14 fail at the stub's first ledger call; the scenario setup case passes | `evidence/prefreeze-integration-baseline.log` |
| First implementation runs | 522/522 unit; 93/93 integration | `evidence/first-implementation-unit-run.log`, `evidence/first-implementation-integration-run.log` |
| `scripts/check --integration` at `d8fa98b` (unamended) | build FAILED at the purity scan (`"unsafe-retry-budget"`) | `evidence/check-integration-unamended.log` |
| Trial with the proposed amendment (restored afterwards) | all 6 steps PASSED | `evidence/check-integration-with-proposed-amendment.log` |
| `scripts/check --integration`, clean tree at `837ddbc` | all 6 steps PASSED; 522 unit, 93 integration; backup/restore round trip | `evidence/check-integration.log` |
| Linux clone at `837ddbc` | format, lint, build, unit, integration PASSED; case-sensitive | `evidence/linux-clone.log` |

## 4. Notes for the owner

- Nothing executes an effect yet. C-P2.6 adds the dispatcher, the scripted adapters and restart
  recovery; C-P2.7 adds class-specific reconciliation and human resolution.
- Migration 0008 adds tables only. Operators take a backup before migrating (ADR-0002); the
  Gate B packet (P2.9) records that run on the installed service.
- The constructor is still named `UnsafeRetryBudget`. Only its rendered code changed, as the
  amendment specified.
