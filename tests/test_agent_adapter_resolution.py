import ast
import dataclasses
import inspect
from dataclasses import FrozenInstanceError
from pathlib import Path

import pytest

from lockstep.agents import (
    AgentAdapterResolutionError,
    AgentInvocationRequest,
    AgentProviderStatuses,
    ClaudeAdapter,
    ClaudeCliStatus,
    ClaudePreflightError,
    CodexAdapter,
    CodexCliStatus,
    CodexPreflightError,
    ResolvedAgentAdapters,
    resolve_agent_adapters,
)
from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.domain import AgentRole, BillingMode

# ---------------------------------------------------------------------------
# Fixtures (Sections 25, 26)
# ---------------------------------------------------------------------------


def _healthy_claude_status(*, executable: str = "/fake/bin/claude") -> ClaudeCliStatus:
    return ClaudeCliStatus(
        executable=executable,
        version="2.1.259",
        logged_in=True,
        auth_method="claude.ai",
        api_provider="firstParty",
        subscription_type="max",
        supports_print=True,
        supports_model=True,
        supports_effort=True,
        supports_output_format=True,
        supports_json_schema=True,
        supports_permission_mode=True,
        supports_permission_prompts=True,
        supports_no_session_persistence=True,
        supports_restricted=True,
        supports_bare=False,
        supports_tools=True,
        supports_disallowed_tools=True,
        supports_safe_mode=True,
        supports_allowed_tools=True,
    )


def _healthy_codex_status(*, executable: str = "/fake/bin/codex") -> CodexCliStatus:
    return CodexCliStatus(
        executable=executable,
        version="0.1.0",
        doctor_schema_version=1,
        doctor_overall_status="ok",
        doctor_returncode=0,
        auth_check_status="ok",
        stored_auth_mode="chatgpt",
        stored_chatgpt_tokens=True,
        stored_api_key=False,
        supports_exec_ephemeral=True,
        supports_exec_ignore_user_config=True,
        supports_exec_sandbox=True,
        supports_exec_color=True,
        supports_exec_ignore_rules=True,
        supports_exec_output_schema=True,
    )


def _route(
    provider: AgentProvider,
    model: str = "model",
    effort: str = "low",
    *,
    billing_mode: BillingMode = BillingMode.SUBSCRIPTION_ONLY,
) -> AgentRoleRoute:
    return AgentRoleRoute(provider=provider, model=model, effort=effort, billing_mode=billing_mode)


def _policy(
    planner_provider: AgentProvider,
    implementer_provider: AgentProvider,
    reviewer_provider: AgentProvider,
) -> AgentRoutingPolicy:
    return AgentRoutingPolicy(
        planner=_route(planner_provider, "planner-model", "planner-effort"),
        implementer=_route(implementer_provider, "implementer-model", "implementer-effort"),
        reviewer=_route(reviewer_provider, "reviewer-model", "reviewer-effort"),
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


# ---------------------------------------------------------------------------
# Result shape (Section 27 / AC-7.2.7-9)
# ---------------------------------------------------------------------------


def test_provider_statuses_is_frozen_and_slotted() -> None:
    statuses = AgentProviderStatuses(claude=_healthy_claude_status())

    with pytest.raises(FrozenInstanceError):
        statuses.claude = None  # type: ignore[misc]
    assert not hasattr(statuses, "__dict__")


def test_provider_statuses_both_fields_default_to_none() -> None:
    statuses = AgentProviderStatuses()

    assert statuses.claude is None
    assert statuses.codex is None


def test_resolved_adapters_is_frozen_slotted_and_has_exactly_three_roles(
    tmp_path: Path,
) -> None:
    policy = _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE)
    statuses = AgentProviderStatuses(claude=_healthy_claude_status())

    resolved = resolve_agent_adapters(policy, statuses, tmp_path)

    assert isinstance(resolved, ResolvedAgentAdapters)
    assert not hasattr(resolved, "__dict__")
    field_names = {field.name for field in dataclasses.fields(resolved)}
    assert field_names == {"planner", "implementer", "reviewer"}

    with pytest.raises(FrozenInstanceError):
        resolved.planner = resolved.implementer  # type: ignore[misc]


