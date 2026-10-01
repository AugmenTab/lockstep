"""Planner-authored specification of Sub-phase 10.5 derived transaction metrics.

Pins the contract that metrics are a deterministic, read-only *projection* of
the authoritative event journal (and, for change size, accepted Git commits):
no model call, no prose parsing, no workflow mutation, no monetary cost, and
never an unknown value silently collapsed into zero.

Public surface under test (all new):

* ``lockstep.metrics.project_run_metrics(events, *, repository_change=None)`` --
  pure; one journal's events -> ``RunMetrics`` (``run_id``, ``subphases``,
  ``totals``).
* ``lockstep.metrics.project_runtime_metrics(runtime_dir, ...)`` -- reads
  ``events.jsonl`` and delegates; writes nothing.
* ``lockstep.metrics.aggregate_metrics(subphases)`` -- ``TransactionMetrics`` over
  ``SubphaseMetrics`` from any number of runs.
* ``lockstep.metrics.UnsupportedJournalError`` -- a journal whose completion
  cannot be attributed (more than one attempted Sub-phase).
* ``lockstep.git.measure_repository_change(root, base_sha, head_sha)`` -- diff
  size between two accepted commits, never the working tree.

Frozen definitions (population -> formula):

* attempted = distinct ``(phase_id, subphase_id)`` with an ``INVOCATION_STARTED``.
* completed = attempted Sub-phase whose journal replays through a
  ``StateTransitionedEvent`` to ``SUBPHASE_COMPLETE``. REVIEW_DECIDED APPROVE
  alone is not completion.
* executed attempts = distinct attempt numbers carried by ``INVOCATION_STARTED``
  or ``RESUME_STARTED``. An authorized-but-never-started retry is not one.
* first_pass_approval_rate = completed with 1 executed attempt and no REWORK
  review / completed.
* rework_rate = reviewed (a ``REVIEW_DECIDED`` exists) with a REWORK verdict /
  reviewed.
* attempts_per_success = executed attempts of completed Sub-phases / completed.
* <role>_invocations_per_success = distinct started invocations of that role over
  ALL attempted Sub-phases (failed work included) / completed.
* implementation_verification_runs = ``VERIFICATION_COMPLETED`` events;
  baseline runs = ``BASELINE_VERIFIED`` events; never mixed.
* repeated_attempts = executed attempts beyond the first; repeated_attempt_rate =
  repeated_attempts / executed attempts (all attempted Sub-phases);
  repeated_invocations = started invocations with attempt > 1.
* wall clock = first ``INVOCATION_STARTED`` -> the ``SUBPHASE_COMPLETE``
  transition, completed Sub-phases only; includes any halted idle time.
* a usage aggregate exposes ``known_total``, ``reporting_invocations``,
  ``total_invocations`` and ``complete``; provider-reported ``0`` reports, ``None``
  does not.
* human intervention = events whose ``cause`` is ``HUMAN_REQUIRED_DECISION`` or
  whose ``stop_reason`` is ``NEEDS_USER`` / ``EXTERNAL_SIDE_EFFECT_REQUIRED``.

Baseline classification (pre-implementation): every test in this module is RED
(collection ``ImportError``: ``lockstep.metrics`` does not exist). The 10.1-10.4
suites, Phase 9 retry/resume suites and the architecture tests are the
GREEN_REGRESSION guard; no existing test is changed.
"""

from __future__ import annotations

import json
import subprocess
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

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
    ProcessTermination,
    ProjectId,
    ProviderTelemetry,
    QuotaStatus,
    ReviewVerdict,
    RunId,
    StopReason,
    SubphaseId,
)
from lockstep.git import RepositoryChange, measure_repository_change
from lockstep.metrics import (
    RunMetrics,
    SubphaseMetrics,
    TransactionMetrics,
    UnsupportedJournalError,
    aggregate_metrics,
    project_run_metrics,
    project_runtime_metrics,
)
from lockstep.persistence import (
    ExecutionEvent,
    LockstepEvent,
    RunCreatedEvent,
    StateTransitionedEvent,
    append_event,
    read_events,
)
from lockstep.state import WorkflowState

K = ExecutionEventKind
OK = ExecutionOutcome.SUCCESS
FAIL = ExecutionOutcome.FAILURE
BLOCKED = ExecutionOutcome.BLOCKED
S = WorkflowState

_BASE = datetime(2026, 10, 1, 12, 0, 0, tzinfo=UTC)

_TO_COMPLETE = (
    S.PHASE_PLANNING,
    S.SUBPHASE_PLANNING,
    S.TEST_AUTHORING,
    S.TEST_BASELINE_VERIFY,
    S.TEST_COMMIT,
    S.IMPLEMENTING,
    S.VERIFYING,
    S.REVIEWING,
    S.IMPLEMENTATION_COMMIT,
    S.SUBPHASE_COMPLETE,
)

_PHASE = PhaseId.model_validate("10")
_SUBPHASE = SubphaseId.model_validate("05")


def _n(value: int) -> AttemptNumber:
    return AttemptNumber.model_validate(value)


def _usage(
    provider: str,
    *,
    model: str | None = None,
    effort: str | None = None,
    elapsed: float | None = None,
    termination: ProcessTermination = ProcessTermination.EXITED,
    quota: QuotaStatus = QuotaStatus.UNKNOWN,
    reported_model: str | None = None,
    input_tokens: int | None = None,
    uncached: int | None = None,
    cache_read: int | None = None,
    cache_write: int | None = None,
    output: int | None = None,
) -> InvocationUsage:
    return InvocationUsage(
        provider=provider,
        configured_model=model,
        configured_effort=effort,
        elapsed_seconds=elapsed,
        termination=termination,
        quota_status=quota,
        reported=ProviderTelemetry(
            reported_model=reported_model,
            input_tokens=input_tokens,
            uncached_input_tokens=uncached,
            cache_read_tokens=cache_read,
            cache_write_tokens=cache_write,
            output_tokens=output,
        ),
    )


