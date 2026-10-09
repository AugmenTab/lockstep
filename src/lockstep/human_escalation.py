"""Durable, actionable human escalation (dogfood-04).

A blocker that only a human may answer used to exist only in memory: the transaction halted
``HUMAN_REQUIRED`` and the exact question was discarded, so there was nothing to answer and no
controlled way back in. This module gives that interaction a durable, typed lifecycle::

    structured blocker routed HUMAN_REQUIRED
        -> HumanEscalationRecord      written before the transaction is durably HALTED
        -> autonomous stop            the run reports a typed reference to the request
        -> operator loads it          load_pending_human_request (no grep, no provider session)
        -> operator answers it        record_human_resolution (explicit host/operator action)
        -> HumanContinuation          CLAIMED -> STARTED -> SETTLED, at most one launch
        -> a fresh invocation of the blocked role, at the same attempt, receives the original
           request and the answer as evidence -- never as amended scope

Layout beneath a transaction's runtime directory, beside the attempt's other evidence::

    artifacts/attempt-<N>/human/request-<K>.json       the request (write-once)
    artifacts/attempt-<N>/human/resolution-<K>.json    the operator's answer (write-once)
    artifacts/attempt-<N>/human/continuation-<K>.json  the re-entry boundary
                                                       (CLAIMED -> STARTED -> SETTLED)

``K`` is the request's ordinal within its attempt: a continuation can itself need a human
again, which is a new request of the same attempt and never overwrites an earlier one.

Authority is preserved, never widened. A request is evidence of what the agent asked; a
resolution is an answer to exactly one request, bound to it by run, Phase, Sub-phase, attempt,
ordinal and request digest. Neither carries -- or can carry (``extra="forbid"``) -- a Master
Plan, a Contract, frozen tests, scope, a retry budget or routing policy. The record pins the
basis the blocked role stood on (the frozen test commit, the worktree HEAD and its dirty paths)
and the retry authority and budget the attempt already ran under, so a continuation re-enters
exactly that transaction and nothing else. Only :func:`record_human_resolution` writes a
resolution; nothing in the transaction, orchestration or autonomous layers calls it.

Every write is atomic and durable (temporary file, ``fsync``, publish, directory ``fsync``);
first writes are exclusive, so a duplicate or conflicting artifact is refused rather than
overwritten. Errors carry short bounded reasons, never artifact contents.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
import re
from collections.abc import Sequence
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Annotated, Literal, Self

from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    ValidationError,
    model_validator,
)

from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    ExecutionEventKind,
    PhaseId,
    RunId,
    SubphaseId,
)
from lockstep.escalation import (
    EscalationAuthority,
    EscalationCategory,
    EscalationProtocolError,
    EscalationRequest,
    route_escalation,
)
from lockstep.escalation_decision import (
    PlannerDecision,
    PlannerDecisionDisposition,
    escalation_request_digest,
    resolve_planner_decision,
)
from lockstep.evidence_store import attempt_artifact_dir
from lockstep.persistence import load_verified_state, read_events, record_execution_event
from lockstep.resume_settlement import ResumeSettlementOutcome
from lockstep.retry import AttemptState, RetryBudget
from lockstep.retry_checkpoint import RetryCheckpoint
from lockstep.state import WorkflowState

_ARTIFACTS_DIR_NAME = "artifacts"
_HUMAN_DIR_NAME = "human"
_JOURNAL_NAME = "events.jsonl"
_STATE_NAME = "state.json"
_ATTEMPT_DIR = re.compile(r"^attempt-([1-9][0-9]*)$")
_REQUEST_FILE = re.compile(r"^request-([1-9][0-9]*)\.json$")

_MAX_ANSWER_LENGTH = 4096
_MAX_EVIDENCE_ENTRIES = 32
_MAX_EVIDENCE_ENTRY_LENGTH = 2048
_MAX_OPERATOR_LENGTH = 128

_REENTRANT_ROLES = frozenset({AgentRole.IMPLEMENTER, AgentRole.REVIEWER})

_Sha256Hex = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
_GitObjectId = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{40,64}$")]
_Ordinal = Annotated[int, Field(strict=True, ge=1)]


class HumanEscalationError(Exception):
    """A human-escalation artifact could not be recorded, trusted or acted on.

    Carries a short, bounded, deterministic ``reason`` that never includes the request's
    question or evidence, the operator's answer, or any provider output.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"human escalation error: {reason}")


