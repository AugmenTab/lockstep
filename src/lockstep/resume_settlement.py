"""Durable resume settlement protocol (Phase 9.12).

Gives the frozen 9.11 durable resume claim protocol
(:mod:`lockstep.resume`) a durable way to explain what happened to an
already-``STARTED`` claim before that claim is ever removed:

    STARTED claim
        -> known result
        -> ResumeSettlement
        -> claim removed (and, for NEXT_RETRY, a new checkpoint installed)

Core invariant:

    a STARTED claim is removed only after a durable settlement explains
    what happened to it

Four outcomes exist -- :attr:`ResumeSettlementOutcome.COMPLETED`,
:attr:`ResumeSettlementOutcome.HALTED`,
:attr:`ResumeSettlementOutcome.NEXT_RETRY`, and
:attr:`ResumeSettlementOutcome.EXECUTION_FAILED` -- and only
``NEXT_RETRY`` carries a next :class:`~lockstep.retry_checkpoint.RetryCheckpoint`,
whose attempt/phase/subphase/budget identity must chain exactly from the
settled claim's own checkpoint. This module never re-implements frozen
:class:`~lockstep.retry_checkpoint.RetryCheckpoint` validation -- it adds
only that chain relationship. It never launches an agent, never mutates
the Supervisor transaction, FSM, or event journal, and performs no Git
or provider I/O.

Settlements are content-addressed by the settled claim's
``checkpoint_digest`` and persisted at
``<runtime_dir>/retry/settlements/<digest>.json``, one immutable file per
claimed retry authority, so multiple bounded retry attempts leave a full
audit trail rather than overwriting one another.

This module cannot eliminate the unavoidable crash window between
launching an attempt and durably recording its result -- that remains
:attr:`~lockstep.resume.ResumeDisposition.STARTED_RECOVERY_REQUIRED` and
must never auto-replay. It solves deterministic settlement only after
the Supervisor already possesses a known result.
"""

import contextlib
import json
import os
from enum import StrEnum
from pathlib import Path
from typing import Literal, Self

from pydantic import BaseModel, ConfigDict, ValidationError, model_validator

from lockstep.resume import ResumeClaim, ResumeClaimStatus, resume_claim_path
from lockstep.retry_checkpoint import (
    RetryCheckpoint,
    freeze_retry_checkpoint,
    load_retry_checkpoint,
    retry_checkpoint_path,
)

_RETRY_SUBDIR_NAME = "retry"
_SETTLEMENTS_SUBDIR_NAME = "settlements"
_START_LOCK_NAME = "start.lock"


class ResumeSettlementOutcome(StrEnum):
    """What a durably known result means for an already-``STARTED`` claim."""

    COMPLETED = "completed"
    HALTED = "halted"
    NEXT_RETRY = "next_retry"
    EXECUTION_FAILED = "execution_failed"


class ResumeSettlementStoreError(Exception):
    """A resume settlement could not be safely persisted, loaded, or finalized.

    Carries a short, bounded, deterministic ``reason`` that never
    contains a blocker question, evidence, Planner rationale,
    instructions, Reviewer findings, full settlement/checkpoint JSON, or
    provider telemetry. The optional ``path`` attribute identifies the
    filesystem location involved, when one is relevant.

    Owns settlement-protocol failures: a malformed persisted settlement,
    a conflicting settlement at the same digest, a stored resume claim
    that does not match the supplied settlement, an unsafe symlinked
    settlement/settlements-directory/retry-directory location, an
    unexpected canonical retry checkpoint, a stale resume start lock, a
    settlement publication failure, and a claim-removal failure. It
    never wraps :class:`~lockstep.retry_checkpoint.RetryCheckpointStoreError`
    or a :class:`pydantic.ValidationError` raised by a lower layer that
    naturally owns that failure.
    """

    def __init__(self, reason: str, *, path: Path | None = None) -> None:
        self.reason = reason
        self.path = path
        super().__init__(f"resume settlement store error: {reason}")


