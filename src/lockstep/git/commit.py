"""Supervisor-owned exact staging and canonical commit creation.

Provides the single Supervisor primitive that stages a caller-supplied
exact set of repository-relative paths and produces one canonical commit
in the run worktree. All deterministic policy failures raise
``GitCommitPolicyError``; underlying Git command failures raise the
shared ``GitCommandError``.
"""

from __future__ import annotations

import subprocess
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path

from lockstep.git.repository import (
    GitCommandError,
    inspect_repository,
)

_HOOKS_DISABLED = "/dev/null"


class GitCommitPolicyError(Exception):
    """A deterministic precondition or postcondition of a Supervisor commit failed."""

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
        super().__init__(f"canonical Supervisor commit at {root} rejected: {reason}")


@dataclass(frozen=True, slots=True)
class GitCommitResult:
    """Immutable outcome of a completed canonical Supervisor commit."""

    root: Path
    branch: str
    parent_sha: str
    commit_sha: str
    committed_paths: tuple[str, ...]


def _run_git_text(
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


def _run_git_bytes(
    path: Path,
    args: Sequence[str],
) -> subprocess.CompletedProcess[bytes]:
    argv = ["git", "-C", str(path), *args]
    try:
        result = subprocess.run(
            argv,
            capture_output=True,
            text=False,
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

    if result.returncode != 0:
        stderr = result.stderr.decode("utf-8", errors="replace")
        raise GitCommandError(
            path=path.resolve(),
            git_args=tuple(args),
            reason=stderr.strip() or f"git exited with {result.returncode}",
            returncode=result.returncode,
        )
    return result


def _decode_nul_paths(payload: bytes) -> tuple[str, ...]:
    if not payload:
        return ()
    return tuple(
        chunk.decode("utf-8", errors="replace") for chunk in payload.split(b"\x00") if chunk
    )


def _staged_paths(root: Path) -> tuple[str, ...]:
    result = _run_git_bytes(
        root,
        ("diff", "--cached", "--name-only", "--no-renames", "-z"),
    )
    return tuple(sorted(_decode_nul_paths(result.stdout)))


def _unstaged_paths(root: Path) -> tuple[str, ...]:
    result = _run_git_bytes(
        root,
        ("diff", "--name-only", "--no-renames", "-z"),
    )
    return tuple(sorted(_decode_nul_paths(result.stdout)))


def _untracked_paths(root: Path) -> tuple[str, ...]:
    result = _run_git_bytes(
        root,
        ("ls-files", "--others", "--exclude-standard", "-z"),
    )
    return tuple(sorted(_decode_nul_paths(result.stdout)))


def _committed_paths(root: Path) -> tuple[str, ...]:
    result = _run_git_bytes(
        root,
        (
            "diff-tree",
            "--no-commit-id",
            "--name-only",
            "--no-renames",
            "-r",
            "-z",
            "HEAD",
        ),
    )
    return tuple(sorted(_decode_nul_paths(result.stdout)))


def _validate_paths(root: Path, paths: Sequence[str]) -> tuple[str, ...]:
    if len(paths) == 0:
        raise GitCommitPolicyError(
            root=root,
            reason="approved path set is empty",
        )

    seen: set[str] = set()
    for entry in paths:
        if entry == "":
            raise GitCommitPolicyError(
                root=root,
                reason="approved path is an empty string",
            )
        if entry in seen:
            raise GitCommitPolicyError(
                root=root,
                reason=f"approved path {entry!r} is duplicated",
            )
        parts = entry.split("/")
        if any(part == "" for part in parts):
            raise GitCommitPolicyError(
                root=root,
                reason=f"approved path {entry!r} is not repository-relative",
            )
        if any(part in (".", "..") for part in parts):
            raise GitCommitPolicyError(
                root=root,
                reason=f"approved path {entry!r} contains '.' or '..' traversal",
            )
        if parts[0] == ".git":
            raise GitCommitPolicyError(
                root=root,
                reason=f"approved path {entry!r} is inside .git",
            )
        seen.add(entry)

    return tuple(sorted(seen))


def _validate_message(root: Path, message: str) -> None:
    if message.strip() == "":
        raise GitCommitPolicyError(
            root=root,
            reason="commit message is blank",
        )
    if "\x00" in message:
        raise GitCommitPolicyError(
            root=root,
            reason="commit message contains NUL character",
        )


def _git_add_exact_paths(root: Path, paths: tuple[str, ...]) -> None:
    _run_git_text(
        root,
        ("--literal-pathspecs", "add", "-A", "--", *paths),
        check=True,
    )


def _git_commit(root: Path, message: str) -> None:
    _run_git_text(
        root,
        (
            "-c",
            f"core.hooksPath={_HOOKS_DISABLED}",
            "commit",
            "--no-gpg-sign",
            "--no-verify",
            "-m",
            message,
        ),
        check=True,
    )


def commit_exact_paths(
    worktree_path: Path,
    *,
    expected_branch: str,
    expected_head_sha: str,
    paths: Sequence[str],
    message: str,
) -> GitCommitResult:
    """Create one canonical Supervisor commit from exactly the approved paths."""
    approved = _validate_paths(worktree_path, paths)
    _validate_message(worktree_path, message)

    snapshot = inspect_repository(worktree_path)
    root = snapshot.root

    if snapshot.branch != expected_branch:
        raise GitCommitPolicyError(
            root=root,
            reason=(f"expected branch {expected_branch!r}, but worktree is on {snapshot.branch!r}"),
        )

    if snapshot.head_sha != expected_head_sha:
        raise GitCommitPolicyError(
            root=root,
            reason=(
                f"expected HEAD {expected_head_sha!r}, but worktree HEAD is {snapshot.head_sha!r}"
            ),
        )

    preexisting_staged = _staged_paths(root)
    if preexisting_staged:
        raise GitCommitPolicyError(
            root=root,
            reason="index already contains staged changes",
            expected_paths=(),
            actual_paths=preexisting_staged,
        )

    actual_dirty = snapshot.dirty_paths
    if set(actual_dirty) != set(approved):
        raise GitCommitPolicyError(
            root=root,
            reason="dirty paths do not exactly match approved paths",
            expected_paths=approved,
            actual_paths=actual_dirty,
        )

    _git_add_exact_paths(root, approved)

    staged_after = _staged_paths(root)
    if staged_after != approved:
        raise GitCommitPolicyError(
            root=root,
            reason="staged paths do not match approved paths after add",
            expected_paths=approved,
            actual_paths=staged_after,
        )

    unstaged_after = _unstaged_paths(root)
    untracked_after = _untracked_paths(root)
    if unstaged_after or untracked_after:
        remaining = tuple(sorted({*unstaged_after, *untracked_after}))
        raise GitCommitPolicyError(
            root=root,
            reason="unstaged or untracked changes remain after exact staging",
            expected_paths=approved,
            actual_paths=remaining,
        )

    _git_commit(root, message)

    post_snapshot = inspect_repository(root)
    if post_snapshot.branch != expected_branch:
        raise GitCommitPolicyError(
            root=root,
            reason=f"branch drifted to {post_snapshot.branch!r} after commit",
        )
    if not post_snapshot.is_clean:
        raise GitCommitPolicyError(
            root=root,
            reason="worktree is not clean after commit",
            actual_paths=post_snapshot.dirty_paths,
        )
    if post_snapshot.head_sha == expected_head_sha:
        raise GitCommitPolicyError(
            root=root,
            reason="HEAD did not advance after commit",
        )

    parent_result = _run_git_text(
        root,
        ("rev-parse", "--verify", "HEAD^"),
        check=True,
    )
    parent_sha = parent_result.stdout.strip()
    if parent_sha != expected_head_sha:
        raise GitCommitPolicyError(
            root=root,
            reason=(
                f"new commit parent {parent_sha!r} does not match "
                f"expected HEAD {expected_head_sha!r}"
            ),
        )

    committed = _committed_paths(root)
    if committed != approved:
        raise GitCommitPolicyError(
            root=root,
            reason="commit contents do not equal approved paths",
            expected_paths=approved,
            actual_paths=committed,
        )

    if _staged_paths(root) != ():
        raise GitCommitPolicyError(
            root=root,
            reason="index is not empty after commit",
        )

    return GitCommitResult(
        root=root,
        branch=expected_branch,
        parent_sha=expected_head_sha,
        commit_sha=post_snapshot.head_sha,
        committed_paths=approved,
    )
