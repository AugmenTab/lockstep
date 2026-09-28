"""Attempt state and retry-budget protocol (Phase 9.8).

Defines the pure, deterministic control-plane protocol that answers,
from already-produced structured Phase-9 evidence, whether another
attempt at a blocked or reworked role is authorized and permitted:

    current AttemptState
            +
    retry-triggering structured outcome
            |
    RetryRequest
            +
    RetryBudget
            |
    evaluate_retry(...)
            |
    RETRY_AVAILABLE + exact next AttemptState
        or
    RETRY_EXHAUSTED + no next state

Core invariant: retry is an explicit deterministic control-plane
decision, never an invisible loop around an agent call. Only two
structured outcomes carry retry authority --
:class:`~lockstep.supervisor.escalation.SupervisorEscalationResult`
with disposition ``RESUME_AGENT`` (:func:`retry_request_from_escalation`)
and an existing :class:`~lockstep.domain.ReviewDecision` with verdict
``REWORK`` (:func:`retry_request_from_review`) -- and only structured
enum fields are ever inspected; no prose, rationale, question, or
evidence text influences either function. This module does not mutate
the Supervisor transaction, does not persist anything, and does not
re-enter an agent; it answers only whether another attempt is
authorized and permitted, not how to run it.
"""

from dataclasses import dataclass
from enum import StrEnum
from typing import Annotated

from pydantic import AfterValidator, BaseModel, ConfigDict

from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    PhaseId,
    ReviewDecision,
    ReviewVerdict,
    SubphaseId,
)
from lockstep.supervisor.escalation import (
    SupervisorEscalationDisposition,
    SupervisorEscalationResult,
)

_RETRYABLE_TARGET_ROLES = frozenset({AgentRole.IMPLEMENTER, AgentRole.REVIEWER})


class RetryReason(StrEnum):
    """Why another attempt is structurally authorized."""

    ESCALATION_RESUME = "escalation_resume"
    REVIEW_REWORK = "review_rework"


class RetryBudgetDisposition(StrEnum):
    """Whether a configured retry budget still permits another attempt."""

    RETRY_AVAILABLE = "retry_available"
    RETRY_EXHAUSTED = "retry_exhausted"


class RetryProtocolError(Exception):
    """Valid retry objects that cannot legally compose.

    Reserved for control-plane inconsistencies -- a phase/subphase/
    attempt mismatch between a :class:`RetryRequest` and the
    :class:`AttemptState` it is evaluated against, a current attempt
    already beyond the configured :class:`RetryBudget`, or an
    escalation RESUME whose source role is not a legal retry target --
    never for ordinary model-shape validation, which raises
    :class:`pydantic.ValidationError` instead. Messages are bounded,
    deterministic, and content-light: no prompt, question, evidence,
    rationale, or provider output.
    """


def _validate_target_role(value: AgentRole) -> AgentRole:
    if value not in _RETRYABLE_TARGET_ROLES:
        raise ValueError("target_role must be Implementer or Reviewer")
    return value


_RetryTargetRole = Annotated[AgentRole, AfterValidator(_validate_target_role)]


class RetryBudget(BaseModel):
    """The total number of permitted attempts, including the initial one.

    Strict and frozen; reuses the canonical :class:`AttemptNumber`
    validation rather than a second integer validator. There is no
    product-level default: callers must supply ``max_attempts``
    explicitly.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    max_attempts: AttemptNumber


class AttemptState(BaseModel):
    """The control-plane identity of the currently active attempt.

    Binding ``phase_id``/``subphase_id`` to ``current_attempt`` prevents
    a retry request from one Sub-phase being evaluated against another
    Sub-phase's budget state. Carries no provider, model, role, retry
    count, timestamp, or resume-token information.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    phase_id: PhaseId
    subphase_id: SubphaseId
    current_attempt: AttemptNumber


