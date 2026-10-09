"""Phase 11.6: the bounded autonomous project-run driver (Scenarios A-R).

``run_autonomous_project`` composes the accepted 11.1-11.5 machinery at the narrowest seams
(``step_project_run``, ``run_phase_gate_attempt`` and the remediation steps) so that, under an
immutable finite policy, it can cross Sub-phase and Phase boundaries without a human relaying
normal successful work -- and always knows why it may continue and exactly when it must stop.
The host owns advancement, retry limits, budgets and hard stops; no agent output extends a run.

Everything runs the real production code against fake provider executables, a real Git source
repository, real worktrees, the real planning/cursor stores, real subprocess gate commands and a
deterministic injectable clock. No real Claude/Codex account, network, model inference, or long
sleep is used (the two wall-clock cap tests sleep only for the few seconds of their budget).

Baseline classification: every test here is RED at entry (``lockstep.autonomous_run`` does not
exist).
"""

from __future__ import annotations

import ast
import inspect
import math
import sys
import time
from datetime import timedelta
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest
from autonomous_run_support import (
    TWO_PHASES,
    FakeClock,
    after_call,
    append_quota_signal,
    autonomous_project,
    make_policy,
    planner_script,
    read_lines,
    run_autonomous,
    sleeping_planner,
)
from phase_gate_support import (
    CrashError,
    GateProject,
    crash_once,
    fail_once_command,
    failing_command,
    file_bytes,
    master_plan,
    remediation_plan_response,
    replan_response,
    review_response,
    subjects,
    unit_script,
)
from test_project_orchestrator import (
    _contract_response,
    _impl_response,
    _review_response,
    _tests_response,
)
from test_supervisor_resume_execution import (
    _implementer_blocked_response,
    _malformed_stdout_response,
)

import lockstep.autonomous_run as autonomous_run
import lockstep.phase_gate_cycle as phase_gate_cycle
import lockstep.project_orchestrator as project_orchestrator
from lockstep.autonomous_run import (
    AutonomousRunResult,
    run_autonomous_project,
    start_project_run,
)
from lockstep.autonomous_run_control import (
    AutonomousRunDisposition,
    AutonomousRunError,
    AutonomousRunPolicyError,
    AutonomousRunPolicyMismatchError,
    ProjectRunEventKind,
    ProjectRunId,
    list_project_runs,
    load_project_run,
    load_project_run_state,
    project_run_dir,
    read_project_run_events,
)
from lockstep.domain import AttemptNumber, PhaseId, QuotaStatus, StopReason
from lockstep.escalation import EscalationAuthority, EscalationCategory
from lockstep.execution_config import ExecutionConfig
from lockstep.jit_replan import JitReplanState, jit_replan_state
from lockstep.metrics import project_runtime_metrics
from lockstep.phase_gate import (
    PhaseGateEventKind,
    PhaseGateVerdict,
    list_phase_gate_attempts,
    load_phase_gate_decision,
    load_remediation_receipt,
    read_phase_gate_events,
)
from lockstep.project_cursor import PhaseGateStatus
from lockstep.project_orchestrator import ProjectRunDisposition
from lockstep.retry import RetryBudget
from lockstep.supervisor.escalation import SupervisorEscalationDisposition
from lockstep.supervisor.transaction import ResumeExecutionDisposition

_P1 = PhaseId.model_validate("01")
_P2 = PhaseId.model_validate("02")
_SRC = Path(__file__).resolve().parent.parent / "src" / "lockstep"
_D = AutonomousRunDisposition
_ONE_PHASE: dict[str, tuple[str, ...]] = {"01": ("01",)}
_TWO_UNITS: dict[str, tuple[str, ...]] = {"01": ("01", "02")}
_THREE_UNITS: dict[str, tuple[str, ...]] = {"01": ("01", "02", "03")}


def _state(project: GateProject, result: AutonomousRunResult) -> Any:
    return load_project_run_state(project.runtime_dir, result.project_run_id)


def _reserved(project: GateProject, result: AutonomousRunResult) -> list[tuple[str, str]]:
    return [(r.phase_id.root, r.subphase_id.root) for r in _state(project, result).reservations]


def _gate_kinds(project: GateProject, phase: PhaseId) -> list[PhaseGateEventKind]:
    return [e.kind for e in read_phase_gate_events(project.runtime_dir, phase)]


def _cursor_bytes(project: GateProject) -> bytes:
    return (project.runtime_dir / "project" / "cursor.json").read_bytes()


def _fail_once(marker: Path) -> tuple[tuple[str, ...], ...]:
    return (fail_once_command(marker, marker.parent / "gate.flag", "gate"),)


def _failing(marker: Path) -> tuple[tuple[str, ...], ...]:
    return (failing_command(marker, "gate"),)


def _process_failure(stderr: str = "") -> dict[str, object]:
    return {"stdout": "", "returncode": 1, "stderr": stderr}


# ===========================================================================
# Public shape
# ===========================================================================


def test_the_driver_has_explicit_keyword_policy_and_no_replan_switch() -> None:
    parameters = inspect.signature(run_autonomous_project).parameters

    assert next(iter(parameters)) == "runtime"
    assert parameters["policy"].kind is inspect.Parameter.KEYWORD_ONLY
    assert parameters["policy"].default is inspect.Parameter.empty
    assert parameters["project_run_id"].default is None
    assert parameters["request_factory"].default is None
    assert parameters["clock"].kind is inspect.Parameter.KEYWORD_ONLY
    # JIT replanning is immutable host policy (``AutonomousRunPolicy.jit_replan``), never a
    # per-call switch.
    assert "jit_replan" not in parameters

    start = inspect.signature(start_project_run).parameters
    assert list(start)[:2] == ["runtime", "policy"]


def test_the_driver_never_calls_a_monolithic_phase_or_gate_helper() -> None:
    tree = ast.parse((_SRC / "autonomous_run.py").read_text(encoding="utf-8"))
    forbidden = {"run_project_phase", "run_phase_gate_cycle"}
    referenced: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Name):
            referenced.add(node.id)
        elif isinstance(node, ast.Attribute):
            referenced.add(node.attr)
        elif isinstance(node, ast.alias):
            referenced.add(node.name)

    assert referenced.isdisjoint(forbidden)


def test_no_failure_handler_in_the_driver_can_fall_through_and_continue() -> None:
    tree = ast.parse((_SRC / "autonomous_run.py").read_text(encoding="utf-8"))
    handlers = [node for node in ast.walk(tree) if isinstance(node, ast.ExceptHandler)]

    assert handlers  # the driver does record terminal failures
    for handler in handlers:
        assert any(isinstance(n, ast.Raise | ast.Return) for n in ast.walk(handler))