# ---------------------------------------------------------------------------
# All eight combinations and exact role mapping (Sections 19, 28 / AC-7.2.10-12)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("planner_provider", "implementer_provider", "reviewer_provider"),
    _ALL_PROVIDER_ASSIGNMENTS,
)
def test_all_eight_combinations_resolve_to_exact_providers_and_roles(
    planner_provider: AgentProvider,
    implementer_provider: AgentProvider,
    reviewer_provider: AgentProvider,
    tmp_path: Path,
) -> None:
    policy = _policy(planner_provider, implementer_provider, reviewer_provider)
    statuses = AgentProviderStatuses(
        claude=_healthy_claude_status(),
        codex=_healthy_codex_status(),
    )

    resolved = resolve_agent_adapters(policy, statuses, tmp_path)

    for attr, provider, agent_role in (
        ("planner", planner_provider, AgentRole.PLANNER),
        ("implementer", implementer_provider, AgentRole.IMPLEMENTER),
        ("reviewer", reviewer_provider, AgentRole.REVIEWER),
    ):
        adapter = getattr(resolved, attr)
        assert adapter.name == provider.value
        assert adapter.role is agent_role


def test_role_independence_forward_and_inverse_provider_assignment(tmp_path: Path) -> None:
    statuses = AgentProviderStatuses(
        claude=_healthy_claude_status(),
        codex=_healthy_codex_status(),
    )

    forward = resolve_agent_adapters(
        _policy(AgentProvider.CLAUDE, AgentProvider.CODEX, AgentProvider.CLAUDE),
        statuses,
        tmp_path / "forward",
    )
    inverse = resolve_agent_adapters(
        _policy(AgentProvider.CODEX, AgentProvider.CLAUDE, AgentProvider.CODEX),
        statuses,
        tmp_path / "inverse",
    )

    assert isinstance(forward.planner, ClaudeAdapter)
    assert isinstance(forward.implementer, CodexAdapter)
    assert isinstance(forward.reviewer, ClaudeAdapter)

    assert isinstance(inverse.planner, CodexAdapter)
    assert isinstance(inverse.implementer, ClaudeAdapter)
    assert isinstance(inverse.reviewer, CodexAdapter)


# ---------------------------------------------------------------------------
# Exact model / effort translation (Section 29 / AC-7.2.13-17)
# ---------------------------------------------------------------------------


def test_exact_model_and_effort_mapping_for_claude_routes(tmp_path: Path) -> None:
    policy = AgentRoutingPolicy(
        planner=_route(AgentProvider.CLAUDE, "planner-model-7-2", "planner-effort-7-2"),
        implementer=_route(AgentProvider.CLAUDE, "implementer-model-7-2", "implementer-effort-7-2"),
        reviewer=_route(AgentProvider.CLAUDE, "reviewer-model-7-2", "reviewer-effort-7-2"),
    )
    statuses = AgentProviderStatuses(claude=_healthy_claude_status())

    resolved = resolve_agent_adapters(policy, statuses, tmp_path)

    assert resolved.planner.model == "planner-model-7-2"  # type: ignore[attr-defined]
    assert resolved.planner.effort == "planner-effort-7-2"  # type: ignore[attr-defined]
    assert resolved.implementer.model == "implementer-model-7-2"  # type: ignore[attr-defined]
    assert resolved.implementer.effort == "implementer-effort-7-2"  # type: ignore[attr-defined]
    assert resolved.reviewer.model == "reviewer-model-7-2"  # type: ignore[attr-defined]
    assert resolved.reviewer.effort == "reviewer-effort-7-2"  # type: ignore[attr-defined]


