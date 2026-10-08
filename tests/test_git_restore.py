"""Supervisor-owned exact-path restoration of a rejected, unfrozen candidate.

``restore_exact_paths`` undoes worktree changes to exactly the approved literal paths
and nothing else. It refuses -- without touching anything -- a different branch or
HEAD, any staged change, unsafe paths, and any dirty path outside the approved set, and
proves the expected HEAD/branch and a clean index and worktree afterwards. Real Git.
"""

from __future__ import annotations

import subprocess
from pathlib import Path

import pytest

from lockstep.git import (
    GitRestorePolicyError,
    GitRestoreResult,
    inspect_repository,
    restore_exact_paths,
)

_BRANCH = "main"


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True, capture_output=True, text=True
    )


def _repo(tmp_path: Path, files: dict[str, str] | None = None) -> tuple[Path, str]:
    repo = tmp_path / "repo"
    repo.mkdir()
    _git(repo, "init")
    _git(repo, "config", "user.name", "Lockstep Tests")
    _git(repo, "config", "user.email", "lockstep-tests@example.invalid")
    _git(repo, "config", "commit.gpgsign", "false")
    for path, content in {"README.md": "initial\n", **(files or {})}.items():
        target = repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content)
        _git(repo, "add", "--", path)
    _git(repo, "commit", "-m", "initial")
    _git(repo, "branch", "-M", _BRANCH)
    return repo, _git(repo, "rev-parse", "HEAD").stdout.strip()


def _restore(repo: Path, head: str, *paths: str, branch: str = _BRANCH) -> GitRestoreResult:
    return restore_exact_paths(repo, expected_branch=branch, expected_head_sha=head, paths=paths)


def _refused(repo: Path, head: str, *paths: str, branch: str = _BRANCH) -> GitRestorePolicyError:
    with pytest.raises(GitRestorePolicyError) as exc_info:
        _restore(repo, head, *paths, branch=branch)
    return exc_info.value


def test_modified_tracked_test_is_restored_to_expected_head_contents(tmp_path: Path) -> None:
    repo, head = _repo(tmp_path, {"tests/test_a.py": "original\n"})
    (repo / "tests/test_a.py").write_text("candidate\n")

    result = _restore(repo, head, "tests/test_a.py")

    assert (repo / "tests/test_a.py").read_text() == "original\n"
    assert result.restored_paths == ("tests/test_a.py",)
    assert result.removed_paths == ()
    assert inspect_repository(repo).is_clean


def test_new_untracked_test_is_removed_with_the_empty_directories_it_created(
    tmp_path: Path,
) -> None:
    repo, head = _repo(tmp_path)
    (repo / "tests" / "deep").mkdir(parents=True)
    (repo / "tests/deep/test_new.py").write_text("candidate\n")

    result = _restore(repo, head, "tests/deep/test_new.py")

    assert not (repo / "tests").exists()
    assert result.removed_paths == ("tests/deep/test_new.py",)
    assert inspect_repository(repo).is_clean


def test_a_directory_that_still_has_content_is_kept(tmp_path: Path) -> None:
    repo, head = _repo(tmp_path, {"tests/test_keep.py": "keep\n"})
    (repo / "tests/test_new.py").write_text("candidate\n")

    _restore(repo, head, "tests/test_new.py")

    assert (repo / "tests/test_keep.py").read_text() == "keep\n"


def test_multiple_exact_paths_are_restored_together(tmp_path: Path) -> None:
    repo, head = _repo(tmp_path, {"tests/test_a.py": "a\n", "tests/test_b.py": "b\n"})
    (repo / "tests/test_a.py").write_text("changed\n")
    (repo / "tests/test_b.py").unlink()  # a candidate deletion of a tracked file
    (repo / "tests/test_c.py").write_text("new\n")

    result = _restore(repo, head, "tests/test_a.py", "tests/test_b.py", "tests/test_c.py")

    assert (repo / "tests/test_a.py").read_text() == "a\n"
    assert (repo / "tests/test_b.py").read_text() == "b\n"
    assert not (repo / "tests/test_c.py").exists()
    assert result.restored_paths == ("tests/test_a.py", "tests/test_b.py")
    assert result.removed_paths == ("tests/test_c.py",)


def test_an_approved_path_that_is_already_clean_is_a_no_op(tmp_path: Path) -> None:
    repo, head = _repo(tmp_path, {"tests/test_a.py": "a\n"})
    (repo / "tests/test_b.py").write_text("new\n")

    result = _restore(repo, head, "tests/test_a.py", "tests/test_b.py")

    assert result.restored_paths == ()
    assert (repo / "tests/test_a.py").read_text() == "a\n"