class _Journal:
    """Build a valid in-memory journal one event at a time (deterministic clock)."""

    def __init__(self, run_id: str, phase: PhaseId = _PHASE, subphase: SubphaseId = _SUBPHASE):
        self.run_id = RunId.model_validate(run_id)
        self.phase = phase
        self.subphase = subphase
        self.events: list[LockstepEvent] = []
        self.clock = 0
        self.state = S.READY
        self._sequence = 0
        self._append(
            RunCreatedEvent(
                run_id=self.run_id,
                sequence=1,
                occurred_at=_BASE,
                project_id=ProjectId.model_validate("lockstep"),
            )
        )

    def _append(self, event: LockstepEvent) -> None:
        self.events.append(event)
        self._sequence = event.sequence

    def at(self, seconds: int) -> _Journal:
        self.clock = seconds
        return self

    def go(self, *states: WorkflowState) -> _Journal:
        for target in states:
            self._append(
                StateTransitionedEvent(
                    run_id=self.run_id,
                    sequence=self._sequence + 1,
                    occurred_at=_BASE + timedelta(seconds=self.clock),
                    source=self.state,
                    target=target,
                )
            )
            self.state = target
        return self

    def event(
        self,
        kind: ExecutionEventKind,
        *,
        attempt: int = 1,
        outcome: ExecutionOutcome | None = None,
        role: AgentRole | None = None,
        stage: InvocationStage | None = None,
        inv: str | None = None,
        verdict: ReviewVerdict | None = None,
        cause: FailureCause | None = None,
        stop: StopReason | None = None,
        detail: str | None = None,
        usage: InvocationUsage | None = None,
        returncode: int | None = None,
    ) -> _Journal:
        self._append(
            ExecutionEvent(
                run_id=self.run_id,
                sequence=self._sequence + 1,
                occurred_at=_BASE + timedelta(seconds=self.clock),
                kind=kind,
                outcome=outcome,
                phase_id=self.phase,
                subphase_id=self.subphase,
                attempt=_n(attempt),
                role=role,
                stage=stage,
                invocation_id=InvocationId.model_validate(inv) if inv else None,
                verdict=verdict,
                cause=cause,
                stop_reason=stop,
                detail=detail,
                usage=usage,
                returncode=returncode,
            )
        )
        return self

    def start(self, inv: str, role: AgentRole, stage: InvocationStage, attempt: int = 1):
        return self.event(K.INVOCATION_STARTED, attempt=attempt, role=role, stage=stage, inv=inv)

    def returned(
        self,
        inv: str,
        role: AgentRole,
        stage: InvocationStage,
        attempt: int = 1,
        *,
        outcome: ExecutionOutcome = OK,
        usage: InvocationUsage | None = None,
        cause: FailureCause | None = None,
    ):
        return self.event(
            K.INVOCATION_RETURNED,
            attempt=attempt,
            role=role,
            stage=stage,
            inv=inv,
            outcome=outcome,
            usage=usage,
            cause=cause,
        )

    def invoke(self, inv: str, role: AgentRole, stage: InvocationStage, attempt: int = 1, **kw):
        self.start(inv, role, stage, attempt)
        return self.returned(inv, role, stage, attempt, **kw)


PLAN = (AgentRole.PLANNER, InvocationStage.TEST_AUTHORING)
IMPL = (AgentRole.IMPLEMENTER, InvocationStage.IMPLEMENTATION)
REVIEW = (AgentRole.REVIEWER, InvocationStage.REVIEW)


# ---------------------------------------------------------------------------
# The required three-Sub-phase scenario (answers are computable by inspection).
# ---------------------------------------------------------------------------


def _subphase_a() -> _Journal:
    """Attempt 1 only: Planner, Implementer, verification, Reviewer APPROVE, complete."""
    j = _Journal("20261001-001", subphase=SubphaseId.model_validate("01"))
    j.at(10).go(S.PHASE_PLANNING, S.SUBPHASE_PLANNING, S.TEST_AUTHORING)
    j.invoke(
        "inv-a1",
        *PLAN,
        usage=_usage(
            "claude",
            model="opus",
            effort="high",
            elapsed=10.0,
            input_tokens=1000,
            uncached=200,
            cache_read=700,
            cache_write=100,
            output=50,
        ),
    )
    j.event(K.BASELINE_VERIFIED, outcome=OK, detail="red")
    j.event(K.TESTS_FROZEN, outcome=OK)
    j.at(40).go(S.TEST_BASELINE_VERIFY, S.TEST_COMMIT, S.IMPLEMENTING)
    j.invoke(
        "inv-a2",
        *IMPL,
        usage=_usage(
            "codex", model="gpt-5", effort="medium", elapsed=20.0, input_tokens=500, output=40
        ),
    )
    j.event(K.VERIFICATION_COMPLETED, outcome=OK)
    j.go(S.VERIFYING, S.REVIEWING)
    j.invoke(
        "inv-a3",
        *REVIEW,
        usage=_usage(
            "claude",
            model="opus",
            effort="high",
            elapsed=5.0,
            input_tokens=300,
            uncached=300,
            cache_read=0,
            cache_write=0,
            output=30,
        ),
    )
    j.event(K.REVIEW_DECIDED, role=AgentRole.REVIEWER, verdict=ReviewVerdict.APPROVE, outcome=OK)
    j.at(130).go(S.IMPLEMENTATION_COMMIT, S.SUBPHASE_COMPLETE)
    return j


