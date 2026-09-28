"""Planner decision protocol for Planner-routed escalations (Phase 9.2).

Extends the Phase-9.1 escalation protocol on the response side:

    EscalationRequest
            |
    route_escalation(...)
            |
    authority = PLANNER
            |
    PlannerDecision
            |
    resolve_planner_decision(...)
            |
    deterministic next disposition

Core invariant: a Planner response is not authority merely because it is
prose emitted by a Planner. It must be structurally valid
(:class:`PlannerDecision`), bound to the exact escalation request it
answers (:func:`escalation_request_digest`), and within the Planner's
allowed decision vocabulary for that request's category
(:func:`resolve_planner_decision`).

This module consumes the frozen Phase-9.1 category-to-authority routing
policy without redefining it; it does not modify ``lockstep.escalation``.
It is pure, provider-neutral, Git-neutral, filesystem-I/O-neutral,
runtime-neutral, Supervisor-neutral, and persistence-neutral. It defines
the response-side protocol; it does not execute it. No Planner
invocation, human prompting, retries, or resume semantics exist here.
"""

import hashlib
import json
from collections.abc import Mapping
from dataclasses import dataclass
from enum import StrEnum
from typing import Annotated

from pydantic import AfterValidator, BaseModel, ConfigDict, Field

from lockstep.escalation import (
    EscalationAuthority,
    EscalationCategory,
    EscalationProtocolError,
    EscalationRequest,
    route_escalation,
)

_DIGEST_LENGTH = 64
_HEX_DIGITS = frozenset("0123456789abcdef")

_MAX_RATIONALE_LENGTH = 4096
_MAX_INSTRUCTIONS = 16
_MAX_INSTRUCTION_LENGTH = 2048
_MAX_AUTHORIZED_PATHS = 64
_MAX_PATH_LENGTH = 512
_FORBIDDEN_PATH_GLOB_CHARS = frozenset("*?[")
_FORBIDDEN_PATH_ROOT_COMPONENTS = frozenset({".git", ".lockstep"})


class PlannerDecisionKind(StrEnum):
    """The Planner's structured answer to a Planner-routed escalation."""

    AUTHORIZE_BOUNDED_CHANGE = "authorize_bounded_change"
    AUTHORIZE_FROZEN_ARTIFACT_CORRECTION = "authorize_frozen_artifact_correction"
    REPLAN_SUBPHASE = "replan_subphase"
    HALT_FOR_HUMAN = "halt_for_human"
    TERMINAL_HALT = "terminal_halt"


class PlannerDecisionDisposition(StrEnum):
    """What a future Supervisor should conceptually do after validation."""

    RESUME_AGENT = "resume_agent"
    REPLAN_SUBPHASE = "replan_subphase"
    HUMAN_REQUIRED = "human_required"
    RUN_HALT = "run_halt"


_DISPOSITION_BY_KIND: Mapping[PlannerDecisionKind, PlannerDecisionDisposition] = {
    PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE: PlannerDecisionDisposition.RESUME_AGENT,
    PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION: (
        PlannerDecisionDisposition.RESUME_AGENT
    ),
    PlannerDecisionKind.REPLAN_SUBPHASE: PlannerDecisionDisposition.REPLAN_SUBPHASE,
    PlannerDecisionKind.HALT_FOR_HUMAN: PlannerDecisionDisposition.HUMAN_REQUIRED,
    PlannerDecisionKind.TERMINAL_HALT: PlannerDecisionDisposition.RUN_HALT,
}

