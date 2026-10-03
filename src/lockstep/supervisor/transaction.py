"""Deterministic single-Sub-phase Supervisor transaction.

Composes the Phase 1-3 kernels into one Supervisor-owned transaction
that drives a new run from ``READY`` to ``SUBPHASE_COMPLETE``. The
event journal at ``request.runtime_dir/events.jsonl`` is authoritative;
``state.json`` beside it is the derived checkpoint. The Supervisor
launches no subprocess and issues no Git command directly: agent
invocation, worktree management, canonical commits, verification
process execution, and state persistence all delegate to the trusted
lower-layer packages.

Sub-phase 9.6 adds a second, additive entrypoint,
:func:`run_single_subphase_transaction_with_blockers`, that drives the
same deterministic prefix and successful suffix but executes the
Implementer stage through the structured Sub-phase 9.4 agent-turn
channel (:func:`~lockstep.agent_turn.invoke_agent_turn`) instead of a
plain :func:`~lockstep.agents.invoke_agent` call. A ``BLOCKED``
Implementer turn is dispatched through the frozen Sub-phase 9.5
Supervisor escalation dispatcher
(:func:`~lockstep.supervisor.escalation.dispatch_escalation`, imported
lazily inside the function to avoid the runtime/Supervisor import
cycle that a module-level import would create) and the transaction
halts with a structured :class:`ImplementerBlockedTransactionResult` --
never re-entering the Implementer, never invoking the Reviewer, and
never committing partial work.

Sub-phase 9.7 additionally migrates the blocker-aware entrypoint's
Reviewer stage onto the composite Sub-phase 9.7 structured turn
(:func:`~lockstep.reviewer_turn.invoke_reviewer_turn`): a ``COMPLETED``
Reviewer report feeds its nested ``ReviewDecision`` into the exact
existing verdict-handling/commit suffix, unchanged, while a ``BLOCKED``
report is dispatched through the same escalation dispatcher and the
transaction halts with a structured
:class:`ReviewerBlockedTransactionResult` -- never re-running
verification, never re-entering the Reviewer, and never committing. The
original :func:`run_single_subphase_transaction` entrypoint is unchanged
in behavior and keeps invoking the Reviewer through the old raw
``invoke_agent``/``ReviewDecision`` contract; both entrypoints share the
same prefix/verification/verdict-handling helpers so the transaction
algorithm is not duplicated.

Sub-phase 9.10 adds a third, additive entrypoint,
:func:`run_single_subphase_transaction_with_retry_checkpoint`, that shares
the exact same blocker-capable execution pipeline
(:func:`_run_blocker_capable_transaction`) as the Sub-phase 9.7 blocker-aware
entrypoint, but additionally captures a Reviewer ``COMPLETED`` report whose
``ReviewDecision.verdict`` is ``REWORK`` -- a retry authority that
:func:`run_single_subphase_transaction_with_blockers` still raises
:class:`SupervisorTransactionError` for, unchanged. Whenever the shared
pipeline produces an Implementer/Reviewer ``RESUME_AGENT`` escalation or a
Reviewer ``REWORK`` verdict, the new entrypoint derives a durable
:class:`~lockstep.retry_checkpoint.RetryCheckpoint` from the frozen
Sub-phase 9.8/9.9 retry protocol (using the caller-supplied
:class:`~lockstep.retry.RetryBudget`, with no default or config/env/CLI
source) and freezes it via
:func:`~lockstep.retry_checkpoint.freeze_retry_checkpoint` before returning
a :class:`RetryCheckpointedTransactionResult` -- only after that freeze
succeeds; a freeze failure propagates unchanged, leaving the run ``HALTED``
with no checkpoint. ``lockstep.retry``/``lockstep.retry_checkpoint`` are
imported only under ``TYPE_CHECKING`` or lazily inside the exact
checkpoint-integration call sites, mirroring the existing lazy
``dispatch_escalation`` import, to avoid the module-load cycle those
modules' own imports of :mod:`lockstep.supervisor.escalation` would
otherwise create. This sub-phase still runs only the initial transaction
attempt; it never executes a second Implementer or Reviewer invocation and
never consumes, claims, or deletes a checkpoint.

Phase 11.4 makes the blocker-capable and resume paths compose authority-preserving
handoffs. The Implementer now runs through the specialized
:func:`~lockstep.implementer_turn.invoke_implementer_turn` seam, whose completed
report the host persists per attempt as evidence
(:mod:`lockstep.evidence_store`). The whole Contract verification stack runs as one
verification stage with one ``VerificationReport``, one bounded evidence record and
one ``VERIFICATION_COMPLETED`` event. The Reviewer prompt is composed at the
Reviewer stage from durable state (:mod:`lockstep.handoff`). A request that carries
its frozen ``contract`` also gets canonical Implementer and rework handoffs. None of
this changes retry authority, the claim/settlement protocol or the workflow state
machine.
"""

from __future__ import annotations

import json
from collections.abc import Mapping, Sequence
from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path
from typing import TYPE_CHECKING

from pydantic import ValidationError

from lockstep.agent_turn import AgentTurnError, AgentTurnStatus
from lockstep.agents import (
    AgentAdapter,
    AgentInvocationRequest,
    invoke_agent,
)
from lockstep.baseline_expectations import (
    authoring_scope_violation,
    expectation_specs,
    required_changed_paths,
    run_baseline_expectations,
)
from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    BillingMode,
    ExecutionEventKind,
    ExecutionOutcome,
    FailureCause,
    ImplementationReport,
    InvocationIdentity,
    InvocationStage,
    PhaseId,
    ProjectId,
    ReviewDecision,
    ReviewVerdict,
    RunId,
    StopReason,
    SubphaseContract,
    SubphaseId,
)
from lockstep.escalation import EscalationProtocolError, EscalationRequest
from lockstep.escalation_decision import PlannerDecisionKind
from lockstep.evidence_store import (
    EvidenceStoreError,
    write_baseline_evidence,
    write_implementation_report,
    write_verification_evidence,
    write_verification_report,
)
from lockstep.failure import (
    cause_for_escalation,
    cause_for_review_verdict,
    stop_reason_for_escalation,
)
from lockstep.git import (
    GitCommitResult,
    GitRepositorySnapshot,
    commit_exact_paths,
    create_run_worktree,
    inspect_repository,
)
from lockstep.git.commit import commit_exact_subset_paths
from lockstep.handoff import (
    REVIEWER_IDENTITY_HEADER,
    HandoffError,
    RetryControl,
    build_implementer_handoff,
    build_reviewer_handoff,
    build_rework_handoff,
    render_implementer_handoff,
    render_reviewer_handoff,
    render_rework_handoff,
)
from lockstep.implementer_turn import ImplementerTurnResult, invoke_implementer_turn
from lockstep.persistence import (
    RunCreatedEvent,
    StateTransitionedEvent,
    append_event,
    load_verified_state,
    read_events,
    record_execution_event,
    replay_events,
    write_state,
)
from lockstep.process import (
    build_process_environment,
    run_process,
)
from lockstep.reviewer_turn import ReviewerTurnError, ReviewerTurnResult, invoke_reviewer_turn
from lockstep.state import RunStateSnapshot, WorkflowState
from lockstep.verification_stack import run_verification_stack

if TYPE_CHECKING:
    from lockstep.resume import ResumeClaim
    from lockstep.resume_settlement import ResumeSettlement, ResumeSettlementOutcome
    from lockstep.retry import AttemptState, RetryBudget
    from lockstep.retry_checkpoint import RetryCheckpoint
    from lockstep.runtime import AgentRuntime
    from lockstep.supervisor.escalation import SupervisorEscalationResult


class SupervisorTransactionError(Exception):
    """A Supervisor-level semantic transaction failure.

    Carries a short ``stage`` naming the transaction step that failed
    and a ``reason`` explaining why. The exception deliberately omits
    prompt text, environment mappings, and captured agent output so
    diagnostic surfaces cannot leak that context.
    """

    def __init__(self, *, stage: str, reason: str) -> None:
        self.stage = stage
        self.reason = reason
        super().__init__(f"supervisor transaction failed during {stage}: {reason}")


@dataclass(frozen=True, slots=True)
class SingleSubphaseTransactionRequest:
    """Orchestrator-owned request for a single-Sub-phase transaction.

    ``source_path``, ``worktree_path``, and ``runtime_dir`` are
    normalized with non-strict :meth:`Path.resolve` at construction so
    downstream layers see stable absolute paths. Prompt fields are
    excluded from :func:`repr` so casual logging cannot surface them.
    """

    project_id: ProjectId
    run_id: RunId
    phase_id: PhaseId
    subphase_id: SubphaseId

    source_path: Path
    worktree_path: Path
    runtime_dir: Path
    branch: str

    billing_mode: BillingMode

    planner_prompt: str = field(repr=False)
    implementer_prompt: str = field(repr=False)
    reviewer_prompt: str = field(repr=False)

    test_paths: tuple[str, ...]
    implementation_paths: tuple[str, ...]

    planner_quality_argv: tuple[str, ...]
    baseline_argv: tuple[str, ...]
    verification_argv: tuple[str, ...]

    test_commit_message: str
    implementation_commit_message: str

    agent_timeout_seconds: float = 30.0
    command_timeout_seconds: float = 30.0
    max_output_bytes: int = 1_048_576
    termination_grace_seconds: float = 0.25

    # Root the run branch at this existing local branch's tip instead of the
    # source HEAD (sequential Sub-phases build on the previous accepted run).
    base_branch: str | None = None

    # The Contract's complete, ordered verification stack as direct argv. Empty
    # means the single legacy ``verification_argv`` (injected requests only);
    # when set it is the canonical verification authority for the transaction.
    verification_commands: tuple[tuple[str, ...], ...] = ()

    # The frozen Contract this transaction executes. When supplied the host
    # composes the canonical role handoffs (frozen authority, protected tests,
    # repository basis, evidence) at each role's invocation; the *_prompt fields
    # then only carry base role instructions. When ``None`` (legacy injected
    # requests) the prompt fields are used as given and no Contract section is
    # composed.
    contract: SubphaseContract | None = field(default=None, repr=False)

    def __post_init__(self) -> None:
        object.__setattr__(self, "source_path", Path(self.source_path).resolve())
        object.__setattr__(self, "worktree_path", Path(self.worktree_path).resolve())
        object.__setattr__(self, "runtime_dir", Path(self.runtime_dir).resolve())


@dataclass(frozen=True, slots=True)
class SingleSubphaseTransactionResult:
    """Durable outcome of a completed single-Sub-phase transaction."""

    run_id: RunId
    phase_id: PhaseId
    subphase_id: SubphaseId

    worktree_root: Path
    branch: str

    test_commit: GitCommitResult
    implementation_commit: GitCommitResult

    review: ReviewDecision
    final_state: RunStateSnapshot


@dataclass(frozen=True, slots=True)
class ImplementerBlockedTransactionResult:
    """Durable outcome of a single-Sub-phase transaction halted by a blocked Implementer.

    Produced only when the structured Implementer turn invoked by
    :func:`run_single_subphase_transaction_with_blockers` reports
    ``BLOCKED``. ``test_commit`` is the exact frozen Planner-authored
    test commit the transaction already produced; ``implementer_turn``
    is the exact :class:`~lockstep.implementer_turn.ImplementerTurnResult`
    returned by :func:`~lockstep.implementer_turn.invoke_implementer_turn`
    (excluded from :func:`repr` so logging never dumps raw provider output);
    ``escalation`` is the exact
    :class:`~lockstep.supervisor.escalation.SupervisorEscalationResult`
    returned by
    :func:`~lockstep.supervisor.escalation.dispatch_escalation`; and
    ``final_state`` is the transaction's final ``HALTED`` snapshot.
    Carries no production commit, review decision, or verification
    result -- those stages never occur after a blocked Implementer
    turn.
    """

    test_commit: GitCommitResult
    implementer_turn: ImplementerTurnResult = field(repr=False)
    escalation: SupervisorEscalationResult
    final_state: RunStateSnapshot


@dataclass(frozen=True, slots=True)
class ReviewerBlockedTransactionResult:
    """Durable outcome of a single-Sub-phase transaction halted by a blocked Reviewer.

    Produced only when the composite structured Reviewer turn invoked by
    :func:`run_single_subphase_transaction_with_blockers` reports
    ``BLOCKED``. ``test_commit`` is the exact frozen Planner-authored
    test commit the transaction already produced; ``implementer_turn``
    is the exact :class:`~lockstep.implementer_turn.ImplementerTurnResult`
    for the already-``COMPLETED`` Implementer turn that preceded
    verification (excluded from :func:`repr`); ``reviewer_turn`` is the exact
    :class:`~lockstep.reviewer_turn.ReviewerTurnResult` returned by
    :func:`~lockstep.reviewer_turn.invoke_reviewer_turn` (excluded from
    :func:`repr` so logging never dumps raw provider output);
    ``escalation`` is the exact
    :class:`~lockstep.supervisor.escalation.SupervisorEscalationResult`
    returned by
    :func:`~lockstep.supervisor.escalation.dispatch_escalation`; and
    ``final_state`` is the transaction's final ``HALTED`` snapshot.
    Carries no production commit or review decision -- those never occur
    after a blocked Reviewer turn. Deterministic verification already
    ran and passed before the Reviewer stage; it is not rerun.
    """

    test_commit: GitCommitResult
    implementer_turn: ImplementerTurnResult = field(repr=False)
    reviewer_turn: ReviewerTurnResult = field(repr=False)
    escalation: SupervisorEscalationResult
    final_state: RunStateSnapshot


