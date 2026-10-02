"""Shared construction helpers for the Phase 11.6 autonomous-run suites.

Not a test module. Builds on the 11.5 multi-Phase project (a real Git source repository, the
real planning/cursor stores, fake provider executables) and adds what an unattended run needs:
a deterministic injectable clock, scripted Planner/Implementer/Reviewer answers for a *whole*
project with JIT replanning on (the default), a fake Planner that sleeps, and a way to inject an
authoritative usage signal into a child transaction journal.

It imports no 11.6 production module at module level, so the fixture characterization suite
can run before those modules exist.
"""

from __future__ import annotations

import sys
from collections.abc import Callable, Sequence
from datetime import UTC, datetime, timedelta
from pathlib import Path
from typing import Any

from phase_gate_support import (
    GateProject,
    make_gate_project,
    master_plan,
    passing_command,
    replan_response,
    review_response,
    unit_script,
)
from test_project_orchestrator import _impl_response

from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    ExecutionEventKind,
    ExecutionOutcome,
    InvocationIdentity,
    InvocationStage,
    InvocationUsage,
    PhaseId,
    ProcessTermination,
    QuotaStatus,
    SubphaseId,
)
from lockstep.execution_config import ExecutionConfig
from lockstep.persistence import record_execution_event

TWO_PHASES: dict[str, tuple[str, ...]] = {"01": ("01", "02"), "02": ("11",)}

_START = datetime(2031, 1, 1, 12, 0, 0, tzinfo=UTC)


class FakeClock:
    """A deterministic host clock: it only moves when a test advances it."""

    def __init__(self, start: datetime = _START) -> None:
        self.now = start

    def __call__(self) -> datetime:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += timedelta(seconds=seconds)


# ---------------------------------------------------------------------------
# Scripted provider answers
# ---------------------------------------------------------------------------


def planner_script(phases: dict[str, tuple[str, ...]], *, jit: bool = True) -> list[dict[str, Any]]:
    """Every Planner answer a green run of *phases* consumes, in order.

    Per Sub-phase a Contract plan then the test-authoring turn; with *jit* (the default of the
    autonomous driver) a replan -- returning the frozen outline unchanged -- between a Sub-phase
    and its unfinished successor. A Phase without integration criteria needs no gate review.
    """
    script: list[dict[str, Any]] = []
    for plan in master_plan(phases).phases:
        sids = tuple(outline.subphase_id.root for outline in plan.subphases)
        for index, sid in enumerate(sids):
            script.extend(unit_script(plan.phase_id.root, sid))
            if jit and index < len(sids) - 1:
                script.append(replan_response(plan))
    return script


def executed_units(phases: dict[str, tuple[str, ...]]) -> list[tuple[str, str]]:
    return [(phase, sid) for phase, sids in phases.items() for sid in sids]


def default_gate_commands(marker: Path) -> tuple[tuple[str, ...], ...]:
    return (passing_command(marker, "gate"),)


def autonomous_project(
    tmp_path: Path,
    *,
    phases: dict[str, tuple[str, ...]] | None = None,
    planner: list[dict[str, Any]] | None = None,
    implementer: list[dict[str, Any]] | None = None,
    reviewer: list[dict[str, Any]] | None = None,
    gate_commands: Callable[[Path], tuple[tuple[str, ...], ...]] | None = None,
    execution: ExecutionConfig | None = None,
    jit: bool = True,
) -> GateProject:
    """A real multi-Phase project scripted so the whole of *phases* runs to completion."""
    phases = phases if phases is not None else TWO_PHASES
    units = executed_units(phases)
    return make_gate_project(
        tmp_path,
        phases=phases,
        planner=planner if planner is not None else planner_script(phases, jit=jit),
        implementer=(
            implementer if implementer is not None else [_impl_response(sid) for _, sid in units]
        ),
        reviewer=(
            reviewer
            if reviewer is not None
            else [review_response(phase, sid) for phase, sid in units]
        ),
        gate_commands=gate_commands if gate_commands is not None else default_gate_commands,
        execution=execution,
    )


