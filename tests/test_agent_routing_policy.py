import ast
import inspect
from dataclasses import FrozenInstanceError, replace

import pytest

from lockstep.agents.routing import (
    AgentProvider,
    AgentRoleRoute,
    AgentRoutingPolicy,
    AgentRoutingPolicyError,
)
from lockstep.domain import BillingMode

# ---------------------------------------------------------------------------
# Provider identity (Section 3 / AC-7.1.7)
# ---------------------------------------------------------------------------


def test_agent_provider_contains_exactly_claude_and_codex() -> None:
    assert {member.name: member.value for member in AgentProvider} == {
        "CLAUDE": "claude",
        "CODEX": "codex",
    }


def test_agent_provider_is_string_backed() -> None:
    assert AgentProvider.CLAUDE.value == "claude"
    assert AgentProvider.CODEX.value == "codex"


# ---------------------------------------------------------------------------
# Role route construction and validation (Sections 4, 7, 8, 6 / AC-7.1.10-23)
# ---------------------------------------------------------------------------


def _route(
    *,
    provider: AgentProvider = AgentProvider.CLAUDE,
    model: str = "model-exact-7-1",
    effort: str = "effort-exact-7-1",
    billing_mode: BillingMode = BillingMode.SUBSCRIPTION_ONLY,
) -> AgentRoleRoute:
    return AgentRoleRoute(
        provider=provider,
        model=model,
        effort=effort,
        billing_mode=billing_mode,
    )


def test_role_route_preserves_exact_values() -> None:
    route = _route(
        provider=AgentProvider.CODEX,
        model="model-exact-7-1",
        effort="effort-exact-7-1",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )

    assert route.provider is AgentProvider.CODEX
    assert route.model == "model-exact-7-1"
    assert route.effort == "effort-exact-7-1"
    assert route.billing_mode is BillingMode.SUBSCRIPTION_ONLY


@pytest.mark.parametrize("bad_model", ["", " ", "\t", "\n", "model\x00bad"])
def test_blank_or_nul_model_rejected(bad_model: str) -> None:
    with pytest.raises(AgentRoutingPolicyError):
        _route(model=bad_model)


@pytest.mark.parametrize("bad_effort", ["", " ", "\t", "\n", "effort\x00bad"])
def test_blank_or_nul_effort_rejected(bad_effort: str) -> None:
    with pytest.raises(AgentRoutingPolicyError):
        _route(effort=bad_effort)


def test_model_with_interior_spaces_remains_legal() -> None:
    route = _route(model="model with spaces")

    assert route.model == "model with spaces"


@pytest.mark.parametrize(
    "billing_mode",
    [BillingMode.SUBSCRIPTION_ONLY, BillingMode.API_ALLOWED],
)
def test_billing_mode_preserved_exactly(billing_mode: BillingMode) -> None:
    route = _route(billing_mode=billing_mode)

    assert route.billing_mode is billing_mode


def test_billing_mode_has_no_implicit_default() -> None:
    with pytest.raises(TypeError):
        AgentRoleRoute(  # type: ignore[call-arg]
            provider=AgentProvider.CLAUDE,
            model="model-exact-7-1",
            effort="effort-exact-7-1",
        )


# ---------------------------------------------------------------------------
# Routing policy aggregate (Sections 5, 9, 24, 25 / AC-7.1.13-14, 24)
# ---------------------------------------------------------------------------


def test_routing_policy_requires_exactly_three_roles() -> None:
    with pytest.raises(TypeError):
        AgentRoutingPolicy(  # type: ignore[call-arg]
            planner=_route(),
            implementer=_route(),
        )


def test_routing_policy_rejects_unknown_role_field() -> None:
    with pytest.raises(TypeError):
        AgentRoutingPolicy(  # type: ignore[call-arg]
            planner=_route(),
            implementer=_route(),
            reviewer=_route(),
            scribe=_route(),
        )


