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
"""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime
from enum import StrEnum
from pathlib import Path
from typing import TYPE_CHECKING

from pydantic import ValidationError

from lockstep.agent_turn import AgentTurnError, AgentTurnResult, AgentTurnStatus, invoke_agent_turn
from lockstep.agents import (
    AgentAdapter,
    AgentInvocationRequest,
    invoke_agent,
)
from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    BillingMode,
    PhaseId,
    ProjectId,
    ReviewDecision,
    ReviewVerdict,
    RunId,
    SubphaseId,
)
from lockstep.escalation import EscalationProtocolError, EscalationRequest
from lockstep.escalation_decision import PlannerDecisionKind
from lockstep.git import (
    GitCommitResult,
    commit_exact_paths,
    create_run_worktree,
    inspect_repository,
)
from lockstep.git.commit import commit_exact_subset_paths
from lockstep.persistence import (
    RunCreatedEvent,
    StateTransitionedEvent,
    append_event,
    load_verified_state,
    read_events,
    replay_events,
    write_state,
)
from lockstep.process import (
    build_process_environment,
    run_process,
)
from lockstep.reviewer_turn import ReviewerTurnError, ReviewerTurnResult, invoke_reviewer_turn
from lockstep.state import RunStateSnapshot, WorkflowState

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
    is the exact :class:`~lockstep.agent_turn.AgentTurnResult` returned
    by :func:`~lockstep.agent_turn.invoke_agent_turn` (excluded from
    :func:`repr` so logging never dumps raw provider output);
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
    implementer_turn: AgentTurnResult = field(repr=False)
    escalation: SupervisorEscalationResult
    final_state: RunStateSnapshot


@dataclass(frozen=True, slots=True)
class ReviewerBlockedTransactionResult:
    """Durable outcome of a single-Sub-phase transaction halted by a blocked Reviewer.

    Produced only when the composite structured Reviewer turn invoked by
    :func:`run_single_subphase_transaction_with_blockers` reports
    ``BLOCKED``. ``test_commit`` is the exact frozen Planner-authored
    test commit the transaction already produced; ``implementer_turn``
    is the exact :class:`~lockstep.agent_turn.AgentTurnResult` for the
    already-``COMPLETED`` Implementer turn that preceded verification
    (excluded from :func:`repr`); ``reviewer_turn`` is the exact
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
    implementer_turn: AgentTurnResult = field(repr=False)
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
    implementer_turn: AgentTurnResult = field(repr=False)
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
) -> AgentInvocationRequest:
    return AgentInvocationRequest(
        role=role,
        billing_mode=request.billing_mode,
        prompt=prompt,
        cwd=cwd,
        timeout_seconds=request.agent_timeout_seconds,
        max_output_bytes=request.max_output_bytes,
        termination_grace_seconds=request.termination_grace_seconds,
    )


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


