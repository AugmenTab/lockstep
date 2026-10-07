"""Deterministic, read-only project audit projection over durable machine evidence (13.1).

Answers, for a whole project, what work was attempted and completed, how often first-pass
work succeeded, where rework and retries occurred and why, which roles, stages, providers and
models consumed invocations, what usage telemetry was actually reported, what the accepted
commits changed, and what the Phase gates did -- from durable evidence alone::

    project cursor, frozen Master Plan, archived / active Contracts
    planning/invocations.jsonl                         project-level planning (12.10-R1)
    transactions/<run>/events.jsonl, state.json        child transactions (Phase 10)
    transactions/<run>/retry/...                       typed retry authority
    transactions/<run>/artifacts/attempt-<n>/...       verification reports
    phase-gates/<phase>/...                            gate attempts, events, decisions
    phase-gates/<phase>/review-invocations.jsonl       semantic-review attribution (13.1)
    project/phase-context/<phase>.json                 Phase finalizations (12.8)
    project-runs/<id>/...                              autonomous project runs
    lockstep/run/<run> branches                        accepted commits (survive 12.9 teardown)

Canonical rule: metrics explain authoritative events and artifacts; they never become new
execution truth. Building a projection is pure with respect to execution state -- it loads,
validates, aggregates and reads Git objects, and it never repairs, writes, reruns, invokes an
agent, or synthesizes a provider value. It needs no provider session, rendered prompt,
completed-Phase worktree (only the retained accepted basis, which 12.9 never removes) or prose,
and it does not persist itself: the projection is regenerable.

Honesty rules:

* Missing is not zero. Every sum is an :class:`ObservedTotal` / :class:`ObservedSeconds` that
  carries how many items reported, how many were eligible, and how many are known to have
  happened without any durable record (``not_recorded``, for example a pre-13.1 gate review).
  ``observed_sum`` is ``None`` when nothing reported; :class:`Coverage` names the case.
* Corrupt authoritative evidence fails closed with :class:`ProjectAuditError` naming its
  :class:`AuditEvidenceSource`; absent *optional* telemetry is coverage, never an error.
* No free text is parsed or classified. Repeated work is attributed only from typed events and
  artifacts; an unknown cause stays ``None``. The one host-written value read from an event
  ``detail`` is the frozen-test commit id that the Supervisor records on ``TESTS_FROZEN``; it is
  accepted only as a full object id that Git proves is the accepted commit's ancestor.
* Phase-10 transaction semantics are reused, not recomputed: every Sub-phase row embeds the
  accepted :class:`~lockstep.metrics.SubphaseMetrics` of its journal.
* Determinism: given identical artifacts and Git refs the projection, and its canonical
  serialization (:func:`audit_projection_json`), are identical. Nothing is taken from the
  projection-time clock, process or host, and every collection has a stable order.

Frozen definitions:

* attempted Sub-phase -- a cursor unit (completed, or the active binding) whose transaction
  journal exists. A planned or bound Contract without a journal is not an attempt. A journal no
  cursor unit owns is unattributable and fails closed.
* completed Sub-phase -- the cursor records the completion *and* the journal replays to
  ``SUBPHASE_COMPLETE``; a recorded completion the journal contradicts fails closed.
* first pass -- completed, and the Phase-10 first-pass rule holds (one executed attempt, no
  ``REWORK``): a Reviewer- or Implementer-targeted retry, a resumed attempt, a malformed or
  failed provider return and a blocker all deny it.
* review rework -- a ``REVIEW_DECIDED`` event with verdict ``REWORK``; retry -- a
  ``RETRY_AUTHORIZED`` event, typed by the retry authority (checkpoint, claim or settlement)
  that names its attempt; resumed attempt -- ``RESUME_STARTED``; abandoned invocation -- a
  ``STARTED`` with no ``RETURNED``.
* elapsed -- invocation: the host-measured ``InvocationUsage.elapsed_seconds``; attempt: first
  ``INVOCATION_STARTED`` / ``RESUME_STARTED`` of the attempt to its last
  ``INVOCATION_RETURNED``; Sub-phase: the Phase-10 wall clock (first invocation start to
  ``SUBPHASE_COMPLETE``) plus the journal span (first to last event); project run: record
  ``started_at`` to the last recorded stop.
* accepted change -- for the k-th completed Sub-phase, the accepted commit is its run branch
  tip, the frozen-test commit comes from ``TESTS_FROZEN`` and the base is that commit's parent,
  which must equal the previous accepted commit; test change = base..test commit,
  implementation change = test commit..accepted commit.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from collections import Counter, defaultdict
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass
from datetime import datetime
from enum import StrEnum
from pathlib import Path

from pydantic import BaseModel, ConfigDict, ValidationError, computed_field

from lockstep.autonomous_run_control import (
    AutonomousRunDisposition,
    AutonomousRunError,
    ProjectRunEventKind,
    list_project_runs,
    load_project_run,
    load_project_run_state,
    read_project_run_events,
)
from lockstep.contract_history import load_archived_subphase_contract
from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    ExecutionEventKind,
    ExecutionOutcome,
    FailureCause,
    InvocationStage,
    InvocationUsage,
    MasterPlan,
    PhaseId,
    QuotaStatus,
    ReviewVerdict,
    RunId,
    StopReason,
    SubphaseContract,
    SubphaseId,
    TestExpectation,
)
from lockstep.evidence_store import EvidenceStoreError, load_verification_report
from lockstep.git import (
    GitCommandError,
    RepositoryChange,
    changed_paths_between,
    measure_repository_change,
)
from lockstep.git.evidence import branch_commit, commit_parent, is_ancestor
from lockstep.metrics import (
    Distribution,
    SubphaseMetrics,
    UnsupportedJournalError,
    aggregate_metrics,
    project_run_metrics,
)
from lockstep.persistence import (
    ExecutionEvent,
    JournalIntegrityError,
    LockstepEvent,
    RunHaltedEvent,
    StateConsistencyError,
    StatePersistenceError,
    load_verified_state,
    read_events,
)
from lockstep.phase_context_finalization import (
    FinalizedSubphase,
    PhaseContextFinalization,
    PhaseContextFinalizationError,
    load_phase_context_finalization,
    phase_context_finalization_identity,
)
from lockstep.phase_gate import (
    PhaseGateBasisRule,
    PhaseGateDecision,
    PhaseGateError,
    PhaseGateEventKind,
    PhaseGateExecutionFailure,
    PhaseGateVerdict,
    list_phase_gate_attempts,
    load_phase_gate_basis,
    load_phase_gate_decision,
    load_phase_gate_evidence,
    load_phase_gate_violation,
    load_remediation_receipt,
    phase_gate_attempt_dir,
    read_phase_gate_events,
)
from lockstep.phase_gate_review_invocation import (
    PhaseGateReviewInvocationError,
    PhaseGateReviewInvocationEventKind,
    read_phase_gate_review_invocation_events,
)
from lockstep.planning_invocation import (
    PlanningInvocationError,
    PlanningInvocationEventKind,
    PlanningStage,
    read_planning_invocation_events,
)
from lockstep.planning_store import (
    PlanningStoreError,
    load_active_subphase_contract,
    load_frozen_master_plan,
)
from lockstep.project_cursor import PhaseGateStatus, ProjectCursor, contract_digest
from lockstep.project_cursor_store import ProjectCursorStoreError, load_project_cursor
from lockstep.project_orchestrator import (
    transaction_branch,
    transaction_runtime_dir,
    transaction_worktree_path,
)
from lockstep.resume import ResumeClaim, ResumeStoreError, resume_claim_path
from lockstep.resume_settlement import ResumeSettlement
from lockstep.retry import RetryProtocolError
from lockstep.retry_checkpoint import (
    RetryAuthorityKind,
    RetryCheckpoint,
    RetryCheckpointStoreError,
    load_retry_checkpoint,
)
from lockstep.state import WorkflowState

AUDIT_PROJECTION_VERSION = 1

K = ExecutionEventKind

_GIT_OBJECT_ID = re.compile(r"^[0-9a-f]{40,64}$")
_PHASE_DIR = re.compile(r"^[0-9]{2,}$")
_TRANSACTIONS_DIR_NAME = "transactions"
_JOURNAL_NAME = "events.jsonl"
_STATE_NAME = "state.json"
_SETTLEMENTS_DIR = Path("retry") / "settlements"
_HALT_KINDS = frozenset({K.TRANSACTION_HALTED, K.TRANSACTION_ABORTED, K.RETRY_EXHAUSTED})
_HUMAN_STOP_REASONS = frozenset({StopReason.NEEDS_USER, StopReason.EXTERNAL_SIDE_EFFECT_REQUIRED})


# --- Errors ------------------------------------------------------------------------------------


class AuditEvidenceSource(StrEnum):
    """Which durable evidence a fail-closed projection error concerns."""

    MASTER_PLAN = "master_plan"
    PROJECT_CURSOR = "project_cursor"
    PLANNING_JOURNAL = "planning_journal"
    TRANSACTION_JOURNAL = "transaction_journal"
    RETRY_EVIDENCE = "retry_evidence"
    CONTRACT_ARCHIVE = "contract_archive"
    VERIFICATION_EVIDENCE = "verification_evidence"
    PHASE_GATE = "phase_gate"
    GATE_REVIEW_JOURNAL = "gate_review_journal"
    PHASE_FINALIZATION = "phase_finalization"
    PROJECT_RUN = "project_run"
    GIT = "git"


class ProjectAuditError(Exception):
    """Authoritative evidence is invalid or inconsistent; no projection is produced.

    Carries the typed ``source`` and a short, bounded, deterministic ``reason`` that may name a
    canonical identifier but never artifact contents, prompt text or provider output.
    """

    def __init__(self, source: AuditEvidenceSource, reason: str) -> None:
        self.source = source
        self.reason = reason
        super().__init__(f"project audit error ({source.value}): {reason}")


# --- Vocabulary --------------------------------------------------------------------------------


class Coverage(StrEnum):
    """How completely a quantity is evidenced across its eligible items.

    ``NONE_ELIGIBLE`` -- nothing was eligible, so zero is exact. ``COMPLETE`` -- every eligible
    item reported. ``PARTIAL`` -- some did. ``UNAVAILABLE`` -- recorded items exist and none
    reported. ``NOT_RECORDED`` -- every eligible item happened before (or outside) any durable
    record of it.
    """

    NONE_ELIGIBLE = "none_eligible"
    COMPLETE = "complete"
    PARTIAL = "partial"
    UNAVAILABLE = "unavailable"
    NOT_RECORDED = "not_recorded"


class TelemetryStatus(StrEnum):
    """Whether a durable telemetry surface recorded something that happened."""

    RECORDED = "recorded"
    NOT_RECORDED = "not_recorded"
    NOT_APPLICABLE = "not_applicable"


class InvocationFamily(StrEnum):
    """The identity family that owns an invocation; never inferred from its role."""

    PLANNING = "planning"
    TRANSACTION = "transaction"
    PHASE_GATE = "phase_gate"


class AuditStage(StrEnum):
    """Every recorded invocation stage, each from exactly one family."""

    TEST_AUTHORING = InvocationStage.TEST_AUTHORING.value
    IMPLEMENTATION = InvocationStage.IMPLEMENTATION.value
    REVIEW = InvocationStage.REVIEW.value
    ESCALATION_DECISION = InvocationStage.ESCALATION_DECISION.value
    PHASE_PLANNING = PlanningStage.PHASE_PLANNING.value
    CONTRACT_PLANNING = PlanningStage.CONTRACT_PLANNING.value
    JIT_REPLAN = PlanningStage.JIT_REPLAN.value
    GATE_REMEDIATION = PlanningStage.GATE_REMEDIATION.value
    SEMANTIC_REVIEW = "semantic_review"


class ProjectAuditStatus(StrEnum):
    NOT_STARTED = "not_started"
    IN_PROGRESS = "in_progress"
    COMPLETE = "complete"


class PhaseAuditStatus(StrEnum):
    COMPLETED = "completed"
    CURRENT = "current"
    PENDING = "pending"


class HaltKind(StrEnum):
    TRANSACTION_HALTED = K.TRANSACTION_HALTED.value
    TRANSACTION_ABORTED = K.TRANSACTION_ABORTED.value
    RETRY_EXHAUSTED = K.RETRY_EXHAUSTED.value
    RUN_HALTED = "run_halted"


class RepeatedWorkSource(StrEnum):
    TRANSACTION_ATTEMPT = "transaction_attempt"
    PLANNING_INVOCATION = "planning_invocation"
    GATE_ATTEMPT = "gate_attempt"


class RepeatedWorkCategory(StrEnum):
    """Why work was repeated, kept typed by its source; later views may group these."""

    REVIEW_REWORK = "review_rework"
    ESCALATION_RESUME = "escalation_resume"
    RETRY_UNATTRIBUTED = "retry_unattributed"
    ABANDONED_INVOCATION = "abandoned_invocation"
    PLANNING_FAILURE = "planning_failure"
    SUPERSEDED_PLANNING_CANDIDATE = "superseded_planning_candidate"
    GATE_COMMAND_FAILURE = "gate_command_failure"
    GATE_SEMANTIC_FAILURE = "gate_semantic_failure"
    GATE_AUTHORITY_VIOLATION = "gate_authority_violation"
    GATE_UNATTRIBUTED = "gate_unattributed"


# --- Value models ------------------------------------------------------------------------------


class _Model(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


def _coverage(observed: int, eligible: int, not_recorded: int) -> Coverage:
    if eligible == 0:
        return Coverage.NONE_ELIGIBLE
    if observed == eligible:
        return Coverage.COMPLETE
    if observed == 0:
        return Coverage.NOT_RECORDED if not_recorded == eligible else Coverage.UNAVAILABLE
    return Coverage.PARTIAL


class ObservedTotal(_Model):
    """A sum over only the eligible items that reported; ``None`` when none did."""

    observed_sum: int | None
    observed: int
    eligible: int
    not_recorded: int = 0

    @computed_field  # type: ignore[prop-decorator]
    @property
    def coverage(self) -> Coverage:
        return _coverage(self.observed, self.eligible, self.not_recorded)

    @classmethod
    def of(cls, values: Iterable[int | None], *, not_recorded: int = 0) -> ObservedTotal:
        collected = list(values)
        known = [v for v in collected if v is not None]
        return cls(
            observed_sum=sum(known) if known else None,
            observed=len(known),
            eligible=len(collected) + not_recorded,
            not_recorded=not_recorded,
        )


class ObservedSeconds(_Model):
    """Like :class:`ObservedTotal`, for seconds."""

    observed_seconds: float | None
    observed: int
    eligible: int
    not_recorded: int = 0

    @computed_field  # type: ignore[prop-decorator]
    @property
    def coverage(self) -> Coverage:
        return _coverage(self.observed, self.eligible, self.not_recorded)

    @classmethod
    def of(cls, values: Iterable[float | None], *, not_recorded: int = 0) -> ObservedSeconds:
        collected = list(values)
        known = [v for v in collected if v is not None]
        return cls(
            observed_seconds=math.fsum(known) if known else None,
            observed=len(known),
            eligible=len(collected) + not_recorded,
            not_recorded=not_recorded,
        )


class AuditInvocation(_Model):
    """One recorded agent invocation of any family, exactly as its journal evidences it.

    ``configured_*`` is the host's routing and ``reported_model`` is what the provider said; the
    two are never merged. Unreported values are ``None``.
    """

    family: InvocationFamily
    invocation_id: str
    role: AgentRole
    stage: AuditStage
    phase_id: PhaseId
    subphase_id: SubphaseId | None
    run_id: RunId | None
    attempt: int | None
    gate_attempt: int | None
    started: bool
    returned: bool
    started_at: datetime | None
    returned_at: datetime | None
    outcome: ExecutionOutcome | None
    returncode: int | None
    cause: FailureCause | None
    provider: str | None
    configured_model: str | None
    configured_effort: str | None
    reported_model: str | None
    quota_status: QuotaStatus | None
    elapsed_seconds: float | None
    input_tokens: int | None
    uncached_input_tokens: int | None
    cache_read_tokens: int | None
    cache_write_tokens: int | None
    output_tokens: int | None

    @computed_field  # type: ignore[prop-decorator]
    @property
    def abandoned(self) -> bool:
        return self.started and not self.returned


class UsageSummary(_Model):
    """Usage over a set of invocations; cache telemetry is descriptive only."""

    input_tokens: ObservedTotal
    uncached_input_tokens: ObservedTotal
    cache_read_tokens: ObservedTotal
    cache_write_tokens: ObservedTotal
    output_tokens: ObservedTotal
    elapsed: ObservedSeconds
    quota: Distribution


class InvocationGroup(_Model):
    """Counts and usage of the invocations sharing one key (``None`` = not reported)."""

    key: str | None
    invocations: int
    recorded: int
    not_recorded: int
    started: int
    returned: int
    succeeded: int
    failed: int
    blocked: int
    abandoned: int
    usage: UsageSummary


class InvocationSummary(_Model):
    """Aggregate views; configured and reported model identity stay separate."""

    total: InvocationGroup
    by_family: tuple[InvocationGroup, ...]
    by_role: tuple[InvocationGroup, ...]
    by_stage: tuple[InvocationGroup, ...]
    by_provider: tuple[InvocationGroup, ...]
    by_configured_model: tuple[InvocationGroup, ...]
    by_configured_effort: tuple[InvocationGroup, ...]
    by_reported_model: tuple[InvocationGroup, ...]


class PlanningAudit(_Model):
    """Project-level planning from ``planning/invocations.jsonl``, never from child journals.

    An unmatched ``STARTED`` is abandoned or incomplete evidence: counted as started, never as
    returned, successful or failed.
    """

    journal: TelemetryStatus
    unmatched_started: int
    total: InvocationGroup
    by_stage: tuple[InvocationGroup, ...]


class RetryAudit(_Model):
    """One ``RETRY_AUTHORIZED`` decision and the typed authority that granted it."""

    attempt: int
    role: AgentRole | None
    cause: FailureCause | None
    authority: RetryAuthorityKind | None
    executed: bool


class HaltAudit(_Model):
    kind: HaltKind
    attempt: int | None
    cause: FailureCause | None
    stop_reason: StopReason | None


class AttemptElapsed(_Model):
    attempt: int
    started_at: datetime | None
    finished_at: datetime | None
    seconds: float | None


class SubphaseElapsed(_Model):
    wall_clock_seconds: float | None
    journal_span_seconds: float | None
    attempts: tuple[AttemptElapsed, ...]
    invocations: ObservedSeconds


class TestAudit(_Model):
    """Structured test and verification evidence; executed test counts are not persisted."""

    __test__ = False

    acceptance_tests: int | None
    acceptance_tests_by_expectation: dict[TestExpectation, int]
    verification_commands: int | None
    verification_runs: int
    verification_failures: int
    verification_failures_before_success: int | None
    final_verification_passed: bool | None
    final_verification_commands_run: int | None


class RepositoryAudit(_Model):
    """The accepted change of one completed Sub-phase, measured from retained Git objects."""

    base_commit: str
    test_commit: str
    accepted_commit: str
    test_change: RepositoryChange
    implementation_change: RepositoryChange
    accepted_change: RepositoryChange
    test_paths: tuple[str, ...]
    implementation_paths: tuple[str, ...]


class SubphaseAudit(_Model):
    """One attempted Sub-phase transaction."""

    phase_id: PhaseId
    subphase_id: SubphaseId
    run_id: RunId
    contract_digest: str
    terminal_state: WorkflowState
    completion_recorded: bool
    completed: bool
    accepted_commit: str | None
    attempts_observed: int
    final_attempt: int | None
    first_pass: bool
    review_rework_count: int
    retry_count: int
    retries: tuple[RetryAudit, ...]
    resumed_attempts: int
    abandoned_invocations: int
    contract_planning_invocations: int
    planner_invocations: int
    test_authoring_invocations: int
    implementer_invocations: int
    reviewer_invocations: int
    escalation_invocations: int
    baseline_verification_runs: int
    failure_causes: dict[FailureCause, int]
    stop_reasons: dict[StopReason, int]
    halts: tuple[HaltAudit, ...]
    human_intervention_events: int
    elapsed: SubphaseElapsed
    usage: UsageSummary
    tests: TestAudit
    repository: RepositoryAudit | None
    transaction_metrics: SubphaseMetrics | None


class RepeatedWork(_Model):
    """One unit of repeated work, attributed only where typed evidence names its cause."""

    source: RepeatedWorkSource
    category: RepeatedWorkCategory
    cause: FailureCause | None
    phase_id: PhaseId
    subphase_id: SubphaseId | None
    run_id: RunId | None
    attempt: int | None
    gate_attempt: int | None
    gate_execution_failure: PhaseGateExecutionFailure | None
    invocation_id: str | None


class GateAttemptAudit(_Model):
    """One numbered gate attempt; failed and execution-failed attempts stay in the audit."""

    gate_attempt: int
    basis_commit: str | None
    basis_run_id: RunId | None
    basis_rule: PhaseGateBasisRule | None
    configured_command_count: int | None
    commands_run: int | None
    deterministic_passed: bool | None
    outcome: PhaseGateVerdict | None
    review_verdict: PhaseGateVerdict | None
    execution_failures: tuple[PhaseGateExecutionFailure, ...]
    authority_violation: bool
    remediation_subphase_id: SubphaseId | None
    semantic_review: TelemetryStatus
    semantic_review_invocations: int
    semantic_review_not_recorded: int


class PhaseGateAudit(_Model):
    attempts: tuple[GateAttemptAudit, ...]
    attempt_count: int
    passed: bool
    final_outcome: PhaseGateVerdict | None
    final_basis_commit: str | None
    remediation_count: int
    event_counts: dict[PhaseGateEventKind, int]
    semantic_review: InvocationGroup


class FinalizationAudit(_Model):
    """The Phase's durable finalization, used as an index; metrics still come from evidence."""

    identity: str
    final_repository_basis_commit: str
    gate_attempt: int
    subphases: tuple[FinalizedSubphase, ...]


