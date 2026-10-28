# Phase 4 independent read-only review — 2026-10-28

- Requested by the owner. Reviewer: one agent (not a person), read-only (no edits, builds or state-changing
  commands), over `77a96ce..d59aceb`, against the C-P4.x contracts and `engine-design.md`. The deferred
  Orville/Fleece debt was excluded.
- Verification by the Implementer: findings 1–5 were confirmed by reading the cited code; 6–11 are recorded as
  reported (9 and 11 the reviewer marked PLAUSIBLE).
- **Nothing has been changed.** Remediation waits for the owner.

## Result

No HIGH. **Five MEDIUM**, six LOW, two INFO.

| # | Sev. | Where | Defect | Failure scenario |
|---|---|---|---|---|
| 1 | MEDIUM (confirmed) | `Engine.hs` freeze stage (guard `h == basis`, 1151) | The branch is moved to the freeze commit before the step is recorded; a retry finds it already moved and halts `branch-moved` | Database briefly unavailable or a restart between the move and `settle` → halted for good; every retry halts again; only `stop` ends it. The deterministic freeze commit makes `h == freeze` safe to treat as done |
| 2 | MEDIUM (confirmed) | `Engine.hs` `invokeRecorded` vs. each stage's `settle` | A role run is finished (outcome recorded) before the stage's long work, but its answer is held only in memory until the stage settles | A restart during baselines, mutants or counterexamples → the role (Planner, Challenger, Implementer) is run again by itself; the attempt counters do not rise, so repeated crashes run it without bound — against "never re-runs it by itself" |
| 3 | MEDIUM (confirmed) | `Engine.hs` `settleUnfinished` | Marking a cut-short role run `uncertain` and halting are two database transactions | The second fails (database, restart, stale step) → the run is finished but the transaction still running → the next pass runs the role again by itself |
| 4 | MEDIUM (confirmed) | `Kernel/Roles.hs` test paths (`treePathValid`) vs. `HelperRunner.validProtected` / `control-helper` | A Planner may name a test path (space, non-ASCII, `,`, `=`) the container runner refuses as a protected path | `tests/test bug.py` frozen → every Implementer run in the container is refused → halted at implement for good. (Not reachable with the direct runner used in the tests) |
| 5 | MEDIUM (confirmed) | `GitSupervisor.hs` snapshot walk | Every file (≤ 16 MiB each, no count or total cap) is read into memory before comparing | An Implementer writes ~1000 files of 16 MiB → the service holds ~16 GiB and can be killed; large real repositories are held whole on every implement |
| 6 | LOW | `EngineWorker.hs` | `done` is signalled only on two paths; an exception in `threadDelay` or `logLine` ends the thread without it | `stopEngineWorker` blocks; and a stop waits a whole pass (container roles up to 1260 s each) |
| 7 | LOW | `Roles.hs`, `HelperRunner.hs` | Workspaces (a full tree copy per run) are never removed | Disk use grows without bound |
| 8 | LOW | `GitSupervisor.hs` `observeBasis` | `git status` on the person's repository can run configured clean/process filters | Operator-written configuration only; the module header claims all repository-configured programs are off |
| 9 | LOW (PLAUSIBLE) | `GitSupervisor.hs` `writeEntry` | Only parents are checked for links, not the file itself | Case-insensitive disk with `Foo` → link and `foo` file in the basis; probably prevented by the clean-basis check |
| 10 | LOW | `EngineEvidence.hs`, `ExecutionPages.hs` | The page shows the latest review and all findings regardless of attempt; "Every check passed on the committed change" before acceptance | During attempt 2 the page shows attempt 1's rejection and findings; wording claims a commit not yet accepted |
| 11 | LOW (PLAUSIBLE) | `Engine.hs` `startTransaction` | One writer per Engineer is checked without a lock or unique index | Two concurrent starts (a second worker or instance) could both insert; today only one worker starts transactions |
| — | INFO | — | The worker is not started by `lockstep serve` (deferred by C-P4.15; see the decision packet); the completion form has no key or revision (harmless: a resubmit is `closed`) | — |

## Checked and found correct (reviewer)

A person's answer resumes only its own halt (H1); completion authorization and order (H2); acceptance only of
the exact verified and approved commit; compare-and-swap branch moves; `.git` in any case, special files and
new links refused; hooks and fsmonitor off; answers read with `nofollow`, regular file, capped; process-group
TERM→KILL and capped streams; every new route behind the session and origin; page text escaped; no `error`,
`undefined` or partial functions in new code.