@dataclass(frozen=True, slots=True)
class ReviewReworkTransactionResult:
    """Durable outcome of a Sub-phase 9.10 checkpoint-aware transaction halted by REWORK.

    Produced only by :func:`run_single_subphase_transaction_with_retry_checkpoint`
    when the composite Reviewer turn reports ``COMPLETED`` with a
    ``ReviewDecision.verdict`` of ``REWORK`` -- the one retry authority that
    never reaches a return value on the frozen Sub-phase 9.7 blocker-aware
    entrypoint, which still raises :class:`SupervisorTransactionError` for
    it unchanged. ``test_commit`` is the exact frozen Planner-authored test
    commit; ``implementer_turn`` and ``reviewer_turn`` are the exact
    already-``COMPLETED`` structured turn results (both excluded from
    :func:`repr`); ``review_decision`` is the exact nested
    :class:`~lockstep.domain.ReviewDecision` -- the durable semantic
    authority for the retry; and ``final_state`` is the transaction's final
    ``HALTED`` snapshot. Carries no production commit -- REWORK never
    commits.
    """

    test_commit: GitCommitResult
    implementer_turn: ImplementerTurnResult = field(repr=False)
    reviewer_turn: ReviewerTurnResult = field(repr=False)
    review_decision: ReviewDecision
    final_state: RunStateSnapshot


# The one retry-authority-bearing source result a Sub-phase 9.10 durable
# checkpoint can be derived from. Kept private: 9.11 may need to broaden it,
# but nothing outside this module needs to name it directly.
_RetryCheckpointSourceResult = (
    ImplementerBlockedTransactionResult
    | ReviewerBlockedTransactionResult
    | ReviewReworkTransactionResult
)


@dataclass(frozen=True, slots=True)
class RetryCheckpointedTransactionResult:
    """Durable outcome of a Sub-phase 9.10 transaction that froze retry authority.

    ``source_result`` is the exact blocked/reworked result the shared
    blocker-capable pipeline produced (excluded from :func:`repr` so
    logging never dumps nested turn content); ``checkpoint`` is the exact
    :class:`~lockstep.retry_checkpoint.RetryCheckpoint` already durably
    frozen via :func:`~lockstep.retry_checkpoint.freeze_retry_checkpoint`
    before this result is ever constructed. Carries no duplicate
    ``final_state``/``attempt``/``target_role``/``budget`` -- those facts
    already have authoritative homes on ``source_result`` and
    ``checkpoint``.
    """

    source_result: _RetryCheckpointSourceResult = field(repr=False)
    checkpoint: RetryCheckpoint


def _persist_run_created(
    *,
    run_id: RunId,
    project_id: ProjectId,
    journal_path: Path,
    state_path: Path,
) -> None:
    event = RunCreatedEvent(
        run_id=run_id,
        sequence=1,
        occurred_at=datetime.now(UTC),
        project_id=project_id,
    )
    append_event(journal_path, event)
    snapshot = replay_events(read_events(journal_path))
    write_state(state_path, snapshot)


def _persist_transition(
    *,
    run_id: RunId,
    source: WorkflowState,
    target: WorkflowState,
    sequence: int,
    journal_path: Path,
    state_path: Path,
) -> None:
    event = StateTransitionedEvent(
        run_id=run_id,
        sequence=sequence,
        occurred_at=datetime.now(UTC),
        source=source,
        target=target,
    )
    append_event(journal_path, event)
    snapshot = replay_events(read_events(journal_path))
    write_state(state_path, snapshot)


# A single-Sub-phase transaction currently drives exactly one Reviewer
# invocation; there is no automated REWORK loop yet (Phase 9 concern), so
# the transaction's authoritative attempt number is always the first.
_TRANSACTION_ATTEMPT = AttemptNumber.model_validate(1)


def _emit(
    request: SingleSubphaseTransactionRequest,
    kind: ExecutionEventKind,
    *,
    attempt: AttemptNumber = _TRANSACTION_ATTEMPT,
    outcome: ExecutionOutcome | None = None,
    role: AgentRole | None = None,
    verdict: ReviewVerdict | None = None,
    stop_reason: StopReason | None = None,
    cause: FailureCause | None = None,
    detail: str | None = None,
) -> None:
    """Record one observational execution event for *request*'s Sub-phase.

    Called only from the deterministic code path that owns the action,
    after the action occurred. Confers no authority; see
    :class:`~lockstep.persistence.ExecutionEvent`. ``cause`` / ``stop_reason``
    attribute history only (see :mod:`lockstep.failure`).
    """
    record_execution_event(
        request.runtime_dir,
        kind=kind,
        outcome=outcome,
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        attempt=attempt,
        role=role,
        verdict=verdict,
        stop_reason=stop_reason,
        cause=cause,
        detail=detail,
    )


def _emit_abort(
    request: SingleSubphaseTransactionRequest,
    *,
    stage: str,
    cause: FailureCause | None,
    stop_reason: StopReason | None,
    attempt: AttemptNumber = _TRANSACTION_ATTEMPT,
    subreason: str | None = None,
) -> None:
    """Record that the deterministic transaction is about to raise at *stage*.

    The boundary no halt/complete event covers: the caller still raises
    :class:`SupervisorTransactionError`; this only attributes why. A typed
    *subreason* is appended to the stage (``stage:subreason``).
    """
    _emit(
        request,
        ExecutionEventKind.TRANSACTION_ABORTED,
        attempt=attempt,
        outcome=ExecutionOutcome.FAILURE,
        stop_reason=stop_reason,
        cause=cause,
        detail=stage if subreason is None else f"{stage}:{subreason}",
    )


def _halt_after_agent_failure(
    request: SingleSubphaseTransactionRequest,
    journal_path: Path,
    state_path: Path,
    *,
    stage: str,
) -> None:
    """Make a known attempt-1 agent/provider failure durably non-active before it escapes.

    The failed invocation's own ``INVOCATION_RETURNED`` event is the single
    root-cause record (``cause`` / usage / timing); this boundary carries no
    ``cause`` or ``stop_reason`` so a failure is never counted twice. It
    creates no retry checkpoint: ``HALTED`` alone confers no retry authority.
    """
    current = load_verified_state(state_path, journal_path)
    assert current is not None
    _persist_transition(
        run_id=request.run_id,
        source=current.workflow_state,
        target=WorkflowState.HALTED,
        sequence=_next_sequence(journal_path),
        journal_path=journal_path,
        state_path=state_path,
    )
    _emit(request, ExecutionEventKind.TRANSACTION_HALTED, detail=stage)


def _implementer_scope_breached(
    request: SingleSubphaseTransactionRequest,
    snapshot: GitRepositorySnapshot,
    allowed_paths: Sequence[str],
    *,
    expected_head_sha: str | None = None,
) -> bool:
    """Did the Implementer exceed its authority? (11.7-R3)

    ``allowed_paths`` is a ceiling, not a checklist: the dirty set must be a subset of it
    (the empty set included), and it must never touch a frozen Planner test even if a
    malformed request also lists that path as allowed. Whether enough work was done is
    answered by later stages, not here.
    """
    dirty = set(snapshot.dirty_paths)
    if expected_head_sha is not None and snapshot.head_sha != expected_head_sha:
        return True
    return not dirty <= set(allowed_paths) or bool(dirty & set(request.test_paths))


def _attribute_scope_breach(
    request: SingleSubphaseTransactionRequest,
    snapshot: GitRepositorySnapshot,
    expected_head_sha: str,
    approved_paths: Sequence[str],
) -> tuple[FailureCause | None, StopReason | None]:
    """Distinguish an authority violation from a scope violation, from git facts only.

    Touching a protected (frozen test) path or moving HEAD exercises authority
    the Implementer does not hold; any other unapproved dirty path is a scope
    violation. A shortfall (nothing unexpected changed) asserts neither.
    """
    if snapshot.head_sha != expected_head_sha or set(snapshot.dirty_paths) & set(
        request.test_paths
    ):
        return FailureCause.AUTHORITY_VIOLATION, StopReason.PROTECTED_ARTIFACT_CHANGED
    if set(snapshot.dirty_paths) - set(approved_paths):
        return FailureCause.SCOPE_VIOLATION, StopReason.OUT_OF_SCOPE_CHANGE
    return None, None


def _require_review_matches_transaction(
    review: ReviewDecision,
    request: SingleSubphaseTransactionRequest,
) -> None:
    if (
        review.phase_id != request.phase_id
        or review.subphase_id != request.subphase_id
        or review.attempt != _TRANSACTION_ATTEMPT
    ):
        raise SupervisorTransactionError(
            stage="review",
            reason="reviewer decision does not match current transaction",
        )


def _agent_request(
    *,
    role: AgentRole,
    prompt: str,
    request: SingleSubphaseTransactionRequest,
    cwd: Path,
    stage: InvocationStage,
) -> AgentInvocationRequest:
    return AgentInvocationRequest(
        role=role,
        billing_mode=request.billing_mode,
        prompt=prompt,
        cwd=cwd,
        timeout_seconds=request.agent_timeout_seconds,
        max_output_bytes=request.max_output_bytes,
        termination_grace_seconds=request.termination_grace_seconds,
        identity=InvocationIdentity.issue(
            run_id=request.run_id,
            phase_id=request.phase_id,
            subphase_id=request.subphase_id,
            attempt=_TRANSACTION_ATTEMPT,
            role=role,
            stage=stage,
        ),
    )


def _record_escalation_dispatched(
    request: SingleSubphaseTransactionRequest,
    result: SupervisorEscalationResult,
) -> None:
    """Record the disposition the dispatcher decided (observational; confers no authority)."""
    _emit(
        request,
        ExecutionEventKind.ESCALATION_DISPATCHED,
        attempt=result.request.attempt,
        role=result.request.source_role,
        cause=cause_for_escalation(result.request.category),
        detail=result.disposition.value,
    )


_REVIEWER_IDENTITY_HEADER = REVIEWER_IDENTITY_HEADER


def _reviewer_prompt_with_host_identity(
    prompt: str,
    *,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
) -> str:
    """Append the host-owned Reviewer identity section after all caller/resume prose.

    The single composition point for every Reviewer invocation path, so the
    identity later validated against the returned ``ReviewDecision`` is
    always supplied by the Supervisor rather than inferred from prose.
    """
    payload = {
        "phase_id": phase_id.root,
        "subphase_id": subphase_id.root,
        "attempt": attempt.root,
        "role": AgentRole.REVIEWER.value,
    }
    return prompt + _REVIEWER_IDENTITY_HEADER + _deterministic_json(payload) + "\n"


def _verification_cache_root(request: SingleSubphaseTransactionRequest) -> Path:
    return request.worktree_path.parent / f".lockstep-pycache-{request.run_id.root}"


def _verification_env_for(
    base_env: Mapping[str, str],
    *,
    cache_root: Path,
    purpose: str,
    attempt: AttemptNumber | None = None,
) -> Mapping[str, str]:
    """Build a verification environment with its own private bytecode-cache namespace.

    Python validates cached bytecode by source path, encoded size, and
    integer-second mtime, so a cache populated for one worktree state can be
    read back as valid for a different state that happens to share all
    three. Each logically distinct verification (baseline, and each attempt's
    post-Implementer verification) therefore gets its own
    ``PYTHONPYCACHEPREFIX`` beneath *cache_root*, derived only from the
    authoritative execution identity *purpose* and *attempt* -- never a
    clock, counter, PID, or random value.
    """
    namespace = purpose if attempt is None else f"{purpose}-attempt-{attempt.root}"
    pycache_dir = cache_root / namespace
    pycache_dir.mkdir(parents=True, exist_ok=True)
    return build_process_environment(
        base_env, explicit_env={"PYTHONPYCACHEPREFIX": str(pycache_dir)}
    )


def _verification_commands(
    request: SingleSubphaseTransactionRequest,
) -> tuple[tuple[str, ...], ...]:
    """The ordered verification stack: the Contract's commands, or the one legacy argv."""
    return request.verification_commands or (request.verification_argv,)


