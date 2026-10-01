"""Typed Lockstep event schemas.

Every event is a frozen Pydantic v2 model that rejects unknown fields and
serializes timestamps as UTC ISO 8601 with a ``Z`` suffix. The concrete
event variants form a discriminated union keyed on ``event_type`` so a
journal line's kind is unambiguous. ``StateTransitionedEvent`` delegates
legality of its ``source -> target`` edge to
:func:`lockstep.state.transition` so callers cannot fabricate illegal
workflow transitions inside the event history.
"""

from datetime import UTC, datetime
from typing import Annotated, Literal, Self

from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    Field,
    field_serializer,
    field_validator,
    model_validator,
)

from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    ExecutionEventKind,
    ExecutionOutcome,
    FailureCause,
    InvocationId,
    InvocationStage,
    InvocationUsage,
    PhaseId,
    ProjectId,
    ReviewVerdict,
    RunId,
    SchemaVersion,
    StopReason,
    SubphaseId,
)
from lockstep.state import InvalidTransitionError, WorkflowState, transition

_CURRENT_SCHEMA_VERSION: SchemaVersion = SchemaVersion.model_validate(1)


def _reject_naive(value: datetime) -> datetime:
    if value.tzinfo is None or value.tzinfo.utcoffset(value) is None:
        raise ValueError("occurred_at must be timezone-aware")
    return value


def _reject_blank(value: str) -> str:
    if not value.strip():
        raise ValueError("must not be empty or whitespace-only")
    return value


_TzAwareDateTime = Annotated[datetime, AfterValidator(_reject_naive)]
_NonBlankStr = Annotated[str, AfterValidator(_reject_blank)]
_PositiveStrictInt = Annotated[int, Field(strict=True, ge=1)]


class _EventBase(BaseModel):
    """Fields common to every Lockstep event."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    schema_version: SchemaVersion = _CURRENT_SCHEMA_VERSION
    run_id: RunId
    sequence: _PositiveStrictInt
    occurred_at: _TzAwareDateTime

    @field_validator("schema_version")
    @classmethod
    def _reject_unsupported_schema_version(cls, value: SchemaVersion) -> SchemaVersion:
        if value.root != _CURRENT_SCHEMA_VERSION.root:
            raise ValueError(
                f"unsupported schema_version {value.root}; "
                f"events currently understand only schema_version "
                f"{_CURRENT_SCHEMA_VERSION.root}"
            )
        return value

    @field_serializer("occurred_at", when_used="json")
    def _serialize_occurred_at(self, value: datetime) -> str:
        return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


class RunCreatedEvent(_EventBase):
    event_type: Literal["run_created"] = "run_created"
    project_id: ProjectId
    initial_state: WorkflowState = WorkflowState.READY

    @field_validator("initial_state")
    @classmethod
    def _require_ready(cls, value: WorkflowState) -> WorkflowState:
        if value is not WorkflowState.READY:
            raise ValueError("initial_state must always be 'ready'")
        return value


class StateTransitionedEvent(_EventBase):
    event_type: Literal["state_transitioned"] = "state_transitioned"
    source: WorkflowState
    target: WorkflowState

    @model_validator(mode="after")
    def _enforce_legal_edge(self) -> Self:
        try:
            transition(self.source, self.target)
        except InvalidTransitionError as exc:
            raise ValueError(str(exc)) from exc
        return self


class RunHaltedEvent(_EventBase):
    event_type: Literal["run_halted"] = "run_halted"
    reason: StopReason
    detail: _NonBlankStr | None = None


_INVOCATION_KINDS = frozenset(
    {ExecutionEventKind.INVOCATION_STARTED, ExecutionEventKind.INVOCATION_RETURNED}
)


_STOP_BOUNDARY_KINDS = frozenset(
    {
        ExecutionEventKind.TRANSACTION_HALTED,
        ExecutionEventKind.TRANSACTION_ABORTED,
        ExecutionEventKind.RETRY_EXHAUSTED,
    }
)


class ExecutionEvent(_EventBase):
    """Observational record that a significant transaction stage occurred.

    Never drives workflow state: replay advances only the sequence for it, and
    nothing in it confers retry, resume, commit, scope, Contract, or Planner
    authority. Invocation-bearing kinds carry the complete host-issued 10.1
    identity; other kinds carry only the coordinates the owning action knows.
    Every vocabulary-valued field reuses an existing canonical type.
    """

    event_type: Literal["execution"] = "execution"
    kind: ExecutionEventKind
    outcome: ExecutionOutcome | None = None
    phase_id: PhaseId | None = None
    subphase_id: SubphaseId | None = None
    attempt: AttemptNumber | None = None
    role: AgentRole | None = None
    stage: InvocationStage | None = None
    invocation_id: InvocationId | None = None
    returncode: int | None = None
    verdict: ReviewVerdict | None = None
    stop_reason: StopReason | None = None
    cause: FailureCause | None = None
    detail: _NonBlankStr | None = None
    usage: InvocationUsage | None = None

    @model_validator(mode="after")
    def _require_identity_for_invocation_kinds(self) -> Self:
        if self.cause is not None and self.outcome is ExecutionOutcome.SUCCESS:
            raise ValueError("cause is only valid on a stage that did not succeed")
        if self.stop_reason is not None and self.kind not in _STOP_BOUNDARY_KINDS:
            raise ValueError(f"stop_reason is not valid on {self.kind.value}")
        if self.usage is not None and self.kind is not ExecutionEventKind.INVOCATION_RETURNED:
            raise ValueError("usage is only valid on invocation_returned")
        if self.kind in _INVOCATION_KINDS:
            missing = [
                name
                for name in ("phase_id", "subphase_id", "attempt", "role", "stage", "invocation_id")
                if getattr(self, name) is None
            ]
            if missing:
                raise ValueError(f"{self.kind.value} requires host identity; missing {missing}")
        if self.kind is ExecutionEventKind.INVOCATION_RETURNED and self.outcome is None:
            raise ValueError("invocation_returned requires an outcome")
        return self


LockstepEvent = Annotated[
    RunCreatedEvent | StateTransitionedEvent | RunHaltedEvent | ExecutionEvent,
    Field(discriminator="event_type"),
]
