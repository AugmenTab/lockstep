"""Read-only repository evidence measured against one fixed base commit.

A Reviewer handoff must describe what the Implementer changed, and that
description must be reconstructable later from Git alone. Measuring the working
tree against the *frozen test commit* gives that: before the implementation
commit the change is dirty and partly untracked, and after it the same change is
committed, yet the set of changed paths and their content is identical either
way. The patch is built here from the two file contents rather than from Git's
porcelain output, so it does not depend on the index or on how a path happens to
be tracked.

Everything is observational. Nothing in this module mutates a repository, and
nothing it returns is authority: it is evidence about the repository.
"""

from __future__ import annotations

import difflib
from dataclasses import dataclass
from pathlib import Path

from lockstep.git.repository import (
    GitCommandError,
    _decode_nul_paths,
    _run_git_bytes,
    _run_git_text,
)


@dataclass(frozen=True, slots=True)
class FileChangeEvidence:
    """One path whose content differs between the base commit and the working tree."""

    path: str
    status: str  # "added" | "modified" | "deleted"
    patch: str
    patch_truncated: bool


def _require_commit(root: Path, sha: str) -> None:
    if not sha or sha.startswith("-"):
        raise GitCommandError(
            path=root,
            git_args=("cat-file",),
            reason="invalid commit reference",
            returncode=None,
        )


def blob_at(root: Path, sha: str, path: str) -> bytes | None:
    """The content of *path* at commit *sha*, or ``None`` if it does not exist there."""
    _require_commit(root, sha)
    result = _run_git_text(root, ["cat-file", "-e", f"{sha}:{path}"], check=False)
    if result.returncode != 0:
        return None
    return _run_git_bytes(root, ["show", f"{sha}:{path}"]).stdout


def commit_parent(root: Path, sha: str) -> str:
    """The first parent of commit *sha*."""
    _require_commit(root, sha)
    return _run_git_text(root, ["rev-parse", "--verify", f"{sha}^"]).stdout.strip()


def is_ancestor(root: Path, ancestor: str, descendant: str) -> bool:
    """Whether commit *ancestor* is an ancestor of (or equal to) commit *descendant*."""
    _require_commit(root, ancestor)
    _require_commit(root, descendant)
    result = _run_git_text(root, ["merge-base", "--is-ancestor", ancestor, descendant], check=False)
    if result.returncode not in (0, 1):
        raise GitCommandError(
            path=root,
            git_args=("merge-base", "--is-ancestor"),
            reason=result.stderr.strip() or f"git exited with {result.returncode}",
            returncode=result.returncode,
        )
    return result.returncode == 0


def _worktree_bytes(root: Path, path: str) -> bytes | None:
    target = root / path
    if target.is_file():
        return target.read_bytes()
    return None


def _patch(path: str, old: bytes | None, new: bytes | None, limit: int) -> tuple[str, bool]:
    if (old is not None and b"\x00" in old) or (new is not None and b"\x00" in new):
        return "Binary content differs.\n", False
    old_lines = (old or b"").decode("utf-8", errors="replace").splitlines(keepends=True)
    new_lines = (new or b"").decode("utf-8", errors="replace").splitlines(keepends=True)
    text = "".join(
        difflib.unified_diff(
            old_lines,
            new_lines,
            fromfile="/dev/null" if old is None else f"a/{path}",
            tofile="/dev/null" if new is None else f"b/{path}",
        )
    )
    data = text.encode("utf-8")
    if len(data) <= limit:
        return text, False
    return data[:limit].decode("utf-8", errors="ignore"), True


def changes_since(
    root: Path, base_sha: str, *, max_patch_bytes: int
) -> tuple[FileChangeEvidence, ...]:
    """Every path whose working-tree content differs from commit *base_sha*, sorted by path."""
    _require_commit(root, base_sha)
    tracked = _decode_nul_paths(
        _run_git_bytes(root, ["diff", "--name-only", "--no-renames", "-z", base_sha]).stdout
    )
    untracked = _decode_nul_paths(
        _run_git_bytes(root, ["ls-files", "--others", "--exclude-standard", "-z"]).stdout
    )
    changes: list[FileChangeEvidence] = []
    for path in sorted(set(tracked) | set(untracked)):
        old = blob_at(root, base_sha, path)
        new = _worktree_bytes(root, path)
        if old == new:
            continue
        if old is None:
            status = "added"
        elif new is None:
            status = "deleted"
        else:
            status = "modified"
        patch, truncated = _patch(path, old, new, max_patch_bytes)
        changes.append(
            FileChangeEvidence(path=path, status=status, patch=patch, patch_truncated=truncated)
        )
    return tuple(changes)
