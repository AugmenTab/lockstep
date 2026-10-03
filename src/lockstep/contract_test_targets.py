"""Executable semantics of ``TestSpecification.path`` (11.7-R1).

A Contract ``TestSpecification.path`` identifies one exact repository-relative FILE target
that the Planner test-authoring stage is authorized to create or modify. It is not a
directory, a glob, a runner selector, or a "tests live here" hint; broad existing-suite
health belongs to the configured baseline/verification commands.

This module is the single definition of the structural properties of such a target, shared
by the two points in time that must agree about them:

    before the Contract freezes   :func:`contract_target_findings` (this module, over the
                                  candidate and the repository state it would run against)
    after Planner authoring       :mod:`lockstep.test_authoring` (over the actual result)

A target that does not exist yet is valid: a RED acceptance test is created during test
authoring. Only conditions that make a target structurally impossible, or already known to
be invalid, are findings. The host never rewrites a rejected path; a finding is evidence for
a fresh Planner correction and nothing else.
"""

from __future__ import annotations

from collections.abc import Sequence
from pathlib import Path, PurePosixPath

from lockstep.domain import SubphaseContract

_GLOB_METACHARACTERS = frozenset("*?[")
_FORBIDDEN_PATH_ROOTS = (".git", ".lockstep")

_REQUIREMENT = "TestSpecification.path must identify an exact test-file target"


def target_path_violation(path: str) -> str | None:
    """The structural reason *path* cannot be an exact repository-relative file, or ``None``."""
    if not path or "\x00" in path or "\\" in path:
        return "is not an exact repository-relative path"
    if path.startswith("/"):
        return "is an absolute path"
    if any(character in path for character in _GLOB_METACHARACTERS):
        return "contains glob syntax"

    pure = PurePosixPath(path)
    if pure.as_posix() != path or path == ".":
        return "is not a normalized repository-relative path"

    parts = pure.parts
    if any(part in (".", "..") for part in parts):
        return "contains a '.' or '..' component"
    if parts and parts[0] in _FORBIDDEN_PATH_ROOTS:
        return "is inside a reserved directory"
    return None


def traverses_symlink(root: Path, path: str) -> bool:
    """Is any component of *path* beneath *root* (including the last) a symlink?"""
    current = root
    for part in PurePosixPath(path).parts:
        current = current / part
        if current.is_symlink():
            return True
    return False


def _state_violation(root: Path, path: str) -> str | None:
    """What about the current state of *path* beneath *root* already makes it invalid."""
    if traverses_symlink(root, path):
        return "traverses a symlink"
    current = root
    parts = PurePosixPath(path).parts
    for part in parts[:-1]:
        current = current / part
        if current.exists() and not current.is_dir():
            return "has a parent component that is not a directory"
    target = root / path
    if target.is_dir():
        return "currently resolves to a directory"
    if target.exists() and not target.is_file():
        return "currently resolves to something that is not a regular file"
    return None


def contract_target_findings(contract: SubphaseContract, roots: Sequence[Path]) -> tuple[str, ...]:
    """Deterministic findings for every Contract test target that cannot be executed.

    *roots* are the repository states the Contract's tests would be authored against (the
    source checkout and, for a later Sub-phase, the previous accepted worktree). A missing
    target is never a finding. Each finding names the test's position and path so a fresh
    Planner can correct it without inferring the cause. Pure of Planner output: it reads the
    filesystem only to inspect, and mutates nothing.
    """
    findings: list[str] = []
    for index, spec in enumerate(contract.tests):
        reason = target_path_violation(spec.path)
        if reason is None:
            for root in roots:
                reason = _state_violation(root, spec.path)
                if reason is not None:
                    break
        if reason is not None:
            findings.append(
                f"tests[{index}].path = {spec.path!r} rejected: it {reason}; {_REQUIREMENT}"
            )
    return tuple(findings)


__all__ = ["contract_target_findings", "target_path_violation", "traverses_symlink"]
