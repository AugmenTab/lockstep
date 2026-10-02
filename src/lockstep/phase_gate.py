"""Audit-only Phase integration gate: one durable, numbered attempt.

When every Sub-phase of the current Phase is canonically complete (the cursor's
gate is ``READY``), a gate attempt asks one question of the final accepted
repository state::

    does the completed Phase, as an integrated whole, satisfy its frozen
    Phase-level requirements and broad repository-health requirements?

It answers with objective evidence first and, only when the frozen Phase has
integration criteria, a fresh read-only Planner review second::

    ready cursor -> accepted basis (final completed run's worktree, branch, commit)
        -> the project's configured Phase-gate command stack, as structured argv
        -> durable command evidence
        -> (criteria present) fresh read-only Planner review -> validated review
        -> durable decision: the acceptance point, PASS or FAIL

A command failure is by itself a FAIL; no model is asked whether it "really matters".
A review that cannot be obtained or validated is an *execution failure*, never a
verdict: nothing is manufactured from missing evidence.

The attempt holds no authority to change anything. It reads the cursor but never writes
it; it creates no commit, Contract, outline, or remediation. Before and after every
command stack and every review it proves the accepted worktree still has the same HEAD
and no staged or unstaged tracked change; a gate that changes tracked content has
violated its authority and no decision is accepted from it. Untracked files (caches,
scratch notes) follow the same policy the read-only Planner checks already use: they are
not tracked changes and are tolerated. Completing the Phase and planning a remediation
belong to :mod:`lockstep.phase_gate_cycle`, which composes this module.

Layout beneath the project run root (``runtime.runtime_dir``)::

    phase-gates/<phase-id>/events.jsonl          typed project-level gate journal
    phase-gates/<phase-id>/attempt-<n>/basis.json
                                       evidence.json
                                       decision.json      the acceptance point
                                       violation.json     tracked mutation, terminal
                                       remediation.json   the accepted remediation plan

Every artifact is written once and atomically, bound to its project, Master Plan digest,
Phase, attempt and basis commit, and refused if recorded again with different content.
The gate journal is evidence of gate execution, not a second project cursor; it is a
separate stream from every child transaction journal, so Phase-10 transaction metrics
are untouched. Writers are assumed single-process.
"""

from __future__ import annotations

import contextlib
import dataclasses
import json
import os
import re
import uuid
from dataclasses import dataclass, field
from datetime import UTC, datetime
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
    field_serializer,
    field_validator,
    model_validator,
)

from lockstep.agents import (
    AgentInvocationRequest,
    ClaudeAdapterError,
    CodexAdapterError,
    OpenAIStrictSchemaError,
    StructuredOutputAdapterError,
    invoke_agent,
    prepare_structured_planner_adapter,
)
from lockstep.domain import (
    AcceptanceCriterion,
    AgentRole,
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    RunId,
    SchemaVersion,
    SubphaseId,
    SubphaseOutline,
)
from lockstep.execution_config import ExecutionConfigError, require_phase_gate_execution
from lockstep.git import GitCommandError, inspect_repository
from lockstep.planning_store import load_active_subphase_contract, load_frozen_master_plan
from lockstep.planning_transport import PlanningTransportError
from lockstep.process import (
    ProcessConfigurationError,
    ProcessLaunchError,
    ProcessTimeoutError,
    build_process_environment,
)
from lockstep.project_cursor import CompletedSubphase, PhaseGateStatus, ProjectCursor
from lockstep.project_cursor_store import load_project_cursor
from lockstep.project_orchestrator import transaction_branch, transaction_worktree_path
from lockstep.runtime import AgentRuntime
from lockstep.verification_stack import CommandEvidence, run_command_evidence

_CURRENT_SCHEMA_VERSION: SchemaVersion = SchemaVersion.model_validate(1)

_GATES_DIR_NAME = "phase-gates"
_ATTEMPT_PREFIX = "attempt-"
_BASIS_NAME = "basis.json"
_EVIDENCE_NAME = "evidence.json"
_DECISION_NAME = "decision.json"
_VIOLATION_NAME = "violation.json"
_REMEDIATION_NAME = "remediation.json"
_EVENTS_NAME = "events.jsonl"
_PYCACHE_DIR_NAME = ".lockstep-gate-pycache"
_ATTEMPT_PATTERN = re.compile(rf"^{_ATTEMPT_PREFIX}([1-9][0-9]*)$")

_Sha256Hex = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
_GitObjectId = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{40,64}$")]
_PositiveStrictInt = Annotated[int, Field(strict=True, ge=1)]


def _reject_blank(value: str) -> str:
    if not value.strip():
        raise ValueError("must not be empty or whitespace-only")
    return value


def _reject_naive(value: datetime) -> datetime:
    if value.tzinfo is None or value.tzinfo.utcoffset(value) is None:
        raise ValueError("occurred_at must be timezone-aware")
    return value


_NonBlankStr = Annotated[str, AfterValidator(_reject_blank)]
_TzAwareDateTime = Annotated[datetime, AfterValidator(_reject_naive)]


# --- Vocabulary ----------------------------------------------------------------------


class PhaseGateVerdict(StrEnum):
    """The only two product outcomes of a gate: the Phase is integrated, or it is not."""

    PASS = "pass"
    FAIL = "fail"


class PhaseGateBasisRule(StrEnum):
    """Which accepted state a gate attempt audits.

    ``LATEST_PHASE_SUBPHASE`` is the normal rule: the latest canonically completed
    Sub-phase of the current Phase. ``PRIOR_PHASE_TIP`` is the explicit rule for a Phase
    that reached ``READY`` with no completed Sub-phase of its own: the latest accepted
    Sub-phase of any earlier Phase. With no accepted Sub-phase at all there is no basis
    and the gate refuses.
    """

    LATEST_PHASE_SUBPHASE = "latest_phase_subphase"
    PRIOR_PHASE_TIP = "prior_phase_tip"


class PhaseGateAttemptDisposition(StrEnum):
    PASSED = "passed"
    FAILED = "failed"
    EXECUTION_FAILED = "execution_failed"


class PhaseGateExecutionFailure(StrEnum):
    """Why an attempt could not reach a decision (never a verdict about the Phase)."""

    COMMAND_ERROR = "command_error"
    REVIEW_FAILED = "review_failed"
    AUTHORITY_VIOLATION = "authority_violation"


