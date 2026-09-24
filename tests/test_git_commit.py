import subprocess
from pathlib import Path

import pytest

from lockstep.git import (
    GitCommitPolicyError,
    GitCommitResult,
    commit_exact_paths,
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


def _staged_paths(repo: Path) -> tuple[str, ...]:
    output = _git_stdout(
        repo,
        "diff",
        "--cached",
        "--name-only",
        "--no-renames",
    )
    if not output:
        return ()

    return tuple(sorted(output.splitlines()))


def _head_paths(repo: Path) -> tuple[str, ...]:
    output = _git_stdout(
        repo,
        "diff-tree",
        "--no-commit-id",
        "--name-only",
        "--no-renames",
        "-r",
        "HEAD",
    )
    if not output:
        return ()

    return tuple(sorted(output.splitlines()))


def _init_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "source"
    repo.mkdir()

    _git(repo, "init")
    _git(repo, "config", "user.name", "Lockstep Tests")
    _git(repo, "config", "user.email", "lockstep-tests@example.invalid")

    (repo / "README.md").write_text("initial\n")
    (repo / "tracked.txt").write_text("tracked\n")

    _git(repo, "add", "README.md", "tracked.txt")
    _git(repo, "commit", "-m", "initial")
    _git(repo, "branch", "-M", "main")

    return repo


def _create_run(
    tmp_path: Path,
) -> tuple[Path, Path, str]:
    source = _init_repo(tmp_path)
    worktree = tmp_path / "run-worktree"
    branch = "lockstep/run/run-001"

    create_run_worktree(source, worktree, branch)

    return source, worktree, branch


def test_commit_exact_paths_creates_one_exact_clean_commit(
    tmp_path: Path,
) -> None:
    source, worktree, branch = _create_run(tmp_path)
    source_before = inspect_repository(source)
    run_before = inspect_repository(worktree)

    (worktree / "README.md").write_text("changed\n")
    (worktree / "new.txt").write_text("new\n")
    (worktree / "tracked.txt").unlink()

    expected_paths = (
        "README.md",
        "new.txt",
        "tracked.txt",
    )

    result = commit_exact_paths(
        worktree,
        expected_branch=branch,
        expected_head_sha=run_before.head_sha,
        paths=expected_paths,
        message="feat: bounded change",
    )

    assert isinstance(result, GitCommitResult)
    assert result.root == worktree.resolve()
    assert result.branch == branch
    assert result.parent_sha == run_before.head_sha
    assert result.commit_sha == inspect_repository(worktree).head_sha
    assert result.committed_paths == expected_paths

    assert _git_stdout(worktree, "rev-parse", "HEAD^") == run_before.head_sha
    assert _git_stdout(worktree, "log", "-1", "--format=%s") == "feat: bounded change"
    assert _head_paths(worktree) == expected_paths
    assert _staged_paths(worktree) == ()
    assert inspect_repository(worktree).is_clean is True
    assert inspect_repository(source) == source_before


def test_unapproved_dirty_path_prevents_any_staging(
    tmp_path: Path,
) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)

    (worktree / "README.md").write_text("approved\n")
    (worktree / "extra.txt").write_text("not approved\n")

    with pytest.raises(GitCommitPolicyError) as exc_info:
        commit_exact_paths(
            worktree,
            expected_branch=branch,
            expected_head_sha=before.head_sha,
            paths=("README.md",),
            message="feat: bounded change",
        )

    assert exc_info.value.expected_paths == ("README.md",)
    assert exc_info.value.actual_paths == ("README.md", "extra.txt")
    assert _staged_paths(worktree) == ()
    assert inspect_repository(worktree).head_sha == before.head_sha


def test_preexisting_staged_change_is_rejected(
    tmp_path: Path,
) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)

    (worktree / "README.md").write_text("changed\n")
    _git(worktree, "add", "README.md")

    with pytest.raises(GitCommitPolicyError) as exc_info:
        commit_exact_paths(
            worktree,
            expected_branch=branch,
            expected_head_sha=before.head_sha,
            paths=("README.md",),
            message="feat: bounded change",
        )

    assert "staged" in exc_info.value.reason
    assert exc_info.value.actual_paths == ("README.md",)
    assert _staged_paths(worktree) == ("README.md",)
    assert inspect_repository(worktree).head_sha == before.head_sha


