"""Tests for the Phase 9.1 structured escalation and authority-routing protocol.

Specifies ``lockstep.escalation`` before it exists: a pure, provider-neutral
representation of an agent-encountered blocker (``EscalationRequest``) and
the deterministic policy that decides who has authority to resolve it
(``route_escalation`` -> ``EscalationRoute``). No Supervisor integration,
persistence, Planner invocation, or human prompting exists yet; this module
defines only the typed control-plane protocol those later mechanisms will
consume.
"""

import ast
import inspect

import pytest
from pydantic import ValidationError

import lockstep.escalation as escalation_module
from lockstep.domain import AgentRole, AttemptNumber, PhaseId, SubphaseId
from lockstep.escalation import (
    EscalationAuthority,
    EscalationCategory,
    EscalationProtocolError,
    EscalationRequest,
    EscalationRoute,
    HaltLevel,
    route_escalation,
)

_MAX_QUESTION_LENGTH = 4096
_MAX_EVIDENCE_ENTRIES = 32
_MAX_EVIDENCE_ENTRY_LENGTH = 2048


def _phase_id(value: str = "09") -> PhaseId:
    return PhaseId.model_validate(value)


def _subphase_id(value: str = "01") -> SubphaseId:
    return SubphaseId.model_validate(value)


def _request(
    *,
    source_role: AgentRole = AgentRole.IMPLEMENTER,
    phase_id: PhaseId | None = None,
    subphase_id: SubphaseId | None = None,
    attempt: AttemptNumber | int = 1,
    category: EscalationCategory = EscalationCategory.CONTROL_PLANE_BLOCKER,
    question: str = "Is the working tree clean before this turn begins?",
    evidence: tuple[str, ...] = (
        "git status reported a dirty working tree before the turn began.",
    ),
    requested_authority: EscalationAuthority = EscalationAuthority.SUPERVISOR,
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


# ---------------------------------------------------------------------------
# Public surface (Section 28)
# ---------------------------------------------------------------------------


def test_public_api_exports_expected_names() -> None:
    # Subset check, not exact equality: later Phase-9 sub-phases may
    # additively extend this module's exports. Carrying the lesson from
    # incident #12, a full-equality export test would misread authorized
    # growth as drift.
    assert {
        "EscalationAuthority",
        "EscalationCategory",
        "EscalationProtocolError",
        "EscalationRequest",
        "EscalationRoute",
        "HaltLevel",
        "route_escalation",
    }.issubset(set(escalation_module.__all__))


def test_public_names_are_importable_from_the_module() -> None:
    assert EscalationCategory is not None
    assert EscalationAuthority is not None
    assert HaltLevel is not None
    assert EscalationRequest is not None
    assert EscalationRoute is not None
    assert EscalationProtocolError is not None
    assert callable(route_escalation)


# ---------------------------------------------------------------------------
# Enum exact values (Section 29)
# ---------------------------------------------------------------------------


def test_escalation_category_values_are_stable() -> None:
    assert {member.name: member.value for member in EscalationCategory} == {
        "CONTROL_PLANE_BLOCKER": "control_plane_blocker",
        "PLANNER_DECISION_REQUIRED": "planner_decision_required",
        "TEST_DEFECT": "test_defect",
        "ARCHITECTURE_CONFLICT": "architecture_conflict",
        "REQUIREMENT_AMBIGUITY": "requirement_ambiguity",
        "EXTERNAL_SIDE_EFFECT_REQUIRED": "external_side_effect_required",
        "HUMAN_AUTHORITY_REQUIRED": "human_authority_required",
    }


def test_escalation_authority_values_are_stable() -> None:
    assert {member.name: member.value for member in EscalationAuthority} == {
        "SUPERVISOR": "supervisor",
        "PLANNER": "planner",
        "HUMAN": "human",
    }


def test_halt_level_values_are_stable() -> None:
    assert {member.name: member.value for member in HaltLevel} == {
        "AGENT": "agent",
        "RUN": "run",
        "HUMAN_REQUIRED": "human_required",
    }


def test_escalation_category_rejects_unknown_value() -> None:
    with pytest.raises(ValueError):
        EscalationCategory("not_a_real_category")

    with pytest.raises(ValidationError):
        _request(category="not_a_real_category")  # type: ignore[arg-type]


def test_escalation_authority_rejects_unknown_value() -> None:
    with pytest.raises(ValueError):
        EscalationAuthority("not_a_real_authority")

    with pytest.raises(ValidationError):
        _request(requested_authority="not_a_real_authority")  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# EscalationRequest shape (Section 30)
# ---------------------------------------------------------------------------


def test_escalation_request_has_expected_fields() -> None:
    request = _request()

    for field_name in (
        "source_role",
        "phase_id",
        "subphase_id",
        "attempt",
        "category",
        "question",
        "evidence",
        "requested_authority",
    ):
        assert hasattr(request, field_name)


def test_escalation_request_rejects_unknown_fields() -> None:
    with pytest.raises(ValidationError):
        EscalationRequest(
            source_role=AgentRole.IMPLEMENTER,
            phase_id=_phase_id(),
            subphase_id=_subphase_id(),
            attempt=1,
            category=EscalationCategory.CONTROL_PLANE_BLOCKER,
            question="Is the precondition satisfied?",
            evidence=("the precondition check failed deterministically.",),
            requested_authority=EscalationAuthority.SUPERVISOR,
            unexpected=True,
        )


def test_escalation_request_is_immutable() -> None:
    request = _request()

    with pytest.raises(ValidationError):
        request.question = "A different question."  # type: ignore[misc]


# ---------------------------------------------------------------------------
# Attempt validation (Section 31)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("attempt", [0, -1])
def test_escalation_request_rejects_non_positive_attempt(attempt: int) -> None:
    with pytest.raises(ValidationError):
        _request(attempt=attempt)


@pytest.mark.parametrize("attempt", [1, 2, 1_000_000])
def test_escalation_request_accepts_positive_attempt(attempt: int) -> None:
    request = _request(attempt=attempt)
    assert request.attempt == AttemptNumber.model_validate(attempt)


# ---------------------------------------------------------------------------
# Question validation (Section 32)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("question", ["", "   ", "x" * (_MAX_QUESTION_LENGTH + 1)])
def test_escalation_request_rejects_invalid_question(question: str) -> None:
    with pytest.raises(ValidationError):
        _request(question=question)


@pytest.mark.parametrize("question", ["Is this bounded?", "x" * _MAX_QUESTION_LENGTH])
def test_escalation_request_accepts_bounded_question(question: str) -> None:
    request = _request(question=question)
    assert request.question == question


def test_escalation_request_rejects_whitespace_only_evidence_entry() -> None:
    with pytest.raises(ValidationError):
        _request(evidence=("   ",))


# ---------------------------------------------------------------------------
# Evidence bounds (Section 33)
# ---------------------------------------------------------------------------


def test_escalation_request_rejects_empty_evidence() -> None:
    with pytest.raises(ValidationError):
        _request(evidence=())


def test_escalation_request_accepts_one_evidence_entry() -> None:
    request = _request(evidence=("frozen test expects schema file before invocation.",))
    assert request.evidence == ("frozen test expects schema file before invocation.",)


def test_escalation_request_accepts_maximum_evidence_entries() -> None:
    evidence = tuple(f"bounded factual witness number {i}." for i in range(_MAX_EVIDENCE_ENTRIES))
    request = _request(evidence=evidence)
    assert len(request.evidence) == _MAX_EVIDENCE_ENTRIES


def test_escalation_request_rejects_too_many_evidence_entries() -> None:
    evidence = tuple(
        f"bounded factual witness number {i}." for i in range(_MAX_EVIDENCE_ENTRIES + 1)
    )
    with pytest.raises(ValidationError):
        _request(evidence=evidence)


def test_escalation_request_accepts_evidence_entry_at_max_length() -> None:
    entry = "x" * _MAX_EVIDENCE_ENTRY_LENGTH
    request = _request(evidence=(entry,))
    assert request.evidence == (entry,)


def test_escalation_request_rejects_evidence_entry_over_max_length() -> None:
    entry = "x" * (_MAX_EVIDENCE_ENTRY_LENGTH + 1)
    with pytest.raises(ValidationError):
        _request(evidence=(entry,))


# ---------------------------------------------------------------------------
# Deterministic routing (Sections 34-36)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "source_role", [AgentRole.PLANNER, AgentRole.IMPLEMENTER, AgentRole.REVIEWER]
)
def test_control_plane_blocker_routes_to_supervisor(source_role: AgentRole) -> None:
    request = _request(
        source_role=source_role,
        category=EscalationCategory.CONTROL_PLANE_BLOCKER,
        requested_authority=EscalationAuthority.SUPERVISOR,
    )

    route = route_escalation(request)

    assert route.authority == EscalationAuthority.SUPERVISOR
    assert route.halt_level == HaltLevel.AGENT


