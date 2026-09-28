"""Tests for the Phase 9.9 durable retry authority checkpoint.

Specifies ``lockstep.retry_checkpoint`` before it exists: durable,
reconstructable retry authority for exactly one halted Sub-phase, built
strictly on top of the frozen 9.8 attempt-state/retry-budget protocol
(``lockstep.retry``). A ``RetryCheckpoint`` binds a validated
``AttemptState``/``RetryBudget``/``RetryRequest`` triple to the exact
bounded semantic evidence that authorized another attempt -- an
Implementer/Reviewer ``RESUME_AGENT`` escalation's ``EscalationRequest``
and ``PlannerDecision``, or a Reviewer's ``REWORK`` ``ReviewDecision`` --
and re-derives/re-evaluates that relationship on every construction and
load, so a persisted checkpoint can never merely be trusted at face
value. This module creates and freezes checkpoints; it does not consume,
claim, or replay them, does not mutate the Supervisor transaction or FSM,
and does not re-enter an agent.
"""

import ast
import inspect
import json
from pathlib import Path

import pytest
from pydantic import ValidationError

import lockstep.retry_checkpoint as retry_checkpoint_module
from lockstep.agents import AgentInvocationResult
from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    BillingMode,
    PhaseId,
    ReviewDecision,
    ReviewVerdict,
    SubphaseId,
)
from lockstep.escalation import (
    EscalationAuthority,
    EscalationCategory,
    EscalationProtocolError,
    EscalationRequest,
    route_escalation,
)
from lockstep.escalation_decision import (
    PlannerDecision,
    PlannerDecisionKind,
    escalation_request_digest,
    resolve_planner_decision,
)
from lockstep.escalation_transport import PlannerDecisionTurnResult
from lockstep.process import ProcessResult
from lockstep.retry import (
    AttemptState,
    RetryBudget,
    RetryBudgetDisposition,
    RetryProtocolError,
)
from lockstep.retry_checkpoint import (
    RetryAuthority,
    RetryAuthorityKind,
    RetryCheckpoint,
    RetryCheckpointStoreError,
    create_retry_checkpoint_from_escalation,
    create_retry_checkpoint_from_review,
    freeze_retry_checkpoint,
    load_retry_checkpoint,
    retry_checkpoint_path,
)
from lockstep.supervisor.escalation import (
    SupervisorEscalationDisposition,
    SupervisorEscalationResult,
)

_PHASE_ID = "09"
_SUBPHASE_ID = "09"


def _phase_id(value: str = _PHASE_ID) -> PhaseId:
    return PhaseId.model_validate(value)


def _subphase_id(value: str = _SUBPHASE_ID) -> SubphaseId:
    return SubphaseId.model_validate(value)


def _escalation_request(
    *,
    source_role: AgentRole = AgentRole.IMPLEMENTER,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    attempt: int = 1,
    category: EscalationCategory = EscalationCategory.ARCHITECTURE_CONFLICT,
    question: str = "Is the previously reported blocker now resolved?",
    evidence: tuple[str, ...] = ("The Planner authorized a bounded change.",),
    requested_authority: EscalationAuthority = EscalationAuthority.PLANNER,
) -> EscalationRequest:
    return EscalationRequest(
        source_role=source_role,
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        attempt=attempt,
        category=category,
        question=question,
        evidence=evidence,
        requested_authority=requested_authority,
    )


def _planner_decision(
    request: EscalationRequest,
    *,
    kind: PlannerDecisionKind = PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
    rationale: str = "Bounded correction authorized.",
    instructions: tuple[str, ...] = ("Apply the bounded fix.",),
    authorized_paths: tuple[str, ...] = (),
) -> PlannerDecision:
    return PlannerDecision(
        request_digest=escalation_request_digest(request),
        kind=kind,
        rationale=rationale,
        instructions=instructions,
        authorized_paths=authorized_paths,
    )


def _agent_invocation_result(
    *, stdout: str = "", adapter_name: str = "fake-planner"
) -> AgentInvocationResult:
    process = ProcessResult(
        argv=("fake-planner",),
        cwd=Path("."),
        returncode=0,
        stdout=stdout,
        stderr="",
        stdout_truncated=False,
        stderr_truncated=False,
    )
    return AgentInvocationResult(
        adapter_name=adapter_name,
        role=AgentRole.PLANNER,
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        process=process,
    )


def _planner_turn_result(
    request: EscalationRequest, decision: PlannerDecision
) -> PlannerDecisionTurnResult:
    resolution = resolve_planner_decision(request, decision)
    return PlannerDecisionTurnResult(
        decision=decision, resolution=resolution, invocation=_agent_invocation_result()
    )


def _escalation_result(
    *,
    request: EscalationRequest,
    disposition: SupervisorEscalationDisposition,
    planner_turn: PlannerDecisionTurnResult | None = None,
) -> SupervisorEscalationResult:
    return SupervisorEscalationResult(
        request=request,
        route=route_escalation(request),
        disposition=disposition,
        planner_turn=planner_turn,
    )


