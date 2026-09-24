import os
import sys
import time
from dataclasses import FrozenInstanceError
from pathlib import Path

import pytest

from lockstep.process import (
    ProcessConfigurationError,
    ProcessLaunchError,
    ProcessResult,
    ProcessTimeoutError,
    run_process,
)


def _python(*args: str) -> tuple[str, ...]:
    return (sys.executable, *args)


def test_success_captures_stdout_and_stderr(tmp_path: Path) -> None:
    result = run_process(
        _python(
            "-c",
            "import sys; print('out'); print('err', file=sys.stderr)",
        ),
        cwd=tmp_path,
        env={},
        timeout_seconds=5,
    )

    assert isinstance(result, ProcessResult)
    assert result.returncode == 0
    assert result.stdout == "out\n"
    assert result.stderr == "err\n"
    assert result.stdout_truncated is False
    assert result.stderr_truncated is False
    assert result.succeeded is True


def test_nonzero_exit_is_returned_not_raised(tmp_path: Path) -> None:
    result = run_process(
        _python(
            "-c",
            "import sys; print('bad', file=sys.stderr); raise SystemExit(7)",
        ),
        cwd=tmp_path,
        env={},
        timeout_seconds=5,
    )

    assert result.returncode == 7
    assert result.stderr == "bad\n"
    assert result.succeeded is False


def test_runner_uses_explicit_working_directory(tmp_path: Path) -> None:
    nested = tmp_path / "nested"
    nested.mkdir()

    result = run_process(
        _python(
            "-c",
            "import pathlib; print(pathlib.Path.cwd())",
        ),
        cwd=nested,
        env={},
        timeout_seconds=5,
    )

    assert result.stdout.strip() == str(nested.resolve())


