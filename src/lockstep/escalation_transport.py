"""Structured Planner decision transport (Phase 9.3).

Gives Lockstep one production path from a Planner-routed
:class:`~lockstep.escalation.EscalationRequest` to a validated
:class:`~lockstep.escalation_decision.PlannerDecision`:

    EscalationRequest
        -> route_escalation(...)                     (frozen 9.1 policy)
        -> must route to PLANNER
        -> frozen MasterPlan / current PhasePlan / active SubphaseContract
        -> deterministic bounded Planner prompt
        -> exactly one read-only structured Planner inference
        -> structured decision draft (no request identity)
        -> Lockstep injects the exact request digest
        -> PlannerDecision
        -> resolve_planner_decision(...)              (frozen 9.2 policy)
        -> PlannerDecisionTurnResult

Core invariant: the Planner may choose among its structured authorities,
but it cannot manufacture request identity, mutate repository or planning
state, or bypass 9.1/9.2 protocol validation. This module is a read-only,
provider-neutral orchestration seam built strictly on top of
:mod:`lockstep.escalation`, :mod:`lockstep.escalation_decision`,
:mod:`lockstep.planning_store`, :mod:`lockstep.runtime`, and the frozen
Phase-8 structured-output layer (:mod:`lockstep.agents.structured_output`).
It performs no Git mutation, no planning-artifact freeze/publish, no
Supervisor/workflow-state mutation, and no execution of a resolved
decision — it only transports and validates exactly one structured
Planner decision per call. No retry, no repair turn, and no fallback
provider exist here.
"""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Annotated

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, ValidationError

from lockstep.agents import (
    AgentInvocationRequest,
    AgentInvocationResult,
    invoke_agent,
    prepare_structured_planner_adapter,
    record_invocation_returned,
)
from lockstep.domain import (
    AgentRole,
    ExecutionOutcome,
    InvocationIdentity,
    InvocationStage,
    PhasePlan,
    RunId,
    SubphaseContract,
    SubphaseOutline,
)
from lockstep.escalation import (
    EscalationAuthority,
    EscalationCategory,
    EscalationRequest,
    route_escalation,
)
from lockstep.escalation_decision import (
    PlannerDecision,
    PlannerDecisionKind,
    PlannerDecisionResolution,
    escalation_request_digest,
    resolve_planner_decision,
)
from lockstep.planning_store import (
    load_active_subphase_contract,
    load_frozen_master_plan,
    load_phase_plan,
)
from lockstep.runtime import AgentRuntime

_SCHEMA_NAME = "planner-decision"

_MAX_RATIONALE_LENGTH = 4096
_MAX_INSTRUCTIONS = 16
_MAX_INSTRUCTION_LENGTH = 2048
_MAX_AUTHORIZED_PATHS = 64
_MAX_PATH_LENGTH = 512
_FORBIDDEN_PATH_GLOB_CHARS = frozenset("*?[")
_FORBIDDEN_PATH_ROOT_COMPONENTS = frozenset({".git", ".lockstep"})

_STANDARD_PLANNER_KINDS: tuple[PlannerDecisionKind, ...] = (
    PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
    PlannerDecisionKind.REPLAN_SUBPHASE,
    PlannerDecisionKind.HALT_FOR_HUMAN,
    PlannerDecisionKind.TERMINAL_HALT,
)
_TEST_DEFECT_KINDS: tuple[PlannerDecisionKind, ...] = (
    PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
    PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
    PlannerDecisionKind.REPLAN_SUBPHASE,
    PlannerDecisionKind.HALT_FOR_HUMAN,
    PlannerDecisionKind.TERMINAL_HALT,
)
_LEGAL_KINDS_FOR_PROMPT: Mapping[EscalationCategory, tuple[PlannerDecisionKind, ...]] = {
    EscalationCategory.PLANNER_DECISION_REQUIRED: _STANDARD_PLANNER_KINDS,
    EscalationCategory.ARCHITECTURE_CONFLICT: _STANDARD_PLANNER_KINDS,
    EscalationCategory.TEST_DEFECT: _TEST_DEFECT_KINDS,
}

_FROZEN_CORRECTION_INSTRUCTION = (
    "Use AUTHORIZE_FROZEN_ARTIFACT_CORRECTION only if you are explicitly "
    "authorizing mutation of a named frozen artifact. If correction is "
    "authorized, list every exact authorized repository-relative file in "
    "authorized_paths. Do not use ordinary AUTHORIZE_BOUNDED_CHANGE as "
    "implicit frozen-artifact authority."
)
_HALT_SEMANTICS_INSTRUCTION = (
    "HALT_FOR_HUMAN means a true human-authority decision is required. "
    "TERMINAL_HALT means autonomous execution should stop without an "
    "immediate bounded human question. Do not attempt to contact the "
    "human yourself."
)
_NO_IMPLEMENTATION_INSTRUCTION = (
    "You may inspect the repository read-only for additional context. Do "
    "not implement a solution, do not edit any file, and return only the "
    "structured decision within your allowed authority."
)


