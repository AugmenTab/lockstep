import json
import os
import stat
import sys
import textwrap
from pathlib import Path

import pytest

from lockstep.agents import (
    CodexCliStatus,
    CodexPreflightError,
    probe_codex_cli,
    require_codex_subscription_ready,
)
from lockstep.process import ProcessLaunchError

_DEFAULT_EXEC_FLAGS: tuple[str, ...] = (
    "--ephemeral",
    "--ignore-user-config",
    "--sandbox",
    "--color",
)


def _build_doctor_stdout(
    *,
    schema_version: int | str = 1,
    overall_status: str = "ok",
    auth_status: str = "ok",
    stored_auth_mode: str = "chatgpt",
    stored_chatgpt_tokens: str = "true",
    stored_api_key: str = "false",
) -> str:
    return json.dumps(
        {
            "schemaVersion": schema_version,
            "overallStatus": overall_status,
            "checks": {
                "auth.credentials": {
                    "status": auth_status,
                    "details": [
                        {"name": "stored auth mode", "value": stored_auth_mode},
                        {
                            "name": "stored ChatGPT tokens",
                            "value": stored_chatgpt_tokens,
                        },
                        {"name": "stored API key", "value": stored_api_key},
                    ],
                },
                "desktop": {"status": "warning", "details": []},
                "git": {"status": "ok", "details": []},
            },
        }
    )


def _build_exec_help(flags: tuple[str, ...]) -> str:
    lines = [
        "Usage: codex exec [OPTIONS] [PROMPT]",
        "",
        "Options:",
    ]
    lines.extend(f"  {flag}  option description" for flag in flags)
    return "\n".join(lines) + "\n"


