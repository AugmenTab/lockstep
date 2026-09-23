# Lockstep

Lockstep is a local-first, supervised AI software-development orchestration tool
for a single human developer working with two complementary AI roles: a
**Planner** that handles requirements analysis, decomposition, test authoring,
and review; and an **Implementer** that modifies production code to satisfy
narrowly scoped plans and pre-existing tests. A deterministic control plane —
not the AI agents — owns execution state, Git history, verification policy, and
hard stops.

> **Status:** Under active early development. This repository is currently at
> Phase 0, Sub-phase 0.1 — installable project and CLI scaffold. No planning,
> orchestration, or agent behavior is implemented yet.

## Requirements

- Python `>= 3.12`

## Local install

```bash
python -m pip install -e ".[dev]"
```

## Running tests

```bash
pytest
```
