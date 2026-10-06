"""Planner-authored specification of Sub-phase 7.5 configuration-driven runtime composition."""

from __future__ import annotations

import ast
import inspect
import json
import os
import stat
import subprocess
import sys
import textwrap
from dataclasses import FrozenInstanceError, fields
from pathlib import Path

import pytest

import lockstep.runtime as lockstep_runtime
from lockstep.agents import (
    AgentAdapterResolutionError,
    ClaudeAdapter,
    ClaudePreflightError,
    CodexAdapter,
    CodexPreflightError,
    ProviderDiagnosticsError,
    ProviderRuntimeOverrides,
)
from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.config import (
    LOCKSTEP_CONFIG_FILENAME,
    ProjectConfig,
    ProjectConfigError,
    load_project_config,
    render_project_config,
)
from lockstep.domain import AgentRole, BillingMode, PhaseId, ProjectId, RunId, SubphaseId
from lockstep.git import inspect_repository
from lockstep.persistence import ExecutionEvent, read_events, read_state, replay_events
from lockstep.process import EnvironmentPolicyError
from lockstep.runtime import (
    AgentRuntime,
    AgentRuntimeError,
    prepare_agent_runtime,
    run_single_subphase_with_runtime,
)
from lockstep.state import WorkflowState
from lockstep.supervisor import SingleSubphaseTransactionRequest

_CLAUDE = AgentProvider.CLAUDE
_CODEX = AgentProvider.CODEX