def test_an_unrelated_dirty_path_is_refused_and_never_cleaned(tmp_path: Path) -> None:
    repo, head = _repo(tmp_path)
    (repo / "tests").mkdir()
    (repo / "tests/test_a.py").write_text("candidate\n")
    (repo / "README.md").write_text("tampered\n")
    (repo / "stray.txt").write_text("stray\n")

    error = _refused(repo, head, "tests/test_a.py")

    assert error.actual_paths == ("README.md", "stray.txt")
    # Nothing was touched, approved candidate included.
    assert (repo / "README.md").read_text() == "tampered\n"
    assert (repo / "stray.txt").exists()
    assert (repo / "tests/test_a.py").read_text() == "candidate\n"


def test_staged_changes_are_refused(tmp_path: Path) -> None:
    repo, head = _repo(tmp_path)
    (repo / "tests").mkdir()
    (repo / "tests/test_a.py").write_text("candidate\n")
    _git(repo, "add", "tests/test_a.py")

    error = _refused(repo, head, "tests/test_a.py")

    assert "staged" in error.reason
    assert inspect_repository(repo).staged_paths == ("tests/test_a.py",)


def test_wrong_head_is_refused(tmp_path: Path) -> None:
    repo, head = _repo(tmp_path)
    (repo / "README.md").write_text("next\n")
    _git(repo, "commit", "-am", "planner moved history")
    (repo / "tests").mkdir()
    (repo / "tests/test_a.py").write_text("candidate\n")

    error = _refused(repo, head, "tests/test_a.py")

    assert "HEAD" in error.reason
    assert (repo / "tests/test_a.py").exists()


def test_wrong_branch_is_refused(tmp_path: Path) -> None:
    repo, head = _repo(tmp_path)
    (repo / "tests").mkdir()
    (repo / "tests/test_a.py").write_text("candidate\n")

    error = _refused(repo, head, "tests/test_a.py", branch="lockstep/run/other")

    assert "branch" in error.reason
    assert (repo / "tests/test_a.py").exists()


@pytest.mark.parametrize(
    "path",
    [
        pytest.param("", id="empty"),
        pytest.param("../outside.py", id="parent-traversal"),
        pytest.param("tests/../README.md", id="inner-traversal"),
        pytest.param("./tests/test_a.py", id="dot"),
        pytest.param("/abs/test_a.py", id="absolute"),
        pytest.param("tests//test_a.py", id="empty-component"),
        pytest.param(".git/config", id="git-dir"),
        pytest.param("tests/test\x00a.py", id="nul"),
    ],
)
def test_unsafe_paths_are_rejected(tmp_path: Path, path: str) -> None:
    repo, head = _repo(tmp_path)

    _refused(repo, head, path)


def test_duplicate_and_empty_path_sets_are_rejected(tmp_path: Path) -> None:
    repo, head = _repo(tmp_path)

    _refused(repo, head)
    _refused(repo, head, "tests/test_a.py", "tests/test_a.py")


def test_a_path_through_a_symlinked_directory_is_refused(tmp_path: Path) -> None:
    repo, head = _repo(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    (repo / "tests").symlink_to(outside, target_is_directory=True)

    # The symlink itself is the dirty, unapproved path: refused before anything happens.
    _refused(repo, head, "tests/test_a.py")
    assert outside.exists()


@pytest.mark.parametrize(
    "name",
    [
        pytest.param("tests/test_[weird]*?.py", id="glob-characters"),
        pytest.param("tests/test with space.py", id="space"),
        pytest.param("tests/:(top)test_magic.py", id="pathspec-magic"),
    ],
)
def test_literal_weird_but_valid_filenames_are_handled_literally(tmp_path: Path, name: str) -> None:
    sibling = "tests/test_weird.py"  # would match "test_[weird]*?.py" as a glob
    repo, head = _repo(tmp_path, {name: "tracked\n", sibling: "sibling\n"})
    (repo / name).write_text("candidate\n")

    result = _restore(repo, head, name)

    assert (repo / name).read_text() == "tracked\n"
    assert result.restored_paths == (name,)
    assert inspect_repository(repo).is_clean


def test_a_glob_like_approved_path_never_reaches_other_files(tmp_path: Path) -> None:
    repo, head = _repo(tmp_path, {"tests/test_a.py": "a\n"})
    (repo / "tests/test_a.py").write_text("changed\n")

    # "tests/test_*.py" is not dirty and is not a glob; the changed sibling is unrelated.
    error = _refused(repo, head, "tests/test_*.py")

    assert error.actual_paths == ("tests/test_a.py",)
    assert (repo / "tests/test_a.py").read_text() == "changed\n"


def test_postcondition_proves_a_clean_expected_worktree(tmp_path: Path) -> None:
    repo, head = _repo(tmp_path, {"tests/test_a.py": "a\n"})
    (repo / "tests/test_a.py").write_text("changed\n")
    (repo / "tests/test_b.py").write_text("new\n")

    result = _restore(repo, head, "tests/test_a.py", "tests/test_b.py")

    snapshot = result.snapshot
    assert snapshot.head_sha == head
    assert snapshot.branch == _BRANCH
    assert snapshot.staged_paths == ()
    assert snapshot.is_clean
    assert snapshot == inspect_repository(repo)
