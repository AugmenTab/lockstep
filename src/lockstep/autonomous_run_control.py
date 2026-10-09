"""Durable run control for bounded autonomous project runs.

An unattended run is bounded by an immutable, finite, host-owned policy. This module owns the
*control* facts of such a run and nothing else::

    identity            one ``ProjectRunId`` per unattended invocation (never a child ``RunId``)
    immutable policy    the finite controls, bound by a content digest
    start and deadline  the wall-clock budget, fixed once and never reset by a restart
    reservations        which Sub-phase units this run has taken execution authority for
    last stop           the disposition the run last stopped with
    audit journal       an append-only control-plane event stream

It never says where the project *is*. Progression -- the current Phase and Sub-phase, what is
complete, the gate state -- belongs to the ``ProjectCursor``, and the artifacts here may only
reference a Phase or Sub-phase as evidence of what a reservation was for. Nothing here is read
back to repair or steer the cursor.

Layout beneath the project run root (``runtime_dir``)::

    project-runs/<project-run-id>/policy.json    immutable record: identity, policy, digest,
                                                 start and deadline (written once, atomically)
                                 state.json      reservations and the last stop (atomic replace)
                                 events.jsonl    append-only audit journal

A run directory is published whole by one rename, so a crash leaves either no run or a complete
one. A Sub-phase reservation is the durable debit: the state file is replaced (and fsynced)
*before* execution may begin, and reserving the same Sub-phase again is a no-op, so a restart can
neither reset the budget nor take a second slot for the same unit. When a crash falls between the
debit and its audit event, the state is authoritative and the event is merely absent. Writers are
assumed single-process; no cross-process lock is taken.

Pure persistence: no Planner, provider, Git, or Phase gate is invoked here.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import math
import os
import re
import shutil
import uuid
from collections.abc import Callable
from datetime import datetime, timedelta
from enum import StrEnum
from pathlib import Path
from typing import Annotated, Self

from pydantic import (
    AfterValidator,
    BaseModel,
    BeforeValidator,
    ConfigDict,
    Field,
    RootModel,
    StrictBool,
    StringConstraints,
    ValidationError,
    field_validator,
    model_validator,
)

from lockstep.domain import PhaseId, ProjectId, RunId, SchemaVersion, SubphaseId
from lockstep.retry import RetryBudget

_CURRENT_SCHEMA_VERSION: SchemaVersion = SchemaVersion.model_validate(1)

_RUNS_DIR_NAME = "project-runs"
_POLICY_NAME = "policy.json"
_STATE_NAME = "state.json"
_EVENTS_NAME = "events.jsonl"
_ID_PREFIX = "prun-"
_ID_PATTERN = re.compile(rf"^{_ID_PREFIX}([0-9]{{4,}})$")
_DEADLINE_TOLERANCE_SECONDS = 1e-3

_IdentifierStr = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]*$")]
_Sha256Hex = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
_PositiveStrictInt = Annotated[int, Field(strict=True, ge=1)]
_NonNegativeStrictInt = Annotated[int, Field(strict=True, ge=0)]


def _reject_naive(value: datetime) -> datetime:
    if value.tzinfo is None or value.tzinfo.utcoffset(value) is None:
        raise ValueError("timestamps must be timezone-aware")
    return value


def _reject_blank(value: str) -> str:
    if not value.strip():
        raise ValueError("must not be empty or whitespace-only")
    return value


def _require_number(value: object) -> object:
    if isinstance(value, bool) or not isinstance(value, int | float):
        raise ValueError("must be a number of seconds")
    return value


_TzAwareDateTime = Annotated[datetime, AfterValidator(_reject_naive)]
_NonBlankStr = Annotated[str, AfterValidator(_reject_blank)]
_FiniteSeconds = Annotated[
    float, BeforeValidator(_require_number), Field(ge=0, allow_inf_nan=False)
]


# --- Errors ---------------------------------------------------------------------------


class AutonomousRunError(Exception):
    """An autonomous-run operation was refused.

    Carries a short, bounded, deterministic ``reason`` that never includes artifact contents,
    prompt text, command output, or provider output.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"autonomous run error: {reason}")


