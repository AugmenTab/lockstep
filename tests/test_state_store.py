from datetime import UTC, datetime
from pathlib import Path

import pytest

import lockstep.persistence.state_store as state_store
from lockstep.domain import ProjectId, RunId
from lockstep.persistence import (
    RunCreatedEvent,
    StateConsistencyError,
    StatePersistenceError,
    StateTransitionedEvent,
    append_event,
    load_verified_state,
    read_state,
    write_state,
)
from lockstep.state import RunStateSnapshot, WorkflowState


def _occurred_at() -> datetime:
    return datetime(2026, 9, 23, 12, 0, tzinfo=UTC)


def _run_id() -> RunId:
    return RunId.model_validate("20260923-001")


def _snapshot(
    *,
    workflow_state: WorkflowState = WorkflowState.READY,
    last_sequence: int = 1,
) -> RunStateSnapshot:
    return RunStateSnapshot(
        run_id=_run_id(),
        project_id=ProjectId.model_validate("lockstep"),
        workflow_state=workflow_state,
        last_sequence=last_sequence,
    )


def _created() -> RunCreatedEvent:
    return RunCreatedEvent(
        run_id=_run_id(),
        sequence=1,
        occurred_at=_occurred_at(),
        project_id=ProjectId.model_validate("lockstep"),
    )


def _transition() -> StateTransitionedEvent:
    return StateTransitionedEvent(
        run_id=_run_id(),
        sequence=2,
        occurred_at=_occurred_at(),
        source=WorkflowState.READY,
        target=WorkflowState.PHASE_PLANNING,
    )


def test_state_store_round_trips_snapshot(tmp_path: Path) -> None:
    path = tmp_path / "state.json"
    snapshot = _snapshot(
        workflow_state=WorkflowState.PHASE_PLANNING,
        last_sequence=2,
    )

    write_state(path, snapshot)

    assert read_state(path) == snapshot


def test_missing_state_file_reads_as_none(tmp_path: Path) -> None:
    assert read_state(tmp_path / "missing.json") is None


def test_invalid_state_file_raises_persistence_error(tmp_path: Path) -> None:
    path = tmp_path / "state.json"
    path.write_text("{broken json}")

    with pytest.raises(StatePersistenceError) as exc_info:
        read_state(path)

    assert exc_info.value.path == path
    assert exc_info.value.reason


def test_failed_atomic_replace_preserves_previous_snapshot(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    path = tmp_path / "state.json"
    original = _snapshot()
    replacement = _snapshot(
        workflow_state=WorkflowState.PHASE_PLANNING,
        last_sequence=2,
    )
    write_state(path, original)

    def fail_replace(source: str | Path, target: str | Path) -> None:
        raise OSError(f"cannot replace {source} with {target}")

    monkeypatch.setattr(state_store.os, "replace", fail_replace)

    with pytest.raises(StatePersistenceError):
        write_state(path, replacement)

    assert read_state(path) == original
    assert list(tmp_path.glob(".state.json.*.tmp")) == []


def test_load_verified_state_returns_none_when_nothing_exists(
    tmp_path: Path,
) -> None:
    state_path = tmp_path / "state.json"
    journal_path = tmp_path / "events.jsonl"

    assert load_verified_state(state_path, journal_path) is None


def test_load_verified_state_reconstructs_when_snapshot_is_missing(
    tmp_path: Path,
) -> None:
    state_path = tmp_path / "state.json"
    journal_path = tmp_path / "events.jsonl"
    append_event(journal_path, _created())
    append_event(journal_path, _transition())

    state = load_verified_state(state_path, journal_path)

    assert state == _snapshot(
        workflow_state=WorkflowState.PHASE_PLANNING,
        last_sequence=2,
    )


def test_load_verified_state_accepts_matching_snapshot(
    tmp_path: Path,
) -> None:
    state_path = tmp_path / "state.json"
    journal_path = tmp_path / "events.jsonl"
    append_event(journal_path, _created())
    write_state(state_path, _snapshot())

    assert load_verified_state(state_path, journal_path) == _snapshot()


def test_load_verified_state_advances_valid_stale_snapshot(
    tmp_path: Path,
) -> None:
    state_path = tmp_path / "state.json"
    journal_path = tmp_path / "events.jsonl"
    append_event(journal_path, _created())
    write_state(state_path, _snapshot())
    append_event(journal_path, _transition())

    state = load_verified_state(state_path, journal_path)

    assert state == _snapshot(
        workflow_state=WorkflowState.PHASE_PLANNING,
        last_sequence=2,
    )


def test_load_verified_state_rejects_inconsistent_snapshot(
    tmp_path: Path,
) -> None:
    state_path = tmp_path / "state.json"
    journal_path = tmp_path / "events.jsonl"
    append_event(journal_path, _created())
    write_state(
        state_path,
        _snapshot(
            workflow_state=WorkflowState.IMPLEMENTING,
            last_sequence=1,
        ),
    )

    with pytest.raises(StateConsistencyError):
        load_verified_state(state_path, journal_path)


def test_load_verified_state_rejects_snapshot_ahead_of_journal(
    tmp_path: Path,
) -> None:
    state_path = tmp_path / "state.json"
    journal_path = tmp_path / "events.jsonl"
    append_event(journal_path, _created())
    write_state(
        state_path,
        _snapshot(
            workflow_state=WorkflowState.PHASE_PLANNING,
            last_sequence=2,
        ),
    )

    with pytest.raises(StateConsistencyError):
        load_verified_state(state_path, journal_path)


def test_load_verified_state_rejects_orphan_snapshot(
    tmp_path: Path,
) -> None:
    state_path = tmp_path / "state.json"
    journal_path = tmp_path / "events.jsonl"
    write_state(state_path, _snapshot())

    with pytest.raises(StateConsistencyError):
        load_verified_state(state_path, journal_path)
