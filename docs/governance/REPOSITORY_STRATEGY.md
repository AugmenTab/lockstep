# v2 Repository and Migration Strategy (P0.3 / DG-01b)

- Status: **ACCEPTED: Option A as amended** (human owner, 2026-10-16). A single
  working directory switches branches; there is no second worktree. See
  "Execution record".
- Revision: 0.1 — DRAFT, 2026-10-16
- Traces: FR-APP-01, FR-EXE-07/08; Bible §39, §40 ("V2 repository strategy"), §43

## Facts

| Fact | Evidence |
|---|---|
| Python repo `AugmenTab/lockstep`, `main` at `8b045edb…944cb`, 215 commits, **no tags** | `git rev-parse HEAD`, `git log --oneline \| wc -l`, `git tag` |
| Python repo has **no LICENSE** file and no `license` field in `pyproject.toml` | file inspection |
| Working tree has uncommitted operator edits (`.gitignore` adds `.local-archive/`) and an untracked `.DS_Store` | `git status` |
| Rich local evidence lives in ignored `.local/` and `.local-archive/` in this checkout | `ls` |
| Bible §42 cites `https://github.com/AugmenTab/lockstep` as the reference repository | Bible p.64 |
| Launchpad is designed to be copied into a new project (`scripts/rebrand`, README) | Launchpad README |
| Plan §14.2: a self-hosted supervisor must be isolated from the code it edits | Plan p.24 |

## Options

| | A. Orphan `v2` branch in `AugmenTab/lockstep` | B. Separate repository | C. Same `main`, side-by-side directories |
|---|---|---|---|
| History | Unrelated root, so v2 `git log` never shows Python commits as v2 progress | Fully separate | Python and Haskell interleave on one log |
| Python preservation | `main` untouched; annotated tag `python-v0.1-final` at `8b045edb` | Python repo archived read-only; tag the same | Python is still live on `main`; no clear archive point |
| Ownership / URL continuity | Same repo, issues and URL as the Bible references | New URL; Bible reference becomes "historical" | Same |
| Licensing | v2 license can differ per branch, but one repo with two licenses invites confusion | Clean: v2 gets its own license | Mixed licenses in one tree |
| Tooling / CI | Each branch carries its own toolchain files; CI must key on branch | Clean | Python + Haskell tooling collide (Dockerfile, `.gitignore`, CI) |
| Release / main switch | Later human decision: rename `main`→`python-v0.1`, `v2`→`main` | No switch needed | n/a |
| Operational | One checkout; switch branches (amended, see below) | Separate clone | Single tree |
| Falsification risk | Low (orphan root) | Lowest | **High**: implies migration |

## Recommendation

**Option A: an orphan `v2` branch in `AugmenTab/lockstep`, with the Python
baseline tagged.** Rationale:

- It keeps the product identity and URL that the Bible cites.
- Its unrelated history means no Python commit can be mistaken for v2 progress.
- `main` and all Python history stay byte-identical.

Self-hosting isolation (Plan §14.2) is a concern for the first v2 dogfood, not
for Phase 0.

Choose **Option B** instead if you want v2 to carry a different license or
visibility from the Python repo (see ADR-0001 C2). B is the cleaner choice when
licensing differs. Option C is not recommended.

## Amendment (human owner, 2026-10-16)

"One directory." The separate-worktree element of Option A is dropped. The
`~/personal/lockstep` checkout switches between `main` (Python reference) and `v2`
(Haskell). Ignored `.local/` and `.local-archive/` persist across switches.

## Reproducible procedure

```sh
git tag -a python-v0.1-final 8b045edb4100c4a8e8fe2275f7a7b597a1e944cb \
  -m "Python Lockstep v0.1 behavioral reference; frozen for v2 (P0.3)"
git stash push -m "operator .gitignore edit on main" -- .gitignore   # only if main has that edit
git switch --orphan v2
# to inspect Python later:  git switch main && git stash pop
```

Commits use the repository's history identity via per-command `git -c
user.name=… -c user.email=…`. **Nothing is pushed** without separate explicit
authorization.

## Execution record (2026-10-16)

| Step | Result |
|---|---|
| Tag `python-v0.1-final` | `git rev-parse python-v0.1-final^{commit}` returns `8b045edb4100c4a8e8fe2275f7a7b597a1e944cb` |
| First attempt: worktree at `../lockstep-v2` | Created, then **removed** at the operator's direction: it was outside the agent's working directory and added complexity. No commits were made there. |
| Operator's uncommitted `main` edit to `.gitignore` (adds `.local-archive/`) | Parked in `stash@{0}` ("operator .gitignore edit on main …"). Restore with `git switch main && git stash pop`. |
| `git switch --orphan v2` | Branch `v2` with unrelated history; leftover ignored Python caches (`__pycache__`, `.venv`, …) are covered by the v2 `.gitignore` |
| Python `main` | Unchanged at `8b045ed` |
| Push | **None.** |

The main-branch switch (`main`→`python-v0.1`, `v2`→`main`) remains an open
human decision, to be revisited no earlier than Gate A.
