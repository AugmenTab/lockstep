"""Structured Implementer turn: a completion report, or a blocker (Phase 11.4).

The generic :class:`~lockstep.agent_turn.AgentTurnReport` (status + blocker)
stays exactly as it was for every other caller. A canonical Implementer instead
returns an :class:`ImplementerTurnReport`::

    Implementer turn
        -> exactly one structured inference
        -> ImplementerTurnReport
               COMPLETED -> ImplementationReportDraft (no blocker)
               BLOCKED   -> AgentBlockerDraft (no report)
        -> host injects source_role/phase_id/subphase_id/attempt for a
           BLOCKED report only
        -> ImplementerTurnResult

A ``COMPLETED`` turn without a report is rejected: there is no ambiguous
"completed with nothing to review" outcome. The draft is deliberately free of
host-owned identity (Phase, Sub-phase, attempt); the host builds the canonical
:class:`~lockstep.domain.ImplementationReport` from the draft plus the identity
it already owns, so a model cannot manufacture workflow identity. The report is
evidence: nothing in it amends a Contract, scope, test or retry budget.

This module mirrors :mod:`lockstep.reviewer_turn`. It performs no routing, no
Planner invocation, no human prompting and no workflow-state mutation, and has
no retry, repair turn or fallback provider.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Annotated

from pydantic import AfterValidator, BaseModel, ConfigDict, ValidationError, model_validator

from lockstep.agent_turn import (
    _BLOCKER_PROTOCOL_SUFFIX,
    AgentBlockerDraft,
    AgentTurnError,
    AgentTurnRuntimeContext,
    AgentTurnStatus,
)
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
    FailureCause,
    InvocationIdentity,
    InvocationStage,
    PhaseId,
    RunId,
    SubphaseId,
)
from lockstep.escalation import EscalationRequest

_SCHEMA_NAME = "implementer-turn-report"

_IMPLEMENTER_TURN_PROTOCOL_SUFFIX = (
    "\n---\n"
    "Structured implementation-report protocol:\n\n"
    "When COMPLETED:\n"
    "    return implementation_report: a summary of what you implemented, plus\n"
    "    optional changed_files, decisions, deviations and concerns\n"
    "    blocker must be null\n\n"
    "When BLOCKED:\n"
    "    implementation_report must be null\n\n"
    "The report is evidence for the Reviewer. It does not change the Contract, the\n"
    "allowed paths, the frozen tests or your scope: do not edit anything outside the\n"
    "authorized paths because the report mentions a need to.\n"
)


class ImplementerTurnError(AgentTurnError):
    """A structured Implementer turn could not be completed or transported.

    An :class:`~lockstep.agent_turn.AgentTurnError`, so every existing handler of
    an Implementer transport failure keeps working. Carries only a short,
    bounded, deterministic ``reason``.
    """


def _reject_blank(value: str) -> str:
    if not value.strip():
        raise ValueError("must not be empty or whitespace-only")
    return value


_NonBlankStr = Annotated[str, AfterValidator(_reject_blank)]


class ImplementationReportDraft(BaseModel):
    """What the Implementer reports about its own turn, before host identity is added.

    Immutable and strict. Carries no ``phase_id``/``subphase_id``/``attempt``: the
    host supplies those when it builds the canonical
    :class:`~lockstep.domain.ImplementationReport`.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    summary: _NonBlankStr
    changed_files: tuple[_NonBlankStr, ...] = ()
    decisions: tuple[_NonBlankStr, ...] = ()
    deviations: tuple[_NonBlankStr, ...] = ()
    concerns: tuple[_NonBlankStr, ...] = ()


