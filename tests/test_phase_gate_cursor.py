"""Phase 11.5: the cursor's Phase-gate protocol -- PASS completion and remediation reopening.

Pure semantics of the two new cursor transitions and the one new status the Phase-gate
protocol needs, layered on the accepted 11.1 cursor:

* a gate PASS is the only thing that appends the current Phase to ``completed_phases``,
  and the successor Phase is derived by the host from the frozen Master Plan order;
* the final Phase's PASS has a legal durable representation (``current_phase is None``);
* a gate FAIL plus an accepted remediation plan reopens the *same* Phase with exactly one
  new Sub-phase.

Baseline classification: every test here is RED at entry (the transitions and the
``PROJECT_COMPLETE`` status do not exist); the unchanged 11.1 cursor suites remain the
GREEN_REGRESSION guard.
"""

from __future__ import annotations

import inspect
from typing import Any

import pytest
from pydantic import ValidationError
from test_project_cursor import (
    _completed,
    _contract,
    _cursor_data,
    _outline,
    _phase,
    _pid,
    _plan,
    _rid,
    _sid,
    _snapshot,
)

import lockstep.project_cursor as project_cursor
import lockstep.project_cursor_store as project_cursor_store
from lockstep.domain import MasterPlan, ProjectId
from lockstep.project_cursor import (
    PhaseGateStatus,
    PlanningEligibilityReason,
    ProjectCursor,
    ProjectCursorError,
    bind_active_contract,
    master_plan_digest,
    new_project_cursor,
    planning_eligibility,
    record_phase_gate_pass,
    record_subphase_completion,
    reopen_phase_for_remediation,
    require_legal_successor,
    validate_cursor_against_master_plan,
)
from lockstep.project_cursor_store import (
    ProjectCursorStoreError,
    record_phase_completion,
    reopen_cursor_for_remediation,
)
from lockstep.state import WorkflowState


def _ready(plan: MasterPlan | None = None) -> ProjectCursor:
    """Every Sub-phase of the first Phase canonically complete: the gate is READY."""
    plan = plan if plan is not None else _plan()
    cursor = new_project_cursor(plan)
    index = 0
    while cursor.current_subphase is not None:
        index += 1
        phase = cursor.current_phase
        assert phase is not None
        run = f"run-{index}"
        cursor = bind_active_contract(
            cursor,
            _contract(phase_id=phase.root, subphase_id=cursor.current_subphase.root),
            transaction_run_id=_rid(run),
        )
        cursor = record_subphase_completion(
            cursor, _snapshot(WorkflowState.SUBPHASE_COMPLETE, run_id=run)
        )
    assert cursor.phase_gate_status is PhaseGateStatus.READY
    return cursor


def _two_phase_plan() -> MasterPlan:
    return MasterPlan(
        project_id=ProjectId.model_validate("lockstep"),
        title="Lockstep",
        objective="Build the control plane.",
        phases=(
            _phase("01", (_outline("01"), _outline("02", ("01",)))),
            _phase(
                "02",
                (_outline("01"), _outline("02", ("01",)), _outline("03", ("02",))),
                deps=("01",),
            ),
        ),
    )


def _single_phase_plan() -> MasterPlan:
    return MasterPlan(
        project_id=ProjectId.model_validate("lockstep"),
        title="Lockstep",
        objective="Build the control plane.",
        phases=(_phase("01", (_outline("01"), _outline("02", ("01",)))),),
    )


# ---------------------------------------------------------------------------
# Vocabulary and public surface
# ---------------------------------------------------------------------------


def test_the_phase_gate_status_vocabulary_gains_exactly_project_complete() -> None:
    assert {s.name for s in PhaseGateStatus} == {"SUBPHASES_PENDING", "READY", "PROJECT_COMPLETE"}
    assert PhaseGateStatus.PROJECT_COMPLETE.value == "project_complete"


def test_the_new_transitions_are_not_part_of_the_frozen_11_1_export_surface() -> None:
    assert "record_phase_gate_pass" not in project_cursor.__all__
    assert "reopen_phase_for_remediation" not in project_cursor.__all__
    assert "record_phase_completion" not in project_cursor_store.__all__
    assert "reopen_cursor_for_remediation" not in project_cursor_store.__all__


# ---------------------------------------------------------------------------
# PASS: completion of a non-final Phase
# ---------------------------------------------------------------------------


def test_a_pass_completes_the_current_phase_and_starts_the_next_in_master_plan_order() -> None:
    plan = _two_phase_plan()
    ready = _ready(plan)

    advanced = record_phase_gate_pass(ready, plan, phase_id=_pid("01"))

    assert advanced.revision == ready.revision + 1
    assert advanced.completed_phases == (_pid("01"),)
    assert advanced.current_phase == _pid("02")
    # The next Phase starts from its own frozen outline; only its head is current.
    assert advanced.current_subphase == _sid("01")
    assert advanced.remaining_outline == (_outline("02", ("01",)), _outline("03", ("02",)))
    assert advanced.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING
    assert advanced.active_contract is None


