"""High-level AI planning workflow: Master Plan and Phase outline creation.

Composes a prepared :class:`~lockstep.runtime.AgentRuntime`, the
provider-neutral structured Planner transport
(:mod:`lockstep.planning_transport`), and the pure semantic validator
(:mod:`lockstep.planning`) into two production paths:

    human-approved requirements
        -> prepared AgentRuntime
        -> configured structured Planner (lockstep.planning_transport)
        -> typed MasterPlan candidate
        -> explicit project binding
        -> semantic validation (lockstep.planning)
        -> MasterPlanCandidate returned for human review

and, for one explicitly selected Phase of an already-frozen Master Plan:

    frozen Master Plan + explicit phase_id + optional current provisional
    Phase outline
        -> configured structured Planner (lockstep.planning_transport)
        -> typed PhasePlan candidate
        -> phase identity / frozen-fact binding
        -> effective Master Plan semantic validation (lockstep.planning)
        -> PhasePlanCandidate returned for the caller to publish or discard

Successful candidate creation never approves, freezes, or persists the
candidate: it returns a validated proposal. The explicit
:func:`~lockstep.planning_store.freeze_master_plan` and
:func:`~lockstep.planning_store.publish_phase_plan` calls remain the sole
actions that make planning state durable, and this module imports
neither. Every call performs at most one Planner inference: there is no
retry, no repair prompt, and no provider or model fallback.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field

from lockstep.agents import AgentInvocationResult
from lockstep.domain import MasterPlan, PhaseId, PhasePlan, ProjectId
from lockstep.planning import validate_master_plan
from lockstep.planning_store import (
    load_active_subphase_contract,
    load_frozen_master_plan,
    load_phase_plan,
)
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


# ---------------------------------------------------------------------------
# Phase outline candidate creation (Sub-phase 8.5)
# ---------------------------------------------------------------------------

_MASTER_PLAN_LABEL = "Frozen Master Plan:"
_TARGET_PHASE_LABEL = "Target phase_id:"
_CURRENT_OUTLINE_LABEL = "Current provisional outline:"

_PHASE_OUTLINE_INSTRUCTIONS = (
    "The frozen Master Plan above is authoritative context for the whole "
    "project.\n"
    "Use exactly the supplied target phase_id for the returned PhasePlan.\n"
    "Preserve exactly these frozen Phase-level facts from the Master Plan: "
    "schema_version, phase_id, title, objective, depends_on, and "
    "integration_acceptance_criteria.\n"
    "Only the subphases field is provisional and revisable.\n"
    "The subphases must be non-empty, ordered, and dependency-valid: each "
    "Sub-phase may depend only on earlier Sub-phases in the same Phase.\n"
    "Each Sub-phase outline must contain only subphase_id, title, "
    "objective, and depends_on.\n"
    "Do not create detailed SubphaseContracts or TestSpecifications, and "
    "do not create executable tests; those belong to later, "
    "one-Sub-phase-at-a-time planning.\n"
    "A good Sub-phase represents one coherent mental-model change: "
    "dependency-complete, reviewable as one diff, meaningfully verifiable, "
    "and safe to land green.\n"
    "Do not over-decompose inseparable work merely to create more "
    "Sub-phases, and do not create a giant catch-all Sub-phase either. "
    "Diff/file-count thresholds are heuristics only; do not fabricate "
    "exact future diff sizes.\n"
    "Inspect the current repository read-only when useful to refine "
    "implementation order and boundaries. Do not modify files and do not "
    "implement any Sub-phase.\n"
    "If a current provisional outline is supplied above, you may retain, "
    "reorder, split, combine, rename, remove, or add future Sub-phase "
    "outlines if the resulting plan better matches the frozen Phase and "
    "current repository state; do not treat it as immutable.\n"
    "Return only the structured PhasePlan requested by the supplied "
    "schema.\n"
)


class PhaseOutlinePlanningError(Exception):
    """A Phase outline candidate could not be created.

    Carries a short, bounded, deterministic ``reason``. Never carries
    Master Plan content, Phase plan content, prompt text, raw provider
    output, or filesystem paths. Used only for workflow-owned failures:
    an unfrozen Master Plan, a requested Phase absent from the frozen
    Master Plan, an active Sub-phase Contract, a wrong-Phase or
    wrong-type Planner artifact, or a Planner attempt to change a frozen
    Phase-level fact. Lower-layer typed failures
    (:class:`~lockstep.planning_transport.PlanningTransportError`,
    :class:`~lockstep.planning.PlanningValidationError`,
    :class:`~lockstep.planning_store.PlanningStoreError`, and provider or
    process errors) propagate unwrapped and are never represented by
    this exception.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"phase outline planning error: {reason}")


@dataclass(frozen=True, slots=True)
class PhasePlanCandidate:
    """A validated Phase outline candidate awaiting explicit publication.

    Carries exactly the hydrated, semantically validated Phase plan and
    the bounded provenance of the Planner invocation that produced it.
    Neither field appears in :func:`repr`, so logging a candidate never
    dumps plan contents or raw provider output. Creating a candidate
    never publishes it; see
    :func:`~lockstep.planning_store.publish_phase_plan` for the explicit
    durable-adoption boundary. Publication is deterministic adoption of
    provisional planning state, not human approval.
    """

    plan: PhasePlan = field(repr=False)
    invocation: AgentInvocationResult = field(repr=False)


