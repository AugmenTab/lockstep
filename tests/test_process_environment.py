import sys
from pathlib import Path

import pytest

from lockstep.process import (
    EnvironmentPolicyError,
    build_process_environment,
    run_process,
)


def test_default_policy_inherits_only_safe_baseline() -> None:
    parent = {
        "HOME": "/home/tester",
        "PATH": "/usr/local/bin:/usr/bin",
        "TMPDIR": "/tmp/custom",
        "USER": "tester",
        "LOGNAME": "tester",
        "SHELL": "/bin/sh",
        "LANG": "en_US.UTF-8",
        "LC_TIME": "C",
        "XDG_CONFIG_HOME": "/home/tester/.config",
        "XDG_CACHE_HOME": "/home/tester/.cache",
        "OPENAI_API_KEY": "openai-secret",
        "ANTHROPIC_API_KEY": "anthropic-secret",
        "AWS_SECRET_ACCESS_KEY": "aws-secret",
        "GITHUB_TOKEN": "github-secret",
        "SSH_AUTH_SOCK": "/tmp/ssh-agent.sock",
        "HTTPS_PROXY": "http://user:password@proxy.invalid",
        "PYTHONPATH": "/tmp/injected-python",
        "LD_PRELOAD": "/tmp/injected.so",
        "BASH_ENV": "/tmp/injected-shell",
        "GIT_CONFIG_COUNT": "1",
        "CI": "true",
        "PWD": "/parent/cwd",
    }

    child = build_process_environment(parent)

    assert child == {
        "HOME": "/home/tester",
        "LANG": "en_US.UTF-8",
        "LC_TIME": "C",
        "LOGNAME": "tester",
        "PATH": "/usr/local/bin:/usr/bin",
        "SHELL": "/bin/sh",
        "TMPDIR": "/tmp/custom",
        "USER": "tester",
        "XDG_CACHE_HOME": "/home/tester/.cache",
        "XDG_CONFIG_HOME": "/home/tester/.config",
    }


def test_missing_optional_baseline_values_are_omitted() -> None:
    child = build_process_environment(
        {
            "HOME": "/home/tester",
            "PATH": "/usr/bin",
        }
    )

    assert child == {
        "HOME": "/home/tester",
        "PATH": "/usr/bin",
    }


def test_additional_inheritance_requires_explicit_opt_in() -> None:
    parent = {
        "HOME": "/home/tester",
        "PATH": "/usr/bin",
        "HTTPS_PROXY": "http://proxy.invalid",
    }

    default_child = build_process_environment(parent)
    opted_in_child = build_process_environment(
        parent,
        inherit_names=("HTTPS_PROXY",),
    )

    assert "HTTPS_PROXY" not in default_child
    assert opted_in_child["HTTPS_PROXY"] == "http://proxy.invalid"


def test_explicit_values_add_and_override_environment() -> None:
    child = build_process_environment(
        {
            "HOME": "/home/parent",
            "PATH": "/usr/bin",
        },
        explicit_env={
            "HOME": "/home/isolated",
            "LOCKSTEP_AGENT_MODE": "planner",
            "OPENAI_API_KEY": "explicit-secret",
        },
    )

    assert child["HOME"] == "/home/isolated"
    assert child["LOCKSTEP_AGENT_MODE"] == "planner"
    assert child["OPENAI_API_KEY"] == "explicit-secret"


def test_required_names_are_checked_after_explicit_overrides() -> None:
    child = build_process_environment(
        {},
        explicit_env={
            "HOME": "/home/isolated",
            "PATH": "/custom/bin",
        },
        required_names=("HOME", "PATH"),
    )

    assert child == {
        "HOME": "/home/isolated",
        "PATH": "/custom/bin",
    }


