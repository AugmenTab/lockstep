"""Append-only JSONL event journal for a Lockstep run.

The journal stores one JSON-encoded :class:`LockstepEvent` per line. Each
successful append is flushed and ``fsync``ed so a survived process crash
loses at most an in-progress final line. Readers tolerate exactly that
one shape of corruption -- a non-newline-terminated crash tail -- and
reject every other form of damage by raising
:class:`JournalIntegrityError` with the offending line number.

Cross-line invariants are enforced on both read and append: the first
event must be a :class:`RunCreatedEvent` at sequence ``1``, sequence
numbers must be contiguous, the ``run_id`` must not change, and no
second :class:`RunCreatedEvent` may appear.
"""

from __future__ import annotations

import os
from pathlib import Path

from pydantic import TypeAdapter, ValidationError

from lockstep.persistence.events import (
    LockstepEvent,
    RunCreatedEvent,
    RunHaltedEvent,
    StateTransitionedEvent,
)

_ConcreteEvent = RunCreatedEvent | StateTransitionedEvent | RunHaltedEvent
_EVENT_ADAPTER: TypeAdapter[_ConcreteEvent] = TypeAdapter(LockstepEvent)


class JournalIntegrityError(Exception):
    """Raised when the on-disk journal violates a structural invariant."""

    def __init__(self, reason: str, *, line_number: int | None = None) -> None:
        self.reason = reason
        self.line_number = line_number

        if line_number is None:
            message = f"event journal integrity error: {reason}"
        else:
            message = f"event journal integrity error at line {line_number}: {reason}"

        super().__init__(message)


def read_events(path: Path) -> tuple[_ConcreteEvent, ...]:
    if not path.exists():
        return ()

    raw = path.read_bytes()
    if not raw:
        return ()

    text = raw.decode("utf-8")
    lines = text.split("\n")
    # A trailing newline yields an empty tail element that we drop. A file
    # without a trailing newline has its last element treated as a crash
    # tail and ignored.
    candidate_lines = lines[:-1]

    events: list[_ConcreteEvent] = []
    for offset, raw_line in enumerate(candidate_lines):
        line_number = offset + 1
        if not raw_line:
            raise JournalIntegrityError(
                "empty line",
                line_number=line_number,
            )
        try:
            event = _EVENT_ADAPTER.validate_json(raw_line)
        except ValidationError as exc:
            raise JournalIntegrityError(
                f"malformed event: {exc}",
                line_number=line_number,
            ) from exc
        events.append(event)

    _validate_journal_invariants(events)
    return tuple(events)


def append_event(path: Path, event: _ConcreteEvent) -> None:
    if path.exists():
        existing_raw = path.read_bytes()
        if existing_raw and not existing_raw.endswith(b"\n"):
            raise JournalIntegrityError("cannot append: journal has an incomplete final line")

    existing = read_events(path)
    _validate_append(existing, event)

    line = event.model_dump_json() + "\n"
    with path.open("ab") as fh:
        fh.write(line.encode("utf-8"))
        fh.flush()
        os.fsync(fh.fileno())


def _validate_journal_invariants(events: list[_ConcreteEvent]) -> None:
    if not events:
        return

    first = events[0]
    if not isinstance(first, RunCreatedEvent):
        raise JournalIntegrityError(
            "first event must be a RunCreatedEvent",
            line_number=1,
        )
    if first.sequence != 1:
        raise JournalIntegrityError(
            f"first event sequence must be 1; got {first.sequence}",
            line_number=1,
        )

    run_id = first.run_id
    for offset, event in enumerate(events[1:], start=1):
        line_number = offset + 1
        expected_sequence = offset + 1
        if event.run_id != run_id:
            raise JournalIntegrityError(
                "run_id changed",
                line_number=line_number,
            )
        if event.sequence != expected_sequence:
            raise JournalIntegrityError(
                f"non-contiguous sequence: expected {expected_sequence}, got {event.sequence}",
                line_number=line_number,
            )
        if isinstance(event, RunCreatedEvent):
            raise JournalIntegrityError(
                "unexpected second RunCreatedEvent",
                line_number=line_number,
            )


def _validate_append(
    existing: tuple[_ConcreteEvent, ...],
    new_event: _ConcreteEvent,
) -> None:
    if not existing:
        if not isinstance(new_event, RunCreatedEvent):
            raise JournalIntegrityError(
                "first event appended to a journal must be a RunCreatedEvent"
            )
        if new_event.sequence != 1:
            raise JournalIntegrityError(f"first event sequence must be 1; got {new_event.sequence}")
        return

    first = existing[0]
    last = existing[-1]

    if new_event.run_id != first.run_id:
        raise JournalIntegrityError(
            f"run_id must not change; expected {first.run_id.root!r}, got {new_event.run_id.root!r}"
        )

    expected_sequence = last.sequence + 1
    if new_event.sequence != expected_sequence:
        raise JournalIntegrityError(
            f"non-contiguous sequence: expected {expected_sequence}, got {new_event.sequence}"
        )

    if isinstance(new_event, RunCreatedEvent):
        raise JournalIntegrityError("only the first event in a journal may be a RunCreatedEvent")