_LEGAL_KINDS_BY_CATEGORY: Mapping[EscalationCategory, frozenset[PlannerDecisionKind]] = {
    EscalationCategory.PLANNER_DECISION_REQUIRED: frozenset(
        {
            PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
            PlannerDecisionKind.REPLAN_SUBPHASE,
            PlannerDecisionKind.HALT_FOR_HUMAN,
            PlannerDecisionKind.TERMINAL_HALT,
        }
    ),
    EscalationCategory.ARCHITECTURE_CONFLICT: frozenset(
        {
            PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
            PlannerDecisionKind.REPLAN_SUBPHASE,
            PlannerDecisionKind.HALT_FOR_HUMAN,
            PlannerDecisionKind.TERMINAL_HALT,
        }
    ),
    EscalationCategory.TEST_DEFECT: frozenset(
        {
            PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
            PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
            PlannerDecisionKind.REPLAN_SUBPHASE,
            PlannerDecisionKind.HALT_FOR_HUMAN,
            PlannerDecisionKind.TERMINAL_HALT,
        }
    ),
}

_NO_PATH_KINDS = frozenset(
    {
        PlannerDecisionKind.REPLAN_SUBPHASE,
        PlannerDecisionKind.HALT_FOR_HUMAN,
        PlannerDecisionKind.TERMINAL_HALT,
    }
)


