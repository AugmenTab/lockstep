# Independent review: Phase 4, second remediation round (C-P4.R2)

- Reviewer: independent read-only agent (did not write this code; ran no builds or tests)
- Date: 2026-10-29
- Range reviewed: `b77bc81..54966a4` (contract `docs/gates/P4.R2/contract.md`)
- HEAD: `aba8b33`. `git diff --stat 54966a4..aba8b33` touches only `docs/gates/C-EXEC/decision-packet.md` and
  `docs/gates/C-EXEC/phase-report.md` (72+/57-), so no code changed after the candidate `54966a4`.
- Files changed in range: `app/lockstep/Main.hs`, `src/Lockstep/Application/{Engine,EngineWorker}.hs`,
  `src/Lockstep/Effects/{GitSupervisor,HelperRunner,Roles}.hs`, `src/Lockstep/Kernel/GitBasis.hs`,
  `test/integration/Lockstep/EngineRecoveryTwoTest.hs` (new, 430 lines), `test/integration/Main.hs`,
  `lockstep.cabal`, docs.
- Method: I read the diff and the code around it (settle/recover/invoke paths, the worker, the helper client, the
  helper script's runner loop, snapshot writing, the frozen test). I checked each contract claim against the code,
  not against the contract or disposition text. Note: this range has no migration and no new index. The
  one-run-per-role rule rests only on the check under the row lock. `Store.lockEngineer` and the
  `lockstep_transactions_one_writer` index come from earlier rounds and did not change here.

## Summary

| Severity | Count |
|---|---|
| HIGH | 0 |
| MEDIUM | 1 |
| LOW | 3 |
| INFO | 6 |

## Findings

| ID | Sev | Location | Short title | Test covers? |
|---|---|---|---|---|
| R2F-M1 | MEDIUM | `Engine.hs:544-571`, `Engine.hs:815`, `Transactions.hs:369-395` | A second engine settles the first engine's live run as "unfinished". The first engine then overwrites the settled outcome | No (the test's 1 s window hides it) |
| R2F-L1 | LOW | `EngineWorker.hs:127` | `killThread` blocks, so "n + 2 s whatever happens" is not guaranteed | No |
| R2F-L2 | LOW | `GitBasis.hs:106-115` | The fold check uses `T.toLower` with no Unicode normalisation, so directories still merge on APFS/HFS+ | No |
| R2F-L3 | LOW | `GitBasis.hs:96-97` | The 1024-byte limit applies to the relative path, but the host limit applies to the absolute path, so some paths are not refused early | No |
| R2F-I1 | INFO | `Main.hs:270` vs contract R2-W | The contract says 5 s; the code and the guide say 4 s | n/a |
| R2F-I2 | INFO | `Main.hs:295` | `serve` has no role adapter, so the role paths fixed here are not reachable in production yet | n/a |
| R2F-I3 | INFO | `EngineRecoveryTwoTest.hs:366-396` | The R2-C test only checks the fix on a disk that folds case. On Linux CI it is vacuous | partly |
| R2F-I4 | INFO | `EngineRecoveryTwoTest.hs:338-348` | The two-engine test depends on timing (a 1 s prepare delay) | n/a |
| R2F-I5 | INFO | `Engine.hs:459-460` | Workspaces kept after an unknown outcome are never reclaimed | n/a |
| R2F-I6 | INFO | `Roles.hs:185-209` | `writableTree` still walks by path after the `fchmod`. This is harmless only because no writer is left | n/a |

## Details

### R2F-M1 (MEDIUM): with two engines, the second engine halts the first engine's live run as "unfinished", and the settled record is overwritten later

**Claim it breaks:** R2-I is stated for "a second engine on the same database". Its narrow claim (a role never
runs twice) holds. The claims it leans on do not hold with two engines:
- E4 / C-P4.R1 R-U1 (`Engine.hs:538-543`): an invocation "found started but not finished" is one whose outcome is
  unknown, and settling it is final.
- The halt record must say truthfully why the transaction stopped.

**Scenario:**
1. Engine A inserts the Planner invocation under the lock at revision r. It commits and starts the run, which can
   take up to 660 s in a container.
2. Engine B polls 2 s later (`Main.hs:295`, interval 2000). `advanceRow` calls `settleUnfinished` first. It takes
   the row lock. The revision is still r, because A only bumps it when the run ends.
