import subprocess
from pathlib import Path

import pytest

from lockstep.git import (
    DirtyRepositoryError,
    GitCommandError,
    WorktreeCreationError,
    create_run_worktree,
    inspect_repository,
)


def _git(
    repo: Path,
    *args: str,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=check,
        capture_output=True,
        text=True,
    )


def _git_stdout(repo: Path, *args: str) -> str:
    return _git(repo, *args).stdout.strip()


def _branch_exists(repo: Path, branch: str) -> bool:
    result = _git(
        repo,
        "show-ref",
        "--verify",
        "--quiet",
        f"refs/heads/{branch}",
        check=False,
    )
    return result.returncode == 0


def _init_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "source"
    repo.mkdir()

    _git(repo, "init")
    _git(repo, "config", "user.name", "Lockstep Tests")
    _git(repo, "config", "user.email", "lockstep-tests@example.invalid")

    (repo / "README.md").write_text("initial\n")
    _git(repo, "add", "README.md")
    _git(repo, "commit", "-m", "initial")
    _git(repo, "branch", "-M", "main")

    return repo


def test_create_run_worktree_from_exact_source_head(tmp_path: Path) -> None:
    source = _init_repo(tmp_path)
    target = tmp_path / "run worktree"
    branch = "lockstep/run/run-001"

    before = inspect_repository(source)

    created = create_run_worktree(source, target, branch)

    assert created.root == target.resolve()
    assert created.head_sha == before.head_sha
    assert created.branch == branch
    assert created.is_detached is False
    assert created.is_clean is True

    after = inspect_repository(source)

    assert after == before
    assert _branch_exists(source, branch)


def test_created_worktree_is_registered_with_git(tmp_path: Path) -> None:
    source = _init_repo(tmp_path)
    target = tmp_path / "run-worktree"
    branch = "lockstep/run/run-001"

    create_run_worktree(source, target, branch)

    porcelain = _git_stdout(source, "worktree", "list", "--porcelain")

    assert f"worktree {target.resolve()}" in porcelain
    assert f"branch refs/heads/{branch}" in porcelain


def test_nested_source_path_resolves_original_repository(tmp_path: Path) -> None:
    source = _init_repo(tmp_path)
    nested = source / "src" / "nested"
    nested.mkdir(parents=True)
    target = tmp_path / "run-worktree"

    created = create_run_worktree(
        nested,
        target,
        "lockstep/run/run-001",
    )

    assert created.root == target.resolve()
    assert inspect_repository(source).branch == "main"


def test_dirty_source_is_rejected_before_mutation(tmp_path: Path) -> None:
    source = _init_repo(tmp_path)
    target = tmp_path / "run-worktree"
    branch = "lockstep/run/run-001"
    (source / "README.md").write_text("dirty\n")

    with pytest.raises(DirtyRepositoryError):
        create_run_worktree(source, target, branch)

    assert not target.exists()
    assert not _branch_exists(source, branch)


def test_detached_source_is_rejected_before_mutation(tmp_path: Path) -> None:
    source = _init_repo(tmp_path)
    target = tmp_path / "run-worktree"
    branch = "lockstep/run/run-001"
    _git(source, "checkout", "--detach", "HEAD")

    with pytest.raises(WorktreeCreationError) as exc_info:
        create_run_worktree(source, target, branch)

    assert exc_info.value.source_root == source.resolve()
    assert exc_info.value.worktree_path == target.resolve()
    assert exc_info.value.branch == branch
    assert "attached" in exc_info.value.reason
    assert not target.exists()
    assert not _branch_exists(source, branch)


def test_existing_destination_is_rejected_before_git_mutation(
    tmp_path: Path,
) -> None:
    source = _init_repo(tmp_path)
    target = tmp_path / "run-worktree"
    branch = "lockstep/run/run-001"
    target.mkdir()

    with pytest.raises(WorktreeCreationError) as exc_info:
        create_run_worktree(source, target, branch)

    assert "already exists" in exc_info.value.reason
    assert not _branch_exists(source, branch)


def test_destination_inside_source_checkout_is_rejected(
    tmp_path: Path,
) -> None:
    source = _init_repo(tmp_path)
    target = source / "nested-worktree"
    branch = "lockstep/run/run-001"

    with pytest.raises(WorktreeCreationError) as exc_info:
        create_run_worktree(source, target, branch)

    assert "inside" in exc_info.value.reason
    assert not target.exists()
    assert not _branch_exists(source, branch)
    assert inspect_repository(source).is_clean is True


def test_existing_branch_is_rejected_before_worktree_creation(
    tmp_path: Path,
) -> None:
    source = _init_repo(tmp_path)
    target = tmp_path / "run-worktree"
    branch = "lockstep/run/run-001"
    _git(source, "branch", branch)

    with pytest.raises(WorktreeCreationError) as exc_info:
        create_run_worktree(source, target, branch)

    assert "already exists" in exc_info.value.reason
    assert not target.exists()


def test_invalid_branch_name_is_reported_as_git_command_error(
    tmp_path: Path,
) -> None:
    source = _init_repo(tmp_path)
    target = tmp_path / "run-worktree"

    with pytest.raises(GitCommandError) as exc_info:
        create_run_worktree(source, target, "bad..branch")

    assert exc_info.value.path == source.resolve()
    assert exc_info.value.git_args == (
        "check-ref-format",
        "--branch",
        "bad..branch",
    )
    assert not target.exists()


def test_worktree_parent_directories_may_be_created(tmp_path: Path) -> None:
    source = _init_repo(tmp_path)
    target = tmp_path / "runs" / "nested" / "run-worktree"

    created = create_run_worktree(
        source,
        target,
        "lockstep/run/run-001",
    )

    assert created.root == target.resolve()
    assert created.is_clean is True