def _resume_escalation_result(
    *,
    source_role: AgentRole = AgentRole.IMPLEMENTER,
    attempt: int = 1,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
) -> tuple[EscalationRequest, PlannerDecision, SupervisorEscalationResult]:
    request = _escalation_request(
        source_role=source_role, attempt=attempt, phase_id=phase_id, subphase_id=subphase_id
    )
    decision = _planner_decision(request)
    planner_turn = _planner_turn_result(request, decision)
    result = _escalation_result(
        request=request,
        disposition=SupervisorEscalationDisposition.RESUME_AGENT,
        planner_turn=planner_turn,
    )
    return request, decision, result


def _review_decision(
    *,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    attempt: int = 1,
    verdict: ReviewVerdict = ReviewVerdict.REWORK,
    summary: str = "Rework requested.",
) -> ReviewDecision:
    return ReviewDecision(
        schema_version=1,
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        attempt=attempt,
        verdict=verdict,
        summary=summary,
        findings=(),
    )


def _attempt_state(
    *,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    current_attempt: int = 1,
) -> AttemptState:
    return AttemptState(
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        current_attempt=current_attempt,
    )


def _valid_escalation_checkpoint(
    *,
    current_attempt: int = 1,
    max_attempts: int = 3,
    source_role: AgentRole = AgentRole.IMPLEMENTER,
) -> tuple[RetryCheckpoint, EscalationRequest, PlannerDecision]:
    request, decision, result = _resume_escalation_result(
        source_role=source_role, attempt=current_attempt
    )
    attempt_state = _attempt_state(current_attempt=current_attempt)
    budget = RetryBudget(max_attempts=max_attempts)
    checkpoint = create_retry_checkpoint_from_escalation(
        attempt_state=attempt_state, budget=budget, result=result
    )
    assert checkpoint is not None
    return checkpoint, request, decision


def _valid_review_checkpoint(
    *, current_attempt: int = 1, max_attempts: int = 3
) -> tuple[RetryCheckpoint, ReviewDecision]:
    decision = _review_decision(attempt=current_attempt, verdict=ReviewVerdict.REWORK)
    attempt_state = _attempt_state(current_attempt=current_attempt)
    budget = RetryBudget(max_attempts=max_attempts)
    checkpoint = create_retry_checkpoint_from_review(
        attempt_state=attempt_state, budget=budget, decision=decision
    )
    assert checkpoint is not None
    return checkpoint, decision


def _runtime_dir(tmp_path: Path) -> Path:
    directory = tmp_path / "runtime"
    directory.mkdir()
    return directory