def _author_tests(
    request: SingleSubphaseTransactionRequest,
    ctx: _PreparedTransaction,
    *,
    parent_env: Mapping[str, str],
    planner_adapter: AgentAdapter,
) -> GitCommitResult:
    for sequence, (source_state, target_state) in enumerate(
        (
            (WorkflowState.READY, WorkflowState.PHASE_PLANNING),
            (WorkflowState.PHASE_PLANNING, WorkflowState.SUBPHASE_PLANNING),
            (WorkflowState.SUBPHASE_PLANNING, WorkflowState.TEST_AUTHORING),
        ),
        start=2,
    ):
        _persist_transition(
            run_id=request.run_id,
            source=source_state,
            target=target_state,
            sequence=sequence,
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
        ),
        parent_env=parent_env,
    )
    if planner_result.process.returncode != 0:
        raise SupervisorTransactionError(
            stage="planner",
            reason=(f"planner process exited with returncode {planner_result.process.returncode}"),
        )

    expected_test_paths = tuple(sorted(request.test_paths))
    post_planner_snapshot = inspect_repository(ctx.worktree_root)
    if post_planner_snapshot.dirty_paths != expected_test_paths:
        raise SupervisorTransactionError(
            stage="test_scope",
            reason="planner dirty paths do not exactly match requested test paths",
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
        sequence=5,
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
    )

    baseline_result = run_process(
        request.baseline_argv,
        cwd=ctx.worktree_root,
        env=ctx.verification_env,
        timeout_seconds=request.command_timeout_seconds,
        max_output_bytes=request.max_output_bytes,
        termination_grace_seconds=request.termination_grace_seconds,
    )
    if baseline_result.returncode == 0:
        raise SupervisorTransactionError(
            stage="baseline",
            reason="RED baseline unexpectedly passed",
        )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.TEST_BASELINE_VERIFY,
        target=WorkflowState.TEST_COMMIT,
        sequence=6,
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
    )

    test_commit = commit_exact_paths(
        ctx.worktree_root,
        expected_branch=request.branch,
        expected_head_sha=ctx.source_head_sha,
        paths=request.test_paths,
        message=request.test_commit_message,
    )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.TEST_COMMIT,
        target=WorkflowState.IMPLEMENTING,
        sequence=7,
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
    expected_impl_paths = tuple(sorted(request.implementation_paths))
    post_implementer_snapshot = inspect_repository(ctx.worktree_root)
    if (
        post_implementer_snapshot.head_sha != test_commit.commit_sha
        or post_implementer_snapshot.dirty_paths != expected_impl_paths
    ):
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
        sequence=8,
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
    )

    verification_result = run_process(
        request.verification_argv,
        cwd=ctx.worktree_root,
        env=_verification_env_for(
            ctx.parent_env,
            cache_root=_verification_cache_root(request),
            purpose="verify",
            attempt=_TRANSACTION_ATTEMPT,
        ),
        timeout_seconds=request.command_timeout_seconds,
        max_output_bytes=request.max_output_bytes,
        termination_grace_seconds=request.termination_grace_seconds,
    )
    if verification_result.returncode != 0:
        raise SupervisorTransactionError(
            stage="verification",
            reason=(
                f"verification command exited with returncode {verification_result.returncode}"
            ),
        )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.VERIFYING,
        target=WorkflowState.REVIEWING,
        sequence=9,
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
    expected_impl_paths = tuple(sorted(request.implementation_paths))
    _require_review_matches_transaction(review, request)

    if review.verdict is not ReviewVerdict.APPROVE:
        raise SupervisorTransactionError(
            stage="review",
            reason=(
                f"review verdict {review.verdict.value!r} is not supported by the 4.1 happy path"
            ),
        )

    pre_commit_snapshot = inspect_repository(ctx.worktree_root)
    if (
        pre_commit_snapshot.head_sha != test_commit.commit_sha
        or pre_commit_snapshot.dirty_paths != expected_impl_paths
    ):
        raise SupervisorTransactionError(
            stage="pre_commit_integrity",
            reason=("worktree drifted between verification and implementation commit"),
        )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.REVIEWING,
        target=WorkflowState.IMPLEMENTATION_COMMIT,
        sequence=10,
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
    )

    implementation_commit = commit_exact_paths(
        ctx.worktree_root,
        expected_branch=request.branch,
        expected_head_sha=test_commit.commit_sha,
        paths=request.implementation_paths,
        message=request.implementation_commit_message,
    )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.IMPLEMENTATION_COMMIT,
        target=WorkflowState.SUBPHASE_COMPLETE,
        sequence=11,
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
            prompt=request.reviewer_prompt,
            request=request,
            cwd=ctx.worktree_root,
        ),
        parent_env=parent_env,
    )
    if reviewer_result.process.returncode != 0:
        raise SupervisorTransactionError(
            stage="reviewer",
            reason=(
                f"reviewer process exited with returncode {reviewer_result.process.returncode}"
            ),
        )

    try:
        review = ReviewDecision.model_validate_json(reviewer_result.process.stdout)
    except ValidationError as exc:
        raise SupervisorTransactionError(
            stage="review",
            reason="reviewer output is not a valid ReviewDecision",
        ) from exc

    return _handle_review_decision(request, ctx, test_commit, review)