def _run_verification_stage(
    request: SingleSubphaseTransactionRequest,
    *,
    cwd: Path,
    env: Mapping[str, str],
    attempt: AttemptNumber,
) -> None:
    """Run the whole verification stack as one stage and durably record its evidence.

    However many commands the stack holds, the stage yields exactly one
    ``VerificationReport``, one bounded evidence record and one
    ``VERIFICATION_COMPLETED`` event, so the frozen Phase-10 stage metrics are
    unchanged. The artifacts are persisted before the outcome is acted on, so a
    failed stage leaves the same reconstructable evidence a passing one does.
    """
    stack = run_verification_stack(
        _verification_commands(request),
        run_id=request.run_id,
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        attempt=attempt,
        cwd=cwd,
        env=env,
        timeout_seconds=request.command_timeout_seconds,
        max_output_bytes=request.max_output_bytes,
        termination_grace_seconds=request.termination_grace_seconds,
        runner=run_process,
    )
    write_verification_report(request.runtime_dir, stack.report)
    write_verification_evidence(request.runtime_dir, stack.evidence)
    if not stack.passed:
        _emit(
            request,
            ExecutionEventKind.VERIFICATION_COMPLETED,
            attempt=attempt,
            outcome=ExecutionOutcome.FAILURE,
            cause=FailureCause.VERIFICATION_FAILURE,
        )
        raise SupervisorTransactionError(
            stage="verification",
            reason=(
                "verification command exited with returncode "
                f"{stack.evidence.commands[-1].exit_code}"
            ),
        )
    _emit(
        request,
        ExecutionEventKind.VERIFICATION_COMPLETED,
        attempt=attempt,
        outcome=ExecutionOutcome.SUCCESS,
    )


def _record_implementation_report(
    request: SingleSubphaseTransactionRequest,
    implementer_turn: ImplementerTurnResult,
    attempt: AttemptNumber,
) -> None:
    """Persist the canonical report: the Implementer's draft plus host-owned identity.

    The report is evidence. It is recorded verbatim and never read back to derive
    scope, paths, tests or retry authority.
    """
    draft = implementer_turn.report.implementation_report
    assert draft is not None
    write_implementation_report(
        request.runtime_dir,
        ImplementationReport(
            phase_id=request.phase_id,
            subphase_id=request.subphase_id,
            attempt=attempt,
            summary=draft.summary,
            changed_files=draft.changed_files,
            decisions=draft.decisions,
            deviations=draft.deviations,
            concerns=draft.concerns,
        ),
    )


def _initial_implementer_prompt(
    request: SingleSubphaseTransactionRequest, worktree_root: Path
) -> str:
    """The first-attempt Implementer prompt: base instructions plus the host's handoff.

    A legacy request without a Contract keeps its prompt exactly as given.
    """
    if request.contract is None:
        return request.implementer_prompt
    handoff = build_implementer_handoff(
        runtime_dir=request.runtime_dir,
        worktree_path=worktree_root,
        run_id=request.run_id,
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        attempt=_TRANSACTION_ATTEMPT,
        contract=request.contract,
        test_paths=request.test_paths,
    )
    return request.implementer_prompt + render_implementer_handoff(handoff)


def _late_reviewer_prompt(
    request: SingleSubphaseTransactionRequest,
    *,
    worktree_path: Path,
    attempt: AttemptNumber,
    base_prompt: str,
    prior_decisions: tuple[ReviewDecision, ...] = (),
) -> str:
    """Compose the Reviewer prompt at the Reviewer stage, from durable state only.

    The caller's text is base reviewer instructions. Everything the Reviewer needs
    to judge -- Contract and tests as authority; the Implementer report,
    verification evidence and diff as evidence; prior findings as history; and the
    host identity the decision must copy -- is rebuilt here from the Contract, the
    journal, the attempt's durable artifacts and Git, after all of it exists.

    A legacy injected request carries no Contract and keeps exactly its established
    prompt: the caller's text followed by the host identity block (frozen by the
    Sub-phase 9.14 identity tests, which require that prompt to be byte-identical for
    identical inputs and so cannot include per-run evidence).
    """
    if request.contract is None:
        return _reviewer_prompt_with_host_identity(
            base_prompt,
            phase_id=request.phase_id,
            subphase_id=request.subphase_id,
            attempt=attempt,
        )
    handoff = build_reviewer_handoff(
        runtime_dir=request.runtime_dir,
        worktree_path=worktree_path,
        run_id=request.run_id,
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        attempt=attempt,
        contract=request.contract,
        test_paths=request.test_paths,
        prior_decisions=prior_decisions,
    )
    return base_prompt + render_reviewer_handoff(handoff)


@dataclass(frozen=True, slots=True)
class _PreparedTransaction:
    """Internal seam: the shared, provider-neutral transaction prefix state."""

    journal_path: Path
    state_path: Path
    worktree_root: Path
    source_head_sha: str
    parent_env: Mapping[str, str]
    verification_env: Mapping[str, str]


def _prepare_transaction(
    request: SingleSubphaseTransactionRequest,
    *,
    parent_env: Mapping[str, str],
) -> _PreparedTransaction:
    journal_path = request.runtime_dir / "events.jsonl"
    state_path = request.runtime_dir / "state.json"

    if journal_path.exists() or state_path.exists():
        raise SupervisorTransactionError(
            stage="runtime",
            reason="runtime already initialized",
        )

    request.runtime_dir.mkdir(parents=True, exist_ok=True)

    _persist_run_created(
        run_id=request.run_id,
        project_id=request.project_id,
        journal_path=journal_path,
        state_path=state_path,
    )

    worktree_snapshot = create_run_worktree(
        request.source_path,
        request.worktree_path,
        request.branch,
        base_branch=request.base_branch,
    )
    worktree_root = worktree_snapshot.root
    source_head_sha = worktree_snapshot.head_sha

    # A supervisor-owned bytecode cache prefix keeps Python's automatic
    # ``__pycache__`` writes (from py_compile and pytest imports) outside
    # the run worktree so ``commit_exact_paths`` can compare dirty paths
    # against the approved set without spurious ``.pyc`` matches. The
    # planner-quality and baseline commands observe the same immutable
    # worktree snapshot and share one namespace; post-Implementer
    # verification gets its own (see ``_verify_after_implementer``).
    verification_env = _verification_env_for(
        parent_env,
        cache_root=_verification_cache_root(request),
        purpose="baseline",
    )

    return _PreparedTransaction(
        journal_path=journal_path,
        state_path=state_path,
        worktree_root=worktree_root,
        source_head_sha=source_head_sha,
        parent_env=parent_env,
        verification_env=verification_env,
    )


def _baseline_prefix(request: SingleSubphaseTransactionRequest) -> tuple[str, ...]:
    """The configured baseline command prefix: ``baseline_argv`` without its test paths.

    ``baseline_argv`` is the prefix followed by every Contract test path; the baseline stage
    runs ``prefix + [path]`` once per specification instead of one aggregate command.
    """
    count = len(request.test_paths)
    if count and request.baseline_argv[-count:] == request.test_paths:
        return request.baseline_argv[:-count]
    return request.baseline_argv


def _author_tests(
    request: SingleSubphaseTransactionRequest,
    ctx: _PreparedTransaction,
    *,
    parent_env: Mapping[str, str],
    planner_adapter: AgentAdapter,
) -> GitCommitResult:
    for source_state, target_state in (
        (WorkflowState.READY, WorkflowState.PHASE_PLANNING),
        (WorkflowState.PHASE_PLANNING, WorkflowState.SUBPHASE_PLANNING),
        (WorkflowState.SUBPHASE_PLANNING, WorkflowState.TEST_AUTHORING),
    ):
        _persist_transition(
            run_id=request.run_id,
            source=source_state,
            target=target_state,
            sequence=_next_sequence(ctx.journal_path),
            journal_path=ctx.journal_path,
            state_path=ctx.state_path,
        )

    planner_result = invoke_agent(
        planner_adapter,
        _agent_request(
            role=AgentRole.PLANNER,
            prompt=request.planner_prompt,
            request=request,
            cwd=ctx.worktree_root,
            stage=InvocationStage.TEST_AUTHORING,
        ),
        parent_env=parent_env,
        runtime_dir=request.runtime_dir,
    )
    if planner_result.process.returncode != 0:
        _halt_after_agent_failure(request, ctx.journal_path, ctx.state_path, stage="planner")
        raise SupervisorTransactionError(
            stage="planner",
            reason=(f"planner process exited with returncode {planner_result.process.returncode}"),
        )

    specs = expectation_specs(request.test_paths, request.contract)
    post_planner_snapshot = inspect_repository(ctx.worktree_root)
    scope_violation = authoring_scope_violation(
        specs, post_planner_snapshot.dirty_paths, ctx.worktree_root
    )
    if scope_violation is not None:
        _emit_abort(
            request,
            stage="test_scope",
            cause=FailureCause.SCOPE_VIOLATION,
            stop_reason=StopReason.OUT_OF_SCOPE_CHANGE,
            subreason=scope_violation.value,
        )
        raise SupervisorTransactionError(
            stage="test_scope",
            reason=(
                f"planner test authoring does not match the Contract expectations: "
                f"{scope_violation.value}"
            ),
        )

    quality_result = run_process(
        request.planner_quality_argv,
        cwd=ctx.worktree_root,
        env=ctx.verification_env,
        timeout_seconds=request.command_timeout_seconds,
        max_output_bytes=request.max_output_bytes,
        termination_grace_seconds=request.termination_grace_seconds,
    )
    if quality_result.returncode != 0:
        raise SupervisorTransactionError(
            stage="test_quality",
            reason=(
                f"planner-test quality command exited with returncode {quality_result.returncode}"
            ),
        )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.TEST_AUTHORING,
        target=WorkflowState.TEST_BASELINE_VERIFY,
        sequence=_next_sequence(ctx.journal_path),
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
    )

    # One logical baseline stage (one BASELINE_VERIFIED event) that judges each
    # specification by its own expectation, so an intended RED failure can never
    # hide an unexpected GREEN failure. The evidence is persisted before it is acted on.
    baseline = run_baseline_expectations(
        specs,
        prefix_argv=_baseline_prefix(request),
        run_id=request.run_id,
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        attempt=_TRANSACTION_ATTEMPT,
        cwd=ctx.worktree_root,
        env=ctx.verification_env,
        timeout_seconds=request.command_timeout_seconds,
        max_output_bytes=request.max_output_bytes,
        termination_grace_seconds=request.termination_grace_seconds,
        runner=run_process,
    )
    write_baseline_evidence(request.runtime_dir, baseline.record)
    if not baseline.satisfied:
        _emit(
            request,
            ExecutionEventKind.BASELINE_VERIFIED,
            outcome=ExecutionOutcome.FAILURE,
            cause=baseline.cause,
            detail=baseline.detail,
        )
        raise SupervisorTransactionError(
            stage="baseline",
            reason=f"baseline expectation violated: {baseline.detail}",
        )
    _emit(
        request,
        ExecutionEventKind.BASELINE_VERIFIED,
        outcome=ExecutionOutcome.SUCCESS,
        detail="baseline_expectations_satisfied",
    )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.TEST_BASELINE_VERIFY,
        target=WorkflowState.TEST_COMMIT,
        sequence=_next_sequence(ctx.journal_path),
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
    )

    test_commit = commit_exact_paths(
        ctx.worktree_root,
        expected_branch=request.branch,
        expected_head_sha=ctx.source_head_sha,
        # Only what the Planner authored; an unchanged GREEN_REGRESSION file is still
        # protected (request.test_paths) but is not part of the commit.
        paths=required_changed_paths(specs),
        message=request.test_commit_message,
    )
    _emit(
        request,
        ExecutionEventKind.TESTS_FROZEN,
        outcome=ExecutionOutcome.SUCCESS,
        detail=test_commit.commit_sha,
    )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.TEST_COMMIT,
        target=WorkflowState.IMPLEMENTING,
        sequence=_next_sequence(ctx.journal_path),
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
    )

    return test_commit


def _verify_after_implementer(
    request: SingleSubphaseTransactionRequest,
    ctx: _PreparedTransaction,
    test_commit: GitCommitResult,
) -> None:
    """Shared post-Implementer prefix: scope check through ``REVIEWING`` (sequences 8-9).

    Shared verbatim by the legacy Reviewer path and both Sub-phase 9.7
    composite-Reviewer outcomes (``COMPLETED`` and ``BLOCKED``) -- the
    Reviewer stage never determines whether deterministic verification
    ran; it always already has by the time either Reviewer contract is
    invoked.
    """
    post_implementer_snapshot = inspect_repository(ctx.worktree_root)
    if _implementer_scope_breached(
        request,
        post_implementer_snapshot,
        request.implementation_paths,
        expected_head_sha=test_commit.commit_sha,
    ):
        cause, stop_reason = _attribute_scope_breach(
            request,
            post_implementer_snapshot,
            test_commit.commit_sha,
            request.implementation_paths,
        )
        _emit_abort(request, stage="implementation_scope", cause=cause, stop_reason=stop_reason)
        raise SupervisorTransactionError(
            stage="implementation_scope",
            reason=(
                "implementer either advanced HEAD or produced dirty paths outside "
                "the approved implementation set"
            ),
        )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.IMPLEMENTING,
        target=WorkflowState.VERIFYING,
        sequence=_next_sequence(ctx.journal_path),
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
    )

    _run_verification_stage(
        request,
        cwd=ctx.worktree_root,
        env=_verification_env_for(
            ctx.parent_env,
            cache_root=_verification_cache_root(request),
            purpose="verify",
            attempt=_TRANSACTION_ATTEMPT,
        ),
        attempt=_TRANSACTION_ATTEMPT,
    )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.VERIFYING,
        target=WorkflowState.REVIEWING,
        sequence=_next_sequence(ctx.journal_path),
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
    )