class PhaseGateEventKind(StrEnum):
    """Project-level gate evidence. Deliberately disjoint from ``ExecutionEventKind``."""

    PHASE_GATE_STARTED = "phase_gate_started"
    PHASE_GATE_PASSED = "phase_gate_passed"
    PHASE_GATE_FAILED = "phase_gate_failed"
    PHASE_GATE_EXECUTION_FAILED = "phase_gate_execution_failed"
    PHASE_GATE_REMEDIATION_PLANNED = "phase_gate_remediation_planned"
    PHASE_COMPLETE = "phase_complete"


class PhaseGateRefusal(StrEnum):
    """Deterministic reason a gate operation refused to start or proceed."""

    CURSOR_MISSING = "cursor_missing"
    NO_CURRENT_PHASE = "no_current_phase"
    NOT_READY = "not_ready"
    ACTIVE_CONTRACT = "active_contract"
    COMMANDS_NOT_CONFIGURED = "commands_not_configured"
    BASIS_UNAVAILABLE = "basis_unavailable"
    BASIS_DIRTY = "basis_dirty"
    BASIS_DRIFT = "basis_drift"
    GATE_NOT_PASSED = "gate_not_passed"
    INVALID_REMEDIATION_BOUND = "invalid_remediation_bound"
    REMEDIATION_INVALID = "remediation_invalid"
    ARTIFACT_INCONSISTENT = "artifact_inconsistent"


class PhaseGateError(Exception):
    """A gate operation refused to proceed, with a typed deterministic ``refusal``.

    Carries a short, bounded ``reason`` that never includes artifact contents, prompt
    text, command output, or provider output.
    """

    def __init__(self, refusal: PhaseGateRefusal, reason: str) -> None:
        self.refusal = refusal
        self.reason = reason
        super().__init__(f"phase gate error: {reason}")


# --- Artifact models -----------------------------------------------------------------


class _GateModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class _VersionedGateModel(_GateModel):
    schema_version: SchemaVersion = _CURRENT_SCHEMA_VERSION

    @field_validator("schema_version")
    @classmethod
    def _reject_unsupported_schema_version(cls, value: SchemaVersion) -> SchemaVersion:
        if value.root != _CURRENT_SCHEMA_VERSION.root:
            raise ValueError(
                f"unsupported schema_version {value.root}; "
                f"this artifact only understands schema_version {_CURRENT_SCHEMA_VERSION.root}"
            )
        return value


class PhaseGateBasis(_VersionedGateModel):
    """The accepted repository state one attempt audits, read from Git and the cursor."""

    project_id: ProjectId
    master_plan_digest: _Sha256Hex
    phase_id: PhaseId
    gate_attempt: _PositiveStrictInt
    basis_phase_id: PhaseId
    basis_subphase_id: SubphaseId
    basis_run_id: RunId
    branch: _NonBlankStr
    commit: _GitObjectId
    rule: PhaseGateBasisRule


class PhaseGateEvidence(_VersionedGateModel):
    """Ordered, bounded process evidence of one attempt's command stack.

    ``configured_command_count`` is how many commands the project configured; fewer
    attempted commands mean the stack stopped at the first required failure. States no
    verdict of its own.
    """

    project_id: ProjectId
    master_plan_digest: _Sha256Hex
    phase_id: PhaseId
    gate_attempt: _PositiveStrictInt
    basis_commit: _GitObjectId
    configured_command_count: _PositiveStrictInt
    max_output_bytes: _PositiveStrictInt
    commands: Annotated[tuple[CommandEvidence, ...], Field(min_length=1)]

    @model_validator(mode="after")
    def _enforce_stack_shape(self) -> Self:
        attempted = len(self.commands)
        if attempted > self.configured_command_count:
            raise ValueError("more commands were attempted than were configured")
        if any(entry.exit_code != 0 for entry in self.commands[:-1]):
            raise ValueError("commands ran after a required failure")
        if attempted < self.configured_command_count and self.commands[-1].exit_code == 0:
            raise ValueError("the stack stopped early without a failure")
        for entry in self.commands:
            for text in (entry.stdout, entry.stderr):
                if len(text.encode("utf-8")) > self.max_output_bytes:
                    raise ValueError("captured output exceeds the recorded bound")
        return self

    @property
    def passed(self) -> bool:
        return (
            len(self.commands) == self.configured_command_count and self.commands[-1].exit_code == 0
        )


class PhaseGateFinding(_GateModel):
    """One concrete way the Phase fails its integration criteria."""

    criterion_id: _NonBlankStr | None = None
    observation: _NonBlankStr
    evidence: _NonBlankStr


class PhaseGateReview(_VersionedGateModel):
    """The structured read-only Planner review of one completed Phase.

    A distinct decision type from the Sub-phase ``ReviewDecision``: it judges a whole
    Phase against its frozen integration criteria and can only say PASS or FAIL, and a
    FAIL must carry concrete findings.
    """

    phase_id: PhaseId
    verdict: PhaseGateVerdict
    summary: _NonBlankStr
    findings: tuple[PhaseGateFinding, ...] = ()

    @model_validator(mode="after")
    def _enforce_findings_consistency(self) -> Self:
        if self.verdict is PhaseGateVerdict.PASS and self.findings:
            raise ValueError("a passing review must not contain findings")
        if self.verdict is PhaseGateVerdict.FAIL and not self.findings:
            raise ValueError("a failing review must contain at least one finding")
        return self


class PhaseGateDecision(_VersionedGateModel):
    """The accepted outcome of one attempt: the gate's single durable acceptance point.

    Once ``decision.json`` exists a restart reuses it; the model is never asked again
    about the same attempt.
    """

    project_id: ProjectId
    master_plan_digest: _Sha256Hex
    phase_id: PhaseId
    gate_attempt: _PositiveStrictInt
    basis_commit: _GitObjectId
    outcome: PhaseGateVerdict
    deterministic_passed: bool
    review: PhaseGateReview | None = None
    summary: _NonBlankStr

    @model_validator(mode="after")
    def _enforce_outcome_consistency(self) -> Self:
        review = self.review
        if review is not None and review.phase_id != self.phase_id:
            raise ValueError("the review belongs to another phase")
        if self.outcome is PhaseGateVerdict.PASS:
            if not self.deterministic_passed:
                raise ValueError("a passing gate needs a passing command stack")
            if review is not None and review.verdict is not PhaseGateVerdict.PASS:
                raise ValueError("a passing gate cannot rest on a failing review")
        elif not self.deterministic_passed:
            if review is not None:
                raise ValueError("a failed command stack is never sent to a reviewer")
        elif review is None or review.verdict is not PhaseGateVerdict.FAIL:
            raise ValueError("a failing gate needs a failed command stack or a failing review")
        return self


