"""Durable persistence and semantic operations for the project execution cursor.

Persists the :class:`~lockstep.project_cursor.ProjectCursor` as exactly one
canonical JSON file, ``<runtime_dir>/project/cursor.json``, beside the
other runtime planning artifacts. Every write goes through a same-directory
temporary file, ``fsync``, ``os.replace``, and a parent-directory ``fsync``,
so a successful write is durable and a crash leaves the previous cursor
byte-for-byte intact. Managed paths that are symlinks are rejected, and the
runtime directory must lie outside the project root.

The cursor file is the only state this module owns; everything else it
consults is authoritative elsewhere and is never copied or modified:

* the frozen Master Plan (:mod:`lockstep.planning_store`) -- the cursor
  must bind to it by project and digest on every load;
* the active frozen Contract (:mod:`lockstep.planning_store`) -- the cursor
  holds a digest reference, and a load fails closed if the frozen Contract
  has drifted from it;
* the single-Sub-phase transaction journal (:mod:`lockstep.persistence`) --
  read-only evidence of canonical completion; this module never appends
  to it and emits no execution events, so Phase-10 metrics are untouched.

Each operation is a single atomic publication, so a crash leaves either the
previous or the next valid cursor. Completion has an inherent two-record
window (journal says ``SUBPHASE_COMPLETE``, cursor not yet updated); it is
safe because the cursor then still holds the active Contract, so planning is
not eligible (``COMPLETION_NOT_RECORDED``) and re-running
:func:`record_completed_subphase` is idempotent. The failure mode is lost
liveness, never a duplicate execution. Writers are assumed single-process;
no cross-process lock is taken.

This module invokes no Planner, Implementer, Reviewer, provider, Git, or
Phase gate; it only records and reconstructs progression.
"""

from __future__ import annotations

import json
import os
import uuid
from pathlib import Path

from pydantic import ValidationError

from lockstep.domain import RunId, SubphaseOutline
from lockstep.persistence.events import ExecutionEvent
from lockstep.persistence.journal import read_events
from lockstep.persistence.state_store import load_verified_state
from lockstep.planning_store import (
    load_active_subphase_contract,
    load_frozen_master_plan,
    load_phase_plan,
)
from lockstep.project_cursor import (
    ProjectCursor,
    ProjectCursorError,
    bind_active_contract,
    contract_digest,
    new_project_cursor,
    record_subphase_completion,
    require_legal_successor,
    revise_remaining_outline,
    validate_cursor_against_master_plan,
)

_PROJECT_SUBDIR_NAME = "project"
_CURSOR_JSON_NAME = "cursor.json"


class ProjectCursorStoreError(Exception):
    """The cursor could not be durably persisted, loaded, or operated on.

    Carries a short, bounded, deterministic ``reason`` that never contains
    file contents or raw JSON. The optional ``path`` identifies the artifact
    path involved. Owns filesystem failures, malformed or schema-invalid
    persisted JSON, unsafe storage locations, and missing prerequisites.
    Semantic refusals remain :class:`~lockstep.project_cursor.ProjectCursorError`.
    """

    def __init__(self, reason: str, *, path: Path | None = None) -> None:
        self.reason = reason
        self.path = path
        super().__init__(f"project cursor store error: {reason}")


# --- Location and atomic publication ---------------------------------------------


def _cursor_dir(runtime_dir: Path) -> Path:
    return runtime_dir / _PROJECT_SUBDIR_NAME


def _cursor_path(runtime_dir: Path) -> Path:
    return _cursor_dir(runtime_dir) / _CURSOR_JSON_NAME


def _checked_runtime_dir(project_root: Path, runtime_dir: Path) -> Path:
    resolved_project = Path(project_root).resolve()
    resolved_runtime = Path(runtime_dir).resolve()
    if resolved_runtime == resolved_project or resolved_runtime.is_relative_to(resolved_project):
        raise ProjectCursorStoreError("runtime directory must be outside project root")
    for path, name in (
        (_cursor_dir(resolved_runtime), "project directory"),
        (_cursor_path(resolved_runtime), _CURSOR_JSON_NAME),
    ):
        if path.is_symlink():
            raise ProjectCursorStoreError(f"{name} must not be a symlink", path=path)
    return resolved_runtime


