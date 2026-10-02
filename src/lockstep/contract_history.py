"""Contract lifecycle: retire a completed active Contract into immutable history.

:mod:`lockstep.planning_store` allows exactly one active, immutable
Sub-phase Contract and deliberately offers no way to edit, replace, or
delete it. Sequential execution needs the active slot back once a
Sub-phase is canonically complete. This module provides the one
authority-preserving way to do that: the active Contract file is copied,
byte for byte, into ``<runtime_dir>/contracts/history/`` under a name
derived from its Phase, Sub-phase, and content digest, and only then is
the active file removed. History is never overwritten: an existing entry
must be byte-identical to what is being archived, and an archived
Contract is verified against its digest whenever it is loaded.

The two steps (archive, then clear the active file) are individually
atomic and idempotent, so a crash between them is repaired by calling
:func:`retire_active_subphase_contract` again; until then the active slot
stays occupied and the planning store keeps refusing to freeze another
Contract over it.

This module decides nothing about *when* retirement is allowed: it only
checks that the digest it is given names the Contract that is active. The
caller (the project orchestrator) is responsible for retiring only a
Contract whose Sub-phase the project cursor has recorded as complete.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import uuid
from pathlib import Path

from pydantic import ValidationError

from lockstep.domain import PhaseId, SubphaseContract, SubphaseId
from lockstep.planning_store import PlanningStoreError, load_active_subphase_contract
from lockstep.project_cursor import contract_digest as _digest_of

_CONTRACTS_DIR_NAME = "contracts"
_ACTIVE_NAME = "active.json"
_HISTORY_DIR_NAME = "history"
_DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def _contracts_dir(runtime_dir: Path) -> Path:
    return runtime_dir / _CONTRACTS_DIR_NAME


def _active_path(runtime_dir: Path) -> Path:
    return _contracts_dir(runtime_dir) / _ACTIVE_NAME


def _history_dir(runtime_dir: Path) -> Path:
    return _contracts_dir(runtime_dir) / _HISTORY_DIR_NAME


def _archive_path(
    runtime_dir: Path, phase_id: PhaseId, subphase_id: SubphaseId, digest: str
) -> Path:
    return _history_dir(runtime_dir) / f"{phase_id.root}-{subphase_id.root}-{digest}.json"


def _require_digest(value: str) -> None:
    if not _DIGEST_PATTERN.match(value):
        raise PlanningStoreError("contract digest is malformed")


def _require_external_runtime(project_root: Path, runtime_dir: Path) -> Path:
    resolved_project = Path(project_root).resolve()
    resolved_runtime = Path(runtime_dir).resolve()
    if resolved_runtime == resolved_project or resolved_runtime.is_relative_to(resolved_project):
        raise PlanningStoreError("runtime directory must be outside project root")
    return resolved_runtime


def _reject_symlinks(runtime_dir: Path) -> None:
    for path, name in (
        (_contracts_dir(runtime_dir), "contracts directory"),
        (_history_dir(runtime_dir), "contract history directory"),
    ):
        if path.is_symlink():
            raise PlanningStoreError(f"{name} must not be a symlink", path=path)


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _replace_atomically(source: Path, target: Path) -> None:
    os.replace(source, target)


def _atomic_write_bytes(path: Path, payload: bytes, *, artifact_name: str) -> None:
    parent = path.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise PlanningStoreError(
            f"cannot create directory for {artifact_name}", path=parent
        ) from exc

    temp_path = parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    try:
        try:
            fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except OSError as exc:
            raise PlanningStoreError(
                f"cannot create temporary file for {artifact_name}", path=temp_path
            ) from exc
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as exc:
            raise PlanningStoreError(
                f"cannot write temporary file for {artifact_name}", path=temp_path
            ) from exc
        try:
            _replace_atomically(temp_path, path)
        except OSError as exc:
            raise PlanningStoreError(f"cannot publish {artifact_name}", path=path) from exc
        try:
            _fsync_directory(parent)
        except OSError as exc:
            raise PlanningStoreError(
                f"cannot fsync directory for {artifact_name}", path=parent
            ) from exc
    except BaseException:
        with contextlib.suppress(OSError):
            temp_path.unlink()
        raise


def _read_bytes(path: Path, *, artifact_name: str) -> bytes:
    try:
        return path.read_bytes()
    except OSError as exc:
        raise PlanningStoreError(f"cannot read {artifact_name}", path=path) from exc


def _hydrate(payload: bytes, path: Path) -> SubphaseContract:
    try:
        return SubphaseContract.model_validate(json.loads(payload.decode("utf-8")))
    except (UnicodeDecodeError, json.JSONDecodeError, ValidationError) as exc:
        raise PlanningStoreError("archived contract is not a valid contract", path=path) from exc


def _verified_archive(path: Path, digest: str) -> SubphaseContract:
    contract = _hydrate(_read_bytes(path, artifact_name="archived contract"), path)
    if _digest_of(contract) != digest:
        raise PlanningStoreError("archived contract does not match its digest", path=path)
    return contract


def load_archived_subphase_contract(
    project_root: Path,
    runtime_dir: Path,
    *,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    contract_digest: str,
) -> SubphaseContract | None:
    """Load a historical Contract by Phase, Sub-phase, and digest, or ``None``.

    Read-only. The stored Contract must hydrate, carry exactly the requested
    identity, and hash to exactly the requested digest; anything else fails
    closed with :class:`~lockstep.planning_store.PlanningStoreError`. It is
    deliberately *not* re-validated against the current Phase outline, since
    history is evidence of what was frozen, not a live plan.
    """
    _require_digest(contract_digest)
    resolved_runtime = _require_external_runtime(project_root, runtime_dir)
    _reject_symlinks(resolved_runtime)

    path = _archive_path(resolved_runtime, phase_id, subphase_id, contract_digest)
    if not path.exists():
        return None
    contract = _verified_archive(path, contract_digest)
    if contract.phase_id != phase_id or contract.subphase_id != subphase_id:
        raise PlanningStoreError("archived contract names a different sub-phase", path=path)
    return contract


def _find_archive(runtime_dir: Path, digest: str) -> Path | None:
    history = _history_dir(runtime_dir)
    if not history.is_dir():
        return None
    matches = sorted(history.glob(f"*-{digest}.json"))
    if len(matches) > 1:
        raise PlanningStoreError("contract history is ambiguous for this digest", path=history)
    return matches[0] if matches else None


def retire_active_subphase_contract(
    project_root: Path, runtime_dir: Path, *, contract_digest: str
) -> Path:
    """Move the active Contract named by *contract_digest* into immutable history.

    Archives the active Contract's exact bytes (refusing to overwrite a
    differing history entry), then clears the active slot, and returns the
    history path. Idempotent: when the active slot is already clear and
    history holds a verified entry for *contract_digest*, that entry's path
    is returned unchanged. A digest that does not name the active Contract
    (and has no archived entry) is rejected and nothing moves.
    """
    _require_digest(contract_digest)
    resolved_runtime = _require_external_runtime(project_root, runtime_dir)
    _reject_symlinks(resolved_runtime)

    active = load_active_subphase_contract(project_root, resolved_runtime)
    if active is None:
        existing = _find_archive(resolved_runtime, contract_digest)
        if existing is None:
            raise PlanningStoreError("no active contract to retire")
        _verified_archive(existing, contract_digest)
        return existing

    if _digest_of(active) != contract_digest:
        raise PlanningStoreError("active contract does not match the requested digest")

    active_path = _active_path(resolved_runtime)
    payload = _read_bytes(active_path, artifact_name="active contract")
    target = _archive_path(resolved_runtime, active.phase_id, active.subphase_id, contract_digest)

    if target.exists():
        if _read_bytes(target, artifact_name="archived contract") != payload:
            raise PlanningStoreError("history already holds a different contract", path=target)
    else:
        _atomic_write_bytes(target, payload, artifact_name="archived contract")

    try:
        active_path.unlink()
        _fsync_directory(active_path.parent)
    except OSError as exc:
        raise PlanningStoreError("cannot clear the active contract", path=active_path) from exc
    return target


__all__ = [
    "load_archived_subphase_contract",
    "retire_active_subphase_contract",
]