def _handle_review_decision(
    request: SingleSubphaseTransactionRequest,
    ctx: _PreparedTransaction,
    test_commit: GitCommitResult,
    review: ReviewDecision,
) -> SingleSubphaseTransactionResult:
    """Shared REWORK/HALT/APPROVE handling and production commit (sequences 10-11).

    Consumes an already-obtained :class:`~lockstep.domain.ReviewDecision`
    -- whichever contract produced it, legacy raw ``invoke_agent`` or the
    Sub-phase 9.7 composite ``ReviewerTurnReport.review_decision`` -- and
    applies the exact existing verdict semantics unchanged: only
    ``APPROVE`` continues to the production commit; every other verdict
    raises :class:`SupervisorTransactionError` with ``stage="review"``,
    exactly as before Sub-phase 9.7.
    """
    _require_review_matches_transaction(review, request)
    _emit(
        request,
        ExecutionEventKind.REVIEW_DECIDED,
        role=AgentRole.REVIEWER,
        verdict=review.verdict,
        cause=cause_for_review_verdict(review.verdict),
    )

    if review.verdict is not ReviewVerdict.APPROVE:
        raise SupervisorTransactionError(
            stage="review",
            reason=(
                f"review verdict {review.verdict.value!r} is not supported by the 4.1 happy path"
            ),
        )

    pre_commit_snapshot = inspect_repository(ctx.worktree_root)
    if _implementer_scope_breached(
        request,
        pre_commit_snapshot,
        request.implementation_paths,
        expected_head_sha=test_commit.commit_sha,
    ):
        raise SupervisorTransactionError(
            stage="pre_commit_integrity",
            reason=("worktree drifted between verification and implementation commit"),
        )
    if not pre_commit_snapshot.dirty_paths:
        raise SupervisorTransactionError(
            stage="pre_commit_integrity",
            reason="no implementation changes to commit",
        )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.REVIEWING,
        target=WorkflowState.IMPLEMENTATION_COMMIT,
        sequence=_next_sequence(ctx.journal_path),
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
    )

    implementation_commit = commit_exact_paths(
        ctx.worktree_root,
        expected_branch=request.branch,
        expected_head_sha=test_commit.commit_sha,
        paths=pre_commit_snapshot.dirty_paths,
        message=request.implementation_commit_message,
    )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.IMPLEMENTATION_COMMIT,
        target=WorkflowState.SUBPHASE_COMPLETE,
        sequence=_next_sequence(ctx.journal_path),
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
    )

    final_state = load_verified_state(ctx.state_path, ctx.journal_path)
    if final_state is None or final_state.workflow_state != WorkflowState.SUBPHASE_COMPLETE:
        raise SupervisorTransactionError(
            stage="reconciliation",
            reason="final journal replay does not reach SUBPHASE_COMPLETE",
        )

    return SingleSubphaseTransactionResult(
        run_id=request.run_id,
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        worktree_root=ctx.worktree_root,
        branch=request.branch,
        test_commit=test_commit,
        implementation_commit=implementation_commit,
        review=review,
        final_state=final_state,
    )


def _complete_after_implementer_success(
    request: SingleSubphaseTransactionRequest,
    ctx: _PreparedTransaction,
    test_commit: GitCommitResult,
    *,
    parent_env: Mapping[str, str],
    reviewer_adapter: AgentAdapter,
) -> SingleSubphaseTransactionResult:
    """Legacy raw ``invoke_agent``/``ReviewDecision`` Reviewer stage, unchanged."""
    _verify_after_implementer(request, ctx, test_commit)

    reviewer_result = invoke_agent(
        reviewer_adapter,
        _agent_request(
            role=AgentRole.REVIEWER,
            prompt=_reviewer_prompt_with_host_identity(
                request.reviewer_prompt,
                phase_id=request.phase_id,
                subphase_id=request.subphase_id,
                attempt=_TRANSACTION_ATTEMPT,
            ),
            request=request,
            cwd=ctx.worktree_root,
            stage=InvocationStage.REVIEW,
        ),
        parent_env=parent_env,
        runtime_dir=request.runtime_dir,
    )
    if reviewer_result.process.returncode != 0:
        _halt_after_agent_failure(request, ctx.journal_path, ctx.state_path, stage="reviewer")
        raise SupervisorTransactionError(
            stage="reviewer",
            reason=(
                f"reviewer process exited with returncode {reviewer_result.process.returncode}"
            ),
        )

    try:
        review = ReviewDecision.model_validate_json(reviewer_result.process.stdout)
    except ValidationError as exc:
        _emit_abort(
            request,
            stage="review",
            cause=FailureCause.MALFORMED_OUTPUT,
            stop_reason=StopReason.MALFORMED_AGENT_OUTPUT,
        )
        raise SupervisorTransactionError(
            stage="review",
            reason="reviewer output is not a valid ReviewDecision",
        ) from exc

    return _handle_review_decision(request, ctx, test_commit, review)


def _capture_review_rework(
    request: SingleSubphaseTransactionRequest,
    ctx: _PreparedTransaction,
    test_commit: GitCommitResult,
    implementer_turn: ImplementerTurnResult,
    reviewer_turn: ReviewerTurnResult,
    review: ReviewDecision,
) -> ReviewReworkTransactionResult:
    """Sub-phase 9.10 REWORK capture: ``REVIEWING -> HALTED``, no commit.

    Called only by :func:`_complete_after_implementer_success_with_reviewer_turn`
    when ``capture_rework`` is set and the composite Reviewer report is
    ``COMPLETED`` with a ``REWORK`` verdict -- the one branch the frozen
    Sub-phase 9.7 ``_handle_review_decision`` suffix still raises
    :class:`SupervisorTransactionError` for. Preserves the exact
    ``ReviewDecision`` as the durable semantic authority for the retry
    checkpoint 9.10's caller will freeze; never runs verification again,
    never re-enters the Reviewer, and never commits.
    """
    _require_review_matches_transaction(review, request)
    _emit(
        request,
        ExecutionEventKind.REVIEW_DECIDED,
        role=AgentRole.REVIEWER,
        verdict=review.verdict,
        cause=cause_for_review_verdict(review.verdict),
    )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.REVIEWING,
        target=WorkflowState.HALTED,
        sequence=_next_sequence(ctx.journal_path),
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
    )
    _emit(
        request,
        ExecutionEventKind.TRANSACTION_HALTED,
        cause=cause_for_review_verdict(review.verdict),
        detail="review_rework",
    )

    final_state = load_verified_state(ctx.state_path, ctx.journal_path)
    if final_state is None or final_state.workflow_state != WorkflowState.HALTED:
        raise SupervisorTransactionError(
            stage="reconciliation",
            reason="final journal replay does not reach HALTED",
        )

    return ReviewReworkTransactionResult(
        test_commit=test_commit,
        implementer_turn=implementer_turn,
        reviewer_turn=reviewer_turn,
        review_decision=review,
        final_state=final_state,
    )


def _complete_after_implementer_success_with_reviewer_turn(
    request: SingleSubphaseTransactionRequest,
    ctx: _PreparedTransaction,
    test_commit: GitCommitResult,
    implementer_turn: ImplementerTurnResult,
    *,
    agent_turn_runtime: AgentRuntime,
    capture_rework: bool = False,
) -> (
    SingleSubphaseTransactionResult
    | ReviewerBlockedTransactionResult
    | ReviewReworkTransactionResult
):
    """Blocker-aware Sub-phase 9.7 composite Reviewer stage.

    Shares the exact ``_verify_after_implementer`` prefix and
    ``_handle_review_decision`` suffix with the legacy path. A
    ``COMPLETED`` composite report feeds its ``review_decision`` into
    the unchanged verdict/commit handling -- unless *capture_rework* is
    set and the verdict is ``REWORK``, in which case
    :func:`_capture_review_rework` handles it instead (Sub-phase 9.10
    only; the default ``False`` preserves
    :func:`run_single_subphase_transaction_with_blockers`'s exact frozen
    Sub-phase 9.7 behavior of raising :class:`SupervisorTransactionError`
    for REWORK). A ``BLOCKED`` report is dispatched through
    :func:`~lockstep.supervisor.escalation.dispatch_escalation` exactly
    once (imported lazily, mirroring the Sub-phase 9.6 Implementer
    branch, to avoid the runtime/Supervisor import cycle a module-level
    import would create), the transaction transitions
    ``REVIEWING -> HALTED``, and this function returns a
    :class:`ReviewerBlockedTransactionResult` -- never re-running
    verification, never re-entering the Reviewer, and never committing.
    """
    _verify_after_implementer(request, ctx, test_commit)

    # Built only now, after the report, verification evidence and diff exist, and
    # rebuilt from durable state; a stale or drifted handoff is never launched.
    try:
        reviewer_prompt = _late_reviewer_prompt(
            request,
            worktree_path=ctx.worktree_root,
            attempt=_TRANSACTION_ATTEMPT,
            base_prompt=request.reviewer_prompt,
        )
    except (HandoffError, EvidenceStoreError):
        _halt_after_agent_failure(
            request, ctx.journal_path, ctx.state_path, stage="reviewer_handoff"
        )
        raise

    try:
        reviewer_turn = invoke_reviewer_turn(
            agent_turn_runtime,
            phase_id=request.phase_id,
            subphase_id=request.subphase_id,
            attempt=_TRANSACTION_ATTEMPT,
            prompt=reviewer_prompt,
            cwd=ctx.worktree_root,
            timeout_seconds=request.agent_timeout_seconds,
            max_output_bytes=request.max_output_bytes,
            termination_grace_seconds=request.termination_grace_seconds,
            run_id=request.run_id,
        )
    except ReviewerTurnError:
        _halt_after_agent_failure(request, ctx.journal_path, ctx.state_path, stage="reviewer")
        raise

    if reviewer_turn.report.status is AgentTurnStatus.COMPLETED:
        review = reviewer_turn.report.review_decision
        assert review is not None
        assert reviewer_turn.escalation_request is None
        if capture_rework and review.verdict is ReviewVerdict.REWORK:
            return _capture_review_rework(
                request, ctx, test_commit, implementer_turn, reviewer_turn, review
            )
        return _handle_review_decision(request, ctx, test_commit, review)

    assert reviewer_turn.escalation_request is not None

    # Deferred import: see the identical rationale on the Implementer-blocked
    # branch of ``run_single_subphase_transaction_with_blockers`` below.
    from lockstep.escalation_transport import PlannerDecisionTransportError
    from lockstep.supervisor.escalation import dispatch_escalation

    try:
        escalation_result = dispatch_escalation(
            agent_turn_runtime,
            request=reviewer_turn.escalation_request,
            timeout_seconds=request.agent_timeout_seconds,
            max_output_bytes=request.max_output_bytes,
            termination_grace_seconds=request.termination_grace_seconds,
            run_id=request.run_id,
        )
    except (PlannerDecisionTransportError, EscalationProtocolError):
        _halt_after_agent_failure(request, ctx.journal_path, ctx.state_path, stage="escalation")
        raise
    _record_escalation_dispatched(request, escalation_result)

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.REVIEWING,
        target=WorkflowState.HALTED,
        sequence=_next_sequence(ctx.journal_path),
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
    )
    _emit(
        request,
        ExecutionEventKind.TRANSACTION_HALTED,
        stop_reason=stop_reason_for_escalation(reviewer_turn.escalation_request.category),
        cause=cause_for_escalation(reviewer_turn.escalation_request.category),
        detail=reviewer_turn.escalation_request.category.value,
    )

    final_state = load_verified_state(ctx.state_path, ctx.journal_path)
    if final_state is None or final_state.workflow_state != WorkflowState.HALTED:
        raise SupervisorTransactionError(
            stage="reconciliation",
            reason="final journal replay does not reach HALTED",
        )

    return ReviewerBlockedTransactionResult(
        test_commit=test_commit,
        implementer_turn=implementer_turn,
        reviewer_turn=reviewer_turn,
        escalation=escalation_result,
        final_state=final_state,
    )