class PhaseGateViolation(_VersionedGateModel):
    """Terminal record that a gate command or review changed the accepted tracked state."""

    project_id: ProjectId
    master_plan_digest: _Sha256Hex
    phase_id: PhaseId
    gate_attempt: _PositiveStrictInt
    basis_commit: _GitObjectId
    stage: Literal["commands", "review"]
    observed_head: _GitObjectId
    changed_paths: tuple[_NonBlankStr, ...] = ()
    evidence: PhaseGateEvidence | None = None


class RemediationReceipt(_VersionedGateModel):
    """The accepted remediation plan for one failed attempt: exactly one new Sub-phase."""

    project_id: ProjectId
    master_plan_digest: _Sha256Hex
    phase_id: PhaseId
    gate_attempt: _PositiveStrictInt
    basis_commit: _GitObjectId
    outline: SubphaseOutline


class PhaseGateEvent(_GateModel):
    """Typed project-level evidence that a gate action occurred.

    Bound to the project, Phase, gate attempt and repository basis. It carries no
    Sub-phase identity of its own (``basis_run_id`` names the accepted run audited, not
    a transaction this event belongs to) and is never read as progress authority.
    """

    schema_version: SchemaVersion = _CURRENT_SCHEMA_VERSION
    sequence: _PositiveStrictInt
    occurred_at: _TzAwareDateTime
    kind: PhaseGateEventKind
    project_id: ProjectId
    master_plan_digest: _Sha256Hex
    phase_id: PhaseId
    gate_attempt: _PositiveStrictInt
    basis_commit: _GitObjectId
    basis_run_id: RunId | None = None
    verdict: PhaseGateVerdict | None = None
    failure: PhaseGateExecutionFailure | None = None
    detail: _NonBlankStr | None = None

    @field_validator("schema_version")
    @classmethod
    def _reject_unsupported_schema_version(cls, value: SchemaVersion) -> SchemaVersion:
        if value.root != _CURRENT_SCHEMA_VERSION.root:
            raise ValueError(f"unsupported schema_version {value.root}")
        return value

    @field_serializer("occurred_at", when_used="json")
    def _serialize_occurred_at(self, value: datetime) -> str:
        return value.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")

    @model_validator(mode="after")
    def _enforce_kind_fields(self) -> Self:
        expected = {
            PhaseGateEventKind.PHASE_GATE_PASSED: PhaseGateVerdict.PASS,
            PhaseGateEventKind.PHASE_GATE_FAILED: PhaseGateVerdict.FAIL,
        }.get(self.kind)
        if self.verdict is not expected:
            raise ValueError(f"verdict is not valid on {self.kind.value}")
        if (self.failure is not None) != (
            self.kind is PhaseGateEventKind.PHASE_GATE_EXECUTION_FAILED
        ):
            raise ValueError(f"failure is not valid on {self.kind.value}")
        return self


@dataclass(frozen=True, slots=True)
class PhaseGateAttemptResult:
    """Typed outcome of one :func:`run_phase_gate_attempt` call.

    ``decision`` is present exactly when the attempt reached an accepted decision;
    ``reused`` says that decision was already durable and nothing was run. ``failure``
    explains an execution failure, which is never a verdict.
    """

    disposition: PhaseGateAttemptDisposition
    gate_attempt: int
    basis: PhaseGateBasis = field(repr=False)
    decision: PhaseGateDecision | None = field(default=None, repr=False)
    failure: PhaseGateExecutionFailure | None = None
    reused: bool = False
    detail: str | None = None


# --- Layout --------------------------------------------------------------------------


def phase_gate_dir(runtime_dir: Path, phase_id: PhaseId) -> Path:
    """The directory holding every gate artifact of one Phase."""
    return Path(runtime_dir) / _GATES_DIR_NAME / phase_id.root


def phase_gate_attempt_dir(runtime_dir: Path, phase_id: PhaseId, gate_attempt: int) -> Path:
    """The directory holding the artifacts of one numbered gate attempt."""
    return phase_gate_dir(runtime_dir, phase_id) / f"{_ATTEMPT_PREFIX}{gate_attempt}"


def phase_gate_events_path(runtime_dir: Path, phase_id: PhaseId) -> Path:
    """The Phase's typed gate journal: a stream apart from every transaction journal."""
    return phase_gate_dir(runtime_dir, phase_id) / _EVENTS_NAME


def list_phase_gate_attempts(runtime_dir: Path, phase_id: PhaseId) -> tuple[int, ...]:
    """The numbers of every gate attempt recorded for *phase_id*, ascending."""
    directory = phase_gate_dir(runtime_dir, phase_id)
    if not directory.is_dir():
        return ()
    numbers = []
    for child in directory.iterdir():
        match = _ATTEMPT_PATTERN.match(child.name)
        if match is not None and child.is_dir():
            numbers.append(int(match.group(1)))
    return tuple(sorted(numbers))


# --- Durable artifacts ------------------------------------------------------------------


def _canonical_bytes(model: BaseModel) -> bytes:
    text = json.dumps(model.model_dump(mode="json"), ensure_ascii=False, separators=(",", ":"))
    return (text + "\n").encode("utf-8")


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _inconsistent(reason: str) -> PhaseGateError:
    return PhaseGateError(PhaseGateRefusal.ARTIFACT_INCONSISTENT, reason)


def _reject_symlinks(path: Path) -> None:
    for guarded in (path.parent.parent, path.parent, path):
        if guarded.is_symlink():
            raise _inconsistent("gate storage must not be a symlink")


