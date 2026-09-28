import subprocess
from pathlib import Path

from lockstep.git import (
    GitRepositorySnapshot,
    inspect_repository,
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
    (repo / "removable.txt").write_text("initial\n")

    _git(repo, "add", "README.md", "tracked.txt", "removable.txt")
    _git(repo, "commit", "-m", "initial")
    _git(repo, "branch", "-M", "main")

    return repo


def test_clean_repository_has_no_classified_paths(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)

    snapshot = inspect_repository(repo)

    assert isinstance(snapshot, GitRepositorySnapshot)
    assert snapshot.staged_paths == ()
    assert snapshot.unstaged_paths == ()
    assert snapshot.untracked_paths == ()
    assert snapshot.dirty_paths == ()


def test_unstaged_tracked_modification_is_classified_as_unstaged(
    tmp_path: Path,
) -> None:
    repo = _init_repo(tmp_path)

    (repo / "tracked.txt").write_text("modified but unstaged\n")

    snapshot = inspect_repository(repo)

    assert "tracked.txt" in snapshot.unstaged_paths
    assert "tracked.txt" not in snapshot.staged_paths
    assert "tracked.txt" not in snapshot.untracked_paths
    assert snapshot.dirty_paths.count("tracked.txt") == 1


def test_staged_tracked_modification_is_classified_as_staged(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)

    (repo / "tracked.txt").write_text("modified and staged\n")
    _git(repo, "add", "tracked.txt")

    snapshot = inspect_repository(repo)

    assert "tracked.txt" in snapshot.staged_paths
    assert "tracked.txt" not in snapshot.unstaged_paths
    assert "tracked.txt" not in snapshot.untracked_paths
    assert snapshot.dirty_paths.count("tracked.txt") == 1


def test_untracked_file_is_classified_as_untracked(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)

    (repo / "untracked.txt").write_text("new\n")

    snapshot = inspect_repository(repo)

    assert "untracked.txt" in snapshot.untracked_paths
    assert "untracked.txt" not in snapshot.staged_paths
    assert "untracked.txt" not in snapshot.unstaged_paths
    assert snapshot.dirty_paths.count("untracked.txt") == 1


def test_staged_new_file_is_classified_as_staged_not_untracked(
    tmp_path: Path,
) -> None:
    repo = _init_repo(tmp_path)

    (repo / "new_test.py").write_text("content\n")
    _git(repo, "add", "new_test.py")

    snapshot = inspect_repository(repo)

    assert "new_test.py" in snapshot.staged_paths
    assert "new_test.py" not in snapshot.untracked_paths


def test_path_staged_then_modified_again_appears_in_both_categories(
    tmp_path: Path,
) -> None:
    repo = _init_repo(tmp_path)

    (repo / "tracked.txt").write_text("staged\n")
    _git(repo, "add", "tracked.txt")
    (repo / "tracked.txt").write_text("staged plus unstaged\n")

    snapshot = inspect_repository(repo)

    assert "tracked.txt" in snapshot.staged_paths
    assert "tracked.txt" in snapshot.unstaged_paths
    assert snapshot.dirty_paths.count("tracked.txt") == 1


def test_mixed_repository_state_is_classified_exactly(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)

    (repo / "README.md").write_text("staged\n")
    _git(repo, "add", "README.md")
    (repo / "tracked.txt").write_text("unstaged\n")
    (repo / "untracked.txt").write_text("new\n")

    snapshot = inspect_repository(repo)

    assert snapshot.staged_paths == ("README.md",)
    assert snapshot.unstaged_paths == ("tracked.txt",)
    assert snapshot.untracked_paths == ("untracked.txt",)
    assert snapshot.dirty_paths == (
        "README.md",
        "tracked.txt",
        "untracked.txt",
    )


def test_staged_deletion_is_classified_as_staged(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)

    _git(repo, "rm", "removable.txt")

    snapshot = inspect_repository(repo)

    assert "removable.txt" in snapshot.staged_paths
    assert "removable.txt" in snapshot.dirty_paths


def test_unstaged_deletion_is_classified_as_unstaged(tmp_path: Path) -> None:
    repo = _init_repo(tmp_path)

    (repo / "removable.txt").unlink()

    snapshot = inspect_repository(repo)

    assert "removable.txt" in snapshot.unstaged_paths
    assert "removable.txt" in snapshot.dirty_paths


def test_classification_is_deterministic_across_repeated_inspection(
    tmp_path: Path,
) -> None:
    repo = _init_repo(tmp_path)

    (repo / "README.md").write_text("staged\n")
    _git(repo, "add", "README.md")
    (repo / "tracked.txt").write_text("unstaged\n")
    (repo / "untracked.txt").write_text("new\n")

    first = inspect_repository(repo)
    second = inspect_repository(repo)

    assert first.staged_paths == second.staged_paths
    assert first.unstaged_paths == second.unstaged_paths
    assert first.untracked_paths == second.untracked_paths
    assert first.dirty_paths == second.dirty_paths
