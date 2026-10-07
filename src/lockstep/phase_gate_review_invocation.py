"""Host-owned identity and durable evidence of Phase-gate semantic-review invocations (13.1).

A Phase-gate attempt whose frozen Phase has integration criteria asks one fresh read-only
Planner for a structured :class:`~lockstep.phase_gate.PhaseGateReview`. That invocation is
neither a transaction role (no run, no transaction attempt) nor project-level planning (it plans
nothing and targets no Sub-phase), so it has its own identity, owned by the gate attempt that
caused it::

    PhaseGateReviewInvocationIdentity(project_id, phase_id, gate_attempt,
                                      role = planner, stage = semantic_review, invocation_id)

The host issues the identity before launch; the provider never sees, creates, modifies or
returns it. Every such invocation leaves two append-only events in the Phase's gate-owned
review journal, a stream beside the gate journal and apart from every attempt directory::

    <runtime_dir>/phase-gates/<phase-id>/review-invocations.jsonl

``STARTED`` is durable immediately before the provider process launches (after the command and
its environment were built, so a refused launch fabricates nothing); ``RETURNED`` once the
process result is known, carrying the reusable Phase-10 evidence -- outcome, return code,
:class:`~lockstep.domain.InvocationUsage` (unreported telemetry stays unavailable, never zero;
there is no monetary field) and :class:`~lockstep.domain.FailureCause`.

The journal is attribution only. It confers no authority, is never read by the gate, and
changes nothing about how the gate decides: the durable ``decision.json`` stays the acceptance
point and the attempt directory keeps exactly its accepted artifacts. A process that dies
after ``STARTED`` leaves that event unmatched for good; a rerun of the same undecided attempt
is a new invocation with a new ``invocation_id``. Gate attempts recorded before 13.1 have no
such journal; their review telemetry is simply not recorded. Writers are assumed
single-process.
"""

from __future__ import annotations

import os
import uuid
from dataclasses import dataclass
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path
from typing import Annotated, Self

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    ValidationError,
    field_serializer,
    field_validator,
    model_validator,
)

from lockstep.agents.invocation import AgentAdapter, UsageReportingAdapter
from lockstep.domain import (
    AgentRole,
    ExecutionOutcome,
    FailureCause,
    InvocationId,
    InvocationUsage,
    PhaseId,
    ProjectId,
    SchemaVersion,
)
from lockstep.failure import cause_for_invocation_failure

_CURRENT_SCHEMA_VERSION: SchemaVersion = SchemaVersion.model_validate(1)
# The Phase-gate layout (``lockstep.phase_gate``), which imports this module.
_GATES_DIR_NAME = "phase-gates"
_JOURNAL_NAME = "review-invocations.jsonl"

_PositiveStrictInt = Annotated[int, Field(strict=True, ge=1)]


class PhaseGateReviewInvocationError(Exception):
    """The gate review journal is unsafe, unreadable, or cannot be appended to.

    Carries a short, bounded, deterministic ``reason`` that never contains prompt text or
    provider output.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"phase gate review invocation error: {reason}")


class PhaseGateReviewStage(StrEnum):
    """The gate operation an invocation performs (attribution only)."""

    SEMANTIC_REVIEW = "semantic_review"


class _ReviewModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class PhaseGateReviewInvocationIdentity(_ReviewModel):
    """Which gate attempt one semantic-review invocation belongs to, and which invocation it is.

    Grants no authority. Only the host issues one, through :meth:`issue`.
    """

    project_id: ProjectId
    phase_id: PhaseId
    gate_attempt: _PositiveStrictInt
    role: AgentRole
    stage: PhaseGateReviewStage
    invocation_id: InvocationId

    @model_validator(mode="after")
    def _the_planner_reviews(self) -> Self:
        if self.role is not AgentRole.PLANNER:
            raise ValueError("a phase gate semantic review is always performed by the planner")
        return self

    @classmethod
    def issue(
        cls, *, project_id: ProjectId, phase_id: PhaseId, gate_attempt: int
    ) -> PhaseGateReviewInvocationIdentity:
        """Issue a fresh identity with a host-generated ``invocation_id``."""
        return cls(
            project_id=project_id,
            phase_id=phase_id,
            gate_attempt=gate_attempt,
            role=AgentRole.PLANNER,
            stage=PhaseGateReviewStage.SEMANTIC_REVIEW,
            invocation_id=InvocationId.model_validate(f"inv-{uuid.uuid4().hex}"),
        )


class PhaseGateReviewInvocationEventKind(StrEnum):
    STARTED = "started"
    RETURNED = "returned"


class PhaseGateReviewInvocationEvent(_ReviewModel):
    """One durable fact about one semantic-review invocation.

    Both kinds carry the identity and the host's routing (provider, configured model and
    effort). Only ``RETURNED`` carries a result: its outcome, the process return code when the
    process exited, the usage when the process ran, and the failure cause when known.
    """

    schema_version: SchemaVersion = _CURRENT_SCHEMA_VERSION
    sequence: _PositiveStrictInt
    occurred_at: datetime
    kind: PhaseGateReviewInvocationEventKind
    identity: PhaseGateReviewInvocationIdentity
    provider: str
    configured_model: str | None = None
    configured_effort: str | None = None
    outcome: ExecutionOutcome | None = None
    returncode: int | None = None
    usage: InvocationUsage | None = None
    cause: FailureCause | None = None

    @field_validator("schema_version")
    @classmethod
    def _reject_unsupported_schema_version(cls, value: SchemaVersion) -> SchemaVersion:
        if value.root != _CURRENT_SCHEMA_VERSION.root:
            raise ValueError(f"unsupported schema_version {value.root}")
        return value

    @field_validator("occurred_at")
    @classmethod
    def _require_timezone(cls, value: datetime) -> datetime:
        if value.tzinfo is None or value.utcoffset() is None:
            raise ValueError("occurred_at must be timezone-aware")
        return value

    @field_serializer("occurred_at", when_used="json")
    def _serialize_occurred_at(self, value: datetime) -> str:
        return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")

    @model_validator(mode="after")
    def _result_only_on_return(self) -> Self:
        if self.kind is PhaseGateReviewInvocationEventKind.STARTED:
            if (self.outcome, self.returncode, self.usage, self.cause) != (None,) * 4:
                raise ValueError("a started event carries no result")
        elif self.outcome is None:
            raise ValueError("a returned event carries its outcome")
        if self.cause is not None and self.outcome is ExecutionOutcome.SUCCESS:
            raise ValueError("a successful invocation carries no failure cause")
        return self


# --- Layout and the journal -----------------------------------------------------------------


def phase_gate_review_invocations_path(runtime_dir: Path, phase_id: PhaseId) -> Path:
    """The Phase's gate-owned semantic-review invocation journal."""
    return Path(runtime_dir) / _GATES_DIR_NAME / phase_id.root / _JOURNAL_NAME


