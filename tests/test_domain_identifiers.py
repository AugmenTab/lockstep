import pytest
from pydantic import ValidationError

from lockstep.domain import (
    AttemptNumber,
    PhaseId,
    ProjectId,
    RunId,
    SchemaVersion,
    SubphaseId,
)


@pytest.mark.parametrize(
    ("identifier_type", "value"),
    [
        (ProjectId, "lockstep"),
        (ProjectId, "lockstep.dev"),
        (ProjectId, "lockstep_dev"),
        (ProjectId, "lockstep-dev"),
        (RunId, "20260923-001"),
        (RunId, "run_001"),
        (PhaseId, "01"),
        (PhaseId, "99"),
        (PhaseId, "100"),
        (SubphaseId, "01"),
        (SubphaseId, "12"),
        (SubphaseId, "100"),
    ],
)
def test_string_identifier_round_trips_as_json_scalar(
    identifier_type: type[ProjectId | RunId | PhaseId | SubphaseId],
    value: str,
) -> None:
    identifier = identifier_type.model_validate(value)

    assert identifier.root == value
    assert identifier.model_dump(mode="json") == value


@pytest.mark.parametrize(
    ("identifier_type", "value"),
    [
        (ProjectId, ""),
        (ProjectId, " "),
        (ProjectId, "contains space"),
        (ProjectId, "/lockstep"),
        (ProjectId, "lockstep/project"),
        (RunId, ""),
        (RunId, "run with spaces"),
        (RunId, "run/001"),
        (PhaseId, "1"),
        (PhaseId, "-1"),
        (PhaseId, "phase-01"),
        (SubphaseId, "1"),
        (SubphaseId, "-1"),
        (SubphaseId, "subphase-01"),
    ],
)
def test_invalid_string_identifier_is_rejected(
    identifier_type: type[ProjectId | RunId | PhaseId | SubphaseId],
    value: str,
) -> None:
    with pytest.raises(ValidationError):
        identifier_type.model_validate(value)


@pytest.mark.parametrize(
    ("number_type", "value"),
    [
        (AttemptNumber, 1),
        (AttemptNumber, 2),
        (SchemaVersion, 1),
        (SchemaVersion, 2),
    ],
)
def test_positive_integer_primitive_round_trips_as_json_scalar(
    number_type: type[AttemptNumber | SchemaVersion],
    value: int,
) -> None:
    number = number_type.model_validate(value)

    assert number.root == value
    assert number.model_dump(mode="json") == value


@pytest.mark.parametrize(
    ("number_type", "value"),
    [
        (AttemptNumber, 0),
        (AttemptNumber, -1),
        (AttemptNumber, True),
        (AttemptNumber, "1"),
        (SchemaVersion, 0),
        (SchemaVersion, -1),
        (SchemaVersion, True),
        (SchemaVersion, "1"),
    ],
)
def test_invalid_positive_integer_primitive_is_rejected(
    number_type: type[AttemptNumber | SchemaVersion],
    value: object,
) -> None:
    with pytest.raises(ValidationError):
        number_type.model_validate(value)


@pytest.mark.parametrize(
    ("identifier", "replacement"),
    [
        (ProjectId.model_validate("lockstep"), "changed"),
        (RunId.model_validate("20260923-001"), "changed"),
        (PhaseId.model_validate("01"), "02"),
        (SubphaseId.model_validate("01"), "02"),
        (AttemptNumber.model_validate(1), 2),
        (SchemaVersion.model_validate(1), 2),
    ],
)
def test_domain_primitives_are_immutable(
    identifier: ProjectId | RunId | PhaseId | SubphaseId | AttemptNumber | SchemaVersion,
    replacement: str | int,
) -> None:
    with pytest.raises(ValidationError):
        identifier.root = replacement  # type: ignore[misc]