def _write_once(path: Path, payload: bytes, *, name: str) -> None:
    _reject_symlinks(path)
    if path.exists():
        try:
            existing = path.read_bytes()
        except OSError as exc:
            raise _inconsistent(f"cannot read the recorded {name}") from exc
        if existing == payload:
            return
        raise _inconsistent(f"{name} is already recorded with different content")

    parent = path.parent
    temp_path = parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    try:
        try:
            parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            with os.fdopen(fd, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp_path, path)
            _fsync_directory(parent)
        except OSError as exc:
            raise _inconsistent(f"cannot record the {name}") from exc
    except BaseException:
        with contextlib.suppress(OSError):
            temp_path.unlink()
        raise


def _load[ModelT: BaseModel](path: Path, model_type: type[ModelT], *, name: str) -> ModelT | None:
    _reject_symlinks(path)
    if not path.exists():
        return None
    try:
        return model_type.model_validate(json.loads(path.read_bytes().decode("utf-8")))
    except (OSError, ValueError, ValidationError) as exc:
        raise _inconsistent(f"the recorded {name} is unreadable or malformed") from exc


def _require_attempt(
    artifact: BaseModel, phase_id: PhaseId, gate_attempt: int, *, name: str
) -> None:
    if (
        getattr(artifact, "phase_id", None) != phase_id
        or getattr(artifact, "gate_attempt", None) != gate_attempt
    ):
        raise _inconsistent(f"the recorded {name} does not belong to this attempt")


def load_phase_gate_basis(
    runtime_dir: Path, phase_id: PhaseId, gate_attempt: int
) -> PhaseGateBasis | None:
    """Load an attempt's basis, or ``None`` if none was recorded."""
    path = phase_gate_attempt_dir(runtime_dir, phase_id, gate_attempt) / _BASIS_NAME
    basis = _load(path, PhaseGateBasis, name="gate basis")
    if basis is not None:
        _require_attempt(basis, phase_id, gate_attempt, name="gate basis")
    return basis


def load_phase_gate_evidence(
    runtime_dir: Path, phase_id: PhaseId, gate_attempt: int
) -> PhaseGateEvidence | None:
    """Load an attempt's command evidence, or ``None`` if none was recorded."""
    path = phase_gate_attempt_dir(runtime_dir, phase_id, gate_attempt) / _EVIDENCE_NAME
    evidence = _load(path, PhaseGateEvidence, name="gate evidence")
    if evidence is not None:
        _require_attempt(evidence, phase_id, gate_attempt, name="gate evidence")
    return evidence


def load_phase_gate_decision(
    runtime_dir: Path, phase_id: PhaseId, gate_attempt: int
) -> PhaseGateDecision | None:
    """Load an attempt's accepted decision, or ``None`` if none was accepted."""
    path = phase_gate_attempt_dir(runtime_dir, phase_id, gate_attempt) / _DECISION_NAME
    decision = _load(path, PhaseGateDecision, name="gate decision")
    if decision is not None:
        _require_attempt(decision, phase_id, gate_attempt, name="gate decision")
    return decision


def load_phase_gate_violation(
    runtime_dir: Path, phase_id: PhaseId, gate_attempt: int
) -> PhaseGateViolation | None:
    """Load an attempt's authority-violation record, or ``None`` if there is none."""
    path = phase_gate_attempt_dir(runtime_dir, phase_id, gate_attempt) / _VIOLATION_NAME
    violation = _load(path, PhaseGateViolation, name="gate violation")
    if violation is not None:
        _require_attempt(violation, phase_id, gate_attempt, name="gate violation")
    return violation


def load_remediation_receipt(
    runtime_dir: Path, phase_id: PhaseId, gate_attempt: int
) -> RemediationReceipt | None:
    """Load an attempt's accepted remediation plan, or ``None`` if none was accepted."""
    path = phase_gate_attempt_dir(runtime_dir, phase_id, gate_attempt) / _REMEDIATION_NAME
    receipt = _load(path, RemediationReceipt, name="remediation receipt")
    if receipt is not None:
        _require_attempt(receipt, phase_id, gate_attempt, name="remediation receipt")
    return receipt


def write_remediation_receipt(runtime_dir: Path, receipt: RemediationReceipt) -> None:
    """Durably accept *receipt*; an identical re-record is a no-op, a different one refused."""
    path = (
        phase_gate_attempt_dir(runtime_dir, receipt.phase_id, receipt.gate_attempt)
        / _REMEDIATION_NAME
    )
    _write_once(path, _canonical_bytes(receipt), name="remediation receipt")


# --- The gate journal ---------------------------------------------------------------------


def read_phase_gate_events(runtime_dir: Path, phase_id: PhaseId) -> tuple[PhaseGateEvent, ...]:
    """Read the Phase's gate journal in order; an absent journal is empty."""
    path = phase_gate_events_path(runtime_dir, phase_id)
    _reject_symlinks(path)
    if not path.exists():
        return ()
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise _inconsistent("the gate journal is unreadable") from exc
    events = []
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            events.append(PhaseGateEvent.model_validate_json(line))
        except ValidationError as exc:
            raise _inconsistent("the gate journal is malformed") from exc
    return tuple(events)


def append_phase_gate_event(
    runtime_dir: Path,
    *,
    kind: PhaseGateEventKind,
    project_id: ProjectId,
    master_plan_digest: str,
    phase_id: PhaseId,
    gate_attempt: int,
    basis_commit: str,
    basis_run_id: RunId | None = None,
    verdict: PhaseGateVerdict | None = None,
    failure: PhaseGateExecutionFailure | None = None,
    detail: str | None = None,
    dedupe: bool = False,
) -> PhaseGateEvent | None:
    """Append one typed event to the Phase's gate journal and make it durable.

    With *dedupe*, an event of the same kind for the same attempt that is already
    recorded is not appended again (``None`` is returned): this is what lets a restart
    repair a missing event without duplicating a present one.
    """
    existing = read_phase_gate_events(runtime_dir, phase_id)
    if dedupe and any(e.kind is kind and e.gate_attempt == gate_attempt for e in existing):
        return None
    event = PhaseGateEvent(
        sequence=existing[-1].sequence + 1 if existing else 1,
        occurred_at=datetime.now(UTC),
        kind=kind,
        project_id=project_id,
        master_plan_digest=master_plan_digest,
        phase_id=phase_id,
        gate_attempt=gate_attempt,
        basis_commit=basis_commit,
        basis_run_id=basis_run_id,
        verdict=verdict,
        failure=failure,
        detail=detail,
    )
    path = phase_gate_events_path(runtime_dir, phase_id)
    line = (event.model_dump_json() + "\n").encode("utf-8")
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
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
        raise _inconsistent("cannot record the gate event") from exc
    return event


