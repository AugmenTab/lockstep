# Contract — P4.R3 Third remediation: the final review of C-P4.R2

- Contract ID: `C-P4.R3@v1`
- Status: **FROZEN** (§4)
- Authority: `.local/plans/phase-04_update3.md` (sha256 `97c86589…2da6a12`) §3 (the final P4.R2 review; a
  confirmed HIGH or MEDIUM blocks the live trial and is corrected through a narrow Contract and regression
  test); the review `docs/reviews/phase-4-r2-final-review-2026-10-29.md`.
- Writer: the single writing agent (Implementer, manual). Scope: the review's one MEDIUM (R2F-M1) only.

## 1. The finding, as checked by the writer

R2F-M1 (two engines on one database): the second engine treats a run the first engine is still running as
left unfinished. Confirmed: `settleUnfinished` cannot tell an engine that has gone from one still at work, so
the second engine halts the transaction `uncertain-invocation unfinished-invocation` (a false halt; for a
command, the stage runs again while the first engine's run goes on). Not confirmed: "the settled row is then
overwritten with `answered`". Migration 21's `lockstep_invocation_finish_once` trigger refuses any change to a
finished invocation, so the first engine's finish fails instead. That failure is still wrong (the first
engine's answer is lost and its step errors), and it is fixed by the same decision.

## 2. Decision

| # | Decision |
|---|---|
| R3-O | **A stage belongs to the engine running it.** `advance` takes the transaction's session-level advisory lock (`TransactionStepLock`, namespace 7303, keyed by the transaction id) on a connection of its own (the existing `withSessionLock`, C-C.R1) and holds it for the whole step: reading the row, settling what was left unfinished, the stage and its records. An engine that cannot get the lock within the lock wait (5 s) is refused `busy`: it touches nothing. An engine that goes away (stopped thread, crash, lost connection) loses its session and so the lock; the next engine then settles what it left, exactly as before (E4: a role's run uncertain and never run again by itself, a command's interrupted). |

R2-I (the check under the row lock) stays as a second line. Nothing is migrated.

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/integration/Lockstep/EngineOwnershipTest.hs` | integration: real PostgreSQL, Git, processes | R3-O: engine A's Planner takes 12 s; engine B, on its own connections, advances the same transaction meanwhile and is refused `busy`, records nothing uncertain; A's answer stands (`discovery-answered`, one Planner run, answered, no halt). R3-R: engine A's thread is stopped while its Planner runs; engine B then halts the transaction `uncertain-invocation unfinished-invocation`, one Planner run, uncertain (recovery unchanged) |
| `test/integration/Main.hs` | runner, additive | — |

## 4. Freeze record

- Frozen 2026-10-29 by the single writing agent (Implementer, manual), on `phase-4` after `aba8b33`.
- Frozen files (formatted with `scripts/format`, then hashed):

  | File | sha256 |
  |---|---|
  | `test/integration/Lockstep/EngineOwnershipTest.hs` | `ba66da55eb4f5ec051db2480780704678e899682b8a2cb030a626f70bd0da2a4` |
  | `test/integration/Main.hs` (one group added) | `50f4770981331d84c195b205f7e77de977a09a8f0aa204679221c3defb81a152` |

- Baseline on `aba8b33` (no new names, so no stubs; console output, not kept): **R3-O fails for the finding's
  reason**: engine B answers `Right (Right "role-uncertain")` (it halted the transaction while A's Planner ran)
  instead of `busy`. R3-R passes before and after: it guards that recovery after an engine has gone is unchanged.
- Trial: R3-O and R3-R pass; every C-P4 group **142 of 142** (`.local/p4r3-allp4.log`). A first trial that read
  the transaction only after taking the lock broke the frozen R2-I case (engine B, having waited, advanced the
  next stage instead of `stale-step`); the step now reads the row first and the lock-held check of its revision
  refuses it, as before.

## 4a. Verification record

Checkpoint `d13ac33`: Mac `scripts/check --integration` and Linux clean clone, unit 870/870, integration 571/571
(R3-O, R3-R and the frozen R2-I included). **Status: VERIFIED** at `d13ac33`.

## 5. Allowed paths

Changed: `src/Lockstep/Application/{Engine,Database}.hs`, the test files, `lockstep.cabal`,
`docs/gates/P4.R3/**`, `docs/gates/C-EXEC/**`, `docs/reviews/**`.

## 6. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Rollback: revert the commits; nothing is migrated.