3. B finds A's invocation with `finished_at IS NULL`. It finishes the invocation as `uncertain`, applies
   `RoleUncertain "unfinished-invocation"`, and halts the transaction. A's run is still going.
4. When A's run ends, `finishInvocation` overwrites the settled row. Its only filter is `WHERE id = ...`, with no
   `finished_at IS NULL`. The row now reads `outcome = answered` with a kept answer.
5. A's `applyInput` is refused with `stale-step`.

**Result:**
- The person sees a halt that says the run was not finished. In fact it was live, and later it answered.
- The `uncertain` record names an invocation whose stored outcome is now `answered`.
- The same thing happens with command invocations. B finishes A's live command as `interrupted`, and "the stage
  runs again" (B runs the command while A's is still running; the helper refuses it as `busy`).
- A person who answers "try again" while A's role is still running starts a second run of the role. With the
  direct runner the two runs overlap. With the helper, the second is refused as `busy`.

The `recovered` branch (`Engine.hs:815`, `(Nothing, _, _) -> uncertain "unfinished-invocation"`) does the same
thing if B reaches `invokeRecorded` after A's insert.

**Evidence:**
```haskell
-- Engine.hs:553-571 (settleUnfinished): any unfinished invocation, whoever is running it
invocations <- Store.unfinishedInvocations (Store.txRowId row)
... | otherwise -> do applied <- applyLocked current Supervisor input [(T.pack "uncertain", body)] id
```
```haskell
-- Transactions.hs:371-395 (finishInvocation): no guard on an already-finished row
sql "UPDATE lockstep_invocations SET finished_at = clock_timestamp(), outcome = " ... <> sql " WHERE id = " <> uuid invocationId
```

**Impact:**
- This fails safe: no role runs twice by itself and nothing is lost.
- But two engines on one database halt practically every role step, because a role run outlasts the 2 s poll.
- Settled invocation rows can be rewritten afterwards.

**Test:** `twoEngines` does not cover this. It delays `runnerPrepare` by 1 s, after both engines have already
passed `settleUnfinished` and read `earlier`, so neither engine ever sees the other's unfinished row.

