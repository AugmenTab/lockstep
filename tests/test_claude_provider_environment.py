"""Phase 12.6-R1: the Claude provider environment projection.

Claude processes receive ``HOME`` and ``PATH`` (required) and the operator's
``USER`` when the operator environment supplies it, and nothing else from the
ambient environment. The diagnostic probe and every role's inference command
use the same projection; Codex is unaffected. Every value below is fake.

The environment *supplied by Lockstep* is captured at the ``run_process``
boundary, so platform-created child variables (macOS ``LC_CTYPE`` /
``__CF_USER_TEXT_ENCODING``) never enter these assertions.
"""

from __future__ import annotations

import json
import stat
import sys
import textwrap
from pathlib import Path

import pytest

import lockstep.agents.claude as claude_module
import lockstep.agents.codex as codex_module
import lockstep.agents.invocation as invocation_module
from lockstep.agents import (
    AgentInvocationRequest,
    AgentProviderStatuses,
    ClaudeAdapter,
    ClaudeAdapterError,
    ClaudeCliStatus,
    CodexAdapter,
    ProviderRuntimeOverrides,
    invoke_agent,
    probe_claude_cli,
    resolve_agent_adapters,
)
from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.config import LOCKSTEP_CONFIG_FILENAME, ProjectConfig, render_project_config
from lockstep.domain import AgentRole, BillingMode
from lockstep.process import build_process_environment
from lockstep.runtime import AgentRuntime, prepare_agent_runtime

_CLAUDE = AgentProvider.CLAUDE
_CODEX = AgentProvider.CODEX

_ROLES: tuple[AgentRole, ...] = (AgentRole.PLANNER, AgentRole.IMPLEMENTER, AgentRole.REVIEWER)

_FAKE_USER = "r1-fake-operator"

# Ambient names that must never reach a Claude process. USER is the only
# newly inherited name; LOGNAME/TMPDIR/SHELL are explicitly not authorized.
_AMBIENT_SENTINELS: dict[str, str] = {
    "SECRET_SENTINEL": "secret-sentinel-must-not-leak",
    "SSH_AUTH_SOCK": "/tmp/r1-fake-agent.sock",
    "ANTHROPIC_API_KEY": "sk-ant-r1-fake-must-not-leak",
    "LOGNAME": "r1-fake-logname",
    "TMPDIR": "/tmp/r1-fake-tmpdir",
    "SHELL": "/bin/r1-fake-shell",
    "LANG": "C.UTF-8",
    "LC_ALL": "C.UTF-8",
    "XDG_CONFIG_HOME": "/tmp/r1-fake-xdg",
}

# Metered/API credential names: present in the parent, never inherited.
_API_CREDENTIALS: dict[str, str] = {
    "ANTHROPIC_API_KEY": "sk-ant-r1-fake",
    "ANTHROPIC_AUTH_TOKEN": "r1-fake-auth-token",
    "ANTHROPIC_BASE_URL": "https://r1-fake.invalid",
    "CLAUDE_CODE_OAUTH_TOKEN": "r1-fake-oauth",
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "CLAUDE_CODE_USE_VERTEX": "1",
    "OPENAI_API_KEY": "sk-r1-fake",
    "CODEX_API_KEY": "sk-r1-fake",
    "AWS_ACCESS_KEY_ID": "AKIAR1FAKE",
    "AWS_SECRET_ACCESS_KEY": "r1-fake-aws-secret",
    "AWS_SESSION_TOKEN": "r1-fake-aws-session",
    "GOOGLE_APPLICATION_CREDENTIALS": "/tmp/r1-fake-gcp.json",
    "GOOGLE_API_KEY": "r1-fake-google",
}

_CLAUDE_AUTH_OK = json.dumps(
    {
        "loggedIn": True,
        "authMethod": "claude.ai",
        "apiProvider": "firstParty",
        "subscriptionType": "max",
    }
)

_CLAUDE_HELP_TEXT = (
    "Usage: claude [OPTIONS] [PROMPT]\n"
    "  -p, --print\n  --model\n  --effort\n  --output-format\n  --json-schema\n"
    "  --permission-mode\n  --permission-prompts\n  --no-session-persistence\n"
    "  --restricted\n  --safe-mode\n  --tools\n  --disallowedTools\n  --allowedTools\n"
)

