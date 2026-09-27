import ast
import dataclasses
import inspect
import os
from dataclasses import FrozenInstanceError
from pathlib import Path

import pytest

from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.config import (
    LOCKSTEP_CONFIG_FILENAME,
    ProjectConfig,
    ProjectConfigError,
    load_project_config,
    parse_project_config,
    render_project_config,
)
from lockstep.domain import BillingMode

_CLAUDE = AgentProvider.CLAUDE.value
_CODEX = AgentProvider.CODEX.value
_SUBSCRIPTION_ONLY = BillingMode.SUBSCRIPTION_ONLY.value
_API_ALLOWED = BillingMode.API_ALLOWED.value

_ALL_PROVIDER_VALUE_ASSIGNMENTS: tuple[tuple[str, str, str], ...] = (
    (_CLAUDE, _CLAUDE, _CLAUDE),
    (_CLAUDE, _CLAUDE, _CODEX),
    (_CLAUDE, _CODEX, _CLAUDE),
    (_CLAUDE, _CODEX, _CODEX),
    (_CODEX, _CLAUDE, _CLAUDE),
    (_CODEX, _CLAUDE, _CODEX),
    (_CODEX, _CODEX, _CLAUDE),
    (_CODEX, _CODEX, _CODEX),
)


# ---------------------------------------------------------------------------
# Text fixtures (Section 28-29)
# ---------------------------------------------------------------------------


def _role_fields(
    provider: str, model: str, effort: str, *, billing_mode: str = _SUBSCRIPTION_ONLY
) -> dict[str, str]:
    return {
        "provider": f'"{provider}"',
        "model": f'"{model}"',
        "effort": f'"{effort}"',
        "billing_mode": f'"{billing_mode}"',
    }


def _default_fields() -> dict[str, str]:
    return _role_fields(_CLAUDE, "model", "low")


def _config_text(
    *,
    schema_version_line: str | None = "schema_version = 1\n",
    top_level_extra: str = "",
    include_routing: bool = True,
    role_names: tuple[str, ...] = ("planner", "implementer", "reviewer"),
    role_fields: dict[str, dict[str, str]] | None = None,
) -> str:
    text = (schema_version_line or "") + top_level_extra
    if not include_routing:
        return text

    resolved = role_fields or {}
    for role in role_names:
        fields = resolved.get(role, _default_fields())
        text += f"\n[routing.{role}]\n"
        for key, value in fields.items():
            text += f"{key} = {value}\n"
    return text


def _build_project_config(
    *,
    planner_provider: AgentProvider = AgentProvider.CLAUDE,
    implementer_provider: AgentProvider = AgentProvider.CODEX,
    reviewer_provider: AgentProvider = AgentProvider.CLAUDE,
    planner_model: str = "planner-model",
    implementer_model: str = "implementer-model",
    reviewer_model: str = "reviewer-model",
    planner_effort: str = "low",
    implementer_effort: str = "low",
    reviewer_effort: str = "low",
    billing_mode: BillingMode = BillingMode.SUBSCRIPTION_ONLY,
) -> ProjectConfig:
    return ProjectConfig(
        schema_version=1,
        routing=AgentRoutingPolicy(
            planner=AgentRoleRoute(
                provider=planner_provider,
                model=planner_model,
                effort=planner_effort,
                billing_mode=billing_mode,
            ),
            implementer=AgentRoleRoute(
                provider=implementer_provider,
                model=implementer_model,
                effort=implementer_effort,
                billing_mode=billing_mode,
            ),
            reviewer=AgentRoleRoute(
                provider=reviewer_provider,
                model=reviewer_model,
                effort=reviewer_effort,
                billing_mode=billing_mode,
            ),
        ),
    )


# ---------------------------------------------------------------------------
# Constant / basic shape (AC-7.3.7-9)
# ---------------------------------------------------------------------------


def test_lockstep_config_filename_is_frozen() -> None:
    assert LOCKSTEP_CONFIG_FILENAME == "lockstep.toml"