def _canonical_json_bytes(cursor: ProjectCursor) -> bytes:
    text = json.dumps(cursor.model_dump(mode="json"), ensure_ascii=False, separators=(",", ":"))
    return (text + "\n").encode("utf-8")


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _replace_atomically(source: Path, target: Path) -> None:
    os.replace(source, target)


def _atomic_write_bytes(path: Path, payload: bytes) -> None:
    parent = path.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise ProjectCursorStoreError("cannot create cursor directory", path=parent) from exc

    temp_path = parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    try:
        try:
            fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except OSError as exc:
            raise ProjectCursorStoreError(
                "cannot create temporary cursor file", path=temp_path
            ) from exc

        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as exc:
            raise ProjectCursorStoreError(
                "cannot write temporary cursor file", path=temp_path
            ) from exc

        try:
            _replace_atomically(temp_path, path)
        except OSError as exc:
            raise ProjectCursorStoreError("cannot publish cursor", path=path) from exc

        try:
            _fsync_directory(parent)
        except OSError as exc:
            raise ProjectCursorStoreError("cannot fsync cursor directory", path=parent) from exc
    except BaseException:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass
        raise


def _write_cursor(path: Path, previous: ProjectCursor | None, candidate: ProjectCursor) -> None:
    if previous is not None:
        require_legal_successor(previous, candidate)
    _atomic_write_bytes(path, _canonical_json_bytes(candidate))


def _read_cursor(path: Path) -> ProjectCursor:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise ProjectCursorStoreError("cannot read cursor", path=path) from exc
    try:
        text = raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise ProjectCursorStoreError("cursor is not valid UTF-8", path=path) from exc
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ProjectCursorStoreError("cursor is malformed JSON", path=path) from exc
    try:
        return ProjectCursor.model_validate(data)
    except ValidationError as exc:
        raise ProjectCursorStoreError(
            "cursor does not match the expected schema", path=path
        ) from exc


# --- Load -------------------------------------------------------------------------


def load_project_cursor(project_root: Path, runtime_dir: Path) -> ProjectCursor | None:
    """Reconstruct the durable cursor, or ``None`` if none was initialized.

    Read-only and never repairs. Fails closed unless the cursor binds to the
    frozen Master Plan (project, digest, Phase order) and, when it holds an
    active Contract reference, the frozen Contract still matches that
    reference exactly. Depends only on persisted artifacts, never on a
    provider conversation.
    """
    resolved_runtime = _checked_runtime_dir(project_root, runtime_dir)
    path = _cursor_path(resolved_runtime)
    if not path.exists():
        return None

    cursor = _read_cursor(path)

    plan = load_frozen_master_plan(project_root)
    if plan is None:
        raise ProjectCursorStoreError("cursor exists without a frozen master plan", path=path)
    validate_cursor_against_master_plan(cursor, plan)

    binding = cursor.active_contract
    if binding is not None:
        contract = load_active_subphase_contract(project_root, resolved_runtime)
        if contract is None:
            raise ProjectCursorStoreError("cursor references a contract that is not frozen")
        if (
            contract.phase_id != binding.phase_id
            or contract.subphase_id != binding.subphase_id
            or contract_digest(contract) != binding.contract_digest
        ):
            raise ProjectCursorError("frozen contract does not match the cursor's reference")

    return cursor


def _require_cursor(project_root: Path, runtime_dir: Path) -> ProjectCursor:
    cursor = load_project_cursor(project_root, runtime_dir)
    if cursor is None:
        raise ProjectCursorStoreError("project cursor is not initialized")
    return cursor


# --- Semantic operations ----------------------------------------------------------