def test_exact_model_and_effort_mapping_for_codex_routes(tmp_path: Path) -> None:
    policy = AgentRoutingPolicy(
        planner=_route(AgentProvider.CODEX, "planner-model-7-2", "planner-effort-7-2"),
        implementer=_route(AgentProvider.CODEX, "implementer-model-7-2", "implementer-effort-7-2"),
        reviewer=_route(AgentProvider.CODEX, "reviewer-model-7-2", "reviewer-effort-7-2"),
    )
    statuses = AgentProviderStatuses(codex=_healthy_codex_status())

    resolved = resolve_agent_adapters(policy, statuses, tmp_path)

    assert resolved.planner.model == "planner-model-7-2"  # type: ignore[attr-defined]
    assert resolved.planner.reasoning_effort == "planner-effort-7-2"  # type: ignore[attr-defined]
    assert resolved.implementer.model == "implementer-model-7-2"  # type: ignore[attr-defined]
    assert (
        resolved.implementer.reasoning_effort  # type: ignore[attr-defined]
        == "implementer-effort-7-2"
    )
    assert resolved.reviewer.model == "reviewer-model-7-2"  # type: ignore[attr-defined]
    assert resolved.reviewer.reasoning_effort == "reviewer-effort-7-2"  # type: ignore[attr-defined]


# ---------------------------------------------------------------------------
# Missing / unused provider status (Sections 6, 18, 30, 31 / AC-7.2.18-19)
# ---------------------------------------------------------------------------


def test_all_claude_policy_resolves_with_no_codex_status(tmp_path: Path) -> None:
    policy = _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE)
    statuses = AgentProviderStatuses(claude=_healthy_claude_status(), codex=None)

    resolved = resolve_agent_adapters(policy, statuses, tmp_path)

    assert isinstance(resolved.planner, ClaudeAdapter)
    assert isinstance(resolved.implementer, ClaudeAdapter)
    assert isinstance(resolved.reviewer, ClaudeAdapter)


def test_all_codex_policy_resolves_with_no_claude_status(tmp_path: Path) -> None:
    policy = _policy(AgentProvider.CODEX, AgentProvider.CODEX, AgentProvider.CODEX)
    statuses = AgentProviderStatuses(claude=None, codex=_healthy_codex_status())

    resolved = resolve_agent_adapters(policy, statuses, tmp_path)

    assert isinstance(resolved.planner, CodexAdapter)
    assert isinstance(resolved.implementer, CodexAdapter)
    assert isinstance(resolved.reviewer, CodexAdapter)


def test_missing_claude_status_fails_before_any_side_effect(tmp_path: Path) -> None:
    policy = _policy(AgentProvider.CLAUDE, AgentProvider.CODEX, AgentProvider.CODEX)
    statuses = AgentProviderStatuses(claude=None, codex=_healthy_codex_status())

    with pytest.raises(AgentAdapterResolutionError):
        resolve_agent_adapters(policy, statuses, tmp_path)

    assert not (tmp_path / "providers").exists()


def test_missing_codex_status_fails_before_any_side_effect(tmp_path: Path) -> None:
    policy = _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CODEX)
    statuses = AgentProviderStatuses(claude=_healthy_claude_status(), codex=None)

    with pytest.raises(AgentAdapterResolutionError):
        resolve_agent_adapters(policy, statuses, tmp_path)

    assert not (tmp_path / "providers").exists()


# ---------------------------------------------------------------------------
# Unsupported billing rejected at resolution time (Section 32 / AC-7.2.20-21)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("role_attr", "provider"),
    [
        ("planner", AgentProvider.CLAUDE),
        ("planner", AgentProvider.CODEX),
        ("implementer", AgentProvider.CLAUDE),
        ("implementer", AgentProvider.CODEX),
        ("reviewer", AgentProvider.CLAUDE),
        ("reviewer", AgentProvider.CODEX),
    ],
)
def test_unsupported_billing_mode_fails_before_any_side_effect(
    role_attr: str,
    provider: AgentProvider,
    tmp_path: Path,
) -> None:
    routes = {
        "planner": _route(AgentProvider.CLAUDE, "planner-model", "low"),
        "implementer": _route(AgentProvider.CLAUDE, "implementer-model", "low"),
        "reviewer": _route(AgentProvider.CLAUDE, "reviewer-model", "low"),
    }
    routes[role_attr] = _route(
        provider,
        f"{role_attr}-model",
        "low",
        billing_mode=BillingMode.API_ALLOWED,
    )

    policy = AgentRoutingPolicy(**routes)
    statuses = AgentProviderStatuses(
        claude=_healthy_claude_status(),
        codex=_healthy_codex_status(),
    )

    with pytest.raises(AgentAdapterResolutionError):
        resolve_agent_adapters(policy, statuses, tmp_path)

    assert not (tmp_path / "providers").exists()


