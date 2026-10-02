"""Phase 11.4: typed, authority-preserving role handoffs and their deterministic rendering.

A handoff quotes, labels and serializes authoritative artifacts; it never
turns evidence into authority. These tests exercise the typed models and the
renderers directly, with constructed (not provider-produced) inputs, so the
authority/evidence separation is proven independently of any run.

Baseline classification: every test in this module is RED at entry
(``lockstep.handoff`` does not exist).
"""

from __future__ import annotations

import json
import re
import sys

import pytest
from pydantic import ValidationError

from lockstep.domain import (
    AcceptanceCriterion,
    AgentRole,
    AttemptNumber,
    ImplementationReport,
    PhaseId,
    ReviewDecision,
    ReviewFinding,
    ReviewVerdict,
    RunId,
    SubphaseContract,
    SubphaseId,
    TestExpectation,
    TestSpecification,
    VerificationReport,
)
from lockstep.handoff import (
    AuthorityKind,
    ContractAuthority,
    FileChange,
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
    render_implementer_handoff,
    render_planner_test_handoff,
    render_reviewer_handoff,
    render_rework_handoff,
)
from lockstep.project_cursor import contract_digest
from lockstep.verification_stack import CommandEvidence, VerificationEvidenceRecord

_RUN = RunId.model_validate("run-01-01")
_PHASE = PhaseId.model_validate("01")
_SUBPHASE = SubphaseId.model_validate("01")
_SHA = "a" * 40
_BASIS_SHA = "b" * 40
_SCOPE_CLAIM = "I also need src/outside_scope.py"
_EXPANSION_FINDING = "also add unrelated endpoint Z"

_SECTION = re.compile(r"^## (?P<title>[A-Z /]+?) \[(?P<authority>[a-z_]+)\]$", re.MULTILINE)


def _attempt(value: int) -> AttemptNumber:
    return AttemptNumber.model_validate(value)


def _sections(text: str) -> dict[str, str]:
    matches = list(_SECTION.finditer(text))
    return {
        m["title"]: text[m.end() : matches[i + 1].start() if i + 1 < len(matches) else len(text)]
        for i, m in enumerate(matches)
    }


def _authorities(text: str) -> dict[str, str]:
    return {m["title"]: m["authority"] for m in _SECTION.finditer(text)}


def _contract() -> SubphaseContract:
    return SubphaseContract(
        phase_id=_PHASE,
        subphase_id=_SUBPHASE,
        title="Feature 01",
        objective="Provide feature 01.",
        acceptance_criteria=(AcceptanceCriterion(criterion_id="AC-1", description="It works."),),
        tests=(
            TestSpecification(
                path="tests/test_feature_01.py",
                expectation=TestExpectation.RED,
                acceptance_criteria=("AC-1",),
            ),
        ),
        allowed_paths=("feature_01.py",),
        verification_commands=("pytest tests/test_feature_01.py",),
    )


def _identity(role: AgentRole, attempt: int = 1) -> HandoffIdentity:
    return HandoffIdentity(
        run_id=_RUN, phase_id=_PHASE, subphase_id=_SUBPHASE, attempt=_attempt(attempt), role=role
    )


def _contract_authority() -> ContractAuthority:
    contract = _contract()
    return ContractAuthority(contract_digest=contract_digest(contract), contract=contract)


def _protected() -> ProtectedAcceptance:
    return ProtectedAcceptance(test_paths=("tests/test_feature_01.py",), test_commit_sha=_SHA)


def _basis() -> RepositoryBasis:
    return RepositoryBasis(
        branch="lockstep/run/run-01-01", basis_commit_sha=_BASIS_SHA, test_commit_sha=_SHA
    )


def _implementer_evidence(attempt: int = 1) -> ImplementerEvidence:
    return ImplementerEvidence(
        report=ImplementationReport(
            phase_id=_PHASE,
            subphase_id=_SUBPHASE,
            attempt=_attempt(attempt),
            summary="implemented feature 01",
            changed_files=("feature_01.py", "src/outside_scope.py"),
            deviations=(_SCOPE_CLAIM,),
        )
    )


