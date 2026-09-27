import ast
import inspect

import pytest

import lockstep.domain as ls_domain
from lockstep.domain import (
    AcceptanceCriterion,
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    SubphaseContract,
    SubphaseId,
    SubphaseOutline,
    TestExpectation,
)
from lockstep.planning import (
    PlanningValidationError,
    validate_master_plan,
    validate_subphase_contract,
)

# ---------------------------------------------------------------------------
# Construction helpers
# ---------------------------------------------------------------------------


def _phase_id(value: str) -> PhaseId:
    return PhaseId.model_validate(value)


def _subphase_id(value: str) -> SubphaseId:
    return SubphaseId.model_validate(value)


def _criterion(
    criterion_id: str, description: str = "Observable behavior holds."
) -> AcceptanceCriterion:
    return AcceptanceCriterion(criterion_id=criterion_id, description=description)


def _test_spec(
    path: str,
    acceptance_criteria: tuple[str, ...],
    expectation: TestExpectation = TestExpectation.RED,
) -> ls_domain.TestSpecification:
    return ls_domain.TestSpecification(
        path=path,
        expectation=expectation,
        acceptance_criteria=acceptance_criteria,
    )


def _outline(
    subphase_id: str,
    depends_on: tuple[str, ...] = (),
    title: str = "Outline title",
    objective: str = "Outline objective.",
) -> SubphaseOutline:
    return SubphaseOutline(
        subphase_id=_subphase_id(subphase_id),
        title=title,
        objective=objective,
        depends_on=tuple(_subphase_id(d) for d in depends_on),
    )


def _phase(
    phase_id: str,
    subphases: tuple[SubphaseOutline, ...],
    depends_on: tuple[str, ...] = (),
    integration_acceptance_criteria: tuple[AcceptanceCriterion, ...] = (),
    title: str = "Phase title",
    objective: str = "Phase objective.",
) -> PhasePlan:
    return PhasePlan(
        phase_id=_phase_id(phase_id),
        title=title,
        objective=objective,
        depends_on=tuple(_phase_id(d) for d in depends_on),
        subphases=subphases,
        integration_acceptance_criteria=integration_acceptance_criteria,
    )


def _plan(phases: tuple[PhasePlan, ...]) -> MasterPlan:
    return MasterPlan(
        project_id=ProjectId.model_validate("lockstep"),
        title="Lockstep",
        objective="Build the local orchestration control plane.",
        phases=phases,
    )


def _valid_ordered_plan() -> MasterPlan:
    phase_01 = _phase(
        "01",
        subphases=(
            _outline("01"),
            _outline("02", depends_on=("01",)),
        ),
    )
    phase_02 = _phase(
        "02",
        depends_on=("01",),
        subphases=(
            _outline("01"),
            _outline("02", depends_on=("01",)),
        ),
    )
    phase_03 = _phase(
        "03",
        depends_on=("01", "02"),
        subphases=(
            _outline("01"),
            _outline("02", depends_on=("01",)),
            _outline("03", depends_on=("01", "02")),
        ),
    )
    return _plan((phase_01, phase_02, phase_03))


def _valid_independent_plan() -> MasterPlan:
    phase_01 = _phase("01", subphases=(_outline("01"), _outline("02")))
    phase_02 = _phase("02", subphases=(_outline("01"), _outline("02")))
    return _plan((phase_01, phase_02))


def _contract_target_plan() -> MasterPlan:
    return _valid_ordered_plan()


def _build_contract(
    *,
    phase_id: str = "01",
    subphase_id: str = "02",
    title: str = "Refined contract title",
    objective: str = "Refined contract objective.",
    acceptance_criteria: tuple[AcceptanceCriterion, ...] = (_criterion("AC-1"), _criterion("AC-2")),
    tests: tuple[ls_domain.TestSpecification, ...] = (
        _test_spec("tests/test_one.py", ("AC-1",)),
        _test_spec("tests/test_two.py", ("AC-1", "AC-2")),
    ),
) -> SubphaseContract:
    return SubphaseContract(
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        title=title,
        objective=objective,
        acceptance_criteria=acceptance_criteria,
        tests=tests,
        allowed_paths=("src/lockstep/**",),
        verification_commands=("./scripts/check",),
    )


def _valid_contract() -> SubphaseContract:
    return _build_contract()


# ---------------------------------------------------------------------------
# Valid Master Plan acceptance (Sections 33-34)
# ---------------------------------------------------------------------------


def test_valid_dependency_ordered_master_plan_is_accepted() -> None:
    assert validate_master_plan(_valid_ordered_plan()) is None


