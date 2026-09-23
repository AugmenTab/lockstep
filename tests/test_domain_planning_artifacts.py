import pytest
from pydantic import ValidationError

from lockstep.domain import (
    AcceptanceCriterion,
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    SchemaVersion,
    SubphaseContract,
    SubphaseId,
    SubphaseOutline,
    TestExpectation,
    TestSpecification as DomainTestSpecification,
)


def _criterion() -> AcceptanceCriterion:
    return AcceptanceCriterion(
        criterion_id="AC-1",
        description="The required behavior is observable.",
    )


def _test_specification() -> DomainTestSpecification:
    return DomainTestSpecification(
        path="tests/test_feature.py",
        expectation=TestExpectation.RED,
        acceptance_criteria=("AC-1",),
    )


def _contract() -> SubphaseContract:
    return SubphaseContract(
        phase_id=PhaseId.model_validate("01"),
        subphase_id=SubphaseId.model_validate("02"),
        title="Canonical artifacts",
        objective="Define the persisted planning contract.",
        acceptance_criteria=(_criterion(),),
        tests=(_test_specification(),),
        allowed_paths=("src/lockstep/domain/**",),
        protected_paths=("tests/test_feature.py",),
        forbidden_paths=(".env",),
        verification_commands=("./scripts/check",),
    )


def test_subphase_contract_round_trips_through_json() -> None:
    contract = _contract()

    restored = SubphaseContract.model_validate_json(contract.model_dump_json())

    assert restored == contract
    assert contract.model_dump(mode="json")["schema_version"] == 1
    assert contract.model_dump(mode="json")["phase_id"] == "01"
    assert contract.model_dump(mode="json")["subphase_id"] == "02"


def test_phase_and_master_plan_round_trip_through_json() -> None:
    outline = SubphaseOutline(
        subphase_id=SubphaseId.model_validate("01"),
        title="Vocabulary",
        objective="Define stable protocol vocabulary.",
    )
    phase = PhasePlan(
        phase_id=PhaseId.model_validate("01"),
        title="Protocol kernel",
        objective="Build deterministic foundations.",
        subphases=(outline,),
        integration_acceptance_criteria=(_criterion(),),
    )
    plan = MasterPlan(
        project_id=ProjectId.model_validate("lockstep"),
        title="Lockstep",
        objective="Build the local orchestration control plane.",
        phases=(phase,),
    )

    restored = MasterPlan.model_validate_json(plan.model_dump_json())

    assert restored == plan
    dumped = plan.model_dump(mode="json")
    assert dumped["schema_version"] == 1
    assert dumped["project_id"] == "lockstep"
    assert dumped["phases"][0]["phase_id"] == "01"
    assert dumped["phases"][0]["subphases"][0]["subphase_id"] == "01"


@pytest.mark.parametrize(
    "artifact",
    [
        _contract(),
        PhasePlan(
            phase_id=PhaseId.model_validate("01"),
            title="Protocol kernel",
            objective="Build deterministic foundations.",
            subphases=(
                SubphaseOutline(
                    subphase_id=SubphaseId.model_validate("01"),
                    title="Vocabulary",
                    objective="Define stable protocol vocabulary.",
                ),
            ),
        ),
        MasterPlan(
            project_id=ProjectId.model_validate("lockstep"),
            title="Lockstep",
            objective="Build the local orchestration control plane.",
            phases=(
                PhasePlan(
                    phase_id=PhaseId.model_validate("01"),
                    title="Protocol kernel",
                    objective="Build deterministic foundations.",
                    subphases=(
                        SubphaseOutline(
                            subphase_id=SubphaseId.model_validate("01"),
                            title="Vocabulary",
                            objective="Define stable protocol vocabulary.",
                        ),
                    ),
                ),
            ),
        ),
    ],
)
def test_versioned_planning_artifact_rejects_wrong_schema_version(artifact: object) -> None:
    data = artifact.model_dump(mode="json")  # type: ignore[attr-defined]
    data["schema_version"] = 2

    with pytest.raises(ValidationError):
        type(artifact).model_validate(data)  # type: ignore[attr-defined]


def test_versioned_planning_artifact_rejects_unknown_fields() -> None:
    data = _contract().model_dump(mode="json")
    data["unexpected"] = True

    with pytest.raises(ValidationError):
        SubphaseContract.model_validate(data)


def test_planning_artifacts_are_immutable() -> None:
    contract = _contract()

    with pytest.raises(ValidationError):
        contract.title = "Changed"  # type: ignore[misc]


def test_schema_version_type_is_preserved_in_python() -> None:
    contract = _contract()

    assert contract.schema_version == SchemaVersion.model_validate(1)


def test_contract_requires_acceptance_criteria_and_tests() -> None:
    data = _contract().model_dump(mode="json")

    data["acceptance_criteria"] = []
    with pytest.raises(ValidationError):
        SubphaseContract.model_validate(data)

    data = _contract().model_dump(mode="json")
    data["tests"] = []
    with pytest.raises(ValidationError):
        SubphaseContract.model_validate(data)


def test_test_specification_requires_acceptance_criterion_reference() -> None:
    with pytest.raises(ValidationError):
        DomainTestSpecification(
            path="tests/test_feature.py",
            expectation=TestExpectation.RED,
            acceptance_criteria=(),
        )


def test_phase_and_master_plan_require_children() -> None:
    with pytest.raises(ValidationError):
        PhasePlan(
            phase_id=PhaseId.model_validate("01"),
            title="Protocol kernel",
            objective="Build deterministic foundations.",
            subphases=(),
        )

    with pytest.raises(ValidationError):
        MasterPlan(
            project_id=ProjectId.model_validate("lockstep"),
            title="Lockstep",
            objective="Build the local orchestration control plane.",
            phases=(),
        )
