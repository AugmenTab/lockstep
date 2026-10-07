"""Assemble role-specific Context Packs from durable, host-known sources (Phase 12.2).

Each ``build_*`` function reconstructs one :class:`~lockstep.context.context_pack.ContextPack`
for a fresh role invocation::

    durable sources                     this module
        frozen Project Digest   ─┐
        frozen Master Plan       │     ContextPack  ──render──▶  provider-neutral prompt text
        typed 11.4 handoff       ├──▶  (structured,
        selected documents       │      derived,
        cursor / replan basis   ─┘      never persisted)

The 11.4 handoff builders (:mod:`lockstep.handoff`) remain the single place that
rebuilds Contract, test, evidence and diff material from the journal, the evidence
store and Git; this module wraps that material in sources with fixed authority and
adds what the handoffs do not carry: the Project Digest, the relevant Master Plan
excerpt, and explicitly selected repository documents.

Selection is host-owned and deterministic. Nothing is chosen by a model and nothing is
guessed: the Project Digest is included whenever one has been frozen (and is required
only when :attr:`ContextSelection.require_project_digest` says so); documents are
included only when a :class:`SelectedContextDocument` names their exact
repository-relative path and the operations they serve. A selected document is read
from the project root, confined to it, refused when any path component is a symlink,
bounded per file and in aggregate, and identified by its SHA-256. Oversize input fails
typed; nothing is truncated.

Every read is fresh: no pack and no source is cached, so a pack built after a durable
source changes observes the change. Nothing here writes: the Project Digest is loaded
read-only and never created, updated or finalized.
"""

from __future__ import annotations

import hashlib
import json
import os
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING, Annotated, Literal, Self

from pydantic import BaseModel, ConfigDict, Field, ValidationError, model_validator

from lockstep.context.context_pack import (
    SOURCE_AUTHORITY,
    ContextCompleteness,
    ContextIdentity,
    ContextOperation,
    ContextPack,
    ContextPackError,
    ContextSection,
    ContextSourceKind,
)
from lockstep.context.project_digest import project_digest_identity
from lockstep.context.project_digest_store import ProjectDigestStoreError, load_project_digest
from lockstep.contract_test_targets import target_path_violation, traverses_symlink
from lockstep.domain import (
    AgentRole,
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    SubphaseId,
    SubphaseOutline,
)
from lockstep.handoff import (
    ContractAuthority,
    HandoffIdentity,
    ImplementerEvidence,
    ImplementerHandoff,
    PlannerTestHandoff,
    ProtectedAcceptance,
    RepositoryBasis,
    RepositoryEvidence,
    RequiredTestPaths,
    RetryControl,
    ReviewerHandoff,
    ReviewEvidence,
    ReviewHistory,
    ReworkHandoff,
    VerificationEvidence,
)
from lockstep.planning_store import PlanningStoreError, load_frozen_master_plan
from lockstep.project_cursor import ProjectCursor, master_plan_digest

if TYPE_CHECKING:
    from lockstep.jit_replan import ReplanBasis
    from lockstep.phase_gate import PhaseGateBasis, PhaseGateDecision, PhaseGateEvidence

CONTEXT_DOCUMENT_MAX_BYTES = 64 * 1024
CONTEXT_DOCUMENTS_MAX_TOTAL_BYTES = 256 * 1024
CONTEXT_DOCUMENTS_MAX_COUNT = 16

_K = ContextSourceKind
_EXACT = ContextCompleteness.EXACT
_EXCERPT = ContextCompleteness.EXCERPT

_DOCUMENT_KIND_ORDER: tuple[ContextSourceKind, ...] = (
    _K.PROJECT_INSTRUCTIONS,
    _K.PROJECT_DOCUMENTATION,
    _K.SKILL,
)
_DOCUMENT_TITLES = {
    _K.PROJECT_INSTRUCTIONS: "PROJECT INSTRUCTIONS",
    _K.PROJECT_DOCUMENTATION: "PROJECT DOCUMENTATION",
    _K.SKILL: "SKILL GUIDANCE",
}

