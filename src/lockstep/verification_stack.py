"""The complete Contract verification stack, run directly and without a shell.

``SubphaseContract.verification_commands`` is a tuple of strings. This module
turns each string into argv with :func:`shlex.split` (POSIX rules), runs every
command directly through :func:`~lockstep.process.run_process` in Contract
order, and stops at the first failure. Nothing is ever handed to a shell, so a
string such as ``pytest && ruff check`` cannot gain shell semantics: shell
control tokens are rejected before anything runs.

The whole stack is one verification *stage*. It produces exactly two typed
artifacts:

* the existing domain :class:`~lockstep.domain.VerificationReport`, the
  semantic result of the stage (every attempted command, and the failure if
  there was one);
* a :class:`VerificationEvidenceRecord`, a bounded sidecar of ordered
  per-command process evidence (argv, exit code, captured output).

The sidecar supports the report; it is not a second report and carries no
Contract authority.
"""

from __future__ import annotations

import shlex
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from lockstep.domain import (
    AttemptNumber,
    PhaseId,
    RunId,
    SchemaVersion,
    SubphaseId,
    VerificationFinding,
    VerificationReport,
)
from lockstep.process import ProcessResult, run_process

_CURRENT_SCHEMA_VERSION: SchemaVersion = SchemaVersion.model_validate(1)

# Tokens that only mean something to a shell. Each would silently be passed to a
# program as a literal argument if left in argv, so they are refused outright.
_SHELL_OPERATOR_TOKENS: frozenset[str] = frozenset(
    {"&&", "||", ";", ";;", "|", "|&", "&", ">", ">>", "<", "<<", "<<<", "&>", "2>", "2>>", "2>&1"}
)
_SHELL_SUBSTITUTION_MARKERS: tuple[str, ...] = ("$(", "`")