@pytest.mark.parametrize(
    "category",
    [
        EscalationCategory.PLANNER_DECISION_REQUIRED,
        EscalationCategory.TEST_DEFECT,
        EscalationCategory.ARCHITECTURE_CONFLICT,
    ],
)
def test_planner_categories_route_to_planner(category: EscalationCategory) -> None:
    request = _request(category=category, requested_authority=EscalationAuthority.PLANNER)

    route = route_escalation(request)

    assert route.authority == EscalationAuthority.PLANNER
    assert route.halt_level == HaltLevel.AGENT


@pytest.mark.parametrize(
    "category",
    [
        EscalationCategory.REQUIREMENT_AMBIGUITY,
        EscalationCategory.EXTERNAL_SIDE_EFFECT_REQUIRED,
        EscalationCategory.HUMAN_AUTHORITY_REQUIRED,
    ],
)
def test_human_categories_route_to_human(category: EscalationCategory) -> None:
    request = _request(category=category, requested_authority=EscalationAuthority.HUMAN)

    route = route_escalation(request)

    assert route.authority == EscalationAuthority.HUMAN
    assert route.halt_level == HaltLevel.HUMAN_REQUIRED


def test_run_halt_level_exists_but_is_never_produced_by_v1_categories() -> None:
    assert HaltLevel.RUN in set(HaltLevel)

    for category in EscalationCategory:
        request = _request(category=category, requested_authority=EscalationAuthority.SUPERVISOR)
        route = route_escalation(request)
        assert route.halt_level != HaltLevel.RUN


