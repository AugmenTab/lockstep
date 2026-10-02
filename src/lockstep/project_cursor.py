"""Durable project / Phase execution cursor: pure model, transitions, eligibility.

A :class:`ProjectCursor` answers "where is this project run, what is
canonically complete, what is active, and what is only provisional?". It
is a progression record layered *above* the single-Sub-phase transaction:
it identifies the current unit and lets the transaction subsystem
(:mod:`lockstep.supervisor`) keep owning attempt-level workflow. It never
copies transaction state.

Authority is preserved, not inflated, by persistence:

* the Master Plan is referenced by ``project_id`` and a content digest,
  never copied or amended;
* the remaining outline is stored by value because it is the cursor's own
  *provisional* planning state; it is :class:`~lockstep.domain.SubphaseOutline`
  entries only, so a future item cannot masquerade as a Contract;
* the one active frozen Contract is a *reference* (Phase, Sub-phase,
  digest, and the transaction ``run_id`` that executes it), never an
  editable copy;
* a Sub-phase enters ``completed_subphases`` only from a transaction
  snapshot that has reached the canonical ``SUBPHASE_COMPLETE`` boundary
  for the exact run bound to the active Contract; a Reviewer ``APPROVE``
  alone never does.

Every function here is pure: no filesystem, Git, process, clock, network,
or model access. Persistence lives in :mod:`lockstep.project_cursor_store`.

Phase boundaries follow the Phase gate protocol. A Phase is added to the
completed-Phase history by exactly one transition, :func:`record_phase_gate_pass`,
from a ``READY`` gate; the successor is derived from the frozen Master Plan
order, never chosen by a caller. The final Phase's pass leaves a legal
terminal cursor (``current_phase is None``, ``PROJECT_COMPLETE``). A gate
failure may reopen the same Phase for one remediation Sub-phase through
:func:`reopen_phase_for_remediation`. :func:`require_legal_successor` accepts
only those two Phase-boundary shapes besides ordinary Sub-phase progress.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from enum import StrEnum
from typing import Annotated, Any, Self

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    ValidationError,
    field_validator,
    model_validator,
)

from lockstep.domain import (
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    RunId,
    SchemaVersion,
    SubphaseContract,
    SubphaseId,
    SubphaseOutline,
)
from lockstep.planning import validate_master_plan
from lockstep.state import RunStateSnapshot, WorkflowState

_CURRENT_SCHEMA_VERSION: SchemaVersion = SchemaVersion.model_validate(1)

_Sha256Hex = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
_PositiveStrictInt = Annotated[int, Field(strict=True, ge=1)]


class ProjectCursorError(Exception):
    """A cursor transition, binding, or identity check was refused.

    Carries a short, bounded, deterministic ``reason`` that may name a
    canonical non-secret identifier (a Phase id, a Sub-phase id, a run id)
    but never artifact contents, prompt text, or raw JSON.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"project cursor error: {reason}")


class PhaseGateStatus(StrEnum):
    """Where the current Phase stands relative to its integration gate.

    ``READY`` means every Sub-phase of the current Phase is canonically
    complete and no current Sub-phase remains; it does not mean a gate has
    run or passed. The gate's own attempts, decisions, and evidence live in
    their own durable artifacts (:mod:`lockstep.phase_gate`); this cursor only
    records the Phase boundary a PASS crosses. ``PROJECT_COMPLETE`` is the
    terminal status of a cursor with no current Phase: every Phase of the
    frozen Master Plan has passed its gate.
    """

    SUBPHASES_PENDING = "subphases_pending"
    READY = "ready"
    PROJECT_COMPLETE = "project_complete"


class PlanningEligibilityReason(StrEnum):
    ELIGIBLE = "eligible"
    ACTIVE_CONTRACT_NOT_COMPLETE = "active_contract_not_complete"
    TRANSACTION_HALTED = "transaction_halted"
    COMPLETION_NOT_RECORDED = "completion_not_recorded"
    PHASE_GATE_PENDING = "phase_gate_pending"


