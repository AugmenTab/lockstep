"""Phase 11.5: the project-wide Phase-gate verification stack in ``[execution]``.

``execution.phase_gate_commands`` is project execution policy: an ordered list of structured
argv arrays that audit a completed Phase as a whole. It is deliberately distinct from every
Contract's ``verification_commands`` and from ``baseline_argv`` / ``planner_quality_argv``,
and it has no default: a project that has not configured it cannot run a Phase gate.

Baseline classification: RED at entry (``phase_gate_commands`` and
``require_phase_gate_execution`` do not exist).
"""

from __future__ import annotations

import dataclasses
import json
import tomllib
from typing import Any

import pytest

from lockstep.execution_config import (
    ExecutionConfig,
    ExecutionConfigError,
    parse_execution_table,
    render_execution_lines,
    require_autonomous_execution,
    require_phase_gate_execution,
)

_STACK = [["./scripts/check"], ["./scripts/integration-smoke", "--fast"]]


def test_the_default_policy_has_no_phase_gate_stack() -> None:
    assert ExecutionConfig().phase_gate_commands == ()
    assert "phase_gate_commands" in {f.name for f in dataclasses.fields(ExecutionConfig)}


def test_the_stack_parses_to_ordered_structured_argv() -> None:
    config = parse_execution_table({"phase_gate_commands": _STACK})

    assert config.phase_gate_commands == (
        ("./scripts/check",),
        ("./scripts/integration-smoke", "--fast"),
    )


def test_the_stack_is_independent_of_the_contract_scoped_commands() -> None:
    config = parse_execution_table(
        {
            "baseline_argv": ["pytest"],
            "planner_quality_argv": ["ruff", "check"],
            "phase_gate_commands": [["./scripts/check"]],
        }
    )

    assert config.baseline_argv == ("pytest",)
    assert config.planner_quality_argv == ("ruff", "check")
    assert config.phase_gate_commands == (("./scripts/check",),)


@pytest.mark.parametrize(
    "raw",
    [
        "./scripts/check",  # not an array
        [],  # empty stack is "not configured", never an empty configured stack
        ["./scripts/check"],  # one flat argv, not an array of argv arrays
        [[]],  # an empty argv
        [["./scripts/check", 3]],  # a non-string argument
        [["./scripts/check", " "]],  # a blank argument
        [["\x00"]],  # NUL
        [["bash", "-c", "make check"]],  # a shell launcher
        [["/bin/sh", "-c", "a && b"]],  # a shell launcher by path
        [["./scripts/check"], "extra"],  # a mixed stack
    ],
)
def test_a_malformed_stack_is_rejected_without_echoing_values(raw: Any) -> None:
    with pytest.raises(ExecutionConfigError) as caught:
        parse_execution_table({"phase_gate_commands": raw})

    assert "phase_gate_commands" in caught.value.reason
    assert "make check" not in caught.value.reason


def test_unknown_execution_keys_are_still_rejected() -> None:
    with pytest.raises(ExecutionConfigError):
        parse_execution_table({"phase_gate_command": [["./scripts/check"]]})


def test_the_stack_round_trips_through_the_rendered_toml_table() -> None:
    config = parse_execution_table({"phase_gate_commands": _STACK, "max_output_bytes": 4096})

    lines = render_execution_lines(config, json.dumps)
    reparsed = parse_execution_table(tomllib.loads("\n".join(lines))["execution"])

    assert reparsed == config
    assert any(line.startswith("phase_gate_commands") for line in lines)


def test_the_default_policy_still_renders_nothing() -> None:
    assert render_execution_lines(ExecutionConfig(), json.dumps) == []


def test_an_unconfigured_stack_is_refused_for_phase_gate_execution() -> None:
    with pytest.raises(ExecutionConfigError) as caught:
        require_phase_gate_execution(ExecutionConfig())

    assert "phase_gate_commands" in caught.value.reason


def test_contract_scoped_commands_never_stand_in_for_the_phase_gate_stack() -> None:
    config = ExecutionConfig(baseline_argv=("pytest",), planner_quality_argv=("ruff", "check"))

    require_autonomous_execution(config)
    with pytest.raises(ExecutionConfigError):
        require_phase_gate_execution(config)


def test_a_configured_stack_is_accepted_and_does_not_affect_autonomous_readiness() -> None:
    config = ExecutionConfig(phase_gate_commands=(("./scripts/check",),))

    require_phase_gate_execution(config)
    with pytest.raises(ExecutionConfigError):
        require_autonomous_execution(config)