# ===========================================================================
# Scenario A: cross-Phase green path, no human relay
# ===========================================================================


@pytest.fixture(scope="module")
def green(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    project = autonomous_project(tmp_path_factory.mktemp("green"))

    def forbidden(*args: object, **kwargs: object) -> object:
        raise AssertionError("a monolithic helper was used")

    with pytest.MonkeyPatch.context() as patch:
        patch.setattr(project_orchestrator, "run_project_phase", forbidden)
        patch.setattr(phase_gate_cycle, "run_phase_gate_cycle", forbidden)
        result = run_autonomous(project, make_policy(), clock=FakeClock())
    return SimpleNamespace(project=project, result=result)


def test_two_phases_complete_unattended_and_the_project_is_complete(green: SimpleNamespace) -> None:
    project, result = green.project, green.result

    assert result.disposition is _D.PROJECT_COMPLETE
    cursor = project.cursor()
    assert cursor == result.cursor
    assert cursor.completed_phases == (_P1, _P2)
    assert cursor.current_phase is None
    assert cursor.phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE
    assert [e.subphase_id.root for e in cursor.completed_subphases] == ["01", "02", "11"]
    assert result.completed_phases == (_P1, _P2)
    assert [e.subphase_id.root for e in result.completed_subphases] == ["01", "02", "11"]


def test_every_role_ran_the_scripted_number_of_times_with_jit_replanning_on(
    green: SimpleNamespace,
) -> None:
    project = green.project

    # Phase 01: two Contract plans, two test-authoring turns, one JIT replan; Phase 02: one unit.
    assert project.counts() == (7, 3, 3)
    assert [label for label, _, _ in project.markers()] == ["gate", "gate"]


def test_the_next_phase_continues_from_the_accepted_branch_of_the_previous_one(
    green: SimpleNamespace,
) -> None:
    project = green.project

    history = subjects(project.worktree("02", "11"))

    assert history[:2] == [
        "feat(feature-11): implement answer",
        "test(feature-11): freeze answer expectation",
    ]
    assert "feat(feature-02): implement answer" in history


def test_each_phase_gate_passed_and_completed_exactly_once(green: SimpleNamespace) -> None:
    project = green.project

    for phase in (_P1, _P2):
        assert _gate_kinds(project, phase) == [
            PhaseGateEventKind.PHASE_GATE_STARTED,
            PhaseGateEventKind.PHASE_GATE_PASSED,
            PhaseGateEventKind.PHASE_COMPLETE,
        ]


def test_run_identity_is_independent_of_the_child_transaction_run_ids(
    green: SimpleNamespace,
) -> None:
    project, result = green.project, green.result
    state = _state(project, result)

    assert isinstance(result.project_run_id, ProjectRunId)
    assert result.project_run_id.root == "prun-0001"
    assert [r.transaction_run_id.root for r in state.reservations] == [
        "run-01-01",
        "run-01-02",
        "run-02-11",
    ]
    assert result.reserved_subphases == 3


def test_the_control_journal_records_the_reservations_and_the_final_stop(
    green: SimpleNamespace,
) -> None:
    project, result = green.project, green.result

    events = read_project_run_events(project.runtime_dir, result.project_run_id)

    assert [e.kind for e in events] == [
        ProjectRunEventKind.RUN_STARTED,
        ProjectRunEventKind.SUBPHASE_RESERVED,
        ProjectRunEventKind.SUBPHASE_RESERVED,
        ProjectRunEventKind.SUBPHASE_RESERVED,
        ProjectRunEventKind.RUN_STOPPED,
    ]
    assert _state(project, result).stop.disposition is _D.PROJECT_COMPLETE


def test_run_control_competes_with_neither_the_cursor_nor_a_child_journal(
    green: SimpleNamespace,
) -> None:
    project, result = green.project, green.result

    assert (project_run_dir(project.runtime_dir, result.project_run_id)).is_dir()
    assert not (project.runtime_dir / "events.jsonl").exists()
    assert not (project.runtime_dir / "state.json").exists()
    # Corrected by Planner ruling (12.8, C1): a run that completes Phases also holds
    # exactly one immutable Phase-context finalization per completed Phase.
    assert sorted(p.name for p in (project.runtime_dir / "project").iterdir()) == [
        "cursor.json",
        "phase-context",
    ]
    assert sorted(
        p.name for p in (project.runtime_dir / "project" / "phase-context").iterdir()
    ) == [
        f"{_P1.root}.json",
        f"{_P2.root}.json",
    ]


def test_child_transaction_telemetry_is_unchanged_by_the_unattended_run(
    green: SimpleNamespace,
) -> None:
    project = green.project

    for phase, sid in (("01", "01"), ("01", "02"), ("02", "11")):
        totals = project_runtime_metrics(project.txn_dir(phase, sid), repository_change=None).totals
        assert (totals.subphases_attempted, totals.subphases_completed) == (1, 1)
        assert totals.executed_attempts == 1
        assert {role.value: n for role, n in totals.invocations_by_role.items()} == {
            "planner": 1,
            "implementer": 1,
            "reviewer": 1,
        }


# ===========================================================================
# Scenario B: until_phase is an inclusive boundary
# ===========================================================================


@pytest.fixture(scope="module")
def boundary(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    project = autonomous_project(tmp_path_factory.mktemp("boundary"))
    clock = FakeClock()
    policy = make_policy(until_phase="01")
    first = run_autonomous(project, policy, clock=clock)
    after_first = SimpleNamespace(
        counts=project.counts(), markers=project.markers(), cursor=_cursor_bytes(project)
    )
    again = run_autonomous(project, policy, clock=clock, project_run_id=first.project_run_id)
    after_again = SimpleNamespace(
        counts=project.counts(), markers=project.markers(), cursor=_cursor_bytes(project)
    )
    fresh = run_autonomous(project, policy, clock=clock)
    return SimpleNamespace(
        project=project,
        first=first,
        again=again,
        fresh=fresh,
        after_first=after_first,
        after_again=after_again,
    )


def test_until_phase_completes_the_target_phase_then_stops(boundary: SimpleNamespace) -> None:
    project, first = boundary.project, boundary.first

    assert first.disposition is _D.PHASE_BOUNDARY_REACHED
    assert first.completed_phases == (_P1,)
    cursor = project.cursor()
    assert cursor.completed_phases == (_P1,)
    assert [e.subphase_id.root for e in cursor.completed_subphases] == ["01", "02"]
    assert [label for label, _, _ in project.markers()] == ["gate"]


def test_successor_phase_receives_no_planner_contract_or_agent_work(
    boundary: SimpleNamespace,
) -> None:
    project = boundary.project

    # Phase 01 only: two Contract plans, two test-authoring turns and one replan.
    assert boundary.after_first.counts == (5, 2, 2)
    cursor = project.cursor()
    assert cursor.current_phase == _P2
    assert cursor.active_contract is None
    assert not project.txn_dir("02", "11").exists()
    assert not project.worktree("02", "11").exists()
    assert boundary.first.reserved_subphases == 2


def test_resuming_a_reached_boundary_changes_nothing(boundary: SimpleNamespace) -> None:
    again = boundary.again

    assert again.disposition is _D.PHASE_BOUNDARY_REACHED
    assert again.project_run_id == boundary.first.project_run_id
    assert boundary.after_again.counts == boundary.after_first.counts
    assert boundary.after_again.markers == boundary.after_first.markers
    assert boundary.after_again.cursor == boundary.after_first.cursor


def test_a_new_run_whose_boundary_is_already_complete_returns_without_new_work(
    boundary: SimpleNamespace,
) -> None:
    project, fresh = boundary.project, boundary.fresh

    assert fresh.disposition is _D.PHASE_BOUNDARY_REACHED
    assert fresh.project_run_id != boundary.first.project_run_id
    assert fresh.reserved_subphases == 0
    assert project.counts() == boundary.after_first.counts
    assert project.markers() == boundary.after_first.markers


def test_an_until_phase_that_is_not_in_the_master_plan_is_rejected_before_anything_runs(
    tmp_path: Path,
) -> None:
    project = autonomous_project(tmp_path)

    with pytest.raises(AutonomousRunPolicyError):
        run_autonomous(project, make_policy(until_phase="09"), clock=FakeClock())

    assert project.counts() == (0, 0, 0)
    assert not (project.runtime_dir / "project-runs").exists()


def test_a_zero_sub_phase_run_still_gates_a_ready_phase_and_stops_at_the_boundary(
    tmp_path: Path,
) -> None:
    project = autonomous_project(tmp_path, phases={"01": ("01",), "02": ("11",)})
    assert project.run_phase().disposition is ProjectRunDisposition.PHASE_GATE_READY
    planner_before = project.launches("planner")

    result = run_autonomous(
        project, make_policy(max_subphases=0, until_phase="01"), clock=FakeClock()
    )

    assert result.disposition is _D.PHASE_BOUNDARY_REACHED
    assert result.reserved_subphases == 0
    assert project.cursor().completed_phases == (_P1,)
    assert [label for label, _, _ in project.markers()] == ["gate"]
    assert project.launches("planner") == planner_before  # nothing was planned for Phase 02


# ===========================================================================
# Scenario C: max_subphases bounds distinct units, stops before needless JIT
# ===========================================================================


@pytest.fixture(scope="module")
def limited(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    project = autonomous_project(tmp_path_factory.mktemp("limited"), phases=_TWO_UNITS)
    clock = FakeClock()
    policy = make_policy(max_subphases=1)
    first = run_autonomous(project, policy, clock=clock)
    state = SimpleNamespace(
        counts=project.counts(),
        cursor=_cursor_bytes(project),
        # An immutable snapshot of the durable cursor right after the first bounded run, before
        # any later continuation moves the live cursor on.
        cursor_after_first=project.cursor(),
        jit=jit_replan_state(project.project_root, project.runtime_dir),
    )
    again = run_autonomous(project, policy, clock=clock, project_run_id=first.project_run_id)
    after_again = project.counts()
    later = run_autonomous(project, policy, clock=clock)
    return SimpleNamespace(
        project=project,
        first=first,
        again=again,
        later=later,
        state=state,
        after_again=after_again,
    )


def test_the_first_unit_runs_and_the_second_never_launches(limited: SimpleNamespace) -> None:
    project, first = limited.project, limited.first

    assert first.disposition is _D.MAX_SUBPHASES_REACHED
    assert [e.subphase_id.root for e in first.completed_subphases] == ["01"]
    assert limited.state.counts == (2, 1, 1)
    assert first.reserved_subphases == 1
    assert _reserved(project, first) == [("01", "01")]


def test_no_planner_call_is_spent_on_work_this_run_cannot_execute(
    limited: SimpleNamespace,
) -> None:
    # Contract + tests for the first unit only: no JIT replan, no Contract for the second.
    assert limited.state.counts[0] == 2
    # The replan is delayed, not skipped: the next run must still perform it.
    assert limited.state.jit is JitReplanState.REPLAN_REQUIRED


def test_the_stop_is_durable_and_leaves_the_cursor_ready_for_a_later_run(
    limited: SimpleNamespace,
) -> None:
    project, first = limited.project, limited.first
    cursor = limited.state.cursor_after_first

    assert _state(project, first).stop.disposition is _D.MAX_SUBPHASES_REACHED
    assert cursor.current_subphase is not None and cursor.current_subphase.root == "02"
    assert cursor.active_contract is None
    assert cursor.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING


def test_resuming_the_same_exhausted_run_launches_nothing(limited: SimpleNamespace) -> None:
    again = limited.again

    assert again.disposition is _D.MAX_SUBPHASES_REACHED
    assert limited.after_again == limited.state.counts
    assert again.reserved_subphases == 1


def test_a_later_run_with_its_own_budget_replans_then_finishes_and_gates(
    limited: SimpleNamespace,
) -> None:
    project, later = limited.project, limited.later

    # The delayed replan, then Contract + tests for the second unit; the gate needs no slot.
    assert later.disposition is _D.PROJECT_COMPLETE
    assert project.counts() == (5, 2, 2)
    assert later.project_run_id != limited.first.project_run_id
    assert later.reserved_subphases == 1
    assert _reserved(project, later) == [("01", "02")]
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == ["01", "02"]
    assert list_project_runs(project.runtime_dir) == (
        limited.first.project_run_id,
        later.project_run_id,
    )


def test_a_zero_sub_phase_budget_launches_nothing(tmp_path: Path) -> None:
    project = autonomous_project(tmp_path, phases=_ONE_PHASE)

    result = run_autonomous(project, make_policy(max_subphases=0), clock=FakeClock())

    assert result.disposition is _D.MAX_SUBPHASES_REACHED
    assert result.reserved_subphases == 0
    assert project.counts() == (0, 0, 0)
    assert project.markers() == []


# ===========================================================================
# Fixed outline: the host policy can run the published outline without JIT replanning
# ===========================================================================


def _spy_ordinary_jit(monkeypatch: pytest.MonkeyPatch) -> list[bool]:
    """Record the ``jit_replan`` every Sub-phase-step call of the driver passes."""
    seen: list[bool] = []
    original = autonomous_run.step_project_run

    def spy(*args: Any, **kwargs: Any) -> Any:
        if "jit_replan" in kwargs:
            seen.append(kwargs["jit_replan"])
        return original(*args, **kwargs)

    monkeypatch.setattr(autonomous_run, "step_project_run", spy)
    return seen


def _spy_replans(monkeypatch: pytest.MonkeyPatch) -> list[object]:
    calls: list[object] = []
    original = project_orchestrator.run_jit_replan

    def spy(*args: Any, **kwargs: Any) -> Any:
        calls.append(args)
        return original(*args, **kwargs)

    monkeypatch.setattr(project_orchestrator, "run_jit_replan", spy)
    return calls


def test_default_policy_passes_jit_replanning_into_ordinary_orchestration(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = autonomous_project(tmp_path, phases=_THREE_UNITS)
    seen = _spy_ordinary_jit(monkeypatch)
    replans = _spy_replans(monkeypatch)

    result = run_autonomous(project, make_policy(), clock=FakeClock())

    assert result.disposition is _D.PROJECT_COMPLETE
    assert seen and all(value is True for value in seen)
    assert len(replans) == 2  # between 01->02 and 02->03, exactly as before
    assert project.counts() == (8, 3, 3)


def test_a_fixed_outline_policy_runs_the_frozen_outline_without_any_jit_replan(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = autonomous_project(tmp_path, phases=_THREE_UNITS, jit=False)
    seen = _spy_ordinary_jit(monkeypatch)
    replans = _spy_replans(monkeypatch)

    result = run_autonomous(project, make_policy(jit_replan=False), clock=FakeClock())

    assert result.disposition is _D.PROJECT_COMPLETE
    assert seen and all(value is False for value in seen)
    assert replans == []
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == [
        "01",
        "02",
        "03",
    ]
    assert project.counts() == (6, 3, 3)  # Contract + tests per unit, no replan
    assert _reserved(project, result) == [("01", "01"), ("01", "02"), ("01", "03")]
    assert not (project.runtime_dir / "planning" / "replans").exists()


def test_a_fixed_outline_spends_no_planner_call_on_a_unit_it_cannot_execute(
    tmp_path: Path,
) -> None:
    project = autonomous_project(tmp_path, phases=_TWO_UNITS, jit=False)

    result = run_autonomous(
        project, make_policy(max_subphases=1, jit_replan=False), clock=FakeClock()
    )

    assert result.disposition is _D.MAX_SUBPHASES_REACHED
    assert project.counts() == (2, 1, 1)
    assert project.cursor().active_contract is None
    assert _reserved(project, result) == [("01", "01")]


def test_a_fixed_outline_run_continues_the_published_outline_after_an_unreplanned_unit(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    # An earlier replanning run stopped before its replan: no receipt exists, so the published
    # outline is untouched and a fixed-outline run executes it as published.
    project = autonomous_project(tmp_path, phases=_TWO_UNITS, jit=False)
    first = run_autonomous(project, make_policy(max_subphases=1), clock=FakeClock())
    assert first.disposition is _D.MAX_SUBPHASES_REACHED
    assert jit_replan_state(project.project_root, project.runtime_dir) is (
        JitReplanState.REPLAN_REQUIRED
    )
    replans = _spy_replans(monkeypatch)

    later = run_autonomous(project, make_policy(jit_replan=False), clock=FakeClock())

    assert later.disposition is _D.PROJECT_COMPLETE
    assert replans == []
    assert project.counts() == (4, 2, 2)


def test_a_fixed_outline_run_stops_at_an_accepted_but_unapplied_replan(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    import lockstep.jit_replan as jit_replan_module

    # A revised (retitled) successor, so the accepted receipt differs from the published outline.
    plan = master_plan(_TWO_UNITS).phases[0]
    successor = plan.subphases[1].model_copy(update={"title": "revised successor"})
    revised = plan.model_copy(update={"subphases": (plan.subphases[0], successor)})
    project = autonomous_project(
        tmp_path,
        phases=_TWO_UNITS,
        planner=[*unit_script("01", "01"), replan_response(revised), *unit_script("01", "02")],
    )
    crash_once(monkeypatch, jit_replan_module, "_apply_receipt")
    with pytest.raises(CrashError):
        run_autonomous(project, make_policy(), clock=FakeClock())
    assert jit_replan_state(project.project_root, project.runtime_dir) is (
        JitReplanState.REPLAN_ACCEPTED
    )
    counts = project.counts()
    cursor = _cursor_bytes(project)

    fixed = run_autonomous(project, make_policy(jit_replan=False), clock=FakeClock())

    assert fixed.disposition is _D.RECOVERY_REQUIRED
    assert fixed.detail is not None and "accepted jit replan" in fixed.detail
    assert fixed.reserved_subphases == 0
    assert project.counts() == counts
    assert _cursor_bytes(project) == cursor
    assert jit_replan_state(project.project_root, project.runtime_dir) is (
        JitReplanState.REPLAN_ACCEPTED
    )

    # A replanning run settles the accepted receipt (no new Planner call for it) and finishes.
    settled = run_autonomous(project, make_policy(), clock=FakeClock())

    assert settled.disposition is _D.PROJECT_COMPLETE
    assert project.counts() == (5, 2, 2)


# ===========================================================================
# Scenario D: a retry is more work in one unit, never another unit
# ===========================================================================


def test_a_reworked_unit_is_debited_once_and_the_run_continues(tmp_path: Path) -> None:
    project = autonomous_project(
        tmp_path,
        phases=_ONE_PHASE,
        implementer=[_impl_response("01"), _impl_response("01", verbose=True)],
        reviewer=[
            _review_response("01", attempt=1, verdict="rework"),
            _review_response("01", attempt=2),
        ],
    )

    result = run_autonomous(
        project, make_policy(max_subphases=1, retry_attempts=3), clock=FakeClock()
    )

    assert result.disposition is _D.PROJECT_COMPLETE
    assert result.reserved_subphases == 1
    assert project.counts() == (2, 2, 2)
    totals = project_runtime_metrics(project.txn_dir("01", "01"), repository_change=None).totals
    assert totals.executed_attempts == 2 and totals.repeated_attempts == 1


def test_an_exhausted_retry_budget_stops_the_run_and_later_work_never_starts(
    tmp_path: Path,
) -> None:
    project = autonomous_project(
        tmp_path,
        phases=_TWO_UNITS,
        implementer=[_impl_response("01"), _impl_response("02")],
        reviewer=[_review_response("01", attempt=1, verdict="rework")],
    )

    result = run_autonomous(project, make_policy(retry_attempts=1), clock=FakeClock())

    assert result.disposition is _D.TERMINAL_HALT
    assert result.child_disposition is ProjectRunDisposition.HALTED
    assert result.resume_disposition is ResumeExecutionDisposition.RETRY_EXHAUSTED
    assert result.reserved_subphases == 1
    assert project.counts() == (2, 1, 1)  # the second unit is never planned or launched
    assert project.cursor().completed_subphases == ()


# ===========================================================================
# Scenarios E, F: gate remediation is a Sub-phase and consumes the global budget
# ===========================================================================


@pytest.mark.parametrize("jit_replan", [True, False])
def test_a_gate_remediation_consumes_one_budget_slot_and_the_gate_attempt_none(
    tmp_path: Path, jit_replan: bool
) -> None:
    project = autonomous_project(
        tmp_path,
        phases=_ONE_PHASE,
        planner=[
            *unit_script("01", "01"),
            remediation_plan_response("01", ["01"], "02"),
            *unit_script("01", "02"),
        ],
        implementer=[_impl_response("01"), _impl_response("02")],
        reviewer=[review_response("01", "01"), review_response("01", "02")],
        gate_commands=_fail_once,
    )

    result = run_autonomous(
        project,
        make_policy(max_subphases=2, max_gate_remediations=1, jit_replan=jit_replan),
        clock=FakeClock(),
    )

    assert result.disposition is _D.PROJECT_COMPLETE
    assert result.reserved_subphases == 2
    assert _reserved(project, result) == [("01", "01"), ("01", "02")]
    assert list_phase_gate_attempts(project.runtime_dir, _P1) == (1, 2)
    first = load_phase_gate_decision(project.runtime_dir, _P1, 1)
    second = load_phase_gate_decision(project.runtime_dir, _P1, 2)
    assert first is not None and first.outcome is PhaseGateVerdict.FAIL
    assert second is not None and second.outcome is PhaseGateVerdict.PASS
    receipt = load_remediation_receipt(project.runtime_dir, _P1, 1)
    assert receipt is not None and receipt.outline.subphase_id.root == "02"
    # Unit, remediation plan, remediation unit: a remediation never triggers an ordinary replan.
    assert project.counts() == (5, 2, 2)
    assert len(project.markers()) == 2


def test_a_failed_gate_without_sub_phase_capacity_persists_the_failure_and_plans_no_repair(
    tmp_path: Path,
) -> None:
    project = autonomous_project(
        tmp_path,
        phases=_ONE_PHASE,
        planner=[
            *unit_script("01", "01"),
            remediation_plan_response("01", ["01"], "02"),
            *unit_script("01", "02"),
        ],
        implementer=[_impl_response("01"), _impl_response("02")],
        reviewer=[review_response("01", "01"), review_response("01", "02")],
        gate_commands=_fail_once,
    )
    clock = FakeClock()
    policy = make_policy(max_subphases=1, max_gate_remediations=1)

    first = run_autonomous(project, policy, clock=clock)

    assert first.disposition is _D.MAX_SUBPHASES_REACHED
    assert first.remediation_required is True
    assert project.counts() == (2, 1, 1)  # no remediation Planner, Contract, Implementer
    decision = load_phase_gate_decision(project.runtime_dir, _P1, 1)
    assert decision is not None and decision.outcome is PhaseGateVerdict.FAIL
    assert load_remediation_receipt(project.runtime_dir, _P1, 1) is None
    cursor = project.cursor()
    assert cursor.completed_phases == ()  # the Phase is incomplete
    assert cursor.phase_gate_status is PhaseGateStatus.READY
    assert len(project.markers()) == 1

    # Re-entering does not rerun the gate merely because remediation could not start.
    again = run_autonomous(project, policy, clock=clock, project_run_id=first.project_run_id)
    assert again.disposition is _D.MAX_SUBPHASES_REACHED
    assert len(project.markers()) == 1
    assert project.counts() == (2, 1, 1)

    # A later run continues from the durable gate evidence and repairs the Phase.
    later = run_autonomous(project, policy, clock=clock)
    assert later.disposition is _D.PROJECT_COMPLETE
    assert project.counts() == (5, 2, 2)
    assert list_phase_gate_attempts(project.runtime_dir, _P1) == (1, 2)
    assert len(project.markers()) == 2


def test_a_zero_remediation_bound_stops_at_the_first_gate_failure(tmp_path: Path) -> None:
    project = autonomous_project(tmp_path, phases=_ONE_PHASE, gate_commands=_failing)

    result = run_autonomous(project, make_policy(max_gate_remediations=0), clock=FakeClock())

    assert result.disposition is _D.GATE_REMEDIATION_EXHAUSTED
    assert result.remediation_required is True
    assert project.counts() == (2, 1, 1)
    assert project.cursor().completed_phases == ()


# ===========================================================================
# Scenarios G, H, I: the unattended wall-clock budget
# ===========================================================================


def test_a_run_with_no_time_left_launches_no_provider_and_no_command(tmp_path: Path) -> None:
    project = autonomous_project(tmp_path)

    result = run_autonomous(project, make_policy(wall_clock_seconds=0.0), clock=FakeClock())

    assert result.disposition is _D.WALL_CLOCK_BUDGET_EXHAUSTED
    assert project.counts() == (0, 0, 0)
    assert project.markers() == []
    assert result.reserved_subphases == 0
    assert _state(project, result).stop.disposition is _D.WALL_CLOCK_BUDGET_EXHAUSTED
    kinds = [e.kind for e in read_project_run_events(project.runtime_dir, result.project_run_id)]
    assert kinds == [ProjectRunEventKind.RUN_STARTED, ProjectRunEventKind.RUN_STOPPED]


def test_the_budget_is_checked_between_units_before_any_new_planner_call(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = autonomous_project(tmp_path, phases=_TWO_UNITS)
    clock = FakeClock()
    # Plan + bind, then run the first unit; the deadline passes right after it completes.
    after_call(monkeypatch, autonomous_run, "step_project_run", 2, lambda: clock.advance(10_000))

    result = run_autonomous(project, make_policy(wall_clock_seconds=3600.0), clock=clock)

    assert result.disposition is _D.WALL_CLOCK_BUDGET_EXHAUSTED
    assert [e.subphase_id.root for e in result.completed_subphases] == ["01"]
    assert project.counts() == (2, 1, 1)  # no JIT replan and no second Contract
    assert jit_replan_state(project.project_root, project.runtime_dir) is (
        JitReplanState.REPLAN_REQUIRED
    )


def test_remaining_time_caps_a_long_provider_timeout_and_the_stop_is_the_budgets(
    tmp_path: Path,
) -> None:
    execution = ExecutionConfig(
        phase_gate_commands=((sys.executable, "-c", "pass"),),
        agent_timeout_seconds=600.0,
        command_timeout_seconds=600.0,
    )
    project = autonomous_project(tmp_path, phases=_ONE_PHASE, execution=execution)
    sleeping_planner(project, seconds=60.0)
    started = time.monotonic()

    result = run_autonomous(
        project,
        make_policy(wall_clock_seconds=2.0),
        clock=FakeClock(),  # frozen: 2.0 s remain at every launch
        planning_timeout_seconds=600.0,
    )

    assert time.monotonic() - started < 40
    assert result.disposition is _D.WALL_CLOCK_BUDGET_EXHAUSTED
    assert result.disposition is not _D.TERMINAL_HALT
    assert project.launches("planner") == 1
    assert project.counts()[1:] == (0, 0)
    assert _state(project, result).stop.disposition is _D.WALL_CLOCK_BUDGET_EXHAUSTED


def test_remaining_time_caps_a_gate_command_and_it_is_not_misreported_as_a_gate_failure(
    tmp_path: Path,
) -> None:
    execution = ExecutionConfig(
        phase_gate_commands=((sys.executable, "-c", "import time; time.sleep(60)"),),
        agent_timeout_seconds=600.0,
        command_timeout_seconds=600.0,
    )
    project = autonomous_project(tmp_path, phases=_ONE_PHASE, execution=execution)
    started = time.monotonic()

    result = run_autonomous(project, make_policy(wall_clock_seconds=10.0), clock=FakeClock())

    assert time.monotonic() - started < 60
    assert result.disposition is _D.WALL_CLOCK_BUDGET_EXHAUSTED
    assert [e.subphase_id.root for e in result.completed_subphases] == ["01"]
    assert load_phase_gate_decision(project.runtime_dir, _P1, 1) is None
    assert project.cursor().phase_gate_status is PhaseGateStatus.READY
    assert project.cursor().completed_phases == ()


def test_the_deadline_survives_a_restart_and_a_dead_process_still_spends_wall_time(
    tmp_path: Path,
) -> None:
    project = autonomous_project(tmp_path, phases=_ONE_PHASE)
    clock = FakeClock()
    policy = make_policy(wall_clock_seconds=60.0)
    record = start_project_run(project.runtime, policy, clock=clock)
    started = clock()
    assert project.counts() == (0, 0, 0)  # creating the run launches nothing

    clock.advance(120)  # the process was down; wall time kept running
    first = run_autonomous(project, policy, clock=clock, project_run_id=record.project_run_id)
    clock.advance(1000)  # repeated restarts cannot extend the budget
    second = run_autonomous(project, policy, clock=clock, project_run_id=record.project_run_id)

    assert first.disposition is _D.WALL_CLOCK_BUDGET_EXHAUSTED
    assert second.disposition is _D.WALL_CLOCK_BUDGET_EXHAUSTED
    assert project.counts() == (0, 0, 0)
    reloaded = load_project_run(project.runtime_dir, record.project_run_id)
    assert reloaded is not None
    assert reloaded.started_at == started
    assert reloaded.deadline_at == started + timedelta(seconds=60)


def test_a_restart_inside_the_budget_resumes_under_the_original_deadline(tmp_path: Path) -> None:
    project = autonomous_project(tmp_path, phases=_ONE_PHASE)
    clock = FakeClock()
    policy = make_policy(wall_clock_seconds=3600.0)
    record = start_project_run(project.runtime, policy, clock=clock)
    clock.advance(100)

    result = run_autonomous(project, policy, clock=clock, project_run_id=record.project_run_id)

    assert result.disposition is _D.PROJECT_COMPLETE
    reloaded = load_project_run(project.runtime_dir, record.project_run_id)
    assert reloaded is not None and reloaded.deadline_at == record.deadline_at


# ===========================================================================
# Scenarios J, K, L, M: hard stops propagate and never skip failed work
# ===========================================================================


def _human_required_project(tmp_path: Path) -> GateProject:
    return autonomous_project(
        tmp_path,
        phases=_THREE_UNITS,
        implementer=[
            _impl_response("01"),
            _implementer_blocked_response(
                category=EscalationCategory.REQUIREMENT_AMBIGUITY,
                requested_authority=EscalationAuthority.HUMAN,
            ),
        ],
        reviewer=[review_response("01", "01")],
    )


def test_a_human_required_child_stops_the_run_immediately_with_its_reason_preserved(
    tmp_path: Path,
) -> None:
    project = _human_required_project(tmp_path)
    clock = FakeClock()
    policy = make_policy()

    result = run_autonomous(project, policy, clock=clock)

    assert result.disposition is _D.HUMAN_REQUIRED
    assert result.child_disposition is ProjectRunDisposition.HUMAN_REQUIRED
    assert result.escalation_disposition is SupervisorEscalationDisposition.HUMAN_REQUIRED
    assert [e.subphase_id.root for e in result.completed_subphases] == ["01"]
    # The second unit's Implementer was blocked: no Reviewer, no unit 03, no gate.
    _, implementers, reviewers = project.counts()
    assert (implementers, reviewers) == (2, 1)
    assert not project.txn_dir("01", "03").exists()
    assert project.markers() == []
    before = project.counts()

    again = run_autonomous(project, policy, clock=clock, project_run_id=result.project_run_id)

    assert again.disposition is _D.HUMAN_REQUIRED
    assert again.escalation_disposition is SupervisorEscalationDisposition.HUMAN_REQUIRED
    assert project.counts() == before
    assert _reserved(project, again) == [("01", "01"), ("01", "02")]  # never debited twice


def test_an_authoritative_exhausted_quota_stops_the_run_before_any_further_work(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = autonomous_project(tmp_path, phases=_TWO_UNITS)
    after_call(
        monkeypatch,
        autonomous_run,
        "step_project_run",
        2,
        lambda: append_quota_signal(project, "01", "01", QuotaStatus.EXHAUSTED),
    )

    result = run_autonomous(project, make_policy(), clock=FakeClock())

    assert result.disposition is _D.USAGE_LIMIT
    assert result.stop_reason is StopReason.USAGE_LIMIT
    assert [e.subphase_id.root for e in result.completed_subphases] == ["01"]
    assert project.counts() == (2, 1, 1)  # no JIT replan, no second unit
    assert project.markers() == []


@pytest.mark.parametrize("quota", [QuotaStatus.UNKNOWN, QuotaStatus.LOW, QuotaStatus.SAFE])
def test_an_unknown_or_low_or_safe_quota_never_stops_the_run(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, quota: QuotaStatus
) -> None:
    project = autonomous_project(tmp_path, phases=_TWO_UNITS)
    after_call(
        monkeypatch,
        autonomous_run,
        "step_project_run",
        2,
        lambda: append_quota_signal(project, "01", "01", quota),
    )

    result = run_autonomous(project, make_policy(), clock=FakeClock())

    assert result.disposition is _D.PROJECT_COMPLETE
    assert project.counts() == (5, 2, 2)


def test_quota_exhaustion_is_never_inferred_from_provider_prose(tmp_path: Path) -> None:
    prose = "usage limit reached: quota exhausted (HTTP 429, rate limit, try again later)"
    project = autonomous_project(
        tmp_path,
        phases=_TWO_UNITS,
        implementer=[_impl_response("01"), _process_failure(prose)],
    )
    clock = FakeClock()

    first = run_autonomous(project, make_policy(), clock=clock)

    assert first.disposition is _D.TERMINAL_HALT
    assert first.stop_reason is None

    # Only a typed fact in the child's journal can turn that halt into a usage stop.
    append_quota_signal(project, "01", "02", QuotaStatus.EXHAUSTED)
    again = run_autonomous(project, make_policy(), clock=clock, project_run_id=first.project_run_id)

    assert again.disposition is _D.USAGE_LIMIT
    assert again.stop_reason is StopReason.USAGE_LIMIT


def test_a_provider_process_failure_is_a_hard_stop_that_never_skips_the_unit(
    tmp_path: Path,
) -> None:
    project = autonomous_project(
        tmp_path,
        phases=_THREE_UNITS,
        implementer=[_impl_response("01"), _process_failure()],
    )
    clock = FakeClock()

    result = run_autonomous(project, make_policy(), clock=clock)

    assert result.disposition is _D.TERMINAL_HALT
    assert result.child_disposition is ProjectRunDisposition.HALTED
    assert [e.subphase_id.root for e in result.completed_subphases] == ["01"]
    assert project.counts() == (5, 2, 1)  # unit 03 and the gate never start
    assert project.markers() == []
    before = project.counts()

    again = run_autonomous(
        project, make_policy(), clock=clock, project_run_id=result.project_run_id
    )

    assert again.disposition is _D.TERMINAL_HALT
    assert project.counts() == before
    assert project.cursor().current_subphase is not None
    assert project.cursor().current_subphase.root == "02"


def test_malformed_agent_output_is_a_hard_stop(tmp_path: Path) -> None:
    project = autonomous_project(
        tmp_path,
        phases=_TWO_UNITS,
        implementer=[_impl_response("01"), _malformed_stdout_response()],
    )

    result = run_autonomous(project, make_policy(), clock=FakeClock())

    assert result.disposition is _D.TERMINAL_HALT
    assert [e.subphase_id.root for e in result.completed_subphases] == ["01"]
    assert project.markers() == []


def test_an_ambiguous_at_most_once_state_is_recovery_required_and_never_relaunched(
    tmp_path: Path,
) -> None:
    project = autonomous_project(
        tmp_path,
        phases=_ONE_PHASE,
        planner=[
            _contract_response("01"),
            _tests_response("01", path="tests/test_unexpected.py"),  # outside the Contract
        ],
    )
    clock = FakeClock()
    policy = make_policy()

    first = run_autonomous(project, policy, clock=clock)
    assert first.disposition is _D.TERMINAL_HALT
    before = project.counts()

    again = run_autonomous(project, policy, clock=clock, project_run_id=first.project_run_id)

    assert again.disposition is _D.RECOVERY_REQUIRED
    assert again.child_disposition is ProjectRunDisposition.RECOVERY_REQUIRED
    assert project.counts() == before
    assert project.cursor().completed_subphases == ()


# ===========================================================================
# Scenario N: project completion outranks everything
# ===========================================================================


def test_an_already_complete_project_returns_immediately_with_zero_external_work(
    tmp_path: Path,
) -> None:
    project = autonomous_project(tmp_path, phases=_ONE_PHASE)
    clock = FakeClock()
    first = run_autonomous(project, make_policy(), clock=clock)
    assert first.disposition is _D.PROJECT_COMPLETE
    counts, markers, cursor = project.counts(), project.markers(), _cursor_bytes(project)

    again = run_autonomous(project, make_policy(max_subphases=0), clock=clock)

    assert again.disposition is _D.PROJECT_COMPLETE
    assert again.reserved_subphases == 0
    assert project.counts() == counts
    assert project.markers() == markers
    assert _cursor_bytes(project) == cursor


# ===========================================================================
# Scenario O: the policy is immutable once a run exists
# ===========================================================================


@pytest.mark.parametrize(
    "changes",
    [
        {"max_subphases": 11},
        {"max_unattended_wall_clock_seconds": 3601.0},
        {"retry_budget": RetryBudget(max_attempts=AttemptNumber.model_validate(4))},
        {"max_gate_remediations": 2},
        {"until_phase": _P2},
        {"jit_replan": False},
    ],
)
def test_a_run_cannot_silently_gain_authority_by_resuming_under_another_policy(
    tmp_path: Path, changes: dict[str, Any]
) -> None:
    project = autonomous_project(tmp_path)
    clock = FakeClock()
    policy = make_policy()
    record = start_project_run(project.runtime, policy, clock=clock)
    policy_file = project_run_dir(project.runtime_dir, record.project_run_id) / "policy.json"
    before = policy_file.read_bytes()

    with pytest.raises(AutonomousRunPolicyMismatchError):
        run_autonomous(
            project,
            policy.model_copy(update=changes),
            clock=clock,
            project_run_id=record.project_run_id,
        )

    assert project.counts() == (0, 0, 0)
    assert policy_file.read_bytes() == before


def test_an_unknown_project_run_cannot_be_resumed(tmp_path: Path) -> None:
    project = autonomous_project(tmp_path)

    with pytest.raises(AutonomousRunError):
        run_autonomous(
            project,
            make_policy(),
            clock=FakeClock(),
            project_run_id=ProjectRunId.model_validate("prun-0042"),
        )

    assert project.counts() == (0, 0, 0)


@pytest.mark.parametrize(
    "changes",
    [
        {"max_unattended_wall_clock_seconds": math.inf},
        {"max_unattended_wall_clock_seconds": math.nan},
        {"max_subphases": math.inf},
        {"max_gate_remediations": None},
    ],
)
def test_an_unbounded_policy_cannot_start_unattended_execution(
    tmp_path: Path, changes: dict[str, Any]
) -> None:
    project = autonomous_project(tmp_path)

    with pytest.raises(AutonomousRunPolicyError):
        run_autonomous(project, make_policy().model_copy(update=changes), clock=FakeClock())

    assert project.counts() == (0, 0, 0)
    assert not (project.runtime_dir / "project-runs").exists()


# ===========================================================================
# Scenario P: the budget debit survives a crash and is never taken twice
# ===========================================================================


def test_a_crash_after_the_budget_debit_does_not_debit_again_on_restart(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = autonomous_project(tmp_path, phases=_ONE_PHASE)
    clock = FakeClock()
    policy = make_policy(max_subphases=1)
    record = start_project_run(project.runtime, policy, clock=clock)
    crash_once(monkeypatch, autonomous_run, "step_project_run")

    with pytest.raises(CrashError):
        run_autonomous(project, policy, clock=clock, project_run_id=record.project_run_id)

    state = load_project_run_state(project.runtime_dir, record.project_run_id)
    assert [(r.phase_id.root, r.subphase_id.root) for r in state.reservations] == [("01", "01")]
    assert project.counts() == (0, 0, 0)  # reserved, but nothing launched

    result = run_autonomous(project, policy, clock=clock, project_run_id=record.project_run_id)

    assert result.disposition is _D.PROJECT_COMPLETE  # a second debit would have stopped it
    assert result.reserved_subphases == 1
    kinds = [e.kind for e in read_project_run_events(project.runtime_dir, record.project_run_id)]
    assert kinds.count(ProjectRunEventKind.SUBPHASE_RESERVED) == 1


def test_completion_reconciliation_spends_no_sub_phase_budget(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = autonomous_project(tmp_path, phases=_ONE_PHASE)
    clock = FakeClock()
    crash_once(monkeypatch, project_orchestrator, "record_completed_subphase")
    with pytest.raises(CrashError):
        run_autonomous(project, make_policy(max_subphases=1), clock=clock)
    assert project.cursor().completed_subphases == ()  # complete in the journal only
    launches = project.counts()

    result = run_autonomous(project, make_policy(max_subphases=0), clock=clock)

    assert result.disposition is _D.PROJECT_COMPLETE
    assert result.reserved_subphases == 0
    assert project.counts() == launches  # nothing was launched to reconcile
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == ["01"]


# ===========================================================================
# Scenario Q: the PHASE_COMPLETE evidence crash window is repaired, idempotently
# ===========================================================================


def test_a_missing_phase_complete_event_is_repaired_once_without_rerunning_anything(
    tmp_path: Path,
) -> None:
    project = autonomous_project(tmp_path, phases={"01": ("01",), "02": ("11",)})
    clock = FakeClock()
    policy = make_policy(until_phase="01")
    first = run_autonomous(project, policy, clock=clock)
    assert first.disposition is _D.PHASE_BOUNDARY_REACHED
    journal = project.gate_dir("01") / "events.jsonl"
    lines = read_lines(journal)
    assert _gate_kinds(project, _P1)[-1] is PhaseGateEventKind.PHASE_COMPLETE
    journal.write_text("".join(lines[:-1]), encoding="utf-8")  # the crash window
    assert PhaseGateEventKind.PHASE_COMPLETE not in _gate_kinds(project, _P1)
    cursor, counts, markers = _cursor_bytes(project), project.counts(), project.markers()

    second = run_autonomous(project, policy, clock=clock, project_run_id=first.project_run_id)

    assert second.disposition is _D.PHASE_BOUNDARY_REACHED
    assert _gate_kinds(project, _P1) == [
        PhaseGateEventKind.PHASE_GATE_STARTED,
        PhaseGateEventKind.PHASE_GATE_PASSED,
        PhaseGateEventKind.PHASE_COMPLETE,
    ]
    assert _cursor_bytes(project) == cursor  # evidence repair only: the cursor is untouched
    assert project.counts() == counts  # no Planner, no agent
    assert project.markers() == markers  # no gate rerun
    repaired = file_bytes(project.gate_dir("01"))

    third = run_autonomous(project, policy, clock=clock, project_run_id=first.project_run_id)

    assert third.disposition is _D.PHASE_BOUNDARY_REACHED
    assert file_bytes(project.gate_dir("01")) == repaired  # no duplicate event


# ===========================================================================
# Scenario R: an unknown failure is recorded and never continued past
# ===========================================================================


def test_an_unexpected_internal_failure_is_recorded_as_terminal_and_reraised(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = autonomous_project(tmp_path, phases=_ONE_PHASE)
    crash_once(monkeypatch, autonomous_run, "step_project_run")

    with pytest.raises(CrashError):
        run_autonomous(project, make_policy(), clock=FakeClock())

    [identity] = list_project_runs(project.runtime_dir)
    state = load_project_run_state(project.runtime_dir, identity)
    assert state.stop is not None
    assert state.stop.disposition is _D.TERMINAL_HALT
    assert state.stop.detail == "CrashError"  # the type only; never the message
    events = read_project_run_events(project.runtime_dir, identity)
    assert events[-1].kind is ProjectRunEventKind.RUN_STOPPED
    assert project.counts() == (0, 0, 0)  # nothing ran after the failure
    assert project.markers() == []


def test_an_unexpected_failure_in_the_gate_path_stops_before_any_later_action(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = autonomous_project(tmp_path, phases={"01": ("01",), "02": ("11",)})
    crash_once(monkeypatch, autonomous_run, "run_phase_gate_attempt")

    with pytest.raises(CrashError):
        run_autonomous(project, make_policy(), clock=FakeClock())

    assert project.markers() == []
    assert project.cursor().phase_gate_status is PhaseGateStatus.READY
    assert project.counts() == (2, 1, 1)  # the next Phase never starts
    [identity] = list_project_runs(project.runtime_dir)
    stop = load_project_run_state(project.runtime_dir, identity).stop
    assert stop is not None and stop.disposition is _D.TERMINAL_HALT


# ===========================================================================
# Planner-authored script sanity for the shared support
# ===========================================================================


def test_the_default_planner_script_matches_the_driver_default_of_jit_replanning() -> None:
    assert len(planner_script(TWO_PHASES)) == 7
