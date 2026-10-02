"""Sequential Sub-phase orchestration over the durable project cursor.

Composes the accepted machinery -- Phase-8 Contract planning and freeze,
the Phase-9 single-Sub-phase transaction with retry checkpointing and
at-most-once resume, and the 11.1 project cursor -- so the Sub-phases of
the current Phase's already-outlined, provisional schedule run one after
another with no human relaying one transaction's result into the next::

    cursor -> current Sub-phase -> plan + freeze its Contract -> bind it
        -> single-Sub-phase transaction (Planner tests, baseline, freeze,
           Implementer, verification, Reviewer, retry/resume)
        -> canonical Sub-phase completion -> record in the cursor
        -> retire the Contract into history -> next Sub-phase
        -> ... -> the Phase gate is ``READY`` -> stop

Nothing is reimplemented here. Agents, worktrees, commits, verification,
retry settlement, and escalation all stay inside the transaction layer;
this module only decides *which* transaction runs next and records the
result. The cursor is the sole progression authority: this module writes
no progress file of its own, and every decision is re-derived from the
cursor and the bound transaction's journal, never from process memory, so
a restart at any point resumes or stops safely.

Layout beneath the project run root (``runtime.runtime_dir``)::

    project/             the cursor (owned by lockstep.project_cursor_store)
    planning/            the provisional Phase outline
    contracts/           the one active Contract, plus ``history/``
    transactions/<run>/  one independent journal/state/retry tree per Sub-phase
    worktrees/<run>/     one isolated Git worktree per Sub-phase

Each Sub-phase transaction has its own :class:`~lockstep.domain.RunId`
(allocated deterministically from its Phase and Sub-phase) and its own
runtime directory, so each stays individually projectable by the Phase-10
metrics. Sub-phase B's branch is rooted at Sub-phase A's accepted branch,
giving the linear history ``test(A) feat(A) test(B) feat(B)`` while the
user's source checkout is never moved or dirtied.

Authority is preserved, not inflated. A Planner-authored Contract is
authoritative only once frozen; the cursor advances only when the bound
transaction's journal reaches canonical completion (a Reviewer ``APPROVE``,
an implementation report, or a passing verification never advances it); a
halted transaction without durable retry authority is never relaunched;
and any state that cannot be proven safe fails closed. The remaining
outline is the current provisional schedule. By default a fresh Planner
reconsiders it (delegated to :mod:`lockstep.jit_replan`) after each recorded
Sub-phase that leaves unfinished work, before the next Contract is planned;
``jit_replan=False`` runs it as published. Either way this module
neither runs the Phase integration step nor completes the Phase -- it stops
when the cursor reports the Phase gate ready. Crossing that boundary belongs to
the dedicated higher-level module :mod:`lockstep.phase_gate_cycle`, which
composes this runner (for a gate-remediation Sub-phase) rather than the other
way around.

:func:`step_project_run` performs exactly one durable step and is the seam
between "record completion" and "plan the next Contract"; the replanning
step sits between two calls to it.
"""

from __future__ import annotations

import dataclasses
from collections.abc import Callable
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path

from lockstep.agent_turn import AgentTurnError
from lockstep.contract_history import retire_active_subphase_contract
from lockstep.domain import ExecutionEventKind, PhaseId, RunId, SubphaseContract, SubphaseId
from lockstep.escalation import EscalationProtocolError
from lockstep.escalation_transport import PlannerDecisionTransportError
from lockstep.handoff import HandoffError
from lockstep.jit_replan import JitReplanError, JitReplanState, jit_replan_state, run_jit_replan
from lockstep.persistence import ExecutionEvent, load_verified_state, read_events
from lockstep.planning import PlanningValidationError
from lockstep.planning_store import (
    freeze_subphase_contract,
    load_active_subphase_contract,
    load_frozen_master_plan,
    load_phase_plan,
    publish_phase_plan,
)
from lockstep.planning_transport import PlanningTransportError
from lockstep.planning_workflow import create_subphase_contract_candidate
from lockstep.project_cursor import (
    CompletedSubphase,
    PhaseGateStatus,
    PlanningEligibilityReason,
    ProjectCursor,
    ProjectCursorError,
    contract_digest,
    planning_eligibility,
)
from lockstep.project_cursor_store import (
    bind_frozen_contract,
    initialize_project_cursor,
    load_project_cursor,
    record_completed_subphase,
)
from lockstep.retry import RetryBudget
from lockstep.reviewer_turn import ReviewerTurnError
from lockstep.runtime import AgentRuntime
from lockstep.state import RunStateSnapshot
from lockstep.supervisor.escalation import SupervisorEscalationDisposition
from lockstep.supervisor.transaction import (
    ResumeExecutionDisposition,
    SingleSubphaseTransactionRequest,
    SupervisorTransactionError,
    resume_single_subphase_transaction,
    run_single_subphase_transaction_with_retry_checkpoint,
)