class RepositoryTotals(_Model):
    files_changed: ObservedTotal
    lines_added: ObservedTotal
    lines_deleted: ObservedTotal
    binary_files_changed: ObservedTotal


class PhaseAudit(_Model):
    phase_id: PhaseId
    status: PhaseAuditStatus
    subphase_ids: tuple[SubphaseId, ...]
    subphases_attempted: int
    subphases_completed: int
    first_pass_subphases: int
    review_rework_count: int
    retry_count: int
    invocations_by_family: dict[InvocationFamily, int]
    gate: PhaseGateAudit | None
    finalization: FinalizationAudit | None
    repository: RepositoryTotals


class ReservationAudit(_Model):
    phase_id: PhaseId
    subphase_id: SubphaseId
    transaction_run_id: RunId
    reserved_at: datetime


class ProjectRunAudit(_Model):
    project_run_id: str
    policy_digest: str
    max_subphases: int
    started_at: datetime
    deadline_at: datetime
    reservations: tuple[ReservationAudit, ...]
    stop_disposition: AutonomousRunDisposition | None
    stopped_at: datetime | None
    elapsed_seconds: float | None
    event_counts: dict[ProjectRunEventKind, int]


class ActiveUnitAudit(_Model):
    phase_id: PhaseId
    subphase_id: SubphaseId
    run_id: RunId
    contract_digest: str
    attempted: bool
    terminal_state: WorkflowState | None


