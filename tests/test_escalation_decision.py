"""Tests for the Phase 9.2 Planner decision protocol.

Specifies ``lockstep.escalation_decision`` before it exists: a pure,
provider-neutral representation of a Planner's structured response to a
Planner-routed :class:`~lockstep.escalation.EscalationRequest`
(``PlannerDecision``) and the deterministic, exact-request-bound
resolution of that decision into a next disposition
(``resolve_planner_decision`` -> ``PlannerDecisionResolution``).

This module consumes the frozen Phase-9.1 category-to-authority routing
policy (``lockstep.escalation.route_escalation``) without redefining it.
No Planner invocation, Supervisor integration, persistence, retry, or
resume semantics exists yet; this module defines only the typed
response-side protocol those later mechanisms will consume.
"""

import ast
import dataclasses
import inspect
import json

import pytest
from pydantic import ValidationError

import lockstep.escalation_decision as escalation_decision_module
from lockstep.domain import AgentRole, AttemptNumber, PhaseId, SubphaseId
from lockstep.escalation import (
    EscalationAuthority,
    EscalationCategory,
    EscalationProtocolError,
    EscalationRequest,
    route_escalation,
)
from lockstep.escalation_decision import (
    PlannerDecision,
    PlannerDecisionDisposition,
    PlannerDecisionKind,
    PlannerDecisionResolution,
    escalation_request_digest,
    resolve_planner_decision,
)

_MAX_RATIONALE_LENGTH = 4096
_MAX_INSTRUCTIONS = 16
_MAX_INSTRUCTION_LENGTH = 2048
_MAX_AUTHORIZED_PATHS = 64
_MAX_PATH_LENGTH = 512

_PLANNER_ROUTED_CATEGORIES = (
    EscalationCategory.PLANNER_DECISION_REQUIRED,
    EscalationCategory.ARCHITECTURE_CONFLICT,
    EscalationCategory.TEST_DEFECT,
)

_NON_PLANNER_ROUTED_CATEGORIES = (
    EscalationCategory.CONTROL_PLANE_BLOCKER,
    EscalationCategory.REQUIREMENT_AMBIGUITY,
    EscalationCategory.EXTERNAL_SIDE_EFFECT_REQUIRED,
    EscalationCategory.HUMAN_AUTHORITY_REQUIRED,
)

_NO_PATH_KINDS = (
    PlannerDecisionKind.REPLAN_SUBPHASE,
    PlannerDecisionKind.HALT_FOR_HUMAN,
    PlannerDecisionKind.TERMINAL_HALT,
)

_NO_PATH_KIND_TO_DISPOSITION = {
    PlannerDecisionKind.REPLAN_SUBPHASE: PlannerDecisionDisposition.REPLAN_SUBPHASE,
    PlannerDecisionKind.HALT_FOR_HUMAN: PlannerDecisionDisposition.HUMAN_REQUIRED,
    PlannerDecisionKind.TERMINAL_HALT: PlannerDecisionDisposition.RUN_HALT,
}


def _phase_id(value: str = "09") -> PhaseId:
    return PhaseId.model_validate(value)


def _subphase_id(value: str = "02") -> SubphaseId:
    return SubphaseId.model_validate(value)


def _request(
    *,
    source_role: AgentRole = AgentRole.IMPLEMENTER,
    phase_id: PhaseId | None = None,
    subphase_id: SubphaseId | None = None,
    attempt: AttemptNumber | int = 1,
    category: EscalationCategory = EscalationCategory.PLANNER_DECISION_REQUIRED,
    question: str = "Which of two Contract-compatible architectures should this Sub-phase use?",
    evidence: tuple[str, ...] = (
        "Both candidate architectures satisfy the frozen Contract as written.",
    ),
    requested_authority: EscalationAuthority = EscalationAuthority.PLANNER,
) -> EscalationRequest:
    return EscalationRequest(
        source_role=source_role,
        phase_id=phase_id if phase_id is not None else _phase_id(),
        subphase_id=subphase_id if subphase_id is not None else _subphase_id(),
        attempt=attempt,
        category=category,
        question=question,
        evidence=evidence,
        requested_authority=requested_authority,
    )


