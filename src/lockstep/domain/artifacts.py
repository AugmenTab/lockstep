"""Canonical Lockstep protocol artifacts.

Immutable, versioned Pydantic v2 value objects passed between the human,
Planner, Implementer, verifier, reviewer, and (later) Scribe. All models
are frozen, reject unknown fields, and preserve required text verbatim.
Repeated fields are Python tuples so canonical artifacts remain values
rather than mutable bags of state.

Each independently persistable top-level artifact carries a
``schema_version: SchemaVersion`` that currently accepts only ``1``.
``SchemaVersion`` itself describes a valid version number; each concrete
artifact model describes which schema version it presently understands.

Nothing here executes work: these types describe future work and its
evidence. Deterministic cross-artifact validation (dependency graphs,
duplicate identifiers, path containment, glob semantics, resolvable test
references, scope enforcement) is intentionally deferred to later
planning, Git, and verification layers.
"""

from typing import Annotated, Self

from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    Field,
    field_validator,
    model_validator,
)

from lockstep.domain.enums import ReviewVerdict, TestExpectation
from lockstep.domain.identifiers import (
    AttemptNumber,
    PhaseId,
    ProjectId,
    SchemaVersion,
    SubphaseId,
)

_CURRENT_SCHEMA_VERSION: SchemaVersion = SchemaVersion.model_validate(1)


def _reject_blank(value: str) -> str:
    if not value.strip():
        raise ValueError("must not be empty or whitespace-only")
    return value


_NonBlankStr = Annotated[str, AfterValidator(_reject_blank)]


class _ArtifactModel(BaseModel):
    """Base for every canonical protocol artifact: frozen, strict schema."""

    model_config = ConfigDict(frozen=True, extra="forbid")


class _VersionedArtifact(_ArtifactModel):
    """Base for independently persistable, schema-versioned artifacts."""

    schema_version: SchemaVersion = _CURRENT_SCHEMA_VERSION

    @field_validator("schema_version")
    @classmethod
    def _reject_unsupported_schema_version(cls, value: SchemaVersion) -> SchemaVersion:
        if value.root != _CURRENT_SCHEMA_VERSION.root:
            raise ValueError(
                f"unsupported schema_version {value.root}; "
                f"this artifact only understands schema_version "
                f"{_CURRENT_SCHEMA_VERSION.root}"
            )
        return value


# --- Planning artifacts --------------------------------------------------


class AcceptanceCriterion(_ArtifactModel):
    criterion_id: _NonBlankStr
    description: _NonBlankStr


class TestSpecification(_ArtifactModel):
    path: _NonBlankStr
    expectation: TestExpectation
    acceptance_criteria: Annotated[tuple[_NonBlankStr, ...], Field(min_length=1)]


class SubphaseOutline(_ArtifactModel):
    subphase_id: SubphaseId
    title: _NonBlankStr
    objective: _NonBlankStr
    depends_on: tuple[SubphaseId, ...] = ()


class SubphaseContract(_VersionedArtifact):
    phase_id: PhaseId
    subphase_id: SubphaseId
    title: _NonBlankStr
    objective: _NonBlankStr
    acceptance_criteria: Annotated[tuple[AcceptanceCriterion, ...], Field(min_length=1)]
    tests: Annotated[tuple[TestSpecification, ...], Field(min_length=1)]
    allowed_paths: Annotated[tuple[_NonBlankStr, ...], Field(min_length=1)]
    protected_paths: tuple[_NonBlankStr, ...] = ()
    forbidden_paths: tuple[_NonBlankStr, ...] = ()
    verification_commands: Annotated[tuple[_NonBlankStr, ...], Field(min_length=1)]


class PhasePlan(_VersionedArtifact):
    phase_id: PhaseId
    title: _NonBlankStr
    objective: _NonBlankStr
    depends_on: tuple[PhaseId, ...] = ()
    subphases: Annotated[tuple[SubphaseOutline, ...], Field(min_length=1)]
    integration_acceptance_criteria: tuple[AcceptanceCriterion, ...] = ()


class MasterPlan(_VersionedArtifact):
    project_id: ProjectId
    title: _NonBlankStr
    objective: _NonBlankStr
    phases: Annotated[tuple[PhasePlan, ...], Field(min_length=1)]


# --- Execution and reporting artifacts -----------------------------------


class ImplementationReport(_VersionedArtifact):
    phase_id: PhaseId
    subphase_id: SubphaseId
    attempt: AttemptNumber
    summary: _NonBlankStr
    changed_files: tuple[_NonBlankStr, ...] = ()
    decisions: tuple[_NonBlankStr, ...] = ()
    deviations: tuple[_NonBlankStr, ...] = ()
    concerns: tuple[_NonBlankStr, ...] = ()


class VerificationFinding(_ArtifactModel):
    criterion_id: _NonBlankStr | None = None
    observation: _NonBlankStr
    expected: _NonBlankStr
    reproduction: _NonBlankStr


class VerificationReport(_VersionedArtifact):
    phase_id: PhaseId
    subphase_id: SubphaseId
    attempt: AttemptNumber
    passed: bool
    commands: tuple[_NonBlankStr, ...] = ()
    failures: tuple[VerificationFinding, ...] = ()

    @model_validator(mode="after")
    def _enforce_failure_evidence_consistency(self) -> Self:
        if self.passed and self.failures:
            raise ValueError("a passing VerificationReport must not contain failure evidence")
        if not self.passed and not self.failures:
            raise ValueError("a failing VerificationReport must contain at least one failure")
        return self


class ReviewFinding(_ArtifactModel):
    summary: _NonBlankStr
    evidence: _NonBlankStr
    file_path: _NonBlankStr | None = None
    acceptance_criterion_id: _NonBlankStr | None = None


class ReviewDecision(_VersionedArtifact):
    phase_id: PhaseId
    subphase_id: SubphaseId
    attempt: AttemptNumber
    verdict: ReviewVerdict
    summary: _NonBlankStr
    findings: tuple[ReviewFinding, ...] = ()


class ContextImprovementCandidate(_VersionedArtifact):
    scope: _NonBlankStr
    reason: _NonBlankStr
    evidence: Annotated[tuple[_NonBlankStr, ...], Field(min_length=1)]
    recommended_artifact: _NonBlankStr
    suggested_contents: _NonBlankStr