def run_single_subphase_transaction(
    request: SingleSubphaseTransactionRequest,
    *,
    parent_env: Mapping[str, str],
    planner_adapter: AgentAdapter,
    implementer_adapter: AgentAdapter,
    reviewer_adapter: AgentAdapter,
) -> SingleSubphaseTransactionResult:
    """Drive one Sub-phase from ``READY`` to ``SUBPHASE_COMPLETE``."""
    ctx = _prepare_transaction(request, parent_env=parent_env)

    test_commit = _author_tests(
        request,
        ctx,
        parent_env=parent_env,
        planner_adapter=planner_adapter,
    )

    implementer_result = invoke_agent(
        implementer_adapter,
        _agent_request(
            role=AgentRole.IMPLEMENTER,
            prompt=request.implementer_prompt,
            request=request,
            cwd=ctx.worktree_root,
            stage=InvocationStage.IMPLEMENTATION,
        ),
        parent_env=parent_env,
        runtime_dir=request.runtime_dir,
    )
    if implementer_result.process.returncode != 0:
        _halt_after_agent_failure(request, ctx.journal_path, ctx.state_path, stage="implementer")
        raise SupervisorTransactionError(
            stage="implementer",
            reason=(
                f"implementer process exited with returncode "
                f"{implementer_result.process.returncode}"
            ),
        )

    return _complete_after_implementer_success(
        request,
        ctx,
        test_commit,
        parent_env=parent_env,
        reviewer_adapter=reviewer_adapter,
    )


def _require_agent_turn_runtime_matches_request(
    request: SingleSubphaseTransactionRequest,
    agent_turn_runtime: AgentRuntime,
) -> None:
    if request.runtime_dir != agent_turn_runtime.runtime_dir:
        raise SupervisorTransactionError(
            stage="runtime_consistency",
            reason="agent-turn runtime directory does not match the transaction request",
        )


def _run_blocker_capable_transaction(
    request: SingleSubphaseTransactionRequest,
    *,
    agent_turn_runtime: AgentRuntime,
    capture_rework: bool,
) -> (
    SingleSubphaseTransactionResult
    | ImplementerBlockedTransactionResult
    | ReviewerBlockedTransactionResult
    | ReviewReworkTransactionResult
):
    """Shared blocker-capable execution pipeline (Sub-phase 9.7 + 9.10 policy toggle).

    Drives Planner test authoring through the structured, blocker-aware
    Implementer and (on Implementer success) composite Reviewer turns --
    the exact single algorithm both
    :func:`run_single_subphase_transaction_with_blockers` and
    :func:`run_single_subphase_transaction_with_retry_checkpoint` share,
    so neither public entrypoint duplicates it. *capture_rework* is the
    only behavioral difference between the two callers: ``False``
    preserves the frozen Sub-phase 9.7 semantics of
    :func:`_handle_review_decision` raising
    :class:`SupervisorTransactionError` for a ``REWORK`` verdict;
    ``True`` (Sub-phase 9.10 only) routes a ``COMPLETED`` + ``REWORK``
    composite Reviewer report through :func:`_capture_review_rework`
    instead, returning a :class:`ReviewReworkTransactionResult`. Requires
    *request* and *agent_turn_runtime* to share the same ``runtime_dir``
    before any agent inference occurs.
    """
    _require_agent_turn_runtime_matches_request(request, agent_turn_runtime)

    ctx = _prepare_transaction(request, parent_env=agent_turn_runtime.transaction_parent_env)

    test_commit = _author_tests(
        request,
        ctx,
        parent_env=agent_turn_runtime.transaction_parent_env,
        planner_adapter=agent_turn_runtime.adapters.planner,
    )

    try:
        implementer_prompt = _initial_implementer_prompt(request, ctx.worktree_root)
    except (HandoffError, EvidenceStoreError):
        _halt_after_agent_failure(
            request, ctx.journal_path, ctx.state_path, stage="implementer_handoff"
        )
        raise

    try:
        implementer_turn = invoke_implementer_turn(
            agent_turn_runtime,
            phase_id=request.phase_id,
            subphase_id=request.subphase_id,
            attempt=_TRANSACTION_ATTEMPT,
            prompt=implementer_prompt,
            cwd=ctx.worktree_root,
            timeout_seconds=request.agent_timeout_seconds,
            max_output_bytes=request.max_output_bytes,
            termination_grace_seconds=request.termination_grace_seconds,
            run_id=request.run_id,
        )
    except AgentTurnError:
        _halt_after_agent_failure(request, ctx.journal_path, ctx.state_path, stage="implementer")
        raise

    if implementer_turn.report.status is AgentTurnStatus.COMPLETED:
        assert implementer_turn.escalation_request is None
        _record_implementation_report(request, implementer_turn, _TRANSACTION_ATTEMPT)
        return _complete_after_implementer_success_with_reviewer_turn(
            request,
            ctx,
            test_commit,
            implementer_turn,
            agent_turn_runtime=agent_turn_runtime,
            capture_rework=capture_rework,
        )

    assert implementer_turn.escalation_request is not None

    # Deferred import: ``lockstep.supervisor.escalation`` imports
    # ``lockstep.runtime`` at module level, and ``lockstep.runtime`` imports
    # this package (``lockstep.supervisor``) at module level. Importing
    # ``dispatch_escalation`` here -- at call time, after both modules have
    # already finished loading -- avoids that cycle without modifying either
    # frozen module.
    from lockstep.escalation_transport import PlannerDecisionTransportError
    from lockstep.supervisor.escalation import dispatch_escalation

    try:
        escalation_result = dispatch_escalation(
            agent_turn_runtime,
            request=implementer_turn.escalation_request,
            timeout_seconds=request.agent_timeout_seconds,
            max_output_bytes=request.max_output_bytes,
            termination_grace_seconds=request.termination_grace_seconds,
            run_id=request.run_id,
        )
    except (PlannerDecisionTransportError, EscalationProtocolError):
        _halt_after_agent_failure(request, ctx.journal_path, ctx.state_path, stage="escalation")
        raise
    _record_escalation_dispatched(request, escalation_result)

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.IMPLEMENTING,
        target=WorkflowState.HALTED,
        sequence=_next_sequence(ctx.journal_path),
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
    )
    _emit(
        request,
        ExecutionEventKind.TRANSACTION_HALTED,
        stop_reason=stop_reason_for_escalation(implementer_turn.escalation_request.category),
        cause=cause_for_escalation(implementer_turn.escalation_request.category),
        detail=implementer_turn.escalation_request.category.value,
    )

    final_state = load_verified_state(ctx.state_path, ctx.journal_path)
    if final_state is None or final_state.workflow_state != WorkflowState.HALTED:
        raise SupervisorTransactionError(
            stage="reconciliation",
            reason="final journal replay does not reach HALTED",
        )

    return ImplementerBlockedTransactionResult(
        test_commit=test_commit,
        implementer_turn=implementer_turn,
        escalation=escalation_result,
        final_state=final_state,
    )


def run_single_subphase_transaction_with_blockers(
    request: SingleSubphaseTransactionRequest,
    *,
    agent_turn_runtime: AgentRuntime,
) -> (
    SingleSubphaseTransactionResult
    | ImplementerBlockedTransactionResult
    | ReviewerBlockedTransactionResult
):
    """Drive one Sub-phase using the structured, blocker-aware Implementer and Reviewer turns.

    Thin, behavior-preserving wrapper around the shared
    :func:`_run_blocker_capable_transaction` pipeline with
    ``capture_rework=False`` -- the exact frozen Sub-phase 9.7 contract:
    a ``COMPLETED`` composite Reviewer report enters the existing
    verdict/commit suffix and returns a
    :class:`SingleSubphaseTransactionResult` on ``APPROVE`` (``REWORK``/
    ``HALT`` still raise :class:`SupervisorTransactionError`); a
    ``BLOCKED`` composite Reviewer report returns a
    :class:`ReviewerBlockedTransactionResult`; a ``BLOCKED`` Implementer
    report returns an :class:`ImplementerBlockedTransactionResult` --
    every Sub-phase 9.5 disposition (including ``RESUME_AGENT``) halts
    here. Neither blocked branch ever re-enters the blocked role, never
    runs deterministic verification more than once, and never commits
    partial work.
    """
    result = _run_blocker_capable_transaction(
        request,
        agent_turn_runtime=agent_turn_runtime,
        capture_rework=False,
    )
    assert not isinstance(result, ReviewReworkTransactionResult)
    return result


def _current_attempt_state(request: SingleSubphaseTransactionRequest) -> AttemptState:
    # Lazy import: ``lockstep.retry`` imports ``lockstep.supervisor.escalation``
    # at module level, which imports ``lockstep.runtime`` at module level,
    # which imports this package at module level -- the same shape of cycle
    # the ``dispatch_escalation`` import above already avoids by staying
    # function-local.
    from lockstep.retry import AttemptState

    return AttemptState(
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        current_attempt=_TRANSACTION_ATTEMPT,
    )


def _record_retry_decision(
    request: SingleSubphaseTransactionRequest, checkpoint: RetryCheckpoint
) -> None:
    """Record the durable retry decision a checkpoint carries, after it is persisted.

    ``RETRY_AUTHORIZED`` carries the next (authorized) attempt and the
    target role; an exhausted checkpoint carries the attempt that used up
    the budget. Observational only: the checkpoint file, not this event,
    is the retry authority.
    """
    target_role = checkpoint.retry_request.target_role
    next_state = checkpoint.next_attempt_state
    # Why the work repeats (or would have): the authority's own evidence, never
    # the budget. Exhaustion keeps that cause and adds why automation stopped.
    cause = _cause_for_retry_authority(checkpoint)
    if next_state is None:
        _emit(
            request,
            ExecutionEventKind.RETRY_EXHAUSTED,
            attempt=checkpoint.attempt_state.current_attempt,
            role=target_role,
            stop_reason=StopReason.MAX_REWORK_EXCEEDED,
            cause=cause,
        )
        return
    _emit(
        request,
        ExecutionEventKind.RETRY_AUTHORIZED,
        attempt=next_state.current_attempt,
        role=target_role,
        cause=cause,
    )


def _cause_for_retry_authority(checkpoint: RetryCheckpoint) -> FailureCause | None:
    from lockstep.retry_checkpoint import RetryAuthorityKind

    authority = checkpoint.authority
    if authority.kind == RetryAuthorityKind.REVIEW_REWORK:
        assert authority.review_decision is not None
        return cause_for_review_verdict(authority.review_decision.verdict)
    assert authority.escalation_request is not None
    return cause_for_escalation(authority.escalation_request.category)


def _freeze_and_record_retry(
    request: SingleSubphaseTransactionRequest, checkpoint: RetryCheckpoint
) -> RetryCheckpoint:
    from lockstep.retry_checkpoint import freeze_retry_checkpoint

    frozen = freeze_retry_checkpoint(request.runtime_dir, checkpoint)
    _record_retry_decision(request, frozen)
    return frozen


def _checkpoint_from_implementer_blocked(
    request: SingleSubphaseTransactionRequest,
    retry_budget: RetryBudget,
    result: ImplementerBlockedTransactionResult,
) -> ImplementerBlockedTransactionResult | RetryCheckpointedTransactionResult:
    from lockstep.retry_checkpoint import create_retry_checkpoint_from_escalation

    checkpoint = create_retry_checkpoint_from_escalation(
        attempt_state=_current_attempt_state(request),
        budget=retry_budget,
        result=result.escalation,
    )
    if checkpoint is None:
        return result

    frozen = _freeze_and_record_retry(request, checkpoint)
    return RetryCheckpointedTransactionResult(source_result=result, checkpoint=frozen)


def _checkpoint_from_reviewer_blocked(
    request: SingleSubphaseTransactionRequest,
    retry_budget: RetryBudget,
    result: ReviewerBlockedTransactionResult,
) -> ReviewerBlockedTransactionResult | RetryCheckpointedTransactionResult:
    from lockstep.retry_checkpoint import create_retry_checkpoint_from_escalation

    checkpoint = create_retry_checkpoint_from_escalation(
        attempt_state=_current_attempt_state(request),
        budget=retry_budget,
        result=result.escalation,
    )
    if checkpoint is None:
        return result

    frozen = _freeze_and_record_retry(request, checkpoint)
    return RetryCheckpointedTransactionResult(source_result=result, checkpoint=frozen)


def _checkpoint_from_review_rework(
    request: SingleSubphaseTransactionRequest,
    retry_budget: RetryBudget,
    result: ReviewReworkTransactionResult,
) -> RetryCheckpointedTransactionResult:
    from lockstep.retry_checkpoint import create_retry_checkpoint_from_review

    checkpoint = create_retry_checkpoint_from_review(
        attempt_state=_current_attempt_state(request),
        budget=retry_budget,
        decision=result.review_decision,
    )
    # A REWORK verdict always carries retry authority (frozen 9.8
    # ``retry_request_from_review`` contract) -- ``None`` here would mean
    # this function was called for a non-REWORK decision, a caller defect.
    assert checkpoint is not None

    frozen = _freeze_and_record_retry(request, checkpoint)
    return RetryCheckpointedTransactionResult(source_result=result, checkpoint=frozen)