# The accepted 11.4 handoff headings; rendering keeps those sections byte for byte.
_TITLE_FROZEN = "FROZEN REQUIREMENT AUTHORITY"
_TITLE_REQUIRED_TESTS = "REQUIRED TEST PATHS"
_TITLE_PROTECTED = "PROTECTED ACCEPTANCE ARTIFACT"
_TITLE_BASIS = "REPOSITORY BASIS"
_TITLE_IMPLEMENTER = "IMPLEMENTER EVIDENCE"
_TITLE_VERIFICATION = "VERIFICATION EVIDENCE"
_TITLE_REPOSITORY = "REPOSITORY EVIDENCE"
_TITLE_HISTORY = "REVIEW HISTORY"
_TITLE_RETRY = "RETRY CONTROL AUTHORITY"
_TITLE_REVIEW_EVIDENCE = "REVIEW EVIDENCE / REPAIR GUIDANCE"

_TITLE_DIGEST = "PROJECT DIGEST / STABLE PROJECT KNOWLEDGE"
_TITLE_PHASE_EXCERPT = "MASTER PLAN EXCERPT / CURRENT PHASE"
_TITLE_MASTER_PLAN = "MASTER PLAN"
_TITLE_COMPLETED = "COMPLETED HISTORY"
_TITLE_UNFINISHED = "UNFINISHED PROVISIONAL OUTLINE"
_TITLE_ACCEPTED_BASIS = "ACCEPTED REPOSITORY BASIS"
_TITLE_PHASE_PLAN = "CURRENT PROVISIONAL PHASE PLAN"
_TITLE_GATE_DECISION = "PHASE GATE FAILURE FINDINGS"
_TITLE_GATE_EVIDENCE = "PHASE GATE COMMAND EVIDENCE"


# --- Selection and sources ------------------------------------------------------------


class _SelectionModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class SelectedContextDocument(_SelectionModel):
    """One explicitly selected repository document and the operations it serves.

    *path* must be an exact repository-relative file path; it is checked against the
    repository when a pack is built, never expanded or guessed.
    """

    path: Annotated[str, Field(min_length=1)]
    kind: Literal[
        ContextSourceKind.PROJECT_INSTRUCTIONS,
        ContextSourceKind.PROJECT_DOCUMENTATION,
        ContextSourceKind.SKILL,
    ]
    operations: Annotated[tuple[ContextOperation, ...], Field(min_length=1)]


class ContextSelection(_SelectionModel):
    """The host's explicit, bounded choice of optional context sources."""

    documents: Annotated[
        tuple[SelectedContextDocument, ...], Field(max_length=CONTEXT_DOCUMENTS_MAX_COUNT)
    ] = ()
    require_project_digest: bool = False

    @model_validator(mode="after")
    def _paths_are_unique(self) -> Self:
        paths = [document.path for document in self.documents]
        if len(set(paths)) != len(paths):
            raise ValueError("a document is selected more than once")
        return self


@dataclass(frozen=True, slots=True)
class ContextSources:
    """Where a pack's durable sources live: the project and its project-level runtime.

    *runtime_dir* is the project runtime directory (the one holding ``project/``), not
    a transaction directory.
    """

    project_id: ProjectId
    project_root: Path
    runtime_dir: Path
    selection: ContextSelection = field(default_factory=ContextSelection)

    def __post_init__(self) -> None:
        object.__setattr__(self, "project_root", Path(self.project_root).resolve())
        object.__setattr__(self, "runtime_dir", Path(self.runtime_dir).resolve())


# --- Source sections ------------------------------------------------------------------


def _json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _section(
    kind: ContextSourceKind,
    title: str,
    reference: str,
    content: object,
    *,
    version: str | None = None,
    completeness: ContextCompleteness = _EXACT,
) -> ContextSection:
    try:
        return ContextSection(
            kind=kind,
            authority=SOURCE_AUTHORITY[kind],
            title=title,
            reference=reference,
            completeness=completeness,
            version=version,
            content=_json(content),
        )
    except ValidationError as exc:
        raise ContextPackError(f"{kind.value} source is not representable") from exc