# --- Review prompt and transport ------------------------------------------------------------

_MASTER_PLAN_LABEL = "Frozen Master Plan:"
_TARGET_PHASE_LABEL = "Target phase_id:"
_CRITERIA_LABEL = "Frozen Phase integration criteria:"
_BASIS_LABEL = "Accepted repository basis:"
_EVIDENCE_LABEL = "Deterministic gate evidence:"

_REVIEW_INSTRUCTIONS = (
    "You are the Lockstep Planner reviewing one completed Phase as an integrated whole.\n"
    "The frozen Phase integration criteria above are the only requirement authority. Decide "
    "whether the completed Phase, as it exists in the accepted repository, satisfies every one "
    "of them.\n"
    "The deterministic gate evidence is the authoritative record of the broad verification "
    "commands the host ran; it is evidence, not requirements.\n"
    "Do not invent criteria, do not add requirements, and do not reinterpret the Master Plan.\n"
    "Inspect the accepted repository read-only when useful. Do not modify files and do not "
    "implement or repair anything.\n"
    "Return pass only when every criterion is met. Otherwise return fail with concrete "
    "findings: each states what you observed and the evidence for it, and may name the "
    "criterion_id it concerns.\n"
    "Return only the structured PhaseGateReview requested by the supplied schema.\n"
)


def _canonical_json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def build_phase_gate_review_prompt(
    master_plan: MasterPlan,
    phase: PhasePlan,
    basis: PhaseGateBasis,
    evidence: PhaseGateEvidence,
) -> str:
    """Build the fresh-Planner review request from durable state alone.

    Names the frozen Master Plan and the Phase's frozen integration criteria as the
    requirement authority, the accepted repository basis, and the deterministic command
    evidence as evidence only. Nothing comes from a prior Reviewer or Planner session.
    """
    criteria = [c.model_dump(mode="json") for c in phase.integration_acceptance_criteria]
    return (
        f"{_MASTER_PLAN_LABEL}\n"
        f"{_canonical_json(master_plan.model_dump(mode='json'))}\n"
        "\n"
        f"{_TARGET_PHASE_LABEL}\n"
        f"{phase.phase_id.root}\n"
        "\n"
        f"{_CRITERIA_LABEL}\n"
        f"{_canonical_json(criteria)}\n"
        "\n"
        f"{_BASIS_LABEL}\n"
        f"{_canonical_json(basis.model_dump(mode='json'))}\n"
        "\n"
        f"{_EVIDENCE_LABEL}\n"
        f"{_canonical_json(evidence.model_dump(mode='json'))}\n"
        "\n"
        f"{_REVIEW_INSTRUCTIONS}"
    )


def invoke_planner_review(
    runtime: AgentRuntime,
    *,
    prompt: str,
    timeout_seconds: float,
    max_output_bytes: int,
    termination_grace_seconds: float,
) -> PhaseGateReview:
    """Invoke the configured Planner once and hydrate its structured Phase-gate review.

    The same provider-neutral path every Planner artifact takes (adapter, structured
    schema, private-stdin inference, strict hydration), for the one artifact the planning
    transport does not know. Exactly one inference: no retry, fallback, or repair.
    """
    structured = prepare_structured_planner_adapter(
        runtime.adapters.planner,
        canonical_schema=PhaseGateReview.model_json_schema(),
        runtime_dir=runtime.runtime_dir,
        schema_name="phase-gate-review",
    )
    request = AgentInvocationRequest(
        role=AgentRole.PLANNER,
        billing_mode=runtime.config.routing.planner.billing_mode,
        prompt=prompt,
        cwd=runtime.project_root,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=termination_grace_seconds,
    )
    process = invoke_agent(structured, request, parent_env=runtime.transaction_parent_env).process
    if process.returncode != 0:
        raise PlanningTransportError("planner process exited non-zero")
    if process.stdout_truncated:
        raise PlanningTransportError("planner review exceeded the configured output budget")
    try:
        return PhaseGateReview.model_validate_json(process.stdout)
    except ValidationError:
        raise PlanningTransportError("planner output is not a valid phase-gate-review") from None


# Failures that mean "the review could not be obtained", never "the Phase failed".
_REVIEW_FAILURES = (
    PlanningTransportError,
    ProcessLaunchError,
    ProcessTimeoutError,
    ProcessConfigurationError,
    ClaudeAdapterError,
    CodexAdapterError,
    StructuredOutputAdapterError,
    OpenAIStrictSchemaError,
)
# Failures that mean "the command stack could not be run", never "a command failed".
_COMMAND_FAILURES = (ProcessLaunchError, ProcessTimeoutError, ProcessConfigurationError)


# --- The accepted basis ------------------------------------------------------------------


def _final_basis_run(cursor: ProjectCursor, phase_id: PhaseId) -> tuple[CompletedSubphase, str]:
    """The accepted Sub-phase a gate attempt audits, and the rule that selected it."""
    in_phase = [e for e in cursor.completed_subphases if e.phase_id == phase_id]
    if in_phase:
        return in_phase[-1], PhaseGateBasisRule.LATEST_PHASE_SUBPHASE.value
    if cursor.completed_subphases:
        return cursor.completed_subphases[-1], PhaseGateBasisRule.PRIOR_PHASE_TIP.value
    raise PhaseGateError(
        PhaseGateRefusal.BASIS_UNAVAILABLE, "no accepted subphase exists to gate against"
    )


