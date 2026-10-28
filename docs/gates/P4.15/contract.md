# Contract — P4.15 A person's decisions in the coding transaction; the engine worker

- Contract ID: `C-P4.15@v1`
- Status: **FROZEN** (§4)
- Authority: Phase 4 handoff P4.15 ("typed, finite human escalation when genuine ambiguity, missing authority or
  exhausted safe recovery requires it. Bind answers to request identity, principal, Contract and revision. Reject
  stale, replayed, mismatched or unauthorized answers. Persist halt/resume state across restarts, without double
  invocation or uncertain-effect replay. Exit: the engineering transaction can halt and resume safely without
  impersonating the human"); C-P4.3 (requests, binding answers: Human only, revision, once, replay by key);
  C-P4.6 E3/E4 (halts open a request; uncertain never replayed); C-P2.2 T1–T3; Bible: only a person marks work
  done.
- Writer: the single writing agent (Implementer, manual).
- Scope: acting on a person's answer to a halt; the person's Done or not-done after acceptance; the worker that
  starts handed-over bugs and keeps transactions moving. Pages are P4.16; starting the worker in the service is
  P4.17.

## 2. Decisions

| # | Decision |
|---|---|
| H1 | **Resume**: a halted transaction moves only by a person's binding answer (C-P4.3 `HumanDecides`, Human principal only) to **its current halt's** request — the one opened with the key of this transaction and this halt record. `retry` → the halted stage again; `stop` → stopped (keeping the halt's code); `accept-non-reproduction` → the candidate stage, only at `reproduction-missing` (C-P4.6 T1). The input is applied with the Human principal and recorded as `resume` (request id, choice, revision). An answer to any other request — an earlier halt's, replayed or not — never moves it. Without an answer, `advance` leaves it halted. |
| H2 | **Completion**: `decideCompletion txId sender choice`, in this order: an Agent → `agent-assertion`; the Supervisor or a Planner → `not-authorized` (only a person, through the application or the command line); a choice other than `done`/`not-done` → `unknown-choice`; no such transaction → `unknown-transaction`; a transaction that is done or stopped → `closed`; one not yet accepted → `illegal-input`; then `done` → done, `not-done` → stopped "not accepted by a person". Recorded as `completion` (choice, channel, evidence). |
| H3 | **Restart**: nothing a person decided or a halt recorded is held in memory; a new runtime over the same database sees the same halted transaction and request, runs nothing until the answer, and a role whose run was cut short is never run again by itself (C-P4.6 E4). A person's retry runs the stage once more, as a new invocation. |
| W1 | **Worker**: one thread; each pass (every interval) first starts a transaction for each handed-over bug that has none, in hand-over order (an Engineer whose one writer is busy is skipped and tried again next pass), then advances every running or halted transaction once, in start order. One pass at a time; an error in a pass is logged and the next pass runs; an asynchronous exception is never swallowed; `stopEngineWorker` stops it after its pass. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/integration/Lockstep/EngineHumanTest.hs` | integration: real PostgreSQL, Git, processes; scripted roles | H1 a dirty-repository halt waits, then a person's retry (after they clean up) resumes it and the basis proceeds; accept-non-reproduction at reproduction-missing; stop stops for good; the earlier halt's answer, replayed, never resumes the later halt; an agent's, the Supervisor's and the Planner's answers refused; H2 completion's principals, early, unknown, done once, not-done; H3 a crashed role, a restart, still halted with one invocation, a person's retry runs it once more; W1 two handed-over bugs started and taken to acceptance by the worker, which stops cleanly |

## 4. Freeze record

- Frozen 2026-10-28 by the single writing agent (Implementer, manual), on `phase-4` after `a8cb588`.
- Frozen files (formatted with `scripts/format`, then hashed):

  | File | sha256 |
  |---|---|
  | `test/integration/Lockstep/EngineHumanTest.hs` | `55ec4df6b6b467ddd2d8ba3e60cb3bc4e10f30f0c9d9d8f5f59d0600f15ad68c` |
  | `test/integration/Main.hs` (one import, one group added) | `d19d0993f270bbf93fe428b2184ebe271caf0a20d63b42db0b21ba3740f02730` |

- Baseline at `stage-not-built` (the halt never resumes; `decideCompletion` refuses `stage-not-built`; the
  worker starts and advances nothing): **7 of 7 fail**, each for that reason (`.local/p415-baseline.log`).
- Trial against the full implementation, before the stubs were put back: **7 of 7 pass**
  (`.local/p415-trial.log`); lint and static checks clean.

## 5. Allowed paths

New: `src/Lockstep/Application/EngineWorker.hs`, the test file. Changed: `src/Lockstep/Application/Engine.hs`
(resume, completion, active and pending lists), `src/Lockstep/Persistence/Transactions.hs` (two queries),
`lockstep.cabal` (generated), the integration runner (additive), `docs/gates/P4.15/**`,
`docs/gates/C-EXEC/phase-report.md`.

## 6. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Rollback: revert the commits; nothing is migrated.