def test_master_plan_with_independent_phases_and_subphases_is_valid() -> None:
    assert validate_master_plan(_valid_independent_plan()) is None


# ---------------------------------------------------------------------------
# Phase identity/dependency failures (Section 35)
# ---------------------------------------------------------------------------


def test_duplicate_phase_id_is_rejected() -> None:
    phase_01a = _phase("01", subphases=(_outline("01"),))
    phase_01b = _phase("01", subphases=(_outline("01"),))
    plan = _plan((phase_01a, phase_01b))

    with pytest.raises(PlanningValidationError):
        validate_master_plan(plan)


def test_unknown_phase_dependency_is_rejected() -> None:
    phase_01 = _phase("01", depends_on=("99",), subphases=(_outline("01"),))
    plan = _plan((phase_01,))

    with pytest.raises(PlanningValidationError):
        validate_master_plan(plan)


def test_self_phase_dependency_is_rejected() -> None:
    phase_01 = _phase("01", depends_on=("01",), subphases=(_outline("01"),))
    plan = _plan((phase_01,))

    with pytest.raises(PlanningValidationError):
        validate_master_plan(plan)


def test_future_phase_dependency_is_rejected() -> None:
    phase_01 = _phase("01", depends_on=("02",), subphases=(_outline("01"),))
    phase_02 = _phase("02", subphases=(_outline("01"),))
    plan = _plan((phase_01, phase_02))

    with pytest.raises(PlanningValidationError):
        validate_master_plan(plan)


def test_duplicate_phase_dependency_reference_is_rejected() -> None:
    phase_01 = _phase("01", subphases=(_outline("01"),))
    phase_02 = _phase("02", depends_on=("01", "01"), subphases=(_outline("01"),))
    plan = _plan((phase_01, phase_02))

    with pytest.raises(PlanningValidationError):
        validate_master_plan(plan)


# ---------------------------------------------------------------------------
# Sub-phase identity/dependency failures (Section 36)
# ---------------------------------------------------------------------------


def test_duplicate_subphase_id_is_rejected() -> None:
    phase_01 = _phase("01", subphases=(_outline("01"), _outline("01")))
    plan = _plan((phase_01,))

    with pytest.raises(PlanningValidationError):
        validate_master_plan(plan)


def test_unknown_subphase_dependency_is_rejected() -> None:
    phase_01 = _phase("01", subphases=(_outline("01", depends_on=("99",)),))
    plan = _plan((phase_01,))

    with pytest.raises(PlanningValidationError):
        validate_master_plan(plan)


def test_self_subphase_dependency_is_rejected() -> None:
    phase_01 = _phase("01", subphases=(_outline("01", depends_on=("01",)),))
    plan = _plan((phase_01,))

    with pytest.raises(PlanningValidationError):
        validate_master_plan(plan)


def test_future_subphase_dependency_is_rejected() -> None:
    phase_01 = _phase(
        "01",
        subphases=(
            _outline("01", depends_on=("02",)),
            _outline("02"),
        ),
    )
    plan = _plan((phase_01,))

    with pytest.raises(PlanningValidationError):
        validate_master_plan(plan)


def test_duplicate_subphase_dependency_reference_is_rejected() -> None:
    phase_01 = _phase(
        "01",
        subphases=(
            _outline("01"),
            _outline("02", depends_on=("01", "01")),
        ),
    )
    plan = _plan((phase_01,))

    with pytest.raises(PlanningValidationError):
        validate_master_plan(plan)


def test_subphase_dependency_from_another_phase_does_not_resolve() -> None:
    phase_01 = _phase("01", subphases=(_outline("01"),))
    phase_02 = _phase(
        "02",
        depends_on=("01",),
        subphases=(_outline("02", depends_on=("01",)),),
    )
    plan = _plan((phase_01, phase_02))

    with pytest.raises(PlanningValidationError):
        validate_master_plan(plan)


# ---------------------------------------------------------------------------
# Phase integration acceptance criterion uniqueness (Section 37)
# ---------------------------------------------------------------------------


def test_duplicate_phase_integration_criterion_id_is_rejected() -> None:
    phase_01 = _phase(
        "01",
        subphases=(_outline("01"),),
        integration_acceptance_criteria=(_criterion("AC-1"), _criterion("AC-1")),
    )
    plan = _plan((phase_01,))

    with pytest.raises(PlanningValidationError):
        validate_master_plan(plan)


