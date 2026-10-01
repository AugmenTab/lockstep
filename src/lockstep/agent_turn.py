"""Structured agent blocker channel for execution-role turns (Phase 9.4).

Gives writable/read-only execution agents (Implementer, Reviewer) a
strict machine-readable way to report a normal turn's outcome:

    normal task prompt
        -> normal role authority (unchanged tool/sandbox surface)
        -> deterministic bounded blocker-protocol prompt suffix
        -> exactly one structured inference through the role-output layer
        -> AgentTurnReport (COMPLETED, or BLOCKED + bounded blocker draft)
        -> host injects source_role/phase_id/subphase_id/attempt
        -> AgentTurnResult (COMPLETED -> no request, BLOCKED -> EscalationRequest)

Core invariant: the model may describe a blocker, but it may not
manufacture workflow identity. ``source_role``, ``phase_id``,
``subphase_id``, and ``attempt`` are supplied by the caller and are
absent from the provider's structured-output schema entirely; a model
that manages to emit them anyway fails strict hydration rather than
being silently accepted.

This module is a thin, provider-neutral orchestration seam built
strictly on top of :mod:`lockstep.escalation`, :mod:`lockstep.runtime`,
and the additive Sub-phase 9.4 role-output layer
(:mod:`lockstep.agents.role_output`). It performs no routing, no Planner
invocation, no human prompting, and no Supervisor/workflow-state
mutation — it only transports and validates exactly one structured
Implementer or Reviewer turn per call, and (for a BLOCKED outcome)
constructs the resulting :class:`~lockstep.escalation.EscalationRequest`
unchanged. No retry, no repair turn, and no fallback provider exist
here.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from enum import StrEnum
from pathlib import Path
from typing import Annotated, Protocol

from pydantic import AfterValidator, BaseModel, ConfigDict, Field, ValidationError, model_validator

from lockstep.agents import (
    AgentAdapter,
    AgentInvocationRequest,
    AgentInvocationResult,
    invoke_agent,
    prepare_structured_role_adapter,
)
from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    BillingMode,
    InvocationIdentity,
    InvocationStage,
    PhaseId,
    RunId,
    SubphaseId,
)
from lockstep.escalation import EscalationAuthority, EscalationCategory, EscalationRequest

_MAX_QUESTION_LENGTH = 4096
_MAX_EVIDENCE_ENTRIES = 32
_MAX_EVIDENCE_ENTRY_LENGTH = 2048

_SUPPORTED_ROLES: frozenset[AgentRole] = frozenset({AgentRole.IMPLEMENTER, AgentRole.REVIEWER})
_STAGE_BY_ROLE: dict[AgentRole, InvocationStage] = {
    AgentRole.IMPLEMENTER: InvocationStage.IMPLEMENTATION,
    AgentRole.REVIEWER: InvocationStage.REVIEW,
}

_SCHEMA_NAME_BY_ROLE: Mapping[AgentRole, str] = {
    AgentRole.IMPLEMENTER: "agent-turn-implementer",
    AgentRole.REVIEWER: "agent-turn-reviewer",
}

_BLOCKER_PROTOCOL_SUFFIX = (
    "\n\n---\n"
    "Structured turn-completion protocol:\n\n"
    "Return COMPLETED if you can complete the assigned turn under the "
    "authority and constraints provided.\n\n"
    "Return BLOCKED if continuing would require an authority decision, "
    "architectural choice, frozen-artifact correction, requirement "
    "decision, external side effect, or deterministic control-plane "
    "resolution that you do not possess.\n\n"
    "When BLOCKED:\n"
    "    stop rather than self-authorizing the resolution\n"
    "    choose the best matching structured category\n"
    "    provide one bounded question\n"
    "    provide bounded factual evidence\n"
    "    state the authority you believe is required\n\n"
    "Do not invent phase/subphase/attempt identity.\n"
    "Do not contact the human directly.\n"
    "Do not invoke another agent.\n\n"
    "Discovering an apparently obvious fix does not grant authority to "
    "cross a frozen or out-of-scope boundary. For a frozen test defect, "
    "report status BLOCKED with category test_defect rather than editing "
    "the test.\n\n"
    "If you encounter a deterministic issue you believe a higher-level "
    "control plane can resolve, report category control_plane_blocker "
    "with requested_authority supervisor, and still stop your own turn "
    "rather than resolving it yourself.\n"
)


class AgentTurnStatus(StrEnum):
    """The exact terminal outcome vocabulary for one structured agent turn."""

    COMPLETED = "completed"
    BLOCKED = "blocked"


class AgentTurnError(Exception):
    """A structured agent turn could not be completed or transported.

    Carries a short, bounded, deterministic ``reason``. Never carries the
    request prompt, provider stdout/stderr, environment values, the
    blocker's question/evidence, or raw model output. Reserved for
    transport/protocol failures owned by this layer; a failure owned by
    a lower layer (role-output preparation, environment policy, process
    launch, provider adapter) propagates unwrapped.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"agent turn error: {reason}")


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


