"""Host-owned identity and durable evidence of project-level Planner invocations (12.10-R1).

Transaction roles are identified by :class:`~lockstep.domain.InvocationIdentity` and journaled
in their own transaction. Project-level planning runs *between* transactions -- Phase-outline
planning, next-Contract planning, JIT replanning and gate-remediation planning -- where no
run and no attempt exist, so it has a separate, smaller identity family::

    PlanningInvocationIdentity(project_id, phase_id, target_subphase_id | None,
                               role = planner, stage: PlanningStage, invocation_id)

The stage fixes the shape: Contract planning and gate remediation name the Sub-phase they
plan (the cursor's current Sub-phase, or the host-allocated remediation id), Phase-outline
planning and JIT replanning name none. The host issues the identity before launch; the
provider never sees, creates, modifies or returns it.

Every such invocation leaves two append-only events in one project-level journal::

    <runtime_dir>/planning/invocations.jsonl

``STARTED`` is durable immediately before the provider process launches (after the command
and its environment were built, so a refused launch fabricates nothing); ``RETURNED`` once the
process result is known, carrying the reusable Phase-10 evidence -- outcome, return code,
:class:`~lockstep.domain.InvocationUsage` (unreported telemetry stays unavailable, never zero;
there is no monetary field) and :class:`~lockstep.domain.FailureCause`. A failed call, a
malformed answer and a candidate the workflow later refuses are all kept: the journal records
model/process invocations, while frozen Contracts, published outlines and replan/remediation
receipts keep recording accepted planning outcomes.

There is no claim/resume protocol. A process that dies after ``STARTED`` leaves that event
unmatched for good; a later legitimate invocation is a new one with a new ``invocation_id``.
Nothing here is transaction state, progress authority, or input to the per-transaction
Phase-10 metrics. Writers are assumed single-process.
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
    SubphaseId,
)
from lockstep.failure import cause_for_invocation_failure

_CURRENT_SCHEMA_VERSION: SchemaVersion = SchemaVersion.model_validate(1)
_PLANNING_DIR_NAME = "planning"
_JOURNAL_NAME = "invocations.jsonl"

_PositiveStrictInt = Annotated[int, Field(strict=True, ge=1)]


class PlanningInvocationError(Exception):
    """The planning invocation journal is unsafe, unreadable, or cannot be appended to.

    Carries a short, bounded, deterministic ``reason`` that never contains prompt text or
    provider output.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"planning invocation error: {reason}")


class PlanningStage(StrEnum):
    """The project-level Planner operation an invocation performs (attribution only)."""

    PHASE_PLANNING = "phase_planning"
    CONTRACT_PLANNING = "contract_planning"
    JIT_REPLAN = "jit_replan"
    GATE_REMEDIATION = "gate_remediation"


# Whether each stage names the Sub-phase it plans. A JIT replan revises a Phase's unfinished
# suffix and a Phase-outline plan creates the outline: neither has a target to name.
_STAGE_TARGETS_SUBPHASE: dict[PlanningStage, bool] = {
    PlanningStage.PHASE_PLANNING: False,
    PlanningStage.CONTRACT_PLANNING: True,
    PlanningStage.JIT_REPLAN: False,
    PlanningStage.GATE_REMEDIATION: True,
}


class _PlanningModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class PlanningInvocationIdentity(_PlanningModel):
    """Where one project-level Planner invocation belongs, and which invocation it is.

    Grants no authority. Only the host issues one, through :meth:`issue`.
    """

    project_id: ProjectId
    phase_id: PhaseId
    target_subphase_id: SubphaseId | None
    role: AgentRole
    stage: PlanningStage
    invocation_id: InvocationId

    @model_validator(mode="after")
    def _shape_follows_the_stage(self) -> Self:
        if self.role is not AgentRole.PLANNER:
            raise ValueError("project-level planning is always performed by the planner")
        targets = _STAGE_TARGETS_SUBPHASE[self.stage]
        if (self.target_subphase_id is not None) is not targets:
            raise ValueError(
                f"stage {self.stage.value} "
                + ("requires" if targets else "forbids")
                + " a target sub-phase"
            )
        return self

    @classmethod
    def issue(
        cls,
        *,
        project_id: ProjectId,
        phase_id: PhaseId,
        target_subphase_id: SubphaseId | None,
        stage: PlanningStage,
    ) -> PlanningInvocationIdentity:
        """Issue a fresh identity with a host-generated ``invocation_id``."""
        return cls(
            project_id=project_id,
            phase_id=phase_id,
            target_subphase_id=target_subphase_id,
            role=AgentRole.PLANNER,
            stage=stage,
            invocation_id=InvocationId.model_validate(f"inv-{uuid.uuid4().hex}"),
        )