def _handoff_section(
    kind: ContextSourceKind,
    title: str,
    reference: str,
    model: BaseModel,
    *,
    version: str | None = None,
    completeness: ContextCompleteness = _EXACT,
) -> ContextSection:
    # Exactly the JSON the 11.4 renderer emits for this handoff section.
    return _section(
        kind,
        title,
        reference,
        model.model_dump(mode="json"),
        version=version,
        completeness=completeness,
    )


def _digest_sections(sources: ContextSources) -> tuple[ContextSection, ...]:
    try:
        digest = load_project_digest(sources.project_root, sources.runtime_dir)
    except (ProjectDigestStoreError, PlanningStoreError) as exc:
        raise ContextPackError(f"project digest: {exc.reason}") from exc
    if digest is None:
        if sources.selection.require_project_digest:
            raise ContextPackError("a project digest is required but none has been frozen")
        return ()
    if digest.project_id != sources.project_id:
        raise ContextPackError("the project digest names a different project")
    identity = project_digest_identity(digest)
    return (
        _section(
            _K.PROJECT_DIGEST,
            _TITLE_DIGEST,
            f"project-digest:{identity}",
            {"revision": identity, "digest": digest.model_dump(mode="json")},
            version=identity,
        ),
    )


def _read_document(root: Path, path: str, position: int) -> bytes:
    where = f"selected context document {position}"
    violation = target_path_violation(path)
    if violation is not None:
        raise ContextPackError(f"{where} {violation}")
    if traverses_symlink(root, path):
        raise ContextPackError(f"{where} traverses a symlink")
    target = root / path
    if not target.exists():
        raise ContextPackError(f"{where} does not exist")
    if not target.is_file():
        raise ContextPackError(f"{where} is not a regular file")
    if not target.resolve().is_relative_to(root):
        raise ContextPackError(f"{where} escapes the project root")
    try:
        fd = os.open(target, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
    except OSError as exc:
        raise ContextPackError(f"{where} cannot be read") from exc
    try:
        with os.fdopen(fd, "rb") as handle:
            data = handle.read(CONTEXT_DOCUMENT_MAX_BYTES + 1)
    except OSError as exc:
        raise ContextPackError(f"{where} cannot be read") from exc
    if len(data) > CONTEXT_DOCUMENT_MAX_BYTES:
        raise ContextPackError(f"{where} exceeds {CONTEXT_DOCUMENT_MAX_BYTES} bytes")
    return data


def _document_sections(
    sources: ContextSources, operation: ContextOperation
) -> tuple[ContextSection, ...]:
    selected = [
        (position, document)
        for position, document in enumerate(sources.selection.documents)
        if operation in document.operations
    ]
    selected.sort(key=lambda item: (_DOCUMENT_KIND_ORDER.index(item[1].kind), item[1].path))
    sections: list[ContextSection] = []
    total = 0
    for position, document in selected:
        data = _read_document(sources.project_root, document.path, position)
        total += len(data)
        if total > CONTEXT_DOCUMENTS_MAX_TOTAL_BYTES:
            raise ContextPackError(
                f"selected context documents exceed {CONTEXT_DOCUMENTS_MAX_TOTAL_BYTES} bytes"
            )
        try:
            text = data.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise ContextPackError(
                f"selected context document {position} is not UTF-8 text"
            ) from exc
        sha256 = hashlib.sha256(data).hexdigest()
        sections.append(
            _section(
                document.kind,
                _DOCUMENT_TITLES[document.kind],
                f"file:{document.path}",
                {"path": document.path, "sha256": sha256, "text": text},
                version=sha256,
            )
        )
    return tuple(sections)


def _guidance(sources: ContextSources, operation: ContextOperation) -> list[ContextSection]:
    return [*_digest_sections(sources), *_document_sections(sources, operation)]


def _contract(contract: ContractAuthority) -> ContextSection:
    return _handoff_section(
        _K.CONTRACT,
        _TITLE_FROZEN,
        f"contract:{contract.contract_digest}",
        contract,
        version=contract.contract_digest,
    )


def _protected(protected: ProtectedAcceptance) -> ContextSection:
    return _handoff_section(
        _K.FROZEN_TESTS,
        _TITLE_PROTECTED,
        f"git:{protected.test_commit_sha}#frozen-tests",
        protected,
        version=protected.test_commit_sha,
    )


def _basis(basis: RepositoryBasis) -> ContextSection:
    return _handoff_section(
        _K.REPOSITORY_STATE,
        _TITLE_BASIS,
        f"git:{basis.basis_commit_sha}#basis",
        basis,
        version=basis.basis_commit_sha,
    )


def _verification(verification: VerificationEvidence) -> ContextSection:
    truncated = any(
        command.stdout_truncated or command.stderr_truncated
        for command in verification.commands.commands
    )
    return _handoff_section(
        _K.VERIFICATION_REPORT,
        _TITLE_VERIFICATION,
        f"verification:attempt-{verification.report.attempt.root}",
        verification,
        completeness=_EXCERPT if truncated else _EXACT,
    )


def _retry(retry: RetryControl) -> ContextSection:
    return _handoff_section(
        _K.RETRY_CONTROL, _TITLE_RETRY, f"retry:attempt-{retry.attempt.root}:{retry.kind}", retry
    )


def _review_evidence(review: ReviewEvidence) -> ContextSection:
    return _handoff_section(
        _K.REVIEW_FINDINGS,
        _TITLE_REVIEW_EVIDENCE,
        f"review-decision:attempt-{review.decision.attempt.root}",
        review,
    )


def _implementer(evidence: ImplementerEvidence) -> ContextSection:
    return _handoff_section(
        _K.IMPLEMENTATION_REPORT,
        _TITLE_IMPLEMENTER,
        f"implementation-report:attempt-{evidence.report.attempt.root}",
        evidence,
    )


def _repository(evidence: RepositoryEvidence) -> ContextSection:
    truncated = any(change.patch_truncated for change in evidence.changes)
    return _handoff_section(
        _K.REPOSITORY_STATE,
        _TITLE_REPOSITORY,
        f"git:{evidence.base_commit_sha}..worktree",
        evidence,
        version=evidence.base_commit_sha,
        completeness=_EXCERPT if truncated else _EXACT,
    )


def _history(history: ReviewHistory) -> ContextSection:
    attempts = ",".join(f"attempt-{d.attempt.root}" for d in history.decisions) or "none"
    return _handoff_section(
        _K.REVIEW_HISTORY, _TITLE_HISTORY, f"review-history:{attempts}", history
    )


def _required_tests(paths: RequiredTestPaths, contract: ContractAuthority) -> ContextSection:
    return _handoff_section(
        _K.REQUIRED_TESTS,
        _TITLE_REQUIRED_TESTS,
        f"contract:{contract.contract_digest}#tests",
        paths,
        version=contract.contract_digest,
    )


# --- Packs ------------------------------------------------------------------------------


def _pack(
    operation: ContextOperation, identity: ContextIdentity, sections: Sequence[ContextSection]
) -> ContextPack:
    try:
        return ContextPack(operation=operation, identity=identity, sections=tuple(sections))
    except ValidationError as exc:
        message = str(exc.errors()[0].get("msg", "invalid"))
        raise ContextPackError(f"context pack refused: {message}") from exc


def _role_identity(
    sources: ContextSources,
    identity: HandoffIdentity,
    role: AgentRole,
    contract: ContractAuthority | None,
) -> ContextIdentity:
    if identity.role is not role:
        raise ContextPackError(f"the handoff is not for the {role.value}")
    if contract is None:
        raise ContextPackError("the frozen contract is required and is missing")
    if (contract.contract.phase_id, contract.contract.subphase_id) != (
        identity.phase_id,
        identity.subphase_id,
    ):
        raise ContextPackError("the frozen contract belongs to another sub-phase")
    return ContextIdentity(
        project_id=sources.project_id,
        phase_id=identity.phase_id,
        subphase_id=identity.subphase_id,
        run_id=identity.run_id,
        attempt=identity.attempt,
        role=role,
    )


def _frozen_master_plan(sources: ContextSources) -> MasterPlan:
    try:
        master = load_frozen_master_plan(sources.project_root)
    except PlanningStoreError as exc:
        raise ContextPackError(f"master plan: {exc.reason}") from exc
    if master is None:
        raise ContextPackError("the master plan is not frozen")
    if master.project_id != sources.project_id:
        raise ContextPackError("the master plan names a different project")
    return master


def _phase_excerpt(sources: ContextSources, identity: ContextIdentity) -> ContextSection:
    master = _frozen_master_plan(sources)
    phase = next((p for p in master.phases if p.phase_id == identity.phase_id), None)
    if phase is None:
        raise ContextPackError("the current phase is not in the frozen master plan")
    digest = master_plan_digest(master)
    # Frozen Phase-level facts only; the Sub-phase outline is provisional planning state.
    facts = phase.model_dump(mode="json", exclude={"subphases"})
    return _section(
        _K.PHASE_CONTEXT,
        _TITLE_PHASE_EXCERPT,
        f"master-plan:{digest}#phase:{phase.phase_id.root}",
        {
            "master_plan_digest": digest,
            "project_id": master.project_id.root,
            "title": master.title,
            "objective": master.objective,
            "phase": facts,
        },
        version=digest,
        completeness=_EXCERPT,
    )


def build_test_authoring_context_pack(
    sources: ContextSources, handoff: PlannerTestHandoff
) -> ContextPack:
    """The Planner test-authoring pack: Digest, current-Phase excerpt, Contract, tests."""
    operation = ContextOperation.TEST_AUTHORING
    identity = _role_identity(sources, handoff.identity, AgentRole.PLANNER, handoff.contract)
    return _pack(
        operation,
        identity,
        [
            *_guidance(sources, operation),
            _phase_excerpt(sources, identity),
            _contract(handoff.contract),
            _required_tests(handoff.test_paths, handoff.contract),
        ],
    )


def build_implementer_context_pack(
    sources: ContextSources, handoff: ImplementerHandoff
) -> ContextPack:
    """The first-attempt Implementer pack: Digest, Contract, frozen tests, basis."""
    operation = ContextOperation.IMPLEMENTATION
    identity = _role_identity(sources, handoff.identity, AgentRole.IMPLEMENTER, handoff.contract)
    return _pack(
        operation,
        identity,
        [
            *_guidance(sources, operation),
            _contract(handoff.contract),
            _protected(handoff.protected_tests),
            _basis(handoff.basis),
        ],
    )


def build_rework_context_pack(sources: ContextSources, handoff: ReworkHandoff) -> ContextPack:
    """A retried Implementer's pack: the original authority plus retry control and evidence.

    Review Findings and prior verification stay evidence / repair guidance; only the
    host's retry control carries control authority.
    """
    operation = ContextOperation.REWORK
    identity = _role_identity(sources, handoff.identity, AgentRole.IMPLEMENTER, handoff.contract)
    sections = [
        *_guidance(sources, operation),
        _contract(handoff.contract),
        _protected(handoff.protected_tests),
        _basis(handoff.basis),
        _retry(handoff.retry),
    ]
    if handoff.review is not None:
        sections.append(_review_evidence(handoff.review))
    if handoff.verification is not None:
        sections.append(_verification(handoff.verification))
    return _pack(operation, identity, sections)


def build_reviewer_context_pack(sources: ContextSources, handoff: ReviewerHandoff) -> ContextPack:
    """The late Reviewer pack: authority, then report, verification, diff and history evidence."""
    operation = ContextOperation.REVIEW
    identity = _role_identity(sources, handoff.identity, AgentRole.REVIEWER, handoff.contract)
    assert handoff.contract is not None
    return _pack(
        operation,
        identity,
        [
            *_guidance(sources, operation),
            _contract(handoff.contract),
            _protected(handoff.protected_tests),
            _implementer(handoff.implementer),
            _verification(handoff.verification),
            _repository(handoff.repository),
            _history(handoff.history),
        ],
    )


def _master_plan(master_plan: MasterPlan) -> ContextSection:
    digest = master_plan_digest(master_plan)
    return _section(
        _K.MASTER_PLAN,
        _TITLE_MASTER_PLAN,
        f"master-plan:{digest}",
        {"master_plan_digest": digest, "master_plan": master_plan.model_dump(mode="json")},
        version=digest,
    )


def _completed_history(
    cursor: ProjectCursor,
    phase_id: PhaseId,
    outlines: Sequence[SubphaseOutline],
    finalized_phases: Sequence[tuple[PhaseId, str]],
) -> ContextSection:
    """The immutable completed history of *phase_id*, plus earlier Phases' finalizations.

    *outlines* is the Phase's current outline; its completed prefix must name exactly the
    cursor's accepted Sub-phases of that Phase. Finalized Phases (12.8) join as compact
    references only, and the member is absent when there are none.
    """
    completed = tuple(e for e in cursor.completed_subphases if e.phase_id == phase_id)
    count = len(completed)
    if tuple(o.subphase_id for o in outlines[:count]) != tuple(e.subphase_id for e in completed):
        raise ContextPackError("the phase plan diverges from the completed history")
    if any(finalized not in cursor.completed_phases for finalized, _ in finalized_phases):
        raise ContextPackError("a finalized phase is not in the completed history")
    history: dict[str, object] = {
        "phase_id": phase_id.root,
        "subphases": [o.model_dump(mode="json") for o in outlines[:count]],
        "accepted": [e.model_dump(mode="json") for e in completed],
    }
    if finalized_phases:
        history["finalized_phases"] = [
            {
                "phase_id": finalized.root,
                "identity": sha256,
                "reference": f"phase-context:{finalized.root}@{sha256}",
            }
            for finalized, sha256 in finalized_phases
        ]
    return _section(
        _K.COMPLETED_HISTORY,
        _TITLE_COMPLETED,
        f"project-cursor:revision-{cursor.revision}#completed",
        history,
    )


def _accepted_basis(basis: ReplanBasis) -> ContextSection:
    return _section(
        _K.REPOSITORY_STATE,
        _TITLE_ACCEPTED_BASIS,
        f"git:{basis.commit}#accepted-basis",
        basis.model_dump(mode="json"),
        version=basis.commit,
    )


def _require_planning_state(
    sources: ContextSources, master_plan: MasterPlan, cursor: ProjectCursor | None
) -> None:
    if master_plan.project_id != sources.project_id or (
        cursor is not None and cursor.project_id != sources.project_id
    ):
        raise ContextPackError("the planning state names a different project")
    if cursor is not None and master_plan_digest(master_plan) != cursor.master_plan_digest:
        raise ContextPackError("the master plan is not the one the cursor is bound to")


def build_jit_replan_context_pack(
    sources: ContextSources,
    *,
    master_plan: MasterPlan,
    phase_plan: PhasePlan,
    cursor: ProjectCursor,
    basis: ReplanBasis,
    finalized_phases: Sequence[tuple[PhaseId, str]] = (),
) -> ContextPack:
    """A fresh JIT Planner's pack, from the frozen plan, the cursor and the accepted basis.

    The completed prefix of *phase_plan* is immutable history; the rest is the
    provisional suffix. No Implementer or Reviewer material is admitted.
    *finalized_phases* are ``(phase_id, identity)`` references to the verified
    finalizations of completed earlier Phases (Phase 12.8); they join the same
    completed-history section as compact references only, and the member is absent
    when there are none.
    """
    operation = ContextOperation.JIT_REPLAN
    _require_planning_state(sources, master_plan, cursor)
    if cursor.current_phase is None or phase_plan.phase_id != cursor.current_phase:
        raise ContextPackError("the phase plan is not the cursor's current phase")
    history = _completed_history(
        cursor, cursor.current_phase, phase_plan.subphases, finalized_phases
    )
    count = sum(e.phase_id == cursor.current_phase for e in cursor.completed_subphases)

    phase = cursor.current_phase.root
    identity = ContextIdentity(
        project_id=sources.project_id, phase_id=cursor.current_phase, role=AgentRole.PLANNER
    )
    return _pack(
        operation,
        identity,
        [
            *_guidance(sources, operation),
            _master_plan(master_plan),
            history,
            _section(
                _K.PROVISIONAL_OUTLINE,
                _TITLE_UNFINISHED,
                f"project-cursor:revision-{cursor.revision}#unfinished",
                {
                    "phase_id": phase,
                    "subphases": [o.model_dump(mode="json") for o in phase_plan.subphases[count:]],
                },
            ),
            _accepted_basis(basis),
        ],
    )


def _accepted_history(
    cursor: ProjectCursor | None,
    basis: ReplanBasis | None,
    phase_id: PhaseId,
    outlines: Sequence[SubphaseOutline],
    finalized_phases: Sequence[tuple[PhaseId, str]],
) -> tuple[ContextSection, ContextSection] | None:
    """Completed history and the accepted basis: both exactly when something was accepted.

    The first-ever planning of a project legitimately has neither and fabricates neither;
    once history exists, planning without either is refused.
    """
    accepted = cursor is not None and bool(cursor.completed_subphases)
    if basis is None:
        if accepted:
            raise ContextPackError("the accepted repository basis is required and is missing")
        return None
    if not accepted:
        raise ContextPackError("an accepted basis was supplied without accepted history")
    assert cursor is not None
    last = cursor.completed_subphases[-1]
    if (basis.phase_id, basis.subphase_id, basis.run_id, basis.contract_digest) != (
        last.phase_id,
        last.subphase_id,
        last.run_id,
        last.contract_digest,
    ):
        raise ContextPackError("the accepted basis is not the latest accepted sub-phase")
    return (
        _completed_history(cursor, phase_id, outlines, finalized_phases),
        _accepted_basis(basis),
    )


def _phase_plan_digest(phase_plan: PhasePlan) -> str:
    return hashlib.sha256(_json(phase_plan.model_dump(mode="json")).encode("utf-8")).hexdigest()


def build_contract_planning_context_pack(
    sources: ContextSources,
    *,
    master_plan: MasterPlan,
    phase_plan: PhasePlan,
    target_subphase_id: SubphaseId,
    cursor: ProjectCursor | None,
    basis: ReplanBasis | None,
    finalized_phases: Sequence[tuple[PhaseId, str]] = (),
) -> ContextPack:
    """The next-Contract Planner's pack (12.10-R1): plan, outline, history and accepted basis.

    The frozen Master Plan and the current published Phase plan are always carried, exactly
    once; the trailer names only the target. Completed history and the accepted basis join
    exactly when something has been accepted. There is no Contract yet and none is invented.
    Deliberately not part of the frozen ``__all__`` surface.
    """
    operation = ContextOperation.CONTRACT_PLANNING
    _require_planning_state(sources, master_plan, cursor)
    if all(p.phase_id != phase_plan.phase_id for p in master_plan.phases):
        raise ContextPackError("the phase plan is not a phase of the master plan")
    if all(o.subphase_id != target_subphase_id for o in phase_plan.subphases):
        raise ContextPackError("the target sub-phase is not in the phase plan")
    history = _accepted_history(
        cursor, basis, phase_plan.phase_id, phase_plan.subphases, finalized_phases
    )
    digest = _phase_plan_digest(phase_plan)
    outline = _section(
        _K.PROVISIONAL_OUTLINE,
        _TITLE_PHASE_PLAN,
        f"phase-plan:{digest}",
        {"phase_plan_digest": digest, "phase_plan": phase_plan.model_dump(mode="json")},
        version=digest,
    )
    identity = ContextIdentity(
        project_id=sources.project_id,
        phase_id=phase_plan.phase_id,
        subphase_id=target_subphase_id,
        role=AgentRole.PLANNER,
    )
    sections = [*_guidance(sources, operation), _master_plan(master_plan)]
    if history is None:
        sections.append(outline)
    else:
        sections.extend((history[0], outline, history[1]))
    return _pack(operation, identity, sections)


def build_phase_planning_context_pack(
    sources: ContextSources,
    *,
    master_plan: MasterPlan,
    phase_id: PhaseId,
    current_outline: PhasePlan | None,
    cursor: ProjectCursor | None,
    basis: ReplanBasis | None,
    finalized_phases: Sequence[tuple[PhaseId, str]] = (),
) -> ContextPack:
    """The Phase-outline Planner's pack (12.10-R1): Master Plan, then history and basis.

    The outline being created is never in its own pack; a current provisional outline stays
    request material in the trailer. Deliberately not part of the frozen ``__all__`` surface.
    """
    operation = ContextOperation.PHASE_PLANNING
    _require_planning_state(sources, master_plan, cursor)
    if all(p.phase_id != phase_id for p in master_plan.phases):
        raise ContextPackError("the target phase is not in the master plan")
    outlines = current_outline.subphases if current_outline is not None else ()
    history = _accepted_history(cursor, basis, phase_id, outlines, finalized_phases)
    identity = ContextIdentity(
        project_id=sources.project_id, phase_id=phase_id, role=AgentRole.PLANNER
    )
    return _pack(
        operation,
        identity,
        [*_guidance(sources, operation), _master_plan(master_plan), *(history or ())],
    )


def build_gate_remediation_context_pack(
    sources: ContextSources,
    *,
    master_plan: MasterPlan,
    phase_plan: PhasePlan,
    cursor: ProjectCursor,
    basis: PhaseGateBasis,
    decision: PhaseGateDecision,
    evidence: PhaseGateEvidence,
    remediation_subphase_id: SubphaseId,
    finalized_phases: Sequence[tuple[PhaseId, str]] = (),
) -> ContextPack:
    """The gate-remediation Planner's pack (12.10-R1).

    Stable project context, the Phase's completed history, the audited gate basis, and the
    failed attempt's decision and command evidence. The failure stays volatile execution
    evidence: it explains why the frozen requirements are unmet and never becomes one.
    Deliberately not part of the frozen ``__all__`` surface.
    """
    operation = ContextOperation.GATE_REMEDIATION
    _require_planning_state(sources, master_plan, cursor)
    if (decision.phase_id, decision.gate_attempt, decision.basis_commit) != (
        basis.phase_id,
        basis.gate_attempt,
        basis.commit,
    ) or (evidence.phase_id, evidence.gate_attempt, evidence.basis_commit) != (
        basis.phase_id,
        basis.gate_attempt,
        basis.commit,
    ):
        raise ContextPackError("the gate artifacts belong to different attempts")
    if phase_plan.phase_id != basis.phase_id:
        raise ContextPackError("the phase plan is not the gated phase")
    attempt = f"phase-gate:{basis.phase_id.root}/attempt-{basis.gate_attempt}"
    identity = ContextIdentity(
        project_id=sources.project_id,
        phase_id=basis.phase_id,
        subphase_id=remediation_subphase_id,
        role=AgentRole.PLANNER,
    )
    return _pack(
        operation,
        identity,
        [
            *_guidance(sources, operation),
            _master_plan(master_plan),
            _completed_history(cursor, basis.phase_id, phase_plan.subphases, finalized_phases),
            _section(
                _K.REPOSITORY_STATE,
                _TITLE_ACCEPTED_BASIS,
                f"git:{basis.commit}#accepted-basis",
                basis.model_dump(mode="json"),
                version=basis.commit,
            ),
            _section(
                _K.REVIEW_FINDINGS,
                _TITLE_GATE_DECISION,
                f"{attempt}#decision",
                decision.model_dump(mode="json"),
            ),
            _section(
                _K.VERIFICATION_REPORT,
                _TITLE_GATE_EVIDENCE,
                f"{attempt}#evidence",
                evidence.model_dump(mode="json"),
            ),
        ],
    )


__all__ = [
    "CONTEXT_DOCUMENTS_MAX_COUNT",
    "CONTEXT_DOCUMENTS_MAX_TOTAL_BYTES",
    "CONTEXT_DOCUMENT_MAX_BYTES",
    "ContextSelection",
    "ContextSources",
    "SelectedContextDocument",
    "build_implementer_context_pack",
    "build_jit_replan_context_pack",
    "build_reviewer_context_pack",
    "build_rework_context_pack",
    "build_test_authoring_context_pack",
]