def _decision(
    *,
    request: EscalationRequest,
    kind: PlannerDecisionKind = PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
    rationale: str = "Use the existing public inspect_repository API rather than a private helper.",
    instructions: tuple[str, ...] = ("Use inspect_repository rather than private Git helpers.",),
    authorized_paths: tuple[str, ...] = (),
    request_digest: str | None = None,
) -> PlannerDecision:
    return PlannerDecision(
        request_digest=(
            request_digest if request_digest is not None else escalation_request_digest(request)
        ),
        kind=kind,
        rationale=rationale,
        instructions=instructions,
        authorized_paths=authorized_paths,
    )


# ---------------------------------------------------------------------------
# Public surface (Section 35)
# ---------------------------------------------------------------------------


def test_public_api_exports_expected_names() -> None:
    assert {
        "PlannerDecisionKind",
        "PlannerDecisionDisposition",
        "PlannerDecision",
        "PlannerDecisionResolution",
        "escalation_request_digest",
        "resolve_planner_decision",
    }.issubset(set(escalation_decision_module.__all__))


def test_public_names_are_importable_from_the_module() -> None:
    assert PlannerDecisionKind is not None
    assert PlannerDecisionDisposition is not None
    assert PlannerDecision is not None
    assert PlannerDecisionResolution is not None
    assert callable(escalation_request_digest)
    assert callable(resolve_planner_decision)


# ---------------------------------------------------------------------------
# Exact enum values (Section 36)
# ---------------------------------------------------------------------------


def test_planner_decision_kind_values_are_stable() -> None:
    assert {member.name: member.value for member in PlannerDecisionKind} == {
        "AUTHORIZE_BOUNDED_CHANGE": "authorize_bounded_change",
        "AUTHORIZE_FROZEN_ARTIFACT_CORRECTION": "authorize_frozen_artifact_correction",
        "REPLAN_SUBPHASE": "replan_subphase",
        "HALT_FOR_HUMAN": "halt_for_human",
        "TERMINAL_HALT": "terminal_halt",
    }


def test_planner_decision_disposition_values_are_stable() -> None:
    assert {member.name: member.value for member in PlannerDecisionDisposition} == {
        "RESUME_AGENT": "resume_agent",
        "REPLAN_SUBPHASE": "replan_subphase",
        "HUMAN_REQUIRED": "human_required",
        "RUN_HALT": "run_halt",
    }


def test_planner_decision_kind_rejects_unknown_value() -> None:
    with pytest.raises(ValueError):
        PlannerDecisionKind("not_a_real_kind")


def test_planner_decision_disposition_rejects_unknown_value() -> None:
    with pytest.raises(ValueError):
        PlannerDecisionDisposition("not_a_real_disposition")


# ---------------------------------------------------------------------------
# PlannerDecision shape (Section 37)
# ---------------------------------------------------------------------------


def test_planner_decision_has_expected_fields() -> None:
    request = _request()
    decision = _decision(request=request)

    for field_name in ("request_digest", "kind", "rationale", "instructions", "authorized_paths"):
        assert hasattr(decision, field_name)


def test_planner_decision_rejects_unknown_fields() -> None:
    request = _request()
    with pytest.raises(ValidationError):
        PlannerDecision(
            request_digest=escalation_request_digest(request),
            kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
            rationale="Bounded rationale.",
            instructions=("Do the bounded thing.",),
            authorized_paths=(),
            unexpected=True,
        )


def test_planner_decision_is_immutable() -> None:
    decision = _decision(request=_request())

    with pytest.raises(ValidationError):
        decision.rationale = "A different rationale."  # type: ignore[misc]


# ---------------------------------------------------------------------------
# Digest determinism (Section 38)
# ---------------------------------------------------------------------------


def test_escalation_request_digest_is_deterministic_for_identical_data() -> None:
    first = _request()
    second = _request()

    assert first == second
    assert escalation_request_digest(first) == escalation_request_digest(second)


def test_escalation_request_digest_is_lowercase_hex_of_length_64() -> None:
    digest = escalation_request_digest(_request())

    assert len(digest) == 64
    assert digest == digest.lower()
    assert all(char in "0123456789abcdef" for char in digest)


# ---------------------------------------------------------------------------
# Digest sensitivity (Section 39)
# ---------------------------------------------------------------------------


def test_escalation_request_digest_changes_with_source_role() -> None:
    base = _request(source_role=AgentRole.IMPLEMENTER)
    varied = _request(source_role=AgentRole.REVIEWER)
    assert escalation_request_digest(base) != escalation_request_digest(varied)


def test_escalation_request_digest_changes_with_phase_id() -> None:
    base = _request(phase_id=_phase_id("09"))
    varied = _request(phase_id=_phase_id("10"))
    assert escalation_request_digest(base) != escalation_request_digest(varied)


