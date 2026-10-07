"""Just-in-time replanning of the unfinished Phase outline after an accepted Sub-phase.

After a Sub-phase is canonically complete and recorded, and unfinished Phase
work still exists, a fresh Planner reconsiders the provisional remainder of the
current Phase against the accepted repository state::

    accepted Sub-phase (cursor-recorded, Contract retired)
        -> verified accepted worktree / branch / commit      (the replan basis)
        -> fresh Planner invocation inside that worktree     (read-only)
        -> candidate Phase plan
        -> host validation (completed history, frozen facts, dependencies)
        -> durable acceptance: the replan receipt            (the acceptance point)
        -> publish the revised outline, then revise the cursor
        -> the existing orchestrator plans and freezes the next single Contract

The completed prefix of the outline is never taken from the Planner: the host
compares what the Planner returned against the published outline and rejects any
change. Only the unfinished suffix -- including the selected-but-unfrozen next
Sub-phase -- may differ. A revised outline is provisional planning state; it
confers no execution authority until its first unit has a frozen Contract.

A receipt (``<runtime_dir>/planning/replans/<completed run id>.json``) proves that
replanning for one completed Sub-phase happened and what the host accepted. It is
not a progress record: the project cursor stays the sole authority on what is
current and what is complete. Because acceptance is durable *before* the outline and
cursor are published, a restart applies an accepted receipt without another model
call; a Planner answer that was not yet accepted is simply asked for again. Applying
is idempotent, so a crash between the two publications is repaired the same way.

Every call performs at most one fresh Planner inference, derived entirely from
durable repository and planning state. Writers are assumed single-process.

Since Phase 12.2 the fresh Planner's prompt is a rendered
:class:`~lockstep.context.context_pack.ContextPack` (the Project Digest when frozen,
the frozen Master Plan, the immutable completed history, the provisional suffix and
the accepted basis) followed by the replan instructions. :func:`build_jit_replan_prompt`
remains the accepted pure label-based projection of the same durable inputs.

Since 12.10-R1 every fresh replan inference carries a host-issued
:class:`~lockstep.planning_invocation.PlanningInvocationIdentity` (stage ``jit_replan``, no
target Sub-phase) and leaves STARTED / RETURNED evidence in the project planning journal,
whether or not its candidate is accepted. Basis, ContextPack, prompt and receipt are unchanged.
"""

from __future__ import annotations

import contextlib
import dataclasses
import json
import os
import uuid
from enum import StrEnum
from pathlib import Path
from typing import Annotated

from pydantic import BaseModel, ConfigDict, StringConstraints, ValidationError, field_validator

from lockstep.context.context_pack import ContextPackError, compose_context_prompt
from lockstep.context.context_pack_builder import (
    ContextSelection,
    ContextSources,
    build_jit_replan_context_pack,
)
from lockstep.context.context_selection_store import (
    ContextSelectionStoreError,
    load_context_selection,
)
from lockstep.domain import (
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    RunId,
    SchemaVersion,
    SubphaseId,
    SubphaseOutline,
)
from lockstep.git import GitCommandError, inspect_repository
from lockstep.planning import validate_master_plan
from lockstep.planning_invocation import PlanningInvocationIdentity, PlanningStage
from lockstep.planning_store import (
    load_active_subphase_contract,
    load_frozen_master_plan,
    load_phase_plan,
    publish_phase_plan,
)
from lockstep.planning_transport import PlanningArtifactKind, invoke_planner_artifact
from lockstep.project_cursor import (
    CompletedSubphase,
    ProjectCursor,
    ProjectCursorError,
    revise_unfinished_outline,
)
from lockstep.project_cursor_store import load_project_cursor, revise_cursor_unfinished_outline
from lockstep.runtime import AgentRuntime

_CURRENT_SCHEMA_VERSION: SchemaVersion = SchemaVersion.model_validate(1)
_PLANNING_DIR_NAME = "planning"
_REPLANS_DIR_NAME = "replans"

_Sha256Hex = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
_GitObjectId = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{40,64}$")]


