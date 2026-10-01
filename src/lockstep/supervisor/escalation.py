"""Supervisor-layer escalation dispatch (Phase 9.5).

Consumes an already-produced, structured
:class:`~lockstep.escalation.EscalationRequest` and determines what
happens next at the authority-routing level:

    EscalationRequest
        -> route_escalation                         (frozen 9.1 policy)
        -> SUPERVISOR -> SUPERVISOR_ACTION_REQUIRED  (0 inference)
        -> HUMAN      -> HUMAN_REQUIRED              (0 inference)
        -> PLANNER    -> invoke_planner_decision     (frozen 9.3 transport)
                      -> mapped SupervisorEscalationDisposition

Core invariant: a structured Implementer/Reviewer blocker can reach the
Planner automatically without being relayed through the human. This
module does not produce an ``EscalationRequest`` (that is
:mod:`lockstep.agent_turn`'s job), does not re-enter the blocked agent,
does not execute a Planner-granted REPLAN/RESUME/RUN_HALT disposition,
and does not prompt a human. It performs no Git, persistence, or FSM
mutation. Exactly one Planner inference occurs per dispatch, at most,
and only on the Planner-routed branch; no retry exists here.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from enum import StrEnum

from lockstep.domain import RunId
from lockstep.escalation import (
    EscalationAuthority,
    EscalationRequest,
    EscalationRoute,
    route_escalation,
)
from lockstep.escalation_decision import PlannerDecisionDisposition
from lockstep.escalation_transport import PlannerDecisionTurnResult, invoke_planner_decision
from lockstep.runtime import AgentRuntime


class SupervisorEscalationDisposition(StrEnum):
    """What the Supervisor should do next with a dispatched escalation."""

    SUPERVISOR_ACTION_REQUIRED = "supervisor_action_required"
    RESUME_AGENT = "resume_agent"
    REPLAN_SUBPHASE = "replan_subphase"
    HUMAN_REQUIRED = "human_required"
    RUN_HALT = "run_halt"


_DISPOSITION_BY_PLANNER_DISPOSITION: Mapping[
    PlannerDecisionDisposition, SupervisorEscalationDisposition
] = {
    PlannerDecisionDisposition.RESUME_AGENT: SupervisorEscalationDisposition.RESUME_AGENT,
    PlannerDecisionDisposition.REPLAN_SUBPHASE: SupervisorEscalationDisposition.REPLAN_SUBPHASE,
    PlannerDecisionDisposition.HUMAN_REQUIRED: SupervisorEscalationDisposition.HUMAN_REQUIRED,
    PlannerDecisionDisposition.RUN_HALT: SupervisorEscalationDisposition.RUN_HALT,
}


@dataclass(frozen=True, slots=True)
class SupervisorEscalationResult:
    """The result of dispatching one :class:`~lockstep.escalation.EscalationRequest`.

    ``request`` is the exact object supplied to :func:`dispatch_escalation`.
    ``route`` is the exact :class:`~lockstep.escalation.EscalationRoute`
    returned by :func:`~lockstep.escalation.route_escalation`. ``planner_turn``
    is the exact :class:`~lockstep.escalation_transport.PlannerDecisionTurnResult`
    returned by :func:`~lockstep.escalation_transport.invoke_planner_decision`
    on the Planner branch, and ``None`` on every other branch; it is
    excluded from :func:`repr` so logging a result never dumps raw
    Planner prompt/provider output.
    """

    request: EscalationRequest
    route: EscalationRoute
    disposition: SupervisorEscalationDisposition
    planner_turn: PlannerDecisionTurnResult | None = field(default=None, repr=False)


def dispatch_escalation(
    runtime: AgentRuntime,
    *,
    request: EscalationRequest,
    timeout_seconds: float,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
    run_id: RunId | None = None,
) -> SupervisorEscalationResult:
    """Route *request* and resolve its authority-level disposition.

    Always calls :func:`~lockstep.escalation.route_escalation` first;
    ``route_escalation`` is the sole category-to-authority authority, so
    this function never reproduces a category mapping of its own and
    branches only on the resulting
    :class:`~lockstep.escalation.EscalationAuthority`. A Supervisor-routed
    request returns :attr:`SupervisorEscalationDisposition.SUPERVISOR_ACTION_REQUIRED`
    with zero Planner inference and zero human interaction: the specific
    deterministic Supervisor remedy is a later bounded policy, not
    invented here. A Human-routed request returns
    :attr:`SupervisorEscalationDisposition.HUMAN_REQUIRED` without
    invoking the Planner or contacting a human. A Planner-routed request
    calls :func:`~lockstep.escalation_transport.invoke_planner_decision`
    exactly once and maps the validated
    ``planner_turn.resolution.disposition`` — the sole Planner outcome
    authority — onto the matching :class:`SupervisorEscalationDisposition`;
    Planner transport/protocol failures propagate unwrapped, with no
    retry. A supplied *run_id* is forwarded unchanged so the Planner
    invocation is attributable; it confers no authority.
    ``request.requested_authority`` never overrides the
    deterministic route in any branch.
    """
    route = route_escalation(request)

    if route.authority == EscalationAuthority.SUPERVISOR:
        return SupervisorEscalationResult(
            request=request,
            route=route,
            disposition=SupervisorEscalationDisposition.SUPERVISOR_ACTION_REQUIRED,
        )

    if route.authority == EscalationAuthority.HUMAN:
        return SupervisorEscalationResult(
            request=request,
            route=route,
            disposition=SupervisorEscalationDisposition.HUMAN_REQUIRED,
        )

    planner_turn = invoke_planner_decision(
        runtime,
        request=request,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=termination_grace_seconds,
        run_id=run_id,
    )

    return SupervisorEscalationResult(
        request=request,
        route=route,
        disposition=_DISPOSITION_BY_PLANNER_DISPOSITION[planner_turn.resolution.disposition],
        planner_turn=planner_turn,
    )


__all__ = [
    "SupervisorEscalationDisposition",
    "SupervisorEscalationResult",
    "dispatch_escalation",
]