def _verification(attempt: int = 1) -> VerificationEvidence:
    return VerificationEvidence(
        report=VerificationReport(
            phase_id=_PHASE,
            subphase_id=_SUBPHASE,
            attempt=_attempt(attempt),
            passed=True,
            commands=("pytest tests/test_feature_01.py",),
        ),
        commands=VerificationEvidenceRecord(
            run_id=_RUN,
            phase_id=_PHASE,
            subphase_id=_SUBPHASE,
            attempt=_attempt(attempt),
            max_output_bytes=4096,
            commands=(
                CommandEvidence(
                    argv=(sys.executable, "-m", "pytest"),
                    exit_code=0,
                    stdout="1 passed",
                    stderr="",
                    stdout_truncated=False,
                    stderr_truncated=False,
                ),
            ),
        ),
    )


def _repository() -> RepositoryEvidence:
    return RepositoryEvidence(
        base_commit_sha=_SHA,
        changes=(
            FileChange(
                path="feature_01.py",
                status="added",
                patch="+def answer() -> int:\n+    return 1\n",
                patch_truncated=False,
            ),
        ),
    )


def _rework_decision() -> ReviewDecision:
    return ReviewDecision(
        phase_id=_PHASE,
        subphase_id=_SUBPHASE,
        attempt=_attempt(1),
        verdict=ReviewVerdict.REWORK,
        summary="needs another pass",
        findings=(
            ReviewFinding(
                summary=_EXPANSION_FINDING,
                evidence="the reviewer asked for it",
                acceptance_criterion_id="AC-1",
            ),
        ),
    )


def _reviewer_handoff(*, with_history: bool = False) -> ReviewerHandoff:
    return ReviewerHandoff(
        identity=_identity(AgentRole.REVIEWER),
        contract=_contract_authority(),
        protected_tests=_protected(),
        implementer=_implementer_evidence(),
        verification=_verification(),
        repository=_repository(),
        history=ReviewHistory(decisions=(_rework_decision(),) if with_history else ()),
    )


# --- vocabulary and typing --------------------------------------------------------------


def test_authority_is_a_semantic_category_not_a_numeric_rank() -> None:
    assert {kind.name for kind in AuthorityKind} == {
        "FROZEN_REQUIREMENT",
        "PROTECTED_ACCEPTANCE",
        "PROVISIONAL_PLAN",
        "CONTROL_DECISION",
        "EXECUTION_EVIDENCE",
        "ADVISORY_CONTEXT",
    }
    assert all(isinstance(kind.value, str) for kind in AuthorityKind)


def test_every_section_pins_its_own_authority_category() -> None:
    contract = _contract()
    with pytest.raises(ValidationError):
        ContractAuthority(
            authority=AuthorityKind.EXECUTION_EVIDENCE,
            contract_digest=contract_digest(contract),
            contract=contract,
        )
    with pytest.raises(ValidationError):
        ProtectedAcceptance(
            authority=AuthorityKind.ADVISORY_CONTEXT,
            test_paths=("tests/test_feature_01.py",),
            test_commit_sha=_SHA,
        )
    with pytest.raises(ValidationError):
        ImplementerEvidence(
            authority=AuthorityKind.FROZEN_REQUIREMENT,
            report=_implementer_evidence().report,
        )
    assert _contract_authority().authority is AuthorityKind.FROZEN_REQUIREMENT
    assert _protected().authority is AuthorityKind.PROTECTED_ACCEPTANCE
    assert _implementer_evidence().authority is AuthorityKind.EXECUTION_EVIDENCE
    assert _verification().authority is AuthorityKind.EXECUTION_EVIDENCE


def test_handoffs_are_frozen_typed_models_not_dictionary_bags() -> None:
    handoff = _reviewer_handoff()

    with pytest.raises(ValidationError):
        handoff.contract = None  # type: ignore[misc]
    with pytest.raises(ValidationError):
        ReviewerHandoff.model_validate({**handoff.model_dump(), "scribe_summary": "x"})
    for model in (
        ReviewerHandoff,
        ImplementerHandoff,
        ReworkHandoff,
        PlannerTestHandoff,
    ):
        assert not any("dict" in str(field.annotation) for field in model.model_fields.values())


# --- planner test-authoring handoff -------------------------------------------------------


