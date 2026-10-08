"""Supervisor-owned exact-path restoration of an unfrozen candidate.

Restores an isolated run worktree to its exact pre-candidate state by undoing
changes to a caller-supplied, exact set of repository-relative paths -- and only
those paths. It is the counterpart of :mod:`lockstep.git.commit` for a rejected,
never-committed Planner test candidate:

    tracked path modified or deleted    restored from the expected HEAD commit
    untracked path created              removed (and any directory left empty by it)

It never resets, cleans, stashes or checks out broadly, never expands a glob or
pathspec (every Git call uses ``--literal-pathspecs`` and an explicit ``--``), and
never repairs an authority violation: a different branch or HEAD, any staged
change, or any dirty path outside the approved set is refused before anything is
touched. After restoration it proves the expected branch and HEAD are unchanged and
that the index and worktree are clean. Policy failures raise
:class:`GitRestorePolicyError`; Git command failures raise the shared
:class:`~lockstep.git.repository.GitCommandError`.
"""

from __future__ import annotations

from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from lockstep.git.commit import _path_violation, _run_git_bytes
from lockstep.git.repository import GitRepositorySnapshot, inspect_repository


class GitRestorePolicyError(Exception):
    """A deterministic precondition or postcondition of an exact-path restore failed."""

    def __init__(
        self,
        *,
        root: Path,
        reason: str,
        expected_paths: tuple[str, ...] = (),
        actual_paths: tuple[str, ...] = (),
    ) -> None:
        self.root = root
        self.reason = reason
        self.expected_paths = expected_paths
        self.actual_paths = actual_paths
        super().__init__(f"exact-path restore at {root} rejected: {reason}")


@dataclass(frozen=True, slots=True)
class GitRestoreResult:
    """Immutable outcome of a completed exact-path restore.

    ``restored_paths`` were tracked and are back at ``head_sha``'s content;
    ``removed_paths`` were untracked and no longer exist. ``snapshot`` is the
    post-restore proof (clean, on ``branch`` at ``head_sha``).
    """

    root: Path
    branch: str
    head_sha: str
    restored_paths: tuple[str, ...]
    removed_paths: tuple[str, ...]
    snapshot: GitRepositorySnapshot


def _validate_paths(root: Path, paths: Sequence[str]) -> tuple[str, ...]:
    if len(paths) == 0:
        raise GitRestorePolicyError(root=root, reason="approved path set is empty")
    seen: set[str] = set()
    for entry in paths:
        violation = _path_violation(entry)
        if violation is not None:
            raise GitRestorePolicyError(root=root, reason=violation)
        if entry in seen:
            raise GitRestorePolicyError(root=root, reason=f"approved path {entry!r} is duplicated")
        seen.add(entry)
    return tuple(sorted(seen))


def _traverses_symlink(root: Path, path: str) -> bool:
    current = root
    for part in path.split("/")[:-1]:
        current = current / part
        if current.is_symlink():
            return True
    return False


def _tracked_at(root: Path, head_sha: str, path: str) -> bool:
    result = _run_git_bytes(
        root,
        ("--literal-pathspecs", "ls-tree", "-z", "--name-only", head_sha, "--", path),
    )
    return path.encode("utf-8") in result.stdout.split(b"\x00")


def _restore_tracked(root: Path, head_sha: str, paths: tuple[str, ...]) -> None:
    _run_git_bytes(
        root,
        ("--literal-pathspecs", "restore", f"--source={head_sha}", "--worktree", "--", *paths),
    )


def _remove_untracked(root: Path, path: str) -> None:
    target = root / path
    if target.is_dir() and not target.is_symlink():
        raise GitRestorePolicyError(
            root=root, reason=f"untracked path {path!r} is a directory, not a file"
        )
    target.unlink()
    # Git does not track directories: remove only the now-empty parents the candidate
    # left behind, never the worktree root and never a directory that still has content.
    parent = target.parent
    while parent != root:
        try:
            parent.rmdir()
        except OSError:
            break
        parent = parent.parent


def restore_exact_paths(
    worktree_path: Path,
    *,
    expected_branch: str,
    expected_head_sha: str,
    paths: Sequence[str],
) -> GitRestoreResult:
    """Undo every worktree change to exactly *paths*, refusing anything else."""
    approved = _validate_paths(worktree_path, paths)

    snapshot = inspect_repository(worktree_path)
    root = snapshot.root

    if snapshot.branch != expected_branch:
        raise GitRestorePolicyError(
            root=root,
            reason=f"expected branch {expected_branch!r}, but worktree is on {snapshot.branch!r}",
        )
    if snapshot.head_sha != expected_head_sha:
        raise GitRestorePolicyError(
            root=root,
            reason=(
                f"expected HEAD {expected_head_sha!r}, but worktree HEAD is {snapshot.head_sha!r}"
            ),
        )
    if snapshot.staged_paths:
        raise GitRestorePolicyError(
            root=root,
            reason="index contains staged changes",
            actual_paths=snapshot.staged_paths,
        )
    unrelated = tuple(sorted(set(snapshot.dirty_paths) - set(approved)))
    if unrelated:
        raise GitRestorePolicyError(
            root=root,
            reason="dirty paths outside the approved set",
            expected_paths=approved,
            actual_paths=unrelated,
        )

    dirty = set(snapshot.dirty_paths)
    for path in approved:
        if path in dirty and _traverses_symlink(root, path):
            raise GitRestorePolicyError(root=root, reason=f"path {path!r} traverses a symlink")

    untracked = set(snapshot.untracked_paths)
    restored = tuple(path for path in approved if path in dirty and path not in untracked)
    removed = tuple(path for path in approved if path in untracked)
    for path in restored:
        if not _tracked_at(root, expected_head_sha, path):
            raise GitRestorePolicyError(
                root=root, reason=f"path {path!r} is dirty but not tracked at the expected HEAD"
            )

    if restored:
        _restore_tracked(root, expected_head_sha, restored)
    for path in removed:
        _remove_untracked(root, path)

    post = inspect_repository(root)
    if post.branch != expected_branch:
        raise GitRestorePolicyError(
            root=root, reason=f"branch drifted to {post.branch!r} during restore"
        )
    if post.head_sha != expected_head_sha:
        raise GitRestorePolicyError(root=root, reason="HEAD moved during restore")
    if post.staged_paths:
        raise GitRestorePolicyError(
            root=root, reason="index is not clean after restore", actual_paths=post.staged_paths
        )
    if not post.is_clean:
        raise GitRestorePolicyError(
            root=root,
            reason="worktree is not clean after restore",
            expected_paths=(),
            actual_paths=post.dirty_paths,
        )

    return GitRestoreResult(
        root=root,
        branch=expected_branch,
        head_sha=expected_head_sha,
        restored_paths=restored,
        removed_paths=removed,
        snapshot=post,
    )


__all__ = ["GitRestorePolicyError", "GitRestoreResult", "restore_exact_paths"]
