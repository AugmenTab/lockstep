# P2.1 — verification record (C-P2.1@v1)

- Status: **`VERIFIED — awaiting human acceptance`** at `2eb97c554f35ffbb70a28731edb10a97c69702bb`.
  This record is the writing agent's verification, not an acceptance. P2.1 acceptance and Gate B
  are the human owner's.
- Recorded by: manual agent session (writing agent / Implementer), 2026-10-18.
- Contract: `contract.md` (FROZEN at `cab6f38`). Decision basis: DG-03, ACCEPTED 2026-10-18
  (`dg-03-decision-request.md`).

## 1. Commits

| Commit | What |
|---|---|
| `672ec57` | the owner's DG-03 decision recorded |
| `cab6f38` | freeze: Contract, tests, fixtures, Henforcer rows, `check-kernel-boundary` |
| `2eb97c5` | implementation (tested commit) |

## 2. Criteria → evidence

| Criterion (Contract) | Result | Evidence |
|---|---|---|
| I1 typed identities, boundary generation | PASSED | `IdentityTest` (11 cases); `Application.Identity` v4 UUIDs; distinct newtypes |
| I2 Kernel purity, enforced | PASSED | Henforcer rows; `check-kernel-boundary`: Kernel → `System.Process` and → `Persistence` rejected with `HEN-`, control compiled, scan clean (3 files) — in the build step of both runs below |
| I3 observation: aliases, worktrees, shapes; no case-folding | PASSED | integration "aliases, linked worktrees…" (16 refusals, each with its code and decision row); "case sensitivity" ran **both** branches on this Mac (system temp case-sensitive: `Proj`/`proj` accepted as two; bind mount case-insensitive: `ORIG` refused as an alias) |
| I4/I5 authoritative remote, normalization | PASSED | `RemoteTest` (18 cases); integration: `insteadOf` rewrite, ambiguous, unknown, inconsistent push URL, `ext::`, dangling local remote |
| I6 decision (D-3.3d, D-3.5a) | PASSED | `RepositoryTest` (21 adversarial cases incl. order-independence over all permutations); integration: duplicate clones (local-path origin, https form, `insteadOf`) refused; fork, remote-less shared-ancestry clone and template-derived project **accepted** |
| I7 plan-less Work Unit | PASSED | `WorkUnitTest`: Ticket-originated with `planRef = Nothing` admitted with the owning Engineer |
| I8/I9 persistence, one decision per attempt, lock | PASSED | integration decision-count and consistency checks; 5 concurrent alias rounds → exactly one owner each; backup gate for `0006` |
| I10 CLI | PASSED | `CliRepositoryTest` (16 cases); output lines asserted by the integration suite |
| I11 dependency | PASSED | `scripts/licenses` output **identical** to P1.7 (`process` 1.6.26.1 BSD-3 was already in the library's transitive closure) |
| Frozen digests | PASSED | all 12 C-P2.1 digests match at `2eb97c5`; runner diffs additive (10 + 2 lines, 0 removed) |

## 3. Runs

| Run | Result | Log |
|---|---|---|
| `scripts/check --integration` on the clean tree at `2eb97c5` (Mac, OrbStack) | all 6 steps PASSED; 330 unit, 73 integration; guard sentinel empty; backup/restore ok | `evidence/check-integration.log` |
| Linux clone (fresh `git clone` inside the dev container, case-sensitive `/work`) | format, lint, build, unit, integration PASSED; 330 / 73; both case branches case-sensitive there (as expected) | `evidence/linux-clone.log`, `evidence/linux-clone-run.sh` |
| Pre-freeze baselines | every failure new; P1 tests unaffected | `evidence/prefreeze-*.log` |

Implementation attempts: one. Every frozen test passed at the first full run.

## 4. Deviations (for the owner)

1. **No operator-database run (Contract §6).** Migrating the operator database to `0006` would make
   the installed Gate A binary (`6c2851d`) refuse it as `unknown_applied_migration`, so it would
   also mean replacing the installed service. I left the owner's accepted installation and
   database at schema 5. The installed-service run, with a backup before `0006`, moves to P2.9
   (Gate B requires the actual installed service). The binary's database behaviour, including the
   `0006` backup gate, is covered by the integration suite on real PostgreSQL 17.11.
2. `scripts/check` itself is unchanged. `check-step` defaults `LOCKSTEP_TEST_CASE_DIR` to a
   directory on the bind-mounted checkout (`.local/test-case-dir`, git-ignored). Contract §3 says
   this.

## 5. Known limits carried forward (Contract §9)

SSH host aliases are not resolved. Path case is folded only for GitHub, GitLab and Bitbucket.
Admission uses the last observation and does not detect later drift. Physical identity depends on
stable device numbers. Phase 2 has one filesystem view per installation, and the installed
container cannot register host repositories (D-3.7). Mounting host repositories into it is a
P3.2/P5.2 decision.