class HumanRequestStatus(StrEnum):
    """Where the latest human request of a transaction stands."""

    AWAITING_RESOLUTION = "awaiting_resolution"
    RESOLVED = "resolved"
    CONTINUATION_CLAIMED = "continuation_claimed"
    CONTINUATION_STARTED = "continuation_started"
    SETTLED = "settled"


class HumanContinuationStatus(StrEnum):
    """The durable re-entry boundary of one resolved human request.

    ``CLAIMED``: one actor owns the continuation; nothing has launched. ``STARTED``: the launch
    boundary is crossed -- whatever happened next cannot be told from here, so a ``STARTED``
    continuation is never launched again. ``SETTLED``: the continuation's known result is durable.
    """

    CLAIMED = "claimed"
    STARTED = "started"
    SETTLED = "settled"


# --- Bounded text ----------------------------------------------------------------------------


def _reject_blank(value: str) -> str:
    if not value.strip():
        raise ValueError("must not be empty or whitespace-only")
    return value


def _bounded(limit: int) -> AfterValidator:
    def check(value: str) -> str:
        if len(value) > limit:
            raise ValueError(f"must be at most {limit} characters")
        return value

    return AfterValidator(check)


def _single_line(value: str) -> str:
    if "\n" in value or "\r" in value:
        raise ValueError("must be a single line")
    return value


_Answer = Annotated[str, AfterValidator(_reject_blank), _bounded(_MAX_ANSWER_LENGTH)]
_EvidenceEntry = Annotated[str, AfterValidator(_reject_blank), _bounded(_MAX_EVIDENCE_ENTRY_LENGTH)]
_Operator = Annotated[
    str,
    AfterValidator(_reject_blank),
    AfterValidator(_single_line),
    _bounded(_MAX_OPERATOR_LENGTH),
]


# --- Models ------------------------------------------------------------------------------------