# ---------------------------------------------------------------------------
# Codex Reviewer schema materialization (Sections 4, 20, 33 / AC-7.2.26-27, 30)
# ---------------------------------------------------------------------------


def test_codex_reviewer_schema_materialized_and_wired_into_adapter(tmp_path: Path) -> None:
    policy = _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CODEX)
    statuses = AgentProviderStatuses(
        claude=_healthy_claude_status(),
        codex=_healthy_codex_status(),
    )

    resolved = resolve_agent_adapters(policy, statuses, tmp_path)

    expected_path = tmp_path.resolve() / "providers" / "codex" / "review-decision.schema.json"
    assert expected_path.exists()

    assert isinstance(resolved.reviewer, CodexAdapter)
    assert resolved.reviewer.role is AgentRole.REVIEWER
    assert resolved.reviewer.review_output_schema_path == expected_path

    request = AgentInvocationRequest(
        role=AgentRole.REVIEWER,
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        prompt="reviewer prompt",
        cwd=tmp_path,
        timeout_seconds=5,
    )
    command = resolved.reviewer.build_command(request)

    assert "--output-schema" in command.argv
    index = command.argv.index("--output-schema")
    assert command.argv[index + 1] == str(expected_path)


def test_runtime_dir_is_resolved_before_schema_materialization(tmp_path: Path) -> None:
    messy_runtime_dir = tmp_path / "runtime" / ".." / "runtime"
    policy = _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CODEX)
    statuses = AgentProviderStatuses(
        claude=_healthy_claude_status(),
        codex=_healthy_codex_status(),
    )

    resolved = resolve_agent_adapters(policy, statuses, messy_runtime_dir)

    expected_path = (
        (tmp_path / "runtime").resolve() / "providers" / "codex" / "review-decision.schema.json"
    )
    assert expected_path.exists()
    assert isinstance(resolved.reviewer, CodexAdapter)
    assert resolved.reviewer.review_output_schema_path == expected_path


# ---------------------------------------------------------------------------
# Claude Reviewer causes no Codex materialization (Sections 4, 21, 34 / AC-7.2.29, 31)
# ---------------------------------------------------------------------------


def test_claude_reviewer_causes_no_codex_schema_materialization(tmp_path: Path) -> None:
    policy = _policy(AgentProvider.CODEX, AgentProvider.CODEX, AgentProvider.CLAUDE)
    statuses = AgentProviderStatuses(
        claude=_healthy_claude_status(),
        codex=_healthy_codex_status(),
    )

    resolved = resolve_agent_adapters(policy, statuses, tmp_path)

    assert not (tmp_path / "providers" / "codex" / "review-decision.schema.json").exists()
    assert isinstance(resolved.reviewer, ClaudeAdapter)

    request = AgentInvocationRequest(
        role=AgentRole.REVIEWER,
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        prompt="reviewer prompt",
        cwd=tmp_path,
        timeout_seconds=5,
    )
    command = resolved.reviewer.build_command(request)

    assert "--json-schema" in command.argv


# ---------------------------------------------------------------------------
# Codex non-reviewers receive no schema (Section 35 / AC-7.2.28)
# ---------------------------------------------------------------------------


def test_codex_non_reviewer_roles_receive_no_schema_path(tmp_path: Path) -> None:
    policy = _policy(AgentProvider.CODEX, AgentProvider.CODEX, AgentProvider.CODEX)
    statuses = AgentProviderStatuses(codex=_healthy_codex_status())

    resolved = resolve_agent_adapters(policy, statuses, tmp_path)

    assert isinstance(resolved.planner, CodexAdapter)
    assert isinstance(resolved.implementer, CodexAdapter)
    assert resolved.planner.review_output_schema_path is None
    assert resolved.implementer.review_output_schema_path is None
    assert resolved.reviewer.review_output_schema_path is not None  # type: ignore[attr-defined]