def test_the_planner_test_handoff_labels_the_contract_as_the_requirement_authority() -> None:
    handoff = PlannerTestHandoff(
        identity=_identity(AgentRole.PLANNER),
        contract=_contract_authority(),
        test_paths=RequiredTestPaths(paths=("tests/test_feature_01.py",)),
    )

    text = render_planner_test_handoff(handoff)

    assert _authorities(text) == {
        "FROZEN REQUIREMENT AUTHORITY": "frozen_requirement",
        "REQUIRED TEST PATHS": "frozen_requirement",
    }
    body = json.JSONDecoder().raw_decode(_sections(text)["FROZEN REQUIREMENT AUTHORITY"].lstrip())[
        0
    ]
    assert body["contract_digest"] == contract_digest(_contract())
    assert render_planner_test_handoff(handoff) == text


# --- implementer handoff -------------------------------------------------------------------


def test_the_implementer_handoff_binds_contract_identity_tests_paths_and_basis() -> None:
    handoff = ImplementerHandoff(
        identity=_identity(AgentRole.IMPLEMENTER),
        contract=_contract_authority(),
        protected_tests=_protected(),
        basis=_basis(),
    )

    text = render_implementer_handoff(handoff)
    sections = _sections(text)

    assert list(sections) == [
        "FROZEN REQUIREMENT AUTHORITY",
        "PROTECTED ACCEPTANCE ARTIFACT",
        "REPOSITORY BASIS",
    ]
    assert _authorities(text)["PROTECTED ACCEPTANCE ARTIFACT"] == "protected_acceptance"
    assert _authorities(text)["REPOSITORY BASIS"] == "execution_evidence"
    assert contract_digest(_contract()) in sections["FROZEN REQUIREMENT AUTHORITY"]
    assert "feature_01.py" in sections["FROZEN REQUIREMENT AUTHORITY"]
    assert _SHA in sections["PROTECTED ACCEPTANCE ARTIFACT"]
    assert "tests/test_feature_01.py" in sections["PROTECTED ACCEPTANCE ARTIFACT"]
    assert _BASIS_SHA in sections["REPOSITORY BASIS"]
    assert render_implementer_handoff(handoff) == text


# --- reviewer handoff ------------------------------------------------------------------------


def test_the_reviewer_handoff_keeps_authority_and_evidence_in_separate_labeled_sections() -> None:
    text = render_reviewer_handoff(_reviewer_handoff(with_history=True))

    assert _authorities(text) == {
        "FROZEN REQUIREMENT AUTHORITY": "frozen_requirement",
        "PROTECTED ACCEPTANCE ARTIFACT": "protected_acceptance",
        "IMPLEMENTER EVIDENCE": "execution_evidence",
        "VERIFICATION EVIDENCE": "execution_evidence",
        "REPOSITORY EVIDENCE": "execution_evidence",
        "REVIEW HISTORY": "execution_evidence",
    }
    assert list(_sections(text)) == [
        "FROZEN REQUIREMENT AUTHORITY",
        "PROTECTED ACCEPTANCE ARTIFACT",
        "IMPLEMENTER EVIDENCE",
        "VERIFICATION EVIDENCE",
        "REPOSITORY EVIDENCE",
        "REVIEW HISTORY",
    ]


def test_the_reviewer_handoff_ends_with_the_host_identity_the_decision_must_copy() -> None:
    text = render_reviewer_handoff(_reviewer_handoff())

    identity = text[text.index("Reviewer identity (host-supplied") :]
    payload = json.JSONDecoder().raw_decode(identity[identity.index("{") :])[0]
    assert payload == {"phase_id": "01", "subphase_id": "01", "attempt": 1, "role": "reviewer"}
    assert text.index("REVIEW HISTORY") < text.index("Reviewer identity (host-supplied")


def test_an_implementer_scope_claim_is_evidence_only_and_never_reaches_authority() -> None:
    handoff = _reviewer_handoff()
    sections = _sections(render_reviewer_handoff(handoff))

    assert _SCOPE_CLAIM in sections["IMPLEMENTER EVIDENCE"]
    for authority_section in ("FROZEN REQUIREMENT AUTHORITY", "PROTECTED ACCEPTANCE ARTIFACT"):
        assert "outside_scope" not in sections[authority_section]
    body = json.JSONDecoder().raw_decode(sections["FROZEN REQUIREMENT AUTHORITY"].lstrip())[0]
    assert body["contract"]["allowed_paths"] == ["feature_01.py"]
    assert handoff.contract is not None
    assert handoff.contract.contract.allowed_paths == ("feature_01.py",)