class JitReplanError(Exception):
    """A replan was refused: the basis, the candidate, or the durable state is not acceptable.

    Carries a short, bounded, deterministic ``reason`` that never includes plan
    contents, prompt text, or provider output. Lower-layer typed failures
    (:class:`~lockstep.planning_transport.PlanningTransportError`,
    :class:`~lockstep.planning.PlanningValidationError`, store errors) propagate
    unwrapped.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"jit replan error: {reason}")


class JitReplanState(StrEnum):
    """Where replanning stands for the most recently completed Sub-phase."""

    NOT_APPLICABLE = "not_applicable"
    REPLAN_REQUIRED = "replan_required"
    REPLAN_ACCEPTED = "replan_accepted"
    REPLAN_APPLIED = "replan_applied"


class ReplanOutcome(StrEnum):
    UNCHANGED = "unchanged"
    REVISED = "revised"


class _ReplanModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class ReplanBasis(_ReplanModel):
    """The completed state a replan was performed after.

    Names the canonical completed Sub-phase and run, and the accepted branch and
    commit the Planner inspected; the commit is read from Git, never from prose.
    """

    phase_id: PhaseId
    subphase_id: SubphaseId
    run_id: RunId
    contract_digest: _Sha256Hex
    branch: str
    commit: _GitObjectId


class ReplanReceipt(_ReplanModel):
    """Durable record that one replan was host-validated and accepted.

    ``unfinished_outline`` is the accepted provisional suffix, kept so an
    interrupted publication can be completed without another model call. It does
    not name a current or completed Sub-phase.
    """

    schema_version: SchemaVersion = _CURRENT_SCHEMA_VERSION
    project_id: ProjectId
    master_plan_digest: _Sha256Hex
    basis: ReplanBasis
    outcome: ReplanOutcome
    unfinished_outline: tuple[SubphaseOutline, ...]

    @field_validator("schema_version")
    @classmethod
    def _reject_unsupported_schema_version(cls, value: SchemaVersion) -> SchemaVersion:
        if value.root != _CURRENT_SCHEMA_VERSION.root:
            raise ValueError(f"unsupported schema_version {value.root}")
        return value


# --- Layout and durable receipts ------------------------------------------------------


def replan_receipt_path(runtime_dir: Path, run_id: RunId) -> Path:
    """Where the receipt for the replan performed after *run_id* completed lives."""
    return Path(runtime_dir) / _PLANNING_DIR_NAME / _REPLANS_DIR_NAME / f"{run_id.root}.json"


def _canonical_bytes(receipt: ReplanReceipt) -> bytes:
    text = json.dumps(receipt.model_dump(mode="json"), ensure_ascii=False, separators=(",", ":"))
    return (text + "\n").encode("utf-8")


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_receipt(path: Path, receipt: ReplanReceipt) -> None:
    parent = path.parent
    temp_path = parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    try:
        try:
            parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            with os.fdopen(fd, "wb") as handle:
                handle.write(_canonical_bytes(receipt))
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp_path, path)
            _fsync_directory(parent)
        except OSError as exc:
            raise JitReplanError("cannot persist the replan receipt") from exc
    except BaseException:
        with contextlib.suppress(OSError):
            temp_path.unlink()
        raise


def load_replan_receipt(
    project_root: Path, runtime_dir: Path, run_id: RunId
) -> ReplanReceipt | None:
    """Load the accepted replan receipt for *run_id*, or ``None`` if none was accepted."""
    resolved_project = Path(project_root).resolve()
    resolved_runtime = Path(runtime_dir).resolve()
    if resolved_runtime == resolved_project or resolved_runtime.is_relative_to(resolved_project):
        raise JitReplanError("runtime directory must be outside project root")

    path = replan_receipt_path(resolved_runtime, run_id)
    for guarded in (path.parent.parent, path.parent, path):
        if guarded.is_symlink():
            raise JitReplanError("replan storage must not be a symlink")
    if not path.exists():
        return None
    try:
        receipt = ReplanReceipt.model_validate(json.loads(path.read_text(encoding="utf-8")))
    except (OSError, ValueError, ValidationError) as exc:
        raise JitReplanError("replan receipt is unreadable or malformed") from exc
    if receipt.basis.run_id != run_id:
        raise JitReplanError("replan receipt belongs to a different run")
    return receipt


# --- Reading durable state ------------------------------------------------------------


def _phase_completed(cursor: ProjectCursor) -> tuple[CompletedSubphase, ...]:
    return tuple(e for e in cursor.completed_subphases if e.phase_id == cursor.current_phase)


def _frozen_phase(project_root: Path, cursor: ProjectCursor) -> tuple[MasterPlan, PhasePlan]:
    master = load_frozen_master_plan(project_root)
    if master is None:
        raise JitReplanError("master plan is not frozen")
    phase = next((p for p in master.phases if p.phase_id == cursor.current_phase), None)
    if phase is None:
        raise JitReplanError("current phase is not in the master plan")
    return master, phase


def _require_receipt_matches(
    cursor: ProjectCursor, last: CompletedSubphase, receipt: ReplanReceipt
) -> None:
    basis = receipt.basis
    if (
        receipt.project_id != cursor.project_id
        or receipt.master_plan_digest != cursor.master_plan_digest
        or (basis.phase_id, basis.subphase_id, basis.run_id, basis.contract_digest)
        != (last.phase_id, last.subphase_id, last.run_id, last.contract_digest)
    ):
        raise JitReplanError("replan receipt does not match the completed history")


def _is_applied(
    project_root: Path,
    runtime_dir: Path,
    cursor: ProjectCursor,
    completed: int,
    receipt: ReplanReceipt,
) -> bool:
    suffix = receipt.unfinished_outline
    if (cursor.current_subphase, cursor.remaining_outline) != (
        suffix[0].subphase_id if suffix else None,
        suffix[1:],
    ):
        return False
    plan = load_phase_plan(project_root, runtime_dir)
    return (
        plan is not None
        and plan.phase_id == cursor.current_phase
        and tuple(plan.subphases[completed:]) == suffix
    )


def _assess(
    project_root: Path, runtime_dir: Path, cursor: ProjectCursor | None
) -> tuple[JitReplanState, ReplanReceipt | None]:
    if cursor is None or cursor.current_subphase is None:
        return JitReplanState.NOT_APPLICABLE, None
    completed = _phase_completed(cursor)
    if not completed:
        return JitReplanState.NOT_APPLICABLE, None

    last = completed[-1]
    receipt = load_replan_receipt(project_root, runtime_dir, last.run_id)
    if receipt is None:
        return JitReplanState.REPLAN_REQUIRED, None
    _require_receipt_matches(cursor, last, receipt)
    if _is_applied(project_root, runtime_dir, cursor, len(completed), receipt):
        return JitReplanState.REPLAN_APPLIED, receipt
    return JitReplanState.REPLAN_ACCEPTED, receipt


def jit_replan_state(project_root: Path, runtime_dir: Path) -> JitReplanState:
    """Classify the replan obligation of the most recently completed Sub-phase.

    ``NOT_APPLICABLE`` when nothing is complete yet or no unfinished work remains;
    ``REPLAN_REQUIRED`` when no accepted receipt exists; ``REPLAN_ACCEPTED`` when a
    receipt is durable but the outline and cursor do not yet both reflect it;
    ``REPLAN_APPLIED`` when they do. Read-only; derived from durable state only.
    """
    cursor = load_project_cursor(project_root, runtime_dir)
    return _assess(project_root, runtime_dir, cursor)[0]


# --- The Planner request ---------------------------------------------------------------

_MASTER_PLAN_LABEL = "Frozen Master Plan:"
_TARGET_PHASE_LABEL = "Target phase_id:"
_COMPLETED_LABEL = "Completed Sub-phases (immutable):"
_UNFINISHED_LABEL = "Unfinished provisional outline:"
_BASIS_LABEL = "Accepted repository basis:"

_REPLAN_INSTRUCTIONS = (
    "A Sub-phase of the target Phase was just accepted. Reconsider the unfinished "
    "provisional outline in light of what the accepted repository now contains.\n"
    "The frozen Master Plan above is authoritative context for the whole project.\n"
    "Preserve exactly these frozen Phase-level facts from the Master Plan: "
    "schema_version, phase_id, title, objective, depends_on, and "
    "integration_acceptance_criteria.\n"
    "The completed Sub-phases are accepted history. Never rename, reorder, edit, "
    "or remove them.\n"
    "Return the complete PhasePlan: the completed Sub-phase outlines exactly as "
    "supplied, unchanged and first and in the same order, followed by the revised "
    "unfinished Sub-phase outlines.\n"
    "You may retain, reorder, replace, split, combine, add, or remove unfinished "
    "outlines, including the next Sub-phase, which has no frozen Contract yet. If "
    "no further Sub-phase is needed in this Phase, return no unfinished outlines.\n"
    "Each unfinished Sub-phase may depend only on completed Sub-phases or on "
    "earlier unfinished Sub-phases. Sub-phase ids must be unique.\n"
    "Each Sub-phase outline must contain only subphase_id, title, objective, and "
    "depends_on. Do not create detailed SubphaseContracts or TestSpecifications, "
    "and do not create executable tests.\n"
    "Inspect the accepted repository read-only when useful. Do not modify files and "
    "do not implement any Sub-phase.\n"
    "Return only the structured PhasePlan requested by the supplied schema.\n"
)


def _canonical_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _outlines_json(outlines: tuple[SubphaseOutline, ...]) -> str:
    return _canonical_json([o.model_dump(mode="json") for o in outlines])


def _jit_replan_context_prompt(
    runtime: AgentRuntime,
    selection: ContextSelection,
    master_plan: MasterPlan,
    phase_plan: PhasePlan,
    cursor: ProjectCursor,
    basis: ReplanBasis,
) -> str:
    """The fresh Planner's prompt: a ContextPack rebuilt from durable state, then instructions."""
    # Imported here: the finalization module reaches the Phase gate, which imports the
    # orchestrator, which imports this module.
    from lockstep.phase_context_finalization import (
        PhaseContextFinalizationError,
        finalized_phase_references,
    )

    try:
        finalized = finalized_phase_references(runtime.runtime_dir, cursor)
    except PhaseContextFinalizationError as exc:
        raise JitReplanError(f"phase finalization: {exc.reason}") from exc
    sources = ContextSources(
        project_id=cursor.project_id,
        project_root=runtime.project_root,
        runtime_dir=runtime.runtime_dir,
        selection=selection,
    )
    try:
        pack = build_jit_replan_context_pack(
            sources,
            master_plan=master_plan,
            phase_plan=phase_plan,
            cursor=cursor,
            basis=basis,
            finalized_phases=finalized,
        )
    except ContextPackError as exc:
        raise JitReplanError(f"context pack: {exc.reason}") from exc
    # The instructions refer to the material "above", so they stay after it.
    return compose_context_prompt("", pack, trailer="\n" + _REPLAN_INSTRUCTIONS).text