# ---------------------------------------------------------------------------
# Provider runtime paths (Section 17, 36 / AC-7.2.23-25)
# ---------------------------------------------------------------------------


def test_provider_runtime_paths_routed_without_cross_wiring(tmp_path: Path) -> None:
    claude_dir = tmp_path / "claude-config"
    codex_dir = tmp_path / "codex-home"
    claude_dir.mkdir()
    codex_dir.mkdir()

    policy = _policy(AgentProvider.CLAUDE, AgentProvider.CODEX, AgentProvider.CLAUDE)
    statuses = AgentProviderStatuses(
        claude=_healthy_claude_status(),
        codex=_healthy_codex_status(),
    )

    resolved = resolve_agent_adapters(
        policy,
        statuses,
        tmp_path / "runtime",
        claude_config_dir=claude_dir,
        codex_home=codex_dir,
    )

    assert isinstance(resolved.planner, ClaudeAdapter)
    assert isinstance(resolved.implementer, CodexAdapter)
    assert isinstance(resolved.reviewer, ClaudeAdapter)

    assert resolved.planner.claude_config_dir == claude_dir.resolve()
    assert resolved.reviewer.claude_config_dir == claude_dir.resolve()
    assert resolved.implementer.codex_home == codex_dir.resolve()

    assert not hasattr(resolved.planner, "codex_home")
    assert not hasattr(resolved.implementer, "claude_config_dir")


def test_unused_provider_runtime_paths_are_legal(tmp_path: Path) -> None:
    policy = _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE)
    statuses = AgentProviderStatuses(claude=_healthy_claude_status())

    resolved = resolve_agent_adapters(
        policy,
        statuses,
        tmp_path,
        claude_config_dir=None,
        codex_home=tmp_path / "unused-codex-home",
    )

    assert isinstance(resolved.planner, ClaudeAdapter)


# ---------------------------------------------------------------------------
# Lower-layer exception transparency (Section 37 / AC-7.2.22)
# ---------------------------------------------------------------------------


def test_claude_preflight_error_propagates_unwrapped(tmp_path: Path) -> None:
    policy = _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE)
    unhealthy = dataclasses.replace(_healthy_claude_status(), logged_in=False)
    statuses = AgentProviderStatuses(claude=unhealthy)

    with pytest.raises(ClaudePreflightError):
        resolve_agent_adapters(policy, statuses, tmp_path)


def test_codex_preflight_error_propagates_unwrapped(tmp_path: Path) -> None:
    policy = _policy(AgentProvider.CODEX, AgentProvider.CODEX, AgentProvider.CODEX)
    unhealthy = dataclasses.replace(_healthy_codex_status(), auth_check_status="error")
    statuses = AgentProviderStatuses(codex=unhealthy)

    with pytest.raises(CodexPreflightError):
        resolve_agent_adapters(policy, statuses, tmp_path)


# ---------------------------------------------------------------------------
# Resolver error privacy (Section 12, 38 / AC-7.2.35)
# ---------------------------------------------------------------------------

_FORBIDDEN_ERROR_SUBSTRINGS: tuple[str, ...] = (
    "token",
    "secret",
    "password",
    "credential",
    "stdout",
    "stderr",
    "authorization",
)


def test_missing_status_error_is_bounded_and_privacy_safe(tmp_path: Path) -> None:
    policy = _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE)
    statuses = AgentProviderStatuses(claude=None)

    with pytest.raises(AgentAdapterResolutionError) as exc_info:
        resolve_agent_adapters(policy, statuses, tmp_path)

    error = exc_info.value
    assert isinstance(error.reason, str)
    assert "planner" in error.reason
    assert "claude" in error.reason
    for forbidden in _FORBIDDEN_ERROR_SUBSTRINGS:
        assert forbidden not in error.reason.lower()
        assert forbidden not in str(error).lower()