def run_single_subphase_transaction_with_retry_checkpoint(
    request: SingleSubphaseTransactionRequest,
    *,
    agent_turn_runtime: AgentRuntime,
    retry_budget: RetryBudget,
) -> (
    SingleSubphaseTransactionResult
    | ImplementerBlockedTransactionResult
    | ReviewerBlockedTransactionResult
    | RetryCheckpointedTransactionResult
):
    """Drive one Sub-phase, freezing durable retry authority when it occurs.

    Runs the exact shared :func:`_run_blocker_capable_transaction`
    pipeline with ``capture_rework=True``, so a Reviewer ``COMPLETED`` +
    ``REWORK`` report is captured as a :class:`ReviewReworkTransactionResult`
    instead of raising -- the one Sub-phase 9.10 behavioral difference
    from :func:`run_single_subphase_transaction_with_blockers`. A plain
    :class:`SingleSubphaseTransactionResult` (``APPROVE``) is returned
    unchanged, with no checkpoint. Every other outcome is offered to the
    frozen Sub-phase 9.8/9.9 retry protocol via
    :func:`~lockstep.retry_checkpoint.create_retry_checkpoint_from_escalation`/
    :func:`~lockstep.retry_checkpoint.create_retry_checkpoint_from_review`
    using *retry_budget* (a required argument with no default, config,
    environment, or CLI source) and the canonical attempt-1
    :class:`~lockstep.retry.AttemptState` for *request*; a nonretryable
    outcome (``SUPERVISOR_ACTION_REQUIRED``, ``REPLAN_SUBPHASE``,
    ``HUMAN_REQUIRED``, ``RUN_HALT``, or Reviewer ``HALT``) returns its
    original blocked/error result unchanged, with no checkpoint written.
    A retryable outcome is frozen via
    :func:`~lockstep.retry_checkpoint.freeze_retry_checkpoint` -- only
    after that freeze succeeds is a :class:`RetryCheckpointedTransactionResult`
    returned; a freeze failure (:class:`~lockstep.retry_checkpoint.RetryCheckpointStoreError`)
    propagates unchanged, leaving the run ``HALTED`` with no checkpoint.
    Still runs only the initial transaction attempt: no agent is ever
    invoked a second time, and no checkpoint is ever consumed, claimed,
    or deleted.
    """
    result = _run_blocker_capable_transaction(
        request,
        agent_turn_runtime=agent_turn_runtime,
        capture_rework=True,
    )

    if isinstance(result, SingleSubphaseTransactionResult):
        return result

    if isinstance(result, ImplementerBlockedTransactionResult):
        return _checkpoint_from_implementer_blocked(request, retry_budget, result)

    if isinstance(result, ReviewerBlockedTransactionResult):
        return _checkpoint_from_reviewer_blocked(request, retry_budget, result)

    return _checkpoint_from_review_rework(request, retry_budget, result)


# ============================================================================
# Sub-phase 9.13: Controlled Re-entry / At-Most-Once Resume
#
# Composes the frozen Sub-phase 9.11 durable resume claim protocol
# (:mod:`lockstep.resume`) and Sub-phase 9.12 durable resume settlement
# protocol (:mod:`lockstep.resume_settlement`) into the first production
# path that may actually execute attempt N+1:
#
#     HALTED + retry/checkpoint.json
#         -> inspect_resume -> claim_retry_checkpoint / existing CLAIMED
#         -> request/runtime/state preflight -> executability validation
#         -> mark_resume_started -> durable STARTED boundary
#         -> HALTED -> IMPLEMENTING / HALTED -> REVIEWING (9.13 FSM edges)
#         -> invoke the exact target role at the exact attempt N+1
#         -> known result -> ResumeSettlement -> finalize_resume_settlement
#
# Provides at-most-once automatic launch per retry attempt, never
# exactly-once external inference: a crash after STARTED but before a
# durable result settlement leaves STARTED with no settlement, which is
# never automatically replayed. `lockstep.resume`/`lockstep.resume_settlement`
# are imported only inside resume-only call sites (mirroring the existing
# lazy `lockstep.retry`/`lockstep.retry_checkpoint` convention) to avoid the
# runtime/Supervisor import cycle their own imports would otherwise create.
# ============================================================================


class ResumeExecutionDisposition(StrEnum):
    """Where one public :func:`resume_single_subphase_transaction` call landed."""

    NO_CHECKPOINT = "no_checkpoint"
    RETRY_EXHAUSTED = "retry_exhausted"
    STARTED_RECOVERY_REQUIRED = "started_recovery_required"
    AUTHORITY_NOT_EXECUTABLE = "authority_not_executable"
    SETTLED = "settled"


@dataclass(frozen=True, slots=True)
class ResumeExecutionResult:
    """Durable outcome of one public resume call.

    ``claim`` is excluded from :func:`repr` so logging a result never
    dumps embedded checkpoint authority. ``claim`` is ``None`` only for
    :attr:`ResumeExecutionDisposition.NO_CHECKPOINT` and
    :attr:`ResumeExecutionDisposition.RETRY_EXHAUSTED` -- every other
    disposition carries the exact claim the call acted on. ``settlement``
    is non-``None`` only for :attr:`ResumeExecutionDisposition.SETTLED`.
    ``final_state`` is populated only when a fresh durable workflow-state
    snapshot was produced by this call (a known ``COMPLETED`` outcome);
    settlement-only recovery calls leave it ``None`` since they mutate no
    workflow state.
    """

    disposition: ResumeExecutionDisposition
    claim: ResumeClaim | None = field(default=None, repr=False)
    settlement: ResumeSettlement | None = None
    final_state: RunStateSnapshot | None = None


class ResumeExecutionError(Exception):
    """A Supervisor-owned resume precondition failure.

    Carries a short ``stage`` naming the precondition that failed and a
    ``reason`` explaining why. Reserved for resume-precondition failures
    this layer owns (request/claim identity mismatch, workflow state
    incompatible with the claim, unsupported resume target role) --
    never used to wrap :class:`~lockstep.resume.ResumeStoreError`,
    :class:`~lockstep.resume_settlement.ResumeSettlementStoreError`,
    :class:`~lockstep.retry_checkpoint.RetryCheckpointStoreError`, or
    :class:`~lockstep.retry.RetryProtocolError`.
    """

    def __init__(self, *, stage: str, reason: str) -> None:
        self.stage = stage
        self.reason = reason
        super().__init__(f"resume execution error during {stage}: {reason}")


def _next_sequence(journal_path: Path) -> int:
    return len(read_events(journal_path)) + 1


def _sorted_implementation_paths(request: SingleSubphaseTransactionRequest) -> tuple[str, ...]:
    return tuple(sorted(request.implementation_paths))


def _resume_verification_env(
    request: SingleSubphaseTransactionRequest,
    parent_env: Mapping[str, str],
    attempt: AttemptNumber,
) -> Mapping[str, str]:
    return _verification_env_for(
        parent_env,
        cache_root=_verification_cache_root(request),
        purpose="verify",
        attempt=attempt,
    )


def _require_resume_identity_matches_claim(
    request: SingleSubphaseTransactionRequest,
    claim: ResumeClaim,
) -> None:
    attempt_state = claim.checkpoint.attempt_state
    next_attempt_state = claim.checkpoint.next_attempt_state
    assert next_attempt_state is not None

    if (
        request.phase_id != attempt_state.phase_id
        or request.phase_id != next_attempt_state.phase_id
    ):
        raise ResumeExecutionError(
            stage="resume_identity",
            reason="transaction request does not match the claimed phase",
        )
    if (
        request.subphase_id != attempt_state.subphase_id
        or request.subphase_id != next_attempt_state.subphase_id
    ):
        raise ResumeExecutionError(
            stage="resume_identity",
            reason="transaction request does not match the claimed subphase",
        )


def _require_workflow_state_halted(request: SingleSubphaseTransactionRequest) -> None:
    journal_path = request.runtime_dir / "events.jsonl"
    state_path = request.runtime_dir / "state.json"
    current = load_verified_state(state_path, journal_path)
    if current is None or current.workflow_state != WorkflowState.HALTED:
        raise ResumeExecutionError(
            stage="workflow_state",
            reason="workflow state is not halted",
        )


def _frozen_correction_authorized_paths(claim: ResumeClaim) -> tuple[str, ...] | None:
    from lockstep.retry_checkpoint import RetryAuthorityKind

    authority = claim.checkpoint.authority
    if authority.kind != RetryAuthorityKind.ESCALATION_RESUME:
        return None
    decision = authority.planner_decision
    assert decision is not None
    if decision.kind != PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION:
        return None
    return decision.authorized_paths


def _bounded_change_authorized_paths(claim: ResumeClaim) -> tuple[str, ...] | None:
    from lockstep.retry_checkpoint import RetryAuthorityKind

    authority = claim.checkpoint.authority
    if authority.kind != RetryAuthorityKind.ESCALATION_RESUME:
        return None
    decision = authority.planner_decision
    assert decision is not None
    if decision.kind != PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE:
        return None
    return decision.authorized_paths


def _resume_authority_is_executable(claim: ResumeClaim, target_role: AgentRole) -> bool:
    from lockstep.retry_checkpoint import RetryAuthorityKind

    authority = claim.checkpoint.authority

    if authority.kind == RetryAuthorityKind.REVIEW_REWORK:
        if target_role != AgentRole.IMPLEMENTER:
            raise ResumeExecutionError(
                stage="executability",
                reason="review rework authority must target the implementer",
            )
        return True

    assert authority.kind == RetryAuthorityKind.ESCALATION_RESUME
    decision = authority.planner_decision
    assert decision is not None

    if decision.kind == PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE:
        if target_role == AgentRole.REVIEWER:
            return len(decision.authorized_paths) == 0
        return True

    if decision.kind == PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION:
        if target_role == AgentRole.REVIEWER:
            return False
        if len(decision.authorized_paths) == 0:
            raise ResumeExecutionError(
                stage="executability",
                reason="frozen artifact correction requires at least one authorized path",
            )
        return True

    raise ResumeExecutionError(
        stage="executability",
        reason="planner decision kind does not authorize resume",
    )