def build_jit_replan_prompt(
    master_plan: MasterPlan, phase_plan: PhasePlan, cursor: ProjectCursor, basis: ReplanBasis
) -> str:
    """Build the fresh-Planner request from durable state alone.

    Separates the host-owned immutable completed prefix of *phase_plan* from the
    unfinished provisional suffix, and names the accepted repository basis.
    """
    assert cursor.current_phase is not None
    completed = len(_phase_completed(cursor))
    return (
        f"{_MASTER_PLAN_LABEL}\n"
        f"{_canonical_json(master_plan.model_dump(mode='json'))}\n"
        "\n"
        f"{_TARGET_PHASE_LABEL}\n"
        f"{cursor.current_phase.root}\n"
        "\n"
        f"{_COMPLETED_LABEL}\n"
        f"{_outlines_json(tuple(phase_plan.subphases[:completed]))}\n"
        "\n"
        f"{_UNFINISHED_LABEL}\n"
        f"{_outlines_json(tuple(phase_plan.subphases[completed:]))}\n"
        "\n"
        f"{_BASIS_LABEL}\n"
        f"{_canonical_json(basis.model_dump(mode='json'))}\n"
        "\n"
        f"{_REPLAN_INSTRUCTIONS}"
    )


# --- The accepted repository basis ------------------------------------------------------