def _expected_canonical_bytes(checkpoint: RetryCheckpoint) -> bytes:
    text = json.dumps(
        checkpoint.model_dump(mode="json"),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return (text + "\n").encode("utf-8")


def _symlink_or_skip(link: Path, target: Path) -> None:
    try:
        link.symlink_to(target)
    except OSError as exc:
        pytest.skip(f"symlink creation unsupported on this platform: {exc}")


def _call_names(tree: ast.AST) -> set[str]:
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            names.add(node.func.id)
    return names


# ---------------------------------------------------------------------------
# Public surface (Section 41)
# ---------------------------------------------------------------------------


def test_public_api_exports_expected_names() -> None:
    assert {
        "RetryAuthorityKind",
        "RetryAuthority",
        "RetryCheckpoint",
        "RetryCheckpointStoreError",
        "retry_checkpoint_path",
        "create_retry_checkpoint_from_escalation",
        "create_retry_checkpoint_from_review",
        "freeze_retry_checkpoint",
        "load_retry_checkpoint",
    }.issubset(set(retry_checkpoint_module.__all__))


def test_public_names_are_importable_from_the_module() -> None:
    assert RetryAuthorityKind is not None
    assert RetryAuthority is not None
    assert RetryCheckpoint is not None
    assert RetryCheckpointStoreError is not None
    assert callable(retry_checkpoint_path)
    assert callable(create_retry_checkpoint_from_escalation)
    assert callable(create_retry_checkpoint_from_review)
    assert callable(freeze_retry_checkpoint)
    assert callable(load_retry_checkpoint)


def test_public_api_has_no_root_package_export() -> None:
    import lockstep

    assert not hasattr(lockstep, "RetryCheckpoint")
    assert not hasattr(lockstep, "RetryAuthority")


# ---------------------------------------------------------------------------
# Exact authority enum (Section 42)
# ---------------------------------------------------------------------------


def test_retry_authority_kind_values_are_stable() -> None:
    assert {member.name: member.value for member in RetryAuthorityKind} == {
        "ESCALATION_RESUME": "escalation_resume",
        "REVIEW_REWORK": "review_rework",
    }
    forbidden_names = {"MANUAL", "PROCESS_FAILURE", "PROVIDER_FAILURE", "UNKNOWN", "OTHER"}
    assert forbidden_names.isdisjoint(set(RetryAuthorityKind.__members__))


def test_retry_authority_kind_rejects_unknown_value() -> None:
    with pytest.raises(ValueError):
        RetryAuthorityKind("not_a_real_kind")


# ---------------------------------------------------------------------------
# Escalation authority shape (Section 43)
# ---------------------------------------------------------------------------


def test_escalation_authority_has_expected_shape() -> None:
    request = _escalation_request()
    decision = _planner_decision(request)

    authority = RetryAuthority(
        kind=RetryAuthorityKind.ESCALATION_RESUME,
        escalation_request=request,
        planner_decision=decision,
    )

    assert authority.kind == RetryAuthorityKind.ESCALATION_RESUME
    assert authority.escalation_request == request
    assert authority.planner_decision == decision
    assert authority.review_decision is None


def test_escalation_authority_is_frozen() -> None:
    request = _escalation_request()
    decision = _planner_decision(request)
    authority = RetryAuthority(
        kind=RetryAuthorityKind.ESCALATION_RESUME,
        escalation_request=request,
        planner_decision=decision,
    )
    with pytest.raises(ValidationError):
        authority.kind = RetryAuthorityKind.REVIEW_REWORK  # type: ignore[misc]


def test_escalation_authority_rejects_unknown_fields() -> None:
    request = _escalation_request()
    decision = _planner_decision(request)
    with pytest.raises(ValidationError):
        RetryAuthority(
            kind=RetryAuthorityKind.ESCALATION_RESUME,
            escalation_request=request,
            planner_decision=decision,
            provider="claude",
        )  # type: ignore[call-arg]


# ---------------------------------------------------------------------------
# Review authority shape (Section 44)
# ---------------------------------------------------------------------------


def test_review_authority_has_expected_shape() -> None:
    decision = _review_decision()
    authority = RetryAuthority(kind=RetryAuthorityKind.REVIEW_REWORK, review_decision=decision)

    assert authority.kind == RetryAuthorityKind.REVIEW_REWORK
    assert authority.review_decision == decision
    assert authority.escalation_request is None
    assert authority.planner_decision is None


def test_review_authority_is_frozen() -> None:
    decision = _review_decision()
    authority = RetryAuthority(kind=RetryAuthorityKind.REVIEW_REWORK, review_decision=decision)
    with pytest.raises(ValidationError):
        authority.review_decision = None  # type: ignore[misc]


def test_review_authority_rejects_unknown_fields() -> None:
    decision = _review_decision()
    with pytest.raises(ValidationError):
        RetryAuthority(
            kind=RetryAuthorityKind.REVIEW_REWORK, review_decision=decision, provider="claude"
        )  # type: ignore[call-arg]


# ---------------------------------------------------------------------------
# Invalid authority combinations (Section 45)
# ---------------------------------------------------------------------------


def test_escalation_authority_requires_escalation_request() -> None:
    request = _escalation_request()
    decision = _planner_decision(request)
    with pytest.raises(ValidationError):
        RetryAuthority(kind=RetryAuthorityKind.ESCALATION_RESUME, planner_decision=decision)


def test_escalation_authority_requires_planner_decision() -> None:
    request = _escalation_request()
    with pytest.raises(ValidationError):
        RetryAuthority(kind=RetryAuthorityKind.ESCALATION_RESUME, escalation_request=request)


def test_escalation_authority_rejects_review_decision() -> None:
    request = _escalation_request()
    decision = _planner_decision(request)
    review = _review_decision()
    with pytest.raises(ValidationError):
        RetryAuthority(
            kind=RetryAuthorityKind.ESCALATION_RESUME,
            escalation_request=request,
            planner_decision=decision,
            review_decision=review,
        )


def test_review_authority_requires_review_decision() -> None:
    with pytest.raises(ValidationError):
        RetryAuthority(kind=RetryAuthorityKind.REVIEW_REWORK)


def test_review_authority_rejects_escalation_request() -> None:
    review = _review_decision()
    request = _escalation_request()
    with pytest.raises(ValidationError):
        RetryAuthority(
            kind=RetryAuthorityKind.REVIEW_REWORK,
            review_decision=review,
            escalation_request=request,
        )


def test_review_authority_rejects_planner_decision() -> None:
    review = _review_decision()
    request = _escalation_request()
    decision = _planner_decision(request)
    with pytest.raises(ValidationError):
        RetryAuthority(
            kind=RetryAuthorityKind.REVIEW_REWORK,
            review_decision=review,
            planner_decision=decision,
        )


# ---------------------------------------------------------------------------
# Decision/request digest binding (Section 46)
# ---------------------------------------------------------------------------


def test_escalation_authority_accepts_planner_decision_bound_to_the_same_request() -> None:
    request = _escalation_request()
    decision = _planner_decision(request)

    authority = RetryAuthority(
        kind=RetryAuthorityKind.ESCALATION_RESUME,
        escalation_request=request,
        planner_decision=decision,
    )

    assert authority.escalation_request == request
    assert authority.planner_decision == decision


def test_escalation_authority_rejects_planner_decision_bound_to_a_different_request() -> None:
    request_a = _escalation_request(phase_id="09", subphase_id="08")
    request_b = _escalation_request(phase_id="09", subphase_id="09")
    decision_for_b = _planner_decision(request_b)

    with pytest.raises(EscalationProtocolError):
        RetryAuthority(
            kind=RetryAuthorityKind.ESCALATION_RESUME,
            escalation_request=request_a,
            planner_decision=decision_for_b,
        )


# ---------------------------------------------------------------------------
# Escalation decision must RESUME (Section 47)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "kind",
    [
        PlannerDecisionKind.REPLAN_SUBPHASE,
        PlannerDecisionKind.HALT_FOR_HUMAN,
        PlannerDecisionKind.TERMINAL_HALT,
    ],
)
def test_escalation_authority_rejects_non_resume_planner_decision(
    kind: PlannerDecisionKind,
) -> None:
    request = _escalation_request()
    decision = _planner_decision(request, kind=kind)

    with pytest.raises(ValidationError):
        RetryAuthority(
            kind=RetryAuthorityKind.ESCALATION_RESUME,
            escalation_request=request,
            planner_decision=decision,
        )


