"""The Phase-gate cycle: gate attempt, PASS completion, bounded remediation, rerun.

:func:`~lockstep.phase_gate.run_phase_gate_attempt` is audit-only. This module composes it
with the host transitions around a Phase boundary, in a dedicated higher-level layer so that
neither the gate nor the ordinary Sub-phase runner ever completes a Phase or repairs one::

    cursor READY -> gate attempt n -> accepted decision
        PASS -> next Phase's outline published, cursor advanced (or project complete)
        FAIL -> a fresh Planner plans exactly one remediation Sub-phase (the gate findings are
                evidence, not requirements) -> host-validated, durably accepted
             -> the same Phase reopened with that Sub-phase -> the ordinary 11.2-11.4 runner
                executes it (Contract, tests, Implementer, verification, Reviewer, retry)
             -> cursor READY again -> gate attempt n + 1 on the new accepted basis

Authority stays where it was. Only a durably accepted PASS decision reaches the cursor's
one Phase-completion transition, and the successor Phase is derived by the host from the
frozen Master Plan, never chosen by a model. A remediation is one new Sub-phase with a host
allocated id, dependencies only on completed history, and the Phase's frozen facts and
completed outlines unchanged; it confers no authority until its own Contract is frozen. The
remediation runs with JIT replanning off so no fresh Planner can invent unrelated work around
it; ordinary Phase execution keeps JIT replanning on by default.

The loop is finite: the caller must pass ``max_gate_remediations``. A gate that still fails
after that many remediations stops with a typed exhaustion, the Phase incomplete and every
artifact intact.

Crash safety comes from durable acceptance points, never from process memory. An accepted
decision is reused, never re-decided; an accepted remediation plan is applied, never asked for
twice; every application step is idempotent. Writers are assumed single-process.
"""

from __future__ import annotations

import dataclasses
import json
from dataclasses import dataclass, field
from enum import StrEnum

from lockstep.agents import (
    ClaudeAdapterError,
    CodexAdapterError,
    OpenAIStrictSchemaError,
    StructuredOutputAdapterError,
)
from lockstep.domain import MasterPlan, PhaseId, PhasePlan, SubphaseId, SubphaseOutline
from lockstep.phase_gate import (
    PhaseGateAttemptDisposition,
    PhaseGateAttemptResult,
    PhaseGateBasis,
    PhaseGateDecision,
    PhaseGateError,
    PhaseGateEventKind,
    PhaseGateEvidence,
    PhaseGateRefusal,
    PhaseGateVerdict,
    RemediationReceipt,
    append_phase_gate_event,
    list_phase_gate_attempts,
    load_phase_gate_basis,
    load_phase_gate_decision,
    load_phase_gate_evidence,
    load_remediation_receipt,
    read_phase_gate_events,
    run_phase_gate_attempt,
    tracked_state_mutation,
    write_remediation_receipt,
)
from lockstep.planning import PlanningValidationError, validate_master_plan
from lockstep.planning_store import load_frozen_master_plan, load_phase_plan, publish_phase_plan
from lockstep.planning_transport import (
    PlanningArtifactKind,
    PlanningTransportError,
    invoke_planner_artifact,
)
from lockstep.process import ProcessConfigurationError, ProcessLaunchError, ProcessTimeoutError
from lockstep.project_cursor import (
    PhaseGateStatus,
    ProjectCursor,
    ProjectCursorError,
    reopen_phase_for_remediation,
)
from lockstep.project_cursor_store import (
    load_project_cursor,
    record_phase_completion,
    reopen_cursor_for_remediation,
)
from lockstep.project_orchestrator import (
    ProjectRunDisposition,
    ProjectRunResult,
    TransactionRequestFactory,
    run_project_phase,
    transaction_worktree_path,
)
from lockstep.retry import RetryBudget
from lockstep.runtime import AgentRuntime

# Failures of asking the Planner for a remediation plan and validating its answer: known
# outcomes that stop the cycle, never a verdict and never a remediation.
_REMEDIATION_PLAN_FAILURES = (
    PlanningTransportError,
    PlanningValidationError,
    ProcessLaunchError,
    ProcessTimeoutError,
    ProcessConfigurationError,
    ClaudeAdapterError,
    CodexAdapterError,
    StructuredOutputAdapterError,
    OpenAIStrictSchemaError,
)