_ALL_EIGHT_ASSIGNMENTS: tuple[tuple[AgentProvider, AgentProvider, AgentProvider], ...] = (
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
# Fake provider executables — satisfy production preflight AND production
# inference argv/stdin contracts so real ClaudeAdapter/CodexAdapter commands
# can be executed end to end without a real subscription account.
# ---------------------------------------------------------------------------

_CLAUDE_AUTH_OK = json.dumps(
    {
        "loggedIn": True,
        "authMethod": "claude.ai",
        "apiProvider": "firstParty",
        "subscriptionType": "max",
    }
)

_CLAUDE_AUTH_NOT_LOGGED_IN = json.dumps(
    {
        "loggedIn": False,
        "authMethod": None,
        "apiProvider": None,
        "subscriptionType": None,
    }
)

_CLAUDE_HELP_TEXT = (
    "Usage: claude [OPTIONS] [PROMPT]\n"
    "\n"
    "Options:\n"
    "  -p, --print                  Print mode\n"
    "  --model <model>              Model to use\n"
    "  --effort <effort>            Reasoning effort\n"
    "  --output-format <format>     Output format\n"
    "  --json-schema <schema>       Inline JSON schema for output\n"
    "  --permission-mode <mode>     Permission mode\n"
    "  --permission-prompts <mode>  Permission prompts\n"
    "  --no-session-persistence     Disable session persistence\n"
    "  --restricted                 Restricted mode\n"
    "  --safe-mode                  Safe mode\n"
    "  --tools <tools>              Tool list\n"
    "  --disallowedTools <tools>    Disallowed tools\n"
    "  --allowedTools <tools>       Allowed tools\n"
)

_CODEX_EXEC_HELP_TEXT = (
    "Usage: codex exec [OPTIONS]\n"
    "\n"
    "Options:\n"
    "  --ephemeral              option description\n"
    "  --ignore-user-config     option description\n"
    "  --ignore-rules           option description\n"
    "  --sandbox <mode>         option description\n"
    "  --color <mode>           option description\n"
    "  --output-schema <path>   option description\n"
    "  -c, --config <key=value> option description\n"
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

_CODEX_DOCTOR_UNHEALTHY = json.dumps(
    {
        "schemaVersion": 1,
        "overallStatus": "ok",
        "checks": {"auth.credentials": {"status": "error", "details": []}},
    }
)


def _write_fake_claude(
    directory: Path,
    *,
    version_stdout: str = "2.1.259 (Claude Code)\n",
    help_text: str = _CLAUDE_HELP_TEXT,
    auth_stdout: str = _CLAUDE_AUTH_OK,
    auth_returncode: int = 0,
) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    executable = directory / "claude"
    config_path = directory / "claude-config.json"
    config_path.write_text(
        json.dumps(
            {
                "version_stdout": version_stdout,
                "help_text": help_text,
                "auth_stdout": auth_stdout,
                "auth_returncode": auth_returncode,
            }
        ),
        encoding="utf-8",
    )

    script = textwrap.dedent(
        f"""\
        #!{sys.executable}
        import json
        import os
        import sys
        from pathlib import Path

        base = Path(__file__).resolve().parent
        config = json.loads((base / "claude-config.json").read_text(encoding="utf-8"))
        args = sys.argv[1:]

        with (base / "invocations.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(
                json.dumps({{"exe": "claude", "argv": args, "env": dict(os.environ)}}) + "\\n"
            )

        if args == ["--version"]:
            sys.stdout.write(config["version_stdout"])
            raise SystemExit(0)
        if args == ["--help"]:
            sys.stdout.write(config["help_text"])
            raise SystemExit(0)
        if args == ["auth", "status"]:
            sys.stdout.write(config["auth_stdout"])
            raise SystemExit(int(config["auth_returncode"]))
        if args and args[0] == "-p":
            payload = json.loads(sys.stdin.read())
            action = payload["action"]
            if action == "write_files":
                for rel_path, content in payload["files"].items():
                    target = Path(rel_path)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text(content)
            elif action == "emit_stdout":
                sys.stdout.write(payload["stdout"])
            raise SystemExit(0)

        sys.stderr.write("fake claude: unauthorized argv " + json.dumps(args) + "\\n")
        raise SystemExit(99)
        """
    )
    executable.write_text(script, encoding="utf-8")
    mode = executable.stat().st_mode
    executable.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _write_fake_codex(
    directory: Path,
    *,
    version: str = "codex-cli test-version",
    exec_help_text: str = _CODEX_EXEC_HELP_TEXT,
    doctor_stdout: str = _CODEX_DOCTOR_OK,
    doctor_returncode: int = 0,
) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    executable = directory / "codex"
    config_path = directory / "codex-config.json"
    config_path.write_text(
        json.dumps(
            {
                "version": version,
                "exec_help_text": exec_help_text,
                "doctor_stdout": doctor_stdout,
                "doctor_returncode": doctor_returncode,
            }
        ),
        encoding="utf-8",
    )

    script = textwrap.dedent(
        f"""\
        #!{sys.executable}
        import json
        import os
        import sys
        from pathlib import Path

        base = Path(__file__).resolve().parent
        config = json.loads((base / "codex-config.json").read_text(encoding="utf-8"))
        args = sys.argv[1:]

        with (base / "invocations.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(
                json.dumps({{"exe": "codex", "argv": args, "env": dict(os.environ)}}) + "\\n"
            )

        if args == ["--version"]:
            sys.stdout.write(config["version"] + "\\n")
            raise SystemExit(0)
        if args == ["exec", "--help"]:
            sys.stdout.write(config["exec_help_text"])
            raise SystemExit(0)
        if args == ["doctor", "--json"]:
            sys.stdout.write(config["doctor_stdout"])
            raise SystemExit(int(config["doctor_returncode"]))
        if args and args[0] == "exec":
            payload, _ = json.JSONDecoder().raw_decode(sys.stdin.read().lstrip())
            action = payload["action"]
            if action == "write_files":
                for rel_path, content in payload["files"].items():
                    target = Path(rel_path)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    target.write_text(content)
            elif action == "emit_stdout":
                sys.stdout.write(payload["stdout"])
            raise SystemExit(0)

        sys.stderr.write("fake codex: unauthorized argv " + json.dumps(args) + "\\n")
        raise SystemExit(99)
        """
    )
    executable.write_text(script, encoding="utf-8")
    mode = executable.stat().st_mode
    executable.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _read_invocations(bin_dir: Path) -> list[dict[str, object]]:
    log_path = bin_dir / "invocations.jsonl"
    if not log_path.exists():
        return []
    return [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines() if line]


def _write_files_prompt(files: dict[str, str]) -> str:
    return json.dumps({"action": "write_files", "files": files})


def _emit_stdout_prompt(payload: dict[str, object]) -> str:
    return json.dumps({"action": "emit_stdout", "stdout": json.dumps(payload)})


# ---------------------------------------------------------------------------
# Routing / project-config fixtures
# ---------------------------------------------------------------------------


def _route(
    provider: AgentProvider,
    model: str = "model",
    effort: str = "low",
    *,
    billing_mode: BillingMode = BillingMode.SUBSCRIPTION_ONLY,
) -> AgentRoleRoute:
    return AgentRoleRoute(provider=provider, model=model, effort=effort, billing_mode=billing_mode)


def _policy(
    planner: AgentProvider = _CLAUDE,
    implementer: AgentProvider = _CLAUDE,
    reviewer: AgentProvider = _CLAUDE,
) -> AgentRoutingPolicy:
    return AgentRoutingPolicy(
        planner=_route(planner, "planner-model", "planner-effort"),
        implementer=_route(implementer, "implementer-model", "implementer-effort"),
        reviewer=_route(reviewer, "reviewer-model", "reviewer-effort"),
    )


def _write_project(
    tmp_path: Path,
    *,
    name: str = "project",
    planner: AgentProvider = _CLAUDE,
    implementer: AgentProvider = _CLAUDE,
    reviewer: AgentProvider = _CLAUDE,
) -> Path:
    root = tmp_path / name
    root.mkdir(parents=True, exist_ok=True)
    config = ProjectConfig(schema_version=1, routing=_policy(planner, implementer, reviewer))
    (root / LOCKSTEP_CONFIG_FILENAME).write_text(render_project_config(config), encoding="utf-8")
    return root


def _operator_env(*, path: str, home: Path | None = None) -> dict[str, str]:
    home_path = home if home is not None else Path(os.environ.get("HOME", "/tmp"))
    return {"HOME": str(home_path), "PATH": path}


def _prepared_runtime(
    tmp_path: Path,
    *,
    name: str = "prepared",
    planner: AgentProvider = _CLAUDE,
    implementer: AgentProvider = _CLAUDE,
    reviewer: AgentProvider = _CLAUDE,
) -> AgentRuntime:
    project_root = _write_project(
        tmp_path,
        name=f"{name}-project",
        planner=planner,
        implementer=implementer,
        reviewer=reviewer,
    )
    bin_dir = tmp_path / f"{name}-bin"
    _write_fake_claude(bin_dir)
    if _CODEX in (planner, implementer, reviewer):
        _write_fake_codex(bin_dir)
    return prepare_agent_runtime(
        project_root,
        tmp_path / f"{name}-runtime",
        operator_parent_env=_operator_env(path=str(bin_dir)),
    )


def _fail_if_called(*_args: object, **_kwargs: object) -> None:
    raise AssertionError("run_single_subphase_transaction must not be called")


def _minimal_request(
    *,
    source_path: Path,
    worktree_path: Path,
    runtime_dir: Path,
    billing_mode: BillingMode = BillingMode.SUBSCRIPTION_ONLY,
) -> SingleSubphaseTransactionRequest:
    return SingleSubphaseTransactionRequest(
        project_id=ProjectId.model_validate("lockstep"),
        run_id=RunId.model_validate("20260927-001"),
        phase_id=PhaseId.model_validate("07"),
        subphase_id=SubphaseId.model_validate("05"),
        source_path=source_path,
        worktree_path=worktree_path,
        runtime_dir=runtime_dir,
        branch="lockstep/run/run-07-05",
        billing_mode=billing_mode,
        planner_prompt="unused",
        implementer_prompt="unused",
        reviewer_prompt="unused",
        test_paths=("tests/test_feature.py",),
        implementation_paths=("feature.py",),
        planner_quality_argv=(sys.executable, "-c", "pass"),
        baseline_argv=(sys.executable, "-c", "import sys; sys.exit(1)"),
        verification_argv=(sys.executable, "-c", "pass"),
        test_commit_message="test: freeze",
        implementation_commit_message="feat: implement",
    )


# ---------------------------------------------------------------------------
# Section 32 — API shape
# ---------------------------------------------------------------------------


def test_agent_runtime_is_frozen_and_slotted(tmp_path: Path) -> None:
    runtime = _prepared_runtime(tmp_path)

    with pytest.raises(FrozenInstanceError):
        runtime.project_root = Path("/hijack")  # type: ignore[misc]
    assert not hasattr(runtime, "__dict__")

    field_names = {f.name for f in fields(runtime)}
    assert field_names == {
        "project_root",
        "runtime_dir",
        "config",
        "diagnostics",
        "adapters",
        "transaction_parent_env",
    }


def test_transaction_parent_env_excluded_from_repr(tmp_path: Path) -> None:
    sentinel = "REPR-LEAK-SENTINEL-env-home"
    home_dir = tmp_path / f"home-{sentinel}"
    home_dir.mkdir()
    project_root = _write_project(tmp_path)
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)

    runtime = prepare_agent_runtime(
        project_root,
        tmp_path / "runtime",
        operator_parent_env=_operator_env(path=str(bin_dir), home=home_dir),
    )

    assert sentinel not in repr(runtime)


# ---------------------------------------------------------------------------
# Section 33 — exact HOME/PATH projection
# ---------------------------------------------------------------------------


def test_exact_home_path_projection_excludes_ambient_variables(tmp_path: Path) -> None:
    project_root = _write_project(tmp_path)
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    home_dir = tmp_path / "operator-home"
    home_dir.mkdir()

    operator_env = {
        "HOME": str(home_dir),
        "PATH": str(bin_dir),
        "LANG": "en_US.UTF-8",
        "LC_ALL": "en_US.UTF-8",
        "USER": "tester",
        "LOGNAME": "tester",
        "SHELL": "/bin/bash",
        "XDG_RUNTIME_DIR": "/run/user/1000",
        "OPENAI_API_KEY": "sk-should-not-leak",
        "ANTHROPIC_API_KEY": "sk-ant-should-not-leak",
        "ARBITRARY_SENTINEL": "sentinel-value",
    }

    runtime = prepare_agent_runtime(
        project_root, tmp_path / "runtime", operator_parent_env=operator_env
    )

    assert dict(runtime.transaction_parent_env) == {"HOME": str(home_dir), "PATH": str(bin_dir)}


# ---------------------------------------------------------------------------
# Section 34 — environment lower-layer validation
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("missing", ["HOME", "PATH"])
def test_missing_home_or_path_raises_environment_policy_error(missing: str, tmp_path: Path) -> None:
    project_root = _write_project(tmp_path)
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    operator_env = _operator_env(path=str(bin_dir))
    del operator_env[missing]

    with pytest.raises(EnvironmentPolicyError):
        prepare_agent_runtime(project_root, tmp_path / "runtime", operator_parent_env=operator_env)

    assert _read_invocations(bin_dir) == []


# ---------------------------------------------------------------------------
# Section 35 — projected mapping independence/immutability
# ---------------------------------------------------------------------------


def test_projected_mapping_independent_of_caller_and_immutable(tmp_path: Path) -> None:
    project_root = _write_project(tmp_path)
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    home_dir = tmp_path / "home"
    home_dir.mkdir()
    operator_env = {"HOME": str(home_dir), "PATH": str(bin_dir), "LOGNAME": "before"}

    runtime = prepare_agent_runtime(
        project_root, tmp_path / "runtime", operator_parent_env=operator_env
    )
    snapshot = dict(runtime.transaction_parent_env)

    operator_env["HOME"] = "/mutated"
    operator_env["PATH"] = "/mutated"
    operator_env["NEW_KEY"] = "new"
    del operator_env["LOGNAME"]

    assert dict(runtime.transaction_parent_env) == snapshot

    with pytest.raises(TypeError):
        runtime.transaction_parent_env["HOME"] = "/hijack"  # type: ignore[index]


# ---------------------------------------------------------------------------
# Section 36 — runtime directory must be outside project root
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "relative_runtime_dir",
    [Path(), Path(".local") / "runtime", Path("runtime")],
)
def test_runtime_dir_inside_or_equal_project_root_rejected(
    relative_runtime_dir: Path, tmp_path: Path
) -> None:
    project_root = _write_project(tmp_path, reviewer=_CODEX)
    bin_dir = tmp_path / "bin"
    claude_exe = _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)
    runtime_dir = project_root / relative_runtime_dir

    with pytest.raises(AgentRuntimeError):
        prepare_agent_runtime(
            project_root, runtime_dir, operator_parent_env=_operator_env(path=str(bin_dir))
        )

    assert _read_invocations(claude_exe.parent) == []
    assert not (runtime_dir.resolve() / "providers").exists()


