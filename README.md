# Lockstep

Lockstep is a local-first, supervised AI software-development orchestration tool
for a single human developer working with two complementary AI roles: a
**Planner** that handles requirements analysis, decomposition, test authoring,
and review; and an **Implementer** that modifies production code to satisfy
narrowly scoped plans and pre-existing tests. A deterministic control plane —
not the AI agents — owns execution state, Git history, verification policy, and
hard stops.

> **Status:** Under active early development. This repository is currently at
> Phase 0, Sub-phase 0.2 — installable project, CLI scaffold, and repository
> quality gates. No planning, orchestration, or agent behavior is implemented
> yet.

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