_CODEX_EXEC_HELP_TEXT = (
    "Usage: codex exec [OPTIONS]\n"
    "  --ephemeral\n  --ignore-user-config\n  --ignore-rules\n  --sandbox\n"
    "  --color\n  --output-schema\n"
)

_CODEX_DOCTOR_OK = json.dumps(
    {
        "schemaVersion": 1,
        "overallStatus": "ok",
        "checks": {
            "auth.credentials": {
                "status": "ok",
                "details": [
                    {"name": "stored auth mode", "value": "chatgpt"},
                    {"name": "stored ChatGPT tokens", "value": "true"},
                    {"name": "stored API key", "value": "false"},
                ],
            },
        },
    }
)


# ---------------------------------------------------------------------------
# Fakes and capture
# ---------------------------------------------------------------------------


def _write_executable(path: Path, body: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!{sys.executable}\n" + textwrap.dedent(body), encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _write_fake_claude(bin_dir: Path) -> Path:
    executable = bin_dir / "claude"
    _write_executable(
        executable,
        f"""\
        import sys
        args = sys.argv[1:]
        if args == ["--version"]:
            sys.stdout.write("2.1.259 (Claude Code)\\n")
            raise SystemExit(0)
        if args == ["--help"]:
            sys.stdout.write({_CLAUDE_HELP_TEXT!r})
            raise SystemExit(0)
        if args == ["auth", "status"]:
            sys.stdout.write({_CLAUDE_AUTH_OK!r})
            raise SystemExit(0)
        if args and args[0] == "-p":
            sys.stdin.read()
            sys.stdout.write("ok")
            raise SystemExit(0)
        raise SystemExit(99)
        """,
    )
    return executable


def _write_fake_codex(bin_dir: Path) -> Path:
    executable = bin_dir / "codex"
    _write_executable(
        executable,
        f"""\
        import sys
        args = sys.argv[1:]
        if args == ["--version"]:
            sys.stdout.write("codex-cli r1-fake\\n")
            raise SystemExit(0)
        if args == ["exec", "--help"]:
            sys.stdout.write({_CODEX_EXEC_HELP_TEXT!r})
            raise SystemExit(0)
        if args == ["doctor", "--json"]:
            sys.stdout.write({_CODEX_DOCTOR_OK!r})
            raise SystemExit(0)
        if args and args[0] == "exec":
            sys.stdin.read()
            sys.stdout.write("ok")
            raise SystemExit(0)
        raise SystemExit(99)
        """,
    )
    return executable


_PROBE_ARGV: frozenset[tuple[str, ...]] = frozenset(
    {
        ("--version",),
        ("--help",),
        ("auth", "status"),
        ("exec", "--help"),
        ("doctor", "--json"),
    }
)


class _SuppliedEnvironments:
    """Exact child environments Lockstep hands to ``run_process``, per launch."""

    def __init__(self) -> None:
        self.launches: list[tuple[str, tuple[str, ...], dict[str, str]]] = []

    def install(self, monkeypatch: pytest.MonkeyPatch) -> None:
        for module in (claude_module, codex_module, invocation_module):
            real = module.run_process

            def recording(
                argv: tuple[str, ...],
                *,
                _real: object = real,
                **kwargs: object,
            ) -> object:
                env = kwargs["env"]
                assert isinstance(env, dict)
                self.launches.append((Path(argv[0]).name, tuple(argv[1:]), dict(env)))
                return _real(argv, **kwargs)  # type: ignore[operator]

            monkeypatch.setattr(module, "run_process", recording)

    def probes(self, exe: str) -> list[dict[str, str]]:
        return [env for name, args, env in self.launches if name == exe and args in _PROBE_ARGV]

    def inferences(self, exe: str) -> list[dict[str, str]]:
        return [env for name, args, env in self.launches if name == exe and args not in _PROBE_ARGV]


def _route(provider: AgentProvider, model: str) -> AgentRoleRoute:
    return AgentRoleRoute(
        provider=provider, model=model, effort="low", billing_mode=BillingMode.SUBSCRIPTION_ONLY
    )


def _policy(
    planner: AgentProvider = _CLAUDE,
    implementer: AgentProvider = _CLAUDE,
    reviewer: AgentProvider = _CLAUDE,
) -> AgentRoutingPolicy:
    return AgentRoutingPolicy(
        planner=_route(planner, "planner-model"),
        implementer=_route(implementer, "implementer-model"),
        reviewer=_route(reviewer, "reviewer-model"),
    )


def _prepare(
    tmp_path: Path,
    operator_env: dict[str, str],
    *,
    policy: AgentRoutingPolicy | None = None,
    overrides: ProviderRuntimeOverrides | None = None,
) -> AgentRuntime:
    project_root = tmp_path / "project"
    project_root.mkdir()
    config = ProjectConfig(schema_version=1, routing=policy if policy is not None else _policy())
    (project_root / LOCKSTEP_CONFIG_FILENAME).write_text(
        render_project_config(config), encoding="utf-8"
    )
    return prepare_agent_runtime(
        project_root,
        tmp_path / "runtime",
        operator_parent_env=operator_env,
        provider_overrides=overrides,
    )


def _operator_env(tmp_path: Path, **extra: str) -> dict[str, str]:
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)
    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    return {"HOME": str(home), "PATH": str(bin_dir), **extra}


