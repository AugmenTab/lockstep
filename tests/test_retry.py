"""Tests for the Phase 9.8 attempt-state and retry-budget protocol.

Specifies ``lockstep.retry`` before it exists: a pure, deterministic
control-plane protocol answering what the current Sub-phase attempt is,
which structured outcomes authorize another attempt
(``retry_request_from_escalation``, ``retry_request_from_review``), and
whether a configured retry budget permits it (``evaluate_retry``).

This module consumes already-produced, structured Phase-9 evidence -- a
validated ``SupervisorEscalationResult`` (9.5) and an existing
``ReviewDecision`` (domain) -- without mutating the Supervisor
transaction, persisting anything, or re-entering an agent. It answers
only "is another attempt authorized and permitted", never "go run it";
9.9 will integrate this pure protocol into durable resume execution.
"""

import ast
import dataclasses
import inspect

import pytest
from pydantic import ValidationError

import lockstep.retry as retry_module
from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    PhaseId,
    ReviewDecision,
    ReviewVerdict,
    SubphaseId,
)
from lockstep.escalation import (
    EscalationAuthority,
    EscalationCategory,
    EscalationRequest,
    route_escalation,
)
from lockstep.retry import (
    AttemptState,
    RetryBudget,
    RetryBudgetDisposition,
    RetryEvaluation,
    RetryProtocolError,
    RetryReason,
    RetryRequest,
    evaluate_retry,
    retry_request_from_escalation,
    retry_request_from_review,
)
from lockstep.supervisor.escalation import (
    SupervisorEscalationDisposition,
    SupervisorEscalationResult,
)

_PHASE_ID = "09"
_SUBPHASE_ID = "08"


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


def _escalation_result(
    *,
    request: EscalationRequest | None = None,
    disposition: SupervisorEscalationDisposition = SupervisorEscalationDisposition.RESUME_AGENT,
) -> SupervisorEscalationResult:
    resolved_request = request if request is not None else _escalation_request()
    return SupervisorEscalationResult(
        request=resolved_request,
        route=route_escalation(resolved_request),
        disposition=disposition,
    )


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


def _retry_request(
    *,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    observed_attempt: int = 1,
    reason: RetryReason = RetryReason.ESCALATION_RESUME,
    target_role: AgentRole = AgentRole.IMPLEMENTER,
) -> RetryRequest:
    return RetryRequest(
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        observed_attempt=observed_attempt,
        reason=reason,
        target_role=target_role,
    )


# ---------------------------------------------------------------------------
# Public surface (Section 39)
# ---------------------------------------------------------------------------


def test_public_api_exports_expected_names() -> None:
    assert {
        "RetryReason",
        "RetryBudgetDisposition",
        "RetryBudget",
        "AttemptState",
        "RetryRequest",
        "RetryEvaluation",
        "RetryProtocolError",
        "retry_request_from_escalation",
        "retry_request_from_review",
        "evaluate_retry",
    }.issubset(set(retry_module.__all__))


def test_public_names_are_importable_from_the_module() -> None:
    assert RetryReason is not None
    assert RetryBudgetDisposition is not None
    assert RetryBudget is not None
    assert AttemptState is not None
    assert RetryRequest is not None
    assert RetryEvaluation is not None
    assert RetryProtocolError is not None
    assert callable(retry_request_from_escalation)
    assert callable(retry_request_from_review)
    assert callable(evaluate_retry)


# ---------------------------------------------------------------------------
# Exact enum values (Section 40)
# ---------------------------------------------------------------------------


def test_retry_reason_values_are_stable() -> None:
    assert {member.name: member.value for member in RetryReason} == {
        "ESCALATION_RESUME": "escalation_resume",
        "REVIEW_REWORK": "review_rework",
    }
    forbidden_names = {"OTHER", "UNKNOWN", "PROCESS_FAILURE", "PROVIDER_FAILURE", "TEST_FAILURE"}
    assert forbidden_names.isdisjoint(set(RetryReason.__members__))


def test_retry_budget_disposition_values_are_stable() -> None:
    assert {member.name: member.value for member in RetryBudgetDisposition} == {
        "RETRY_AVAILABLE": "retry_available",
        "RETRY_EXHAUSTED": "retry_exhausted",
    }
    forbidden_names = {"RETRYING", "RETRIED", "FAILED", "RUN_HALT"}
    assert forbidden_names.isdisjoint(set(RetryBudgetDisposition.__members__))