def _subphase_b() -> _Journal:
    """Attempt 1 REWORK (IMPLEMENTATION_DEFECT); attempt 2 APPROVE; complete."""
    j = _Journal("20261001-002", subphase=SubphaseId.model_validate("02"))
    j.at(1000).go(S.PHASE_PLANNING, S.SUBPHASE_PLANNING, S.TEST_AUTHORING, S.TEST_BASELINE_VERIFY)
    j.go(S.TEST_COMMIT, S.IMPLEMENTING)
    j.invoke(
        "inv-b1",
        *IMPL,
        usage=_usage(
            "claude",
            model="haiku",
            effort="low",
            elapsed=12.0,
            reported_model="claude-haiku-4-5-20251001",
            input_tokens=400,
            uncached=100,
            cache_read=250,
            cache_write=50,
            output=60,
        ),
    )
    j.event(K.VERIFICATION_COMPLETED, outcome=OK)
    j.go(S.VERIFYING, S.REVIEWING)
    j.invoke(
        "inv-b2",
        *REVIEW,
        usage=_usage("codex", model="gpt-5", effort="medium", elapsed=4.0),
    )
    j.event(
        K.REVIEW_DECIDED,
        role=AgentRole.REVIEWER,
        verdict=ReviewVerdict.REWORK,
        outcome=FAIL,
        cause=FailureCause.IMPLEMENTATION_DEFECT,
    )
    j.go(S.HALTED)
    j.event(K.TRANSACTION_HALTED, outcome=BLOCKED, cause=FailureCause.IMPLEMENTATION_DEFECT)
    j.event(
        K.RETRY_AUTHORIZED,
        attempt=2,
        role=AgentRole.IMPLEMENTER,
        cause=FailureCause.IMPLEMENTATION_DEFECT,
    )
    j.event(K.RESUME_CLAIMED, attempt=2, role=AgentRole.IMPLEMENTER)
    j.event(K.RESUME_STARTED, attempt=2, role=AgentRole.IMPLEMENTER)
    j.go(S.IMPLEMENTING)
    j.invoke(
        "inv-b3",
        *IMPL,
        attempt=2,
        usage=_usage(
            "claude",
            model="haiku",
            effort="low",
            elapsed=8.0,
            input_tokens=450,
            uncached=50,
            cache_read=350,
            cache_write=50,
            output=70,
        ),
    )
    j.event(K.VERIFICATION_COMPLETED, attempt=2, outcome=OK)
    j.go(S.VERIFYING, S.REVIEWING)
    j.invoke(
        "inv-b4",
        *REVIEW,
        attempt=2,
        usage=_usage("codex", model="gpt-5", effort="medium", elapsed=6.0),
    )
    j.event(
        K.REVIEW_DECIDED,
        attempt=2,
        role=AgentRole.REVIEWER,
        verdict=ReviewVerdict.APPROVE,
        outcome=OK,
    )
    j.event(K.RESUME_SETTLED, attempt=2, role=AgentRole.REVIEWER, detail="completed")
    j.at(1200).go(S.IMPLEMENTATION_COMMIT, S.SUBPHASE_COMPLETE)
    return j


def _subphase_c() -> _Journal:
    """Attempt 1 provider failure, retry, attempt 2 fails again, retry exhausted (halted)."""
    j = _Journal("20261001-003", subphase=SubphaseId.model_validate("03"))
    j.at(2000).go(S.PHASE_PLANNING, S.SUBPHASE_PLANNING, S.TEST_AUTHORING, S.TEST_BASELINE_VERIFY)
    j.go(S.TEST_COMMIT, S.IMPLEMENTING)
    j.invoke(
        "inv-c1",
        *IMPL,
        outcome=FAIL,
        cause=FailureCause.PROVIDER_PROCESS_FAILURE,
        usage=_usage(
            "codex",
            model="gpt-5",
            effort="medium",
            elapsed=30.0,
            termination=ProcessTermination.TIMED_OUT,
        ),
    )
    j.go(S.HALTED)
    j.event(K.TRANSACTION_HALTED, outcome=BLOCKED, cause=FailureCause.PROVIDER_PROCESS_FAILURE)
    j.event(
        K.RETRY_AUTHORIZED,
        attempt=2,
        role=AgentRole.IMPLEMENTER,
        cause=FailureCause.PROVIDER_PROCESS_FAILURE,
    )
    j.event(K.RESUME_CLAIMED, attempt=2, role=AgentRole.IMPLEMENTER)
    j.event(K.RESUME_STARTED, attempt=2, role=AgentRole.IMPLEMENTER)
    j.go(S.IMPLEMENTING)
    # A pre-10.3-style record: no usage evidence at all.
    j.invoke(
        "inv-c2",
        *IMPL,
        attempt=2,
        outcome=FAIL,
        cause=FailureCause.PROVIDER_PROCESS_FAILURE,
    )
    j.event(
        K.RETRY_EXHAUSTED,
        attempt=2,
        role=AgentRole.IMPLEMENTER,
        cause=FailureCause.PROVIDER_PROCESS_FAILURE,
        stop=StopReason.MAX_REWORK_EXCEEDED,
    )
    j.go(S.HALTED)
    return j


def _scenario() -> list[SubphaseMetrics]:
    out: list[SubphaseMetrics] = []
    for journal in (_subphase_a(), _subphase_b(), _subphase_c()):
        out.extend(project_run_metrics(journal.events).subphases)
    return out


@pytest.fixture
def totals() -> TransactionMetrics:
    return aggregate_metrics(_scenario())


# ===========================================================================
# AC-02: attempted / completed counts; retries do not inflate them
# ===========================================================================


def test_attempted_and_completed_count_unique_subphases(totals: TransactionMetrics) -> None:
    assert totals.subphases_attempted == 3
    assert totals.subphases_completed == 2


def test_retries_do_not_create_extra_subphases() -> None:
    [b] = project_run_metrics(_subphase_b().events).subphases

    assert b.executed_attempts == 2
    assert b.completed is True
    assert project_run_metrics(_subphase_b().events).totals.subphases_attempted == 1


def test_review_approve_alone_is_not_completion() -> None:
    j = _Journal("20261001-010")
    j.go(*_TO_COMPLETE[:-3])  # stops at VERIFYING
    j.invoke("inv-x1", *IMPL)
    j.go(S.REVIEWING)
    j.invoke("inv-x2", *REVIEW)
    j.event(K.REVIEW_DECIDED, role=AgentRole.REVIEWER, verdict=ReviewVerdict.APPROVE, outcome=OK)

    [sub] = project_run_metrics(j.events).subphases

    assert sub.completed is False
    assert project_run_metrics(j.events).totals.subphases_completed == 0


def test_planned_but_never_executed_subphase_is_not_attempted() -> None:
    j = _Journal("20261001-011")
    j.go(S.PHASE_PLANNING, S.SUBPHASE_PLANNING)
    j.event(K.BASELINE_VERIFIED, outcome=OK)

    run = project_run_metrics(j.events)

    assert run.subphases == ()
    assert run.totals.subphases_attempted == 0


# ===========================================================================
# AC-03 / AC-04: first-pass approval and rework rate (explicit populations)
# ===========================================================================


def test_first_pass_approval_rate_population(totals: TransactionMetrics) -> None:
    rate = totals.first_pass_approval_rate

    assert (rate.numerator, rate.denominator) == (1, 2)
    assert rate.value == 0.5