# ---------------------------------------------------------------------------
# Requested-authority mismatch (Section 37)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("category", "requested_authority", "expected_authority"),
    [
        (EscalationCategory.TEST_DEFECT, EscalationAuthority.HUMAN, EscalationAuthority.PLANNER),
        (
            EscalationCategory.REQUIREMENT_AMBIGUITY,
            EscalationAuthority.PLANNER,
            EscalationAuthority.HUMAN,
        ),
        (
            EscalationCategory.CONTROL_PLANE_BLOCKER,
            EscalationAuthority.HUMAN,
            EscalationAuthority.SUPERVISOR,
        ),
    ],
)
def test_mismatched_requested_authority_does_not_override_deterministic_route(
    category: EscalationCategory,
    requested_authority: EscalationAuthority,
    expected_authority: EscalationAuthority,
) -> None:
    request = _request(category=category, requested_authority=requested_authority)

    route = route_escalation(request)

    assert route.authority == expected_authority
    assert route.authority_mismatch is True
    assert request.requested_authority == requested_authority


@pytest.mark.parametrize(
    ("category", "requested_authority"),
    [
        (EscalationCategory.CONTROL_PLANE_BLOCKER, EscalationAuthority.SUPERVISOR),
        (EscalationCategory.PLANNER_DECISION_REQUIRED, EscalationAuthority.PLANNER),
        (EscalationCategory.HUMAN_AUTHORITY_REQUIRED, EscalationAuthority.HUMAN),
    ],
)
def test_matching_requested_authority_has_no_mismatch(
    category: EscalationCategory, requested_authority: EscalationAuthority
) -> None:
    request = _request(category=category, requested_authority=requested_authority)

    route = route_escalation(request)

    assert route.authority_mismatch is False


def test_route_escalation_does_not_mutate_request() -> None:
    request = _request(
        category=EscalationCategory.TEST_DEFECT, requested_authority=EscalationAuthority.HUMAN
    )
    before = request.model_dump(mode="json")

    route_escalation(request)

    assert request.model_dump(mode="json") == before
    assert request.requested_authority == EscalationAuthority.HUMAN


def test_escalation_route_does_not_embed_the_request() -> None:
    route = route_escalation(_request())
    rendered = repr(route)
    assert "EscalationRequest" not in rendered


# ---------------------------------------------------------------------------
# Source-role independence (Section 38)
# ---------------------------------------------------------------------------


