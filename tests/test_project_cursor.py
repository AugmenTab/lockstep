"""Phase 11.1: pure semantics of the durable project / Phase execution cursor."""

from typing import Any

import pytest
from pydantic import ValidationError

import lockstep.project_cursor as project_cursor
from lockstep.domain import (
    AcceptanceCriterion,
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    RunId,
    SubphaseContract,
    SubphaseId,
    SubphaseOutline,
    TestExpectation,
    TestSpecification,
)
from lockstep.project_cursor import (
    ActiveContractBinding,
    CompletedSubphase,
    PhaseGateStatus,
    PlanningEligibilityReason,
    ProjectCursor,
    ProjectCursorError,
    bind_active_contract,
    contract_digest,
    master_plan_digest,
    new_project_cursor,
    planning_eligibility,
    record_subphase_completion,
    require_legal_successor,
    revise_remaining_outline,
    validate_cursor_against_master_plan,
)
from lockstep.state import RunStateSnapshot, WorkflowState

# ---------------------------------------------------------------------------
# Construction helpers
# ---------------------------------------------------------------------------


def _pid(value: str) -> PhaseId:
    return PhaseId.model_validate(value)


def _sid(value: str) -> SubphaseId:
    return SubphaseId.model_validate(value)


def _rid(value: str) -> RunId:
    return RunId.model_validate(value)


def _outline(subphase_id: str, depends_on: tuple[str, ...] = ()) -> SubphaseOutline:
    return SubphaseOutline(
        subphase_id=_sid(subphase_id),
        title=f"Outline {subphase_id}",
        objective=f"Objective {subphase_id}.",
        depends_on=tuple(_sid(d) for d in depends_on),
    )


def _phase(phase_id: str, subphases: tuple[SubphaseOutline, ...], deps: tuple[str, ...] = ()):
    return PhasePlan(
        phase_id=_pid(phase_id),
        title=f"Phase {phase_id}",
        objective=f"Phase objective {phase_id}.",
        depends_on=tuple(_pid(d) for d in deps),
        subphases=subphases,
        integration_acceptance_criteria=(
            AcceptanceCriterion(criterion_id="IC-1", description="Integration holds."),
        ),
    )


def _plan(project_id: str = "lockstep") -> MasterPlan:
    return MasterPlan(
        project_id=ProjectId.model_validate(project_id),
        title="Lockstep",
        objective="Build the control plane.",
        phases=(
            _phase(
                "01",
                (_outline("01"), _outline("02", ("01",)), _outline("03", ("02",))),
            ),
            _phase("02", (_outline("01"),), deps=("01",)),
            _phase("03", (_outline("01"),), deps=("02",)),
        ),
    )


def _contract(phase_id: str = "01", subphase_id: str = "01", title: str = "Contract") -> Any:
    return SubphaseContract(
        phase_id=_pid(phase_id),
        subphase_id=_sid(subphase_id),
        title=title,
        objective="Contract objective.",
        acceptance_criteria=(AcceptanceCriterion(criterion_id="AC-1", description="Holds."),),
        tests=(
            TestSpecification(
                path="tests/test_one.py",
                expectation=TestExpectation.RED,
                acceptance_criteria=("AC-1",),
            ),
        ),
        allowed_paths=("src/lockstep/**",),
        verification_commands=("./scripts/check",),
    )


def _snapshot(
    state: WorkflowState, run_id: str = "run-1", project_id: str = "lockstep"
) -> RunStateSnapshot:
    return RunStateSnapshot(
        run_id=_rid(run_id),
        project_id=ProjectId.model_validate(project_id),
        workflow_state=state,
        last_sequence=11,
    )


def _fresh() -> ProjectCursor:
    return new_project_cursor(_plan())


def _bound(run_id: str = "run-1") -> ProjectCursor:
    return bind_active_contract(_fresh(), _contract(), transaction_run_id=_rid(run_id))


def _cursor_data(**overrides: Any) -> dict[str, Any]:
    data: dict[str, Any] = {
        "project_id": "lockstep",
        "master_plan_digest": master_plan_digest(_plan()),
        "revision": 1,
        "current_phase": "01",
        "completed_phases": [],
        "current_subphase": "01",
        "completed_subphases": [],
        "remaining_outline": [_outline("02", ("01",)).model_dump(mode="json")],
        "active_contract": None,
        "phase_gate_status": "subphases_pending",
    }
    data.update(overrides)
    return data