def test_rework_rate_uses_reviewed_subphases_only(totals: TransactionMetrics) -> None:
    rate = totals.rework_rate

    # C failed before any review: it must not enter the denominator.
    assert (rate.numerator, rate.denominator) == (1, 2)
    assert rate.value == 0.5


def test_subphase_flags_for_review_and_rework() -> None:
    a, b, c = _scenario()

    assert (a.reached_review, a.reworked, a.first_pass) == (True, False, True)
    assert (b.reached_review, b.reworked, b.first_pass) == (True, True, False)
    assert (c.reached_review, c.reworked, c.first_pass) == (False, False, False)


def test_rework_inside_one_attempt_still_blocks_first_pass() -> None:
    j = _Journal("20261001-012")
    j.go(*_TO_COMPLETE[:-3])
    j.invoke("inv-y1", *IMPL)
    j.go(S.REVIEWING)
    j.invoke("inv-y2", *REVIEW)
    j.event(
        K.REVIEW_DECIDED,
        role=AgentRole.REVIEWER,
        verdict=ReviewVerdict.REWORK,
        outcome=FAIL,
        cause=FailureCause.IMPLEMENTATION_DEFECT,
    )
    j.invoke("inv-y3", *REVIEW)
    j.event(K.REVIEW_DECIDED, role=AgentRole.REVIEWER, verdict=ReviewVerdict.APPROVE, outcome=OK)
    j.go(S.IMPLEMENTATION_COMMIT, S.SUBPHASE_COMPLETE)

    [sub] = project_run_metrics(j.events).subphases

    assert sub.executed_attempts == 1
    assert sub.completed is True
    assert sub.reworked is True
    assert sub.first_pass is False


# ===========================================================================
# AC-05: attempts per success
# ===========================================================================


def test_attempts_per_success_uses_executed_attempts_of_completed_work(
    totals: TransactionMetrics,
) -> None:
    ratio = totals.attempts_per_success

    # A: 1 attempt, B: 2 attempts, over 2 completed. C's attempts are excluded.
    assert (ratio.numerator, ratio.denominator) == (3, 2)
    assert ratio.value == 1.5
    assert totals.executed_attempts == 5


def test_authorized_but_never_started_retry_is_not_an_executed_attempt() -> None:
    j = _Journal("20261001-013")
    j.go(*_TO_COMPLETE[:6])
    j.invoke("inv-z1", *IMPL, outcome=FAIL, cause=FailureCause.PROVIDER_PROCESS_FAILURE)
    j.go(S.HALTED)
    j.event(
        K.RETRY_AUTHORIZED,
        attempt=2,
        role=AgentRole.IMPLEMENTER,
        cause=FailureCause.PROVIDER_PROCESS_FAILURE,
    )
    j.event(K.RESUME_CLAIMED, attempt=2, role=AgentRole.IMPLEMENTER)

    [sub] = project_run_metrics(j.events).subphases

    assert sub.executed_attempts == 1
    assert sub.repeated_attempts == 0


def test_resume_started_counts_the_attempt_even_without_an_invocation() -> None:
    j = _Journal("20261001-014")
    j.go(*_TO_COMPLETE[:6])
    j.invoke("inv-w1", *IMPL, outcome=FAIL, cause=FailureCause.PROVIDER_PROCESS_FAILURE)
    j.event(K.RESUME_STARTED, attempt=2, role=AgentRole.REVIEWER)

    [sub] = project_run_metrics(j.events).subphases

    assert sub.executed_attempts == 2


# ===========================================================================
# AC-06: role invocations (canonical identity, no double counting)
# ===========================================================================


def test_raw_role_invocations_include_failed_work(totals: TransactionMetrics) -> None:
    assert totals.invocations_by_role == {
        AgentRole.PLANNER: 1,
        AgentRole.IMPLEMENTER: 5,
        AgentRole.REVIEWER: 3,
    }
    assert totals.total_invocations == 9


def test_role_invocations_per_success_have_explicit_denominator(
    totals: TransactionMetrics,
) -> None:
    assert (totals.planner_invocations_per_success.numerator, totals.subphases_completed) == (1, 2)
    assert totals.planner_invocations_per_success.value == 0.5
    assert totals.implementer_invocations_per_success.numerator == 5
    assert totals.implementer_invocations_per_success.denominator == 2
    assert totals.implementer_invocations_per_success.value == 2.5
    assert totals.reviewer_invocations_per_success.numerator == 3
    assert totals.reviewer_invocations_per_success.denominator == 2
    assert totals.reviewer_invocations_per_success.value == 1.5


def test_duplicate_started_and_returned_records_do_not_inflate_counts() -> None:
    j = _Journal("20261001-015")
    j.go(*_TO_COMPLETE[:6])
    j.start("inv-d1", *IMPL)
    j.start("inv-d1", *IMPL)  # duplicate record for the same canonical invocation
    j.returned("inv-d1", *IMPL, usage=_usage("claude", input_tokens=10, elapsed=1.0))
    j.returned("inv-d1", *IMPL, usage=_usage("claude", input_tokens=10, elapsed=1.0))

    [sub] = project_run_metrics(j.events).subphases

    assert sub.invocations_by_role == {AgentRole.IMPLEMENTER: 1}
    assert sub.usage.input_tokens.known_total == 10
    assert sub.usage.input_tokens.total_invocations == 1


def test_escalation_decision_is_a_planner_invocation_with_its_own_stage() -> None:
    j = _Journal("20261001-016")
    j.go(*_TO_COMPLETE[:6])
    j.invoke("inv-e1", AgentRole.PLANNER, InvocationStage.ESCALATION_DECISION)

    [sub] = project_run_metrics(j.events).subphases

    assert sub.invocations_by_role == {AgentRole.PLANNER: 1}
    assert sub.invocations_by_stage == {InvocationStage.ESCALATION_DECISION: 1}


def test_started_without_returned_is_still_one_invocation_with_no_usage() -> None:
    j = _Journal("20261001-017")
    j.go(*_TO_COMPLETE[:6])
    j.start("inv-g1", *IMPL)

    [sub] = project_run_metrics(j.events).subphases

    assert sub.invocations_by_role == {AgentRole.IMPLEMENTER: 1}
    assert sub.usage.input_tokens.total_invocations == 1
    assert sub.usage.input_tokens.reporting_invocations == 0