class PlanningInvocationEventKind(StrEnum):
    STARTED = "started"
    RETURNED = "returned"


class PlanningInvocationEvent(_PlanningModel):
    """One durable fact about one project-level Planner invocation.

    Both kinds carry the identity and the host's routing (provider, configured model and
    effort). Only ``RETURNED`` carries a result: its outcome, the process return code when
    the process exited, the usage when the process ran, and the failure cause when known.
    """

    schema_version: SchemaVersion = _CURRENT_SCHEMA_VERSION
    sequence: _PositiveStrictInt
    occurred_at: datetime
    kind: PlanningInvocationEventKind
    identity: PlanningInvocationIdentity
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
        if self.kind is PlanningInvocationEventKind.STARTED:
            if (self.outcome, self.returncode, self.usage, self.cause) != (None,) * 4:
                raise ValueError("a started event carries no result")
        elif self.outcome is None:
            raise ValueError("a returned event carries its outcome")
        return self


# --- Layout and the journal -----------------------------------------------------------------


def planning_invocations_path(runtime_dir: Path) -> Path:
    """The project-level planning invocation journal beneath the project run root."""
    return Path(runtime_dir) / _PLANNING_DIR_NAME / _JOURNAL_NAME


def _reject_symlinks(path: Path) -> None:
    for guarded in (path.parent, path):
        if guarded.is_symlink():
            raise PlanningInvocationError("the planning journal must not be a symlink")


def read_planning_invocation_events(runtime_dir: Path) -> tuple[PlanningInvocationEvent, ...]:
    """Read the planning invocation journal in order; an absent journal is empty."""
    path = planning_invocations_path(runtime_dir)
    _reject_symlinks(path)
    if not path.exists():
        return ()
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise PlanningInvocationError("the planning journal is unreadable") from exc
    events: list[PlanningInvocationEvent] = []
    for line in text.splitlines():
        try:
            events.append(PlanningInvocationEvent.model_validate_json(line))
        except ValidationError as exc:
            raise PlanningInvocationError("the planning journal is malformed") from exc
    if [event.sequence for event in events] != list(range(1, len(events) + 1)):
        raise PlanningInvocationError("the planning journal sequence is not contiguous")
    return tuple(events)


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def append_planning_invocation_event(runtime_dir: Path, event: PlanningInvocationEvent) -> None:
    """Append *event* durably (``fsync``) as the journal's next line."""
    path = planning_invocations_path(runtime_dir)
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
        raise PlanningInvocationError("cannot record the planning invocation") from exc


# --- Recording one invocation -----------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class PlanningInvocationRecorder:
    """Records the STARTED / RETURNED events of one identified planning invocation.

    Handed to :func:`~lockstep.agents.invoke_agent`, which calls :meth:`started` right before
    the process launches and :meth:`returned` for an abnormal process failure; the planning
    transport classifies every normal return itself.
    """

    runtime_dir: Path
    identity: PlanningInvocationIdentity
    adapter: AgentAdapter

    def _append(self, kind: PlanningInvocationEventKind, **result: object) -> None:
        existing = read_planning_invocation_events(self.runtime_dir)
        model: str | None = None
        effort: str | None = None
        if isinstance(self.adapter, UsageReportingAdapter):
            model, effort = self.adapter.configured_model, self.adapter.configured_effort
        event = PlanningInvocationEvent.model_validate(
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
        append_planning_invocation_event(self.runtime_dir, event)

    def started(self) -> None:
        self._append(PlanningInvocationEventKind.STARTED)

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
        self._append(
            PlanningInvocationEventKind.RETURNED,
            outcome=outcome,
            returncode=returncode,
            usage=usage,
            cause=cause,
        )


__all__ = [
    "PlanningInvocationError",
    "PlanningInvocationEvent",
    "PlanningInvocationEventKind",
    "PlanningInvocationIdentity",
    "PlanningInvocationRecorder",
    "PlanningStage",
    "append_planning_invocation_event",
    "planning_invocations_path",
    "read_planning_invocation_events",
]