def initialize_project_cursor(project_root: Path, runtime_dir: Path) -> ProjectCursor:
    """Create the cursor at the first Phase of the frozen Master Plan.

    Adopts the published provisional Phase outline when it is for the first
    Phase, otherwise the Master Plan's own outline. An identical existing
    cursor is returned unchanged; a cursor that has progressed is never
    reset.
    """
    resolved_runtime = _checked_runtime_dir(project_root, runtime_dir)
    plan = load_frozen_master_plan(project_root)
    if plan is None:
        raise ProjectCursorStoreError("cannot initialize a cursor without a frozen master plan")

    published = load_phase_plan(project_root, resolved_runtime)
    first = plan.phases[0]
    outline = published if published is not None and published.phase_id == first.phase_id else None
    candidate = new_project_cursor(plan, outline)

    existing = load_project_cursor(project_root, resolved_runtime)
    if existing is not None:
        if existing == candidate:
            return existing
        raise ProjectCursorStoreError("project cursor is already initialized")

    _write_cursor(_cursor_path(resolved_runtime), None, candidate)
    return candidate


def bind_frozen_contract(
    project_root: Path, runtime_dir: Path, *, transaction_run_id: RunId
) -> ProjectCursor:
    """Bind the authoritative frozen active Contract to the current Sub-phase.

    The Contract is read from the planning store and referenced by digest;
    it is never copied into the cursor.
    """
    resolved_runtime = _checked_runtime_dir(project_root, runtime_dir)
    cursor = _require_cursor(project_root, resolved_runtime)

    contract = load_active_subphase_contract(project_root, resolved_runtime)
    if contract is None:
        raise ProjectCursorStoreError("no frozen active contract to bind")

    bound = bind_active_contract(cursor, contract, transaction_run_id=transaction_run_id)
    if bound != cursor:
        _write_cursor(_cursor_path(resolved_runtime), cursor, bound)
    return bound


def _require_journal_identity(cursor: ProjectCursor, journal_path: Path, run_id: RunId) -> None:
    """Reject a journal whose execution events name a different Phase/Sub-phase."""
    binding = cursor.active_contract
    if binding is not None and binding.transaction_run_id == run_id:
        expected = (binding.phase_id, binding.subphase_id)
    else:
        matches = [entry for entry in cursor.completed_subphases if entry.run_id == run_id]
        if not matches:
            return  # the pure transition refuses a run the cursor does not know
        expected = (matches[0].phase_id, matches[0].subphase_id)

    for event in read_events(journal_path):
        if not isinstance(event, ExecutionEvent):
            continue
        if event.phase_id is not None and event.phase_id != expected[0]:
            raise ProjectCursorError("transaction journal names a different phase")
        if event.subphase_id is not None and event.subphase_id != expected[1]:
            raise ProjectCursorError("transaction journal names a different subphase")


def record_completed_subphase(
    project_root: Path,
    runtime_dir: Path,
    *,
    journal_path: Path,
    state_path: Path,
) -> ProjectCursor:
    """Record canonical Sub-phase completion proven by the transaction journal.

    The journal (reconciled with its checkpoint by
    :func:`~lockstep.persistence.state_store.load_verified_state`) is the
    sole evidence; it is read, never written. Re-recording is idempotent.
    """
    resolved_runtime = _checked_runtime_dir(project_root, runtime_dir)
    cursor = _require_cursor(project_root, resolved_runtime)

    snapshot = load_verified_state(state_path, journal_path)
    if snapshot is None:
        raise ProjectCursorStoreError("transaction journal is missing", path=journal_path)

    _require_journal_identity(cursor, journal_path, snapshot.run_id)
    updated = record_subphase_completion(cursor, snapshot)
    if updated != cursor:
        _write_cursor(_cursor_path(resolved_runtime), cursor, updated)
    return updated


def revise_cursor_outline(
    project_root: Path, runtime_dir: Path, remaining: tuple[SubphaseOutline, ...]
) -> ProjectCursor:
    """Durably replace the remaining provisional outline of the current Phase."""
    resolved_runtime = _checked_runtime_dir(project_root, runtime_dir)
    cursor = _require_cursor(project_root, resolved_runtime)

    revised = revise_remaining_outline(cursor, remaining)
    _write_cursor(_cursor_path(resolved_runtime), cursor, revised)
    return revised


__all__ = [
    "ProjectCursorStoreError",
    "bind_frozen_contract",
    "initialize_project_cursor",
    "load_project_cursor",
    "record_completed_subphase",
    "revise_cursor_outline",
]