def _invoke(runtime: AgentRuntime, role: AgentRole, tmp_path: Path) -> None:
    adapter = {
        AgentRole.PLANNER: runtime.adapters.planner,
        AgentRole.IMPLEMENTER: runtime.adapters.implementer,
        AgentRole.REVIEWER: runtime.adapters.reviewer,
    }[role]
    invoke_agent(
        adapter,
        AgentInvocationRequest(
            role=role,
            billing_mode=BillingMode.SUBSCRIPTION_ONLY,
            prompt="r1-prompt",
            cwd=tmp_path,
            timeout_seconds=30,
            termination_grace_seconds=0.1,
        ),
        parent_env=runtime.transaction_parent_env,
    )


def _healthy_status() -> ClaudeCliStatus:
    return ClaudeCliStatus(
        executable="/fake/claude",
        version="2.1.283",
        logged_in=True,
        auth_method="claude.ai",
        api_provider="firstParty",
        subscription_type="pro",
        supports_print=True,
        supports_model=True,
        supports_effort=True,
        supports_output_format=True,
        supports_json_schema=True,
        supports_permission_mode=True,
        supports_permission_prompts=True,
        supports_no_session_persistence=True,
        supports_restricted=True,
        supports_bare=True,
        supports_tools=True,
        supports_disallowed_tools=True,
        supports_safe_mode=True,
        supports_allowed_tools=True,
    )


# ---------------------------------------------------------------------------
# A — USER propagation
# ---------------------------------------------------------------------------


def test_a_probe_environment_carries_parent_user(tmp_path: Path) -> None:
    operator_env = _operator_env(tmp_path, USER=_FAKE_USER)
    captured = _SuppliedEnvironments()
    with pytest.MonkeyPatch.context() as monkeypatch:
        captured.install(monkeypatch)
        probe_claude_cli(
            claude_executable=str(tmp_path / "bin" / "claude"),
            parent_env=operator_env,
            cwd=tmp_path,
        )

    probes = captured.probes("claude")
    assert len(probes) == 3
    for env in probes:
        assert env == {
            "HOME": operator_env["HOME"],
            "PATH": operator_env["PATH"],
            "USER": _FAKE_USER,
        }


