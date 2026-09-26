import json
import os
import stat
import sys
import textwrap
from pathlib import Path

import pytest

from lockstep.agents import (
    ClaudeCliStatus,
    ClaudePreflightError,
    probe_claude_cli,
    require_claude_subscription_ready,
)
from lockstep.process import ProcessLaunchError

_HELP_ALL_FLAGS: tuple[str, ...] = (
    "-p / --print",
    "--model MODEL",
    "--effort EFFORT",
    "--output-format json",
    "--json-schema PATH",
    "--permission-mode default",
    "--permission-prompts none",
    "--no-session-persistence",
    "--restricted",
    "--bare",
    "--tools TOOLS",
    "--disallowedTools LIST",
)


def _build_help_text(lines: tuple[str, ...] = _HELP_ALL_FLAGS) -> str:
    header = ["Usage: claude [OPTIONS] [PROMPT]", "", "Options:"]
    header.extend(f"  {line}  option description" for line in lines)
    return "\n".join(header) + "\n"


def _build_auth_stdout(
    *,
    logged_in: bool = True,
    auth_method: object = "claude.ai",
    api_provider: object = "firstParty",
    subscription_type: object = "max",
    extra: dict[str, object] | None = None,
) -> str:
    payload: dict[str, object] = {
        "loggedIn": logged_in,
        "authMethod": auth_method,
        "apiProvider": api_provider,
        "subscriptionType": subscription_type,
    }
    if extra is not None:
        payload.update(extra)
    return json.dumps(payload)


def _write_fake_claude(
    root: Path,
    *,
    version_stdout: str = "2.1.259 (Claude Code)\n",
    version_returncode: int = 0,
    help_text: str | None = None,
    help_returncode: int = 0,
    auth_stdout: str | None = None,
    auth_returncode: int = 0,
) -> Path:
    fake_root = root / "claude-fake"
    fake_root.mkdir(parents=True, exist_ok=True)

    executable = fake_root / "claude"
    config_path = fake_root / "config.json"

    if help_text is None:
        help_text = _build_help_text()
    if auth_stdout is None:
        auth_stdout = _build_auth_stdout()

    config_path.write_text(
        json.dumps(
            {
                "version_stdout": version_stdout,
                "version_returncode": version_returncode,
                "help_text": help_text,
                "help_returncode": help_returncode,
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
        config = json.loads((base / "config.json").read_text(encoding="utf-8"))
        args = sys.argv[1:]

        with (base / "invocations.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(
                json.dumps(
                    {{
                        "argv": args,
                        "cwd": os.getcwd(),
                        "env": dict(os.environ),
                    }}
                )
                + "\\n"
            )

        for token in args:
            if token in ("-p", "--print"):
                sys.stderr.write(
                    "fake claude: refusing inference invocation "
                    + json.dumps(args) + "\\n"
                )
                raise SystemExit(97)

        if args == ["--version"]:
            sys.stdout.write(config["version_stdout"])
            raise SystemExit(int(config["version_returncode"]))
        if args == ["--help"]:
            sys.stdout.write(config["help_text"])
            raise SystemExit(int(config["help_returncode"]))
        if args == ["auth", "status"]:
            sys.stdout.write(config["auth_stdout"])
            raise SystemExit(int(config["auth_returncode"]))

        sys.stderr.write(
            "fake claude: unauthorized argv " + json.dumps(args) + "\\n"
        )
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


def _minimal_parent_env() -> dict[str, str]:
    return {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    }


def test_public_exports_present() -> None:
    from lockstep import agents

    exported = set(agents.__all__)
    assert {
        "ClaudeCliStatus",
        "ClaudePreflightError",
        "probe_claude_cli",
        "require_claude_subscription_ready",
    }.issubset(exported)


def test_probe_returns_status_for_healthy_max_subscription(tmp_path: Path) -> None:
    executable = _write_fake_claude(tmp_path)

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    assert isinstance(status, ClaudeCliStatus)
    assert status.executable == str(executable)
    assert status.version == "2.1.259"
    assert status.logged_in is True
    assert status.auth_method == "claude.ai"
    assert status.api_provider == "firstParty"
    assert status.subscription_type == "max"
    assert status.supports_print is True
    assert status.supports_model is True
    assert status.supports_effort is True
    assert status.supports_output_format is True
    assert status.supports_json_schema is True
    assert status.supports_permission_mode is True
    assert status.supports_permission_prompts is True
    assert status.supports_no_session_persistence is True
    assert status.supports_restricted is True
    assert status.supports_bare is True
    assert status.supports_tools is True
    assert status.supports_disallowed_tools is True

    assert require_claude_subscription_ready(status) is status


@pytest.mark.parametrize("subscription_type", ["pro", "max", "team", "enterprise"])
def test_require_accepts_all_paid_subscription_types(
    tmp_path: Path,
    subscription_type: str,
) -> None:
    executable = _write_fake_claude(
        tmp_path,
        auth_stdout=_build_auth_stdout(subscription_type=subscription_type),
    )

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    assert status.subscription_type == subscription_type
    assert require_claude_subscription_ready(status) is status


def test_require_accepts_case_insensitive_subscription_type(tmp_path: Path) -> None:
    executable = _write_fake_claude(
        tmp_path,
        auth_stdout=_build_auth_stdout(subscription_type="Max"),
    )

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    assert require_claude_subscription_ready(status) is status


def test_require_rejects_not_logged_in(tmp_path: Path) -> None:
    executable = _write_fake_claude(
        tmp_path,
        auth_stdout=_build_auth_stdout(
            logged_in=False,
            auth_method="none",
            subscription_type=None,
        ),
    )

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )
    assert status.logged_in is False

    with pytest.raises(ClaudePreflightError) as exc_info:
        require_claude_subscription_ready(status)
    assert exc_info.value.stage == "auth"


@pytest.mark.parametrize(
    "auth_method",
    ["console", "apiKey", "oauth_token", "profile"],
)
def test_require_rejects_non_claude_ai_auth_method(
    tmp_path: Path,
    auth_method: str,
) -> None:
    executable = _write_fake_claude(
        tmp_path,
        auth_stdout=_build_auth_stdout(auth_method=auth_method),
    )

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )
    assert status.auth_method == auth_method

    with pytest.raises(ClaudePreflightError) as exc_info:
        require_claude_subscription_ready(status)
    assert exc_info.value.stage in {"auth", "subscription"}


@pytest.mark.parametrize(
    "provider",
    ["bedrock", "vertex", "foundry", "gateway"],
)
def test_require_rejects_non_first_party_api_provider(
    tmp_path: Path,
    provider: str,
) -> None:
    executable = _write_fake_claude(
        tmp_path,
        auth_stdout=_build_auth_stdout(api_provider=provider),
    )

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )
    assert status.api_provider == provider

    with pytest.raises(ClaudePreflightError) as exc_info:
        require_claude_subscription_ready(status)
    assert exc_info.value.stage in {"auth", "subscription"}


