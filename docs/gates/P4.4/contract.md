# Contract — P4.4 The Supervisor's local Git boundary

- Contract ID: `C-P4.4@v1`
- Status: **FROZEN** (2026-10-28; §4)
- Authority: Phase 4 handoff P4.4 ("controlled local worktree/branch creation, basis verification,
  repository identity, path confinement and safe recovery. Test dirty repositories, stale source commits,
  worktree conflicts, branch collisions, symlink/path attacks and ambiguous Git effects. Exit:
  implementation work has a safe, exact, locally verified Git basis"); **DG-17 ACCEPTED** (D-17.2(a): a
  Git-free snapshot for the Implementer; the canonical repository and its `.git` never in an agent's reach;
  the Supervisor checks changed paths, file types and exact revision identity; D-17.3(a) projects folder
  only); DG-03 (repository identity, C-P2.1); C-P4.1 X4 (ownership re-checked: `ownershipHolds`);
  `engine-design.md` §2.
- Writer: the single writing agent (Implementer, manual).
- Scope: Git operations as typed effects. The engine stages that call them (and the ownership re-check
  before each) are P4.8 onward; no push, fetch, remote, merge or checkout ever.

## 1. What P4.4 delivers

The Supervisor's Git: observe a clean basis; create and move the Work Order's branch only by compare and
swap; write the exact tree of a commit into an empty directory without `.git`; find what changed in such a
directory and refuse anything that is not a regular file; and commit changes by the Supervisor's identity
through a private index. The person's working tree, index, `HEAD` and checked-out branches are never
touched (a *worktree* is therefore not needed: the snapshot replaces it, and nothing is checked out).

## 2. Decisions

