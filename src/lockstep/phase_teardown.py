"""Deterministic teardown of a completed Phase's transient execution residue.

Once a Phase is durably finalized *and* recorded complete, the execution residue that only
served to produce it is removed, so later work reconstructs from durable truth instead of
relying on leftovers::

    verified PhaseContextFinalization  +  phase_id in cursor.completed_phases
        -> exact target set derived from the finalization and the cursor
        -> every target validated before anything is deleted
        -> Git-aware worktree removal, bounded cache deletion
        -> target absence and the finalization re-verified

Both prerequisites are required. A finalization whose Phase the cursor has not yet completed
(the crash window between finalization and completion) is never torn down, and a completed
Phase without a finalization (a runtime that completed it before finalizations existed) is
left exactly as it is: no inference, no migration, no synthetic finalization.

The target set is bounded by one finalization and one cursor -- never a scan of runtime state:

    worktrees/<run-id>                        each finalized run's linked Git worktree
    worktrees/.lockstep-pycache-<run-id>      each finalized run's verification bytecode cache
    .lockstep-gate-pycache/<phase>-attempt-<n> each durable gate attempt's bytecode cache

One worktree is never a target: the worktree of the cursor's latest accepted Sub-phase. It is
the live accepted repository basis -- the next Contract's test targets are checked against it
and a Phase with no Sub-phase of its own is gated on it -- and once the project is complete it
is the final accepted checkout. It becomes a target of its Phase's teardown as soon as a later
Sub-phase is accepted.

Everything durable stays: the cursor, every finalization, gate decisions, bases, evidence and
events, archived Contracts, transaction journals, state, artifacts, retry and settlement
records, JIT receipts, project-run history, the Project Digest, the tracked ContextSelection,
the Master Plan, and every run branch and accepted commit. Lockstep persists no provider
session state and no rendered prompt or ContextPack, so neither has anything to remove.

A worktree is removed only through ``git worktree remove`` without ``--force``, after proving
it is exactly the registered, unlocked worktree of its run, on its run branch, at the accepted
commit, with no tracked change and no untracked file; anything else fails closed before any
target is touched. Caches are deleted only as real directories directly beneath their expected
parent, never through a symlink. Deletion is naturally idempotent and needs no receipt: a
crash at any point is finished by running teardown again, which recomputes the same target
set, accepts targets already gone, unregisters a registration whose directory is already gone,
and removes the rest. No provider is invoked; the finalization and the cursor are never written.
"""

from __future__ import annotations

import contextlib
import os
import shutil
import stat
from dataclasses import dataclass
from pathlib import Path

from lockstep.domain import PhaseId, RunId
from lockstep.git import (
    GitCommandError,
    inspect_repository,
    linked_worktree_common_dir,
    registered_worktrees,
    remove_linked_worktree,
)
from lockstep.git.evidence import branch_commit
from lockstep.persistence import StateConsistencyError, load_verified_state
from lockstep.persistence.journal import JournalIntegrityError
from lockstep.persistence.state_store import StatePersistenceError
from lockstep.phase_context_finalization import (
    PhaseContextFinalization,
    finalize_phase_context,
    load_phase_context_finalization,
)
from lockstep.phase_gate import PhaseGateError, list_phase_gate_attempts, load_phase_gate_decision
from lockstep.planning_store import PlanningStoreError
from lockstep.project_cursor import ProjectCursor, ProjectCursorError
from lockstep.project_cursor_store import ProjectCursorStoreError, load_project_cursor
from lockstep.project_orchestrator import (
    transaction_branch,
    transaction_runtime_dir,
    transaction_worktree_path,
)
from lockstep.runtime import AgentRuntime
from lockstep.state import WorkflowState

# The verification bytecode-cache namespaces the transaction and the gate own (each module
# keeps its own name private).
_RUN_CACHE_PREFIX = ".lockstep-pycache-"
_GATE_CACHE_DIR_NAME = ".lockstep-gate-pycache"
_JOURNAL_NAME = "events.jsonl"
_STATE_NAME = "state.json"


class PhaseTeardownError(Exception):
    """A completed Phase's residue could not be proven safe to remove, or was not removed.

    Carries a short, bounded, deterministic ``reason``. Nothing is deleted after a refusal
    raised while the target set is being validated.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"phase teardown refused: {reason}")


@dataclass(frozen=True, slots=True)
class WorktreeTarget:
    """One finalized run's worktree and the commit its run branch must still name."""

    run_id: RunId
    path: Path
    branch: str
    accepted_commit: str


