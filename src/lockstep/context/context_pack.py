"""The provider-neutral Context Pack: derived context for one fresh agent invocation (Phase 12.2).

A :class:`ContextPack` reconstructs the materially relevant working context for a
fresh agent invocation from durable, host-known state: the Project Digest, the frozen
Master Plan, the frozen Contract, the frozen tests, explicitly selected repository
documents, recorded evidence, the repository, and the host's invocation identity.
Correctness never depends on a provider conversation, a transcript, or hidden model
memory; nothing here has a field that could carry one.

A pack is a host-generated *view*. It is not requirement authority, not a Contract or
Master Plan amendment, not a Project Digest revision, not a retry checkpoint and not
durable state: it is rebuilt on demand and never persisted. Context assembly does not
increase authority. Every :class:`ContextSection` names its source kind, and each
source kind has exactly one authority class (:data:`SOURCE_AUTHORITY`, reusing the
11.4 :class:`~lockstep.handoff.AuthorityKind` vocabulary), so evidence cannot be
relabeled as a requirement and stable knowledge cannot become execution authority.

Mandatory authority (the Contract, required and protected tests, retry control, the
Master Plan, completed history) is always carried exactly. An authoritative excerpt
must say so in its heading as well as in its completeness, so an excerpt never
masquerades as the whole artifact. Each operation requires its mandatory sources and
admits only the sources relevant to it; an initial Implementer never sees Review
Findings and a JIT Planner never sees Implementer or Reviewer prose.

The structured pack is canonical; :func:`render_context_pack` is a deterministic
projection of it. Section content is one line of canonical JSON, so no source --
including a selected document -- can begin a line and spoof a heading. The rendering
starts with a provenance manifest (:data:`CONTEXT_PACK_HEADER` plus one JSON line)
naming every source, then emits each section exactly as the 11.4 handoff renderers
do, so the accepted role-section layout is preserved byte for byte.

Every function here is pure: no filesystem, Git, process, clock, network, or model
access. Durable sources are read by :mod:`lockstep.context.context_pack_builder`.
"""

from __future__ import annotations

import json
import re
from enum import StrEnum
from types import MappingProxyType
from typing import Annotated, Self

from pydantic import BaseModel, ConfigDict, StringConstraints, field_validator, model_validator

from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    PhaseId,
    ProjectId,
    RunId,
    SchemaVersion,
    SubphaseId,
)
from lockstep.handoff import REVIEWER_IDENTITY_HEADER, AuthorityKind, HandoffError

_CURRENT_SCHEMA_VERSION: SchemaVersion = SchemaVersion.model_validate(1)

CONTEXT_PACK_HEADER = (
    "\n\n---\n# CONTEXT PACK (host-assembled derived context; each section keeps the "
    "authority of its source and gains none)\n"
)

_TITLE_PATTERN = re.compile(r"^[A-Z][A-Z /]*[A-Z]$")
_EXCERPT_MARKER = "EXCERPT"

_Reference = Annotated[
    str, StringConstraints(pattern=r"^\S(?:[^\r\n\t\x00]*\S)?$", max_length=1024)
]
_Version = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{40,64}$")]


class ContextPackError(HandoffError):
    """A Context Pack cannot be built: a mandatory source is missing, unsafe, or drifted.

    A specialization of :class:`~lockstep.handoff.HandoffError`, so a role whose pack
    cannot be built fails closed exactly where a stale handoff does, before any
    provider launches. Carries a short, bounded, deterministic ``reason`` that never
    contains source contents.
    """


class ContextOperation(StrEnum):
    """The role invocation a pack is assembled for."""

    TEST_AUTHORING = "test_authoring"
    IMPLEMENTATION = "implementation"
    REWORK = "rework"
    REVIEW = "review"
    JIT_REPLAN = "jit_replan"


