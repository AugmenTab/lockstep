"""Phase 11.6 regression pins (GREEN_REGRESSION at entry).

11.6 composes the accepted machinery and does not reimplement it. These tests pin the seams it
must leave untouched: the process-package public surface, the project configuration the run
policy must never rewrite, the accepted orchestration entrypoints and their default JIT
replanning, the Phase-10 baseline, and a plain launch with no run budget active.
"""

from __future__ import annotations

import dataclasses
import inspect
import json
import sys
from pathlib import Path

import lockstep.phase_gate_cycle as phase_gate_cycle
import lockstep.process as process
import lockstep.project_orchestrator as project_orchestrator
from lockstep.execution_config import ExecutionConfig
from lockstep.phase_gate_cycle import run_phase_gate_cycle
from lockstep.process import run_process
from lockstep.project_orchestrator import run_project_phase, step_project_run

_BASELINE = Path(__file__).parent / "baselines" / "transaction_baseline.json"


def test_the_process_package_surface_is_not_widened_by_the_run_budget() -> None:
    assert set(process.__all__) == {
        "EnvironmentPolicyError",
        "ProcessConfigurationError",
        "ProcessLaunchError",
        "ProcessResult",
        "ProcessTimeoutError",
        "build_process_environment",
        "run_process",
    }


def test_the_project_execution_configuration_is_not_rewritten_by_a_run_policy() -> None:
    assert [f.name for f in dataclasses.fields(ExecutionConfig)] == [
        "baseline_argv",
        "planner_quality_argv",
        "agent_timeout_seconds",
        "command_timeout_seconds",
        "max_output_bytes",
        "termination_grace_seconds",
        "phase_gate_commands",
    ]


def test_the_accepted_orchestration_surfaces_are_unchanged() -> None:
    assert set(project_orchestrator.__all__) == {
        "ProjectOrchestrationError",
        "ProjectRunDisposition",
        "ProjectRunResult",
        "TransactionPlacement",
        "TransactionRequestFactory",
        "allocate_transaction_run_id",
        "run_project_phase",
        "step_project_run",
        "transaction_runtime_dir",
        "transaction_worktree_path",
    }
    assert set(phase_gate_cycle.__all__) == {
        "PhaseGateCycleDisposition",
        "PhaseGateCycleResult",
        "build_gate_remediation_prompt",
        "complete_phase_from_gate_pass",
        "run_phase_gate_cycle",
    }


def test_ordinary_phase_execution_keeps_jit_replanning_on_by_default() -> None:
    for function in (run_project_phase, step_project_run):
        assert inspect.signature(function).parameters["jit_replan"].default is True


def test_the_gate_remediation_bound_is_still_a_required_keyword() -> None:
    parameter = inspect.signature(run_phase_gate_cycle).parameters["max_gate_remediations"]

    assert parameter.kind is inspect.Parameter.KEYWORD_ONLY
    assert parameter.default is inspect.Parameter.empty


def test_the_phase_10_baseline_is_still_version_1() -> None:
    assert json.loads(_BASELINE.read_text(encoding="utf-8"))["baseline_version"] == 1


def test_a_launch_with_no_run_budget_active_is_governed_only_by_its_own_timeout(
    tmp_path: Path,
) -> None:
    result = run_process(
        (sys.executable, "-c", "print('ok')"), cwd=tmp_path, env={}, timeout_seconds=30
    )

    assert result.returncode == 0
    assert result.stdout.strip() == "ok"