@dataclass(frozen=True, slots=True)
class PhaseTeardownPlan:
    """The exact, deterministic teardown target set of one completed Phase."""

    phase_id: PhaseId
    worktrees: tuple[WorktreeTarget, ...]
    caches: tuple[Path, ...]
    retained_basis: RunId | None


@dataclass(frozen=True, slots=True)
class PhaseTeardownResult:
    """What one teardown call removed; empty tuples when everything was already gone."""

    phase_id: PhaseId
    removed_worktrees: tuple[RunId, ...]
    removed_caches: tuple[Path, ...]
    retained_basis: RunId | None


# --- Eligibility and the target set ----------------------------------------------------------


def _load_cursor(runtime: AgentRuntime) -> ProjectCursor:
    try:
        cursor = load_project_cursor(runtime.project_root, runtime.runtime_dir)
    except (ProjectCursorStoreError, ProjectCursorError, PlanningStoreError) as exc:
        raise PhaseTeardownError("the project cursor cannot be loaded") from exc
    if cursor is None:
        raise PhaseTeardownError("the project cursor is not initialized")
    return cursor


def _verified_finalization(
    runtime: AgentRuntime, cursor: ProjectCursor, phase_id: PhaseId
) -> PhaseContextFinalization:
    if phase_id not in cursor.completed_phases:
        raise PhaseTeardownError(f"phase {phase_id.root} is not recorded complete")
    try:
        recorded = load_phase_context_finalization(runtime.runtime_dir, phase_id)
        if recorded is None:
            raise PhaseTeardownError(f"phase {phase_id.root} has no phase finalization")
        decision = load_phase_gate_decision(
            runtime.runtime_dir, phase_id, recorded.final_phase_gate.gate_attempt
        )
        if decision is None:
            raise PhaseTeardownError(f"phase {phase_id.root} has no durable passing gate decision")
        # A completed Phase's finalization is verified against retained durable history only.
        verified = finalize_phase_context(runtime, decision)
    except PhaseGateError as exc:
        raise PhaseTeardownError(f"phase {phase_id.root} finalization does not verify") from exc
    if verified != recorded:
        raise PhaseTeardownError(f"phase {phase_id.root} finalization does not verify")
    return verified


def _require_canonically_complete(runtime: AgentRuntime, run_id: RunId) -> None:
    directory = transaction_runtime_dir(runtime.runtime_dir, run_id)
    try:
        snapshot = load_verified_state(directory / _STATE_NAME, directory / _JOURNAL_NAME)
    except (
        StateConsistencyError,
        StatePersistenceError,
        JournalIntegrityError,
        OSError,
        ValueError,
    ) as exc:
        raise PhaseTeardownError(f"run {run_id.root} has an unverifiable journal") from exc
    if (
        snapshot is None
        or snapshot.run_id != run_id
        or snapshot.workflow_state is not WorkflowState.SUBPHASE_COMPLETE
    ):
        raise PhaseTeardownError(f"run {run_id.root} is not canonically complete")


def phase_teardown_plan(runtime: AgentRuntime, phase_id: PhaseId) -> PhaseTeardownPlan:
    """The exact teardown target set of completed *phase_id*, or a typed refusal.

    Requires the Phase in the cursor's completed history and its finalization present and
    verifying against retained durable evidence. Read-only.
    """
    cursor = _load_cursor(runtime)
    finalization = _verified_finalization(runtime, cursor, phase_id)
    runtime_dir = runtime.runtime_dir
    live_basis = cursor.completed_subphases[-1].run_id if cursor.completed_subphases else None
    active = cursor.active_contract.transaction_run_id if cursor.active_contract else None

    worktrees: list[WorktreeTarget] = []
    caches: list[Path] = []
    retained: RunId | None = None
    for entry in finalization.completed_subphases:
        if entry.run_id == active:
            raise PhaseTeardownError(f"run {entry.run_id.root} is bound to the active contract")
        _require_canonically_complete(runtime, entry.run_id)
        caches.append(runtime_dir / "worktrees" / f"{_RUN_CACHE_PREFIX}{entry.run_id.root}")
        if entry.run_id == live_basis:
            retained = entry.run_id
            continue
        worktrees.append(
            WorktreeTarget(
                run_id=entry.run_id,
                path=transaction_worktree_path(runtime_dir, entry.run_id),
                branch=transaction_branch(entry.run_id),
                accepted_commit=entry.accepted_commit,
            )
        )
    for attempt in list_phase_gate_attempts(runtime_dir, phase_id):
        caches.append(runtime_dir / _GATE_CACHE_DIR_NAME / f"{phase_id.root}-attempt-{attempt}")
    return PhaseTeardownPlan(
        phase_id=phase_id,
        worktrees=tuple(worktrees),
        caches=tuple(caches),
        retained_basis=retained,
    )


