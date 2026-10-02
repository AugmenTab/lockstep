"""Shared construction helpers for the Phase 11.5 Phase-gate suites.

Not a test module. Builds a real multi-Phase project (a real Git source
repository, the real planning/cursor stores, fake provider executables) plus the
scripted Planner, Implementer and Reviewer responses and the deterministic
Phase-gate commands the 11.5 scenarios drive.
"""

from __future__ import annotations

import json
import subprocess
import sys
from collections.abc import Callable, Sequence
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from test_project_orchestrator import (
    _default_factory,
    _impl_response,
    _tests_response,
)
from test_supervisor_resume_execution import (
    _budget,
    _claude_adapter,
    _git,
    _init_source_repo,
    _invocation_count,
    _parent_env,
    _review_decision_payload,
    _write_fake_claude_executable,
)

from lockstep.agents import (
    AgentProviderDiagnostics,
    AgentProviderStatuses,
    ResolvedAgentAdapters,
)
from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.config import ProjectConfig
from lockstep.domain import (
    AcceptanceCriterion,
    AgentRole,
    BillingMode,
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    RunId,
    SubphaseContract,
    SubphaseId,
    SubphaseOutline,
)
from lockstep.execution_config import ExecutionConfig
from lockstep.planning_store import freeze_master_plan
from lockstep.project_cursor import ProjectCursor
from lockstep.project_cursor_store import load_project_cursor
from lockstep.project_orchestrator import (
    ProjectRunResult,
    TransactionPlacement,
    run_project_phase,
    transaction_runtime_dir,
    transaction_worktree_path,
)
from lockstep.runtime import AgentRuntime
from lockstep.supervisor.transaction import SingleSubphaseTransactionRequest

CRITERIA = (
    AcceptanceCriterion(criterion_id="IC-1", description="The completed features integrate."),
)


class CrashError(Exception):
    """Simulated process death at an exact point."""


# ---------------------------------------------------------------------------
# Planning artifacts
# ---------------------------------------------------------------------------


def outlines(sids: Sequence[str]) -> tuple[SubphaseOutline, ...]:
    return tuple(
        SubphaseOutline(
            subphase_id=SubphaseId.model_validate(sid),
            title=f"Outline {sid}",
            objective=f"Objective {sid}.",
            depends_on=(SubphaseId.model_validate(sids[i - 1]),) if i else (),
        )
        for i, sid in enumerate(sids)
    )


def phase_plan(
    phase_id: str,
    sids: Sequence[str],
    *,
    criteria: tuple[AcceptanceCriterion, ...] = (),
    depends_on: tuple[str, ...] = (),
) -> PhasePlan:
    return PhasePlan(
        phase_id=PhaseId.model_validate(phase_id),
        title=f"Phase {phase_id}",
        objective=f"Objective of phase {phase_id}.",
        depends_on=tuple(PhaseId.model_validate(p) for p in depends_on),
        subphases=outlines(sids),
        integration_acceptance_criteria=criteria,
    )


def master_plan(
    phases: dict[str, tuple[str, ...]],
    criteria: dict[str, tuple[AcceptanceCriterion, ...]] | None = None,
) -> MasterPlan:
    built: list[PhasePlan] = []
    previous: str | None = None
    for phase_id, sids in phases.items():
        built.append(
            phase_plan(
                phase_id,
                sids,
                criteria=(criteria or {}).get(phase_id, ()),
                depends_on=(previous,) if previous else (),
            )
        )
        previous = phase_id
    return MasterPlan(
        project_id=ProjectId.model_validate("lockstep"),
        title="Lockstep",
        objective="Build the control plane.",
        phases=tuple(built),
    )


# ---------------------------------------------------------------------------
# Scripted provider responses
# ---------------------------------------------------------------------------


def contract_response(phase: str, sid: str) -> dict[str, object]:
    payload = {
        "schema_version": 1,
        "phase_id": phase,
        "subphase_id": sid,
        "title": f"Feature {sid}",
        "objective": f"Provide feature {sid}.",
        "acceptance_criteria": [{"criterion_id": "AC-1", "description": f"Feature {sid} works."}],
        "tests": [
            {
                "path": f"tests/test_feature_{sid}.py",
                "expectation": "red",
                "acceptance_criteria": ["AC-1"],
            }
        ],
        "allowed_paths": [f"feature_{sid}.py"],
        "protected_paths": [],
        "forbidden_paths": [],
        "verification_commands": [f"pytest tests/test_feature_{sid}.py"],
    }
    return {"stdout": json.dumps(payload), "returncode": 0}