class PlannerDecisionTransportError(Exception):
    """A structured Planner decision turn could not be completed or transported.

    Carries a short, bounded, deterministic ``reason``. Never carries the
    request's question/evidence, the prompt, provider stdout/stderr,
    environment values, or raw model output. Reserved for transport/
    workflow failures owned by this module; a failure owned by a lower
    layer (planning store, environment policy, process launch, provider
    adapter) propagates unwrapped, and a structurally valid decision that
    violates the 9.1/9.2 request/authority protocol raises
    :class:`~lockstep.escalation.EscalationProtocolError` instead.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"planner decision transport error: {reason}")


@dataclass(frozen=True, slots=True)
class PlannerDecisionTurnResult:
    """The result of one structured Planner decision turn.

    ``invocation`` is excluded from :func:`repr` so logging a result never
    dumps raw process output. Carries exactly the constructed
    :class:`~lockstep.escalation_decision.PlannerDecision`, the exact
    :class:`~lockstep.escalation_decision.PlannerDecisionResolution`
    returned by
    :func:`~lockstep.escalation_decision.resolve_planner_decision`, and
    the exact :class:`~lockstep.agents.AgentInvocationResult` returned by
    :func:`~lockstep.agents.invoke_agent`.
    """

    decision: PlannerDecision
    resolution: PlannerDecisionResolution
    invocation: AgentInvocationResult = field(repr=False)


def _reject_blank(value: str) -> str:
    if not value.strip():
        raise ValueError("must not be empty or whitespace-only")
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


_Rationale = Annotated[
    str, AfterValidator(_reject_blank), AfterValidator(_validate_rationale_length)
]
_Instruction = Annotated[
    str, AfterValidator(_reject_blank), AfterValidator(_validate_instruction_length)
]
_AuthorizedPath = Annotated[str, AfterValidator(_validate_authorized_path)]


class _PlannerDecisionDraft(BaseModel):
    """The Planner's structured output shape, before request-identity injection.

    Deliberately excludes ``request_digest``: the Planner is never asked
    to reproduce it, and this schema is what is actually offered to the
    provider. Field bounds/lexical semantics mirror
    :class:`~lockstep.escalation_decision.PlannerDecision` exactly, so a
    structurally invalid draft fails at hydration rather than later at
    public-model construction. This model carries no relationship
    (category/kind legality, path-count) semantics of its own; those
    belong solely to
    :func:`~lockstep.escalation_decision.resolve_planner_decision`.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    kind: PlannerDecisionKind
    rationale: _Rationale
    instructions: Annotated[
        tuple[_Instruction, ...], Field(min_length=1, max_length=_MAX_INSTRUCTIONS)
    ]
    authorized_paths: Annotated[
        tuple[_AuthorizedPath, ...],
        Field(max_length=_MAX_AUTHORIZED_PATHS),
        AfterValidator(_reject_duplicate_authorized_paths),
    ] = ()