class PhaseGateCycleDisposition(StrEnum):
    """Why :func:`run_phase_gate_cycle` stopped. Never a gate verdict by itself."""

    PHASE_COMPLETE = "phase_complete"
    PROJECT_COMPLETE = "project_complete"
    GATE_REMEDIATION_EXHAUSTED = "gate_remediation_exhausted"
    EXECUTION_FAILED = "execution_failed"
    HALTED = "halted"
    HUMAN_REQUIRED = "human_required"
    RECOVERY_REQUIRED = "recovery_required"


@dataclass(frozen=True, slots=True)
class PhaseGateCycleResult:
    """Typed outcome of one :func:`run_phase_gate_cycle` call.

    ``attempts`` are the gate attempts this call ran or re-read, in order;
    ``remediations`` the remediation Sub-phases it planned or applied;
    ``remediation_result`` the ordinary runner's result when a remediation Sub-phase
    stopped the cycle. ``cursor`` is the durable cursor at the moment of stopping.
    """

    disposition: PhaseGateCycleDisposition
    cursor: ProjectCursor = field(repr=False)
    attempts: tuple[PhaseGateAttemptResult, ...] = ()
    remediations: tuple[SubphaseId, ...] = ()
    remediation_result: ProjectRunResult | None = None
    detail: str | None = None


_STOP_FOR_DISPOSITION = {
    ProjectRunDisposition.HALTED: PhaseGateCycleDisposition.HALTED,
    ProjectRunDisposition.HUMAN_REQUIRED: PhaseGateCycleDisposition.HUMAN_REQUIRED,
    ProjectRunDisposition.RECOVERY_REQUIRED: PhaseGateCycleDisposition.RECOVERY_REQUIRED,
    ProjectRunDisposition.EXECUTION_FAILED: PhaseGateCycleDisposition.EXECUTION_FAILED,
}


# --- PASS: completing the Phase ------------------------------------------------------------


def _emit(
    runtime: AgentRuntime,
    basis: PhaseGateBasis,
    kind: PhaseGateEventKind,
    *,
    detail: str | None = None,
) -> None:
    append_phase_gate_event(
        runtime.runtime_dir,
        kind=kind,
        project_id=basis.project_id,
        master_plan_digest=basis.master_plan_digest,
        phase_id=basis.phase_id,
        gate_attempt=basis.gate_attempt,
        basis_commit=basis.commit,
        basis_run_id=basis.basis_run_id,
        detail=detail,
        dedupe=True,
    )


def complete_phase_from_gate_pass(
    runtime: AgentRuntime, decision: PhaseGateDecision
) -> ProjectCursor:
    """Apply an accepted gate PASS: publish the next Phase's outline, then advance the cursor.

    Only a PASS decision bound to this project and Master Plan can be applied. Both steps
    are idempotent, so a crash between them (or after them) is repaired by calling this again:
    the Phase joins the completed history exactly once and ``PHASE_COMPLETE`` is recorded
    exactly once. The successor Phase starts from its own frozen outline; nothing is invented.
    """
    if decision.outcome is not PhaseGateVerdict.PASS:
        raise PhaseGateError(
            PhaseGateRefusal.GATE_NOT_PASSED, "only a passing gate decision completes a phase"
        )
    project_root, runtime_dir = runtime.project_root, runtime.runtime_dir
    cursor = load_project_cursor(project_root, runtime_dir)
    if cursor is None:
        raise PhaseGateError(
            PhaseGateRefusal.CURSOR_MISSING, "the project cursor is not initialized"
        )
    if (decision.project_id, decision.master_plan_digest) != (
        cursor.project_id,
        cursor.master_plan_digest,
    ):
        raise PhaseGateError(
            PhaseGateRefusal.ARTIFACT_INCONSISTENT, "the gate decision belongs to another plan"
        )
    basis = load_phase_gate_basis(runtime_dir, decision.phase_id, decision.gate_attempt)
    if basis is None:
        raise PhaseGateError(
            PhaseGateRefusal.ARTIFACT_INCONSISTENT, "a gate decision exists without its basis"
        )

    if decision.phase_id not in cursor.completed_phases:
        master = load_frozen_master_plan(project_root)
        if master is None:
            raise PhaseGateError(
                PhaseGateRefusal.ARTIFACT_INCONSISTENT, "the master plan is not frozen"
            )
        successor = len(cursor.completed_phases) + 1
        if cursor.current_phase == decision.phase_id and successor < len(master.phases):
            publish_phase_plan(project_root, runtime_dir, master.phases[successor])
        cursor = record_phase_completion(project_root, runtime_dir, phase_id=decision.phase_id)
    _emit(runtime, basis, PhaseGateEventKind.PHASE_COMPLETE)
    return cursor