# ---------------------------------------------------------------------------
# Section 37 — config loaded from tracked project file
# ---------------------------------------------------------------------------


def test_config_is_loaded_from_tracked_project_file(tmp_path: Path) -> None:
    project_root = _write_project(tmp_path, planner=_CODEX, implementer=_CLAUDE, reviewer=_CODEX)
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)

    runtime = prepare_agent_runtime(
        project_root, tmp_path / "runtime", operator_parent_env=_operator_env(path=str(bin_dir))
    )

    assert runtime.config == load_project_config(project_root)


# ---------------------------------------------------------------------------
# Section 38 — all eight configuration combinations
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(("planner", "implementer", "reviewer"), _ALL_EIGHT_ASSIGNMENTS)
def test_all_eight_provider_assignments_prepare_correctly(
    planner: AgentProvider,
    implementer: AgentProvider,
    reviewer: AgentProvider,
    tmp_path: Path,
) -> None:
    project_root = _write_project(
        tmp_path, planner=planner, implementer=implementer, reviewer=reviewer
    )
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)

    runtime = prepare_agent_runtime(
        project_root, tmp_path / "runtime", operator_parent_env=_operator_env(path=str(bin_dir))
    )

    for attr, provider, role in (
        ("planner", planner, AgentRole.PLANNER),
        ("implementer", implementer, AgentRole.IMPLEMENTER),
        ("reviewer", reviewer, AgentRole.REVIEWER),
    ):
        adapter = getattr(runtime.adapters, attr)
        assert adapter.name == provider.value
        assert adapter.role is role