def test_escalation_request_digest_changes_with_subphase_id() -> None:
    base = _request(subphase_id=_subphase_id("02"))
    varied = _request(subphase_id=_subphase_id("03"))
    assert escalation_request_digest(base) != escalation_request_digest(varied)


def test_escalation_request_digest_changes_with_attempt() -> None:
    base = _request(attempt=1)
    varied = _request(attempt=2)
    assert escalation_request_digest(base) != escalation_request_digest(varied)


def test_escalation_request_digest_changes_with_category() -> None:
    base = _request(category=EscalationCategory.PLANNER_DECISION_REQUIRED)
    varied = _request(category=EscalationCategory.ARCHITECTURE_CONFLICT)
    assert escalation_request_digest(base) != escalation_request_digest(varied)


def test_escalation_request_digest_changes_with_question() -> None:
    base = _request(question="Is approach A acceptable?")
    varied = _request(question="Is approach B acceptable?")
    assert escalation_request_digest(base) != escalation_request_digest(varied)


def test_escalation_request_digest_changes_with_evidence() -> None:
    base = _request(evidence=("Witness one.",))
    varied = _request(evidence=("Witness two.",))
    assert escalation_request_digest(base) != escalation_request_digest(varied)


def test_escalation_request_digest_changes_with_requested_authority() -> None:
    base = _request(
        category=EscalationCategory.TEST_DEFECT, requested_authority=EscalationAuthority.PLANNER
    )
    varied = _request(
        category=EscalationCategory.TEST_DEFECT, requested_authority=EscalationAuthority.HUMAN
    )
    assert escalation_request_digest(base) != escalation_request_digest(varied)


# ---------------------------------------------------------------------------
# Canonical ordering (Section 40)
# ---------------------------------------------------------------------------


def test_escalation_request_digest_is_independent_of_construction_path() -> None:
    first = EscalationRequest(
        source_role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=1,
        category=EscalationCategory.PLANNER_DECISION_REQUIRED,
        question="Which of two Contract-compatible architectures should this Sub-phase use?",
        evidence=("Both candidate architectures satisfy the frozen Contract as written.",),
        requested_authority=EscalationAuthority.PLANNER,
    )
    second = EscalationRequest.model_validate_json(first.model_dump_json())
    third = EscalationRequest.model_validate(json.loads(json.dumps(first.model_dump(mode="json"))))

    assert escalation_request_digest(first) == escalation_request_digest(second)
    assert escalation_request_digest(first) == escalation_request_digest(third)


# ---------------------------------------------------------------------------
# Digest field validation (Section 41)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "digest",
    [
        "",
        "a" * 63,
        "a" * 65,
        "A" * 64,
        "g" * 64,
    ],
)
def test_planner_decision_rejects_malformed_request_digest(digest: str) -> None:
    with pytest.raises(ValidationError):
        _decision(request=_request(), request_digest=digest)


def test_planner_decision_accepts_valid_request_digest() -> None:
    request = _request()
    decision = _decision(request=request)
    assert decision.request_digest == escalation_request_digest(request)
    assert len(decision.request_digest) == 64


# ---------------------------------------------------------------------------
# Rationale bounds (Section 42)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("rationale", ["", "   ", "x" * (_MAX_RATIONALE_LENGTH + 1)])
def test_planner_decision_rejects_invalid_rationale(rationale: str) -> None:
    with pytest.raises(ValidationError):
        _decision(request=_request(), rationale=rationale)


@pytest.mark.parametrize("rationale", ["Bounded rationale.", "x" * _MAX_RATIONALE_LENGTH])
def test_planner_decision_accepts_bounded_rationale(rationale: str) -> None:
    decision = _decision(request=_request(), rationale=rationale)
    assert decision.rationale == rationale


# ---------------------------------------------------------------------------
# Instruction bounds (Section 43)
# ---------------------------------------------------------------------------


def test_planner_decision_rejects_empty_instructions() -> None:
    with pytest.raises(ValidationError):
        _decision(request=_request(), instructions=())


def test_planner_decision_accepts_one_instruction() -> None:
    decision = _decision(request=_request(), instructions=("Do the bounded thing.",))
    assert decision.instructions == ("Do the bounded thing.",)