def _find_frozen_phase(master_plan: MasterPlan, phase_id: PhaseId) -> PhasePlan | None:
    for phase in master_plan.phases:
        if phase.phase_id == phase_id:
            return phase
    return None


def _canonical_json(model: MasterPlan | PhasePlan) -> str:
    return json.dumps(model.model_dump(mode="json"), ensure_ascii=False, separators=(",", ":"))


def _build_phase_plan_prompt(
    master_plan: MasterPlan,
    phase_id: PhaseId,
    current_outline: PhasePlan | None,
) -> str:
    current_outline_text = "null" if current_outline is None else _canonical_json(current_outline)
    return (
        f"{_MASTER_PLAN_LABEL}\n"
        f"{_canonical_json(master_plan)}\n"
        "\n"
        f"{_TARGET_PHASE_LABEL}\n"
        f"{phase_id.root}\n"
        "\n"
        f"{_CURRENT_OUTLINE_LABEL}\n"
        f"{current_outline_text}\n"
        "\n"
        f"{_PHASE_OUTLINE_INSTRUCTIONS}"
    )


def create_phase_plan_candidate(
    runtime: AgentRuntime,
    *,
    phase_id: PhaseId,
    timeout_seconds: float,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
) -> PhasePlanCandidate:
    """Ask the configured Planner for one validated Phase outline candidate.

    Performs, in order: a frozen-Master-Plan check
    (:func:`~lockstep.planning_store.load_frozen_master_plan`), a
    requested-Phase-exists check, an active-Sub-phase-Contract check
    (:func:`~lockstep.planning_store.load_active_subphase_contract`) that
    fails closed before any inference, loading a matching current
    provisional Phase plan when one exists
    (:func:`~lockstep.planning_store.load_phase_plan`), exactly one
    structured Planner inference
    (:func:`~lockstep.planning_transport.invoke_planner_artifact`),
    artifact-kind/type verification, exact ``phase_id`` binding, frozen
    Phase-level fact binding (only ``subphases`` may differ from the
    frozen Phase), and semantic validation of the effective Master Plan
    (:func:`~lockstep.planning.validate_master_plan`). Returns a
    :class:`PhasePlanCandidate` for the caller to publish or discard; it
    never publishes the candidate itself, and it never retries, repairs,
    or falls back to another provider or model. Provider selection comes
    entirely from *runtime*; this function has no provider, model,
    effort, billing, or schema parameter of its own. Phase identity is
    never inferred: *phase_id* is always the caller's explicit choice.
    """
    master_plan = load_frozen_master_plan(runtime.project_root)
    if master_plan is None:
        raise PhaseOutlinePlanningError("master plan is not frozen")

    frozen_phase = _find_frozen_phase(master_plan, phase_id)
    if frozen_phase is None:
        raise PhaseOutlinePlanningError("requested phase is not present in the frozen master plan")

    if load_active_subphase_contract(runtime.project_root, runtime.runtime_dir) is not None:
        raise PhaseOutlinePlanningError(
            "phase outline cannot be replanned while a subphase contract is active"
        )

    current_phase_plan = load_phase_plan(runtime.project_root, runtime.runtime_dir)
    current_outline = (
        current_phase_plan
        if current_phase_plan is not None and current_phase_plan.phase_id == phase_id
        else None
    )

    prompt = _build_phase_plan_prompt(master_plan, phase_id, current_outline)

    result = invoke_planner_artifact(
        runtime,
        kind=PlanningArtifactKind.PHASE_PLAN,
        prompt=prompt,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=termination_grace_seconds,
    )

    if result.kind is not PlanningArtifactKind.PHASE_PLAN or not isinstance(
        result.artifact, PhasePlan
    ):
        raise PhaseOutlinePlanningError("planner returned an unexpected artifact")

    candidate_plan = result.artifact
    if candidate_plan.phase_id != phase_id:
        raise PhaseOutlinePlanningError("planner returned a phase plan for the wrong phase")

    expected_candidate = frozen_phase.model_copy(update={"subphases": candidate_plan.subphases})
    if candidate_plan != expected_candidate:
        raise PhaseOutlinePlanningError("planner changed frozen phase-level facts")

    effective_master_plan = master_plan.model_copy(
        update={
            "phases": tuple(
                candidate_plan if phase.phase_id == phase_id else phase
                for phase in master_plan.phases
            )
        }
    )
    validate_master_plan(effective_master_plan)

    return PhasePlanCandidate(plan=candidate_plan, invocation=result.invocation)


__all__ = [
    "MasterPlanCandidate",
    "MasterPlanCreationError",
    "PhaseOutlinePlanningError",
    "PhasePlanCandidate",
    "create_master_plan_candidate",
    "create_phase_plan_candidate",
]