def _verified_basis_commit(worktree_path: Path, branch: str) -> str:
    """Prove the worktree is exactly the accepted branch with no tracked changes; return HEAD."""
    resolved = Path(worktree_path).resolve()
    try:
        snapshot = inspect_repository(resolved)
    except (GitCommandError, OSError) as exc:
        raise JitReplanError("the accepted worktree is unavailable") from exc
    if snapshot.root != resolved:
        raise JitReplanError("the accepted worktree is not a repository root")
    if snapshot.branch != branch:
        raise JitReplanError("the accepted worktree is not on the accepted branch")
    if snapshot.staged_paths or snapshot.unstaged_paths:
        raise JitReplanError("the accepted worktree has uncommitted tracked changes")
    return snapshot.head_sha


def _require_unmodified(worktree_path: Path, branch: str, commit: str) -> None:
    if _verified_basis_commit(worktree_path, branch) != commit:
        raise JitReplanError("the planner moved the accepted repository state")


# --- Candidate acceptance --------------------------------------------------------------


def _validated_suffix(
    master: MasterPlan,
    frozen: PhasePlan,
    published: PhasePlan,
    cursor: ProjectCursor,
    completed: int,
    candidate: PhasePlan,
) -> tuple[SubphaseOutline, ...]:
    if candidate.phase_id != cursor.current_phase:
        raise JitReplanError("planner returned a phase plan for the wrong phase")
    if candidate != frozen.model_copy(update={"subphases": candidate.subphases}):
        raise JitReplanError("planner changed frozen phase-level facts")
    if tuple(candidate.subphases[:completed]) != tuple(published.subphases[:completed]):
        raise JitReplanError("planner rewrote completed history")

    validate_master_plan(
        master.model_copy(
            update={
                "phases": tuple(
                    candidate if p.phase_id == cursor.current_phase else p for p in master.phases
                )
            }
        )
    )

    suffix = tuple(candidate.subphases[completed:])
    try:
        revise_unfinished_outline(cursor, suffix)
    except ProjectCursorError as exc:
        raise JitReplanError(f"planner outline does not fit the cursor: {exc.reason}") from exc
    return suffix


