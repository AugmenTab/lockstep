"""Phase 11.4: the typed, strict ``[execution]`` project-configuration boundary.

``lockstep.toml [execution]`` is the one tracked source of project-specific
execution policy: the baseline and Planner-test quality command prefixes
(structured argv, never shell strings) and the per-operation timeouts and
limits. Parsing stays strict -- unknown configuration is still rejected -- and
"configuration parses" is separate from "configuration is sufficient for
autonomous execution".

Baseline classification: every test in this module is RED at entry
(``lockstep.execution_config`` does not exist).
"""

from __future__ import annotations

import dataclasses

import pytest

from lockstep.config import (
    ProjectConfig,
    ProjectConfigError,
    parse_project_config,
    render_project_config,
)
from lockstep.execution_config import (
    ExecutionConfig,
    ExecutionConfigError,
    require_autonomous_execution,
)
from lockstep.supervisor.transaction import SingleSubphaseTransactionRequest

_ROUTING = """schema_version = 1

[routing.planner]
provider = "claude"
model = "m"
effort = "low"
billing_mode = "subscription_only"

[routing.implementer]
provider = "claude"
model = "m"
effort = "low"
billing_mode = "subscription_only"

[routing.reviewer]
provider = "claude"
model = "m"
effort = "low"
billing_mode = "subscription_only"
"""

_FULL_EXECUTION = """
[execution]
baseline_argv = ["./scripts/test"]
planner_quality_argv = ["./scripts/test-quality", "--strict"]
agent_timeout_seconds = 900
command_timeout_seconds = 120.5
max_output_bytes = 65536
termination_grace_seconds = 1.5
"""


def _parse(execution: str = "") -> ProjectConfig:
    return parse_project_config(_ROUTING + execution)


def _transaction_default(name: str) -> object:
    for field in dataclasses.fields(SingleSubphaseTransactionRequest):
        if field.name == name:
            return field.default
    raise AssertionError(f"no such request field: {name}")


def test_execution_defaults_equal_the_accepted_transaction_defaults() -> None:
    execution = ExecutionConfig()

    assert execution.baseline_argv == ()
    assert execution.planner_quality_argv == ()
    assert execution.agent_timeout_seconds == _transaction_default("agent_timeout_seconds")
    assert execution.command_timeout_seconds == _transaction_default("command_timeout_seconds")
    assert execution.max_output_bytes == _transaction_default("max_output_bytes")
    assert execution.termination_grace_seconds == _transaction_default("termination_grace_seconds")


def test_execution_config_is_frozen() -> None:
    with pytest.raises(dataclasses.FrozenInstanceError):
        ExecutionConfig().max_output_bytes = 1  # type: ignore[misc]


def test_a_config_without_an_execution_table_still_parses_with_defaults() -> None:
    config = _parse()

    assert config.execution == ExecutionConfig()


def test_the_full_execution_table_parses_to_structured_argv_and_limits() -> None:
    execution = _parse(_FULL_EXECUTION).execution

    assert execution.baseline_argv == ("./scripts/test",)
    assert execution.planner_quality_argv == ("./scripts/test-quality", "--strict")
    assert execution.agent_timeout_seconds == 900.0
    assert execution.command_timeout_seconds == 120.5
    assert execution.max_output_bytes == 65536
    assert execution.termination_grace_seconds == 1.5


def test_omitted_limits_keep_their_defaults_when_only_commands_are_configured() -> None:
    execution = _parse(
        '\n[execution]\nbaseline_argv = ["pytest"]\nplanner_quality_argv = ["ruff"]\n'
    ).execution

    assert execution.baseline_argv == ("pytest",)
    assert execution.agent_timeout_seconds == ExecutionConfig().agent_timeout_seconds
    assert execution.max_output_bytes == ExecutionConfig().max_output_bytes


def test_render_omits_a_default_execution_table_and_round_trips() -> None:
    config = _parse()

    text = render_project_config(config)

    assert "[execution]" not in text
    assert parse_project_config(text) == config


def test_render_emits_a_configured_execution_table_after_routing_and_round_trips() -> None:
    config = _parse(_FULL_EXECUTION)

    text = render_project_config(config)

    assert text.index("[routing.reviewer]") < text.index("[execution]")
    assert text.endswith("\n") and not text.endswith("\n\n")
    assert render_project_config(config) == text
    assert parse_project_config(text) == config


def test_unknown_execution_keys_are_rejected() -> None:
    with pytest.raises(ProjectConfigError):
        _parse('\n[execution]\nbaseline_argv = ["pytest"]\nshell = "bash"\n')


def test_unknown_top_level_configuration_is_still_rejected() -> None:
    with pytest.raises(ProjectConfigError):
        parse_project_config(_ROUTING + 'executions = "x"\n')


def test_execution_must_be_a_table() -> None:
    text = _ROUTING.replace("schema_version = 1", "schema_version = 1\nexecution = 1", 1)

    with pytest.raises(ProjectConfigError):
        parse_project_config(text)


@pytest.mark.parametrize(
    "line",
    [
        'baseline_argv = "pytest -q"',
        "baseline_argv = []",
        'baseline_argv = ["pytest", 1]',
        'baseline_argv = [""]',
        'baseline_argv = ["sh", "-c", "pytest"]',
        'baseline_argv = ["/bin/bash", "-c", "pytest"]',
        'planner_quality_argv = "ruff check"',
        'planner_quality_argv = ["zsh", "-c", "ruff"]',
    ],
)
def test_commands_must_be_shell_free_structured_argv(line: str) -> None:
    with pytest.raises(ProjectConfigError):
        _parse(f"\n[execution]\n{line}\n")


@pytest.mark.parametrize(
    "line",
    [
        "agent_timeout_seconds = 0",
        "agent_timeout_seconds = -1",
        "command_timeout_seconds = true",
        'command_timeout_seconds = "30"',
        "max_output_bytes = 0",
        "max_output_bytes = 1.5",
        "termination_grace_seconds = -0.1",
    ],
)
def test_invalid_limits_are_rejected(line: str) -> None:
    with pytest.raises(ProjectConfigError):
        _parse(f"\n[execution]\n{line}\n")


def test_parsing_does_not_require_commands_but_autonomous_execution_does() -> None:
    parsed = _parse()
    with pytest.raises(ExecutionConfigError):
        require_autonomous_execution(parsed.execution)

    only_baseline = _parse('\n[execution]\nbaseline_argv = ["pytest"]\n').execution
    with pytest.raises(ExecutionConfigError):
        require_autonomous_execution(only_baseline)

    only_quality = _parse('\n[execution]\nplanner_quality_argv = ["ruff"]\n').execution
    with pytest.raises(ExecutionConfigError):
        require_autonomous_execution(only_quality)

    require_autonomous_execution(_parse(_FULL_EXECUTION).execution)


def test_execution_errors_never_echo_configured_values() -> None:
    with pytest.raises(ProjectConfigError) as caught:
        _parse('\n[execution]\nbaseline_argv = ["SENTINEL-VALUE", 1]\n')

    assert "SENTINEL-VALUE" not in caught.value.reason