def _verified_head(worktree: Path, branch: str) -> str:
    """Prove *worktree* is exactly the accepted branch with no tracked change; return HEAD."""
    try:
        snapshot = inspect_repository(worktree)
    except (GitCommandError, OSError) as exc:
        raise PhaseGateError(
            PhaseGateRefusal.BASIS_UNAVAILABLE, "the accepted worktree is unavailable"
        ) from exc
    if snapshot.root != worktree.resolve():
        raise PhaseGateError(
            PhaseGateRefusal.BASIS_UNAVAILABLE, "the accepted worktree is not a repository root"
        )
    if snapshot.branch != branch:
        raise PhaseGateError(
            PhaseGateRefusal.BASIS_UNAVAILABLE,
            "the accepted worktree is not on the accepted branch",
        )
    if snapshot.staged_paths or snapshot.unstaged_paths:
        raise PhaseGateError(
            PhaseGateRefusal.BASIS_DIRTY, "the accepted worktree has uncommitted tracked changes"
        )
    return snapshot.head_sha


def tracked_state_mutation(worktree: Path, commit: str) -> tuple[str, tuple[str, ...]] | None:
    """``(observed HEAD, changed tracked paths)`` if the audited state changed, else ``None``.

    Deliberately not part of the frozen ``__all__`` surface; the Phase-gate cycle uses it to
    prove the Planner left the accepted state alone.
    """
    try:
        snapshot = inspect_repository(worktree)
    except (GitCommandError, OSError):
        return commit, ()
    changed = tuple(sorted({*snapshot.staged_paths, *snapshot.unstaged_paths}))
    if snapshot.head_sha != commit or changed:
        return snapshot.head_sha, changed
    return None


# --- Attempt selection ---------------------------------------------------------------------


def _select_attempt(
    runtime_dir: Path, cursor: ProjectCursor, phase_id: PhaseId, attempts: tuple[int, ...]
) -> tuple[int, bool]:
    """Pick the attempt number to run or reuse: ``(number, already_exists)``.

    The latest attempt is reused while it is undecided (a crash left it resumable) or
    holds a decision that has not yet been acted on; a terminal attempt (an authority
    violation, or a FAIL whose accepted remediation has completed) is followed by a new,
    explicitly numbered one.
    """
    if not attempts:
        return 1, False
    last = attempts[-1]
    if load_phase_gate_violation(runtime_dir, phase_id, last) is not None:
        return last + 1, False
    decision = load_phase_gate_decision(runtime_dir, phase_id, last)
    if decision is not None and decision.outcome is PhaseGateVerdict.FAIL:
        receipt = load_remediation_receipt(runtime_dir, phase_id, last)
        if receipt is not None:
            completed = {
                e.subphase_id for e in cursor.completed_subphases if e.phase_id == phase_id
            }
            if receipt.outline.subphase_id in completed:
                return last + 1, False
    return last, True


def _emit(
    runtime_dir: Path,
    basis: PhaseGateBasis,
    kind: PhaseGateEventKind,
    *,
    verdict: PhaseGateVerdict | None = None,
    failure: PhaseGateExecutionFailure | None = None,
    detail: str | None = None,
    dedupe: bool = True,
) -> None:
    append_phase_gate_event(
        runtime_dir,
        kind=kind,
        project_id=basis.project_id,
        master_plan_digest=basis.master_plan_digest,
        phase_id=basis.phase_id,
        gate_attempt=basis.gate_attempt,
        basis_commit=basis.commit,
        basis_run_id=basis.basis_run_id,
        verdict=verdict,
        failure=failure,
        detail=detail,
        dedupe=dedupe,
    )


def _result_from_decision(
    runtime_dir: Path, basis: PhaseGateBasis, decision: PhaseGateDecision, *, reused: bool
) -> PhaseGateAttemptResult:
    passed = decision.outcome is PhaseGateVerdict.PASS
    _emit(runtime_dir, basis, PhaseGateEventKind.PHASE_GATE_STARTED)
    _emit(
        runtime_dir,
        basis,
        PhaseGateEventKind.PHASE_GATE_PASSED if passed else PhaseGateEventKind.PHASE_GATE_FAILED,
        verdict=decision.outcome,
    )
    return PhaseGateAttemptResult(
        disposition=(
            PhaseGateAttemptDisposition.PASSED if passed else PhaseGateAttemptDisposition.FAILED
        ),
        gate_attempt=basis.gate_attempt,
        basis=basis,
        decision=decision,
        reused=reused,
    )


def _execution_failed(
    runtime_dir: Path,
    basis: PhaseGateBasis,
    failure: PhaseGateExecutionFailure,
    detail: str,
) -> PhaseGateAttemptResult:
    _emit(
        runtime_dir,
        basis,
        PhaseGateEventKind.PHASE_GATE_EXECUTION_FAILED,
        failure=failure,
        detail=detail,
        dedupe=False,
    )
    return PhaseGateAttemptResult(
        disposition=PhaseGateAttemptDisposition.EXECUTION_FAILED,
        gate_attempt=basis.gate_attempt,
        basis=basis,
        failure=failure,
        detail=detail,
    )


def _record_violation(
    runtime_dir: Path,
    basis: PhaseGateBasis,
    *,
    stage: Literal["commands", "review"],
    mutation: tuple[str, tuple[str, ...]],
    evidence: PhaseGateEvidence | None,
) -> PhaseGateAttemptResult:
    observed_head, changed = mutation
    violation = PhaseGateViolation(
        project_id=basis.project_id,
        master_plan_digest=basis.master_plan_digest,
        phase_id=basis.phase_id,
        gate_attempt=basis.gate_attempt,
        basis_commit=basis.commit,
        stage=stage,
        observed_head=observed_head,
        changed_paths=changed,
        evidence=evidence,
    )
    path = phase_gate_attempt_dir(runtime_dir, basis.phase_id, basis.gate_attempt) / _VIOLATION_NAME
    _write_once(path, _canonical_bytes(violation), name="gate violation")
    return _execution_failed(
        runtime_dir,
        basis,
        PhaseGateExecutionFailure.AUTHORITY_VIOLATION,
        f"the gate {stage} changed the accepted tracked state",
    )


def _write_decision(runtime_dir: Path, decision: PhaseGateDecision) -> None:
    path = (
        phase_gate_attempt_dir(runtime_dir, decision.phase_id, decision.gate_attempt)
        / _DECISION_NAME
    )
    _write_once(path, _canonical_bytes(decision), name="gate decision")


# --- The attempt ---------------------------------------------------------------------------


