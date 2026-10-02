"""Typed, authority-preserving role handoffs (Phase 11.4).

When orchestration carries information from one role to the next, the host must
keep track of where each fact came from and what it is allowed to influence.
Authority does not increase through transmission: a handoff may quote, label and
serialize an authoritative artifact, but it never turns evidence into authority.

Authority is a semantic category, not a rank (:class:`AuthorityKind`). Each
section model pins its own category with a ``Literal`` field, so a caller cannot
relabel an artifact it does not own. Handoffs are role-specific typed models, not
a dictionary bag:

* :class:`PlannerTestHandoff` -- frozen Contract and the test paths to author;
* :class:`ImplementerHandoff` -- frozen Contract, protected tests, repository basis;
* :class:`ReworkHandoff` -- the same original authority, plus retry control and
  Review Findings and prior verification as *evidence / repair guidance*;
* :class:`ReviewerHandoff` -- Contract and tests as authority, with the
  Implementer report, verification and repository diff as evidence, and any prior
  Review Findings as history.

A handoff is derived, replaceable and reconstructable: it is neither a second
Contract store nor a progress store. The ``build_*`` functions rebuild a handoff
from durable artifacts and Git alone (the frozen Contract, the transaction
journal, the attempt's evidence files and the worktree), never from an in-memory
object a previous role produced, and they refuse (:class:`HandoffError`) when a
canonical reference has drifted. The ``render_*`` functions turn a typed handoff
into prompt text deterministically; the typed objects, not the headings, are the
machine boundary.

Nothing here calls a model, summarizes, ranks relevance, or optimizes context.
"""

from __future__ import annotations

import json
from collections.abc import Callable, Sequence
from enum import StrEnum
from pathlib import Path
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, StringConstraints, model_validator

from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    ExecutionEventKind,
    ImplementationReport,
    PhaseId,
    ReviewDecision,
    RunId,
    SubphaseContract,
    SubphaseId,
    VerificationReport,
)
from lockstep.evidence_store import (
    EvidenceStoreError,
    implementation_report_path,
    load_implementation_report,
    load_verification_evidence,
    load_verification_report,
    verification_report_path,
)
from lockstep.git import GitCommandError, inspect_repository
from lockstep.git.evidence import changes_since, commit_parent, is_ancestor
from lockstep.persistence import ExecutionEvent, read_events
from lockstep.project_cursor import contract_digest
from lockstep.verification_stack import VerificationEvidenceRecord

_Sha256Hex = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
_GitObjectId = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{40,64}$")]

DEFAULT_MAX_PATCH_BYTES = 65_536

REVIEWER_IDENTITY_HEADER = (
    "\n\n---\nReviewer identity (host-supplied, deterministic; "
    "the ReviewDecision must copy these values exactly):\n"
)

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