# ===========================================================================
# AC-07: verification runs; baseline is separate
# ===========================================================================


def test_baseline_and_implementation_verification_are_separate(
    totals: TransactionMetrics,
) -> None:
    assert totals.baseline_verification_runs == 1
    assert totals.implementation_verification_runs == 3
    ratio = totals.implementation_verification_runs_per_success
    assert (ratio.numerator, ratio.denominator) == (3, 2)
    assert ratio.value == 1.5


def test_failed_verification_runs_are_counted_as_runs() -> None:
    j = _Journal("20261001-018")
    j.go(*_TO_COMPLETE[:6])
    j.invoke("inv-v1", *IMPL)
    j.event(K.VERIFICATION_COMPLETED, outcome=FAIL, cause=FailureCause.VERIFICATION_FAILURE)

    [sub] = project_run_metrics(j.events).subphases

    assert sub.implementation_verification_runs == 1
    assert sub.baseline_verification_runs == 0


# ===========================================================================
# AC-08: repeated work (attribution over consumed work, not extra spend)
# ===========================================================================


def test_repeated_work_definition(totals: TransactionMetrics) -> None:
    assert totals.repeated_attempts == 2  # B attempt 2, C attempt 2
    rate = totals.repeated_attempt_rate
    assert (rate.numerator, rate.denominator) == (2, 5)
    assert rate.value == 0.4
    assert totals.repeated_invocations == 3  # b3, b4, c2


def test_repeated_work_does_not_change_resource_totals(totals: TransactionMetrics) -> None:
    # Repeated invocations are a subset of the invocations already counted once.
    assert totals.repeated_invocations <= totals.total_invocations
    assert totals.usage.input_tokens.known_total == 2650


# ===========================================================================
# AC-09: duration honesty
# ===========================================================================


def test_wall_clock_is_first_invocation_to_completion_transition() -> None:
    a, b, c = _scenario()

    assert a.wall_clock_seconds == 120.0  # t=10 -> t=130
    assert b.wall_clock_seconds == 200.0  # t=1000 -> t=1200
    assert c.wall_clock_seconds is None  # never completed


def test_wall_clock_is_not_the_sum_of_invocation_time() -> None:
    a, _, _ = _scenario()

    assert a.usage.elapsed.known_total_seconds == 35.0
    assert a.wall_clock_seconds == 120.0


def test_aggregate_wall_clock_covers_completed_subphases_only(
    totals: TransactionMetrics,
) -> None:
    wall = totals.completed_wall_clock

    assert wall.known_total_seconds == 320.0
    assert (wall.reporting_invocations, wall.total_invocations) == (2, 2)
    assert wall.complete is True


def test_invocation_elapsed_aggregate_exposes_coverage(totals: TransactionMetrics) -> None:
    elapsed = totals.usage.elapsed

    # a1 10 + a2 20 + a3 5 + b1 12 + b2 4 + b3 8 + b4 6 + c1 30; c2 has no usage.
    assert elapsed.known_total_seconds == 95.0
    assert (elapsed.reporting_invocations, elapsed.total_invocations) == (8, 9)
    assert elapsed.complete is False


def test_completion_transition_without_any_invocation_is_not_an_attempted_subphase() -> None:
    j = _Journal("20261001-020")
    j.go(*_TO_COMPLETE)

    run = project_run_metrics(j.events)

    assert run.subphases == ()
    assert run.totals.subphases_completed == 0


# ===========================================================================
# AC-10: provider / model / effort distribution (evidence preserved exactly)
# ===========================================================================


def test_provider_distribution_counts_invocations_and_reports_unreported(
    totals: TransactionMetrics,
) -> None:
    providers = totals.usage.providers

    assert providers.counts == {"claude": 4, "codex": 4}
    assert providers.unreported == 1


def test_configured_model_and_effort_are_distributed(totals: TransactionMetrics) -> None:
    usage = totals.usage

    assert usage.configured_models.counts == {"opus": 2, "haiku": 2, "gpt-5": 4}
    assert usage.configured_models.unreported == 1
    assert usage.configured_efforts.counts == {"high": 2, "medium": 4, "low": 2}
    assert usage.configured_efforts.unreported == 1


def test_configured_and_reported_models_are_never_merged(totals: TransactionMetrics) -> None:
    usage = totals.usage

    assert "claude-haiku-4-5-20251001" not in usage.configured_models.counts
    assert usage.reported_models.counts == {"claude-haiku-4-5-20251001": 1}
    assert usage.reported_models.unreported == 8
    assert "haiku" not in usage.reported_models.counts


def test_quota_status_keeps_unknown_visible(totals: TransactionMetrics) -> None:
    quota = totals.usage.quota

    assert quota.counts == {QuotaStatus.UNKNOWN: 8}
    assert quota.unreported == 1


def test_quota_exhausted_is_reported_only_from_canonical_status() -> None:
    j = _Journal("20261001-021")
    j.go(*_TO_COMPLETE[:6])
    j.invoke("inv-q1", *IMPL, outcome=FAIL, usage=_usage("claude", quota=QuotaStatus.EXHAUSTED))
    j.invoke("inv-q2", *IMPL, usage=_usage("claude", quota=QuotaStatus.SAFE))
    j.invoke("inv-q3", *IMPL, usage=_usage("codex"))

    [sub] = project_run_metrics(j.events).subphases

    assert sub.usage.quota.counts == {
        QuotaStatus.EXHAUSTED: 1,
        QuotaStatus.SAFE: 1,
        QuotaStatus.UNKNOWN: 1,
    }


# ===========================================================================
# AC-11 / AC-12 / AC-19: usage aggregation with coverage; failed work counts
# ===========================================================================