# ---------------------------------------------------------------------------
# Review authority must REWORK (Section 48)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("verdict", [ReviewVerdict.APPROVE, ReviewVerdict.HALT])
def test_review_authority_rejects_non_rework_verdict(verdict: ReviewVerdict) -> None:
    decision = _review_decision(verdict=verdict, summary="Terminal review outcome.")
    with pytest.raises(ValidationError):
        RetryAuthority(kind=RetryAuthorityKind.REVIEW_REWORK, review_decision=decision)


# ---------------------------------------------------------------------------
# Escalation checkpoint creation (Section 49)
# ---------------------------------------------------------------------------


def test_create_checkpoint_from_implementer_escalation_resume() -> None:
    checkpoint, request, decision = _valid_escalation_checkpoint(
        current_attempt=1, max_attempts=3, source_role=AgentRole.IMPLEMENTER
    )

    assert checkpoint.retry_request.target_role == AgentRole.IMPLEMENTER
    assert checkpoint.budget_disposition == RetryBudgetDisposition.RETRY_AVAILABLE
    assert checkpoint.next_attempt_state is not None
    assert checkpoint.next_attempt_state.current_attempt == AttemptNumber.model_validate(2)
    assert checkpoint.authority.kind == RetryAuthorityKind.ESCALATION_RESUME
    assert checkpoint.authority.escalation_request == request
    assert checkpoint.authority.planner_decision == decision


# ---------------------------------------------------------------------------
# Reviewer escalation checkpoint (Section 50)
# ---------------------------------------------------------------------------


def test_create_checkpoint_from_reviewer_escalation_resume() -> None:
    checkpoint, request, decision = _valid_escalation_checkpoint(
        current_attempt=2, max_attempts=3, source_role=AgentRole.REVIEWER
    )

    assert checkpoint.retry_request.target_role == AgentRole.REVIEWER
    assert checkpoint.budget_disposition == RetryBudgetDisposition.RETRY_AVAILABLE
    assert checkpoint.next_attempt_state is not None
    assert checkpoint.next_attempt_state.current_attempt == AttemptNumber.model_validate(3)
    assert checkpoint.authority.escalation_request == request
    assert checkpoint.authority.planner_decision == decision


def test_create_checkpoint_raises_for_resume_result_missing_planner_turn() -> None:
    request = _escalation_request(source_role=AgentRole.IMPLEMENTER)
    result = SupervisorEscalationResult(
        request=request,
        route=route_escalation(request),
        disposition=SupervisorEscalationDisposition.RESUME_AGENT,
        planner_turn=None,
    )
    attempt_state = _attempt_state(current_attempt=1)
    budget = RetryBudget(max_attempts=3)

    with pytest.raises(RetryCheckpointStoreError):
        create_retry_checkpoint_from_escalation(
            attempt_state=attempt_state, budget=budget, result=result
        )


# ---------------------------------------------------------------------------
# Review REWORK checkpoint (Section 51)
# ---------------------------------------------------------------------------


def test_create_checkpoint_from_review_rework() -> None:
    checkpoint, decision = _valid_review_checkpoint(current_attempt=1, max_attempts=3)

    assert checkpoint.retry_request.target_role == AgentRole.IMPLEMENTER
    assert checkpoint.authority.kind == RetryAuthorityKind.REVIEW_REWORK
    assert checkpoint.authority.review_decision == decision
    assert checkpoint.authority.escalation_request is None
    assert checkpoint.authority.planner_decision is None