class ProjectAudit(_Model):
    project_id: str | None
    master_plan_digest: str | None
    status: ProjectAuditStatus
    phase_gate_status: PhaseGateStatus | None
    phases_planned: int
    completed_phases: tuple[PhaseId, ...]
    current_phase: PhaseId | None
    current_subphase: SubphaseId | None
    active_unit: ActiveUnitAudit | None
    subphases_attempted: int
    subphases_completed: int
    first_pass_subphases: int
    review_rework_count: int
    retry_count: int
    project_runs: tuple[ProjectRunAudit, ...]
    final_stop: AutonomousRunDisposition | None
    repository: RepositoryTotals


class EvidenceCoverage(_Model):
    planning_journal: TelemetryStatus
    transaction_journals: int
    semantic_reviews_recorded: int
    semantic_reviews_not_recorded: int
    finalizations: int
    completed_phases_without_finalization: int
    project_runs: int
    git_basis_run_id: RunId | None
    unavailable: dict[str, str]


class ProjectAuditProjection(_Model):
    """The complete, versioned audit projection of one project."""

    projection_version: int
    project: ProjectAudit
    phases: tuple[PhaseAudit, ...]
    subphases: tuple[SubphaseAudit, ...]
    planning: PlanningAudit
    invocations: tuple[AuditInvocation, ...]
    invocation_summary: InvocationSummary
    repeated_work: tuple[RepeatedWork, ...]
    coverage: EvidenceCoverage


# --- Small helpers -----------------------------------------------------------------------------


def _sorted_counts[T: str](counter: Mapping[T, int]) -> dict[T, int]:
    return dict(sorted(counter.items(), key=lambda item: str(item[0])))


def _seconds(start: datetime | None, end: datetime | None) -> float | None:
    if start is None or end is None or end < start:
        return None
    return (end - start).total_seconds()


@dataclass(frozen=True, slots=True)
class _InvocationEvidence:
    """The STARTED / RETURNED facts of one invocation, from any family's journal."""

    started_at: datetime | None
    returned_at: datetime | None
    outcome: ExecutionOutcome | None
    returncode: int | None
    cause: FailureCause | None
    provider: str | None
    configured_model: str | None
    configured_effort: str | None
    usage: InvocationUsage | None


def _row(
    evidence: _InvocationEvidence,
    *,
    family: InvocationFamily,
    invocation_id: str,
    role: AgentRole,
    stage: AuditStage,
    phase_id: PhaseId,
    subphase_id: SubphaseId | None = None,
    run_id: RunId | None = None,
    attempt: int | None = None,
    gate_attempt: int | None = None,
) -> AuditInvocation:
    usage = evidence.usage
    reported = usage.reported if usage is not None else None
    return AuditInvocation(
        family=family,
        invocation_id=invocation_id,
        role=role,
        stage=stage,
        phase_id=phase_id,
        subphase_id=subphase_id,
        run_id=run_id,
        attempt=attempt,
        gate_attempt=gate_attempt,
        started=evidence.started_at is not None,
        returned=evidence.outcome is not None,
        started_at=evidence.started_at,
        returned_at=evidence.returned_at,
        outcome=evidence.outcome,
        returncode=evidence.returncode,
        cause=evidence.cause,
        provider=usage.provider if usage is not None else evidence.provider,
        configured_model=(usage.configured_model if usage is not None else None)
        or evidence.configured_model,
        configured_effort=(usage.configured_effort if usage is not None else None)
        or evidence.configured_effort,
        reported_model=reported.reported_model if reported is not None else None,
        quota_status=usage.quota_status if usage is not None else None,
        elapsed_seconds=usage.elapsed_seconds if usage is not None else None,
        input_tokens=reported.input_tokens if reported is not None else None,
        uncached_input_tokens=reported.uncached_input_tokens if reported is not None else None,
        cache_read_tokens=reported.cache_read_tokens if reported is not None else None,
        cache_write_tokens=reported.cache_write_tokens if reported is not None else None,
        output_tokens=reported.output_tokens if reported is not None else None,
    )


def _usage_summary(rows: Sequence[AuditInvocation], *, not_recorded: int = 0) -> UsageSummary:
    def total(read: Callable[[AuditInvocation], int | None]) -> ObservedTotal:
        return ObservedTotal.of((read(r) for r in rows), not_recorded=not_recorded)

    return UsageSummary(
        input_tokens=total(lambda r: r.input_tokens),
        uncached_input_tokens=total(lambda r: r.uncached_input_tokens),
        cache_read_tokens=total(lambda r: r.cache_read_tokens),
        cache_write_tokens=total(lambda r: r.cache_write_tokens),
        output_tokens=total(lambda r: r.output_tokens),
        elapsed=ObservedSeconds.of((r.elapsed_seconds for r in rows), not_recorded=not_recorded),
        quota=Distribution.of(
            [r.quota_status.value if r.quota_status is not None else None for r in rows]
            + [None] * not_recorded
        ),
    )


def _group(
    key: str | None, rows: Sequence[AuditInvocation], not_recorded: int = 0
) -> InvocationGroup:
    returned = [r for r in rows if r.returned]
    return InvocationGroup(
        key=key,
        invocations=len(rows) + not_recorded,
        recorded=len(rows),
        not_recorded=not_recorded,
        started=sum(1 for r in rows if r.started),
        returned=len(returned),
        succeeded=sum(1 for r in returned if r.outcome is ExecutionOutcome.SUCCESS),
        failed=sum(1 for r in returned if r.outcome is ExecutionOutcome.FAILURE),
        blocked=sum(1 for r in returned if r.outcome is ExecutionOutcome.BLOCKED),
        abandoned=sum(1 for r in rows if r.abandoned),
        usage=_usage_summary(rows, not_recorded=not_recorded),
    )


@dataclass(frozen=True, slots=True)
class _NotRecorded:
    """Invocations known to have happened with no durable record (historical gate reviews)."""

    phase_id: PhaseId
    gate_attempt: int