@pytest.mark.parametrize("role", _ROLES)
def test_a_runtime_claude_inference_carries_parent_user(
    tmp_path: Path, role: AgentRole, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime = _prepare(tmp_path, _operator_env(tmp_path, USER=_FAKE_USER))
    captured = _SuppliedEnvironments()
    captured.install(monkeypatch)

    _invoke(runtime, role, tmp_path)

    (env,) = captured.inferences("claude")
    assert env["USER"] == _FAKE_USER
    assert env["HOME"] == str(tmp_path / "home")
    assert env["PATH"] == str(tmp_path / "bin")


def test_a_inherited_environment_helper_selects_user() -> None:
    parent = {"HOME": "/h", "PATH": "/p", "USER": _FAKE_USER, **_AMBIENT_SENTINELS}

    assert dict(claude_module.claude_inherited_environment(parent)) == {"USER": _FAKE_USER}


# ---------------------------------------------------------------------------
# B — ambient isolation
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("role", _ROLES)
def test_b_ambient_sentinels_reach_neither_probe_nor_inference(
    tmp_path: Path, role: AgentRole, monkeypatch: pytest.MonkeyPatch
) -> None:
    operator_env = _operator_env(tmp_path, USER=_FAKE_USER, **_AMBIENT_SENTINELS)
    captured = _SuppliedEnvironments()
    captured.install(monkeypatch)

    runtime = _prepare(tmp_path, operator_env)
    _invoke(runtime, role, tmp_path)

    launches = [*captured.probes("claude"), *captured.inferences("claude")]
    assert len(launches) == 4
    for env in launches:
        assert set(env) == {"HOME", "PATH", "USER"}
        for name in _AMBIENT_SENTINELS:
            assert name not in env


# ---------------------------------------------------------------------------
# C — USER absent
# ---------------------------------------------------------------------------


def test_c_user_absent_is_not_invented(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    operator_env = _operator_env(tmp_path, LOGNAME="r1-fake-logname")
    captured = _SuppliedEnvironments()
    captured.install(monkeypatch)

    runtime = _prepare(tmp_path, operator_env)
    for role in _ROLES:
        _invoke(runtime, role, tmp_path)

    launches = [*captured.probes("claude"), *captured.inferences("claude")]
    assert len(launches) == 6
    for env in launches:
        assert env == {"HOME": operator_env["HOME"], "PATH": operator_env["PATH"]}


def test_c_inherited_environment_helper_is_empty_without_user() -> None:
    assert dict(claude_module.claude_inherited_environment({"HOME": "/h", "PATH": "/p"})) == {}


# ---------------------------------------------------------------------------
# D — diagnostic / adapter parity
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("with_config_dir", [False, True])
@pytest.mark.parametrize("with_user", [False, True])
def test_d_probe_and_inference_environments_are_identical(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    with_user: bool,
    with_config_dir: bool,
) -> None:
    extra = {**_AMBIENT_SENTINELS, **_API_CREDENTIALS}
    if with_user:
        extra["USER"] = _FAKE_USER
    operator_env = _operator_env(tmp_path, **extra)
    overrides = None
    if with_config_dir:
        config_dir = tmp_path / "claude-config"
        config_dir.mkdir()
        overrides = ProviderRuntimeOverrides(claude_config_dir=config_dir)
    captured = _SuppliedEnvironments()
    captured.install(monkeypatch)

    runtime = _prepare(tmp_path, operator_env, overrides=overrides)
    for role in _ROLES:
        _invoke(runtime, role, tmp_path)

    probes = captured.probes("claude")
    inferences = captured.inferences("claude")
    assert len(probes) == 3
    assert len(inferences) == 3
    reference = probes[0]
    for env in (*probes, *inferences):
        assert env == reference
    assert ("USER" in reference) is with_user
    assert ("CLAUDE_CONFIG_DIR" in reference) is with_config_dir


# ---------------------------------------------------------------------------
# E — all roles
# ---------------------------------------------------------------------------


def test_e_every_claude_role_receives_the_same_policy(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime = _prepare(tmp_path, _operator_env(tmp_path, USER=_FAKE_USER, **_AMBIENT_SENTINELS))
    adapters = (runtime.adapters.planner, runtime.adapters.implementer, runtime.adapters.reviewer)
    for adapter in adapters:
        assert isinstance(adapter, ClaudeAdapter)
        assert dict(adapter.inherited_env) == {"USER": _FAKE_USER}

    captured = _SuppliedEnvironments()
    captured.install(monkeypatch)
    for role in _ROLES:
        _invoke(runtime, role, tmp_path)

    planner, implementer, reviewer = captured.inferences("claude")
    assert planner == implementer == reviewer
    assert set(planner) == {"HOME", "PATH", "USER"}


def test_e_resolution_binds_status_environment_into_every_claude_role(tmp_path: Path) -> None:
    statuses = AgentProviderStatuses(
        claude=_healthy_status(), claude_inherited_env={"USER": _FAKE_USER}
    )

    resolved = resolve_agent_adapters(_policy(), statuses, tmp_path)

    for adapter in (resolved.planner, resolved.implementer, resolved.reviewer):
        assert isinstance(adapter, ClaudeAdapter)
        assert dict(adapter.inherited_env) == {"USER": _FAKE_USER}


# ---------------------------------------------------------------------------
# F — Codex unchanged
# ---------------------------------------------------------------------------


def test_f_codex_environment_is_unchanged(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    operator_env = _operator_env(tmp_path, USER=_FAKE_USER, **_AMBIENT_SENTINELS)
    captured = _SuppliedEnvironments()
    captured.install(monkeypatch)

    runtime = _prepare(tmp_path, operator_env, policy=_policy(_CLAUDE, _CODEX, _CODEX))
    assert isinstance(runtime.adapters.implementer, CodexAdapter)
    assert isinstance(runtime.adapters.reviewer, CodexAdapter)
    _invoke(runtime, AgentRole.IMPLEMENTER, tmp_path)

    # Accepted Codex probe policy: the process-layer safe baseline over the
    # operator environment, HOME/PATH required, no explicit additions.
    accepted_probe_env = build_process_environment(
        operator_env, inherit_names=(), required_names=("HOME", "PATH")
    )
    codex_probes = captured.probes("codex")
    assert len(codex_probes) == 3
    for env in codex_probes:
        assert env == accepted_probe_env

    # Accepted Codex inference policy: exactly the projected HOME/PATH parent.
    (codex_inference,) = captured.inferences("codex")
    assert codex_inference == {"HOME": operator_env["HOME"], "PATH": operator_env["PATH"]}
    assert "USER" not in codex_inference


def test_f_codex_adapter_gains_no_user_through_resolution(tmp_path: Path) -> None:
    runtime = _prepare(
        tmp_path,
        _operator_env(tmp_path, USER=_FAKE_USER),
        policy=_policy(_CODEX, _CODEX, _CODEX),
    )

    assert dict(runtime.transaction_parent_env) == {
        "HOME": str(tmp_path / "home"),
        "PATH": str(tmp_path / "bin"),
    }
    for adapter in (runtime.adapters.planner, runtime.adapters.implementer):
        assert isinstance(adapter, CodexAdapter)
        assert not hasattr(adapter, "inherited_env")


# ---------------------------------------------------------------------------
# G — no ambient API credentials
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("role", _ROLES)
def test_g_api_credentials_are_never_inherited(
    tmp_path: Path, role: AgentRole, monkeypatch: pytest.MonkeyPatch
) -> None:
    operator_env = _operator_env(tmp_path, USER=_FAKE_USER, **_API_CREDENTIALS)
    captured = _SuppliedEnvironments()
    captured.install(monkeypatch)

    runtime = _prepare(tmp_path, operator_env)
    _invoke(runtime, role, tmp_path)

    launches = [*captured.probes("claude"), *captured.inferences("claude")]
    assert len(launches) == 4
    for env in launches:
        for name in _API_CREDENTIALS:
            assert name not in env
        for value in _API_CREDENTIALS.values():
            assert value not in env.values()


# ---------------------------------------------------------------------------
# Security boundary of the bound environment
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "name",
    ["LOGNAME", "TMPDIR", "SHELL", "SSH_AUTH_SOCK", "ANTHROPIC_API_KEY", "HOME", "PATH"],
)
def test_adapter_rejects_unapproved_inherited_names(name: str) -> None:
    with pytest.raises(ClaudeAdapterError):
        ClaudeAdapter(
            role=AgentRole.IMPLEMENTER,
            status=_healthy_status(),
            model="m",
            effort="low",
            inherited_env={name: "r1-fake"},
        )


def test_bound_user_value_stays_out_of_reprs(tmp_path: Path) -> None:
    sentinel = "r1-user-repr-sentinel"
    runtime = _prepare(tmp_path, _operator_env(tmp_path, USER=sentinel))

    assert sentinel not in repr(runtime)
    assert sentinel not in repr(runtime.diagnostics)
    assert sentinel not in repr(runtime.adapters)
    assert sentinel not in repr(runtime.adapters.implementer)
