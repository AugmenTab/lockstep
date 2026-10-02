"""Deterministic subprocess execution primitive.

Runs a caller-supplied ``argv`` in a caller-supplied environment with
bounded output capture, a hard timeout, and POSIX process-group
termination on timeout. Non-zero child exits are reported through
``ProcessResult``; only launch failure, invalid configuration, and
timeout are raised.
"""

from __future__ import annotations

import contextlib
import os
import signal
import subprocess
import tempfile
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import BinaryIO

from lockstep.process.budget import active_run_time_budget

_DEFAULT_MAX_OUTPUT_BYTES = 1_048_576
_POST_KILL_REAP_TIMEOUT_SECONDS = 5.0


def _utc_now() -> datetime:
    return datetime.now(UTC)


@dataclass(frozen=True, slots=True)
class ProcessResult:
    """Immutable record of a completed child process invocation.

    ``started_at``/``completed_at`` are wall-clock instants; ``elapsed_seconds``
    is measured with a monotonic clock and is deliberately not derived from
    them. All three are ``None`` only for results not produced by
    :func:`run_process`.
    """

    argv: tuple[str, ...]
    cwd: Path
    returncode: int
    stdout: str
    stderr: str
    stdout_truncated: bool
    stderr_truncated: bool
    started_at: datetime | None = None
    completed_at: datetime | None = None
    elapsed_seconds: float | None = None

    @property
    def succeeded(self) -> bool:
        return self.returncode == 0


class ProcessConfigurationError(Exception):
    """Runner arguments failed deterministic precondition checks."""

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(reason)


class ProcessLaunchError(Exception):
    """The child process could not be started."""

    def __init__(
        self,
        *,
        argv: tuple[str, ...],
        cwd: Path,
        reason: str,
        returncode: int | None = None,
    ) -> None:
        self.argv = argv
        self.cwd = cwd
        self.reason = reason
        self.returncode = returncode
        super().__init__(f"failed to launch {argv!r} in {cwd}: {reason}")


class ProcessTimeoutError(Exception):
    """The child process exceeded its hard deadline and was terminated."""

    def __init__(
        self,
        *,
        argv: tuple[str, ...],
        cwd: Path,
        timeout_seconds: float,
        stdout: str,
        stderr: str,
        stdout_truncated: bool,
        stderr_truncated: bool,
        started_at: datetime | None = None,
        completed_at: datetime | None = None,
        elapsed_seconds: float | None = None,
    ) -> None:
        self.argv = argv
        self.cwd = cwd
        self.timeout_seconds = timeout_seconds
        self.stdout = stdout
        self.stderr = stderr
        self.stdout_truncated = stdout_truncated
        self.stderr_truncated = stderr_truncated
        self.started_at = started_at
        self.completed_at = completed_at
        self.elapsed_seconds = elapsed_seconds
        super().__init__(f"process {argv!r} in {cwd} exceeded timeout of {timeout_seconds}s")


class RunBudgetTimeoutError(ProcessTimeoutError):
    """The unattended run's wall-clock budget, not the stage's own timeout, ended the launch.

    Raised when no run time remained at launch (nothing was started) or when the remaining run
    time was the limiting timeout. It is a :class:`ProcessTimeoutError` so every existing handler
    still treats the operation as timed out, but the policy that caused the stop stays
    distinguishable from an ordinary provider or command failure.
    """


def _validate_argv(argv: Sequence[str]) -> tuple[str, ...]:
    if len(argv) == 0:
        raise ProcessConfigurationError("argv must not be empty")
    normalized: list[str] = []
    for index, entry in enumerate(argv):
        if not isinstance(entry, str):
            raise ProcessConfigurationError(
                f"argv[{index}] must be str, got {type(entry).__name__}"
            )
        if "\x00" in entry:
            raise ProcessConfigurationError(f"argv[{index}] contains an embedded NUL character")
        normalized.append(entry)
    return tuple(normalized)


