import ast
import inspect
import json
import os
import stat
import sys
import textwrap
from dataclasses import FrozenInstanceError, fields
from pathlib import Path

import pytest

from lockstep.agents import (
    AgentProvider,
    AgentProviderDiagnostics,
    AgentProviderStatuses,
    AgentRoleRoute,
    AgentRoutingPolicy,
    ClaudePreflightError,
    CodexPreflightError,
    ProviderDiagnosticsError,
    ProviderRuntimeOverrides,
    diagnose_agent_providers,
)
from lockstep.domain import BillingMode
from lockstep.process import ProcessLaunchError

# ---------------------------------------------------------------------------
# Fixtures / fake provider executables
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

_CODEX_EXEC_FLAGS: tuple[str, ...] = (
    "--ephemeral",
    "--ignore-user-config",
    "--sandbox",
    "--color",
    "-c, --config <key=value>",
)


def _codex_exec_help(flags: tuple[str, ...] = _CODEX_EXEC_FLAGS) -> str:
    lines = ["Usage: codex exec [OPTIONS]", "", "Options:"]
    lines.extend(f"  {flag}  option description" for flag in flags)
    return "\n".join(lines) + "\n"


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


def _write_fake_claude(
    directory: Path,
    *,
    version_stdout: str = "2.1.259 (Claude Code)\n",
    help_text: str = "Usage: claude [OPTIONS] [PROMPT]\n",
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
    exec_help_text: str | None = None,
    doctor_stdout: str = _CODEX_DOCTOR_OK,
    doctor_returncode: int = 0,
) -> Path:
    directory.mkdir(parents=True, exist_ok=True)
    executable = directory / "codex"
    config_path = directory / "codex-config.json"
    if exec_help_text is None:
        exec_help_text = _codex_exec_help()
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

        sys.stderr.write("fake codex: unauthorized argv " + json.dumps(args) + "\\n")
        raise SystemExit(99)
        """
    )
    executable.write_text(script, encoding="utf-8")
    mode = executable.stat().st_mode
    executable.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _read_invocations(executable: Path) -> list[dict[str, object]]:
    log_path = executable.parent / "invocations.jsonl"
    if not log_path.exists():
        return []
    return [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines() if line]


def _minimal_parent_env(*, path: str) -> dict[str, str]:
    return {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": path,
    }


def _route(provider: AgentProvider, model: str = "model", effort: str = "low") -> AgentRoleRoute:
    return AgentRoleRoute(
        provider=provider,
        model=model,
        effort=effort,
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )


def _policy(
    planner: AgentProvider,
    implementer: AgentProvider,
    reviewer: AgentProvider,
) -> AgentRoutingPolicy:
    return AgentRoutingPolicy(
        planner=_route(planner, "planner-model", "planner-effort"),
        implementer=_route(implementer, "implementer-model", "implementer-effort"),
        reviewer=_route(reviewer, "reviewer-model", "reviewer-effort"),
    )


_ALL_EIGHT_ASSIGNMENTS: tuple[tuple[AgentProvider, AgentProvider, AgentProvider], ...] = (
    (AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
    (AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CODEX),
    (AgentProvider.CLAUDE, AgentProvider.CODEX, AgentProvider.CLAUDE),
    (AgentProvider.CLAUDE, AgentProvider.CODEX, AgentProvider.CODEX),
    (AgentProvider.CODEX, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
    (AgentProvider.CODEX, AgentProvider.CLAUDE, AgentProvider.CODEX),
    (AgentProvider.CODEX, AgentProvider.CODEX, AgentProvider.CLAUDE),
    (AgentProvider.CODEX, AgentProvider.CODEX, AgentProvider.CODEX),
)


def _assert_claude_then_codex_order(invocations: list[dict[str, object]]) -> None:
    exe_sequence = [entry["exe"] for entry in invocations]
    assert exe_sequence.count("claude") == 3
    assert exe_sequence.count("codex") == 3
    first_codex_index = exe_sequence.index("codex")
    assert exe_sequence[:first_codex_index] == ["claude"] * 3
    assert exe_sequence[first_codex_index:] == ["codex"] * 3


# ---------------------------------------------------------------------------
# Public API / signature (AC-7.4.7-10)
# ---------------------------------------------------------------------------


def test_public_exports_present() -> None:
    from lockstep import agents

    exported = set(agents.__all__)
    assert {
        "AgentProviderDiagnostics",
        "ProviderDiagnosticsError",
        "ProviderRuntimeOverrides",
        "diagnose_agent_providers",
    }.issubset(exported)


def test_parent_env_parameter_has_no_default() -> None:
    signature = inspect.signature(diagnose_agent_providers)
    assert signature.parameters["parent_env"].kind in (
        inspect.Parameter.POSITIONAL_OR_KEYWORD,
        inspect.Parameter.KEYWORD_ONLY,
    )
    assert signature.parameters["parent_env"].default is inspect.Parameter.empty


# ---------------------------------------------------------------------------
# Section 33 — result shape
# ---------------------------------------------------------------------------


def test_runtime_overrides_is_frozen_and_slotted() -> None:
    overrides = ProviderRuntimeOverrides()

    with pytest.raises(FrozenInstanceError):
        overrides.claude_executable = Path("/hijack")  # type: ignore[misc]
    assert not hasattr(overrides, "__dict__")

    field_names = {field.name for field in fields(overrides)}
    assert field_names == {
        "claude_executable",
        "codex_executable",
        "claude_config_dir",
        "codex_home",
    }
    assert overrides.claude_executable is None
    assert overrides.codex_executable is None
    assert overrides.claude_config_dir is None
    assert overrides.codex_home is None


def test_diagnostics_result_is_frozen_slotted_with_only_intended_fields(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)

    result = diagnose_agent_providers(
        _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
        parent_env=_minimal_parent_env(path=str(bin_dir)),
    )

    with pytest.raises(FrozenInstanceError):
        result.claude_executable = Path("/hijack")  # type: ignore[misc]
    assert not hasattr(result, "__dict__")

    field_names = {field.name for field in fields(result)}
    assert field_names == {
        "statuses",
        "claude_executable",
        "codex_executable",
        "claude_config_dir",
        "codex_home",
    }
    assert isinstance(result.statuses, AgentProviderStatuses)
    assert isinstance(result, AgentProviderDiagnostics)


# ---------------------------------------------------------------------------
# Section 34 — all-Claude
# ---------------------------------------------------------------------------


def test_all_claude_policy_probes_only_claude(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    executable = _write_fake_claude(bin_dir)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    result = diagnose_agent_providers(
        _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
        parent_env=parent_env,
    )

    assert result.statuses.claude is not None
    assert result.statuses.codex is None
    assert result.claude_executable == executable.resolve()
    assert result.codex_executable is None

    invocations = _read_invocations(executable)
    argvs = sorted(tuple(entry["argv"]) for entry in invocations)  # type: ignore[arg-type]
    assert argvs == sorted([("--version",), ("--help",), ("auth", "status")])
    assert len(argvs) == 3


# ---------------------------------------------------------------------------
# Section 35 — all-Codex
# ---------------------------------------------------------------------------


def test_all_codex_policy_probes_only_codex(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    executable = _write_fake_codex(bin_dir)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    result = diagnose_agent_providers(
        _policy(AgentProvider.CODEX, AgentProvider.CODEX, AgentProvider.CODEX),
        parent_env=parent_env,
    )

    assert result.statuses.codex is not None
    assert result.statuses.claude is None
    assert result.codex_executable == executable.resolve()
    assert result.claude_executable is None

    invocations = _read_invocations(executable)
    argvs = sorted(tuple(entry["argv"]) for entry in invocations)  # type: ignore[arg-type]
    assert argvs == sorted([("--version",), ("exec", "--help"), ("doctor", "--json")])
    assert len(argvs) == 3


# ---------------------------------------------------------------------------
# Section 36 — mixed providers, fixed diagnostic order
# ---------------------------------------------------------------------------


def test_mixed_providers_fixed_order_with_claude_planner(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    claude_exe = _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    result = diagnose_agent_providers(
        _policy(AgentProvider.CLAUDE, AgentProvider.CODEX, AgentProvider.CLAUDE),
        parent_env=parent_env,
    )

    assert result.statuses.claude is not None
    assert result.statuses.codex is not None
    _assert_claude_then_codex_order(_read_invocations(claude_exe))


def test_mixed_providers_fixed_order_with_codex_planner(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    claude_exe = _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    result = diagnose_agent_providers(
        _policy(AgentProvider.CODEX, AgentProvider.CLAUDE, AgentProvider.CODEX),
        parent_env=parent_env,
    )

    assert result.statuses.claude is not None
    assert result.statuses.codex is not None
    _assert_claude_then_codex_order(_read_invocations(claude_exe))


# ---------------------------------------------------------------------------
# Section 37 — all eight combinations
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("planner", "implementer", "reviewer"),
    _ALL_EIGHT_ASSIGNMENTS,
)
def test_all_eight_combinations_derive_selected_providers(
    planner: AgentProvider,
    implementer: AgentProvider,
    reviewer: AgentProvider,
    tmp_path: Path,
) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    result = diagnose_agent_providers(
        _policy(planner, implementer, reviewer), parent_env=parent_env
    )

    used = {planner, implementer, reviewer}
    expect_claude = AgentProvider.CLAUDE in used
    expect_codex = AgentProvider.CODEX in used

    assert (result.statuses.claude is not None) is expect_claude
    assert (result.statuses.codex is not None) is expect_codex
    assert (result.claude_executable is not None) is expect_claude
    assert (result.codex_executable is not None) is expect_codex


# ---------------------------------------------------------------------------
# Section 38 — selected provider probed exactly once
# ---------------------------------------------------------------------------


def test_selected_provider_probed_exactly_once_not_per_role(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    claude_exe = _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    diagnose_agent_providers(
        _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CODEX),
        parent_env=parent_env,
    )

    invocations = _read_invocations(claude_exe)
    claude_calls = [entry for entry in invocations if entry["exe"] == "claude"]
    codex_calls = [entry for entry in invocations if entry["exe"] == "codex"]
    assert len(claude_calls) == 3
    assert len(codex_calls) == 3


# ---------------------------------------------------------------------------
# Section 39 — unused provider overrides ignored
# ---------------------------------------------------------------------------


def test_all_claude_ignores_invalid_unused_codex_overrides(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    result = diagnose_agent_providers(
        _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
        parent_env=parent_env,
        overrides=ProviderRuntimeOverrides(
            codex_executable=Path("relative/nonexistent/codex"),
            codex_home=Path("relative/codex-home"),
        ),
    )

    assert result.statuses.claude is not None
    assert result.codex_executable is None
    assert result.codex_home is None


def test_all_codex_ignores_invalid_unused_claude_overrides(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_codex(bin_dir)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    result = diagnose_agent_providers(
        _policy(AgentProvider.CODEX, AgentProvider.CODEX, AgentProvider.CODEX),
        parent_env=parent_env,
        overrides=ProviderRuntimeOverrides(
            claude_executable=Path("relative/nonexistent/claude"),
            claude_config_dir=Path("relative/claude-config"),
        ),
    )

    assert result.statuses.codex is not None
    assert result.claude_executable is None
    assert result.claude_config_dir is None


# ---------------------------------------------------------------------------
# Section 40 — explicit executable overrides win over PATH
# ---------------------------------------------------------------------------


def test_explicit_claude_executable_override_wins_over_path(tmp_path: Path) -> None:
    path_claude = _write_fake_claude(tmp_path / "bin")
    override_claude = _write_fake_claude(tmp_path / "override")
    parent_env = _minimal_parent_env(path=str(tmp_path / "bin"))

    result = diagnose_agent_providers(
        _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
        parent_env=parent_env,
        overrides=ProviderRuntimeOverrides(claude_executable=override_claude),
    )

    assert result.claude_executable == override_claude.resolve()
    assert _read_invocations(path_claude) == []
    assert len(_read_invocations(override_claude)) == 3


def test_explicit_codex_executable_override_wins_over_path(tmp_path: Path) -> None:
    path_codex = _write_fake_codex(tmp_path / "bin")
    override_codex = _write_fake_codex(tmp_path / "override")
    parent_env = _minimal_parent_env(path=str(tmp_path / "bin"))

    result = diagnose_agent_providers(
        _policy(AgentProvider.CODEX, AgentProvider.CODEX, AgentProvider.CODEX),
        parent_env=parent_env,
        overrides=ProviderRuntimeOverrides(codex_executable=override_codex),
    )

    assert result.codex_executable == override_codex.resolve()
    assert _read_invocations(path_codex) == []
    assert len(_read_invocations(override_codex)) == 3


# ---------------------------------------------------------------------------
# Section 41 — relative overrides rejected
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("field", ["claude_executable", "claude_config_dir"])
def test_relative_claude_overrides_rejected(field: str, tmp_path: Path) -> None:
    executable = _write_fake_claude(tmp_path / "bin")
    parent_env = _minimal_parent_env(path=str(tmp_path / "bin"))

    with pytest.raises(ProviderDiagnosticsError):
        diagnose_agent_providers(
            _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
            parent_env=parent_env,
            overrides=ProviderRuntimeOverrides(**{field: Path("relative/path")}),
        )
    assert _read_invocations(executable) == []


@pytest.mark.parametrize("field", ["codex_executable", "codex_home"])
def test_relative_codex_overrides_rejected(field: str, tmp_path: Path) -> None:
    executable = _write_fake_codex(tmp_path / "bin")
    parent_env = _minimal_parent_env(path=str(tmp_path / "bin"))

    with pytest.raises(ProviderDiagnosticsError):
        diagnose_agent_providers(
            _policy(AgentProvider.CODEX, AgentProvider.CODEX, AgentProvider.CODEX),
            parent_env=parent_env,
            overrides=ProviderRuntimeOverrides(**{field: Path("relative/path")}),
        )
    assert _read_invocations(executable) == []


def test_relative_override_is_not_resolved_against_process_cwd(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    parent_env = _minimal_parent_env(path=str(bin_dir))
    monkeypatch.chdir(bin_dir)

    with pytest.raises(ProviderDiagnosticsError):
        diagnose_agent_providers(
            _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
            parent_env=parent_env,
            overrides=ProviderRuntimeOverrides(claude_executable=Path("claude")),
        )


# ---------------------------------------------------------------------------
# Section 42 — executable file checks
# ---------------------------------------------------------------------------


def test_missing_explicit_executable_rejected(tmp_path: Path) -> None:
    parent_env = _minimal_parent_env(path=str(tmp_path / "empty-bin"))
    missing = tmp_path / "nowhere" / "claude"

    with pytest.raises(ProviderDiagnosticsError):
        diagnose_agent_providers(
            _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
            parent_env=parent_env,
            overrides=ProviderRuntimeOverrides(claude_executable=missing),
        )


def test_directory_explicit_executable_rejected(tmp_path: Path) -> None:
    directory = tmp_path / "claude-dir"
    directory.mkdir()
    parent_env = _minimal_parent_env(path=str(tmp_path / "empty-bin"))

    with pytest.raises(ProviderDiagnosticsError):
        diagnose_agent_providers(
            _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
            parent_env=parent_env,
            overrides=ProviderRuntimeOverrides(claude_executable=directory),
        )


def test_non_executable_regular_file_rejected(tmp_path: Path) -> None:
    regular = tmp_path / "claude-not-executable"
    regular.write_text("not a real executable\n", encoding="utf-8")
    parent_env = _minimal_parent_env(path=str(tmp_path / "empty-bin"))

    with pytest.raises(ProviderDiagnosticsError):
        diagnose_agent_providers(
            _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
            parent_env=parent_env,
            overrides=ProviderRuntimeOverrides(claude_executable=regular),
        )


def test_symlink_to_valid_executable_is_accepted(tmp_path: Path) -> None:
    real = _write_fake_claude(tmp_path / "durable-store")
    link = tmp_path / "claude-symlink"
    link.symlink_to(real)
    parent_env = _minimal_parent_env(path=str(tmp_path / "empty-bin"))

    result = diagnose_agent_providers(
        _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
        parent_env=parent_env,
        overrides=ProviderRuntimeOverrides(claude_executable=link),
    )

    assert result.claude_executable == real.resolve()


# ---------------------------------------------------------------------------
# Section 43 — PATH discovery uses only explicit parent PATH
# ---------------------------------------------------------------------------


def test_discovery_uses_only_explicit_parent_path_in_order(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    bin1 = tmp_path / "bin1"
    bin2 = tmp_path / "bin2"
    exe1 = _write_fake_claude(bin1)
    exe2 = _write_fake_claude(bin2)
    explicit_path = f"{bin1}:{bin2}"

    monkeypatch.setenv("PATH", "/definitely/not/a/real/contradictory/path")

    parent_env = {"HOME": os.environ.get("HOME", "/tmp"), "PATH": explicit_path}
    result = diagnose_agent_providers(
        _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
        parent_env=parent_env,
    )

    assert result.claude_executable == exe1.resolve()
    assert len(_read_invocations(exe1)) == 3
    assert _read_invocations(exe2) == []


def test_missing_path_raises_bounded_error(tmp_path: Path) -> None:
    parent_env = {"HOME": os.environ.get("HOME", "/tmp"), "PATH": ""}

    with pytest.raises(ProviderDiagnosticsError):
        diagnose_agent_providers(
            _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
            parent_env=parent_env,
        )


# ---------------------------------------------------------------------------
# Section 44 — PATH error privacy
# ---------------------------------------------------------------------------


def test_path_not_found_error_does_not_leak_path_contents(tmp_path: Path) -> None:
    sentinel = "SECRET-SENTINEL-PATH-9f3k-DO-NOT-ECHO"
    fake_secret_dir = tmp_path / sentinel
    fake_secret_dir.mkdir()
    parent_env = {"HOME": os.environ.get("HOME", "/tmp"), "PATH": str(fake_secret_dir)}

    with pytest.raises(ProviderDiagnosticsError) as exc_info:
        diagnose_agent_providers(
            _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
            parent_env=parent_env,
        )

    assert sentinel not in str(exc_info.value)
    assert sentinel not in exc_info.value.reason


# ---------------------------------------------------------------------------
# Section 45 — discovery/validation happens before any probe
# ---------------------------------------------------------------------------


def test_mixed_policy_missing_codex_fails_before_claude_probe(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    claude_exe = _write_fake_claude(bin_dir)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    with pytest.raises(ProviderDiagnosticsError):
        diagnose_agent_providers(
            _policy(AgentProvider.CLAUDE, AgentProvider.CODEX, AgentProvider.CLAUDE),
            parent_env=parent_env,
        )

    assert _read_invocations(claude_exe) == []


def test_mixed_policy_missing_claude_fails_before_codex_probe(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    codex_exe = _write_fake_codex(bin_dir)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    with pytest.raises(ProviderDiagnosticsError):
        diagnose_agent_providers(
            _policy(AgentProvider.CODEX, AgentProvider.CLAUDE, AgentProvider.CODEX),
            parent_env=parent_env,
        )

    assert _read_invocations(codex_exe) == []


# ---------------------------------------------------------------------------
# Section 46 — transient npx cache rejection
# ---------------------------------------------------------------------------


def test_path_discovered_transient_npx_claude_rejected(tmp_path: Path) -> None:
    npx_dir = tmp_path / "home" / ".npm" / "_npx" / "abc123" / "node_modules" / ".bin"
    executable = _write_fake_claude(npx_dir)
    parent_env = _minimal_parent_env(path=str(npx_dir))

    with pytest.raises(ProviderDiagnosticsError):
        diagnose_agent_providers(
            _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
            parent_env=parent_env,
        )

    assert _read_invocations(executable) == []


def test_explicit_transient_npx_claude_override_rejected(tmp_path: Path) -> None:
    npx_dir = tmp_path / "home" / ".npm" / "_npx" / "abc123" / "node_modules" / ".bin"
    executable = _write_fake_claude(npx_dir)
    parent_env = _minimal_parent_env(path=str(tmp_path / "empty-bin"))

    with pytest.raises(ProviderDiagnosticsError):
        diagnose_agent_providers(
            _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
            parent_env=parent_env,
            overrides=ProviderRuntimeOverrides(claude_executable=executable),
        )

    assert _read_invocations(executable) == []


def test_stable_symlink_outside_npx_tree_is_legal(tmp_path: Path) -> None:
    real = _write_fake_claude(tmp_path / "durable-store")
    stable_dir = tmp_path / "stable-bin"
    stable_dir.mkdir()
    link = stable_dir / "claude"
    link.symlink_to(real)
    parent_env = _minimal_parent_env(path=str(stable_dir))

    result = diagnose_agent_providers(
        _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
        parent_env=parent_env,
    )

    assert result.claude_executable == real.resolve()


# ---------------------------------------------------------------------------
# Section 47 — runtime directory routing without cross-wiring
# ---------------------------------------------------------------------------


def test_runtime_directories_routed_without_cross_wiring(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    claude_exe = _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    claude_config_dir = tmp_path / "claude-config"
    codex_home = tmp_path / "codex-home"
    claude_config_dir.mkdir()
    codex_home.mkdir()

    result = diagnose_agent_providers(
        _policy(AgentProvider.CLAUDE, AgentProvider.CODEX, AgentProvider.CLAUDE),
        parent_env=parent_env,
        overrides=ProviderRuntimeOverrides(
            claude_config_dir=claude_config_dir,
            codex_home=codex_home,
        ),
    )

    assert result.claude_config_dir == claude_config_dir.resolve()
    assert result.codex_home == codex_home.resolve()

    invocations = _read_invocations(claude_exe)
    claude_calls = [entry for entry in invocations if entry["exe"] == "claude"]
    codex_calls = [entry for entry in invocations if entry["exe"] == "codex"]
    assert claude_calls
    assert codex_calls

    for entry in claude_calls:
        env = entry["env"]
        assert isinstance(env, dict)
        assert env.get("CLAUDE_CONFIG_DIR") == str(claude_config_dir.resolve())
        assert "CODEX_HOME" not in env

    for entry in codex_calls:
        env = entry["env"]
        assert isinstance(env, dict)
        assert env.get("CODEX_HOME") == str(codex_home.resolve())
        assert "CLAUDE_CONFIG_DIR" not in env


# ---------------------------------------------------------------------------
# Section 48 — ambient credential exclusion
# ---------------------------------------------------------------------------


def test_ambient_credentials_excluded_from_probe_children(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    claude_exe = _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)
    parent_env = {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": str(bin_dir),
        "OPENAI_API_KEY": "sk-parent-should-not-leak",
        "CODEX_API_KEY": "sk-parent-should-not-leak",
        "CODEX_ACCESS_TOKEN": "parent-should-not-leak",
        "OPENAI_BASE_URL": "https://parent.invalid",
        "ANTHROPIC_API_KEY": "sk-ant-parent-should-not-leak",
        "ANTHROPIC_AUTH_TOKEN": "parent-should-not-leak",
        "ANTHROPIC_BASE_URL": "https://parent.invalid",
        "CLAUDE_CODE_OAUTH_TOKEN": "parent-should-not-leak",
        "CODEX_HOME": "/attacker/codex-home",
        "CLAUDE_CONFIG_DIR": "/attacker/claude-home",
    }

    diagnose_agent_providers(
        _policy(AgentProvider.CLAUDE, AgentProvider.CODEX, AgentProvider.CLAUDE),
        parent_env=parent_env,
    )

    forbidden_names = (
        "OPENAI_API_KEY",
        "CODEX_API_KEY",
        "CODEX_ACCESS_TOKEN",
        "OPENAI_BASE_URL",
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "CLAUDE_CODE_OAUTH_TOKEN",
    )
    invocations = _read_invocations(claude_exe)
    assert invocations
    for entry in invocations:
        env = entry["env"]
        assert isinstance(env, dict)
        for name in forbidden_names:
            assert name not in env
        assert env.get("CODEX_HOME") != "/attacker/codex-home"
        assert env.get("CLAUDE_CONFIG_DIR") != "/attacker/claude-home"


# ---------------------------------------------------------------------------
# Section 49 / 50 — lower-layer exception transparency
# ---------------------------------------------------------------------------


def test_claude_preflight_error_propagates_unwrapped(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir, auth_stdout=_CLAUDE_AUTH_NOT_LOGGED_IN)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    with pytest.raises(ClaudePreflightError):
        diagnose_agent_providers(
            _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
            parent_env=parent_env,
        )


def test_codex_preflight_error_propagates_unwrapped(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    unhealthy_doctor = json.dumps(
        {
            "schemaVersion": 1,
            "overallStatus": "ok",
            "checks": {"auth.credentials": {"status": "error", "details": []}},
        }
    )
    _write_fake_codex(bin_dir, doctor_stdout=unhealthy_doctor)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    with pytest.raises(CodexPreflightError):
        diagnose_agent_providers(
            _policy(AgentProvider.CODEX, AgentProvider.CODEX, AgentProvider.CODEX),
            parent_env=parent_env,
        )


# ---------------------------------------------------------------------------
# Section 51 — process-layer failure transparency
# ---------------------------------------------------------------------------


def test_process_launch_failure_propagates_unwrapped(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(parents=True)
    broken = bin_dir / "claude"
    broken.write_bytes(b"\x00\x01\x02not-a-real-executable\xff")
    mode = broken.stat().st_mode
    broken.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    with pytest.raises(ProcessLaunchError):
        diagnose_agent_providers(
            _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
            parent_env=parent_env,
        )


# ---------------------------------------------------------------------------
# Section 52 — parent mapping immutability
# ---------------------------------------------------------------------------


def test_parent_env_mapping_is_not_mutated(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    parent_env = _minimal_parent_env(path=str(bin_dir))
    snapshot = dict(parent_env)

    diagnose_agent_providers(
        _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
        parent_env=parent_env,
    )

    assert parent_env == snapshot


# ---------------------------------------------------------------------------
# Section 53 — diagnostics privacy
# ---------------------------------------------------------------------------


def test_diagnostics_result_does_not_store_parent_env(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_claude(bin_dir)
    sentinel = "PARENT-ENV-SENTINEL-should-not-appear-in-result"
    parent_env = _minimal_parent_env(path=str(bin_dir))
    parent_env["LOGNAME"] = sentinel

    result = diagnose_agent_providers(
        _policy(AgentProvider.CLAUDE, AgentProvider.CLAUDE, AgentProvider.CLAUDE),
        parent_env=parent_env,
    )

    assert sentinel not in repr(result)
    assert not hasattr(result, "parent_env")
    assert not hasattr(result, "cwd")


# ---------------------------------------------------------------------------
# Section 54 — exact known preflight commands only (no inference)
# ---------------------------------------------------------------------------


def test_no_inference_commands_invoked_in_mixed_diagnostics(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    claude_exe = _write_fake_claude(bin_dir)
    _write_fake_codex(bin_dir)
    parent_env = _minimal_parent_env(path=str(bin_dir))

    diagnose_agent_providers(
        _policy(AgentProvider.CLAUDE, AgentProvider.CODEX, AgentProvider.CLAUDE),
        parent_env=parent_env,
    )

    invocations = _read_invocations(claude_exe)
    claude_argvs = {tuple(entry["argv"]) for entry in invocations if entry["exe"] == "claude"}  # type: ignore[arg-type]
    codex_argvs = {tuple(entry["argv"]) for entry in invocations if entry["exe"] == "codex"}  # type: ignore[arg-type]

    assert claude_argvs == {("--version",), ("--help",), ("auth", "status")}
    assert codex_argvs == {("--version",), ("exec", "--help"), ("doctor", "--json")}


# ---------------------------------------------------------------------------
# Section 55 — dependency boundary
# ---------------------------------------------------------------------------

_FORBIDDEN_DIAGNOSTICS_REFERENCES: tuple[str, ...] = (
    "ProjectConfig",
    "load_project_config",
    "parse_project_config",
    "ClaudeAdapter",
    "CodexAdapter",
    "resolve_agent_adapters",
    "materialize_codex_review_schema",
    "invoke_agent",
    "Supervisor",
    "run_single_subphase_transaction",
    "SingleSubphaseTransactionRequest",
    "subprocess",
)

_FORBIDDEN_DIAGNOSTICS_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.config",
    "lockstep.supervisor",
    "lockstep.git",
    "lockstep.persistence",
    "lockstep.state",
    "lockstep.verification",
    "lockstep.reporting",
    "lockstep.cli",
    "subprocess",
)


def test_diagnostics_module_has_no_forbidden_imports_or_calls() -> None:
    import lockstep.agents.diagnostics as diagnostics_module

    tree = ast.parse(inspect.getsource(diagnostics_module))

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

    for forbidden in _FORBIDDEN_DIAGNOSTICS_REFERENCES:
        assert forbidden not in imported_names
        assert forbidden not in called_names

    for forbidden_prefix in _FORBIDDEN_DIAGNOSTICS_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


# ---------------------------------------------------------------------------
# Section 56 — no ambient environment access
# ---------------------------------------------------------------------------

_FORBIDDEN_AMBIENT_ATTRIBUTES: tuple[str, ...] = (
    "environ",
    "getenv",
    "expanduser",
)


def test_diagnostics_module_does_not_access_ambient_environment() -> None:
    import lockstep.agents.diagnostics as diagnostics_module

    tree = ast.parse(inspect.getsource(diagnostics_module))

    attribute_accesses: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute):
            attribute_accesses.add(node.attr)

    for forbidden in _FORBIDDEN_AMBIENT_ATTRIBUTES:
        assert forbidden not in attribute_accesses

    home_calls = [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "home"
    ]
    assert home_calls == []