def _canonical_json(model: BaseModel) -> str:
    return json.dumps(
        model.model_dump(mode="json"),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def _find_outline(phase_plan: PhasePlan, request: EscalationRequest) -> SubphaseOutline | None:
    for outline in phase_plan.subphases:
        if outline.subphase_id == request.subphase_id:
            return outline
    return None


def _build_prompt(
    *,
    request: EscalationRequest,
    digest: str,
    phase_plan: PhasePlan,
    outline: SubphaseOutline,
    contract: SubphaseContract,
    legal_kinds: tuple[PlannerDecisionKind, ...],
) -> str:
    sections: list[str] = [
        "You are the Planner resolving one bounded escalation request.",
        f"Request digest: {digest}",
        "Do not invent, return, alter, or recompute request identity. "
        "Lockstep binds your structured decision to the request digest "
        "itself; your structured output does not include a digest field.",
        "Escalation request (canonical JSON):\n" + _canonical_json(request),
        "Current published phase plan (canonical JSON):\n" + _canonical_json(phase_plan),
        "Current target sub-phase outline (canonical JSON):\n" + _canonical_json(outline),
        "Active frozen sub-phase contract (canonical JSON):\n" + _canonical_json(contract),
        "Legal decision kinds for this request: "
        + ", ".join(kind.value for kind in legal_kinds)
        + ". Return only one of these decision kinds.",
    ]
    if PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION in legal_kinds:
        sections.append(_FROZEN_CORRECTION_INSTRUCTION)
    sections.append(_HALT_SEMANTICS_INSTRUCTION)
    sections.append(_NO_IMPLEMENTATION_INSTRUCTION)
    return "\n\n".join(sections) + "\n"


def invoke_planner_decision(
    runtime: AgentRuntime,
    *,
    request: EscalationRequest,
    timeout_seconds: float,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
    run_id: RunId | None = None,
) -> PlannerDecisionTurnResult:
    """Invoke the configured Planner once and resolve its structured decision.

    Derives everything provider-specific from *runtime*. Requires, in
    order, and before any inference: *request* routes to
    :attr:`~lockstep.escalation.EscalationAuthority.PLANNER`
    (:func:`~lockstep.escalation.route_escalation`, which alone decides —
    ``request.requested_authority`` cannot override it); a frozen Master
    Plan; a current published Phase plan; an active frozen Sub-phase
    Contract; and exact Phase/Sub-phase identity binding between
    *request*, the Phase plan, and the Contract. Builds a deterministic
    bounded prompt from exactly those durable inputs plus *request*'s own
    bounded evidence, performs exactly one read-only structured Planner
    inference through the frozen Phase-8 structured-output layer,
    hydrates a private decision draft, injects the exact locally computed
    request digest, constructs a public
    :class:`~lockstep.escalation_decision.PlannerDecision`, and calls
    :func:`~lockstep.escalation_decision.resolve_planner_decision`
    unchanged. When *run_id* is given, the host issues the Planner's
    :class:`~lockstep.domain.InvocationIdentity` (escalation-decision
    stage) from *request*'s own Phase/Sub-phase/attempt; without it no
    identity is issued. Performs no retry, no repair turn, no Git/planning
    mutation, and no execution of the resolved disposition.
    """
    route = route_escalation(request)
    if route.authority != EscalationAuthority.PLANNER:
        raise PlannerDecisionTransportError("escalation request does not route to planner")

    frozen_plan = load_frozen_master_plan(runtime.project_root)
    if frozen_plan is None:
        raise PlannerDecisionTransportError("master plan is not frozen")

    phase_plan = load_phase_plan(runtime.project_root, runtime.runtime_dir)
    if phase_plan is None:
        raise PlannerDecisionTransportError("current phase plan is not published")

    contract = load_active_subphase_contract(runtime.project_root, runtime.runtime_dir)
    if contract is None:
        raise PlannerDecisionTransportError("active subphase contract is not frozen")

    if phase_plan.phase_id != request.phase_id:
        raise PlannerDecisionTransportError("request phase does not match current phase plan")
    if contract.phase_id != request.phase_id:
        raise PlannerDecisionTransportError("request phase does not match active subphase contract")
    if contract.subphase_id != request.subphase_id:
        raise PlannerDecisionTransportError(
            "request subphase does not match active subphase contract"
        )

    outline = _find_outline(phase_plan, request)
    if outline is None:
        raise PlannerDecisionTransportError(
            "request subphase is not present in the current phase plan"
        )

    digest = escalation_request_digest(request)
    legal_kinds = _LEGAL_KINDS_FOR_PROMPT[request.category]
    prompt = _build_prompt(
        request=request,
        digest=digest,
        phase_plan=phase_plan,
        outline=outline,
        contract=contract,
        legal_kinds=legal_kinds,
    )

    canonical_schema = _PlannerDecisionDraft.model_json_schema()
    structured_adapter = prepare_structured_planner_adapter(
        runtime.adapters.planner,
        canonical_schema=canonical_schema,
        runtime_dir=runtime.runtime_dir,
        schema_name=_SCHEMA_NAME,
    )

    identity = (
        None
        if run_id is None
        else InvocationIdentity.issue(
            run_id=run_id,
            phase_id=request.phase_id,
            subphase_id=request.subphase_id,
            attempt=request.attempt,
            role=AgentRole.PLANNER,
            stage=InvocationStage.ESCALATION_DECISION,
        )
    )

    invocation_request = AgentInvocationRequest(
        role=AgentRole.PLANNER,
        billing_mode=runtime.config.routing.planner.billing_mode,
        prompt=prompt,
        cwd=runtime.project_root,
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
            runtime.runtime_dir,
            identity,
            outcome=outcome,
            returncode=process.returncode,
            usage=invocation.usage,
        )

    if process.returncode != 0:
        _record(ExecutionOutcome.FAILURE)
        raise PlannerDecisionTransportError("planner process exited non-zero")
    if process.stdout_truncated:
        _record(ExecutionOutcome.FAILURE)
        raise PlannerDecisionTransportError(
            "planner structured output exceeded the configured output budget"
        )

    try:
        draft = _PlannerDecisionDraft.model_validate_json(process.stdout)
    except ValidationError:
        _record(ExecutionOutcome.FAILURE)
        raise PlannerDecisionTransportError("planner returned invalid structured output") from None

    try:
        decision = PlannerDecision(
            request_digest=digest,
            kind=draft.kind,
            rationale=draft.rationale,
            instructions=draft.instructions,
            authorized_paths=draft.authorized_paths,
        )
    except ValidationError:
        _record(ExecutionOutcome.FAILURE)
        raise PlannerDecisionTransportError(
            "planner returned unexpected structured object"
        ) from None

    _record(ExecutionOutcome.SUCCESS)

    resolution = resolve_planner_decision(request, decision)

    return PlannerDecisionTurnResult(
        decision=decision,
        resolution=resolution,
        invocation=invocation,
    )


__all__ = [
    "PlannerDecisionTransportError",
    "PlannerDecisionTurnResult",
    "invoke_planner_decision",
]
