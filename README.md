# Lockstep

Lockstep is a local-first, supervised AI software-development orchestration tool
for a single human developer working with two complementary AI roles: a
**Planner** that handles requirements analysis, decomposition, test authoring,
and review; and an **Implementer** that modifies production code to satisfy
narrowly scoped plans and pre-existing tests. A deterministic control plane —
not the AI agents — owns execution state, Git history, verification policy, and
hard stops.

> **Status:** Under active early development. The core control plane is now
> implemented and internally qualified: domain model, event journal, state
> machine, Git worktree and commit primitives, process runner and environment
> filtering, agent invocation interface, Codex CLI adapter with subscription
> preflight and provider-boundary strict-schema normalization, and a
> single-subphase Supervisor transaction that drives Planner → test-quality →
> RED baseline → test commit → Implementer → verification → Reviewer →
> implementation commit end-to-end. Phase 5, Sub-phase 5.5 is the latest merged
> work; Sub-phase 5.4 has been qualified against a real subscription-backed
> Codex CLI. The public CLI still exposes only `--help` and `--version`; a
> user-facing orchestration command is not yet wired up.

## Requirements

- Python `>= 3.12`

## Local install

Install the project along with its development tooling into your environment:

```bash
python -m pip install -e ".[dev]"
```

## Repository health check

Lockstep exposes a single canonical, non-mutating command that runs every
required quality gate (Ruff format check, Ruff lint, mypy, pytest):

```bash
./scripts/check
```

It exits `0` only when the repository is healthy. It never modifies tracked
files and never installs dependencies.

## Developer repair commands

The health check reports problems but does not fix them. To apply formatting
and lint auto-fixes locally, run the underlying tools directly:

```bash
ruff format .
ruff check --fix .
```

These are developer actions and are intentionally kept out of `./scripts/check`.

## Running tests only

```bash
pytest
```

## Docker

Lockstep ships a reproducible container image that runs the installed CLI as a
non-root user. The image build executes `./scripts/check` internally, so a
successful build implies a green repository.

```bash
docker build -t lockstep:dev .
docker run --rm lockstep:dev --help
docker run --rm lockstep:dev --version
```

No host bind mount is required.
