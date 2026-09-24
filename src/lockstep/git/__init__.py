"""Repository inspection and Supervisor-controlled Git mutation.

Eventually mediates every Git interaction Lockstep performs, including
worktree management and the mutation boundary that only the Supervisor
role is permitted to cross. Callers depend on this package rather than
shelling out to Git directly.
"""

from lockstep.git.repository import (
    DirtyRepositoryError,
    GitCommandError,
    GitRepositorySnapshot,
    inspect_repository,
    require_clean_repository,
)
from lockstep.git.worktree import (
    WorktreeCreationError,
    create_run_worktree,
)

__all__ = [
    "DirtyRepositoryError",
    "GitCommandError",
    "GitRepositorySnapshot",
    "WorktreeCreationError",
    "create_run_worktree",
    "inspect_repository",
    "require_clean_repository",
]