def _groups_by(
    rows: Sequence[AuditInvocation],
    not_recorded: Sequence[_NotRecorded],
    key: Callable[[AuditInvocation], str | None],
    *,
    not_recorded_key: str | None,
    order: Sequence[str] | None = None,
) -> tuple[InvocationGroup, ...]:
    buckets: dict[str | None, list[AuditInvocation]] = defaultdict(list)
    for row in rows:
        buckets[key(row)].append(row)
    unrecorded: Counter[str | None] = Counter()
    if not_recorded:
        unrecorded[not_recorded_key] += len(not_recorded)
    keys = set(buckets) | set(unrecorded)
    if order is not None:
        ordered: list[str | None] = list(order)
    else:
        ordered = sorted((k for k in keys if k is not None), key=str)
        if None in keys:
            ordered.append(None)
    return tuple(_group(k, buckets.get(k, []), unrecorded.get(k, 0)) for k in ordered)


# --- Loading authoritative evidence ------------------------------------------------------------


def _fail(source: AuditEvidenceSource, reason: str) -> ProjectAuditError:
    return ProjectAuditError(source, reason)


def _load_master(project_root: Path) -> MasterPlan | None:
    try:
        return load_frozen_master_plan(project_root)
    except (PlanningStoreError, ValidationError, ValueError, OSError) as exc:
        raise _fail(AuditEvidenceSource.MASTER_PLAN, "the master plan is unreadable") from exc


def _load_cursor(project_root: Path, runtime_dir: Path) -> ProjectCursor | None:
    try:
        return load_project_cursor(project_root, runtime_dir)
    except (ProjectCursorStoreError, ValidationError, ValueError, OSError) as exc:
        raise _fail(AuditEvidenceSource.PROJECT_CURSOR, "the project cursor is invalid") from exc


@dataclass(frozen=True, slots=True)
class _Unit:
    phase_id: PhaseId
    subphase_id: SubphaseId
    run_id: RunId
    contract_digest: str
    completion_recorded: bool


def _cursor_units(cursor: ProjectCursor | None) -> tuple[_Unit, ...]:
    if cursor is None:
        return ()
    units = [
        _Unit(e.phase_id, e.subphase_id, e.run_id, e.contract_digest, True)
        for e in cursor.completed_subphases
    ]
    active = cursor.active_contract
    if active is not None:
        units.append(
            _Unit(
                active.phase_id,
                active.subphase_id,
                active.transaction_run_id,
                active.contract_digest,
                False,
            )
        )
    return tuple(units)


@dataclass(frozen=True, slots=True)
class _Transaction:
    unit: _Unit
    runtime_dir: Path
    events: tuple[LockstepEvent, ...]
    state: WorkflowState
    metrics: SubphaseMetrics | None


def _load_transaction(runtime_dir: Path, unit: _Unit) -> _Transaction | None:
    txn_dir = transaction_runtime_dir(runtime_dir, unit.run_id)
    journal = txn_dir / _JOURNAL_NAME
    where = f"transaction {unit.run_id.root}"
    source = AuditEvidenceSource.TRANSACTION_JOURNAL
    if journal.is_symlink() or txn_dir.is_symlink():
        raise _fail(source, f"{where} storage must not be a symlink")
    if not journal.exists():
        return None
    try:
        events = read_events(journal)
        snapshot = load_verified_state(txn_dir / _STATE_NAME, journal)
    except (JournalIntegrityError, StateConsistencyError, StatePersistenceError, OSError) as exc:
        raise _fail(source, f"{where} journal or state is invalid") from exc
    if not events or snapshot is None:
        raise _fail(source, f"{where} journal is empty")
    if events[0].run_id != unit.run_id:
        raise _fail(source, f"{where} journal names another run")
    for event in events:
        if isinstance(event, ExecutionEvent) and (
            (event.phase_id is not None and event.phase_id != unit.phase_id)
            or (event.subphase_id is not None and event.subphase_id != unit.subphase_id)
        ):
            raise _fail(source, f"{where} journal names another sub-phase")
    try:
        metrics = project_run_metrics(events)
    except UnsupportedJournalError as exc:
        raise _fail(source, f"{where} journal cannot be projected") from exc
    if len(metrics.subphases) > 1:  # pragma: no cover - project_run_metrics refuses this
        raise _fail(source, f"{where} journal attempts more than one sub-phase")
    return _Transaction(
        unit=unit,
        runtime_dir=txn_dir,
        events=tuple(events),
        state=snapshot.workflow_state,
        metrics=metrics.subphases[0] if metrics.subphases else None,
    )


def _require_no_orphan_transactions(runtime_dir: Path, units: Sequence[_Unit]) -> int:
    root = Path(runtime_dir) / _TRANSACTIONS_DIR_NAME
    if not root.is_dir():
        return 0
    known = {u.run_id.root for u in units}
    journals = sorted(child.name for child in root.iterdir() if (child / _JOURNAL_NAME).exists())
    orphans = [name for name in journals if name not in known]
    if orphans:
        raise _fail(
            AuditEvidenceSource.TRANSACTION_JOURNAL,
            f"transaction journal {orphans[0]} belongs to no cursor unit",
        )
    return len(journals)


def _retry_authorities(txn: _Transaction) -> dict[int, RetryAuthorityKind]:
    """The typed authority of every retry this transaction durably recorded, by its attempt."""
    source = AuditEvidenceSource.RETRY_EVIDENCE
    where = f"transaction {txn.unit.run_id.root}"
    checkpoints: list[RetryCheckpoint] = []
    try:
        pending = load_retry_checkpoint(txn.runtime_dir)
        if pending is not None:
            checkpoints.append(pending)
        claim_path = resume_claim_path(txn.runtime_dir)
        if claim_path.exists():
            checkpoints.append(
                ResumeClaim.model_validate_json(claim_path.read_text(encoding="utf-8")).checkpoint
            )
        settlements = txn.runtime_dir / _SETTLEMENTS_DIR
        if settlements.is_dir():
            for path in sorted(settlements.iterdir(), key=lambda p: p.name):
                if path.suffix != ".json":
                    continue
                settled = ResumeSettlement.model_validate_json(path.read_text(encoding="utf-8"))
                checkpoints.append(settled.claim.checkpoint)
                if settled.next_checkpoint is not None:
                    checkpoints.append(settled.next_checkpoint)
    except (
        RetryCheckpointStoreError,
        ResumeStoreError,
        RetryProtocolError,
        ValidationError,
        ValueError,
        OSError,
    ) as exc:
        raise _fail(source, f"{where} retry evidence is invalid") from exc
    authorities: dict[int, RetryAuthorityKind] = {}
    for checkpoint in checkpoints:
        nxt = checkpoint.next_attempt_state
        if nxt is None:
            continue
        attempt = nxt.current_attempt.root
        kind = checkpoint.authority.kind
        if authorities.setdefault(attempt, kind) is not kind:
            raise _fail(source, f"{where} retry evidence disagrees about attempt {attempt}")
    return authorities


def _contract(project_root: Path, runtime_dir: Path, unit: _Unit) -> SubphaseContract | None:
    where = f"sub-phase {unit.phase_id.root}/{unit.subphase_id.root}"
    try:
        if unit.completion_recorded:
            return load_archived_subphase_contract(
                project_root,
                runtime_dir,
                phase_id=unit.phase_id,
                subphase_id=unit.subphase_id,
                contract_digest=unit.contract_digest,
            )
        active = load_active_subphase_contract(project_root, runtime_dir)
    except (PlanningStoreError, ValidationError, ValueError, OSError) as exc:
        raise _fail(AuditEvidenceSource.CONTRACT_ARCHIVE, f"{where} contract is invalid") from exc
    if active is None:
        return None
    if contract_digest(active) != unit.contract_digest:
        raise _fail(
            AuditEvidenceSource.CONTRACT_ARCHIVE, f"{where} active contract is not the bound one"
        )
    return active


# --- Invocation rows ---------------------------------------------------------------------------


def _transaction_rows(txn: _Transaction) -> tuple[AuditInvocation, ...]:
    """Every invocation of one journal, merged by ``invocation_id`` exactly as Phase 10 does."""
    started: dict[str, ExecutionEvent] = {}
    returned: dict[str, ExecutionEvent] = {}
    order: list[str] = []
    for event in txn.events:
        if not isinstance(event, ExecutionEvent) or event.invocation_id is None:
            continue
        key = event.invocation_id.root
        if event.kind is K.INVOCATION_STARTED:
            started.setdefault(key, event)
        elif event.kind is K.INVOCATION_RETURNED:
            returned.setdefault(key, event)
        else:
            continue
        if key not in order:
            order.append(key)
    rows: list[AuditInvocation] = []
    for key in order:
        first = started.get(key) or returned[key]
        back = returned.get(key)
        assert first.role is not None and first.stage is not None and first.attempt is not None
        rows.append(
            _row(
                _InvocationEvidence(
                    started_at=started[key].occurred_at if key in started else None,
                    returned_at=back.occurred_at if back is not None else None,
                    outcome=back.outcome if back is not None else None,
                    returncode=back.returncode if back is not None else None,
                    cause=back.cause if back is not None else None,
                    provider=None,
                    configured_model=None,
                    configured_effort=None,
                    usage=back.usage if back is not None else None,
                ),
                family=InvocationFamily.TRANSACTION,
                invocation_id=key,
                role=first.role,
                stage=AuditStage(first.stage.value),
                phase_id=txn.unit.phase_id,
                subphase_id=txn.unit.subphase_id,
                run_id=txn.unit.run_id,
                attempt=first.attempt.root,
            )
        )
    return tuple(rows)


