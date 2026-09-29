"""Planner-authorized specification of the exact-subset Git commit primitive.

Adds one additive Git-layer primitive alongside the frozen
:func:`~lockstep.git.commit.commit_exact_paths`:

    commit_exact_paths
        the complete dirty set must equal the approved set;
        the commit consumes the complete dirty set.

    commit_exact_subset_paths
        the approved set must be a non-empty exact subset of the current
        dirty set; the commit consumes exactly the approved paths while
        every other dirty path remains dirty and uncommitted.

This closes the Sub-phase 9.13 frozen-artifact-correction gap: a resumed
Implementer turn may produce an authorized frozen-artifact correction and
ordinary production work in the same turn, and the Supervisor must be able
to commit only the authorized correction paths while leaving the ordinary
production work dirty for a later, separate commit. No stash, checkout,
restore, or clean is used to achieve this -- the residual dirty work is
never touched.

``commit_exact_paths`` itself is exercised, unchanged, by
``tests/test_git_commit.py``; this module never edits that file.
"""

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
from lockstep.git.commit import commit_exact_subset_paths


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
    output = _git_stdout(repo, "diff", "--cached", "--name-only", "--no-renames")
    if not output:
        return ()
    return tuple(sorted(output.splitlines()))


def _head_paths(repo: Path) -> tuple[str, ...]:
    output = _git_stdout(
        repo, "diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", "HEAD"
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
    (repo / "tracked_a.txt").write_text("a\n")
    (repo / "tracked_b.txt").write_text("b\n")
    (repo / "tracked_c.txt").write_text("c\n")

    _git(repo, "add", "README.md", "tracked_a.txt", "tracked_b.txt", "tracked_c.txt")
    _git(repo, "commit", "-m", "initial")
    _git(repo, "branch", "-M", "main")

    return repo


def _create_run(tmp_path: Path) -> tuple[Path, Path, str]:
    source = _init_repo(tmp_path)
    worktree = tmp_path / "run-worktree"
    branch = "lockstep/run/run-001"

    create_run_worktree(source, worktree, branch)

    return source, worktree, branch


# ===========================================================================
# Basic exact-subset commits (section 13)
# ===========================================================================


def test_subset_commit_of_two_dirty_paths_leaves_the_other_dirty(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)

    (worktree / "tracked_a.txt").write_text("changed a\n")
    (worktree / "tracked_b.txt").write_text("changed b\n")
    assert set(inspect_repository(worktree).dirty_paths) == {"tracked_a.txt", "tracked_b.txt"}

    result = commit_exact_subset_paths(
        worktree,
        expected_branch=branch,
        expected_head_sha=before.head_sha,
        paths=("tracked_a.txt",),
        message="fix: correct frozen retry artifacts",
    )

    assert isinstance(result, GitCommitResult)
    assert result.root == worktree.resolve()
    assert result.branch == branch
    assert result.parent_sha == before.head_sha
    assert result.committed_paths == ("tracked_a.txt",)

    after = inspect_repository(worktree)
    assert after.head_sha == result.commit_sha
    assert after.head_sha != before.head_sha
    assert after.dirty_paths == ("tracked_b.txt",)
    assert _head_paths(worktree) == ("tracked_a.txt",)
    assert _staged_paths(worktree) == ()
    assert (worktree / "tracked_b.txt").read_text() == "changed b\n"


def test_subset_commit_of_three_dirty_paths_commits_exactly_two(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)

    (worktree / "tracked_a.txt").write_text("changed a\n")
    (worktree / "tracked_b.txt").write_text("changed b\n")
    (worktree / "tracked_c.txt").write_text("changed c\n")

    result = commit_exact_subset_paths(
        worktree,
        expected_branch=branch,
        expected_head_sha=before.head_sha,
        paths=("tracked_a.txt", "tracked_c.txt"),
        message="fix: correct frozen retry artifacts",
    )

    assert result.committed_paths == ("tracked_a.txt", "tracked_c.txt")
    after = inspect_repository(worktree)
    assert after.dirty_paths == ("tracked_b.txt",)
    assert _head_paths(worktree) == ("tracked_a.txt", "tracked_c.txt")
    assert (worktree / "tracked_b.txt").read_text() == "changed b\n"


def test_subset_commit_accepts_an_untracked_approved_path(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)

    (worktree / "new_frozen.txt").write_text("new frozen content\n")
    (worktree / "tracked_a.txt").write_text("changed a\n")

    result = commit_exact_subset_paths(
        worktree,
        expected_branch=branch,
        expected_head_sha=before.head_sha,
        paths=("new_frozen.txt",),
        message="fix: correct frozen retry artifacts",
    )

    assert result.committed_paths == ("new_frozen.txt",)
    after = inspect_repository(worktree)
    assert after.dirty_paths == ("tracked_a.txt",)
    assert _head_paths(worktree) == ("new_frozen.txt",)


def test_subset_commit_accepts_a_deleted_approved_path(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)

    (worktree / "tracked_a.txt").unlink()
    (worktree / "tracked_b.txt").write_text("changed b\n")

    result = commit_exact_subset_paths(
        worktree,
        expected_branch=branch,
        expected_head_sha=before.head_sha,
        paths=("tracked_a.txt",),
        message="fix: correct frozen retry artifacts",
    )

    assert result.committed_paths == ("tracked_a.txt",)
    after = inspect_repository(worktree)
    assert after.dirty_paths == ("tracked_b.txt",)
    assert _head_paths(worktree) == ("tracked_a.txt",)


def test_subset_commit_residual_mixes_tracked_and_untracked_paths(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)

    (worktree / "tracked_a.txt").write_text("frozen correction\n")
    (worktree / "tracked_b.txt").write_text("ordinary production change\n")
    (worktree / "new_production.txt").write_text("ordinary production new file\n")

    result = commit_exact_subset_paths(
        worktree,
        expected_branch=branch,
        expected_head_sha=before.head_sha,
        paths=("tracked_a.txt",),
        message="fix: correct frozen retry artifacts",
    )

    assert result.committed_paths == ("tracked_a.txt",)
    after = inspect_repository(worktree)
    assert after.dirty_paths == ("new_production.txt", "tracked_b.txt")
    assert (worktree / "tracked_b.txt").read_text() == "ordinary production change\n"
    assert (worktree / "new_production.txt").read_text() == "ordinary production new file\n"


# ===========================================================================
# The commit never silently absorbs residual work (section 6)
# ===========================================================================


def test_subset_commit_never_includes_a_residual_path(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)

    (worktree / "tracked_a.txt").write_text("frozen correction\n")
    (worktree / "tracked_b.txt").write_text("ordinary production change\n")

    result = commit_exact_subset_paths(
        worktree,
        expected_branch=branch,
        expected_head_sha=before.head_sha,
        paths=("tracked_a.txt",),
        message="fix: correct frozen retry artifacts",
    )

    assert "tracked_b.txt" not in result.committed_paths
    assert "tracked_b.txt" not in _head_paths(worktree)
    assert _staged_paths(worktree) == ()


# ===========================================================================
# Rejections (section 14)
# ===========================================================================


def test_empty_approved_set_is_rejected(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)
    (worktree / "tracked_a.txt").write_text("changed a\n")

    with pytest.raises(GitCommitPolicyError):
        commit_exact_subset_paths(
            worktree,
            expected_branch=branch,
            expected_head_sha=before.head_sha,
            paths=(),
            message="fix: correct frozen retry artifacts",
        )

    assert _staged_paths(worktree) == ()
    assert inspect_repository(worktree).head_sha == before.head_sha
    assert inspect_repository(worktree).dirty_paths == ("tracked_a.txt",)


def test_approved_path_not_dirty_is_rejected(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)
    (worktree / "tracked_a.txt").write_text("changed a\n")

    with pytest.raises(GitCommitPolicyError) as exc_info:
        commit_exact_subset_paths(
            worktree,
            expected_branch=branch,
            expected_head_sha=before.head_sha,
            paths=("tracked_b.txt",),
            message="fix: correct frozen retry artifacts",
        )

    assert exc_info.value.expected_paths == ("tracked_b.txt",)
    assert exc_info.value.actual_paths == ("tracked_a.txt",)
    assert _staged_paths(worktree) == ()
    assert inspect_repository(worktree).head_sha == before.head_sha
    assert inspect_repository(worktree).dirty_paths == ("tracked_a.txt",)


def test_approved_set_not_fully_dirty_is_rejected(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)
    (worktree / "tracked_a.txt").write_text("changed a\n")

    with pytest.raises(GitCommitPolicyError):
        commit_exact_subset_paths(
            worktree,
            expected_branch=branch,
            expected_head_sha=before.head_sha,
            paths=("tracked_a.txt", "tracked_b.txt"),
            message="fix: correct frozen retry artifacts",
        )

    assert _staged_paths(worktree) == ()
    assert inspect_repository(worktree).head_sha == before.head_sha
    assert inspect_repository(worktree).dirty_paths == ("tracked_a.txt",)


def test_preexisting_staged_change_contaminates_and_is_rejected(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)

    (worktree / "tracked_a.txt").write_text("frozen correction\n")
    (worktree / "tracked_b.txt").write_text("staged foreign change\n")
    _git(worktree, "add", "tracked_b.txt")

    with pytest.raises(GitCommitPolicyError) as exc_info:
        commit_exact_subset_paths(
            worktree,
            expected_branch=branch,
            expected_head_sha=before.head_sha,
            paths=("tracked_a.txt",),
            message="fix: correct frozen retry artifacts",
        )

    assert "staged" in exc_info.value.reason
    assert exc_info.value.actual_paths == ("tracked_b.txt",)
    assert _staged_paths(worktree) == ("tracked_b.txt",)
    assert inspect_repository(worktree).head_sha == before.head_sha


def test_wrong_branch_is_rejected_before_staging(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)
    (worktree / "tracked_a.txt").write_text("changed a\n")
    (worktree / "tracked_b.txt").write_text("changed b\n")

    with pytest.raises(GitCommitPolicyError) as exc_info:
        commit_exact_subset_paths(
            worktree,
            expected_branch=f"{branch}-other",
            expected_head_sha=before.head_sha,
            paths=("tracked_a.txt",),
            message="fix: correct frozen retry artifacts",
        )

    assert "branch" in exc_info.value.reason
    assert _staged_paths(worktree) == ()
    assert inspect_repository(worktree).head_sha == before.head_sha


def test_unexpected_head_is_rejected_before_staging(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    (worktree / "tracked_a.txt").write_text("changed a\n")
    (worktree / "tracked_b.txt").write_text("changed b\n")

    with pytest.raises(GitCommitPolicyError) as exc_info:
        commit_exact_subset_paths(
            worktree,
            expected_branch=branch,
            expected_head_sha="0" * 40,
            paths=("tracked_a.txt",),
            message="fix: correct frozen retry artifacts",
        )

    assert "HEAD" in exc_info.value.reason
    assert _staged_paths(worktree) == ()


@pytest.mark.parametrize(
    "paths",
    [
        ("tracked_a.txt", "tracked_a.txt"),
        ("/absolute.txt",),
        ("../outside.txt",),
        (".git/config",),
        ("./tracked_a.txt",),
    ],
)
def test_invalid_approved_path_shapes_are_rejected(
    tmp_path: Path,
    paths: tuple[str, ...],
) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)
    (worktree / "tracked_a.txt").write_text("changed a\n")

    with pytest.raises(GitCommitPolicyError):
        commit_exact_subset_paths(
            worktree,
            expected_branch=branch,
            expected_head_sha=before.head_sha,
            paths=paths,
            message="fix: correct frozen retry artifacts",
        )

    assert _staged_paths(worktree) == ()
    assert inspect_repository(worktree).head_sha == before.head_sha


@pytest.mark.parametrize("message", ["", " ", "\n"])
def test_blank_commit_message_is_rejected_before_staging(
    tmp_path: Path,
    message: str,
) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)
    (worktree / "tracked_a.txt").write_text("changed a\n")

    with pytest.raises(GitCommitPolicyError):
        commit_exact_subset_paths(
            worktree,
            expected_branch=branch,
            expected_head_sha=before.head_sha,
            paths=("tracked_a.txt",),
            message=message,
        )

    assert _staged_paths(worktree) == ()
    assert inspect_repository(worktree).head_sha == before.head_sha