_TRANSACTIONS_DIR_NAME = "transactions"
_WORKTREES_DIR_NAME = "worktrees"
_JOURNAL_NAME = "events.jsonl"
_STATE_NAME = "state.json"

# Failures the transaction layer documents as known outcomes of a launch or a
# resume. Anything else (a store fault, a programming error, a simulated crash)
# is not a Sub-phase outcome and propagates.
_KNOWN_TRANSACTION_FAILURES = (
    SupervisorTransactionError,
    AgentTurnError,
    ReviewerTurnError,
    PlannerDecisionTransportError,
    EscalationProtocolError,
    HandoffError,
)

# Failures of a required JIT replan that are known outcomes of asking the Planner and
# validating its answer; they stop the Phase instead of falling back to stale work.
_KNOWN_REPLAN_FAILURES = (JitReplanError, PlanningTransportError, PlanningValidationError)


class ProjectOrchestrationError(Exception):
    """The orchestrator refused to proceed because a precondition does not hold.

    Carries a short, bounded, deterministic ``reason`` that never includes
    artifact contents, prompt text, or provider output. Raised for caller
    errors (a transaction request that does not match the bound Contract) and
    for durable-state inconsistencies the orchestrator cannot repair.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"project orchestration error: {reason}")


class ProjectRunDisposition(StrEnum):
    """Why :func:`run_project_phase` / :func:`step_project_run` stopped.

    Deliberately not a stop-reason vocabulary: it only says what the
    orchestrator did next, never why work failed.
    """

    PHASE_GATE_READY = "phase_gate_ready"
    HALTED = "halted"
    HUMAN_REQUIRED = "human_required"
    RECOVERY_REQUIRED = "recovery_required"
    EXECUTION_FAILED = "execution_failed"


@dataclass(frozen=True, slots=True)
class TransactionPlacement:
    """Where and as whom one Sub-phase transaction must run.

    Allocated by the orchestrator, never by the caller: ``run_id`` and the
    runtime directory identify the transaction durably, and ``base_branch``
    (the previous accepted run's branch, or ``None`` for the first Sub-phase)
    roots the new branch so history stays linear.
    """

    run_id: RunId
    runtime_dir: Path
    worktree_path: Path
    branch: str
    base_branch: str | None


TransactionRequestFactory = Callable[
    [SubphaseContract, TransactionPlacement], SingleSubphaseTransactionRequest
]


def _resolve_request_factory(
    runtime: AgentRuntime, request_factory: TransactionRequestFactory | None
) -> TransactionRequestFactory:
    """An explicit factory is a controlled injection seam; ``None`` selects the host's own.

    The canonical factory lives in a module that imports this one, so it is imported
    here, at call time. It refuses an unconfigured project immediately, before any
    provider is launched.
    """
    if request_factory is not None:
        return request_factory
    from lockstep.transaction_factory import canonical_transaction_request_factory

    return canonical_transaction_request_factory(runtime)


@dataclass(frozen=True, slots=True)
class ProjectRunResult:
    """Typed outcome of a stopping orchestration call.

    ``cursor`` is the durable cursor at the moment of stopping. ``completed``
    lists the Sub-phases this :func:`run_project_phase` call recorded.
    ``escalation_disposition`` and ``resume_disposition`` carry the durable
    control facts that explain a stop, when there are any.
    """

    disposition: ProjectRunDisposition
    cursor: ProjectCursor = field(repr=False)
    transaction_run_id: RunId | None = None
    completed: tuple[CompletedSubphase, ...] = ()
    escalation_disposition: SupervisorEscalationDisposition | None = None
    resume_disposition: ResumeExecutionDisposition | None = None
    detail: str | None = None


# --- Identity and layout ---------------------------------------------------------


def allocate_transaction_run_id(phase_id: PhaseId, subphase_id: SubphaseId) -> RunId:
    """Deterministically allocate the one canonical RunId of a Sub-phase transaction."""
    return RunId.model_validate(f"run-{phase_id.root}-{subphase_id.root}")


def transaction_runtime_dir(runtime_dir: Path, run_id: RunId) -> Path:
    """The independent runtime directory (journal, state, retry tree) of one transaction."""
    return Path(runtime_dir) / _TRANSACTIONS_DIR_NAME / run_id.root


def transaction_worktree_path(runtime_dir: Path, run_id: RunId) -> Path:
    """The isolated Git worktree location of one transaction."""
    return Path(runtime_dir) / _WORKTREES_DIR_NAME / run_id.root


def transaction_branch(run_id: RunId) -> str:
    """The accepted Git branch of one Sub-phase transaction, deterministic from its run id.

    Deliberately not part of the frozen ``__all__`` surface.
    """
    return f"lockstep/run/{run_id.root}"


def _placement(runtime_dir: Path, cursor: ProjectCursor, run_id: RunId) -> TransactionPlacement:
    previous = cursor.completed_subphases[-1] if cursor.completed_subphases else None
    return TransactionPlacement(
        run_id=run_id,
        runtime_dir=transaction_runtime_dir(runtime_dir, run_id),
        worktree_path=transaction_worktree_path(runtime_dir, run_id),
        branch=transaction_branch(run_id),
        base_branch=transaction_branch(previous.run_id) if previous is not None else None,
    )


def _validated_request(
    factory: TransactionRequestFactory,
    contract: SubphaseContract,
    placement: TransactionPlacement,
) -> SingleSubphaseTransactionRequest:
    """Build the request and prove it belongs to exactly this Contract and placement."""
    request = factory(contract, placement)

    def refuse(what: str) -> ProjectOrchestrationError:
        return ProjectOrchestrationError(f"transaction request {what} does not match the contract")

    if request.run_id != placement.run_id:
        raise refuse("run id")
    if request.phase_id != contract.phase_id:
        raise refuse("phase")
    if request.subphase_id != contract.subphase_id:
        raise refuse("sub-phase")
    if request.runtime_dir != Path(placement.runtime_dir).resolve():
        raise refuse("runtime directory")
    if request.worktree_path != Path(placement.worktree_path).resolve():
        raise refuse("worktree")
    if request.branch != placement.branch:
        raise refuse("branch")
    if request.base_branch != placement.base_branch:
        raise refuse("base branch")
    expected_tests = sorted(spec.path for spec in contract.tests)
    if sorted(request.test_paths) != expected_tests:
        raise refuse("test paths")
    return request


# --- Durable-state reading -----------------------------------------------------------


def _load_or_initialize(project_root: Path, runtime_dir: Path) -> ProjectCursor:
    cursor = load_project_cursor(project_root, runtime_dir)
    if cursor is None:
        cursor = initialize_project_cursor(project_root, runtime_dir)
    return cursor


def _verified_bound_transaction(
    cursor: ProjectCursor, journal_path: Path, state_path: Path
) -> RunStateSnapshot:
    """Load the bound transaction and prove its identity agrees with the cursor."""
    binding = cursor.active_contract
    assert binding is not None
    snapshot = load_verified_state(state_path, journal_path)
    if snapshot is None:
        raise ProjectOrchestrationError("bound transaction journal is missing")
    if snapshot.run_id != binding.transaction_run_id:
        raise ProjectCursorError("transaction journal belongs to a different run")
    if snapshot.project_id != cursor.project_id:
        raise ProjectCursorError("transaction belongs to a different project")
    for event in read_events(journal_path):
        if not isinstance(event, ExecutionEvent):
            continue
        if event.phase_id is not None and event.phase_id != binding.phase_id:
            raise ProjectCursorError("transaction journal names a different phase")
        if event.subphase_id is not None and event.subphase_id != binding.subphase_id:
            raise ProjectCursorError("transaction journal names a different subphase")
    return snapshot


def _transaction_condition(
    cursor: ProjectCursor, journal_path: Path, state_path: Path
) -> PlanningEligibilityReason:
    """Classify the bound transaction with the cursor's own canonical predicate.

    ``COMPLETION_NOT_RECORDED`` is the 11.1 name for a journal that has
    canonically completed while the cursor has not yet recorded it;
    ``TRANSACTION_HALTED`` is a durable halt; anything else is work that
    looks active.
    """
    snapshot = _verified_bound_transaction(cursor, journal_path, state_path)
    return planning_eligibility(cursor, snapshot).reason


def _durable_escalation_disposition(journal_path: Path) -> SupervisorEscalationDisposition | None:
    """The escalation disposition that produced the journal's final halt, if any."""
    events = read_events(journal_path)
    halted_at = None
    for index, event in enumerate(events):
        if (
            isinstance(event, ExecutionEvent)
            and event.kind is ExecutionEventKind.TRANSACTION_HALTED
        ):
            halted_at = index
    if halted_at is None:
        return None
    for event in reversed(events[:halted_at]):
        if not isinstance(event, ExecutionEvent):
            continue
        if event.kind is not ExecutionEventKind.ESCALATION_DISPATCHED or event.detail is None:
            return None
        try:
            return SupervisorEscalationDisposition(event.detail)
        except ValueError:
            return None
    return None


# --- Planning the current Contract ---------------------------------------------------


def _ensure_outline_published(project_root: Path, runtime_dir: Path, cursor: ProjectCursor) -> None:
    """Make sure the provisional outline the Contract planner reads is published.

    Adopts the frozen Master Plan's own outline verbatim when nothing is
    published; never asks the Planner to revise it.
    """
    plan = load_phase_plan(project_root, runtime_dir)
    if plan is None:
        master = load_frozen_master_plan(project_root)
        if master is None:
            raise ProjectOrchestrationError("master plan is not frozen")
        frozen = next((p for p in master.phases if p.phase_id == cursor.current_phase), None)
        if frozen is None:
            raise ProjectOrchestrationError("current phase is not in the master plan")
        publish_phase_plan(project_root, runtime_dir, frozen)
        plan = frozen
    if plan.phase_id != cursor.current_phase:
        raise ProjectOrchestrationError("published outline belongs to another phase")

    assert cursor.current_subphase is not None
    expected = (
        *(e.subphase_id for e in cursor.completed_subphases if e.phase_id == cursor.current_phase),
        cursor.current_subphase,
        *(o.subphase_id for o in cursor.remaining_outline),
    )
    if tuple(o.subphase_id for o in plan.subphases) != expected:
        raise ProjectOrchestrationError("published outline diverges from the cursor")


def _reconcile_unbound_contract(
    project_root: Path, runtime_dir: Path, cursor: ProjectCursor
) -> SubphaseContract | None:
    """Settle a leftover active Contract while the cursor binds none.

    A Contract of an already-recorded Sub-phase is retired into history (this
    closes the crash window between recording completion and retirement). A
    Contract frozen for the current Sub-phase but not yet bound is returned so
    it is bound rather than planned again. Anything else is inconsistent.
    """
    leftover = load_active_subphase_contract(project_root, runtime_dir)
    if leftover is None:
        return None
    digest = contract_digest(leftover)
    for entry in cursor.completed_subphases:
        if (entry.phase_id, entry.subphase_id, entry.contract_digest) == (
            leftover.phase_id,
            leftover.subphase_id,
            digest,
        ):
            retire_active_subphase_contract(project_root, runtime_dir, contract_digest=digest)
            return None
    if (
        leftover.phase_id == cursor.current_phase
        and leftover.subphase_id == cursor.current_subphase
    ):
        return leftover
    raise ProjectOrchestrationError(
        "active contract belongs to neither a completed nor the current sub-phase"
    )


def _plan_and_bind(
    runtime: AgentRuntime,
    cursor: ProjectCursor,
    leftover: SubphaseContract | None,
    *,
    planning_timeout_seconds: float,
    max_output_bytes: int,
    termination_grace_seconds: float,
) -> None:
    eligibility = planning_eligibility(cursor)
    if not eligibility.eligible:
        raise ProjectOrchestrationError(f"planning is not eligible: {eligibility.reason.value}")
    assert cursor.current_phase is not None
    assert cursor.current_subphase is not None

    contract = leftover
    if contract is None:
        _ensure_outline_published(runtime.project_root, runtime.runtime_dir, cursor)
        candidate = create_subphase_contract_candidate(
            runtime,
            phase_id=cursor.current_phase,
            subphase_id=cursor.current_subphase,
            timeout_seconds=planning_timeout_seconds,
            max_output_bytes=max_output_bytes,
            termination_grace_seconds=termination_grace_seconds,
        )
        contract = candidate.contract
        freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, contract)

    bind_frozen_contract(
        runtime.project_root,
        runtime.runtime_dir,
        transaction_run_id=allocate_transaction_run_id(contract.phase_id, contract.subphase_id),
    )


