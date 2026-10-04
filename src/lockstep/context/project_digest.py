"""The Project Digest: compact, structured, stable project knowledge (Phase 12.1).

A :class:`ProjectDigest` lets a fresh, disposable agent context learn what is
stable about a project -- its architecture, module boundaries, technology
stack, standard commands, test strategy, Git conventions, invariants, and
architectural constraints -- without replaying the project's documents or
history. Each section is a tuple of :class:`DigestFact` entries, and every
fact names the accepted sources (:class:`DigestSource`) that justify it, so the
question "why is this in the Digest?" always has an answer.

The Digest is stable knowledge, not execution authority. Summarization does
not increase authority: the model has no field that can express a
requirement, an acceptance criterion, a path scope, a dependency, or a
Contract, and unknown fields are rejected. The frozen Master Plan and the
active frozen Sub-phase Contract stay authoritative for what they own; a fact
that cites a Master Plan revision is checked against the frozen one by the
store (:mod:`lockstep.context.project_digest_store`), which fails closed on
any disagreement rather than choosing a side.

Canonical form is independent of construction order: facts are ordered by
``fact_id`` and sources by their own content, so equivalent Digests serialize
to identical bytes. The persisted bytes are compact, key-sorted JSON plus one
trailing newline; the revision identity is the lowercase SHA-256 of those
bytes without the newline, the same convention as
:func:`~lockstep.project_cursor.contract_digest`. The canonical encoding is
bounded by :data:`PROJECT_DIGEST_MAX_BYTES`; an oversized Digest is rejected,
never truncated.

Every function here is pure: no filesystem, Git, process, clock, network, or
model access.
"""

from __future__ import annotations

import hashlib
import json
from enum import StrEnum
from pathlib import PurePosixPath
from typing import Annotated, Self

from pydantic import (
    AfterValidator,
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    field_validator,
    model_validator,
)

from lockstep.domain import ProjectId, SchemaVersion

PROJECT_DIGEST_MAX_BYTES = 64 * 1024

_CURRENT_SCHEMA_VERSION: SchemaVersion = SchemaVersion.model_validate(1)

_Sha256Hex = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
_FactId = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9][A-Za-z0-9._-]*$")]

_SECTIONS: tuple[str, ...] = (
    "architecture",
    "module_boundaries",
    "technology_stack",
    "standard_commands",
    "test_strategy",
    "git_conventions",
    "invariants",
    "architectural_constraints",
)