# --- FAIL: planning exactly one remediation Sub-phase ----------------------------------------

_MASTER_PLAN_LABEL = "Frozen Master Plan:"
_TARGET_PHASE_LABEL = "Target phase_id:"
_COMPLETED_LABEL = "Completed Sub-phases (immutable):"
_BASIS_LABEL = "Accepted repository basis:"
_FAILURE_LABEL = "Phase gate failure evidence:"
_REMEDIATION_ID_LABEL = "Remediation subphase_id:"

_REMEDIATION_INSTRUCTIONS = (
    "A Phase integration gate failed against the accepted repository state described above. "
    "Plan exactly one bounded remediation Sub-phase that repairs what the gate found.\n"
    "The frozen Master Plan above is the requirement authority. The gate failure evidence is "
    "evidence, not requirements: it explains why the existing requirements are not met and "
    "never adds, removes, or changes one.\n"
    "Preserve exactly these frozen Phase-level facts from the Master Plan: schema_version, "
    "phase_id, title, objective, depends_on, and integration_acceptance_criteria.\n"
    "Return the complete PhasePlan: the completed Sub-phase outlines exactly as supplied, "
    "unchanged and first and in the same order, followed by exactly one new Sub-phase outline.\n"
    "The new Sub-phase must use exactly the supplied remediation subphase_id and may depend "
    "only on completed Sub-phases. It must be one coherent, bounded change that is safe to land "
    "green; if the repair genuinely needs several unrelated changes, plan the single most "
    "important coherent unit rather than a backlog.\n"
    "The outline must contain only subphase_id, title, objective, and depends_on. Do not create "
    "detailed SubphaseContracts or TestSpecifications, and do not create executable tests.\n"
    "Inspect the accepted repository read-only when useful. Do not modify files and do not "
    "implement or repair anything.\n"
    "Return only the structured PhasePlan requested by the supplied schema.\n"
)


def _canonical_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def build_gate_remediation_prompt(
    master_plan: MasterPlan,
    completed: tuple[SubphaseOutline, ...],
    basis: PhaseGateBasis,
    decision: PhaseGateDecision,
    evidence: PhaseGateEvidence,
    remediation_subphase_id: SubphaseId,
) -> str:
    """Build the fresh-Planner remediation request from durable state alone.

    The frozen Master Plan is the requirement authority; the immutable completed outlines,
    the accepted basis, and the gate's decision and command evidence are evidence only.
    """
    failure = {
        "decision": decision.model_dump(mode="json"),
        "evidence": evidence.model_dump(mode="json"),
    }
    return (
        f"{_MASTER_PLAN_LABEL}\n"
        f"{_canonical_json(master_plan.model_dump(mode='json'))}\n"
        "\n"
        f"{_TARGET_PHASE_LABEL}\n"
        f"{basis.phase_id.root}\n"
        "\n"
        f"{_COMPLETED_LABEL}\n"
        f"{_canonical_json([o.model_dump(mode='json') for o in completed])}\n"
        "\n"
        f"{_BASIS_LABEL}\n"
        f"{_canonical_json(basis.model_dump(mode='json'))}\n"
        "\n"
        f"{_FAILURE_LABEL}\n"
        f"{_canonical_json(failure)}\n"
        "\n"
        f"{_REMEDIATION_ID_LABEL}\n"
        f"{remediation_subphase_id.root}\n"
        "\n"
        f"{_REMEDIATION_INSTRUCTIONS}"
    )


def _remediation_invalid(reason: str) -> PhaseGateError:
    return PhaseGateError(PhaseGateRefusal.REMEDIATION_INVALID, reason)