def escalation_request_digest(request: EscalationRequest) -> str:
    """Return the deterministic lowercase-hex SHA-256 digest of *request*.

    Pure and deterministic: the digest covers every field of *request*
    via its canonical JSON representation (sorted keys, no whitespace),
    so it depends only on the request's content — never on dictionary
    insertion order, object identity, a clock, or randomness. This binds
    a :class:`PlannerDecision` to the exact request it answers, without
    introducing a random blocker identity.
    """

    payload = request.model_dump(mode="json")
    encoded = json.dumps(
        payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _reject_blank(value: str) -> str:
    if not value.strip():
        raise ValueError("must not be empty or whitespace-only")
    return value


def _validate_request_digest(value: str) -> str:
    if len(value) != _DIGEST_LENGTH:
        raise ValueError(f"must be exactly {_DIGEST_LENGTH} characters")
    if any(char not in _HEX_DIGITS for char in value):
        raise ValueError("must be lowercase hexadecimal")
    return value


def _validate_rationale_length(value: str) -> str:
    if len(value) > _MAX_RATIONALE_LENGTH:
        raise ValueError(f"must be at most {_MAX_RATIONALE_LENGTH} characters")
    return value


def _validate_instruction_length(value: str) -> str:
    if len(value) > _MAX_INSTRUCTION_LENGTH:
        raise ValueError(f"must be at most {_MAX_INSTRUCTION_LENGTH} characters")
    return value


def _validate_authorized_path(value: str) -> str:
    if not value.strip():
        raise ValueError("must not be empty or whitespace-only")
    if len(value) > _MAX_PATH_LENGTH:
        raise ValueError(f"must be at most {_MAX_PATH_LENGTH} characters")
    if "\x00" in value:
        raise ValueError("must not contain NUL")
    if "\\" in value:
        raise ValueError("must not contain a backslash")
    if any(char in _FORBIDDEN_PATH_GLOB_CHARS for char in value):
        raise ValueError("must not contain glob metacharacters")
    if value.startswith("/"):
        raise ValueError("must not be absolute")
    if value == ".":
        raise ValueError("must not be '.'")

    components = value.split("/")
    if any(component == "" for component in components):
        raise ValueError("must not contain an empty path component")
    if any(component == "." for component in components):
        raise ValueError("must not contain a '.' component")
    if any(component == ".." for component in components):
        raise ValueError("must not contain a '..' component")
    if components[0] in _FORBIDDEN_PATH_ROOT_COMPONENTS:
        raise ValueError("must not be under .git/ or .lockstep/")

    return value


def _reject_duplicate_authorized_paths(paths: tuple[str, ...]) -> tuple[str, ...]:
    seen: set[str] = set()
    for path in paths:
        if path in seen:
            raise ValueError("must not contain duplicate authorized paths")
        seen.add(path)
    return paths


_RequestDigest = Annotated[str, AfterValidator(_validate_request_digest)]
_Rationale = Annotated[
    str, AfterValidator(_reject_blank), AfterValidator(_validate_rationale_length)
]
_Instruction = Annotated[
    str, AfterValidator(_reject_blank), AfterValidator(_validate_instruction_length)
]
_AuthorizedPath = Annotated[str, AfterValidator(_validate_authorized_path)]


class PlannerDecision(BaseModel):
    """A bounded, structured Planner response to a Planner-routed escalation.

    Immutable and strict: unknown fields are rejected. ``request_digest``
    binds this decision to the exact :class:`~lockstep.escalation.EscalationRequest`
    it answers (see :func:`escalation_request_digest`) rather than to
    ``phase_id``/``subphase_id``/``attempt`` alone, since multiple distinct
    blockers may occur within the same attempt. ``rationale`` is a bounded
    decision explanation for durable control-plane evidence, not a
    chain-of-thought field. ``authorized_paths`` is an exact,
    order-preserving, repo-relative file-authorization surface — not glob
    semantics, and not a grant of Git/commit/network/persistence
    capability beyond naming the files themselves.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    request_digest: _RequestDigest
    kind: PlannerDecisionKind
    rationale: _Rationale
    instructions: Annotated[tuple[_Instruction, ...], Field(min_length=1, max_length=16)]
    authorized_paths: Annotated[
        tuple[_AuthorizedPath, ...],
        Field(max_length=64),
        AfterValidator(_reject_duplicate_authorized_paths),
    ] = ()


@dataclass(frozen=True, slots=True)
class PlannerDecisionResolution:
    """The deterministic outcome of validating one :class:`PlannerDecision`.

    ``decision`` is the exact supplied object, retained by identity.
    ``frozen_artifact_correction`` is true only for
    :attr:`PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION` — the
    only structural signal that grants frozen-artifact-correction
    authority. It is never inferred from prose.
    """

    decision: PlannerDecision
    disposition: PlannerDecisionDisposition
    frozen_artifact_correction: bool


def resolve_planner_decision(
    request: EscalationRequest,
    decision: PlannerDecision,
) -> PlannerDecisionResolution:
    """Validate *decision* against *request* and derive its disposition.

    Pure: no I/O, no mutation, no transport, no provider, no Supervisor,
    no persistence. Validates in a fixed order — (1) the request's
    authoritative Phase-9.1 route must be Planner, (2) the decision must
    be bound to the exact request via its digest, (3) the decision kind
    must be legal for the request's category, (4) the decision kind's
    ``authorized_paths`` constraints must hold — raising
    :class:`~lockstep.escalation.EscalationProtocolError` with a bounded,
    content-free message on the first violation. A caller's
    ``requested_authority`` can never manufacture Planner authority: only
    ``route_escalation(request).authority`` decides. Only structured
    fields (``kind``, ``authorized_paths``) determine the outcome; prose
    in ``rationale``/``instructions`` is never interpreted.
    """

    route = route_escalation(request)
    if route.authority != EscalationAuthority.PLANNER:
        raise EscalationProtocolError("escalation request does not route to Planner")

    if decision.request_digest != escalation_request_digest(request):
        raise EscalationProtocolError("planner decision digest does not match escalation request")

    legal_kinds = _LEGAL_KINDS_BY_CATEGORY[request.category]
    if decision.kind not in legal_kinds:
        raise EscalationProtocolError(
            "planner decision kind is not legal for the escalation category"
        )

    if decision.kind == PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION:
        if len(decision.authorized_paths) < 1:
            raise EscalationProtocolError(
                "frozen artifact correction requires at least one authorized path"
            )
    elif decision.kind in _NO_PATH_KINDS and len(decision.authorized_paths) != 0:
        raise EscalationProtocolError("this planner decision kind must not authorize any paths")

    return PlannerDecisionResolution(
        decision=decision,
        disposition=_DISPOSITION_BY_KIND[decision.kind],
        frozen_artifact_correction=(
            decision.kind == PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION
        ),
    )


__all__ = [
    "PlannerDecision",
    "PlannerDecisionDisposition",
    "PlannerDecisionKind",
    "PlannerDecisionResolution",
    "escalation_request_digest",
    "resolve_planner_decision",
]