def _completed(phase: str, sub: str, run: str) -> dict[str, Any]:
    return {
        "phase_id": phase,
        "subphase_id": sub,
        "run_id": run,
        "contract_digest": "a" * 64,
    }


# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------


def test_public_api_exports_expected_names() -> None:
    assert set(project_cursor.__all__) == {
        "ActiveContractBinding",
        "CompletedSubphase",
        "PhaseGateStatus",
        "PlanningEligibility",
        "PlanningEligibilityReason",
        "ProjectCursor",
        "ProjectCursorError",
        "bind_active_contract",
        "contract_digest",
        "master_plan_digest",
        "new_project_cursor",
        "planning_eligibility",
        "record_subphase_completion",
        "require_legal_successor",
        "revise_remaining_outline",
        "validate_cursor_against_master_plan",
    }


# ---------------------------------------------------------------------------
# A. Initialization
# ---------------------------------------------------------------------------


def test_new_cursor_initial_state() -> None:
    plan = _plan()
    cursor = new_project_cursor(plan)

    assert cursor.project_id == plan.project_id
    assert cursor.master_plan_digest == master_plan_digest(plan)
    assert cursor.revision == 1
    assert cursor.current_phase == _pid("01")
    assert cursor.completed_phases == ()
    assert cursor.current_subphase == _sid("01")
    assert cursor.completed_subphases == ()
    assert cursor.remaining_outline == (_outline("02", ("01",)), _outline("03", ("02",)))
    assert cursor.active_contract is None
    assert cursor.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING


def test_new_cursor_uses_supplied_current_outline_for_first_phase() -> None:
    plan = _plan()
    revised = plan.phases[0].model_copy(update={"subphases": (_outline("01"), _outline("04"))})

    cursor = new_project_cursor(plan, revised)

    assert cursor.current_subphase == _sid("01")
    assert cursor.remaining_outline == (_outline("04"),)


def test_new_cursor_rejects_outline_for_a_different_phase() -> None:
    plan = _plan()
    with pytest.raises(ProjectCursorError):
        new_project_cursor(plan, plan.phases[1])


def test_new_cursor_rejects_outline_that_changes_frozen_phase_facts() -> None:
    plan = _plan()
    tampered = plan.phases[0].model_copy(update={"title": "Different title"})
    with pytest.raises(ProjectCursorError):
        new_project_cursor(plan, tampered)


def test_cursor_is_frozen_and_strict() -> None:
    cursor = _fresh()
    with pytest.raises(ValidationError):
        cursor.revision = 5  # type: ignore[misc]
    with pytest.raises(ValidationError):
        ProjectCursor.model_validate(_cursor_data(unexpected="field"))


# ---------------------------------------------------------------------------
# B. Serialization round trip
# ---------------------------------------------------------------------------


def test_cursor_json_round_trip_is_semantically_identical() -> None:
    cursor = record_subphase_completion(_bound(), _snapshot(WorkflowState.SUBPHASE_COMPLETE))

    assert ProjectCursor.model_validate_json(cursor.model_dump_json()) == cursor


# ---------------------------------------------------------------------------
# C. Completed Sub-phase advancement
# ---------------------------------------------------------------------------


def test_bind_active_contract_records_digest_and_run() -> None:
    cursor = _bound("run-7")
    contract = _contract()

    assert cursor.revision == 2
    assert cursor.active_contract == ActiveContractBinding(
        phase_id=_pid("01"),
        subphase_id=_sid("01"),
        contract_digest=contract_digest(contract),
        transaction_run_id=_rid("run-7"),
    )


def test_contract_digest_is_deterministic_and_content_sensitive() -> None:
    assert contract_digest(_contract()) == contract_digest(_contract())
    assert contract_digest(_contract()) != contract_digest(_contract(title="Other"))
    assert len(contract_digest(_contract())) == 64


def test_canonical_completion_advances_history_and_current() -> None:
    cursor = record_subphase_completion(_bound(), _snapshot(WorkflowState.SUBPHASE_COMPLETE))

    assert cursor.completed_subphases == (
        CompletedSubphase(
            phase_id=_pid("01"),
            subphase_id=_sid("01"),
            run_id=_rid("run-1"),
            contract_digest=contract_digest(_contract()),
        ),
    )
    assert cursor.current_subphase == _sid("02")
    assert cursor.remaining_outline == (_outline("03", ("02",)),)
    assert cursor.active_contract is None
    assert cursor.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING
    assert cursor.revision == 3


