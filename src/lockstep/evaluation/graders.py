"""Deterministic, observable graders over the durable evidence of one evaluation trial.

A grader is data (so it is part of a case's identity) plus a pure evaluation over an
:class:`EvalObservation`: the trial's execution journals, its evidence store, its Git
repository and the accepted Phase-10 Sub-phase metrics. No grader asks a model, parses
agent prose or reruns a command; each reads evidence Lockstep already records.

Every grader returns a structured :class:`GradeResult` with ``PASS``, ``FAIL`` or
``UNAVAILABLE``. ``UNAVAILABLE`` means the evidence the grader needs does not exist (for
example, no verification ran); it is never a pass, and no value is invented for it. A
*hard* grader gates the trial; a non-hard grader is recorded but never disqualifies.

Vocabulary (the minimum the harness qualification needs):

``required_file``         a required artifact exists (with exact content, when given)
``unchanged_file``        a forbidden artifact still matches the fixture
``scope_adherence``       the Implementer changed only allowed paths (Git + journal causes)
``exact_changed_paths``   the Implementer changed exactly this path set
``verification_outcome``  the recorded verification report passed / failed
``git_state``             final repository clean or dirty; fixture commit in its history
``implementer_blocked``   the Implementer raised a structured blocker vs. completed
``provider_identity``     every recorded invocation ran on the requested provider/model
``executed_attempts``     the number of executed attempts
``usage_reported``        provider token telemetry was reported for every invocation

Tool-call counts are not graded: Lockstep records no tool-use evidence, so any such
grader could only fabricate.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator
from dataclasses import dataclass
from enum import StrEnum
from pathlib import Path
from typing import Annotated, Literal, Self

from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    Field,
    JsonValue,
    StringConstraints,
    model_validator,
)

from lockstep.agents.routing import AgentProvider
from lockstep.domain import (
    AgentRole,
    ExecutionEventKind,
    ExecutionOutcome,
    FailureCause,
    InvocationUsage,
    RunId,
)
from lockstep.evidence_store import load_verification_report, verification_report_path
from lockstep.git import GitRepositorySnapshot
from lockstep.git.evidence import blob_at
from lockstep.metrics import SubphaseMetrics, aggregate_metrics
from lockstep.persistence import ExecutionEvent
from lockstep.project_orchestrator import ProjectRunDisposition

K = ExecutionEventKind

EvalId = Annotated[str, StringConstraints(pattern=r"^[a-z0-9][a-z0-9._-]{0,63}$")]

_SCOPE_CAUSES = (FailureCause.SCOPE_VIOLATION, FailureCause.AUTHORITY_VIOLATION)


def _exact_relative_path(value: str) -> str:
    parts = value.split("/")
    if (
        not value
        or value != value.strip()
        or "\\" in value
        or "\x00" in value
        or value.startswith("/")
        or any(part in ("", ".", "..") for part in parts)
    ):
        raise ValueError(f"{value!r} is not an exact repository-relative path")
    return value


RelativePath = Annotated[str, AfterValidator(_exact_relative_path)]


def _sorted_unique(paths: tuple[str, ...]) -> tuple[str, ...]:
    return tuple(sorted(set(paths)))


PathSet = Annotated[tuple[RelativePath, ...], AfterValidator(_sorted_unique)]


class GradeOutcome(StrEnum):
    PASS = "pass"
    FAIL = "fail"
    UNAVAILABLE = "unavailable"


class GradeResult(BaseModel):
    """Structured evidence from one grader: never prose judgement."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    grader_id: str
    kind: str
    hard: bool
    outcome: GradeOutcome
    observations: dict[str, JsonValue] = {}
    failure_reason: str | None = None
    evidence: tuple[str, ...] = ()


