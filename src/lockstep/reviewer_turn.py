"""Composite Reviewer decision/blocker structured turn (Phase 9.7).

Unifies the Reviewer's two structured-output needs -- deciding whether
it can complete a review at all, and (when it can) producing the normal
:class:`~lockstep.domain.ReviewDecision` -- into exactly one structured
Reviewer inference:

    Reviewer turn
        -> exactly one structured inference
        -> ReviewerTurnReport
               COMPLETED -> ReviewDecision (no blocker)
               BLOCKED   -> AgentBlockerDraft (no ReviewDecision)
        -> host injects source_role/phase_id/subphase_id/attempt for a
           BLOCKED report only
        -> ReviewerTurnResult (COMPLETED -> no request,
                                BLOCKED -> EscalationRequest)

Core invariant: a Reviewer must never need one inference to decide
whether it is blocked and a second inference to approve/rework/halt.

This module is a thin, provider-neutral orchestration seam built
strictly on top of :mod:`lockstep.escalation`, the frozen Sub-phase 9.4
role-output layer (:mod:`lockstep.agents.role_output`), and the existing
:class:`~lockstep.domain.ReviewDecision` / :class:`AgentBlockerDraft`
protocols; it neither recreates ``ReviewDecision`` validation nor
invents a duplicate blocker vocabulary. It performs no routing, no
Planner invocation, no human prompting, and no
Supervisor/workflow-state mutation -- it only transports and validates
exactly one structured Reviewer turn per call, and (for a ``BLOCKED``
outcome) constructs the resulting
:class:`~lockstep.escalation.EscalationRequest` unchanged. No retry, no
repair turn, and no fallback provider exist here.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

from pydantic import BaseModel, ConfigDict, ValidationError, model_validator

from lockstep.agent_turn import AgentBlockerDraft, AgentTurnRuntimeContext, AgentTurnStatus
from lockstep.agents import (
    AgentInvocationRequest,
    AgentInvocationResult,
    invoke_agent,
    prepare_structured_role_adapter,
    record_invocation_returned,
)
from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    ExecutionOutcome,
    InvocationIdentity,
    InvocationStage,
    PhaseId,
    ReviewDecision,
    RunId,
    SubphaseId,
)
from lockstep.escalation import EscalationRequest

_SCHEMA_NAME = "reviewer-turn-report"

_REVIEWER_TURN_PROTOCOL_SUFFIX = (
    "\n\n---\n"
    "Structured review-completion protocol:\n\n"
    "Return COMPLETED when you can perform the requested review.\n\n"
    "When COMPLETED:\n"
    "    return the normal ReviewDecision in review_decision\n"
    "    blocker must be null\n\n"
    "Return BLOCKED only when you cannot validly perform or complete the "
    "review without authority you do not possess.\n\n"
    "When BLOCKED:\n"
    "    review_decision must be null\n"
    "    return a structured blocker\n\n"
    "Do not use BLOCKED merely because you intend to return REWORK or "
    "HALT.\n\n"
    "REWORK and HALT are normal completed review decisions, not "
    "escalation blockers.\n"
)


class ReviewerTurnError(Exception):
    """A structured Reviewer turn could not be completed or transported.

    Carries a short, bounded, deterministic ``reason``. Never carries the
    request prompt, provider stdout/stderr, environment values, the
    blocker's question/evidence, or raw model output.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"reviewer turn error: {reason}")