class AutonomousRunPolicyError(AutonomousRunError):
    """The policy is unbounded, malformed, or names something the project does not have."""


class AutonomousRunPolicyMismatchError(AutonomousRunError):
    """A run was resumed under a policy other than the immutable one it started with."""


class AutonomousRunStoreError(AutonomousRunError):
    """The run-control artifacts could not be persisted, loaded, or trusted."""


# --- Vocabulary -----------------------------------------------------------------------


class AutonomousRunDisposition(StrEnum):
    """Why an unattended run stopped.

    Child outcomes keep their canonical names (``HUMAN_REQUIRED``, ``RECOVERY_REQUIRED``,
    ``USAGE_LIMIT``); run-specific names exist only where nothing canonical says the same thing:
    the requested Phase boundary, the Sub-phase budget, the wall-clock budget, and the gate
    remediation bound.
    """

    PROJECT_COMPLETE = "project_complete"
    PHASE_BOUNDARY_REACHED = "phase_boundary_reached"
    MAX_SUBPHASES_REACHED = "max_subphases_reached"
    WALL_CLOCK_BUDGET_EXHAUSTED = "wall_clock_budget_exhausted"
    GATE_REMEDIATION_EXHAUSTED = "gate_remediation_exhausted"
    HUMAN_REQUIRED = "human_required"
    USAGE_LIMIT = "usage_limit"
    RECOVERY_REQUIRED = "recovery_required"
    TERMINAL_HALT = "terminal_halt"


class ReservationOutcome(StrEnum):
    """What asking for one Sub-phase budget slot did."""

    RESERVED = "reserved"
    ALREADY_RESERVED = "already_reserved"
    EXHAUSTED = "exhausted"


class ProjectRunEventKind(StrEnum):
    """Control-plane audit events. Deliberately disjoint from every transaction event kind."""

    RUN_STARTED = "run_started"
    SUBPHASE_RESERVED = "subphase_reserved"
    RUN_STOPPED = "run_stopped"


# --- Identity and policy --------------------------------------------------------------


class ProjectRunId(RootModel[_IdentifierStr]):
    """The identity of one unattended project run, independent of any child ``RunId``."""

    model_config = ConfigDict(frozen=True)


