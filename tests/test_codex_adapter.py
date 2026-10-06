import hashlib
import json
import os
import stat
import sys
import textwrap
from dataclasses import replace
from pathlib import Path

import pytest

from lockstep.agents import (
    AgentAdapter,
    AgentInvocationRequest,
    CodexAdapter,
    CodexAdapterError,
    CodexCliStatus,
    CodexPreflightError,
    invoke_agent,
    probe_codex_cli,
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

_FORBIDDEN_FLAGS: tuple[str, ...] = (
    "--dangerously-bypass-approvals-and-sandbox",
    "--worktree",
    "--skip-git-repo-check",
    "--ask-for-approval",
    "-a",
    "-C",
    "--cd",
)

_HEALTHY_DOCTOR_STDOUT: str = json.dumps(
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


def _healthy_status(executable: str = "/fake/codex") -> CodexCliStatus:
    return CodexCliStatus(
        executable=executable,
        version="codex-cli test-version",
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


def _minimal_parent_env() -> dict[str, str]:
    return {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    }


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


def _build_exec_help(flags: tuple[str, ...]) -> str:
    lines = ["Usage: codex exec [OPTIONS] [PROMPT]", "", "Options:"]
    lines.extend(f"  {flag}  option description" for flag in flags)
    return "\n".join(lines) + "\n"


def _write_probe_codex(root: Path, *, exec_help_text: str) -> Path:
    fake_root = root / "codex-probe-fake"
    fake_root.mkdir(parents=True, exist_ok=True)
    executable = fake_root / "codex"
    config_path = fake_root / "config.json"
    config_path.write_text(
        json.dumps(
            {
                "version": "codex-cli test-version",
                "exec_help_text": exec_help_text,
                "doctor_stdout": _HEALTHY_DOCTOR_STDOUT,
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

        if args == ["--version"]:
            sys.stdout.write(config["version"] + "\\n")
            raise SystemExit(0)
        if args == ["exec", "--help"]:
            sys.stdout.write(config["exec_help_text"])
            raise SystemExit(0)
        if args == ["doctor", "--json"]:
            sys.stdout.write(config["doctor_stdout"])
            raise SystemExit(0)
        sys.stderr.write("fake codex: unexpected argv " + json.dumps(args) + "\\n")
        raise SystemExit(99)
        """
    )
    executable.write_text(script, encoding="utf-8")
    mode = executable.stat().st_mode
    executable.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _write_recording_codex(
    root: Path,
    *,
    mode: str = "hash-stdin",
    stdout_payload: str = "",
) -> Path:
    fake_root = root / "codex-recorder"
    fake_root.mkdir(parents=True, exist_ok=True)
    executable = fake_root / "codex"
    config_path = fake_root / "config.json"
    config_path.write_text(
        json.dumps({"mode": mode, "stdout_payload": stdout_payload}),
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

        base = Path(__file__).resolve().parent
        config = json.loads((base / "config.json").read_text(encoding="utf-8"))
        argv = sys.argv[1:]
        stdin_bytes = sys.stdin.buffer.read()
        digest = hashlib.sha256(stdin_bytes).hexdigest()
        record = {{
            "argv": argv,
            "env": dict(os.environ),
            "stdin_sha256": digest,
            "stdin_len": len(stdin_bytes),
        }}
        with (base / "invocations.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\\n")
        if config["mode"] == "hash-stdin":
            sys.stdout.write(digest)
        elif config["mode"] == "stdout-payload":
            sys.stdout.write(config["stdout_payload"])
        else:
            sys.stderr.write("fake codex: unknown mode\\n")
            raise SystemExit(2)
        raise SystemExit(0)
        """
    )
    executable.write_text(script, encoding="utf-8")
    mode_bits = executable.stat().st_mode
    executable.chmod(mode_bits | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _read_recorded(executable: Path) -> list[dict[str, object]]:
    log_path = executable.parent / "invocations.jsonl"
    if not log_path.exists():
        return []
    return [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines() if line]


# ---------------------------------------------------------------------------
# Capability probe additions (Section 36)
# ---------------------------------------------------------------------------


def test_probe_detects_new_ignore_rules_and_output_schema_flags(tmp_path: Path) -> None:
    help_text = _build_exec_help(
        (
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--sandbox",
            "--color",
            "--output-schema",
        )
    )
    executable = _write_probe_codex(tmp_path, exec_help_text=help_text)

    status = probe_codex_cli(
        codex_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    assert status.supports_exec_ignore_rules is True
    assert status.supports_exec_output_schema is True
    assert status.supports_exec_ephemeral is True
    assert status.supports_exec_ignore_user_config is True
    assert status.supports_exec_sandbox is True
    assert status.supports_exec_color is True


def test_probe_reports_missing_ignore_rules_and_output_schema_flags(
    tmp_path: Path,
) -> None:
    help_text = _build_exec_help(
        (
            "--ephemeral",
            "--ignore-user-config",
            "--sandbox",
            "--color",
        )
    )
    executable = _write_probe_codex(tmp_path, exec_help_text=help_text)

    status = probe_codex_cli(
        codex_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    assert status.supports_exec_ignore_rules is False
    assert status.supports_exec_output_schema is False


# ---------------------------------------------------------------------------
# Structural adapter protocol (Section 37)
# ---------------------------------------------------------------------------


def test_codex_adapter_satisfies_agent_adapter_protocol() -> None:
    adapter = CodexAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_status(),
        model="gpt-5",
        reasoning_effort="medium",
    )

    assert isinstance(adapter, AgentAdapter)
    assert adapter.name == "codex"


# ---------------------------------------------------------------------------
# Planner / Implementer / Reviewer commands (Sections 38-40)
# ---------------------------------------------------------------------------


def test_planner_command_argv_matches_deterministic_sequence(tmp_path: Path) -> None:
    adapter = CodexAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_status(executable="/fake/codex"),
        model="gpt-5-planner",
        reasoning_effort="medium",
    )
    request = _make_request(
        tmp_path,
        role=AgentRole.PLANNER,
        prompt="planner-prompt-SECRET",
    )

    command = adapter.build_command(request)

    expected = (
        "/fake/codex",
        "exec",
        "--ephemeral",
        "--ignore-user-config",
        "--ignore-rules",
        "--json",
        "--color",
        "never",
        "--sandbox",
        "workspace-write",
        "--model",
        "gpt-5-planner",
        "-c",
        'model_reasoning_effort="medium"',
        "-c",
        "project_doc_max_bytes=0",
        "-c",
        "skills.include_instructions=false",
        "-",
    )

    assert command.argv == expected
    assert command.stdin_text == "planner-prompt-SECRET"
    assert command.inherit_names == ()
    assert command.required_names == ("HOME", "PATH")

    for arg in command.argv:
        assert "planner-prompt-SECRET" not in arg
    for forbidden in _FORBIDDEN_FLAGS:
        assert forbidden not in command.argv
    assert "--output-schema" not in command.argv


def test_implementer_command_matches_planner_shape_with_workspace_write(
    tmp_path: Path,
) -> None:
    adapter = CodexAdapter(
        role=AgentRole.IMPLEMENTER,
        status=_healthy_status(executable="/fake/codex"),
        model="gpt-5-implementer",
        reasoning_effort="high",
    )
    request = _make_request(
        tmp_path,
        role=AgentRole.IMPLEMENTER,
        prompt="implementer-prompt-SECRET",
    )

    command = adapter.build_command(request)

    expected = (
        "/fake/codex",
        "exec",
        "--ephemeral",
        "--ignore-user-config",
        "--ignore-rules",
        "--json",
        "--color",
        "never",
        "--sandbox",
        "workspace-write",
        "--model",
        "gpt-5-implementer",
        "-c",
        'model_reasoning_effort="high"',
        "-c",
        "project_doc_max_bytes=0",
        "-c",
        "skills.include_instructions=false",
        "-",
    )

    assert command.argv == expected
    assert command.stdin_text == "implementer-prompt-SECRET"
    assert "--output-schema" not in command.argv
    for arg in command.argv:
        assert "implementer-prompt-SECRET" not in arg
    for forbidden in _FORBIDDEN_FLAGS:
        assert forbidden not in command.argv


def test_reviewer_command_includes_output_schema_and_read_only_sandbox(
    tmp_path: Path,
) -> None:
    schema_path = tmp_path / "review-schema.json"
    schema_path.write_text("{}", encoding="utf-8")
    adapter = CodexAdapter(
        role=AgentRole.REVIEWER,
        status=_healthy_status(executable="/fake/codex"),
        model="gpt-5-reviewer",
        reasoning_effort="high",
        review_output_schema_path=schema_path,
    )
    request = _make_request(
        tmp_path,
        role=AgentRole.REVIEWER,
        prompt="reviewer-prompt-SECRET",
    )

    command = adapter.build_command(request)

    assert command.argv[0] == "/fake/codex"
    assert command.argv[1] == "exec"
    assert command.argv[-1] == "-"
    assert "--ephemeral" in command.argv
    assert "--ignore-user-config" in command.argv
    assert "--ignore-rules" in command.argv

    sandbox_index = command.argv.index("--sandbox")
    assert command.argv[sandbox_index + 1] == "read-only"

    color_index = command.argv.index("--color")
    assert command.argv[color_index + 1] == "never"

    model_index = command.argv.index("--model")
    assert command.argv[model_index + 1] == "gpt-5-reviewer"

    schema_index = command.argv.index("--output-schema")
    assert command.argv[schema_index + 1] == str(schema_path.resolve())

    dash_c_positions = [i for i, tok in enumerate(command.argv) if tok == "-c"]
    assert len(dash_c_positions) == 3
    assert command.argv[dash_c_positions[0] + 1] == 'model_reasoning_effort="high"'
    assert command.argv[dash_c_positions[1] + 1] == "project_doc_max_bytes=0"
    assert command.argv[dash_c_positions[2] + 1] == "skills.include_instructions=false"

    assert command.stdin_text == "reviewer-prompt-SECRET"
    for arg in command.argv:
        assert "reviewer-prompt-SECRET" not in arg
    for forbidden in _FORBIDDEN_FLAGS:
        assert forbidden not in command.argv


# ---------------------------------------------------------------------------
# Reviewer schema is role-specific (Section 41)
# ---------------------------------------------------------------------------


def test_reviewer_without_schema_rejected() -> None:
    with pytest.raises(CodexAdapterError):
        CodexAdapter(
            role=AgentRole.REVIEWER,
            status=_healthy_status(),
            model="gpt-5",
            reasoning_effort="high",
        )


def test_planner_with_review_schema_rejected(tmp_path: Path) -> None:
    schema_path = tmp_path / "schema.json"
    schema_path.write_text("{}", encoding="utf-8")

    with pytest.raises(CodexAdapterError):
        CodexAdapter(
            role=AgentRole.PLANNER,
            status=_healthy_status(),
            model="gpt-5",
            reasoning_effort="medium",
            review_output_schema_path=schema_path,
        )


def test_implementer_with_review_schema_rejected(tmp_path: Path) -> None:
    schema_path = tmp_path / "schema.json"
    schema_path.write_text("{}", encoding="utf-8")

    with pytest.raises(CodexAdapterError):
        CodexAdapter(
            role=AgentRole.IMPLEMENTER,
            status=_healthy_status(),
            model="gpt-5",
            reasoning_effort="medium",
            review_output_schema_path=schema_path,
        )


# ---------------------------------------------------------------------------
# Role mismatch (Section 42)
# ---------------------------------------------------------------------------


def test_role_mismatch_between_adapter_and_request_rejected(tmp_path: Path) -> None:
    adapter = CodexAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_status(),
        model="gpt-5",
        reasoning_effort="medium",
    )
    request = _make_request(tmp_path, role=AgentRole.IMPLEMENTER)

    with pytest.raises(CodexAdapterError):
        adapter.build_command(request)


# ---------------------------------------------------------------------------
# Scribe rejected (Section 43)
# ---------------------------------------------------------------------------


def test_scribe_role_rejected_at_construction() -> None:
    with pytest.raises(CodexAdapterError):
        CodexAdapter(
            role=AgentRole.SCRIBE,
            status=_healthy_status(),
            model="gpt-5",
            reasoning_effort="medium",
        )


# ---------------------------------------------------------------------------
# API_ALLOWED billing rejected (Section 44)
# ---------------------------------------------------------------------------


def test_api_allowed_billing_mode_rejected_before_launch(tmp_path: Path) -> None:
    adapter = CodexAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_status(),
        model="gpt-5",
        reasoning_effort="medium",
    )
    request = _make_request(
        tmp_path,
        role=AgentRole.PLANNER,
        billing_mode=BillingMode.API_ALLOWED,
    )

    with pytest.raises(CodexAdapterError):
        adapter.build_command(request)


# ---------------------------------------------------------------------------
# Unhealthy subscription evidence rejected at construction (Section 45)
# ---------------------------------------------------------------------------


def test_stored_api_key_rejected_at_adapter_construction() -> None:
    status = replace(_healthy_status(), stored_api_key=True)

    with pytest.raises(CodexPreflightError) as exc_info:
        CodexAdapter(
            role=AgentRole.PLANNER,
            status=status,
            model="gpt-5",
            reasoning_effort="medium",
        )

    assert exc_info.value.stage == "auth"


def test_non_chatgpt_stored_auth_mode_rejected_at_adapter_construction() -> None:
    status = replace(_healthy_status(), stored_auth_mode="apikey")

    with pytest.raises(CodexPreflightError) as exc_info:
        CodexAdapter(
            role=AgentRole.PLANNER,
            status=status,
            model="gpt-5",
            reasoning_effort="medium",
        )

    assert exc_info.value.stage == "auth"


# ---------------------------------------------------------------------------
# Isolation and Reviewer schema capabilities (Sections 46 and 47)
# ---------------------------------------------------------------------------


def test_missing_ignore_rules_capability_rejected_at_construction() -> None:
    status = replace(_healthy_status(), supports_exec_ignore_rules=False)

    with pytest.raises(CodexPreflightError) as exc_info:
        CodexAdapter(
            role=AgentRole.PLANNER,
            status=status,
            model="gpt-5",
            reasoning_effort="medium",
        )

    assert exc_info.value.stage == "capabilities"


def test_reviewer_without_output_schema_capability_rejected(tmp_path: Path) -> None:
    schema_path = tmp_path / "schema.json"
    schema_path.write_text("{}", encoding="utf-8")
    status = replace(_healthy_status(), supports_exec_output_schema=False)

    with pytest.raises(CodexPreflightError) as exc_info:
        CodexAdapter(
            role=AgentRole.REVIEWER,
            status=status,
            model="gpt-5",
            reasoning_effort="high",
            review_output_schema_path=schema_path,
        )

    assert exc_info.value.stage == "capabilities"


def test_planner_does_not_require_output_schema_capability() -> None:
    status = replace(_healthy_status(), supports_exec_output_schema=False)

    adapter = CodexAdapter(
        role=AgentRole.PLANNER,
        status=status,
        model="gpt-5",
        reasoning_effort="medium",
    )

    assert adapter.role is AgentRole.PLANNER


# ---------------------------------------------------------------------------
# Explicit model / reasoning effort validation (Sections 48 and 49)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("bad_model", ["", "   ", "\t\n", "gpt\x00-5"])
def test_blank_or_nul_model_rejected(bad_model: str) -> None:
    with pytest.raises(CodexAdapterError):
        CodexAdapter(
            role=AgentRole.PLANNER,
            status=_healthy_status(),
            model=bad_model,
            reasoning_effort="medium",
        )


@pytest.mark.parametrize("bad_effort", ["", "   ", "\t\n", "med\x00ium"])
def test_blank_or_nul_reasoning_effort_rejected(bad_effort: str) -> None:
    with pytest.raises(CodexAdapterError):
        CodexAdapter(
            role=AgentRole.PLANNER,
            status=_healthy_status(),
            model="gpt-5",
            reasoning_effort=bad_effort,
        )


# ---------------------------------------------------------------------------
# Reasoning config cannot split argv (Section 50)
# ---------------------------------------------------------------------------


def test_reasoning_effort_special_chars_stay_in_single_argv_element(
    tmp_path: Path,
) -> None:
    tricky = 'low"; malicious="true'
    adapter = CodexAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_status(),
        model="gpt-5",
        reasoning_effort=tricky,
    )
    request = _make_request(tmp_path, role=AgentRole.PLANNER)

    command = adapter.build_command(request)

    dash_c_positions = [i for i, tok in enumerate(command.argv) if tok == "-c"]
    assert len(dash_c_positions) == 3

    value_index = dash_c_positions[0] + 1
    value = command.argv[value_index]
    assert value.startswith("model_reasoning_effort=")
    assert "malicious" in value

    for i, arg in enumerate(command.argv):
        if i == value_index:
            continue
        assert "malicious" not in arg


# ---------------------------------------------------------------------------
# CODEX_HOME behaviour (Sections 51 and 52)
# ---------------------------------------------------------------------------


def test_configured_codex_home_appears_in_explicit_env_only(tmp_path: Path) -> None:
    codex_home = tmp_path / "trusted-codex-home"
    codex_home.mkdir()
    adapter = CodexAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_status(),
        model="gpt-5",
        reasoning_effort="medium",
        codex_home=codex_home,
    )
    request = _make_request(tmp_path, role=AgentRole.PLANNER)

    command = adapter.build_command(request)

    assert dict(command.explicit_env) == {"CODEX_HOME": str(codex_home.resolve())}
    assert command.inherit_names == ()
    assert command.required_names == ("HOME", "PATH")

    explicit = dict(command.explicit_env)
    for forbidden_env in (
        "OPENAI_API_KEY",
        "CODEX_API_KEY",
        "CODEX_ACCESS_TOKEN",
        "OPENAI_BASE_URL",
    ):
        assert forbidden_env not in explicit
        assert forbidden_env not in command.inherit_names


def test_default_codex_home_omits_explicit_codex_home(tmp_path: Path) -> None:
    adapter = CodexAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_status(),
        model="gpt-5",
        reasoning_effort="medium",
    )
    request = _make_request(tmp_path, role=AgentRole.PLANNER)

    command = adapter.build_command(request)

    assert "CODEX_HOME" not in dict(command.explicit_env)
    assert "CODEX_HOME" not in command.inherit_names


# ---------------------------------------------------------------------------
# End-to-end composition through invoke_agent (Section 53)
# ---------------------------------------------------------------------------


def test_invoke_agent_ships_prompt_via_private_stdin_without_ambient_credentials(
    tmp_path: Path,
) -> None:
    executable = _write_recording_codex(tmp_path, mode="hash-stdin")
    trusted_home = tmp_path / "trusted-codex-home"
    trusted_home.mkdir()
    attacker_home = tmp_path / "attacker-codex-home"
    attacker_home.mkdir()

    adapter = CodexAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_status(executable=str(executable)),
        model="gpt-5",
        reasoning_effort="medium",
        codex_home=trusted_home,
    )
    prompt = "LOCKSTEP_PROMPT_SENTINEL\nmultiline λ\n"
    expected_hash = hashlib.sha256(prompt.encode("utf-8")).hexdigest()

    parent_env = {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "OPENAI_API_KEY": "sk-openai-should-not-leak",
        "CODEX_API_KEY": "sk-codex-should-not-leak",
        "CODEX_ACCESS_TOKEN": "codex-token-should-not-leak",
        "OPENAI_BASE_URL": "https://parent-openai.invalid",
        "CODEX_HOME": str(attacker_home),
    }

    result = invoke_agent(
        adapter,
        _make_request(tmp_path, role=AgentRole.PLANNER, prompt=prompt),
        parent_env=parent_env,
    )

    assert result.process.returncode == 0
    assert result.process.stdout == expected_hash

    for arg in result.process.argv:
        assert prompt not in arg
    assert prompt not in repr(result)

    records = _read_recorded(executable)
    assert len(records) == 1
    child_env = records[0]["env"]
    assert isinstance(child_env, dict)
    assert records[0]["stdin_sha256"] == expected_hash
    assert child_env["CODEX_HOME"] == str(trusted_home.resolve())
    assert child_env["CODEX_HOME"] != str(attacker_home)
    for forbidden_name in (
        "OPENAI_API_KEY",
        "CODEX_API_KEY",
        "CODEX_ACCESS_TOKEN",
        "OPENAI_BASE_URL",
    ):
        assert forbidden_name not in child_env


