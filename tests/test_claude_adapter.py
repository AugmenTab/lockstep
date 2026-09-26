import hashlib
import json
import os
import stat
import subprocess
import sys
import textwrap
from dataclasses import FrozenInstanceError, replace
from pathlib import Path

import pytest

import lockstep.agents as agents_package
import lockstep.agents.claude as claude_module
import lockstep.agents.invocation as invocation_module
from lockstep.agents import (
    AgentAdapter,
    AgentInvocationRequest,
    ClaudeAdapter,
    ClaudeAdapterError,
    ClaudeCliStatus,
    ClaudePreflightError,
    invoke_agent,
    probe_claude_cli,
)
from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    BillingMode,
    PhaseId,
    ReviewDecision,
    ReviewVerdict,
    SubphaseId,
)
from lockstep.process import EnvironmentPolicyError

_SUPPORTED_ROLES: tuple[AgentRole, ...] = (
    AgentRole.PLANNER,
    AgentRole.IMPLEMENTER,
    AgentRole.REVIEWER,
)

_WRITE_TOOLS = "Read,Write,Edit,Glob,Grep"
_READ_ONLY_TOOLS = "Read,Glob,Grep"

_BASE_ARGV_TAIL: tuple[str, ...] = (
    "-p",
    "--safe-mode",
    "--restricted",
    "--no-session-persistence",
    "--permission-prompts",
    "none",
)

_FORBIDDEN_ARGV_ELEMENTS: tuple[str, ...] = (
    "--bare",
    "--worktree",
    "-w",
    "--continue",
    "-c",
    "--resume",
    "-r",
    "--fork-session",
    "--session-id",
    "--dangerously-skip-permissions",
    "--allow-dangerously-skip-permissions",
    "--permission-mode",
    "--cloud",
    "--remote",
    "--remote-control",
    "--chrome",
    "--fallback-model",
    "--add-dir",
    "--mcp-config",
    "--strict-mcp-config",
    "--setting-sources",
    "--system-prompt",
    "--system-prompt-file",
    "--plugin-dir",
    "--plugin-url",
    "--agent",
    "--agents",
    "Bash",
)

_FORBIDDEN_TOOL_NAMES: tuple[str, ...] = (
    "Bash",
    "WebFetch",
    "WebSearch",
    "NotebookEdit",
    "Agent",
    "Task",
)

_REQUIRED_CAPABILITY_FIELDS: tuple[str, ...] = (
    "supports_print",
    "supports_model",
    "supports_effort",
    "supports_output_format",
    "supports_permission_prompts",
    "supports_no_session_persistence",
    "supports_restricted",
    "supports_safe_mode",
    "supports_tools",
    "supports_allowed_tools",
    "supports_disallowed_tools",
)

_AMBIENT_CREDENTIAL_ENV: dict[str, str] = {
    "ANTHROPIC_API_KEY": "sk-ant-parent-must-not-leak",
    "ANTHROPIC_AUTH_TOKEN": "auth-token-parent-must-not-leak",
    "ANTHROPIC_BASE_URL": "https://parent-anthropic.invalid",
    "ANTHROPIC_PROFILE": "parent-profile-must-not-leak",
    "ANTHROPIC_FEDERATION_RULE_ID": "fed-rule-parent-must-not-leak",
    "ANTHROPIC_ORGANIZATION_ID": "org-parent-must-not-leak",
    "ANTHROPIC_IDENTITY_TOKEN_FILE": "/tmp/identity-token-must-not-leak",
    "CLAUDE_CODE_OAUTH_TOKEN": "oauth-parent-must-not-leak",
    "CLAUDE_CODE_USE_BEDROCK": "1",
    "CLAUDE_CODE_USE_VERTEX": "1",
    "CLAUDE_CODE_USE_FOUNDRY": "1",
}

_NOT_LOGGED_IN_STDOUT = "Not logged in · Please run /login"


