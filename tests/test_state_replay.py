from datetime import UTC, datetime

import pytest

from lockstep.domain import ProjectId, RunId, StopReason
from lockstep.persistence import (
    ReplayError,
    RunCreatedEvent,
    RunHaltedEvent,
    StateTransitionedEvent,
    replay_events,
)
from lockstep.state import WorkflowState


def _occurred_at() -> datetime:
    return datetime(2026, 9, 23, 12, 0, tzinfo=UTC)


def _run_id(value: str = "20260923-001") -> RunId:
    return RunId.model_validate(value)


def _created(
    *,
    run_id: RunId | None = None,
    sequence: int = 1,
) -> RunCreatedEvent:
    return RunCreatedEvent(
        run_id=run_id or _run_id(),
        sequence=sequence,
        occurred_at=_occurred_at(),
        project_id=ProjectId.model_validate("lockstep"),
    )


def _transition(
    *,
    run_id: RunId | None = None,
    sequence: int = 2,
    source: WorkflowState = WorkflowState.READY,
    target: WorkflowState = WorkflowState.PHASE_PLANNING,
) -> StateTransitionedEvent:
    return StateTransitionedEvent(
        run_id=run_id or _run_id(),
        sequence=sequence,
        occurred_at=_occurred_at(),
        source=source,
        target=target,
    )


def _halted(
    *,
    run_id: RunId | None = None,
    sequence: int = 2,
) -> RunHaltedEvent:
    return RunHaltedEvent(
        run_id=run_id or _run_id(),
        sequence=sequence,
        occurred_at=_occurred_at(),
        reason=StopReason.NEEDS_USER,
        detail="Human input is required.",
    )


def test_replay_run_created_event_produces_ready_snapshot() -> None:
    snapshot = replay_events((_created(),))

    assert snapshot.model_dump(mode="json") == {
        "schema_version": 1,
        "run_id": "20260923-001",
        "project_id": "lockstep",
        "workflow_state": "ready",
        "last_sequence": 1,
    }


def test_replay_applies_state_transition() -> None:
    snapshot = replay_events((_created(), _transition()))

    assert snapshot.workflow_state is WorkflowState.PHASE_PLANNING
    assert snapshot.last_sequence == 2


def test_replay_run_halted_event_transitions_to_halted() -> None:
    snapshot = replay_events((_created(), _halted()))

    assert snapshot.workflow_state is WorkflowState.HALTED
    assert snapshot.last_sequence == 2


def test_replay_rejects_empty_event_stream() -> None:
    with pytest.raises(ReplayError) as exc_info:
        replay_events(())

    assert exc_info.value.sequence is None


def test_replay_rejects_sequence_gap() -> None:
    events = (
        _created(),
        _transition(sequence=3),
    )

    with pytest.raises(ReplayError) as exc_info:
        replay_events(events)

    assert exc_info.value.sequence == 3


def test_replay_rejects_run_id_change() -> None:
    events = (
        _created(),
        _transition(run_id=_run_id("20260923-002")),
    )

    with pytest.raises(ReplayError) as exc_info:
        replay_events(events)

    assert exc_info.value.sequence == 2


def test_replay_rejects_second_run_created_event() -> None:
    events = (
        _created(),
        _created(sequence=2),
    )

    with pytest.raises(ReplayError) as exc_info:
        replay_events(events)

    assert exc_info.value.sequence == 2


def test_replay_rejects_transition_source_mismatch() -> None:
    events = (
        _created(),
        _transition(),
        _transition(
            sequence=3,
            source=WorkflowState.READY,
            target=WorkflowState.PHASE_PLANNING,
        ),
    )

    with pytest.raises(ReplayError) as exc_info:
        replay_events(events)

    assert exc_info.value.sequence == 3
    assert "source" in exc_info.value.reason


def test_replay_rejects_event_after_halt() -> None:
    events = (
        _created(),
        _halted(),
        _transition(
            sequence=3,
            source=WorkflowState.READY,
            target=WorkflowState.PHASE_PLANNING,
        ),
    )

    with pytest.raises(ReplayError) as exc_info:
        replay_events(events)

    assert exc_info.value.sequence == 3


def test_replay_error_exposes_reason_and_sequence() -> None:
    error = ReplayError("event stream is empty")

    assert error.reason == "event stream is empty"
    assert error.sequence is None
    assert str(error) == "event replay error: event stream is empty"