def _next_subphase_id(*plans: PhasePlan | tuple[SubphaseId, ...]) -> SubphaseId:
    """The host-allocated id of the remediation: one past every id the Phase has ever named."""
    identifiers: list[str] = []
    for plan in plans:
        if isinstance(plan, PhasePlan):
            identifiers.extend(o.subphase_id.root for o in plan.subphases)
        else:
            identifiers.extend(s.root for s in plan)
    width = max(2, *(len(i) for i in identifiers)) if identifiers else 2
    return SubphaseId.model_validate(f"{max(int(i) for i in identifiers) + 1:0{width}d}")


def _validated_remediation(
    master: MasterPlan,
    frozen: PhasePlan,
    published: PhasePlan,
    cursor: ProjectCursor,
    expected_id: SubphaseId,
    candidate: PhasePlan,
) -> SubphaseOutline:
    if candidate.phase_id != frozen.phase_id:
        raise _remediation_invalid("planner returned a phase plan for the wrong phase")
    if candidate != frozen.model_copy(update={"subphases": candidate.subphases}):
        raise _remediation_invalid("planner changed frozen phase-level facts")
    kept = len(published.subphases)
    if tuple(candidate.subphases[:kept]) != tuple(published.subphases):
        raise _remediation_invalid("planner rewrote completed history")
    added = candidate.subphases[kept:]
    if len(added) != 1:
        raise _remediation_invalid("planner must return exactly one remediation subphase")
    outline = added[0]
    if outline.subphase_id != expected_id:
        raise _remediation_invalid("planner did not use the allocated remediation id")

    validate_master_plan(
        master.model_copy(
            update={
                "phases": tuple(
                    candidate if p.phase_id == frozen.phase_id else p for p in master.phases
                )
            }
        )
    )
    try:
        reopen_phase_for_remediation(cursor, outline)
    except ProjectCursorError as exc:
        raise _remediation_invalid(f"remediation does not fit the cursor: {exc.reason}") from exc
    return outline


def _plan_remediation(
    runtime: AgentRuntime,
    cursor: ProjectCursor,
    attempt: PhaseGateAttemptResult,
    *,
    planning_timeout_seconds: float,
    max_output_bytes: int,
    termination_grace_seconds: float,
) -> RemediationReceipt:
    """Ask one fresh Planner for one remediation Sub-phase and durably accept it."""
    project_root, runtime_dir = runtime.project_root, runtime.runtime_dir
    basis, decision = attempt.basis, attempt.decision
    assert decision is not None and cursor.current_phase is not None
    evidence = load_phase_gate_evidence(runtime_dir, basis.phase_id, basis.gate_attempt)
    master = load_frozen_master_plan(project_root)
    if evidence is None or master is None:
        raise PhaseGateError(
            PhaseGateRefusal.ARTIFACT_INCONSISTENT, "the failed gate's evidence is missing"
        )
    frozen = next(p for p in master.phases if p.phase_id == basis.phase_id)
    published = load_phase_plan(project_root, runtime_dir) or frozen
    completed = tuple(
        e.subphase_id for e in cursor.completed_subphases if e.phase_id == basis.phase_id
    )
    if (
        published.phase_id != basis.phase_id
        or tuple(o.subphase_id for o in published.subphases) != completed
    ):
        raise PhaseGateError(
            PhaseGateRefusal.ARTIFACT_INCONSISTENT, "the published outline diverges from the cursor"
        )
    remediation_id = _next_subphase_id(published, frozen, completed)

    worktree = transaction_worktree_path(runtime_dir, basis.basis_run_id)
    if tracked_state_mutation(worktree, basis.commit) is not None:
        raise PhaseGateError(
            PhaseGateRefusal.BASIS_DRIFT, "the accepted state moved since the gate failed"
        )

    # The Planner inspects the accepted worktree, not the user's source checkout.
    planning_runtime = dataclasses.replace(runtime, project_root=worktree)
    result = invoke_planner_artifact(
        planning_runtime,
        kind=PlanningArtifactKind.PHASE_PLAN,
        prompt=build_gate_remediation_prompt(
            master, published.subphases, basis, decision, evidence, remediation_id
        ),
        timeout_seconds=planning_timeout_seconds,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=termination_grace_seconds,
    )
    if result.kind is not PlanningArtifactKind.PHASE_PLAN or not isinstance(
        result.artifact, PhasePlan
    ):
        raise _remediation_invalid("planner returned an unexpected artifact")
    if tracked_state_mutation(worktree, basis.commit) is not None:
        raise _remediation_invalid("the planner moved the accepted repository state")

    outline = _validated_remediation(
        master, frozen, published, cursor, remediation_id, result.artifact
    )
    receipt = RemediationReceipt(
        project_id=basis.project_id,
        master_plan_digest=basis.master_plan_digest,
        phase_id=basis.phase_id,
        gate_attempt=basis.gate_attempt,
        basis_commit=basis.commit,
        outline=outline,
    )
    write_remediation_receipt(runtime_dir, receipt)  # the acceptance point
    return receipt


