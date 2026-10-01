"""Read-only diff-size measurement between two accepted commits.

Observational only: the measurement is taken from ``git diff --numstat`` of two
commit objects, so the working tree, index, and untracked files can never
influence it. Size is a secondary signal and says nothing about correctness or
scope adherence. No generated-file classification exists in Lockstep, so none
is attempted here.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from lockstep.git.repository import GitCommandError, _run_git_text


@dataclass(frozen=True, slots=True)
class RepositoryChange:
    """Files and lines changed between two commits.

    Binary files count toward ``files_changed`` and ``binary_files_changed`` but
    contribute no lines, because Git reports no line counts for them.
    """

    files_changed: int
    lines_added: int
    lines_deleted: int
    binary_files_changed: int


def measure_repository_change(root: Path, base_sha: str, head_sha: str) -> RepositoryChange:
    """Measure the change from commit *base_sha* to commit *head_sha*."""
    for sha in (base_sha, head_sha):
        if not sha or sha.startswith("-"):
            raise GitCommandError(
                path=root,
                git_args=("diff", "--numstat"),
                reason=f"invalid commit reference {sha!r}",
                returncode=None,
            )
    result = _run_git_text(root, ["diff", "--numstat", "--no-renames", base_sha, head_sha])

    files = added = deleted = binary = 0
    for line in result.stdout.splitlines():
        if not line:
            continue
        added_text, deleted_text, _path = line.split("\t", 2)
        files += 1
        if added_text == "-" and deleted_text == "-":
            binary += 1
            continue
        added += int(added_text)
        deleted += int(deleted_text)
    return RepositoryChange(
        files_changed=files,
        lines_added=added,
        lines_deleted=deleted,
        binary_files_changed=binary,
    )