def test_planner_decision_accepts_maximum_instructions() -> None:
    instructions = tuple(f"Bounded instruction number {i}." for i in range(_MAX_INSTRUCTIONS))
    decision = _decision(request=_request(), instructions=instructions)
    assert len(decision.instructions) == _MAX_INSTRUCTIONS


def test_planner_decision_rejects_too_many_instructions() -> None:
    instructions = tuple(f"Bounded instruction number {i}." for i in range(_MAX_INSTRUCTIONS + 1))
    with pytest.raises(ValidationError):
        _decision(request=_request(), instructions=instructions)


def test_planner_decision_rejects_blank_instruction() -> None:
    with pytest.raises(ValidationError):
        _decision(request=_request(), instructions=("   ",))


def test_planner_decision_accepts_instruction_at_max_length() -> None:
    instruction = "x" * _MAX_INSTRUCTION_LENGTH
    decision = _decision(request=_request(), instructions=(instruction,))
    assert decision.instructions == (instruction,)


def test_planner_decision_rejects_instruction_over_max_length() -> None:
    instruction = "x" * (_MAX_INSTRUCTION_LENGTH + 1)
    with pytest.raises(ValidationError):
        _decision(request=_request(), instructions=(instruction,))


# ---------------------------------------------------------------------------
# Authorized-path lexical safety (Section 44)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "path",
    [
        "/tests/test_x.py",
        ".",
        "../tests/test_x.py",
        "tests/../test_x.py",
        "tests/./test_x.py",
        "tests//test_x.py",
        "tests\\test_x.py",
        ".git/config",
        ".lockstep/project/x.json",
        "tests/*.py",
        "tests/test_?.py",
        "tests/test_[x].py",
        "tests/test_\x00x.py",
        "x" * (_MAX_PATH_LENGTH + 1),
        "",
        "   ",
    ],
)
def test_planner_decision_rejects_unsafe_authorized_path(path: str) -> None:
    with pytest.raises(ValidationError):
        _decision(
            request=_request(),
            kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
            authorized_paths=(path,),
        )


def test_planner_decision_rejects_duplicate_authorized_paths() -> None:
    with pytest.raises(ValidationError):
        _decision(
            request=_request(),
            kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
            authorized_paths=("tests/test_x.py", "tests/test_x.py"),
        )


@pytest.mark.parametrize(
    "path",
    [
        "tests/test_x.py",
        "src/lockstep/foo.py",
        "docs/design/decision.md",
        "lockstep.toml",
    ],
)
def test_planner_decision_accepts_safe_authorized_path(path: str) -> None:
    decision = _decision(
        request=_request(),
        kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
        authorized_paths=(path,),
    )
    assert decision.authorized_paths == (path,)


def test_planner_decision_accepts_maximum_authorized_paths() -> None:
    paths = tuple(f"src/lockstep/module_{i}.py" for i in range(_MAX_AUTHORIZED_PATHS))
    decision = _decision(
        request=_request(),
        kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
        authorized_paths=paths,
    )
    assert len(decision.authorized_paths) == _MAX_AUTHORIZED_PATHS


def test_planner_decision_rejects_too_many_authorized_paths() -> None:
    paths = tuple(f"src/lockstep/module_{i}.py" for i in range(_MAX_AUTHORIZED_PATHS + 1))
    with pytest.raises(ValidationError):
        _decision(
            request=_request(),
            kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
            authorized_paths=paths,
        )


def test_planner_decision_accepts_authorized_path_at_max_length() -> None:
    path = "a/" + ("x" * (_MAX_PATH_LENGTH - 2))
    assert len(path) == _MAX_PATH_LENGTH
    decision = _decision(
        request=_request(),
        kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
        authorized_paths=(path,),
    )
    assert decision.authorized_paths == (path,)


def test_planner_decision_defaults_to_no_authorized_paths() -> None:
    decision = _decision(request=_request(), kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE)
    assert decision.authorized_paths == ()


# ---------------------------------------------------------------------------
# Authorized-path order (Section 45)
# ---------------------------------------------------------------------------


def test_planner_decision_preserves_authorized_path_order() -> None:
    decision = _decision(
        request=_request(),
        kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
        authorized_paths=("b.py", "a.py", "c.py"),
    )
    assert decision.authorized_paths == ("b.py", "a.py", "c.py")

    rehydrated = PlannerDecision.model_validate_json(decision.model_dump_json())
    assert rehydrated.authorized_paths == ("b.py", "a.py", "c.py")