class ContextSourceKind(StrEnum):
    """The conceptually distinct durable sources a pack may carry.

    Provider sessions, transcripts and historical prompts are deliberately absent.
    """

    PROJECT_DIGEST = "project_digest"
    MASTER_PLAN = "master_plan"
    PHASE_CONTEXT = "phase_context"
    COMPLETED_HISTORY = "completed_history"
    PROVISIONAL_OUTLINE = "provisional_outline"
    CONTRACT = "contract"
    REQUIRED_TESTS = "required_tests"
    FROZEN_TESTS = "frozen_tests"
    PROJECT_INSTRUCTIONS = "project_instructions"
    PROJECT_DOCUMENTATION = "project_documentation"
    SKILL = "skill"
    RETRY_CONTROL = "retry_control"
    IMPLEMENTATION_REPORT = "implementation_report"
    VERIFICATION_REPORT = "verification_report"
    REVIEW_FINDINGS = "review_findings"
    REVIEW_HISTORY = "review_history"
    REPOSITORY_STATE = "repository_state"


class ContextCompleteness(StrEnum):
    """Whether a section carries its whole source or a marked excerpt of it."""

    EXACT = "exact"
    EXCERPT = "excerpt"


_K = ContextSourceKind
_A = AuthorityKind

SOURCE_AUTHORITY: MappingProxyType[ContextSourceKind, AuthorityKind] = MappingProxyType(
    {
        _K.PROJECT_DIGEST: _A.ADVISORY_CONTEXT,
        _K.MASTER_PLAN: _A.FROZEN_REQUIREMENT,
        _K.PHASE_CONTEXT: _A.FROZEN_REQUIREMENT,
        _K.COMPLETED_HISTORY: _A.FROZEN_REQUIREMENT,
        _K.PROVISIONAL_OUTLINE: _A.PROVISIONAL_PLAN,
        _K.CONTRACT: _A.FROZEN_REQUIREMENT,
        _K.REQUIRED_TESTS: _A.FROZEN_REQUIREMENT,
        _K.FROZEN_TESTS: _A.PROTECTED_ACCEPTANCE,
        _K.PROJECT_INSTRUCTIONS: _A.ADVISORY_CONTEXT,
        _K.PROJECT_DOCUMENTATION: _A.ADVISORY_CONTEXT,
        _K.SKILL: _A.ADVISORY_CONTEXT,
        _K.RETRY_CONTROL: _A.CONTROL_DECISION,
        _K.IMPLEMENTATION_REPORT: _A.EXECUTION_EVIDENCE,
        _K.VERIFICATION_REPORT: _A.EXECUTION_EVIDENCE,
        _K.REVIEW_FINDINGS: _A.EXECUTION_EVIDENCE,
        _K.REVIEW_HISTORY: _A.EXECUTION_EVIDENCE,
        _K.REPOSITORY_STATE: _A.EXECUTION_EVIDENCE,
    }
)
"""The one authority class of every source kind. A section cannot choose its own."""

_ALWAYS_EXACT = frozenset(
    {
        _K.CONTRACT,
        _K.REQUIRED_TESTS,
        _K.FROZEN_TESTS,
        _K.RETRY_CONTROL,
        _K.MASTER_PLAN,
        _K.COMPLETED_HISTORY,
    }
)
_GUIDANCE = frozenset(
    {_K.PROJECT_DIGEST, _K.PROJECT_INSTRUCTIONS, _K.PROJECT_DOCUMENTATION, _K.SKILL}
)
_EXCERPT_NEEDS_TITLE = frozenset(
    {_A.FROZEN_REQUIREMENT, _A.PROTECTED_ACCEPTANCE, _A.CONTROL_DECISION, _A.PROVISIONAL_PLAN}
)

_OPERATION_ROLE: MappingProxyType[ContextOperation, AgentRole] = MappingProxyType(
    {
        ContextOperation.TEST_AUTHORING: AgentRole.PLANNER,
        ContextOperation.IMPLEMENTATION: AgentRole.IMPLEMENTER,
        ContextOperation.REWORK: AgentRole.IMPLEMENTER,
        ContextOperation.REVIEW: AgentRole.REVIEWER,
        ContextOperation.JIT_REPLAN: AgentRole.PLANNER,
    }
)