# --- JIT replanning ----------------------------------------------------------------------


def _replan(
    runtime: AgentRuntime,
    cursor: ProjectCursor,
    leftover: SubphaseContract | None,
    *,
    planning_timeout_seconds: float,
    max_output_bytes: int,
    termination_grace_seconds: float,
) -> ProjectRunResult | None:
    """Replan the unfinished outline from the latest accepted Sub-phase's repository state.

    ``None`` means the replan is accepted and applied and the next step may plan the
    next Contract. A known planning failure stops the Phase with the cursor and outline
    untouched; it is never treated as a no-op.
    """
    if leftover is not None:
        raise ProjectOrchestrationError("a frozen contract exists while a replan is outstanding")
    previous = cursor.completed_subphases[-1]
    try:
        run_jit_replan(
            runtime,
            worktree_path=transaction_worktree_path(runtime.runtime_dir, previous.run_id),
            branch=transaction_branch(previous.run_id),
            timeout_seconds=planning_timeout_seconds,
            max_output_bytes=max_output_bytes,
            termination_grace_seconds=termination_grace_seconds,
        )
    except _KNOWN_REPLAN_FAILURES as exc:
        reason = getattr(exc, "reason", None) or type(exc).__name__
        return _stop(
            runtime, ProjectRunDisposition.EXECUTION_FAILED, None, detail=f"jit replan: {reason}"
        )
    return None


