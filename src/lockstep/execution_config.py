"""Typed project execution policy: the ``[execution]`` table of ``lockstep.toml``.

``[routing]`` says *who* runs each role; ``[execution]`` says *how* the host
runs deterministic project commands and bounds each operation. It is the one
tracked, strict source of:

* ``baseline_argv`` -- the command prefix that confirms the frozen tests are RED;
* ``planner_quality_argv`` -- the command prefix that checks Planner-authored tests;
* the per-operation agent/command timeouts, captured-output bound and
  termination grace.

Commands are structured argv, never shell strings, and are never executed
through a shell. The host appends the frozen test paths to a command prefix, so a
project that needs richer invocation configures a repository-owned wrapper.

The two project-specific commands deliberately have no default. A configuration
that omits them still *parses* (so an older ``lockstep.toml`` stays valid), but
:func:`require_autonomous_execution` refuses it: it is not ready for canonical
autonomous execution. The limits default to the values the accepted transaction
request already used.

Pure: no filesystem, environment, process or clock access.
"""

from __future__ import annotations

import os
from collections.abc import Callable
from dataclasses import dataclass

_DEFAULT_AGENT_TIMEOUT_SECONDS = 30.0
_DEFAULT_COMMAND_TIMEOUT_SECONDS = 30.0
_DEFAULT_MAX_OUTPUT_BYTES = 1_048_576
_DEFAULT_TERMINATION_GRACE_SECONDS = 0.25

_COMMAND_KEYS: tuple[str, ...] = ("baseline_argv", "planner_quality_argv")
_LIMIT_KEYS: tuple[str, ...] = (
    "agent_timeout_seconds",
    "command_timeout_seconds",
    "max_output_bytes",
    "termination_grace_seconds",
)
_EXECUTION_KEYS: frozenset[str] = frozenset(_COMMAND_KEYS + _LIMIT_KEYS)

# A command whose executable is a shell would reintroduce shell semantics
# (``sh -c "a && b"``) that structured argv exists to rule out.
_SHELL_LAUNCHERS: frozenset[str] = frozenset(
    {"sh", "bash", "zsh", "dash", "ksh", "csh", "tcsh", "fish"}
)


class ExecutionConfigError(Exception):
    """The execution policy is malformed or insufficient.

    Carries a short sanitized ``reason`` that may name a key or an argv index
    but never echoes a configured value.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"execution config error: {reason}")


@dataclass(frozen=True, slots=True)
class ExecutionConfig:
    """Project execution policy. Empty command tuples mean "not configured"."""

    baseline_argv: tuple[str, ...] = ()
    planner_quality_argv: tuple[str, ...] = ()
    agent_timeout_seconds: float = _DEFAULT_AGENT_TIMEOUT_SECONDS
    command_timeout_seconds: float = _DEFAULT_COMMAND_TIMEOUT_SECONDS
    max_output_bytes: int = _DEFAULT_MAX_OUTPUT_BYTES
    termination_grace_seconds: float = _DEFAULT_TERMINATION_GRACE_SECONDS


def require_autonomous_execution(config: ExecutionConfig) -> None:
    """Refuse a configuration that cannot drive canonical autonomous execution."""
    if not config.baseline_argv:
        raise ExecutionConfigError("execution.baseline_argv is not configured")
    if not config.planner_quality_argv:
        raise ExecutionConfigError("execution.planner_quality_argv is not configured")


def _parse_argv(raw: object, *, key: str) -> tuple[str, ...]:
    if not isinstance(raw, list) or not raw:
        raise ExecutionConfigError(f"execution.{key} must be a non-empty array of strings")
    entries: list[str] = []
    for index, entry in enumerate(raw):
        if not isinstance(entry, str):
            raise ExecutionConfigError(f"execution.{key}[{index}] must be a string")
        if not entry.strip() or "\x00" in entry:
            raise ExecutionConfigError(f"execution.{key}[{index}] must be a non-blank string")
        entries.append(entry)
    if os.path.basename(entries[0]) in _SHELL_LAUNCHERS:
        raise ExecutionConfigError(f"execution.{key} must not launch a shell")
    return tuple(entries)


def _parse_number(raw: object, *, key: str, minimum_exclusive: bool) -> float:
    if isinstance(raw, bool) or not isinstance(raw, int | float):
        raise ExecutionConfigError(f"execution.{key} must be a number")
    value = float(raw)
    if value != value or value in (float("inf"), float("-inf")):
        raise ExecutionConfigError(f"execution.{key} must be finite")
    if minimum_exclusive and value <= 0:
        raise ExecutionConfigError(f"execution.{key} must be greater than zero")
    if not minimum_exclusive and value < 0:
        raise ExecutionConfigError(f"execution.{key} must not be negative")
    return value


def _parse_max_output_bytes(raw: object) -> int:
    if isinstance(raw, bool) or not isinstance(raw, int):
        raise ExecutionConfigError("execution.max_output_bytes must be an integer")
    if raw <= 0:
        raise ExecutionConfigError("execution.max_output_bytes must be greater than zero")
    return raw


def parse_execution_table(raw: object) -> ExecutionConfig:
    """Parse a decoded ``[execution]`` TOML table, rejecting anything unknown."""
    if not isinstance(raw, dict):
        raise ExecutionConfigError("execution must be a table")

    extra = set(raw) - _EXECUTION_KEYS
    if extra:
        raise ExecutionConfigError(f"execution has unknown field: {min(extra)}")

    defaults = ExecutionConfig()
    return ExecutionConfig(
        baseline_argv=(
            _parse_argv(raw["baseline_argv"], key="baseline_argv")
            if "baseline_argv" in raw
            else defaults.baseline_argv
        ),
        planner_quality_argv=(
            _parse_argv(raw["planner_quality_argv"], key="planner_quality_argv")
            if "planner_quality_argv" in raw
            else defaults.planner_quality_argv
        ),
        agent_timeout_seconds=(
            _parse_number(
                raw["agent_timeout_seconds"], key="agent_timeout_seconds", minimum_exclusive=True
            )
            if "agent_timeout_seconds" in raw
            else defaults.agent_timeout_seconds
        ),
        command_timeout_seconds=(
            _parse_number(
                raw["command_timeout_seconds"],
                key="command_timeout_seconds",
                minimum_exclusive=True,
            )
            if "command_timeout_seconds" in raw
            else defaults.command_timeout_seconds
        ),
        max_output_bytes=(
            _parse_max_output_bytes(raw["max_output_bytes"])
            if "max_output_bytes" in raw
            else defaults.max_output_bytes
        ),
        termination_grace_seconds=(
            _parse_number(
                raw["termination_grace_seconds"],
                key="termination_grace_seconds",
                minimum_exclusive=False,
            )
            if "termination_grace_seconds" in raw
            else defaults.termination_grace_seconds
        ),
    )


def render_execution_lines(config: ExecutionConfig, quote: Callable[[str], str]) -> list[str]:
    """Render the ``[execution]`` table in a fixed order; nothing for the default policy.

    Only values that differ from the default are emitted, so the default policy
    round-trips without introducing a table an older file never had.
    """
    defaults = ExecutionConfig()
    body: list[str] = []
    for key in _COMMAND_KEYS:
        argv: tuple[str, ...] = getattr(config, key)
        if argv:
            body.append(f"{key} = [{', '.join(quote(entry) for entry in argv)}]")
    for key in _LIMIT_KEYS:
        value = getattr(config, key)
        if value != getattr(defaults, key):
            body.append(f"{key} = {value!r}")
    if not body:
        return []
    return ["", "[execution]", *body]