def test_wrong_branch_is_rejected_before_staging(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)
    (worktree / "README.md").write_text("changed\n")

    with pytest.raises(GitCommitPolicyError) as exc_info:
        commit_exact_paths(
            worktree,
            expected_branch=f"{branch}-other",
            expected_head_sha=before.head_sha,
            paths=("README.md",),
            message="feat: bounded change",
        )

    assert "branch" in exc_info.value.reason
    assert _staged_paths(worktree) == ()
    assert inspect_repository(worktree).head_sha == before.head_sha


def test_unexpected_head_is_rejected_before_staging(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    (worktree / "README.md").write_text("changed\n")

    with pytest.raises(GitCommitPolicyError) as exc_info:
        commit_exact_paths(
            worktree,
            expected_branch=branch,
            expected_head_sha="0" * 40,
            paths=("README.md",),
            message="feat: bounded change",
        )

    assert "HEAD" in exc_info.value.reason
    assert _staged_paths(worktree) == ()


@pytest.mark.parametrize(
    "paths",
    [
        (),
        ("README.md", "README.md"),
        ("/absolute.txt",),
        ("../outside.txt",),
        (".git/config",),
        ("./README.md",),
    ],
)
def test_invalid_approved_path_set_is_rejected(
    tmp_path: Path,
    paths: tuple[str, ...],
) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)
    (worktree / "README.md").write_text("changed\n")

    with pytest.raises(GitCommitPolicyError):
        commit_exact_paths(
            worktree,
            expected_branch=branch,
            expected_head_sha=before.head_sha,
            paths=paths,
            message="feat: bounded change",
        )

    assert _staged_paths(worktree) == ()
    assert inspect_repository(worktree).head_sha == before.head_sha


def test_unchanged_requested_path_is_rejected(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)

    with pytest.raises(GitCommitPolicyError) as exc_info:
        commit_exact_paths(
            worktree,
            expected_branch=branch,
            expected_head_sha=before.head_sha,
            paths=("README.md",),
            message="feat: bounded change",
        )

    assert exc_info.value.actual_paths == ()
    assert inspect_repository(worktree).head_sha == before.head_sha


@pytest.mark.parametrize("message", ["", " ", "\n"])
def test_blank_commit_message_is_rejected_before_staging(
    tmp_path: Path,
    message: str,
) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)
    (worktree / "README.md").write_text("changed\n")

    with pytest.raises(GitCommitPolicyError):
        commit_exact_paths(
            worktree,
            expected_branch=branch,
            expected_head_sha=before.head_sha,
            paths=("README.md",),
            message=message,
        )

    assert _staged_paths(worktree) == ()
    assert inspect_repository(worktree).head_sha == before.head_sha


def test_repository_commit_hooks_are_not_executed(tmp_path: Path) -> None:
    source, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)
    marker = tmp_path / "hook-ran"

    hooks = Path(_git_stdout(source, "rev-parse", "--absolute-git-dir")) / "hooks"
    hooks.mkdir(parents=True, exist_ok=True)

    pre_commit = hooks / "pre-commit"
    pre_commit.write_text(f"#!/bin/sh\ntouch '{marker}'\nexit 1\n")
    pre_commit.chmod(0o755)

    post_commit = hooks / "post-commit"
    post_commit.write_text(f"#!/bin/sh\ntouch '{marker}'\n")
    post_commit.chmod(0o755)

    (worktree / "README.md").write_text("changed\n")

    commit_exact_paths(
        worktree,
        expected_branch=branch,
        expected_head_sha=before.head_sha,
        paths=("README.md",),
        message="feat: hooks disabled",
    )

    assert not marker.exists()
    assert inspect_repository(worktree).is_clean is True