# --- Driving the bound transaction -----------------------------------------------------


def _stop(
    runtime: AgentRuntime,
    disposition: ProjectRunDisposition,
    run_id: RunId | None,
    *,
    escalation: SupervisorEscalationDisposition | None = None,
    resume: ResumeExecutionDisposition | None = None,
    detail: str | None = None,
) -> ProjectRunResult:
    cursor = load_project_cursor(runtime.project_root, runtime.runtime_dir)
    assert cursor is not None
    return ProjectRunResult(
        disposition=disposition,
        cursor=cursor,
        transaction_run_id=run_id,
        escalation_disposition=escalation,
        resume_disposition=resume,
        detail=detail,
    )


def _record_completion(runtime: AgentRuntime, journal_path: Path, state_path: Path) -> None:
    """Record canonical completion, then free the active Contract slot."""
    updated = record_completed_subphase(
        runtime.project_root,
        runtime.runtime_dir,
        journal_path=journal_path,
        state_path=state_path,
    )
    recorded = updated.completed_subphases[-1]
    retire_active_subphase_contract(
        runtime.project_root, runtime.runtime_dir, contract_digest=recorded.contract_digest
    )


def _halted_result(
    runtime: AgentRuntime,
    run_id: RunId,
    journal_path: Path,
    *,
    resume: ResumeExecutionDisposition,
) -> ProjectRunResult:
    escalation = _durable_escalation_disposition(journal_path)
    human = escalation is SupervisorEscalationDisposition.HUMAN_REQUIRED
    return _stop(
        runtime,
        ProjectRunDisposition.HUMAN_REQUIRED if human else ProjectRunDisposition.HALTED,
        run_id,
        escalation=escalation,
        resume=resume,
    )