def test_retry_reason_rejects_unknown_value() -> None:
    with pytest.raises(ValueError):
        RetryReason("not_a_real_reason")


def test_retry_budget_disposition_rejects_unknown_value() -> None:
    with pytest.raises(ValueError):
        RetryBudgetDisposition("not_a_real_disposition")


# ---------------------------------------------------------------------------
# RetryBudget (Section 41)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("max_attempts", [1, 2, 10, 1_000_000])
def test_retry_budget_accepts_valid_max_attempts(max_attempts: int) -> None:
    budget = RetryBudget(max_attempts=max_attempts)
    assert budget.max_attempts == AttemptNumber.model_validate(max_attempts)


@pytest.mark.parametrize("max_attempts", [0, -1, "3", True, False])
def test_retry_budget_rejects_invalid_max_attempts(max_attempts: object) -> None:
    with pytest.raises(ValidationError):
        RetryBudget(max_attempts=max_attempts)  # type: ignore[arg-type]


def test_retry_budget_requires_max_attempts_explicitly() -> None:
    with pytest.raises(ValidationError):
        RetryBudget()  # type: ignore[call-arg]


def test_retry_budget_is_frozen() -> None:
    budget = RetryBudget(max_attempts=3)
    with pytest.raises(ValidationError):
        budget.max_attempts = AttemptNumber.model_validate(5)  # type: ignore[misc]


def test_retry_budget_rejects_unknown_fields() -> None:
    with pytest.raises(ValidationError):
        RetryBudget(max_attempts=3, retry_after=5)  # type: ignore[call-arg]


def test_retry_budget_has_exactly_one_field() -> None:
    assert set(RetryBudget.model_fields) == {"max_attempts"}


# ---------------------------------------------------------------------------
# AttemptState (Section 42)
# ---------------------------------------------------------------------------


def test_attempt_state_has_exactly_expected_fields() -> None:
    assert set(AttemptState.model_fields) == {"phase_id", "subphase_id", "current_attempt"}


def test_attempt_state_is_frozen() -> None:
    state = _attempt_state()
    with pytest.raises(ValidationError):
        state.current_attempt = AttemptNumber.model_validate(2)  # type: ignore[misc]


def test_attempt_state_rejects_unknown_fields() -> None:
    with pytest.raises(ValidationError):
        AttemptState(
            phase_id=_phase_id(),
            subphase_id=_subphase_id(),
            current_attempt=1,
            provider="claude",
        )  # type: ignore[call-arg]


def test_attempt_state_reuses_canonical_identifier_types() -> None:
    state = _attempt_state()
    assert isinstance(state.phase_id, PhaseId)
    assert isinstance(state.subphase_id, SubphaseId)
    assert isinstance(state.current_attempt, AttemptNumber)


# ---------------------------------------------------------------------------
# RetryRequest (Section 43)
# ---------------------------------------------------------------------------


def test_retry_request_has_exactly_expected_fields() -> None:
    assert set(RetryRequest.model_fields) == {
        "phase_id",
        "subphase_id",
        "observed_attempt",
        "reason",
        "target_role",
    }


def test_retry_request_is_frozen() -> None:
    request = _retry_request()
    with pytest.raises(ValidationError):
        request.target_role = AgentRole.REVIEWER  # type: ignore[misc]


def test_retry_request_rejects_unknown_fields() -> None:
    with pytest.raises(ValidationError):
        RetryRequest(
            phase_id=_phase_id(),
            subphase_id=_subphase_id(),
            observed_attempt=1,
            reason=RetryReason.ESCALATION_RESUME,
            target_role=AgentRole.IMPLEMENTER,
            provider="claude",
        )  # type: ignore[call-arg]


def test_retry_request_rejects_planner_target() -> None:
    with pytest.raises(ValidationError):
        _retry_request(target_role=AgentRole.PLANNER)


def test_retry_request_rejects_scribe_target() -> None:
    with pytest.raises(ValidationError):
        _retry_request(target_role=AgentRole.SCRIBE)


@pytest.mark.parametrize("target_role", [AgentRole.IMPLEMENTER, AgentRole.REVIEWER])
def test_retry_request_accepts_implementer_and_reviewer_targets(target_role: AgentRole) -> None:
    request = _retry_request(target_role=target_role)
    assert request.target_role == target_role


