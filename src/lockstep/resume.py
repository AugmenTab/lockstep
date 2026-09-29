"""Durable resume claim protocol (Phase 9.11).

Gives the frozen 9.9 durable retry-checkpoint store
(:mod:`lockstep.retry_checkpoint`) a durable claim/start boundary, so
Lockstep can honestly promise this autonomous safety contract across a
process crash immediately surrounding agent launch:

    at-most-once launch for a given retry attempt
        with conservative recovery

Lockstep cannot honestly guarantee exactly-once external agent
execution across such a crash without an idempotent invocation
identity from the provider itself, which it does not have. The core
invariant is therefore:

    ambiguity after launch must reduce liveness, never duplicate an
    agent attempt

A :class:`ResumeClaim` durably transfers retry authority out of the
"available to claim" ``retry/checkpoint.json`` into an exclusively
claimed ``retry/claim.json``. :attr:`ResumeClaimStatus.CLAIMED` means
one actor has durably claimed the checkpoint, but the durable launch
boundary has not been crossed -- no agent attempt has been authorized
to launch. Only :func:`mark_resume_started`, transitioning to
:attr:`ResumeClaimStatus.STARTED`, crosses that boundary; the actual
launch may not have happened yet, may be running, or may have already
finished, and those cases cannot be distinguished from this module
alone, so a persisted ``STARTED`` claim must never be automatically
re-claimed or re-started.

This module creates and transitions claims; it does not implement
claim completion/settlement (:func:`~lockstep.resume.claim_retry_checkpoint`
and :func:`mark_resume_started` are the entire surface -- Sub-phase
9.12 designs settlement together with actual re-entry outcomes), does
not launch an agent, does not mutate the Supervisor transaction, FSM,
or event journal, and performs no Git or provider I/O.
"""

import contextlib
import hashlib
import json
import os
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Literal, Self

from pydantic import BaseModel, ConfigDict, ValidationError, model_validator

from lockstep.retry import RetryBudgetDisposition
from lockstep.retry_checkpoint import RetryCheckpoint, load_retry_checkpoint, retry_checkpoint_path

_RETRY_SUBDIR_NAME = "retry"
_CLAIM_JSON_NAME = "claim.json"
_START_LOCK_NAME = "start.lock"


class ResumeClaimStatus(StrEnum):
    """Where one retry attempt sits relative to the durable launch boundary."""

    CLAIMED = "claimed"
    STARTED = "started"


class ResumeDisposition(StrEnum):
    """The durable resume condition an inspection or claim attempt observed."""

    NO_CHECKPOINT = "no_checkpoint"
    RETRY_AVAILABLE = "retry_available"
    RETRY_EXHAUSTED = "retry_exhausted"
    CLAIMED = "claimed"
    STARTED_RECOVERY_REQUIRED = "started_recovery_required"


class ResumeStoreError(Exception):
    """A resume claim/start operation could not be safely performed.

    Carries a short, bounded, deterministic ``reason`` that never
    contains a blocker question, evidence, Planner rationale,
    instructions, Reviewer findings, full checkpoint JSON, or provider
    telemetry. The optional ``path`` attribute identifies the
    filesystem location involved, when one is relevant.

    Owns only resume-store/protocol failures: conflicting claim/
    checkpoint dual state, an invalid or corrupt ``claim.json``, an
    unsafe symlinked claim/start-lock/retry-directory location, a
    resume already started, an already-held start lock, a claim
    transfer removal failure, and a stale supplied claim. It never
    wraps :class:`~lockstep.retry_checkpoint.RetryCheckpointStoreError`,
    :class:`~lockstep.retry.RetryProtocolError`, or a
    :class:`pydantic.ValidationError` raised by a lower layer that
    naturally owns that failure.
    """

    def __init__(self, reason: str, *, path: Path | None = None) -> None:
        self.reason = reason
        self.path = path
        super().__init__(f"resume store error: {reason}")