class HandoffError(Exception):
    """A handoff cannot be built because durable evidence is missing or has drifted.

    Carries a short, bounded, deterministic ``reason`` that never includes
    artifact contents. A stale handoff is never launched; authority is never
    regenerated from nearby files when an identity check fails.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"handoff error: {reason}")


class AuthorityKind(StrEnum):
    """What a datum is allowed to influence. A category, never a numeric rank."""

    FROZEN_REQUIREMENT = "frozen_requirement"
    PROTECTED_ACCEPTANCE = "protected_acceptance"
    PROVISIONAL_PLAN = "provisional_plan"
    CONTROL_DECISION = "control_decision"
    EXECUTION_EVIDENCE = "execution_evidence"
    ADVISORY_CONTEXT = "advisory_context"


class _HandoffModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


# --- Sections -----------------------------------------------------------------------------


class HandoffIdentity(_HandoffModel):
    """Host-owned identity of the invocation a handoff is for."""

    run_id: RunId
    phase_id: PhaseId
    subphase_id: SubphaseId
    attempt: AttemptNumber
    role: AgentRole


class ContractAuthority(_HandoffModel):
    """The frozen Sub-phase Contract: the requirement authority."""

    authority: Literal[AuthorityKind.FROZEN_REQUIREMENT] = AuthorityKind.FROZEN_REQUIREMENT
    contract_digest: _Sha256Hex
    contract: SubphaseContract

    @model_validator(mode="after")
    def _digest_names_the_contract(self) -> ContractAuthority:
        if contract_digest(self.contract) != self.contract_digest:
            raise ValueError("contract digest does not name the carried contract")
        return self


class RequiredTestPaths(_HandoffModel):
    """The exact test paths the Contract requires; they come from the frozen Contract."""

    authority: Literal[AuthorityKind.FROZEN_REQUIREMENT] = AuthorityKind.FROZEN_REQUIREMENT
    paths: Annotated[tuple[str, ...], Field(min_length=1)]


class ProtectedAcceptance(_HandoffModel):
    """The frozen tests: protected acceptance artifacts, identified by the host."""

    authority: Literal[AuthorityKind.PROTECTED_ACCEPTANCE] = AuthorityKind.PROTECTED_ACCEPTANCE
    test_paths: Annotated[tuple[str, ...], Field(min_length=1)]
    test_commit_sha: _GitObjectId


class RepositoryBasis(_HandoffModel):
    """The repository state the attempt starts from; evidence, read from Git."""

    authority: Literal[AuthorityKind.EXECUTION_EVIDENCE] = AuthorityKind.EXECUTION_EVIDENCE
    branch: str | None
    basis_commit_sha: _GitObjectId
    test_commit_sha: _GitObjectId


class ImplementerEvidence(_HandoffModel):
    """The Implementer's own report: a claim, never authority."""

    authority: Literal[AuthorityKind.EXECUTION_EVIDENCE] = AuthorityKind.EXECUTION_EVIDENCE
    report: ImplementationReport


class VerificationEvidence(_HandoffModel):
    """The verification result and its bounded command evidence: objective evidence."""

    authority: Literal[AuthorityKind.EXECUTION_EVIDENCE] = AuthorityKind.EXECUTION_EVIDENCE
    report: VerificationReport
    commands: VerificationEvidenceRecord

    @model_validator(mode="after")
    def _evidence_belongs_to_the_report(self) -> VerificationEvidence:
        if (self.report.phase_id, self.report.subphase_id, self.report.attempt) != (
            self.commands.phase_id,
            self.commands.subphase_id,
            self.commands.attempt,
        ):
            raise ValueError("command evidence does not belong to the verification report")
        return self


class FileChange(_HandoffModel):
    path: str
    status: Literal["added", "modified", "deleted"]
    patch: str
    patch_truncated: bool


class RepositoryEvidence(_HandoffModel):
    """What differs from the frozen test commit in the worktree: repository evidence."""

    authority: Literal[AuthorityKind.EXECUTION_EVIDENCE] = AuthorityKind.EXECUTION_EVIDENCE
    base_commit_sha: _GitObjectId
    changes: tuple[FileChange, ...]


class ReviewHistory(_HandoffModel):
    """Prior Review Decisions and findings: review history, evidence about earlier attempts."""

    authority: Literal[AuthorityKind.EXECUTION_EVIDENCE] = AuthorityKind.EXECUTION_EVIDENCE
    decisions: tuple[ReviewDecision, ...]


class ReviewEvidence(_HandoffModel):
    """A Review Decision handed to a fresh Implementer as repair guidance, not authority."""

    authority: Literal[AuthorityKind.EXECUTION_EVIDENCE] = AuthorityKind.EXECUTION_EVIDENCE
    decision: ReviewDecision


class RetryControl(_HandoffModel):
    """The host-owned retry authority for a resumed attempt.

    ``authorized_paths`` and ``instructions`` come only from a Planner decision
    carried by an escalation resume. A Review ``REWORK`` confers no paths and no
    instructions: the Review Findings are evidence, not control.
    """

    authority: Literal[AuthorityKind.CONTROL_DECISION] = AuthorityKind.CONTROL_DECISION
    kind: Literal["review_rework", "escalation_resume"]
    attempt: AttemptNumber
    authorized_paths: tuple[str, ...] = ()
    instructions: tuple[str, ...] = ()


