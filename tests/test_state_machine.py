import pytest

from lockstep.domain import RunStatus
from lockstep.state import (
    InvalidTransitionError,
    WorkflowState,
    allowed_transitions,
    run_status_for,
    transition,
)

EXPECTED_TRANSITIONS = {
    WorkflowState.READY: frozenset(
        {
            WorkflowState.PHASE_PLANNING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.PHASE_PLANNING: frozenset(
        {
            WorkflowState.SUBPHASE_PLANNING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.SUBPHASE_PLANNING: frozenset(
        {
            WorkflowState.TEST_AUTHORING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.TEST_AUTHORING: frozenset(
        {
            WorkflowState.TEST_BASELINE_VERIFY,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.TEST_BASELINE_VERIFY: frozenset(
        {
            WorkflowState.TEST_COMMIT,
            WorkflowState.SUBPHASE_PLANNING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.TEST_COMMIT: frozenset(
        {
            WorkflowState.IMPLEMENTING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.IMPLEMENTING: frozenset(
        {
            WorkflowState.VERIFYING,
            WorkflowState.TEST_REVIEW,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.TEST_REVIEW: frozenset(
        {
            WorkflowState.TEST_AUTHORING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.VERIFYING: frozenset(
        {
            WorkflowState.REVIEWING,
            WorkflowState.IMPLEMENTING,
            WorkflowState.TEST_REVIEW,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.REVIEWING: frozenset(
        {
            WorkflowState.IMPLEMENTATION_COMMIT,
            WorkflowState.IMPLEMENTING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.IMPLEMENTATION_COMMIT: frozenset(
        {
            WorkflowState.SUBPHASE_COMPLETE,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.SUBPHASE_COMPLETE: frozenset(
        {
            WorkflowState.SUBPHASE_PLANNING,
            WorkflowState.PHASE_INTEGRATION_GATE,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.PHASE_INTEGRATION_GATE: frozenset(
        {
            WorkflowState.PHASE_COMPLETE,
            WorkflowState.SUBPHASE_PLANNING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.PHASE_COMPLETE: frozenset(
        {
            WorkflowState.PHASE_PLANNING,
            WorkflowState.COMPLETE,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.HALTED: frozenset(
        {
            WorkflowState.IMPLEMENTING,
            WorkflowState.REVIEWING,
        }
    ),
    WorkflowState.COMPLETE: frozenset(),
}


def test_workflow_state_values_are_stable() -> None:
    assert {member.name: member.value for member in WorkflowState} == {
        "READY": "ready",
        "PHASE_PLANNING": "phase_planning",
        "SUBPHASE_PLANNING": "subphase_planning",
        "TEST_AUTHORING": "test_authoring",
        "TEST_BASELINE_VERIFY": "test_baseline_verify",
        "TEST_COMMIT": "test_commit",
        "IMPLEMENTING": "implementing",
        "TEST_REVIEW": "test_review",
        "VERIFYING": "verifying",
        "REVIEWING": "reviewing",
        "IMPLEMENTATION_COMMIT": "implementation_commit",
        "SUBPHASE_COMPLETE": "subphase_complete",
        "PHASE_INTEGRATION_GATE": "phase_integration_gate",
        "PHASE_COMPLETE": "phase_complete",
        "HALTED": "halted",
        "COMPLETE": "complete",
    }


@pytest.mark.parametrize(
    ("source", "expected"),
    list(EXPECTED_TRANSITIONS.items()),
)
def test_allowed_transitions_match_frozen_graph(
    source: WorkflowState,
    expected: frozenset[WorkflowState],
) -> None:
    actual = allowed_transitions(source)

    assert isinstance(actual, frozenset)
    assert actual == expected


def test_every_declared_legal_transition_succeeds() -> None:
    for source, targets in EXPECTED_TRANSITIONS.items():
        for target in targets:
            assert transition(source, target) is target


def test_every_undeclared_transition_is_rejected() -> None:
    for source in WorkflowState:
        for target in WorkflowState:
            if target in EXPECTED_TRANSITIONS[source]:
                continue

            with pytest.raises(InvalidTransitionError):
                transition(source, target)


def test_invalid_transition_error_exposes_source_and_target() -> None:
    with pytest.raises(InvalidTransitionError) as exc_info:
        transition(WorkflowState.READY, WorkflowState.IMPLEMENTING)

    assert exc_info.value.source is WorkflowState.READY
    assert exc_info.value.target is WorkflowState.IMPLEMENTING
    assert "ready" in str(exc_info.value)
    assert "implementing" in str(exc_info.value)


def test_halted_resume_reentry_edges_and_complete_terminality() -> None:
    # Phase 9.13 supersedes the Phase-1.3 "HALTED is permanently terminal"
    # invariant: HALTED may re-enter execution through exactly the two
    # durable-resume edges Phase 9's claim/settlement protocol authorizes.
    # COMPLETE remains the only fully terminal state.
    assert allowed_transitions(WorkflowState.HALTED) == frozenset(
        {
            WorkflowState.IMPLEMENTING,
            WorkflowState.REVIEWING,
        }
    )
    assert allowed_transitions(WorkflowState.COMPLETE) == frozenset()


def test_no_workflow_state_can_transition_to_itself() -> None:
    for state in WorkflowState:
        assert state not in allowed_transitions(state)


@pytest.mark.parametrize(
    ("state", "expected_status"),
    [
        (WorkflowState.READY, RunStatus.READY),
        (WorkflowState.PHASE_PLANNING, RunStatus.RUNNING),
        (WorkflowState.SUBPHASE_PLANNING, RunStatus.RUNNING),
        (WorkflowState.TEST_AUTHORING, RunStatus.RUNNING),
        (WorkflowState.TEST_BASELINE_VERIFY, RunStatus.RUNNING),
        (WorkflowState.TEST_COMMIT, RunStatus.RUNNING),
        (WorkflowState.IMPLEMENTING, RunStatus.RUNNING),
        (WorkflowState.TEST_REVIEW, RunStatus.RUNNING),
        (WorkflowState.VERIFYING, RunStatus.RUNNING),
        (WorkflowState.REVIEWING, RunStatus.RUNNING),
        (WorkflowState.IMPLEMENTATION_COMMIT, RunStatus.RUNNING),
        (WorkflowState.SUBPHASE_COMPLETE, RunStatus.RUNNING),
        (WorkflowState.PHASE_INTEGRATION_GATE, RunStatus.RUNNING),
        (WorkflowState.PHASE_COMPLETE, RunStatus.RUNNING),
        (WorkflowState.HALTED, RunStatus.HALTED),
        (WorkflowState.COMPLETE, RunStatus.COMPLETE),
    ],
)
def test_run_status_is_derived_from_workflow_state(
    state: WorkflowState,
    expected_status: RunStatus,
) -> None:
    assert run_status_for(state) is expected_status