**Fix direction (for the owner):**
- Either refuse a second engine outright (for example an advisory lock held for the worker's lifetime), or record
  an owner/lease on each invocation and settle only expired ones.
- Make `finishInvocation` conditional on `finished_at IS NULL`.

### R2F-L1 (LOW): `stopEngineWorkerWithin` is not strictly bounded, because `killThread` blocks

**Claim it breaks:** R2-W says "`stopEngineWorkerWithin n` therefore returns within n + 2 s whatever the helper
does."

**Evidence:**
```haskell
-- EngineWorker.hs:125-129
Nothing -> do
  killThread (workerThread worker)
  _ <- timeout 2000000 (readMVar (workerDone worker))
```
`killThread` is `throwTo`, and `throwTo` does not return until the exception is delivered.

**Scenario:** The worker cannot take the exception while it is masked or inside a safe foreign call. One example is
a libpq call (Orville over postgresql-libpq; to my knowledge those imports are safe ccalls) waiting on
`SELECT ... FOR UPDATE` in `lockTransaction`, or on `pg_advisory_xact_lock`, behind another session, or on a hung
database. Then `killThread` blocks and the 2 s timeout is never reached. The service overruns the 10 s budget and
`docker stop` SIGKILLs it.

**Impact:**
- Limited. While the worker is blocked in the database it is not running a role or command, so nothing is
  orphaned. The invocation stays unfinished and is settled as uncertain after the restart.
- The fixed path is real: the helper case blocked in `threadDelay` inside `awaitResult`, which is interruptible.

**Test:** Only that interruptible case is covered (`boundedWithoutHelper`).

**Fix direction:** `void (forkIO (killThread t))`, then the bounded wait.

### R2F-L2 (LOW): case-fold check is ASCII-accurate only, so directories still merge on APFS/HFS+

**Claim:** R2-C refuses trees whose paths or parent directories "differ only in letter case". `treePathValid`
allows non-ASCII paths (`GitBasis.hs:72-83`). Two problems follow:
- `pathsFoldTogether` compares `T.toLower` (`GitBasis.hs:110`) and does no Unicode normalisation. macOS APFS (the
  production host for the helper's runner directory, which the service writes through a bind mount) treats both
  case and normalisation as the same name.
- `T.toLower` is not case folding. For example `ς` (U+03C2) does not lower to `σ` (U+03C3), but under Unicode case
  folding they are the same.

**Scenario:** A repository holds `café/a.py` (NFC `é`) and `café/b.py` (NFD).
1. `pathsFoldTogether` returns False.
2. `writeEntry` writes `a.py`. For `b.py`, `createDirectoryIfMissing` finds the existing directory, and `present`
   is false for `b.py`. So both files land in one directory spelled the NFC way.
3. Afterwards, `snapshotChanges` sees `café/b.py` as new and `café/b.py` as removed.
4. A write role's change set then carries a spurious rename. Verification runs on a tree laid out differently from
   the commit.

Collisions at the same file path are still refused by the `present` check (`GitSupervisor.hs:425-429`). Links met
on the way are still refused by `safeParents`, because `lstat` resolves the other spelling. So this is a tree
integrity problem, not an escape.

**Test:** Not covered. The test uses ASCII `Docs`/`docs`.

**Fix direction:** Compare `T.toCaseFold` of NFC-normalised segments, or refuse non-ASCII paths when the disk
folds case.

### R2F-L3 (LOW): path limit is checked on the relative path, while the host limit applies to the absolute path

**Claim:** R2-P says protected test paths are kept "within the host's limits"; beyond them the candidate is rejected
early with `test-path-unsupported`.

**Evidence:**
```haskell
-- GitBasis.hs:96-97
&& T.length path <= 1024
&& L.all ((<= 255) . T.length) (T.splitOn (T.pack "/") path)
```

**Scenario:**
- The helper mounts `$runner_work/<32 hex>/tree/$p` (`control-helper:1210`), and the snapshot is created at that
  host path.
- On macOS, PATH_MAX is 1024 for the whole absolute path, and the prefix takes about 80–120 bytes.
- So a relative path of about 920–1024 bytes, made of short segments, passes `protectedPathValid`. It then fails
  later: on the host it cannot be created (`ENAMETOOLONG`) or the helper refuses it as `protected-invalid`.
- The transaction then halts with `supervisor-failed` or a runner refusal. This is the symptom the baseline showed
  for long segments, and it is not the early rejection the contract promises.

**Impact:** Fails closed (a halt, not a rejected candidate).

**Test:** Not covered. The test uses only one 300-byte segment, which the 255 rule refuses correctly.

### INFO

- **R2F-I1:** Two documents disagree with the code:
  - The contract R2-W says "at exit it waits at most 5 s". The code waits 4 s (`Main.hs:270`), which matches its
    comment and `OPERATOR_GUIDE.md`.
  - The guide says everything fits "inside 10 s". But `stopDispatcher` (`Dispatcher.hs:138-141`) can wait up to
    10 s more after the worker. It was signalled at SIGTERM and normally finishes earlier, but nothing bounds it to
    the remaining budget.
- **R2F-I2:** `serve` builds `Engine (helperRunner c) (\_ _ -> Nothing)` (`Main.hs:295`). Every role step ends
  `no-coding-agent` before an invocation is inserted. The role-run parts of R2-W/R2-I/R2-K matter once a real
  adapter is wired in; today they are exercised only by the tests.
- **R2F-I3:** `foldedTree` checks the fold branch only when `LOCKSTEP_TEST_CASE_DIR` (or the temp directory) folds
  case. On the Linux clean-clone check it runs the case-sensitive branch only. The contract also says the narrowed
  test's baseline ran on a case-sensitive directory, so the fold branch was never shown to fail before the fix.
  From the code, the old code returns `Right 2` on a folding disk, so the test would catch a regression on macOS.
- **R2F-I4:** `twoEngines` relies on both forked engines getting past `settleUnfinished` and the `earlier` read
  within the 1 s `slowPrepare` delay. If a fresh `withRuntime` is slow, the late engine hits R2F-M1 instead and the
  test fails spuriously.
- **R2F-I5:** A workspace kept after an unknown outcome or an exception is never removed later. No reaper exists in
  the service or the helper (`control-helper` never cleans `$runner_work`). This is intended ("never remove what
  may be in use"), but disk grows by up to one snapshot per uncertain run.
- **R2F-I6:** `writableTree` now `fchmod`s through an `O_NOFOLLOW|O_DIRECTORY` descriptor. It still lists and
  recurses by path, so the directory could be swapped for a link between the `fchmod` and `listDirectory`. This is
  harmless here: release happens only after a known outcome, so no process is left that could make the swap, and
  the only effect would be `u+rwx` on the user's own directories.

## Checked and holds

- **R2-W, early stop request:** `serverSettingsWith (... >> traverse_ requestEngineStop worker)` runs in the
  SIGTERM handler (`Server.hs:33-36`). The worker is asked to stop when shutdown begins, so between transactions it
  does not start another.
- **R2-W, cancel not awaited:** `helperRunner` uses `sendCancel` (`Roles.hs:259`), which only places a signed
  request file (`HelperRunner.hs:147-149`). Before, `requestCancel` waited up to 10 s inside the masked handler,
  which explains the 12.2 s baseline. The test kills the helper with SIGKILL, so the old code would fail the
  `< 6 s` check.
- **R2-W, bounded wait after the kill:** `timeout 2000000 (readMVar done)` holds in the interruptible case (but see
  R2F-L1).
- **No orphan after cancellation (helper alive):** the run request is renamed into place before the cancel. The
  helper handles requests oldest first (`ls -1tr`, `control-helper:1346`) and sets `active_run` synchronously
  (`:1330-1332`), so a cancel placed after the run always finds it and `docker kill`s it.
  - The invocation stays unfinished, and on restart `settleUnfinished` marks it uncertain and halts.
  - If the helper is gone, the container is bounded by the helper's watchdog, and a restarted helper removes it
    (`init_runner`, `control-helper:1143-1145`). This is outside what the service can do.
- **R2-I, under the lock:** the check and the insert run in one database transaction after `SELECT ... FOR UPDATE`
  (`Transactions.hs:220`). The isolation level is READ COMMITTED; no override exists in the code base. So the
  re-read after the lock sees a competitor's committed insert. `insertInvocation` for roles exists only at
  `Engine.hs:841`. The test would fail without the check (two inserts; count 2).
- **Recovery of completed invocations:** a kept answer is reused only at the same stage and revision, with the
  outcome `answered`, a matching digest, a re-decoded and checked answer, and not for the Implementer
  (`Engine.hs:800-815`). Nothing in this range changes that.
- **R2-K:** `advanceRow` sets `unknown` when a run returns `RunnerUncertain` or throws (`Engine.hs:450-455`).
  Release is skipped if `unknown` is set (`:459-460`). An exception anywhere in the stage also skips release,
  because `runStage` propagates. Every helper outcome that might leave a container running (`no-result`,
  `interrupted`, `result-invalid`) maps to `RunnerUncertain` (`Roles.hs:262-264`). The test would fail without the
  change (0 directories left, not 1).
- **writableTree:** it no longer follows a link at the top or below; entries are `lstat`ed, and links are skipped,
  not followed. `removePathForcibly` removes links without touching their targets.
- **R2-C on an ASCII fold:** the destination is probed (the probe is removed, and a failed probe counts as folding).
  The fold check over every path prefix runs before anything is written, and the test checks that the directory is
  left empty. On a case-sensitive disk the old behaviour stays (R-C1).
- **writeEntry fd:** `setFdMode`/`fdToHandle` failure now closes the descriptor (`GitSupervisor.hs:439`). The
  exclusive and `nofollow` create is unchanged.
- **R2-G:** `filtersOff` strictly decodes every `filter.`-prefixed key (`decodeUtf8'`) and refuses the repository
  if any key fails (`GitSupervisor.hs:214-218`), so the `-c filter.<name>.*` names passed back are byte-exact.
  Before, a lenient decode produced U+FFFD, the off-switch named a different driver, and the filter ran; the test
  checks the marker file. Dotted subsection names are still handled (`dropWhileEnd (/= '.')`). `core.fsmonitor`
  and `hooksPath` are neutralised elsewhere (`:110-111`).
- **R2-P, order:** `protectedPathValid` (`Engine.hs:1085`) is checked before any test file is written or run.
  `unusablePath` is evaluated earlier but only calls `doesDirectoryExist`, which swallows `ENAMETOOLONG`. The freeze
  (`:1238`) and the helper client (`HelperRunner.hs:119`) use the same rule. The 300-byte segment test would fail
  without the change (it would halt `supervisor-failed`).
