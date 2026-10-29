# Independent read-only review of the Phase 4 remediation (C-P4.R1) and P4.17 — 2026-10-28

- Requested under `.local/plans/phase-04_update2.md` §6 step 9. Reviewer: one agent (not a person), read-only
  (no edits, builds or state-changing commands), over `cadd969..b77bc81` (the implementation was then in the
  working tree, identical to `b77bc81`), against C-P4.R1, C-P4.17 and the first review.
- Verification by the Implementer: each finding below was checked against the cited code.
- Disposition: the MEDIUM and LOW items 1–6 are remediated by C-P4.R2 (`docs/gates/P4.R2/`); the INFO items
  are recorded with their disposition.

## Result

No HIGH. **One MEDIUM**, six LOW, four INFO. M1–M5 of the first review: fixed as contracted.

| # | Sev. | Where | Defect | Disposition |
|---|---|---|---|---|
| 1 | MEDIUM | `Roles.helperRunner` (cancel on exception), `EngineWorker.stopEngineWorkerWithin`, `app/lockstep/Main.hs` | The bounded stop is not bounded: the worker is told to stop only after Warp returns (graceful shutdown up to 3 s); after the 8 s bound the killed thread's helper cancel waits up to 10 s for the helper's reply; the final wait for the thread has no bound. The service can be SIGKILLed by `docker stop --time 10`. Safety holds (cancel written, invocation unfinished → uncertain) but the claim does not | C-P4.R2 R2-W |
| 2 | LOW | `Engine.invokeRecorded` | The look-up of an earlier invocation is outside the row lock; the insert re-checks only the revision | Two engine workers on one database advancing the same transaction both run the role. C-P4.R2 R2-I |
| 3 | LOW | `Engine.advanceRow` (release), `Roles.releaseUnder`/`writableTree` | A stage that ended normally after a run whose outcome is unknown (`helper-no-result`, `helper-interrupted`, `runner-exception`) has its workspace removed while the helper or container may still use it; `setPermissions` follows a link raced in | C-P4.R2 R2-K |
| 4 | LOW | `GitSupervisor.writeEntry` | Only an entry's own path is checked for a case-folding collision; directories whose names differ only in letter case are merged on a case-insensitive disk | Every Implementer attempt refused on such a basis. C-P4.R2 R2-C |
| 5 | LOW | `GitSupervisor.filtersOff` | Driver names decoded leniently: a non-UTF-8 name is passed back as another name and the real driver runs | C-P4.R2 R2-G |
| 6 | LOW | `Kernel.GitBasis.protectedPathValid` | No segment or total limit within the host's (255 / 1024): such a path halts `supervisor-failed extra-file-unusable` instead of being rejected as `test-path-unsupported` | C-P4.R2 R2-P |
| 7 | LOW | `observeBasis` submodules | Filters named only in a submodule's own configuration are not switched off | Already recorded as a residual (C-P4.R1 L8); unchanged |
| 8 | INFO | `Engine.foldsOnto` | `T.toLower` is not Unicode case folding (`ſ`) | Covered by R2-P (test paths ASCII-only) and R2-C (the snapshot refuses any fold collision) |
| 9 | INFO | migration 21 | The unique index fails to build on a database that already holds two running transactions for one Engineer | Recorded; no such database exists (Phase 4 is not installed); the migration then fails whole and nothing changes, `db migrate` reports it |
| 10 | INFO | `filtersOff` | Git LFS repositories show stat-changed files as `repository-dirty` | By design (raw bytes, never a configured program); stated in the operator guide |
| 11 | INFO | `writeEntry` | The descriptor is not closed if `setFdMode` throws | Fixed in passing (C-P4.R2) |

## Checked and found correct (reviewer)

Role recovery bound to the revision; the Implementer's halt; settleUnfinished all-or-nothing; the freeze's
deterministic commit cannot match another transaction or basis; asynchronous exceptions rethrown; workspace
release only inside the runner's root; streaming comparison exact; exclusive no-follow creation; the path rule
a subset of the helper's; the advisory lock and partial index; the page's attempt scoping; the serve worker
only with a channel; no `error`, `undefined` or partial functions.