# ---------------------------------------------------------------------------
# Section 39 — inverse mixed witness
# ---------------------------------------------------------------------------


def test_inverse_mixed_witness_codex_claude_codex(tmp_path: Path) -> None:
    project_root = _write_project(tmp_path, planner=_CODEX, implementer=_CLAUDE, reviewer=_CODEX)
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)
    runtime_dir = tmp_path / "runtime"

    runtime = prepare_agent_runtime(
        project_root, runtime_dir, operator_parent_env=_operator_env(path=str(bin_dir))
    )

    assert isinstance(runtime.adapters.planner, CodexAdapter)
    assert isinstance(runtime.adapters.implementer, ClaudeAdapter)
    assert isinstance(runtime.adapters.reviewer, CodexAdapter)

    expected_schema = runtime_dir.resolve() / "providers" / "codex" / "review-decision.schema.json"
    assert expected_schema.exists()
    assert runtime.adapters.reviewer.review_output_schema_path == expected_schema


# ---------------------------------------------------------------------------
# Section 40 — provider runtime path threading
# ---------------------------------------------------------------------------


def test_provider_runtime_paths_threaded_without_adaptation(tmp_path: Path) -> None:
    project_root = _write_project(tmp_path, planner=_CLAUDE, implementer=_CODEX, reviewer=_CLAUDE)
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)
    claude_config_dir = tmp_path / "claude-config"
    codex_home = tmp_path / "codex-home"
    claude_config_dir.mkdir()
    codex_home.mkdir()

    runtime = prepare_agent_runtime(
        project_root,
        tmp_path / "runtime",
        operator_parent_env=_operator_env(path=str(bin_dir)),
        provider_overrides=ProviderRuntimeOverrides(
            claude_config_dir=claude_config_dir,
            codex_home=codex_home,
        ),
    )

    assert runtime.diagnostics.claude_config_dir == claude_config_dir.resolve()
    assert runtime.diagnostics.codex_home == codex_home.resolve()
    assert runtime.adapters.planner.claude_config_dir == claude_config_dir.resolve()  # type: ignore[attr-defined]
    assert runtime.adapters.reviewer.claude_config_dir == claude_config_dir.resolve()  # type: ignore[attr-defined]
    assert runtime.adapters.implementer.codex_home == codex_home.resolve()  # type: ignore[attr-defined]


# ---------------------------------------------------------------------------
# Section 41 — API_ALLOWED propagation/failure boundary
# ---------------------------------------------------------------------------