def make_policy(
    *,
    max_subphases: int = 10,
    wall_clock_seconds: float = 3600.0,
    retry_attempts: int = 3,
    max_gate_remediations: int = 1,
    until_phase: str | None = None,
) -> Any:
    """A finite policy; the production types are imported lazily (see the module docstring)."""
    from lockstep.autonomous_run_control import AutonomousRunPolicy
    from lockstep.retry import RetryBudget

    return AutonomousRunPolicy(
        max_subphases=max_subphases,
        max_unattended_wall_clock_seconds=wall_clock_seconds,
        retry_budget=RetryBudget(max_attempts=AttemptNumber.model_validate(retry_attempts)),
        max_gate_remediations=max_gate_remediations,
        until_phase=PhaseId.model_validate(until_phase) if until_phase is not None else None,
    )


def run_autonomous(
    project: GateProject,
    policy: Any,
    *,
    clock: Callable[[], datetime],
    project_run_id: Any = None,
    planning_timeout_seconds: float = 60.0,
) -> Any:
    from lockstep.autonomous_run import run_autonomous_project

    return run_autonomous_project(
        project.runtime,
        policy=policy,
        project_run_id=project_run_id,
        request_factory=project.factory,
        clock=clock,
        planning_timeout_seconds=planning_timeout_seconds,
    )


# ---------------------------------------------------------------------------
# Fault and signal injection
# ---------------------------------------------------------------------------


def sleeping_planner(project: GateProject, *, seconds: float = 60.0) -> None:
    """Replace the fake Planner executable with one that logs its launch, then sleeps."""
    executable = project.bins["planner"] / "claude-planner"
    log = project.bins["planner"] / "claude-planner-invocations.jsonl"
    executable.write_text(
        f"#!{sys.executable}\n"
        "import json\n"
        "import sys\n"
        "import time\n"
        "from pathlib import Path\n"
        "\n"
        "sys.stdin.read()\n"
        f"with Path({str(log)!r}).open('a', encoding='utf-8') as handle:\n"
        "    handle.write(json.dumps({'cwd': str(Path.cwd())}) + '\\n')\n"
        f"time.sleep({seconds!r})\n",
        encoding="utf-8",
    )


def append_quota_signal(project: GateProject, phase: str, sid: str, quota: QuotaStatus) -> None:
    """Append one provider-reported quota fact to a child transaction's journal.

    The fact is a typed ``InvocationUsage.quota_status`` on a recorded invocation return: the
    only authoritative channel. No prose is involved.
    """
    identity = InvocationIdentity.issue(
        run_id=project.run_id(phase, sid),
        phase_id=PhaseId.model_validate(phase),
        subphase_id=SubphaseId.model_validate(sid),
        attempt=AttemptNumber.model_validate(1),
        role=AgentRole.IMPLEMENTER,
        stage=InvocationStage.IMPLEMENTATION,
    )
    record_execution_event(
        project.txn_dir(phase, sid),
        kind=ExecutionEventKind.INVOCATION_RETURNED,
        outcome=ExecutionOutcome.SUCCESS,
        identity=identity,
        returncode=0,
        usage=InvocationUsage(
            provider="fake",
            termination=ProcessTermination.EXITED,
            exit_code=0,
            quota_status=quota,
        ),
    )


def after_call(
    monkeypatch: Any, module: Any, name: str, n: int, action: Callable[[], None]
) -> dict[str, int]:
    """Run *action* right after the *n*-th (1-based) real call of ``module.name`` returns."""
    original = getattr(module, name)
    state = {"calls": 0}

    def wrapper(*args: Any, **kwargs: Any) -> Any:
        result = original(*args, **kwargs)
        state["calls"] += 1
        if state["calls"] == n:
            action()
        return result

    monkeypatch.setattr(module, name, wrapper)
    return state


def read_lines(path: Path) -> list[str]:
    return path.read_text(encoding="utf-8").splitlines(keepends=True)


__all__: Sequence[str] = (
    "TWO_PHASES",
    "FakeClock",
    "after_call",
    "append_quota_signal",
    "autonomous_project",
    "default_gate_commands",
    "executed_units",
    "make_policy",
    "planner_script",
    "read_lines",
    "run_autonomous",
    "sleeping_planner",
)
