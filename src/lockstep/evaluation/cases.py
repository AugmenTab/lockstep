"""Structured evaluation cases, explicit policy arms, finite suites and their trials.

A case says what can be *observed*: a deterministic fixture (repository files, the frozen
Master Plan that is the task, the tracked execution policy), the run disposition the task
should end in, the graders that read the evidence, and finite run bounds. It holds no
prose expectation only a human could judge.

An arm names exactly one agent-facing input that differs between comparison arms
(:class:`PolicySurface`) and the exact value it takes, with its provenance. Everything
else about a trial (case, fixture, provider selection, graders, bounds) is identical
across the arms of one comparison, by construction: :func:`expand_trials` crosses one
suite's cases, arms and repetitions under one provider selection.

Identity is semantic and deterministic: a digest over the canonical JSON of the
normalized model (fixture files and graders are sorted, so construction order never
matters). No wall-clock value is part of any identity.
"""

from __future__ import annotations

import hashlib
import json
from enum import StrEnum
from typing import Annotated

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    ValidationInfo,
    field_validator,
)

from lockstep.agents.routing import AgentRoutingPolicy
from lockstep.domain import MasterPlan
from lockstep.evaluation.graders import EvalGrader, EvalId, RelativePath
from lockstep.execution_config import ExecutionConfig
from lockstep.project_orchestrator import ProjectRunDisposition

# Every suite is finite. These ceilings bound one development/qualification suite; they are
# not a statistics budget, and nothing here repeats, retries or expands until some result.
MAX_CASES = 32
MAX_ARMS = 4
MAX_REPEATS = 20
MAX_TRIALS = 256
MAX_ATTEMPTS = 5
MAX_PLANNING_TIMEOUT_SECONDS = 3600.0

# Files the harness itself writes into every fixture repository from the case and the
# provider selection; a case cannot also supply them.
_HARNESS_OWNED_PREFIXES = ("lockstep.toml", ".lockstep/", ".git/")

_NonBlank = Annotated[str, StringConstraints(min_length=1, pattern=r"\S")]