@pytest.mark.parametrize(
    "subscription_type",
    ["free", "trial", "unknown", None, ""],
)
def test_require_rejects_non_paid_subscription_type(
    tmp_path: Path,
    subscription_type: str | None,
) -> None:
    executable = _write_fake_claude(
        tmp_path,
        auth_stdout=_build_auth_stdout(subscription_type=subscription_type),
    )

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    with pytest.raises(ClaudePreflightError) as exc_info:
        require_claude_subscription_ready(status)
    assert exc_info.value.stage in {"auth", "subscription"}


@pytest.mark.parametrize(
    "auth_body",
    [
        "",
        "this is not JSON",
        "[]",
        "42",
    ],
)
def test_probe_rejects_malformed_auth_output(
    tmp_path: Path,
    auth_body: str,
) -> None:
    executable = _write_fake_claude(tmp_path, auth_stdout=auth_body)

    with pytest.raises(ClaudePreflightError) as exc_info:
        probe_claude_cli(
            claude_executable=str(executable),
            parent_env=_minimal_parent_env(),
            cwd=tmp_path,
        )
    assert exc_info.value.stage == "auth"


def test_probe_rejects_missing_auth_fields(tmp_path: Path) -> None:
    executable = _write_fake_claude(
        tmp_path,
        auth_stdout=json.dumps({"loggedIn": True}),
    )

    with pytest.raises(ClaudePreflightError) as exc_info:
        probe_claude_cli(
            claude_executable=str(executable),
            parent_env=_minimal_parent_env(),
            cwd=tmp_path,
        )
    assert exc_info.value.stage == "auth"


def test_probe_rejects_wrong_auth_field_types(tmp_path: Path) -> None:
    executable = _write_fake_claude(
        tmp_path,
        auth_stdout=_build_auth_stdout(logged_in="yes"),  # type: ignore[arg-type]
    )

    with pytest.raises(ClaudePreflightError) as exc_info:
        probe_claude_cli(
            claude_executable=str(executable),
            parent_env=_minimal_parent_env(),
            cwd=tmp_path,
        )
    assert exc_info.value.stage == "auth"