def _healthy_status(executable: str = "/fake/claude") -> ClaudeCliStatus:
    return ClaudeCliStatus(
        executable=executable,
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


def _make_adapter(
    role: AgentRole,
    *,
    status: ClaudeCliStatus | None = None,
    model: str = "claude-sonnet-5",
    effort: str = "low",
    claude_config_dir: Path | None = None,
) -> ClaudeAdapter:
    return ClaudeAdapter(
        role=role,
        status=_healthy_status() if status is None else status,
        model=model,
        effort=effort,
        claude_config_dir=claude_config_dir,
    )


def _make_request(
    cwd: Path,
    *,
    role: AgentRole,
    prompt: str = "prompt-body",
    billing_mode: BillingMode = BillingMode.SUBSCRIPTION_ONLY,
) -> AgentInvocationRequest:
    return AgentInvocationRequest(
        role=role,
        billing_mode=billing_mode,
        prompt=prompt,
        cwd=cwd,
        timeout_seconds=5,
        termination_grace_seconds=0.1,
    )


def _minimal_parent_env() -> dict[str, str]:
    return {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    }


def _canonical_schema() -> dict[str, object]:
    return ReviewDecision.model_json_schema()


def _flag_value(argv: tuple[str, ...], flag: str) -> str:
    assert argv.count(flag) == 1, f"{flag} must appear exactly once"
    return argv[argv.index(flag) + 1]


def _expected_argv(
    *,
    executable: str,
    model: str,
    effort: str,
    tools: str,
    reviewer: bool,
) -> tuple[str, ...]:
    argv: list[str] = [
        executable,
        *_BASE_ARGV_TAIL,
        "--model",
        model,
        "--effort",
        effort,
        "--output-format",
        "text",
        "--tools",
        tools,
        "--allowedTools",
        tools,
        "--disallowedTools",
        "mcp__*",
    ]
    if reviewer:
        argv.extend(
            (
                "--json-schema",
                json.dumps(
                    _canonical_schema(),
                    ensure_ascii=False,
                    separators=(",", ":"),
                    sort_keys=True,
                ),
            )
        )
    return tuple(argv)


def _review_decision() -> ReviewDecision:
    return ReviewDecision(
        phase_id=PhaseId.model_validate("06"),
        subphase_id=SubphaseId.model_validate("03"),
        attempt=AttemptNumber.model_validate(1),
        verdict=ReviewVerdict.APPROVE,
        summary="approved",
    )


# ---------------------------------------------------------------------------
# Fake Claude executables
# ---------------------------------------------------------------------------


def _write_probe_claude(root: Path, *, help_flags: tuple[str, ...]) -> Path:
    fake_root = root / "claude-probe-fake"
    fake_root.mkdir(parents=True, exist_ok=True)
    executable = fake_root / "claude"
    help_lines = ["Usage: claude [OPTIONS] [PROMPT]", "", "Options:"]
    help_lines.extend(f"  {flag}  option description" for flag in help_flags)
    (fake_root / "config.json").write_text(
        json.dumps(
            {
                "version_stdout": "2.1.283 (Claude Code)\n",
                "help_text": "\n".join(help_lines) + "\n",
                "auth_stdout": json.dumps(
                    {
                        "loggedIn": True,
                        "authMethod": "claude.ai",
                        "apiProvider": "firstParty",
                        "subscriptionType": "pro",
                    }
                ),
            }
        ),
        encoding="utf-8",
    )
    script = textwrap.dedent(
        f"""\
        #!{sys.executable}
        import json
        import sys
        from pathlib import Path

        base = Path(__file__).resolve().parent
        config = json.loads((base / "config.json").read_text(encoding="utf-8"))
        args = sys.argv[1:]

        if "-p" in args or "--print" in args:
            sys.stderr.write("fake claude probe: refusing inference\\n")
            raise SystemExit(97)
        if args == ["--version"]:
            sys.stdout.write(config["version_stdout"])
            raise SystemExit(0)
        if args == ["--help"]:
            sys.stdout.write(config["help_text"])
            raise SystemExit(0)
        if args == ["auth", "status"]:
            sys.stdout.write(config["auth_stdout"])
            raise SystemExit(0)
        sys.stderr.write("fake claude probe: unauthorized argv\\n")
        raise SystemExit(99)
        """
    )
    executable.write_text(script, encoding="utf-8")
    mode = executable.stat().st_mode
    executable.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _write_recording_claude(
    root: Path,
    *,
    stdout_payload: str | None = None,
    stderr_payload: str = "",
    returncode: int = 0,
) -> Path:
    """Write a fake Claude that records argv, env names, and a stdin digest.

    Environment *names* are taken from ``/proc/self/environ`` when it is
    available so that interpreter-side locale coercion (PEP 538), which
    mutates ``os.environ`` after exec, does not pollute the evidence of
    what the parent actually launched the child with. Only the value of
    ``CLAUDE_CONFIG_DIR`` is recorded; no other environment value and no
    stdin content is stored. When ``stdout_payload`` is ``None`` the
    fake prints the stdin SHA-256 digest.
    """
    fake_root = root / "claude-recorder"
    fake_root.mkdir(parents=True, exist_ok=True)
    executable = fake_root / "claude"
    (fake_root / "config.json").write_text(
        json.dumps(
            {
                "stdout_payload": stdout_payload,
                "stderr_payload": stderr_payload,
                "returncode": returncode,
            }
        ),
        encoding="utf-8",
    )
    script = textwrap.dedent(
        f"""\
        #!{sys.executable}
        import hashlib
        import json
        import os
        import sys
        from pathlib import Path


        def launched_env_names():
            proc_environ = Path("/proc/self/environ")
            try:
                raw = proc_environ.read_bytes()
            except OSError:
                return sorted(os.environ)
            names = []
            for entry in raw.split(b"\\0"):
                if entry:
                    names.append(entry.split(b"=", 1)[0].decode("utf-8", "replace"))
            return sorted(names)


        base = Path(__file__).resolve().parent
        config = json.loads((base / "config.json").read_text(encoding="utf-8"))
        stdin_bytes = sys.stdin.buffer.read()
        digest = hashlib.sha256(stdin_bytes).hexdigest()
        record = {{
            "argv": sys.argv[1:],
            "cwd": os.getcwd(),
            "env_names": launched_env_names(),
            "claude_config_dir": os.environ.get("CLAUDE_CONFIG_DIR"),
            "stdin_sha256": digest,
            "stdin_len": len(stdin_bytes),
        }}
        with (base / "invocations.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\\n")

        payload = config["stdout_payload"]
        sys.stdout.write(digest if payload is None else payload)
        sys.stderr.write(config["stderr_payload"])
        raise SystemExit(int(config["returncode"]))
        """
    )
    executable.write_text(script, encoding="utf-8")
    mode = executable.stat().st_mode
    executable.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _read_recorded(executable: Path) -> list[dict[str, object]]:
    log_path = executable.parent / "invocations.jsonl"
    if not log_path.exists():
        return []
    return [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines() if line]


def _forbid_process_execution(monkeypatch: pytest.MonkeyPatch) -> None:
    def _refuse(*args: object, **kwargs: object) -> object:
        raise AssertionError("process execution attempted during pure adapter work")

    monkeypatch.setattr(subprocess, "Popen", _refuse)
    monkeypatch.setattr(subprocess, "run", _refuse)
    monkeypatch.setattr(os, "system", _refuse)
    monkeypatch.setattr(invocation_module, "run_process", _refuse)
    monkeypatch.setattr(claude_module, "run_process", _refuse)


# ---------------------------------------------------------------------------
# Public API (Section 4)
# ---------------------------------------------------------------------------


def test_public_exports_added_without_removing_existing_names() -> None:
    exported = set(agents_package.__all__)

    assert {"ClaudeAdapter", "ClaudeAdapterError"} <= exported
    assert {
        "AgentAdapter",
        "AgentCommand",
        "AgentInvocationRequest",
        "AgentInvocationResult",
        "ClaudeCliStatus",
        "ClaudePreflightError",
        "CodexAdapter",
        "CodexAdapterError",
        "CodexCliStatus",
        "CodexPreflightError",
        "OpenAIStrictSchemaError",
        "invoke_agent",
        "materialize_codex_review_schema",
        "probe_claude_cli",
        "probe_codex_cli",
        "require_claude_subscription_ready",
        "require_codex_subscription_ready",
        "to_openai_strict_json_schema",
    } <= exported
    assert agents_package.ClaudeAdapter is claude_module.ClaudeAdapter
    assert agents_package.ClaudeAdapterError is claude_module.ClaudeAdapterError


# ---------------------------------------------------------------------------
# ClaudeCliStatus additive capability fields (Section 5)
# ---------------------------------------------------------------------------


def test_status_new_capability_fields_default_false() -> None:
    status = ClaudeCliStatus(
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
    )

    assert status.supports_safe_mode is False
    assert status.supports_allowed_tools is False


def test_probe_detects_safe_mode_and_allowed_tools(tmp_path: Path) -> None:
    executable = _write_probe_claude(
        tmp_path,
        help_flags=(
            "-p / --print",
            "--model MODEL",
            "--effort EFFORT",
            "--output-format FORMAT",
            "--json-schema SCHEMA",
            "--permission-prompts MODE",
            "--no-session-persistence",
            "--restricted",
            "--safe-mode",
            "--tools TOOLS",
            "--allowedTools LIST",
            "--disallowedTools LIST",
        ),
    )

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    assert status.supports_safe_mode is True
    assert status.supports_allowed_tools is True
    assert status.supports_bare is False


def test_probe_detects_hyphenated_allowed_tools_spelling(tmp_path: Path) -> None:
    executable = _write_probe_claude(
        tmp_path,
        help_flags=("-p / --print", "--allowed-tools LIST", "--disallowed-tools LIST"),
    )

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    assert status.supports_allowed_tools is True
    assert status.supports_disallowed_tools is True


def test_probe_does_not_confuse_disallowed_tools_with_allowed_tools(
    tmp_path: Path,
) -> None:
    executable = _write_probe_claude(
        tmp_path,
        help_flags=("-p / --print", "--disallowedTools LIST", "--disallowed-tools LIST"),
    )

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    assert status.supports_disallowed_tools is True
    assert status.supports_allowed_tools is False
    assert status.supports_safe_mode is False


# ---------------------------------------------------------------------------
# ClaudeAdapterError (Section 6)
# ---------------------------------------------------------------------------


def test_adapter_error_stores_bounded_reason() -> None:
    error = ClaudeAdapterError("request role does not match")

    assert error.reason == "request role does not match"
    assert "request role does not match" in str(error)
    assert len(str(error)) < 256
    assert not isinstance(error, ClaudePreflightError)


# ---------------------------------------------------------------------------
# Construction (Sections 7 and 24)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_construction_binds_role_and_satisfies_protocol(role: AgentRole) -> None:
    adapter = _make_adapter(role)

    assert isinstance(adapter, AgentAdapter)
    assert adapter.name == "claude"
    assert adapter.role is role
    assert adapter.model == "claude-sonnet-5"
    assert adapter.effort == "low"
    assert adapter.claude_config_dir is None


def test_adapter_is_frozen_and_slotted() -> None:
    adapter = _make_adapter(AgentRole.PLANNER)

    assert not hasattr(adapter, "__dict__")
    with pytest.raises(FrozenInstanceError):
        adapter.model = "hijacked"  # type: ignore[misc]
    with pytest.raises(FrozenInstanceError):
        adapter.role = AgentRole.REVIEWER  # type: ignore[misc]


@pytest.mark.parametrize("role", [AgentRole.SCRIBE])
def test_unsupported_role_rejected_at_construction(role: AgentRole) -> None:
    with pytest.raises(ClaudeAdapterError):
        _make_adapter(role)


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_construction_and_build_command_perform_no_io(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
    role: AgentRole,
) -> None:
    missing_executable = tmp_path / "absent" / "claude"
    missing_config_dir = tmp_path / "absent-config" / "claude"
    before = sorted(p.name for p in tmp_path.iterdir())
    _forbid_process_execution(monkeypatch)

    adapter = _make_adapter(
        role,
        status=_healthy_status(executable=str(missing_executable)),
        claude_config_dir=missing_config_dir,
    )
    command = adapter.build_command(_make_request(tmp_path, role=role))

    assert command.argv[0] == str(missing_executable)
    assert not missing_executable.exists()
    assert not missing_config_dir.exists()
    assert sorted(p.name for p in tmp_path.iterdir()) == before


# ---------------------------------------------------------------------------
# Preflight coupling and corrected capability contract (Sections 9 and 25)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_missing_safe_mode_capability_rejected(role: AgentRole) -> None:
    status = replace(_healthy_status(), supports_safe_mode=False)

    with pytest.raises(ClaudePreflightError) as exc_info:
        _make_adapter(role, status=status)

    assert exc_info.value.stage == "capabilities"


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_missing_allowed_tools_capability_rejected(role: AgentRole) -> None:
    status = replace(_healthy_status(), supports_allowed_tools=False)

    with pytest.raises(ClaudePreflightError) as exc_info:
        _make_adapter(role, status=status)

    assert exc_info.value.stage == "capabilities"


@pytest.mark.parametrize("field_name", _REQUIRED_CAPABILITY_FIELDS)
@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_each_required_capability_enforced(role: AgentRole, field_name: str) -> None:
    status = replace(_healthy_status(), **{field_name: False})

    with pytest.raises(ClaudePreflightError) as exc_info:
        _make_adapter(role, status=status)

    assert exc_info.value.stage == "capabilities"


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_supports_bare_false_does_not_prevent_construction(
    tmp_path: Path,
    role: AgentRole,
) -> None:
    status = replace(_healthy_status(), supports_bare=False)

    adapter = _make_adapter(role, status=status)
    command = adapter.build_command(_make_request(tmp_path, role=role))

    assert "--bare" not in command.argv


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_supports_permission_mode_not_required(role: AgentRole) -> None:
    status = replace(_healthy_status(), supports_permission_mode=False)

    adapter = _make_adapter(role, status=status)

    assert adapter.role is role


def test_reviewer_requires_json_schema_capability() -> None:
    status = replace(_healthy_status(), supports_json_schema=False)

    with pytest.raises(ClaudePreflightError) as exc_info:
        _make_adapter(AgentRole.REVIEWER, status=status)

    assert exc_info.value.stage == "capabilities"


@pytest.mark.parametrize("role", [AgentRole.PLANNER, AgentRole.IMPLEMENTER])
def test_writer_roles_do_not_require_json_schema_capability(role: AgentRole) -> None:
    status = replace(_healthy_status(), supports_json_schema=False)

    adapter = _make_adapter(role, status=status)

    assert adapter.role is role


def test_subscription_readiness_reused_and_not_wrapped() -> None:
    not_logged_in = replace(_healthy_status(), logged_in=False)
    with pytest.raises(ClaudePreflightError) as auth_info:
        _make_adapter(AgentRole.PLANNER, status=not_logged_in)
    assert auth_info.value.stage == "auth"
    assert not isinstance(auth_info.value, ClaudeAdapterError)

    console_auth = replace(_healthy_status(), auth_method="console")
    with pytest.raises(ClaudePreflightError) as sub_info:
        _make_adapter(AgentRole.PLANNER, status=console_auth)
    assert sub_info.value.stage == "subscription"

    bedrock = replace(_healthy_status(), api_provider="bedrock")
    with pytest.raises(ClaudePreflightError) as provider_info:
        _make_adapter(AgentRole.REVIEWER, status=bedrock)
    assert provider_info.value.stage == "subscription"

    free = replace(_healthy_status(), subscription_type="free")
    with pytest.raises(ClaudePreflightError) as free_info:
        _make_adapter(AgentRole.IMPLEMENTER, status=free)
    assert free_info.value.stage == "subscription"


# ---------------------------------------------------------------------------
# Model / effort validation (Section 10)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("bad_model", ["", "   ", "\t\n", "claude\x00-sonnet"])
def test_blank_or_nul_model_rejected(bad_model: str) -> None:
    with pytest.raises(ClaudeAdapterError):
        _make_adapter(AgentRole.PLANNER, model=bad_model)


@pytest.mark.parametrize("bad_effort", ["", "   ", "\t\n", "lo\x00w"])
def test_blank_or_nul_effort_rejected(bad_effort: str) -> None:
    with pytest.raises(ClaudeAdapterError):
        _make_adapter(AgentRole.PLANNER, effort=bad_effort)


def test_model_and_effort_passed_verbatim_without_alias_normalization(
    tmp_path: Path,
) -> None:
    adapter = _make_adapter(AgentRole.PLANNER, model="sonnet", effort="High")

    command = adapter.build_command(_make_request(tmp_path, role=AgentRole.PLANNER))

    assert _flag_value(command.argv, "--model") == "sonnet"
    assert _flag_value(command.argv, "--effort") == "High"
    assert "--fallback-model" not in command.argv


# ---------------------------------------------------------------------------
# Role mismatch (Section 26)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("adapter_role", _SUPPORTED_ROLES)
def test_role_mismatch_rejected_before_process_execution(
    tmp_path: Path,
    adapter_role: AgentRole,
) -> None:
    executable = _write_recording_claude(tmp_path)
    adapter = _make_adapter(adapter_role, status=_healthy_status(executable=str(executable)))

    for request_role in (*_SUPPORTED_ROLES, AgentRole.SCRIBE):
        if request_role is adapter_role:
            continue
        request = _make_request(tmp_path, role=request_role, prompt="mismatch-PROMPT")
        with pytest.raises(ClaudeAdapterError) as exc_info:
            adapter.build_command(request)
        assert "mismatch-PROMPT" not in str(exc_info.value)
        with pytest.raises(ClaudeAdapterError):
            invoke_agent(adapter, request, parent_env=_minimal_parent_env())

    assert _read_recorded(executable) == []


# ---------------------------------------------------------------------------
# Billing mode (Sections 8 and 27)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_subscription_only_billing_accepted(tmp_path: Path, role: AgentRole) -> None:
    executable = _write_recording_claude(tmp_path)
    adapter = _make_adapter(role, status=_healthy_status(executable=str(executable)))

    result = invoke_agent(
        adapter,
        _make_request(tmp_path, role=role),
        parent_env=_minimal_parent_env(),
    )

    assert result.billing_mode is BillingMode.SUBSCRIPTION_ONLY
    assert result.adapter_name == "claude"
    assert result.process.returncode == 0
    assert len(_read_recorded(executable)) == 1


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_api_allowed_billing_rejected_before_launch(tmp_path: Path, role: AgentRole) -> None:
    executable = _write_recording_claude(tmp_path)
    adapter = _make_adapter(role, status=_healthy_status(executable=str(executable)))
    request = _make_request(
        tmp_path,
        role=role,
        prompt="api-allowed-PROMPT",
        billing_mode=BillingMode.API_ALLOWED,
    )

    with pytest.raises(ClaudeAdapterError) as build_info:
        adapter.build_command(request)
    assert "api-allowed-PROMPT" not in str(build_info.value)

    with pytest.raises(ClaudeAdapterError):
        invoke_agent(adapter, request, parent_env=_minimal_parent_env())

    assert _read_recorded(executable) == []


# ---------------------------------------------------------------------------
# Exact argv (Sections 11-15 and 28)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("role", [AgentRole.PLANNER, AgentRole.IMPLEMENTER])
def test_writer_role_exact_argv(tmp_path: Path, role: AgentRole) -> None:
    adapter = _make_adapter(
        role,
        status=_healthy_status(executable="/fake/claude"),
        model="claude-sonnet-5",
        effort="low",
    )

    command = adapter.build_command(_make_request(tmp_path, role=role, prompt="writer-SECRET"))

    assert command.argv == _expected_argv(
        executable="/fake/claude",
        model="claude-sonnet-5",
        effort="low",
        tools=_WRITE_TOOLS,
        reviewer=False,
    )
    assert _flag_value(command.argv, "--tools") == _WRITE_TOOLS
    assert _flag_value(command.argv, "--allowedTools") == _WRITE_TOOLS
    assert _flag_value(command.argv, "--disallowedTools") == "mcp__*"
    assert "--json-schema" not in command.argv
    assert command.stdin_text == "writer-SECRET"
    for arg in command.argv:
        assert "writer-SECRET" not in arg


def test_reviewer_exact_argv(tmp_path: Path) -> None:
    adapter = _make_adapter(
        AgentRole.REVIEWER,
        status=_healthy_status(executable="/fake/claude"),
        model="claude-sonnet-5",
        effort="low",
    )

    command = adapter.build_command(
        _make_request(tmp_path, role=AgentRole.REVIEWER, prompt="reviewer-SECRET")
    )

    assert command.argv == _expected_argv(
        executable="/fake/claude",
        model="claude-sonnet-5",
        effort="low",
        tools=_READ_ONLY_TOOLS,
        reviewer=True,
    )
    tools = _flag_value(command.argv, "--tools")
    assert tools == _READ_ONLY_TOOLS
    assert _flag_value(command.argv, "--allowedTools") == _READ_ONLY_TOOLS
    assert "Write" not in tools.split(",")
    assert "Edit" not in tools.split(",")
    assert _flag_value(command.argv, "--disallowedTools") == "mcp__*"
    assert command.stdin_text == "reviewer-SECRET"
    for arg in command.argv:
        assert "reviewer-SECRET" not in arg


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_every_role_carries_mandatory_base_flags(tmp_path: Path, role: AgentRole) -> None:
    adapter = _make_adapter(role, model="configured-model", effort="configured-effort")

    command = adapter.build_command(_make_request(tmp_path, role=role))
    argv = command.argv

    assert argv[0] == "/fake/claude"
    assert argv[1 : 1 + len(_BASE_ARGV_TAIL)] == _BASE_ARGV_TAIL
    for flag in ("-p", "--safe-mode", "--restricted", "--no-session-persistence"):
        assert argv.count(flag) == 1
    assert _flag_value(argv, "--permission-prompts") == "none"
    assert _flag_value(argv, "--model") == "configured-model"
    assert _flag_value(argv, "--effort") == "configured-effort"
    assert _flag_value(argv, "--output-format") == "text"
    assert _flag_value(argv, "--disallowedTools") == "mcp__*"
    assert command.inherit_names == ()
    assert command.required_names == ("HOME", "PATH")


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_build_command_is_deterministic(tmp_path: Path, role: AgentRole) -> None:
    adapter = _make_adapter(role)
    request = _make_request(tmp_path, role=role)

    first = adapter.build_command(request)
    second = adapter.build_command(request)

    assert first.argv == second.argv
    assert dict(first.explicit_env) == dict(second.explicit_env)


# ---------------------------------------------------------------------------
# Forbidden argv and tool authority (Sections 21 and 34)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_forbidden_argv_elements_absent(tmp_path: Path, role: AgentRole) -> None:
    adapter = _make_adapter(role)

    command = adapter.build_command(_make_request(tmp_path, role=role))

    for forbidden in _FORBIDDEN_ARGV_ELEMENTS:
        assert forbidden not in command.argv


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_no_bash_worktree_or_default_tool_preset(tmp_path: Path, role: AgentRole) -> None:
    adapter = _make_adapter(role)

    command = adapter.build_command(_make_request(tmp_path, role=role))

    for arg in command.argv:
        assert "Bash" not in arg
        assert "--worktree" not in arg
    for flag in ("--tools", "--allowedTools"):
        listed = _flag_value(command.argv, flag).split(",")
        assert "default" not in listed
        assert "" not in listed
        for tool in _FORBIDDEN_TOOL_NAMES:
            assert tool not in listed


def test_adapter_exposes_no_extra_argument_escape_hatch() -> None:
    with pytest.raises(TypeError):
        ClaudeAdapter(  # type: ignore[call-arg]
            role=AgentRole.PLANNER,
            status=_healthy_status(),
            model="claude-sonnet-5",
            effort="low",
            extra_args=("--dangerously-skip-permissions",),
        )
    with pytest.raises(TypeError):
        ClaudeAdapter(  # type: ignore[call-arg]
            role=AgentRole.PLANNER,
            status=_healthy_status(),
            model="claude-sonnet-5",
            effort="low",
            tools=("Bash",),
        )


# ---------------------------------------------------------------------------
# Reviewer canonical schema (Sections 14 and 35)
# ---------------------------------------------------------------------------


def test_reviewer_schema_is_canonical_review_decision_schema(tmp_path: Path) -> None:
    adapter = _make_adapter(AgentRole.REVIEWER)

    command = adapter.build_command(_make_request(tmp_path, role=AgentRole.REVIEWER))
    raw_schema = _flag_value(command.argv, "--json-schema")

    assert json.loads(raw_schema) == _canonical_schema()
    assert raw_schema == json.dumps(
        _canonical_schema(),
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )
    assert "\n" not in raw_schema
    assert not Path(raw_schema).is_absolute()


def test_reviewer_schema_not_openai_strict_normalized() -> None:
    module_names = vars(claude_module)

    assert "to_openai_strict_json_schema" not in module_names
    assert "materialize_codex_review_schema" not in module_names


def test_reviewer_schema_contains_no_private_or_runtime_data(tmp_path: Path) -> None:
    prompt = "SCHEMA-PRIVACY-PROMPT user@example.invalid org_123"
    config_dir = tmp_path / "trusted-claude-config"
    adapter = _make_adapter(AgentRole.REVIEWER, claude_config_dir=config_dir)

    command = adapter.build_command(_make_request(tmp_path, role=AgentRole.REVIEWER, prompt=prompt))
    raw_schema = _flag_value(command.argv, "--json-schema")

    assert json.loads(raw_schema) == _canonical_schema()
    for sensitive in (
        prompt,
        "SCHEMA-PRIVACY-PROMPT",
        "@",
        "org_123",
        "claude.ai",
        "firstParty",
        str(tmp_path),
        str(config_dir),
        os.environ.get("HOME", "/nonexistent-home"),
        *(value for value in _AMBIENT_CREDENTIAL_ENV.values() if len(value) > 1),
    ):
        assert sensitive not in raw_schema


# ---------------------------------------------------------------------------
# Reviewer text-output canonical contract (Sections 15 and 29)
# ---------------------------------------------------------------------------


def test_reviewer_stdout_parses_directly_as_review_decision(tmp_path: Path) -> None:
    decision = _review_decision()
    executable = _write_recording_claude(tmp_path, stdout_payload=decision.model_dump_json())
    adapter = _make_adapter(
        AgentRole.REVIEWER,
        status=_healthy_status(executable=str(executable)),
    )

    result = invoke_agent(
        adapter,
        _make_request(tmp_path, role=AgentRole.REVIEWER, prompt="review-prompt"),
        parent_env=_minimal_parent_env(),
    )

    assert result.process.returncode == 0
    restored = ReviewDecision.model_validate_json(result.process.stdout)
    assert restored == decision
    assert _flag_value(result.process.argv, "--output-format") == "text"

    records = _read_recorded(executable)
    assert len(records) == 1
    recorded_argv = records[0]["argv"]
    assert isinstance(recorded_argv, list)
    assert "--output-format" in recorded_argv
    assert recorded_argv[recorded_argv.index("--output-format") + 1] == "text"


# ---------------------------------------------------------------------------
# Nonzero exit with stdout is not success (Sections 16 and 30)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_nonzero_exit_with_stdout_is_not_reclassified(tmp_path: Path, role: AgentRole) -> None:
    executable = _write_recording_claude(
        tmp_path,
        stdout_payload=_NOT_LOGGED_IN_STDOUT,
        returncode=1,
    )
    adapter = _make_adapter(role, status=_healthy_status(executable=str(executable)))

    result = invoke_agent(
        adapter,
        _make_request(tmp_path, role=role),
        parent_env=_minimal_parent_env(),
    )

    assert result.process.returncode == 1
    assert result.process.stdout == _NOT_LOGGED_IN_STDOUT
    assert result.adapter_name == "claude"


# ---------------------------------------------------------------------------
# Private stdin (Section 31)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_prompt_travels_only_through_private_stdin(tmp_path: Path, role: AgentRole) -> None:
    executable = _write_recording_claude(tmp_path)
    adapter = _make_adapter(role, status=_healthy_status(executable=str(executable)))
    prompt = "LOCKSTEP_CLAUDE_PROMPT_SENTINEL\nzweite Zeile — λ → ✓\n第三行\n"
    expected_hash = hashlib.sha256(prompt.encode("utf-8")).hexdigest()
    request = _make_request(tmp_path, role=role, prompt=prompt)

    command = adapter.build_command(request)
    assert command.stdin_text == prompt
    for arg in command.argv:
        assert "LOCKSTEP_CLAUDE_PROMPT_SENTINEL" not in arg
    for key, value in command.explicit_env.items():
        assert "LOCKSTEP_CLAUDE_PROMPT_SENTINEL" not in key
        assert "LOCKSTEP_CLAUDE_PROMPT_SENTINEL" not in value
    assert "LOCKSTEP_CLAUDE_PROMPT_SENTINEL" not in repr(command)
    assert "LOCKSTEP_CLAUDE_PROMPT_SENTINEL" not in repr(adapter)

    result = invoke_agent(adapter, request, parent_env=_minimal_parent_env())

    assert result.process.returncode == 0
    assert result.process.stdout == expected_hash
    for arg in result.process.argv:
        assert "LOCKSTEP_CLAUDE_PROMPT_SENTINEL" not in arg
    assert "LOCKSTEP_CLAUDE_PROMPT_SENTINEL" not in repr(result)

    records = _read_recorded(executable)
    assert len(records) == 1
    assert records[0]["stdin_sha256"] == expected_hash
    assert records[0]["stdin_len"] == len(prompt.encode("utf-8"))
    assert records[0]["cwd"] == str(tmp_path.resolve())
    recorded_argv = records[0]["argv"]
    assert isinstance(recorded_argv, list)
    for arg in recorded_argv:
        assert "LOCKSTEP_CLAUDE_PROMPT_SENTINEL" not in arg


# ---------------------------------------------------------------------------
# Environment credentials (Sections 17 and 32)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_default_command_requests_no_ambient_credentials(tmp_path: Path, role: AgentRole) -> None:
    adapter = _make_adapter(role)

    command = adapter.build_command(_make_request(tmp_path, role=role))

    assert command.inherit_names == ()
    assert command.required_names == ("HOME", "PATH")
    assert dict(command.explicit_env) == {}


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_ambient_credentials_and_config_dir_never_reach_child(
    tmp_path: Path,
    role: AgentRole,
) -> None:
    executable = _write_recording_claude(tmp_path)
    attacker_config = tmp_path / "attacker-claude-config"
    adapter = _make_adapter(role, status=_healthy_status(executable=str(executable)))
    parent_env = {
        **_minimal_parent_env(),
        **_AMBIENT_CREDENTIAL_ENV,
        "CLAUDE_CONFIG_DIR": str(attacker_config),
    }

    result = invoke_agent(
        adapter,
        _make_request(tmp_path, role=role),
        parent_env=parent_env,
    )

    assert result.process.returncode == 0
    records = _read_recorded(executable)
    assert len(records) == 1
    env_names = records[0]["env_names"]
    assert isinstance(env_names, list)
    assert "HOME" in env_names
    assert "PATH" in env_names
    for forbidden in (*_AMBIENT_CREDENTIAL_ENV, "CLAUDE_CONFIG_DIR"):
        assert forbidden not in env_names
    assert records[0]["claude_config_dir"] is None


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_explicit_trusted_config_dir_is_only_config_reaching_child(
    tmp_path: Path,
    role: AgentRole,
) -> None:
    executable = _write_recording_claude(tmp_path)
    trusted = tmp_path / "trusted-claude-config"
    trusted.mkdir()
    attacker = tmp_path / "attacker-claude-config"
    attacker.mkdir()
    adapter = _make_adapter(
        role,
        status=_healthy_status(executable=str(executable)),
        claude_config_dir=trusted,
    )

    command = adapter.build_command(_make_request(tmp_path, role=role))
    assert dict(command.explicit_env) == {"CLAUDE_CONFIG_DIR": str(trusted.resolve())}
    assert command.inherit_names == ()

    parent_env = {
        **_minimal_parent_env(),
        **_AMBIENT_CREDENTIAL_ENV,
        "CLAUDE_CONFIG_DIR": str(attacker),
    }
    result = invoke_agent(
        adapter,
        _make_request(tmp_path, role=role),
        parent_env=parent_env,
    )

    assert result.process.returncode == 0
    records = _read_recorded(executable)
    assert len(records) == 1
    env_names = records[0]["env_names"]
    assert isinstance(env_names, list)
    for forbidden in _AMBIENT_CREDENTIAL_ENV:
        assert forbidden not in env_names
    assert records[0]["claude_config_dir"] == str(trusted.resolve())
    assert records[0]["claude_config_dir"] != str(attacker)


def test_relative_config_dir_resolved_to_absolute(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.chdir(tmp_path)
    adapter = _make_adapter(AgentRole.PLANNER, claude_config_dir=Path("rel-claude-config"))

    command = adapter.build_command(_make_request(tmp_path, role=AgentRole.PLANNER))

    configured = command.explicit_env["CLAUDE_CONFIG_DIR"]
    assert Path(configured).is_absolute()
    assert configured == str((tmp_path / "rel-claude-config").resolve())


# ---------------------------------------------------------------------------
# Exact projected HOME/PATH parent (Sections 18 and 33)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("role", _SUPPORTED_ROLES)
def test_projected_home_path_parent_yields_exact_child_environment(
    tmp_path: Path,
    role: AgentRole,
) -> None:
    executable = _write_recording_claude(tmp_path)
    adapter = _make_adapter(role, status=_healthy_status(executable=str(executable)))
    ambient_parent = {
        **_minimal_parent_env(),
        **_AMBIENT_CREDENTIAL_ENV,
        "LANG": "C.UTF-8",
        "USER": "someone",
        "TMPDIR": str(tmp_path),
    }
    projected_parent = {
        "HOME": ambient_parent["HOME"],
        "PATH": ambient_parent["PATH"],
    }

    result = invoke_agent(
        adapter,
        _make_request(tmp_path, role=role),
        parent_env=projected_parent,
    )

    assert result.process.returncode == 0
    records = _read_recorded(executable)
    assert len(records) == 1
    assert records[0]["env_names"] == ["HOME", "PATH"]


def test_missing_home_or_path_in_parent_rejected_before_launch(tmp_path: Path) -> None:
    executable = _write_recording_claude(tmp_path)
    adapter = _make_adapter(
        AgentRole.PLANNER,
        status=_healthy_status(executable=str(executable)),
    )
    full_parent = _minimal_parent_env()

    for missing in ("HOME", "PATH"):
        parent = {k: v for k, v in full_parent.items() if k != missing}
        with pytest.raises(EnvironmentPolicyError) as exc_info:
            invoke_agent(
                adapter,
                _make_request(tmp_path, role=AgentRole.PLANNER),
                parent_env=parent,
            )
        assert missing in str(exc_info.value)

    assert _read_recorded(executable) == []
