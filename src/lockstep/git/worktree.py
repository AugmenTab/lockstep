"""Supervisor-owned creation, and Git-aware removal, of isolated run worktrees.

Turns a clean, attached source checkout into a new linked Git worktree
on a new run-specific branch rooted at the exact HEAD observed during
precondition inspection. Deterministic policy failures raise
``WorktreeCreationError``; underlying Git-command failures raise the
existing ``GitCommandError``.

Removal goes through ``git worktree remove`` without ``--force``, so Git
itself unregisters the worktree, refuses one holding uncommitted or
untracked data, and never touches a branch or commit.
"""

from __future__ import annotations

import subprocess
from collections.abc import Sequence
from dataclasses import dataclass
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


def _resolve_base_branch(
    source_root: Path,
    *,
    worktree_path: Path,
    branch: str,
    base_branch: str,
    source_head_sha: str,
) -> str:
    """Resolve *base_branch* to a commit that descends from the source HEAD."""

    def refuse(reason: str) -> WorktreeCreationError:
        return WorktreeCreationError(
            source_root=source_root,
            worktree_path=worktree_path,
            branch=branch,
            reason=reason,
        )

    _validate_branch_name(source_root, base_branch)
    if base_branch == branch:
        raise refuse("base branch must differ from the new branch")
    if not _branch_exists(source_root, base_branch):
        raise refuse(f"base branch {base_branch!r} does not exist")

    base_sha = _run_git(
        source_root,
        ("rev-parse", "--verify", f"refs/heads/{base_branch}^{{commit}}"),
        check=True,
    ).stdout.strip()

    args = ("merge-base", "--is-ancestor", source_head_sha, base_sha)
    ancestry = _run_git(source_root, args, check=False)
    if ancestry.returncode == 1:
        raise refuse(f"base branch {base_branch!r} does not descend from the source HEAD")
    if ancestry.returncode != 0:
        raise GitCommandError(
            path=source_root.resolve(),
            git_args=args,
            reason=ancestry.stderr.strip() or f"git exited with {ancestry.returncode}",
            returncode=ancestry.returncode,
        )
    return base_sha


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
    *,
    base_branch: str | None = None,
) -> GitRepositorySnapshot:
    """Create a linked worktree at *worktree_path* on new branch *branch*.

    The new branch is rooted at the source HEAD, or, when *base_branch* names
    an existing local branch that descends from the source HEAD, at that
    branch's current tip. Rooting at a prior accepted run branch lets
    sequential Sub-phases build a linear history without ever moving or
    dirtying the source checkout.
    """
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

    base_sha = source_snapshot.head_sha
    if base_branch is not None:
        base_sha = _resolve_base_branch(
            source_root,
            worktree_path=resolved_target,
            branch=branch,
            base_branch=base_branch,
            source_head_sha=source_snapshot.head_sha,
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
        base_sha,
    )

    return inspect_repository(resolved_target)


# --- Registered linked worktrees and their removal ------------------------------------------


@dataclass(frozen=True, slots=True)
class RegisteredWorktree:
    """One worktree registration as ``git worktree list --porcelain`` reports it."""

    path: Path
    head_sha: str | None
    branch: str | None
    locked: bool
    prunable: bool


def linked_worktree_common_dir(worktree_path: Path) -> Path:
    """The common Git directory of the linked worktree rooted exactly at *worktree_path*.

    Refuses (``GitCommandError``) a path that is not the root of a *linked* worktree: a main
    checkout, a subdirectory, or a directory that is not a repository at all.
    """
    root = worktree_path.resolve()
    result = _run_git(
        root,
        (
            "rev-parse",
            "--path-format=absolute",
            "--show-toplevel",
            "--git-dir",
            "--git-common-dir",
        ),
        check=True,
    )
    lines = result.stdout.splitlines()
    if len(lines) != 3:
        raise GitCommandError(
            path=root, git_args=("rev-parse",), reason="unexpected rev-parse output", returncode=0
        )
    toplevel, git_dir, common_dir = (Path(line) for line in lines)
    if toplevel.resolve() != root:
        raise GitCommandError(
            path=root, git_args=("rev-parse",), reason="not a worktree root", returncode=0
        )
    if git_dir.resolve() == common_dir.resolve():
        raise GitCommandError(
            path=root, git_args=("rev-parse",), reason="not a linked worktree", returncode=0
        )
    return common_dir.resolve()


def _registration(fields: list[str]) -> RegisteredWorktree:
    path: Path | None = None
    head: str | None = None
    branch: str | None = None
    locked = prunable = False
    for field in fields:
        key, _, value = field.partition(" ")
        if key == "worktree":
            path = Path(value)
        elif key == "HEAD":
            head = value
        elif key == "branch":
            branch = value.removeprefix("refs/heads/")
        elif key == "locked":
            locked = True
        elif key == "prunable":
            prunable = True
    if path is None:
        raise ValueError("a worktree registration without a path")
    return RegisteredWorktree(
        path=path, head_sha=head, branch=branch, locked=locked, prunable=prunable
    )


def registered_worktrees(common_dir: Path) -> tuple[RegisteredWorktree, ...]:
    """Every worktree registered in the repository whose common Git directory is *common_dir*."""
    result = _run_git_dir(common_dir, ("worktree", "list", "--porcelain", "-z"))
    registrations: list[RegisteredWorktree] = []
    fields: list[str] = []
    for field in result.stdout.split("\0"):
        if field:
            fields.append(field)
            continue
        if fields:
            try:
                registrations.append(_registration(fields))
            except ValueError as exc:
                raise GitCommandError(
                    path=common_dir,
                    git_args=("worktree", "list"),
                    reason=str(exc),
                    returncode=0,
                ) from exc
            fields = []
    return tuple(registrations)


def remove_linked_worktree(common_dir: Path, worktree_path: Path) -> None:
    """Unregister and delete one linked worktree the way Git itself does, never forcing it.

    Git refuses a worktree with tracked modifications or untracked files, and a locked one; a
    registration whose directory is already gone is unregistered alone. Branches and commits
    are never touched.
    """
    _run_git_dir(common_dir, ("worktree", "remove", str(worktree_path)))


def _run_git_dir(common_dir: Path, args: Sequence[str]) -> subprocess.CompletedProcess[str]:
    argv = ["git", f"--git-dir={common_dir}", *args]
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
            path=common_dir, git_args=tuple(args), reason=str(exc), returncode=None
        ) from exc
    if result.returncode != 0:
        raise GitCommandError(
            path=common_dir,
            git_args=tuple(args),
            reason=result.stderr.strip() or f"git exited with {result.returncode}",
            returncode=result.returncode,
        )
    return result