# --- Validation: nothing is deleted until every target is proven safe -------------------------


def _lexists(path: Path) -> bool:
    try:
        os.lstat(path)
    except FileNotFoundError:
        return False
    return True


def _require_contained(path: Path, parent: Path, runtime_dir: Path) -> None:
    """*path* is a real directory directly beneath real directory *parent*, inside the runtime."""
    if parent.is_symlink() or (_lexists(parent) and not parent.is_dir()):
        raise PhaseTeardownError("a teardown parent directory is not a real directory")
    mode = os.lstat(path).st_mode
    if stat.S_ISLNK(mode):
        raise PhaseTeardownError("a teardown target is a symlink")
    if not stat.S_ISDIR(mode):
        raise PhaseTeardownError("a teardown target is not a directory")
    resolved = path.resolve()
    if resolved.parent != parent.resolve() or not resolved.is_relative_to(runtime_dir.resolve()):
        raise PhaseTeardownError("a teardown target resolves outside its runtime location")


def _validate_worktree(target: WorktreeTarget, runtime_dir: Path) -> Path:
    """Prove *target* is exactly its run's clean registered worktree; return its common dir."""
    where = f"run {target.run_id.root} worktree"
    _require_contained(target.path, runtime_dir / "worktrees", runtime_dir)
    dot_git = target.path / ".git"
    if not _lexists(dot_git) or not stat.S_ISREG(os.lstat(dot_git).st_mode):
        raise PhaseTeardownError(f"{where} is not a linked Git worktree")
    try:
        common_dir = linked_worktree_common_dir(target.path)
        snapshot = inspect_repository(target.path)
        registrations = registered_worktrees(common_dir)
        tip = branch_commit(target.path, target.branch)
    except (GitCommandError, OSError) as exc:
        raise PhaseTeardownError(f"{where} cannot be inspected") from exc
    resolved = target.path.resolve()
    matching = [r for r in registrations if r.path.resolve() == resolved]
    if len(matching) != 1:
        raise PhaseTeardownError(f"{where} is not registered exactly once")
    [registration] = matching
    if registration.locked or registration.prunable:
        raise PhaseTeardownError(f"{where} is locked or already prunable")
    if snapshot.root != resolved or snapshot.branch != target.branch:
        raise PhaseTeardownError(f"{where} is not on its run branch")
    if registration.branch != target.branch:
        raise PhaseTeardownError(f"{where} is registered on another branch")
    if tip != target.accepted_commit or snapshot.head_sha != target.accepted_commit:
        raise PhaseTeardownError(f"{where} is not at its accepted commit")
    if snapshot.staged_paths or snapshot.unstaged_paths or snapshot.untracked_paths:
        raise PhaseTeardownError(f"{where} holds uncommitted or untracked data")
    return common_dir


def _git_contexts(
    runtime: AgentRuntime, cursor: ProjectCursor, known: set[Path]
) -> tuple[Path, ...]:
    """Common Git directories through which an already-deleted worktree's registration is seen.

    Those of present targets, plus that of the live accepted basis worktree, which is never a
    target and so remains whenever any run worktree does.
    """
    contexts = set(known)
    if cursor.completed_subphases:
        basis = transaction_worktree_path(
            runtime.runtime_dir, cursor.completed_subphases[-1].run_id
        )
        if basis.is_dir() and not basis.is_symlink():
            with contextlib.suppress(GitCommandError):
                contexts.add(linked_worktree_common_dir(basis))
    return tuple(sorted(contexts))


def _stale_registrations(contexts: tuple[Path, ...], path: Path) -> tuple[tuple[Path, Path], ...]:
    """``(common_dir, registered_path)`` for every registration of now-absent *path*."""
    expected = path.parent.resolve() / path.name
    stale: list[tuple[Path, Path]] = []
    for common_dir in contexts:
        try:
            registrations = registered_worktrees(common_dir)
        except GitCommandError as exc:
            raise PhaseTeardownError("a worktree registration cannot be listed") from exc
        stale.extend((common_dir, r.path) for r in registrations if r.path == expected)
    return tuple(stale)