class ResumeSettlement(BaseModel):
    """A durable, one-way settlement of an already-``STARTED`` resume claim.

    Strict and frozen. Carries exactly the settled ``claim``, the
    ``outcome`` that a known result produced, and, only for
    :attr:`ResumeSettlementOutcome.NEXT_RETRY`, the exact
    :class:`~lockstep.retry_checkpoint.RetryCheckpoint` that continues
    the retry authority -- never a timestamp, pid, hostname, provider,
    model, or raw process output. ``claim.status`` must be
    :attr:`~lockstep.resume.ResumeClaimStatus.STARTED`: a result cannot
    settle an attempt whose durable launch boundary was never crossed.
    For :attr:`ResumeSettlementOutcome.NEXT_RETRY`, ``next_checkpoint``
    is required, its ``attempt_state`` must equal exactly the executed
    attempt identity recorded as ``claim.checkpoint.next_attempt_state``,
    and its ``budget`` must equal ``claim.checkpoint.budget`` exactly --
    a resumed attempt can neither skip/replay attempt identity nor
    silently expand its retry budget. Every other outcome forbids a next
    checkpoint entirely. The new checkpoint's ``retry_request.target_role``
    is deliberately never compared against the old one: a Reviewer REWORK
    can validly be followed by an Implementer retry that itself later
    escalates back to the Reviewer, and the embedded checkpoint's own
    frozen 9.8/9.9 semantics already validate that relationship.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    schema_version: Literal[1]
    claim: ResumeClaim
    outcome: ResumeSettlementOutcome
    next_checkpoint: RetryCheckpoint | None = None

    @model_validator(mode="after")
    def _validate_settlement(self) -> Self:
        if self.claim.status != ResumeClaimStatus.STARTED:
            raise ValueError("settlement claim must be started")

        if self.outcome == ResumeSettlementOutcome.NEXT_RETRY:
            if self.next_checkpoint is None:
                raise ValueError("next_retry settlement requires a next checkpoint")

            executed_attempt = self.claim.checkpoint.next_attempt_state
            if executed_attempt is None:
                raise ValueError("started claim has no executed attempt identity")

            if self.next_checkpoint.attempt_state != executed_attempt:
                raise ValueError(
                    "next checkpoint attempt state does not match the executed attempt"
                )

            if self.next_checkpoint.budget != self.claim.checkpoint.budget:
                raise ValueError("next checkpoint budget does not match the claimed retry budget")
        elif self.next_checkpoint is not None:
            raise ValueError("terminal settlement outcome must not carry a next checkpoint")

        return self


# --- Runtime paths -----------------------------------------------------


def resume_settlement_path(runtime_dir: Path, claim: ResumeClaim) -> Path:
    """Return the one canonical durable location for *claim*'s settlement.

    Pure path composition; performs no filesystem access. Always
    ``<runtime_dir>/retry/settlements/<claim.checkpoint_digest>.json`` --
    content-addressed by the checkpoint digest that identifies the retry
    authority the settled attempt was launched under, so distinct retry
    attempts never collide or overwrite one another's settlement history.
    """

    return (
        runtime_dir
        / _RETRY_SUBDIR_NAME
        / _SETTLEMENTS_SUBDIR_NAME
        / f"{claim.checkpoint_digest}.json"
    )


def _start_lock_path(runtime_dir: Path) -> Path:
    return runtime_dir / _RETRY_SUBDIR_NAME / _START_LOCK_NAME


def _reject_symlink(path: Path, name: str) -> None:
    if path.is_symlink():
        raise ResumeSettlementStoreError(f"{name} must not be a symlink", path=path)


# --- Canonical serialization ---------------------------------------------


def _canonical_settlement_bytes(settlement: ResumeSettlement) -> bytes:
    text = json.dumps(
        settlement.model_dump(mode="json"),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return (text + "\n").encode("utf-8")


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _read_utf8(path: Path) -> str:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise ResumeSettlementStoreError("cannot read resume settlement", path=path) from exc
    try:
        return raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise ResumeSettlementStoreError("resume settlement is not valid UTF-8", path=path) from exc


def _hydrate_settlement(path: Path) -> ResumeSettlement:
    text = _read_utf8(path)
    try:
        raw = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ResumeSettlementStoreError("resume settlement is malformed JSON", path=path) from exc
    try:
        return ResumeSettlement.model_validate(raw)
    except ValidationError as exc:
        raise ResumeSettlementStoreError(
            "resume settlement does not match the expected schema", path=path
        ) from exc


def _load_stored_claim(path: Path) -> ResumeClaim | None:
    if not path.exists():
        return None
    text = _read_utf8(path)
    try:
        raw = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ResumeSettlementStoreError(
            "stored resume claim is malformed JSON", path=path
        ) from exc
    try:
        return ResumeClaim.model_validate(raw)
    except ValidationError as exc:
        raise ResumeSettlementStoreError(
            "stored resume claim does not match the expected schema", path=path
        ) from exc


# --- Exclusive first-publication seam ------------------------------------


def _write_new_settlement_exclusive(path: Path, payload: bytes) -> None:
    # Written fully (and fsynced) to a private temp file first, then published
    # via an atomic hard link, so a concurrent racing reader can never observe
    # a settlement file that exists but is still empty or partially written.
    temp_path = path.parent / f".{path.name}.{os.urandom(8).hex()}.newsettlement.tmp"
    fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.link(temp_path, path)
    finally:
        with contextlib.suppress(FileNotFoundError):
            temp_path.unlink()


def _create_settlement_exclusively(path: Path, payload: bytes) -> bool:
    try:
        _write_new_settlement_exclusive(path, payload)
    except FileExistsError:
        return False
    except OSError as exc:
        raise ResumeSettlementStoreError("cannot create resume settlement file", path=path) from exc
    return True


def _remove_started_claim(path: Path) -> None:
    with contextlib.suppress(FileNotFoundError):
        path.unlink()


# --- Freeze / load --------------------------------------------------------


def freeze_resume_settlement(runtime_dir: Path, settlement: ResumeSettlement) -> ResumeSettlement:
    """Freeze *settlement* as the one immutable record for its claim digest.

    An absent settlement is atomically persisted. A semantically
    identical existing settlement is an idempotent no-op. A different
    existing settlement fails closed with :class:`ResumeSettlementStoreError`
    -- there is no overwrite, amend, or force: settlement history is
    immutable audit evidence, never a last-writer-wins record.
    """

    retry_dir = runtime_dir / _RETRY_SUBDIR_NAME
    settlements_dir = retry_dir / _SETTLEMENTS_SUBDIR_NAME
    path = resume_settlement_path(runtime_dir, settlement.claim)

    _reject_symlink(retry_dir, "retry directory")
    _reject_symlink(settlements_dir, "resume settlements directory")
    _reject_symlink(path, "resume settlement")

    if path.exists():
        existing = _hydrate_settlement(path)
        if existing == settlement:
            return existing
        raise ResumeSettlementStoreError(
            "a different resume settlement is already frozen", path=path
        )

    try:
        settlements_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise ResumeSettlementStoreError(
            "cannot create resume settlements directory", path=settlements_dir
        ) from exc

    payload = _canonical_settlement_bytes(settlement)
    created = _create_settlement_exclusively(path, payload)
    if not created:
        existing = _hydrate_settlement(path)
        if existing == settlement:
            return existing
        raise ResumeSettlementStoreError(
            "a different resume settlement is already frozen", path=path
        )

    try:
        _fsync_directory(settlements_dir)
    except OSError as exc:
        raise ResumeSettlementStoreError(
            "cannot fsync resume settlements directory", path=settlements_dir
        ) from exc

    return settlement


def load_resume_settlement(runtime_dir: Path, claim: ResumeClaim) -> ResumeSettlement | None:
    """Load the durable settlement for *claim*, or ``None`` if none exists.

    Read-only: never repairs, reformats, or rewrites. A missing
    settlement is ``None``; a present-but-corrupt or invalid settlement
    raises :class:`ResumeSettlementStoreError` -- absence and corruption
    are materially different and are never conflated.
    """

    retry_dir = runtime_dir / _RETRY_SUBDIR_NAME
    settlements_dir = retry_dir / _SETTLEMENTS_SUBDIR_NAME
    path = resume_settlement_path(runtime_dir, claim)

    _reject_symlink(retry_dir, "retry directory")
    _reject_symlink(settlements_dir, "resume settlements directory")
    _reject_symlink(path, "resume settlement")

    if not path.exists():
        return None
    return _hydrate_settlement(path)


# --- Finalize --------------------------------------------------------------


def finalize_resume_settlement(runtime_dir: Path, settlement: ResumeSettlement) -> ResumeSettlement:
    """Durably settle *settlement*'s claim, removing it once settlement is safe.

    Freezes the settlement (idempotently) before ever touching the
    ``STARTED`` claim it settles. For :attr:`ResumeSettlementOutcome.NEXT_RETRY`,
    the embedded next checkpoint is frozen through the frozen 9.9 store
    -- a conflicting active checkpoint fails closed through that store's
    own freeze-once semantics, unwrapped, and the old claim is left
    untouched. For every other outcome, an unexpected active retry
    checkpoint is a control-plane conflict and fails closed without
    touching the claim. Only once settlement (and, for ``NEXT_RETRY``,
    the next checkpoint) is durable is the old ``STARTED`` claim removed.
    Tolerates every recoverable crash window this protocol defines:
    settlement-only, settlement-plus-checkpoint, and fully-finalized
    (claim already absent) are all safely re-driven to the same durable
    outcome without creating a second settlement or losing retry
    authority. A stale ``start.lock`` makes execution ownership
    ambiguous and fails closed rather than being used as outcome
    authority; this function never creates or removes that lock.
    """

    retry_dir = runtime_dir / _RETRY_SUBDIR_NAME
    settlements_dir = retry_dir / _SETTLEMENTS_SUBDIR_NAME
    claim_path = resume_claim_path(runtime_dir)
    checkpoint_path = retry_checkpoint_path(runtime_dir)
    lock_path = _start_lock_path(runtime_dir)
    settlement_path = resume_settlement_path(runtime_dir, settlement.claim)

    _reject_symlink(retry_dir, "retry directory")
    _reject_symlink(settlements_dir, "resume settlements directory")
    _reject_symlink(settlement_path, "resume settlement")
    _reject_symlink(claim_path, "resume claim")
    _reject_symlink(checkpoint_path, "retry checkpoint")
    _reject_symlink(lock_path, "resume start lock")

    if lock_path.exists():
        raise ResumeSettlementStoreError(
            "resume start lock present during settlement", path=lock_path
        )

    stored_claim = _load_stored_claim(claim_path)

    if stored_claim is not None:
        if stored_claim != settlement.claim:
            raise ResumeSettlementStoreError(
                "stored resume claim does not match settlement claim", path=claim_path
            )

        frozen = freeze_resume_settlement(runtime_dir, settlement)

        if settlement.outcome == ResumeSettlementOutcome.NEXT_RETRY:
            assert settlement.next_checkpoint is not None
            freeze_retry_checkpoint(runtime_dir, settlement.next_checkpoint)
        else:
            existing_checkpoint = load_retry_checkpoint(runtime_dir)
            if existing_checkpoint is not None:
                raise ResumeSettlementStoreError(
                    "an active retry checkpoint conflicts with a terminal settlement",
                    path=checkpoint_path,
                )

        try:
            _remove_started_claim(claim_path)
        except OSError as exc:
            raise ResumeSettlementStoreError(
                "cannot remove settled resume claim", path=claim_path
            ) from exc

        try:
            _fsync_directory(retry_dir)
        except OSError as exc:
            raise ResumeSettlementStoreError(
                "cannot fsync retry directory", path=retry_dir
            ) from exc

        return frozen

    existing_settlement = load_resume_settlement(runtime_dir, settlement.claim)
    if existing_settlement is None:
        raise ResumeSettlementStoreError(
            "no durable settlement evidence exists for the missing resume claim",
            path=claim_path,
        )
    if existing_settlement != settlement:
        raise ResumeSettlementStoreError(
            "stored resume settlement does not match the supplied settlement",
            path=settlement_path,
        )

    if existing_settlement.outcome == ResumeSettlementOutcome.NEXT_RETRY:
        assert existing_settlement.next_checkpoint is not None
        existing_checkpoint = load_retry_checkpoint(runtime_dir)
        if (
            existing_checkpoint is None
            or existing_checkpoint != existing_settlement.next_checkpoint
        ):
            raise ResumeSettlementStoreError(
                "required next retry checkpoint is missing or does not match",
                path=checkpoint_path,
            )
    else:
        existing_checkpoint = load_retry_checkpoint(runtime_dir)
        if existing_checkpoint is not None:
            raise ResumeSettlementStoreError(
                "an active retry checkpoint conflicts with a terminal settlement",
                path=checkpoint_path,
            )

    return existing_settlement


__all__ = [
    "ResumeSettlement",
    "ResumeSettlementOutcome",
    "ResumeSettlementStoreError",
    "finalize_resume_settlement",
    "freeze_resume_settlement",
    "load_resume_settlement",
    "resume_settlement_path",
]
