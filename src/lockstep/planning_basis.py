"""The authoritative repository basis of project-level planning (12.10-R1).

A Planner that reasons about current or future implementation must inspect what the project
has actually accepted, not the user's untouched source checkout::

    no accepted Sub-phase yet       -> no alternate basis: the source checkout is legitimate
    accepted history exists         -> worktrees/<last completed run>  on  lockstep/run/<run>
                                       verified before the Planner launches and re-verified
                                       after it returns; any mismatch fails closed

The verified worktree is the one 12.9 teardown always retains: the cursor's latest accepted
Sub-phase. It must be a repository root on its run branch, with no tracked change, HEAD equal
to the branch tip, and -- when that unit closed a finalized Phase -- HEAD equal to the
finalization's accepted basis commit. The source checkout is never checked out, reset,
merged into or copied to: planning moves to the accepted basis, never the reverse.

Only the Planner's code/tool view moves. Durable project configuration -- the frozen Master
Plan, the tracked ContextSelection and the selected document bytes -- is still read from the
project root (the accepted 12.2 rule), so unaccepted edits never become guidance.

The basis is described exactly as JIT replanning describes its own
(:class:`~lockstep.jit_replan.ReplanBasis`): descriptive execution evidence naming the
accepted unit, its branch and its commit, never Contract authority.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

from lockstep.domain import PhaseId
from lockstep.git import GitCommandError, inspect_repository
from lockstep.git.evidence import branch_commit
from lockstep.jit_replan import ReplanBasis
from lockstep.project_cursor import ProjectCursor


class PlanningBasisError(Exception):
    """The accepted planning basis cannot be established or moved during planning.

    Carries a short, bounded, deterministic ``reason`` that never contains file contents.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"planning basis error: {reason}")


@dataclass(frozen=True, slots=True)
class AcceptedPlanningBasis:
    """The verified accepted worktree a Planner runs in, and its descriptive basis record."""

    worktree: Path
    basis: ReplanBasis


def _verified_head(worktree: Path, branch: str) -> str:
    try:
        snapshot = inspect_repository(worktree)
        tip = branch_commit(worktree, branch)
    except (GitCommandError, OSError) as exc:
        raise PlanningBasisError("the accepted worktree is unavailable") from exc
    if snapshot.root != worktree:
        raise PlanningBasisError("the accepted worktree is not a repository root")
    if snapshot.branch != branch:
        raise PlanningBasisError("the accepted worktree is not on the accepted branch")
    if snapshot.staged_paths or snapshot.unstaged_paths:
        raise PlanningBasisError("the accepted worktree has uncommitted tracked changes")
    if tip != snapshot.head_sha:
        raise PlanningBasisError("the accepted worktree is not at its branch tip")
    return snapshot.head_sha


def accepted_planning_basis(
    runtime_dir: Path, cursor: ProjectCursor | None
) -> AcceptedPlanningBasis | None:
    """The verified latest accepted basis, or ``None`` when nothing has been accepted yet."""
    if cursor is None or not cursor.completed_subphases:
        return None
    # Imported here: the orchestrator and the finalization module both import the planning
    # workflow, which imports this module.
    from lockstep.phase_context_finalization import (
        PhaseContextFinalizationError,
        load_phase_context_finalization,
    )
    from lockstep.project_orchestrator import transaction_branch, transaction_worktree_path

    last = cursor.completed_subphases[-1]
    worktree = transaction_worktree_path(runtime_dir, last.run_id).resolve()
    branch = transaction_branch(last.run_id)
    head = _verified_head(worktree, branch)

    if cursor.completed_phases:
        try:
            final = load_phase_context_finalization(runtime_dir, cursor.completed_phases[-1])
        except PhaseContextFinalizationError as exc:
            raise PlanningBasisError(f"phase finalization: {exc.reason}") from exc
        if (
            final is not None
            and final.final_phase_gate.basis_run_id == last.run_id
            and final.final_repository_basis_commit != head
        ):
            raise PlanningBasisError("the accepted worktree disagrees with the phase finalization")

    return AcceptedPlanningBasis(
        worktree=worktree,
        basis=ReplanBasis(
            phase_id=last.phase_id,
            subphase_id=last.subphase_id,
            run_id=last.run_id,
            contract_digest=last.contract_digest,
            branch=branch,
            commit=head,
        ),
    )


def require_unmoved_planning_basis(selected: AcceptedPlanningBasis) -> None:
    """Prove a read-only Planner left the accepted basis exactly as it was verified."""
    try:
        snapshot = inspect_repository(selected.worktree)
    except (GitCommandError, OSError) as exc:
        raise PlanningBasisError("the planner moved the accepted repository state") from exc
    if (
        snapshot.head_sha != selected.basis.commit
        or snapshot.branch != selected.basis.branch
        or snapshot.staged_paths
        or snapshot.unstaged_paths
    ):
        raise PlanningBasisError("the planner moved the accepted repository state")


def finalized_planning_references(
    runtime_dir: Path, cursor: ProjectCursor | None
) -> tuple[tuple[PhaseId, str], ...]:
    """The 12.8 compact references of every verified completed-Phase finalization."""
    if cursor is None:
        return ()
    from lockstep.phase_context_finalization import (
        PhaseContextFinalizationError,
        finalized_phase_references,
    )

    try:
        return finalized_phase_references(runtime_dir, cursor)
    except PhaseContextFinalizationError as exc:
        raise PlanningBasisError(f"phase finalization: {exc.reason}") from exc


__all__ = [
    "AcceptedPlanningBasis",
    "PlanningBasisError",
    "accepted_planning_basis",
    "finalized_planning_references",
    "require_unmoved_planning_basis",
]