def test_routing_is_independent_of_source_role() -> None:
    routes = {
        source_role: route_escalation(
            _request(source_role=source_role, category=EscalationCategory.TEST_DEFECT)
        )
        for source_role in (AgentRole.PLANNER, AgentRole.IMPLEMENTER, AgentRole.REVIEWER)
    }

    authorities = {route.authority for route in routes.values()}
    halt_levels = {route.halt_level for route in routes.values()}

    assert authorities == {EscalationAuthority.PLANNER}
    assert halt_levels == {HaltLevel.AGENT}


# ---------------------------------------------------------------------------
# Determinism and serialization (Section 39)
# ---------------------------------------------------------------------------


def test_route_escalation_is_pure_and_deterministic() -> None:
    request = _request(category=EscalationCategory.ARCHITECTURE_CONFLICT)

    first = route_escalation(request)
    second = route_escalation(request)

    assert first == second


def test_identical_requests_serialize_identically() -> None:
    first = _request()
    second = _request()

    assert first == second
    assert first.model_dump_json() == second.model_dump_json()
    assert EscalationRequest.model_validate_json(first.model_dump_json()) == first


# ---------------------------------------------------------------------------
# Bounded repr (Section 40)
# ---------------------------------------------------------------------------


def test_escalation_request_repr_is_bounded_and_free_of_unrelated_state() -> None:
    sentinel = "SENTINEL-9F2C-ESCALATION-DO-NOT-CONFUSE-WITH-ENV"
    request = _request(
        question=f"{sentinel} - is this precondition satisfied?",
        evidence=(f"{sentinel} - the precondition check failed deterministically.",),
    )

    rendered = repr(request)

    assert sentinel in rendered
    assert len(rendered) < 4 * (_MAX_QUESTION_LENGTH + _MAX_EVIDENCE_ENTRY_LENGTH)
    for unrelated in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "/home/", "/Users/"):
        assert unrelated not in rendered


# ---------------------------------------------------------------------------
# Pure dependency boundary audit (Section 41)
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
    "pathlib",
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


def test_escalation_module_has_no_forbidden_imports() -> None:
    tree = ast.parse(inspect.getsource(escalation_module))
    imported_modules = _imported_modules(tree)

    for forbidden_prefix in _FORBIDDEN_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


def test_escalation_module_only_imports_lockstep_domain() -> None:
    tree = ast.parse(inspect.getsource(escalation_module))
    imported_modules = _imported_modules(tree)

    lockstep_imports = {
        module
        for module in imported_modules
        if module == "lockstep" or module.startswith("lockstep.")
    }
    assert lockstep_imports <= {"lockstep.domain"}


# ---------------------------------------------------------------------------
# No provider names (Section 42)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("provider_name", ["claude", "codex", "openai", "anthropic"])
def test_escalation_module_source_has_no_provider_names(provider_name: str) -> None:
    source = inspect.getsource(escalation_module).lower()
    assert provider_name not in source


# ---------------------------------------------------------------------------
# No auto-human semantics (Section 43)
# ---------------------------------------------------------------------------


def test_escalation_module_never_prompts_a_human() -> None:
    tree = ast.parse(inspect.getsource(escalation_module))

    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            assert node.func.id not in {"input", "print"}
        if isinstance(node, ast.Attribute):
            assert not (isinstance(node.value, ast.Name) and node.value.id == "sys")


# ---------------------------------------------------------------------------
# No auto-Planner semantics (Section 44)
# ---------------------------------------------------------------------------


def test_escalation_module_never_invokes_an_agent() -> None:
    source = inspect.getsource(escalation_module)
    tree = ast.parse(source)

    imported_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import | ast.ImportFrom):
            for alias in node.names:
                imported_names.add(alias.asname or alias.name)

    for forbidden in ("invoke_agent", "AgentRuntime", "prepare_agent_runtime"):
        assert forbidden not in imported_names
        assert forbidden not in source


# ---------------------------------------------------------------------------
# EscalationProtocolError (Section 25)
# ---------------------------------------------------------------------------


def test_escalation_protocol_error_is_a_normal_exception() -> None:
    error = EscalationProtocolError("reserved for future protocol violations")
    assert isinstance(error, Exception)
    assert "reserved for future protocol violations" in str(error)


def test_route_escalation_does_not_raise_for_any_valid_category() -> None:
    for category in EscalationCategory:
        for requested_authority in EscalationAuthority:
            request = _request(category=category, requested_authority=requested_authority)
            route = route_escalation(request)
            assert isinstance(route, EscalationRoute)