# ---------------------------------------------------------------------------
# Normal bounded authorization (Section 46)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "category",
    [EscalationCategory.PLANNER_DECISION_REQUIRED, EscalationCategory.ARCHITECTURE_CONFLICT],
)
@pytest.mark.parametrize(
    "authorized_paths",
    [(), ("src/lockstep/foo.py",), ("src/lockstep/foo.py", "src/lockstep/bar.py")],
)
def test_bounded_authorization_resumes_agent(
    category: EscalationCategory, authorized_paths: tuple[str, ...]
) -> None:
    request = _request(category=category)
    decision = _decision(
        request=request,
        kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
        authorized_paths=authorized_paths,
    )

    resolution = resolve_planner_decision(request, decision)

    assert resolution.disposition == PlannerDecisionDisposition.RESUME_AGENT
    assert resolution.frozen_artifact_correction is False
    assert resolution.decision is decision


# ---------------------------------------------------------------------------
# TEST_DEFECT bounded authorization (Section 47)
# ---------------------------------------------------------------------------


def test_test_defect_bounded_authorization_does_not_grant_frozen_authority() -> None:
    request = _request(category=EscalationCategory.TEST_DEFECT)
    decision = _decision(request=request, kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE)

    resolution = resolve_planner_decision(request, decision)

    assert resolution.disposition == PlannerDecisionDisposition.RESUME_AGENT
    assert resolution.frozen_artifact_correction is False


# ---------------------------------------------------------------------------
# Explicit frozen-artifact correction (Section 48)
# ---------------------------------------------------------------------------


def test_explicit_frozen_artifact_correction_resumes_agent_and_is_flagged() -> None:
    request = _request(category=EscalationCategory.TEST_DEFECT)
    decision = _decision(
        request=request,
        kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
        authorized_paths=("tests/test_x.py",),
    )

    resolution = resolve_planner_decision(request, decision)

    assert resolution.disposition == PlannerDecisionDisposition.RESUME_AGENT
    assert resolution.frozen_artifact_correction is True


# ---------------------------------------------------------------------------
# Frozen correction requires path (Section 49)
# ---------------------------------------------------------------------------


def test_frozen_artifact_correction_without_paths_is_rejected() -> None:
    request = _request(category=EscalationCategory.TEST_DEFECT)
    decision = _decision(
        request=request,
        kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
        authorized_paths=(),
    )

    with pytest.raises(EscalationProtocolError):
        resolve_planner_decision(request, decision)


# ---------------------------------------------------------------------------
# Frozen correction category restriction (Section 50)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "category",
    [EscalationCategory.PLANNER_DECISION_REQUIRED, EscalationCategory.ARCHITECTURE_CONFLICT],
)
def test_frozen_artifact_correction_illegal_outside_test_defect(
    category: EscalationCategory,
) -> None:
    request = _request(category=category)
    decision = _decision(
        request=request,
        kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
        authorized_paths=("tests/test_x.py",),
    )

    with pytest.raises(EscalationProtocolError):
        resolve_planner_decision(request, decision)


# ---------------------------------------------------------------------------
# Replan / halt-for-human / terminal-halt (Sections 51-53)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("category", _PLANNER_ROUTED_CATEGORIES)
@pytest.mark.parametrize("kind", _NO_PATH_KINDS)
def test_no_path_decision_kinds_resolve_with_no_paths(
    category: EscalationCategory, kind: PlannerDecisionKind
) -> None:
    request = _request(category=category)
    decision = _decision(request=request, kind=kind, authorized_paths=())

    resolution = resolve_planner_decision(request, decision)

    assert resolution.disposition == _NO_PATH_KIND_TO_DISPOSITION[kind]
    assert resolution.frozen_artifact_correction is False


@pytest.mark.parametrize("category", _PLANNER_ROUTED_CATEGORIES)
@pytest.mark.parametrize("kind", _NO_PATH_KINDS)
def test_no_path_decision_kinds_reject_nonempty_authorized_paths(
    category: EscalationCategory, kind: PlannerDecisionKind
) -> None:
    request = _request(category=category)
    decision = _decision(request=request, kind=kind, authorized_paths=("src/lockstep/foo.py",))

    with pytest.raises(EscalationProtocolError):
        resolve_planner_decision(request, decision)