class ProjectDigestError(Exception):
    """A Project Digest cannot be canonically serialized (for example, it is oversized).

    Carries a short, bounded, deterministic ``reason`` that never contains
    Digest content.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"project digest error: {reason}")


class DigestSourceKind(StrEnum):
    """The accepted origins of a Digest fact. Provider sessions are deliberately absent."""

    TRACKED_CONFIG = "tracked_config"
    MASTER_PLAN = "master_plan"
    ARCHITECTURE_DOCUMENT = "architecture_document"
    PROJECT_METADATA = "project_metadata"
    PRIOR_DIGEST_REVISION = "prior_digest_revision"
    PLANNER_AUTHORIZED_UPDATE = "planner_authorized_update"


_DIGEST_REQUIRED_KINDS = frozenset(
    {DigestSourceKind.MASTER_PLAN, DigestSourceKind.PRIOR_DIGEST_REVISION}
)


def _reject_blank(value: str) -> str:
    if not value.strip():
        raise ValueError("must not be empty or whitespace-only")
    return value


def _project_relative_locator(value: str) -> str:
    _reject_blank(value)
    if any(ch in value for ch in "\r\n\0"):
        raise ValueError("locator must be a single line")
    path = PurePosixPath(value)
    if path.is_absolute() or value.startswith("\\") or ".." in path.parts:
        raise ValueError("locator must be project-relative")
    return value


_NonBlankStr = Annotated[str, AfterValidator(_reject_blank)]
_Locator = Annotated[str, AfterValidator(_project_relative_locator)]


class _DigestModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class DigestSource(_DigestModel):
    """One accepted source a fact is attributed to; a reference, never a copy.

    ``locator`` is a project-relative name (a tracked path, ``master-plan``, a
    Planner authorization label). Sources that name a revision -- the Master
    Plan or a prior Digest -- must carry that revision's content ``digest``.
    """

    kind: DigestSourceKind
    locator: _Locator
    digest: _Sha256Hex | None = None

    @model_validator(mode="after")
    def _revision_sources_carry_a_digest(self) -> Self:
        if self.kind in _DIGEST_REQUIRED_KINDS and self.digest is None:
            raise ValueError(f"{self.kind.value} source must carry a content digest")
        return self

    def _sort_key(self) -> tuple[str, str, str]:
        return (self.kind.value, self.locator, self.digest or "")


class DigestFact(_DigestModel):
    """One stable statement and the sources that justify it."""

    fact_id: _FactId
    statement: _NonBlankStr
    sources: Annotated[tuple[DigestSource, ...], Field(min_length=1)]

    @field_validator("sources")
    @classmethod
    def _canonical_sources(cls, value: tuple[DigestSource, ...]) -> tuple[DigestSource, ...]:
        ordered = tuple(sorted(value, key=DigestSource._sort_key))
        if len(set(ordered)) != len(ordered):
            raise ValueError("duplicate source")
        return ordered


def _canonical_facts(value: tuple[DigestFact, ...]) -> tuple[DigestFact, ...]:
    return tuple(sorted(value, key=lambda fact: fact.fact_id))


_Section = Annotated[tuple[DigestFact, ...], AfterValidator(_canonical_facts)]


class ProjectDigest(_DigestModel):
    """Canonical, immutable stable project knowledge for one project.

    ``previous_revision`` is the identity of the revision this one supersedes
    (``None`` for the first), so revisions form a verifiable chain.
    ``fact_id`` values are unique across all sections.
    """

    schema_version: SchemaVersion = _CURRENT_SCHEMA_VERSION
    project_id: ProjectId
    previous_revision: _Sha256Hex | None = None

    architecture: _Section = ()
    module_boundaries: _Section = ()
    technology_stack: _Section = ()
    standard_commands: _Section = ()
    test_strategy: _Section = ()
    git_conventions: _Section = ()
    invariants: _Section = ()
    architectural_constraints: _Section = ()

    @field_validator("schema_version")
    @classmethod
    def _reject_unsupported_schema_version(cls, value: SchemaVersion) -> SchemaVersion:
        if value.root != _CURRENT_SCHEMA_VERSION.root:
            raise ValueError(
                f"unsupported schema_version {value.root}; this artifact only "
                f"understands schema_version {_CURRENT_SCHEMA_VERSION.root}"
            )
        return value

    @model_validator(mode="after")
    def _fact_ids_are_unique(self) -> Self:
        seen: set[str] = set()
        for fact in self.facts():
            if fact.fact_id in seen:
                raise ValueError(f"duplicate fact_id {fact.fact_id}")
            seen.add(fact.fact_id)
        return self

    def facts(self) -> tuple[DigestFact, ...]:
        """Every fact in canonical section order."""
        return tuple(fact for name in _SECTIONS for fact in getattr(self, name))


def _canonical_text(digest: ProjectDigest) -> str:
    return json.dumps(
        digest.model_dump(mode="json"),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )


def canonical_project_digest_bytes(digest: ProjectDigest) -> bytes:
    """Return the canonical persisted bytes of *digest*: sorted compact JSON plus newline.

    Raises :class:`ProjectDigestError` when the result would exceed
    :data:`PROJECT_DIGEST_MAX_BYTES`; nothing is ever truncated.
    """
    payload = (_canonical_text(digest) + "\n").encode("utf-8")
    if len(payload) > PROJECT_DIGEST_MAX_BYTES:
        raise ProjectDigestError(
            f"canonical project digest exceeds {PROJECT_DIGEST_MAX_BYTES} bytes"
        )
    return payload


def project_digest_identity(digest: ProjectDigest) -> str:
    """Return the revision identity of *digest*: SHA-256 of its canonical JSON.

    The storage newline is excluded, matching every other Lockstep content digest.
    """
    return hashlib.sha256(_canonical_text(digest).encode("utf-8")).hexdigest()


__all__ = [
    "PROJECT_DIGEST_MAX_BYTES",
    "DigestFact",
    "DigestSource",
    "DigestSourceKind",
    "ProjectDigest",
    "ProjectDigestError",
    "canonical_project_digest_bytes",
    "project_digest_identity",
]