def test_a_pass_leaves_completed_subphase_history_and_identity_untouched() -> None:
    plan = _two_phase_plan()
    ready = _ready(plan)

    advanced = record_phase_gate_pass(ready, plan, phase_id=_pid("01"))

    assert advanced.completed_subphases == ready.completed_subphases
    assert advanced.project_id == ready.project_id
    assert advanced.master_plan_digest == ready.master_plan_digest


def test_the_successor_is_derived_from_the_master_plan_not_chosen_by_the_caller() -> None:
    plan = _plan()  # three Phases: 01, 02, 03
    ready = _ready(plan)

    advanced = record_phase_gate_pass(ready, plan, phase_id=_pid("01"))

    assert advanced.current_phase == _pid("02")
    assert "next_phase" not in inspect.signature(record_phase_gate_pass).parameters


def test_a_pass_is_a_legal_direct_successor() -> None:
    plan = _two_phase_plan()
    ready = _ready(plan)

    require_legal_successor(ready, record_phase_gate_pass(ready, plan, phase_id=_pid("01")))


def test_the_advanced_cursor_still_binds_to_the_master_plan_in_order() -> None:
    plan = _two_phase_plan()
    advanced = record_phase_gate_pass(_ready(plan), plan, phase_id=_pid("01"))

    validate_cursor_against_master_plan(advanced, plan)


def test_a_pass_refuses_a_phase_that_still_has_subphase_work() -> None:
    plan = _two_phase_plan()
    pending = new_project_cursor(plan)

    with pytest.raises(ProjectCursorError):
        record_phase_gate_pass(pending, plan, phase_id=_pid("01"))


def test_a_pass_refuses_a_phase_that_is_not_the_current_one() -> None:
    plan = _two_phase_plan()
    ready = _ready(plan)

    with pytest.raises(ProjectCursorError):
        record_phase_gate_pass(ready, plan, phase_id=_pid("02"))


def test_a_pass_refuses_a_cursor_that_is_bound_to_a_different_master_plan() -> None:
    plan = _two_phase_plan()
    ready = _ready(plan)
    other = plan.model_copy(update={"title": "A different plan"})

    with pytest.raises(ProjectCursorError):
        record_phase_gate_pass(ready, other, phase_id=_pid("01"))


def test_recording_the_same_pass_again_is_an_idempotent_no_op() -> None:
    plan = _two_phase_plan()
    advanced = record_phase_gate_pass(_ready(plan), plan, phase_id=_pid("01"))

    assert record_phase_gate_pass(advanced, plan, phase_id=_pid("01")) == advanced


def test_a_pass_never_reopens_or_skips_a_phase() -> None:
    plan = _plan()
    advanced = record_phase_gate_pass(_ready(plan), plan, phase_id=_pid("01"))

    # 03 was never current; 01 is already complete (idempotent); only the current Phase passes.
    with pytest.raises(ProjectCursorError):
        record_phase_gate_pass(advanced, plan, phase_id=_pid("03"))


# ---------------------------------------------------------------------------
# PASS: the final Phase
# ---------------------------------------------------------------------------


def test_passing_the_final_phase_yields_a_legal_project_complete_cursor() -> None:
    plan = _single_phase_plan()
    ready = _ready(plan)

    done = record_phase_gate_pass(ready, plan, phase_id=_pid("01"))

    assert done.current_phase is None
    assert done.completed_phases == (_pid("01"),)
    assert done.current_subphase is None
    assert done.remaining_outline == ()
    assert done.active_contract is None
    assert done.phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE
    assert done.revision == ready.revision + 1
    require_legal_successor(ready, done)
    validate_cursor_against_master_plan(done, plan)


def test_the_project_complete_cursor_round_trips_through_json() -> None:
    plan = _single_phase_plan()
    done = record_phase_gate_pass(_ready(plan), plan, phase_id=_pid("01"))

    assert ProjectCursor.model_validate_json(done.model_dump_json()) == done


def test_a_project_complete_cursor_offers_nothing_to_plan() -> None:
    plan = _single_phase_plan()
    done = record_phase_gate_pass(_ready(plan), plan, phase_id=_pid("01"))

    eligibility = planning_eligibility(done)

    assert not eligibility.eligible
    assert eligibility.reason is PlanningEligibilityReason.PHASE_GATE_PENDING


