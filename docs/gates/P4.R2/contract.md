# Contract — P4.R2 Second remediation: the review of C-P4.R1 and P4.17

- Contract ID: `C-P4.R2@v1`
- Status: **FROZEN** (§4)
- Authority: `.local/plans/phase-04_update2.md` (sha256 `c3b2a6fd…6278b8`) §6 steps 9–10 (independent review of
  the remediation, then the packet) and §3/§4 (the invariants: a completed or uncertain invocation is never
  repeated by itself; shutdown bounded without leaving execution orphaned; never remove what may be in use);
  the review `docs/reviews/phase-4-remediation-review-2026-10-28.md`.
- Writer: the single writing agent (Implementer, manual). Scope: the review's MEDIUM and LOW 2–6 only.

## 2. Decisions

| # | Decision |
|---|---|
| R2-W | **Shutdown bounded for real.** `lockstep serve` asks the worker to stop as soon as the shutdown starts (with the dispatcher's stop request), not after Warp returns; at exit it waits at most 5 s, then stops the thread. A container run's cancel on exception is *sent* to the helper, never waited for. The wait for the stopped thread is bounded (2 s). `stopEngineWorkerWithin n` therefore returns within n + 2 s whatever the helper does. |
| R2-I | **One invocation per role, stage and revision, enforced under the row lock**: the insert that records a role run first checks, under `lockTransaction`, that no invocation of that role at that stage and revision exists; if one does, nothing runs (`stale-step`), so a second engine on the same database never runs a role a second time. |
| R2-K | **A workspace that may still be in use is kept**: a stage's workspaces are released only if every run in the stage ended with a known outcome; a run whose outcome is unknown (the runner's `uncertain`, or an exception) keeps them all. Making a tree writable changes a directory only after checking, on the open directory itself, that it is one (no link followed). |
| R2-C | **No case-folding collision in a snapshot on a disk that folds case**: the destination's case behaviour is probed (a file and its upper-case name); there, a tree two of whose paths, or the directories on their way, differ only in letter case is refused before anything is written (`tree-path-collision`). On a case-sensitive disk such a tree is written as it is (C-P4.R1 R-C1's frozen case-sensitive branch). |
| R2-G | **A filter driver name that is not exact UTF-8 is refused** (`repository-filter-unsupported`), so the name passed back is always the configured one. |
| R2-P | **Protected test paths within the host's limits**: at most 1024 bytes and 255 bytes per segment (C-P4.R1 R-P1 otherwise); beyond, the candidate is rejected `test-path-unsupported`. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/integration/Lockstep/EngineRecoveryTwoTest.hs` | integration: real PostgreSQL, Git, processes, the real helper with a `docker` stand-in | R2-W (helper killed outright mid-run: the bounded stop still returns in time, the run unfinished), R2-I (two engines on one database, one role run), R2-K (an unknown outcome keeps the workspace), R2-C (folded directories refused on `LOCKSTEP_TEST_CASE_DIR` when it folds case; written as they are when it does not), R2-G (a non-UTF-8 driver name refused), R2-P (a 300-byte segment rejected before the freeze) |
| `test/integration/Main.hs` | runner, additive | — |

## 4. Freeze record

- Frozen 2026-10-28 by the single writing agent (Implementer, manual), on `phase-4` after `b77bc81`.
- Frozen files (formatted with `scripts/format`, then hashed):

  | File | sha256 |
  |---|---|
  | `test/integration/Lockstep/EngineRecoveryTwoTest.hs` | `c06bd07bb25b73f504512f7ddf17959fc17ed3113d842a89c8af5170f4f4b9e2` |
  | `test/integration/Main.hs` (one group added) | `317996648800ea197828e04b35693251e2c49cf1c6a0ba07c002246a6ef394b5` |

- Baseline on `b77bc81` (no new names, so no stubs): **6 of 6 fail, each for its finding's reason**
  (`.local/p4r2-baseline.log`): the role run twice (2 not 1); the workspace removed after an unknown outcome;
  the folded tree written (`Right 2`); the non-UTF-8 driver's filter run; the long segment halting
  `supervisor-failed` instead of a rejected candidate. R2-W first failed for another reason (a helper stopped
  with SIGTERM reports the run interrupted, so nothing waits); the test was corrected to kill the helper
  outright, and then failed for its own: **the bounded stop took 12.2 s** (`.local/p4r2-baseline-w.log`). R2-C
  was then narrowed to disks that fold case, because a frozen C-P4.R1 case (R-C1, case-sensitive branch)
  requires such a tree to be written there; its baseline ran on a case-sensitive directory, and the old code
  had no fold check at all.
- Trial: **6 of 6 pass** (`.local/p4r2-trial.log`; the stop in 2.7 s); every C-P4 group **140 of 140**
  (`.local/p4r2-allp4.log`; R-C1 and R2-C on the case-insensitive checkout disk); format, lint and static
  checks clean.

## 5. Allowed paths

Changed: `src/Lockstep/Application/{Engine,EngineWorker}.hs`, `src/Lockstep/Effects/{GitSupervisor,Roles,HelperRunner}.hs`,
`src/Lockstep/Kernel/GitBasis.hs`, `app/lockstep/Main.hs`, `src/Lockstep/Web/Server.hs` (the shutdown hook, if
needed), the test files, `lockstep.cabal`, `docs/gates/P4.R2/**`, `docs/gates/C-EXEC/**`, `docs/reviews/**`,
`docs/OPERATOR_GUIDE.md`.

## 6. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Rollback: revert the commits; nothing is migrated.