def test_halt_for_human_does_not_modify_original_request_route() -> None:
    request = _request(category=EscalationCategory.ARCHITECTURE_CONFLICT)
    original_route = route_escalation(request)
    decision = _decision(request=request, kind=PlannerDecisionKind.HALT_FOR_HUMAN)

    resolve_planner_decision(request, decision)

    assert route_escalation(request) == original_route
    assert original_route.authority == EscalationAuthority.PLANNER


# ---------------------------------------------------------------------------
# Non-Planner categories reject Planner decisions (Section 54)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("category", _NON_PLANNER_ROUTED_CATEGORIES)
def test_non_planner_routed_categories_reject_planner_decision(
    category: EscalationCategory,
) -> None:
    expected_authority = route_escalation(_request(category=category)).authority
    request = _request(category=category, requested_authority=expected_authority)
    decision = _decision(request=request, kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE)

    with pytest.raises(EscalationProtocolError):
        resolve_planner_decision(request, decision)


# ---------------------------------------------------------------------------
# Requested authority cannot manufacture route (Section 55)
# ---------------------------------------------------------------------------


def test_requested_authority_cannot_manufacture_planner_route_from_human_category() -> None:
    request = _request(
        category=EscalationCategory.REQUIREMENT_AMBIGUITY,
        requested_authority=EscalationAuthority.PLANNER,
    )
    decision = _decision(request=request, kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE)

    with pytest.raises(EscalationProtocolError):
        resolve_planner_decision(request, decision)


def test_requested_authority_cannot_manufacture_planner_route_from_supervisor_category() -> None:
    request = _request(
        category=EscalationCategory.CONTROL_PLANE_BLOCKER,
        requested_authority=EscalationAuthority.PLANNER,
    )
    decision = _decision(request=request, kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE)

    with pytest.raises(EscalationProtocolError):
        resolve_planner_decision(request, decision)


# ---------------------------------------------------------------------------
# Digest mismatch (Section 56)
# ---------------------------------------------------------------------------


def test_digest_mismatch_is_rejected() -> None:
    request = _request(category=EscalationCategory.PLANNER_DECISION_REQUIRED)
    wrong_digest = "0" * 64
    assert wrong_digest != escalation_request_digest(request)
    decision = _decision(
        request=request,
        kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
        request_digest=wrong_digest,
    )

    with pytest.raises(EscalationProtocolError):
        resolve_planner_decision(request, decision)


# ---------------------------------------------------------------------------
# Validation precedence (Section 57)
# ---------------------------------------------------------------------------


def test_non_planner_route_error_beats_digest_mismatch() -> None:
    request = _request(category=EscalationCategory.HUMAN_AUTHORITY_REQUIRED)
    decision = _decision(
        request=request,
        kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
        request_digest="0" * 64,
        authorized_paths=(),
    )

    with pytest.raises(EscalationProtocolError) as excinfo:
        resolve_planner_decision(request, decision)

    assert "route" in str(excinfo.value) or "Planner" in str(excinfo.value)


def test_digest_mismatch_beats_illegal_kind() -> None:
    request = _request(category=EscalationCategory.PLANNER_DECISION_REQUIRED)
    decision = _decision(
        request=request,
        kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
        request_digest="0" * 64,
        authorized_paths=("tests/test_x.py",),
    )

    with pytest.raises(EscalationProtocolError) as excinfo:
        resolve_planner_decision(request, decision)

    assert "digest" in str(excinfo.value)


def test_illegal_kind_beats_path_violation() -> None:
    request = _request(category=EscalationCategory.PLANNER_DECISION_REQUIRED)
    decision = _decision(
        request=request,
        kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
        authorized_paths=(),
    )

    with pytest.raises(EscalationProtocolError) as excinfo:
        resolve_planner_decision(request, decision)

    assert "kind" in str(excinfo.value) or "category" in str(excinfo.value)


# ---------------------------------------------------------------------------
# No prose interpretation (Section 58)
# ---------------------------------------------------------------------------


def test_structured_kind_wins_over_contradictory_prose_resume() -> None:
    request = _request(category=EscalationCategory.PLANNER_DECISION_REQUIRED)
    decision = _decision(
        request=request,
        kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
        rationale="The run should halt.",
        instructions=("Ask the human and stop.",),
    )

    resolution = resolve_planner_decision(request, decision)

    assert resolution.disposition == PlannerDecisionDisposition.RESUME_AGENT