# ===========================================================================
# commit_exact_paths remains exactly frozen (section 15 -- reused here only
# to prove the two primitives coexist without interference; the existing
# tests/test_git_commit.py file itself is never edited)
# ===========================================================================


def test_commit_exact_paths_still_requires_the_full_dirty_set(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)
    (worktree / "tracked_a.txt").write_text("changed a\n")
    (worktree / "tracked_b.txt").write_text("changed b\n")

    with pytest.raises(GitCommitPolicyError):
        commit_exact_paths(
            worktree,
            expected_branch=branch,
            expected_head_sha=before.head_sha,
            paths=("tracked_a.txt",),
            message="feat: full commit still requires everything dirty",
        )

    assert inspect_repository(worktree).head_sha == before.head_sha


def test_both_primitives_compose_into_two_separate_commits(tmp_path: Path) -> None:
    _, worktree, branch = _create_run(tmp_path)
    before = inspect_repository(worktree)

    (worktree / "tracked_a.txt").write_text("frozen correction\n")
    (worktree / "tracked_b.txt").write_text("ordinary production change\n")

    correction = commit_exact_subset_paths(
        worktree,
        expected_branch=branch,
        expected_head_sha=before.head_sha,
        paths=("tracked_a.txt",),
        message="fix: correct frozen retry artifacts",
    )

    production = commit_exact_paths(
        worktree,
        expected_branch=branch,
        expected_head_sha=correction.commit_sha,
        paths=("tracked_b.txt",),
        message="feat: ordinary production change",
    )

    assert correction.commit_sha != production.commit_sha
    assert production.parent_sha == correction.commit_sha
    assert inspect_repository(worktree).is_clean is True
    assert _git_stdout(worktree, "log", "--format=%s") == (
        "feat: ordinary production change\nfix: correct frozen retry artifacts\ninitial"
    )