def test_duplicate_integration_criterion_id_across_phases_remains_legal() -> None:
    phase_01 = _phase(
        "01",
        subphases=(_outline("01"),),
        integration_acceptance_criteria=(_criterion("AC-1"),),
    )
    phase_02 = _phase(
        "02",
        subphases=(_outline("01"),),
        integration_acceptance_criteria=(_criterion("AC-1"),),
    )
    plan = _plan((phase_01, phase_02))

    assert validate_master_plan(plan) is None


# ---------------------------------------------------------------------------
# Contract validation (Sections 38-43)
# ---------------------------------------------------------------------------


def test_valid_contract_is_accepted() -> None:
    plan = _contract_target_plan()
    contract = _valid_contract()

    assert validate_subphase_contract(plan, contract) is None


def test_contract_with_unknown_phase_is_rejected() -> None:
    plan = _contract_target_plan()
    contract = _build_contract(phase_id="99")

    with pytest.raises(PlanningValidationError):
        validate_subphase_contract(plan, contract)


def test_contract_with_unknown_subphase_in_known_phase_is_rejected() -> None:
    plan = _contract_target_plan()
    contract = _build_contract(subphase_id="99")

    with pytest.raises(PlanningValidationError):
        validate_subphase_contract(plan, contract)


def test_contract_subphase_id_from_another_phase_does_not_resolve() -> None:
    plan = _contract_target_plan()
    # Subphase "03" only exists under phase "03", not phase "01".
    contract = _build_contract(phase_id="01", subphase_id="03")

    with pytest.raises(PlanningValidationError):
        validate_subphase_contract(plan, contract)


def test_contract_requires_valid_master_plan_first() -> None:
    phase_01a = _phase("01", subphases=(_outline("01"),))
    phase_01b = _phase("01", subphases=(_outline("01"),))
    invalid_plan = _plan((phase_01a, phase_01b))
    contract = _build_contract(phase_id="01", subphase_id="01")

    with pytest.raises(PlanningValidationError) as direct:
        validate_master_plan(invalid_plan)
    with pytest.raises(PlanningValidationError) as via_contract:
        validate_subphase_contract(invalid_plan, contract)

    assert via_contract.value.reason == direct.value.reason


def test_duplicate_contract_acceptance_criterion_id_is_rejected() -> None:
    plan = _contract_target_plan()
    contract = _build_contract(
        acceptance_criteria=(_criterion("AC-1"), _criterion("AC-1")),
        tests=(_test_spec("tests/test_one.py", ("AC-1",)),),
    )

    with pytest.raises(PlanningValidationError):
        validate_subphase_contract(plan, contract)


def test_duplicate_test_specification_path_is_rejected() -> None:
    plan = _contract_target_plan()
    test_one = _test_spec("tests/test_shared.py", ("AC-1",))
    test_two = _test_spec("tests/test_shared.py", ("AC-2",))
    contract = _build_contract(tests=(test_one, test_two))

    with pytest.raises(PlanningValidationError):
        validate_subphase_contract(plan, contract)

    assert test_one.path == "tests/test_shared.py"
    assert test_two.path == "tests/test_shared.py"
    assert test_one.acceptance_criteria == ("AC-1",)
    assert test_two.acceptance_criteria == ("AC-2",)


def test_unknown_test_criterion_reference_is_rejected() -> None:
    plan = _contract_target_plan()
    contract = _build_contract(
        acceptance_criteria=(_criterion("AC-1"),),
        tests=(_test_spec("tests/test_one.py", ("AC-1", "AC-99")),),
    )

    with pytest.raises(PlanningValidationError):
        validate_subphase_contract(plan, contract)


def test_duplicate_criterion_reference_inside_one_test_is_rejected() -> None:
    plan = _contract_target_plan()
    contract = _build_contract(
        acceptance_criteria=(_criterion("AC-1"),),
        tests=(_test_spec("tests/test_one.py", ("AC-1", "AC-1")),),
    )

    with pytest.raises(PlanningValidationError):
        validate_subphase_contract(plan, contract)


def test_partial_criterion_test_coverage_remains_legal() -> None:
    plan = _contract_target_plan()
    contract = _build_contract(
        acceptance_criteria=(_criterion("AC-1"), _criterion("AC-2")),
        tests=(_test_spec("tests/test_one.py", ("AC-1",)),),
    )

    assert validate_subphase_contract(plan, contract) is None


def test_contract_prose_may_diverge_from_provisional_outline_text() -> None:
    plan = _contract_target_plan()
    outline = plan.phases[0].subphases[1]
    contract = _build_contract(
        phase_id="01",
        subphase_id="02",
        title="A completely different, refined title",
        objective="A completely different, refined objective.",
    )

    assert outline.subphase_id == contract.subphase_id
    assert outline.title != contract.title
    assert outline.objective != contract.objective
    assert validate_subphase_contract(plan, contract) is None