def test_missing_required_name_raises_policy_error() -> None:
    with pytest.raises(EnvironmentPolicyError) as exc_info:
        build_process_environment(
            {"PATH": "/usr/bin"},
            required_names=("HOME", "PATH"),
        )

    assert exc_info.value.variable_name == "HOME"
    assert "HOME" in exc_info.value.reason


def test_required_name_does_not_implicitly_grant_inheritance() -> None:
    with pytest.raises(EnvironmentPolicyError) as exc_info:
        build_process_environment(
            {
                "HOME": "/home/tester",
                "PATH": "/usr/bin",
                "SSH_AUTH_SOCK": "/tmp/agent.sock",
            },
            required_names=("SSH_AUTH_SOCK",),
        )

    assert exc_info.value.variable_name == "SSH_AUTH_SOCK"


def test_builder_does_not_mutate_input_mappings() -> None:
    parent = {
        "HOME": "/home/parent",
        "PATH": "/usr/bin",
    }
    explicit = {
        "HOME": "/home/child",
    }

    parent_before = dict(parent)
    explicit_before = dict(explicit)

    build_process_environment(
        parent,
        explicit_env=explicit,
    )

    assert parent == parent_before
    assert explicit == explicit_before


@pytest.mark.parametrize(
    "name",
    [
        "",
        "BAD=NAME",
        "BAD\x00NAME",
    ],
)
def test_invalid_policy_variable_name_is_rejected(name: str) -> None:
    with pytest.raises(EnvironmentPolicyError):
        build_process_environment(
            {},
            inherit_names=(name,),
        )


def test_duplicate_policy_variable_name_is_rejected() -> None:
    with pytest.raises(EnvironmentPolicyError):
        build_process_environment(
            {},
            inherit_names=("HTTPS_PROXY", "HTTPS_PROXY"),
        )


def test_invalid_explicit_value_does_not_leak_value() -> None:
    secret = "super-secret-value"

    with pytest.raises(EnvironmentPolicyError) as exc_info:
        build_process_environment(
            {},
            explicit_env={
                "LOCKSTEP_SECRET": secret + "\x00",
            },
        )

    assert exc_info.value.variable_name == "LOCKSTEP_SECRET"
    assert secret not in str(exc_info.value)
    assert secret not in exc_info.value.reason


def test_additional_inherited_value_is_validated_without_leaking_it() -> None:
    secret = "inherited-secret-value"

    with pytest.raises(EnvironmentPolicyError) as exc_info:
        build_process_environment(
            {
                "PRIVATE_TOKEN": secret + "\x00",
            },
            inherit_names=("PRIVATE_TOKEN",),
        )

    assert exc_info.value.variable_name == "PRIVATE_TOKEN"
    assert secret not in str(exc_info.value)
    assert secret not in exc_info.value.reason


def test_result_key_order_is_deterministic() -> None:
    child = build_process_environment(
        {
            "PATH": "/usr/bin",
            "HOME": "/home/tester",
            "LANG": "C.UTF-8",
        },
        explicit_env={
            "ZZZ": "last",
            "AAA": "first",
        },
    )

    assert tuple(child) == (
        "AAA",
        "HOME",
        "LANG",
        "PATH",
        "ZZZ",
    )


def test_built_environment_composes_with_process_runner(
    tmp_path: Path,
) -> None:
    child_env = build_process_environment(
        {
            "HOME": "/home/tester",
            "PATH": "/usr/bin",
            "OPENAI_API_KEY": "ambient-secret",
        },
        explicit_env={
            "LOCKSTEP_CHILD_VALUE": "explicit",
        },
        required_names=("HOME", "PATH"),
    )

    result = run_process(
        (
            sys.executable,
            "-c",
            (
                "import os; "
                "print(os.environ['LOCKSTEP_CHILD_VALUE']); "
                "print(os.environ.get('OPENAI_API_KEY', 'missing'))"
            ),
        ),
        cwd=tmp_path,
        env=child_env,
        timeout_seconds=5,
    )

    assert result.stdout == "explicit\nmissing\n"
