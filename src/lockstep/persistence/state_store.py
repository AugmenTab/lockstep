"""Atomic on-disk persistence and reconciliation of `RunStateSnapshot`.

The state file is a convenience checkpoint of the current workflow
state; the append-only event journal remains the sole authoritative
history of a run. Writes go through a same-directory temporary file,
``fsync``, ``os.replace``, and a parent-directory ``fsync`` so that a
successful write is durable and a failed write never damages the
previous snapshot. `load_verified_state` reconciles the checkpoint
against the journal: it accepts matching snapshots, transparently
reconstructs current state when the checkpoint is missing or lags the
journal, and refuses to hand back any snapshot whose stored prefix
disagrees with the authoritative journal history. Reconciliation is
strictly read-only; automatic snapshot repair, journal truncation, and
resume behavior are explicitly out of scope for Phase 1.5.
"""

from __future__ import annotations

import json
import os
import uuid
from pathlib import Path

from pydantic import ValidationError

from lockstep.persistence.journal import read_events
from lockstep.persistence.replay import ReplayError, replay_events
from lockstep.state import RunStateSnapshot


class StatePersistenceError(Exception):
    """Raised when the on-disk state file cannot be read or written."""

    def __init__(self, reason: str, *, path: Path) -> None:
        self.reason = reason
        self.path = path
        super().__init__(f"state persistence error at {path}: {reason}")


class StateConsistencyError(Exception):
    """Raised when a snapshot disagrees with the authoritative event journal."""

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"state consistency error: {reason}")


def read_state(path: Path) -> RunStateSnapshot | None:
    if not path.exists():
        return None

    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise StatePersistenceError(f"unreadable state file: {exc}", path=path) from exc

    try:
        return RunStateSnapshot.model_validate_json(raw)
    except ValidationError as exc:
        raise StatePersistenceError(f"invalid state snapshot: {exc}", path=path) from exc
    except (ValueError, json.JSONDecodeError) as exc:
        raise StatePersistenceError(f"malformed state JSON: {exc}", path=path) from exc


def write_state(path: Path, state: RunStateSnapshot) -> None:
    parent = path.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise StatePersistenceError(f"cannot create parent directory: {exc}", path=path) from exc

    temp_path = parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    payload = state.model_dump_json() + "\n"

    try:
        try:
            fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except OSError as exc:
            raise StatePersistenceError(
                f"cannot create temporary state file: {exc}", path=path
            ) from exc

        try:
            with os.fdopen(fd, "wb") as fh:
                fh.write(payload.encode("utf-8"))
                fh.flush()
                os.fsync(fh.fileno())
        except OSError as exc:
            raise StatePersistenceError(
                f"cannot write temporary state file: {exc}", path=path
            ) from exc

        try:
            os.replace(temp_path, path)
        except OSError as exc:
            raise StatePersistenceError(
                f"cannot atomically replace state file: {exc}", path=path
            ) from exc

        try:
            _fsync_directory(parent)
        except OSError as exc:
            raise StatePersistenceError(f"cannot fsync parent directory: {exc}", path=path) from exc
    except BaseException:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass
        raise


def load_verified_state(
    state_path: Path,
    journal_path: Path,
) -> RunStateSnapshot | None:
    events = read_events(journal_path)
    snapshot = read_state(state_path)

    if not events:
        if snapshot is None:
            return None
        raise StateConsistencyError(
            "snapshot exists but the authoritative journal is missing or empty"
        )

    try:
        latest = replay_events(events)
    except ReplayError as exc:
        raise StateConsistencyError(f"authoritative journal fails replay: {exc.reason}") from exc

    if snapshot is None:
        return latest

    if snapshot.last_sequence > latest.last_sequence:
        raise StateConsistencyError(
            f"snapshot last_sequence {snapshot.last_sequence} is ahead of "
            f"journal last sequence {latest.last_sequence}"
        )

    prefix = tuple(event for event in events if event.sequence <= snapshot.last_sequence)
    try:
        replayed_prefix = replay_events(prefix)
    except ReplayError as exc:
        raise StateConsistencyError(f"journal prefix fails replay: {exc.reason}") from exc

    if snapshot != replayed_prefix:
        raise StateConsistencyError(
            f"snapshot at sequence {snapshot.last_sequence} does not match "
            "replay of the journal prefix"
        )

    return latest


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