def _paired[EventT](
    events: Sequence[EventT],
    *,
    invocation_id: Callable[[EventT], str],
    is_started: Callable[[EventT], bool],
    source: AuditEvidenceSource,
) -> list[tuple[str, EventT | None, EventT | None]]:
    """Pair STARTED / RETURNED by invocation id, refusing a duplicate or a reversed pair."""
    order: list[str] = []
    started: dict[str, EventT] = {}
    returned: dict[str, EventT] = {}
    for event in events:
        key = invocation_id(event)
        if key not in order:
            order.append(key)
        if is_started(event):
            if key in started or key in returned:
                raise _fail(source, "an invocation was started twice or after its return")
            started[key] = event
        else:
            if key in returned:
                raise _fail(source, "an invocation returned twice")
            returned[key] = event
    return [(key, started.get(key), returned.get(key)) for key in order]


def _planning_rows(runtime_dir: Path, cursor: ProjectCursor | None) -> tuple[AuditInvocation, ...]:
    source = AuditEvidenceSource.PLANNING_JOURNAL
    try:
        events = read_planning_invocation_events(runtime_dir)
    except PlanningInvocationError as exc:
        raise _fail(source, "the planning journal is invalid") from exc
    if cursor is not None and any(e.identity.project_id != cursor.project_id for e in events):
        raise _fail(source, "the planning journal names another project")
    rows: list[AuditInvocation] = []
    for key, start, back in _paired(
        events,
        invocation_id=lambda e: e.identity.invocation_id.root,
        is_started=lambda e: e.kind is PlanningInvocationEventKind.STARTED,
        source=source,
    ):
        anchor = start or back
        assert anchor is not None
        if start is not None and back is not None and start.identity != back.identity:
            raise _fail(source, "an invocation changed identity between its events")
        identity = anchor.identity
        rows.append(
            _row(
                _InvocationEvidence(
                    started_at=start.occurred_at if start is not None else None,
                    returned_at=back.occurred_at if back is not None else None,
                    outcome=back.outcome if back is not None else None,
                    returncode=back.returncode if back is not None else None,
                    cause=back.cause if back is not None else None,
                    provider=anchor.provider,
                    configured_model=anchor.configured_model,
                    configured_effort=anchor.configured_effort,
                    usage=back.usage if back is not None else None,
                ),
                family=InvocationFamily.PLANNING,
                invocation_id=key,
                role=identity.role,
                stage=AuditStage(identity.stage.value),
                phase_id=identity.phase_id,
                subphase_id=identity.target_subphase_id,
            )
        )
    return tuple(rows)


def _gate_review_rows(
    runtime_dir: Path, cursor: ProjectCursor | None, phase_id: PhaseId
) -> tuple[AuditInvocation, ...]:
    source = AuditEvidenceSource.GATE_REVIEW_JOURNAL
    try:
        events = read_phase_gate_review_invocation_events(runtime_dir, phase_id)
    except PhaseGateReviewInvocationError as exc:
        raise _fail(source, f"the phase {phase_id.root} gate review journal is invalid") from exc
    if cursor is not None and any(e.identity.project_id != cursor.project_id for e in events):
        raise _fail(source, "the gate review journal names another project")
    rows: list[AuditInvocation] = []
    for key, start, back in _paired(
        events,
        invocation_id=lambda e: e.identity.invocation_id.root,
        is_started=lambda e: e.kind is PhaseGateReviewInvocationEventKind.STARTED,
        source=source,
    ):
        anchor = start or back
        assert anchor is not None
        if start is not None and back is not None and start.identity != back.identity:
            raise _fail(source, "an invocation changed identity between its events")
        identity = anchor.identity
        rows.append(
            _row(
                _InvocationEvidence(
                    started_at=start.occurred_at if start is not None else None,
                    returned_at=back.occurred_at if back is not None else None,
                    outcome=back.outcome if back is not None else None,
                    returncode=back.returncode if back is not None else None,
                    cause=back.cause if back is not None else None,
                    provider=anchor.provider,
                    configured_model=anchor.configured_model,
                    configured_effort=anchor.configured_effort,
                    usage=back.usage if back is not None else None,
                ),
                family=InvocationFamily.PHASE_GATE,
                invocation_id=key,
                role=identity.role,
                stage=AuditStage(identity.stage.value),
                phase_id=identity.phase_id,
                gate_attempt=identity.gate_attempt,
            )
        )
    return tuple(rows)


# --- Git ---------------------------------------------------------------------------------------


def _frozen_test_commit(txn: _Transaction) -> str:
    where = f"transaction {txn.unit.run_id.root}"
    commits = {
        event.detail
        for event in txn.events
        if isinstance(event, ExecutionEvent)
        and event.kind is K.TESTS_FROZEN
        and event.outcome is ExecutionOutcome.SUCCESS
    }
    if len(commits) != 1:
        raise _fail(
            AuditEvidenceSource.TRANSACTION_JOURNAL,
            f"{where} has no single frozen-test commit",
        )
    (commit,) = commits
    if commit is None or not _GIT_OBJECT_ID.match(commit):
        raise _fail(
            AuditEvidenceSource.TRANSACTION_JOURNAL,
            f"{where} frozen-test commit is not an object id",
        )
    return commit


def _repository_audits(
    root: Path | None,
    completed: Sequence[_Transaction],
    finalized: Mapping[RunId, str],
) -> dict[RunId, RepositoryAudit]:
    audits: dict[RunId, RepositoryAudit] = {}
    if not completed:
        return audits
    if root is None or not root.is_dir():
        raise _fail(AuditEvidenceSource.GIT, "the retained accepted basis worktree is missing")
    previous: str | None = None
    for txn in completed:
        run = txn.unit.run_id
        where = f"sub-phase {txn.unit.phase_id.root}/{txn.unit.subphase_id.root}"
        test_commit = _frozen_test_commit(txn)
        try:
            accepted = branch_commit(root, transaction_branch(run))
            if accepted is None:
                raise _fail(AuditEvidenceSource.GIT, f"{where} has no accepted run branch")
            if not is_ancestor(root, test_commit, accepted):
                raise _fail(
                    AuditEvidenceSource.GIT, f"{where} frozen tests are not in its accepted history"
                )
            base = commit_parent(root, test_commit)
            if previous is not None and base != previous:
                raise _fail(
                    AuditEvidenceSource.GIT,
                    f"{where} is not rooted at the previous accepted commit",
                )
            if run in finalized and finalized[run] != accepted:
                raise _fail(
                    AuditEvidenceSource.GIT,
                    f"{where} accepted commit conflicts with its phase finalization",
                )
            audits[run] = RepositoryAudit(
                base_commit=base,
                test_commit=test_commit,
                accepted_commit=accepted,
                test_change=measure_repository_change(root, base, test_commit),
                implementation_change=measure_repository_change(root, test_commit, accepted),
                accepted_change=measure_repository_change(root, base, accepted),
                test_paths=changed_paths_between(root, base, test_commit),
                implementation_paths=changed_paths_between(root, test_commit, accepted),
            )
        except GitCommandError as exc:
            raise _fail(
                AuditEvidenceSource.GIT, f"{where} accepted commits are unreadable"
            ) from exc
        previous = accepted
    return audits


def _repository_totals(audits: Sequence[RepositoryAudit | None]) -> RepositoryTotals:
    changes = [a.accepted_change if a is not None else None for a in audits]

    def total(read: Callable[[RepositoryChange], int]) -> ObservedTotal:
        return ObservedTotal.of(read(c) if c is not None else None for c in changes)

    return RepositoryTotals(
        files_changed=total(lambda c: c.files_changed),
        lines_added=total(lambda c: c.lines_added),
        lines_deleted=total(lambda c: c.lines_deleted),
        binary_files_changed=total(lambda c: c.binary_files_changed),
    )


# --- Sub-phase rows ----------------------------------------------------------------------------


def _execution_events(txn: _Transaction) -> list[ExecutionEvent]:
    return [e for e in txn.events if isinstance(e, ExecutionEvent)]


def _attempt_elapsed(
    events: Sequence[ExecutionEvent], attempts: Iterable[int]
) -> tuple[AttemptElapsed, ...]:
    rows: list[AttemptElapsed] = []
    for attempt in sorted(attempts):
        starts = [
            e.occurred_at
            for e in events
            if e.kind in (K.INVOCATION_STARTED, K.RESUME_STARTED)
            and e.attempt is not None
            and e.attempt.root == attempt
        ]
        ends = [
            e.occurred_at
            for e in events
            if e.kind is K.INVOCATION_RETURNED
            and e.attempt is not None
            and e.attempt.root == attempt
        ]
        start = min(starts) if starts else None
        end = max(ends) if ends else None
        rows.append(
            AttemptElapsed(
                attempt=attempt, started_at=start, finished_at=end, seconds=_seconds(start, end)
            )
        )
    return tuple(rows)


def _tests_audit(
    txn: _Transaction, contract: SubphaseContract | None, final_attempt: int | None
) -> TestAudit:
    events = _execution_events(txn)
    runs = [e for e in events if e.kind is K.VERIFICATION_COMPLETED]
    failures = sum(1 for e in runs if e.outcome is ExecutionOutcome.FAILURE)
    first_success = next(
        (i for i, e in enumerate(runs) if e.outcome is ExecutionOutcome.SUCCESS), None
    )
    report = None
    if final_attempt is not None:
        try:
            report = load_verification_report(
                txn.runtime_dir,
                phase_id=txn.unit.phase_id,
                subphase_id=txn.unit.subphase_id,
                attempt=AttemptNumber.model_validate(final_attempt),
            )
        except (EvidenceStoreError, ValidationError, ValueError, OSError) as exc:
            raise _fail(
                AuditEvidenceSource.VERIFICATION_EVIDENCE,
                f"transaction {txn.unit.run_id.root} verification report is invalid",
            ) from exc
    expectations: Counter[TestExpectation] = Counter(
        spec.expectation for spec in (contract.tests if contract is not None else ())
    )
    return TestAudit(
        acceptance_tests=len(contract.tests) if contract is not None else None,
        acceptance_tests_by_expectation=_sorted_counts(expectations),
        verification_commands=(
            len(contract.verification_commands) if contract is not None else None
        ),
        verification_runs=len(runs),
        verification_failures=failures,
        verification_failures_before_success=first_success,
        final_verification_passed=report.passed if report is not None else None,
        final_verification_commands_run=len(report.commands) if report is not None else None,
    )