# Per operation: the sources that must be present, and the further ones it admits.
_MANDATORY: MappingProxyType[ContextOperation, frozenset[ContextSourceKind]] = MappingProxyType(
    {
        ContextOperation.TEST_AUTHORING: frozenset({_K.CONTRACT, _K.REQUIRED_TESTS}),
        ContextOperation.IMPLEMENTATION: frozenset(
            {_K.CONTRACT, _K.FROZEN_TESTS, _K.REPOSITORY_STATE}
        ),
        ContextOperation.REWORK: frozenset(
            {_K.CONTRACT, _K.FROZEN_TESTS, _K.REPOSITORY_STATE, _K.RETRY_CONTROL}
        ),
        ContextOperation.REVIEW: frozenset(
            {
                _K.CONTRACT,
                _K.FROZEN_TESTS,
                _K.IMPLEMENTATION_REPORT,
                _K.VERIFICATION_REPORT,
                _K.REPOSITORY_STATE,
                _K.REVIEW_HISTORY,
            }
        ),
        ContextOperation.JIT_REPLAN: frozenset(
            {_K.MASTER_PLAN, _K.COMPLETED_HISTORY, _K.PROVISIONAL_OUTLINE, _K.REPOSITORY_STATE}
        ),
    }
)
_OPTIONAL: MappingProxyType[ContextOperation, frozenset[ContextSourceKind]] = MappingProxyType(
    {
        ContextOperation.TEST_AUTHORING: _GUIDANCE | {_K.PHASE_CONTEXT},
        ContextOperation.IMPLEMENTATION: _GUIDANCE,
        ContextOperation.REWORK: _GUIDANCE | {_K.REVIEW_FINDINGS, _K.VERIFICATION_REPORT},
        ContextOperation.REVIEW: _GUIDANCE,
        ContextOperation.JIT_REPLAN: _GUIDANCE,
    }
)


class _PackModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class ContextIdentity(_PackModel):
    """The host-bound identity of the invocation a pack is for.

    Transaction roles carry the run, Sub-phase and attempt; a JIT Planner works on a
    Phase between Sub-phases and carries none of them.
    """

    project_id: ProjectId
    phase_id: PhaseId
    subphase_id: SubphaseId | None = None
    run_id: RunId | None = None
    attempt: AttemptNumber | None = None
    role: AgentRole


class ContextSection(_PackModel):
    """One source carried by a pack, with its provenance.

    ``reference`` names the exact source (``contract:<digest>``, ``file:<path>``,
    ``project-digest:<revision>``, ...); ``version`` is its content digest or commit
    when one exists. ``content`` is one line of canonical JSON.
    """

    kind: ContextSourceKind
    authority: AuthorityKind
    title: str
    reference: _Reference
    completeness: ContextCompleteness
    version: _Version | None = None
    content: str

    @field_validator("title")
    @classmethod
    def _plain_heading(cls, value: str) -> str:
        if not _TITLE_PATTERN.match(value):
            raise ValueError("title must be a plain upper-case heading")
        return value

    @field_validator("content")
    @classmethod
    def _one_line_of_json(cls, value: str) -> str:
        if "\n" in value or "\r" in value:
            raise ValueError("content must be one line")
        try:
            parsed = json.loads(value)
        except ValueError as exc:
            raise ValueError("content must be JSON") from exc
        if not isinstance(parsed, dict):
            raise ValueError("content must be a JSON object")
        return value

    @model_validator(mode="after")
    def _authority_and_completeness_follow_the_source(self) -> Self:
        if self.authority is not SOURCE_AUTHORITY[self.kind]:
            raise ValueError(f"{self.kind.value} carries {SOURCE_AUTHORITY[self.kind].value}")
        if self.completeness is ContextCompleteness.EXCERPT:
            if self.kind in _ALWAYS_EXACT:
                raise ValueError(f"{self.kind.value} is never excerpted")
            if self.authority in _EXCERPT_NEEDS_TITLE and _EXCERPT_MARKER not in self.title:
                raise ValueError("an authoritative excerpt must be titled as an excerpt")
        return self