| # | Decision |
|---|---|
| G1 | **Pure rules** (`Lockstep.Kernel.GitBasis`). Tree paths: relative, 1–4096 characters, no empty, `.` or `..` segment, no `.git` segment in any letter case, no control character or backslash. Modes: `100644`, `100755`, `120000`. Commit ids: 40 lower-case hex. Branch `lockstep/<work order>`. Supervisor identity `Lockstep Supervisor <supervisor@lockstep.invalid>`. |
| G2 | **Basis.** `repository-missing`, `not-a-repository`, `repository-dirty` (any staged, changed or untracked file not ignored; submodules included), `no-commit`; else `HEAD`'s commit and tree. |
| G3 | **Every Git command** runs `git -C <repo>` with the configuration made inert: `core.fsmonitor=false`, `core.hooksPath=/dev/null`, `core.untrackedCache=false`, `commit.gpgSign=false`, `core.autocrlf=false`, `protocol.allow=never`, `core.sshCommand=false`, `credential.helper=` (empty), the C-P2.1 environment (repository-selecting variables removed, `LC_ALL=C`, no prompts), no input, a 60 s limit. The work branch is created with `update-ref <ref> <commit> 0{40}` (only if absent; the same commit again is accepted; elsewhere `branch-exists`; a name Git refuses `branch-invalid`). |
| G4 | **Snapshot.** Into an empty real directory (`snapshot-destination-invalid` otherwise): every blob of the commit's tree from `ls-tree -r -z` and `cat-file`, regular files 0644, executables 0755, symbolic links as links; submodules left out (listed); no `.git`. A tree path failing G1 is `tree-path-invalid`; no path is written through a symbolic link. |
| G5 | **Changes and commits.** `snapshotChanges` walks the directory without following links: changed bytes or executable bit, new and removed regular files, sorted by path; refused: `git-directory` (`.git` in any case, anywhere), `special-file` (a new, changed or removed-and-replaced link, a pipe, socket or device), `path-invalid`, `file-too-large` (> 16 MiB). `checkChanges` (pure, in order): `change-path-invalid`, `change-duplicated`, `change-symlink`, `change-empty`. `commitChanges` uses a private `GIT_INDEX_FILE` in a fresh temporary directory: `read-tree <parent>`, `hash-object -w --no-filters` (the stored id must equal the bytes' blob id, else `blob-mismatch`), `update-index --cacheinfo` / `--force-remove`, `write-tree`, `commit-tree -p <parent>` with the Supervisor's identity as author and committer at the given time; the same inputs give the same commit (so a retry after a crash finds the same commit). `parent-invalid` for a parent that is not a commit. |
| G6 | **Moving the branch** only with `update-ref <ref> <new> <old>`: still at `old` → moved; already at `new` → accepted (a retry); anything else `branch-moved`; a branch checked out in any worktree is never moved (`branch-checked-out`). |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Kernel/GitBasisTest.hs` | unit | G1 paths, modes, ids, names; `checkChanges` and its order |
| `test/integration/Lockstep/GitSupervisorTest.hs` | integration, real Git in disposable repositories | G2 clean basis; dirty (changed, staged, untracked; ignored is fine); missing, plain, unborn; G3 branch once, collision, invalid name, nothing checked out or changed; G4 exact tree with modes and link, no `.git`, no submodule, committed not working content; destination rules and an unknown commit; G5 changes in order; link, `.git`, pipe, link-made-file refused; the commit's identity, parent, tree and message; the person's index, files, `HEAD` and branches unchanged; determinism; invalid change sets refused with no object written; G6 compare-and-swap, retry accepted, moved refused, checked out refused; a configured file-system monitor and hooks path never run |

## 3a. Verification record (after implementation)

| Check | Result | Evidence |
|---|---|---|
| C-P4.4 integration group, targeted | 13 of 13 at the first implementation run | `.local/p44-run1.log` (not committed) |
| `scripts/check --integration` on the Mac, `4f110cd`, clean tree | all six steps PASSED: unit 836 of 836, integration 483 of 483, backup/restore | `check-integration-4f110cd.log` |
| Linux clean clone | at the next checkpoint (after P4.6), per the handoff's "meaningful stable checkpoints" | — |

**Status: IMPLEMENTED, Mac-qualified** at `4f110cd`; Linux clean clone pending at the P4.6 checkpoint.

## 4. Freeze record

Frozen 2026-10-28 by the writing agent (manual), before the Git boundary was implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/GitBasisTest.hs` | `765d204486ce77dc71066b06942b56a62894c6cdaeb47ee659e26cb19c085413` |
| `test/integration/Lockstep/GitSupervisorTest.hs` | `ac055bdf39a8c05f2a868f7229812ebf614b103938b5dd568f5f2759db637031` |
| `test/unit/Main.hs` (runner, additive) | `bc73b4e2197151ab31a2fa0a12a36bdc897ccb29819098639e83a631eb922fa7` |
| `test/integration/Main.hs` (runner, additive) | `4cfae1507051acf8a1ca4e1336cd2dba3a81567c852e964c811928a8038bab18` |

Pre-freeze verification (logs in this directory):

- The pure rules (`Lockstep.Kernel.GitBasis`) were written before the freeze; `Lockstep.Effects.GitSupervisor`
  was a stub refusing `not-implemented` (only the pure `blobId` real). Build (Kernel boundary and purity scan,
  27 files), lint (4 hints fixed first) and format (run last on every frozen file) clean.
- Unit (`prefreeze-unit.log`): 836 of 836, the 5 new cases on the real pure rules.
- Integration baseline against the stub (`prefreeze-integration-baseline.log`): **13 of 13 fail** at the
  first Git call (`not-implemented`), after their fixtures ran (repositories, commits, a submodule).
- Because each case fails at its first call, the later assertions were then exercised once against the
  draft implementation (DG-06 clarification: a defective fixture may be corrected before the freeze, with
  evidence): **13 of 13 passed** (`fixture-trial.log`), so no assertion needed correcting. The stub was put
  back for this freeze commit; the implementation follows in its own commit.

## 5. Allowed paths

New: `src/Lockstep/Kernel/GitBasis.hs`, `src/Lockstep/Effects/GitSupervisor.hs`, the two test files.
Changed: `lockstep.cabal` (generated), the runners (additive), `docs/gates/P4.4/**`,
`docs/gates/C-EXEC/phase-report.md`.

## 6. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Stop on a rule that contradicts DG-17 or DG-03.
Rollback: revert the P4.4 commits; nothing is migrated.
