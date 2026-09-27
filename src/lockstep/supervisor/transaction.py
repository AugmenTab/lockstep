"""Deterministic single-Sub-phase Supervisor transaction.

Composes the Phase 1-3 kernels into one Supervisor-owned transaction
that drives a new run from ``READY`` to ``SUBPHASE_COMPLETE``. The
event journal at ``request.runtime_dir/events.jsonl`` is authoritative;
``state.json`` beside it is the derived checkpoint. The Supervisor
launches no subprocess and issues no Git command directly: agent
invocation, worktree management, canonical commits, verification
process execution, and state persistence all delegate to the trusted
lower-layer packages.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

from pydantic import ValidationError

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
from lockstep.git import (
    GitCommitResult,
    commit_exact_paths,
    create_run_worktree,
    inspect_repository,
)
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
from lockstep.state import RunStateSnapshot, WorkflowState


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


def run_single_subphase_transaction(
    request: SingleSubphaseTransactionRequest,
    *,
    parent_env: Mapping[str, str],
    planner_adapter: AgentAdapter,
    implementer_adapter: AgentAdapter,
    reviewer_adapter: AgentAdapter,
) -> SingleSubphaseTransactionResult:
    """Drive one Sub-phase from ``READY`` to ``SUBPHASE_COMPLETE``."""
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
    # against the approved set without spurious ``.pyc`` matches.
    pycache_dir = request.worktree_path.parent / f".lockstep-pycache-{request.run_id.root}"
    pycache_dir.mkdir(parents=True, exist_ok=True)
    verification_explicit_env = {"PYTHONPYCACHEPREFIX": str(pycache_dir)}

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
            journal_path=journal_path,
            state_path=state_path,
        )

    planner_result = invoke_agent(
        planner_adapter,
        _agent_request(
            role=AgentRole.PLANNER,
            prompt=request.planner_prompt,
            request=request,
            cwd=worktree_root,
        ),
        parent_env=parent_env,
    )
    if planner_result.process.returncode != 0:
        raise SupervisorTransactionError(
            stage="planner",
            reason=(f"planner process exited with returncode {planner_result.process.returncode}"),
        )

    expected_test_paths = tuple(sorted(request.test_paths))
    post_planner_snapshot = inspect_repository(worktree_root)
    if post_planner_snapshot.dirty_paths != expected_test_paths:
        raise SupervisorTransactionError(
            stage="test_scope",
            reason="planner dirty paths do not exactly match requested test paths",
        )

    verification_env = build_process_environment(
        parent_env,
        explicit_env=verification_explicit_env,
    )

    quality_result = run_process(
        request.planner_quality_argv,
        cwd=worktree_root,
        env=verification_env,
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
        journal_path=journal_path,
        state_path=state_path,
    )

    baseline_result = run_process(
        request.baseline_argv,
        cwd=worktree_root,
        env=verification_env,
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
        journal_path=journal_path,
        state_path=state_path,
    )

    test_commit = commit_exact_paths(
        worktree_root,
        expected_branch=request.branch,
        expected_head_sha=source_head_sha,
        paths=request.test_paths,
        message=request.test_commit_message,
    )

    _persist_transition(
        run_id=request.run_id,
        source=WorkflowState.TEST_COMMIT,
        target=WorkflowState.IMPLEMENTING,
        sequence=7,
        journal_path=journal_path,
        state_path=state_path,
    )

    implementer_result = invoke_agent(
        implementer_adapter,
        _agent_request(
            role=AgentRole.IMPLEMENTER,
            prompt=request.implementer_prompt,
            request=request,
            cwd=worktree_root,
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

    expected_impl_paths = tuple(sorted(request.implementation_paths))
    post_implementer_snapshot = inspect_repository(worktree_root)
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
        journal_path=journal_path,
        state_path=state_path,
    )

    verification_result = run_process(
        request.verification_argv,
        cwd=worktree_root,
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
        sequence=9,
        journal_path=journal_path,
        state_path=state_path,
    )

    reviewer_result = invoke_agent(
        reviewer_adapter,
        _agent_request(
            role=AgentRole.REVIEWER,
            prompt=request.reviewer_prompt,
            request=request,
            cwd=worktree_root,
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

    _require_review_matches_transaction(review, request)

    if review.verdict is not ReviewVerdict.APPROVE:
        raise SupervisorTransactionError(
            stage="review",
            reason=(
                f"review verdict {review.verdict.value!r} is not supported by the 4.1 happy path"
            ),
        )

    pre_commit_snapshot = inspect_repository(worktree_root)
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
        journal_path=journal_path,
        state_path=state_path,
    )

    implementation_commit = commit_exact_paths(
        worktree_root,
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
        journal_path=journal_path,
        state_path=state_path,
    )

    final_state = load_verified_state(state_path, journal_path)
    if final_state is None or final_state.workflow_state != WorkflowState.SUBPHASE_COMPLETE:
        raise SupervisorTransactionError(
            stage="reconciliation",
            reason="final journal replay does not reach SUBPHASE_COMPLETE",
        )

    return SingleSubphaseTransactionResult(
        run_id=request.run_id,
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        worktree_root=worktree_root,
        branch=request.branch,
        test_commit=test_commit,
        implementation_commit=implementation_commit,
        review=review,
        final_state=final_state,
    )