# ---------------------------------------------------------------------------
# Escalation RESUME extraction -- Implementer / Reviewer (Sections 44-45)
# ---------------------------------------------------------------------------


def test_escalation_resume_targets_implementer_when_implementer_blocked() -> None:
    request = _escalation_request(source_role=AgentRole.IMPLEMENTER, attempt=2)
    result = _escalation_result(request=request)

    retry_request = retry_request_from_escalation(result)

    assert retry_request is not None
    assert retry_request.reason == RetryReason.ESCALATION_RESUME
    assert retry_request.target_role == AgentRole.IMPLEMENTER
    assert retry_request.phase_id == request.phase_id
    assert retry_request.subphase_id == request.subphase_id
    assert retry_request.observed_attempt == request.attempt


def test_escalation_resume_targets_reviewer_when_reviewer_blocked() -> None:
    request = _escalation_request(source_role=AgentRole.REVIEWER, attempt=3)
    result = _escalation_result(request=request)

    retry_request = retry_request_from_escalation(result)

    assert retry_request is not None
    assert retry_request.reason == RetryReason.ESCALATION_RESUME
    assert retry_request.target_role == AgentRole.REVIEWER
    assert retry_request.phase_id == request.phase_id
    assert retry_request.subphase_id == request.subphase_id
    assert retry_request.observed_attempt == request.attempt


# ---------------------------------------------------------------------------
# Non-resume escalation dispositions (Section 46)
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
def test_non_resume_escalation_dispositions_yield_no_retry_request(
    disposition: SupervisorEscalationDisposition,
) -> None:
    result = _escalation_result(disposition=disposition)
    assert retry_request_from_escalation(result) is None


# ---------------------------------------------------------------------------
# Impossible Planner-source resume (Section 47)
# ---------------------------------------------------------------------------


def test_planner_source_resume_is_rejected_as_a_protocol_error() -> None:
    request = _escalation_request(
        source_role=AgentRole.PLANNER,
        category=EscalationCategory.PLANNER_DECISION_REQUIRED,
        requested_authority=EscalationAuthority.PLANNER,
    )
    result = _escalation_result(request=request)

    with pytest.raises(RetryProtocolError):
        retry_request_from_escalation(result)


# ---------------------------------------------------------------------------
# Requested-authority independence (Section 48)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "requested_authority",
    [EscalationAuthority.PLANNER, EscalationAuthority.HUMAN, EscalationAuthority.SUPERVISOR],
)
def test_requested_authority_does_not_affect_retry_target(
    requested_authority: EscalationAuthority,
) -> None:
    request = _escalation_request(
        source_role=AgentRole.IMPLEMENTER, requested_authority=requested_authority
    )
    result = _escalation_result(request=request)

    retry_request = retry_request_from_escalation(result)

    assert retry_request == RetryRequest(
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        observed_attempt=request.attempt,
        reason=RetryReason.ESCALATION_RESUME,
        target_role=AgentRole.IMPLEMENTER,
    )


# ---------------------------------------------------------------------------
# Review REWORK (Section 49)
# ---------------------------------------------------------------------------


def test_review_rework_targets_implementer() -> None:
    decision = _review_decision(verdict=ReviewVerdict.REWORK, attempt=2)

    retry_request = retry_request_from_review(decision)

    assert retry_request is not None
    assert retry_request.reason == RetryReason.REVIEW_REWORK
    assert retry_request.target_role == AgentRole.IMPLEMENTER
    assert retry_request.phase_id == decision.phase_id
    assert retry_request.subphase_id == decision.subphase_id
    assert retry_request.observed_attempt == decision.attempt


# ---------------------------------------------------------------------------
# Review APPROVE / HALT (Section 50)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("verdict", [ReviewVerdict.APPROVE, ReviewVerdict.HALT])
def test_review_approve_and_halt_yield_no_retry_request(verdict: ReviewVerdict) -> None:
    decision = _review_decision(verdict=verdict, summary="Terminal review outcome.")
    assert retry_request_from_review(decision) is None


# ---------------------------------------------------------------------------
# Error-type distinction (Section 17 / AC-9.8.34)
# ---------------------------------------------------------------------------


def test_retry_protocol_error_is_a_normal_exception_distinct_from_validation_error() -> None:
    error = RetryProtocolError("bounded protocol violation")
    assert isinstance(error, Exception)
    assert not isinstance(error, ValidationError)
    assert "bounded protocol violation" in str(error)