def test_recording_the_final_pass_again_is_an_idempotent_no_op() -> None:
    plan = _single_phase_plan()
    done = record_phase_gate_pass(_ready(plan), plan, phase_id=_pid("01"))

    assert record_phase_gate_pass(done, plan, phase_id=_pid("01")) == done


def test_a_project_complete_cursor_cannot_be_validated_against_a_longer_plan() -> None:
    plan = _two_phase_plan()
    short = _single_phase_plan()
    done = record_phase_gate_pass(_ready(short), short, phase_id=_pid("01"))

    with pytest.raises(ProjectCursorError):
        validate_cursor_against_master_plan(done, plan)


# ---------------------------------------------------------------------------
# Invariants of the widened cursor
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "overrides",
    [
        # No current Phase without the project-complete status.
        {
            "current_phase": None,
            "completed_phases": ["01"],
            "current_subphase": None,
            "remaining_outline": [],
            "phase_gate_status": "ready",
        },
        # The project-complete status with a current Phase.
        {
            "current_subphase": None,
            "remaining_outline": [],
            "phase_gate_status": "project_complete",
        },
        # No current Phase, but a current Sub-phase.
        {
            "current_phase": None,
            "completed_phases": ["01"],
            "remaining_outline": [],
            "phase_gate_status": "project_complete",
        },
        # No current Phase, but a remaining outline.
        {
            "current_phase": None,
            "completed_phases": ["01"],
            "current_subphase": None,
            "phase_gate_status": "project_complete",
        },
        # No current Phase and nothing was ever completed.
        {
            "current_phase": None,
            "completed_phases": [],
            "current_subphase": None,
            "remaining_outline": [],
            "phase_gate_status": "project_complete",
        },
    ],
)
def test_invalid_project_complete_states_are_unrepresentable(overrides: dict[str, Any]) -> None:
    with pytest.raises(ValidationError):
        ProjectCursor.model_validate(_cursor_data(**overrides))


def test_an_accepted_v1_cursor_still_loads_unchanged() -> None:
    cursor = ProjectCursor.model_validate(_cursor_data())

    assert cursor.current_phase == _pid("01")
    assert cursor.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING
    assert cursor.schema_version.root == 1


def test_a_historical_cursor_with_a_completed_phase_still_validates() -> None:
    cursor = ProjectCursor.model_validate(
        _cursor_data(
            current_phase="02",
            completed_phases=["01"],
            current_subphase="01",
            completed_subphases=[_completed("01", "01", "run-1")],
            remaining_outline=[],
        )
    )

    assert cursor.current_phase == _pid("02")


# ---------------------------------------------------------------------------
# Successor legality
# ---------------------------------------------------------------------------


def test_a_phase_cannot_advance_from_a_cursor_that_is_not_ready() -> None:
    plan = _two_phase_plan()
    pending = new_project_cursor(plan)
    forged = pending.model_copy(
        update={
            "revision": pending.revision + 1,
            "completed_phases": (_pid("01"),),
            "current_phase": _pid("02"),
        }
    )

    with pytest.raises(ProjectCursorError):
        require_legal_successor(pending, forged)


def test_an_advance_cannot_rewrite_completed_phase_history() -> None:
    plan = _plan()
    ready = _ready(plan)
    advanced = record_phase_gate_pass(ready, plan, phase_id=_pid("01"))
    forged = advanced.model_copy(update={"completed_phases": (_pid("02"),)})

    with pytest.raises(ProjectCursorError):
        require_legal_successor(ready, forged)


def test_an_advance_cannot_drop_completed_subphase_history() -> None:
    plan = _two_phase_plan()
    ready = _ready(plan)
    advanced = record_phase_gate_pass(ready, plan, phase_id=_pid("01"))
    forged = advanced.model_copy(update={"completed_subphases": ()})

    with pytest.raises(ProjectCursorError):
        require_legal_successor(ready, forged)


def test_a_project_complete_cursor_has_no_successor() -> None:
    plan = _single_phase_plan()
    done = record_phase_gate_pass(_ready(plan), plan, phase_id=_pid("01"))
    forged = done.model_copy(update={"revision": done.revision + 1})

    with pytest.raises(ProjectCursorError):
        require_legal_successor(done, forged)


def test_a_regression_of_the_gate_that_is_not_a_remediation_is_still_refused() -> None:
    ready = _ready()
    regressed = ready.model_copy(
        update={
            "revision": ready.revision + 1,
            "phase_gate_status": PhaseGateStatus.SUBPHASES_PENDING,
        }
    )

    with pytest.raises(ProjectCursorError):
        require_legal_successor(ready, regressed)


# ---------------------------------------------------------------------------
# FAIL: reopening the same Phase for one remediation Sub-phase
# ---------------------------------------------------------------------------