class AutonomousRunPolicy(BaseModel):
    """The immutable, finite, host-owned controls of one unattended run.

    Every control is a finite host input; no model chooses one and no value means
    "unlimited". Zero is valid and means none: ``max_subphases=0`` takes no Sub-phase
    execution authority, ``max_gate_remediations=0`` allows no remediation, and a zero
    wall-clock budget leaves no time to launch anything. ``retry_budget`` is the accepted
    Phase-9 budget, passed unchanged to ordinary child execution; ``until_phase`` is an
    inclusive stop boundary (complete that Phase, then stop before its successor).
    ``jit_replan`` selects JIT replanning of the unfinished outline between accepted
    Sub-phases (the default); ``False`` runs the published outline as frozen.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    max_subphases: _NonNegativeStrictInt
    max_unattended_wall_clock_seconds: _FiniteSeconds
    retry_budget: RetryBudget
    max_gate_remediations: _NonNegativeStrictInt
    until_phase: PhaseId | None = None
    jit_replan: StrictBool = True


def require_finite_policy(policy: AutonomousRunPolicy) -> None:
    """Refuse a policy that is not finite, even one that bypassed model validation.

    Canonical production execution calls this before any provider could launch.
    """
    for name in ("max_subphases", "max_gate_remediations"):
        value = getattr(policy, name, None)
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise AutonomousRunPolicyError(f"{name} must be a finite non-negative integer")
    wall = getattr(policy, "max_unattended_wall_clock_seconds", None)
    if (
        isinstance(wall, bool)
        or not isinstance(wall, int | float)
        or not math.isfinite(wall)
        or wall < 0
    ):
        raise AutonomousRunPolicyError(
            "max_unattended_wall_clock_seconds must be a finite non-negative number"
        )
    if not isinstance(getattr(policy, "retry_budget", None), RetryBudget):
        raise AutonomousRunPolicyError("retry_budget must be a finite retry budget")
    until = getattr(policy, "until_phase", None)
    if until is not None and not isinstance(until, PhaseId):
        raise AutonomousRunPolicyError("until_phase must be a phase id")
    if not isinstance(getattr(policy, "jit_replan", None), bool):
        raise AutonomousRunPolicyError("jit_replan must be a boolean")


def policy_digest(policy: AutonomousRunPolicy) -> str:
    """The canonical lowercase SHA-256 digest binding a run to exactly this policy.

    ``jit_replan=True`` is the meaning of a policy recorded before the field existed, so it is
    left out of the digest payload: such a record keeps its digest, and only ``False`` (a
    different authority) yields a different one.
    """
    payload = policy.model_dump(mode="json")
    if payload.get("jit_replan") is True:
        del payload["jit_replan"]
    text = json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


# --- Artifact models ------------------------------------------------------------------


class _ControlModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class _VersionedControlModel(_ControlModel):
    schema_version: SchemaVersion = _CURRENT_SCHEMA_VERSION

    @field_validator("schema_version")
    @classmethod
    def _reject_unsupported_schema_version(cls, value: SchemaVersion) -> SchemaVersion:
        if value.root != _CURRENT_SCHEMA_VERSION.root:
            raise ValueError(f"unsupported schema_version {value.root}")
        return value


class ProjectRunRecord(_VersionedControlModel):
    """The immutable record of one unattended run: identity, policy, and its clock.

    ``started_at`` and ``deadline_at`` are fixed at creation and are the only source of the
    wall-clock budget, so a restart -- however many and however late -- cannot extend it.
    """

    project_run_id: ProjectRunId
    project_id: ProjectId
    master_plan_digest: _Sha256Hex
    policy: AutonomousRunPolicy
    policy_digest: _Sha256Hex
    started_at: _TzAwareDateTime
    deadline_at: _TzAwareDateTime

    @model_validator(mode="after")
    def _enforce_consistency(self) -> Self:
        if self.policy_digest != policy_digest(self.policy):
            raise ValueError("the policy digest does not match the policy")
        span = (self.deadline_at - self.started_at).total_seconds()
        if abs(span - self.policy.max_unattended_wall_clock_seconds) > _DEADLINE_TOLERANCE_SECONDS:
            raise ValueError("the deadline does not match the wall-clock budget")
        return self


class SubphaseReservation(_ControlModel):
    """One Sub-phase unit this run took execution authority for.

    ``phase_id`` / ``subphase_id`` name what the slot was spent on; they are evidence, not a
    claim about where the project is. ``transaction_run_id`` attributes the child transaction.
    """

    phase_id: PhaseId
    subphase_id: SubphaseId
    transaction_run_id: RunId
    reserved_at: _TzAwareDateTime


class RunStop(_ControlModel):
    """The disposition the run last stopped with."""

    disposition: AutonomousRunDisposition
    detail: _NonBlankStr | None = None
    stopped_at: _TzAwareDateTime


class ProjectRunState(_VersionedControlModel):
    """The mutable control state of one run: budget debits and the last stop."""

    project_run_id: ProjectRunId
    reservations: tuple[SubphaseReservation, ...] = ()
    stop: RunStop | None = None

    @model_validator(mode="after")
    def _reservations_are_unique(self) -> Self:
        keys = [(r.phase_id.root, r.subphase_id.root) for r in self.reservations]
        if len(set(keys)) != len(keys):
            raise ValueError("a sub-phase is reserved more than once")
        return self


class ProjectRunEvent(_VersionedControlModel):
    """One control-plane audit event. Evidence only; never read as progress or budget."""

    sequence: _PositiveStrictInt
    occurred_at: _TzAwareDateTime
    kind: ProjectRunEventKind
    project_run_id: ProjectRunId
    phase_id: PhaseId | None = None
    subphase_id: SubphaseId | None = None
    disposition: AutonomousRunDisposition | None = None
    detail: _NonBlankStr | None = None


# --- Layout and atomic publication ------------------------------------------------------


def project_run_dir(runtime_dir: Path, project_run_id: ProjectRunId) -> Path:
    """The directory holding every control artifact of one unattended run."""
    return Path(runtime_dir) / _RUNS_DIR_NAME / project_run_id.root


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _store_error(reason: str) -> AutonomousRunStoreError:
    return AutonomousRunStoreError(reason)


def _reject_symlinks(path: Path) -> None:
    for guarded in (path.parent.parent, path.parent, path):
        if guarded.is_symlink():
            raise _store_error("run-control storage must not be a symlink")


def _canonical_bytes(model: BaseModel) -> bytes:
    text = json.dumps(model.model_dump(mode="json"), ensure_ascii=False, separators=(",", ":"))
    return (text + "\n").encode("utf-8")


def _atomic_write(path: Path, payload: bytes) -> None:
    """Replace *path* with *payload* atomically and durably; a crash leaves the old content."""
    _reject_symlinks(path)
    temp_path = path.parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    try:
        try:
            fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            with os.fdopen(fd, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp_path, path)
            _fsync_directory(path.parent)
        except OSError as exc:
            raise _store_error(f"cannot record {path.name}") from exc
    except BaseException:
        with contextlib.suppress(OSError):
            temp_path.unlink()
        raise


def _read_text(path: Path, *, name: str) -> str | None:
    _reject_symlinks(path)
    if not path.exists():
        return None
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise _store_error(f"the {name} is unreadable") from exc


def _event_line(event: ProjectRunEvent) -> bytes:
    return (event.model_dump_json() + "\n").encode("utf-8")


def _append_event_line(path: Path, line: bytes) -> None:
    _reject_symlinks(path)
    try:
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
        raise _store_error("cannot record the run event") from exc


# --- Creation, listing and loading ------------------------------------------------------


def list_project_runs(runtime_dir: Path) -> tuple[ProjectRunId, ...]:
    """Every project run recorded under *runtime_dir*, in allocation order."""
    root = Path(runtime_dir) / _RUNS_DIR_NAME
    if not root.is_dir():
        return ()
    names = sorted(
        child.name
        for child in root.iterdir()
        if child.is_dir() and not child.is_symlink() and _ID_PATTERN.match(child.name)
    )
    return tuple(ProjectRunId.model_validate(name) for name in names)


def _allocate_id(runtime_dir: Path) -> ProjectRunId:
    root = Path(runtime_dir) / _RUNS_DIR_NAME
    highest = 0
    if root.is_dir():
        for child in root.iterdir():
            match = _ID_PATTERN.match(child.name)
            if match is not None:
                highest = max(highest, int(match.group(1)))
    return ProjectRunId.model_validate(f"{_ID_PREFIX}{highest + 1:04d}")


def create_project_run(
    runtime_dir: Path,
    *,
    project_id: ProjectId,
    master_plan_digest: str,
    policy: AutonomousRunPolicy,
    clock: Callable[[], datetime],
    project_run_id: ProjectRunId | None = None,
) -> ProjectRunRecord:
    """Durably create one unattended run: fix its identity, policy, start and deadline.

    The whole run directory is published by a single rename, so a crash leaves no run or a
    complete one. An existing run is never recreated or overwritten.
    """
    require_finite_policy(policy)
    runtime = Path(runtime_dir)
    identity = project_run_id if project_run_id is not None else _allocate_id(runtime)
    target = project_run_dir(runtime, identity)
    if target.exists() or target.is_symlink():
        raise _store_error("the project run already exists")

    started_at = clock()
    record = ProjectRunRecord(
        project_run_id=identity,
        project_id=project_id,
        master_plan_digest=master_plan_digest,
        policy=policy,
        policy_digest=policy_digest(policy),
        started_at=started_at,
        deadline_at=started_at + timedelta(seconds=policy.max_unattended_wall_clock_seconds),
    )
    started = ProjectRunEvent(
        sequence=1,
        occurred_at=started_at,
        kind=ProjectRunEventKind.RUN_STARTED,
        project_run_id=identity,
    )

    staging = target.parent / f".{identity.root}.{uuid.uuid4().hex}.tmp"
    try:
        try:
            staging.mkdir(parents=True)
            (staging / _POLICY_NAME).write_bytes(_canonical_bytes(record))
            (staging / _STATE_NAME).write_bytes(
                _canonical_bytes(ProjectRunState(project_run_id=identity))
            )
            (staging / _EVENTS_NAME).write_bytes(_event_line(started))
            for name in (_POLICY_NAME, _STATE_NAME, _EVENTS_NAME):
                fd = os.open(staging / name, os.O_RDONLY)
                try:
                    os.fsync(fd)
                finally:
                    os.close(fd)
            _fsync_directory(staging)
            os.rename(staging, target)
            _fsync_directory(target.parent)
        except OSError as exc:
            raise _store_error("cannot create the project run") from exc
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return record


def load_project_run(runtime_dir: Path, project_run_id: ProjectRunId) -> ProjectRunRecord | None:
    """Load a run's immutable record, or ``None`` if no such run exists.

    The record is validated against its own digest and deadline, so a tampered policy file is
    refused rather than trusted.
    """
    path = project_run_dir(runtime_dir, project_run_id) / _POLICY_NAME
    text = _read_text(path, name="project run record")
    if text is None:
        return None
    try:
        record = ProjectRunRecord.model_validate_json(text)
    except ValidationError as exc:
        raise _store_error("the project run record is malformed or inconsistent") from exc
    if record.project_run_id != project_run_id:
        raise _store_error("the project run record belongs to another run")
    return record


def _require_record(runtime_dir: Path, project_run_id: ProjectRunId) -> ProjectRunRecord:
    record = load_project_run(runtime_dir, project_run_id)
    if record is None:
        raise _store_error("the project run is unknown")
    return record


def load_project_run_state(runtime_dir: Path, project_run_id: ProjectRunId) -> ProjectRunState:
    """Load a run's control state; an unknown run or an unreadable state is an error."""
    _require_record(runtime_dir, project_run_id)
    path = project_run_dir(runtime_dir, project_run_id) / _STATE_NAME
    text = _read_text(path, name="project run state")
    if text is None:
        raise _store_error("the project run state is missing")
    try:
        state = ProjectRunState.model_validate_json(text)
    except ValidationError as exc:
        raise _store_error("the project run state is malformed") from exc
    if state.project_run_id != project_run_id:
        raise _store_error("the project run state belongs to another run")
    return state


