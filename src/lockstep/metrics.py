"""Deterministic transaction metrics projected from the authoritative event journal.

Metrics are a *projection*: they are derived from the journal (and, for change
size, from two accepted commits supplied by the caller) and never become a
source of truth. Projection is pure and read-only, needs no model call, parses
no free text, and can be deleted and recomputed to an identical result.

Honesty rules enforced here:

* ``None`` / absent evidence is never zero. Every sum over partially reported
  telemetry is a :class:`UsageAggregate` that carries how many invocations
  reported and how many were expected, so a partial total cannot pass as a
  complete one.
* A rate is a :class:`Ratio` with an explicit numerator and denominator; a zero
  denominator yields ``value is None`` rather than zero, NaN, or an error.
* Failed, retried, blocked and halted work stays in every resource total. Only
  the *denominator* of ``*_per_success`` ratios is restricted to successes.
* Metrics that no canonical typed evidence supports are listed in
  ``TransactionMetrics.unavailable`` with the reason, never invented.

Frozen population definitions (see the 10.5 specification tests):

* attempted -- a ``(phase_id, subphase_id)`` with an ``INVOCATION_STARTED``.
* completed -- an attempted Sub-phase whose journal transitions to
  ``SUBPHASE_COMPLETE``.
* executed attempt -- a distinct attempt number on an ``INVOCATION_STARTED`` or
  ``RESUME_STARTED`` event; an authorized retry that never started is not one.
* reviewed -- a Sub-phase with a ``REVIEW_DECIDED`` event.
* first pass -- completed on one executed attempt with no REWORK review.
* human intervention -- an event whose cause is ``HUMAN_REQUIRED_DECISION`` or
  whose stop reason is ``NEEDS_USER`` / ``EXTERNAL_SIDE_EFFECT_REQUIRED``.

Aggregation boundary: one journal is one run, and a run currently drives one
Sub-phase. Completion is a journal-level transition without Sub-phase identity,
so a journal with more than one attempted Sub-phase is rejected rather than
guessed at. Cross-run aggregation is :func:`aggregate_metrics` over
``SubphaseMetrics`` from any number of runs.
"""

from __future__ import annotations

import math
from collections import Counter
from collections.abc import Iterable, Mapping, Sequence
from datetime import datetime
from pathlib import Path
from typing import Self

from pydantic import BaseModel, ConfigDict, computed_field

from lockstep.domain import (
    AgentRole,
    ExecutionEventKind,
    FailureCause,
    InvocationStage,
    InvocationUsage,
    PhaseId,
    ReviewVerdict,
    RunId,
    StopReason,
    SubphaseId,
)
from lockstep.git import RepositoryChange
from lockstep.persistence import (
    ExecutionEvent,
    LockstepEvent,
    StateTransitionedEvent,
    read_events,
)
from lockstep.state import WorkflowState

K = ExecutionEventKind

_HUMAN_STOP_REASONS = frozenset({StopReason.NEEDS_USER, StopReason.EXTERNAL_SIDE_EFFECT_REQUIRED})

_UNAVAILABLE: Mapping[str, str] = {
    "escalation_categories": (
        "execution events carry no typed escalation category; it exists only in "
        "free-text detail, which is never parsed"
    ),
    "planner_implementer_disagreement": (
        "no canonical typed Planner/Implementer disagreement evidence exists"
    ),
    "test_counts": (
        "no structured test count or failure-count artifact is persisted; only "
        "stage pass/fail outcomes exist"
    ),
    "non_generated_diff": "no canonical generated-file classification exists",
}


class UnsupportedJournalError(Exception):
    """The journal cannot be projected without guessing."""