class VerificationCommandError(Exception):
    """A Contract verification command cannot be run as direct, shell-free argv.

    Carries a short sanitized ``reason`` that never echoes the command text.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"verification command error: {reason}")


def parse_verification_command(text: str) -> tuple[str, ...]:
    """Split one Contract verification string into direct argv, or reject it."""
    if not text.strip():
        raise VerificationCommandError("command is empty")
    if "\x00" in text:
        raise VerificationCommandError("command contains NUL")
    try:
        argv = tuple(shlex.split(text, posix=True))
    except ValueError:
        raise VerificationCommandError("command has unbalanced quoting") from None
    if not argv:
        raise VerificationCommandError("command is empty")
    for token in argv:
        if token in _SHELL_OPERATOR_TOKENS or any(m in token for m in _SHELL_SUBSTITUTION_MARKERS):
            raise VerificationCommandError("command uses shell syntax, which is not executed")
    return argv


def parse_verification_stack(commands: Sequence[str]) -> tuple[tuple[str, ...], ...]:
    """Parse every command of a stack, preserving Contract order; one bad command rejects all."""
    return tuple(parse_verification_command(command) for command in commands)


class _EvidenceModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class CommandEvidence(_EvidenceModel):
    """What one directly executed verification command did."""

    argv: Annotated[tuple[str, ...], Field(min_length=1)]
    exit_code: int
    stdout: str
    stderr: str
    stdout_truncated: bool
    stderr_truncated: bool
    elapsed_seconds: float | None = None


class VerificationEvidenceRecord(_EvidenceModel):
    """Ordered, bounded process evidence for one verification stage of one attempt.

    Supporting evidence for a :class:`~lockstep.domain.VerificationReport`; it
    states no verdict of its own and amends nothing.
    """

    schema_version: SchemaVersion = _CURRENT_SCHEMA_VERSION
    run_id: RunId
    phase_id: PhaseId
    subphase_id: SubphaseId
    attempt: AttemptNumber
    max_output_bytes: Annotated[int, Field(ge=1)]
    commands: Annotated[tuple[CommandEvidence, ...], Field(min_length=1)]

    @field_validator("schema_version")
    @classmethod
    def _reject_unsupported_schema_version(cls, value: SchemaVersion) -> SchemaVersion:
        if value.root != _CURRENT_SCHEMA_VERSION.root:
            raise ValueError(f"unsupported schema_version {value.root}")
        return value

    @model_validator(mode="after")
    def _enforce_output_bound(self) -> VerificationEvidenceRecord:
        for entry in self.commands:
            for text in (entry.stdout, entry.stderr):
                if len(text.encode("utf-8")) > self.max_output_bytes:
                    raise ValueError("captured output exceeds the recorded bound")
        return self


@dataclass(frozen=True, slots=True)
class VerificationStackResult:
    """The two artifacts one verification stage produces."""

    report: VerificationReport
    evidence: VerificationEvidenceRecord

    @property
    def passed(self) -> bool:
        return self.report.passed


def _bound(text: str, limit: int, already_truncated: bool) -> tuple[str, bool]:
    """Keep at most *limit* UTF-8 bytes of the tail of *text*."""
    data = text.encode("utf-8")
    if len(data) <= limit:
        return text, already_truncated
    return data[-limit:].decode("utf-8", errors="ignore"), True


def run_command_evidence(
    commands: Sequence[Sequence[str]],
    *,
    cwd: Path,
    env: Mapping[str, str],
    timeout_seconds: float,
    max_output_bytes: int,
    termination_grace_seconds: float = 0.25,
    runner: Callable[..., ProcessResult] = run_process,
) -> tuple[CommandEvidence, ...]:
    """Run *commands* directly, in order, stopping after the first non-zero exit.

    Returns the bounded evidence of every command that was attempted. A non-zero
    exit is ordinary evidence, not an error; launch failure, invalid configuration
    and timeout propagate from the process runner unchanged. This is the one
    command-running primitive shared by the Contract verification stage and the
    Phase gate, so every process either launches goes through the same place.
    """
    if not commands:
        raise VerificationCommandError("no verification commands were supplied")

    attempted: list[CommandEvidence] = []
    for argv in commands:
        result = runner(
            tuple(argv),
            cwd=cwd,
            env=env,
            timeout_seconds=timeout_seconds,
            max_output_bytes=max_output_bytes,
            termination_grace_seconds=termination_grace_seconds,
        )
        stdout, stdout_truncated = _bound(result.stdout, max_output_bytes, result.stdout_truncated)
        stderr, stderr_truncated = _bound(result.stderr, max_output_bytes, result.stderr_truncated)
        attempted.append(
            CommandEvidence(
                argv=result.argv,
                exit_code=result.returncode,
                stdout=stdout,
                stderr=stderr,
                stdout_truncated=stdout_truncated,
                stderr_truncated=stderr_truncated,
                elapsed_seconds=result.elapsed_seconds,
            )
        )
        if result.returncode != 0:
            break
    return tuple(attempted)


def run_verification_stack(
    commands: Sequence[Sequence[str]],
    *,
    run_id: RunId,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
    cwd: Path,
    env: Mapping[str, str],
    timeout_seconds: float,
    max_output_bytes: int,
    termination_grace_seconds: float = 0.25,
    runner: Callable[..., ProcessResult] = run_process,
) -> VerificationStackResult:
    """Run every command of *commands* in order, stopping at the first failure.

    A non-zero exit is a normal failed stage, reported rather than raised; launch
    failure, invalid configuration and timeout propagate from the process runner
    unchanged. *runner* is the process-execution seam (by default
    :func:`~lockstep.process.run_process`); a caller that already owns such a seam
    passes it so every process it launches goes through one place.
    """
    attempted = run_command_evidence(
        commands,
        cwd=cwd,
        env=env,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=termination_grace_seconds,
        runner=runner,
    )
    failure: VerificationFinding | None = None
    last = attempted[-1]
    if last.exit_code != 0:
        failure = VerificationFinding(
            observation=f"command exited with returncode {last.exit_code}",
            expected="command exits with returncode 0",
            reproduction=shlex.join(last.argv),
        )

    report = VerificationReport(
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=attempt,
        passed=failure is None,
        commands=tuple(shlex.join(entry.argv) for entry in attempted),
        failures=() if failure is None else (failure,),
    )
    evidence = VerificationEvidenceRecord(
        run_id=run_id,
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=attempt,
        max_output_bytes=max_output_bytes,
        commands=attempted,
    )
    return VerificationStackResult(report=report, evidence=evidence)