_ALL_PROVIDER_ASSIGNMENTS: tuple[tuple[AgentProvider, AgentProvider, AgentProvider], ...] = (
    (AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
    (AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CODEX),
    (AgentProvider.CLAUDE, AgentProvider.CODEX, AgentProvider.CLAUDE),
    (AgentProvider.CLAUDE, AgentProvider.CODEX, AgentProvider.CODEX),
    (AgentProvider.CODEX, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
    (AgentProvider.CODEX, AgentProvider.CLAUDE, AgentProvider.CODEX),
    (AgentProvider.CODEX, AgentProvider.CODEX, AgentProvider.CLAUDE),
    (AgentProvider.CODEX, AgentProvider.CODEX, AgentProvider.CODEX),
)


@pytest.mark.parametrize(
    ("planner_provider", "implementer_provider", "reviewer_provider"),
    _ALL_PROVIDER_ASSIGNMENTS,
)
def test_all_provider_role_combinations_are_legal(
    planner_provider: AgentProvider,
    implementer_provider: AgentProvider,
    reviewer_provider: AgentProvider,
) -> None:
    policy = AgentRoutingPolicy(
        planner=_route(provider=planner_provider, model="planner-model", effort="low"),
        implementer=_route(
            provider=implementer_provider,
            model="implementer-model",
            effort="low",
        ),
        reviewer=_route(provider=reviewer_provider, model="reviewer-model", effort="low"),
    )

    assert policy.planner.provider is planner_provider
    assert policy.implementer.provider is implementer_provider
    assert policy.reviewer.provider is reviewer_provider


def test_role_independence_no_field_derives_another() -> None:
    forward = AgentRoutingPolicy(
        planner=_route(provider=AgentProvider.CLAUDE, model="planner-model", effort="low"),
        implementer=_route(provider=AgentProvider.CODEX, model="implementer-model", effort="low"),
        reviewer=_route(provider=AgentProvider.CLAUDE, model="reviewer-model", effort="low"),
    )
    inverse = AgentRoutingPolicy(
        planner=_route(provider=AgentProvider.CODEX, model="planner-model", effort="low"),
        implementer=_route(provider=AgentProvider.CLAUDE, model="implementer-model", effort="low"),
        reviewer=_route(provider=AgentProvider.CODEX, model="reviewer-model", effort="low"),
    )

    assert forward.planner.provider is AgentProvider.CLAUDE
    assert forward.implementer.provider is AgentProvider.CODEX
    assert forward.reviewer.provider is AgentProvider.CLAUDE

    assert inverse.planner.provider is AgentProvider.CODEX
    assert inverse.implementer.provider is AgentProvider.CLAUDE
    assert inverse.reviewer.provider is AgentProvider.CODEX


def test_all_claude_policy_constructs() -> None:
    policy = AgentRoutingPolicy(
        planner=_route(provider=AgentProvider.CLAUDE),
        implementer=_route(provider=AgentProvider.CLAUDE),
        reviewer=_route(provider=AgentProvider.CLAUDE),
    )

    assert policy.planner.provider is AgentProvider.CLAUDE
    assert policy.implementer.provider is AgentProvider.CLAUDE
    assert policy.reviewer.provider is AgentProvider.CLAUDE


def test_all_codex_policy_constructs() -> None:
    policy = AgentRoutingPolicy(
        planner=_route(provider=AgentProvider.CODEX),
        implementer=_route(provider=AgentProvider.CODEX),
        reviewer=_route(provider=AgentProvider.CODEX),
    )

    assert policy.planner.provider is AgentProvider.CODEX
    assert policy.implementer.provider is AgentProvider.CODEX
    assert policy.reviewer.provider is AgentProvider.CODEX


# ---------------------------------------------------------------------------
# Immutability (Section 26 / AC-7.1.8-9)
# ---------------------------------------------------------------------------


def test_role_route_is_immutable() -> None:
    route = _route()

    with pytest.raises(FrozenInstanceError):
        route.model = "other-model"  # type: ignore[misc]


def test_routing_policy_is_immutable() -> None:
    policy = AgentRoutingPolicy(planner=_route(), implementer=_route(), reviewer=_route())

    with pytest.raises(FrozenInstanceError):
        policy.planner = _route()  # type: ignore[misc]


def test_role_route_replace_does_not_mutate_original() -> None:
    original = _route(model="model-exact-7-1")
    replaced = replace(original, model="model-exact-7-1-b")

    assert original.model == "model-exact-7-1"
    assert replaced.model == "model-exact-7-1-b"


# ---------------------------------------------------------------------------
# Dependency audit (Section 27 / AC-7.1.25-26)
# ---------------------------------------------------------------------------

_FORBIDDEN_REFERENCES: tuple[str, ...] = (
    "ClaudeAdapter",
    "CodexAdapter",
    "probe_claude_cli",
    "probe_codex_cli",
    "run_process",
    "invoke_agent",
    "Supervisor",
    "subprocess",
)


def test_routing_module_has_no_provider_or_process_dependencies() -> None:
    import lockstep.agents.routing as routing_module

    source = inspect.getsource(routing_module)
    tree = ast.parse(source)

    imported_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import | ast.ImportFrom):
            for alias in node.names:
                imported_names.add(alias.asname or alias.name)

    for forbidden in _FORBIDDEN_REFERENCES:
        assert forbidden not in imported_names
        assert forbidden not in source


# ---------------------------------------------------------------------------
# No role/provider preference (Sections 10, 28 / AC-7.1.14)
# ---------------------------------------------------------------------------


def test_routing_module_source_has_no_hardcoded_role_provider_branch() -> None:
    import lockstep.agents.routing as routing_module

    tree = ast.parse(inspect.getsource(routing_module))

    for node in ast.walk(tree):
        if isinstance(node, ast.If):
            branch_source = ast.dump(node)
            assert "PLANNER" not in branch_source
            assert "IMPLEMENTER" not in branch_source
            assert "REVIEWER" not in branch_source


def test_constructing_every_planner_provider_with_every_reviewer_provider_is_symmetric() -> None:
    for planner_provider in AgentProvider:
        for reviewer_provider in AgentProvider:
            policy = AgentRoutingPolicy(
                planner=_route(provider=planner_provider, model="p", effort="low"),
                implementer=_route(provider=AgentProvider.CLAUDE, model="i", effort="low"),
                reviewer=_route(provider=reviewer_provider, model="r", effort="low"),
            )

            assert policy.planner.provider is planner_provider
            assert policy.reviewer.provider is reviewer_provider