class _Model(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class Ratio(_Model):
    """A rate with its explicit population; ``value`` is ``None`` when undefined."""

    numerator: int
    denominator: int

    @computed_field  # type: ignore[prop-decorator]
    @property
    def value(self) -> float | None:
        if self.denominator == 0:
            return None
        return self.numerator / self.denominator


class UsageAggregate(_Model):
    """A sum over only the invocations (or Sub-phases) that reported the field."""

    known_total: int = 0
    reporting_invocations: int = 0
    total_invocations: int = 0

    @computed_field  # type: ignore[prop-decorator]
    @property
    def complete(self) -> bool:
        return self.reporting_invocations == self.total_invocations

    @classmethod
    def of(cls, values: Iterable[int | None]) -> Self:
        collected = list(values)
        known = [v for v in collected if v is not None]
        return cls(
            known_total=sum(known),
            reporting_invocations=len(known),
            total_invocations=len(collected),
        )

    def merged(self, other: UsageAggregate) -> UsageAggregate:
        return UsageAggregate(
            known_total=self.known_total + other.known_total,
            reporting_invocations=self.reporting_invocations + other.reporting_invocations,
            total_invocations=self.total_invocations + other.total_invocations,
        )


class ElapsedAggregate(_Model):
    """Like :class:`UsageAggregate`, for seconds."""

    known_total_seconds: float = 0.0
    reporting_invocations: int = 0
    total_invocations: int = 0

    @computed_field  # type: ignore[prop-decorator]
    @property
    def complete(self) -> bool:
        return self.reporting_invocations == self.total_invocations

    @classmethod
    def of(cls, values: Iterable[float | None]) -> Self:
        collected = list(values)
        known = [v for v in collected if v is not None]
        return cls(
            known_total_seconds=math.fsum(known),
            reporting_invocations=len(known),
            total_invocations=len(collected),
        )

    def merged(self, other: ElapsedAggregate) -> ElapsedAggregate:
        return ElapsedAggregate(
            known_total_seconds=math.fsum([self.known_total_seconds, other.known_total_seconds]),
            reporting_invocations=self.reporting_invocations + other.reporting_invocations,
            total_invocations=self.total_invocations + other.total_invocations,
        )


class Distribution(_Model):
    """Invocation counts per observed value, plus those that reported none."""

    counts: dict[str, int] = {}
    unreported: int = 0

    @classmethod
    def of(cls, values: Iterable[str | None]) -> Self:
        counter: Counter[str] = Counter()
        unreported = 0
        for value in values:
            if value is None:
                unreported += 1
            else:
                counter[value] += 1
        return cls(counts=dict(sorted(counter.items())), unreported=unreported)

    def merged(self, other: Distribution) -> Distribution:
        counter: Counter[str] = Counter(self.counts)
        counter.update(other.counts)
        return Distribution(
            counts=dict(sorted(counter.items())), unreported=self.unreported + other.unreported
        )


class UsageMetrics(_Model):
    """Provider/process consumption over every invocation, successful or not."""

    providers: Distribution = Distribution()
    configured_models: Distribution = Distribution()
    configured_efforts: Distribution = Distribution()
    reported_models: Distribution = Distribution()
    quota: Distribution = Distribution()
    input_tokens: UsageAggregate = UsageAggregate()
    uncached_input_tokens: UsageAggregate = UsageAggregate()
    cache_read_tokens: UsageAggregate = UsageAggregate()
    cache_write_tokens: UsageAggregate = UsageAggregate()
    output_tokens: UsageAggregate = UsageAggregate()
    elapsed: ElapsedAggregate = ElapsedAggregate()

    @classmethod
    def of(cls, usages: Sequence[InvocationUsage | None]) -> UsageMetrics:
        return cls(
            providers=Distribution.of(u.provider if u else None for u in usages),
            configured_models=Distribution.of(u.configured_model if u else None for u in usages),
            configured_efforts=Distribution.of(u.configured_effort if u else None for u in usages),
            reported_models=Distribution.of(
                u.reported.reported_model if u else None for u in usages
            ),
            quota=Distribution.of(u.quota_status.value if u else None for u in usages),
            input_tokens=UsageAggregate.of(u.reported.input_tokens if u else None for u in usages),
            uncached_input_tokens=UsageAggregate.of(
                u.reported.uncached_input_tokens if u else None for u in usages
            ),
            cache_read_tokens=UsageAggregate.of(
                u.reported.cache_read_tokens if u else None for u in usages
            ),
            cache_write_tokens=UsageAggregate.of(
                u.reported.cache_write_tokens if u else None for u in usages
            ),
            output_tokens=UsageAggregate.of(
                u.reported.output_tokens if u else None for u in usages
            ),
            elapsed=ElapsedAggregate.of(u.elapsed_seconds if u else None for u in usages),
        )

    def merged(self, other: UsageMetrics) -> UsageMetrics:
        return UsageMetrics(
            providers=self.providers.merged(other.providers),
            configured_models=self.configured_models.merged(other.configured_models),
            configured_efforts=self.configured_efforts.merged(other.configured_efforts),
            reported_models=self.reported_models.merged(other.reported_models),
            quota=self.quota.merged(other.quota),
            input_tokens=self.input_tokens.merged(other.input_tokens),
            uncached_input_tokens=self.uncached_input_tokens.merged(other.uncached_input_tokens),
            cache_read_tokens=self.cache_read_tokens.merged(other.cache_read_tokens),
            cache_write_tokens=self.cache_write_tokens.merged(other.cache_write_tokens),
            output_tokens=self.output_tokens.merged(other.output_tokens),
            elapsed=self.elapsed.merged(other.elapsed),
        )


class RepositoryAggregate(_Model):
    """Accepted-commit change size over completed Sub-phases (observational only).

    ``total_invocations`` here counts completed Sub-phases and
    ``reporting_invocations`` those with a measured change.
    """

    files_changed: UsageAggregate = UsageAggregate()
    lines_added: UsageAggregate = UsageAggregate()
    lines_deleted: UsageAggregate = UsageAggregate()
    binary_files_changed: UsageAggregate = UsageAggregate()


class SubphaseMetrics(_Model):
    """Metrics of one attempted Sub-phase transaction."""

    phase_id: PhaseId
    subphase_id: SubphaseId
    completed: bool
    executed_attempts: int
    reached_review: bool
    reworked: bool
    first_pass: bool
    invocations_by_role: dict[AgentRole, int]
    invocations_by_stage: dict[InvocationStage, int]
    baseline_verification_runs: int
    implementation_verification_runs: int
    repeated_attempts: int
    repeated_invocations: int
    wall_clock_seconds: float | None
    usage: UsageMetrics
    failure_causes: dict[FailureCause, int]
    stop_reasons: dict[StopReason, int]
    human_intervention_events: int
    repository_change: RepositoryChange | None = None


class TransactionMetrics(_Model):
    """Aggregate over any set of Sub-phases; every ratio names its population."""

    subphases_attempted: int
    subphases_completed: int
    executed_attempts: int
    first_pass_approval_rate: Ratio
    rework_rate: Ratio
    attempts_per_success: Ratio
    invocations_by_role: dict[AgentRole, int]
    total_invocations: int
    planner_invocations_per_success: Ratio
    implementer_invocations_per_success: Ratio
    reviewer_invocations_per_success: Ratio
    baseline_verification_runs: int
    implementation_verification_runs: int
    implementation_verification_runs_per_success: Ratio
    repeated_attempts: int
    repeated_attempt_rate: Ratio
    repeated_invocations: int
    completed_wall_clock: ElapsedAggregate
    usage: UsageMetrics
    failure_cause_events: dict[FailureCause, int]
    failure_cause_subphases: dict[FailureCause, int]
    stop_reason_events: dict[StopReason, int]
    stop_reason_subphases: dict[StopReason, int]
    human_intervention_events: int
    human_intervention_subphases: int
    repository: RepositoryAggregate
    unavailable: dict[str, str]


class RunMetrics(_Model):
    """One journal's projection: its Sub-phases and their aggregate."""

    run_id: RunId
    subphases: tuple[SubphaseMetrics, ...]
    totals: TransactionMetrics


def _sorted_counts[T: str](counter: Mapping[T, int]) -> dict[T, int]:
    return dict(sorted(counter.items(), key=lambda item: str(item[0])))


def _completion_time(events: Sequence[LockstepEvent]) -> datetime | None:
    for event in events:
        if (
            isinstance(event, StateTransitionedEvent)
            and event.target is WorkflowState.SUBPHASE_COMPLETE
        ):
            return event.occurred_at
    return None


def _subphase_metrics(
    key_events: Sequence[ExecutionEvent],
    completion_at: datetime | None,
    repository_change: RepositoryChange | None,
) -> SubphaseMetrics:
    first = key_events[0]
    assert first.phase_id is not None and first.subphase_id is not None

    started: dict[str, ExecutionEvent] = {}
    returned: dict[str, ExecutionEvent] = {}
    attempts: set[int] = set()
    baseline = verification = 0
    reviewed = reworked = False
    causes: Counter[FailureCause] = Counter()
    stops: Counter[StopReason] = Counter()
    human = 0

    for event in key_events:
        if event.kind is K.INVOCATION_STARTED:
            assert event.invocation_id is not None and event.attempt is not None
            started.setdefault(event.invocation_id.root, event)
            attempts.add(event.attempt.root)
        elif event.kind is K.INVOCATION_RETURNED:
            assert event.invocation_id is not None
            returned.setdefault(event.invocation_id.root, event)
        elif event.kind is K.RESUME_STARTED and event.attempt is not None:
            attempts.add(event.attempt.root)
        elif event.kind is K.BASELINE_VERIFIED:
            baseline += 1
        elif event.kind is K.VERIFICATION_COMPLETED:
            verification += 1
        elif event.kind is K.REVIEW_DECIDED:
            reviewed = True
            reworked = reworked or event.verdict is ReviewVerdict.REWORK
        if event.cause is not None:
            causes[event.cause] += 1
        if event.stop_reason is not None:
            stops[event.stop_reason] += 1
        if event.cause is FailureCause.HUMAN_REQUIRED_DECISION or event.stop_reason in (
            _HUMAN_STOP_REASONS
        ):
            human += 1

    identities = {**returned, **started}
    roles: Counter[AgentRole] = Counter()
    stages: Counter[InvocationStage] = Counter()
    repeated_invocations = 0
    for event in identities.values():
        assert event.role is not None and event.stage is not None and event.attempt is not None
        roles[event.role] += 1
        stages[event.stage] += 1
        if event.attempt.root > 1:
            repeated_invocations += 1

    usages = [returned[inv].usage if inv in returned else None for inv in identities]
    completed = completion_at is not None
    executed = len(attempts)
    first_started = min(e.occurred_at for e in started.values()) if started else None
    wall_clock = (
        (completion_at - first_started).total_seconds()
        if completion_at is not None and first_started is not None
        else None
    )

    return SubphaseMetrics(
        phase_id=first.phase_id,
        subphase_id=first.subphase_id,
        completed=completed,
        executed_attempts=executed,
        reached_review=reviewed,
        reworked=reworked,
        first_pass=completed and executed == 1 and not reworked,
        invocations_by_role=_sorted_counts(roles),
        invocations_by_stage=_sorted_counts(stages),
        baseline_verification_runs=baseline,
        implementation_verification_runs=verification,
        repeated_attempts=max(0, executed - 1),
        repeated_invocations=repeated_invocations,
        wall_clock_seconds=wall_clock,
        usage=UsageMetrics.of(usages),
        failure_causes=_sorted_counts(causes),
        stop_reasons=_sorted_counts(stops),
        human_intervention_events=human,
        repository_change=repository_change,
    )


def aggregate_metrics(subphases: Iterable[SubphaseMetrics]) -> TransactionMetrics:
    """Aggregate Sub-phase metrics (from one or many runs) into :class:`TransactionMetrics`."""
    items = list(subphases)
    completed = [s for s in items if s.completed]
    n_completed = len(completed)

    roles: Counter[AgentRole] = Counter()
    cause_events: Counter[FailureCause] = Counter()
    cause_subphases: Counter[FailureCause] = Counter()
    stop_events: Counter[StopReason] = Counter()
    stop_subphases: Counter[StopReason] = Counter()
    usage = UsageMetrics()
    for s in items:
        roles.update(s.invocations_by_role)
        cause_events.update(s.failure_causes)
        cause_subphases.update(s.failure_causes.keys())
        stop_events.update(s.stop_reasons)
        stop_subphases.update(s.stop_reasons.keys())
        usage = usage.merged(s.usage)

    executed = sum(s.executed_attempts for s in items)
    repeated = sum(s.repeated_attempts for s in items)
    reviewed = [s for s in items if s.reached_review]
    changes = [s.repository_change for s in completed]

    def per_success(numerator: int) -> Ratio:
        return Ratio(numerator=numerator, denominator=n_completed)

    return TransactionMetrics(
        subphases_attempted=len(items),
        subphases_completed=n_completed,
        executed_attempts=executed,
        first_pass_approval_rate=per_success(sum(1 for s in completed if s.first_pass)),
        rework_rate=Ratio(
            numerator=sum(1 for s in reviewed if s.reworked), denominator=len(reviewed)
        ),
        attempts_per_success=per_success(sum(s.executed_attempts for s in completed)),
        invocations_by_role=_sorted_counts(roles),
        total_invocations=sum(roles.values()),
        planner_invocations_per_success=per_success(roles[AgentRole.PLANNER]),
        implementer_invocations_per_success=per_success(roles[AgentRole.IMPLEMENTER]),
        reviewer_invocations_per_success=per_success(roles[AgentRole.REVIEWER]),
        baseline_verification_runs=sum(s.baseline_verification_runs for s in items),
        implementation_verification_runs=sum(s.implementation_verification_runs for s in items),
        implementation_verification_runs_per_success=per_success(
            sum(s.implementation_verification_runs for s in items)
        ),
        repeated_attempts=repeated,
        repeated_attempt_rate=Ratio(numerator=repeated, denominator=executed),
        repeated_invocations=sum(s.repeated_invocations for s in items),
        completed_wall_clock=ElapsedAggregate.of(s.wall_clock_seconds for s in completed),
        usage=usage,
        failure_cause_events=_sorted_counts(cause_events),
        failure_cause_subphases=_sorted_counts(cause_subphases),
        stop_reason_events=_sorted_counts(stop_events),
        stop_reason_subphases=_sorted_counts(stop_subphases),
        human_intervention_events=sum(s.human_intervention_events for s in items),
        human_intervention_subphases=sum(1 for s in items if s.human_intervention_events),
        repository=RepositoryAggregate(
            files_changed=UsageAggregate.of(c.files_changed if c else None for c in changes),
            lines_added=UsageAggregate.of(c.lines_added if c else None for c in changes),
            lines_deleted=UsageAggregate.of(c.lines_deleted if c else None for c in changes),
            binary_files_changed=UsageAggregate.of(
                c.binary_files_changed if c else None for c in changes
            ),
        ),
        unavailable=dict(_UNAVAILABLE),
    )


def project_run_metrics(
    events: Sequence[LockstepEvent],
    *,
    repository_change: RepositoryChange | None = None,
) -> RunMetrics:
    """Project one journal's events into metrics. Pure; reads nothing else."""
    if not events:
        raise UnsupportedJournalError("journal has no events")

    by_subphase: dict[tuple[str, str], list[ExecutionEvent]] = {}
    attempted: set[tuple[str, str]] = set()
    for event in events:
        if (
            not isinstance(event, ExecutionEvent)
            or event.phase_id is None
            or event.subphase_id is None
        ):
            continue
        key = (event.phase_id.root, event.subphase_id.root)
        by_subphase.setdefault(key, []).append(event)
        if event.kind is K.INVOCATION_STARTED:
            attempted.add(key)

    if len(attempted) > 1:
        raise UnsupportedJournalError(
            "journal attempts more than one Sub-phase; completion cannot be attributed"
        )

    subphases = tuple(
        _subphase_metrics(by_subphase[key], _completion_time(events), repository_change)
        for key in sorted(attempted)
    )
    return RunMetrics(
        run_id=events[0].run_id,
        subphases=subphases,
        totals=aggregate_metrics(subphases),
    )


def project_runtime_metrics(
    runtime_dir: Path,
    *,
    repository_change: RepositoryChange | None = None,
) -> RunMetrics:
    """Read ``runtime_dir/events.jsonl`` and project it. Writes nothing."""
    events = read_events(runtime_dir / "events.jsonl")
    return project_run_metrics(events, repository_change=repository_change)
