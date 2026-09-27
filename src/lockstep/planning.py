"""Deterministic semantic validation for Lockstep planning artifacts.

The frozen Phase-1 planning artifact models (:mod:`lockstep.domain`)
validate field types, schema versions, non-blank text, immutability, and
basic non-empty collections, but deliberately do not validate the
relationships between artifacts: whether a dependency reference resolves,
whether declared execution order actually satisfies the dependency graph,
or whether identifiers are unique in the scope that requires it.

This module closes that gap for two artifact shapes: a complete
:class:`~lockstep.domain.MasterPlan` and a single
:class:`~lockstep.domain.SubphaseContract` validated against its plan.
Both validators are pure: they inspect only the objects supplied to them
and perform no filesystem, environment, process, Git, network, or clock
access. Path, glob, and containment semantics for a contract's
``allowed_paths``/``protected_paths``/``forbidden_paths`` remain
deliberately unvalidated here; that is a later, execution-scoped concern.
"""

from lockstep.domain import MasterPlan, PhasePlan, SubphaseContract


class PlanningValidationError(Exception):
    """A planning artifact failed semantic (cross-reference) validation.

    Carries a short, bounded, deterministic ``reason`` that may name a
    canonical non-secret identifier (a phase id, a subphase id, an
    acceptance criterion id, a test path) but never echoes raw artifact
    contents, prompt text, or JSON.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"planning validation error: {reason}")


def _require_no_duplicates(values: tuple[str, ...], *, on_duplicate: str) -> None:
    seen: set[str] = set()
    for value in values:
        if value in seen:
            raise PlanningValidationError(on_duplicate.format(value=value))
        seen.add(value)


def _validate_phase_identity(plan: MasterPlan) -> None:
    seen: set[str] = set()
    for phase in plan.phases:
        phase_id = phase.phase_id.root
        if phase_id in seen:
            raise PlanningValidationError(f"duplicate phase id: {phase_id}")
        seen.add(phase_id)


def _validate_phase_dependency_duplicates(plan: MasterPlan) -> None:
    for phase in plan.phases:
        _require_no_duplicates(
            tuple(dep.root for dep in phase.depends_on),
            on_duplicate=f"phase {phase.phase_id.root}: duplicate phase dependency: {{value}}",
        )


def _validate_phase_dependency_known(plan: MasterPlan) -> None:
    known_ids = {phase.phase_id.root for phase in plan.phases}
    for phase in plan.phases:
        for dep in phase.depends_on:
            if dep.root not in known_ids:
                raise PlanningValidationError(
                    f"phase {phase.phase_id.root}: unknown phase dependency: {dep.root}"
                )


def _validate_phase_dependency_not_self(plan: MasterPlan) -> None:
    for phase in plan.phases:
        for dep in phase.depends_on:
            if dep.root == phase.phase_id.root:
                raise PlanningValidationError(
                    f"phase {phase.phase_id.root}: phase depends on itself"
                )


def _validate_phase_dependency_order(plan: MasterPlan) -> None:
    earlier_ids: set[str] = set()
    for phase in plan.phases:
        for dep in phase.depends_on:
            if dep.root not in earlier_ids:
                raise PlanningValidationError(
                    f"phase {phase.phase_id.root}: phase dependency {dep.root} "
                    f"does not precede phase {phase.phase_id.root}"
                )
        earlier_ids.add(phase.phase_id.root)


def _validate_subphase_identity(phase: PhasePlan) -> None:
    seen: set[str] = set()
    for subphase in phase.subphases:
        subphase_id = subphase.subphase_id.root
        if subphase_id in seen:
            raise PlanningValidationError(
                f"phase {phase.phase_id.root}: duplicate subphase id: {subphase_id}"
            )
        seen.add(subphase_id)


def _validate_subphase_dependency_duplicates(phase: PhasePlan) -> None:
    for subphase in phase.subphases:
        _require_no_duplicates(
            tuple(dep.root for dep in subphase.depends_on),
            on_duplicate=(
                f"phase {phase.phase_id.root} subphase {subphase.subphase_id.root}: "
                "duplicate subphase dependency: {value}"
            ),
        )


def _validate_subphase_dependency_known(phase: PhasePlan) -> None:
    known_ids = {subphase.subphase_id.root for subphase in phase.subphases}
    for subphase in phase.subphases:
        for dep in subphase.depends_on:
            if dep.root not in known_ids:
                raise PlanningValidationError(
                    f"phase {phase.phase_id.root} subphase {subphase.subphase_id.root}: "
                    f"unknown subphase dependency: {dep.root}"
                )


def _validate_subphase_dependency_not_self(phase: PhasePlan) -> None:
    for subphase in phase.subphases:
        for dep in subphase.depends_on:
            if dep.root == subphase.subphase_id.root:
                raise PlanningValidationError(
                    f"phase {phase.phase_id.root} subphase {subphase.subphase_id.root}: "
                    "subphase depends on itself"
                )


def _validate_subphase_dependency_order(phase: PhasePlan) -> None:
    earlier_ids: set[str] = set()
    for subphase in phase.subphases:
        for dep in subphase.depends_on:
            if dep.root not in earlier_ids:
                raise PlanningValidationError(
                    f"phase {phase.phase_id.root} subphase {subphase.subphase_id.root}: "
                    f"subphase dependency {dep.root} does not precede subphase "
                    f"{subphase.subphase_id.root}"
                )
        earlier_ids.add(subphase.subphase_id.root)


def _validate_integration_criteria_unique(phase: PhasePlan) -> None:
    _require_no_duplicates(
        tuple(criterion.criterion_id for criterion in phase.integration_acceptance_criteria),
        on_duplicate=(
            f"phase {phase.phase_id.root}: duplicate integration acceptance criterion id: {{value}}"
        ),
    )


def _validate_phase_plan(phase: PhasePlan) -> None:
    _validate_subphase_identity(phase)
    _validate_subphase_dependency_duplicates(phase)
    _validate_subphase_dependency_known(phase)
    _validate_subphase_dependency_not_self(phase)
    _validate_subphase_dependency_order(phase)
    _validate_integration_criteria_unique(phase)


def validate_master_plan(plan: MasterPlan) -> None:
    """Validate identity, dependency, and ordering invariants of *plan*.

    Pure: inspects only *plan*. Raises :class:`PlanningValidationError`
    on the first violation found, in a fixed deterministic category
    order (phase identity and dependency graph, then each Phase's
    nested Sub-phase identity/dependency graph and integration
    criterion identity), so the same malformed plan always yields the
    same first error.
    """
    _validate_phase_identity(plan)
    _validate_phase_dependency_duplicates(plan)
    _validate_phase_dependency_known(plan)
    _validate_phase_dependency_not_self(plan)
    _validate_phase_dependency_order(plan)

    for phase in plan.phases:
        _validate_phase_plan(phase)


def _find_phase(plan: MasterPlan, contract: SubphaseContract) -> PhasePlan:
    for phase in plan.phases:
        if phase.phase_id.root == contract.phase_id.root:
            return phase
    raise PlanningValidationError(
        f"contract phase {contract.phase_id.root} does not exist in master plan"
    )


def _require_subphase_membership(phase: PhasePlan, contract: SubphaseContract) -> None:
    known_ids = {subphase.subphase_id.root for subphase in phase.subphases}
    if contract.subphase_id.root not in known_ids:
        raise PlanningValidationError(
            f"contract subphase {contract.subphase_id.root} does not exist in phase "
            f"{contract.phase_id.root}"
        )


def _validate_contract_criteria_unique(contract: SubphaseContract) -> None:
    _require_no_duplicates(
        tuple(criterion.criterion_id for criterion in contract.acceptance_criteria),
        on_duplicate="duplicate acceptance criterion id: {value}",
    )


def _validate_contract_test_paths_unique(contract: SubphaseContract) -> None:
    _require_no_duplicates(
        tuple(test.path for test in contract.tests),
        on_duplicate="duplicate test path: {value}",
    )


def _validate_contract_test_criteria_known(contract: SubphaseContract) -> None:
    known_criteria = {criterion.criterion_id for criterion in contract.acceptance_criteria}
    for test in contract.tests:
        for reference in test.acceptance_criteria:
            if reference not in known_criteria:
                raise PlanningValidationError(
                    f"test {test.path}: unknown acceptance criterion reference: {reference}"
                )


def _validate_contract_test_criteria_not_duplicated(contract: SubphaseContract) -> None:
    for test in contract.tests:
        _require_no_duplicates(
            test.acceptance_criteria,
            on_duplicate=f"test {test.path}: duplicate acceptance criterion reference: {{value}}",
        )


def validate_subphase_contract(plan: MasterPlan, contract: SubphaseContract) -> None:
    """Validate *contract* against the already-validated *plan*.

    Pure: inspects only *plan* and *contract*. First requires
    :func:`validate_master_plan` to succeed on *plan*, propagating the
    same :class:`PlanningValidationError` rather than masking it.
    Then requires the contract's Phase and Sub-phase to exist and be
    correctly scoped, its acceptance criterion ids to be unique, its
    test paths to be unique, and every test's criterion references to
    resolve within the contract without duplication.
    """
    validate_master_plan(plan)

    phase = _find_phase(plan, contract)
    _require_subphase_membership(phase, contract)

    _validate_contract_criteria_unique(contract)
    _validate_contract_test_paths_unique(contract)
    _validate_contract_test_criteria_known(contract)
    _validate_contract_test_criteria_not_duplicated(contract)


__all__ = [
    "PlanningValidationError",
    "validate_master_plan",
    "validate_subphase_contract",
]