def test_structured_kind_wins_over_contradictory_prose_halt() -> None:
    request = _request(category=EscalationCategory.PLANNER_DECISION_REQUIRED)
    decision = _decision(
        request=request,
        kind=PlannerDecisionKind.TERMINAL_HALT,
        rationale="Resume the agent immediately; everything is fine.",
        instructions=("Resume normal execution.",),
    )

    resolution = resolve_planner_decision(request, decision)

    assert resolution.disposition == PlannerDecisionDisposition.RUN_HALT


# ---------------------------------------------------------------------------
# Request/decision immutability (Section 59)
# ---------------------------------------------------------------------------


def test_resolve_planner_decision_does_not_mutate_request_or_decision() -> None:
    request = _request(category=EscalationCategory.ARCHITECTURE_CONFLICT)
    decision = _decision(request=request, kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE)

    request_before = request.model_dump_json()
    decision_before = decision.model_dump_json()

    resolve_planner_decision(request, decision)

    assert request.model_dump_json() == request_before
    assert decision.model_dump_json() == decision_before


# ---------------------------------------------------------------------------
# Resolution shape (Section 60)
# ---------------------------------------------------------------------------


def test_resolution_has_exactly_expected_fields() -> None:
    request = _request(category=EscalationCategory.PLANNER_DECISION_REQUIRED)
    decision = _decision(request=request, kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE)

    resolution = resolve_planner_decision(request, decision)

    field_names = {field.name for field in dataclasses.fields(resolution)}
    assert field_names == {"decision", "disposition", "frozen_artifact_correction"}

    with pytest.raises(AttributeError):
        resolution.unexpected = True  # type: ignore[attr-defined]


def test_resolution_is_frozen() -> None:
    request = _request(category=EscalationCategory.PLANNER_DECISION_REQUIRED)
    decision = _decision(request=request, kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE)
    resolution = resolve_planner_decision(request, decision)

    with pytest.raises(AttributeError):
        resolution.disposition = PlannerDecisionDisposition.RUN_HALT  # type: ignore[misc]


def test_resolution_preserves_decision_identity() -> None:
    request = _request(category=EscalationCategory.PLANNER_DECISION_REQUIRED)
    decision = _decision(request=request, kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE)

    resolution = resolve_planner_decision(request, decision)

    assert resolution.decision is decision


# ---------------------------------------------------------------------------
# Error-type distinction (Section 61)
# ---------------------------------------------------------------------------


def test_malformed_decision_field_raises_validation_error() -> None:
    with pytest.raises(ValidationError):
        _decision(request=_request(), rationale="")


def test_invalid_relationship_raises_protocol_error() -> None:
    request = _request(category=EscalationCategory.CONTROL_PLANE_BLOCKER)
    decision = _decision(
        request=request,
        kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
        request_digest=escalation_request_digest(request),
    )

    with pytest.raises(EscalationProtocolError):
        resolve_planner_decision(request, decision)


# ---------------------------------------------------------------------------
# Bounded/private protocol errors (Section 62)
# ---------------------------------------------------------------------------


def test_protocol_errors_do_not_leak_request_or_decision_content() -> None:
    question_sentinel = "SENTINEL-QUESTION-9F2C"
    evidence_sentinel = "SENTINEL-EVIDENCE-8B3D"
    rationale_sentinel = "SENTINEL-RATIONALE-7A1E"
    instruction_sentinel = "SENTINEL-INSTRUCTION-6C4F"
    path_sentinel = "sentinel_path_5d2e"

    request = _request(
        category=EscalationCategory.REQUIREMENT_AMBIGUITY,
        question=f"{question_sentinel} - which option is correct?",
        evidence=(f"{evidence_sentinel} - both options satisfy the Contract.",),
        requested_authority=EscalationAuthority.PLANNER,
    )
    decision = _decision(
        request=request,
        kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
        rationale=f"{rationale_sentinel} - the frozen test is defective.",
        instructions=(f"{instruction_sentinel} - correct the frozen test.",),
        authorized_paths=(f"tests/{path_sentinel}.py",),
    )
    forged_digest = escalation_request_digest(request)[:-1] + (
        "0" if escalation_request_digest(request)[-1] != "0" else "1"
    )
    decision_with_wrong_digest = _decision(
        request=request,
        kind=decision.kind,
        rationale=decision.rationale,
        instructions=decision.instructions,
        authorized_paths=decision.authorized_paths,
        request_digest=forged_digest,
    )

    with pytest.raises(EscalationProtocolError) as excinfo:
        resolve_planner_decision(request, decision_with_wrong_digest)

    message = str(excinfo.value)
    for sentinel in (
        question_sentinel,
        evidence_sentinel,
        rationale_sentinel,
        instruction_sentinel,
        path_sentinel,
        forged_digest,
        escalation_request_digest(request),
    ):
        assert sentinel not in message