@dataclass(frozen=True, slots=True)
class PlanningEligibility:
    """Deterministic answer to "may the next Sub-phase Contract be planned now?"."""

    eligible: bool
    reason: PlanningEligibilityReason


class _CursorModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class CompletedSubphase(_CursorModel):
    """Immutable historical fact that one Sub-phase reached canonical completion."""

    phase_id: PhaseId
    subphase_id: SubphaseId
    run_id: RunId
    contract_digest: _Sha256Hex


class ActiveContractBinding(_CursorModel):
    """Reference to the one authoritative frozen Contract for the current Sub-phase."""

    phase_id: PhaseId
    subphase_id: SubphaseId
    contract_digest: _Sha256Hex
    transaction_run_id: RunId


class ProjectCursor(_CursorModel):
    """Canonical, immutable project / Phase execution cursor.

    ``revision`` starts at 1 and increases by exactly one per semantic
    transition. Invalid combinations are unrepresentable: construction
    rejects them.
    """

    schema_version: SchemaVersion = _CURRENT_SCHEMA_VERSION
    project_id: ProjectId
    master_plan_digest: _Sha256Hex
    revision: _PositiveStrictInt

    current_phase: PhaseId | None
    completed_phases: tuple[PhaseId, ...] = ()

    current_subphase: SubphaseId | None
    completed_subphases: tuple[CompletedSubphase, ...] = ()

    remaining_outline: tuple[SubphaseOutline, ...] = ()
    active_contract: ActiveContractBinding | None = None
    phase_gate_status: PhaseGateStatus = PhaseGateStatus.SUBPHASES_PENDING

    @field_validator("schema_version")
    @classmethod
    def _reject_unsupported_schema_version(cls, value: SchemaVersion) -> SchemaVersion:
        if value.root != _CURRENT_SCHEMA_VERSION.root:
            raise ValueError(
                f"unsupported schema_version {value.root}; "
                f"cursors currently understand only schema_version "
                f"{_CURRENT_SCHEMA_VERSION.root}"
            )
        return value

    @model_validator(mode="after")
    def _enforce_invariants(self) -> Self:
        completed_phase_ids = [phase.root for phase in self.completed_phases]
        if len(set(completed_phase_ids)) != len(completed_phase_ids):
            raise ValueError("duplicate completed phase")

        current = self.current_phase
        if current is None:
            if self.phase_gate_status is not PhaseGateStatus.PROJECT_COMPLETE:
                raise ValueError("a cursor without a current phase must be project complete")
            if not completed_phase_ids:
                raise ValueError("a project cannot be complete before any phase completes")
            if self.current_subphase is not None:
                raise ValueError("a project-complete cursor has no current subphase")
            if self.remaining_outline:
                raise ValueError("a project-complete cursor has no remaining outline")
            if self.active_contract is not None:
                raise ValueError("a project-complete cursor has no active contract")
        else:
            if self.phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE:
                raise ValueError("project complete requires that no phase is current")
            if current.root in completed_phase_ids:
                raise ValueError(f"current phase {current.root} is already completed")

        known_phases = set(completed_phase_ids)
        if current is not None:
            known_phases.add(current.root)
        seen_pairs: set[tuple[str, str]] = set()
        seen_runs: set[str] = set()
        for entry in self.completed_subphases:
            if entry.phase_id.root not in known_phases:
                raise ValueError(f"completed subphase names unknown phase {entry.phase_id.root}")
            pair = (entry.phase_id.root, entry.subphase_id.root)
            if pair in seen_pairs:
                raise ValueError(f"duplicate completed subphase {pair[0]}/{pair[1]}")
            seen_pairs.add(pair)
            if entry.run_id.root in seen_runs:
                raise ValueError(f"duplicate completed run {entry.run_id.root}")
            seen_runs.add(entry.run_id.root)

        if current is None:
            return self

        visible = {
            entry.subphase_id.root
            for entry in self.completed_subphases
            if entry.phase_id == self.current_phase
        }

        if self.current_subphase is None:
            if self.phase_gate_status is not PhaseGateStatus.READY:
                raise ValueError("a phase without a current subphase must have a ready gate")
            if self.remaining_outline:
                raise ValueError("remaining outline requires a current subphase")
            if self.active_contract is not None:
                raise ValueError("active contract requires a current subphase")
        else:
            if self.phase_gate_status is PhaseGateStatus.READY:
                raise ValueError("a ready phase gate cannot have a current subphase")
            if self.current_subphase.root in visible:
                raise ValueError(f"current subphase {self.current_subphase.root} is completed")
            visible.add(self.current_subphase.root)

        for outline in self.remaining_outline:
            if outline.subphase_id.root in visible:
                raise ValueError(f"outline repeats subphase {outline.subphase_id.root}")
            for dependency in outline.depends_on:
                if dependency.root not in visible:
                    raise ValueError(
                        f"outline subphase {outline.subphase_id.root} depends on "
                        f"{dependency.root}, which does not precede it"
                    )
            visible.add(outline.subphase_id.root)

        binding = self.active_contract
        if binding is not None and (
            binding.phase_id != self.current_phase or binding.subphase_id != self.current_subphase
        ):
            raise ValueError("active contract does not belong to the current subphase")
        return self