def test_project_config_is_frozen_and_slotted() -> None:
    config = _build_project_config()

    with pytest.raises(FrozenInstanceError):
        config.schema_version = 2  # type: ignore[misc]
    assert not hasattr(config, "__dict__")


def test_project_config_error_stores_reason() -> None:
    error = ProjectConfigError("test-reason-7-3")

    assert error.reason == "test-reason-7-3"


# ---------------------------------------------------------------------------
# Canonical mixed configuration (Section 29)
# ---------------------------------------------------------------------------


def test_canonical_mixed_config_claude_codex_claude() -> None:
    text = _config_text(
        role_fields={
            "planner": _role_fields(_CLAUDE, "planner-model", "planner-effort"),
            "implementer": _role_fields(_CODEX, "implementer-model", "implementer-effort"),
            "reviewer": _role_fields(_CLAUDE, "reviewer-model", "reviewer-effort"),
        }
    )

    config = parse_project_config(text)

    assert isinstance(config, ProjectConfig)
    assert config.schema_version == 1
    assert isinstance(config.routing, AgentRoutingPolicy)
    assert config.routing.planner == AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model="planner-model",
        effort="planner-effort",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )
    assert config.routing.implementer == AgentRoleRoute(
        provider=AgentProvider.CODEX,
        model="implementer-model",
        effort="implementer-effort",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )
    assert config.routing.reviewer == AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model="reviewer-model",
        effort="reviewer-effort",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )


def test_canonical_mixed_config_codex_claude_codex() -> None:
    text = _config_text(
        role_fields={
            "planner": _role_fields(_CODEX, "planner-model", "planner-effort"),
            "implementer": _role_fields(_CLAUDE, "implementer-model", "implementer-effort"),
            "reviewer": _role_fields(_CODEX, "reviewer-model", "reviewer-effort"),
        }
    )

    config = parse_project_config(text)

    assert config.routing.planner.provider is AgentProvider.CODEX
    assert config.routing.implementer.provider is AgentProvider.CLAUDE
    assert config.routing.reviewer.provider is AgentProvider.CODEX


# ---------------------------------------------------------------------------
# All eight provider assignments (Section 30)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("planner_provider", "implementer_provider", "reviewer_provider"),
    _ALL_PROVIDER_VALUE_ASSIGNMENTS,
)
def test_all_eight_provider_assignments_parse_exactly(
    planner_provider: str, implementer_provider: str, reviewer_provider: str
) -> None:
    text = _config_text(
        role_fields={
            "planner": _role_fields(planner_provider, "planner-model", "low"),
            "implementer": _role_fields(implementer_provider, "implementer-model", "low"),
            "reviewer": _role_fields(reviewer_provider, "reviewer-model", "low"),
        }
    )

    config = parse_project_config(text)

    assert config.routing.planner.provider is AgentProvider(planner_provider)
    assert config.routing.implementer.provider is AgentProvider(implementer_provider)
    assert config.routing.reviewer.provider is AgentProvider(reviewer_provider)


# ---------------------------------------------------------------------------
# Strict top-level schema (Section 31)
# ---------------------------------------------------------------------------


def test_missing_schema_version_rejected() -> None:
    with pytest.raises(ProjectConfigError):
        parse_project_config(_config_text(schema_version_line=None))


def test_missing_routing_rejected() -> None:
    with pytest.raises(ProjectConfigError):
        parse_project_config(_config_text(include_routing=False))


@pytest.mark.parametrize(
    "extra_key",
    ["provider", "providers", "runtime", "defaults", "models", "credentials", "environment"],
)
def test_unknown_top_level_key_rejected(extra_key: str) -> None:
    text = _config_text(top_level_extra=f'{extra_key} = "x"\n')

    with pytest.raises(ProjectConfigError):
        parse_project_config(text)


# ---------------------------------------------------------------------------
# Strict routing roles (Section 32)
# ---------------------------------------------------------------------------


def test_missing_planner_role_rejected() -> None:
    with pytest.raises(ProjectConfigError):
        parse_project_config(_config_text(role_names=("implementer", "reviewer")))