def _require_ready(
    runtime: AgentRuntime,
) -> tuple[ProjectCursor, PhaseId, MasterPlan, PhasePlan]:
    project_root, runtime_dir = runtime.project_root, runtime.runtime_dir
    cursor = load_project_cursor(project_root, runtime_dir)
    if cursor is None:
        raise PhaseGateError(
            PhaseGateRefusal.CURSOR_MISSING, "the project cursor is not initialized"
        )
    phase_id = cursor.current_phase
    if phase_id is None:
        raise PhaseGateError(PhaseGateRefusal.NO_CURRENT_PHASE, "every phase has already passed")
    if cursor.active_contract is not None:
        raise PhaseGateError(PhaseGateRefusal.ACTIVE_CONTRACT, "a subphase contract is active")
    if (
        cursor.phase_gate_status is not PhaseGateStatus.READY
        or cursor.current_subphase is not None
        or cursor.remaining_outline
    ):
        raise PhaseGateError(PhaseGateRefusal.NOT_READY, "the phase gate is not ready")
    if load_active_subphase_contract(project_root, runtime_dir) is not None:
        raise PhaseGateError(PhaseGateRefusal.ACTIVE_CONTRACT, "a subphase contract is frozen")
    try:
        require_phase_gate_execution(runtime.config.execution)
    except ExecutionConfigError as exc:
        raise PhaseGateError(PhaseGateRefusal.COMMANDS_NOT_CONFIGURED, exc.reason) from exc

    master = load_frozen_master_plan(project_root)
    if master is None:
        raise _inconsistent("the master plan is not frozen")
    frozen = next((p for p in master.phases if p.phase_id == phase_id), None)
    if frozen is None:
        raise _inconsistent("the current phase is not in the master plan")
    return cursor, phase_id, master, frozen


def _establish_basis(
    runtime: AgentRuntime,
    cursor: ProjectCursor,
    phase_id: PhaseId,
    number: int,
    *,
    existing: bool,
) -> PhaseGateBasis:
    """Return the attempt's basis, verified against Git; record it first if it is new."""
    runtime_dir = runtime.runtime_dir
    entry, rule = _final_basis_run(cursor, phase_id)
    worktree = transaction_worktree_path(runtime_dir, entry.run_id)
    branch = transaction_branch(entry.run_id)

    recorded = load_phase_gate_basis(runtime_dir, phase_id, number) if existing else None
    head = _verified_head(worktree, branch)
    if recorded is not None:
        if (recorded.project_id, recorded.master_plan_digest) != (
            cursor.project_id,
            cursor.master_plan_digest,
        ) or (recorded.basis_run_id, recorded.branch) != (entry.run_id, branch):
            raise _inconsistent("the recorded gate basis does not match the cursor history")
        if head != recorded.commit:
            raise PhaseGateError(
                PhaseGateRefusal.BASIS_DRIFT, "the accepted branch moved since the attempt began"
            )
        return recorded

    basis = PhaseGateBasis(
        project_id=cursor.project_id,
        master_plan_digest=cursor.master_plan_digest,
        phase_id=phase_id,
        gate_attempt=number,
        basis_phase_id=entry.phase_id,
        basis_subphase_id=entry.subphase_id,
        basis_run_id=entry.run_id,
        branch=branch,
        commit=head,
        rule=PhaseGateBasisRule(rule),
    )
    path = phase_gate_attempt_dir(runtime_dir, phase_id, number) / _BASIS_NAME
    _write_once(path, _canonical_bytes(basis), name="gate basis")
    return basis


def _run_commands(
    runtime: AgentRuntime, basis: PhaseGateBasis, worktree: Path
) -> PhaseGateEvidence | None:
    """Run the configured stack in the accepted worktree; ``None`` if it could not be run."""
    execution = runtime.config.execution
    cache_dir = (
        runtime.runtime_dir
        / _PYCACHE_DIR_NAME
        / f"{basis.phase_id.root}-attempt-{basis.gate_attempt}"
    )
    cache_dir.mkdir(parents=True, exist_ok=True)
    env = build_process_environment(
        runtime.transaction_parent_env, explicit_env={"PYTHONPYCACHEPREFIX": str(cache_dir)}
    )
    try:
        attempted = run_command_evidence(
            execution.phase_gate_commands,
            cwd=worktree,
            env=env,
            timeout_seconds=execution.command_timeout_seconds,
            max_output_bytes=execution.max_output_bytes,
            termination_grace_seconds=execution.termination_grace_seconds,
        )
    except _COMMAND_FAILURES:
        return None
    return PhaseGateEvidence(
        project_id=basis.project_id,
        master_plan_digest=basis.master_plan_digest,
        phase_id=basis.phase_id,
        gate_attempt=basis.gate_attempt,
        basis_commit=basis.commit,
        configured_command_count=len(execution.phase_gate_commands),
        max_output_bytes=execution.max_output_bytes,
        commands=attempted,
    )


def _decide_without_review(basis: PhaseGateBasis, evidence: PhaseGateEvidence) -> PhaseGateDecision:
    if evidence.passed:
        outcome = PhaseGateVerdict.PASS
        summary = (
            f"all {evidence.configured_command_count} Phase gate commands passed; the Phase "
            "has no semantic integration criteria"
        )
    else:
        outcome = PhaseGateVerdict.FAIL
        last = evidence.commands[-1]
        summary = (
            f"Phase gate command {len(evidence.commands)} of "
            f"{evidence.configured_command_count} exited {last.exit_code}"
        )
    return PhaseGateDecision(
        project_id=basis.project_id,
        master_plan_digest=basis.master_plan_digest,
        phase_id=basis.phase_id,
        gate_attempt=basis.gate_attempt,
        basis_commit=basis.commit,
        outcome=outcome,
        deterministic_passed=evidence.passed,
        review=None,
        summary=summary,
    )


def _validated_review(
    review: PhaseGateReview, phase_id: PhaseId, criteria: tuple[AcceptanceCriterion, ...]
) -> bool:
    if review.phase_id != phase_id:
        return False
    known = {c.criterion_id for c in criteria}
    return all(f.criterion_id is None or f.criterion_id in known for f in review.findings)