# ---------------------------------------------------------------------------
# Reviewer canonical artifact compatibility (Section 54)
# ---------------------------------------------------------------------------


def test_reviewer_stdout_parses_directly_as_review_decision(tmp_path: Path) -> None:
    schema_path = tmp_path / "review-schema.json"
    schema_path.write_text("{}", encoding="utf-8")

    decision = ReviewDecision(
        phase_id=PhaseId.model_validate("05"),
        subphase_id=SubphaseId.model_validate("03"),
        attempt=AttemptNumber.model_validate(1),
        verdict=ReviewVerdict.APPROVE,
        summary="approved",
    )
    payload = decision.model_dump_json()

    executable = _write_recording_codex(
        tmp_path,
        mode="stdout-payload",
        stdout_payload=payload,
    )

    adapter = CodexAdapter(
        role=AgentRole.REVIEWER,
        status=_healthy_status(executable=str(executable)),
        model="gpt-5",
        reasoning_effort="high",
        review_output_schema_path=schema_path,
    )

    result = invoke_agent(
        adapter,
        _make_request(tmp_path, role=AgentRole.REVIEWER, prompt="review-prompt"),
        parent_env=_minimal_parent_env(),
    )

    assert result.process.returncode == 0
    restored = ReviewDecision.model_validate_json(result.process.stdout)
    assert restored == decision
    assert "--json" in result.process.argv


# ---------------------------------------------------------------------------
# Forbidden provider flags absent across all supported roles (Section 55)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "role",
    [AgentRole.PLANNER, AgentRole.IMPLEMENTER, AgentRole.REVIEWER],
)
def test_forbidden_provider_flags_absent_from_argv(
    tmp_path: Path,
    role: AgentRole,
) -> None:
    kwargs: dict[str, object] = {
        "role": role,
        "status": _healthy_status(),
        "model": "gpt-5",
        "reasoning_effort": "medium",
    }
    if role is AgentRole.REVIEWER:
        schema_path = tmp_path / "schema.json"
        schema_path.write_text("{}", encoding="utf-8")
        kwargs["review_output_schema_path"] = schema_path

    adapter = CodexAdapter(**kwargs)  # type: ignore[arg-type]
    request = _make_request(tmp_path, role=role)

    command = adapter.build_command(request)

    for forbidden in _FORBIDDEN_FLAGS:
        assert forbidden not in command.argv
