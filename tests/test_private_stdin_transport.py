import hashlib
import sys
from pathlib import Path
from typing import Any

import pytest

from lockstep.agents import (
    AgentCommand,
    AgentInvocationRequest,
    AgentInvocationResult,
    invoke_agent,
)
from lockstep.domain import AgentRole, BillingMode
from lockstep.process import (
    ProcessConfigurationError,
    ProcessTimeoutError,
    run_process,
)


class _StdinAdapter:
    name = "stdin-test"

    def build_command(
        self,
        request: AgentInvocationRequest,
    ) -> AgentCommand:
        script = (
            "import hashlib, sys; "
            "data = sys.stdin.buffer.read(); "
            "print(hashlib.sha256(data).hexdigest())"
        )

        return AgentCommand(
            argv=(sys.executable, "-c", script),
            stdin_text=request.prompt,
        )


class _TimeoutAfterInputAdapter:
    name = "stdin-timeout"

    def build_command(
        self,
        request: AgentInvocationRequest,
    ) -> AgentCommand:
        return AgentCommand(
            argv=(
                sys.executable,
                "-c",
                (
                    "import sys, time; "
                    "sys.stdin.buffer.read(); "
                    "print('received', flush=True); "
                    "time.sleep(60)"
                ),
            ),
            stdin_text=request.prompt,
        )


def _request(
    cwd: Path,
    *,
    prompt: str,
    timeout_seconds: float = 5,
) -> AgentInvocationRequest:
    return AgentInvocationRequest(
        role=AgentRole.PLANNER,
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        prompt=prompt,
        cwd=cwd,
        timeout_seconds=timeout_seconds,
        termination_grace_seconds=0.1,
    )


def test_run_process_delivers_exact_utf8_stdin_then_eof(
    tmp_path: Path,
) -> None:
    payload = "first line\nλ second line\n終わり\n"
    expected = hashlib.sha256(payload.encode("utf-8")).hexdigest()

    result = run_process(
        (
            sys.executable,
            "-c",
            (
                "import hashlib, sys; "
                "data = sys.stdin.buffer.read(); "
                "print(hashlib.sha256(data).hexdigest())"
            ),
        ),
        cwd=tmp_path,
        env={},
        timeout_seconds=5,
        stdin_text=payload,
    )

    assert result.returncode == 0
    assert result.stdout == expected + "\n"
    assert payload not in result.argv
    assert payload not in repr(result)


def test_run_process_default_stdin_remains_closed(
    tmp_path: Path,
) -> None:
    result = run_process(
        (
            sys.executable,
            "-c",
            "import sys; print(repr(sys.stdin.read()))",
        ),
        cwd=tmp_path,
        env={},
        timeout_seconds=5,
    )

    assert result.stdout == "''\n"


def test_stdin_may_contain_nul_bytes_after_utf8_encoding(
    tmp_path: Path,
) -> None:
    payload = "before\x00after"

    result = run_process(
        (
            sys.executable,
            "-c",
            "import sys; print(sys.stdin.buffer.read().hex())",
        ),
        cwd=tmp_path,
        env={},
        timeout_seconds=5,
        stdin_text=payload,
    )

    assert result.stdout.strip() == payload.encode("utf-8").hex()


def test_invalid_stdin_type_is_configuration_error_without_leak(
    tmp_path: Path,
) -> None:
    private_value: Any = object()

    with pytest.raises(ProcessConfigurationError) as exc_info:
        run_process(
            (sys.executable, "-c", "print('never')"),
            cwd=tmp_path,
            env={},
            timeout_seconds=5,
            stdin_text=private_value,
        )

    assert "stdin" in exc_info.value.reason
    assert repr(private_value) not in str(exc_info.value)


def test_unencodable_stdin_is_configuration_error_without_payload(
    tmp_path: Path,
) -> None:
    payload = "private-prefix-\ud800-private-suffix"

    with pytest.raises(ProcessConfigurationError) as exc_info:
        run_process(
            (sys.executable, "-c", "print('never')"),
            cwd=tmp_path,
            env={},
            timeout_seconds=5,
            stdin_text=payload,
        )

    assert "UTF-8" in exc_info.value.reason
    assert "private-prefix" not in str(exc_info.value)
    assert "private-suffix" not in str(exc_info.value)


def test_agent_command_hides_stdin_payload_from_repr() -> None:
    private_prompt = "LOCKSTEP_PRIVATE_STDIN_SENTINEL"

    command = AgentCommand(
        argv=(sys.executable, "-c", "pass"),
        stdin_text=private_prompt,
    )

    assert command.stdin_text == private_prompt
    assert private_prompt not in repr(command)


def test_invoke_agent_transports_prompt_via_private_stdin(
    tmp_path: Path,
) -> None:
    prompt = "LOCKSTEP_PROMPT_SENTINEL\nmultiline λ\n"
    expected = hashlib.sha256(prompt.encode("utf-8")).hexdigest()

    result = invoke_agent(
        _StdinAdapter(),
        _request(tmp_path, prompt=prompt),
        parent_env={},
    )

    assert isinstance(result, AgentInvocationResult)
    assert result.process.returncode == 0
    assert result.process.stdout == expected + "\n"

    assert prompt not in result.process.argv
    assert prompt not in repr(result)
    assert not hasattr(result, "stdin_text")
    assert not hasattr(result.process, "stdin_text")


def test_timeout_after_stdin_preserves_timeout_semantics_and_privacy(
    tmp_path: Path,
) -> None:
    prompt = "LOCKSTEP_TIMEOUT_STDIN_PRIVATE"

    with pytest.raises(ProcessTimeoutError) as exc_info:
        invoke_agent(
            _TimeoutAfterInputAdapter(),
            _request(
                tmp_path,
                prompt=prompt,
                timeout_seconds=0.2,
            ),
            parent_env={},
        )

    assert exc_info.value.stdout == "received\n"
    assert prompt not in exc_info.value.argv
    assert prompt not in str(exc_info.value)
    assert not hasattr(exc_info.value, "stdin_text")