def _write_fake_codex(
    root: Path,
    *,
    version: str = "codex-cli test-version",
    exec_help_text: str | None = None,
    exec_flags: tuple[str, ...] = _DEFAULT_EXEC_FLAGS,
    doctor_stdout: str | None = None,
    doctor_returncode: int = 0,
) -> Path:
    fake_root = root / "codex-fake"
    fake_root.mkdir(parents=True, exist_ok=True)

    executable = fake_root / "codex"
    config_path = fake_root / "config.json"

    if exec_help_text is None:
        exec_help_text = _build_exec_help(exec_flags)
    if doctor_stdout is None:
        doctor_stdout = _build_doctor_stdout()

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
        config = json.loads((base / "config.json").read_text(encoding="utf-8"))
        args = sys.argv[1:]

        with (base / "invocations.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(args) + "\\n")
        with (base / "observed-env.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(
                json.dumps({{"argv": args, "env": dict(os.environ)}}) + "\\n"
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
        sys.stderr.write("fake codex: unexpected argv " + json.dumps(args) + "\\n")
        raise SystemExit(99)
        """
    )
    executable.write_text(script, encoding="utf-8")
    mode = executable.stat().st_mode
    executable.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _read_invocations(executable: Path) -> list[list[str]]:
    log_path = executable.parent / "invocations.jsonl"
    if not log_path.exists():
        return []
    return [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines() if line]


def _read_observed_envs(executable: Path) -> list[dict[str, object]]:
    env_path = executable.parent / "observed-env.jsonl"
    if not env_path.exists():
        return []
    return [json.loads(line) for line in env_path.read_text(encoding="utf-8").splitlines() if line]


def _minimal_parent_env() -> dict[str, str]:
    return {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    }


def test_healthy_subscription_probe_survives_unrelated_doctor_diagnostics(
    tmp_path: Path,
) -> None:
    executable = _write_fake_codex(
        tmp_path,
        doctor_stdout=_build_doctor_stdout(overall_status="warning"),
        doctor_returncode=1,
    )

    status = probe_codex_cli(
        codex_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    assert isinstance(status, CodexCliStatus)
    assert status.executable == str(executable)
    assert status.version == "codex-cli test-version"
    assert status.doctor_schema_version == 1
    assert status.doctor_overall_status == "warning"
    assert status.doctor_returncode == 1
    assert status.auth_check_status == "ok"
    assert status.stored_auth_mode == "chatgpt"
    assert status.stored_chatgpt_tokens is True
    assert status.stored_api_key is False
    assert status.supports_exec_ephemeral is True
    assert status.supports_exec_ignore_user_config is True
    assert status.supports_exec_sandbox is True
    assert status.supports_exec_color is True

    assert require_codex_subscription_ready(status) is status


def test_ambient_api_credentials_excluded_and_codex_home_explicit(
    tmp_path: Path,
) -> None:
    executable = _write_fake_codex(tmp_path)
    trusted_home = tmp_path / "trusted-codex-home"
    trusted_home.mkdir()
    attacker_home = tmp_path / "attacker-codex-home"
    attacker_home.mkdir()
    parent_env = {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
        "OPENAI_API_KEY": "sk-parent-openai-should-not-leak",
        "CODEX_API_KEY": "sk-parent-codex-should-not-leak",
        "CODEX_ACCESS_TOKEN": "parent-access-token-should-not-leak",
        "OPENAI_BASE_URL": "https://parent-openai.invalid",
        "CODEX_HOME": str(attacker_home),
    }

    probe_codex_cli(
        codex_executable=str(executable),
        parent_env=parent_env,
        cwd=tmp_path,
        codex_home=trusted_home,
    )

    observed = _read_observed_envs(executable)
    assert observed, "fake Codex recorded no invocations"

    for record in observed:
        env = record["env"]
        assert isinstance(env, dict)
        assert "HOME" in env
        assert "PATH" in env
        assert env["CODEX_HOME"] == str(trusted_home.resolve())
        assert env["CODEX_HOME"] != str(attacker_home)
        assert "OPENAI_API_KEY" not in env
        assert "CODEX_API_KEY" not in env
        assert "CODEX_ACCESS_TOKEN" not in env
        assert "OPENAI_BASE_URL" not in env


def test_apikey_stored_auth_rejected_at_require(tmp_path: Path) -> None:
    executable = _write_fake_codex(
        tmp_path,
        doctor_stdout=_build_doctor_stdout(
            stored_auth_mode="apikey",
            stored_chatgpt_tokens="false",
            stored_api_key="true",
        ),
    )

    status = probe_codex_cli(
        codex_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )
    assert status.stored_auth_mode == "apikey"
    assert status.stored_chatgpt_tokens is False
    assert status.stored_api_key is True

    with pytest.raises(CodexPreflightError) as exc_info:
        require_codex_subscription_ready(status)
    assert exc_info.value.stage == "auth"


def test_mixed_stored_credentials_rejected_at_require(tmp_path: Path) -> None:
    executable = _write_fake_codex(
        tmp_path,
        doctor_stdout=_build_doctor_stdout(
            stored_chatgpt_tokens="true",
            stored_api_key="true",
        ),
    )

    status = probe_codex_cli(
        codex_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )
    assert status.stored_chatgpt_tokens is True
    assert status.stored_api_key is True

    with pytest.raises(CodexPreflightError) as exc_info:
        require_codex_subscription_ready(status)
    assert exc_info.value.stage == "auth"


def test_missing_chatgpt_tokens_rejected_at_require(tmp_path: Path) -> None:
    executable = _write_fake_codex(
        tmp_path,
        doctor_stdout=_build_doctor_stdout(
            stored_chatgpt_tokens="false",
            stored_api_key="false",
        ),
    )

    status = probe_codex_cli(
        codex_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )
    assert status.stored_chatgpt_tokens is False

    with pytest.raises(CodexPreflightError) as exc_info:
        require_codex_subscription_ready(status)
    assert exc_info.value.stage == "auth"


@pytest.mark.parametrize("bad_status", ["warning", "fail"])
def test_unhealthy_auth_check_status_rejected_at_require(
    tmp_path: Path,
    bad_status: str,
) -> None:
    executable = _write_fake_codex(
        tmp_path,
        doctor_stdout=_build_doctor_stdout(auth_status=bad_status),
    )

    status = probe_codex_cli(
        codex_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )
    assert status.auth_check_status == bad_status

    with pytest.raises(CodexPreflightError) as exc_info:
        require_codex_subscription_ready(status)
    assert exc_info.value.stage == "auth"


def test_missing_required_exec_capability_rejected(tmp_path: Path) -> None:
    reduced_flags = tuple(flag for flag in _DEFAULT_EXEC_FLAGS if flag != "--ignore-user-config")
    executable = _write_fake_codex(tmp_path, exec_flags=reduced_flags)

    status = probe_codex_cli(
        codex_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )
    assert status.supports_exec_ephemeral is True
    assert status.supports_exec_ignore_user_config is False
    assert status.supports_exec_sandbox is True
    assert status.supports_exec_color is True

    with pytest.raises(CodexPreflightError) as exc_info:
        require_codex_subscription_ready(status)
    assert exc_info.value.stage == "capabilities"


def test_malformed_doctor_output_produces_secret_safe_error(
    tmp_path: Path,
) -> None:
    sentinel = "SECRET-SENTINEL-8x14vJq-DO-NOT-ECHO"
    malformed = "this is not JSON { " + sentinel + " }"
    executable = _write_fake_codex(tmp_path, doctor_stdout=malformed)

    with pytest.raises(CodexPreflightError) as exc_info:
        probe_codex_cli(
            codex_executable=str(executable),
            parent_env=_minimal_parent_env(),
            cwd=tmp_path,
        )

    assert exc_info.value.stage == "doctor"
    assert sentinel not in str(exc_info.value)
    assert sentinel not in exc_info.value.reason


def test_unknown_doctor_schema_version_rejected(tmp_path: Path) -> None:
    executable = _write_fake_codex(
        tmp_path,
        doctor_stdout=_build_doctor_stdout(schema_version=2),
    )

    with pytest.raises(CodexPreflightError) as exc_info:
        probe_codex_cli(
            codex_executable=str(executable),
            parent_env=_minimal_parent_env(),
            cwd=tmp_path,
        )
    assert exc_info.value.stage == "doctor"


def test_lower_layer_launch_failure_is_transparent(tmp_path: Path) -> None:
    with pytest.raises(ProcessLaunchError):
        probe_codex_cli(
            codex_executable=str(tmp_path / "does-not-exist-codex"),
            parent_env=_minimal_parent_env(),
            cwd=tmp_path,
        )


def test_probe_invokes_only_version_help_and_doctor(tmp_path: Path) -> None:
    executable = _write_fake_codex(tmp_path)

    probe_codex_cli(
        codex_executable=str(executable),
        parent_env=_minimal_parent_env(),
        cwd=tmp_path,
    )

    invocations = _read_invocations(executable)
    assert invocations == [
        ["--version"],
        ["exec", "--help"],
        ["doctor", "--json"],
    ]
    for entry in invocations:
        if entry and entry[0] == "exec":
            assert entry == ["exec", "--help"]
