"""Phase 11.2: a run worktree may be rooted at a prior accepted run branch.

Sequential Sub-phases need Sub-phase B's transaction to start from Sub-phase
A's accepted implementation commit without mutating the user's source
checkout. ``create_run_worktree`` therefore gains one optional, keyword-only
``base_branch``; omitting it preserves the accepted behavior exactly.
"""

import subprocess
from pathlib import Path

import pytest

from lockstep.git import WorktreeCreationError, create_run_worktree, inspect_repository


def _git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=check, capture_output=True, text=True
    )


def _out(repo: Path, *args: str) -> str:
    return _git(repo, *args).stdout.strip()


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


def _commit_on_run_branch(worktree: Path, name: str) -> str:
    (worktree / name).write_text(name)
    _git(worktree, "add", name)
    _git(worktree, "commit", "-m", f"add {name}")
    return _out(worktree, "rev-parse", "HEAD")


def test_base_branch_roots_the_new_worktree_at_that_branch_tip(tmp_path: Path) -> None:
    source = _init_repo(tmp_path)
    first = create_run_worktree(source, tmp_path / "wt-a", "lockstep/run/a")
    tip = _commit_on_run_branch(first.root, "a.txt")

    second = create_run_worktree(
        source, tmp_path / "wt-b", "lockstep/run/b", base_branch="lockstep/run/a"
    )

    assert second.head_sha == tip
    assert second.branch == "lockstep/run/b"
    assert (second.root / "a.txt").read_text() == "a.txt"
    assert second.dirty_paths == ()


def test_base_branch_never_moves_or_dirties_the_source_checkout(tmp_path: Path) -> None:
    source = _init_repo(tmp_path)
    before = _out(source, "rev-parse", "HEAD")
    first = create_run_worktree(source, tmp_path / "wt-a", "lockstep/run/a")
    _commit_on_run_branch(first.root, "a.txt")

    create_run_worktree(source, tmp_path / "wt-b", "lockstep/run/b", base_branch="lockstep/run/a")

    assert _out(source, "rev-parse", "HEAD") == before
    assert _out(source, "rev-parse", "--abbrev-ref", "HEAD") == "main"
    assert inspect_repository(source).dirty_paths == ()
    assert not (source / "a.txt").exists()


def test_history_of_the_second_branch_is_linear_on_top_of_the_first(tmp_path: Path) -> None:
    source = _init_repo(tmp_path)
    first = create_run_worktree(source, tmp_path / "wt-a", "lockstep/run/a")
    _commit_on_run_branch(first.root, "a.txt")
    second = create_run_worktree(
        source, tmp_path / "wt-b", "lockstep/run/b", base_branch="lockstep/run/a"
    )
    _commit_on_run_branch(second.root, "b.txt")

    subjects = _out(second.root, "log", "--format=%s").splitlines()
    assert subjects == ["add b.txt", "add a.txt", "initial"]
    assert _out(second.root, "log", "--merges", "--format=%H") == ""


def test_omitting_base_branch_is_the_accepted_source_head_behavior(tmp_path: Path) -> None:
    source = _init_repo(tmp_path)
    snapshot = create_run_worktree(source, tmp_path / "wt", "lockstep/run/a")
    assert snapshot.head_sha == _out(source, "rev-parse", "HEAD")


def test_missing_base_branch_is_rejected_before_any_mutation(tmp_path: Path) -> None:
    source = _init_repo(tmp_path)
    with pytest.raises(WorktreeCreationError, match="base branch"):
        create_run_worktree(source, tmp_path / "wt", "lockstep/run/b", base_branch="no/such")
    assert not (tmp_path / "wt").exists()
    listed = _git(source, "branch", "--list", "lockstep/run/b").stdout.strip()
    assert listed == ""


def test_base_branch_equal_to_the_new_branch_is_rejected(tmp_path: Path) -> None:
    source = _init_repo(tmp_path)
    with pytest.raises(WorktreeCreationError):
        create_run_worktree(source, tmp_path / "wt", "main", base_branch="main")


def test_base_branch_that_does_not_descend_from_source_head_is_rejected(tmp_path: Path) -> None:
    source = _init_repo(tmp_path)
    # An unrelated orphan branch: not a descendant of the source HEAD.
    _git(source, "checkout", "--orphan", "stranger")
    _git(source, "rm", "-rf", ".")
    (source / "other.txt").write_text("x")
    _git(source, "add", "other.txt")
    _git(source, "commit", "-m", "unrelated root")
    _git(source, "checkout", "main")

    with pytest.raises(WorktreeCreationError, match="descend"):
        create_run_worktree(source, tmp_path / "wt", "lockstep/run/b", base_branch="stranger")
    assert not (tmp_path / "wt").exists()


def test_transaction_request_carries_an_optional_base_branch_defaulting_to_none() -> None:
    import dataclasses

    from lockstep.supervisor.transaction import SingleSubphaseTransactionRequest

    fields = {f.name: f for f in dataclasses.fields(SingleSubphaseTransactionRequest)}
    assert fields["base_branch"].default is None


def test_base_branch_is_keyword_only() -> None:
    import inspect

    parameter = inspect.signature(create_run_worktree).parameters["base_branch"]
    assert parameter.kind is inspect.Parameter.KEYWORD_ONLY
    assert parameter.default is None