class ContextPack(_PackModel):
    """Derived context for one fresh role invocation, in canonical section order."""

    schema_version: SchemaVersion = _CURRENT_SCHEMA_VERSION
    operation: ContextOperation
    identity: ContextIdentity
    sections: tuple[ContextSection, ...]

    @field_validator("schema_version")
    @classmethod
    def _supported_schema_version(cls, value: SchemaVersion) -> SchemaVersion:
        if value.root != _CURRENT_SCHEMA_VERSION.root:
            raise ValueError(f"unsupported schema_version {value.root}")
        return value

    @model_validator(mode="after")
    def _sources_fit_the_operation(self) -> Self:
        if self.identity.role is not _OPERATION_ROLE[self.operation]:
            raise ValueError(f"{self.operation.value} is not a {self.identity.role.value} pack")
        if self.operation is not ContextOperation.JIT_REPLAN and (
            self.identity.subphase_id is None
            or self.identity.run_id is None
            or self.identity.attempt is None
        ):
            raise ValueError("a transaction role pack must name its run, sub-phase and attempt")
        kinds = [section.kind for section in self.sections]
        missing = _MANDATORY[self.operation] - set(kinds)
        if missing:
            raise ValueError(f"missing mandatory source {min(k.value for k in missing)}")
        foreign = set(kinds) - _MANDATORY[self.operation] - _OPTIONAL[self.operation]
        if foreign:
            raise ValueError(f"{min(k.value for k in foreign)} is not relevant here")
        for kind in _MANDATORY[self.operation] | {_K.PROJECT_DIGEST}:
            if kinds.count(kind) > 1:
                raise ValueError(f"{kind.value} appears more than once")
        references = [section.reference for section in self.sections]
        if len(set(references)) != len(references):
            raise ValueError("duplicate source reference")
        return self


# --- Deterministic rendering ------------------------------------------------------


def _json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _manifest(pack: ContextPack) -> str:
    return _json(
        {
            "schema_version": pack.schema_version.root,
            "operation": pack.operation.value,
            "identity": pack.identity.model_dump(mode="json"),
            "sources": [
                {
                    "title": section.title,
                    "kind": section.kind.value,
                    "authority": section.authority.value,
                    "reference": section.reference,
                    "completeness": section.completeness.value,
                    "version": section.version,
                }
                for section in pack.sections
            ],
        }
    )


def render_context_pack(pack: ContextPack) -> str:
    """Project *pack* into provider-neutral prompt text, deterministically.

    The manifest names every source's kind, authority, reference, completeness and
    version; each section follows in pack order under ``## TITLE [authority]``. A
    Reviewer pack ends with the host identity the Review Decision must copy.
    """
    text = CONTEXT_PACK_HEADER + _manifest(pack) + "\n"
    for section in pack.sections:
        text += f"\n\n---\n## {section.title} [{section.authority.value}]\n{section.content}\n"
    if pack.operation is ContextOperation.REVIEW:
        identity = pack.identity
        assert identity.subphase_id is not None and identity.attempt is not None
        text += (
            REVIEWER_IDENTITY_HEADER
            + _json(
                {
                    "phase_id": identity.phase_id.root,
                    "subphase_id": identity.subphase_id.root,
                    "attempt": identity.attempt.root,
                    "role": identity.role.value,
                }
            )
            + "\n"
        )
    return text


__all__ = [
    "CONTEXT_PACK_HEADER",
    "SOURCE_AUTHORITY",
    "ContextCompleteness",
    "ContextIdentity",
    "ContextOperation",
    "ContextPack",
    "ContextPackError",
    "ContextSection",
    "ContextSourceKind",
    "render_context_pack",
]