def _validate_stdin_text(stdin_text: object) -> bytes | None:
    if stdin_text is None:
        return None
    if not isinstance(stdin_text, str):
        raise ProcessConfigurationError(f"stdin_text must be str, got {type(stdin_text).__name__}")
    try:
        return stdin_text.encode("utf-8", errors="strict")
    except UnicodeEncodeError:
        raise ProcessConfigurationError("stdin_text must be valid UTF-8 text") from None


def _validate_env(env: Mapping[str, str]) -> dict[str, str]:
    validated: dict[str, str] = {}
    for key, value in env.items():
        if not isinstance(key, str):
            raise ProcessConfigurationError(f"env keys must be str, got {type(key).__name__}")
        if not isinstance(value, str):
            raise ProcessConfigurationError(
                f"env value for {key!r} must be str, got {type(value).__name__}"
            )
        if "\x00" in key:
            raise ProcessConfigurationError(f"env key {key!r} contains an embedded NUL character")
        if "\x00" in value:
            raise ProcessConfigurationError(
                f"env value for {key!r} contains an embedded NUL character"
            )
        validated[key] = value
    return validated


def _read_bounded_tail(handle: BinaryIO, max_bytes: int) -> tuple[str, bool]:
    handle.flush()
    size = handle.seek(0, os.SEEK_END)
    truncated = size > max_bytes
    start = size - max_bytes if truncated else 0
    handle.seek(start)
    data = handle.read()
    return data.decode("utf-8", errors="replace"), truncated


def _terminate_process_tree(
    proc: subprocess.Popen[bytes],
    grace_seconds: float,
) -> None:
    if os.name == "posix":
        try:
            pgid = os.getpgid(proc.pid)
        except ProcessLookupError:
            pgid = proc.pid
        with contextlib.suppress(ProcessLookupError):
            os.killpg(pgid, signal.SIGTERM)
        try:
            proc.wait(timeout=grace_seconds)
            return
        except subprocess.TimeoutExpired:
            pass
        with contextlib.suppress(ProcessLookupError):
            os.killpg(pgid, signal.SIGKILL)
    else:
        with contextlib.suppress(ProcessLookupError):
            proc.terminate()
        try:
            proc.wait(timeout=grace_seconds)
            return
        except subprocess.TimeoutExpired:
            pass
        with contextlib.suppress(ProcessLookupError):
            proc.kill()
    with contextlib.suppress(subprocess.TimeoutExpired):
        proc.wait(timeout=_POST_KILL_REAP_TIMEOUT_SECONDS)