def _deterministic_json(payload: object) -> str:
    return json.dumps(payload, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _escalation_resume_prompt_suffix(
    claim: ResumeClaim,
    executed_attempt_number: AttemptNumber,
    target_role: AgentRole,
) -> str:
    from lockstep.retry_checkpoint import RetryAuthorityKind

    authority = claim.checkpoint.authority
    assert authority.kind == RetryAuthorityKind.ESCALATION_RESUME
    escalation_request = authority.escalation_request
    decision = authority.planner_decision
    assert escalation_request is not None
    assert decision is not None

    payload = {
        "resume_authority": "escalation_resume",
        "attempt": executed_attempt_number.root,
        "target_role": target_role.value,
        "escalation": {
            "category": escalation_request.category.value,
            "question": escalation_request.question,
            "evidence": list(escalation_request.evidence),
        },
        "planner_decision": {
            "kind": decision.kind.value,
            "rationale": decision.rationale,
            "instructions": list(decision.instructions),
            "authorized_paths": list(decision.authorized_paths),
        },
    }
    return (
        "\n\n---\nResume authority (host-supplied, deterministic):\n"
        + _deterministic_json(payload)
        + "\n"
    )


def _review_rework_prompt_suffix(
    claim: ResumeClaim,
    executed_attempt_number: AttemptNumber,
    target_role: AgentRole,
) -> str:
    from lockstep.retry_checkpoint import RetryAuthorityKind

    authority = claim.checkpoint.authority
    assert authority.kind == RetryAuthorityKind.REVIEW_REWORK
    review_decision = authority.review_decision
    assert review_decision is not None

    # Review Findings are evidence and repair guidance, never requirement or
    # retry authority: the durable retry authority is the host-owned checkpoint.
    payload = {
        "retry_trigger": "review_rework",
        "attempt": executed_attempt_number.root,
        "target_role": target_role.value,
        "review": {
            "summary": review_decision.summary,
            "findings": [
                {
                    "summary": finding.summary,
                    "evidence": finding.evidence,
                    "file_path": finding.file_path,
                    "acceptance_criterion_id": finding.acceptance_criterion_id,
                }
                for finding in review_decision.findings
            ],
        },
    }
    return (
        "\n\n---\nReview evidence / repair guidance "
        "(host-supplied, deterministic; not requirement authority):\n"
        + _deterministic_json(payload)
        + "\n"
    )


def _resume_prompt_suffix(
    claim: ResumeClaim,
    executed_attempt_number: AttemptNumber,
    target_role: AgentRole,
) -> str:
    from lockstep.retry_checkpoint import RetryAuthorityKind

    authority = claim.checkpoint.authority
    if authority.kind == RetryAuthorityKind.REVIEW_REWORK:
        return _review_rework_prompt_suffix(claim, executed_attempt_number, target_role)
    return _escalation_resume_prompt_suffix(claim, executed_attempt_number, target_role)


def _prior_review_decisions(claim: ResumeClaim) -> tuple[ReviewDecision, ...]:
    """The Review Decision that caused this retry, as history for the next Reviewer."""
    from lockstep.retry_checkpoint import RetryAuthorityKind

    authority = claim.checkpoint.authority
    if authority.kind == RetryAuthorityKind.REVIEW_REWORK:
        assert authority.review_decision is not None
        return (authority.review_decision,)
    return ()


def _resume_implementer_prompt(
    request: SingleSubphaseTransactionRequest,
    claim: ResumeClaim,
    executed_attempt: AttemptState,
) -> str:
    """The fresh Implementer's prompt for a resumed attempt.

    A legacy request keeps its base prompt plus the deterministic suffix. A request
    that carries its Contract gets the canonical rework handoff: the original frozen
    authority and protected tests, the host's retry control, and Review Findings and
    prior verification as repair evidence. A Planner-authorized escalation resume also
    keeps its existing deterministic suffix, since that decision is genuine control
    authority; a Review ``REWORK`` has no suffix because its findings are only evidence.
    """
    from lockstep.retry_checkpoint import RetryAuthorityKind

    attempt = executed_attempt.current_attempt
    suffix = _resume_prompt_suffix(claim, attempt, AgentRole.IMPLEMENTER)
    if request.contract is None:
        return request.implementer_prompt + suffix

    authority = claim.checkpoint.authority
    if authority.kind == RetryAuthorityKind.REVIEW_REWORK:
        retry = RetryControl(kind="review_rework", attempt=attempt)
        review_decision = authority.review_decision
        tail = ""
    else:
        decision = authority.planner_decision
        assert decision is not None
        retry = RetryControl(
            kind="escalation_resume",
            attempt=attempt,
            authorized_paths=tuple(decision.authorized_paths),
            instructions=tuple(decision.instructions),
        )
        review_decision = None
        tail = suffix

    handoff = build_rework_handoff(
        runtime_dir=request.runtime_dir,
        worktree_path=request.worktree_path,
        run_id=request.run_id,
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        attempt=attempt,
        contract=request.contract,
        test_paths=request.test_paths,
        retry=retry,
        review_decision=review_decision,
    )
    return request.implementer_prompt + render_rework_handoff(handoff) + tail


def _record_resume_settled(
    request: SingleSubphaseTransactionRequest,
    started_claim: ResumeClaim,
    outcome: ResumeSettlementOutcome,
) -> None:
    """Record a durable settlement (``detail`` is the existing outcome vocabulary)."""
    executed = started_claim.checkpoint.next_attempt_state
    assert executed is not None
    _emit(
        request,
        ExecutionEventKind.RESUME_SETTLED,
        attempt=executed.current_attempt,
        role=started_claim.checkpoint.retry_request.target_role,
        detail=outcome.value,
    )


def _settle_and_transition_to_halted(
    request: SingleSubphaseTransactionRequest,
    started_claim: ResumeClaim,
    outcome: ResumeSettlementOutcome,
    journal_path: Path,
    state_path: Path,
    *,
    halt_detail: str,
    cause: FailureCause | None = None,
    stop_reason: StopReason | None = None,
    next_checkpoint: RetryCheckpoint | None = None,
) -> ResumeExecutionResult:
    from lockstep.resume_settlement import ResumeSettlement, finalize_resume_settlement

    current = load_verified_state(state_path, journal_path)
    assert current is not None

    _persist_transition(
        run_id=request.run_id,
        source=current.workflow_state,
        target=WorkflowState.HALTED,
        sequence=_next_sequence(journal_path),
        journal_path=journal_path,
        state_path=state_path,
    )
    executed = started_claim.checkpoint.next_attempt_state
    assert executed is not None
    _emit(
        request,
        ExecutionEventKind.TRANSACTION_HALTED,
        attempt=executed.current_attempt,
        stop_reason=stop_reason,
        cause=cause,
        detail=halt_detail,
    )

    settlement = ResumeSettlement(
        schema_version=1,
        claim=started_claim,
        outcome=outcome,
        next_checkpoint=next_checkpoint,
    )
    finalized = finalize_resume_settlement(request.runtime_dir, settlement)
    if next_checkpoint is not None:
        _record_retry_decision(request, next_checkpoint)
    _record_resume_settled(request, started_claim, outcome)

    return ResumeExecutionResult(
        disposition=ResumeExecutionDisposition.SETTLED,
        claim=finalized.claim,
        settlement=finalized,
    )


def _settle_execution_failed(
    request: SingleSubphaseTransactionRequest,
    started_claim: ResumeClaim,
    journal_path: Path,
    state_path: Path,
) -> None:
    from lockstep.resume_settlement import ResumeSettlementOutcome

    _settle_and_transition_to_halted(
        request,
        started_claim,
        ResumeSettlementOutcome.EXECUTION_FAILED,
        journal_path,
        state_path,
        halt_detail="execution_failed",
    )


def _partition_frozen_correction_dirty_paths(
    request: SingleSubphaseTransactionRequest,
    authorized_frozen_paths: tuple[str, ...],
    dirty_paths: tuple[str, ...],
    attempt: AttemptNumber,
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    authorized_set = set(authorized_frozen_paths)
    ordinary_set = set(request.implementation_paths)
    dirty_set = set(dirty_paths)

    frozen_touched = dirty_set & authorized_set
    ordinary_touched = dirty_set & ordinary_set
    unexpected = dirty_set - authorized_set - ordinary_set

    if unexpected:
        _emit_abort(
            request,
            stage="frozen_correction_scope",
            cause=FailureCause.SCOPE_VIOLATION,
            stop_reason=StopReason.OUT_OF_SCOPE_CHANGE,
            attempt=attempt,
        )
        raise SupervisorTransactionError(
            stage="frozen_correction_scope",
            reason=(
                "resumed implementer produced changes outside the authorized "
                "frozen-correction and production scope"
            ),
        )
    if not frozen_touched:
        _emit_abort(
            request, stage="frozen_correction_scope", cause=None, stop_reason=None, attempt=attempt
        )
        raise SupervisorTransactionError(
            stage="frozen_correction_scope",
            reason="resumed implementer did not change any authorized frozen artifact path",
        )

    return tuple(sorted(frozen_touched)), tuple(sorted(ordinary_touched))


def _handle_resumed_blocked(
    request: SingleSubphaseTransactionRequest,
    agent_turn_runtime: AgentRuntime,
    started_claim: ResumeClaim,
    executed_attempt: AttemptState,
    escalation_request: EscalationRequest,
    journal_path: Path,
    state_path: Path,
) -> ResumeExecutionResult:
    from lockstep.escalation_transport import PlannerDecisionTransportError
    from lockstep.resume_settlement import ResumeSettlementOutcome
    from lockstep.retry_checkpoint import create_retry_checkpoint_from_escalation
    from lockstep.supervisor.escalation import dispatch_escalation

    try:
        escalation_result = dispatch_escalation(
            agent_turn_runtime,
            request=escalation_request,
            timeout_seconds=request.agent_timeout_seconds,
            max_output_bytes=request.max_output_bytes,
            termination_grace_seconds=request.termination_grace_seconds,
            run_id=request.run_id,
        )
    except (PlannerDecisionTransportError, EscalationProtocolError):
        _settle_execution_failed(request, started_claim, journal_path, state_path)
        raise
    _record_escalation_dispatched(request, escalation_result)

    checkpoint = create_retry_checkpoint_from_escalation(
        attempt_state=executed_attempt,
        budget=started_claim.checkpoint.budget,
        result=escalation_result,
    )

    category = escalation_request.category.value
    cause = cause_for_escalation(escalation_request.category)
    stop_reason = stop_reason_for_escalation(escalation_request.category)
    if checkpoint is None:
        return _settle_and_transition_to_halted(
            request,
            started_claim,
            ResumeSettlementOutcome.HALTED,
            journal_path,
            state_path,
            halt_detail=category,
            cause=cause,
            stop_reason=stop_reason,
        )

    return _settle_and_transition_to_halted(
        request,
        started_claim,
        ResumeSettlementOutcome.NEXT_RETRY,
        journal_path,
        state_path,
        halt_detail=category,
        cause=cause,
        stop_reason=stop_reason,
        next_checkpoint=checkpoint,
    )


def _require_review_matches_resume(
    review: ReviewDecision,
    request: SingleSubphaseTransactionRequest,
    expected_attempt: AttemptNumber,
) -> None:
    if (
        review.phase_id != request.phase_id
        or review.subphase_id != request.subphase_id
        or review.attempt != expected_attempt
    ):
        raise SupervisorTransactionError(
            stage="review",
            reason="reviewer decision does not match the current resumed attempt",
        )


def _resume_approve(
    request: SingleSubphaseTransactionRequest,
    started_claim: ResumeClaim,
    allowed_impl_paths: tuple[str, ...],
    journal_path: Path,
    state_path: Path,
) -> ResumeExecutionResult:
    from lockstep.resume_settlement import (
        ResumeSettlement,
        ResumeSettlementOutcome,
        finalize_resume_settlement,
    )

    pre_commit_snapshot = inspect_repository(request.worktree_path)
    if _implementer_scope_breached(request, pre_commit_snapshot, allowed_impl_paths):
        raise SupervisorTransactionError(
            stage="pre_commit_integrity",
            reason="worktree drifted between verification and the resumed implementation commit",
        )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.REVIEWING,
        target=WorkflowState.IMPLEMENTATION_COMMIT,
        sequence=_next_sequence(journal_path),
        journal_path=journal_path,
        state_path=state_path,
    )

    if pre_commit_snapshot.dirty_paths:
        commit_exact_paths(
            request.worktree_path,
            expected_branch=request.branch,
            expected_head_sha=pre_commit_snapshot.head_sha,
            paths=pre_commit_snapshot.dirty_paths,
            message=request.implementation_commit_message,
        )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.IMPLEMENTATION_COMMIT,
        target=WorkflowState.SUBPHASE_COMPLETE,
        sequence=_next_sequence(journal_path),
        journal_path=journal_path,
        state_path=state_path,
    )

    final_state = load_verified_state(state_path, journal_path)
    if final_state is None or final_state.workflow_state != WorkflowState.SUBPHASE_COMPLETE:
        raise SupervisorTransactionError(
            stage="reconciliation",
            reason="final journal replay does not reach SUBPHASE_COMPLETE",
        )

    settlement = ResumeSettlement(
        schema_version=1, claim=started_claim, outcome=ResumeSettlementOutcome.COMPLETED
    )
    finalized = finalize_resume_settlement(request.runtime_dir, settlement)
    _record_resume_settled(request, started_claim, ResumeSettlementOutcome.COMPLETED)

    return ResumeExecutionResult(
        disposition=ResumeExecutionDisposition.SETTLED,
        claim=finalized.claim,
        settlement=finalized,
        final_state=final_state,
    )


def _resume_rework(
    request: SingleSubphaseTransactionRequest,
    started_claim: ResumeClaim,
    executed_attempt: AttemptState,
    review: ReviewDecision,
    journal_path: Path,
    state_path: Path,
) -> ResumeExecutionResult:
    from lockstep.resume_settlement import ResumeSettlementOutcome
    from lockstep.retry_checkpoint import create_retry_checkpoint_from_review

    checkpoint = create_retry_checkpoint_from_review(
        attempt_state=executed_attempt,
        budget=started_claim.checkpoint.budget,
        decision=review,
    )
    assert checkpoint is not None

    return _settle_and_transition_to_halted(
        request,
        started_claim,
        ResumeSettlementOutcome.NEXT_RETRY,
        journal_path,
        state_path,
        halt_detail="review_rework",
        cause=cause_for_review_verdict(review.verdict),
        next_checkpoint=checkpoint,
    )