def test_malformed_auth_error_is_secret_safe(tmp_path: Path) -> None:
    sentinel = "SECRET-SENTINEL-CLAUDE-9x8-DO-NOT-ECHO"
    malformed = "this is not JSON { " + sentinel + " }"
    executable = _write_fake_claude(tmp_path, auth_stdout=malformed)

    with pytest.raises(ClaudePreflightError) as exc_info:
        probe_claude_cli(
            claude_executable=str(executable),
            parent_env=_minimal_parent_env(),
            cwd=tmp_path,
        )

    assert exc_info.value.stage == "auth"
    assert sentinel not in str(exc_info.value)
    assert sentinel not in exc_info.value.reason


def test_probe_rejects_nonzero_auth_status_exit(tmp_path: Path) -> None:
    executable = _write_fake_claude(tmp_path, auth_returncode=3)

    with pytest.raises(ClaudePreflightError) as exc_info:
        probe_claude_cli(
            claude_executable=str(executable),
            parent_env=_minimal_parent_env(),
            cwd=tmp_path,
        )
    assert exc_info.value.stage == "auth"


def test_probe_rejects_version_below_minimum(tmp_path: Path) -> None:
    executable = _write_fake_claude(tmp_path, version_stdout="2.1.258\n")

    with pytest.raises(ClaudePreflightError) as exc_info:
        probe_claude_cli(
            claude_executable=str(executable),
            parent_env=_minimal_parent_env(),
            cwd=tmp_path,
        )
    assert exc_info.value.stage == "version"


def test_probe_accepts_version_at_minimum(tmp_path: Path) -> None:
    executable = _write_fake_claude(tmp_path, version_stdout="2.1.259\n")

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )
    assert status.version == "2.1.259"


def test_probe_accepts_higher_version(tmp_path: Path) -> None:
    executable = _write_fake_claude(tmp_path, version_stdout="2.2.0\n")

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )
    assert status.version == "2.2.0"


def test_probe_normalizes_decorated_version_output(tmp_path: Path) -> None:
    executable = _write_fake_claude(
        tmp_path,
        version_stdout="2.1.259 (Claude Code)\n",
    )

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )
    assert status.version == "2.1.259"


def test_capabilities_captured_from_help(tmp_path: Path) -> None:
    executable = _write_fake_claude(tmp_path)

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    assert status.supports_print is True
    assert status.supports_model is True
    assert status.supports_effort is True
    assert status.supports_output_format is True
    assert status.supports_json_schema is True
    assert status.supports_permission_mode is True
    assert status.supports_permission_prompts is True
    assert status.supports_no_session_persistence is True
    assert status.supports_restricted is True
    assert status.supports_bare is True
    assert status.supports_tools is True
    assert status.supports_disallowed_tools is True


def test_missing_help_flag_records_false(tmp_path: Path) -> None:
    reduced = tuple(line for line in _HELP_ALL_FLAGS if "--restricted" not in line)
    executable = _write_fake_claude(tmp_path, help_text=_build_help_text(reduced))

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )
    assert status.supports_restricted is False
    assert status.supports_print is True
    assert status.supports_bare is True


def test_disallowed_tools_hyphenated_spelling_recognized(tmp_path: Path) -> None:
    substituted = tuple(
        "--disallowed-tools LIST" if "--disallowedTools" in line else line
        for line in _HELP_ALL_FLAGS
    )
    executable = _write_fake_claude(
        tmp_path,
        help_text=_build_help_text(substituted),
    )

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )
    assert status.supports_disallowed_tools is True


def test_probe_invokes_only_three_authorized_commands(tmp_path: Path) -> None:
    executable = _write_fake_claude(tmp_path)

    probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    invocations = _read_invocations(executable)
    argvs = [tuple(record["argv"]) for record in invocations]
    assert sorted(argvs) == sorted(
        [
            ("--version",),
            ("--help",),
            ("auth", "status"),
        ]
    )
    assert len(argvs) == 3
    for argv in argvs:
        assert "-p" not in argv
        assert "--print" not in argv
        for forbidden in ("login", "logout", "update", "doctor", "fix"):
            assert forbidden not in argv


def test_probe_uses_supplied_cwd(tmp_path: Path) -> None:
    fake_root = tmp_path / "fake"
    fake_root.mkdir()
    executable = _write_fake_claude(fake_root)
    safe_cwd = tmp_path / "workdir"
    safe_cwd.mkdir()

    probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=safe_cwd,
    )

    invocations = _read_invocations(executable)
    assert invocations
    resolved = str(safe_cwd.resolve())
    for record in invocations:
        assert record["cwd"] == resolved