def require_same_policy(record: ProjectRunRecord, policy: AutonomousRunPolicy) -> None:
    """Refuse to resume a run under any policy other than the one it started with."""
    if policy_digest(policy) != record.policy_digest:
        raise AutonomousRunPolicyMismatchError(
            "the policy differs from the immutable policy of this project run; "
            "start a new project run to change the bounds"
        )


# --- Budget reservation, stop and audit journal -------------------------------------------


def read_project_run_events(
    runtime_dir: Path, project_run_id: ProjectRunId
) -> tuple[ProjectRunEvent, ...]:
    """Read a run's audit journal in order; an absent journal is empty."""
    path = project_run_dir(runtime_dir, project_run_id) / _EVENTS_NAME
    text = _read_text(path, name="run event journal")
    if text is None:
        return ()
    events: list[ProjectRunEvent] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            events.append(ProjectRunEvent.model_validate_json(line))
        except ValidationError as exc:
            raise _store_error("the run event journal is malformed") from exc
    for index, event in enumerate(events, start=1):
        if event.sequence != index or event.project_run_id != project_run_id:
            raise _store_error("the run event journal is inconsistent")
    return tuple(events)


def _append_event(
    runtime_dir: Path,
    project_run_id: ProjectRunId,
    *,
    clock: Callable[[], datetime],
    kind: ProjectRunEventKind,
    phase_id: PhaseId | None = None,
    subphase_id: SubphaseId | None = None,
    disposition: AutonomousRunDisposition | None = None,
    detail: str | None = None,
) -> None:
    existing = read_project_run_events(runtime_dir, project_run_id)
    event = ProjectRunEvent(
        sequence=existing[-1].sequence + 1 if existing else 1,
        occurred_at=clock(),
        kind=kind,
        project_run_id=project_run_id,
        phase_id=phase_id,
        subphase_id=subphase_id,
        disposition=disposition,
        detail=detail,
    )
    _append_event_line(
        project_run_dir(runtime_dir, project_run_id) / _EVENTS_NAME, _event_line(event)
    )