def test_missing_implementer_role_rejected() -> None:
    with pytest.raises(ProjectConfigError):
        parse_project_config(_config_text(role_names=("planner", "reviewer")))


def test_missing_reviewer_role_rejected() -> None:
    with pytest.raises(ProjectConfigError):
        parse_project_config(_config_text(role_names=("planner", "implementer")))


@pytest.mark.parametrize("extra_role", ["scribe", "fallback"])
def test_extra_role_rejected(extra_role: str) -> None:
    text = _config_text(role_names=("planner", "implementer", "reviewer", extra_role))

    with pytest.raises(ProjectConfigError):
        parse_project_config(text)


# ---------------------------------------------------------------------------
# Strict route fields (Section 33)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("role", ["planner", "implementer", "reviewer"])
@pytest.mark.parametrize("missing_field", ["provider", "model", "effort", "billing_mode"])
def test_missing_route_field_rejected(role: str, missing_field: str) -> None:
    fields = _default_fields()
    del fields[missing_field]
    text = _config_text(role_fields={role: fields})

    with pytest.raises(ProjectConfigError):
        parse_project_config(text)


@pytest.mark.parametrize("role", ["planner", "implementer", "reviewer"])
@pytest.mark.parametrize("extra_field", ["executable", "fallback_model", "api_key"])
def test_extra_route_field_rejected(role: str, extra_field: str) -> None:
    fields = _default_fields()
    fields[extra_field] = '"x"'
    text = _config_text(role_fields={role: fields})

    with pytest.raises(ProjectConfigError):
        parse_project_config(text)


# ---------------------------------------------------------------------------
# Schema version validation (Section 34)
# ---------------------------------------------------------------------------


def test_schema_version_one_succeeds() -> None:
    config = parse_project_config(_config_text())

    assert config.schema_version == 1


@pytest.mark.parametrize("raw", ["0", "2", "-1", '"1"', "1.0", "true"])
def test_invalid_schema_version_rejected(raw: str) -> None:
    text = _config_text(schema_version_line=f"schema_version = {raw}\n")

    with pytest.raises(ProjectConfigError):
        parse_project_config(text)


# ---------------------------------------------------------------------------
# Provider value validation (Section 35)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("role", ["planner", "implementer", "reviewer"])
@pytest.mark.parametrize("provider_value", [_CLAUDE, _CODEX])
def test_valid_provider_values_parse_to_agent_provider(role: str, provider_value: str) -> None:
    fields = _default_fields()
    fields["provider"] = f'"{provider_value}"'

    config = parse_project_config(_config_text(role_fields={role: fields}))

    assert getattr(config.routing, role).provider is AgentProvider(provider_value)


@pytest.mark.parametrize("role", ["planner", "implementer", "reviewer"])
@pytest.mark.parametrize("bad_provider", ["anthropic", "openai", "CLAUDE", "Codex", "unknown"])
def test_invalid_provider_value_rejected(role: str, bad_provider: str) -> None:
    fields = _default_fields()
    fields["provider"] = f'"{bad_provider}"'

    with pytest.raises(ProjectConfigError):
        parse_project_config(_config_text(role_fields={role: fields}))


# ---------------------------------------------------------------------------
# Billing mode validation (Section 36)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("role", ["planner", "implementer", "reviewer"])
@pytest.mark.parametrize("billing_value", [_SUBSCRIPTION_ONLY, _API_ALLOWED])
def test_valid_billing_values_parse_to_billing_mode(role: str, billing_value: str) -> None:
    fields = _default_fields()
    fields["billing_mode"] = f'"{billing_value}"'

    config = parse_project_config(_config_text(role_fields={role: fields}))

    assert getattr(config.routing, role).billing_mode is BillingMode(billing_value)


def test_invalid_billing_value_rejected() -> None:
    fields = _default_fields()
    fields["billing_mode"] = '"unknown_mode"'

    with pytest.raises(ProjectConfigError):
        parse_project_config(_config_text(role_fields={"planner": fields}))