def test_partial_aggregate_never_masquerades_as_complete(totals: TransactionMetrics) -> None:
    usage = totals.usage

    assert usage.input_tokens.known_total == 2650
    assert usage.input_tokens.reporting_invocations == 5
    assert usage.input_tokens.total_invocations == 9
    assert usage.input_tokens.complete is False

    assert usage.uncached_input_tokens.known_total == 650
    assert usage.uncached_input_tokens.reporting_invocations == 4
    assert usage.cache_read_tokens.known_total == 1300
    assert usage.cache_read_tokens.reporting_invocations == 4
    assert usage.cache_write_tokens.known_total == 200
    assert usage.cache_write_tokens.reporting_invocations == 4
    assert usage.output_tokens.known_total == 250
    assert usage.output_tokens.reporting_invocations == 5
    for aggregate in (
        usage.uncached_input_tokens,
        usage.cache_read_tokens,
        usage.cache_write_tokens,
        usage.output_tokens,
    ):
        assert aggregate.total_invocations == 9
        assert aggregate.complete is False


def test_fully_reported_field_is_complete() -> None:
    [a] = project_run_metrics(_subphase_a().events).subphases

    assert a.usage.input_tokens.known_total == 1800
    assert a.usage.input_tokens.reporting_invocations == 3
    assert a.usage.input_tokens.total_invocations == 3
    assert a.usage.input_tokens.complete is True
    assert a.usage.output_tokens.complete is True
    # The Codex Implementer reported no uncached/cache fields: partial, not complete.
    assert a.usage.uncached_input_tokens.known_total == 500
    assert a.usage.uncached_input_tokens.reporting_invocations == 2
    assert a.usage.uncached_input_tokens.complete is False


def test_provider_reported_zero_is_reporting_and_unavailable_is_not() -> None:
    [a] = project_run_metrics(_subphase_a().events).subphases

    # a3 reported cache_read=0 and cache_write=0; a2 reported nothing; a1 reported values.
    assert a.usage.cache_read_tokens.known_total == 700
    assert a.usage.cache_read_tokens.reporting_invocations == 2
    assert a.usage.cache_write_tokens.known_total == 100
    assert a.usage.cache_write_tokens.reporting_invocations == 2
    assert a.usage.cache_read_tokens.total_invocations == 3


def test_no_telemetry_at_all_is_unavailable_not_zero_and_not_complete() -> None:
    j = _Journal("20261001-022")
    j.go(*_TO_COMPLETE[:6])
    j.invoke("inv-n1", *IMPL)
    j.invoke("inv-n2", *IMPL, usage=_usage("codex"))

    [sub] = project_run_metrics(j.events).subphases
    aggregate = sub.usage.input_tokens

    assert aggregate.reporting_invocations == 0
    assert aggregate.total_invocations == 2
    assert aggregate.complete is False


def test_failed_invocation_usage_is_included_in_raw_totals() -> None:
    _, _, c = _scenario()

    # c1 (failed, timed out) contributes its elapsed time to the raw consumption.
    assert c.usage.elapsed.known_total_seconds == 30.0
    assert c.usage.elapsed.reporting_invocations == 1
    assert c.usage.elapsed.total_invocations == 2
    assert c.usage.providers.counts == {"codex": 1}


def test_pre_telemetry_history_degrades_to_partial_coverage_never_zero() -> None:
    j = _Journal("20261001-023")
    j.go(*_TO_COMPLETE)
    j.invoke("inv-h1", *PLAN)
    j.invoke("inv-h2", *IMPL)
    j.event(K.REVIEW_DECIDED, role=AgentRole.REVIEWER, verdict=ReviewVerdict.APPROVE, outcome=OK)

    [sub] = project_run_metrics(j.events).subphases

    assert sub.usage.providers.counts == {}
    assert sub.usage.providers.unreported == 2
    assert sub.usage.output_tokens.reporting_invocations == 0
    assert sub.usage.elapsed.complete is False
    assert sub.failure_causes == {}


# ===========================================================================
# AC-13 / AC-14 / AC-15: failure cause and stop reason are distinct and typed
# ===========================================================================


def test_failure_cause_distribution_counts_events_and_affected_subphases(
    totals: TransactionMetrics,
) -> None:
    assert totals.failure_cause_events == {
        FailureCause.IMPLEMENTATION_DEFECT: 3,  # review, halt, retry-authorized (B)
        FailureCause.PROVIDER_PROCESS_FAILURE: 5,  # c1, halt, authorized, c2, exhausted (C)
    }
    assert totals.failure_cause_subphases == {
        FailureCause.IMPLEMENTATION_DEFECT: 1,
        FailureCause.PROVIDER_PROCESS_FAILURE: 1,
    }


def test_stop_reasons_are_aggregated_separately_from_causes(
    totals: TransactionMetrics,
) -> None:
    assert totals.stop_reason_events == {StopReason.MAX_REWORK_EXCEEDED: 1}
    assert totals.stop_reason_subphases == {StopReason.MAX_REWORK_EXCEEDED: 1}
    # The exhausted event keeps its original cause AND its terminal stop.
    assert FailureCause.PROVIDER_PROCESS_FAILURE in totals.failure_cause_events
    assert StopReason.MAX_REWORK_EXCEEDED not in totals.failure_cause_events
    assert all(isinstance(key, StopReason) for key in totals.stop_reason_events)
    assert all(isinstance(key, FailureCause) for key in totals.failure_cause_events)


def test_free_text_detail_is_never_parsed_into_categories() -> None:
    j = _Journal("20261001-024")
    j.go(*_TO_COMPLETE[:6])
    j.invoke("inv-p1", *IMPL)
    j.event(K.ESCALATION_DISPATCHED, role=AgentRole.PLANNER, detail="architecture_conflict")
    j.event(K.TRANSACTION_HALTED, outcome=BLOCKED, detail="human_authority_required")
    j.event(K.RESUME_SETTLED, attempt=2, detail="execution_failed")

    [sub] = project_run_metrics(j.events).subphases

    assert sub.failure_causes == {}
    assert sub.stop_reasons == {}
    assert sub.human_intervention_events == 0


# ===========================================================================
# AC-17: human intervention
# ===========================================================================


