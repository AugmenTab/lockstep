"""Supervisor-owned creation of isolated run worktrees.

Turns a clean, attached source checkout into a new linked Git worktree
on a new run-specific branch rooted at the exact HEAD observed during
precondition inspection. Deterministic policy failures raise
``WorktreeCreationError``; underlying Git-command failures raise the
existing ``GitCommandError``.
"""

from __future__ import annotations

import subprocess
from collections.abc import Sequence
from pathlib import Path

from lockstep.git.repository import (
    GitCommandError,
    GitRepositorySnapshot,
    inspect_repository,
    require_clean_repository,
)


class WorktreeCreationError(Exception):
    """A deterministic precondition for run worktree creation failed."""

    def __init__(
        self,
        *,
        source_root: Path,
        worktree_path: Path,
        branch: str,
        reason: str,
    ) -> None:
        self.source_root = source_root
        self.worktree_path = worktree_path
        self.branch = branch
        self.reason = reason
        super().__init__(
            f"cannot create Lockstep run worktree at {worktree_path} "
            f"on branch {branch!r} from source {source_root}: {reason}"
        )


def _run_git(
    path: Path,
    args: Sequence[str],
    *,
    check: bool,
) -> subprocess.CompletedProcess[str]:
    argv = ["git", "-C", str(path), *args]
    try:
        result = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            stdin=subprocess.DEVNULL,
            check=False,
            shell=False,
        )
    except OSError as exc:
        raise GitCommandError(
            path=path.resolve(),
            git_args=tuple(args),
            reason=str(exc),
            returncode=None,
        ) from exc

    if check and result.returncode != 0:
        raise GitCommandError(
            path=path.resolve(),
            git_args=tuple(args),
            reason=result.stderr.strip() or f"git exited with {result.returncode}",
            returncode=result.returncode,
        )
    return result


def _validate_branch_name(source_root: Path, branch: str) -> None:
    _run_git(
        source_root,
        ("check-ref-format", "--branch", branch),
        check=True,
    )


def _branch_exists(source_root: Path, branch: str) -> bool:
    args = ("show-ref", "--verify", "--quiet", f"refs/heads/{branch}")
    result = _run_git(source_root, args, check=False)
    if result.returncode == 0:
        return True
    if result.returncode == 1:
        return False
    raise GitCommandError(
        path=source_root.resolve(),
        git_args=args,
        reason=result.stderr.strip() or f"git exited with {result.returncode}",
        returncode=result.returncode,
    )


def _git_worktree_add(
    source_root: Path,
    worktree_path: Path,
    branch: str,
    base_sha: str,
) -> None:
    _run_git(
        source_root,
        (
            "worktree",
            "add",
            "-b",
            branch,
            str(worktree_path),
            base_sha,
        ),
        check=True,
    )


def _is_inside(candidate: Path, root: Path) -> bool:
    try:
        candidate.relative_to(root)
    except ValueError:
        return False
    return True


def create_run_worktree(
    source_path: Path,
    worktree_path: Path,
    branch: str,
) -> GitRepositorySnapshot:
    """Create a linked worktree at *worktree_path* on new branch *branch*."""
    source_snapshot = require_clean_repository(source_path)
    source_root = source_snapshot.root
    resolved_target = worktree_path.resolve()

    if source_snapshot.is_detached:
        raise WorktreeCreationError(
            source_root=source_root,
            worktree_path=resolved_target,
            branch=branch,
            reason="source repository must be on an attached branch",
        )

    if worktree_path.is_symlink() or resolved_target.exists():
        raise WorktreeCreationError(
            source_root=source_root,
            worktree_path=resolved_target,
            branch=branch,
            reason=f"destination {resolved_target} already exists",
        )

    if _is_inside(resolved_target, source_root):
        raise WorktreeCreationError(
            source_root=source_root,
            worktree_path=resolved_target,
            branch=branch,
            reason=(f"destination {resolved_target} is inside source checkout {source_root}"),
        )

    _validate_branch_name(source_root, branch)

    if _branch_exists(source_root, branch):
        raise WorktreeCreationError(
            source_root=source_root,
            worktree_path=resolved_target,
            branch=branch,
            reason=f"branch {branch!r} already exists",
        )

    parent = resolved_target.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise WorktreeCreationError(
            source_root=source_root,
            worktree_path=resolved_target,
            branch=branch,
            reason=f"could not create parent directory {parent}: {exc}",
        ) from exc

    _git_worktree_add(
        source_root,
        resolved_target,
        branch,
        source_snapshot.head_sha,
    )

    return inspect_repository(resolved_target)