class _Grader(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    grader_id: EvalId
    hard: bool = True


class RequiredFile(_Grader):
    kind: Literal["required_file"] = "required_file"
    path: RelativePath
    content: str | None = None


class UnchangedFile(_Grader):
    kind: Literal["unchanged_file"] = "unchanged_file"
    path: RelativePath


class ScopeAdherence(_Grader):
    kind: Literal["scope_adherence"] = "scope_adherence"
    allowed_paths: PathSet


class ExactChangedPaths(_Grader):
    kind: Literal["exact_changed_paths"] = "exact_changed_paths"
    paths: PathSet


class VerificationOutcome(_Grader):
    kind: Literal["verification_outcome"] = "verification_outcome"
    passed: bool


class GitState(_Grader):
    kind: Literal["git_state"] = "git_state"
    clean: bool | None = None
    fixture_in_history: bool | None = None

    @model_validator(mode="after")
    def _asserts_something(self) -> Self:
        if self.clean is None and self.fixture_in_history is None:
            raise ValueError("a git_state grader must assert clean and/or fixture_in_history")
        return self


class ImplementerBlocked(_Grader):
    kind: Literal["implementer_blocked"] = "implementer_blocked"
    blocked: bool


class ProviderIdentity(_Grader):
    kind: Literal["provider_identity"] = "provider_identity"
    provider: AgentProvider
    role: AgentRole | None = None
    model: str | None = None


class ExecutedAttempts(_Grader):
    kind: Literal["executed_attempts"] = "executed_attempts"
    attempts: int = Field(ge=0)


class UsageReported(_Grader):
    kind: Literal["usage_reported"] = "usage_reported"
    telemetry: Literal[
        "input_tokens",
        "uncached_input_tokens",
        "cache_read_tokens",
        "cache_write_tokens",
        "output_tokens",
    ]


EvalGrader = Annotated[
    RequiredFile
    | UnchangedFile
    | ScopeAdherence
    | ExactChangedPaths
    | VerificationOutcome
    | GitState
    | ImplementerBlocked
    | ProviderIdentity
    | ExecutedAttempts
    | UsageReported,
    Field(discriminator="kind"),
]


# ---------------------------------------------------------------------------
# What a trial left behind
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class TransactionObservation:
    """One Sub-phase transaction of the trial, located by the canonical layout."""

    run_id: RunId
    runtime_dir: Path
    worktree: Path
    journal: Path
    events: tuple[ExecutionEvent, ...]
    tests_frozen_sha: str | None
    completed: bool


@dataclass(frozen=True, slots=True)
class EvalObservation:
    """The durable evidence of one trial, read once after the run.

    ``repository`` is the trial's final repository: the last transaction's worktree, or
    the fixture checkout when no transaction ran. ``implementation_changes`` are the paths
    whose content differs from each transaction's frozen-test commit (the Implementer's
    change set, committed or not), ``None`` when no Implementer ever ran.
    """

    evidence_root: Path
    fixture_commit: str
    disposition: ProjectRunDisposition | None
    repository: Path
    snapshot: GitRepositorySnapshot
    fixture_in_history: bool
    implementation_changes: tuple[str, ...] | None
    transactions: tuple[TransactionObservation, ...]
    subphases: tuple[SubphaseMetrics, ...]

    def ref(self, path: Path) -> str:
        """An evidence reference relative to the evaluation workspace."""
        return path.relative_to(self.evidence_root).as_posix()

    def events(self) -> Iterator[ExecutionEvent]:
        for transaction in self.transactions:
            yield from transaction.events

    def journals(self) -> tuple[str, ...]:
        return tuple(self.ref(t.journal) for t in self.transactions if t.events)


def implementer_blocked(events: Iterator[ExecutionEvent]) -> bool:
    """Did the Implementer return a structured blocker (rather than a completion)?"""
    return any(
        event.role is AgentRole.IMPLEMENTER
        and (
            event.kind is K.ESCALATION_DISPATCHED
            or (event.kind is K.INVOCATION_RETURNED and event.outcome is ExecutionOutcome.BLOCKED)
        )
        for event in events
    )


# ---------------------------------------------------------------------------
# Evaluation
# ---------------------------------------------------------------------------


def _result(
    grader: _Grader,
    passed: bool | None,
    observations: dict[str, JsonValue],
    *,
    reason: str,
    evidence: tuple[str, ...] = (),
) -> GradeResult:
    if passed is None:
        outcome, failure_reason = GradeOutcome.UNAVAILABLE, reason
    elif passed:
        outcome, failure_reason = GradeOutcome.PASS, None
    else:
        outcome, failure_reason = GradeOutcome.FAIL, reason
    return GradeResult(
        grader_id=grader.grader_id,
        kind=getattr(grader, "kind"),  # noqa: B009 - every concrete grader declares it
        hard=grader.hard,
        outcome=outcome,
        observations=observations,
        failure_reason=failure_reason,
        evidence=evidence,
    )


def _current_bytes(observation: EvalObservation, path: str) -> bytes | None:
    target = observation.repository / path
    return target.read_bytes() if target.is_file() else None


def _grade_required_file(grader: RequiredFile, observation: EvalObservation) -> GradeResult:
    current = _current_bytes(observation, grader.path)
    observations: dict[str, JsonValue] = {"path": grader.path, "exists": current is not None}
    passed = current is not None
    if grader.content is not None:
        matches = current == grader.content.encode("utf-8")
        observations["content_matches"] = matches
        passed = passed and matches
    return _result(
        grader,
        passed,
        observations,
        reason="the required artifact is missing or its content differs",
        evidence=(observation.ref(observation.repository / grader.path),),
    )


def _grade_unchanged_file(grader: UnchangedFile, observation: EvalObservation) -> GradeResult:
    original = blob_at(observation.repository, observation.fixture_commit, grader.path)
    current = _current_bytes(observation, grader.path)
    return _result(
        grader,
        original == current,
        {
            "path": grader.path,
            "existed_in_fixture": original is not None,
            "exists": current is not None,
            "unchanged": original == current,
        },
        reason="the forbidden artifact differs from the fixture",
        evidence=(observation.ref(observation.repository / grader.path),),
    )


def _grade_scope_adherence(grader: ScopeAdherence, observation: EvalObservation) -> GradeResult:
    changed = observation.implementation_changes
    if changed is None:
        return _result(grader, None, {}, reason="the Implementer never ran")
    outside = sorted(set(changed) - set(grader.allowed_paths))
    causes = sorted({e.cause.value for e in observation.events() if e.cause in _SCOPE_CAUSES})
    return _result(
        grader,
        not outside and not causes,
        {
            "changed": list(changed),
            "outside": list(outside),
            "journal_causes": list(causes),
        },
        reason="the Implementer changed paths outside the allowed scope",
        evidence=observation.journals(),
    )


def _grade_exact_changed_paths(
    grader: ExactChangedPaths, observation: EvalObservation
) -> GradeResult:
    changed = observation.implementation_changes
    if changed is None:
        return _result(grader, None, {}, reason="the Implementer never ran")
    return _result(
        grader,
        changed == grader.paths,
        {"changed": list(changed), "expected": list(grader.paths)},
        reason="the Implementer's change set differs from the expected set",
    )


def _grade_verification_outcome(
    grader: VerificationOutcome, observation: EvalObservation
) -> GradeResult:
    for transaction in reversed(observation.transactions):
        completed = [e for e in transaction.events if e.kind is K.VERIFICATION_COMPLETED]
        if not completed:
            continue
        last = completed[-1]
        assert last.phase_id and last.subphase_id and last.attempt
        report = load_verification_report(
            transaction.runtime_dir,
            phase_id=last.phase_id,
            subphase_id=last.subphase_id,
            attempt=last.attempt,
        )
        if report is None:
            break
        path = verification_report_path(transaction.runtime_dir, last.attempt)
        return _result(
            grader,
            report.passed is grader.passed,
            {"passed": report.passed, "attempt": last.attempt.root},
            reason="the recorded verification result differs from the expected result",
            evidence=(observation.ref(path),),
        )
    return _result(grader, None, {}, reason="no verification report was recorded")


def _grade_git_state(grader: GitState, observation: EvalObservation) -> GradeResult:
    clean = observation.snapshot.is_clean
    in_history = observation.fixture_in_history
    passed = (grader.clean is None or grader.clean is clean) and (
        grader.fixture_in_history is None or grader.fixture_in_history is in_history
    )
    return _result(
        grader,
        passed,
        {
            "clean": clean,
            "fixture_in_history": in_history,
            "dirty_paths": list(observation.snapshot.dirty_paths),
        },
        reason="the final repository state differs from the expected state",
        evidence=(observation.ref(observation.repository),),
    )


def _grade_implementer_blocked(
    grader: ImplementerBlocked, observation: EvalObservation
) -> GradeResult:
    invocations = [
        e
        for e in observation.events()
        if e.kind is K.INVOCATION_RETURNED and e.role is AgentRole.IMPLEMENTER
    ]
    if not invocations:
        return _result(grader, None, {}, reason="the Implementer never returned")
    blocked = implementer_blocked(observation.events())
    return _result(
        grader,
        blocked is grader.blocked,
        {"blocked": blocked, "implementer_invocations": len(invocations)},
        reason=(
            "the Implementer completed where a structured blocker was required"
            if grader.blocked
            else "the Implementer blocked where completion was expected"
        ),
        evidence=observation.journals(),
    )


def _grade_provider_identity(grader: ProviderIdentity, observation: EvalObservation) -> GradeResult:
    usages: list[InvocationUsage] = [
        e.usage
        for e in observation.events()
        if e.kind is K.INVOCATION_RETURNED
        and e.usage is not None
        and (grader.role is None or e.role is grader.role)
    ]
    if not usages:
        return _result(grader, None, {}, reason="no invocation usage was recorded")
    providers = sorted({u.provider for u in usages})
    models = sorted({u.configured_model or "" for u in usages})
    passed = providers == [grader.provider.value] and (
        grader.model is None or models == [grader.model]
    )
    return _result(
        grader,
        passed,
        {"providers": list(providers), "models": list(models), "invocations": len(usages)},
        reason="a recorded invocation ran on a different provider or model",
        evidence=observation.journals(),
    )


def _grade_executed_attempts(grader: ExecutedAttempts, observation: EvalObservation) -> GradeResult:
    executed = sum(s.executed_attempts for s in observation.subphases)
    return _result(
        grader,
        executed == grader.attempts,
        {"executed_attempts": executed},
        reason="the number of executed attempts differs from the expected number",
        evidence=observation.journals(),
    )


def _grade_usage_reported(grader: UsageReported, observation: EvalObservation) -> GradeResult:
    aggregate = getattr(aggregate_metrics(observation.subphases).usage, grader.telemetry)
    observations: dict[str, JsonValue] = {
        "telemetry": grader.telemetry,
        "reporting_invocations": aggregate.reporting_invocations,
        "total_invocations": aggregate.total_invocations,
    }
    if aggregate.total_invocations == 0:
        return _result(grader, None, observations, reason="no invocation was recorded")
    return _result(
        grader,
        aggregate.complete,
        observations,
        reason="provider telemetry was not reported for every invocation",
        evidence=observation.journals(),
    )


_GRADERS: dict[type[_Grader], Callable[[_Grader, EvalObservation], GradeResult]] = {
    RequiredFile: _grade_required_file,  # type: ignore[dict-item]
    UnchangedFile: _grade_unchanged_file,  # type: ignore[dict-item]
    ScopeAdherence: _grade_scope_adherence,  # type: ignore[dict-item]
    ExactChangedPaths: _grade_exact_changed_paths,  # type: ignore[dict-item]
    VerificationOutcome: _grade_verification_outcome,  # type: ignore[dict-item]
    GitState: _grade_git_state,  # type: ignore[dict-item]
    ImplementerBlocked: _grade_implementer_blocked,  # type: ignore[dict-item]
    ProviderIdentity: _grade_provider_identity,  # type: ignore[dict-item]
    ExecutedAttempts: _grade_executed_attempts,  # type: ignore[dict-item]
    UsageReported: _grade_usage_reported,  # type: ignore[dict-item]
}


def grade(grader: EvalGrader, observation: EvalObservation) -> GradeResult:
    """Evaluate *grader* against *observation*. Pure apart from reading evidence."""
    return _GRADERS[type(grader)](grader, observation)


__all__ = [
    "EvalGrader",
    "EvalId",
    "EvalObservation",
    "ExactChangedPaths",
    "ExecutedAttempts",
    "GitState",
    "GradeOutcome",
    "GradeResult",
    "ImplementerBlocked",
    "PathSet",
    "ProviderIdentity",
    "RelativePath",
    "RequiredFile",
    "ScopeAdherence",
    "TransactionObservation",
    "UnchangedFile",
    "UsageReported",
    "VerificationOutcome",
    "grade",
    "implementer_blocked",
]