def _published_outline(
    project_root: Path,
    runtime_dir: Path,
    cursor: ProjectCursor,
    frozen: PhasePlan,
    completed: tuple[CompletedSubphase, ...],
) -> PhasePlan:
    plan = load_phase_plan(project_root, runtime_dir) or frozen
    if plan.phase_id != cursor.current_phase:
        raise JitReplanError("published outline belongs to another phase")
    assert cursor.current_subphase is not None
    expected = (
        *(e.subphase_id for e in completed),
        cursor.current_subphase,
        *(o.subphase_id for o in cursor.remaining_outline),
    )
    if tuple(o.subphase_id for o in plan.subphases) != expected:
        raise JitReplanError("published outline diverges from the cursor")
    return plan


def _accept_new_replan(
    runtime: AgentRuntime,
    cursor: ProjectCursor,
    *,
    worktree_path: Path,
    branch: str,
    timeout_seconds: float,
    max_output_bytes: int,
    termination_grace_seconds: float,
    context_selection: ContextSelection,
) -> ReplanReceipt:
    project_root, runtime_dir = runtime.project_root, runtime.runtime_dir
    completed = _phase_completed(cursor)
    last = completed[-1]
    master, frozen = _frozen_phase(project_root, cursor)
    published = _published_outline(project_root, runtime_dir, cursor, frozen, completed)

    commit = _verified_basis_commit(worktree_path, branch)
    basis = ReplanBasis(
        phase_id=last.phase_id,
        subphase_id=last.subphase_id,
        run_id=last.run_id,
        contract_digest=last.contract_digest,
        branch=branch,
        commit=commit,
    )

    # The Planner inspects the accepted worktree, not the user's source checkout.
    planning_runtime = dataclasses.replace(runtime, project_root=Path(worktree_path))
    result = invoke_planner_artifact(
        planning_runtime,
        kind=PlanningArtifactKind.PHASE_PLAN,
        prompt=_jit_replan_context_prompt(
            runtime, context_selection, master, published, cursor, basis
        ),
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=termination_grace_seconds,
        planning_identity=PlanningInvocationIdentity.issue(
            project_id=cursor.project_id,
            phase_id=last.phase_id,
            target_subphase_id=None,
            stage=PlanningStage.JIT_REPLAN,
        ),
    )
    if result.kind is not PlanningArtifactKind.PHASE_PLAN or not isinstance(
        result.artifact, PhasePlan
    ):
        raise JitReplanError("planner returned an unexpected artifact")
    _require_unmodified(worktree_path, branch, commit)

    suffix = _validated_suffix(master, frozen, published, cursor, len(completed), result.artifact)
    unchanged = suffix == tuple(published.subphases[len(completed) :])
    receipt = ReplanReceipt(
        project_id=cursor.project_id,
        master_plan_digest=cursor.master_plan_digest,
        basis=basis,
        outcome=ReplanOutcome.UNCHANGED if unchanged else ReplanOutcome.REVISED,
        unfinished_outline=suffix,
    )
    _write_receipt(replan_receipt_path(runtime_dir, last.run_id), receipt)  # acceptance point
    return receipt