def test_api_allowed_resolution_error_propagates_unwrapped(tmp_path: Path) -> None:
    policy = AgentRoutingPolicy(
        planner=_route(_CLAUDE, "planner-model", "low", billing_mode=BillingMode.API_ALLOWED),
        implementer=_route(_CLAUDE, "implementer-model", "low"),
        reviewer=_route(_CLAUDE, "reviewer-model", "low"),
    )
    project_root = tmp_path / "project"
    project_root.mkdir()
    (project_root / LOCKSTEP_CONFIG_FILENAME).write_text(
        render_project_config(ProjectConfig(schema_version=1, routing=policy)),
        encoding="utf-8",
    )
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)

    with pytest.raises(AgentAdapterResolutionError):
        prepare_agent_runtime(
            project_root, tmp_path / "runtime", operator_parent_env=_operator_env(path=str(bin_dir))
        )


# ---------------------------------------------------------------------------
# Section 42 — ProjectConfigError transparency
# ---------------------------------------------------------------------------


def test_project_config_error_propagates_and_skips_diagnostics(tmp_path: Path) -> None:
    project_root = tmp_path / "project"
    project_root.mkdir()
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)

    with pytest.raises(ProjectConfigError):
        prepare_agent_runtime(
            project_root, tmp_path / "runtime", operator_parent_env=_operator_env(path=str(bin_dir))
        )

    assert _read_invocations(bin_dir) == []


# ---------------------------------------------------------------------------
# Section 43 — diagnostics error transparency
# ---------------------------------------------------------------------------


def test_provider_diagnostics_error_propagates_and_skips_resolution(tmp_path: Path) -> None:
    project_root = _write_project(tmp_path, reviewer=_CODEX)
    empty_bin = tmp_path / "empty-bin"
    empty_bin.mkdir()
    runtime_dir = tmp_path / "runtime"

    with pytest.raises(ProviderDiagnosticsError):
        prepare_agent_runtime(
            project_root, runtime_dir, operator_parent_env=_operator_env(path=str(empty_bin))
        )

    assert not (runtime_dir.resolve() / "providers").exists()


# ---------------------------------------------------------------------------
# Section 44 — provider preflight transparency
# ---------------------------------------------------------------------------


def test_claude_preflight_error_propagates_unwrapped(tmp_path: Path) -> None:
    project_root = _write_project(tmp_path)
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir, auth_stdout=_CLAUDE_AUTH_NOT_LOGGED_IN)

    with pytest.raises(ClaudePreflightError):
        prepare_agent_runtime(
            project_root, tmp_path / "runtime", operator_parent_env=_operator_env(path=str(bin_dir))
        )


def test_codex_preflight_error_propagates_unwrapped(tmp_path: Path) -> None:
    project_root = _write_project(tmp_path, planner=_CODEX, implementer=_CODEX, reviewer=_CODEX)
    bin_dir = tmp_path / "bin"
    _write_fake_codex(bin_dir, doctor_stdout=_CODEX_DOCTOR_UNHEALTHY)

    with pytest.raises(CodexPreflightError):
        prepare_agent_runtime(
            project_root, tmp_path / "runtime", operator_parent_env=_operator_env(path=str(bin_dir))
        )


# ---------------------------------------------------------------------------
# Section 45 — runtime result identity / call ordering
# ---------------------------------------------------------------------------


def test_preparation_calls_lower_layers_exactly_once_in_order_with_identity_preserved(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    project_root = _write_project(tmp_path, planner=_CODEX, implementer=_CLAUDE, reviewer=_CODEX)
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)

    calls: list[str] = []
    captured: dict[str, object] = {}

    real_load_project_config = lockstep_runtime.load_project_config
    real_diagnose = lockstep_runtime.diagnose_agent_providers
    real_resolve = lockstep_runtime.resolve_agent_adapters

    def spy_load_project_config(root: Path) -> object:
        calls.append("load_project_config")
        result = real_load_project_config(root)
        captured["config"] = result
        return result

    def spy_diagnose(policy: object, *, parent_env: object, overrides: object) -> object:
        calls.append("diagnose_agent_providers")
        result = real_diagnose(policy, parent_env=parent_env, overrides=overrides)
        captured["diagnostics"] = result
        return result

    def spy_resolve(
        policy: object,
        statuses: object,
        runtime_dir: Path,
        *,
        claude_config_dir: object = None,
        codex_home: object = None,
    ) -> object:
        calls.append("resolve_agent_adapters")
        result = real_resolve(
            policy,
            statuses,
            runtime_dir,
            claude_config_dir=claude_config_dir,
            codex_home=codex_home,
        )
        captured["adapters"] = result
        return result

    monkeypatch.setattr(lockstep_runtime, "load_project_config", spy_load_project_config)
    monkeypatch.setattr(lockstep_runtime, "diagnose_agent_providers", spy_diagnose)
    monkeypatch.setattr(lockstep_runtime, "resolve_agent_adapters", spy_resolve)

    runtime = lockstep_runtime.prepare_agent_runtime(
        project_root, tmp_path / "runtime", operator_parent_env=_operator_env(path=str(bin_dir))
    )

    assert calls == ["load_project_config", "diagnose_agent_providers", "resolve_agent_adapters"]
    assert runtime.config is captured["config"]
    assert runtime.diagnostics is captured["diagnostics"]
    assert runtime.adapters is captured["adapters"]


# ---------------------------------------------------------------------------
# Sections 46-49 — integrity guards before Supervisor
# ---------------------------------------------------------------------------


