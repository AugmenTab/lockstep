import subprocess
from dataclasses import FrozenInstanceError
from pathlib import Path

import pytest

from lockstep.git import (
    DirtyRepositoryError,
    GitCommandError,
    GitRepositorySnapshot,
    inspect_repository,
    require_clean_repository,
)


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def _init_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()

    _git(repo, "init")
    _git(repo, "config", "user.name", "Lockstep Tests")
    _git(repo, "config", "user.email", "lockstep-tests@example.invalid")

    (repo / "README.md").write_text("initial\n")
    (repo / "tracked.txt").write_text("initial\n")

    _git(repo, "add", "README.md", "tracked.txt")
    _git(repo, "commit", "-m", "initial")
    _git(repo, "branch", "-M", "main")

    return repo


def test_inspect_clean_repository(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)

    snapshot = inspect_repository(repo)

    assert isinstance(snapshot, GitRepositorySnapshot)
    assert snapshot.root == repo.resolve()
    assert snapshot.head_sha == _git(repo, "rev-parse", "HEAD")
    assert snapshot.branch == "main"
    assert snapshot.is_detached is False
    assert snapshot.is_clean is True
    assert snapshot.dirty_paths == ()


def test_inspect_from_nested_directory_resolves_repository_root(
    tmp_path: Path,
) -> None:
    repo = _init_repo(tmp_path)
    nested = repo / "src" / "nested"
    nested.mkdir(parents=True)

    snapshot = inspect_repository(nested)

    assert snapshot.root == repo.resolve()


def test_inspect_repository_reports_dirty_paths(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)

    (repo / "README.md").write_text("modified but unstaged\n")
    (repo / "tracked.txt").write_text("modified and staged\n")
    _git(repo, "add", "tracked.txt")
    (repo / "untracked.txt").write_text("new\n")

    snapshot = inspect_repository(repo)

    assert snapshot.is_clean is False
    assert snapshot.dirty_paths == (
        "README.md",
        "tracked.txt",
        "untracked.txt",
    )


def test_dirty_paths_are_unique_across_index_and_worktree(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)

    (repo / "README.md").write_text("staged\n")
    _git(repo, "add", "README.md")
    (repo / "README.md").write_text("staged plus unstaged\n")

    snapshot = inspect_repository(repo)

    assert snapshot.dirty_paths == ("README.md",)


def test_require_clean_repository_returns_snapshot_when_clean(
    tmp_path: Path,
) -> None:
    repo = _init_repo(tmp_path)

    snapshot = require_clean_repository(repo)

    assert snapshot.is_clean is True
    assert snapshot.root == repo.resolve()


def test_require_clean_repository_exposes_dirty_paths(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)
    (repo / "README.md").write_text("dirty\n")

    with pytest.raises(DirtyRepositoryError) as exc_info:
        require_clean_repository(repo)

    assert exc_info.value.root == repo.resolve()
    assert exc_info.value.dirty_paths == ("README.md",)
    assert "README.md" in str(exc_info.value)


def test_detached_head_is_reported_without_mutation(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)
    _git(repo, "checkout", "--detach", "HEAD")

    snapshot = inspect_repository(repo)

    assert snapshot.branch is None
    assert snapshot.is_detached is True
    assert snapshot.head_sha == _git(repo, "rev-parse", "HEAD")
    assert snapshot.is_clean is True


def test_repository_snapshot_is_immutable(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)
    snapshot = inspect_repository(repo)

    with pytest.raises(FrozenInstanceError):
        snapshot.branch = "other"  # type: ignore[misc]


def test_non_repository_raises_git_command_error(tmp_path: Path) -> None:
    with pytest.raises(GitCommandError) as exc_info:
        inspect_repository(tmp_path)

    assert exc_info.value.path == tmp_path.resolve()
    assert exc_info.value.git_args == ("rev-parse", "--show-toplevel")
    assert exc_info.value.returncode is not None
    assert exc_info.value.reason


def test_repository_without_head_commit_raises_git_command_error(
    tmp_path: Path,
) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init")

    with pytest.raises(GitCommandError) as exc_info:
        inspect_repository(repo)

    assert exc_info.value.path == repo.resolve()
    assert exc_info.value.git_args == ("rev-parse", "--verify", "HEAD")
    assert exc_info.value.reason