def test_environment_is_exact_not_implicitly_inherited(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("LOCKSTEP_PARENT_SECRET", "must-not-leak")

    absent = run_process(
        _python(
            "-c",
            "import os; print(os.environ.get('LOCKSTEP_PARENT_SECRET', 'missing'))",
        ),
        cwd=tmp_path,
        env={},
        timeout_seconds=5,
    )

    explicit = run_process(
        _python(
            "-c",
            "import os; print(os.environ['LOCKSTEP_CHILD_VALUE'])",
        ),
        cwd=tmp_path,
        env={"LOCKSTEP_CHILD_VALUE": "explicit"},
        timeout_seconds=5,
    )

    assert absent.stdout == "missing\n"
    assert explicit.stdout == "explicit\n"


def test_stdin_is_closed_to_interactive_input(tmp_path: Path) -> None:
    result = run_process(
        _python(
            "-c",
            "import sys; print(repr(sys.stdin.read()))",
        ),
        cwd=tmp_path,
        env={},
        timeout_seconds=5,
    )

    assert result.stdout == "''\n"


def test_argv_is_not_interpreted_by_a_shell(tmp_path: Path) -> None:
    payload = "$(touch SHOULD_NOT_EXIST); * ; echo injected"

    result = run_process(
        _python(
            "-c",
            "import sys; print(sys.argv[1])",
            payload,
        ),
        cwd=tmp_path,
        env={},
        timeout_seconds=5,
    )

    assert result.stdout == payload + "\n"
    assert not (tmp_path / "SHOULD_NOT_EXIST").exists()


def test_output_is_bounded_and_tail_preserved(tmp_path: Path) -> None:
    result = run_process(
        _python(
            "-c",
            "import sys; sys.stdout.write('abcdefghijklmnopqrst')",
        ),
        cwd=tmp_path,
        env={},
        timeout_seconds=5,
        max_output_bytes=8,
    )

    assert result.stdout == "mnopqrst"
    assert result.stdout_truncated is True
    assert result.stderr == ""
    assert result.stderr_truncated is False


def test_stdout_and_stderr_are_bounded_independently(
    tmp_path: Path,
) -> None:
    result = run_process(
        _python(
            "-c",
            ("import sys; sys.stdout.write('0123456789'); sys.stderr.write('abcdefghij')"),
        ),
        cwd=tmp_path,
        env={},
        timeout_seconds=5,
        max_output_bytes=4,
    )

    assert result.stdout == "6789"
    assert result.stderr == "ghij"
    assert result.stdout_truncated is True
    assert result.stderr_truncated is True


def test_invalid_utf8_is_replaced_in_captured_output(
    tmp_path: Path,
) -> None:
    result = run_process(
        _python(
            "-c",
            "import sys; sys.stdout.buffer.write(b'good\\xffbad')",
        ),
        cwd=tmp_path,
        env={},
        timeout_seconds=5,
    )

    assert result.stdout == "good\ufffdbad"


def test_missing_executable_raises_launch_error(tmp_path: Path) -> None:
    argv = (str(tmp_path / "does-not-exist"),)

    with pytest.raises(ProcessLaunchError) as exc_info:
        run_process(
            argv,
            cwd=tmp_path,
            env={},
            timeout_seconds=5,
        )

    assert exc_info.value.argv == argv
    assert exc_info.value.cwd == tmp_path.resolve()
    assert exc_info.value.reason
    assert exc_info.value.returncode is None


def test_missing_working_directory_raises_launch_error(tmp_path: Path) -> None:
    missing = tmp_path / "missing"

    with pytest.raises(ProcessLaunchError) as exc_info:
        run_process(
            _python("-c", "print('never')"),
            cwd=missing,
            env={},
            timeout_seconds=5,
        )

    assert exc_info.value.cwd == missing.resolve()
    assert exc_info.value.reason


@pytest.mark.parametrize(
    ("argv", "timeout_seconds", "max_output_bytes", "termination_grace_seconds"),
    [
        ((), 1.0, 1024, 0.1),
        ((_python("-c", "pass")), 0.0, 1024, 0.1),
        ((_python("-c", "pass")), -1.0, 1024, 0.1),
        ((_python("-c", "pass")), 1.0, 0, 0.1),
        ((_python("-c", "pass")), 1.0, -1, 0.1),
        ((_python("-c", "pass")), 1.0, 1024, -0.1),
    ],
)
def test_invalid_runner_configuration_is_rejected(
    tmp_path: Path,
    argv: tuple[str, ...],
    timeout_seconds: float,
    max_output_bytes: int,
    termination_grace_seconds: float,
) -> None:
    with pytest.raises(ProcessConfigurationError):
        run_process(
            argv,
            cwd=tmp_path,
            env={},
            timeout_seconds=timeout_seconds,
            max_output_bytes=max_output_bytes,
            termination_grace_seconds=termination_grace_seconds,
        )


def test_result_is_immutable(tmp_path: Path) -> None:
    result = run_process(
        _python("-c", "print('ok')"),
        cwd=tmp_path,
        env={},
        timeout_seconds=5,
    )

    with pytest.raises(FrozenInstanceError):
        result.returncode = 99  # type: ignore[misc]


def test_timeout_exposes_partial_output_and_terminates_process(
    tmp_path: Path,
) -> None:
    with pytest.raises(ProcessTimeoutError) as exc_info:
        run_process(
            _python(
                "-u",
                "-c",
                (
                    "import sys, time; "
                    "print('started'); "
                    "print('problem', file=sys.stderr); "
                    "time.sleep(60)"
                ),
            ),
            cwd=tmp_path,
            env={},
            timeout_seconds=0.2,
            termination_grace_seconds=0.1,
        )

    assert exc_info.value.stdout == "started\n"
    assert exc_info.value.stderr == "problem\n"
    assert exc_info.value.timeout_seconds == 0.2
    assert exc_info.value.argv[0] == sys.executable


@pytest.mark.skipif(os.name != "posix", reason="process-group semantics are POSIX-specific")
def test_timeout_terminates_descendant_processes(tmp_path: Path) -> None:
    marker = tmp_path / "descendant-survived"

    script = (
        "import pathlib, subprocess, sys, time; "
        "marker = sys.argv[1]; "
        "subprocess.Popen(["
        "sys.executable, '-c', "
        "'import pathlib, sys, time; "
        'time.sleep(0.6); pathlib.Path(sys.argv[1]).write_text("alive")\', '
        "marker]); "
        "time.sleep(60)"
    )

    with pytest.raises(ProcessTimeoutError):
        run_process(
            _python("-c", script, str(marker)),
            cwd=tmp_path,
            env={},
            timeout_seconds=0.2,
            termination_grace_seconds=0.1,
        )

    time.sleep(0.8)

    assert not marker.exists()
