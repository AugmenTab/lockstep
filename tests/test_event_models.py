from datetime import UTC, datetime

import pytest
from pydantic import ValidationError

from lockstep.domain import ProjectId, RunId, SchemaVersion, StopReason
from lockstep.persistence import (
    RunCreatedEvent,
    RunHaltedEvent,
    StateTransitionedEvent,
)
from lockstep.state import WorkflowState


def _occurred_at() -> datetime:
    return datetime(2026, 9, 23, 12, 0, tzinfo=UTC)


def _run_id() -> RunId:
    return RunId.model_validate("20260923-001")


def test_run_created_event_round_trips_through_json() -> None:
    event = RunCreatedEvent(
        run_id=_run_id(),
        sequence=1,
        occurred_at=_occurred_at(),
        project_id=ProjectId.model_validate("lockstep"),
    )

    restored = RunCreatedEvent.model_validate_json(event.model_dump_json())

    assert restored == event
    assert event.model_dump(mode="json") == {
        "schema_version": 1,
        "event_type": "run_created",
        "run_id": "20260923-001",
        "sequence": 1,
        "occurred_at": "2026-09-23T12:00:00Z",
        "project_id": "lockstep",
        "initial_state": "ready",
    }


def test_state_transitioned_event_round_trips_through_json() -> None:
    event = StateTransitionedEvent(
        run_id=_run_id(),
        sequence=2,
        occurred_at=_occurred_at(),
        source=WorkflowState.READY,
        target=WorkflowState.PHASE_PLANNING,
    )

    restored = StateTransitionedEvent.model_validate_json(event.model_dump_json())

    assert restored == event
    assert event.model_dump(mode="json")["event_type"] == "state_transitioned"
    assert event.model_dump(mode="json")["source"] == "ready"
    assert event.model_dump(mode="json")["target"] == "phase_planning"


def test_state_transitioned_event_rejects_illegal_edge() -> None:
    with pytest.raises(ValidationError):
        StateTransitionedEvent(
            run_id=_run_id(),
            sequence=2,
            occurred_at=_occurred_at(),
            source=WorkflowState.READY,
            target=WorkflowState.IMPLEMENTING,
        )


def test_run_halted_event_round_trips_through_json() -> None:
    event = RunHaltedEvent(
        run_id=_run_id(),
        sequence=3,
        occurred_at=_occurred_at(),
        reason=StopReason.NEEDS_USER,
        detail="The next action requires human input.",
    )

    restored = RunHaltedEvent.model_validate_json(event.model_dump_json())

    assert restored == event
    assert event.model_dump(mode="json")["reason"] == "needs_user"


@pytest.mark.parametrize(
    "event",
    [
        RunCreatedEvent(
            run_id=_run_id(),
            sequence=1,
            occurred_at=_occurred_at(),
            project_id=ProjectId.model_validate("lockstep"),
        ),
        StateTransitionedEvent(
            run_id=_run_id(),
            sequence=2,
            occurred_at=_occurred_at(),
            source=WorkflowState.READY,
            target=WorkflowState.PHASE_PLANNING,
        ),
        RunHaltedEvent(
            run_id=_run_id(),
            sequence=3,
            occurred_at=_occurred_at(),
            reason=StopReason.NEEDS_USER,
        ),
    ],
)
def test_event_rejects_unsupported_schema_version(event: object) -> None:
    data = event.model_dump(mode="json")  # type: ignore[attr-defined]
    data["schema_version"] = 2

    with pytest.raises(ValidationError):
        type(event).model_validate(data)  # type: ignore[attr-defined]


def test_event_schema_version_is_preserved_as_domain_type() -> None:
    event = RunCreatedEvent(
        run_id=_run_id(),
        sequence=1,
        occurred_at=_occurred_at(),
        project_id=ProjectId.model_validate("lockstep"),
    )

    assert event.schema_version == SchemaVersion.model_validate(1)


def test_event_rejects_unknown_fields() -> None:
    data = RunCreatedEvent(
        run_id=_run_id(),
        sequence=1,
        occurred_at=_occurred_at(),
        project_id=ProjectId.model_validate("lockstep"),
    ).model_dump(mode="json")
    data["unexpected"] = True

    with pytest.raises(ValidationError):
        RunCreatedEvent.model_validate(data)


def test_event_requires_timezone_aware_timestamp() -> None:
    with pytest.raises(ValidationError):
        RunCreatedEvent(
            run_id=_run_id(),
            sequence=1,
            occurred_at=datetime(2026, 9, 23, 12, 0),
            project_id=ProjectId.model_validate("lockstep"),
        )


@pytest.mark.parametrize("sequence", [0, -1, True, "1"])
def test_event_rejects_invalid_sequence(sequence: object) -> None:
    with pytest.raises(ValidationError):
        RunCreatedEvent(
            run_id=_run_id(),
            sequence=sequence,
            occurred_at=_occurred_at(),
            project_id=ProjectId.model_validate("lockstep"),
        )


def test_run_created_event_initial_state_is_always_ready() -> None:
    data = RunCreatedEvent(
        run_id=_run_id(),
        sequence=1,
        occurred_at=_occurred_at(),
        project_id=ProjectId.model_validate("lockstep"),
    ).model_dump(mode="json")
    data["initial_state"] = "implementing"

    with pytest.raises(ValidationError):
        RunCreatedEvent.model_validate(data)


def test_event_is_immutable() -> None:
    event = RunCreatedEvent(
        run_id=_run_id(),
        sequence=1,
        occurred_at=_occurred_at(),
        project_id=ProjectId.model_validate("lockstep"),
    )

    with pytest.raises(ValidationError):
        event.sequence = 2  # type: ignore[misc]


def test_halt_detail_must_be_non_blank_when_present() -> None:
    with pytest.raises(ValidationError):
        RunHaltedEvent(
            run_id=_run_id(),
            sequence=3,
            occurred_at=_occurred_at(),
            reason=StopReason.NEEDS_USER,
            detail="   ",
        )