def remaining_subphase_budget(record: ProjectRunRecord, state: ProjectRunState) -> int:
    """How many more distinct Sub-phase units this run may take execution authority for."""
    return max(0, record.policy.max_subphases - len(state.reservations))


def reserve_subphase(
    runtime_dir: Path,
    project_run_id: ProjectRunId,
    *,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    transaction_run_id: RunId,
    clock: Callable[[], datetime],
) -> ReservationOutcome:
    """Durably debit one Sub-phase budget slot for a unit; idempotent per Sub-phase.

    A unit is counted exactly once, when the run first takes execution authority for it: a retry
    or a resumed attempt of the same unit finds its reservation and costs nothing, and a unit
    already reserved is honoured even once the budget is spent. The debit is durable before this
    returns, so execution may only begin afterwards; a crash after it loses capacity (the slot
    stays spent) and never grants more.
    """
    record = _require_record(runtime_dir, project_run_id)
    state = load_project_run_state(runtime_dir, project_run_id)
    key = (phase_id.root, subphase_id.root)
    if any((r.phase_id.root, r.subphase_id.root) == key for r in state.reservations):
        return ReservationOutcome.ALREADY_RESERVED
    if remaining_subphase_budget(record, state) <= 0:
        return ReservationOutcome.EXHAUSTED

    reservation = SubphaseReservation(
        phase_id=phase_id,
        subphase_id=subphase_id,
        transaction_run_id=transaction_run_id,
        reserved_at=clock(),
    )
    updated = state.model_copy(update={"reservations": (*state.reservations, reservation)})
    _atomic_write(
        project_run_dir(runtime_dir, project_run_id) / _STATE_NAME, _canonical_bytes(updated)
    )
    _append_event(
        runtime_dir,
        project_run_id,
        clock=clock,
        kind=ProjectRunEventKind.SUBPHASE_RESERVED,
        phase_id=phase_id,
        subphase_id=subphase_id,
    )
    return ReservationOutcome.RESERVED