def _invoke_and_handle_resumed_reviewer(
    request: SingleSubphaseTransactionRequest,
    agent_turn_runtime: AgentRuntime,
    started_claim: ResumeClaim,
    executed_attempt: AttemptState,
    prompt: str,
    allowed_impl_paths: tuple[str, ...],
    journal_path: Path,
    state_path: Path,
    prior_decisions: tuple[ReviewDecision, ...] = (),
) -> ResumeExecutionResult:
    from lockstep.resume_settlement import ResumeSettlementOutcome

    # *prompt* is the base reviewer instruction text; the evidence is composed here,
    # at the Reviewer stage, from durable state. A drifted handoff is never launched.
    try:
        reviewer_prompt = _late_reviewer_prompt(
            request,
            worktree_path=request.worktree_path,
            attempt=executed_attempt.current_attempt,
            base_prompt=prompt,
            prior_decisions=prior_decisions,
        )
    except (HandoffError, EvidenceStoreError):
        _settle_execution_failed(request, started_claim, journal_path, state_path)
        raise

    try:
        reviewer_turn = invoke_reviewer_turn(
            agent_turn_runtime,
            phase_id=request.phase_id,
            subphase_id=request.subphase_id,
            attempt=executed_attempt.current_attempt,
            prompt=reviewer_prompt,
            cwd=request.worktree_path,
            timeout_seconds=request.agent_timeout_seconds,
            max_output_bytes=request.max_output_bytes,
            termination_grace_seconds=request.termination_grace_seconds,
            run_id=request.run_id,
        )
    except ReviewerTurnError:
        _settle_execution_failed(request, started_claim, journal_path, state_path)
        raise

    if reviewer_turn.report.status is AgentTurnStatus.BLOCKED:
        assert reviewer_turn.escalation_request is not None
        return _handle_resumed_blocked(
            request,
            agent_turn_runtime,
            started_claim,
            executed_attempt,
            reviewer_turn.escalation_request,
            journal_path,
            state_path,
        )

    review = reviewer_turn.report.review_decision
    assert review is not None
    assert reviewer_turn.escalation_request is None

    _require_review_matches_resume(review, request, executed_attempt.current_attempt)
    _emit(
        request,
        ExecutionEventKind.REVIEW_DECIDED,
        attempt=executed_attempt.current_attempt,
        role=AgentRole.REVIEWER,
        verdict=review.verdict,
        cause=cause_for_review_verdict(review.verdict),
    )

    if review.verdict is ReviewVerdict.APPROVE:
        try:
            return _resume_approve(
                request, started_claim, allowed_impl_paths, journal_path, state_path
            )
        except SupervisorTransactionError:
            _settle_execution_failed(request, started_claim, journal_path, state_path)
            raise

    if review.verdict is ReviewVerdict.REWORK:
        return _resume_rework(
            request, started_claim, executed_attempt, review, journal_path, state_path
        )

    assert review.verdict is ReviewVerdict.HALT
    return _settle_and_transition_to_halted(
        request,
        started_claim,
        ResumeSettlementOutcome.HALTED,
        journal_path,
        state_path,
        halt_detail="review_halt",
    )


def _resume_run_verification(
    request: SingleSubphaseTransactionRequest,
    parent_env: Mapping[str, str],
    attempt: AttemptNumber,
    allowed_impl_paths: tuple[str, ...],
    journal_path: Path,
    state_path: Path,
) -> None:
    post_implementer_snapshot = inspect_repository(request.worktree_path)
    if _implementer_scope_breached(request, post_implementer_snapshot, allowed_impl_paths):
        # The resumed attempt's start HEAD is not carried here, so only the
        # dirty-path evidence (protected vs unapproved path) is attributable.
        cause, stop_reason = _attribute_scope_breach(
            request,
            post_implementer_snapshot,
            post_implementer_snapshot.head_sha,
            allowed_impl_paths,
        )
        _emit_abort(
            request,
            stage="implementation_scope",
            cause=cause,
            stop_reason=stop_reason,
            attempt=attempt,
        )
        raise SupervisorTransactionError(
            stage="implementation_scope",
            reason=(
                "implementer either advanced HEAD or produced dirty paths outside "
                "the approved resumed implementation scope"
            ),
        )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.IMPLEMENTING,
        target=WorkflowState.VERIFYING,
        sequence=_next_sequence(journal_path),
        journal_path=journal_path,
        state_path=state_path,
    )

    _run_verification_stage(
        request,
        cwd=request.worktree_path,
        env=_resume_verification_env(request, parent_env, attempt),
        attempt=attempt,
    )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.VERIFYING,
        target=WorkflowState.REVIEWING,
        sequence=_next_sequence(journal_path),
        journal_path=journal_path,
        state_path=state_path,
    )


def _resume_implementer(
    request: SingleSubphaseTransactionRequest,
    agent_turn_runtime: AgentRuntime,
    started_claim: ResumeClaim,
    executed_attempt: AttemptState,
    journal_path: Path,
    state_path: Path,
) -> ResumeExecutionResult:
    try:
        prompt = _resume_implementer_prompt(request, started_claim, executed_attempt)
    except (HandoffError, EvidenceStoreError):
        _settle_execution_failed(request, started_claim, journal_path, state_path)
        raise

    try:
        implementer_turn = invoke_implementer_turn(
            agent_turn_runtime,
            phase_id=request.phase_id,
            subphase_id=request.subphase_id,
            attempt=executed_attempt.current_attempt,
            prompt=prompt,
            cwd=request.worktree_path,
            timeout_seconds=request.agent_timeout_seconds,
            max_output_bytes=request.max_output_bytes,
            termination_grace_seconds=request.termination_grace_seconds,
            run_id=request.run_id,
        )
    except AgentTurnError:
        _settle_execution_failed(request, started_claim, journal_path, state_path)
        raise

    if implementer_turn.report.status is AgentTurnStatus.BLOCKED:
        assert implementer_turn.escalation_request is not None
        return _handle_resumed_blocked(
            request,
            agent_turn_runtime,
            started_claim,
            executed_attempt,
            implementer_turn.escalation_request,
            journal_path,
            state_path,
        )

    assert implementer_turn.escalation_request is None
    _record_implementation_report(request, implementer_turn, executed_attempt.current_attempt)

    frozen_paths = _frozen_correction_authorized_paths(started_claim)
    bounded_extra_paths = _bounded_change_authorized_paths(started_claim)

    try:
        if frozen_paths is not None:
            pre_snapshot = inspect_repository(request.worktree_path)
            frozen_touched, ordinary_touched = _partition_frozen_correction_dirty_paths(
                request,
                frozen_paths,
                pre_snapshot.dirty_paths,
                executed_attempt.current_attempt,
            )
            commit_exact_subset_paths(
                request.worktree_path,
                expected_branch=request.branch,
                expected_head_sha=pre_snapshot.head_sha,
                paths=frozen_touched,
                message="fix: correct frozen retry artifacts",
            )
            allowed_impl_paths = ordinary_touched
        else:
            extra = set(bounded_extra_paths) if bounded_extra_paths else set()
            allowed_impl_paths = tuple(sorted(set(request.implementation_paths) | extra))

        _resume_run_verification(
            request,
            agent_turn_runtime.transaction_parent_env,
            executed_attempt.current_attempt,
            allowed_impl_paths,
            journal_path,
            state_path,
        )
    except SupervisorTransactionError:
        _settle_execution_failed(request, started_claim, journal_path, state_path)
        raise

    return _invoke_and_handle_resumed_reviewer(
        request,
        agent_turn_runtime,
        started_claim,
        executed_attempt,
        request.reviewer_prompt,
        allowed_impl_paths,
        journal_path,
        state_path,
        prior_decisions=_prior_review_decisions(started_claim),
    )


def _resume_reviewer(
    request: SingleSubphaseTransactionRequest,
    agent_turn_runtime: AgentRuntime,
    started_claim: ResumeClaim,
    executed_attempt: AttemptState,
    journal_path: Path,
    state_path: Path,
) -> ResumeExecutionResult:
    prompt = request.reviewer_prompt + _resume_prompt_suffix(
        started_claim, executed_attempt.current_attempt, AgentRole.REVIEWER
    )
    return _invoke_and_handle_resumed_reviewer(
        request,
        agent_turn_runtime,
        started_claim,
        executed_attempt,
        prompt,
        _sorted_implementation_paths(request),
        journal_path,
        state_path,
    )


def _launch_claimed_resume(
    request: SingleSubphaseTransactionRequest,
    agent_turn_runtime: AgentRuntime,
    claim: ResumeClaim,
) -> ResumeExecutionResult:
    from lockstep.resume import mark_resume_started

    _require_resume_identity_matches_claim(request, claim)
    _require_workflow_state_halted(request)

    target_role = claim.checkpoint.retry_request.target_role
    if target_role not in (AgentRole.IMPLEMENTER, AgentRole.REVIEWER):
        raise ResumeExecutionError(
            stage="target_role",
            reason="resume target role unsupported",
        )

    if not _resume_authority_is_executable(claim, target_role):
        return ResumeExecutionResult(
            disposition=ResumeExecutionDisposition.AUTHORITY_NOT_EXECUTABLE,
            claim=claim,
        )

    executed_attempt = claim.checkpoint.next_attempt_state
    assert executed_attempt is not None

    started_claim = mark_resume_started(request.runtime_dir, claim)
    _emit(
        request,
        ExecutionEventKind.RESUME_STARTED,
        attempt=executed_attempt.current_attempt,
        role=target_role,
    )

    journal_path = request.runtime_dir / "events.jsonl"
    state_path = request.runtime_dir / "state.json"
    active_state = (
        WorkflowState.IMPLEMENTING
        if target_role == AgentRole.IMPLEMENTER
        else WorkflowState.REVIEWING
    )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.HALTED,
        target=active_state,
        sequence=_next_sequence(journal_path),
        journal_path=journal_path,
        state_path=state_path,
    )

    if target_role == AgentRole.IMPLEMENTER:
        return _resume_implementer(
            request, agent_turn_runtime, started_claim, executed_attempt, journal_path, state_path
        )
    return _resume_reviewer(
        request, agent_turn_runtime, started_claim, executed_attempt, journal_path, state_path
    )


def resume_single_subphase_transaction(
    request: SingleSubphaseTransactionRequest,
    *,
    agent_turn_runtime: AgentRuntime,
) -> ResumeExecutionResult:
    """Claim and, if executable, execute exactly one durable resumed attempt.

    All retry authority comes from durable state: the target role from
    ``claim.checkpoint.retry_request.target_role`` and the resumed attempt
    from ``claim.checkpoint.next_attempt_state.current_attempt`` -- never
    recomputed, never caller-supplied. Dispatches on the frozen Sub-phase
    9.11 :func:`~lockstep.resume.inspect_resume` disposition:
    :attr:`~lockstep.resume.ResumeDisposition.NO_CHECKPOINT` and
    :attr:`~lockstep.resume.ResumeDisposition.RETRY_EXHAUSTED` return
    immediately with no mutation; an existing
    :attr:`~lockstep.resume.ResumeDisposition.CLAIMED` claim is reused
    unchanged; :attr:`~lockstep.resume.ResumeDisposition.RETRY_AVAILABLE`
    is claimed via :func:`~lockstep.resume.claim_retry_checkpoint`; and
    :attr:`~lockstep.resume.ResumeDisposition.STARTED_RECOVERY_REQUIRED`
    either finalizes an already-known settlement (zero agent launches) or
    is returned unchanged for explicit recovery -- a pre-existing
    ``STARTED`` claim without a settlement is never automatically
    replayed. Requires the current durable workflow state to be
    ``HALTED`` and the claimed authority to be executable under its exact
    target role before ever crossing the durable
    :func:`~lockstep.resume.mark_resume_started` boundary; ``STARTED`` is
    always persisted, and the ``HALTED -> IMPLEMENTING``/
    ``HALTED -> REVIEWING`` workflow transition always occurs, strictly
    before the target role is ever invoked. Executes at most one resumed
    role invocation per call -- a newly produced
    :attr:`~lockstep.resume_settlement.ResumeSettlementOutcome.NEXT_RETRY`
    checkpoint is never consumed within the same call; a subsequent
    explicit call handles the next attempt.
    """
    from lockstep.resume import ResumeDisposition, claim_retry_checkpoint, inspect_resume
    from lockstep.resume_settlement import finalize_resume_settlement, load_resume_settlement

    _require_agent_turn_runtime_matches_request(request, agent_turn_runtime)

    inspection = inspect_resume(request.runtime_dir)

    if inspection.disposition == ResumeDisposition.NO_CHECKPOINT:
        return ResumeExecutionResult(disposition=ResumeExecutionDisposition.NO_CHECKPOINT)

    if inspection.disposition == ResumeDisposition.RETRY_EXHAUSTED:
        return ResumeExecutionResult(disposition=ResumeExecutionDisposition.RETRY_EXHAUSTED)

    if inspection.disposition == ResumeDisposition.STARTED_RECOVERY_REQUIRED:
        assert inspection.claim is not None
        started_claim = inspection.claim
        settlement = load_resume_settlement(request.runtime_dir, started_claim)
        if settlement is None:
            return ResumeExecutionResult(
                disposition=ResumeExecutionDisposition.STARTED_RECOVERY_REQUIRED,
                claim=started_claim,
            )
        finalized = finalize_resume_settlement(request.runtime_dir, settlement)
        return ResumeExecutionResult(
            disposition=ResumeExecutionDisposition.SETTLED,
            claim=finalized.claim,
            settlement=finalized,
        )

    if inspection.disposition == ResumeDisposition.CLAIMED:
        claim = inspection.claim
        assert claim is not None
    else:
        assert inspection.disposition == ResumeDisposition.RETRY_AVAILABLE
        claimed_inspection = claim_retry_checkpoint(request.runtime_dir)
        if claimed_inspection.disposition != ResumeDisposition.CLAIMED:
            raise ResumeExecutionError(
                stage="claim",
                reason="checkpoint did not reach claimed status",
            )
        claim = claimed_inspection.claim
        assert claim is not None
        claimed_attempt = claim.checkpoint.next_attempt_state
        assert claimed_attempt is not None
        _emit(
            request,
            ExecutionEventKind.RESUME_CLAIMED,
            attempt=claimed_attempt.current_attempt,
            role=claim.checkpoint.retry_request.target_role,
        )

    return _launch_claimed_resume(request, agent_turn_runtime, claim)