def _reject_symlinks(path: Path) -> None:
    for guarded in (path.parent.parent, path.parent, path):
        if guarded.is_symlink():
            raise PhaseGateReviewInvocationError("the gate review journal must not be a symlink")


def read_phase_gate_review_invocation_events(
    runtime_dir: Path, phase_id: PhaseId
) -> tuple[PhaseGateReviewInvocationEvent, ...]:
    """Read the Phase's review journal in order; an absent journal is empty.

    Every event must belong to *phase_id* and the sequence must be contiguous from 1.
    """
    path = phase_gate_review_invocations_path(runtime_dir, phase_id)
    _reject_symlinks(path)
    if not path.exists():
        return ()
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise PhaseGateReviewInvocationError("the gate review journal is unreadable") from exc
    events: list[PhaseGateReviewInvocationEvent] = []
    for line in text.splitlines():
        try:
            events.append(PhaseGateReviewInvocationEvent.model_validate_json(line))
        except ValidationError as exc:
            raise PhaseGateReviewInvocationError("the gate review journal is malformed") from exc
    if [event.sequence for event in events] != list(range(1, len(events) + 1)):
        raise PhaseGateReviewInvocationError("the gate review journal sequence is not contiguous")
    if any(event.identity.phase_id != phase_id for event in events):
        raise PhaseGateReviewInvocationError("the gate review journal names another phase")
    return tuple(events)


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _append(runtime_dir: Path, event: PhaseGateReviewInvocationEvent) -> None:
    path = phase_gate_review_invocations_path(runtime_dir, event.identity.phase_id)
    line = (event.model_dump_json() + "\n").encode("utf-8")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        _reject_symlinks(path)
        created = not path.exists()
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o644)
        try:
            os.write(fd, line)
            os.fsync(fd)
        finally:
            os.close(fd)
        if created:
            _fsync_directory(path.parent)
    except OSError as exc:
        raise PhaseGateReviewInvocationError("cannot record the gate review invocation") from exc


# --- Recording one invocation -----------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class PhaseGateReviewInvocationRecorder:
    """Records the STARTED / RETURNED events of one identified semantic-review invocation.

    Handed to :func:`~lockstep.agents.invoke_agent`, which calls :meth:`started` right before
    the process launches and :meth:`returned` for an abnormal process failure; the review
    transport classifies every normal return itself.
    """

    runtime_dir: Path
    identity: PhaseGateReviewInvocationIdentity
    adapter: AgentAdapter

    def _record(self, kind: PhaseGateReviewInvocationEventKind, **result: object) -> None:
        existing = read_phase_gate_review_invocation_events(
            self.runtime_dir, self.identity.phase_id
        )
        model: str | None = None
        effort: str | None = None
        if isinstance(self.adapter, UsageReportingAdapter):
            model, effort = self.adapter.configured_model, self.adapter.configured_effort
        event = PhaseGateReviewInvocationEvent.model_validate(
            {
                "sequence": len(existing) + 1,
                "occurred_at": datetime.now(UTC),
                "kind": kind,
                "identity": self.identity,
                "provider": self.adapter.name,
                "configured_model": model,
                "configured_effort": effort,
                **result,
            }
        )
        _append(self.runtime_dir, event)

    def started(self) -> None:
        self._record(PhaseGateReviewInvocationEventKind.STARTED)

    def returned(
        self,
        *,
        outcome: ExecutionOutcome,
        returncode: int | None = None,
        usage: InvocationUsage | None = None,
        cause: FailureCause | None = None,
    ) -> None:
        if cause is None and outcome is ExecutionOutcome.FAILURE and usage is not None:
            cause = cause_for_invocation_failure(usage)
        self._record(
            PhaseGateReviewInvocationEventKind.RETURNED,
            outcome=outcome,
            returncode=returncode,
            usage=usage,
            cause=cause,
        )


__all__ = [
    "PhaseGateReviewInvocationError",
    "PhaseGateReviewInvocationEvent",
    "PhaseGateReviewInvocationEventKind",
    "PhaseGateReviewInvocationIdentity",
    "PhaseGateReviewInvocationRecorder",
    "PhaseGateReviewStage",
    "phase_gate_review_invocations_path",
    "read_phase_gate_review_invocation_events",
]