def test_human_intervention_counts_only_genuine_human_required_evidence() -> None:
    j = _Journal("20261001-025")
    j.go(*_TO_COMPLETE[:6])
    j.invoke("inv-u1", *IMPL)
    j.event(
        K.ESCALATION_DISPATCHED,
        role=AgentRole.PLANNER,
        cause=FailureCause.HUMAN_REQUIRED_DECISION,
    )
    j.event(
        K.TRANSACTION_HALTED,
        outcome=BLOCKED,
        cause=FailureCause.HUMAN_REQUIRED_DECISION,
        stop=StopReason.NEEDS_USER,
    )
    # Unrelated halts must not count.
    j.event(
        K.TRANSACTION_ABORTED,
        outcome=FAIL,
        cause=FailureCause.SCOPE_VIOLATION,
        stop=StopReason.OUT_OF_SCOPE_CHANGE,
        detail="implementation_scope",
    )

    run = project_run_metrics(j.events)
    [sub] = run.subphases

    assert sub.human_intervention_events == 2
    assert run.totals.human_intervention_events == 2
    assert run.totals.human_intervention_subphases == 1


def test_external_side_effect_stop_is_human_intervention_without_a_cause() -> None:
    j = _Journal("20261001-026")
    j.go(*_TO_COMPLETE[:6])
    j.invoke("inv-s1", *IMPL)
    j.event(K.TRANSACTION_HALTED, outcome=BLOCKED, stop=StopReason.EXTERNAL_SIDE_EFFECT_REQUIRED)

    assert project_run_metrics(j.events).totals.human_intervention_subphases == 1


def test_unrelated_stop_reasons_are_not_human_intervention(totals: TransactionMetrics) -> None:
    assert totals.human_intervention_events == 0
    assert totals.human_intervention_subphases == 0


# ===========================================================================
# AC-15 / AC-16 / AC-18 / AC-19: unsupported metrics are explicit
# ===========================================================================


def test_unsupported_metrics_are_declared_with_a_reason(totals: TransactionMetrics) -> None:
    unavailable = totals.unavailable

    for name in (
        "escalation_categories",
        "planner_implementer_disagreement",
        "test_counts",
        "non_generated_diff",
    ):
        assert name in unavailable
        assert unavailable[name].strip()


def test_unavailable_metrics_have_no_fabricated_value_fields(
    totals: TransactionMetrics,
) -> None:
    dumped = json.loads(totals.model_dump_json())

    for name in ("escalation_categories", "planner_implementer_disagreement", "test_counts"):
        assert name not in {key for key in dumped if key != "unavailable"}


# ===========================================================================
# AC-18: repository change from accepted commits only
# ===========================================================================


def _git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), "-c", "user.name=t", "-c", "user.email=t@example.com", *args],
        capture_output=True,
        text=True,
        check=True,
    )
    return result.stdout.strip()


@pytest.fixture
def accepted_commits(tmp_path: Path) -> tuple[Path, str, str]:
    root = tmp_path / "repo"
    root.mkdir()
    _git(root, "init", "-q", "-b", "main")
    (root / "tests").mkdir()
    (root / "tests" / "test_x.py").write_text("def test_x():\n    assert True\n")
    _git(root, "add", "-A")
    _git(root, "commit", "-q", "-m", "test commit")
    test_sha = _git(root, "rev-parse", "HEAD")
    (root / "mod.py").write_text("a = 1\nb = 2\nc = 3\n")
    (root / "tests" / "test_x.py").write_text("def test_x():\n    assert 1 == 1\n")
    (root / "blob.bin").write_bytes(b"\x00\x01\x02\x03")
    _git(root, "add", "-A")
    _git(root, "commit", "-q", "-m", "implementation commit")
    impl_sha = _git(root, "rev-parse", "HEAD")
    return root, test_sha, impl_sha


def test_repository_change_is_measured_between_accepted_commits(
    accepted_commits: tuple[Path, str, str],
) -> None:
    root, test_sha, impl_sha = accepted_commits

    change = measure_repository_change(root, test_sha, impl_sha)

    assert change == RepositoryChange(
        files_changed=3, lines_added=4, lines_deleted=1, binary_files_changed=1
    )


def test_repository_change_ignores_the_working_tree(
    accepted_commits: tuple[Path, str, str],
) -> None:
    root, test_sha, impl_sha = accepted_commits
    before = measure_repository_change(root, test_sha, impl_sha)

    (root / "mod.py").write_text("dirty\n" * 50)
    (root / "untracked.txt").write_text("x\n" * 50)

    assert measure_repository_change(root, test_sha, impl_sha) == before


def test_repository_change_attaches_to_the_completed_subphase_with_coverage(
    accepted_commits: tuple[Path, str, str],
) -> None:
    root, test_sha, impl_sha = accepted_commits
    change = measure_repository_change(root, test_sha, impl_sha)

    run = project_run_metrics(_subphase_a().events, repository_change=change)
    [sub] = run.subphases
    other = aggregate_metrics(
        [*run.subphases, *project_run_metrics(_subphase_b().events).subphases]
    )

    assert sub.repository_change == change
    assert run.totals.repository.files_changed.known_total == 3
    assert run.totals.repository.lines_added.known_total == 4
    assert run.totals.repository.files_changed.complete is True
    # B has no measured change: partial coverage, not zero.
    assert other.repository.files_changed.known_total == 3
    assert other.repository.files_changed.reporting_invocations == 1
    assert other.repository.files_changed.total_invocations == 2
    assert other.repository.files_changed.complete is False


def test_non_generated_diff_is_declared_unavailable_and_size_is_not_quality() -> None:
    totals = project_run_metrics(_subphase_a().events).totals

    assert "non_generated_diff" in totals.unavailable
    assert not hasattr(totals.repository, "non_generated_lines")
    assert not hasattr(totals, "quality_score")


# ===========================================================================
# AC-20 / AC-01: determinism, purity, read-only
# ===========================================================================


def test_projection_is_deterministic_and_does_not_mutate_inputs() -> None:
    events = tuple(_subphase_b().events)

    first = project_run_metrics(events)
    second = project_run_metrics(events)

    assert first == second
    assert first.model_dump_json() == second.model_dump_json()
    assert events == tuple(_subphase_b().events)


def _write_journal(runtime: Path, journal: _Journal) -> None:
    runtime.mkdir(parents=True, exist_ok=True)
    for event in journal.events:
        append_event(runtime / "events.jsonl", event)  # type: ignore[arg-type]


