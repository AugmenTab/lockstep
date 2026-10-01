"""Deterministic failure/rework attribution (Phase 10.4).

Pure projections from existing control-plane vocabulary onto
:class:`~lockstep.domain.FailureCause` (why an attempt failed or work
repeated) and, where an existing :class:`~lockstep.domain.StopReason` says
exactly the same thing, onto that (why automation stopped).

Core invariant: classification describes history, existing protocol controls
progression. Nothing here routes, retries, resumes, approves, widens scope, or
commits; the callers record the result on an observational execution event
*after* the owning control path has already decided. No I/O, no clock, no
provider access, no prose parsing, no model judgment.
"""

from collections.abc import Mapping

from lockstep.domain import (
    FailureCause,
    InvocationUsage,
    ProcessTermination,
    QuotaStatus,
    ReviewVerdict,
    StopReason,
)
from lockstep.escalation import EscalationCategory

# ``None`` means the category carries no deterministic cause: the agent said it
# is blocked, which does not establish *why* in a way this taxonomy may assert.
_CAUSE_BY_ESCALATION: Mapping[EscalationCategory, FailureCause | None] = {
    EscalationCategory.CONTROL_PLANE_BLOCKER: None,
    EscalationCategory.PLANNER_DECISION_REQUIRED: None,
    EscalationCategory.TEST_DEFECT: FailureCause.TEST_DEFECT,
    EscalationCategory.ARCHITECTURE_CONFLICT: FailureCause.ARCHITECTURE_CONFLICT,
    EscalationCategory.REQUIREMENT_AMBIGUITY: FailureCause.REQUIREMENT_AMBIGUITY,
    EscalationCategory.EXTERNAL_SIDE_EFFECT_REQUIRED: FailureCause.HUMAN_REQUIRED_DECISION,
    EscalationCategory.HUMAN_AUTHORITY_REQUIRED: FailureCause.HUMAN_REQUIRED_DECISION,
}

# Only exact matches. ``TEST_DEFECT`` is not ``TEST_DEFECT_REQUIRING_REQUIREMENT_CHANGE``
# (the requirement stays valid) and ``ARCHITECTURE_CONFLICT`` is not
# ``ARCHITECTURAL_AMBIGUITY``, so neither is projected.
_STOP_REASON_BY_ESCALATION: Mapping[EscalationCategory, StopReason | None] = {
    EscalationCategory.CONTROL_PLANE_BLOCKER: None,
    EscalationCategory.PLANNER_DECISION_REQUIRED: None,
    EscalationCategory.TEST_DEFECT: None,
    EscalationCategory.ARCHITECTURE_CONFLICT: None,
    EscalationCategory.REQUIREMENT_AMBIGUITY: StopReason.REQUIREMENT_AMBIGUITY,
    EscalationCategory.EXTERNAL_SIDE_EFFECT_REQUIRED: StopReason.EXTERNAL_SIDE_EFFECT_REQUIRED,
    EscalationCategory.HUMAN_AUTHORITY_REQUIRED: StopReason.NEEDS_USER,
}


def cause_for_escalation(category: EscalationCategory) -> FailureCause | None:
    """Project an escalation category onto the cause it establishes, if any."""
    return _CAUSE_BY_ESCALATION[category]


def stop_reason_for_escalation(category: EscalationCategory) -> StopReason | None:
    """Project an escalation category onto an exactly-equivalent stop reason, if any."""
    return _STOP_REASON_BY_ESCALATION[category]


def cause_for_review_verdict(verdict: ReviewVerdict) -> FailureCause | None:
    """A Reviewer ``REWORK`` means the implementation did not satisfy the Contract."""
    return FailureCause.IMPLEMENTATION_DEFECT if verdict is ReviewVerdict.REWORK else None


def cause_for_invocation_failure(
    usage: InvocationUsage | None, *, launch_failed: bool = False
) -> FailureCause | None:
    """Attribute a *failed* agent invocation from host-observed process evidence only.

    ``launch_failed`` (no process ever existed) is an environment failure.
    Usage exhaustion requires the authoritative ``QuotaStatus.EXHAUSTED``;
    ``UNKNOWN`` quota, slowness, or any generic error stay a provider/process
    failure. Returns ``None`` for a clean exit.
    """
    if launch_failed:
        return FailureCause.ENVIRONMENT_FAILURE
    if usage is None:
        return FailureCause.PROVIDER_PROCESS_FAILURE
    if usage.termination is ProcessTermination.EXITED and usage.exit_code == 0:
        return None
    if usage.quota_status is QuotaStatus.EXHAUSTED:
        return FailureCause.USAGE_EXHAUSTION
    return FailureCause.PROVIDER_PROCESS_FAILURE


__all__ = [
    "cause_for_escalation",
    "cause_for_invocation_failure",
    "cause_for_review_verdict",
    "stop_reason_for_escalation",
]