# ---------------------------------------------------------------------------
# Model / effort semantics (Section 37)
# ---------------------------------------------------------------------------


def test_model_and_effort_exact_values_preserved() -> None:
    fields = _role_fields(_CLAUDE, "distinctive-model-7-3", "distinctive-effort-7-3")

    config = parse_project_config(_config_text(role_fields={"planner": fields}))

    assert config.routing.planner.model == "distinctive-model-7-3"
    assert config.routing.planner.effort == "distinctive-effort-7-3"


@pytest.mark.parametrize("field", ["model", "effort"])
@pytest.mark.parametrize("bad_value", ['""', '"   "', '"model\\u0000bad"'])
def test_invalid_model_or_effort_value_raises_bounded_project_config_error(
    field: str, bad_value: str
) -> None:
    fields = _default_fields()
    fields[field] = bad_value

    with pytest.raises(ProjectConfigError):
        parse_project_config(_config_text(role_fields={"planner": fields}))


# ---------------------------------------------------------------------------
# TOML primitive type rejection (Section 38)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("field", ["provider", "model", "effort", "billing_mode"])
@pytest.mark.parametrize("raw_literal", ["1", "true", "[]", "{}"])
def test_non_string_primitive_values_rejected(field: str, raw_literal: str) -> None:
    fields = _default_fields()
    fields[field] = raw_literal

    with pytest.raises(ProjectConfigError):
        parse_project_config(_config_text(role_fields={"planner": fields}))


# ---------------------------------------------------------------------------
# Malformed TOML (Section 39)
# ---------------------------------------------------------------------------


def test_malformed_toml_is_bounded_and_privacy_safe() -> None:
    sentinel = "LOCKSTEP_MALFORMED_SENTINEL_7_3"
    text = f"schema_version = 1\n[routing.planner\n{sentinel} = broken\n"

    with pytest.raises(ProjectConfigError) as exc_info:
        parse_project_config(text)

    error = exc_info.value
    assert sentinel not in error.reason
    assert sentinel not in str(error)


def test_project_config_error_reason_is_bounded_with_no_traceback_text() -> None:
    with pytest.raises(ProjectConfigError) as exc_info:
        parse_project_config("not valid toml [[[")

    error = exc_info.value
    assert isinstance(error.reason, str)
    assert len(error.reason) < 200
    assert "Traceback" not in error.reason
    assert 'File "' not in error.reason


# ---------------------------------------------------------------------------
# Unknown credential/runtime fields (Section 40)
# ---------------------------------------------------------------------------

_CREDENTIAL_RUNTIME_FIELD_NAMES: tuple[str, ...] = (
    "api_key",
    "token",
    "claude_config_dir",
    "codex_home",
    "runtime_dir",
    "executable",
)


@pytest.mark.parametrize("field_name", _CREDENTIAL_RUNTIME_FIELD_NAMES)
def test_unknown_top_level_credential_or_runtime_field_rejected(field_name: str) -> None:
    text = _config_text(top_level_extra=f'{field_name} = "x"\n')

    with pytest.raises(ProjectConfigError):
        parse_project_config(text)


@pytest.mark.parametrize("field_name", _CREDENTIAL_RUNTIME_FIELD_NAMES)
def test_unknown_route_credential_or_runtime_field_rejected(field_name: str) -> None:
    fields = _default_fields()
    fields[field_name] = '"x"'

    with pytest.raises(ProjectConfigError):
        parse_project_config(_config_text(role_fields={"planner": fields}))