def test_model_shape_errors_are_validation_errors_not_protocol_errors() -> None:
    with pytest.raises(ValidationError):
        RetryBudget(max_attempts=0)


def test_composition_errors_are_protocol_errors_not_validation_errors() -> None:
    state = _attempt_state(current_attempt=1)
    request = _retry_request(observed_attempt=2)
    with pytest.raises(RetryProtocolError):
        evaluate_retry(state, RetryBudget(max_attempts=3), request)


# ---------------------------------------------------------------------------
# Validation precedence (Section 51)
# ---------------------------------------------------------------------------


def test_phase_mismatch_is_detected_before_stale_attempt() -> None:
    state = _attempt_state(phase_id="09", current_attempt=2)
    request = _retry_request(phase_id="10", observed_attempt=1)

    with pytest.raises(RetryProtocolError) as excinfo:
        evaluate_retry(state, RetryBudget(max_attempts=3), request)
    assert "phase" in str(excinfo.value)


def test_subphase_mismatch_is_detected_before_stale_attempt() -> None:
    state = _attempt_state(subphase_id="08", current_attempt=2)
    request = _retry_request(subphase_id="09", observed_attempt=1)

    with pytest.raises(RetryProtocolError) as excinfo:
        evaluate_retry(state, RetryBudget(max_attempts=3), request)
    assert "subphase" in str(excinfo.value)


def test_stale_attempt_is_detected_before_budget_consistency() -> None:
    state = _attempt_state(current_attempt=4)
    request = _retry_request(observed_attempt=1)

    with pytest.raises(RetryProtocolError) as excinfo:
        evaluate_retry(state, RetryBudget(max_attempts=3), request)
    assert "attempt" in str(excinfo.value)


def test_phase_mismatch_takes_precedence_over_subphase_mismatch() -> None:
    state = _attempt_state(phase_id="09", subphase_id="08", current_attempt=1)
    request = _retry_request(phase_id="10", subphase_id="09", observed_attempt=1)

    with pytest.raises(RetryProtocolError) as excinfo:
        evaluate_retry(state, RetryBudget(max_attempts=3), request)
    message = str(excinfo.value)
    assert "phase" in message
    assert "subphase" not in message


# ---------------------------------------------------------------------------
# Attempt-budget arithmetic (Sections 52-55)
# ---------------------------------------------------------------------------


def test_attempt_one_of_three_is_available_with_next_attempt_two() -> None:
    state = _attempt_state(current_attempt=1)
    request = _retry_request(observed_attempt=1)

    evaluation = evaluate_retry(state, RetryBudget(max_attempts=3), request)

    assert evaluation.disposition == RetryBudgetDisposition.RETRY_AVAILABLE
    assert evaluation.next_state is not None
    assert evaluation.next_state.current_attempt == AttemptNumber.model_validate(2)


def test_attempt_two_of_three_is_available_with_next_attempt_three() -> None:
    state = _attempt_state(current_attempt=2)
    request = _retry_request(observed_attempt=2)

    evaluation = evaluate_retry(state, RetryBudget(max_attempts=3), request)

    assert evaluation.disposition == RetryBudgetDisposition.RETRY_AVAILABLE
    assert evaluation.next_state is not None
    assert evaluation.next_state.current_attempt == AttemptNumber.model_validate(3)


def test_attempt_three_of_three_is_exhausted_with_no_next_state() -> None:
    state = _attempt_state(current_attempt=3)
    request = _retry_request(observed_attempt=3)

    evaluation = evaluate_retry(state, RetryBudget(max_attempts=3), request)

    assert evaluation.disposition == RetryBudgetDisposition.RETRY_EXHAUSTED
    assert evaluation.next_state is None


def test_one_attempt_policy_permits_no_retry() -> None:
    state = _attempt_state(current_attempt=1)
    request = _retry_request(observed_attempt=1)

    evaluation = evaluate_retry(state, RetryBudget(max_attempts=1), request)

    assert evaluation.disposition == RetryBudgetDisposition.RETRY_EXHAUSTED
    assert evaluation.next_state is None


# ---------------------------------------------------------------------------
# State exceeding budget (Section 56)
# ---------------------------------------------------------------------------


def test_state_already_exceeding_budget_is_a_protocol_error_not_exhaustion() -> None:
    state = _attempt_state(current_attempt=4)
    request = _retry_request(observed_attempt=4)

    with pytest.raises(RetryProtocolError):
        evaluate_retry(state, RetryBudget(max_attempts=3), request)