def _apply_remediation(runtime: AgentRuntime, receipt: RemediationReceipt) -> None:
    """Publish the accepted remediation to the outline, then reopen the cursor; both idempotent."""
    project_root, runtime_dir = runtime.project_root, runtime.runtime_dir
    basis = load_phase_gate_basis(runtime_dir, receipt.phase_id, receipt.gate_attempt)
    if basis is None:
        raise PhaseGateError(
            PhaseGateRefusal.ARTIFACT_INCONSISTENT, "a remediation exists without its gate basis"
        )
    _emit(
        runtime,
        basis,
        PhaseGateEventKind.PHASE_GATE_REMEDIATION_PLANNED,
        detail=receipt.outline.subphase_id.root,
    )

    master = load_frozen_master_plan(project_root)
    if master is None:
        raise PhaseGateError(
            PhaseGateRefusal.ARTIFACT_INCONSISTENT, "the master plan is not frozen"
        )
    frozen = next(p for p in master.phases if p.phase_id == receipt.phase_id)
    published = load_phase_plan(project_root, runtime_dir) or frozen
    if published.phase_id != receipt.phase_id:
        raise PhaseGateError(
            PhaseGateRefusal.ARTIFACT_INCONSISTENT, "the published outline belongs to another phase"
        )
    present = {o.subphase_id: o for o in published.subphases}
    if receipt.outline.subphase_id in present:
        if present[receipt.outline.subphase_id] != receipt.outline:
            raise PhaseGateError(
                PhaseGateRefusal.ARTIFACT_INCONSISTENT,
                "the published outline disagrees with the accepted remediation",
            )
    else:
        desired = published.model_copy(
            update={"subphases": (*published.subphases, receipt.outline)}
        )
        publish_phase_plan(project_root, runtime_dir, desired)
    reopen_cursor_for_remediation(project_root, runtime_dir, receipt.outline)


def _remediation_in_flight(runtime: AgentRuntime, cursor: ProjectCursor) -> bool:
    """Is the cursor's current Sub-phase an accepted gate remediation that has not completed?"""
    phase_id = cursor.current_phase
    if phase_id is None or cursor.current_subphase is None:
        return False
    for number in reversed(list_phase_gate_attempts(runtime.runtime_dir, phase_id)):
        receipt = load_remediation_receipt(runtime.runtime_dir, phase_id, number)
        if receipt is not None:
            return receipt.outline.subphase_id == cursor.current_subphase
    return False


# --- Narrow steps shared with a higher-level driver ------------------------------------------
#
# The cycle below is one monolithic call. A driver that must enforce a project-wide budget
# *between* its steps composes these instead, so there is exactly one implementation of every
# step and no second remediation protocol. They are deliberately not part of ``__all__``.


def remediation_in_flight(runtime: AgentRuntime, cursor: ProjectCursor) -> bool:
    """Is the current Sub-phase an accepted gate remediation that has not completed yet?"""
    return _remediation_in_flight(runtime, cursor)


def remediations_spent(runtime: AgentRuntime, phase_id: PhaseId) -> int:
    """How many remediations the Phase has durably accepted: the count the bound is checked on."""
    return sum(
        load_remediation_receipt(runtime.runtime_dir, phase_id, number) is not None
        for number in list_phase_gate_attempts(runtime.runtime_dir, phase_id)
    )


