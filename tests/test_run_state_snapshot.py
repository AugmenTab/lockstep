import pytest
from pydantic import ValidationError

from lockstep.domain import ProjectId, RunId, SchemaVersion
from lockstep.state import RunStateSnapshot, WorkflowState


def _snapshot(
    *,
    workflow_state: WorkflowState = WorkflowState.READY,
    last_sequence: int = 1,
) -> RunStateSnapshot:
    return RunStateSnapshot(
        run_id=RunId.model_validate("20260923-001"),
        project_id=ProjectId.model_validate("lockstep"),
        workflow_state=workflow_state,
        last_sequence=last_sequence,
    )


def test_run_state_snapshot_round_trips_through_json() -> None:
    snapshot = _snapshot(
        workflow_state=WorkflowState.PHASE_PLANNING,
        last_sequence=2,
    )

    restored = RunStateSnapshot.model_validate_json(snapshot.model_dump_json())

    assert restored == snapshot
    assert snapshot.model_dump(mode="json") == {
        "schema_version": 1,
        "run_id": "20260923-001",
        "project_id": "lockstep",
        "workflow_state": "phase_planning",
        "last_sequence": 2,
    }


def test_run_state_snapshot_preserves_schema_version_type() -> None:
    snapshot = _snapshot()

    assert snapshot.schema_version == SchemaVersion.model_validate(1)


def test_run_state_snapshot_rejects_unsupported_schema_version() -> None:
    data = _snapshot().model_dump(mode="json")
    data["schema_version"] = 2

    with pytest.raises(ValidationError):
        RunStateSnapshot.model_validate(data)


@pytest.mark.parametrize("last_sequence", [0, -1, True, "1"])
def test_run_state_snapshot_rejects_invalid_last_sequence(
    last_sequence: object,
) -> None:
    with pytest.raises(ValidationError):
        RunStateSnapshot(
            run_id=RunId.model_validate("20260923-001"),
            project_id=ProjectId.model_validate("lockstep"),
            workflow_state=WorkflowState.READY,
            last_sequence=last_sequence,
        )


def test_run_state_snapshot_rejects_unknown_fields() -> None:
    data = _snapshot().model_dump(mode="json")
    data["unexpected"] = True

    with pytest.raises(ValidationError):
        RunStateSnapshot.model_validate(data)


def test_run_state_snapshot_is_immutable() -> None:
    snapshot = _snapshot()

    with pytest.raises(ValidationError):
        snapshot.workflow_state = WorkflowState.IMPLEMENTING  # type: ignore[misc]


def test_run_status_is_not_persisted_in_snapshot() -> None:
    dumped = _snapshot().model_dump(mode="json")

    assert "run_status" not in dumped