# --- Applying an accepted receipt -----------------------------------------------------


def _apply_receipt(
    project_root: Path, runtime_dir: Path, cursor: ProjectCursor, receipt: ReplanReceipt
) -> None:
    """Publish the accepted suffix to the outline, then to the cursor; each step is idempotent."""
    completed = len(_phase_completed(cursor))
    _, frozen = _frozen_phase(project_root, cursor)
    published = load_phase_plan(project_root, runtime_dir)
    current = published or frozen
    desired = current.model_copy(
        update={"subphases": (*current.subphases[:completed], *receipt.unfinished_outline)}
    )
    if published is None or published != desired:
        publish_phase_plan(project_root, runtime_dir, desired)

    suffix = receipt.unfinished_outline
    if (cursor.current_subphase, cursor.remaining_outline) != (
        suffix[0].subphase_id if suffix else None,
        suffix[1:],
    ):
        revise_cursor_unfinished_outline(project_root, runtime_dir, suffix)


def run_jit_replan(
    runtime: AgentRuntime,
    *,
    worktree_path: Path,
    branch: str,
    timeout_seconds: float,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
    context_selection: ContextSelection | None = None,
) -> ReplanReceipt | None:
    """Replan the unfinished outline after the most recently completed Sub-phase.

    *worktree_path* and *branch* identify the accepted run's worktree, which must be
    on that branch with no tracked changes; the Planner runs inside it. Returns
    ``None`` when replanning does not apply, otherwise the accepted receipt, now
    applied. Calling it again for the same completed Sub-phase never invokes the
    Planner again: an applied receipt is returned unchanged and an accepted one is
    applied. Refused while any Contract is frozen but not yet reflected by an
    applied replan. *context_selection* explicitly selects optional ContextPack
    documents for the fresh Planner; omitted, the project's tracked durable selection is
    loaded afresh (absent: none).
    """
    project_root, runtime_dir = runtime.project_root, runtime.runtime_dir
    cursor = load_project_cursor(project_root, runtime_dir)
    state, receipt = _assess(project_root, runtime_dir, cursor)
    if state is JitReplanState.NOT_APPLICABLE:
        return None
    assert cursor is not None
    if state is JitReplanState.REPLAN_APPLIED:
        return receipt

    if (
        cursor.active_contract is not None
        or load_active_subphase_contract(project_root, runtime_dir) is not None
    ):
        raise JitReplanError("a frozen subphase contract is active; it cannot be replanned")

    if receipt is None:
        if context_selection is None:
            try:
                context_selection = load_context_selection(project_root)
            except ContextSelectionStoreError as exc:
                raise JitReplanError(f"context selection: {exc.reason}") from exc
        receipt = _accept_new_replan(
            runtime,
            cursor,
            worktree_path=worktree_path,
            branch=branch,
            timeout_seconds=timeout_seconds,
            max_output_bytes=max_output_bytes,
            termination_grace_seconds=termination_grace_seconds,
            context_selection=context_selection,
        )
    _apply_receipt(project_root, runtime_dir, cursor, receipt)
    return receipt


__all__ = [
    "JitReplanError",
    "JitReplanState",
    "ReplanBasis",
    "ReplanOutcome",
    "ReplanReceipt",
    "build_jit_replan_prompt",
    "jit_replan_state",
    "load_replan_receipt",
    "replan_receipt_path",
    "run_jit_replan",
]