def test_a_review_finding_requesting_new_behavior_appears_only_as_review_evidence() -> None:
    sections = _sections(render_reviewer_handoff(_reviewer_handoff(with_history=True)))

    assert _EXPANSION_FINDING in sections["REVIEW HISTORY"]
    for title, body in sections.items():
        if title != "REVIEW HISTORY":
            assert _EXPANSION_FINDING not in body
    assert "REWORK" in sections["REVIEW HISTORY"] or "rework" in sections["REVIEW HISTORY"]


def test_the_report_commands_and_diff_are_not_flattened_into_one_blob() -> None:
    sections = _sections(render_reviewer_handoff(_reviewer_handoff()))

    assert "1 passed" in sections["VERIFICATION EVIDENCE"]
    assert "return 1" in sections["REPOSITORY EVIDENCE"]
    assert "1 passed" not in sections["IMPLEMENTER EVIDENCE"]
    assert "return 1" not in sections["IMPLEMENTER EVIDENCE"]


def test_rendering_is_deterministic_for_equal_semantic_handoffs() -> None:
    assert render_reviewer_handoff(_reviewer_handoff(with_history=True)) == render_reviewer_handoff(
        _reviewer_handoff(with_history=True)
    )
    assert render_reviewer_handoff(_reviewer_handoff()) != render_reviewer_handoff(
        _reviewer_handoff(with_history=True)
    )


# --- rework handoff ---------------------------------------------------------------------------


def _rework_handoff() -> ReworkHandoff:
    return ReworkHandoff(
        identity=_identity(AgentRole.IMPLEMENTER, attempt=2),
        contract=_contract_authority(),
        protected_tests=_protected(),
        basis=_basis(),
        retry=RetryControl(
            kind="review_rework", attempt=_attempt(2), authorized_paths=(), instructions=()
        ),
        review=ReviewEvidence(decision=_rework_decision()),
        verification=_verification(attempt=1),
    )


def test_rework_separates_frozen_authority_retry_control_and_review_guidance() -> None:
    text = render_rework_handoff(_rework_handoff())
    sections = _sections(text)

    assert _authorities(text) == {
        "FROZEN REQUIREMENT AUTHORITY": "frozen_requirement",
        "PROTECTED ACCEPTANCE ARTIFACT": "protected_acceptance",
        "REPOSITORY BASIS": "execution_evidence",
        "RETRY CONTROL AUTHORITY": "control_decision",
        "REVIEW EVIDENCE / REPAIR GUIDANCE": "execution_evidence",
        "VERIFICATION EVIDENCE": "execution_evidence",
    }
    assert _EXPANSION_FINDING in sections["REVIEW EVIDENCE / REPAIR GUIDANCE"]
    for title, body in sections.items():
        if title != "REVIEW EVIDENCE / REPAIR GUIDANCE":
            assert _EXPANSION_FINDING not in body


def test_review_prose_is_never_labeled_as_authority_and_confers_no_paths() -> None:
    text = render_rework_handoff(_rework_handoff())
    sections = _sections(text)

    assert "resume authority" not in text.lower()
    control = json.JSONDecoder().raw_decode(sections["RETRY CONTROL AUTHORITY"].lstrip())[0]
    assert control["authorized_paths"] == []
    assert control["kind"] == "review_rework"
    body = json.JSONDecoder().raw_decode(sections["FROZEN REQUIREMENT AUTHORITY"].lstrip())[0]
    assert body["contract"]["allowed_paths"] == ["feature_01.py"]


def test_the_contract_digest_is_identical_in_every_attempt_handoff() -> None:
    first = render_implementer_handoff(
        ImplementerHandoff(
            identity=_identity(AgentRole.IMPLEMENTER),
            contract=_contract_authority(),
            protected_tests=_protected(),
            basis=_basis(),
        )
    )
    second = render_rework_handoff(_rework_handoff())

    digest = contract_digest(_contract())
    assert digest in _sections(first)["FROZEN REQUIREMENT AUTHORITY"]
    assert digest in _sections(second)["FROZEN REQUIREMENT AUTHORITY"]
    assert (
        _sections(first)["FROZEN REQUIREMENT AUTHORITY"]
        == _sections(second)["FROZEN REQUIREMENT AUTHORITY"]
    )
