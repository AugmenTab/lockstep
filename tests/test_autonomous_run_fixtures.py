"""Phase 11.6 fixture characterization (GREEN_CHARACTERIZATION at entry).

The autonomous-run suites script a whole multi-Phase project and inject one kind of fact into a
finished child transaction. This module proves, against the *accepted* 11.1-11.5 machinery only,
that those fixtures behave the way the 11.6 acceptance tests assume. It is also the executable
statement of what a human relaying work between the existing layers does today -- the manual
loop the 11.6 driver replaces. Nothing here imports an 11.6 production module.
"""

from __future__ import annotations

from pathlib import Path

from autonomous_run_support import (
    TWO_PHASES,
    FakeClock,
    append_quota_signal,
    autonomous_project,
    planner_script,
)
from phase_gate_support import GateProject
from test_supervisor_resume_execution import _budget

from lockstep.domain import PhaseId, QuotaStatus
from lockstep.jit_replan import JitReplanState, jit_replan_state
from lockstep.persistence import ExecutionEvent, load_verified_state, read_events
from lockstep.phase_gate_cycle import PhaseGateCycleDisposition, run_phase_gate_cycle
from lockstep.project_cursor import PhaseGateStatus
from lockstep.project_orchestrator import ProjectRunDisposition, run_project_phase

_P1 = PhaseId.model_validate("01")
_P2 = PhaseId.model_validate("02")


def _run_phase(project: GateProject) -> ProjectRunDisposition:
    return run_project_phase(
        project.runtime,
        request_factory=project.factory,
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
    ).disposition


def _gate(project: GateProject) -> PhaseGateCycleDisposition:
    return run_phase_gate_cycle(
        project.runtime,
        max_gate_remediations=1,
        request_factory=project.factory,
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
    ).disposition


def test_the_scripted_project_is_what_a_human_relays_between_the_existing_layers(
    tmp_path: Path,
) -> None:
    project = autonomous_project(tmp_path)

    assert _run_phase(project) is ProjectRunDisposition.PHASE_GATE_READY
    # Two Contract plans, two test-authoring turns, and the JIT replan between them.
    assert project.counts() == (5, 2, 2)
    assert _gate(project) is PhaseGateCycleDisposition.PHASE_COMPLETE

    assert _run_phase(project) is ProjectRunDisposition.PHASE_GATE_READY
    assert project.counts() == (7, 3, 3)
    assert _gate(project) is PhaseGateCycleDisposition.PROJECT_COMPLETE

    cursor = project.cursor()
    assert cursor.completed_phases == (_P1, _P2)
    assert cursor.current_phase is None
    assert cursor.phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE
    assert [e.subphase_id.root for e in cursor.completed_subphases] == ["01", "02", "11"]
    assert [label for label, _, _ in project.markers()] == ["gate", "gate"]


def test_the_planner_script_is_exactly_what_a_green_run_consumes() -> None:
    # Phase 01: contract + tests, replan, contract + tests; Phase 02: contract + tests.
    assert len(planner_script(TWO_PHASES)) == 7
    assert len(planner_script(TWO_PHASES, jit=False)) == 6


def test_a_first_subphase_of_a_new_phase_carries_no_replan_obligation(tmp_path: Path) -> None:
    project = autonomous_project(tmp_path)
    _run_phase(project)
    assert _gate(project) is PhaseGateCycleDisposition.PHASE_COMPLETE

    state = jit_replan_state(project.project_root, project.runtime_dir)

    assert state is JitReplanState.NOT_APPLICABLE
    assert project.cursor().current_phase == _P2


def test_a_quota_signal_appended_to_a_finished_child_journal_keeps_it_verifiable(
    tmp_path: Path,
) -> None:
    project = autonomous_project(tmp_path, phases={"01": ("01",)})
    assert _run_phase(project) is ProjectRunDisposition.PHASE_GATE_READY
    journal = project.txn_dir("01", "01") / "events.jsonl"
    state = project.txn_dir("01", "01") / "state.json"
    before = len(read_events(journal))

    append_quota_signal(project, "01", "01", QuotaStatus.EXHAUSTED)

    events = read_events(journal)
    assert len(events) == before + 1
    last = events[-1]
    assert isinstance(last, ExecutionEvent)
    assert last.usage is not None and last.usage.quota_status is QuotaStatus.EXHAUSTED
    assert load_verified_state(state, journal) is not None


def test_the_fake_clock_moves_only_when_told_to() -> None:
    clock = FakeClock()
    first = clock()

    assert clock() == first
    clock.advance(90)
    assert (clock() - first).total_seconds() == 90