def _capture_review_rework(
    request: SingleSubphaseTransactionRequest,
    ctx: _PreparedTransaction,
    test_commit: GitCommitResult,
    implementer_turn: AgentTurnResult,
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

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.REVIEWING,
        target=WorkflowState.HALTED,
        sequence=10,
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
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
    implementer_turn: AgentTurnResult,
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

    reviewer_turn = invoke_reviewer_turn(
        agent_turn_runtime,
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        attempt=_TRANSACTION_ATTEMPT,
        prompt=request.reviewer_prompt,
        cwd=ctx.worktree_root,
        timeout_seconds=request.agent_timeout_seconds,
        max_output_bytes=request.max_output_bytes,
        termination_grace_seconds=request.termination_grace_seconds,
    )

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
    from lockstep.supervisor.escalation import dispatch_escalation

    escalation_result = dispatch_escalation(
        agent_turn_runtime,
        request=reviewer_turn.escalation_request,
        timeout_seconds=request.agent_timeout_seconds,
        max_output_bytes=request.max_output_bytes,
        termination_grace_seconds=request.termination_grace_seconds,
    )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.REVIEWING,
        target=WorkflowState.HALTED,
        sequence=10,
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
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
        ),
        parent_env=parent_env,
    )
    if implementer_result.process.returncode != 0:
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

    implementer_turn = invoke_agent_turn(
        agent_turn_runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        attempt=_TRANSACTION_ATTEMPT,
        prompt=request.implementer_prompt,
        cwd=ctx.worktree_root,
        timeout_seconds=request.agent_timeout_seconds,
        max_output_bytes=request.max_output_bytes,
        termination_grace_seconds=request.termination_grace_seconds,
    )

    if implementer_turn.report.status is AgentTurnStatus.COMPLETED:
        assert implementer_turn.escalation_request is None
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
    from lockstep.supervisor.escalation import dispatch_escalation

    escalation_result = dispatch_escalation(
        agent_turn_runtime,
        request=implementer_turn.escalation_request,
        timeout_seconds=request.agent_timeout_seconds,
        max_output_bytes=request.max_output_bytes,
        termination_grace_seconds=request.termination_grace_seconds,
    )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.IMPLEMENTING,
        target=WorkflowState.HALTED,
        sequence=8,
        journal_path=ctx.journal_path,
        state_path=ctx.state_path,
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


def _checkpoint_from_implementer_blocked(
    request: SingleSubphaseTransactionRequest,
    retry_budget: RetryBudget,
    result: ImplementerBlockedTransactionResult,
) -> ImplementerBlockedTransactionResult | RetryCheckpointedTransactionResult:
    from lockstep.retry_checkpoint import (
        create_retry_checkpoint_from_escalation,
        freeze_retry_checkpoint,
    )

    checkpoint = create_retry_checkpoint_from_escalation(
        attempt_state=_current_attempt_state(request),
        budget=retry_budget,
        result=result.escalation,
    )
    if checkpoint is None:
        return result

    frozen = freeze_retry_checkpoint(request.runtime_dir, checkpoint)
    return RetryCheckpointedTransactionResult(source_result=result, checkpoint=frozen)


def _checkpoint_from_reviewer_blocked(
    request: SingleSubphaseTransactionRequest,
    retry_budget: RetryBudget,
    result: ReviewerBlockedTransactionResult,
) -> ReviewerBlockedTransactionResult | RetryCheckpointedTransactionResult:
    from lockstep.retry_checkpoint import (
        create_retry_checkpoint_from_escalation,
        freeze_retry_checkpoint,
    )

    checkpoint = create_retry_checkpoint_from_escalation(
        attempt_state=_current_attempt_state(request),
        budget=retry_budget,
        result=result.escalation,
    )
    if checkpoint is None:
        return result

    frozen = freeze_retry_checkpoint(request.runtime_dir, checkpoint)
    return RetryCheckpointedTransactionResult(source_result=result, checkpoint=frozen)