def test_completing_the_last_subphase_makes_the_phase_gate_ready() -> None:
    cursor = _fresh()
    for index, sub in enumerate(("01", "02", "03"), start=1):
        cursor = bind_active_contract(
            cursor, _contract(subphase_id=sub), transaction_run_id=_rid(f"run-{index}")
        )
        cursor = record_subphase_completion(
            cursor, _snapshot(WorkflowState.SUBPHASE_COMPLETE, f"run-{index}")
        )

    assert cursor.current_subphase is None
    assert cursor.remaining_outline == ()
    assert cursor.active_contract is None
    assert cursor.phase_gate_status is PhaseGateStatus.READY
    assert cursor.completed_phases == ()
    assert [entry.subphase_id.root for entry in cursor.completed_subphases] == ["01", "02", "03"]


def test_completed_subphase_cannot_be_bound_again() -> None:
    cursor = record_subphase_completion(_bound(), _snapshot(WorkflowState.SUBPHASE_COMPLETE))

    with pytest.raises(ProjectCursorError):
        bind_active_contract(cursor, _contract(), transaction_run_id=_rid("run-2"))


def test_recording_the_same_completion_twice_is_idempotent() -> None:
    snapshot = _snapshot(WorkflowState.SUBPHASE_COMPLETE)
    once = record_subphase_completion(_bound(), snapshot)

    assert record_subphase_completion(once, snapshot) == once


# ---------------------------------------------------------------------------
# D / E. Planning eligibility
# ---------------------------------------------------------------------------

_IN_FLIGHT_STATES = (
    WorkflowState.TEST_AUTHORING,
    WorkflowState.TEST_BASELINE_VERIFY,
    WorkflowState.TEST_COMMIT,
    WorkflowState.IMPLEMENTING,
    WorkflowState.TEST_REVIEW,
    WorkflowState.VERIFYING,
    WorkflowState.REVIEWING,
    WorkflowState.IMPLEMENTATION_COMMIT,
)


@pytest.mark.parametrize("state", _IN_FLIGHT_STATES)
def test_in_flight_transaction_is_not_planning_eligible(state: WorkflowState) -> None:
    result = planning_eligibility(_bound(), _snapshot(state))

    assert result.eligible is False
    assert result.reason is PlanningEligibilityReason.ACTIVE_CONTRACT_NOT_COMPLETE


def test_active_contract_without_transaction_state_is_not_eligible() -> None:
    result = planning_eligibility(_bound(), None)

    assert result.eligible is False
    assert result.reason is PlanningEligibilityReason.ACTIVE_CONTRACT_NOT_COMPLETE


def test_halted_transaction_is_not_planning_eligible() -> None:
    result = planning_eligibility(_bound(), _snapshot(WorkflowState.HALTED))

    assert result.eligible is False
    assert result.reason is PlanningEligibilityReason.TRANSACTION_HALTED


def test_reviewer_approve_state_alone_does_not_complete_or_enable_planning() -> None:
    # A reviewed-and-approved transaction that has not reached the canonical
    # SUBPHASE_COMPLETE boundary is still in flight.
    cursor = _bound()

    assert planning_eligibility(cursor, _snapshot(WorkflowState.REVIEWING)).eligible is False
    with pytest.raises(ProjectCursorError):
        record_subphase_completion(cursor, _snapshot(WorkflowState.IMPLEMENTATION_COMMIT))
    assert cursor.completed_subphases == ()


def test_complete_transaction_not_yet_recorded_is_not_eligible() -> None:
    result = planning_eligibility(_bound(), _snapshot(WorkflowState.SUBPHASE_COMPLETE))

    assert result.eligible is False
    assert result.reason is PlanningEligibilityReason.COMPLETION_NOT_RECORDED


def test_recorded_canonical_completion_makes_next_planning_eligible() -> None:
    snapshot = _snapshot(WorkflowState.SUBPHASE_COMPLETE)
    cursor = record_subphase_completion(_bound(), snapshot)

    for supplied in (snapshot, None):
        result = planning_eligibility(cursor, supplied)
        assert result.eligible is True
        assert result.reason is PlanningEligibilityReason.ELIGIBLE


