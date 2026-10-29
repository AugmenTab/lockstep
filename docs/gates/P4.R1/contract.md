# Contract — P4.R1 Recovery and resource-bound remediation of the Phase 4 review

- Contract ID: `C-P4.R1@v1`
- Status: **FROZEN** (§4)
- Authority: `.local/plans/phase-04_update2.md` (sha256 `c3b2a6fd…6278b8`; register entry "Phase 4 recovery and
  completion", 2026-10-28): correct M1–M5 of `docs/reviews/phase-4-review-2026-10-28.md` (blocking), M2 and M3
  first; a bounded disposition of L6–L11. Invariants kept: one writer; the Supervisor alone controls protected
  tests, Git acceptance and commits; a completed or uncertain role invocation is never repeated by itself; every
  retry, invocation, filesystem effect and resource is bounded; human decisions are never inferred.
- Writer: the single writing agent (Implementer, manual).
- Scope: the narrow fixes below. **Not** in scope: the Orville/Fleece clean-up (the existing raw-SQL and
  hand-built-JSON style is kept), new roles, a state-machine redesign, anything of Phase 5.

## 1. Findings and dispositions

| # | Finding (review) | Disposition |
|---|---|---|
| M1 | Freeze: branch moved, step not recorded → `branch-moved` for good | Fix R-F1 |
| M2 | A finished role's answer only in memory until its stage settles → run again by itself after a restart | Fix R-I1–R-I3 |
| M3 | Uncertain invocation and the halt in two database transactions | Fix R-U1, R-U2 |
| M4 | Planner test paths the container runner refuses | Fix R-P1, R-P2 |
| M5 | Snapshot comparison holds the whole tree | Fix R-S1–R-S3 |
| L6 | Worker `done` not always signalled; a stop waits a whole pass | Fix R-W1, R-W2 |
| L7 | Workspaces never removed | Fix R-K1 |
| L8 | `git status` can run configured clean/process filters | Investigated: it can (R-G1 shows it). Fix R-G1 |
| L9 | `writeEntry` checks only the parents for links | Reproduced on this Mac's case-insensitive disk. Fix R-C1, R-C2 |
| L10 | Page mixes attempts; "committed change" before acceptance | Fix R-A1 |
| L11 | One writer per Engineer checked without a lock or index | Fix R-O1 |
| — | Found while reading for M3: `withDatabase` catches *every* exception, so a stopped thread becomes an ordinary database failure and the engine goes on | Fix R-U2 |

## 2. Decisions

| # | Decision |
|---|---|
| R-I1 | **A role's answer is kept with its outcome.** An invocation is recorded with the transaction revision it ran at (`tx_revision`). When a role answers, its answer document — re-read from the output and accepted only if it decodes to exactly the checked answer, at most 256 KiB — is written in the same statement that finishes the invocation (`answer`, `answer_digest`, sha256). An answer that reads back differently finishes the invocation `uncertain answer-unstable`. The finish-once trigger also refuses a change of `tx_revision`. |
| R-I2 | **Before a stage runs its role**, the engine looks for an invocation of that role, at that stage, at the transaction's current revision. Found and finished with a kept answer whose digest matches, for the Planner, the challenger or the Reviewer: that answer is used (a fresh snapshot of the same commit is written for the Supervisor's own checks) and **no role runs**. Found with any other ending: the stage's input is decided from it without running anything — a failure code → `role-failed <code>`; `uncertain <c>` → `uncertain-invocation <c>`; the Implementer's answer, or an answer that is missing or does not match its digest → `uncertain-invocation answer-not-recoverable`. All of these halt for a person (C-P4.6 T2). |
| R-I3 | **The Implementer is never resumed from memory**: its change was a workspace, not an answer, so a lost settle halts `uncertain-invocation answer-not-recoverable`; only a person's `retry` (a new revision) runs it again. Commands and Git steps stay deterministic and simply run again. |
| R-U1 | **Uncertain and halted together**: marking the cut-short invocations (`uncertain` for a role, `interrupted` for a command) and applying the halt are one database transaction under the row lock and the revision check; if any part fails, none is written, the invocation stays unfinished, and nothing runs. |
| R-U2 | **Asynchronous exceptions pass through**: `withDatabase` rethrows an asynchronous exception (a stopped thread, a timeout) instead of reporting it as a database failure. |
| R-F1 | **Freeze, idempotent**: the Supervisor computes the deterministic freeze commit first. Branch at the basis → moved by compare-and-swap; branch already at exactly that commit → the earlier move is recognised and the step is recorded; any other commit → `branch-moved`, as before. |
| R-P1 | **One rule for protected test paths** (`protectedPathValid`, Kernel): a valid tree path (C-P4.4 G1) made only of `A–Z a–z 0–9 . _ + @ - /`. It is the rule of the helper's channel client (`HelperRunner`), and no wider than the helper's own check, so a path the Kernel accepts is one the container runner mounts. |
| R-P2 | **Refused before the freeze**: a candidate whose test path breaks R-P1 is rejected with the candidate as `test-path-unsupported` (the Planner's next candidate, DG-06 D-6.4), before any freeze, Implementer or protected mount. Traversal, absolute, `.git` and linked paths keep their refusals. |
| R-S1 | **Snapshot comparison streams**: each file of the snapshot is compared with its tree entry by its Git blob id, computed while reading in 64 KiB chunks; only a changed file's bytes are kept. Lookups by path are maps, not lists. |
| R-S2 | **Aggregate limits** (`SnapshotLimits`; defaults): at most 100 000 files in a snapshot (`snapshot-too-many-files`); at most 2 GiB written into a workspace (`snapshot-too-large`); at most 1 000 changed paths (`changes-too-many`) and 64 MiB of changed bytes (`changes-too-large`); one file at most 16 MiB (`file-too-large`, as before). Each is a typed refusal before the limit is passed by more than one file. |
| R-S3 | **Measured**: a separate stress suite snapshots and compares a 384 MiB tree inside a 96 MiB heap (`-M96m`); the old comparison needs the whole tree. |
| R-G1 | **No configured filter runs on the person's repository**: before `git status`, every `filter.<driver>` named in the repository's configuration is neutralised for that command (`clean`, `smudge`, `process` empty, `required` false). A file whose raw bytes differ from its blob then shows as a change (`repository-dirty`), never as clean. The module header says exactly this. |
| R-C1 | **A snapshot never writes through a link**: an entry whose target already exists (a case-insensitive disk folding `Foo` onto `foo`) is refused as `tree-path-collision`; files are created exclusively and without following a link. |
| R-C2 | **A test path that folds onto another path** (a basis entry or another test, differing only in letter case) is `test-path-unusable`, before the freeze. |
| R-W1 | **The worker always signals done**, however its thread ends; `stopEngineWorker` never waits on a thread that is gone. |
| R-W2 | **A bounded stop**: `stopEngineWorkerWithin seconds` asks the worker to stop after the current transaction (not the whole pass), waits at most that long, then stops the thread; a role it was running is killed with its process group (direct runner) or cancelled through the helper (container runner), and its invocation stays unfinished, so it is `uncertain` after a restart and never run again by itself. |
| R-K1 | **Workspaces released**: after a stage, every workspace made for it is removed — only a directory directly under the runner's own root, named by 32 hexadecimal characters, not a link. A stage cut short leaves its workspaces (they may be in use). A path outside the root is never removed. |
| R-A1 | **The page tells attempts apart**: what the checks showed, the findings after the change and the review are those of the latest attempt (records after its implementation); earlier attempts are named as such. "Every check passed on the committed change" only once the commit is accepted; before, "on the latest change". |
| R-O1 | **One writer, enforced by the database**: a partial unique index on running and halted transactions per Engineer, and the start takes a transaction-scoped lock for the Engineer before checking, so concurrent starts give one transaction and `engineer-busy`. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/integration/Lockstep/EngineRecoveryTest.hs` | integration: real PostgreSQL (faults injected with a test-only trigger), Git, processes; scripted roles; restarts as new runtimes | R-I1–R-I3 (discovery, candidate baseline, mutant, counterexample, review, implement), R-U1, R-U2, R-F1, R-O1, R-W1, R-W2, R-K1 |
| `test/integration/Lockstep/EngineHelperPathTest.hs` | integration: the real `scripts/control-helper` with `--runner`, and a `docker` stand-in that maps the helper's mounts | R-P1 (the Kernel's rule and the helper's acceptance agree on a table of paths), R-P2, R-C2, a fix accepted through the helper with a protected test path of every allowed character |
| `test/integration/Lockstep/SnapshotBoundsTest.hs` | integration: real Git | R-S1, R-S2, R-G1, R-C1 (on `LOCKSTEP_TEST_CASE_DIR`, the host's case behaviour) |
| `test/integration/Lockstep/EngineAttemptPageTest.hs` | integration: the real service over HTTP | R-A1 |
| `test/stress/Main.hs` (suite `lockstep-stress`, `-M96m`) | stress, run separately (`stack test lockstep:lockstep-stress`) | R-S3 |
| `test/integration/Main.hs` | runner, additive | — |

The baseline is the code as it is (a new name the tests need is added with today's behaviour: the limits
ignored, the path rule `treePathValid`, release a no-op, the bounded stop the old stop): every case must fail for
its finding's reason.

## 4. Freeze record

- Frozen 2026-10-28 by the single writing agent (Implementer, manual), on `phase-4` after `cadd969`.
- Frozen files (formatted with `scripts/format`, then hashed):

  | File | sha256 |
  |---|---|
  | `test/integration/Lockstep/EngineRecoveryTest.hs` | `ae8e3599d8f90c20484f4388444cd17ad74032459bab2ddc9916b4544513c84f` |
  | `test/integration/Lockstep/EngineHelperPathTest.hs` | `2721ce59e22ad1b48dc3b5d32145be670c9271afb0da629e143b85fa131547a8` |
  | `test/integration/Lockstep/SnapshotBoundsTest.hs` | `d0dd1d12a44bf3ad9fbeaf4684af4c8bf06b9b9b0a7482d921ab0b6deabc912a` |
  | `test/integration/Lockstep/EngineAttemptPageTest.hs` | `a9aee50a66b9eb9378b5e300b64a1d39d78503b54cbdf91b8fb01eb53dd14d4d` |
  | `test/stress/Main.hs` | `3acdd54f40c55ac95db906ef3b1cb12bd0d5035c0d3b30949de23fbb2fd270e9` |
  | `scripts/lib/check-runner-paths` (host check, real Docker) | `591e77c16afb21eea20d930da1542296550c0b9a50c1cb5f09519d1c13604a5c` |
  | `test/integration/Main.hs` (shared with C-P4.17: four groups here, two there) | `f1944e1ccea68194f8beb9ef56864f0b00b987c9670b9bee443465a8ca9959ec` |

- Baseline, the code as it was (the new names stubbed with today's behaviour): **22 of 22 fail, each for its
  finding's reason** (`.local/p4r1-baseline.log`; the recovery group again after a fixture correction — an
  idempotency key with a space — `.local/p4r1-baseline2.log`, 13 of 13); the stress suite: **`Heap exhausted`
  at 96 MB** (`.local/p4r1-stress-baseline.log`). The R-O1 race reproduced on its first run (two running
  transactions for one Engineer). The host check is evidence for the real container, not a RED test: the
  helper's own rule did not change.
- Trial against the implementation, before the stubs were put back: **22 of 22 pass** at the first run
  (`.local/p4r1-trial1.log`; R-C1 ran on the case-insensitive checkout disk); stress **pass, 17 MB maximum
  residency** for the 384 MiB tree (`.local/p4r1-stress-measured.log`); host `check-runner-paths` **7 of 7**
  (`.local/p4r1-runner-paths.log`); every C-P4 group **132 of 132** (`.local/p4r1-allp4.log`); format, lint
  and static checks clean.
- One check path added: `scripts/lib/check-source-paths` accepts `test/stress/Main.hs`.

## 5. Allowed paths

Changed: `src/Lockstep/Application/{Engine,EngineWorker,EngineEvidence,Database}.hs`,
`src/Lockstep/Persistence/{Transactions,Migrations}.hs` (one new migration), `src/Lockstep/Effects/{GitSupervisor,Roles,HelperRunner}.hs`,
`src/Lockstep/Kernel/GitBasis.hs`, `src/Lockstep/Web/ExecutionPages.hs`, `package.yaml` (the stress suite),
`lockstep.cabal` (generated), the test files above, `scripts/lib/check-runner-paths` (new),
`scripts/lib/check-source-paths` (the stress suite's path), `docs/gates/P4.R1/**`, `docs/gates/C-EXEC/**`,
`docs/reviews/**`, `docs/governance/DECISION_REGISTER.md`.

## 6. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. A frozen test of an earlier contract that this work
would have to change stops for an amendment request. Rollback: revert the commits; the migration only adds
nullable columns, a trigger function body and an index.