def retry_checkpoint_digest(checkpoint: RetryCheckpoint) -> str:
    """Return the canonical lowercase SHA-256 digest of *checkpoint*.

    Pure: no salt, no UUID, no provider data. Hashes the same
    deterministic canonical JSON encoding used to persist a
    :class:`~lockstep.retry_checkpoint.RetryCheckpoint`, so equivalent
    checkpoints always produce the same 64-character lowercase
    hexadecimal digest.
    """

    text = json.dumps(
        checkpoint.model_dump(mode="json"),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class ResumeClaim(BaseModel):
    """One actor's durable, exclusive claim on a retry checkpoint.

    Strict and frozen. Carries exactly the checkpoint digest, the
    claimed checkpoint itself, and the claim's status -- never a
    timestamp, pid, hostname, provider, model, or random claim ID; the
    embedded checkpoint already carries every semantic field a resumed
    attempt needs. ``checkpoint_digest`` must equal
    :func:`retry_checkpoint_digest` of ``checkpoint``: a claim whose
    digest does not bind its checkpoint is rejected outright, never
    silently recomputed. Only a checkpoint carrying
    :attr:`~lockstep.retry.RetryBudgetDisposition.RETRY_AVAILABLE` with
    a non-``None`` ``next_attempt_state`` may become a claim; an
    exhausted checkpoint is durable terminal evidence and is never
    claimed.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    schema_version: Literal[1]
    checkpoint_digest: str
    checkpoint: RetryCheckpoint
    status: ResumeClaimStatus

    @model_validator(mode="after")
    def _validate_claim(self) -> Self:
        if self.checkpoint_digest != retry_checkpoint_digest(self.checkpoint):
            raise ValueError("checkpoint digest does not bind the claimed checkpoint")
        if self.checkpoint.budget_disposition != RetryBudgetDisposition.RETRY_AVAILABLE:
            raise ValueError("checkpoint does not carry available retry authority")
        if self.checkpoint.next_attempt_state is None:
            raise ValueError("checkpoint has no next attempt state")
        return self


@dataclass(frozen=True, slots=True)
class ResumeInspection:
    """The durable resume condition observed for one runtime directory.

    Exactly ``disposition``/``checkpoint``/``claim``.
    :attr:`ResumeDisposition.NO_CHECKPOINT` carries neither.
    :attr:`ResumeDisposition.RETRY_AVAILABLE` and
    :attr:`ResumeDisposition.RETRY_EXHAUSTED` carry only ``checkpoint``.
    :attr:`ResumeDisposition.CLAIMED` and
    :attr:`ResumeDisposition.STARTED_RECOVERY_REQUIRED` carry ``claim``
    with the matching status, and ``checkpoint`` is always
    ``claim.checkpoint`` so callers never need to reconstruct it.
    """

    disposition: ResumeDisposition
    checkpoint: RetryCheckpoint | None
    claim: ResumeClaim | None


def resume_claim_path(runtime_dir: Path) -> Path:
    """Return the one canonical durable resume-claim location.

    Pure path composition; performs no filesystem access. Always
    ``<runtime_dir>/retry/claim.json``, sharing the retry directory
    with :func:`~lockstep.retry_checkpoint.retry_checkpoint_path`.
    """

    return runtime_dir / _RETRY_SUBDIR_NAME / _CLAIM_JSON_NAME


def _start_lock_path(runtime_dir: Path) -> Path:
    return runtime_dir / _RETRY_SUBDIR_NAME / _START_LOCK_NAME


def _reject_symlink(path: Path, name: str) -> None:
    if path.is_symlink():
        raise ResumeStoreError(f"{name} must not be a symlink", path=path)


def _canonical_claim_bytes(claim: ResumeClaim) -> bytes:
    text = json.dumps(
        claim.model_dump(mode="json"),
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
        raise ResumeStoreError("cannot read resume claim", path=path) from exc
    try:
        return raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise ResumeStoreError("resume claim is not valid UTF-8", path=path) from exc


def _hydrate_claim(path: Path) -> ResumeClaim:
    text = _read_utf8(path)
    try:
        raw = json.loads(text)
    except json.JSONDecodeError as exc:
        raise ResumeStoreError("resume claim is malformed JSON", path=path) from exc
    try:
        return ResumeClaim.model_validate(raw)
    except ValidationError as exc:
        raise ResumeStoreError(
            "resume claim does not match the expected schema", path=path
        ) from exc


def _load_claim_if_present(path: Path) -> ResumeClaim | None:
    if not path.exists():
        return None
    return _hydrate_claim(path)


def _require_stored_claim(path: Path) -> ResumeClaim:
    if not path.exists():
        raise ResumeStoreError("no resume claim exists to start", path=path)
    return _hydrate_claim(path)


# --- Exclusive first-claim / atomic start seams -----------------------------


def _write_new_claim_exclusive(path: Path, payload: bytes) -> None:
    # Written fully (and fsynced) to a private temp file first, then published
    # via an atomic hard link, so a concurrent racing reader can never observe
    # a claim file that exists but is still empty or partially written.
    temp_path = path.parent / f".{path.name}.{os.urandom(8).hex()}.newclaim.tmp"
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


def _create_claim_exclusively(path: Path, payload: bytes) -> bool:
    try:
        _write_new_claim_exclusive(path, payload)
    except FileExistsError:
        return False
    except OSError as exc:
        raise ResumeStoreError("cannot create resume claim file", path=path) from exc
    return True


def _remove_transferred_checkpoint(path: Path) -> None:
    with contextlib.suppress(FileNotFoundError):
        path.unlink()


def _replace_atomically(source: Path, target: Path) -> None:
    os.replace(source, target)


def _replace_claim_file(retry_dir: Path, claim_path: Path, claim: ResumeClaim) -> None:
    payload = _canonical_claim_bytes(claim)
    temp_path = retry_dir / f".{claim_path.name}.{os.urandom(8).hex()}.tmp"

    try:
        try:
            fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except OSError as exc:
            raise ResumeStoreError(
                "cannot create temporary resume claim file", path=temp_path
            ) from exc

        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as exc:
            raise ResumeStoreError(
                "cannot write temporary resume claim file", path=temp_path
            ) from exc

        try:
            _replace_atomically(temp_path, claim_path)
        except OSError as exc:
            raise ResumeStoreError("cannot publish started resume claim", path=claim_path) from exc

        try:
            _fsync_directory(retry_dir)
        except OSError as exc:
            raise ResumeStoreError("cannot fsync retry directory", path=retry_dir) from exc
    except BaseException:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass
        raise


# --- Read-only inspection ----------------------------------------------


def inspect_resume(runtime_dir: Path) -> ResumeInspection:
    """Report the current durable resume condition, without mutation.

    Read-only: never creates, deletes, rewrites, or repairs anything.
    Observes the recoverable crash window of a ``CLAIMED`` claim whose
    matching checkpoint has not yet been removed and reports
    :attr:`ResumeDisposition.CLAIMED` without touching either file --
    only :func:`claim_retry_checkpoint` completes that interrupted
    transfer. A claim and a present checkpoint that disagree, or a
    ``STARTED`` claim alongside any checkpoint, fail closed with
    :class:`ResumeStoreError`.
    """

    retry_dir = runtime_dir / _RETRY_SUBDIR_NAME
    claim_path = resume_claim_path(runtime_dir)
    checkpoint_path = retry_checkpoint_path(runtime_dir)

    _reject_symlink(retry_dir, "retry directory")
    _reject_symlink(claim_path, "resume claim")
    _reject_symlink(checkpoint_path, "retry checkpoint")

    claim = _load_claim_if_present(claim_path)
    checkpoint = load_retry_checkpoint(runtime_dir)

    if claim is not None:
        if checkpoint is not None and checkpoint != claim.checkpoint:
            raise ResumeStoreError("resume claim and retry checkpoint disagree")

        if claim.status == ResumeClaimStatus.STARTED:
            if checkpoint is not None:
                raise ResumeStoreError("retry checkpoint must not coexist with a started claim")
            return ResumeInspection(
                disposition=ResumeDisposition.STARTED_RECOVERY_REQUIRED,
                checkpoint=claim.checkpoint,
                claim=claim,
            )

        return ResumeInspection(
            disposition=ResumeDisposition.CLAIMED, checkpoint=claim.checkpoint, claim=claim
        )

    if checkpoint is None:
        return ResumeInspection(
            disposition=ResumeDisposition.NO_CHECKPOINT, checkpoint=None, claim=None
        )

    if checkpoint.budget_disposition != RetryBudgetDisposition.RETRY_AVAILABLE:
        return ResumeInspection(
            disposition=ResumeDisposition.RETRY_EXHAUSTED, checkpoint=checkpoint, claim=None
        )

    return ResumeInspection(
        disposition=ResumeDisposition.RETRY_AVAILABLE, checkpoint=checkpoint, claim=None
    )


# --- Claim -------------------------------------------------------------


def _finish_claim_transfer(runtime_dir: Path, claim: ResumeClaim) -> ResumeInspection:
    retry_dir = runtime_dir / _RETRY_SUBDIR_NAME
    checkpoint_path = retry_checkpoint_path(runtime_dir)

    _reject_symlink(checkpoint_path, "retry checkpoint")

    if checkpoint_path.exists():
        existing_checkpoint = load_retry_checkpoint(runtime_dir)
        if existing_checkpoint != claim.checkpoint:
            raise ResumeStoreError("resume claim and retry checkpoint disagree")

        try:
            _remove_transferred_checkpoint(checkpoint_path)
        except OSError as exc:
            raise ResumeStoreError(
                "cannot remove transferred retry checkpoint", path=checkpoint_path
            ) from exc

        try:
            _fsync_directory(retry_dir)
        except OSError as exc:
            raise ResumeStoreError("cannot fsync retry directory", path=retry_dir) from exc

    return ResumeInspection(
        disposition=ResumeDisposition.CLAIMED, checkpoint=claim.checkpoint, claim=claim
    )


def _reconcile_existing_claim(runtime_dir: Path, claim: ResumeClaim) -> ResumeInspection:
    if claim.status == ResumeClaimStatus.STARTED:
        checkpoint_path = retry_checkpoint_path(runtime_dir)
        _reject_symlink(checkpoint_path, "retry checkpoint")
        if checkpoint_path.exists():
            raise ResumeStoreError("retry checkpoint must not coexist with a started claim")
        return ResumeInspection(
            disposition=ResumeDisposition.STARTED_RECOVERY_REQUIRED,
            checkpoint=claim.checkpoint,
            claim=claim,
        )

    return _finish_claim_transfer(runtime_dir, claim)


def claim_retry_checkpoint(runtime_dir: Path) -> ResumeInspection:
    """Durably and exclusively claim the active retry checkpoint, if any.

    Idempotent for an already-``CLAIMED`` claim (including recovery of
    a crash between claim persistence and checkpoint removal) and
    fails closed with :class:`ResumeStoreError` for an already-
    ``STARTED`` claim, a conflicting claim/checkpoint dual state, or an
    unsafe symlinked location -- it never downgrades ``STARTED``,
    creates a second claim, or restores ``checkpoint.json``. For a
    fresh claim: loads and validates the checkpoint, requires
    :attr:`~lockstep.retry.RetryBudgetDisposition.RETRY_AVAILABLE`,
    durably persists ``claim.json`` under exclusive first-claim
    semantics, and only then removes the matching ``checkpoint.json``
    -- the checkpoint is never removed before the claim is durable.
    """

    retry_dir = runtime_dir / _RETRY_SUBDIR_NAME
    claim_path = resume_claim_path(runtime_dir)

    _reject_symlink(retry_dir, "retry directory")
    _reject_symlink(claim_path, "resume claim")

    existing_claim = _load_claim_if_present(claim_path)
    if existing_claim is not None:
        return _reconcile_existing_claim(runtime_dir, existing_claim)

    checkpoint = load_retry_checkpoint(runtime_dir)
    if checkpoint is None:
        return ResumeInspection(
            disposition=ResumeDisposition.NO_CHECKPOINT, checkpoint=None, claim=None
        )

    if checkpoint.budget_disposition != RetryBudgetDisposition.RETRY_AVAILABLE:
        return ResumeInspection(
            disposition=ResumeDisposition.RETRY_EXHAUSTED, checkpoint=checkpoint, claim=None
        )

    new_claim = ResumeClaim(
        schema_version=1,
        checkpoint_digest=retry_checkpoint_digest(checkpoint),
        checkpoint=checkpoint,
        status=ResumeClaimStatus.CLAIMED,
    )

    try:
        retry_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise ResumeStoreError("cannot create retry directory", path=retry_dir) from exc

    payload = _canonical_claim_bytes(new_claim)
    created = _create_claim_exclusively(claim_path, payload)
    if created:
        try:
            _fsync_directory(retry_dir)
        except OSError as exc:
            raise ResumeStoreError("cannot fsync retry directory", path=retry_dir) from exc
        return _finish_claim_transfer(runtime_dir, new_claim)

    loaded_claim = _hydrate_claim(claim_path)
    return _reconcile_existing_claim(runtime_dir, loaded_claim)


# --- Start ---------------------------------------------------------------


def mark_resume_started(runtime_dir: Path, claim: ResumeClaim) -> ResumeClaim:
    """Cross the durable launch boundary for *claim*, once.

    Requires ``claim.status`` to be exactly ``CLAIMED``, the supplied
    claim to equal the stored claim exactly, and the matching
    ``checkpoint.json`` to already be fully transferred (absent) --
    callers must first run :func:`claim_retry_checkpoint` to complete
    that transfer; this function never hides it. Never idempotent: an
    already-``STARTED`` claim, a stale supplied claim, or a contended
    ``start.lock`` all fail closed with :class:`ResumeStoreError`
    rather than granting or re-granting launch authority, since an
    idempotent "mark started" could let a restarted process launch an
    already-started attempt again. No agent invocation occurs here.
    """

    if claim.status != ResumeClaimStatus.CLAIMED:
        raise ResumeStoreError("supplied claim is not in claimed status")

    retry_dir = runtime_dir / _RETRY_SUBDIR_NAME
    claim_path = resume_claim_path(runtime_dir)
    checkpoint_path = retry_checkpoint_path(runtime_dir)
    lock_path = _start_lock_path(runtime_dir)

    _reject_symlink(retry_dir, "retry directory")
    _reject_symlink(claim_path, "resume claim")
    _reject_symlink(checkpoint_path, "retry checkpoint")
    _reject_symlink(lock_path, "resume start lock")

    if checkpoint_path.exists():
        raise ResumeStoreError("retry checkpoint must be fully transferred before starting")

    stored_claim = _require_stored_claim(claim_path)
    if stored_claim != claim:
        raise ResumeStoreError("supplied claim does not match the stored claim")
    if stored_claim.status != ResumeClaimStatus.CLAIMED:
        raise ResumeStoreError("stored claim is not in claimed status")

    try:
        lock_fd = os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError as exc:
        raise ResumeStoreError("resume start lock already exists", path=lock_path) from exc
    except OSError as exc:
        raise ResumeStoreError("cannot create resume start lock", path=lock_path) from exc
    os.close(lock_fd)

    try:
        reread_claim = _require_stored_claim(claim_path)
        if reread_claim != claim:
            raise ResumeStoreError("supplied claim does not match the stored claim")
        if reread_claim.status != ResumeClaimStatus.CLAIMED:
            raise ResumeStoreError("stored claim is not in claimed status")

        started_claim = claim.model_copy(update={"status": ResumeClaimStatus.STARTED})
        _replace_claim_file(retry_dir, claim_path, started_claim)
        return started_claim
    finally:
        try:
            lock_path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass


__all__ = [
    "ResumeClaim",
    "ResumeClaimStatus",
    "ResumeDisposition",
    "ResumeInspection",
    "ResumeStoreError",
    "claim_retry_checkpoint",
    "inspect_resume",
    "mark_resume_started",
    "resume_claim_path",
    "retry_checkpoint_digest",
]