def test_fresh_cursor_is_eligible_to_plan_the_first_contract() -> None:
    result = planning_eligibility(_fresh(), None)

    assert result.eligible is True
    assert result.reason is PlanningEligibilityReason.ELIGIBLE


def test_phase_gate_pending_is_not_eligible_for_next_subphase_planning() -> None:
    cursor = _fresh()
    for index, sub in enumerate(("01", "02", "03"), start=1):
        cursor = bind_active_contract(
            cursor, _contract(subphase_id=sub), transaction_run_id=_rid(f"run-{index}")
        )
        cursor = record_subphase_completion(
            cursor, _snapshot(WorkflowState.SUBPHASE_COMPLETE, f"run-{index}")
        )

    result = planning_eligibility(cursor, None)

    assert result.eligible is False
    assert result.reason is PlanningEligibilityReason.PHASE_GATE_PENDING


# ---------------------------------------------------------------------------
# F. Provisional outline is not executable
# ---------------------------------------------------------------------------


def test_remaining_outline_items_are_outlines_not_contracts() -> None:
    cursor = _fresh()

    assert cursor.remaining_outline
    assert all(isinstance(item, SubphaseOutline) for item in cursor.remaining_outline)
    assert cursor.active_contract is None


def test_future_outline_item_cannot_be_bound_as_an_active_contract() -> None:
    cursor = _fresh()

    with pytest.raises(ProjectCursorError):
        bind_active_contract(cursor, _contract(subphase_id="02"), transaction_run_id=_rid("run-1"))
    assert cursor.active_contract is None


# ---------------------------------------------------------------------------
# G. One active Contract
# ---------------------------------------------------------------------------


def test_second_active_contract_for_another_subphase_is_rejected() -> None:
    with pytest.raises(ProjectCursorError):
        bind_active_contract(_bound(), _contract(subphase_id="02"), transaction_run_id=_rid("r2"))


def test_different_contract_for_the_active_subphase_is_rejected() -> None:
    with pytest.raises(ProjectCursorError):
        bind_active_contract(
            _bound(), _contract(title="Rewritten"), transaction_run_id=_rid("run-1")
        )


def test_different_transaction_run_for_the_active_contract_is_rejected() -> None:
    with pytest.raises(ProjectCursorError):
        bind_active_contract(_bound("run-1"), _contract(), transaction_run_id=_rid("run-2"))


def test_rebinding_the_identical_contract_is_idempotent() -> None:
    cursor = _bound()

    assert bind_active_contract(cursor, _contract(), transaction_run_id=_rid("run-1")) == cursor


# ---------------------------------------------------------------------------
# H. Completed history is immutable
# ---------------------------------------------------------------------------


def _successor(previous: ProjectCursor, **changes: Any) -> ProjectCursor:
    # model_copy skips validation so the successor rule itself is under test.
    update = {"revision": previous.revision + 1, **changes}
    return previous.model_copy(update=update)


def _history_cursor() -> ProjectCursor:
    return ProjectCursor.model_validate(
        _cursor_data(
            current_phase="03",
            completed_phases=["01", "02"],
            current_subphase="01",
            completed_subphases=[_completed("01", "01", "run-1"), _completed("02", "01", "run-2")],
            remaining_outline=[],
        )
    )


def test_legal_successor_accepts_ordinary_progress() -> None:
    previous = _bound()
    candidate = record_subphase_completion(previous, _snapshot(WorkflowState.SUBPHASE_COMPLETE))

    require_legal_successor(previous, candidate)


def test_successor_cannot_remove_a_completed_subphase() -> None:
    previous = record_subphase_completion(_bound(), _snapshot(WorkflowState.SUBPHASE_COMPLETE))

    with pytest.raises(ProjectCursorError):
        require_legal_successor(previous, _successor(previous, completed_subphases=()))


def test_successor_cannot_mutate_a_completed_entry() -> None:
    previous = record_subphase_completion(_bound(), _snapshot(WorkflowState.SUBPHASE_COMPLETE))
    forged = previous.completed_subphases[0].model_copy(update={"run_id": _rid("run-forged")})

    with pytest.raises(ProjectCursorError):
        require_legal_successor(previous, _successor(previous, completed_subphases=(forged,)))


def test_successor_cannot_reorder_completed_phases() -> None:
    previous = _history_cursor()

    with pytest.raises(ProjectCursorError):
        require_legal_successor(
            previous, _successor(previous, completed_phases=(_pid("02"), _pid("01")))
        )