def unit_script(phase: str, sid: str) -> list[dict[str, object]]:
    """The Planner's two answers for one Sub-phase: its Contract, then its tests."""
    return [contract_response(phase, sid), _tests_response(sid)]


def replan_response(plan: PhasePlan) -> dict[str, object]:
    return {"stdout": plan.model_dump_json(), "returncode": 0}


def gate_review_response(
    phase: str,
    verdict: str = "pass",
    *,
    findings: Sequence[dict[str, object]] = (),
    files: dict[str, str] | None = None,
    stdout: str | None = None,
    returncode: int = 0,
) -> dict[str, object]:
    payload = {
        "schema_version": 1,
        "phase_id": phase,
        "verdict": verdict,
        "summary": f"phase {phase} integration {verdict}",
        "findings": list(findings),
    }
    response: dict[str, object] = {
        "stdout": json.dumps(payload) if stdout is None else stdout,
        "returncode": returncode,
    }
    if files is not None:
        response["files"] = files
    return response


def finding(
    observation: str = "The two features do not integrate.",
    *,
    criterion_id: str | None = "IC-1",
) -> dict[str, object]:
    return {
        "criterion_id": criterion_id,
        "observation": observation,
        "evidence": "feature_01 and feature_02 disagree on the shared answer.",
    }


def remediation_plan_response(
    phase: str,
    completed: Sequence[str],
    new_sid: str,
    *,
    criteria: tuple[AcceptanceCriterion, ...] = (),
    depends_on: str | None = None,
) -> dict[str, object]:
    base = phase_plan(phase, completed, criteria=criteria)
    dependency = depends_on if depends_on is not None else completed[-1]
    remediation = SubphaseOutline(
        subphase_id=SubphaseId.model_validate(new_sid),
        title=f"Gate remediation {new_sid}",
        objective="Repair the integration defect the Phase gate found.",
        depends_on=(SubphaseId.model_validate(dependency),),
    )
    plan = base.model_copy(update={"subphases": (*base.subphases, remediation)})
    return replan_response(plan)


# ---------------------------------------------------------------------------
# Deterministic Phase-gate commands (structured argv)
# ---------------------------------------------------------------------------


def passing_command(marker: Path, label: str) -> tuple[str, ...]:
    """Records ``label|cwd|HEAD`` in *marker*, then exits 0."""
    code = (
        "import os, subprocess; "
        "head = subprocess.run(['git', 'rev-parse', 'HEAD'], "
        "capture_output=True, text=True).stdout.strip(); "
        f"open({str(marker)!r}, 'a').write({label!r} + '|' + os.getcwd() + '|' + head + '\\n')"
    )
    return (sys.executable, "-c", code)


def failing_command(marker: Path, label: str, *, code: int = 3) -> tuple[str, ...]:
    """Records the run, prints a diagnostic, and exits non-zero."""
    source = (
        "import os, sys; "
        f"open({str(marker)!r}, 'a').write({label!r} + '|' + os.getcwd() + '|-\\n'); "
        "print('integration boom'); "
        f"sys.exit({code})"
    )
    return (sys.executable, "-c", source)


def fail_once_command(marker: Path, flag: Path, label: str) -> tuple[str, ...]:
    """Fails (exit 3) the first time it runs anywhere, then passes."""
    source = (
        "import os, sys; "
        f"open({str(marker)!r}, 'a').write({label!r} + '|' + os.getcwd() + '|-\\n'); "
        f"first = not os.path.exists({str(flag)!r}); "
        f"open({str(flag)!r}, 'a').close(); "
        "print('integration boom' if first else 'ok'); "
        "sys.exit(3 if first else 0)"
    )
    return (sys.executable, "-c", source)


def mutating_command(target: str) -> tuple[str, ...]:
    """Modifies a tracked file of the repository it runs in, then exits 0."""
    return (sys.executable, "-c", f"open({target!r}, 'a').write('# tampered\\n')")