# --- Handoffs ------------------------------------------------------------------------------


class PlannerTestHandoff(_HandoffModel):
    identity: HandoffIdentity
    contract: ContractAuthority
    test_paths: RequiredTestPaths


class ImplementerHandoff(_HandoffModel):
    identity: HandoffIdentity
    contract: ContractAuthority
    protected_tests: ProtectedAcceptance
    basis: RepositoryBasis


class ReworkHandoff(_HandoffModel):
    identity: HandoffIdentity
    contract: ContractAuthority
    protected_tests: ProtectedAcceptance
    basis: RepositoryBasis
    retry: RetryControl
    review: ReviewEvidence | None = None
    verification: VerificationEvidence | None = None


class ReviewerHandoff(_HandoffModel):
    identity: HandoffIdentity
    contract: ContractAuthority | None
    protected_tests: ProtectedAcceptance
    implementer: ImplementerEvidence
    verification: VerificationEvidence
    repository: RepositoryEvidence
    history: ReviewHistory


# --- Deterministic rendering -----------------------------------------------------------------


def _json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _section(title: str, section: BaseModel, authority: AuthorityKind) -> str:
    return f"\n\n---\n## {title} [{authority.value}]\n{_json(section.model_dump(mode='json'))}\n"


def render_planner_test_handoff(handoff: PlannerTestHandoff) -> str:
    return _section(_TITLE_FROZEN, handoff.contract, handoff.contract.authority) + _section(
        _TITLE_REQUIRED_TESTS, handoff.test_paths, handoff.test_paths.authority
    )


def _render_attempt_start(
    contract: ContractAuthority, protected: ProtectedAcceptance, basis: RepositoryBasis
) -> str:
    return (
        _section(_TITLE_FROZEN, contract, contract.authority)
        + _section(_TITLE_PROTECTED, protected, protected.authority)
        + _section(_TITLE_BASIS, basis, basis.authority)
    )


def render_implementer_handoff(handoff: ImplementerHandoff) -> str:
    return _render_attempt_start(handoff.contract, handoff.protected_tests, handoff.basis)


def render_rework_handoff(handoff: ReworkHandoff) -> str:
    text = _render_attempt_start(handoff.contract, handoff.protected_tests, handoff.basis)
    text += _section(_TITLE_RETRY, handoff.retry, handoff.retry.authority)
    if handoff.review is not None:
        text += _section(_TITLE_REVIEW_EVIDENCE, handoff.review, handoff.review.authority)
    if handoff.verification is not None:
        text += _section(_TITLE_VERIFICATION, handoff.verification, handoff.verification.authority)
    return text


def render_reviewer_handoff(handoff: ReviewerHandoff) -> str:
    text = ""
    if handoff.contract is not None:
        text += _section(_TITLE_FROZEN, handoff.contract, handoff.contract.authority)
    text += _section(_TITLE_PROTECTED, handoff.protected_tests, handoff.protected_tests.authority)
    text += _section(_TITLE_IMPLEMENTER, handoff.implementer, handoff.implementer.authority)
    text += _section(_TITLE_VERIFICATION, handoff.verification, handoff.verification.authority)
    text += _section(_TITLE_REPOSITORY, handoff.repository, handoff.repository.authority)
    text += _section(_TITLE_HISTORY, handoff.history, handoff.history.authority)
    identity = {
        "phase_id": handoff.identity.phase_id.root,
        "subphase_id": handoff.identity.subphase_id.root,
        "attempt": handoff.identity.attempt.root,
        "role": handoff.identity.role.value,
    }
    return text + REVIEWER_IDENTITY_HEADER + _json(identity) + "\n"


# --- Reconstruction from durable state --------------------------------------------------------


def _identity(
    run_id: RunId,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
    role: AgentRole,
) -> HandoffIdentity:
    return HandoffIdentity(
        run_id=run_id, phase_id=phase_id, subphase_id=subphase_id, attempt=attempt, role=role
    )