def _resume_until_terminal(
    runtime: AgentRuntime,
    txn_runtime: AgentRuntime,
    cursor: ProjectCursor,
    request: SingleSubphaseTransactionRequest,
    journal_path: Path,
    state_path: Path,
    *,
    attempts: int,
) -> ProjectRunResult | None:
    """Consume durable retry authority until the halted transaction completes or must stop."""
    run_id = request.run_id
    for _ in range(attempts + 2):
        outcome = resume_single_subphase_transaction(request, agent_turn_runtime=txn_runtime)
        disposition = outcome.disposition

        if disposition is ResumeExecutionDisposition.STARTED_RECOVERY_REQUIRED:
            return _stop(
                runtime, ProjectRunDisposition.RECOVERY_REQUIRED, run_id, resume=disposition
            )
        if disposition is not ResumeExecutionDisposition.SETTLED:
            # No checkpoint, an exhausted budget, or authority that is not executable.
            return _halted_result(runtime, run_id, journal_path, resume=disposition)

        condition = _transaction_condition(cursor, journal_path, state_path)
        if condition is PlanningEligibilityReason.COMPLETION_NOT_RECORDED:
            _record_completion(runtime, journal_path, state_path)
            return None
        if condition is not PlanningEligibilityReason.TRANSACTION_HALTED:
            return _stop(
                runtime, ProjectRunDisposition.EXECUTION_FAILED, run_id, resume=disposition
            )
    raise ProjectOrchestrationError("retry resumption did not converge within the retry budget")