# ---------------------------------------------------------------------------
# Project construction
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class GateProject:
    root: Path
    source: Path
    project_root: Path
    runtime_dir: Path
    runtime: AgentRuntime
    bins: dict[str, Path]
    marker: Path
    factory: Callable[[SubphaseContract, TransactionPlacement], SingleSubphaseTransactionRequest]

    def launches(self, role: str) -> int:
        return _invocation_count(self.bins[role], f"claude-{role}")

    def counts(self) -> tuple[int, int, int]:
        return (self.launches("planner"), self.launches("implementer"), self.launches("reviewer"))

    def cursor(self) -> ProjectCursor:
        cursor = load_project_cursor(self.project_root, self.runtime_dir)
        assert cursor is not None
        return cursor

    def run_id(self, phase: str, sid: str) -> RunId:
        return RunId.model_validate(f"run-{phase}-{sid}")

    def txn_dir(self, phase: str, sid: str) -> Path:
        return transaction_runtime_dir(self.runtime_dir, self.run_id(phase, sid))

    def worktree(self, phase: str, sid: str) -> Path:
        return transaction_worktree_path(self.runtime_dir, self.run_id(phase, sid))

    def branch(self, phase: str, sid: str) -> str:
        return f"lockstep/run/{self.run_id(phase, sid).root}"

    def run_phase(self, *, jit: bool = False, budget: int = 3) -> ProjectRunResult:
        return run_project_phase(
            self.runtime,
            request_factory=self.factory,
            retry_budget=_budget(budget),
            planning_timeout_seconds=60.0,
            jit_replan=jit,
        )

    def markers(self) -> list[tuple[str, str, str]]:
        if not self.marker.exists():
            return []
        rows = [line.split("|") for line in self.marker.read_text().splitlines() if line]
        return [(row[0], row[1], row[2]) for row in rows]

    def gate_dir(self, phase: str) -> Path:
        return self.runtime_dir / "phase-gates" / phase

    def attempt_dir(self, phase: str, attempt: int) -> Path:
        return self.gate_dir(phase) / f"attempt-{attempt}"

    def planner_prompts_cwds(self) -> list[Path]:
        log = self.bins["planner"] / "claude-planner-invocations.jsonl"
        if not log.exists():
            return []
        return [Path(json.loads(line)["cwd"]).resolve() for line in log.read_text().splitlines()]


def make_gate_project(
    tmp_path: Path,
    *,
    phases: dict[str, tuple[str, ...]] | None = None,
    criteria: dict[str, tuple[AcceptanceCriterion, ...]] | None = None,
    planner: list[dict[str, object]],
    implementer: list[dict[str, object]],
    reviewer: list[dict[str, object]],
    gate_commands: Callable[[Path], tuple[tuple[str, ...], ...]] | None = None,
    execution: ExecutionConfig | None = None,
) -> GateProject:
    phases = phases if phases is not None else {"01": ("01", "02")}
    root = tmp_path / "world"
    root.mkdir()
    source = _init_source_repo(root)
    project_root = root / "agent-project"
    project_root.mkdir()
    runtime_dir = root / "runtime"
    runtime_dir.mkdir()
    marker = root / "gate-markers.txt"

    freeze_master_plan(project_root, master_plan(phases, criteria))

    bins: dict[str, Path] = {}
    adapters = {}
    roles = {
        "planner": AgentRole.PLANNER,
        "implementer": AgentRole.IMPLEMENTER,
        "reviewer": AgentRole.REVIEWER,
    }
    scripts = {"planner": planner, "implementer": implementer, "reviewer": reviewer}
    for role, responses in scripts.items():
        bins[role] = root / f"{role}-bin"
        _write_fake_claude_executable(bins[role], name=f"claude-{role}", responses=responses)
        adapters[role] = _claude_adapter(roles[role], executable=str(bins[role] / f"claude-{role}"))

    route = AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model="unused-model",
        effort="unused-effort",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )
    if execution is None:
        execution = ExecutionConfig(
            phase_gate_commands=gate_commands(marker) if gate_commands is not None else (),
            agent_timeout_seconds=60.0,
            command_timeout_seconds=60.0,
        )
    runtime = AgentRuntime(
        project_root=project_root,
        runtime_dir=runtime_dir,
        config=ProjectConfig(
            schema_version=1,
            routing=AgentRoutingPolicy(planner=route, implementer=route, reviewer=route),
            execution=execution,
        ),
        diagnostics=AgentProviderDiagnostics(statuses=AgentProviderStatuses()),
        adapters=ResolvedAgentAdapters(
            planner=adapters["planner"],
            implementer=adapters["implementer"],
            reviewer=adapters["reviewer"],
        ),
        transaction_parent_env=_parent_env(root),
    )
    return GateProject(
        root=root,
        source=source,
        project_root=project_root,
        runtime_dir=runtime_dir,
        runtime=runtime,
        bins=bins,
        marker=marker,
        factory=_default_factory(source),
    )


def review_response(phase: str, sid: str) -> dict[str, object]:
    """The Sub-phase Reviewer's APPROVE for ``phase``/``sid``."""
    return {
        "stdout": json.dumps(
            {
                "status": "completed",
                "review_decision": _review_decision_payload(
                    phase_id=phase,
                    subphase_id=sid,
                    attempt=1,
                    verdict="approve",
                    summary=f"approve {sid}",
                ),
                "blocker": None,
            }
        ),
        "returncode": 0,
    }


