"""High-level AI planning workflow: Master Plan candidate creation.

Composes a prepared :class:`~lockstep.runtime.AgentRuntime`, the
provider-neutral structured Planner transport
(:mod:`lockstep.planning_transport`), and the pure semantic validator
(:mod:`lockstep.planning`) into the one production path from
human-approved requirements to a validated Master Plan *candidate*:

    human-approved requirements
        -> prepared AgentRuntime
        -> configured structured Planner (lockstep.planning_transport)
        -> typed MasterPlan candidate
        -> explicit project binding
        -> semantic validation (lockstep.planning)
        -> MasterPlanCandidate returned for human review

Successful candidate creation never approves, freezes, or persists the
candidate: it returns a validated proposal for a human to review. The
explicit :func:`~lockstep.planning_store.freeze_master_plan` call remains
the sole action that makes a Master Plan canonical, and this module does
not import it. Every call performs at most one Planner inference: there
is no retry, no repair prompt, and no provider or model fallback.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field

from lockstep.agents import AgentInvocationResult
from lockstep.domain import MasterPlan, ProjectId
from lockstep.planning import validate_master_plan
from lockstep.planning_store import load_frozen_master_plan
from lockstep.planning_transport import PlanningArtifactKind, invoke_planner_artifact
from lockstep.runtime import AgentRuntime

_PROJECT_ID_LABEL = "Project ID:"
_REQUIREMENTS_LABEL = "Human-approved requirements (JSON-encoded string):"

_PLANNING_INSTRUCTIONS = (
    "The human requirements above are authoritative.\n"
    "Use exactly the supplied project_id for every artifact you return.\n"
    "Produce a dependency-ordered implementation Master Plan.\n"
    "Describe major architectural/dependency Phases.\n"
    "Every Phase must be independently meaningful as a milestone.\n"
    "Phase dependencies may reference only earlier Phases.\n"
    "Each Phase must contain a provisional, non-empty Sub-phase outline "
    "as required by the current MasterPlan/PhasePlan schema.\n"
    "Sub-phase outlines are only likely sequencing information.\n"
    "Do not create detailed SubphaseContracts or TestSpecifications.\n"
    "Do not create executable tests.\n"
    "Do not pretend future Sub-phase details are frozen.\n"
    "Sub-phase dependencies may reference only earlier Sub-phases in the "
    "same Phase.\n"
    "Keep completed/green-increment thinking in mind: no Phase or "
    "outlined Sub-phase should intentionally require the repository to "
    "remain broken until a later unit repairs it.\n"
    "Do not perform implementation work.\n"
    "Inspect the repository read-only when useful to ground the plan.\n"
    "Return only the structured MasterPlan requested by the supplied schema.\n"
)


class MasterPlanCreationError(Exception):
    """A Master Plan candidate could not be created.

    Carries a short, bounded, deterministic ``reason``. Never carries
    requirements text, prompt text, raw provider output, or filesystem
    paths. Lower-layer typed failures
    (:class:`~lockstep.planning_transport.PlanningTransportError`,
    :class:`~lockstep.planning.PlanningValidationError`,
    :class:`~lockstep.planning_store.PlanningStoreError`, and provider or
    process errors) propagate unwrapped and are never represented by
    this exception.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"master plan creation error: {reason}")


@dataclass(frozen=True, slots=True)
class MasterPlanCandidate:
    """A validated Master Plan candidate awaiting explicit human approval.

    Carries exactly the hydrated, semantically validated plan and the
    bounded provenance of the Planner invocation that produced it.
    Neither field appears in :func:`repr`, so logging a candidate never
    dumps plan contents or raw provider output. Creating a candidate
    never approves, freezes, or persists it; see
    :func:`~lockstep.planning_store.freeze_master_plan` for the explicit
    human-approval boundary.
    """

    plan: MasterPlan = field(repr=False)
    invocation: AgentInvocationResult = field(repr=False)


def _validate_requirements(requirements: str) -> None:
    if not isinstance(requirements, str):
        raise MasterPlanCreationError("requirements must be a string")
    if not requirements.strip():
        raise MasterPlanCreationError("requirements must not be blank")
    if "\x00" in requirements:
        raise MasterPlanCreationError("requirements must not contain NUL")


def _build_master_plan_prompt(project_id: str, requirements: str) -> str:
    encoded_requirements = json.dumps(requirements)
    return (
        f"{_PROJECT_ID_LABEL}\n"
        f"{project_id}\n"
        "\n"
        f"{_REQUIREMENTS_LABEL}\n"
        f"{encoded_requirements}\n"
        "\n"
        f"{_PLANNING_INSTRUCTIONS}"
    )


def create_master_plan_candidate(
    runtime: AgentRuntime,
    *,
    project_id: ProjectId,
    requirements: str,
    timeout_seconds: float,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
) -> MasterPlanCandidate:
    """Ask the configured Planner for one validated Master Plan candidate.

    Performs, in order: requirements validation, an already-frozen-plan
    check (:func:`~lockstep.planning_store.load_frozen_master_plan`),
    exactly one structured Planner inference
    (:func:`~lockstep.planning_transport.invoke_planner_artifact`),
    artifact-kind/type verification, exact ``project_id`` binding, and
    semantic validation (:func:`~lockstep.planning.validate_master_plan`).
    Returns a :class:`MasterPlanCandidate` for human review; it neither
    approves nor freezes the plan, and it never retries, repairs, or
    falls back to another provider or model. Provider selection comes
    entirely from *runtime*; this function has no provider, model,
    effort, billing, or schema parameter of its own.
    """
    _validate_requirements(requirements)

    if load_frozen_master_plan(runtime.project_root) is not None:
        raise MasterPlanCreationError("master plan is already frozen")

    prompt = _build_master_plan_prompt(project_id.root, requirements)

    result = invoke_planner_artifact(
        runtime,
        kind=PlanningArtifactKind.MASTER_PLAN,
        prompt=prompt,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=termination_grace_seconds,
    )

    if result.kind is not PlanningArtifactKind.MASTER_PLAN or not isinstance(
        result.artifact, MasterPlan
    ):
        raise MasterPlanCreationError("planner returned an unexpected artifact")

    plan = result.artifact
    if plan.project_id != project_id:
        raise MasterPlanCreationError("planner returned a master plan for the wrong project")

    validate_master_plan(plan)

    return MasterPlanCandidate(plan=plan, invocation=result.invocation)


__all__ = [
    "MasterPlanCandidate",
    "MasterPlanCreationError",
    "create_master_plan_candidate",
]