def _drive_bound_transaction(
    runtime: AgentRuntime,
    cursor: ProjectCursor,
    *,
    request_factory: TransactionRequestFactory,
    retry_budget: RetryBudget,
) -> ProjectRunResult | None:
    binding = cursor.active_contract
    assert binding is not None
    run_id = binding.transaction_run_id
    placement = _placement(runtime.runtime_dir, cursor, run_id)

    contract = load_active_subphase_contract(runtime.project_root, runtime.runtime_dir)
    if contract is None:
        raise ProjectOrchestrationError("bound contract is not frozen")
    # Nothing launches against a Contract that is not exactly the one the cursor bound.
    if (
        contract.phase_id != binding.phase_id
        or contract.subphase_id != binding.subphase_id
        or contract_digest(contract) != binding.contract_digest
    ):
        raise ProjectOrchestrationError("active contract does not match the cursor binding")
    request = _validated_request(request_factory, contract, placement)
    txn_runtime = dataclasses.replace(runtime, runtime_dir=request.runtime_dir)

    journal_path = request.runtime_dir / _JOURNAL_NAME
    state_path = request.runtime_dir / _STATE_NAME

    failure: str | None = None
    launched = not (journal_path.exists() or state_path.exists())
    if launched:
        try:
            run_single_subphase_transaction_with_retry_checkpoint(
                request, agent_turn_runtime=txn_runtime, retry_budget=retry_budget
            )
        except _KNOWN_TRANSACTION_FAILURES as exc:
            failure = (
                exc.stage if isinstance(exc, SupervisorTransactionError) else type(exc).__name__
            )

    condition = _transaction_condition(cursor, journal_path, state_path)
    if condition is PlanningEligibilityReason.COMPLETION_NOT_RECORDED:
        _record_completion(runtime, journal_path, state_path)
        return None
    if condition is PlanningEligibilityReason.TRANSACTION_HALTED:
        return _resume_until_terminal(
            runtime,
            txn_runtime,
            cursor,
            request,
            journal_path,
            state_path,
            attempts=retry_budget.max_attempts.root,
        )
    # Neither complete nor durably halted: nothing proves it is safe to act.
    return _stop(
        runtime,
        ProjectRunDisposition.EXECUTION_FAILED
        if launched
        else ProjectRunDisposition.RECOVERY_REQUIRED,
        run_id,
        detail=failure,
    )


# --- Public steps --------------------------------------------------------------------