# --- Digests ------------------------------------------------------------------


def _digest(model: BaseModel) -> str:
    text = json.dumps(
        model.model_dump(mode="json"),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def contract_digest(contract: SubphaseContract) -> str:
    """Return the canonical lowercase SHA-256 digest of *contract*."""
    return _digest(contract)


def master_plan_digest(plan: MasterPlan) -> str:
    """Return the canonical lowercase SHA-256 digest of *plan*."""
    return _digest(plan)


# --- Construction and transitions ---------------------------------------------


def _advance(cursor: ProjectCursor, **changes: Any) -> ProjectCursor:
    """Return the validated successor of *cursor* with *changes* and ``revision + 1``."""
    data: dict[str, Any] = {name: getattr(cursor, name) for name in ProjectCursor.model_fields}
    data.update(changes)
    data["revision"] = cursor.revision + 1
    try:
        return ProjectCursor.model_validate(data)
    except ValidationError as exc:
        first = exc.errors()[0]["msg"].removeprefix("Value error, ")
        raise ProjectCursorError(f"invalid cursor transition: {first}") from exc


def new_project_cursor(
    master_plan: MasterPlan, phase_plan: PhasePlan | None = None
) -> ProjectCursor:
    """Initialize the cursor at the first Phase of a frozen *master_plan*.

    The current Sub-phase is the head of the Phase outline and the rest is
    the remaining provisional outline. *phase_plan*, when given, is the
    current provisional outline for the first Phase; it may revise only
    ``subphases`` and must keep the effective Master Plan valid. No
    Contract is bound and nothing is complete.
    """
    validate_master_plan(master_plan)
    first = master_plan.phases[0]

    source = first
    if phase_plan is not None:
        if phase_plan.phase_id != first.phase_id:
            raise ProjectCursorError("outline does not belong to the first phase")
        if phase_plan != first.model_copy(update={"subphases": phase_plan.subphases}):
            raise ProjectCursorError("outline changes frozen phase-level facts")
        validate_master_plan(
            master_plan.model_copy(update={"phases": (phase_plan, *master_plan.phases[1:])})
        )
        source = phase_plan

    subphases = source.subphases
    return ProjectCursor(
        project_id=master_plan.project_id,
        master_plan_digest=master_plan_digest(master_plan),
        revision=1,
        current_phase=first.phase_id,
        completed_phases=(),
        current_subphase=subphases[0].subphase_id,
        completed_subphases=(),
        remaining_outline=subphases[1:],
        active_contract=None,
        phase_gate_status=PhaseGateStatus.SUBPHASES_PENDING,
    )


def bind_active_contract(
    cursor: ProjectCursor,
    contract: SubphaseContract,
    *,
    transaction_run_id: RunId,
) -> ProjectCursor:
    """Bind the frozen *contract* as the one active Contract of the current Sub-phase.

    Only the current Sub-phase may be bound: a provisional outline item,
    a completed Sub-phase, or a Sub-phase of another Phase is rejected. At
    most one Contract is active; re-binding the identical Contract for the
    identical transaction run is an idempotent no-op, anything else while
    one is active is rejected.
    """
    binding = ActiveContractBinding(
        phase_id=contract.phase_id,
        subphase_id=contract.subphase_id,
        contract_digest=contract_digest(contract),
        transaction_run_id=transaction_run_id,
    )
    if cursor.active_contract == binding:
        return cursor
    if cursor.active_contract is not None:
        raise ProjectCursorError("a subphase contract is already active")
    if cursor.current_phase is None or cursor.current_subphase is None:
        raise ProjectCursorError("the current phase has no subphase left to execute")
    if contract.phase_id != cursor.current_phase:
        raise ProjectCursorError(
            f"contract phase {contract.phase_id.root} is not the current phase "
            f"{cursor.current_phase.root}"
        )
    if contract.subphase_id != cursor.current_subphase:
        raise ProjectCursorError(
            f"contract subphase {contract.subphase_id.root} is not the current subphase "
            f"{cursor.current_subphase.root}"
        )
    if any(entry.run_id == transaction_run_id for entry in cursor.completed_subphases):
        raise ProjectCursorError(f"run {transaction_run_id.root} already completed a subphase")
    return _advance(cursor, active_contract=binding)


def record_subphase_completion(
    cursor: ProjectCursor, transaction: RunStateSnapshot
) -> ProjectCursor:
    """Record canonical completion of the active Sub-phase from *transaction*.

    *transaction* must be the verified snapshot of exactly the run bound to
    the active Contract, in the same project, at ``SUBPHASE_COMPLETE``. The
    Sub-phase moves into immutable history, the active Contract is
    cleared, the head of the remaining outline becomes current (with no
    Contract), and the Phase gate becomes ``READY`` once nothing remains.
    Recording an already-recorded completion is an idempotent no-op.
    """
    if transaction.project_id != cursor.project_id:
        raise ProjectCursorError("transaction belongs to a different project")

    binding = cursor.active_contract
    if binding is None:
        recorded = any(entry.run_id == transaction.run_id for entry in cursor.completed_subphases)
        if recorded and transaction.workflow_state is WorkflowState.SUBPHASE_COMPLETE:
            return cursor
        raise ProjectCursorError("no active contract to complete")

    if transaction.run_id != binding.transaction_run_id:
        raise ProjectCursorError(
            f"transaction run {transaction.run_id.root} is not the active run "
            f"{binding.transaction_run_id.root}"
        )
    if transaction.workflow_state is not WorkflowState.SUBPHASE_COMPLETE:
        raise ProjectCursorError(
            f"transaction is {transaction.workflow_state.value}, not canonically complete"
        )

    entry = CompletedSubphase(
        phase_id=binding.phase_id,
        subphase_id=binding.subphase_id,
        run_id=binding.transaction_run_id,
        contract_digest=binding.contract_digest,
    )
    remaining = cursor.remaining_outline
    gate = PhaseGateStatus.SUBPHASES_PENDING if remaining else PhaseGateStatus.READY
    return _advance(
        cursor,
        completed_subphases=(*cursor.completed_subphases, entry),
        current_subphase=remaining[0].subphase_id if remaining else None,
        remaining_outline=remaining[1:],
        active_contract=None,
        phase_gate_status=gate,
    )


def revise_remaining_outline(
    cursor: ProjectCursor, remaining: tuple[SubphaseOutline, ...]
) -> ProjectCursor:
    """Replace the future provisional outline; history and the current unit are untouched."""
    if cursor.current_subphase is None:
        raise ProjectCursorError("the phase gate is ready; there is no outline to revise")
    return _advance(cursor, remaining_outline=tuple(remaining))


def revise_unfinished_outline(
    cursor: ProjectCursor, unfinished: tuple[SubphaseOutline, ...]
) -> ProjectCursor:
    """Replace the whole unfinished suffix: the current unfrozen unit and every later entry.

    Unlike :func:`revise_remaining_outline`, the head of *unfinished* becomes
    the new current Sub-phase, so a selected-but-unfrozen unit may be
    replaced, split, or dropped; an empty suffix makes the Phase gate
    ``READY`` (it never completes the Phase). Completed history is untouched.
    Refused while a Contract is active: that Sub-phase is no longer provisional.
    The head's dependencies must be completed Sub-phases of the current Phase;
    every later entry is checked by the cursor invariants.

    Deliberately not part of the frozen 11.1 ``__all__`` surface.
    """
    if cursor.current_subphase is None:
        raise ProjectCursorError("the phase gate is ready; no unfinished outline to revise")
    if cursor.active_contract is not None:
        raise ProjectCursorError("a subphase contract is active; it cannot be revised away")

    suffix = tuple(unfinished)
    if suffix:
        completed = {
            entry.subphase_id.root
            for entry in cursor.completed_subphases
            if entry.phase_id == cursor.current_phase
        }
        head = suffix[0]
        for dependency in head.depends_on:
            if dependency.root not in completed:
                raise ProjectCursorError(
                    f"outline subphase {head.subphase_id.root} depends on "
                    f"{dependency.root}, which is not completed"
                )

    return _advance(
        cursor,
        current_subphase=suffix[0].subphase_id if suffix else None,
        remaining_outline=suffix[1:],
        phase_gate_status=PhaseGateStatus.SUBPHASES_PENDING if suffix else PhaseGateStatus.READY,
    )


# --- Phase boundaries: gate PASS and gate-FAIL remediation ----------------------


def record_phase_gate_pass(
    cursor: ProjectCursor, plan: MasterPlan, *, phase_id: PhaseId
) -> ProjectCursor:
    """Record that *phase_id* passed its integration gate: the only Phase completion.

    *cursor* must be bound to the frozen *plan* and *phase_id* must be its
    current Phase with a ``READY`` gate. The Phase moves into the immutable
    completed-Phase history and the successor is derived from *plan*'s own
    Phase order: it starts at the head of its frozen outline with the rest as
    the provisional remainder and nothing bound or complete. The final Phase's
    pass yields the terminal ``PROJECT_COMPLETE`` cursor. Recording a pass that
    is already recorded is an idempotent no-op; a Phase that is neither current
    nor already complete is refused, so a pass can never skip, reorder, or
    reopen a Phase.
    """
    validate_cursor_against_master_plan(cursor, plan)
    if phase_id in cursor.completed_phases:
        return cursor
    if cursor.current_phase != phase_id:
        raise ProjectCursorError(f"phase {phase_id.root} is not the current phase")
    if (
        cursor.phase_gate_status is not PhaseGateStatus.READY
        or cursor.current_subphase is not None
        or cursor.active_contract is not None
    ):
        raise ProjectCursorError("the phase gate is not ready")

    completed = (*cursor.completed_phases, phase_id)
    successor_index = len(cursor.completed_phases) + 1
    if successor_index >= len(plan.phases):
        return _advance(
            cursor,
            current_phase=None,
            completed_phases=completed,
            current_subphase=None,
            remaining_outline=(),
            active_contract=None,
            phase_gate_status=PhaseGateStatus.PROJECT_COMPLETE,
        )

    successor = plan.phases[successor_index]
    outline = successor.subphases
    return _advance(
        cursor,
        current_phase=successor.phase_id,
        completed_phases=completed,
        current_subphase=outline[0].subphase_id,
        remaining_outline=outline[1:],
        active_contract=None,
        phase_gate_status=PhaseGateStatus.SUBPHASES_PENDING,
    )


def reopen_phase_for_remediation(
    cursor: ProjectCursor, remediation: SubphaseOutline
) -> ProjectCursor:
    """Reopen the current ``READY`` Phase for exactly one remediation Sub-phase.

    The remediation becomes the current Sub-phase with no remaining outline; the
    Phase, the completed-Phase history, and every completed Sub-phase are
    untouched. Its id must be new to the Phase's completed history and it may
    depend only on completed Sub-phases of this Phase. Reopening the identical
    remediation again is an idempotent no-op; a different remediation while one is
    current is refused.
    """
    if cursor.current_phase is None:
        raise ProjectCursorError("the project is complete; there is no phase to reopen")
    if (
        cursor.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING
        and cursor.current_subphase == remediation.subphase_id
    ):
        return cursor
    if cursor.phase_gate_status is not PhaseGateStatus.READY:
        raise ProjectCursorError("only a ready phase gate can be reopened for remediation")

    completed = {
        entry.subphase_id.root
        for entry in cursor.completed_subphases
        if entry.phase_id == cursor.current_phase
    }
    if remediation.subphase_id.root in completed:
        raise ProjectCursorError(
            f"remediation subphase {remediation.subphase_id.root} reuses a completed subphase"
        )
    for dependency in remediation.depends_on:
        if dependency.root not in completed:
            raise ProjectCursorError(
                f"remediation subphase {remediation.subphase_id.root} depends on "
                f"{dependency.root}, which is not completed"
            )
    return _advance(
        cursor,
        current_subphase=remediation.subphase_id,
        remaining_outline=(),
        phase_gate_status=PhaseGateStatus.SUBPHASES_PENDING,
    )


# --- Successor legality and Master Plan binding ---------------------------------


def _require_legal_phase_advance(previous: ProjectCursor, candidate: ProjectCursor) -> None:
    """The only legal change of Phase: a gate PASS from a ready, unbound, current Phase."""
    if (
        previous.current_phase is None
        or previous.phase_gate_status is not PhaseGateStatus.READY
        or previous.active_contract is not None
    ):
        raise ProjectCursorError("a phase can only be completed from a ready phase gate")
    if candidate.completed_phases != (*previous.completed_phases, previous.current_phase):
        raise ProjectCursorError("completed phase history is immutable")
    if candidate.phase_gate_status not in (
        PhaseGateStatus.SUBPHASES_PENDING,
        PhaseGateStatus.PROJECT_COMPLETE,
    ):
        raise ProjectCursorError("a completed phase must hand over to pending work or completion")
    if candidate.active_contract is not None:
        raise ProjectCursorError("a phase boundary cannot bind a contract")


def _is_remediation_reopening(previous: ProjectCursor, candidate: ProjectCursor) -> bool:
    """A ready gate becoming pending again is legal only as one remediation Sub-phase."""
    current = previous.current_phase
    if current is None or candidate.current_subphase is None:
        return False
    completed = {
        entry.subphase_id.root
        for entry in previous.completed_subphases
        if entry.phase_id == current
    }
    return (
        candidate.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING
        and candidate.current_subphase.root not in completed
        and candidate.remaining_outline == ()
        and candidate.active_contract is None
        and candidate.completed_subphases == previous.completed_subphases
    )


def require_legal_successor(previous: ProjectCursor, candidate: ProjectCursor) -> None:
    """Require *candidate* to be a legal direct successor of *previous*.

    Identity (project, Master Plan digest) is fixed, ``revision`` advances by
    exactly one, and completed-Sub-phase history is an unmodified prefix. The
    Phase position and completed-Phase history change only by a gate PASS (the
    current Phase joins the history and the cursor hands over to pending work or
    to project completion). The Phase gate never regresses, except that a gate
    failure may reopen the same Phase for exactly one remediation Sub-phase. A
    project-complete cursor has no successor.
    """
    if candidate.project_id != previous.project_id:
        raise ProjectCursorError("successor changes the project")
    if candidate.master_plan_digest != previous.master_plan_digest:
        raise ProjectCursorError("successor changes the master plan")
    if candidate.revision != previous.revision + 1:
        raise ProjectCursorError(
            f"successor revision must be {previous.revision + 1}, got {candidate.revision}"
        )
    if previous.phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE:
        raise ProjectCursorError("a complete project has no successor")

    advanced = (
        candidate.completed_phases != previous.completed_phases
        or candidate.current_phase != previous.current_phase
    )
    if advanced:
        _require_legal_phase_advance(previous, candidate)
    kept = len(previous.completed_subphases)
    if candidate.completed_subphases[:kept] != previous.completed_subphases:
        raise ProjectCursorError("completed subphase history is immutable")
    if (
        not advanced
        and previous.phase_gate_status is PhaseGateStatus.READY
        and candidate.phase_gate_status is not PhaseGateStatus.READY
        and not _is_remediation_reopening(previous, candidate)
    ):
        raise ProjectCursorError("the phase gate status cannot regress")


def validate_cursor_against_master_plan(cursor: ProjectCursor, plan: MasterPlan) -> None:
    """Require *cursor* to belong to the frozen *plan* and follow its Phase order."""
    validate_master_plan(plan)
    if cursor.project_id != plan.project_id:
        raise ProjectCursorError("cursor belongs to a different project")
    if cursor.master_plan_digest != master_plan_digest(plan):
        raise ProjectCursorError("cursor was created for a different master plan")

    order = tuple(phase.phase_id for phase in plan.phases)
    done = len(cursor.completed_phases)
    if order[:done] != cursor.completed_phases:
        raise ProjectCursorError("completed phases do not match the master plan order")
    if cursor.current_phase is None:
        if done != len(order):
            raise ProjectCursorError("the project is complete before every phase completed")
    elif done >= len(order) or order[done] != cursor.current_phase:
        raise ProjectCursorError("current phase skips an incomplete prior phase")


# --- Planning eligibility ---------------------------------------------------------


def planning_eligibility(
    cursor: ProjectCursor, transaction: RunStateSnapshot | None = None
) -> PlanningEligibility:
    """Decide deterministically whether the next Sub-phase Contract may be planned.

    Eligible only when a current Sub-phase exists and no Contract is active
    for it: i.e. nothing is in flight and every earlier Sub-phase is
    canonically recorded complete. An active Contract blocks planning
    whatever its transaction looks like -- in flight, halted, or even
    already ``SUBPHASE_COMPLETE`` but not yet recorded (the cursor is
    authoritative; record the completion first). *transaction*, when
    supplied, must belong to this project and to either the active run or
    an already-completed run; it only refines the reason.
    """
    binding = cursor.active_contract
    if transaction is not None:
        if transaction.project_id != cursor.project_id:
            raise ProjectCursorError("transaction belongs to a different project")
        known_runs = {entry.run_id for entry in cursor.completed_subphases}
        if binding is not None:
            known_runs.add(binding.transaction_run_id)
        if transaction.run_id not in known_runs:
            raise ProjectCursorError(f"transaction run {transaction.run_id.root} is unknown")

    def decide(reason: PlanningEligibilityReason) -> PlanningEligibility:
        return PlanningEligibility(
            eligible=reason is PlanningEligibilityReason.ELIGIBLE, reason=reason
        )

    if cursor.current_subphase is None:
        return decide(PlanningEligibilityReason.PHASE_GATE_PENDING)
    if binding is None:
        return decide(PlanningEligibilityReason.ELIGIBLE)

    if transaction is not None and transaction.run_id == binding.transaction_run_id:
        if transaction.workflow_state is WorkflowState.HALTED:
            return decide(PlanningEligibilityReason.TRANSACTION_HALTED)
        if transaction.workflow_state is WorkflowState.SUBPHASE_COMPLETE:
            return decide(PlanningEligibilityReason.COMPLETION_NOT_RECORDED)
    return decide(PlanningEligibilityReason.ACTIVE_CONTRACT_NOT_COMPLETE)


__all__ = [
    "ActiveContractBinding",
    "CompletedSubphase",
    "PhaseGateStatus",
    "PlanningEligibility",
    "PlanningEligibilityReason",
    "ProjectCursor",
    "ProjectCursorError",
    "bind_active_contract",
    "contract_digest",
    "master_plan_digest",
    "new_project_cursor",
    "planning_eligibility",
    "record_subphase_completion",
    "require_legal_successor",
    "revise_remaining_outline",
    "validate_cursor_against_master_plan",
]