def _subphase_audit(
    project_root: Path,
    runtime_dir: Path,
    txn: _Transaction,
    rows: Sequence[AuditInvocation],
    planning_rows: Sequence[AuditInvocation],
    repository: RepositoryAudit | None,
) -> SubphaseAudit:
    unit = txn.unit
    events = _execution_events(txn)
    metrics = txn.metrics
    complete = txn.state is WorkflowState.SUBPHASE_COMPLETE
    if unit.completion_recorded and not complete:
        raise _fail(
            AuditEvidenceSource.TRANSACTION_JOURNAL,
            f"transaction {unit.run_id.root} is recorded complete but its journal disagrees",
        )
    completed = unit.completion_recorded and complete

    attempts = {
        e.attempt.root
        for e in events
        if e.kind in (K.INVOCATION_STARTED, K.RESUME_STARTED) and e.attempt is not None
    }
    authorities = _retry_authorities(txn)
    retries = tuple(
        RetryAudit(
            attempt=e.attempt.root,
            role=e.role,
            cause=e.cause,
            authority=authorities.get(e.attempt.root),
            executed=e.attempt.root in attempts,
        )
        for e in events
        if e.kind is K.RETRY_AUTHORIZED and e.attempt is not None
    )
    halts: list[HaltAudit] = [
        HaltAudit(
            kind=HaltKind(e.kind.value),
            attempt=e.attempt.root if e.attempt is not None else None,
            cause=e.cause,
            stop_reason=e.stop_reason,
        )
        for e in events
        if e.kind in _HALT_KINDS
    ]
    halts.extend(
        HaltAudit(kind=HaltKind.RUN_HALTED, attempt=None, cause=None, stop_reason=e.reason)
        for e in txn.events
        if isinstance(e, RunHaltedEvent)
    )
    stages = metrics.invocations_by_stage if metrics is not None else {}
    roles = metrics.invocations_by_role if metrics is not None else {}
    final_attempt = max(attempts) if attempts else None
    contract = _contract(project_root, runtime_dir, unit)
    times = [e.occurred_at for e in txn.events]

    return SubphaseAudit(
        phase_id=unit.phase_id,
        subphase_id=unit.subphase_id,
        run_id=unit.run_id,
        contract_digest=unit.contract_digest,
        terminal_state=txn.state,
        completion_recorded=unit.completion_recorded,
        completed=completed,
        accepted_commit=repository.accepted_commit if repository is not None else None,
        attempts_observed=metrics.executed_attempts if metrics is not None else 0,
        final_attempt=final_attempt,
        first_pass=completed and metrics is not None and metrics.first_pass,
        review_rework_count=sum(
            1 for e in events if e.kind is K.REVIEW_DECIDED and e.verdict is ReviewVerdict.REWORK
        ),
        retry_count=len(retries),
        retries=retries,
        resumed_attempts=sum(1 for e in events if e.kind is K.RESUME_STARTED),
        abandoned_invocations=sum(1 for r in rows if r.abandoned),
        contract_planning_invocations=sum(
            1
            for r in planning_rows
            if r.stage is AuditStage.CONTRACT_PLANNING
            and (r.phase_id, r.subphase_id) == (unit.phase_id, unit.subphase_id)
        ),
        planner_invocations=roles.get(AgentRole.PLANNER, 0),
        test_authoring_invocations=stages.get(InvocationStage.TEST_AUTHORING, 0),
        implementer_invocations=roles.get(AgentRole.IMPLEMENTER, 0),
        reviewer_invocations=roles.get(AgentRole.REVIEWER, 0),
        escalation_invocations=stages.get(InvocationStage.ESCALATION_DECISION, 0),
        baseline_verification_runs=metrics.baseline_verification_runs if metrics is not None else 0,
        failure_causes=dict(metrics.failure_causes) if metrics is not None else {},
        stop_reasons=dict(metrics.stop_reasons) if metrics is not None else {},
        halts=tuple(halts),
        human_intervention_events=sum(
            1
            for e in events
            if e.cause is FailureCause.HUMAN_REQUIRED_DECISION
            or e.stop_reason in _HUMAN_STOP_REASONS
        ),
        elapsed=SubphaseElapsed(
            wall_clock_seconds=metrics.wall_clock_seconds if metrics is not None else None,
            journal_span_seconds=_seconds(min(times), max(times)) if times else None,
            attempts=_attempt_elapsed(events, attempts),
            invocations=ObservedSeconds.of(r.elapsed_seconds for r in rows),
        ),
        usage=_usage_summary(rows),
        tests=_tests_audit(txn, contract, final_attempt),
        repository=repository,
        transaction_metrics=metrics,
    )


# --- Phase gates -------------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class _GateFacts:
    audit: PhaseGateAudit
    attempts: tuple[tuple[GateAttemptAudit, PhaseGateDecision | None], ...]
    not_recorded: tuple[_NotRecorded, ...]


def _gate_audit(
    runtime_dir: Path,
    phase_id: PhaseId,
    review_rows: Sequence[AuditInvocation],
) -> _GateFacts | None:
    source = AuditEvidenceSource.PHASE_GATE
    try:
        numbers = list_phase_gate_attempts(runtime_dir, phase_id)
        events = read_phase_gate_events(runtime_dir, phase_id)
        loaded = [
            (
                n,
                load_phase_gate_basis(runtime_dir, phase_id, n),
                load_phase_gate_evidence(runtime_dir, phase_id, n),
                load_phase_gate_decision(runtime_dir, phase_id, n),
                load_phase_gate_violation(runtime_dir, phase_id, n),
                load_remediation_receipt(runtime_dir, phase_id, n),
            )
            for n in numbers
        ]
    except PhaseGateError as exc:
        raise _fail(source, f"phase {phase_id.root} gate evidence is invalid") from exc
    if not numbers and not events and not review_rows:
        return None
    if any(e.phase_id != phase_id for e in events):
        raise _fail(source, f"phase {phase_id.root} gate journal names another phase")
    known = set(numbers)
    if any(e.gate_attempt not in known for e in events) or any(
        r.gate_attempt not in known for r in review_rows
    ):
        raise _fail(source, f"phase {phase_id.root} gate evidence names an unknown attempt")

    attempts: list[tuple[GateAttemptAudit, PhaseGateDecision | None]] = []
    missing: list[_NotRecorded] = []
    for n, basis, evidence, decision, violation, receipt in loaded:
        recorded = [r for r in review_rows if r.gate_attempt == n]
        reviewed = decision is not None and decision.review is not None
        if recorded:
            status = TelemetryStatus.RECORDED
        elif reviewed:
            status = TelemetryStatus.NOT_RECORDED
            missing.append(_NotRecorded(phase_id, n))
        elif any(
            e.gate_attempt == n and e.failure is PhaseGateExecutionFailure.REVIEW_FAILED
            for e in events
        ):
            # A review was attempted, but no durable record says whether a process launched.
            status = TelemetryStatus.NOT_RECORDED
        else:
            status = TelemetryStatus.NOT_APPLICABLE
        attempts.append(
            (
                GateAttemptAudit(
                    gate_attempt=n,
                    basis_commit=basis.commit if basis is not None else None,
                    basis_run_id=basis.basis_run_id if basis is not None else None,
                    basis_rule=basis.rule if basis is not None else None,
                    configured_command_count=(
                        evidence.configured_command_count if evidence is not None else None
                    ),
                    commands_run=len(evidence.commands) if evidence is not None else None,
                    deterministic_passed=evidence.passed if evidence is not None else None,
                    outcome=decision.outcome if decision is not None else None,
                    review_verdict=(
                        decision.review.verdict
                        if decision is not None and decision.review is not None
                        else None
                    ),
                    execution_failures=tuple(
                        e.failure for e in events if e.gate_attempt == n and e.failure is not None
                    ),
                    authority_violation=violation is not None,
                    remediation_subphase_id=(
                        receipt.outline.subphase_id if receipt is not None else None
                    ),
                    semantic_review=status,
                    semantic_review_invocations=len(recorded),
                    semantic_review_not_recorded=1 if reviewed and not recorded else 0,
                ),
                decision,
            )
        )
    final = attempts[-1][0] if attempts else None
    return _GateFacts(
        audit=PhaseGateAudit(
            attempts=tuple(a for a, _ in attempts),
            attempt_count=len(attempts),
            passed=final is not None and final.outcome is PhaseGateVerdict.PASS,
            final_outcome=final.outcome if final is not None else None,
            final_basis_commit=final.basis_commit if final is not None else None,
            remediation_count=sum(1 for a, _ in attempts if a.remediation_subphase_id is not None),
            event_counts=_sorted_counts(Counter(e.kind for e in events)),
            semantic_review=_group(AuditStage.SEMANTIC_REVIEW.value, review_rows, len(missing)),
        ),
        attempts=tuple(attempts),
        not_recorded=tuple(missing),
    )