class ReviewerTurnReport(BaseModel):
    """The strict structured final report of one composite Reviewer turn.

    Immutable and strict: unknown fields are rejected. A ``COMPLETED``
    report must carry the normal :class:`~lockstep.domain.ReviewDecision`
    and no blocker; a ``BLOCKED`` report must carry a blocker and no
    ``ReviewDecision``.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    status: AgentTurnStatus
    review_decision: ReviewDecision | None
    blocker: AgentBlockerDraft | None

    @model_validator(mode="after")
    def _check_status_payload_relationship(self) -> ReviewerTurnReport:
        if self.status is AgentTurnStatus.COMPLETED:
            if self.review_decision is None:
                raise ValueError("a COMPLETED reviewer turn report must include a review_decision")
            if self.blocker is not None:
                raise ValueError("a COMPLETED reviewer turn report must not include a blocker")
        else:
            if self.review_decision is not None:
                raise ValueError(
                    "a BLOCKED reviewer turn report must not include a review_decision"
                )
            if self.blocker is None:
                raise ValueError("a BLOCKED reviewer turn report must include a blocker")
        return self


@dataclass(frozen=True, slots=True)
class ReviewerTurnResult:
    """The result of one composite structured Reviewer turn.

    ``invocation`` is excluded from :func:`repr` so logging a result
    never dumps raw process output. ``escalation_request`` is ``None``
    for a ``COMPLETED`` report and a real, unmodified
    :class:`~lockstep.escalation.EscalationRequest` for a ``BLOCKED``
    report.
    """

    report: ReviewerTurnReport
    escalation_request: EscalationRequest | None
    invocation: AgentInvocationResult = field(repr=False)


def invoke_reviewer_turn(
    runtime: AgentTurnRuntimeContext,
    *,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
    prompt: str,
    cwd: Path,
    timeout_seconds: float,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
    run_id: RunId | None = None,
) -> ReviewerTurnResult:
    """Invoke exactly one composite structured Reviewer turn and resolve its report.

    Derives everything provider-specific from *runtime*:
    ``runtime.adapters.reviewer`` and
    ``runtime.config.routing.reviewer.billing_mode``. *cwd* is
    caller-owned so the Supervisor's existing worktree convention is
    never guessed at this layer. Appends a fixed, deterministic
    review-completion protocol suffix to *prompt*, performs exactly one
    structured inference through
    :func:`~lockstep.agents.role_output.prepare_structured_role_adapter`
    wrapping the Reviewer's own frozen authority (read-only for both
    providers), strictly hydrates the resulting :class:`ReviewerTurnReport`,
    and -- only for a ``BLOCKED`` report -- constructs a real
    :class:`~lockstep.escalation.EscalationRequest` from *phase_id*,
    *subphase_id*, *attempt*, :attr:`~lockstep.domain.AgentRole.REVIEWER`,
    and the report's blocker fields exactly as reported. When *run_id* is
    given, the host issues the turn's
    :class:`~lockstep.domain.InvocationIdentity` (Reviewer stage); without
    it no identity is issued. Performs no
    routing, no Planner invocation, no human prompting, and no
    repository/workflow-state mutation.
    """
    if not isinstance(prompt, str):
        raise ReviewerTurnError("prompt must be a string")
    if not prompt.strip():
        raise ReviewerTurnError("prompt must not be blank")
    if "\x00" in prompt:
        raise ReviewerTurnError("prompt must not contain NUL")

    base_adapter = runtime.adapters.reviewer
    billing_mode = runtime.config.routing.reviewer.billing_mode

    canonical_schema = ReviewerTurnReport.model_json_schema()

    structured_adapter = prepare_structured_role_adapter(
        base_adapter,
        role=AgentRole.REVIEWER,
        runtime_dir=runtime.runtime_dir,
        schema=canonical_schema,
        schema_name=_SCHEMA_NAME,
    )

    final_prompt = prompt + _REVIEWER_TURN_PROTOCOL_SUFFIX

    identity = (
        None
        if run_id is None
        else InvocationIdentity.issue(
            run_id=run_id,
            phase_id=phase_id,
            subphase_id=subphase_id,
            attempt=attempt,
            role=AgentRole.REVIEWER,
            stage=InvocationStage.REVIEW,
        )
    )

    invocation_request = AgentInvocationRequest(
        role=AgentRole.REVIEWER,
        billing_mode=billing_mode,
        prompt=final_prompt,
        cwd=cwd,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=termination_grace_seconds,
        identity=identity,
    )

    invocation = invoke_agent(
        structured_adapter,
        invocation_request,
        parent_env=runtime.transaction_parent_env,
        runtime_dir=runtime.runtime_dir,
        record_return=False,
    )

    process = invocation.process

    def _record(outcome: ExecutionOutcome) -> None:
        record_invocation_returned(
            runtime.runtime_dir, identity, outcome=outcome, returncode=process.returncode
        )

    if process.returncode != 0:
        _record(ExecutionOutcome.FAILURE)
        raise ReviewerTurnError("reviewer process exited non-zero")
    if process.stdout_truncated:
        _record(ExecutionOutcome.FAILURE)
        raise ReviewerTurnError("reviewer structured output exceeded the configured output budget")

    try:
        report = ReviewerTurnReport.model_validate_json(process.stdout)
    except ValidationError:
        _record(ExecutionOutcome.FAILURE)
        raise ReviewerTurnError("reviewer returned invalid structured outcome") from None

    _record(
        ExecutionOutcome.SUCCESS
        if report.status is AgentTurnStatus.COMPLETED
        else ExecutionOutcome.BLOCKED
    )

    if report.status is AgentTurnStatus.COMPLETED:
        return ReviewerTurnResult(report=report, escalation_request=None, invocation=invocation)

    assert report.blocker is not None
    escalation_request = EscalationRequest(
        source_role=AgentRole.REVIEWER,
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=attempt,
        category=report.blocker.category,
        question=report.blocker.question,
        evidence=report.blocker.evidence,
        requested_authority=report.blocker.requested_authority,
    )

    return ReviewerTurnResult(
        report=report, escalation_request=escalation_request, invocation=invocation
    )


__all__ = [
    "ReviewerTurnError",
    "ReviewerTurnReport",
    "ReviewerTurnResult",
    "invoke_reviewer_turn",
]