# ---------------------------------------------------------------------------
# Nonretryable escalation (Section 52)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "disposition",
    [
        SupervisorEscalationDisposition.SUPERVISOR_ACTION_REQUIRED,
        SupervisorEscalationDisposition.REPLAN_SUBPHASE,
        SupervisorEscalationDisposition.HUMAN_REQUIRED,
        SupervisorEscalationDisposition.RUN_HALT,
    ],
)
def test_create_checkpoint_from_escalation_returns_none_for_nonretryable_dispositions(
    disposition: SupervisorEscalationDisposition,
) -> None:
    request = _escalation_request()
    result = _escalation_result(request=request, disposition=disposition)
    attempt_state = _attempt_state(current_attempt=1)
    budget = RetryBudget(max_attempts=3)

    assert (
        create_retry_checkpoint_from_escalation(
            attempt_state=attempt_state, budget=budget, result=result
        )
        is None
    )


# ---------------------------------------------------------------------------
# APPROVE / HALT (Section 53)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("verdict", [ReviewVerdict.APPROVE, ReviewVerdict.HALT])
def test_create_checkpoint_from_review_returns_none_for_terminal_verdicts(
    verdict: ReviewVerdict,
) -> None:
    decision = _review_decision(verdict=verdict, summary="Terminal review outcome.")
    attempt_state = _attempt_state(current_attempt=1)
    budget = RetryBudget(max_attempts=3)

    assert (
        create_retry_checkpoint_from_review(
            attempt_state=attempt_state, budget=budget, decision=decision
        )
        is None
    )


# ---------------------------------------------------------------------------
# Exhausted authority remains durable (Section 54)
# ---------------------------------------------------------------------------


def test_create_checkpoint_persists_exhausted_escalation_authority() -> None:
    checkpoint, *_ = _valid_escalation_checkpoint(current_attempt=3, max_attempts=3)

    assert checkpoint.budget_disposition == RetryBudgetDisposition.RETRY_EXHAUSTED
    assert checkpoint.next_attempt_state is None


# ---------------------------------------------------------------------------
# One-attempt budget (Section 55)
# ---------------------------------------------------------------------------


def test_create_checkpoint_persists_one_attempt_exhaustion() -> None:
    checkpoint, *_ = _valid_escalation_checkpoint(current_attempt=1, max_attempts=1)

    assert checkpoint.budget_disposition == RetryBudgetDisposition.RETRY_EXHAUSTED
    assert checkpoint.next_attempt_state is None


# ---------------------------------------------------------------------------
# Stale authority (Section 56)
# ---------------------------------------------------------------------------


def test_create_checkpoint_propagates_stale_retry_protocol_error() -> None:
    _request, _decision, result = _resume_escalation_result(attempt=1)
    attempt_state = _attempt_state(current_attempt=2)
    budget = RetryBudget(max_attempts=3)

    with pytest.raises(RetryProtocolError):
        create_retry_checkpoint_from_escalation(
            attempt_state=attempt_state, budget=budget, result=result
        )


# ---------------------------------------------------------------------------
# Checkpoint model recomputes evaluation (Section 57)
# ---------------------------------------------------------------------------


def test_retry_checkpoint_rejects_forged_budget_disposition() -> None:
    checkpoint, *_ = _valid_escalation_checkpoint(current_attempt=1, max_attempts=3)
    data = checkpoint.model_dump(mode="json")
    data["budget_disposition"] = RetryBudgetDisposition.RETRY_EXHAUSTED.value
    data["next_attempt_state"] = None

    with pytest.raises(ValidationError):
        RetryCheckpoint.model_validate(data)


def test_retry_checkpoint_rejects_forged_next_attempt_state() -> None:
    checkpoint, *_ = _valid_escalation_checkpoint(current_attempt=3, max_attempts=3)
    data = checkpoint.model_dump(mode="json")
    data["budget_disposition"] = RetryBudgetDisposition.RETRY_AVAILABLE.value
    data["next_attempt_state"] = {
        "phase_id": _PHASE_ID,
        "subphase_id": _SUBPHASE_ID,
        "current_attempt": 4,
    }

    with pytest.raises(ValidationError):
        RetryCheckpoint.model_validate(data)


# ---------------------------------------------------------------------------
# Retry request must match authority (Section 58)
# ---------------------------------------------------------------------------


def test_retry_checkpoint_rejects_retry_request_mismatched_with_authority() -> None:
    checkpoint, *_ = _valid_escalation_checkpoint(source_role=AgentRole.IMPLEMENTER)
    data = checkpoint.model_dump(mode="json")
    data["retry_request"]["target_role"] = AgentRole.REVIEWER.value

    with pytest.raises(ValidationError):
        RetryCheckpoint.model_validate(data)


# ---------------------------------------------------------------------------
# RetryCheckpoint schema shape (AC-9.9.11 / AC-9.9.12)
# ---------------------------------------------------------------------------


def test_retry_checkpoint_has_exactly_expected_fields() -> None:
    assert set(RetryCheckpoint.model_fields) == {
        "schema_version",
        "attempt_state",
        "budget",
        "retry_request",
        "budget_disposition",
        "next_attempt_state",
        "authority",
    }