def _gate_repeated_work(phase_id: PhaseId, facts: _GateFacts) -> list[RepeatedWork]:
    items: list[RepeatedWork] = []
    for (previous, decision), (current, _) in zip(facts.attempts, facts.attempts[1:], strict=False):
        failure: PhaseGateExecutionFailure | None = None
        cause: FailureCause | None = None
        if previous.authority_violation:
            category = RepeatedWorkCategory.GATE_AUTHORITY_VIOLATION
            cause = FailureCause.AUTHORITY_VIOLATION
            failure = PhaseGateExecutionFailure.AUTHORITY_VIOLATION
        elif decision is not None and decision.outcome is PhaseGateVerdict.FAIL:
            category = (
                RepeatedWorkCategory.GATE_COMMAND_FAILURE
                if not decision.deterministic_passed
                else RepeatedWorkCategory.GATE_SEMANTIC_FAILURE
            )
        else:
            category = RepeatedWorkCategory.GATE_UNATTRIBUTED
        items.append(
            RepeatedWork(
                source=RepeatedWorkSource.GATE_ATTEMPT,
                category=category,
                cause=cause,
                phase_id=phase_id,
                subphase_id=None,
                run_id=None,
                attempt=None,
                gate_attempt=current.gate_attempt,
                gate_execution_failure=failure,
                invocation_id=None,
            )
        )
    return items


# --- Repeated work ----------------------------------------------------------------------------

_TARGETED_PLANNING = (AuditStage.CONTRACT_PLANNING, AuditStage.GATE_REMEDIATION)


def _planning_repeated_work(rows: Sequence[AuditInvocation]) -> list[RepeatedWork]:
    items: list[RepeatedWork] = []
    last: dict[tuple[str, str, str | None], AuditInvocation] = {}
    for row in rows:
        if row.stage not in _TARGETED_PLANNING:
            continue
        key = (
            row.stage.value,
            row.phase_id.root,
            row.subphase_id.root if row.subphase_id else None,
        )
        previous = last.get(key)
        last[key] = row
        if previous is None:
            continue
        cause: FailureCause | None = None
        if not previous.returned:
            category = RepeatedWorkCategory.ABANDONED_INVOCATION
        elif previous.outcome is ExecutionOutcome.SUCCESS:
            category = RepeatedWorkCategory.SUPERSEDED_PLANNING_CANDIDATE
        else:
            category = RepeatedWorkCategory.PLANNING_FAILURE
            cause = previous.cause
        items.append(
            RepeatedWork(
                source=RepeatedWorkSource.PLANNING_INVOCATION,
                category=category,
                cause=cause,
                phase_id=row.phase_id,
                subphase_id=row.subphase_id,
                run_id=None,
                attempt=None,
                gate_attempt=None,
                gate_execution_failure=None,
                invocation_id=row.invocation_id,
            )
        )
    return items


def _transaction_repeated_work(row: SubphaseAudit) -> list[RepeatedWork]:
    categories = {
        RetryAuthorityKind.REVIEW_REWORK: RepeatedWorkCategory.REVIEW_REWORK,
        RetryAuthorityKind.ESCALATION_RESUME: RepeatedWorkCategory.ESCALATION_RESUME,
    }
    return [
        RepeatedWork(
            source=RepeatedWorkSource.TRANSACTION_ATTEMPT,
            category=(
                categories[retry.authority]
                if retry.authority is not None
                else RepeatedWorkCategory.RETRY_UNATTRIBUTED
            ),
            cause=retry.cause,
            phase_id=row.phase_id,
            subphase_id=row.subphase_id,
            run_id=row.run_id,
            attempt=retry.attempt,
            gate_attempt=None,
            gate_execution_failure=None,
            invocation_id=None,
        )
        for retry in row.retries
        if retry.executed
    ]


# --- Project runs and finalizations ------------------------------------------------------------


def _project_runs(runtime_dir: Path, cursor: ProjectCursor | None) -> tuple[ProjectRunAudit, ...]:
    audits: list[ProjectRunAudit] = []
    try:
        for run_id in list_project_runs(runtime_dir):
            record = load_project_run(runtime_dir, run_id)
            if record is None:
                raise _fail(
                    AuditEvidenceSource.PROJECT_RUN, f"project run {run_id.root} has no record"
                )
            if cursor is not None and record.project_id != cursor.project_id:
                raise _fail(AuditEvidenceSource.PROJECT_RUN, "a project run names another project")
            state = load_project_run_state(runtime_dir, run_id)
            events = read_project_run_events(runtime_dir, run_id)
            stop = state.stop
            audits.append(
                ProjectRunAudit(
                    project_run_id=run_id.root,
                    policy_digest=record.policy_digest,
                    max_subphases=record.policy.max_subphases,
                    started_at=record.started_at,
                    deadline_at=record.deadline_at,
                    reservations=tuple(
                        ReservationAudit(
                            phase_id=r.phase_id,
                            subphase_id=r.subphase_id,
                            transaction_run_id=r.transaction_run_id,
                            reserved_at=r.reserved_at,
                        )
                        for r in state.reservations
                    ),
                    stop_disposition=stop.disposition if stop is not None else None,
                    stopped_at=stop.stopped_at if stop is not None else None,
                    elapsed_seconds=(
                        _seconds(record.started_at, stop.stopped_at) if stop is not None else None
                    ),
                    event_counts=_sorted_counts(Counter(e.kind for e in events)),
                )
            )
    except AutonomousRunError as exc:
        raise _fail(AuditEvidenceSource.PROJECT_RUN, "project run evidence is invalid") from exc
    return tuple(audits)


def _finalization(
    runtime_dir: Path, cursor: ProjectCursor, phase_id: PhaseId
) -> PhaseContextFinalization | None:
    try:
        value = load_phase_context_finalization(runtime_dir, phase_id)
    except (PhaseContextFinalizationError, PhaseGateError, ValidationError, OSError) as exc:
        raise _fail(
            AuditEvidenceSource.PHASE_FINALIZATION,
            f"phase {phase_id.root} finalization is invalid",
        ) from exc
    if value is None:
        return None
    if (value.project_id, value.master_plan_digest, value.phase_id) != (
        cursor.project_id,
        cursor.master_plan_digest,
        phase_id,
    ):
        raise _fail(
            AuditEvidenceSource.PHASE_FINALIZATION,
            f"phase {phase_id.root} finalization belongs to another plan",
        )
    _require_finalization_agrees(runtime_dir, cursor, value)
    return value


def _require_finalization_agrees(
    runtime_dir: Path, cursor: ProjectCursor, value: PhaseContextFinalization
) -> None:
    """The finalization indexes the cursor history and the gate it crossed, exactly."""
    phase_id = value.phase_id
    where = f"phase {phase_id.root} finalization"
    recorded = [(e.subphase_id, e.run_id, e.contract_digest) for e in value.completed_subphases]
    history = [
        (e.subphase_id, e.run_id, e.contract_digest)
        for e in cursor.completed_subphases
        if e.phase_id == phase_id
    ]
    if recorded != history:
        raise _fail(AuditEvidenceSource.PHASE_FINALIZATION, f"{where} disagrees with the cursor")
    gate = value.final_phase_gate
    attempt_dir = phase_gate_attempt_dir(runtime_dir, phase_id, gate.gate_attempt)
    try:
        decision_raw = (attempt_dir / "decision.json").read_bytes()
        basis_raw = (attempt_dir / "basis.json").read_bytes()
        decision = load_phase_gate_decision(runtime_dir, phase_id, gate.gate_attempt)
    except (OSError, PhaseGateError) as exc:
        raise _fail(AuditEvidenceSource.PHASE_FINALIZATION, f"{where} gate is unreadable") from exc
    if (
        decision is None
        or decision.outcome is not PhaseGateVerdict.PASS
        or decision.basis_commit != value.final_repository_basis_commit
        or hashlib.sha256(decision_raw).hexdigest() != gate.decision_sha256
        or hashlib.sha256(basis_raw).hexdigest() != gate.basis_sha256
    ):
        raise _fail(AuditEvidenceSource.PHASE_FINALIZATION, f"{where} disagrees with its gate")


def _require_known_gate_phases(runtime_dir: Path, phases: Sequence[PhaseId]) -> None:
    root = Path(runtime_dir) / "phase-gates"
    if not root.is_dir():
        return
    known = {p.root for p in phases}
    for name in sorted(child.name for child in root.iterdir() if _PHASE_DIR.match(child.name)):
        if name not in known:
            raise _fail(AuditEvidenceSource.PHASE_GATE, f"gate evidence for unknown phase {name}")


# --- The projection ----------------------------------------------------------------------------