def test_run_validates_source_binding_before_supervisor(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime = _prepared_runtime(tmp_path, name="source-binding")
    other_project = tmp_path / "other-project"
    other_project.mkdir()
    request = _minimal_request(
        source_path=other_project,
        worktree_path=tmp_path / "worktree",
        runtime_dir=runtime.runtime_dir,
    )
    monkeypatch.setattr(lockstep_runtime, "run_single_subphase_transaction", _fail_if_called)

    with pytest.raises(AgentRuntimeError):
        run_single_subphase_with_runtime(request, runtime)


def test_run_validates_runtime_dir_binding_before_supervisor(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime = _prepared_runtime(tmp_path, name="runtime-dir-binding")
    request = _minimal_request(
        source_path=runtime.project_root,
        worktree_path=tmp_path / "worktree",
        runtime_dir=tmp_path / "other-runtime-dir",
    )
    monkeypatch.setattr(lockstep_runtime, "run_single_subphase_transaction", _fail_if_called)

    with pytest.raises(AgentRuntimeError):
        run_single_subphase_with_runtime(request, runtime)


def test_run_rejects_worktree_inside_runtime_dir(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime = _prepared_runtime(tmp_path, name="overlap-a")
    request = _minimal_request(
        source_path=runtime.project_root,
        worktree_path=runtime.runtime_dir / "nested-worktree",
        runtime_dir=runtime.runtime_dir,
    )
    monkeypatch.setattr(lockstep_runtime, "run_single_subphase_transaction", _fail_if_called)

    with pytest.raises(AgentRuntimeError):
        run_single_subphase_with_runtime(request, runtime)


def test_run_rejects_runtime_dir_inside_worktree(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime = _prepared_runtime(tmp_path, name="overlap-b")
    worktree_path = runtime.runtime_dir.parent
    request = _minimal_request(
        source_path=runtime.project_root,
        worktree_path=worktree_path,
        runtime_dir=runtime.runtime_dir,
    )
    monkeypatch.setattr(lockstep_runtime, "run_single_subphase_transaction", _fail_if_called)

    with pytest.raises(AgentRuntimeError):
        run_single_subphase_with_runtime(request, runtime)


def test_run_rejects_billing_mode_mismatch(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    runtime = _prepared_runtime(tmp_path, name="billing-mismatch")
    request = _minimal_request(
        source_path=runtime.project_root,
        worktree_path=tmp_path / "worktree",
        runtime_dir=runtime.runtime_dir,
        billing_mode=BillingMode.API_ALLOWED,
    )
    monkeypatch.setattr(lockstep_runtime, "run_single_subphase_transaction", _fail_if_called)

    with pytest.raises(AgentRuntimeError):
        run_single_subphase_with_runtime(request, runtime)


def test_run_allows_matching_billing_mode_through_delegation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime = _prepared_runtime(tmp_path, name="billing-match")
    request = _minimal_request(
        source_path=runtime.project_root,
        worktree_path=tmp_path / "worktree",
        runtime_dir=runtime.runtime_dir,
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )
    monkeypatch.setattr(
        lockstep_runtime, "run_single_subphase_transaction", lambda *a, **k: "delegated"
    )

    assert run_single_subphase_with_runtime(request, runtime) == "delegated"


# ---------------------------------------------------------------------------
# Section 50 — exact Supervisor delegation
# ---------------------------------------------------------------------------


def test_run_delegates_exactly_once_with_exact_adapters_and_env(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime = _prepared_runtime(tmp_path, name="delegation")
    request = _minimal_request(
        source_path=runtime.project_root,
        worktree_path=tmp_path / "worktree",
        runtime_dir=runtime.runtime_dir,
    )
    sentinel_result = object()
    calls: list[tuple[object, ...]] = []

    def _spy(
        req: object,
        *,
        parent_env: object,
        planner_adapter: object,
        implementer_adapter: object,
        reviewer_adapter: object,
    ) -> object:
        calls.append((req, parent_env, planner_adapter, implementer_adapter, reviewer_adapter))
        return sentinel_result

    monkeypatch.setattr(lockstep_runtime, "run_single_subphase_transaction", _spy)

    result = run_single_subphase_with_runtime(request, runtime)

    assert result is sentinel_result
    assert len(calls) == 1
    called_request, called_env, planner, implementer, reviewer = calls[0]
    assert called_request is request
    assert dict(called_env) == dict(runtime.transaction_parent_env)  # type: ignore[arg-type]
    assert planner is runtime.adapters.planner
    assert implementer is runtime.adapters.implementer
    assert reviewer is runtime.adapters.reviewer


# ---------------------------------------------------------------------------
# Section 51 — no preparation during run
# ---------------------------------------------------------------------------


def test_run_does_not_reload_diagnose_or_resolve(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime = _prepared_runtime(tmp_path, name="no-reprep")
    request = _minimal_request(
        source_path=runtime.project_root,
        worktree_path=tmp_path / "worktree",
        runtime_dir=runtime.runtime_dir,
    )

    def _fail(*_args: object, **_kwargs: object) -> None:
        raise AssertionError("must not be called during run_single_subphase_with_runtime")

    monkeypatch.setattr(lockstep_runtime, "load_project_config", _fail)
    monkeypatch.setattr(lockstep_runtime, "diagnose_agent_providers", _fail)
    monkeypatch.setattr(lockstep_runtime, "resolve_agent_adapters", _fail)
    monkeypatch.setattr(
        lockstep_runtime, "run_single_subphase_transaction", lambda *a, **k: "reusable"
    )

    assert run_single_subphase_with_runtime(request, runtime) == "reusable"


# ---------------------------------------------------------------------------
# Section 61 — dependency audit
# ---------------------------------------------------------------------------

_FORBIDDEN_RUNTIME_REFERENCES: tuple[str, ...] = (
    "ClaudeAdapter",
    "CodexAdapter",
    "ClaudeCliStatus",
    "CodexCliStatus",
    "AgentProvider",
    "probe_claude_cli",
    "probe_codex_cli",
    "require_claude_subscription_ready",
    "require_codex_subscription_ready",
    "materialize_codex_review_schema",
    "invoke_agent",
    "run_process",
    "subprocess",
    "append_event",
    "write_state",
    "read_state",
    "read_events",
    "replay_events",
    "commit_exact_paths",
    "create_run_worktree",
    "inspect_repository",
)

_FORBIDDEN_RUNTIME_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.git",
    "lockstep.persistence",
    "lockstep.state",
    "lockstep.verification",
    "lockstep.reporting",
    "lockstep.cli",
    "subprocess",
)


def test_runtime_module_has_no_forbidden_imports_or_calls() -> None:
    tree = ast.parse(inspect.getsource(lockstep_runtime))

    imported_names: set[str] = set()
    imported_modules: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imported_names.add(alias.asname or alias.name)
                imported_modules.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            imported_modules.add(module)
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

    for forbidden in _FORBIDDEN_RUNTIME_REFERENCES:
        assert forbidden not in imported_names
        assert forbidden not in called_names

    for forbidden_prefix in _FORBIDDEN_RUNTIME_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


def test_runtime_module_does_not_access_ambient_environment() -> None:
    tree = ast.parse(inspect.getsource(lockstep_runtime))

    attribute_accesses = {node.attr for node in ast.walk(tree) if isinstance(node, ast.Attribute)}
    assert "environ" not in attribute_accesses
    assert "getenv" not in attribute_accesses

    home_calls = [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "home"
    ]
    assert home_calls == []


# ---------------------------------------------------------------------------
# Sections 52-60 — full end-to-end fake-provider transaction
# ---------------------------------------------------------------------------

_TEST_FILE_RED = (
    "import pathlib\n"
    "import sys\n"
    "\n"
    "sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))\n"
    "\n"
    "from feature import answer\n"
    "\n"
    "\n"
    "def test_answer() -> None:\n"
    "    assert answer() == 42\n"
)

_IMPL_CORRECT = "def answer() -> int:\n    return 42\n"


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )


def _log_subjects(worktree: Path) -> list[str]:
    return _git(worktree, "log", "--format=%s").stdout.strip().splitlines()


def _init_e2e_source_repo(tmp_path: Path, policy: AgentRoutingPolicy) -> Path:
    source = tmp_path / "source"
    source.mkdir()
    _git(source, "init")
    _git(source, "config", "user.name", "Lockstep Tests")
    _git(source, "config", "user.email", "lockstep-tests@example.invalid")
    _git(source, "config", "commit.gpgsign", "false")
    (source / "README.md").write_text("initial\n", encoding="utf-8")
    (source / "pyproject.toml").write_text(
        '[tool.pytest.ini_options]\npythonpath = ["."]\n', encoding="utf-8"
    )
    (source / ".gitignore").write_text("__pycache__/\n*.pyc\n.pytest_cache/\n", encoding="utf-8")
    config = ProjectConfig(schema_version=1, routing=policy)
    (source / LOCKSTEP_CONFIG_FILENAME).write_text(render_project_config(config), encoding="utf-8")
    _git(
        source,
        "add",
        "README.md",
        "pyproject.toml",
        ".gitignore",
        LOCKSTEP_CONFIG_FILENAME,
    )
    _git(source, "commit", "-m", "initial")
    _git(source, "branch", "-M", "main")
    return source


def test_end_to_end_fake_transaction_through_full_production_path(tmp_path: Path) -> None:
    policy = _policy(planner=_CODEX, implementer=_CLAUDE, reviewer=_CODEX)
    source = _init_e2e_source_repo(tmp_path, policy)
    original_config_text = (source / LOCKSTEP_CONFIG_FILENAME).read_text(encoding="utf-8")
    source_head_before = inspect_repository(source).head_sha

    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)

    home_dir = tmp_path / "home"
    home_dir.mkdir()
    operator_env = {
        "HOME": str(home_dir),
        "PATH": str(bin_dir),
        "LANG": "en_US.UTF-8",
        "USER": "tester",
        "OPENAI_API_KEY": "sk-should-not-leak",
        "ANTHROPIC_API_KEY": "sk-ant-should-not-leak",
        "ARBITRARY_SENTINEL": "sentinel-should-not-leak",
    }

    runtime_dir = tmp_path / "runtime"
    runtime = prepare_agent_runtime(source, runtime_dir, operator_parent_env=operator_env)

    pytest_argv = (
        sys.executable,
        "-m",
        "pytest",
        "-q",
        "-p",
        "no:cacheprovider",
        "tests/test_feature.py",
    )
    request = SingleSubphaseTransactionRequest(
        project_id=ProjectId.model_validate("lockstep"),
        run_id=RunId.model_validate("20260927-002"),
        phase_id=PhaseId.model_validate("07"),
        subphase_id=SubphaseId.model_validate("05"),
        source_path=source,
        worktree_path=tmp_path / "run-worktree",
        runtime_dir=runtime_dir,
        branch="lockstep/run/run-07-05-runtime",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        planner_prompt=_write_files_prompt({"tests/test_feature.py": _TEST_FILE_RED}),
        implementer_prompt=_write_files_prompt({"feature.py": _IMPL_CORRECT}),
        reviewer_prompt=_emit_stdout_prompt(
            {
                "schema_version": 1,
                "phase_id": "07",
                "subphase_id": "05",
                "attempt": 1,
                "verdict": "approve",
                "summary": "approved",
            }
        ),
        test_paths=("tests/test_feature.py",),
        implementation_paths=("feature.py",),
        planner_quality_argv=(sys.executable, "-m", "py_compile", "tests/test_feature.py"),
        baseline_argv=pytest_argv,
        verification_argv=pytest_argv,
        test_commit_message="test(feature): freeze answer expectation",
        implementation_commit_message="feat(feature): implement answer",
        agent_timeout_seconds=60.0,
        command_timeout_seconds=60.0,
    )

    result = run_single_subphase_with_runtime(request, runtime)

    # Section 58 — canonical outcome
    assert result.final_state.workflow_state == WorkflowState.SUBPHASE_COMPLETE
    # Observational execution events (10.2) share the journal sequence.
    assert result.final_state.last_sequence == len(read_events(runtime_dir / "events.jsonl"))
    assert result.review.verdict.value == "approve"

    subjects = _log_subjects(request.worktree_path)
    assert subjects[0] == request.implementation_commit_message
    assert subjects[1] == request.test_commit_message
    assert subjects[2] == "initial"

    assert inspect_repository(source).head_sha == source_head_before
    assert not (source / "feature.py").exists()
    assert not (source / "tests").exists()
    assert (source / LOCKSTEP_CONFIG_FILENAME).read_text(encoding="utf-8") == original_config_text

    worktree_snapshot = inspect_repository(request.worktree_path)
    assert worktree_snapshot.is_clean
    assert worktree_snapshot.head_sha == result.implementation_commit.commit_sha
    assert (request.worktree_path / "tests" / "test_feature.py").read_text(
        encoding="utf-8"
    ) == _TEST_FILE_RED

    # Codex Reviewer schema bound to the prepared runtime directory (Section 30, 39).
    expected_schema = runtime_dir.resolve() / "providers" / "codex" / "review-decision.schema.json"
    assert expected_schema.exists()

    # Section 60 — persistence reconciliation
    events = read_events(runtime_dir / "events.jsonl")
    assert len([e for e in events if not isinstance(e, ExecutionEvent)]) == 11
    persisted_state = read_state(runtime_dir / "state.json")
    assert persisted_state == result.final_state
    assert replay_events(events) == result.final_state

    # Section 57 — environment evidence and Section 59 — turn/order accounting
    invocations = _read_invocations(bin_dir)
    assert len(invocations) == 9

    def _is_preflight(entry: dict[str, object]) -> bool:
        argv = tuple(entry["argv"])  # type: ignore[arg-type]
        if entry["exe"] == "claude":
            return argv in (("--version",), ("--help",), ("auth", "status"))
        return argv in (("--version",), ("exec", "--help"), ("doctor", "--json"))

    preflight = invocations[:6]
    inference = invocations[6:]
    assert all(_is_preflight(entry) for entry in preflight)
    assert sum(1 for entry in preflight if entry["exe"] == "claude") == 3
    assert sum(1 for entry in preflight if entry["exe"] == "codex") == 3
    first_codex_index = next(i for i, entry in enumerate(preflight) if entry["exe"] == "codex")
    assert all(entry["exe"] == "claude" for entry in preflight[:first_codex_index])
    assert all(entry["exe"] == "codex" for entry in preflight[first_codex_index:])

    assert [entry["exe"] for entry in inference] == ["codex", "claude", "codex"]
    planner_argv = inference[0]["argv"]
    implementer_argv = inference[1]["argv"]
    assert planner_argv[0] == "exec"  # type: ignore[index]
    assert implementer_argv[0] == "-p"  # type: ignore[index]
    reviewer_argv = tuple(inference[2]["argv"])  # type: ignore[arg-type]
    assert reviewer_argv[0] == "exec"
    assert "--output-schema" in reviewer_argv
    schema_index = reviewer_argv.index("--output-schema")
    assert reviewer_argv[schema_index + 1] == str(expected_schema)

    forbidden_env_names = (
        "LANG",
        "OPENAI_API_KEY",
        "ANTHROPIC_API_KEY",
        "ARBITRARY_SENTINEL",
    )
    for entry in inference:
        env = entry["env"]
        assert isinstance(env, dict)
        assert env.get("HOME") == str(home_dir)
        assert env.get("PATH") == str(bin_dir)
        for forbidden in forbidden_env_names:
            assert forbidden not in env

    # 12.6-R1: USER reaches Claude only through the Claude-specific inheritance
    # path; Codex does not inherit it merely because the operator has it.
    planner_env = inference[0]["env"]
    implementer_env = inference[1]["env"]
    reviewer_env = inference[2]["env"]
    assert isinstance(planner_env, dict)
    assert isinstance(implementer_env, dict)
    assert isinstance(reviewer_env, dict)
    assert implementer_env.get("USER") == "tester"
    assert "USER" not in planner_env
    assert "USER" not in reviewer_env