def test_runtime_projection_reads_the_journal_and_writes_nothing(tmp_path: Path) -> None:
    runtime = tmp_path / "rt"
    _write_journal(runtime, _subphase_b())
    (runtime / "state.json").write_text('{"sentinel": true}\n')
    journal_before = (runtime / "events.jsonl").read_bytes()
    state_before = (runtime / "state.json").read_bytes()
    listing_before = sorted(p.name for p in runtime.iterdir())

    first = project_runtime_metrics(runtime)
    second = project_runtime_metrics(runtime)

    assert first == second
    assert first == project_run_metrics(read_events(runtime / "events.jsonl"))
    assert (runtime / "events.jsonl").read_bytes() == journal_before
    assert (runtime / "state.json").read_bytes() == state_before
    assert sorted(p.name for p in runtime.iterdir()) == listing_before


def test_deleting_and_recomputing_yields_identical_metrics(tmp_path: Path) -> None:
    runtime = tmp_path / "rt"
    _write_journal(runtime, _subphase_a())

    cached = project_runtime_metrics(runtime).model_dump_json()
    (runtime / "metrics.json").write_text(cached)
    (runtime / "metrics.json").unlink()

    assert project_runtime_metrics(runtime).model_dump_json() == cached


def test_run_projection_matches_aggregation_of_its_subphases() -> None:
    run = project_run_metrics(_subphase_b().events)

    assert run.totals == aggregate_metrics(run.subphases)
    assert isinstance(run, RunMetrics)
    assert run.run_id == RunId.model_validate("20261001-002")


def test_aggregation_is_independent_of_run_order() -> None:
    forward = aggregate_metrics(_scenario())
    backward = aggregate_metrics(list(reversed(_scenario())))

    assert forward == backward


def test_multiple_attempted_subphases_in_one_journal_are_unsupported() -> None:
    j = _Journal("20261001-027")
    j.go(*_TO_COMPLETE[:6])
    j.invoke("inv-m1", *IMPL)
    j.subphase = SubphaseId.model_validate("06")
    j.invoke("inv-m2", *IMPL)

    with pytest.raises(UnsupportedJournalError):
        project_run_metrics(j.events)


# ===========================================================================
# AC-21: zero denominators
# ===========================================================================


def test_zero_denominators_are_undefined_not_zero_nan_or_an_error() -> None:
    empty = aggregate_metrics([])

    for ratio in (
        empty.first_pass_approval_rate,
        empty.rework_rate,
        empty.attempts_per_success,
        empty.planner_invocations_per_success,
        empty.implementer_invocations_per_success,
        empty.reviewer_invocations_per_success,
        empty.implementation_verification_runs_per_success,
        empty.repeated_attempt_rate,
    ):
        assert ratio.denominator == 0
        assert ratio.value is None
    assert empty.subphases_attempted == 0
    assert json.loads(empty.model_dump_json())["first_pass_approval_rate"]["value"] is None


def test_attempts_with_no_successes_leave_success_ratios_undefined() -> None:
    [c] = project_run_metrics(_subphase_c().events).subphases
    totals = aggregate_metrics([c])

    assert totals.subphases_completed == 0
    assert totals.attempts_per_success.value is None
    assert totals.implementer_invocations_per_success.numerator == 2
    assert totals.implementer_invocations_per_success.value is None
    # Rates over executed work are still defined.
    assert totals.repeated_attempt_rate.value == 0.5
    assert totals.completed_wall_clock.reporting_invocations == 0
    assert totals.completed_wall_clock.complete is True  # vacuously: nothing was expected


def test_empty_journal_projects_to_empty_metrics(tmp_path: Path) -> None:
    runtime = tmp_path / "rt"
    runtime.mkdir()
    append_event(
        runtime / "events.jsonl",
        RunCreatedEvent(
            run_id=RunId.model_validate("20261001-028"),
            sequence=1,
            occurred_at=_BASE,
            project_id=ProjectId.model_validate("lockstep"),
        ),
    )

    run = project_runtime_metrics(runtime)

    assert run.subphases == ()
    assert run.totals.subphases_attempted == 0
    assert run.totals.first_pass_approval_rate.value is None


# ===========================================================================
# AC-22: no monetary cost, no model call (static scans of the metrics surface)
# ===========================================================================

_METRICS_SOURCE = Path(__file__).resolve().parents[1] / "src" / "lockstep" / "metrics.py"


def test_metrics_output_model_has_no_monetary_vocabulary(totals: TransactionMetrics) -> None:
    keys: set[str] = set()

    def walk(node: object) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                keys.add(str(key))
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(json.loads(totals.model_dump_json()))
    walk(json.loads(aggregate_metrics(_scenario()[:1]).model_dump_json()))

    for forbidden in ("cost", "price", "dollar", "usd", "spend", "billing", "amortiz"):
        assert not [key for key in keys if forbidden in key.lower()], forbidden


def test_metrics_module_depends_on_no_provider_process_or_supervisor_layer() -> None:
    source = _METRICS_SOURCE.read_text()

    for forbidden in (
        "lockstep.agents",
        "lockstep.process",
        "lockstep.supervisor",
        "lockstep.agent_turn",
        "subprocess",
        "import re\n",
    ):
        assert forbidden not in source, forbidden


def test_metrics_module_never_reads_free_text_detail() -> None:
    source = _METRICS_SOURCE.read_text()

    assert ".detail" not in source


def test_metrics_projection_emits_no_events(tmp_path: Path) -> None:
    runtime = tmp_path / "rt"
    _write_journal(runtime, _subphase_a())
    count = len(read_events(runtime / "events.jsonl"))

    project_runtime_metrics(runtime)

    assert len(read_events(runtime / "events.jsonl")) == count


def test_event_schema_is_unchanged_by_the_metrics_layer() -> None:
    fields = set(ExecutionEvent.model_fields)

    assert fields == {
        "schema_version",
        "run_id",
        "sequence",
        "occurred_at",
        "event_type",
        "kind",
        "outcome",
        "phase_id",
        "subphase_id",
        "attempt",
        "role",
        "stage",
        "invocation_id",
        "returncode",
        "verdict",
        "stop_reason",
        "cause",
        "detail",
        "usage",
    }


def test_scenario_journals_are_valid_authoritative_journals(tmp_path: Path) -> None:
    for index, journal in enumerate((_subphase_a(), _subphase_b(), _subphase_c())):
        runtime = tmp_path / f"rt{index}"
        _write_journal(runtime, journal)

        assert len(read_events(runtime / "events.jsonl")) == len(journal.events)
