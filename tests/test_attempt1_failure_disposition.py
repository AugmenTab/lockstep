"""10.8-R1: a known attempt-1 agent/provider failure is durably non-active before it escapes.

Every journal is written by the real transaction machinery against fake
provider executables. The invariant under test: once the failure is known and
control returns as an exception, durable state is ``HALTED`` with a typed
``TRANSACTION_HALTED`` boundary that carries no duplicate ``cause`` (the failed
``INVOCATION_RETURNED`` event is the single root-cause record), and no retry
authority, review verdict, escalation decision or commit has been fabricated.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from test_supervisor_implementer_blocker import (
    _implementer_blocked_response,
)
from test_supervisor_implementer_blocker import (
    _prepare_scenario as _blocker_scenario,
)
from test_supervisor_resume_execution import (
    _TEST_FILE_RED,
    _budget,
    _implementer_completed_response,
    _invocation_count,
    _planner_authoring_response,
    _prepare_scenario,
    _reviewer_turn_completed_response,
)
from test_transaction_baseline import (
    _IMPLEMENTER_USAGE,
    _PLANNER_USAGE,
    _REVIEWER_USAGE,
    _envelope,
    _failing,
    _reload_dir,
    _Run,
    _state,
)

from lockstep.agent_turn import AgentTurnError
from lockstep.domain import AgentRole, ExecutionEventKind, FailureCause
from lockstep.escalation import EscalationAuthority, EscalationCategory
from lockstep.escalation_transport import PlannerDecisionTransportError
from lockstep.metrics import project_runtime_metrics
from lockstep.persistence import ExecutionEvent, StateTransitionedEvent, read_events, replay_events
from lockstep.reviewer_turn import ReviewerTurnError
from lockstep.state import WorkflowState
from lockstep.supervisor.transaction import (
    ResumeExecutionDisposition,
    SupervisorTransactionError,
    resume_single_subphase_transaction,
    run_single_subphase_transaction_with_blockers,
    run_single_subphase_transaction_with_retry_checkpoint,
)


def _journal(runtime_dir: Path) -> list[object]:
    return list(read_events(runtime_dir / "events.jsonl"))


def _kinds(runtime_dir: Path) -> list[ExecutionEventKind]:
    return [e.kind for e in _journal(runtime_dir) if isinstance(e, ExecutionEvent)]


def _halts(runtime_dir: Path) -> list[ExecutionEvent]:
    return [
        e
        for e in _journal(runtime_dir)
        if isinstance(e, ExecutionEvent) and e.kind is ExecutionEventKind.TRANSACTION_HALTED
    ]


def _assert_halt_boundary(runtime_dir: Path, *, stage: str, failed_role: AgentRole) -> None:
    """Failure evidence -> HALTED transition -> typed halt event, in journal order."""
    events = _journal(runtime_dir)
    failed = [
        i
        for i, e in enumerate(events)
        if isinstance(e, ExecutionEvent)
        and e.kind is ExecutionEventKind.INVOCATION_RETURNED
        and e.role is failed_role
        and e.cause is not None
    ]
    to_halted = [
        i
        for i, e in enumerate(events)
        if isinstance(e, StateTransitionedEvent) and e.target is WorkflowState.HALTED
    ]
    halted = [
        i
        for i, e in enumerate(events)
        if isinstance(e, ExecutionEvent) and e.kind is ExecutionEventKind.TRANSACTION_HALTED
    ]
    assert len(failed) == len(to_halted) == len(halted) == 1
    assert failed[0] < to_halted[0] < halted[0]

    [halt] = _halts(runtime_dir)
    assert halt.cause is None and halt.stop_reason is None
    assert halt.detail == stage
    assert _state(runtime_dir) is WorkflowState.HALTED


def _assert_reload_is_halted(run: _Run, tmp_path: Path) -> None:
    fresh = _reload_dir(run, tmp_path)
    snapshot = replay_events(read_events(fresh / "events.jsonl"))
    assert snapshot.workflow_state is WorkflowState.HALTED

    totals = project_runtime_metrics(fresh, repository_change=None).totals
    assert totals.subphases_completed == 0
    assert totals.failure_cause_events == {FailureCause.PROVIDER_PROCESS_FAILURE: 1}
    assert totals.usage.elapsed.reporting_invocations >= 1


# ---------------------------------------------------------------------------
# Planner test-authoring failure
# ---------------------------------------------------------------------------


def test_planner_failure_halts_without_test_commit_or_baseline(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "s",
        planner_responses=[
            _failing(_envelope(_planner_authoring_response(_TEST_FILE_RED), _PLANNER_USAGE))
        ],
    )

    with pytest.raises(SupervisorTransactionError):
        run_single_subphase_transaction_with_retry_checkpoint(
            scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
        )

    runtime_dir = scenario.request.runtime_dir
    _assert_halt_boundary(runtime_dir, stage="planner", failed_role=AgentRole.PLANNER)
    kinds = _kinds(runtime_dir)
    assert ExecutionEventKind.TESTS_FROZEN not in kinds
    assert ExecutionEventKind.BASELINE_VERIFIED not in kinds
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 0
    _assert_reload_is_halted(_Run("planner-failure", scenario, None, _state(runtime_dir)), tmp_path)


# ---------------------------------------------------------------------------
# Implementer failure (blocker-capable pipeline)
# ---------------------------------------------------------------------------


def _implementer_failure(root: Path):  # type: ignore[no-untyped-def]
    scenario = _prepare_scenario(
        root,
        planner_responses=[_envelope(_planner_authoring_response(_TEST_FILE_RED), _PLANNER_USAGE)],
        implementer_responses=[
            _failing(
                _envelope(
                    _implementer_completed_response({"feature.py": "x = 1\n"}), _IMPLEMENTER_USAGE
                )
            )
        ],
    )
    with pytest.raises(AgentTurnError):
        run_single_subphase_transaction_with_retry_checkpoint(
            scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
        )
    return scenario


def test_implementer_failure_halts_with_one_failure_cause_and_no_authority(
    tmp_path: Path,
) -> None:
    scenario = _implementer_failure(tmp_path / "s")
    runtime_dir = scenario.request.runtime_dir

    _assert_halt_boundary(runtime_dir, stage="implementer", failed_role=AgentRole.IMPLEMENTER)
    kinds = _kinds(runtime_dir)
    assert ExecutionEventKind.REVIEW_DECIDED not in kinds
    assert ExecutionEventKind.RETRY_AUTHORIZED not in kinds
    run = _Run("implementer-failure", scenario, None, _state(runtime_dir))
    _assert_reload_is_halted(run, tmp_path)

    # HALTED alone is not retry authority: resume finds no checkpoint and launches nothing.
    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert result.disposition is ResumeExecutionDisposition.NO_CHECKPOINT
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 0
    assert _state(runtime_dir) is WorkflowState.HALTED


# ---------------------------------------------------------------------------
# Reviewer failure
# ---------------------------------------------------------------------------


def test_reviewer_failure_halts_without_verdict_or_approval(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "s",
        planner_responses=[_envelope(_planner_authoring_response(_TEST_FILE_RED), _PLANNER_USAGE)],
        implementer_responses=[
            _envelope(
                _implementer_completed_response(
                    {"feature.py": "def answer() -> int:\n    return 42\n"}
                ),
                _IMPLEMENTER_USAGE,
            )
        ],
        reviewer_responses=[
            _failing(_envelope(_reviewer_turn_completed_response(), _REVIEWER_USAGE))
        ],
    )

    with pytest.raises(ReviewerTurnError):
        run_single_subphase_transaction_with_retry_checkpoint(
            scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
        )

    runtime_dir = scenario.request.runtime_dir
    _assert_halt_boundary(runtime_dir, stage="reviewer", failed_role=AgentRole.REVIEWER)
    kinds = _kinds(runtime_dir)
    assert ExecutionEventKind.REVIEW_DECIDED not in kinds
    assert ExecutionEventKind.RETRY_AUTHORIZED not in kinds
    _assert_reload_is_halted(
        _Run("reviewer-failure", scenario, None, _state(runtime_dir)), tmp_path
    )
    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert result.disposition is ResumeExecutionDisposition.NO_CHECKPOINT


# ---------------------------------------------------------------------------
# Escalation dispatch failure
# ---------------------------------------------------------------------------


def test_escalation_failure_halts_without_fabricating_a_decision(tmp_path: Path) -> None:
    scenario = _blocker_scenario(
        tmp_path,
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            {"stdout": "", "returncode": 7},
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.PLANNER_DECISION_REQUIRED,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    with pytest.raises(PlannerDecisionTransportError):
        run_single_subphase_transaction_with_blockers(
            scenario.request, agent_turn_runtime=scenario.runtime
        )

    runtime_dir = scenario.request.runtime_dir
    [halt] = _halts(runtime_dir)
    assert halt.cause is None and halt.stop_reason is None
    assert halt.detail == "escalation"
    assert _state(runtime_dir) is WorkflowState.HALTED
    kinds = _kinds(runtime_dir)
    assert ExecutionEventKind.ESCALATION_DISPATCHED not in kinds
    assert ExecutionEventKind.RETRY_AUTHORIZED not in kinds