def test_a_remediation_reopens_the_same_phase_with_exactly_one_new_subphase() -> None:
    ready = _ready()

    reopened = reopen_phase_for_remediation(ready, _outline("04", ("03",)))

    assert reopened.revision == ready.revision + 1
    assert reopened.current_phase == ready.current_phase
    assert reopened.completed_phases == ready.completed_phases
    assert reopened.completed_subphases == ready.completed_subphases
    assert reopened.current_subphase == _sid("04")
    assert reopened.remaining_outline == ()
    assert reopened.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING
    assert reopened.active_contract is None
    require_legal_successor(ready, reopened)


def test_a_remediation_may_depend_on_any_completed_subphase_of_the_phase() -> None:
    reopened = reopen_phase_for_remediation(_ready(), _outline("04", ("01", "03")))

    assert reopened.current_subphase == _sid("04")


@pytest.mark.parametrize("depends_on", [("09",), ("04",)])
def test_a_remediation_may_only_depend_on_completed_history(depends_on: tuple[str, ...]) -> None:
    with pytest.raises(ProjectCursorError):
        reopen_phase_for_remediation(_ready(), _outline("04", depends_on))


@pytest.mark.parametrize("sid", ["01", "02", "03"])
def test_a_remediation_cannot_reuse_a_completed_subphase_id(sid: str) -> None:
    with pytest.raises(ProjectCursorError):
        reopen_phase_for_remediation(_ready(), _outline(sid))


def test_a_remediation_requires_a_ready_gate() -> None:
    pending = new_project_cursor(_plan())

    with pytest.raises(ProjectCursorError):
        reopen_phase_for_remediation(pending, _outline("09"))


def test_a_remediation_is_refused_on_a_project_complete_cursor() -> None:
    plan = _single_phase_plan()
    done = record_phase_gate_pass(_ready(plan), plan, phase_id=_pid("01"))

    with pytest.raises(ProjectCursorError):
        reopen_phase_for_remediation(done, _outline("09"))


def test_reapplying_the_same_remediation_is_an_idempotent_no_op() -> None:
    reopened = reopen_phase_for_remediation(_ready(), _outline("04", ("03",)))

    assert reopen_phase_for_remediation(reopened, _outline("04", ("03",))) == reopened


def test_a_different_remediation_cannot_replace_the_one_already_reopened() -> None:
    reopened = reopen_phase_for_remediation(_ready(), _outline("04", ("03",)))

    with pytest.raises(ProjectCursorError):
        reopen_phase_for_remediation(reopened, _outline("05", ("03",)))


def test_a_reopening_that_carries_a_backlog_is_not_a_legal_successor() -> None:
    ready = _ready()
    backlog = ready.model_copy(
        update={
            "revision": ready.revision + 1,
            "phase_gate_status": PhaseGateStatus.SUBPHASES_PENDING,
            "current_subphase": _sid("04"),
            "remaining_outline": (_outline("05", ("04",)),),
        }
    )

    with pytest.raises(ProjectCursorError):
        require_legal_successor(ready, backlog)


def test_a_reopening_cannot_change_the_phase() -> None:
    plan = _two_phase_plan()
    ready = _ready(plan)
    forged = ready.model_copy(
        update={
            "revision": ready.revision + 1,
            "phase_gate_status": PhaseGateStatus.SUBPHASES_PENDING,
            "current_phase": _pid("02"),
            "current_subphase": _sid("04"),
        }
    )

    with pytest.raises(ProjectCursorError):
        require_legal_successor(ready, forged)


# ---------------------------------------------------------------------------
# The durable operations refuse an uninitialized project
# ---------------------------------------------------------------------------


def test_recording_a_phase_completion_requires_an_initialized_cursor(tmp_path: Any) -> None:
    project_root, runtime_dir = tmp_path / "project", tmp_path / "runtime"
    project_root.mkdir()
    runtime_dir.mkdir()

    with pytest.raises(ProjectCursorStoreError):
        record_phase_completion(project_root, runtime_dir, phase_id=_pid("01"))


def test_reopening_for_remediation_requires_an_initialized_cursor(tmp_path: Any) -> None:
    project_root, runtime_dir = tmp_path / "project", tmp_path / "runtime"
    project_root.mkdir()
    runtime_dir.mkdir()

    with pytest.raises(ProjectCursorStoreError):
        reopen_cursor_for_remediation(project_root, runtime_dir, _outline("04", ("03",)))


def test_the_master_plan_digest_is_unchanged_by_a_phase_advance() -> None:
    plan = _two_phase_plan()
    advanced = record_phase_gate_pass(_ready(plan), plan, phase_id=_pid("01"))

    assert advanced.master_plan_digest == master_plan_digest(plan)