# --- Teardown ----------------------------------------------------------------------------------


def teardown_completed_phase(runtime: AgentRuntime, phase_id: PhaseId) -> PhaseTeardownResult:
    """Remove the transient residue of finalized, completed *phase_id*; idempotent.

    Every present target is validated before anything is deleted, so a refusal (an unverified
    finalization, an incomplete Phase, a dirty, foreign, locked or symlinked target) removes
    nothing. Already-absent targets are accepted. Afterwards every target must be absent and
    unregistered, every run branch must still name its accepted commit, and the finalization
    must still verify. Invokes no provider and writes neither the finalization nor the cursor.
    """
    plan = phase_teardown_plan(runtime, phase_id)
    runtime_dir = runtime.runtime_dir
    cursor = _load_cursor(runtime)

    present: list[tuple[WorktreeTarget, Path]] = []
    for target in plan.worktrees:
        if _lexists(target.path):
            present.append((target, _validate_worktree(target, runtime_dir)))
    caches = [cache for cache in plan.caches if _lexists(cache)]
    for cache in caches:
        _require_contained(cache, cache.parent, runtime_dir)
    contexts = _git_contexts(runtime, cursor, {common for _, common in present})

    removed: list[RunId] = []
    for target, common_dir in present:
        try:
            remove_linked_worktree(common_dir, target.path.resolve())
        except GitCommandError as exc:
            raise PhaseTeardownError(f"run {target.run_id.root} worktree was not removed") from exc
        removed.append(target.run_id)
    for target in plan.worktrees:
        for common_dir, registered in _stale_registrations(contexts, target.path):
            try:
                remove_linked_worktree(common_dir, registered)
            except GitCommandError as exc:
                raise PhaseTeardownError(
                    f"run {target.run_id.root} registration was not removed"
                ) from exc
    for cache in caches:
        try:
            shutil.rmtree(cache)
        except OSError as exc:
            raise PhaseTeardownError("a verification cache was not removed") from exc

    _verify_torn_down(runtime, plan, contexts)
    return PhaseTeardownResult(
        phase_id=phase_id,
        removed_worktrees=tuple(removed),
        removed_caches=tuple(caches),
        retained_basis=plan.retained_basis,
    )


def _verify_torn_down(
    runtime: AgentRuntime, plan: PhaseTeardownPlan, contexts: tuple[Path, ...]
) -> None:
    for path in (*(t.path for t in plan.worktrees), *plan.caches):
        if _lexists(path):
            raise PhaseTeardownError("a teardown target still exists")
    for target in plan.worktrees:
        if _stale_registrations(contexts, target.path):
            raise PhaseTeardownError(f"run {target.run_id.root} worktree is still registered")
        for common_dir in contexts:
            try:
                tip = branch_commit(common_dir, target.branch)
            except GitCommandError as exc:
                raise PhaseTeardownError("an accepted run branch cannot be resolved") from exc
            if tip != target.accepted_commit:
                raise PhaseTeardownError(
                    f"run {target.run_id.root} accepted commit is not retained"
                )
    if phase_teardown_plan(runtime, plan.phase_id) != plan:
        raise PhaseTeardownError(f"phase {plan.phase_id.root} changed during teardown")


def ensure_completed_phase_teardown(runtime: AgentRuntime) -> tuple[PhaseTeardownResult, ...]:
    """Finish the teardown of every finalized completed Phase, in completion order.

    The resume-safe re-entry point: called after a Phase completes and before ordinary work
    continues, it completes any teardown a crash or a refusal left pending. A completed Phase
    without a finalization is left untouched. A refusal propagates, so pending cleanup is never
    silently skipped.
    """
    cursor = _load_cursor(runtime)
    results: list[PhaseTeardownResult] = []
    for phase_id in cursor.completed_phases:
        try:
            recorded = load_phase_context_finalization(runtime.runtime_dir, phase_id)
        except PhaseGateError as exc:
            raise PhaseTeardownError(f"phase {phase_id.root} finalization does not verify") from exc
        if recorded is None:
            continue
        results.append(teardown_completed_phase(runtime, phase_id))
    return tuple(results)


__all__ = [
    "PhaseTeardownError",
    "PhaseTeardownPlan",
    "PhaseTeardownResult",
    "WorktreeTarget",
    "ensure_completed_phase_teardown",
    "phase_teardown_plan",
    "teardown_completed_phase",
]