class AgentBlockerDraft(BaseModel):
    """A bounded, structured blocker description, before host-identity injection.

    Immutable and strict: unknown fields are rejected. Deliberately
    excludes ``source_role``/``phase_id``/``subphase_id``/``attempt`` —
    those are host-owned and supplied only when
    :func:`invoke_agent_turn` constructs the final
    :class:`~lockstep.escalation.EscalationRequest`. Field bounds mirror
    :class:`~lockstep.escalation.EscalationRequest` exactly.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    category: EscalationCategory
    question: _Question
    evidence: Annotated[tuple[_EvidenceEntry, ...], Field(min_length=1, max_length=32)]
    requested_authority: EscalationAuthority


class AgentTurnReport(BaseModel):
    """The strict structured final report of one agent turn.

    Immutable and strict: unknown fields are rejected. A ``COMPLETED``
    report must carry no blocker; a ``BLOCKED`` report must carry one.
    Carries no free-form summary field — the repository/worktree itself
    is authoritative evidence of completed work.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    status: AgentTurnStatus
    blocker: AgentBlockerDraft | None

    @model_validator(mode="after")
    def _check_status_blocker_relationship(self) -> AgentTurnReport:
        if self.status is AgentTurnStatus.COMPLETED and self.blocker is not None:
            raise ValueError("a COMPLETED agent turn report must not include a blocker")
        if self.status is AgentTurnStatus.BLOCKED and self.blocker is None:
            raise ValueError("a BLOCKED agent turn report must include a blocker")
        return self


@dataclass(frozen=True, slots=True)
class AgentTurnResult:
    """The result of one structured agent turn.

    ``invocation`` is excluded from :func:`repr` so logging a result
    never dumps raw process output. ``escalation_request`` is ``None``
    for a ``COMPLETED`` report and a real, unmodified
    :class:`~lockstep.escalation.EscalationRequest` for a ``BLOCKED``
    report.
    """

    report: AgentTurnReport
    escalation_request: EscalationRequest | None
    invocation: AgentInvocationResult = field(repr=False)


def _validate_prompt(prompt: str) -> str:
    if not isinstance(prompt, str):
        raise AgentTurnError("prompt must be a string")
    if not prompt.strip():
        raise AgentTurnError("prompt must not be blank")
    if "\x00" in prompt:
        raise AgentTurnError("prompt must not contain NUL")
    return prompt


class AgentTurnRoleRoute(Protocol):
    """The one routing attribute :func:`invoke_agent_turn` reads per role."""

    @property
    def billing_mode(self) -> BillingMode: ...


class AgentTurnRoutingPolicy(Protocol):
    """The Implementer/Reviewer routes :func:`invoke_agent_turn` reads."""

    @property
    def implementer(self) -> AgentTurnRoleRoute: ...
    @property
    def reviewer(self) -> AgentTurnRoleRoute: ...


class AgentTurnProjectConfig(Protocol):
    """The one configuration attribute :func:`invoke_agent_turn` reads."""

    @property
    def routing(self) -> AgentTurnRoutingPolicy: ...


class AgentTurnAdapters(Protocol):
    """The Implementer/Reviewer adapters :func:`invoke_agent_turn` reads."""

    @property
    def implementer(self) -> AgentAdapter: ...
    @property
    def reviewer(self) -> AgentAdapter: ...


class AgentTurnRuntimeContext(Protocol):
    """The structural runtime-view :func:`invoke_agent_turn` actually consumes.

    A deliberately narrow, provider-neutral substitute for a concrete
    ``lockstep.runtime.AgentRuntime``: importing that class here would
    create a Supervisor/runtime import cycle once the Supervisor
    transaction composes with this module (Sub-phase 9.6). Any object
    exposing this exact shape — including a real ``AgentRuntime`` — is
    accepted; this module never imports or names ``AgentRuntime``. Every
    attribute is read-only (``@property``) so a frozen concrete runtime
    (whose fields are themselves read-only) satisfies this Protocol
    structurally.
    """

    @property
    def runtime_dir(self) -> Path: ...
    @property
    def transaction_parent_env(self) -> Mapping[str, str]: ...
    @property
    def config(self) -> AgentTurnProjectConfig: ...
    @property
    def adapters(self) -> AgentTurnAdapters: ...