def test_successor_cannot_reopen_a_completed_phase() -> None:
    previous = _history_cursor()

    with pytest.raises(ProjectCursorError):
        require_legal_successor(
            previous,
            _successor(previous, current_phase=_pid("02"), completed_phases=(_pid("01"),)),
        )


def test_successor_cannot_complete_a_phase_in_this_subphase() -> None:
    previous = _fresh()

    with pytest.raises(ProjectCursorError):
        require_legal_successor(
            previous,
            _successor(previous, current_phase=_pid("02"), completed_phases=(_pid("01"),)),
        )


def test_successor_cannot_regress_the_phase_gate_status() -> None:
    ready = _fresh().model_copy(
        update={
            "phase_gate_status": PhaseGateStatus.READY,
            "current_subphase": None,
            "remaining_outline": (),
        }
    )

    with pytest.raises(ProjectCursorError):
        require_legal_successor(
            ready, _successor(ready, phase_gate_status=PhaseGateStatus.SUBPHASES_PENDING)
        )


@pytest.mark.parametrize(
    "changes",
    [
        {"revision": 1},
        {"revision": 9},
        {"project_id": ProjectId.model_validate("other")},
        {"master_plan_digest": "b" * 64},
    ],
)
def test_successor_must_keep_identity_and_advance_revision_by_one(changes: dict[str, Any]) -> None:
    previous = _fresh()
    candidate = previous.model_copy(update={"revision": 2, **changes})

    with pytest.raises(ProjectCursorError):
        require_legal_successor(previous, candidate)


# ---------------------------------------------------------------------------
# Model invariants (unrepresentable invalid states)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "overrides",
    [
        {"completed_phases": ["01"]},  # current phase also completed
        {"completed_phases": ["02", "02"], "current_phase": "03"},  # duplicate phase
        {"completed_subphases": [_completed("01", "01", "run-1")]},  # current also completed
        {
            "completed_subphases": [
                _completed("01", "03", "run-1"),
                _completed("01", "04", "run-1"),
            ]
        },  # duplicate run id
        {"completed_subphases": [_completed("09", "01", "run-1")]},  # unknown phase
        {"remaining_outline": [_outline("01").model_dump(mode="json")]},  # repeats current
        {
            "remaining_outline": [
                _outline("02", ("01",)).model_dump(mode="json"),
                _outline("02", ("01",)).model_dump(mode="json"),
            ]
        },  # duplicate outline id
        {"remaining_outline": [_outline("02", ("09",)).model_dump(mode="json")]},  # dangling dep
        {"remaining_outline": [_outline("02", ("03",)).model_dump(mode="json")]},  # forward dep
        {"phase_gate_status": "ready"},  # READY while a Sub-phase is still current
        {"current_subphase": None},  # no current Sub-phase but gate pending
        {"revision": 0},
        {"schema_version": 2},
        {"master_plan_digest": "not-a-digest"},
        {
            "active_contract": {
                "phase_id": "01",
                "subphase_id": "02",
                "contract_digest": "a" * 64,
                "transaction_run_id": "run-1",
            }
        },  # active contract is for a different Sub-phase
    ],
)
def test_invalid_cursor_states_are_rejected(overrides: dict[str, Any]) -> None:
    with pytest.raises(ValidationError):
        ProjectCursor.model_validate(_cursor_data(**overrides))


def test_same_subphase_id_in_different_phases_is_distinct_history() -> None:
    cursor = ProjectCursor.model_validate(
        _cursor_data(
            current_phase="02",
            completed_phases=["01"],
            current_subphase="01",
            completed_subphases=[_completed("01", "01", "run-1")],
            remaining_outline=[],
        )
    )

    assert cursor.current_subphase == _sid("01")
    assert cursor.completed_subphases[0].phase_id == _pid("01")


# ---------------------------------------------------------------------------
# Remaining-outline revision
# ---------------------------------------------------------------------------


def test_revising_remaining_outline_leaves_history_and_current_untouched() -> None:
    cursor = record_subphase_completion(_bound(), _snapshot(WorkflowState.SUBPHASE_COMPLETE))

    revised = revise_remaining_outline(cursor, (_outline("04", ("02",)), _outline("05", ("04",))))

    assert revised.completed_subphases == cursor.completed_subphases
    assert revised.current_subphase == cursor.current_subphase
    assert revised.active_contract is None
    assert revised.remaining_outline == (_outline("04", ("02",)), _outline("05", ("04",)))
    assert revised.revision == cursor.revision + 1
    require_legal_successor(cursor, revised)