class _Model(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class HumanEscalationRecord(_Model):
    """The exact, validated request a human is asked to answer, and the basis it was asked on.

    ``request`` is the agent's own structured :class:`~lockstep.escalation.EscalationRequest`
    (source role, Phase/Sub-phase/attempt, category, question, bounded evidence, requested
    authority), byte-for-byte; ``request_digest`` binds it. It must genuinely need a human:
    either its category routes to the human, or it routes to the Planner and
    ``planner_decision`` is the Planner's validated ``HALT_FOR_HUMAN`` for exactly this request.
    A Supervisor-routed request, or any other Planner disposition, can never become one.

    The remaining fields are host-observed facts, never agent claims: the frozen test commit the
    journal recorded, the worktree HEAD and dirty paths the blocked role left, and -- for an
    attempt that was itself a durable retry -- the retry checkpoint it ran under. ``retry_budget``
    is the budget the transaction was already running with (``None`` only for an entrypoint that
    has none); a continuation reuses it and nobody can change it here.
    """

    schema_version: Literal[1]
    run_id: RunId
    ordinal: _Ordinal
    request: EscalationRequest
    request_digest: _Sha256Hex
    planner_decision: PlannerDecision | None = None
    frozen_test_commit: _GitObjectId
    worktree_head: _GitObjectId
    dirty_paths: tuple[str, ...] = ()
    retry_budget: RetryBudget | None = None
    retry_checkpoint: RetryCheckpoint | None = None

    @model_validator(mode="after")
    def _validate_record(self) -> Self:
        if self.request_digest != escalation_request_digest(self.request):
            raise ValueError("request digest does not match the escalation request")
        if self.request.source_role not in _REENTRANT_ROLES:
            raise ValueError("only an implementer or reviewer blocker can await a human answer")

        authority = route_escalation(self.request).authority
        if authority is EscalationAuthority.HUMAN:
            if self.planner_decision is not None:
                raise ValueError("a human-routed request carries no planner decision")
        elif authority is EscalationAuthority.PLANNER:
            if self.planner_decision is None:
                raise ValueError("a planner-routed request needs a planner halt-for-human decision")
            try:
                resolution = resolve_planner_decision(self.request, self.planner_decision)
            except EscalationProtocolError as exc:
                raise ValueError("the planner decision does not answer this request") from exc
            if resolution.disposition is not PlannerDecisionDisposition.HUMAN_REQUIRED:
                raise ValueError("the planner decision does not require a human")
        else:
            raise ValueError("a supervisor-routed request does not require a human")

        if list(self.dirty_paths) != sorted(set(self.dirty_paths)):
            raise ValueError("dirty paths must be sorted and unique")

        checkpoint = self.retry_checkpoint
        if checkpoint is not None:
            executed = AttemptState(
                phase_id=self.request.phase_id,
                subphase_id=self.request.subphase_id,
                current_attempt=self.request.attempt,
            )
            if checkpoint.next_attempt_state != executed:
                raise ValueError("the retry checkpoint did not authorize this attempt")
            if self.retry_budget != checkpoint.budget:
                raise ValueError("the retry budget differs from the attempt's retry checkpoint")
        return self


class HumanResolution(_Model):
    """One operator's answer to exactly one human request.

    Bound to its request by run, Phase, Sub-phase, attempt, ordinal and request digest. Carries
    a bounded answer, bounded operator evidence and the operator's name -- and nothing else: no
    plan, Contract, test, scope, retry-budget or routing field exists, and unknown fields are
    refused. It is an answer and acknowledgement, never a transaction edit.
    """

    schema_version: Literal[1]
    run_id: RunId
    phase_id: PhaseId
    subphase_id: SubphaseId
    attempt: AttemptNumber
    ordinal: _Ordinal
    request_digest: _Sha256Hex
    answer: _Answer
    evidence: Annotated[tuple[_EvidenceEntry, ...], Field(max_length=_MAX_EVIDENCE_ENTRIES)] = ()
    resolved_by: _Operator


class HumanContinuation(_Model):
    """The durable re-entry boundary of one resolved request.

    See :class:`HumanContinuationStatus`. ``outcome`` is the settled result, in the 9.12
    settlement vocabulary.
    """

    schema_version: Literal[1]
    run_id: RunId
    phase_id: PhaseId
    subphase_id: SubphaseId
    attempt: AttemptNumber
    ordinal: _Ordinal
    target_role: AgentRole
    request_digest: _Sha256Hex
    resolution_digest: _Sha256Hex
    status: HumanContinuationStatus
    outcome: ResumeSettlementOutcome | None = None

    @model_validator(mode="after")
    def _outcome_only_when_settled(self) -> Self:
        if (self.status is HumanContinuationStatus.SETTLED) != (self.outcome is not None):
            raise ValueError("an outcome is recorded exactly when the continuation is settled")
        return self


class HumanRequestReference(_Model):
    """A bounded, durable pointer to one human request, safe to surface in any result.

    Names the request (never its question or evidence) so a caller can find and answer it.
    """

    run_id: RunId
    phase_id: PhaseId
    subphase_id: SubphaseId
    attempt: AttemptNumber
    ordinal: _Ordinal
    source_role: AgentRole
    category: EscalationCategory
    request_digest: _Sha256Hex
    status: HumanRequestStatus
    artifact: str

    def describe(self) -> str:
        """A bounded one-line summary for a result ``detail`` (identity and status only)."""
        return (
            f"human request {self.status.value}: {self.run_id.root} phase {self.phase_id.root} "
            f"sub-phase {self.subphase_id.root} attempt {self.attempt.root} "
            f"request {self.ordinal} ({self.source_role.value}, {self.category.value}) "
            f"digest {self.request_digest} at {self.artifact}"
        )


@dataclass(frozen=True, slots=True)
class PendingHumanRequest:
    """The latest human request of a transaction, with everything recorded against it."""

    record: HumanEscalationRecord
    status: HumanRequestStatus
    resolution: HumanResolution | None
    continuation: HumanContinuation | None

    @property
    def reference(self) -> HumanRequestReference:
        request = self.record.request
        return HumanRequestReference(
            run_id=self.record.run_id,
            phase_id=request.phase_id,
            subphase_id=request.subphase_id,
            attempt=request.attempt,
            ordinal=self.record.ordinal,
            source_role=request.source_role,
            category=request.category,
            request_digest=self.record.request_digest,
            status=self.status,
            artifact=_relative_artifact(request.attempt, self.record.ordinal),
        )


# --- Paths -------------------------------------------------------------------------------------


def _require_ordinal(ordinal: int) -> None:
    if ordinal < 1:
        raise HumanEscalationError("a human request ordinal must be a positive integer")


def human_escalation_dir(runtime_dir: Path, attempt: AttemptNumber) -> Path:
    """The directory holding every human-escalation artifact of one attempt."""
    return attempt_artifact_dir(Path(runtime_dir), attempt) / _HUMAN_DIR_NAME


def human_request_path(runtime_dir: Path, attempt: AttemptNumber, ordinal: int) -> Path:
    _require_ordinal(ordinal)
    return human_escalation_dir(runtime_dir, attempt) / f"request-{ordinal}.json"


def human_resolution_path(runtime_dir: Path, attempt: AttemptNumber, ordinal: int) -> Path:
    _require_ordinal(ordinal)
    return human_escalation_dir(runtime_dir, attempt) / f"resolution-{ordinal}.json"


def human_continuation_path(runtime_dir: Path, attempt: AttemptNumber, ordinal: int) -> Path:
    _require_ordinal(ordinal)
    return human_escalation_dir(runtime_dir, attempt) / f"continuation-{ordinal}.json"


def _continuation_lock_path(runtime_dir: Path, attempt: AttemptNumber, ordinal: int) -> Path:
    return human_escalation_dir(runtime_dir, attempt) / f"continuation-{ordinal}.lock"


def _relative_artifact(attempt: AttemptNumber, ordinal: int) -> str:
    return f"{_ARTIFACTS_DIR_NAME}/attempt-{attempt.root}/{_HUMAN_DIR_NAME}/request-{ordinal}.json"


# --- Canonical, atomic persistence -------------------------------------------------------------


def _canonical_bytes(model: BaseModel) -> bytes:
    text = json.dumps(
        model.model_dump(mode="json"), ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    return (text + "\n").encode("utf-8")


def human_resolution_digest(resolution: HumanResolution) -> str:
    """The canonical SHA-256 of *resolution*, binding a continuation to the exact answer."""
    return hashlib.sha256(_canonical_bytes(resolution)).hexdigest()


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _reject_symlinks(path: Path) -> None:
    for guarded in (path.parent.parent.parent, path.parent.parent, path.parent, path):
        if guarded.is_symlink():
            raise HumanEscalationError("human escalation storage must not be a symlink")


def _write_temp(directory: Path, name: str, payload: bytes) -> Path:
    temp = directory / f".{name}.{os.urandom(8).hex()}.tmp"
    fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    with os.fdopen(fd, "wb") as handle:
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    return temp


def _create_exclusive(path: Path, payload: bytes, *, name: str) -> bool:
    """Publish *payload* at *path* only if nothing is there; ``False`` if something already is.

    Written fully to a private temporary file first and published by a hard link, so a reader
    never observes a partially written artifact and two writers can never both succeed.
    """
    _reject_symlinks(path)
    temp: Path | None = None
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        temp = _write_temp(path.parent, path.name, payload)
        try:
            os.link(temp, path)
        except FileExistsError:
            return False
        _fsync_directory(path.parent)
    except OSError as exc:
        raise HumanEscalationError(f"cannot record the {name}") from exc
    finally:
        if temp is not None:
            with contextlib.suppress(OSError):
                temp.unlink()
    return True


def _replace(path: Path, payload: bytes, *, name: str) -> None:
    _reject_symlinks(path)
    temp: Path | None = None
    try:
        temp = _write_temp(path.parent, path.name, payload)
        os.replace(temp, path)
        temp = None
        _fsync_directory(path.parent)
    except OSError as exc:
        raise HumanEscalationError(f"cannot record the {name}") from exc
    finally:
        if temp is not None:
            with contextlib.suppress(OSError):
                temp.unlink()


def _load[ModelT: BaseModel](path: Path, model_type: type[ModelT], *, name: str) -> ModelT | None:
    _reject_symlinks(path)
    if not path.exists():
        return None
    try:
        return model_type.model_validate(json.loads(path.read_bytes().decode("utf-8")))
    except (OSError, ValueError, ValidationError) as exc:
        raise HumanEscalationError(f"the recorded {name} is unreadable or malformed") from exc


# --- Transaction facts -------------------------------------------------------------------------


def _journal_run_id(runtime_dir: Path) -> RunId | None:
    journal = Path(runtime_dir) / _JOURNAL_NAME
    if not journal.exists():
        return None
    events = read_events(journal)
    return events[0].run_id if events else None


def _require_halted_transaction(runtime_dir: Path, run_id: RunId) -> None:
    journal_run = _journal_run_id(runtime_dir)
    if journal_run is None:
        raise HumanEscalationError("no transaction journal exists")
    if journal_run != run_id:
        raise HumanEscalationError("the transaction belongs to another run")
    state = load_verified_state(Path(runtime_dir) / _STATE_NAME, Path(runtime_dir) / _JOURNAL_NAME)
    if state is None or state.workflow_state is not WorkflowState.HALTED:
        raise HumanEscalationError("the transaction is not halted")


# --- Requests (host) ---------------------------------------------------------------------------


def _request_keys(runtime_dir: Path) -> list[tuple[int, int]]:
    artifacts = Path(runtime_dir) / _ARTIFACTS_DIR_NAME
    if artifacts.is_symlink():
        raise HumanEscalationError("human escalation storage must not be a symlink")
    if not artifacts.is_dir():
        return []
    keys: list[tuple[int, int]] = []
    for attempt_dir in artifacts.iterdir():
        attempt = _ATTEMPT_DIR.match(attempt_dir.name)
        human = attempt_dir / _HUMAN_DIR_NAME
        if attempt is None or not human.is_dir():
            continue
        for entry in human.iterdir():
            request = _REQUEST_FILE.match(entry.name)
            if request is not None:
                keys.append((int(attempt.group(1)), int(request.group(1))))
    return sorted(keys)


def next_human_request_ordinal(runtime_dir: Path, attempt: AttemptNumber) -> int:
    """The ordinal the next human request of *attempt* takes (1 for the first)."""
    used = [k for a, k in _request_keys(runtime_dir) if a == attempt.root]
    return max(used, default=0) + 1


def _load_record(runtime_dir: Path, attempt: int, ordinal: int) -> HumanEscalationRecord:
    number = AttemptNumber.model_validate(attempt)
    record = _load(
        human_request_path(runtime_dir, number, ordinal),
        HumanEscalationRecord,
        name="human request",
    )
    if record is None:
        raise HumanEscalationError("the human request vanished while it was read")
    if (record.request.attempt.root, record.ordinal) != (attempt, ordinal):
        raise HumanEscalationError("the recorded human request is filed under another identity")
    journal_run = _journal_run_id(runtime_dir)
    if journal_run is not None and record.run_id != journal_run:
        raise HumanEscalationError("the recorded human request belongs to another run")
    return record


def record_human_request(runtime_dir: Path, record: HumanEscalationRecord) -> Path:
    """Durably record the request a human must answer. Host-only; write-once.

    The ordinal must be the next free one of its attempt; recording the identical request again
    is a no-op (a restart re-driving the same halt), anything else at that path is refused.
    """
    path = human_request_path(runtime_dir, record.request.attempt, record.ordinal)
    payload = _canonical_bytes(record)
    if path.exists():
        if _load_record(runtime_dir, record.request.attempt.root, record.ordinal) == record:
            return path
        raise HumanEscalationError("a different human request is already recorded")
    if record.ordinal != next_human_request_ordinal(runtime_dir, record.request.attempt):
        raise HumanEscalationError("the human request ordinal is not the next one of its attempt")
    created = _create_exclusive(path, payload, name="human request")
    if not created and (
        _load_record(runtime_dir, record.request.attempt.root, record.ordinal) != record
    ):
        raise HumanEscalationError("a different human request is already recorded")
    return path


# --- Inspection (operator and host) ------------------------------------------------------------


def _bound_resolution(runtime_dir: Path, record: HumanEscalationRecord) -> HumanResolution | None:
    resolution = _load(
        human_resolution_path(runtime_dir, record.request.attempt, record.ordinal),
        HumanResolution,
        name="human resolution",
    )
    if resolution is not None and _resolution_identity(resolution) != _record_identity(record):
        raise HumanEscalationError("the recorded human resolution does not bind its request")
    return resolution


def _bound_continuation(
    runtime_dir: Path, record: HumanEscalationRecord, resolution: HumanResolution | None
) -> HumanContinuation | None:
    continuation = _load(
        human_continuation_path(runtime_dir, record.request.attempt, record.ordinal),
        HumanContinuation,
        name="human continuation",
    )
    if continuation is None:
        return None
    if resolution is None:
        raise HumanEscalationError("a human continuation exists without a resolution")
    if (
        _continuation_identity(continuation) != _record_identity(record)
        or continuation.target_role is not record.request.source_role
        or continuation.resolution_digest != human_resolution_digest(resolution)
    ):
        raise HumanEscalationError("the recorded human continuation does not bind its request")
    return continuation


def _record_identity(record: HumanEscalationRecord) -> tuple[object, ...]:
    request = record.request
    return (
        record.run_id,
        request.phase_id,
        request.subphase_id,
        request.attempt,
        record.ordinal,
        record.request_digest,
    )


def _resolution_identity(resolution: HumanResolution) -> tuple[object, ...]:
    return (
        resolution.run_id,
        resolution.phase_id,
        resolution.subphase_id,
        resolution.attempt,
        resolution.ordinal,
        resolution.request_digest,
    )


def _continuation_identity(continuation: HumanContinuation) -> tuple[object, ...]:
    return (
        continuation.run_id,
        continuation.phase_id,
        continuation.subphase_id,
        continuation.attempt,
        continuation.ordinal,
        continuation.request_digest,
    )


_STATUS_BY_CONTINUATION = {
    HumanContinuationStatus.CLAIMED: HumanRequestStatus.CONTINUATION_CLAIMED,
    HumanContinuationStatus.STARTED: HumanRequestStatus.CONTINUATION_STARTED,
    HumanContinuationStatus.SETTLED: HumanRequestStatus.SETTLED,
}


def inspect_human_escalation(runtime_dir: Path) -> PendingHumanRequest | None:
    """The transaction's latest human request and its status, from disk alone; read-only.

    ``None`` means no human request was ever recorded -- including a transaction that halted
    ``HUMAN_REQUIRED`` before requests were durable: nothing is reconstructed or invented. Every
    artifact is re-validated and re-bound on load; one that does not bind fails closed.
    """
    keys = _request_keys(runtime_dir)
    if not keys:
        return None
    record = _load_record(runtime_dir, *keys[-1])
    resolution = _bound_resolution(runtime_dir, record)
    continuation = _bound_continuation(runtime_dir, record, resolution)
    if resolution is None:
        status = HumanRequestStatus.AWAITING_RESOLUTION
    elif continuation is None:
        status = HumanRequestStatus.RESOLVED
    else:
        status = _STATUS_BY_CONTINUATION[continuation.status]
    return PendingHumanRequest(
        record=record, status=status, resolution=resolution, continuation=continuation
    )


def load_pending_human_request(runtime_dir: Path) -> PendingHumanRequest | None:
    """The human request awaiting an operator's answer, or ``None`` when nothing awaits one.

    The operator's entry point: everything needed to answer -- the exact request, its basis and
    a :attr:`PendingHumanRequest.reference` to quote back -- from typed artifacts, with no
    provider, session or journal parsing.
    """
    inspection = inspect_human_escalation(runtime_dir)
    if inspection is None or inspection.status is not HumanRequestStatus.AWAITING_RESOLUTION:
        return None
    return inspection


# --- Resolution (operator only) ----------------------------------------------------------------


def record_human_resolution(
    runtime_dir: Path,
    *,
    run_id: RunId,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
    ordinal: int,
    request_digest: str,
    answer: str,
    evidence: Sequence[str] = (),
    resolved_by: str,
) -> HumanResolution:
    """Record an operator's answer to the pending human request. The explicit operator action.

    Refuses unless the transaction is durably halted, its latest request awaits an answer, and
    every binding field -- run, Phase, Sub-phase, attempt, ordinal and request digest -- names
    exactly that request. A request can be answered once: a second resolution, identical or
    not, is refused. The journal records only the resolution's identity, never its text.
    Nothing in the automated layers calls this; it grants no scope, budget or plan authority.
    """
    runtime_dir = Path(runtime_dir)
    _require_halted_transaction(runtime_dir, run_id)
    inspection = inspect_human_escalation(runtime_dir)
    if inspection is None:
        raise HumanEscalationError("no human request is recorded for this transaction")
    record = inspection.record
    if (run_id, phase_id, subphase_id, attempt, ordinal, request_digest) != _record_identity(
        record
    ):
        raise HumanEscalationError("the resolution does not bind the pending human request")
    if inspection.resolution is not None:
        raise HumanEscalationError("a human resolution is already recorded for this request")

    resolution = HumanResolution(
        schema_version=1,
        run_id=run_id,
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=attempt,
        ordinal=ordinal,
        request_digest=request_digest,
        answer=answer,
        evidence=tuple(evidence),
        resolved_by=resolved_by,
    )
    path = human_resolution_path(runtime_dir, attempt, ordinal)
    if not _create_exclusive(path, _canonical_bytes(resolution), name="human resolution"):
        raise HumanEscalationError("a human resolution is already recorded for this request")
    record_execution_event(
        runtime_dir,
        kind=ExecutionEventKind.HUMAN_RESOLUTION_RECORDED,
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=attempt,
        role=record.request.source_role,
        detail=f"request-{ordinal}",
    )
    return resolution


# --- Continuation boundary (host) --------------------------------------------------------------


def load_human_continuation(
    runtime_dir: Path, attempt: AttemptNumber, ordinal: int
) -> HumanContinuation | None:
    """The continuation recorded for request *ordinal* of *attempt*, or ``None``."""
    return _load(
        human_continuation_path(runtime_dir, attempt, ordinal),
        HumanContinuation,
        name="human continuation",
    )


def claim_human_continuation(runtime_dir: Path, pending: PendingHumanRequest) -> HumanContinuation:
    """Durably and exclusively claim the continuation of a resolved request.

    Reuses an existing ``CLAIMED`` continuation (a restart before launch); refuses one that has
    started or settled -- that launch authority is spent.
    """
    if pending.status is HumanRequestStatus.CONTINUATION_CLAIMED:
        assert pending.continuation is not None
        return pending.continuation
    if pending.status is not HumanRequestStatus.RESOLVED:
        raise HumanEscalationError("only a resolved human request can be continued")
    assert pending.resolution is not None
    record = pending.record
    request = record.request
    claimed = HumanContinuation(
        schema_version=1,
        run_id=record.run_id,
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        attempt=request.attempt,
        ordinal=record.ordinal,
        target_role=request.source_role,
        request_digest=record.request_digest,
        resolution_digest=human_resolution_digest(pending.resolution),
        status=HumanContinuationStatus.CLAIMED,
    )
    path = human_continuation_path(runtime_dir, request.attempt, record.ordinal)
    if _create_exclusive(path, _canonical_bytes(claimed), name="human continuation"):
        return claimed
    existing = load_human_continuation(runtime_dir, request.attempt, record.ordinal)
    if existing != claimed:
        raise HumanEscalationError("the human continuation was already claimed and advanced")
    return claimed


def mark_human_continuation_started(
    runtime_dir: Path, continuation: HumanContinuation
) -> HumanContinuation:
    """Cross the launch boundary once. Never idempotent: a started continuation is spent."""
    if continuation.status is not HumanContinuationStatus.CLAIMED:
        raise HumanEscalationError("the human continuation is not claimed")
    attempt, ordinal = continuation.attempt, continuation.ordinal
    path = human_continuation_path(runtime_dir, attempt, ordinal)
    lock = _continuation_lock_path(runtime_dir, attempt, ordinal)
    _reject_symlinks(lock)
    try:
        fd = os.open(lock, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError as exc:
        raise HumanEscalationError("the human continuation start lock is held") from exc
    except OSError as exc:
        raise HumanEscalationError("cannot take the human continuation start lock") from exc
    os.close(fd)
    try:
        if load_human_continuation(runtime_dir, attempt, ordinal) != continuation:
            raise HumanEscalationError("the stored human continuation is not the claimed one")
        started = continuation.model_copy(update={"status": HumanContinuationStatus.STARTED})
        _replace(path, _canonical_bytes(started), name="human continuation")
        return started
    finally:
        with contextlib.suppress(OSError):
            lock.unlink()


def settle_human_continuation(
    runtime_dir: Path, continuation: HumanContinuation, outcome: ResumeSettlementOutcome
) -> HumanContinuation:
    """Record the known result of a started continuation; re-settling identically is a no-op."""
    if continuation.status is not HumanContinuationStatus.STARTED:
        raise HumanEscalationError("only a started human continuation can be settled")
    settled = HumanContinuation.model_validate(
        {
            **continuation.model_dump(),
            "status": HumanContinuationStatus.SETTLED,
            "outcome": outcome,
        }
    )
    stored = load_human_continuation(runtime_dir, continuation.attempt, continuation.ordinal)
    if stored == settled:
        return settled
    if stored != continuation:
        raise HumanEscalationError("the stored human continuation is not the started one")
    _replace(
        human_continuation_path(runtime_dir, continuation.attempt, continuation.ordinal),
        _canonical_bytes(settled),
        name="human continuation",
    )
    return settled


__all__ = [
    "HumanContinuation",
    "HumanContinuationStatus",
    "HumanEscalationError",
    "HumanEscalationRecord",
    "HumanRequestReference",
    "HumanRequestStatus",
    "HumanResolution",
    "PendingHumanRequest",
    "claim_human_continuation",
    "human_continuation_path",
    "human_escalation_dir",
    "human_request_path",
    "human_resolution_digest",
    "human_resolution_path",
    "inspect_human_escalation",
    "load_human_continuation",
    "load_pending_human_request",
    "mark_human_continuation_started",
    "next_human_request_ordinal",
    "record_human_request",
    "record_human_resolution",
    "settle_human_continuation",
]
