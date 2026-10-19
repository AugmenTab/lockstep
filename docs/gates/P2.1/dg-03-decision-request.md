# DG-03 — decision request: canonical repository identity and exclusive ownership

- Prepared by: the writing agent (Implementer), 2026-10-18. **Nothing here is decided.** The
  human owner decides DG-03 (Decision Register; PRD §11). Status on preparation:
  `EVIDENCE-PREPARED`.
- Basis: `v2` after Gate A acceptance (report r2 `33c8d26a…`, tested commit `6c2851d`). Phase 2
  authorized by the handoff `.local/plans/phase-02.md` (2026-10-18).
- Blocks: the P2.1 Contract (stable identities, canonical repository identity, exclusive
  ownership). No P2.1 test or production code exists.
- Sources: Bible v2.1 §3.2 ("One Engineer MUST own a repository … no competing Implementers over
  a single canonical repository"), the §38 paragraph ("ownership is exclusive by repository
  identity, not only by display name or path spelling"), §40 ("canonical repo identity across
  paths/remotes/worktrees and portable Engineer configuration"); PRD §1.3, FR-WRK-01/02, §11
  DG-03 ("Reject collisions/ambiguity; document portable identity policy"); Plan P2.1 ("same
  repo via alias/worktree rejected"), P5.1 ("alias ownership collides even after restart").

## Evidence (measured on this Mac, Git 2.50.1, macOS 26.6.2, APFS case-insensitive)

Script and output: `evidence/dg03-probe.sh`, `evidence/dg03-probe.log`.

| Spelling of the same repository | `git rev-parse --git-common-dir` | Notes |
|---|---|---|
| `orig`, symlink `link → orig`, case variant `ORIG`, subdirectory `orig/sub` | `$S/orig/.git` (one value) | Git resolves symlinks and on-disk case |
| linked worktree `wt` (`git worktree add`) | `$S/orig/.git` | `--show-toplevel` differs (`$S/wt`) |
| independent clone `clone` | `$S/clone/.git` | **different** common dir; **same** root commit; its `origin` is the local path `$S/orig` |
| shallow clone (`--depth 1`) | `$S/shallow/.git` | `is-shallow true`; its "root" is the shallow boundary, **not** the true root |

- `os.path.realpath('$S/ORIG')` returns `$S/ORIG`: plain path canonicalization does **not** fold
  case on macOS. Two spellings of one directory compare unequal as strings.
- `url.<base>.insteadOf` rewrites `git@GitHub.com:Owner/Repo.git` to
  `https://github.com/Owner/Repo.git`; `git ls-remote --get-url` applies it, the raw config does
  not. The configured host is mixed case.
- The installed service and `scripts/service cli` run in a Linux container that mounts **no
  repository files** (`scripts/service` header). Identity observed in the container and on the
  host would be of different filesystems.

Conclusions the options rely on: the Git common directory collapses aliases, symlinks, case
variants, subdirectories and worktrees of one repository. It does **not** detect a second clone.
Remote URLs and root commits do, imperfectly: remotes can be absent or rewritten; root commits are
shared by forks and template-derived projects and are wrong in shallow clones.

## D-3.1 — What *is* a repository's identity?

| Option | Effect |
|---|---|
| **D-3.1a (recommended)** | An opaque `RepositoryId` issued by Lockstep at registration (generated at the boundary, stored). Paths, remotes and root commits are **observed facts** attached to it, used for matching and collision checks, never as the identity. Moving or renaming a repository does not change its identity; Engineer configuration refers to the `RepositoryId`, which keeps it portable (Bible §40). |
| D-3.1b | Identity derived from a fact (canonical path, normalized remote, or root commit). Simpler, but a move, remote change or history rewrite changes the identity, and each fact has the gaps shown above. |

## D-3.2 — Local ownership key and what may be registered

| Option | Effect |
|---|---|
| **D-3.2a (recommended)** | The local key is the Git common directory (`git rev-parse --path-format=absolute --git-common-dir`, then resolved with `realpath`), compared **case-folded** (fail closed: on a case-sensitive filesystem, two repositories differing only in case are refused, which is rare and safe). Registration must name the **main worktree's top level** of a **non-bare, non-shallow** repository that is not a submodule; a subdirectory, a linked worktree, a bare repository, a shallow clone or a submodule is refused with a typed reason (the refusal names the common directory where known). |
| D-3.2b | As (a), but a subdirectory or linked worktree is accepted and normalized to its common directory. Same safety; less explicit for the operator. |
| D-3.2c | Key by `realpath` of the given directory. Misses worktrees and macOS case variants (measured). Not recommended. |

## D-3.3 — Detecting a second clone of an owned repository (fail closed)

A new registration is compared against every **actively owned** repository.

| Option | Refused as ambiguous when it shares … | Cost |
|---|---|---|
| **D-3.3a (recommended)** | the common directory (D-3.2), **or** any normalized remote URL (D-3.4), **or** any root commit | Forks and Launchpad-template-derived projects that share history are refused while the other is owned. Each false refusal is safe and explicit; an exception would need a later human-authorized mechanism (not built in Phase 2). |
| D-3.3b | the common directory or any normalized remote URL | Accepts forks and template-derived projects. A clone with no remotes, or with a rewritten one, is accepted: two writers over the same history are possible. |
| D-3.3c | the common directory only | A second clone is always accepted. Contradicts "no competing Implementers over a single canonical repository". Not recommended. |

## D-3.4 — Remote URL normalization (applies under D-3.3a/b)

**Recommended:** take every remote's fetch and push URLs after Git's own rewriting
(`git ls-remote --get-url <remote>`, `git remote get-url --all [--push]`). Normalize: drop the
scheme distinction between `ssh://`, scp-style `user@host:path`, `git://`, `http(s)://`; drop
userinfo and default ports; lowercase the host; strip trailing `/` and `.git`; compare the path
**case-folded** (fail closed: GitHub paths are case-insensitive, others may not be). A local-path
or `file://` remote is resolved to its Git common directory and compared as a local key, so a
clone of an owned local repository collides. A URL that cannot be parsed refuses the
registration.

## D-3.5 — Ownership cardinality and duplicates

| Option | Effect |
|---|---|
| **D-3.5a (recommended)** | One active owning Engineer per `RepositoryId` (enforced by a PostgreSQL partial unique constraint as well as by the pure Kernel) **and**, in Phase 2, one Repository per Engineer. A repeated registration of the same repository is **refused** (`AlreadyOwned`, naming the owner, even when it is the same Engineer); nothing changes. |
| D-3.5b | As (a), but an Engineer may own several repositories. The Bible says "one Engineer per repository", not "one repository per Engineer"; (a) is the stricter start and can be relaxed later without a migration of meaning. |

## D-3.6 — Release, relocation and drift (scope boundary)

**Recommended:** in Phase 2 there is no transfer, release or relocation command, and no implicit
one. Ownership survives restarts (durable rows). A repository whose observed facts no longer match
(moved, remotes changed) is **not** re-matched automatically; later phases re-observe before
effectful admission and refuse on drift. Explicit, human-authorized relocation and release belong
to P5.1.

## D-3.7 — Where identity is observed

**Recommended:** the observation (Git common directory, top level, bare/shallow/submodule flags,
remotes, root commits) is taken by a boundary module in the filesystem view where that Engineer
will run Git, and the stored observation records that view. Phase 2 verifies it on disposable Git
fixtures inside one view (the test process, and the installed container for B1). Registering a
**host** repository through the installed container requires a path-preserving repository mount,
which is not built in Phase 2 (P3.2/P5.2 decide it). The pure Kernel receives only validated
observations and existing ownership, and returns a decision or a typed refusal.

## Adversarial cases the P2.1 Contract would freeze (under the recommended options)

1. Same directory registered twice (same and different Engineer) → refused `AlreadyOwned`.
2. Symlink to an owned repository; macOS case variant; trailing slash; `..` segments → refused (same common directory).
3. Linked worktree of an owned repository → refused (linked worktree; same common directory).
4. Subdirectory of an owned repository → refused (not a top level).
5. Independent clone of an owned local repository (origin is its path) → refused (local remote collides).
6. Clone with no remotes but shared root commit → refused (root commit).
7. Same remote in a different URL form (scp vs https, `.git`, case, userinfo, `insteadOf`) → refused.
8. Bare repository, shallow clone, submodule, not a Git repository, unreadable path → refused with distinct typed reasons.
9. Unrelated repository → accepted; second Engineer owning it → refused.
10. Ownership survives a service restart; a concurrent double registration of one repository leaves exactly one owner (database constraint, real PostgreSQL).
11. A Work Unit with `planRef = Nothing` (Ticket-originated) validates.

## Not in DG-03 (Implementer choices in the P2.1 Contract, stated for visibility)

- The other identities (`EngineerId`, `TicketId`, `WorkOrderId`, `WorkUnitId`, `ContractId`,
  `AttemptId`) are distinct newtypes over UUIDs generated at the boundary, so they cannot be
  confused at compile time; Phase 1 ids (receipts, jobs) are unchanged.
- Git is invoked as a subprocess with a fixed argument list, read-only commands, the operator's
  own Git configuration (so `insteadOf` applies), no network access and a timeout; its output is
  parsed into a typed observation.

## Human decision (to be filled in by the owner)

| Field | Value |
|---|---|
| D-3.1 identity | |
| D-3.2 local key / registrable shape | |
| D-3.3 second-clone detection | |
| D-3.4 remote normalization | |
| D-3.5 cardinality / duplicates | |
| D-3.6 release / relocation scope | |
| D-3.7 observation location | |
| Decided by / at | |