def test_probe_environment_excludes_ambient_credentials(tmp_path: Path) -> None:
    executable = _write_fake_claude(tmp_path)
    parent_env = {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "ANTHROPIC_API_KEY": "sk-ant-parent-not-leak",
        "ANTHROPIC_AUTH_TOKEN": "at-parent-not-leak",
        "ANTHROPIC_BASE_URL": "https://parent.invalid",
        "ANTHROPIC_PROFILE": "parent-profile-not-leak",
        "ANTHROPIC_FEDERATION_RULE_ID": "fed-parent-not-leak",
        "ANTHROPIC_ORGANIZATION_ID": "org-parent-not-leak",
        "ANTHROPIC_IDENTITY_TOKEN_FILE": "/tmp/tok-not-leak",
        "CLAUDE_CODE_OAUTH_TOKEN": "oauth-parent-not-leak",
        "CLAUDE_CODE_USE_BEDROCK": "1",
        "CLAUDE_CODE_USE_VERTEX": "1",
        "CLAUDE_CODE_USE_FOUNDRY": "1",
        "CLAUDE_CONFIG_DIR": "/tmp/parent-claude-not-leak",
    }

    probe_claude_cli(
        claude_executable=str(executable),
        parent_env=parent_env,
        cwd=tmp_path,
    )

    invocations = _read_invocations(executable)
    assert invocations, "fake claude recorded no invocations"
    forbidden_names = (
        "ANTHROPIC_API_KEY",
        "ANTHROPIC_AUTH_TOKEN",
        "ANTHROPIC_BASE_URL",
        "ANTHROPIC_PROFILE",
        "ANTHROPIC_FEDERATION_RULE_ID",
        "ANTHROPIC_ORGANIZATION_ID",
        "ANTHROPIC_IDENTITY_TOKEN_FILE",
        "CLAUDE_CODE_OAUTH_TOKEN",
        "CLAUDE_CODE_USE_BEDROCK",
        "CLAUDE_CODE_USE_VERTEX",
        "CLAUDE_CODE_USE_FOUNDRY",
        "CLAUDE_CONFIG_DIR",
    )
    for record in invocations:
        env = record["env"]
        assert isinstance(env, dict)
        assert "HOME" in env
        assert "PATH" in env
        for forbidden in forbidden_names:
            assert forbidden not in env


def test_probe_environment_supports_explicit_claude_config_dir(
    tmp_path: Path,
) -> None:
    executable = _write_fake_claude(tmp_path)
    trusted = tmp_path / "trusted-claude-home"
    trusted.mkdir()
    attacker = tmp_path / "attacker-claude-home"
    attacker.mkdir()
    parent_env = {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "CLAUDE_CONFIG_DIR": str(attacker),
    }

    probe_claude_cli(
        claude_executable=str(executable),
        parent_env=parent_env,
        cwd=tmp_path,
        claude_config_dir=trusted,
    )

    invocations = _read_invocations(executable)
    assert invocations
    resolved_trusted = str(trusted.resolve())
    for record in invocations:
        env = record["env"]
        assert isinstance(env, dict)
        assert env.get("CLAUDE_CONFIG_DIR") == resolved_trusted
        assert env["CLAUDE_CONFIG_DIR"] != str(attacker)


def test_status_does_not_carry_identity_fields(tmp_path: Path) -> None:
    email = "user@example.invalid"
    org_id = "org_1234"
    org_name = "Fake Org"
    executable = _write_fake_claude(
        tmp_path,
        auth_stdout=_build_auth_stdout(
            extra={"email": email, "orgId": org_id, "orgName": org_name},
        ),
    )

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    assert not hasattr(status, "email")
    assert not hasattr(status, "org_id")
    assert not hasattr(status, "org_name")

    text = repr(status)
    for value in (email, org_id, org_name):
        assert value not in text

    try:
        require_claude_subscription_ready(status)
    except ClaudePreflightError as exc:
        assert email not in str(exc)
        assert org_id not in str(exc)
        assert org_name not in str(exc)


def test_status_is_immutable(tmp_path: Path) -> None:
    executable = _write_fake_claude(tmp_path)

    status = probe_claude_cli(
        claude_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    with pytest.raises(AttributeError):
        status.version = "hijacked"  # type: ignore[misc]


def test_lower_layer_launch_failure_is_transparent(tmp_path: Path) -> None:
    with pytest.raises(ProcessLaunchError):
        probe_claude_cli(
            claude_executable=str(tmp_path / "no-such-claude"),
            parent_env=_minimal_parent_env(),
            cwd=tmp_path,
        )
