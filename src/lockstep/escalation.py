"""Structured blockers and deterministic authority routing (Phase 9.1).

Provides a provider-neutral, deterministic representation of the
control-plane protocol an agent uses to surface a blocker or question:

    agent encounters blocker/question
            |
    structured escalation artifact (:class:`EscalationRequest`)
            |
    deterministic authority routing (:func:`route_escalation`)

Core invariant: an agent stopping does not imply the run stops, and a
run stopping does not imply the human must be asked. ``route_escalation``
derives authoritative routing from ``category`` alone; a request's
``requested_authority`` is retained as caller evidence, but it never
overrides the deterministic policy below.

This module is pure, provider-neutral, Git-neutral, filesystem-neutral,
Supervisor-neutral, and persistence-neutral. It defines the escalation
protocol; it does not execute it. No retries, resume, automatic Planner
re-entry, or human prompting are implemented here.
"""

from collections.abc import Mapping
from dataclasses import dataclass
from enum import StrEnum
from typing import Annotated

from pydantic import AfterValidator, BaseModel, ConfigDict, Field

from lockstep.domain import AgentRole, AttemptNumber, PhaseId, SubphaseId

_MAX_QUESTION_LENGTH = 4096
_MAX_EVIDENCE_ENTRIES = 32
_MAX_EVIDENCE_ENTRY_LENGTH = 2048


class EscalationCategory(StrEnum):
    """Why an agent halted, in provider-neutral, deterministic terms."""

    CONTROL_PLANE_BLOCKER = "control_plane_blocker"
    PLANNER_DECISION_REQUIRED = "planner_decision_required"
    TEST_DEFECT = "test_defect"
    ARCHITECTURE_CONFLICT = "architecture_conflict"
    REQUIREMENT_AMBIGUITY = "requirement_ambiguity"
    EXTERNAL_SIDE_EFFECT_REQUIRED = "external_side_effect_required"
    HUMAN_AUTHORITY_REQUIRED = "human_authority_required"


class EscalationAuthority(StrEnum):
    """Who has authority to answer a blocker (not who has already answered it)."""

    SUPERVISOR = "supervisor"
    PLANNER = "planner"
    HUMAN = "human"


class HaltLevel(StrEnum):
    """How far a blocker's stoppage propagates.

    ``AGENT``: the current agent turn cannot proceed; the Supervisor may
    route/escalate and later continue the run.

    ``RUN``: autonomous execution cannot proceed until a higher-authority
    decision or remediation occurs. No Phase-9.1 category maps here; it
    is reserved for later Phase-9 policies (retry budget exhaustion,
    Planner-initiated project halt, unrecoverable invariant failure,
    invalid resume state).

    ``HUMAN_REQUIRED``: only the human has authority to resolve the
    blocker.
    """

    AGENT = "agent"
    RUN = "run"
    HUMAN_REQUIRED = "human_required"


def _reject_blank(value: str) -> str:
    if not value.strip():
        raise ValueError("must not be empty or whitespace-only")
    return value


def _reject_overlong_question(value: str) -> str:
    if len(value) > _MAX_QUESTION_LENGTH:
        raise ValueError(f"must be at most {_MAX_QUESTION_LENGTH} characters")
    return value


def _reject_overlong_evidence_entry(value: str) -> str:
    if len(value) > _MAX_EVIDENCE_ENTRY_LENGTH:
        raise ValueError(f"must be at most {_MAX_EVIDENCE_ENTRY_LENGTH} characters")
    return value


_Question = Annotated[str, AfterValidator(_reject_blank), AfterValidator(_reject_overlong_question)]
_EvidenceEntry = Annotated[
    str, AfterValidator(_reject_blank), AfterValidator(_reject_overlong_evidence_entry)
]