def build_project_audit(project_root: Path, runtime_dir: Path) -> ProjectAuditProjection:
    """Project the whole project's durable evidence into a :class:`ProjectAuditProjection`.

    Read-only and deterministic. Needs only the project root and the runtime directory (and the
    Git objects reachable from the retained accepted basis worktree); no provider, adapter,
    credential, session or model call. Raises :class:`ProjectAuditError` for invalid or
    inconsistent authoritative evidence.
    """
    project_root, runtime_dir = Path(project_root), Path(runtime_dir)
    master = _load_master(project_root)
    cursor = _load_cursor(project_root, runtime_dir)
    if cursor is not None and master is None:
        raise _fail(AuditEvidenceSource.MASTER_PLAN, "a cursor exists without a frozen master plan")
    phases: tuple[PhaseId, ...] = tuple(p.phase_id for p in master.phases) if master else ()
    _require_known_gate_phases(runtime_dir, phases)

    units = _cursor_units(cursor)
    journal_count = _require_no_orphan_transactions(runtime_dir, units)
    transactions = [t for t in (_load_transaction(runtime_dir, u) for u in units) if t is not None]
    planning_rows = _planning_rows(runtime_dir, cursor)

    finalizations: dict[PhaseId, PhaseContextFinalization] = {}
    if cursor is not None:
        for phase_id in cursor.completed_phases:
            value = _finalization(runtime_dir, cursor, phase_id)
            if value is not None:
                finalizations[phase_id] = value
    finalized_commits = {
        s.run_id: s.accepted_commit for f in finalizations.values() for s in f.completed_subphases
    }

    completed_txns = [t for t in transactions if t.unit.completion_recorded]
    git_root = (
        transaction_worktree_path(runtime_dir, cursor.completed_subphases[-1].run_id)
        if cursor is not None and cursor.completed_subphases
        else None
    )
    repositories = _repository_audits(git_root, completed_txns, finalized_commits)

    transaction_rows: list[AuditInvocation] = []
    subphases: list[SubphaseAudit] = []
    for txn in transactions:
        rows = _transaction_rows(txn)
        transaction_rows.extend(rows)
        subphases.append(
            _subphase_audit(
                project_root,
                runtime_dir,
                txn,
                rows,
                planning_rows,
                repositories.get(txn.unit.run_id),
            )
        )

    gate_rows: list[AuditInvocation] = []
    gates: dict[PhaseId, _GateFacts] = {}
    for phase_id in phases:
        rows = _gate_review_rows(runtime_dir, cursor, phase_id)
        facts = _gate_audit(runtime_dir, phase_id, rows)
        gate_rows.extend(rows)
        if facts is not None:
            gates[phase_id] = facts
    not_recorded = [n for f in gates.values() for n in f.not_recorded]

    rows_all = (*planning_rows, *transaction_rows, *gate_rows)
    repeated = [
        *_planning_repeated_work(planning_rows),
        *(item for row in subphases for item in _transaction_repeated_work(row)),
        *(
            item
            for phase_id, facts in gates.items()
            for item in _gate_repeated_work(phase_id, facts)
        ),
    ]

    phase_audits: list[PhaseAudit] = []
    for phase_id in phases:
        in_phase = [s for s in subphases if s.phase_id == phase_id]
        family_counts: Counter[InvocationFamily] = Counter(
            r.family for r in rows_all if r.phase_id == phase_id
        )
        family_counts[InvocationFamily.PHASE_GATE] += sum(
            1 for n in not_recorded if n.phase_id == phase_id
        )
        if cursor is not None and phase_id in cursor.completed_phases:
            status = PhaseAuditStatus.COMPLETED
        elif cursor is not None and cursor.current_phase == phase_id:
            status = PhaseAuditStatus.CURRENT
        else:
            status = PhaseAuditStatus.PENDING
        final = finalizations.get(phase_id)
        phase_audits.append(
            PhaseAudit(
                phase_id=phase_id,
                status=status,
                subphase_ids=tuple(s.subphase_id for s in in_phase),
                subphases_attempted=len(in_phase),
                subphases_completed=sum(1 for s in in_phase if s.completed),
                first_pass_subphases=sum(1 for s in in_phase if s.first_pass),
                review_rework_count=sum(s.review_rework_count for s in in_phase),
                retry_count=sum(s.retry_count for s in in_phase),
                invocations_by_family={
                    family: family_counts.get(family, 0) for family in InvocationFamily
                },
                gate=gates[phase_id].audit if phase_id in gates else None,
                finalization=(
                    FinalizationAudit(
                        identity=phase_context_finalization_identity(final),
                        final_repository_basis_commit=final.final_repository_basis_commit,
                        gate_attempt=final.final_phase_gate.gate_attempt,
                        subphases=final.completed_subphases,
                    )
                    if final is not None
                    else None
                ),
                repository=_repository_totals([s.repository for s in in_phase if s.completed]),
            )
        )

    runs = _project_runs(runtime_dir, cursor)
    active = cursor.active_contract if cursor is not None else None
    active_txn = next((t for t in transactions if not t.unit.completion_recorded), None)
    if cursor is None:
        project_status = ProjectAuditStatus.NOT_STARTED
    elif cursor.phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE:
        project_status = ProjectAuditStatus.COMPLETE
    else:
        project_status = ProjectAuditStatus.IN_PROGRESS

    project = ProjectAudit(
        project_id=(
            cursor.project_id.root
            if cursor is not None
            else master.project_id.root
            if master is not None
            else None
        ),
        master_plan_digest=cursor.master_plan_digest if cursor is not None else None,
        status=project_status,
        phase_gate_status=cursor.phase_gate_status if cursor is not None else None,
        phases_planned=len(phases),
        completed_phases=cursor.completed_phases if cursor is not None else (),
        current_phase=cursor.current_phase if cursor is not None else None,
        current_subphase=cursor.current_subphase if cursor is not None else None,
        active_unit=(
            ActiveUnitAudit(
                phase_id=active.phase_id,
                subphase_id=active.subphase_id,
                run_id=active.transaction_run_id,
                contract_digest=active.contract_digest,
                attempted=active_txn is not None,
                terminal_state=active_txn.state if active_txn is not None else None,
            )
            if active is not None
            else None
        ),
        subphases_attempted=len(subphases),
        subphases_completed=sum(1 for s in subphases if s.completed),
        first_pass_subphases=sum(1 for s in subphases if s.first_pass),
        review_rework_count=sum(s.review_rework_count for s in subphases),
        retry_count=sum(s.retry_count for s in subphases),
        project_runs=runs,
        final_stop=runs[-1].stop_disposition if runs else None,
        repository=_repository_totals([s.repository for s in subphases if s.completed]),
    )

    planning_status = (
        TelemetryStatus.RECORDED
        if planning_rows
        else TelemetryStatus.NOT_RECORDED
        if units
        else TelemetryStatus.NOT_APPLICABLE
    )
    unavailable = dict(aggregate_metrics(()).unavailable)
    unavailable["provider_cost"] = (
        "no billing evidence is recorded; cost is never estimated from token counts"
    )
    planning_by_stage = _groups_by(
        planning_rows,
        (),
        lambda r: r.stage.value,
        not_recorded_key=None,
        order=[s.value for s in AuditStage if s.value in {p.value for p in PlanningStage}],
    )

    return ProjectAuditProjection(
        projection_version=AUDIT_PROJECTION_VERSION,
        project=project,
        phases=tuple(phase_audits),
        subphases=tuple(subphases),
        planning=PlanningAudit(
            journal=planning_status,
            unmatched_started=sum(1 for r in planning_rows if r.abandoned),
            total=_group(InvocationFamily.PLANNING.value, planning_rows),
            by_stage=planning_by_stage,
        ),
        invocations=rows_all,
        invocation_summary=_summary(rows_all, not_recorded),
        repeated_work=tuple(repeated),
        coverage=EvidenceCoverage(
            planning_journal=planning_status,
            transaction_journals=journal_count,
            semantic_reviews_recorded=sum(
                1
                for f in gates.values()
                for a in f.audit.attempts
                if a.semantic_review is TelemetryStatus.RECORDED
            ),
            semantic_reviews_not_recorded=sum(
                1
                for f in gates.values()
                for a in f.audit.attempts
                if a.semantic_review is TelemetryStatus.NOT_RECORDED
            ),
            finalizations=len(finalizations),
            completed_phases_without_finalization=(
                len(cursor.completed_phases) - len(finalizations) if cursor is not None else 0
            ),
            project_runs=len(runs),
            git_basis_run_id=(
                cursor.completed_subphases[-1].run_id
                if cursor is not None and cursor.completed_subphases
                else None
            ),
            unavailable=dict(sorted(unavailable.items())),
        ),
    )


def _summary(
    rows: Sequence[AuditInvocation], not_recorded: Sequence[_NotRecorded]
) -> InvocationSummary:
    return InvocationSummary(
        total=_group(None, rows, len(not_recorded)),
        by_family=_groups_by(
            rows,
            not_recorded,
            lambda r: r.family.value,
            not_recorded_key=InvocationFamily.PHASE_GATE.value,
            order=[f.value for f in InvocationFamily],
        ),
        by_role=_groups_by(
            rows,
            not_recorded,
            lambda r: r.role.value,
            not_recorded_key=AgentRole.PLANNER.value,
            order=[
                r.value
                for r in AgentRole
                if any(row.role is r for row in rows) or (not_recorded and r is AgentRole.PLANNER)
            ],
        ),
        by_stage=_groups_by(
            rows,
            not_recorded,
            lambda r: r.stage.value,
            not_recorded_key=AuditStage.SEMANTIC_REVIEW.value,
            order=[
                s.value
                for s in AuditStage
                if any(row.stage is s for row in rows)
                or (not_recorded and s is AuditStage.SEMANTIC_REVIEW)
            ],
        ),
        by_provider=_groups_by(rows, not_recorded, lambda r: r.provider, not_recorded_key=None),
        by_configured_model=_groups_by(
            rows, not_recorded, lambda r: r.configured_model, not_recorded_key=None
        ),
        by_configured_effort=_groups_by(
            rows, not_recorded, lambda r: r.configured_effort, not_recorded_key=None
        ),
        by_reported_model=_groups_by(
            rows, not_recorded, lambda r: r.reported_model, not_recorded_key=None
        ),
    )


def audit_projection_json(projection: ProjectAuditProjection) -> str:
    """The canonical serialization: sorted keys, no insignificant whitespace."""
    return json.dumps(
        projection.model_dump(mode="json"),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    )


__all__ = [
    "AUDIT_PROJECTION_VERSION",
    "ActiveUnitAudit",
    "AttemptElapsed",
    "AuditEvidenceSource",
    "AuditInvocation",
    "AuditStage",
    "Coverage",
    "EvidenceCoverage",
    "FinalizationAudit",
    "GateAttemptAudit",
    "HaltAudit",
    "HaltKind",
    "InvocationFamily",
    "InvocationGroup",
    "InvocationSummary",
    "ObservedSeconds",
    "ObservedTotal",
    "PhaseAudit",
    "PhaseAuditStatus",
    "PhaseGateAudit",
    "PlanningAudit",
    "ProjectAudit",
    "ProjectAuditError",
    "ProjectAuditProjection",
    "ProjectAuditStatus",
    "ProjectRunAudit",
    "RepeatedWork",
    "RepeatedWorkCategory",
    "RepeatedWorkSource",
    "RepositoryAudit",
    "RepositoryTotals",
    "ReservationAudit",
    "RetryAudit",
    "SubphaseAudit",
    "SubphaseElapsed",
    "TelemetryStatus",
    "TestAudit",
    "UsageSummary",
    "audit_projection_json",
    "build_project_audit",
]