def test_billing_mode_error_is_bounded_and_privacy_safe(tmp_path: Path) -> None:
    policy = AgentRoutingPolicy(
        planner=_route(
            AgentProvider.CLAUDE,
            "planner-model",
            "low",
            billing_mode=BillingMode.API_ALLOWED,
        ),
        implementer=_route(AgentProvider.CLAUDE, "implementer-model", "low"),
        reviewer=_route(AgentProvider.CLAUDE, "reviewer-model", "low"),
    )
    statuses = AgentProviderStatuses(claude=_healthy_claude_status())

    with pytest.raises(AgentAdapterResolutionError) as exc_info:
        resolve_agent_adapters(policy, statuses, tmp_path)

    error = exc_info.value
    assert "planner" in error.reason
    assert "api_allowed" in error.reason.lower()
    for forbidden in _FORBIDDEN_ERROR_SUBSTRINGS:
        assert forbidden not in error.reason.lower()


# ---------------------------------------------------------------------------
# No provider/process execution (Section 22-24, 39 / AC-7.2.32-34)
# ---------------------------------------------------------------------------

_FORBIDDEN_RESOLVER_REFERENCES: tuple[str, ...] = (
    "probe_claude_cli",
    "probe_codex_cli",
    "require_claude_subscription_ready",
    "require_codex_subscription_ready",
    "invoke_agent",
    "run_process",
    "subprocess",
    "Supervisor",
    "run_single_subphase_transaction",
    "SingleSubphaseTransactionRequest",
    "AgentInvocationRequest",
)


def test_resolution_module_has_no_forbidden_imports_or_calls() -> None:
    import lockstep.agents.resolution as resolution_module

    tree = ast.parse(inspect.getsource(resolution_module))

    imported_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import | ast.ImportFrom):
            for alias in node.names:
                imported_names.add(alias.asname or alias.name)

    called_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            func = node.func
            if isinstance(func, ast.Name):
                called_names.add(func.id)
            elif isinstance(func, ast.Attribute):
                called_names.add(func.attr)

    for forbidden in _FORBIDDEN_RESOLVER_REFERENCES:
        assert forbidden not in imported_names
        assert forbidden not in called_names


def test_resolve_agent_adapters_never_launches_a_process(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def _fail(*args: object, **kwargs: object) -> None:
        raise AssertionError("resolver must not launch a process")

    monkeypatch.setattr("lockstep.process.run_process", _fail)

    policy = _policy(AgentProvider.CODEX, AgentProvider.CLAUDE, AgentProvider.CODEX)
    statuses = AgentProviderStatuses(
        claude=_healthy_claude_status(),
        codex=_healthy_codex_status(),
    )

    resolved = resolve_agent_adapters(policy, statuses, tmp_path)

    assert isinstance(resolved, ResolvedAgentAdapters)


# ---------------------------------------------------------------------------
# Deterministic repeated resolution (Section 40 / AC-7.2.36)
# ---------------------------------------------------------------------------


def test_repeated_resolution_is_structurally_deterministic_for_claude_reviewer(
    tmp_path: Path,
) -> None:
    policy = _policy(AgentProvider.CODEX, AgentProvider.CODEX, AgentProvider.CLAUDE)
    statuses = AgentProviderStatuses(
        claude=_healthy_claude_status(),
        codex=_healthy_codex_status(),
    )

    first = resolve_agent_adapters(policy, statuses, tmp_path)
    second = resolve_agent_adapters(policy, statuses, tmp_path)

    assert first.planner == second.planner
    assert first.implementer == second.implementer
    assert first.reviewer == second.reviewer


def test_repeated_resolution_into_same_runtime_dir_is_deterministic_for_codex_reviewer(
    tmp_path: Path,
) -> None:
    policy = _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CODEX)
    statuses = AgentProviderStatuses(
        claude=_healthy_claude_status(),
        codex=_healthy_codex_status(),
    )

    first = resolve_agent_adapters(policy, statuses, tmp_path)
    second = resolve_agent_adapters(policy, statuses, tmp_path)

    assert isinstance(first.reviewer, CodexAdapter)
    assert isinstance(second.reviewer, CodexAdapter)
    assert first.reviewer.review_output_schema_path == second.reviewer.review_output_schema_path
    assert first.reviewer.review_output_schema_path is not None
    assert first.reviewer.review_output_schema_path.exists()
    assert first.reviewer == second.reviewer