def run_phase_gate_attempt(
    runtime: AgentRuntime,
    *,
    planning_timeout_seconds: float,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
) -> PhaseGateAttemptResult:
    """Run, resume, or re-read one audit-only gate attempt for the current ``READY`` Phase.

    Refuses with a typed :class:`PhaseGateError` -- running nothing and writing nothing --
    unless the cursor is at a ready gate of a current Phase with no active Contract, the
    project configured ``execution.phase_gate_commands``, and the final accepted
    repository basis is unambiguous, available, and clean. Then it records the attempt's
    basis, runs the command stack against that basis, and (when the frozen Phase has
    integration criteria and the commands passed) asks one fresh read-only Planner for a
    structured review. The first durable decision is the acceptance point: calling again
    reuses it and never asks again. An undecided attempt resumes from its durable
    artifacts: recorded command evidence is reused, an unrecorded stack is rerun only
    against the unchanged basis. *planning_timeout_seconds*, *max_output_bytes* and
    *termination_grace_seconds* bound only the review; the commands use the project's
    execution limits.
    """
    runtime_dir = runtime.runtime_dir
    cursor, phase_id, master, frozen = _require_ready(runtime)
    attempts = list_phase_gate_attempts(runtime_dir, phase_id)
    number, existing = _select_attempt(runtime_dir, cursor, phase_id, attempts)

    decided = load_phase_gate_decision(runtime_dir, phase_id, number) if existing else None
    if decided is not None:
        recorded = load_phase_gate_basis(runtime_dir, phase_id, number)
        if recorded is None:
            raise _inconsistent("a gate decision exists without its basis")
        return _result_from_decision(runtime_dir, recorded, decided, reused=True)

    basis = _establish_basis(runtime, cursor, phase_id, number, existing=existing)
    worktree = transaction_worktree_path(runtime_dir, basis.basis_run_id)
    _emit(runtime_dir, basis, PhaseGateEventKind.PHASE_GATE_STARTED)

    evidence = load_phase_gate_evidence(runtime_dir, phase_id, number)
    if evidence is None:
        evidence = _run_commands(runtime, basis, worktree)
        if evidence is None:
            return _execution_failed(
                runtime_dir,
                basis,
                PhaseGateExecutionFailure.COMMAND_ERROR,
                "the gate command stack could not be run",
            )
        mutation = tracked_state_mutation(worktree, basis.commit)
        if mutation is not None:
            return _record_violation(
                runtime_dir, basis, stage="commands", mutation=mutation, evidence=evidence
            )
        path = phase_gate_attempt_dir(runtime_dir, phase_id, number) / _EVIDENCE_NAME
        _write_once(path, _canonical_bytes(evidence), name="gate evidence")

    criteria = frozen.integration_acceptance_criteria
    if not evidence.passed or not criteria:
        decision = _decide_without_review(basis, evidence)
    else:
        review = _obtain_review(
            runtime,
            master,
            frozen,
            basis,
            evidence,
            worktree,
            timeout_seconds=planning_timeout_seconds,
            max_output_bytes=max_output_bytes,
            termination_grace_seconds=termination_grace_seconds,
        )
        if isinstance(review, PhaseGateAttemptResult):
            return review
        decision = PhaseGateDecision(
            project_id=basis.project_id,
            master_plan_digest=basis.master_plan_digest,
            phase_id=phase_id,
            gate_attempt=number,
            basis_commit=basis.commit,
            outcome=review.verdict,
            deterministic_passed=True,
            review=review,
            summary=review.summary,
        )

    _write_decision(runtime_dir, decision)  # the acceptance point
    return _result_from_decision(runtime_dir, basis, decision, reused=False)


def _obtain_review(
    runtime: AgentRuntime,
    master: MasterPlan,
    frozen: PhasePlan,
    basis: PhaseGateBasis,
    evidence: PhaseGateEvidence,
    worktree: Path,
    *,
    timeout_seconds: float,
    max_output_bytes: int,
    termination_grace_seconds: float,
) -> PhaseGateReview | PhaseGateAttemptResult:
    """One fresh read-only review, or the execution failure that explains its absence."""
    runtime_dir = runtime.runtime_dir
    # The Planner inspects the accepted worktree, not the user's source checkout.
    planning_runtime = dataclasses.replace(runtime, project_root=worktree)
    try:
        review = invoke_planner_review(
            planning_runtime,
            prompt=build_phase_gate_review_prompt(master, frozen, basis, evidence),
            timeout_seconds=timeout_seconds,
            max_output_bytes=max_output_bytes,
            termination_grace_seconds=termination_grace_seconds,
        )
    except _REVIEW_FAILURES as exc:
        return _execution_failed(
            runtime_dir,
            basis,
            PhaseGateExecutionFailure.REVIEW_FAILED,
            f"the phase gate review could not be obtained: {type(exc).__name__}",
        )

    mutation = tracked_state_mutation(worktree, basis.commit)
    if mutation is not None:
        return _record_violation(
            runtime_dir, basis, stage="review", mutation=mutation, evidence=None
        )
    if not _validated_review(review, basis.phase_id, frozen.integration_acceptance_criteria):
        return _execution_failed(
            runtime_dir,
            basis,
            PhaseGateExecutionFailure.REVIEW_FAILED,
            "the phase gate review does not match the frozen phase or its criteria",
        )
    return review


__all__ = [
    "PhaseGateAttemptDisposition",
    "PhaseGateAttemptResult",
    "PhaseGateBasis",
    "PhaseGateBasisRule",
    "PhaseGateDecision",
    "PhaseGateError",
    "PhaseGateEvent",
    "PhaseGateEventKind",
    "PhaseGateEvidence",
    "PhaseGateExecutionFailure",
    "PhaseGateFinding",
    "PhaseGateRefusal",
    "PhaseGateReview",
    "PhaseGateVerdict",
    "PhaseGateViolation",
    "RemediationReceipt",
    "append_phase_gate_event",
    "build_phase_gate_review_prompt",
    "list_phase_gate_attempts",
    "load_phase_gate_basis",
    "load_phase_gate_decision",
    "load_phase_gate_evidence",
    "load_phase_gate_violation",
    "load_remediation_receipt",
    "phase_gate_attempt_dir",
    "phase_gate_dir",
    "phase_gate_events_path",
    "read_phase_gate_events",
    "run_phase_gate_attempt",
    "write_remediation_receipt",
]