def test_revising_remaining_outline_is_allowed_while_a_contract_is_active() -> None:
    cursor = _bound()

    revised = revise_remaining_outline(cursor, (_outline("09", ("01",)),))

    assert revised.active_contract == cursor.active_contract
    assert revised.remaining_outline == (_outline("09", ("01",)),)


def test_revision_cannot_reintroduce_a_completed_or_current_subphase() -> None:
    cursor = record_subphase_completion(_bound(), _snapshot(WorkflowState.SUBPHASE_COMPLETE))

    with pytest.raises(ProjectCursorError):
        revise_remaining_outline(cursor, (_outline("01"),))  # completed
    with pytest.raises(ProjectCursorError):
        revise_remaining_outline(cursor, (_outline("02", ("01",)),))  # current


def test_revision_with_dangling_dependency_is_rejected() -> None:
    with pytest.raises(ProjectCursorError):
        revise_remaining_outline(_fresh(), (_outline("04", ("09",)),))


def test_revision_rejected_when_the_phase_gate_is_ready() -> None:
    ready = _fresh().model_copy(
        update={
            "phase_gate_status": PhaseGateStatus.READY,
            "current_subphase": None,
            "remaining_outline": (),
        }
    )

    with pytest.raises(ProjectCursorError):
        revise_remaining_outline(ready, (_outline("04"),))


# ---------------------------------------------------------------------------
# I. Identity mismatch
# ---------------------------------------------------------------------------


def test_contract_for_a_different_phase_is_rejected() -> None:
    with pytest.raises(ProjectCursorError):
        bind_active_contract(
            _fresh(), _contract(phase_id="02", subphase_id="01"), transaction_run_id=_rid("r")
        )


def test_completion_from_a_different_run_is_rejected() -> None:
    with pytest.raises(ProjectCursorError):
        record_subphase_completion(
            _bound("run-1"), _snapshot(WorkflowState.SUBPHASE_COMPLETE, "run-other")
        )


def test_completion_from_a_different_project_is_rejected() -> None:
    with pytest.raises(ProjectCursorError):
        record_subphase_completion(
            _bound(), _snapshot(WorkflowState.SUBPHASE_COMPLETE, project_id="other")
        )


def test_completion_without_an_active_contract_is_rejected() -> None:
    with pytest.raises(ProjectCursorError):
        record_subphase_completion(_fresh(), _snapshot(WorkflowState.SUBPHASE_COMPLETE))


def test_eligibility_rejects_a_foreign_transaction_snapshot() -> None:
    with pytest.raises(ProjectCursorError):
        planning_eligibility(_bound("run-1"), _snapshot(WorkflowState.REVIEWING, "run-other"))
    with pytest.raises(ProjectCursorError):
        planning_eligibility(_bound(), _snapshot(WorkflowState.REVIEWING, project_id="other"))
    with pytest.raises(ProjectCursorError):
        planning_eligibility(_fresh(), _snapshot(WorkflowState.SUBPHASE_COMPLETE, "run-unknown"))


# ---------------------------------------------------------------------------
# Binding to the frozen Master Plan
# ---------------------------------------------------------------------------


def test_cursor_validates_against_its_own_master_plan() -> None:
    validate_cursor_against_master_plan(_fresh(), _plan())
    validate_cursor_against_master_plan(_history_cursor(), _plan())


def test_cursor_rejects_a_different_master_plan() -> None:
    other = _plan().model_copy(update={"title": "Another plan"})
    with pytest.raises(ProjectCursorError):
        validate_cursor_against_master_plan(_fresh(), other)

    other_project = _plan("other-project")
    with pytest.raises(ProjectCursorError):
        validate_cursor_against_master_plan(_fresh(), other_project)


def test_cursor_rejects_skipping_an_incomplete_prior_phase() -> None:
    skipped = ProjectCursor.model_validate(
        _cursor_data(current_phase="02", current_subphase="01", remaining_outline=[])
    )

    with pytest.raises(ProjectCursorError):
        validate_cursor_against_master_plan(skipped, _plan())
