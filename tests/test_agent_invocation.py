import sys
from dataclasses import FrozenInstanceError
from pathlib import Path

import pytest

from lockstep.agents import (
    AgentAdapter,
    AgentCommand,
    AgentInvocationRequest,
    AgentInvocationResult,
    invoke_agent,
)
from lockstep.domain import AgentRole, BillingMode
from lockstep.process import EnvironmentPolicyError, ProcessTimeoutError


class _EchoAdapter:
    name = "echo"

    def __init__(self) -> None:
        self.requests: list[AgentInvocationRequest] = []

    def build_command(
        self,
        request: AgentInvocationRequest,
    ) -> AgentCommand:
        self.requests.append(request)

        script = (
            "import os, sys; "
            "print(sys.argv[1]); "
            "print(sys.argv[2]); "
            "print(os.environ['LOCKSTEP_EXPLICIT']); "
            "print(os.environ.get('HTTPS_PROXY', 'missing')); "
            "print(os.environ.get('OPENAI_API_KEY', 'missing'))"
        )

        return AgentCommand(
            argv=(
                sys.executable,
                "-c",
                script,
                request.role.value,
                request.billing_mode.value,
            ),
            inherit_names=("HTTPS_PROXY",),
            explicit_env={
                "LOCKSTEP_EXPLICIT": "explicit",
            },
            required_names=("HOME", "PATH"),
        )


class _NonzeroAdapter:
    name = "nonzero"

    def build_command(
        self,
        request: AgentInvocationRequest,
    ) -> AgentCommand:
        return AgentCommand(
            argv=(
                sys.executable,
                "-c",
                "import sys; print('failed'); raise SystemExit(9)",
            ),
        )


class _TimeoutAdapter:
    name = "timeout"

    def build_command(
        self,
        request: AgentInvocationRequest,
    ) -> AgentCommand:
        return AgentCommand(
            argv=(
                sys.executable,
                "-c",
                "import time; time.sleep(60)",
            ),
        )


class _MissingRequirementAdapter:
    name = "missing-requirement"

    def __init__(self, marker: Path) -> None:
        self.marker = marker

    def build_command(
        self,
        request: AgentInvocationRequest,
    ) -> AgentCommand:
        return AgentCommand(
            argv=(
                sys.executable,
                "-c",
                f"import pathlib; pathlib.Path({str(self.marker)!r}).write_text('ran')",
            ),
            required_names=("LOCKSTEP_REQUIRED_VALUE",),
        )


class _BoundedOutputAdapter:
    name = "bounded-output"

    def build_command(
        self,
        request: AgentInvocationRequest,
    ) -> AgentCommand:
        return AgentCommand(
            argv=(
                sys.executable,
                "-c",
                "import os, sys; print(os.getcwd()); sys.stdout.write('0123456789')",
            ),
        )


def _request(
    cwd: Path,
    *,
    timeout_seconds: float = 5,
    max_output_bytes: int = 1_048_576,
) -> AgentInvocationRequest:
    return AgentInvocationRequest(
        role=AgentRole.PLANNER,
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        prompt="private planner prompt",
        cwd=cwd,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=0.1,
    )


def test_agent_adapter_is_structural_runtime_protocol() -> None:
    assert isinstance(_EchoAdapter(), AgentAdapter)


def test_request_is_immutable_resolves_cwd_and_hides_prompt_from_repr(
    tmp_path: Path,
) -> None:
    request = _request(tmp_path / ".." / tmp_path.name)

    assert request.cwd == tmp_path.resolve()
    assert request.prompt == "private planner prompt"
    assert request.prompt not in repr(request)

    with pytest.raises(FrozenInstanceError):
        request.role = AgentRole.IMPLEMENTER  # type: ignore[misc]


def test_agent_command_copies_and_hides_explicit_environment() -> None:
    secret = "very-secret-value"
    supplied = {
        "LOCKSTEP_SECRET": secret,
    }

    command = AgentCommand(
        argv=(sys.executable, "-c", "pass"),
        explicit_env=supplied,
    )

    supplied["LOCKSTEP_SECRET"] = "changed"

    assert command.explicit_env["LOCKSTEP_SECRET"] == secret
    assert secret not in repr(command)

    with pytest.raises(TypeError):
        command.explicit_env["LOCKSTEP_SECRET"] = "mutated"  # type: ignore[index]


def test_invoke_agent_composes_adapter_environment_and_process_layers(
    tmp_path: Path,
) -> None:
    adapter = _EchoAdapter()
    request = _request(tmp_path)
    parent = {
        "HOME": "/home/tester",
        "PATH": "/usr/bin",
        "HTTPS_PROXY": "http://proxy.invalid",
        "OPENAI_API_KEY": "ambient-api-secret",
    }

    result = invoke_agent(
        adapter,
        request,
        parent_env=parent,
    )

    assert isinstance(result, AgentInvocationResult)
    assert result.adapter_name == "echo"
    assert result.role is AgentRole.PLANNER
    assert result.billing_mode is BillingMode.SUBSCRIPTION_ONLY
    assert result.process.returncode == 0
    assert result.process.stdout.splitlines() == [
        AgentRole.PLANNER.value,
        BillingMode.SUBSCRIPTION_ONLY.value,
        "explicit",
        "http://proxy.invalid",
        "missing",
    ]
    assert adapter.requests == [request]
    assert parent == {
        "HOME": "/home/tester",
        "PATH": "/usr/bin",
        "HTTPS_PROXY": "http://proxy.invalid",
        "OPENAI_API_KEY": "ambient-api-secret",
    }


def test_invocation_result_does_not_store_prompt_or_environment(
    tmp_path: Path,
) -> None:
    result = invoke_agent(
        _EchoAdapter(),
        _request(tmp_path),
        parent_env={
            "HOME": "/home/tester",
            "PATH": "/usr/bin",
        },
    )

    assert not hasattr(result, "prompt")
    assert not hasattr(result, "environment")
    assert not hasattr(result, "command")


def test_nonzero_agent_exit_remains_process_result(tmp_path: Path) -> None:
    result = invoke_agent(
        _NonzeroAdapter(),
        _request(tmp_path),
        parent_env={},
    )

    assert result.adapter_name == "nonzero"
    assert result.process.returncode == 9
    assert result.process.succeeded is False
    assert result.process.stdout == "failed\n"


def test_environment_policy_failure_prevents_process_launch(
    tmp_path: Path,
) -> None:
    marker = tmp_path / "process-ran"
    adapter = _MissingRequirementAdapter(marker)

    with pytest.raises(EnvironmentPolicyError):
        invoke_agent(
            adapter,
            _request(tmp_path),
            parent_env={},
        )

    assert not marker.exists()


def test_process_timeout_propagates_without_agent_reclassification(
    tmp_path: Path,
) -> None:
    with pytest.raises(ProcessTimeoutError) as exc_info:
        invoke_agent(
            _TimeoutAdapter(),
            _request(
                tmp_path,
                timeout_seconds=0.2,
            ),
            parent_env={},
        )

    assert exc_info.value.timeout_seconds == 0.2


def test_request_controls_cwd_and_output_budget(tmp_path: Path) -> None:
    nested = tmp_path / "nested"
    nested.mkdir()

    result = invoke_agent(
        _BoundedOutputAdapter(),
        _request(
            nested,
            max_output_bytes=4,
        ),
        parent_env={},
    )

    assert result.process.cwd == nested.resolve()
    assert result.process.stdout == "6789"
    assert result.process.stdout_truncated is True