# ---------------------------------------------------------------------------
# Stale retry request (Section 57)
# ---------------------------------------------------------------------------


def test_stale_retry_request_is_rejected() -> None:
    state = _attempt_state(current_attempt=2)
    request = _retry_request(observed_attempt=1)

    with pytest.raises(RetryProtocolError):
        evaluate_retry(state, RetryBudget(max_attempts=3), request)


# ---------------------------------------------------------------------------
# Phase / Sub-phase mismatch (Section 58)
# ---------------------------------------------------------------------------


def test_phase_mismatch_alone_is_rejected() -> None:
    state = _attempt_state(phase_id="09", current_attempt=1)
    request = _retry_request(phase_id="10", observed_attempt=1)

    with pytest.raises(RetryProtocolError):
        evaluate_retry(state, RetryBudget(max_attempts=3), request)


def test_subphase_mismatch_alone_is_rejected() -> None:
    state = _attempt_state(subphase_id="08", current_attempt=1)
    request = _retry_request(subphase_id="09", observed_attempt=1)

    with pytest.raises(RetryProtocolError):
        evaluate_retry(state, RetryBudget(max_attempts=3), request)


# ---------------------------------------------------------------------------
# Next-state identity (Section 59)
# ---------------------------------------------------------------------------


def test_available_retry_preserves_phase_and_subphase_and_increments_only_attempt() -> None:
    state = _attempt_state(phase_id="09", subphase_id="08", current_attempt=1)
    request = _retry_request(phase_id="09", subphase_id="08", observed_attempt=1)

    evaluation = evaluate_retry(state, RetryBudget(max_attempts=3), request)

    assert evaluation.next_state is not None
    assert evaluation.next_state.phase_id == state.phase_id
    assert evaluation.next_state.subphase_id == state.subphase_id
    assert evaluation.next_state.current_attempt == AttemptNumber.model_validate(2)


# ---------------------------------------------------------------------------
# No mutation (Section 60)
# ---------------------------------------------------------------------------


def test_evaluate_retry_does_not_mutate_its_inputs() -> None:
    state = _attempt_state(current_attempt=1)
    budget = RetryBudget(max_attempts=3)
    request = _retry_request(observed_attempt=1)

    state_before = state.model_dump(mode="json")
    budget_before = budget.model_dump(mode="json")
    request_before = request.model_dump(mode="json")

    evaluate_retry(state, budget, request)

    assert state.model_dump(mode="json") == state_before
    assert budget.model_dump(mode="json") == budget_before
    assert request.model_dump(mode="json") == request_before


# ---------------------------------------------------------------------------
# Result shape (Section 61)
# ---------------------------------------------------------------------------


def test_retry_evaluation_is_frozen_slotted_with_exactly_five_fields() -> None:
    state = _attempt_state(current_attempt=1)
    budget = RetryBudget(max_attempts=3)
    request = _retry_request(observed_attempt=1)

    evaluation = evaluate_retry(state, budget, request)

    field_names = {field.name for field in dataclasses.fields(evaluation)}
    assert field_names == {"state", "budget", "request", "disposition", "next_state"}
    assert set(type(evaluation).__slots__) == field_names
    assert not hasattr(evaluation, "__dict__")

    with pytest.raises(dataclasses.FrozenInstanceError):
        evaluation.disposition = RetryBudgetDisposition.RETRY_EXHAUSTED  # type: ignore[misc]


def test_retry_evaluation_preserves_input_identity() -> None:
    state = _attempt_state(current_attempt=1)
    budget = RetryBudget(max_attempts=3)
    request = _retry_request(observed_attempt=1)

    evaluation = evaluate_retry(state, budget, request)

    assert evaluation.state is state
    assert evaluation.budget is budget
    assert evaluation.request is request


# ---------------------------------------------------------------------------
# Determinism (Sections 33/38)
# ---------------------------------------------------------------------------


def test_evaluate_retry_is_deterministic_for_equivalent_inputs() -> None:
    def _build() -> tuple[AttemptState, RetryBudget, RetryRequest]:
        return (
            _attempt_state(current_attempt=2),
            RetryBudget(max_attempts=3),
            _retry_request(observed_attempt=2),
        )

    state_a, budget_a, request_a = _build()
    state_b, budget_b, request_b = _build()

    evaluation_a = evaluate_retry(state_a, budget_a, request_a)
    evaluation_b = evaluate_retry(state_b, budget_b, request_b)

    assert evaluation_a.disposition == evaluation_b.disposition
    assert evaluation_a.next_state == evaluation_b.next_state