def _checkpoint_from_review_rework(
    request: SingleSubphaseTransactionRequest,
    retry_budget: RetryBudget,
    result: ReviewReworkTransactionResult,
) -> RetryCheckpointedTransactionResult:
    from lockstep.retry_checkpoint import (
        create_retry_checkpoint_from_review,
        freeze_retry_checkpoint,
    )

    checkpoint = create_retry_checkpoint_from_review(
        attempt_state=_current_attempt_state(request),
        budget=retry_budget,
        decision=result.review_decision,
    )
    # A REWORK verdict always carries retry authority (frozen 9.8
    # ``retry_request_from_review`` contract) -- ``None`` here would mean
    # this function was called for a non-REWORK decision, a caller defect.
    assert checkpoint is not None

    frozen = freeze_retry_checkpoint(request.runtime_dir, checkpoint)
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

    payload = {
        "resume_authority": "review_rework",
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
        "\n\n---\nResume authority (host-supplied, deterministic):\n"
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


def _settle_and_transition_to_halted(
    request: SingleSubphaseTransactionRequest,
    started_claim: ResumeClaim,
    outcome: ResumeSettlementOutcome,
    journal_path: Path,
    state_path: Path,
    *,
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

    settlement = ResumeSettlement(
        schema_version=1,
        claim=started_claim,
        outcome=outcome,
        next_checkpoint=next_checkpoint,
    )
    finalized = finalize_resume_settlement(request.runtime_dir, settlement)

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
    )


def _partition_frozen_correction_dirty_paths(
    request: SingleSubphaseTransactionRequest,
    authorized_frozen_paths: tuple[str, ...],
    dirty_paths: tuple[str, ...],
) -> tuple[tuple[str, ...], tuple[str, ...]]:
    authorized_set = set(authorized_frozen_paths)
    ordinary_set = set(request.implementation_paths)
    dirty_set = set(dirty_paths)

    frozen_touched = dirty_set & authorized_set
    ordinary_touched = dirty_set & ordinary_set
    unexpected = dirty_set - authorized_set - ordinary_set

    if unexpected:
        raise SupervisorTransactionError(
            stage="frozen_correction_scope",
            reason=(
                "resumed implementer produced changes outside the authorized "
                "frozen-correction and production scope"
            ),
        )
    if not frozen_touched:
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
        )
    except (PlannerDecisionTransportError, EscalationProtocolError):
        _settle_execution_failed(request, started_claim, journal_path, state_path)
        raise

    checkpoint = create_retry_checkpoint_from_escalation(
        attempt_state=executed_attempt,
        budget=started_claim.checkpoint.budget,
        result=escalation_result,
    )

    if checkpoint is None:
        return _settle_and_transition_to_halted(
            request, started_claim, ResumeSettlementOutcome.HALTED, journal_path, state_path
        )

    return _settle_and_transition_to_halted(
        request,
        started_claim,
        ResumeSettlementOutcome.NEXT_RETRY,
        journal_path,
        state_path,
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
    expected_impl_paths: tuple[str, ...],
    journal_path: Path,
    state_path: Path,
) -> ResumeExecutionResult:
    from lockstep.resume_settlement import (
        ResumeSettlement,
        ResumeSettlementOutcome,
        finalize_resume_settlement,
    )

    pre_commit_snapshot = inspect_repository(request.worktree_path)
    if pre_commit_snapshot.dirty_paths != expected_impl_paths:
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

    if expected_impl_paths:
        commit_exact_paths(
            request.worktree_path,
            expected_branch=request.branch,
            expected_head_sha=pre_commit_snapshot.head_sha,
            paths=expected_impl_paths,
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
        next_checkpoint=checkpoint,
    )