# ---------------------------------------------------------------------------
# No interpolation (Section 41)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "literal_value",
    ["${LOCKSTEP_SENTINEL}", "$LOCKSTEP_SENTINEL", "~/somewhere"],
)
def test_literal_environment_like_syntax_is_preserved_verbatim(
    literal_value: str, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("LOCKSTEP_SENTINEL", "should-never-appear-7-3")

    fields = _default_fields()
    fields["model"] = f'"{literal_value}"'

    config = parse_project_config(_config_text(role_fields={"planner": fields}))

    assert config.routing.planner.model == literal_value
    assert "should-never-appear-7-3" not in config.routing.planner.model


# ---------------------------------------------------------------------------
# Loader path exactness (Section 42)
# ---------------------------------------------------------------------------


def test_loader_does_not_search_upward(tmp_path: Path) -> None:
    parent = tmp_path / "parent"
    child = parent / "child"
    child.mkdir(parents=True)
    (parent / LOCKSTEP_CONFIG_FILENAME).write_text(_config_text(), encoding="utf-8")

    with pytest.raises(ProjectConfigError):
        load_project_config(child)

    (child / LOCKSTEP_CONFIG_FILENAME).write_text(_config_text(), encoding="utf-8")

    config = load_project_config(child)

    assert isinstance(config, ProjectConfig)


# ---------------------------------------------------------------------------
# Missing / non-file / symlink config (Section 43)
# ---------------------------------------------------------------------------


def test_missing_config_file_rejected(tmp_path: Path) -> None:
    with pytest.raises(ProjectConfigError):
        load_project_config(tmp_path)


def test_config_path_is_directory_rejected(tmp_path: Path) -> None:
    (tmp_path / LOCKSTEP_CONFIG_FILENAME).mkdir()

    with pytest.raises(ProjectConfigError):
        load_project_config(tmp_path)


def test_symlink_config_rejected(tmp_path: Path) -> None:
    real_dir = tmp_path / "real"
    real_dir.mkdir()
    real_config = real_dir / "real-lockstep.toml"
    real_config.write_text(_config_text(), encoding="utf-8")

    project_root = tmp_path / "project"
    project_root.mkdir()
    (project_root / LOCKSTEP_CONFIG_FILENAME).symlink_to(real_config)

    with pytest.raises(ProjectConfigError):
        load_project_config(project_root)


def test_broken_symlink_config_rejected(tmp_path: Path) -> None:
    project_root = tmp_path / "project"
    project_root.mkdir()
    (project_root / LOCKSTEP_CONFIG_FILENAME).symlink_to(tmp_path / "does-not-exist.toml")

    with pytest.raises(ProjectConfigError):
        load_project_config(project_root)


# ---------------------------------------------------------------------------
# UTF-8 (Section 44)
# ---------------------------------------------------------------------------


def test_valid_non_ascii_model_round_trips_through_loader(tmp_path: Path) -> None:
    fields = _default_fields()
    fields["model"] = '"モデル-7-3-é"'
    (tmp_path / LOCKSTEP_CONFIG_FILENAME).write_text(
        _config_text(role_fields={"planner": fields}), encoding="utf-8"
    )

    config = load_project_config(tmp_path)

    assert config.routing.planner.model == "モデル-7-3-é"


def test_invalid_utf8_bytes_rejected(tmp_path: Path) -> None:
    config_path = tmp_path / LOCKSTEP_CONFIG_FILENAME
    config_path.write_bytes(_config_text().encode("utf-8") + b"\xff\xfe")

    with pytest.raises(ProjectConfigError):
        load_project_config(tmp_path)


# ---------------------------------------------------------------------------
# Deterministic rendering (Section 45)
# ---------------------------------------------------------------------------


def test_render_is_deterministic_across_calls() -> None:
    config = _build_project_config()

    first = render_project_config(config)
    second = render_project_config(config)

    assert first == second


def test_render_uses_canonical_section_and_field_order() -> None:
    text = render_project_config(_build_project_config())

    assert text.index("schema_version") < text.index("[routing.planner]")
    assert text.index("[routing.planner]") < text.index("[routing.implementer]")
    assert text.index("[routing.implementer]") < text.index("[routing.reviewer]")

    for section in ("[routing.planner]", "[routing.implementer]", "[routing.reviewer]"):
        section_text = text[text.index(section) :]
        provider_index = section_text.index("provider")
        model_index = section_text.index("model")
        effort_index = section_text.index("effort")
        billing_index = section_text.index("billing_mode")
        assert provider_index < model_index < effort_index < billing_index


def test_render_ends_with_exactly_one_newline() -> None:
    text = render_project_config(_build_project_config())

    assert text.endswith("\n")
    assert not text.endswith("\n\n")


def test_render_contains_no_host_or_environment_derived_text(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("LOCKSTEP_RENDER_SENTINEL", "should-never-appear-in-render")

    text = render_project_config(_build_project_config())

    assert "should-never-appear-in-render" not in text
    assert str(Path.home()) not in text


# ---------------------------------------------------------------------------
# Render/parse roundtrip (Section 46)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("planner_provider", "implementer_provider", "reviewer_provider"),
    [
        (AgentProvider(p), AgentProvider(i), AgentProvider(r))
        for p, i, r in _ALL_PROVIDER_VALUE_ASSIGNMENTS
    ],
)
def test_render_parse_roundtrip_all_eight_combinations(
    planner_provider: AgentProvider,
    implementer_provider: AgentProvider,
    reviewer_provider: AgentProvider,
) -> None:
    config = _build_project_config(
        planner_provider=planner_provider,
        implementer_provider=implementer_provider,
        reviewer_provider=reviewer_provider,
    )

    roundtripped = parse_project_config(render_project_config(config))

    assert roundtripped == config


def test_render_parse_roundtrip_with_quote_backslash_nonascii_and_spaces() -> None:
    tricky = 'model "with quotes" \\ and spaces and non-ascii café 7-3'
    config = _build_project_config(planner_model=tricky)

    roundtripped = parse_project_config(render_project_config(config))

    assert roundtripped == config
    assert roundtripped.routing.planner.model == tricky


# ---------------------------------------------------------------------------
# Unsupported render schema version (Section 47)
# ---------------------------------------------------------------------------


def test_render_refuses_unsupported_schema_version() -> None:
    valid = _build_project_config()
    unsupported = ProjectConfig(schema_version=2, routing=valid.routing)

    with pytest.raises(ProjectConfigError):
        render_project_config(unsupported)


# ---------------------------------------------------------------------------
# Purity / dependency audit (Section 48)
# ---------------------------------------------------------------------------

_FORBIDDEN_CONFIG_REFERENCES: tuple[str, ...] = (
    "ClaudeAdapter",
    "CodexAdapter",
    "ClaudeCliStatus",
    "CodexCliStatus",
    "resolve_agent_adapters",
    "probe_claude_cli",
    "probe_codex_cli",
    "invoke_agent",
    "run_process",
    "subprocess",
    "Supervisor",
    "persistence",
    "verification",
    "reporting",
)


def test_config_module_has_no_forbidden_dependencies() -> None:
    import lockstep.config as config_module

    source = inspect.getsource(config_module)
    tree = ast.parse(source)

    imported_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import | ast.ImportFrom):
            for alias in node.names:
                imported_names.add(alias.asname or alias.name)

    for forbidden in _FORBIDDEN_CONFIG_REFERENCES:
        assert forbidden not in imported_names
        assert forbidden not in source


def test_parse_and_render_never_touch_environment_or_home(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    def _fail(*args: object, **kwargs: object) -> None:
        raise AssertionError("must not be called")

    monkeypatch.setattr(os, "getenv", _fail)
    monkeypatch.setattr(Path, "home", _fail)

    config = parse_project_config(_config_text())
    text = render_project_config(config)

    assert isinstance(config, ProjectConfig)
    assert isinstance(text, str)


def test_load_project_config_does_not_invoke_subprocess(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    (tmp_path / LOCKSTEP_CONFIG_FILENAME).write_text(_config_text(), encoding="utf-8")

    def _fail(*args: object, **kwargs: object) -> None:
        raise AssertionError("loader must not launch a process")

    monkeypatch.setattr("lockstep.process.run_process", _fail)

    config = load_project_config(tmp_path)

    assert isinstance(config, ProjectConfig)


def test_project_config_has_exactly_schema_version_and_routing_fields() -> None:
    field_names = {field.name for field in dataclasses.fields(ProjectConfig)}

    assert field_names == {"schema_version", "routing"}