# ---------------------------------------------------------------------------
# Deterministic first-error ordering (Section 44)
# ---------------------------------------------------------------------------


def test_first_error_is_deterministic_then_reveals_next_category_once_fixed() -> None:
    phase_01a = _phase("01", depends_on=("99",), subphases=(_outline("01"),))
    phase_01b = _phase("01", depends_on=("99",), subphases=(_outline("01"),))
    malformed_plan = _plan((phase_01a, phase_01b))

    with pytest.raises(PlanningValidationError) as first_attempt:
        validate_master_plan(malformed_plan)
    with pytest.raises(PlanningValidationError) as second_attempt:
        validate_master_plan(malformed_plan)

    assert first_attempt.value.reason == second_attempt.value.reason

    corrected_phase_01 = _phase("01", depends_on=("99",), subphases=(_outline("01"),))
    corrected_plan = _plan((corrected_phase_01,))

    with pytest.raises(PlanningValidationError) as after_fix:
        validate_master_plan(corrected_plan)

    assert after_fix.value.reason != first_attempt.value.reason


# ---------------------------------------------------------------------------
# PlanningValidationError shape (Sections 5, 7)
# ---------------------------------------------------------------------------


def test_planning_validation_error_reason_is_bounded_and_reusable() -> None:
    phase_01 = _phase("01", subphases=(_outline("01"),))
    phase_01_dup = _phase("01", subphases=(_outline("01"),))
    plan = _plan((phase_01, phase_01_dup))

    with pytest.raises(PlanningValidationError) as excinfo:
        validate_master_plan(plan)

    reason = excinfo.value.reason
    assert isinstance(reason, str)
    assert reason
    assert len(reason) <= 200
    assert "{" not in reason
    assert "\n" not in reason


# ---------------------------------------------------------------------------
# Purity (Sections 6, 8, 9)
# ---------------------------------------------------------------------------


def test_validate_master_plan_is_pure_and_returns_none_on_success() -> None:
    plan = _valid_ordered_plan()
    before = plan.model_dump(mode="json")

    result_one = validate_master_plan(plan)
    result_two = validate_master_plan(plan)

    assert result_one is None
    assert result_two is None
    assert plan.model_dump(mode="json") == before


def test_validate_subphase_contract_is_pure_and_returns_none_on_success() -> None:
    plan = _contract_target_plan()
    contract = _valid_contract()
    before_plan = plan.model_dump(mode="json")
    before_contract = contract.model_dump(mode="json")

    result_one = validate_subphase_contract(plan, contract)
    result_two = validate_subphase_contract(plan, contract)

    assert result_one is None
    assert result_two is None
    assert plan.model_dump(mode="json") == before_plan
    assert contract.model_dump(mode="json") == before_contract


# ---------------------------------------------------------------------------
# Purity / dependency audit (Section 45)
# ---------------------------------------------------------------------------

_FORBIDDEN_PLANNING_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.agents",
    "lockstep.runtime",
    "lockstep.config",
    "lockstep.git",
    "lockstep.process",
    "lockstep.persistence",
    "lockstep.state",
    "lockstep.supervisor",
    "lockstep.verification",
    "lockstep.reporting",
    "lockstep.cli",
    "subprocess",
    "os",
)


def _imported_module_names(tree: ast.Module) -> set[str]:
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.name)
        elif isinstance(node, ast.ImportFrom) and node.module:
            names.add(node.module)
    return names


def test_planning_module_imports_only_domain_and_stdlib() -> None:
    import lockstep.planning as planning_module

    source = inspect.getsource(planning_module)
    tree = ast.parse(source)

    imported = _imported_module_names(tree)

    for module in imported:
        if module == "lockstep" or module.startswith("lockstep."):
            assert module == "lockstep.domain" or module.startswith("lockstep.domain.")
        for forbidden in _FORBIDDEN_PLANNING_MODULE_PREFIXES:
            assert module != forbidden
            assert not module.startswith(forbidden + ".")


def test_planning_module_has_no_import_time_side_effects() -> None:
    import lockstep.planning as planning_module

    source = inspect.getsource(planning_module)
    tree = ast.parse(source)

    allowed_node_types = (
        ast.Import,
        ast.ImportFrom,
        ast.FunctionDef,
        ast.AsyncFunctionDef,
        ast.ClassDef,
        ast.Assign,
        ast.AnnAssign,
        ast.Expr,
    )
    for node in tree.body:
        assert isinstance(node, allowed_node_types)
        if isinstance(node, ast.Expr):
            assert isinstance(node.value, ast.Constant)
