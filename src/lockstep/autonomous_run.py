"""The bounded autonomous project-run driver.

A project-level driver that can cross Sub-phase *and* Phase boundaries with no human relaying
normal successful work, while always knowing why it may continue and exactly when it must stop::

    load run control + ProjectCursor
        -> repair derived evidence               (a missing PHASE_COMPLETE event; evidence only)
        -> finish completed-Phase teardown       (transient residue only; a refusal stops the run)
        -> project complete?                     stop PROJECT_COMPLETE
        -> requested Phase boundary reached?     stop PHASE_BOUNDARY_REACHED
        -> authoritative usage exhaustion?       stop USAGE_LIMIT
        -> wall-clock budget spent?              stop WALL_CLOCK_BUDGET_EXHAUSTED
        -> cursor READY      -> one Phase-gate step (attempt / PASS completion / remediation)
        -> cursor PENDING    -> reserve the unit against the Sub-phase budget, then one
                                orchestration step (replan / plan+bind / drive+record)

There is no unbounded mode. The host owns advancement, retry limits, budgets and hard stops:
the policy is finite and immutable, the Sub-phase budget is debited durably *before* a unit may
launch, the wall-clock deadline is fixed once and enforced at every process launch (see
:mod:`lockstep.process.budget`), and nothing an agent says -- a Planner "keep going", an
Implementer "one more thing", a Reviewer APPROVE -- extends a run.

Composition, not reimplementation. Progression stays solely in the ``ProjectCursor``; this
module composes the accepted layers at their *narrowest* seams so a global bound can be checked
between steps instead of being bypassed by a monolithic helper: :func:`step_project_run` for one
orchestration step, :func:`run_phase_gate_attempt` for one gate attempt, and the 11.5 completion
and remediation steps. It deliberately calls neither ``run_project_phase`` nor
``run_phase_gate_cycle``. Run control (:mod:`lockstep.autonomous_run_control`) records only
budget use and the stop; it is never read back to steer or repair the cursor.

Stops are explicit and never skipped past. A child that is halted, needs a human, needs recovery,
or failed is a hard stop of the whole run -- never "proceed to the next Sub-phase". A halted
child with an authoritative, typed usage-exhaustion fact stops as ``USAGE_LIMIT``; quota is never
inferred from provider prose, and ``UNKNOWN`` / ``LOW`` / ``SAFE`` never stop a run. A failure
the host cannot classify is recorded as a terminal stop and re-raised: it is never caught to
continue. Crash safety comes from durable state alone: reserving a unit again is a no-op, a
completed-but-unrecorded child is reconciled without spending budget, and writers are assumed
single-process.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from lockstep.autonomous_run_control import (
    AutonomousRunDisposition,
    AutonomousRunError,
    AutonomousRunPolicy,
    AutonomousRunPolicyError,
    ProjectRunId,
    ProjectRunRecord,
    ReservationOutcome,
    create_project_run,
    load_project_run,
    load_project_run_state,
    record_project_run_stop,
    remaining_subphase_budget,
    require_finite_policy,
    require_same_policy,
    reserve_subphase,
)
from lockstep.domain import FailureCause, PhaseId, QuotaStatus, StopReason
from lockstep.jit_replan import JitReplanState, jit_replan_state
from lockstep.persistence import ExecutionEvent, read_events
from lockstep.phase_gate import (
    PhaseGateAttemptDisposition,
    load_remediation_receipt,
    run_phase_gate_attempt,
)
from lockstep.phase_gate_cycle import (
    apply_gate_remediation,
    complete_phase_from_gate_pass,
    plan_gate_remediation,
    remediation_in_flight,
    remediations_spent,
    repair_phase_complete_evidence,
)
from lockstep.phase_teardown import ensure_completed_phase_teardown
from lockstep.planning import PlanningValidationError
from lockstep.planning_store import load_active_subphase_contract, load_frozen_master_plan
from lockstep.planning_transport import PlanningTransportError
from lockstep.process import ProcessConfigurationError, ProcessLaunchError, ProcessTimeoutError
from lockstep.process.budget import RunTimeBudget, run_time_budget
from lockstep.project_cursor import (
    CompletedSubphase,
    PhaseGateStatus,
    PlanningEligibilityReason,
    ProjectCursor,
)
from lockstep.project_cursor_store import initialize_project_cursor, load_project_cursor
from lockstep.project_orchestrator import (
    ProjectRunDisposition,
    ProjectRunResult,
    TransactionRequestFactory,
    allocate_transaction_run_id,
    bound_transaction_condition,
    step_project_run,
    transaction_runtime_dir,
)
from lockstep.runtime import AgentRuntime
from lockstep.supervisor.escalation import SupervisorEscalationDisposition
from lockstep.supervisor.transaction import ResumeExecutionDisposition

_JOURNAL_NAME = "events.jsonl"
_MAX_STALLED_ITERATIONS = 3

# Operational failures of launching or validating a Planner call that the orchestration layer
# does not itself classify. They stop the run with a typed result; anything else is unknown and
# is recorded as a terminal stop and re-raised.
_KNOWN_OPERATIONAL_FAILURES = (
    ProcessTimeoutError,
    ProcessLaunchError,
    ProcessConfigurationError,
    PlanningTransportError,
    PlanningValidationError,
)

_STOP_FOR_CHILD = {
    ProjectRunDisposition.HUMAN_REQUIRED: AutonomousRunDisposition.HUMAN_REQUIRED,
    ProjectRunDisposition.RECOVERY_REQUIRED: AutonomousRunDisposition.RECOVERY_REQUIRED,
    ProjectRunDisposition.HALTED: AutonomousRunDisposition.TERMINAL_HALT,
    ProjectRunDisposition.EXECUTION_FAILED: AutonomousRunDisposition.TERMINAL_HALT,
}


def _utc_now() -> datetime:
    return datetime.now(UTC)


@dataclass(frozen=True, slots=True)
class AutonomousRunResult:
    """Typed outcome of one :func:`run_autonomous_project` call.

    ``cursor`` is the durable cursor at the moment of stopping. ``reserved_subphases`` is the
    total Sub-phase budget this project run has spent so far (across restarts);
    ``completed_subphases`` / ``completed_phases`` are what *this call* recorded. The child
    fields carry the underlying authoritative reason when a child stopped the run.
    ``remediation_required`` says a Phase gate failed and its repair could not start.
    """

    disposition: AutonomousRunDisposition
    project_run_id: ProjectRunId
    cursor: ProjectCursor = field(repr=False)
    reserved_subphases: int
    completed_subphases: tuple[CompletedSubphase, ...] = ()
    completed_phases: tuple[PhaseId, ...] = ()
    child_disposition: ProjectRunDisposition | None = None
    escalation_disposition: SupervisorEscalationDisposition | None = None
    resume_disposition: ResumeExecutionDisposition | None = None
    stop_reason: StopReason | None = None
    remediation_required: bool = False
    detail: str | None = None


# --- Authoritative usage exhaustion ----------------------------------------------------------


def child_usage_exhausted(journal_path: Path) -> bool:
    """Does a child transaction journal carry an authoritative, typed usage-exhaustion fact?

    Only typed facts count: a provider-reported ``QuotaStatus.EXHAUSTED``, a recorded
    ``FailureCause.USAGE_EXHAUSTION`` attribution, or a ``StopReason.USAGE_LIMIT`` boundary.
    ``UNKNOWN``, ``LOW`` and ``SAFE`` quota are normal, and no provider prose is ever read.
    """
    for event in read_events(journal_path):
        if not isinstance(event, ExecutionEvent):
            continue
        if (
            event.cause is FailureCause.USAGE_EXHAUSTION
            or event.stop_reason is StopReason.USAGE_LIMIT
        ):
            return True
        if event.usage is not None and event.usage.quota_status is QuotaStatus.EXHAUSTED:
            return True
    return False


# --- Starting a run ----------------------------------------------------------------------


def _load_or_initialize(runtime: AgentRuntime) -> ProjectCursor:
    cursor = load_project_cursor(runtime.project_root, runtime.runtime_dir)
    if cursor is None:
        cursor = initialize_project_cursor(runtime.project_root, runtime.runtime_dir)
    return cursor


def _require_known_until_phase(runtime: AgentRuntime, policy: AutonomousRunPolicy) -> None:
    if policy.until_phase is None:
        return
    master = load_frozen_master_plan(runtime.project_root)
    if master is None or all(p.phase_id != policy.until_phase for p in master.phases):
        raise AutonomousRunPolicyError("until_phase is not a phase of the frozen master plan")


def start_project_run(
    runtime: AgentRuntime,
    policy: AutonomousRunPolicy,
    *,
    clock: Callable[[], datetime] = _utc_now,
) -> ProjectRunRecord:
    """Durably create one unattended project run: identity, immutable policy, start, deadline.

    Launches nothing. The policy must be finite and its ``until_phase`` (if any) must be a Phase
    of the frozen Master Plan; either failure refuses deterministically before any record exists.
    """
    require_finite_policy(policy)
    cursor = _load_or_initialize(runtime)
    _require_known_until_phase(runtime, policy)
    return create_project_run(
        runtime.runtime_dir,
        project_id=cursor.project_id,
        master_plan_digest=cursor.master_plan_digest,
        policy=policy,
        clock=clock,
    )


# --- The driver --------------------------------------------------------------------------


class _Driver:
    def __init__(
        self,
        runtime: AgentRuntime,
        record: ProjectRunRecord,
        budget: RunTimeBudget,
        *,
        request_factory: TransactionRequestFactory | None,
        clock: Callable[[], datetime],
        planning_timeout_seconds: float,
        max_output_bytes: int,
        termination_grace_seconds: float,
    ) -> None:
        self.runtime = runtime
        self.record = record
        self.policy = record.policy
        self.budget = budget
        self.request_factory = request_factory
        self.clock = clock
        self.planning_timeout_seconds = planning_timeout_seconds
        self.max_output_bytes = max_output_bytes
        self.termination_grace_seconds = termination_grace_seconds
        entry = _load_or_initialize(runtime)
        self.subphases_at_entry = len(entry.completed_subphases)
        self.phases_at_entry = entry.completed_phases
        self.usage_checked = self.subphases_at_entry

    # -- stopping -------------------------------------------------------------------------

    def stop(
        self,
        disposition: AutonomousRunDisposition,
        *,
        child: ProjectRunResult | None = None,
        detail: str | None = None,
        stop_reason: StopReason | None = None,
        remediation_required: bool = False,
    ) -> AutonomousRunResult:
        runtime = self.runtime
        cursor = load_project_cursor(runtime.project_root, runtime.runtime_dir)
        assert cursor is not None
        child_detail = child.detail if child is not None else None
        text = detail if detail is not None else child_detail
        record_project_run_stop(
            runtime.runtime_dir,
            self.record.project_run_id,
            disposition=disposition,
            detail=text or None,
            clock=self.clock,
        )
        state = load_project_run_state(runtime.runtime_dir, self.record.project_run_id)
        return AutonomousRunResult(
            disposition=disposition,
            project_run_id=self.record.project_run_id,
            cursor=cursor,
            reserved_subphases=len(state.reservations),
            completed_subphases=cursor.completed_subphases[self.subphases_at_entry :],
            completed_phases=tuple(
                p for p in cursor.completed_phases if p not in self.phases_at_entry
            ),
            child_disposition=child.disposition if child is not None else None,
            escalation_disposition=child.escalation_disposition if child is not None else None,
            resume_disposition=child.resume_disposition if child is not None else None,
            stop_reason=stop_reason,
            remediation_required=remediation_required,
            detail=text or None,
        )

    def stop_for_failure(
        self, detail: str, *, child: ProjectRunResult | None = None
    ) -> AutonomousRunResult:
        """A stop caused by something failing: the run budget if it was the cause, else terminal."""
        if self.budget.exhausted:
            return self.stop(AutonomousRunDisposition.WALL_CLOCK_BUDGET_EXHAUSTED, child=child)
        return self.stop(AutonomousRunDisposition.TERMINAL_HALT, child=child, detail=detail)

    # -- budgets --------------------------------------------------------------------------

    def subphase_capacity(self) -> int:
        state = load_project_run_state(self.runtime.runtime_dir, self.record.project_run_id)
        return remaining_subphase_budget(self.record, state)

    def time_left(self) -> bool:
        if self.budget.remaining_seconds() <= 0:
            self.budget.mark_exhausted()
            return False
        return True

    # -- the loop -------------------------------------------------------------------------

    def run(self) -> AutonomousRunResult:
        runtime = self.runtime
        master = load_frozen_master_plan(runtime.project_root)
        if master is None:
            raise AutonomousRunError("the master plan is not frozen")
        order = [p.phase_id for p in master.phases]
        policy = self.policy
        limit = max(64, 16 * (policy.max_subphases + policy.max_gate_remediations + len(order) + 4))

        previous: tuple[object, ...] | None = None
        stalled = 0
        for _ in range(limit):
            cursor = _load_or_initialize(runtime)
            repair_phase_complete_evidence(runtime)
            # A completed Phase's pending teardown is finished before any further work.
            ensure_completed_phase_teardown(runtime)

            if cursor.phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE:
                return self.stop(AutonomousRunDisposition.PROJECT_COMPLETE)
            until = policy.until_phase
            if until is not None:
                if until in cursor.completed_phases:
                    return self.stop(AutonomousRunDisposition.PHASE_BOUNDARY_REACHED)
                if cursor.current_phase is not None and order.index(
                    cursor.current_phase
                ) > order.index(until):
                    raise AutonomousRunError("the cursor is past until_phase without completing it")

            if self.usage_exhausted(cursor):
                return self.stop(
                    AutonomousRunDisposition.USAGE_LIMIT, stop_reason=StopReason.USAGE_LIMIT
                )
            if not self.time_left():
                return self.stop(AutonomousRunDisposition.WALL_CLOCK_BUDGET_EXHAUSTED)

            if cursor.phase_gate_status is PhaseGateStatus.READY:
                outcome = self.gate_step(cursor)
            else:
                outcome = self.subphase_step(cursor)
            if outcome is not None:
                return outcome

            signature = self.signature()
            stalled = stalled + 1 if signature == previous else 0
            previous = signature
            if stalled >= _MAX_STALLED_ITERATIONS:
                raise AutonomousRunError("the autonomous run did not make progress")
        raise AutonomousRunError("the autonomous run did not converge within its bounded steps")

    def signature(self) -> tuple[object, ...]:
        runtime = self.runtime
        cursor = load_project_cursor(runtime.project_root, runtime.runtime_dir)
        assert cursor is not None
        jit = jit_replan_state(runtime.project_root, runtime.runtime_dir)
        state = load_project_run_state(runtime.runtime_dir, self.record.project_run_id)
        return (cursor.revision, jit, len(state.reservations))

    def usage_exhausted(self, cursor: ProjectCursor) -> bool:
        """Did a Sub-phase this call completed report authoritative usage exhaustion?"""
        fresh = cursor.completed_subphases[self.usage_checked :]
        self.usage_checked = len(cursor.completed_subphases)
        return any(
            child_usage_exhausted(
                transaction_runtime_dir(self.runtime.runtime_dir, entry.run_id) / _JOURNAL_NAME
            )
            for entry in fresh
        )

    # -- a Sub-phase step -----------------------------------------------------------------------

    def subphase_step(self, cursor: ProjectCursor) -> AutonomousRunResult | None:
        runtime = self.runtime
        remediation = remediation_in_flight(runtime, cursor)
        needs_reservation = True
        if cursor.active_contract is not None:
            condition = bound_transaction_condition(runtime, cursor)
            # A completed child the cursor has not recorded is reconciled for free: no agent
            # work is newly authorized, so no budget is spent.
            if condition is PlanningEligibilityReason.COMPLETION_NOT_RECORDED:
                needs_reservation = False
        elif not remediation and jit_replan_state(runtime.project_root, runtime.runtime_dir) in (
            JitReplanState.REPLAN_REQUIRED,
            JitReplanState.REPLAN_ACCEPTED,
        ):
            # The next unit's replan only makes sense if the next unit may execute. Stopping here
            # delays the replan to a later run; it never skips it.
            if self.subphase_capacity() <= 0:
                return self.stop(AutonomousRunDisposition.MAX_SUBPHASES_REACHED)
            needs_reservation = False

        if needs_reservation:
            assert cursor.current_phase is not None and cursor.current_subphase is not None
            reserved = reserve_subphase(
                runtime.runtime_dir,
                self.record.project_run_id,
                phase_id=cursor.current_phase,
                subphase_id=cursor.current_subphase,
                transaction_run_id=allocate_transaction_run_id(
                    cursor.current_phase, cursor.current_subphase
                ),
                clock=self.clock,
            )
            if reserved is ReservationOutcome.EXHAUSTED:
                return self.stop(AutonomousRunDisposition.MAX_SUBPHASES_REACHED)

        result = step_project_run(
            runtime,
            request_factory=self.request_factory,
            retry_budget=self.policy.retry_budget,
            planning_timeout_seconds=self.planning_timeout_seconds,
            max_output_bytes=self.max_output_bytes,
            termination_grace_seconds=self.termination_grace_seconds,
            # JIT replanning stays the default; only an accepted gate remediation is the fixed
            # outline case it always was.
            jit_replan=not remediation,
        )
        return None if result is None else self.child_stop(result)

    def child_stop(self, child: ProjectRunResult) -> AutonomousRunResult:
        """Map a stopped child to a run-level stop; a child halt never means "continue"."""
        if child.transaction_run_id is not None:
            journal = (
                transaction_runtime_dir(self.runtime.runtime_dir, child.transaction_run_id)
                / _JOURNAL_NAME
            )
            if child_usage_exhausted(journal):
                return self.stop(
                    AutonomousRunDisposition.USAGE_LIMIT,
                    child=child,
                    stop_reason=StopReason.USAGE_LIMIT,
                )
        if self.budget.exhausted:
            return self.stop(AutonomousRunDisposition.WALL_CLOCK_BUDGET_EXHAUSTED, child=child)
        disposition = _STOP_FOR_CHILD.get(child.disposition)
        if disposition is None:
            raise AutonomousRunError(
                "an orchestration step stopped for a reason that is not a stop"
            )
        return self.stop(disposition, child=child)

    # -- a Phase-gate step ------------------------------------------------------------------------

    def gate_step(self, cursor: ProjectCursor) -> AutonomousRunResult | None:
        runtime = self.runtime
        if load_active_subphase_contract(runtime.project_root, runtime.runtime_dir) is not None:
            # A crash between recording the last Sub-phase and retiring its Contract: the
            # orchestrator settles it for free (it reports the gate ready and does nothing else).
            step_project_run(
                runtime,
                request_factory=self.request_factory,
                retry_budget=self.policy.retry_budget,
                planning_timeout_seconds=self.planning_timeout_seconds,
                max_output_bytes=self.max_output_bytes,
                termination_grace_seconds=self.termination_grace_seconds,
            )
            return None

        phase_id = cursor.current_phase
        assert phase_id is not None
        attempt = run_phase_gate_attempt(
            runtime,
            planning_timeout_seconds=self.planning_timeout_seconds,
            max_output_bytes=self.max_output_bytes,
            termination_grace_seconds=self.termination_grace_seconds,
        )
        if attempt.disposition is PhaseGateAttemptDisposition.EXECUTION_FAILED:
            return self.stop_for_failure(attempt.detail or "the phase gate could not be executed")
        assert attempt.decision is not None
        if attempt.disposition is PhaseGateAttemptDisposition.PASSED:
            complete_phase_from_gate_pass(runtime, attempt.decision)
            return None

        # An accepted FAIL. Persisting it cost no Sub-phase budget; repairing it does.
        receipt = load_remediation_receipt(runtime.runtime_dir, phase_id, attempt.gate_attempt)
        if receipt is None:
            if remediations_spent(runtime, phase_id) >= self.policy.max_gate_remediations:
                return self.stop(
                    AutonomousRunDisposition.GATE_REMEDIATION_EXHAUSTED,
                    detail="the phase gate failed and its remediation bound is spent",
                    remediation_required=True,
                )
            if self.subphase_capacity() <= 0:
                return self.stop(
                    AutonomousRunDisposition.MAX_SUBPHASES_REACHED,
                    detail="the phase gate failed; remediation requires a sub-phase budget",
                    remediation_required=True,
                )
            receipt, failure = plan_gate_remediation(
                runtime,
                cursor,
                attempt,
                planning_timeout_seconds=self.planning_timeout_seconds,
                max_output_bytes=self.max_output_bytes,
                termination_grace_seconds=self.termination_grace_seconds,
            )
            if receipt is None:
                return self.stop_for_failure(failure or "remediation planning failed")
        apply_gate_remediation(runtime, receipt)
        return None


def run_autonomous_project(
    runtime: AgentRuntime,
    *,
    policy: AutonomousRunPolicy,
    project_run_id: ProjectRunId | None = None,
    request_factory: TransactionRequestFactory | None = None,
    clock: Callable[[], datetime] = _utc_now,
    planning_timeout_seconds: float | None = None,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
) -> AutonomousRunResult:
    """Run the project unattended under *policy* until exactly one bounded stop is true.

    With no *project_run_id* a new unattended run is created (fixing its identity, deadline, and
    immutable policy); with one, that run is resumed and *policy* must be identical to the one it
    started with -- a run can never silently gain authority, so larger bounds mean a new run. The
    policy must be finite and is refused before anything could launch. The stop is one of
    :class:`~lockstep.autonomous_run_control.AutonomousRunDisposition`; it is recorded durably
    and returned. Safe to call again after any stop or crash: all progress is re-derived from
    the cursor and the run-control state, and nothing already started is run twice.

    *request_factory* is a controlled injection seam; omitted, the host's canonical factory is
    used. *planning_timeout_seconds* defaults to the project's agent timeout; every launch is
    additionally capped to the run's remaining wall-clock time. JIT replanning is on whenever
    continuation is authorized. An unclassified internal failure is recorded as a terminal stop
    and re-raised, never continued past.
    """
    require_finite_policy(policy)
    if project_run_id is None:
        record = start_project_run(runtime, policy, clock=clock)
    else:
        existing = load_project_run(runtime.runtime_dir, project_run_id)
        if existing is None:
            raise AutonomousRunError("the project run is unknown")
        require_same_policy(existing, policy)
        _require_known_until_phase(runtime, existing.policy)
        record = existing

    budget = RunTimeBudget(deadline=record.deadline_at, clock=clock)
    driver = _Driver(
        runtime,
        record,
        budget,
        request_factory=request_factory,
        clock=clock,
        planning_timeout_seconds=(
            planning_timeout_seconds
            if planning_timeout_seconds is not None
            else runtime.config.execution.agent_timeout_seconds
        ),
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=termination_grace_seconds,
    )
    try:
        with run_time_budget(budget):
            return driver.run()
    except _KNOWN_OPERATIONAL_FAILURES as exc:
        return driver.stop_for_failure(type(exc).__name__)
    except Exception as exc:
        if budget.exhausted:
            return driver.stop(AutonomousRunDisposition.WALL_CLOCK_BUDGET_EXHAUSTED)
        # Unknown: leave durable terminal evidence, then surface the failure. Never continue.
        record_project_run_stop(
            runtime.runtime_dir,
            record.project_run_id,
            disposition=AutonomousRunDisposition.TERMINAL_HALT,
            detail=type(exc).__name__,
            clock=clock,
        )
        raise


__all__ = [
    "AutonomousRunResult",
    "child_usage_exhausted",
    "run_autonomous_project",
    "start_project_run",
]