def _invoke_and_handle_resumed_reviewer(
    request: SingleSubphaseTransactionRequest,
    agent_turn_runtime: AgentRuntime,
    started_claim: ResumeClaim,
    executed_attempt: AttemptState,
    prompt: str,
    expected_impl_paths: tuple[str, ...],
    journal_path: Path,
    state_path: Path,
) -> ResumeExecutionResult:
    from lockstep.resume_settlement import ResumeSettlementOutcome

    try:
        reviewer_turn = invoke_reviewer_turn(
            agent_turn_runtime,
            phase_id=request.phase_id,
            subphase_id=request.subphase_id,
            attempt=executed_attempt.current_attempt,
            prompt=prompt,
            cwd=request.worktree_path,
            timeout_seconds=request.agent_timeout_seconds,
            max_output_bytes=request.max_output_bytes,
            termination_grace_seconds=request.termination_grace_seconds,
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

    if review.verdict is ReviewVerdict.APPROVE:
        try:
            return _resume_approve(
                request, started_claim, expected_impl_paths, journal_path, state_path
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
        request, started_claim, ResumeSettlementOutcome.HALTED, journal_path, state_path
    )


def _resume_run_verification(
    request: SingleSubphaseTransactionRequest,
    parent_env: Mapping[str, str],
    attempt: AttemptNumber,
    expected_impl_paths: tuple[str, ...],
    journal_path: Path,
    state_path: Path,
) -> None:
    post_implementer_snapshot = inspect_repository(request.worktree_path)
    if post_implementer_snapshot.dirty_paths != expected_impl_paths:
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

    verification_env = _resume_verification_env(request, parent_env, attempt)
    verification_result = run_process(
        request.verification_argv,
        cwd=request.worktree_path,
        env=verification_env,
        timeout_seconds=request.command_timeout_seconds,
        max_output_bytes=request.max_output_bytes,
        termination_grace_seconds=request.termination_grace_seconds,
    )
    if verification_result.returncode != 0:
        raise SupervisorTransactionError(
            stage="verification",
            reason=(
                f"verification command exited with returncode {verification_result.returncode}"
            ),
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
    prompt = request.implementer_prompt + _resume_prompt_suffix(
        started_claim, executed_attempt.current_attempt, AgentRole.IMPLEMENTER
    )

    try:
        implementer_turn = invoke_agent_turn(
            agent_turn_runtime,
            role=AgentRole.IMPLEMENTER,
            phase_id=request.phase_id,
            subphase_id=request.subphase_id,
            attempt=executed_attempt.current_attempt,
            prompt=prompt,
            cwd=request.worktree_path,
            timeout_seconds=request.agent_timeout_seconds,
            max_output_bytes=request.max_output_bytes,
            termination_grace_seconds=request.termination_grace_seconds,
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

    frozen_paths = _frozen_correction_authorized_paths(started_claim)
    bounded_extra_paths = _bounded_change_authorized_paths(started_claim)

    try:
        if frozen_paths is not None:
            pre_snapshot = inspect_repository(request.worktree_path)
            frozen_touched, ordinary_touched = _partition_frozen_correction_dirty_paths(
                request, frozen_paths, pre_snapshot.dirty_paths
            )
            commit_exact_subset_paths(
                request.worktree_path,
                expected_branch=request.branch,
                expected_head_sha=pre_snapshot.head_sha,
                paths=frozen_touched,
                message="fix: correct frozen retry artifacts",
            )
            expected_impl_paths = ordinary_touched
        else:
            extra = set(bounded_extra_paths) if bounded_extra_paths else set()
            expected_impl_paths = tuple(sorted(set(request.implementation_paths) | extra))

        _resume_run_verification(
            request,
            agent_turn_runtime.transaction_parent_env,
            executed_attempt.current_attempt,
            expected_impl_paths,
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
        expected_impl_paths,
        journal_path,
        state_path,
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

    return _launch_claimed_resume(request, agent_turn_runtime, claim)
