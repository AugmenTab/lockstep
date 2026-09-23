import pytest
from pydantic import ValidationError

from lockstep.domain import (
    AttemptNumber,
    ContextImprovementCandidate,
    ImplementationReport,
    PhaseId,
    ReviewDecision,
    ReviewFinding,
    ReviewVerdict,
    SubphaseId,
    VerificationFinding,
    VerificationReport,
)


def _implementation_report() -> ImplementationReport:
    return ImplementationReport(
        phase_id=PhaseId.model_validate("01"),
        subphase_id=SubphaseId.model_validate("02"),
        attempt=AttemptNumber.model_validate(1),
        summary="Implemented the bounded change.",
        changed_files=("src/lockstep/domain/artifacts.py",),
        decisions=("Used immutable tuples for repeated fields.",),
    )


def _verification_finding() -> VerificationFinding:
    return VerificationFinding(
        criterion_id="AC-1",
        observation="The command exited with status 1.",
        expected="The command exits with status 0.",
        reproduction="./scripts/check",
    )


def test_implementation_report_round_trips_through_json() -> None:
    report = _implementation_report()

    restored = ImplementationReport.model_validate_json(report.model_dump_json())

    assert restored == report
    dumped = report.model_dump(mode="json")
    assert dumped["schema_version"] == 1
    assert dumped["attempt"] == 1
    assert dumped["changed_files"] == ["src/lockstep/domain/artifacts.py"]


def test_verification_report_requires_failure_evidence_when_failed() -> None:
    with pytest.raises(ValidationError):
        VerificationReport(
            phase_id=PhaseId.model_validate("01"),
            subphase_id=SubphaseId.model_validate("02"),
            attempt=AttemptNumber.model_validate(1),
            passed=False,
        )


def test_verification_report_rejects_failure_evidence_when_passed() -> None:
    with pytest.raises(ValidationError):
        VerificationReport(
            phase_id=PhaseId.model_validate("01"),
            subphase_id=SubphaseId.model_validate("02"),
            attempt=AttemptNumber.model_validate(1),
            passed=True,
            failures=(_verification_finding(),),
        )


def test_failed_verification_report_round_trips_through_json() -> None:
    report = VerificationReport(
        phase_id=PhaseId.model_validate("01"),
        subphase_id=SubphaseId.model_validate("02"),
        attempt=AttemptNumber.model_validate(1),
        passed=False,
        commands=("./scripts/check",),
        failures=(_verification_finding(),),
    )

    restored = VerificationReport.model_validate_json(report.model_dump_json())

    assert restored == report
    dumped = report.model_dump(mode="json")
    assert dumped["failures"][0] == {
        "criterion_id": "AC-1",
        "observation": "The command exited with status 1.",
        "expected": "The command exits with status 0.",
        "reproduction": "./scripts/check",
    }


def test_review_decision_round_trips_through_json() -> None:
    decision = ReviewDecision(
        phase_id=PhaseId.model_validate("01"),
        subphase_id=SubphaseId.model_validate("02"),
        attempt=AttemptNumber.model_validate(1),
        verdict=ReviewVerdict.REWORK,
        summary="One contract mismatch remains.",
        findings=(
            ReviewFinding(
                summary="Required path was not updated.",
                evidence="git diff shows no change to the required module.",
                file_path="src/lockstep/domain/artifacts.py",
                acceptance_criterion_id="AC-1",
            ),
        ),
    )

    restored = ReviewDecision.model_validate_json(decision.model_dump_json())

    assert restored == decision
    assert decision.model_dump(mode="json")["verdict"] == "rework"


def test_context_improvement_candidate_round_trips_through_json() -> None:
    candidate = ContextImprovementCandidate(
        scope="src/lockstep/domain",
        reason="The same domain convention was rediscovered repeatedly.",
        evidence=(
            "The planner inspected the same package boundary in three subphases.",
            "Two reviews repeated the same import-direction correction.",
        ),
        recommended_artifact="src/lockstep/domain/AGENTS.md",
        suggested_contents="Document the domain dependency boundary.",
    )

    restored = ContextImprovementCandidate.model_validate_json(candidate.model_dump_json())

    assert restored == candidate
    assert candidate.model_dump(mode="json")["schema_version"] == 1


@pytest.mark.parametrize(
    "artifact",
    [
        _implementation_report(),
        VerificationReport(
            phase_id=PhaseId.model_validate("01"),
            subphase_id=SubphaseId.model_validate("02"),
            attempt=AttemptNumber.model_validate(1),
            passed=True,
        ),
        ReviewDecision(
            phase_id=PhaseId.model_validate("01"),
            subphase_id=SubphaseId.model_validate("02"),
            attempt=AttemptNumber.model_validate(1),
            verdict=ReviewVerdict.APPROVE,
            summary="Contract satisfied.",
        ),
        ContextImprovementCandidate(
            scope="src/lockstep/domain",
            reason="Repeated rediscovery.",
            evidence=("The same rule was explained twice.",),
            recommended_artifact="src/lockstep/domain/AGENTS.md",
            suggested_contents="Document the rule.",
        ),
    ],
)
def test_versioned_execution_artifact_rejects_wrong_schema_version(artifact: object) -> None:
    data = artifact.model_dump(mode="json")  # type: ignore[attr-defined]
    data["schema_version"] = 2

    with pytest.raises(ValidationError):
        type(artifact).model_validate(data)  # type: ignore[attr-defined]


def test_versioned_execution_artifact_rejects_unknown_fields() -> None:
    data = _implementation_report().model_dump(mode="json")
    data["unexpected"] = True

    with pytest.raises(ValidationError):
        ImplementationReport.model_validate(data)


def test_execution_artifacts_are_immutable() -> None:
    report = _implementation_report()

    with pytest.raises(ValidationError):
        report.summary = "Changed"  # type: ignore[misc]


def test_context_improvement_candidate_requires_evidence() -> None:
    with pytest.raises(ValidationError):
        ContextImprovementCandidate(
            scope="src/lockstep/domain",
            reason="Repeated rediscovery.",
            evidence=(),
            recommended_artifact="src/lockstep/domain/AGENTS.md",
            suggested_contents="Document the rule.",
        )