class RetryRequest(BaseModel):
    """A structured request for another attempt at a specific role.

    ``observed_attempt`` preserves the attempt under which the
    triggering structured outcome occurred, so :func:`evaluate_retry`
    can prove it matches the current :class:`AttemptState` before
    granting another attempt -- stale retry authority from an earlier
    attempt must never apply to a newer state. ``target_role`` is
    limited to :attr:`~lockstep.domain.AgentRole.IMPLEMENTER` and
    :attr:`~lockstep.domain.AgentRole.REVIEWER`; a Planner decision
    transport failure does not mean "retry Planner" under this
    protocol.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    phase_id: PhaseId
    subphase_id: SubphaseId
    observed_attempt: AttemptNumber
    reason: RetryReason
    target_role: _RetryTargetRole


@dataclass(frozen=True, slots=True)
class RetryEvaluation:
    """The deterministic outcome of evaluating one :class:`RetryRequest`.

    ``state``, ``budget``, and ``request`` are the exact objects
    supplied to :func:`evaluate_retry`, preserved by identity.
    ``next_state`` is a new :class:`AttemptState` for
    :attr:`RetryBudgetDisposition.RETRY_AVAILABLE` and ``None`` for
    :attr:`RetryBudgetDisposition.RETRY_EXHAUSTED` -- never a
    synthetic ``max_attempts + 1`` state.
    """

    state: AttemptState
    budget: RetryBudget
    request: RetryRequest
    disposition: RetryBudgetDisposition
    next_state: AttemptState | None


def retry_request_from_escalation(
    result: SupervisorEscalationResult,
) -> RetryRequest | None:
    """Derive a :class:`RetryRequest` from an already-dispatched escalation.

    Returns ``None`` unless ``result.disposition`` is exactly
    :attr:`~lockstep.supervisor.escalation.SupervisorEscalationDisposition.RESUME_AGENT`
    -- ``SUPERVISOR_ACTION_REQUIRED``, ``REPLAN_SUBPHASE``,
    ``HUMAN_REQUIRED``, and ``RUN_HALT`` never carry retry authority.
    On ``RESUME_AGENT``, the retry target is exactly the escalation's
    ``source_role``; ``result.request.requested_authority`` is never
    inspected, since 9.1/9.5 already resolved authority. If the source
    role is not a legal retry target (for example ``PLANNER``), raises
    :class:`RetryProtocolError` rather than silently reinterpreting the
    target.
    """

    if result.disposition != SupervisorEscalationDisposition.RESUME_AGENT:
        return None

    request = result.request
    if request.source_role not in _RETRYABLE_TARGET_ROLES:
        raise RetryProtocolError("resume-agent escalation source role is not a valid retry target")

    return RetryRequest(
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        observed_attempt=request.attempt,
        reason=RetryReason.ESCALATION_RESUME,
        target_role=request.source_role,
    )


def retry_request_from_review(decision: ReviewDecision) -> RetryRequest | None:
    """Derive a :class:`RetryRequest` from a completed Reviewer decision.

    Returns ``None`` unless ``decision.verdict`` is exactly
    :attr:`~lockstep.domain.ReviewVerdict.REWORK` -- ``APPROVE`` and
    ``HALT`` never carry retry authority. A REWORK verdict always
    targets :attr:`~lockstep.domain.AgentRole.IMPLEMENTER`: the
    Reviewer completed successfully and requested further
    implementation, so the Reviewer itself is not retried merely
    because it returned REWORK.
    """

    if decision.verdict != ReviewVerdict.REWORK:
        return None

    return RetryRequest(
        phase_id=decision.phase_id,
        subphase_id=decision.subphase_id,
        observed_attempt=decision.attempt,
        reason=RetryReason.REVIEW_REWORK,
        target_role=AgentRole.IMPLEMENTER,
    )


def evaluate_retry(
    state: AttemptState,
    budget: RetryBudget,
    request: RetryRequest,
) -> RetryEvaluation:
    """Evaluate whether *request* authorizes another attempt under *budget*.

    Pure: no I/O, no persistence, no runtime, no provider, no clock, no
    randomness, no mutation of any input. Validates in a fixed order,
    raising :class:`RetryProtocolError` on the first violation:

    1. ``request.phase_id`` must equal ``state.phase_id``.
    2. ``request.subphase_id`` must equal ``state.subphase_id``.
    3. ``request.observed_attempt`` must equal ``state.current_attempt``
       -- stale retry authority from an earlier attempt is rejected.
    4. ``state.current_attempt`` must not exceed ``budget.max_attempts``
       -- a state already beyond budget is inconsistent control-plane
       state, not normal exhaustion.

    Only once all four hold is the budget itself evaluated: strictly
    below ``max_attempts`` yields ``RETRY_AVAILABLE`` with a new
    :class:`AttemptState` whose ``current_attempt`` is incremented by
    exactly one; equal to ``max_attempts`` yields ``RETRY_EXHAUSTED``
    with no next state. Budget exhaustion is normal protocol output,
    not an exception.
    """

    if request.phase_id != state.phase_id:
        raise RetryProtocolError("retry request phase does not match the current attempt state")

    if request.subphase_id != state.subphase_id:
        raise RetryProtocolError("retry request subphase does not match the current attempt state")

    if request.observed_attempt != state.current_attempt:
        raise RetryProtocolError(
            "retry request observed attempt does not match the current attempt"
        )

    current = state.current_attempt.root
    max_attempts = budget.max_attempts.root
    if current > max_attempts:
        raise RetryProtocolError("current attempt exceeds the configured retry budget")

    if current < max_attempts:
        next_state = AttemptState(
            phase_id=state.phase_id,
            subphase_id=state.subphase_id,
            current_attempt=AttemptNumber.model_validate(current + 1),
        )
        return RetryEvaluation(
            state=state,
            budget=budget,
            request=request,
            disposition=RetryBudgetDisposition.RETRY_AVAILABLE,
            next_state=next_state,
        )

    return RetryEvaluation(
        state=state,
        budget=budget,
        request=request,
        disposition=RetryBudgetDisposition.RETRY_EXHAUSTED,
        next_state=None,
    )


__all__ = [
    "AttemptState",
    "RetryBudget",
    "RetryBudgetDisposition",
    "RetryEvaluation",
    "RetryProtocolError",
    "RetryReason",
    "RetryRequest",
    "evaluate_retry",
    "retry_request_from_escalation",
    "retry_request_from_review",
]
