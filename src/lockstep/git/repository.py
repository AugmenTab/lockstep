"""Read-only Git repository inspection.

Owns the small subprocess wrapper Lockstep uses to interrogate a Git
repository's identity and cleanliness. All production functions in this
module are observational; repository state is never mutated here.
"""

from __future__ import annotations

import subprocess
from collections.abc import Sequence
from dataclasses import dataclass
from pathlib import Path


class GitCommandError(Exception):
    """A Git subprocess invocation failed."""

    def __init__(
        self,
        *,
        path: Path,
        git_args: tuple[str, ...],
        reason: str,
        returncode: int | None,
    ) -> None:
        self.path = path
        self.git_args = git_args
        self.reason = reason
        self.returncode = returncode
        rc = "unavailable" if returncode is None else str(returncode)
        joined = " ".join(git_args)
        super().__init__(f"git {joined} failed in {path} (returncode={rc}): {reason}")


class DirtyRepositoryError(Exception):
    """The repository has uncommitted changes and cannot be used as a source checkout."""

    def __init__(self, *, root: Path, dirty_paths: tuple[str, ...]) -> None:
        self.root = root
        self.dirty_paths = dirty_paths
        joined = ", ".join(dirty_paths) if dirty_paths else "(none reported)"
        super().__init__(
            f"Lockstep requires a clean source checkout at {root}; dirty paths: {joined}"
        )


@dataclass(frozen=True, slots=True)
class GitRepositorySnapshot:
    """Immutable read-only view of a Git repository's identity and cleanliness."""

    root: Path
    head_sha: str
    branch: str | None
    staged_paths: tuple[str, ...]
    unstaged_paths: tuple[str, ...]
    untracked_paths: tuple[str, ...]
    dirty_paths: tuple[str, ...]

    @property
    def is_detached(self) -> bool:
        return self.branch is None

    @property
    def is_clean(self) -> bool:
        return len(self.dirty_paths) == 0


def _run_git_text(
    path: Path,
    args: Sequence[str],
    *,
    check: bool = True,
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


def _decode_nul_paths(payload: bytes) -> list[str]:
    if not payload:
        return []
    return [chunk.decode("utf-8", errors="replace") for chunk in payload.split(b"\x00") if chunk]


def _resolve_repository_root(path: Path) -> Path:
    result = _run_git_text(path, ("rev-parse", "--show-toplevel"))
    return Path(result.stdout.strip()).resolve()


def _resolve_head_sha(root: Path) -> str:
    result = _run_git_text(root, ("rev-parse", "--verify", "HEAD"))
    return result.stdout.strip()


def _resolve_branch(root: Path) -> str | None:
    result = _run_git_text(
        root,
        ("symbolic-ref", "--quiet", "--short", "HEAD"),
        check=False,
    )
    if result.returncode == 0:
        return result.stdout.strip()
    return None


def _collect_staged_paths(root: Path) -> tuple[str, ...]:
    result = _run_git_bytes(
        root,
        ("diff", "--cached", "--name-only", "--no-renames", "-z"),
    )
    return tuple(sorted(_decode_nul_paths(result.stdout)))


def _collect_unstaged_paths(root: Path) -> tuple[str, ...]:
    result = _run_git_bytes(
        root,
        ("diff", "--name-only", "--no-renames", "-z"),
    )
    return tuple(sorted(_decode_nul_paths(result.stdout)))


def _collect_untracked_paths(root: Path) -> tuple[str, ...]:
    result = _run_git_bytes(
        root,
        ("ls-files", "--others", "--exclude-standard", "-z"),
    )
    return tuple(sorted(_decode_nul_paths(result.stdout)))


def _collect_dirty_paths(
    staged_paths: tuple[str, ...],
    unstaged_paths: tuple[str, ...],
    untracked_paths: tuple[str, ...],
) -> tuple[str, ...]:
    seen: set[str] = set()
    seen.update(staged_paths)
    seen.update(unstaged_paths)
    seen.update(untracked_paths)
    return tuple(sorted(seen))


def inspect_repository(path: Path) -> GitRepositorySnapshot:
    """Return a read-only snapshot of the Git repository containing *path*."""
    root = _resolve_repository_root(path)
    head_sha = _resolve_head_sha(root)
    branch = _resolve_branch(root)
    staged_paths = _collect_staged_paths(root)
    unstaged_paths = _collect_unstaged_paths(root)
    untracked_paths = _collect_untracked_paths(root)
    dirty_paths = _collect_dirty_paths(staged_paths, unstaged_paths, untracked_paths)
    return GitRepositorySnapshot(
        root=root,
        head_sha=head_sha,
        branch=branch,
        staged_paths=staged_paths,
        unstaged_paths=unstaged_paths,
        untracked_paths=untracked_paths,
        dirty_paths=dirty_paths,
    )


def require_clean_repository(path: Path) -> GitRepositorySnapshot:
    """Return the snapshot when the repository is clean, else raise DirtyRepositoryError."""
    snapshot = inspect_repository(path)
    if not snapshot.is_clean:
        raise DirtyRepositoryError(
            root=snapshot.root,
            dirty_paths=snapshot.dirty_paths,
        )
    return snapshot