def run_process(
    argv: Sequence[str],
    *,
    cwd: Path,
    env: Mapping[str, str],
    timeout_seconds: float,
    max_output_bytes: int = _DEFAULT_MAX_OUTPUT_BYTES,
    termination_grace_seconds: float = 0.25,
    stdin_text: str | None = None,
    monotonic: Callable[[], float] = time.monotonic,
    wall_clock: Callable[[], datetime] = _utc_now,
) -> ProcessResult:
    """Execute *argv* deterministically and return its result.

    The child is launched with the exact caller-supplied environment
    and working directory, bounded stdout/stderr capture, and a hard
    timeout. Stdin defaults to ``DEVNULL``; when ``stdin_text`` is
    supplied its UTF-8 encoding is written to a private temporary file
    that the child reads to EOF. Non-zero exits return a
    ``ProcessResult``; launch failure, invalid configuration, and
    timeout raise. Both the result and the timeout error carry host timing:
    each of *monotonic* and *wall_clock* is read exactly twice, immediately
    before launch and immediately after the child is reaped.

    While an unattended run's :class:`~lockstep.process.budget.RunTimeBudget` is active, no
    process starts once its time is spent (:class:`RunBudgetTimeoutError`), and *timeout_seconds*
    is capped to the time that remains; a timeout that cap caused is raised as the same typed
    error, so the stop is attributable to the run policy rather than to the process.
    """
    validated_argv = _validate_argv(argv)
    if timeout_seconds <= 0:
        raise ProcessConfigurationError(f"timeout_seconds must be > 0, got {timeout_seconds}")
    if max_output_bytes <= 0:
        raise ProcessConfigurationError(f"max_output_bytes must be > 0, got {max_output_bytes}")
    if termination_grace_seconds < 0:
        raise ProcessConfigurationError(
            f"termination_grace_seconds must be >= 0, got {termination_grace_seconds}"
        )
    stdin_bytes = _validate_stdin_text(stdin_text)
    validated_env = _validate_env(env)
    resolved_cwd = cwd.resolve()

    # An unattended run's remaining wall-clock budget is a stricter upper bound than the stage's
    # own timeout; whichever stops the operation sooner wins, and no launch starts past it.
    budget = active_run_time_budget()
    budget_limited = False
    if budget is not None:
        remaining = budget.remaining_seconds()
        if remaining <= 0:
            budget.mark_exhausted()
            raise RunBudgetTimeoutError(
                argv=validated_argv,
                cwd=resolved_cwd,
                timeout_seconds=0.0,
                stdout="",
                stderr="",
                stdout_truncated=False,
                stderr_truncated=False,
            )
        if remaining < timeout_seconds:
            timeout_seconds = remaining
            budget_limited = True

    with contextlib.ExitStack() as stack:
        stdout_handle = stack.enter_context(tempfile.TemporaryFile())
        stderr_handle = stack.enter_context(tempfile.TemporaryFile())
        if stdin_bytes is None:
            child_stdin: int | BinaryIO = subprocess.DEVNULL
        else:
            stdin_handle = stack.enter_context(tempfile.TemporaryFile())
            stdin_handle.write(stdin_bytes)
            stdin_handle.flush()
            stdin_handle.seek(0)
            child_stdin = stdin_handle

        started_at = wall_clock()
        started_mono = monotonic()
        try:
            proc: subprocess.Popen[bytes] = subprocess.Popen(
                validated_argv,
                cwd=str(resolved_cwd),
                env=validated_env,
                stdin=child_stdin,
                stdout=stdout_handle,
                stderr=stderr_handle,
                shell=False,
                start_new_session=os.name == "posix",
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise ProcessLaunchError(
                argv=validated_argv,
                cwd=resolved_cwd,
                reason=str(exc) or type(exc).__name__,
            ) from exc

        try:
            proc.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            _terminate_process_tree(proc, termination_grace_seconds)
            completed_at = wall_clock()
            elapsed_seconds = max(0.0, monotonic() - started_mono)
            stdout, stdout_truncated = _read_bounded_tail(stdout_handle, max_output_bytes)
            stderr, stderr_truncated = _read_bounded_tail(stderr_handle, max_output_bytes)
            if budget_limited and budget is not None:
                budget.mark_exhausted()
            timeout_type = RunBudgetTimeoutError if budget_limited else ProcessTimeoutError
            raise timeout_type(
                argv=validated_argv,
                cwd=resolved_cwd,
                timeout_seconds=timeout_seconds,
                stdout=stdout,
                stderr=stderr,
                stdout_truncated=stdout_truncated,
                stderr_truncated=stderr_truncated,
                started_at=started_at,
                completed_at=completed_at,
                elapsed_seconds=elapsed_seconds,
            ) from None

        completed_at = wall_clock()
        elapsed_seconds = max(0.0, monotonic() - started_mono)
        stdout, stdout_truncated = _read_bounded_tail(stdout_handle, max_output_bytes)
        stderr, stderr_truncated = _read_bounded_tail(stderr_handle, max_output_bytes)
        return ProcessResult(
            argv=validated_argv,
            cwd=resolved_cwd,
            returncode=proc.returncode,
            stdout=stdout,
            stderr=stderr,
            stdout_truncated=stdout_truncated,
            stderr_truncated=stderr_truncated,
            started_at=started_at,
            completed_at=completed_at,
            elapsed_seconds=elapsed_seconds,
        )