def plan_gate_remediation(
    runtime: AgentRuntime,
    cursor: ProjectCursor,
    attempt: PhaseGateAttemptResult,
    *,
    planning_timeout_seconds: float,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
) -> tuple[RemediationReceipt | None, str | None]:
    """Ask one fresh Planner for the remediation of a failed attempt and durably accept it.

    Returns ``(receipt, None)`` once the plan is accepted, or ``(None, detail)`` for a known
    failure of asking for or validating the plan -- never a verdict and never a remediation.
    """
    try:
        receipt = _plan_remediation(
            runtime,
            cursor,
            attempt,
            planning_timeout_seconds=planning_timeout_seconds,
            max_output_bytes=max_output_bytes,
            termination_grace_seconds=termination_grace_seconds,
        )
    except _REMEDIATION_PLAN_FAILURES as exc:
        return None, f"remediation planning: {getattr(exc, 'reason', type(exc).__name__)}"
    except PhaseGateError as exc:
        if exc.refusal is not PhaseGateRefusal.REMEDIATION_INVALID:
            raise
        return None, f"remediation planning: {exc.reason}"
    return receipt, None


def apply_gate_remediation(runtime: AgentRuntime, receipt: RemediationReceipt) -> None:
    """Publish an accepted remediation to the outline and reopen the cursor; idempotent."""
    _apply_remediation(runtime, receipt)


def repair_phase_complete_evidence(runtime: AgentRuntime) -> tuple[PhaseId, ...]:
    """Append any ``PHASE_COMPLETE`` event a crash left missing for an already-completed Phase.

    Closes the narrow window between the cursor's Phase completion and its derived gate event.
    It is evidence repair only: it requires an accepted PASS decision for a Phase the cursor
    already records complete, never reruns a gate or a Planner, never writes the cursor, and
    never appends a duplicate. Returns the Phases whose event it appended.
    """
    runtime_dir = runtime.runtime_dir
    cursor = load_project_cursor(runtime.project_root, runtime_dir)
    if cursor is None:
        return ()
    repaired: list[PhaseId] = []
    for phase_id in cursor.completed_phases:
        for number in reversed(list_phase_gate_attempts(runtime_dir, phase_id)):
            decision = load_phase_gate_decision(runtime_dir, phase_id, number)
            if decision is None or decision.outcome is not PhaseGateVerdict.PASS:
                continue
            if (decision.project_id, decision.master_plan_digest) != (
                cursor.project_id,
                cursor.master_plan_digest,
            ):
                raise PhaseGateError(
                    PhaseGateRefusal.ARTIFACT_INCONSISTENT,
                    "the gate decision belongs to another plan",
                )
            basis = load_phase_gate_basis(runtime_dir, phase_id, number)
            if basis is None:
                raise PhaseGateError(
                    PhaseGateRefusal.ARTIFACT_INCONSISTENT,
                    "a gate decision exists without its basis",
                )
            recorded = any(
                event.kind is PhaseGateEventKind.PHASE_COMPLETE and event.gate_attempt == number
                for event in read_phase_gate_events(runtime_dir, phase_id)
            )
            if not recorded:
                _emit(runtime, basis, PhaseGateEventKind.PHASE_COMPLETE)
                repaired.append(phase_id)
            break
    return tuple(repaired)


# --- The cycle ---------------------------------------------------------------------------------