class EscalationRequest(BaseModel):
    """A bounded, structured record of one agent's blocker or question.

    Immutable and strict: unknown fields are rejected, and every field
    must validate before construction succeeds. ``evidence`` holds
    bounded facts, not free-form transcripts — callers are responsible
    for evidence quality; this model enforces only size and boundedness.
    ``requested_authority`` is retained as the originating agent's own
    belief about who should answer; it is evidence only. Final routing
    authority belongs to :func:`route_escalation`, which derives it from
    ``category`` alone.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    source_role: AgentRole
    phase_id: PhaseId
    subphase_id: SubphaseId
    attempt: AttemptNumber
    category: EscalationCategory
    question: _Question
    evidence: Annotated[tuple[_EvidenceEntry, ...], Field(min_length=1, max_length=32)]
    requested_authority: EscalationAuthority


@dataclass(frozen=True, slots=True)
class EscalationRoute:
    """The deterministic routing outcome for one :class:`EscalationRequest`.

    Contains only the routing decision: who has authority to resolve
    the blocker, how far the halt propagates, and whether the caller's
    requested authority disagreed with the deterministic policy. It
    never embeds the originating request or prose explanations.
    """

    authority: EscalationAuthority
    halt_level: HaltLevel
    authority_mismatch: bool


class EscalationProtocolError(Exception):
    """Reserved for future escalation-protocol invariant violations.

    ``route_escalation`` cannot fail for a valid :class:`EscalationRequest`:
    the category-to-authority and category-to-halt-level mappings below
    are total over every :class:`EscalationCategory` member, and all
    other validation belongs to ``EscalationRequest`` itself. This type
    exists so later Phase-9 sub-phases have a stable, provider-neutral
    protocol error to raise without expanding this module's public
    surface.
    """


_AUTHORITY_BY_CATEGORY: Mapping[EscalationCategory, EscalationAuthority] = {
    EscalationCategory.CONTROL_PLANE_BLOCKER: EscalationAuthority.SUPERVISOR,
    EscalationCategory.PLANNER_DECISION_REQUIRED: EscalationAuthority.PLANNER,
    EscalationCategory.TEST_DEFECT: EscalationAuthority.PLANNER,
    EscalationCategory.ARCHITECTURE_CONFLICT: EscalationAuthority.PLANNER,
    EscalationCategory.REQUIREMENT_AMBIGUITY: EscalationAuthority.HUMAN,
    EscalationCategory.EXTERNAL_SIDE_EFFECT_REQUIRED: EscalationAuthority.HUMAN,
    EscalationCategory.HUMAN_AUTHORITY_REQUIRED: EscalationAuthority.HUMAN,
}

_HALT_LEVEL_BY_CATEGORY: Mapping[EscalationCategory, HaltLevel] = {
    EscalationCategory.CONTROL_PLANE_BLOCKER: HaltLevel.AGENT,
    EscalationCategory.PLANNER_DECISION_REQUIRED: HaltLevel.AGENT,
    EscalationCategory.TEST_DEFECT: HaltLevel.AGENT,
    EscalationCategory.ARCHITECTURE_CONFLICT: HaltLevel.AGENT,
    EscalationCategory.REQUIREMENT_AMBIGUITY: HaltLevel.HUMAN_REQUIRED,
    EscalationCategory.EXTERNAL_SIDE_EFFECT_REQUIRED: HaltLevel.HUMAN_REQUIRED,
    EscalationCategory.HUMAN_AUTHORITY_REQUIRED: HaltLevel.HUMAN_REQUIRED,
}


def route_escalation(request: EscalationRequest) -> EscalationRoute:
    """Derive the deterministic route for *request* from its category alone.

    Pure and deterministic: no I/O, no environment, no clock, no
    randomness, no provider access, no persistence. Routing depends
    only on ``request.category`` — never on ``source_role``, provider,
    model, ``attempt``, ``phase_id``, or ``subphase_id``. A mismatch
    between ``request.requested_authority`` and the deterministic
    authority is recorded, never silently rewritten or rejected.
    """

    authority = _AUTHORITY_BY_CATEGORY[request.category]
    halt_level = _HALT_LEVEL_BY_CATEGORY[request.category]
    return EscalationRoute(
        authority=authority,
        halt_level=halt_level,
        authority_mismatch=request.requested_authority != authority,
    )


__all__ = [
    "EscalationAuthority",
    "EscalationCategory",
    "EscalationProtocolError",
    "EscalationRequest",
    "EscalationRoute",
    "HaltLevel",
    "route_escalation",
]