class _Model(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    @property
    def digest(self) -> str:
        """SHA-256 of the canonical JSON of this (normalized) model."""
        return canonical_digest(self)


def canonical_digest(model: BaseModel) -> str:
    text = json.dumps(
        model.model_dump(mode="json"), sort_keys=True, separators=(",", ":"), ensure_ascii=False
    )
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class EvalFixture(_Model):
    """The deterministic starting state every trial of a case materializes afresh.

    ``files`` are exact repository-relative paths and their UTF-8 content. The harness adds
    the tracked ``lockstep.toml`` (routing from the provider selection, ``execution`` from
    here) and freezes ``master_plan`` -- the task -- before the single fixture commit.
    """

    files: dict[RelativePath, str]
    master_plan: MasterPlan
    execution: ExecutionConfig

    @field_validator("files")
    @classmethod
    def _normalize_files(cls, files: dict[str, str]) -> dict[str, str]:
        for path in files:
            if any(path == p.rstrip("/") or path.startswith(p) for p in _HARNESS_OWNED_PREFIXES):
                raise ValueError(f"fixture file {path!r} is written by the harness")
        return dict(sorted(files.items()))


class EvalBounds(_Model):
    """Finite run bounds, passed through to the existing execution limits."""

    max_attempts: int = Field(ge=1, le=MAX_ATTEMPTS)
    planning_timeout_seconds: float = Field(gt=0, le=MAX_PLANNING_TIMEOUT_SECONDS)
    jit_replan: bool = True


class EvalCase(_Model):
    """One behavioral case: fixture, task, observable expectations, graders, bounds."""

    case_id: EvalId
    version: int = Field(default=1, ge=1)
    description: _NonBlank
    fixture: EvalFixture
    expected_disposition: ProjectRunDisposition = ProjectRunDisposition.PHASE_GATE_READY
    graders: tuple[EvalGrader, ...] = Field(min_length=1)
    bounds: EvalBounds

    @field_validator("graders")
    @classmethod
    def _normalize_graders(cls, graders: tuple[EvalGrader, ...]) -> tuple[EvalGrader, ...]:
        ids = [grader.grader_id for grader in graders]
        if len(set(ids)) != len(ids):
            raise ValueError("grader ids must be unique within a case")
        return tuple(sorted(graders, key=lambda grader: grader.grader_id))


class PolicySurface(StrEnum):
    """The agent-facing input an arm varies. Exactly one per arm."""

    IMPLEMENTER_INSTRUCTIONS = "implementer_instructions"


class EvalArm(_Model):
    """One comparison arm: the exact value of its single policy surface, and its source."""

    arm_id: EvalId
    version: int = Field(default=1, ge=1)
    surface: PolicySurface
    instructions: _NonBlank
    provenance: _NonBlank


class EvalSuite(_Model):
    """A finite set of cases crossed with explicit arms and an explicit repeat count."""

    suite_id: EvalId
    cases: tuple[EvalCase, ...] = Field(min_length=1, max_length=MAX_CASES)
    arms: tuple[EvalArm, ...] = Field(min_length=1, max_length=MAX_ARMS)
    repeat_count: int = Field(ge=1, le=MAX_REPEATS)

    @field_validator("cases")
    @classmethod
    def _normalize_cases(cls, cases: tuple[EvalCase, ...]) -> tuple[EvalCase, ...]:
        ids = [case.case_id for case in cases]
        if len(set(ids)) != len(ids):
            raise ValueError("case ids must be unique within a suite")
        return tuple(sorted(cases, key=lambda case: case.case_id))

    @field_validator("arms")
    @classmethod
    def _normalize_arms(cls, arms: tuple[EvalArm, ...]) -> tuple[EvalArm, ...]:
        ids = [arm.arm_id for arm in arms]
        if len(set(ids)) != len(ids):
            raise ValueError("arm ids must be unique within a suite")
        if len({arm.surface for arm in arms}) > 1:
            raise ValueError("every arm of a suite must vary the same policy surface")
        return tuple(sorted(arms, key=lambda arm: arm.arm_id))

    @field_validator("repeat_count")
    @classmethod
    def _bound_trials(cls, repeat_count: int, info: ValidationInfo) -> int:
        cases, arms = info.data.get("cases", ()), info.data.get("arms", ())
        if len(cases) * len(arms) * repeat_count > MAX_TRIALS:
            raise ValueError(f"a suite may expand into at most {MAX_TRIALS} trials")
        return repeat_count


class EvalTrialIdentity(_Model):
    """Exactly what one trial ran: case, arm, provider selection and repetition."""

    case_id: EvalId
    case_version: int
    case_digest: str
    arm_id: EvalId
    arm_version: int
    arm_digest: str
    surface: PolicySurface
    routing: AgentRoutingPolicy
    repeat_index: int = Field(ge=1)

    @property
    def trial_id(self) -> str:
        return f"{self.case_id}/{self.arm_id}/{self.repeat_index}"

    @property
    def pair_id(self) -> str:
        """Trials of every arm with the same case and repetition form one comparison pair."""
        return f"{self.case_id}/{self.repeat_index}"


class EvalTrial(_Model):
    """One expanded trial, carrying its complete case and arm semantics."""

    case: EvalCase
    arm: EvalArm
    routing: AgentRoutingPolicy
    repeat_index: int = Field(ge=1, le=MAX_REPEATS)

    @property
    def identity(self) -> EvalTrialIdentity:
        return EvalTrialIdentity(
            case_id=self.case.case_id,
            case_version=self.case.version,
            case_digest=self.case.digest,
            arm_id=self.arm.arm_id,
            arm_version=self.arm.version,
            arm_digest=self.arm.digest,
            surface=self.arm.surface,
            routing=self.routing,
            repeat_index=self.repeat_index,
        )


def expand_trials(suite: EvalSuite, routing: AgentRoutingPolicy) -> tuple[EvalTrial, ...]:
    """Cross the suite's cases, repetitions and arms under one provider selection.

    Ordered by case, then repetition, then arm, so the trials of one comparison pair are
    adjacent. Deterministic and finite (bounded by :data:`MAX_TRIALS`).
    """
    return tuple(
        EvalTrial(case=case, arm=arm, routing=routing, repeat_index=repeat)
        for case in suite.cases
        for repeat in range(1, suite.repeat_count + 1)
        for arm in suite.arms
    )


__all__ = [
    "MAX_ARMS",
    "MAX_ATTEMPTS",
    "MAX_CASES",
    "MAX_PLANNING_TIMEOUT_SECONDS",
    "MAX_REPEATS",
    "MAX_TRIALS",
    "EvalArm",
    "EvalBounds",
    "EvalCase",
    "EvalFixture",
    "EvalId",
    "EvalSuite",
    "EvalTrial",
    "EvalTrialIdentity",
    "PolicySurface",
    "canonical_digest",
    "expand_trials",
]