def _require_bound(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise PhaseGateError(
            PhaseGateRefusal.INVALID_REMEDIATION_BOUND,
            "max_gate_remediations must be a non-negative integer",
        )
    return value


def run_phase_gate_cycle(
    runtime: AgentRuntime,
    *,
    max_gate_remediations: int,
    request_factory: TransactionRequestFactory | None = None,
    retry_budget: RetryBudget,
    planning_timeout_seconds: float,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
) -> PhaseGateCycleResult:
    """Cross the current Phase's boundary: gate it, complete it, or remediate and regate.

    Starts from a ``READY`` gate -- or from a gate-remediation Sub-phase already in flight --
    and stops when the Phase completes (``PHASE_COMPLETE``, or ``PROJECT_COMPLETE`` for the
    final Phase), when *max_gate_remediations* is spent (``GATE_REMEDIATION_EXHAUSTED``, Phase
    left incomplete), or at a typed stop: an execution failure of the gate or of remediation
    planning, or the ordinary runner's halt / human / recovery stop for a remediation Sub-phase.
    *max_gate_remediations* is required: there is no unbounded or default budget, and ``0``
    stops at the first failure without planning anything. Refuses (typed
    :class:`~lockstep.phase_gate.PhaseGateError`) while ordinary Sub-phase work remains.
    Safe to call again after any stop or crash; accepted decisions and remediation plans are
    reused, never re-decided. *request_factory*, *retry_budget* and the planning limits are
    passed to the ordinary runner that executes a remediation Sub-phase, with JIT replanning
    off for that run only.
    """
    bound = _require_bound(max_gate_remediations)
    project_root, runtime_dir = runtime.project_root, runtime.runtime_dir
    cursor = load_project_cursor(project_root, runtime_dir)
    if cursor is None:
        raise PhaseGateError(
            PhaseGateRefusal.CURSOR_MISSING, "the project cursor is not initialized"
        )
    phase_id = cursor.current_phase
    if phase_id is None:
        return PhaseGateCycleResult(PhaseGateCycleDisposition.PROJECT_COMPLETE, cursor)

    attempts: list[PhaseGateAttemptResult] = []
    remediations: list[SubphaseId] = []

    def finish(
        disposition: PhaseGateCycleDisposition,
        *,
        remediation_result: ProjectRunResult | None = None,
        detail: str | None = None,
    ) -> PhaseGateCycleResult:
        latest = load_project_cursor(project_root, runtime_dir)
        assert latest is not None
        return PhaseGateCycleResult(
            disposition,
            latest,
            attempts=tuple(attempts),
            remediations=tuple(remediations),
            remediation_result=remediation_result,
            detail=detail,
        )

    for _ in range(3 * (bound + 2) + 3):
        cursor = load_project_cursor(project_root, runtime_dir)
        assert cursor is not None
        if cursor.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING:
            if not _remediation_in_flight(runtime, cursor):
                raise PhaseGateError(
                    PhaseGateRefusal.NOT_READY, "the phase still has ordinary subphase work"
                )
            outcome = run_project_phase(
                runtime,
                request_factory=request_factory,
                retry_budget=retry_budget,
                planning_timeout_seconds=planning_timeout_seconds,
                max_output_bytes=max_output_bytes,
                termination_grace_seconds=termination_grace_seconds,
                jit_replan=False,
            )
            if outcome.disposition is not ProjectRunDisposition.PHASE_GATE_READY:
                return finish(
                    _STOP_FOR_DISPOSITION[outcome.disposition],
                    remediation_result=outcome,
                    detail=outcome.detail,
                )
            continue

        result = run_phase_gate_attempt(
            runtime,
            planning_timeout_seconds=planning_timeout_seconds,
            max_output_bytes=max_output_bytes,
            termination_grace_seconds=termination_grace_seconds,
        )
        attempts.append(result)
        if result.disposition is PhaseGateAttemptDisposition.EXECUTION_FAILED:
            return finish(PhaseGateCycleDisposition.EXECUTION_FAILED, detail=result.detail)
        assert result.decision is not None
        if result.disposition is PhaseGateAttemptDisposition.PASSED:
            completed = complete_phase_from_gate_pass(runtime, result.decision)
            return PhaseGateCycleResult(
                PhaseGateCycleDisposition.PROJECT_COMPLETE
                if completed.current_phase is None
                else PhaseGateCycleDisposition.PHASE_COMPLETE,
                completed,
                attempts=tuple(attempts),
                remediations=tuple(remediations),
            )

        receipt = load_remediation_receipt(runtime_dir, phase_id, result.gate_attempt)
        if receipt is None:
            if remediations_spent(runtime, phase_id) >= bound:
                return finish(PhaseGateCycleDisposition.GATE_REMEDIATION_EXHAUSTED)
            receipt, failure = plan_gate_remediation(
                runtime,
                cursor,
                result,
                planning_timeout_seconds=planning_timeout_seconds,
                max_output_bytes=max_output_bytes,
                termination_grace_seconds=termination_grace_seconds,
            )
            if receipt is None:
                return finish(PhaseGateCycleDisposition.EXECUTION_FAILED, detail=failure)
        _apply_remediation(runtime, receipt)
        remediations.append(receipt.outline.subphase_id)

    raise PhaseGateError(PhaseGateRefusal.ARTIFACT_INCONSISTENT, "the gate cycle did not converge")


__all__ = [
    "PhaseGateCycleDisposition",
    "PhaseGateCycleResult",
    "build_gate_remediation_prompt",
    "complete_phase_from_gate_pass",
    "run_phase_gate_cycle",
]