class ImplementerTurnReport(BaseModel):
    """The strict structured final report of one Implementer turn.

    A ``COMPLETED`` report must carry an :class:`ImplementationReportDraft` and no
    blocker; a ``BLOCKED`` report must carry a blocker and no report.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    status: AgentTurnStatus
    implementation_report: ImplementationReportDraft | None = None
    blocker: AgentBlockerDraft | None

    @model_validator(mode="after")
    def _check_status_payload_relationship(self) -> ImplementerTurnReport:
        if self.status is AgentTurnStatus.COMPLETED:
            if self.implementation_report is None:
                raise ValueError("a COMPLETED implementer turn report must include a report")
            if self.blocker is not None:
                raise ValueError("a COMPLETED implementer turn report must not include a blocker")
        else:
            if self.implementation_report is not None:
                raise ValueError("a BLOCKED implementer turn report must not include a report")
            if self.blocker is None:
                raise ValueError("a BLOCKED implementer turn report must include a blocker")
        return self


@dataclass(frozen=True, slots=True)
class ImplementerTurnResult:
    """The result of one structured Implementer turn.

    ``invocation`` is excluded from :func:`repr` so logging a result never dumps raw
    process output. ``escalation_request`` is ``None`` for a ``COMPLETED`` report and
    a real, unmodified :class:`~lockstep.escalation.EscalationRequest` for a
    ``BLOCKED`` report.
    """

    report: ImplementerTurnReport
    escalation_request: EscalationRequest | None
    invocation: AgentInvocationResult = field(repr=False)


def invoke_implementer_turn(
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
) -> ImplementerTurnResult:
    """Invoke exactly one structured Implementer turn and resolve its report.

    Derives everything provider-specific from *runtime*:
    ``runtime.adapters.implementer`` and
    ``runtime.config.routing.implementer.billing_mode``. *cwd* is caller-owned.
    Appends the fixed blocker protocol and the fixed implementation-report protocol
    to *prompt*, performs exactly one structured inference through
    :func:`~lockstep.agents.role_output.prepare_structured_role_adapter` wrapping the
    Implementer's own frozen authority, strictly hydrates the
    :class:`ImplementerTurnReport`, and -- only for a ``BLOCKED`` report -- builds a
    real :class:`~lockstep.escalation.EscalationRequest` from the host-supplied
    identity and the report's blocker fields. When *run_id* is given the host issues
    the turn's :class:`~lockstep.domain.InvocationIdentity`.
    """
    if not isinstance(prompt, str):
        raise ImplementerTurnError("prompt must be a string")
    if not prompt.strip():
        raise ImplementerTurnError("prompt must not be blank")
    if "\x00" in prompt:
        raise ImplementerTurnError("prompt must not contain NUL")

    structured_adapter = prepare_structured_role_adapter(
        runtime.adapters.implementer,
        role=AgentRole.IMPLEMENTER,
        runtime_dir=runtime.runtime_dir,
        schema=ImplementerTurnReport.model_json_schema(),
        schema_name=_SCHEMA_NAME,
    )

    identity = (
        None
        if run_id is None
        else InvocationIdentity.issue(
            run_id=run_id,
            phase_id=phase_id,
            subphase_id=subphase_id,
            attempt=attempt,
            role=AgentRole.IMPLEMENTER,
            stage=InvocationStage.IMPLEMENTATION,
        )
    )

    invocation_request = AgentInvocationRequest(
        role=AgentRole.IMPLEMENTER,
        billing_mode=runtime.config.routing.implementer.billing_mode,
        prompt=prompt + _BLOCKER_PROTOCOL_SUFFIX + _IMPLEMENTER_TURN_PROTOCOL_SUFFIX,
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

    def _record(outcome: ExecutionOutcome, cause: FailureCause | None = None) -> None:
        record_invocation_returned(
            runtime.runtime_dir,
            identity,
            outcome=outcome,
            returncode=process.returncode,
            usage=invocation.usage,
            cause=cause,
        )

    if process.returncode != 0:
        _record(ExecutionOutcome.FAILURE)
        raise ImplementerTurnError("agent process exited non-zero")
    if process.stdout_truncated:
        _record(ExecutionOutcome.FAILURE, FailureCause.MALFORMED_OUTPUT)
        raise ImplementerTurnError("agent structured output exceeded the configured output budget")

    try:
        report = ImplementerTurnReport.model_validate_json(process.stdout)
    except ValidationError:
        _record(ExecutionOutcome.FAILURE, FailureCause.MALFORMED_OUTPUT)
        raise ImplementerTurnError("agent returned invalid structured outcome") from None

    _record(
        ExecutionOutcome.SUCCESS
        if report.status is AgentTurnStatus.COMPLETED
        else ExecutionOutcome.BLOCKED
    )

    if report.status is AgentTurnStatus.COMPLETED:
        return ImplementerTurnResult(report=report, escalation_request=None, invocation=invocation)

    assert report.blocker is not None
    escalation_request = EscalationRequest(
        source_role=AgentRole.IMPLEMENTER,
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=attempt,
        category=report.blocker.category,
        question=report.blocker.question,
        evidence=report.blocker.evidence,
        requested_authority=report.blocker.requested_authority,
    )
    return ImplementerTurnResult(
        report=report, escalation_request=escalation_request, invocation=invocation
    )


__all__ = [
    "ImplementationReportDraft",
    "ImplementerTurnError",
    "ImplementerTurnReport",
    "ImplementerTurnResult",
    "invoke_implementer_turn",
]