def test_retry_checkpoint_rejects_unsupported_schema_version() -> None:
    checkpoint, *_ = _valid_escalation_checkpoint()
    data = checkpoint.model_dump(mode="json")
    data["schema_version"] = 2

    with pytest.raises(ValidationError):
        RetryCheckpoint.model_validate(data)


def test_retry_checkpoint_is_frozen() -> None:
    checkpoint, *_ = _valid_escalation_checkpoint()
    with pytest.raises(ValidationError):
        checkpoint.budget_disposition = RetryBudgetDisposition.RETRY_EXHAUSTED  # type: ignore[misc]


def test_retry_checkpoint_rejects_unknown_fields() -> None:
    checkpoint, *_ = _valid_escalation_checkpoint()
    data = checkpoint.model_dump(mode="json")
    data["provider"] = "claude"

    with pytest.raises(ValidationError):
        RetryCheckpoint.model_validate(data)


# ---------------------------------------------------------------------------
# Runtime path (Section 59)
# ---------------------------------------------------------------------------


def test_retry_checkpoint_path_is_exact(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    assert retry_checkpoint_path(runtime_dir) == runtime_dir / "retry" / "checkpoint.json"


# ---------------------------------------------------------------------------
# Freeze absent (Section 60)
# ---------------------------------------------------------------------------


def test_freeze_persists_absent_checkpoint(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()

    frozen = freeze_retry_checkpoint(runtime_dir, checkpoint)

    path = retry_checkpoint_path(runtime_dir)
    assert path.exists()
    assert path.read_bytes() == _expected_canonical_bytes(checkpoint)
    assert load_retry_checkpoint(runtime_dir) == checkpoint
    assert frozen == checkpoint


# ---------------------------------------------------------------------------
# Idempotent freeze (Section 61)
# ---------------------------------------------------------------------------


def test_freeze_is_idempotent_for_an_equivalent_checkpoint(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()

    freeze_retry_checkpoint(runtime_dir, checkpoint)
    path = retry_checkpoint_path(runtime_dir)
    bytes_after_first = path.read_bytes()

    freeze_retry_checkpoint(runtime_dir, checkpoint.model_copy())

    assert path.read_bytes() == bytes_after_first
    assert list(path.parent.glob("*.json")) == [path]


# ---------------------------------------------------------------------------
# Different second checkpoint rejected (Section 62)
# ---------------------------------------------------------------------------


def test_freeze_rejects_a_different_second_checkpoint(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint_a, *_ = _valid_escalation_checkpoint(current_attempt=1, max_attempts=3)
    checkpoint_b, *_ = _valid_escalation_checkpoint(current_attempt=1, max_attempts=5)

    freeze_retry_checkpoint(runtime_dir, checkpoint_a)
    path = retry_checkpoint_path(runtime_dir)
    original_bytes = path.read_bytes()

    with pytest.raises(RetryCheckpointStoreError):
        freeze_retry_checkpoint(runtime_dir, checkpoint_b)

    assert path.read_bytes() == original_bytes


# ---------------------------------------------------------------------------
# Corruption fail closed (Section 63)
# ---------------------------------------------------------------------------


def test_load_rejects_malformed_json(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    path = retry_checkpoint_path(runtime_dir)
    path.parent.mkdir(parents=True)
    path.write_text("{not valid json", encoding="utf-8")

    with pytest.raises(RetryCheckpointStoreError):
        load_retry_checkpoint(runtime_dir)


def test_freeze_does_not_overwrite_malformed_json(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    path = retry_checkpoint_path(runtime_dir)
    path.parent.mkdir(parents=True)
    path.write_text("{not valid json", encoding="utf-8")
    checkpoint, *_ = _valid_escalation_checkpoint()

    with pytest.raises(RetryCheckpointStoreError):
        freeze_retry_checkpoint(runtime_dir, checkpoint)

    assert path.read_text(encoding="utf-8") == "{not valid json"


def test_load_rejects_forged_relationship_in_persisted_json(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint(current_attempt=1, max_attempts=3)
    freeze_retry_checkpoint(runtime_dir, checkpoint)

    path = retry_checkpoint_path(runtime_dir)
    data = json.loads(path.read_text(encoding="utf-8"))
    data["budget_disposition"] = RetryBudgetDisposition.RETRY_EXHAUSTED.value
    data["next_attempt_state"] = None
    path.write_text(json.dumps(data), encoding="utf-8")

    with pytest.raises(RetryCheckpointStoreError):
        load_retry_checkpoint(runtime_dir)


def test_load_propagates_retry_protocol_error_for_stale_persisted_authority(
    tmp_path: Path,
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint(current_attempt=1, max_attempts=3)
    freeze_retry_checkpoint(runtime_dir, checkpoint)

    path = retry_checkpoint_path(runtime_dir)
    data = json.loads(path.read_text(encoding="utf-8"))
    data["attempt_state"]["current_attempt"] = 2
    path.write_text(json.dumps(data), encoding="utf-8")

    with pytest.raises(RetryProtocolError):
        load_retry_checkpoint(runtime_dir)


# ---------------------------------------------------------------------------
# Symlink final path (Section 64)
# ---------------------------------------------------------------------------


def test_freeze_rejects_symlinked_checkpoint_file(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    path = retry_checkpoint_path(runtime_dir)
    path.parent.mkdir(parents=True)
    external_target = tmp_path / "external-checkpoint.json"
    external_target.write_text("external", encoding="utf-8")
    _symlink_or_skip(path, external_target)

    checkpoint, *_ = _valid_escalation_checkpoint()
    with pytest.raises(RetryCheckpointStoreError):
        freeze_retry_checkpoint(runtime_dir, checkpoint)

    assert external_target.read_text(encoding="utf-8") == "external"


def test_load_rejects_symlinked_checkpoint_file(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    path = retry_checkpoint_path(runtime_dir)
    path.parent.mkdir(parents=True)
    external_target = tmp_path / "external-checkpoint.json"
    external_target.write_text("external", encoding="utf-8")
    _symlink_or_skip(path, external_target)

    with pytest.raises(RetryCheckpointStoreError):
        load_retry_checkpoint(runtime_dir)

    assert external_target.read_text(encoding="utf-8") == "external"


# ---------------------------------------------------------------------------
# Symlink retry directory (Section 65)
# ---------------------------------------------------------------------------


def test_freeze_rejects_symlinked_retry_directory(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    real_dir = tmp_path / "real-retry-dir"
    real_dir.mkdir()
    _symlink_or_skip(runtime_dir / "retry", real_dir)

    checkpoint, *_ = _valid_escalation_checkpoint()
    with pytest.raises(RetryCheckpointStoreError):
        freeze_retry_checkpoint(runtime_dir, checkpoint)

    assert list(real_dir.iterdir()) == []


def test_load_rejects_symlinked_retry_directory(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    real_dir = tmp_path / "real-retry-dir"
    real_dir.mkdir()
    _symlink_or_skip(runtime_dir / "retry", real_dir)

    with pytest.raises(RetryCheckpointStoreError):
        load_retry_checkpoint(runtime_dir)


# ---------------------------------------------------------------------------
# Atomic-write fault seam (Section 66 / PROCESS_DEBT #8 regression protection)
# ---------------------------------------------------------------------------


def test_atomic_write_calls_private_replace_seam() -> None:
    source = inspect.getsource(retry_checkpoint_module._atomic_write_checkpoint)
    called = _call_names(ast.parse(source))

    assert "_replace_atomically" in called
    assert "replace" not in called


def test_replace_atomically_is_a_thin_wrapper_around_os_replace() -> None:
    source = inspect.getsource(retry_checkpoint_module._replace_atomically)
    tree = ast.parse(source)

    os_replace_calls = [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "replace"
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id == "os"
    ]
    assert len(os_replace_calls) == 1


def test_no_test_ever_patches_the_shared_os_replace_seam() -> None:
    test_source = Path(__file__).read_text(encoding="utf-8")
    tree = ast.parse(test_source)

    for node in ast.walk(tree):
        if not (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr == "setattr"
            and len(node.args) >= 2
        ):
            continue

        target_arg, name_arg = node.args[0], node.args[1]
        if not (isinstance(name_arg, ast.Constant) and name_arg.value == "replace"):
            continue

        is_bare_os = isinstance(target_arg, ast.Name) and target_arg.id == "os"
        is_module_os_attr = isinstance(target_arg, ast.Attribute) and target_arg.attr == "os"
        assert not is_bare_os, "test must not patch the shared os.replace function"
        assert not is_module_os_attr, (
            "test must not patch retry_checkpoint.os.replace; "
            "patch retry_checkpoint._replace_atomically instead"
        )


def test_forced_replace_failure_leaves_no_partial_checkpoint(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()

    def fail_replace(source: object, target: object) -> None:
        raise OSError("simulated replace failure")

    monkeypatch.setattr(retry_checkpoint_module, "_replace_atomically", fail_replace)

    with pytest.raises(RetryCheckpointStoreError):
        freeze_retry_checkpoint(runtime_dir, checkpoint)

    path = retry_checkpoint_path(runtime_dir)
    assert not path.exists()
    assert list(path.parent.glob(".checkpoint.json.*.tmp")) == []


# ---------------------------------------------------------------------------
# No invocation/provider payload (Section 67)
# ---------------------------------------------------------------------------


def test_serialized_checkpoint_excludes_invocation_and_provider_payload() -> None:
    request = _escalation_request(question="Why is SENTINEL-QUESTION-RETRY-CHECKPOINT needed?")
    decision = _planner_decision(request, rationale="SENTINEL-RATIONALE-RETRY-CHECKPOINT")
    resolution = resolve_planner_decision(request, decision)
    invocation = _agent_invocation_result(
        stdout="SENTINEL-STDOUT-INVOCATION", adapter_name="SENTINEL-ADAPTER-NAME"
    )
    planner_turn = PlannerDecisionTurnResult(
        decision=decision, resolution=resolution, invocation=invocation
    )
    result = _escalation_result(
        request=request,
        disposition=SupervisorEscalationDisposition.RESUME_AGENT,
        planner_turn=planner_turn,
    )
    attempt_state = _attempt_state(current_attempt=1)
    budget = RetryBudget(max_attempts=3)

    checkpoint = create_retry_checkpoint_from_escalation(
        attempt_state=attempt_state, budget=budget, result=result
    )
    assert checkpoint is not None

    serialized = json.dumps(checkpoint.model_dump(mode="json"))

    assert "SENTINEL-STDOUT-INVOCATION" not in serialized
    assert "SENTINEL-ADAPTER-NAME" not in serialized
    assert "SENTINEL-QUESTION-RETRY-CHECKPOINT" in serialized
    assert "SENTINEL-RATIONALE-RETRY-CHECKPOINT" in serialized


# ---------------------------------------------------------------------------
# Deterministic bytes (Section 68)
# ---------------------------------------------------------------------------


def test_freeze_produces_identical_bytes_for_equivalent_checkpoints_in_separate_runtimes(
    tmp_path: Path,
) -> None:
    runtime_a = tmp_path / "runtime-a"
    runtime_a.mkdir()
    runtime_b = tmp_path / "runtime-b"
    runtime_b.mkdir()

    checkpoint_a, *_ = _valid_escalation_checkpoint()
    checkpoint_b, *_ = _valid_escalation_checkpoint()

    freeze_retry_checkpoint(runtime_a, checkpoint_a)
    freeze_retry_checkpoint(runtime_b, checkpoint_b)

    assert (
        retry_checkpoint_path(runtime_a).read_bytes()
        == retry_checkpoint_path(runtime_b).read_bytes()
    )


# ---------------------------------------------------------------------------
# Load is read-only (Section 69)
# ---------------------------------------------------------------------------


def test_load_is_read_only(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)

    path = retry_checkpoint_path(runtime_dir)
    before = path.read_bytes()

    loaded = load_retry_checkpoint(runtime_dir)

    assert loaded == checkpoint
    assert path.read_bytes() == before


# ---------------------------------------------------------------------------
# No execution dependencies (Section 70)
# ---------------------------------------------------------------------------

_ALLOWED_LOCKSTEP_IMPORTS = frozenset(
    {
        "lockstep.domain",
        "lockstep.escalation",
        "lockstep.escalation_decision",
        "lockstep.retry",
        "lockstep.supervisor.escalation",
    }
)

_FORBIDDEN_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.runtime",
    "lockstep.agent_turn",
    "lockstep.reviewer_turn",
    "lockstep.supervisor.transaction",
    "lockstep.planning_store",
    "lockstep.planning_workflow",
    "lockstep.planning_transport",
    "lockstep.planning",
    "lockstep.git",
    "lockstep.process",
    "lockstep.persistence",
    "lockstep.verification",
    "lockstep.reporting",
    "lockstep.cli",
    "lockstep.agents",
    "lockstep.context",
    "lockstep.state",
    "subprocess",
)


def _imported_modules(tree: ast.Module) -> set[str]:
    imported_modules: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imported_modules.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            imported_modules.add(node.module or "")
    return imported_modules


def test_retry_checkpoint_module_only_imports_from_the_allowed_pure_surface() -> None:
    tree = ast.parse(inspect.getsource(retry_checkpoint_module))
    imported_modules = _imported_modules(tree)

    lockstep_imports = {
        module
        for module in imported_modules
        if module == "lockstep" or module.startswith("lockstep.")
    }
    assert lockstep_imports <= _ALLOWED_LOCKSTEP_IMPORTS


def test_retry_checkpoint_module_has_no_forbidden_imports() -> None:
    tree = ast.parse(inspect.getsource(retry_checkpoint_module))
    imported_modules = _imported_modules(tree)

    for forbidden_prefix in _FORBIDDEN_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


# ---------------------------------------------------------------------------
# No execution calls (Section 71)
# ---------------------------------------------------------------------------


def test_retry_checkpoint_module_has_no_execution_primitives() -> None:
    source = inspect.getsource(retry_checkpoint_module)
    tree = ast.parse(source)

    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            assert node.func.id not in {
                "invoke_agent",
                "invoke_agent_turn",
                "invoke_reviewer_turn",
                "invoke_planner_decision",
                "dispatch_escalation",
                "sleep",
                "input",
                "print",
            }

    for forbidden in (
        "invoke_agent",
        "invoke_agent_turn",
        "invoke_reviewer_turn",
        "invoke_planner_decision",
        "dispatch_escalation",
        "subprocess",
        "time.sleep",
    ):
        assert forbidden not in source