def record_project_run_stop(
    runtime_dir: Path,
    project_run_id: ProjectRunId,
    *,
    disposition: AutonomousRunDisposition,
    detail: str | None = None,
    clock: Callable[[], datetime],
) -> None:
    """Record the disposition the run stopped with, in the state and the audit journal."""
    state = load_project_run_state(runtime_dir, project_run_id)
    stop = RunStop(disposition=disposition, detail=detail, stopped_at=clock())
    updated = state.model_copy(update={"stop": stop})
    _atomic_write(
        project_run_dir(runtime_dir, project_run_id) / _STATE_NAME, _canonical_bytes(updated)
    )
    _append_event(
        runtime_dir,
        project_run_id,
        clock=clock,
        kind=ProjectRunEventKind.RUN_STOPPED,
        disposition=disposition,
        detail=detail,
    )


__all__ = [
    "AutonomousRunDisposition",
    "AutonomousRunError",
    "AutonomousRunPolicy",
    "AutonomousRunPolicyError",
    "AutonomousRunPolicyMismatchError",
    "AutonomousRunStoreError",
    "ProjectRunEvent",
    "ProjectRunEventKind",
    "ProjectRunId",
    "ProjectRunRecord",
    "ProjectRunState",
    "ReservationOutcome",
    "RunStop",
    "SubphaseReservation",
    "create_project_run",
    "list_project_runs",
    "load_project_run",
    "load_project_run_state",
    "policy_digest",
    "project_run_dir",
    "read_project_run_events",
    "record_project_run_stop",
    "remaining_subphase_budget",
    "require_finite_policy",
    "require_same_policy",
    "reserve_subphase",
]