def _contract_authority(contract: SubphaseContract) -> ContractAuthority:
    return ContractAuthority(contract_digest=contract_digest(contract), contract=contract)


def frozen_test_commit(runtime_dir: Path) -> str:
    """The frozen-test commit the transaction journal recorded, exactly once."""
    shas = [
        event.detail
        for event in read_events(Path(runtime_dir) / "events.jsonl")
        if isinstance(event, ExecutionEvent) and event.kind is ExecutionEventKind.TESTS_FROZEN
    ]
    if len(shas) != 1 or not shas[0]:
        raise HandoffError("the frozen test commit is not recorded exactly once")
    return shas[0]


def _protected_state(
    runtime_dir: Path, worktree_path: Path, test_paths: Sequence[str]
) -> tuple[ProtectedAcceptance, RepositoryBasis]:
    """Verify the frozen-test identity still holds and derive the protected/basis sections."""
    test_sha = frozen_test_commit(runtime_dir)
    try:
        snapshot = inspect_repository(worktree_path)
        if not is_ancestor(snapshot.root, test_sha, "HEAD"):
            raise HandoffError("the frozen test commit is no longer part of the run history")
        if set(snapshot.dirty_paths) & set(test_paths):
            raise HandoffError("a protected test differs from its frozen commit")
        basis_sha = commit_parent(snapshot.root, test_sha)
    except GitCommandError as exc:
        raise HandoffError("the run worktree is not readable") from exc
    return (
        ProtectedAcceptance(test_paths=tuple(test_paths), test_commit_sha=test_sha),
        RepositoryBasis(
            branch=snapshot.branch, basis_commit_sha=basis_sha, test_commit_sha=test_sha
        ),
    )


def _load_verification(
    runtime_dir: Path,
    *,
    run_id: RunId,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
) -> VerificationEvidence | None:
    try:
        report = load_verification_report(
            runtime_dir, phase_id=phase_id, subphase_id=subphase_id, attempt=attempt
        )
        record = load_verification_evidence(
            runtime_dir,
            run_id=run_id,
            phase_id=phase_id,
            subphase_id=subphase_id,
            attempt=attempt,
        )
    except EvidenceStoreError as exc:
        raise HandoffError(exc.reason) from exc
    if report is None or record is None:
        return None
    return VerificationEvidence(report=report, commands=record)


def _attempt(value: int) -> AttemptNumber:
    return AttemptNumber.model_validate(value)


def _implementation_report_exists(runtime_dir: Path, attempt: AttemptNumber) -> bool:
    return implementation_report_path(runtime_dir, attempt).exists()


def _verification_report_exists(runtime_dir: Path, attempt: AttemptNumber) -> bool:
    return verification_report_path(runtime_dir, attempt).exists()


def _latest_attempt_with(
    runtime_dir: Path,
    up_to: AttemptNumber,
    exists: Callable[[Path, AttemptNumber], bool],
) -> AttemptNumber | None:
    """The newest attempt number at or below *up_to* for which *exists* holds."""
    for number in range(up_to.root, 0, -1):
        candidate = _attempt(number)
        if exists(runtime_dir, candidate):
            return candidate
    return None


def build_planner_test_handoff(
    *,
    run_id: RunId,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    contract: SubphaseContract,
) -> PlannerTestHandoff:
    """The test-authoring handoff: the frozen Contract and the exact tests it requires."""
    return PlannerTestHandoff(
        identity=_identity(run_id, phase_id, subphase_id, _attempt(1), AgentRole.PLANNER),
        contract=_contract_authority(contract),
        test_paths=RequiredTestPaths(paths=tuple(spec.path for spec in contract.tests)),
    )