def standard_project(
    tmp_path: Path,
    *,
    planner_tail: Sequence[dict[str, object]],
    phases: dict[str, tuple[str, ...]] | None = None,
    criteria: dict[str, tuple[AcceptanceCriterion, ...]] | None = None,
    gate_commands: Callable[[Path], tuple[tuple[str, ...], ...]] | None = None,
    extra_units: Sequence[tuple[str, str]] = (),
    execution: ExecutionConfig | None = None,
) -> GateProject:
    """A fixed-outline project whose first Phase will execute every listed Sub-phase.

    The Planner answers each first-Phase Sub-phase's Contract and tests, then *planner_tail*
    verbatim. ``extra_units`` are ``(phase, sid)`` Sub-phases that run later (a remediation, or
    the next Phase's work): they only get an Implementer and Reviewer answer here, in order.
    """
    phases = phases if phases is not None else {"01": ("01", "02")}
    first_phase = next(iter(phases))
    sids = phases[first_phase]
    planner: list[dict[str, object]] = []
    for sid in sids:
        planner.extend(unit_script(first_phase, sid))
    planner.extend(planner_tail)
    executed = [*((first_phase, sid) for sid in sids), *extra_units]
    return make_gate_project(
        tmp_path,
        phases=phases,
        criteria=criteria,
        planner=planner,
        implementer=[_impl_response(sid) for _, sid in executed],
        reviewer=[review_response(phase, sid) for phase, sid in executed],
        gate_commands=gate_commands,
        execution=execution,
    )


def tracked_state(worktree: Path) -> tuple[str, str]:
    """``(HEAD, tracked-status)`` of a worktree; equal values prove nothing tracked changed."""
    head = _git(worktree, "rev-parse", "HEAD").stdout.strip()
    status = _git(worktree, "status", "--porcelain", "--untracked-files=no").stdout
    return head, status


def git_head(worktree: Path, ref: str = "HEAD") -> str:
    return _git(worktree, "rev-parse", ref).stdout.strip()


def subjects(worktree: Path) -> list[str]:
    return _git(worktree, "log", "--format=%s").stdout.strip().splitlines()


def file_bytes(directory: Path) -> dict[str, bytes]:
    return {
        str(path.relative_to(directory)): path.read_bytes()
        for path in sorted(directory.rglob("*"))
        if path.is_file()
    }


def run_git_text(repo: Path, *args: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True, capture_output=True, text=True
    ).stdout


def crash_once(monkeypatch: Any, module: Any, name: str) -> dict[str, int]:
    """Make the first call of ``module.name`` die *before* it runs; later calls are real."""
    original = getattr(module, name)
    state = {"crashed": 0}

    def wrapper(*args: Any, **kwargs: Any) -> Any:
        if state["crashed"] == 0:
            state["crashed"] = 1
            raise CrashError(name)
        return original(*args, **kwargs)

    monkeypatch.setattr(module, name, wrapper)
    return state


def crash_on_nth_call(monkeypatch: Any, module: Any, name: str, n: int) -> dict[str, int]:
    """Make the *n*-th call (1-based) of ``module.name`` die before it runs; others are real."""
    original = getattr(module, name)
    state = {"calls": 0, "crashed": 0}

    def wrapper(*args: Any, **kwargs: Any) -> Any:
        state["calls"] += 1
        if state["calls"] == n and state["crashed"] == 0:
            state["crashed"] = 1
            raise CrashError(name)
        return original(*args, **kwargs)

    monkeypatch.setattr(module, name, wrapper)
    return state


def crash_after_once(monkeypatch: Any, module: Any, name: str) -> dict[str, int]:
    """Make the first call of ``module.name`` run to completion and then die."""
    original = getattr(module, name)
    state = {"crashed": 0}

    def wrapper(*args: Any, **kwargs: Any) -> Any:
        result = original(*args, **kwargs)
        if state["crashed"] == 0:
            state["crashed"] = 1
            raise CrashError(name)
        return result

    monkeypatch.setattr(module, name, wrapper)
    return state


def record_calls(monkeypatch: Any, module: Any, name: str) -> list[dict[str, Any]]:
    """Record every call of ``module.name`` (positionals as ``args``); behavior is unchanged."""
    original = getattr(module, name)
    calls: list[dict[str, Any]] = []

    def wrapper(*args: Any, **kwargs: Any) -> Any:
        calls.append({"args": args, **kwargs})
        return original(*args, **kwargs)

    monkeypatch.setattr(module, name, wrapper)
    return calls