# ---------------------------------------------------------------------------
# Error privacy (Section 62)
# ---------------------------------------------------------------------------


def test_protocol_errors_do_not_leak_structured_object_content() -> None:
    question_sentinel = "SENTINEL-QUESTION-9F2C-RETRY"
    evidence_sentinel = "SENTINEL-EVIDENCE-8B3D-RETRY"

    request = _escalation_request(
        source_role=AgentRole.PLANNER,
        category=EscalationCategory.PLANNER_DECISION_REQUIRED,
        question=f"{question_sentinel} - is this resolved?",
        evidence=(f"{evidence_sentinel} - the Planner authorized itself.",),
        requested_authority=EscalationAuthority.PLANNER,
    )
    result = _escalation_result(request=request)

    with pytest.raises(RetryProtocolError) as excinfo:
        retry_request_from_escalation(result)

    message = str(excinfo.value)
    assert question_sentinel not in message
    assert evidence_sentinel not in message


def test_evaluate_retry_protocol_errors_do_not_leak_identifiers() -> None:
    state = _attempt_state(phase_id="09", current_attempt=1)
    request = _retry_request(phase_id="10", observed_attempt=1)

    with pytest.raises(RetryProtocolError) as excinfo:
        evaluate_retry(state, RetryBudget(max_attempts=3), request)

    message = str(excinfo.value)
    assert len(message) < 200


# ---------------------------------------------------------------------------
# No prose interpretation (Section 24 / AC-9.8.22)
# ---------------------------------------------------------------------------


def test_retry_module_never_reads_prose_fields() -> None:
    tree = ast.parse(inspect.getsource(retry_module))
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute):
            assert node.attr not in {
                "summary",
                "findings",
                "rationale",
                "instructions",
                "question",
                "evidence",
            }


# ---------------------------------------------------------------------------
# Pure dependency boundary (Section 63)
# ---------------------------------------------------------------------------

_ALLOWED_LOCKSTEP_IMPORTS = frozenset(
    {
        "lockstep.domain",
        "lockstep.escalation",
        "lockstep.escalation_decision",
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
    "os",
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


def test_retry_module_only_imports_from_the_allowed_pure_surface() -> None:
    tree = ast.parse(inspect.getsource(retry_module))
    imported_modules = _imported_modules(tree)

    lockstep_imports = {
        module
        for module in imported_modules
        if module == "lockstep" or module.startswith("lockstep.")
    }
    assert lockstep_imports <= _ALLOWED_LOCKSTEP_IMPORTS


def test_retry_module_has_no_forbidden_imports() -> None:
    tree = ast.parse(inspect.getsource(retry_module))
    imported_modules = _imported_modules(tree)

    for forbidden_prefix in _FORBIDDEN_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


# ---------------------------------------------------------------------------
# Provider neutrality (Section 65)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("provider_name", ["claude", "codex", "openai", "anthropic"])
def test_retry_module_source_has_no_provider_names(provider_name: str) -> None:
    source = inspect.getsource(retry_module).lower()
    assert provider_name not in source


# ---------------------------------------------------------------------------
# No execution primitives (Section 66)
# ---------------------------------------------------------------------------


def test_retry_module_has_no_execution_primitives() -> None:
    source = inspect.getsource(retry_module)
    tree = ast.parse(source)

    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            assert node.func.id not in {
                "invoke_agent",
                "invoke_agent_turn",
                "invoke_reviewer_turn",
                "dispatch_escalation",
                "sleep",
                "input",
                "print",
                "open",
            }

    for forbidden in (
        "invoke_agent",
        "invoke_agent_turn",
        "invoke_reviewer_turn",
        "dispatch_escalation",
        "subprocess",
        "time.sleep",
    ):
        assert forbidden not in source


# ---------------------------------------------------------------------------
# No backoff (Section 35)
# ---------------------------------------------------------------------------


def test_retry_module_has_no_backoff_vocabulary() -> None:
    source = inspect.getsource(retry_module).lower()
    for forbidden in ("backoff", "retry_after", "exponential"):
        assert forbidden not in source