def build_implementer_handoff(
    *,
    runtime_dir: Path,
    worktree_path: Path,
    run_id: RunId,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
    contract: SubphaseContract,
    test_paths: Sequence[str],
) -> ImplementerHandoff:
    """The first-attempt Implementer handoff, derived from the frozen Contract and Git."""
    protected, basis = _protected_state(runtime_dir, worktree_path, test_paths)
    return ImplementerHandoff(
        identity=_identity(run_id, phase_id, subphase_id, attempt, AgentRole.IMPLEMENTER),
        contract=_contract_authority(contract),
        protected_tests=protected,
        basis=basis,
    )


def build_rework_handoff(
    *,
    runtime_dir: Path,
    worktree_path: Path,
    run_id: RunId,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
    contract: SubphaseContract,
    test_paths: Sequence[str],
    retry: RetryControl,
    review_decision: ReviewDecision | None,
) -> ReworkHandoff:
    """A fresh Implementer's retry handoff: original authority, retry control, repair evidence."""
    protected, basis = _protected_state(runtime_dir, worktree_path, test_paths)
    previous = (
        _latest_attempt_with(runtime_dir, _attempt(attempt.root - 1), _verification_report_exists)
        if attempt.root > 1
        else None
    )
    verification = (
        None
        if previous is None
        else _load_verification(
            runtime_dir,
            run_id=run_id,
            phase_id=phase_id,
            subphase_id=subphase_id,
            attempt=previous,
        )
    )
    return ReworkHandoff(
        identity=_identity(run_id, phase_id, subphase_id, attempt, AgentRole.IMPLEMENTER),
        contract=_contract_authority(contract),
        protected_tests=protected,
        basis=basis,
        retry=retry,
        review=None if review_decision is None else ReviewEvidence(decision=review_decision),
        verification=verification,
    )


def build_reviewer_handoff(
    *,
    runtime_dir: Path,
    worktree_path: Path,
    run_id: RunId,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
    contract: SubphaseContract | None,
    test_paths: Sequence[str],
    prior_decisions: Sequence[ReviewDecision] = (),
    max_patch_bytes: int = DEFAULT_MAX_PATCH_BYTES,
) -> ReviewerHandoff:
    """The Reviewer handoff, rebuilt from the Contract, the journal, durable evidence and Git.

    The evidence is the newest attempt at or before *attempt* that recorded an
    implementation report, so a Reviewer resumed after the Implementer's work
    still sees that work. Nothing from a prior in-memory result is consulted.
    """
    protected, basis = _protected_state(runtime_dir, worktree_path, test_paths)
    evidence_attempt = _latest_attempt_with(runtime_dir, attempt, _implementation_report_exists)
    if evidence_attempt is None:
        raise HandoffError("no implementation report is recorded for this run")
    try:
        report = load_implementation_report(
            runtime_dir, phase_id=phase_id, subphase_id=subphase_id, attempt=evidence_attempt
        )
    except EvidenceStoreError as exc:
        raise HandoffError(exc.reason) from exc
    if report is None:
        raise HandoffError("no implementation report is recorded for this run")
    verification = _load_verification(
        runtime_dir,
        run_id=run_id,
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=evidence_attempt,
    )
    if verification is None:
        raise HandoffError("no verification evidence is recorded for this attempt")

    try:
        changes = changes_since(
            Path(worktree_path), basis.test_commit_sha, max_patch_bytes=max_patch_bytes
        )
    except GitCommandError as exc:
        raise HandoffError("the run worktree is not readable") from exc

    return ReviewerHandoff(
        identity=_identity(run_id, phase_id, subphase_id, attempt, AgentRole.REVIEWER),
        contract=None if contract is None else _contract_authority(contract),
        protected_tests=protected,
        implementer=ImplementerEvidence(report=report),
        verification=verification,
        repository=RepositoryEvidence(
            base_commit_sha=basis.test_commit_sha,
            changes=tuple(
                FileChange(
                    path=change.path,
                    status=change.status,  # type: ignore[arg-type]
                    patch=change.patch,
                    patch_truncated=change.patch_truncated,
                )
                for change in changes
            ),
        ),
        history=ReviewHistory(decisions=tuple(prior_decisions)),
    )
