"""Provider-neutral structured Planner artifact transport.

Gives Lockstep exactly one production path from a prepared
:class:`~lockstep.runtime.AgentRuntime` to a typed Phase-1 planning
artifact:

    AgentRuntime
        -> configured runtime.adapters.planner
        -> lockstep.agents.prepare_structured_planner_adapter (provider adaptation)
        -> private-stdin Planner inference (lockstep.agents.invoke_agent)
        -> schema-constrained final-message JSON
        -> Pydantic hydration against the exact requested artifact model
        -> typed planning artifact

This module is deliberately provider-neutral: it depends only on the
generic :mod:`lockstep.agents` API, :mod:`lockstep.domain` planning
artifact models, and :class:`~lockstep.runtime.AgentRuntime`. It performs
no semantic (cross-reference) validation of a hydrated candidate — that
composition belongs to later Phase-8 planning workflows built on
:mod:`lockstep.planning` and :mod:`lockstep.planning_store` — and it
implements no durable persistence of its own beyond the schema artifact
that :mod:`lockstep.agents.structured_output` writes for a Codex Planner.
Every call performs exactly one Planner inference; there is no retry, no
alternate provider, and no fallback model.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from enum import StrEnum

from pydantic import ValidationError

from lockstep.agents import (
    AgentInvocationRequest,
    AgentInvocationResult,
    invoke_agent,
    prepare_structured_planner_adapter,
)
from lockstep.domain import AgentRole, MasterPlan, PhasePlan, SubphaseContract
from lockstep.runtime import AgentRuntime

PlanningArtifact = MasterPlan | PhasePlan | SubphaseContract


class PlanningArtifactKind(StrEnum):
    """The exact three Phase-1 planning artifacts 8.3 transports."""

    MASTER_PLAN = "master-plan"
    PHASE_PLAN = "phase-plan"
    SUBPHASE_CONTRACT = "subphase-contract"


_ARTIFACT_TYPES: dict[PlanningArtifactKind, type[PlanningArtifact]] = {
    PlanningArtifactKind.MASTER_PLAN: MasterPlan,
    PlanningArtifactKind.PHASE_PLAN: PhasePlan,
    PlanningArtifactKind.SUBPHASE_CONTRACT: SubphaseContract,
}


class PlanningTransportError(Exception):
    """A completed Planner invocation could not be interpreted as the requested artifact.

    Carries a short, bounded ``reason``. Never carries raw provider
    stdout/stderr, the prompt, environment values, or a Pydantic/JSON
    parser error excerpt. Never raised for a failure owned by a lower
    layer (adapter, environment policy, or process execution); those
    typed exceptions propagate unwrapped.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"planning transport error: {reason}")


@dataclass(frozen=True, slots=True)
class PlanningArtifactResult:
    """The typed outcome of one structured Planner invocation.

    ``artifact`` and ``invocation`` are excluded from :func:`repr` so
    logging a result never dumps a full plan or raw process output.
    """

    kind: PlanningArtifactKind
    artifact: PlanningArtifact = field(repr=False)
    invocation: AgentInvocationResult = field(repr=False)


def _validate_prompt(prompt: str) -> str:
    if not isinstance(prompt, str):
        raise PlanningTransportError("prompt must be a string")
    if not prompt.strip():
        raise PlanningTransportError("prompt must not be blank")
    if "\x00" in prompt:
        raise PlanningTransportError("prompt must not contain NUL")
    return prompt


def invoke_planner_artifact(
    runtime: AgentRuntime,
    *,
    kind: PlanningArtifactKind,
    prompt: str,
    timeout_seconds: float,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
) -> PlanningArtifactResult:
    """Invoke the configured Planner once and hydrate its typed *kind* artifact.

    Derives everything provider-specific from *runtime*: the adapter
    (``runtime.adapters.planner``), the billing mode
    (``runtime.config.routing.planner.billing_mode``), the working
    directory (``runtime.project_root``), and the parent environment
    (``runtime.transaction_parent_env``). The canonical schema for *kind*
    is always ``<ArtifactModel>.model_json_schema()``. Performs exactly
    one Planner inference: no retry, no alternate provider, no fallback
    model, and no semantic (cross-reference) validation of the hydrated
    candidate.
    """
    _validate_prompt(prompt)

    artifact_type = _ARTIFACT_TYPES[kind]
    canonical_schema = artifact_type.model_json_schema()

    structured_adapter = prepare_structured_planner_adapter(
        runtime.adapters.planner,
        canonical_schema=canonical_schema,
        runtime_dir=runtime.runtime_dir,
        schema_name=kind.value,
    )

    request = AgentInvocationRequest(
        role=AgentRole.PLANNER,
        billing_mode=runtime.config.routing.planner.billing_mode,
        prompt=prompt,
        cwd=runtime.project_root,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=termination_grace_seconds,
    )

    invocation = invoke_agent(
        structured_adapter,
        request,
        parent_env=runtime.transaction_parent_env,
    )

    process = invocation.process
    if process.returncode != 0:
        raise PlanningTransportError("planner process exited non-zero")
    if process.stdout_truncated:
        raise PlanningTransportError(
            "planner structured output exceeded the configured output budget"
        )

    try:
        artifact = artifact_type.model_validate_json(process.stdout)
    except ValidationError:
        raise PlanningTransportError(
            f"planner output is not a valid {kind.value} artifact"
        ) from None

    return PlanningArtifactResult(kind=kind, artifact=artifact, invocation=invocation)


__all__ = [
    "PlanningArtifactKind",
    "PlanningArtifactResult",
    "PlanningTransportError",
    "invoke_planner_artifact",
]