# ---------------------------------------------------------------------------
# Deterministic resolution (Section 63)
# ---------------------------------------------------------------------------


def test_resolve_planner_decision_is_deterministic_for_independently_built_data() -> None:
    def _build() -> tuple[EscalationRequest, PlannerDecision]:
        request = _request(category=EscalationCategory.TEST_DEFECT)
        decision = _decision(
            request=request,
            kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
            authorized_paths=("tests/test_x.py",),
        )
        return request, decision

    request_a, decision_a = _build()
    request_b, decision_b = _build()

    resolution_a = resolve_planner_decision(request_a, decision_a)
    resolution_b = resolve_planner_decision(request_b, decision_b)

    assert resolution_a.disposition == resolution_b.disposition
    assert resolution_a.frozen_artifact_correction == resolution_b.frozen_artifact_correction


# ---------------------------------------------------------------------------
# Category -> legal decision-kind matrix (supporting Sections 46-53)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "category",
    [EscalationCategory.PLANNER_DECISION_REQUIRED, EscalationCategory.ARCHITECTURE_CONFLICT],
)
def test_frozen_correction_illegal_for_non_test_defect_even_with_valid_digest_and_paths(
    category: EscalationCategory,
) -> None:
    request = _request(category=category)
    decision = _decision(
        request=request,
        kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
        authorized_paths=("tests/test_x.py",),
    )

    with pytest.raises(EscalationProtocolError):
        resolve_planner_decision(request, decision)


# ---------------------------------------------------------------------------
# Pure dependency boundary audit (Section 64)
# ---------------------------------------------------------------------------

_FORBIDDEN_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.runtime",
    "lockstep.planning_store",
    "lockstep.planning_workflow",
    "lockstep.planning_transport",
    "lockstep.planning",
    "lockstep.git",
    "lockstep.process",
    "lockstep.supervisor",
    "lockstep.persistence",
    "lockstep.verification",
    "lockstep.reporting",
    "lockstep.cli",
    "lockstep.agents",
    "lockstep.state",
    "lockstep.context",
    "subprocess",
    "os",
)


def _imported_modules(tree: ast.Module) -> set[str]:
    imported_modules: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imported_modules.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            imported_modules.add(node.module or "")
    return imported_modules


def test_escalation_decision_module_has_no_forbidden_imports() -> None:
    tree = ast.parse(inspect.getsource(escalation_decision_module))
    imported_modules = _imported_modules(tree)

    for forbidden_prefix in _FORBIDDEN_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


def test_escalation_decision_module_only_imports_lockstep_domain_and_escalation() -> None:
    tree = ast.parse(inspect.getsource(escalation_decision_module))
    imported_modules = _imported_modules(tree)

    lockstep_imports = {
        module
        for module in imported_modules
        if module == "lockstep" or module.startswith("lockstep.")
    }
    assert lockstep_imports <= {"lockstep.domain", "lockstep.escalation"}


# ---------------------------------------------------------------------------
# Provider neutrality (Section 65)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("provider_name", ["claude", "codex", "openai", "anthropic"])
def test_escalation_decision_module_source_has_no_provider_names(provider_name: str) -> None:
    source = inspect.getsource(escalation_decision_module).lower()
    assert provider_name not in source


# ---------------------------------------------------------------------------
# No execution primitives (Section 66)
# ---------------------------------------------------------------------------


def test_escalation_decision_module_has_no_execution_primitives() -> None:
    source = inspect.getsource(escalation_decision_module)
    tree = ast.parse(source)

    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            assert node.func.id not in {
                "invoke_agent",
                "prepare_agent_runtime",
                "input",
                "print",
                "open",
            }

    for forbidden in (
        "invoke_agent",
        "prepare_agent_runtime",
        "subprocess",
        "Path.write_text",
        "Path.write_bytes",
    ):
        assert forbidden not in source


# ---------------------------------------------------------------------------
# EscalationProtocolError reuse (Section 25/40)
# ---------------------------------------------------------------------------


def test_escalation_decision_module_reuses_existing_protocol_error() -> None:
    source = inspect.getsource(escalation_decision_module)
    assert "class EscalationProtocolError" not in source
    assert "EscalationProtocolError" in source