def step_project_run(
    runtime: AgentRuntime,
    *,
    request_factory: TransactionRequestFactory | None = None,
    retry_budget: RetryBudget,
    planning_timeout_seconds: float,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
    jit_replan: bool = True,
) -> ProjectRunResult | None:
    """Perform exactly one durable orchestration step.

    Returns ``None`` when a step made durable progress and the caller should
    call again, or a :class:`ProjectRunResult` when orchestration must stop.
    One step is one of: freeze and bind the current Sub-phase's Contract;
    drive (launch, resume, or settle) the bound transaction, recording and
    retiring its Contract when it is canonically complete; replan the
    unfinished outline (only with *jit_replan*); or report that the Phase
    gate is ready. Recording completion, replanning, and planning the next
    Contract are separate steps. A required replan that fails stops the Phase
    (``EXECUTION_FAILED``) with the cursor and outline untouched.

    *jit_replan* makes a fresh Planner reconsider the unfinished outline after
    each recorded Sub-phase that leaves unfinished work. It is on by default;
    ``jit_replan=False`` explicitly selects the fixed-outline behavior, where
    the outline runs as published.

    *runtime* is the project-level runtime: its ``runtime_dir`` is the
    project run root, and its adapters plan Contracts. Each transaction runs
    against a copy of it rebound to that transaction's own runtime directory.

    *request_factory* is a controlled injection seam. Omitted (``None``), the host's
    canonical factory builds every transaction request from the project's
    configuration, the frozen Contract and the placement; see
    :mod:`lockstep.transaction_factory`.
    """
    factory = _resolve_request_factory(runtime, request_factory)
    cursor = _load_or_initialize(runtime.project_root, runtime.runtime_dir)

    if cursor.phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE:
        raise ProjectOrchestrationError("the project is complete; there is nothing left to run")

    if cursor.active_contract is not None:
        return _drive_bound_transaction(
            runtime, cursor, request_factory=factory, retry_budget=retry_budget
        )

    leftover = _reconcile_unbound_contract(runtime.project_root, runtime.runtime_dir, cursor)
    if cursor.phase_gate_status is PhaseGateStatus.READY:
        return _stop(runtime, ProjectRunDisposition.PHASE_GATE_READY, None)

    if jit_replan and jit_replan_state(runtime.project_root, runtime.runtime_dir) in (
        JitReplanState.REPLAN_REQUIRED,
        JitReplanState.REPLAN_ACCEPTED,
    ):
        return _replan(
            runtime,
            cursor,
            leftover,
            planning_timeout_seconds=planning_timeout_seconds,
            max_output_bytes=max_output_bytes,
            termination_grace_seconds=termination_grace_seconds,
        )

    _plan_and_bind(
        runtime,
        cursor,
        leftover,
        planning_timeout_seconds=planning_timeout_seconds,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=termination_grace_seconds,
    )
    return None


def run_project_phase(
    runtime: AgentRuntime,
    *,
    request_factory: TransactionRequestFactory | None = None,
    retry_budget: RetryBudget,
    planning_timeout_seconds: float,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
    jit_replan: bool = True,
) -> ProjectRunResult:
    """Run the current Phase's Sub-phases sequentially until it must stop.

    Repeats :func:`step_project_run` until it reports a stop: the Phase gate
    ready (every Sub-phase canonically complete), or a typed halt, human, or
    recovery disposition for the current Sub-phase. Safe to call again after
    a stop or a crash: all progress is re-derived from durable state, a
    finished Phase stops immediately, and nothing already started is run twice.
    *retry_budget* is passed through to the transaction layer; there is no
    project-level retry policy. By default the unfinished outline is replanned
    between Sub-phases (see :func:`step_project_run`), so the number of
    Sub-phases is not fixed in advance; pass ``jit_replan=False`` for the
    fixed-outline behavior. *request_factory* is a controlled injection seam; omitted,
    the host's canonical factory is used (and an unconfigured project is refused before
    anything launches).
    """
    factory = _resolve_request_factory(runtime, request_factory)
    start = _load_or_initialize(runtime.project_root, runtime.runtime_dir)
    already_recorded = len(start.completed_subphases)
    # Every non-terminal step changes the cursor or the replan state, so a run of
    # steps that changes neither means orchestration is not converging.
    progress = _progress(runtime, jit_replan)
    stalled = 0
    while stalled < _MAX_STALLED_STEPS:
        result = step_project_run(
            runtime,
            request_factory=factory,
            retry_budget=retry_budget,
            planning_timeout_seconds=planning_timeout_seconds,
            max_output_bytes=max_output_bytes,
            termination_grace_seconds=termination_grace_seconds,
            jit_replan=jit_replan,
        )
        if result is not None:
            return dataclasses.replace(
                result, completed=result.cursor.completed_subphases[already_recorded:]
            )
        latest = _progress(runtime, jit_replan)
        stalled = stalled + 1 if latest == progress else 0
        progress = latest
    raise ProjectOrchestrationError("orchestration did not converge")


_MAX_STALLED_STEPS = 3


def _progress(runtime: AgentRuntime, jit_replan: bool) -> tuple[int, JitReplanState | None]:
    cursor = load_project_cursor(runtime.project_root, runtime.runtime_dir)
    assert cursor is not None
    state = jit_replan_state(runtime.project_root, runtime.runtime_dir) if jit_replan else None
    return cursor.revision, state


__all__ = [
    "ProjectOrchestrationError",
    "ProjectRunDisposition",
    "ProjectRunResult",
    "TransactionPlacement",
    "TransactionRequestFactory",
    "allocate_transaction_run_id",
    "run_project_phase",
    "step_project_run",
    "transaction_runtime_dir",
    "transaction_worktree_path",
]