def invoke_agent_turn(
    runtime: AgentTurnRuntimeContext,
    *,
    role: AgentRole,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
    prompt: str,
    cwd: Path,
    timeout_seconds: float,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
    run_id: RunId | None = None,
) -> AgentTurnResult:
    """Invoke one structured Implementer/Reviewer turn and resolve its report.

    Derives everything provider-specific from *runtime*: the adapter
    (``runtime.adapters.implementer`` or ``runtime.adapters.reviewer``,
    selected by *role*) and the billing mode
    (``runtime.config.routing.implementer.billing_mode`` or
    ``.reviewer.billing_mode``). Supports only
    :attr:`~lockstep.domain.AgentRole.IMPLEMENTER` and
    :attr:`~lockstep.domain.AgentRole.REVIEWER`; any other role —
    including :attr:`~lockstep.domain.AgentRole.PLANNER`, which has its
    own dedicated 9.3 transport — raises :class:`AgentTurnError` before
    any inference. *cwd* is caller-owned so the Supervisor's existing
    worktree convention is never guessed at this layer. Appends a fixed,
    deterministic blocker-protocol suffix to *prompt*, performs exactly
    one structured inference through
    :func:`~lockstep.agents.role_output.prepare_structured_role_adapter`,
    strictly hydrates the resulting :class:`AgentTurnReport`, and — only
    for a ``BLOCKED`` report — constructs a real
    :class:`~lockstep.escalation.EscalationRequest` from *phase_id*,
    *subphase_id*, *attempt*, *role*, and the report's blocker fields
    exactly as reported. When *run_id* is given, the host issues the
    turn's :class:`~lockstep.domain.InvocationIdentity` (Implementer
    stage); without it no identity is issued. Performs no routing, no Planner invocation, no
    human prompting, and no repository/workflow-state mutation.
    """
    if role not in _SUPPORTED_ROLES:
        raise AgentTurnError("unsupported blocker-capable role")

    _validate_prompt(prompt)

    if role is AgentRole.IMPLEMENTER:
        base_adapter = runtime.adapters.implementer
        billing_mode = runtime.config.routing.implementer.billing_mode
    else:
        base_adapter = runtime.adapters.reviewer
        billing_mode = runtime.config.routing.reviewer.billing_mode

    schema_name = _SCHEMA_NAME_BY_ROLE[role]
    canonical_schema = AgentTurnReport.model_json_schema()

    structured_adapter = prepare_structured_role_adapter(
        base_adapter,
        role=role,
        runtime_dir=runtime.runtime_dir,
        schema=canonical_schema,
        schema_name=schema_name,
    )

    final_prompt = prompt + _BLOCKER_PROTOCOL_SUFFIX

    identity = (
        None
        if run_id is None
        else InvocationIdentity.issue(
            run_id=run_id,
            phase_id=phase_id,
            subphase_id=subphase_id,
            attempt=attempt,
            role=role,
            stage=_STAGE_BY_ROLE[role],
        )
    )

    invocation_request = AgentInvocationRequest(
        role=role,
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
    )

    process = invocation.process
    if process.returncode != 0:
        raise AgentTurnError("agent process exited non-zero")
    if process.stdout_truncated:
        raise AgentTurnError("agent structured output exceeded the configured output budget")

    try:
        report = AgentTurnReport.model_validate_json(process.stdout)
    except ValidationError:
        raise AgentTurnError("agent returned invalid structured outcome") from None

    if report.status is AgentTurnStatus.COMPLETED:
        return AgentTurnResult(report=report, escalation_request=None, invocation=invocation)

    assert report.blocker is not None
    escalation_request = EscalationRequest(
        source_role=role,
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=attempt,
        category=report.blocker.category,
        question=report.blocker.question,
        evidence=report.blocker.evidence,
        requested_authority=report.blocker.requested_authority,
    )

    return AgentTurnResult(
        report=report, escalation_request=escalation_request, invocation=invocation
    )


__all__ = [
    "AgentBlockerDraft",
    "AgentTurnError",
    "AgentTurnReport",
    "AgentTurnResult",
    "AgentTurnRuntimeContext",
    "AgentTurnStatus",
    "invoke_agent_turn",
]
