from datetime import UTC, datetime
from pathlib import Path

import pytest

from lockstep.domain import ProjectId, RunId, StopReason
from lockstep.persistence import (
    JournalIntegrityError,
    RunCreatedEvent,
    RunHaltedEvent,
    StateTransitionedEvent,
    append_event,
    read_events,
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
) -> StateTransitionedEvent:
    return StateTransitionedEvent(
        run_id=run_id or _run_id(),
        sequence=sequence,
        occurred_at=_occurred_at(),
        source=WorkflowState.READY,
        target=WorkflowState.PHASE_PLANNING,
    )


def _halted(
    *,
    run_id: RunId | None = None,
    sequence: int = 3,
) -> RunHaltedEvent:
    return RunHaltedEvent(
        run_id=run_id or _run_id(),
        sequence=sequence,
        occurred_at=_occurred_at(),
        reason=StopReason.NEEDS_USER,
    )


def test_journal_appends_and_reads_events_in_order(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"

    append_event(path, _created())
    append_event(path, _transition())
    append_event(path, _halted())

    events = read_events(path)

    assert events == (_created(), _transition(), _halted())
    assert path.read_text().count("\n") == 3


def test_missing_journal_reads_as_empty(tmp_path: Path) -> None:
    assert read_events(tmp_path / "missing.jsonl") == ()


def test_first_event_must_be_run_created(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"

    with pytest.raises(JournalIntegrityError):
        append_event(path, _transition(sequence=1))

    assert not path.exists()


def test_first_event_sequence_must_be_one(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"

    with pytest.raises(JournalIntegrityError):
        append_event(path, _created(sequence=2))

    assert not path.exists()


def test_journal_requires_contiguous_sequence_numbers(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    append_event(path, _created())

    with pytest.raises(JournalIntegrityError):
        append_event(path, _halted(sequence=3))

    assert read_events(path) == (_created(),)


def test_journal_rejects_event_from_different_run(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    append_event(path, _created())

    with pytest.raises(JournalIntegrityError):
        append_event(path, _transition(run_id=_run_id("20260923-002")))

    assert read_events(path) == (_created(),)


def test_journal_rejects_second_run_created_event(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    append_event(path, _created())

    with pytest.raises(JournalIntegrityError):
        append_event(path, _created(sequence=2))

    assert read_events(path) == (_created(),)


def test_reader_ignores_incomplete_final_json_line(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    append_event(path, _created())
    append_event(path, _transition())

    with path.open("ab") as journal:
        journal.write(b'{"schema_version":1,"event_type":"run_halted"')

    assert read_events(path) == (_created(), _transition())


def test_reader_rejects_malformed_nonfinal_line(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    path.write_text(
        _created().model_dump_json()
        + "\n"
        + "{broken json}\n"
        + _transition(sequence=3).model_dump_json()
        + "\n"
    )

    with pytest.raises(JournalIntegrityError) as exc_info:
        read_events(path)

    assert exc_info.value.line_number == 2


def test_reader_rejects_schema_invalid_complete_final_line(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    path.write_text(
        _created().model_dump_json() + "\n" + '{"schema_version":2,"event_type":"run_halted"}\n'
    )

    with pytest.raises(JournalIntegrityError) as exc_info:
        read_events(path)

    assert exc_info.value.line_number == 2


def test_append_refuses_journal_with_incomplete_tail(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    append_event(path, _created())

    with path.open("ab") as journal:
        journal.write(b'{"schema_version":1')

    with pytest.raises(JournalIntegrityError):
        append_event(path, _transition())


def test_reader_rejects_sequence_gap_in_existing_journal(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    path.write_text(
        _created().model_dump_json() + "\n" + _transition(sequence=3).model_dump_json() + "\n"
    )

    with pytest.raises(JournalIntegrityError) as exc_info:
        read_events(path)

    assert exc_info.value.line_number == 2


def test_reader_rejects_run_id_change_in_existing_journal(tmp_path: Path) -> None:
    path = tmp_path / "events.jsonl"
    path.write_text(
        _created().model_dump_json()
        + "\n"
        + _transition(run_id=_run_id("20260923-002")).model_dump_json()
        + "\n"
    )

    with pytest.raises(JournalIntegrityError) as exc_info:
        read_events(path)

    assert exc_info.value.line_number == 2
