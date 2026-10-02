"""Phase 11.1: durable persistence, reconstruction, and crash semantics of the cursor."""

import ast
import inspect
import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest

import lockstep.project_cursor_store as project_cursor_store
from lockstep.domain import (
    AcceptanceCriterion,
    ExecutionEventKind,
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    ReviewVerdict,
    RunId,
    SubphaseContract,
    SubphaseId,
    SubphaseOutline,
    TestExpectation,
    TestSpecification,
)
from lockstep.persistence.events import (
    ExecutionEvent,
    RunCreatedEvent,
    StateTransitionedEvent,
)
from lockstep.persistence.journal import append_event, read_events
from lockstep.persistence.replay import replay_events
from lockstep.persistence.state_store import load_verified_state, write_state
from lockstep.planning_store import (
    freeze_master_plan,
    freeze_subphase_contract,
    publish_phase_plan,
)
from lockstep.project_cursor import (
    PhaseGateStatus,
    PlanningEligibilityReason,
    ProjectCursor,
    ProjectCursorError,
    contract_digest,
    master_plan_digest,
    planning_eligibility,
)
from lockstep.project_cursor_store import (
    ProjectCursorStoreError,
    bind_frozen_contract,
    initialize_project_cursor,
    load_project_cursor,
    record_completed_subphase,
    revise_cursor_outline,
)
from lockstep.state import WorkflowState

# ---------------------------------------------------------------------------
# Construction helpers
# ---------------------------------------------------------------------------


def _pid(value: str) -> PhaseId:
    return PhaseId.model_validate(value)


def _sid(value: str) -> SubphaseId:
    return SubphaseId.model_validate(value)


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


def _plan(project_id: str = "lockstep", title: str = "Lockstep") -> MasterPlan:
    return MasterPlan(
        project_id=ProjectId.model_validate(project_id),
        title=title,
        objective="Build the control plane.",
        phases=(
            _phase("01", (_outline("01"), _outline("02", ("01",)), _outline("03", ("02",)))),
            _phase("02", (_outline("01"),), deps=("01",)),
        ),
    )


def _contract(subphase_id: str = "01", title: str = "Contract") -> SubphaseContract:
    return SubphaseContract(
        phase_id=_pid("01"),
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


def _roots(tmp_path: Path) -> tuple[Path, Path]:
    project_root = tmp_path / "project"
    project_root.mkdir()
    runtime_dir = tmp_path / "runtime"
    runtime_dir.mkdir()
    return project_root, runtime_dir


def _cursor_path(runtime_dir: Path) -> Path:
    return runtime_dir / "project" / "cursor.json"


def _frozen_project(tmp_path: Path) -> tuple[Path, Path]:
    project_root, runtime_dir = _roots(tmp_path)
    freeze_master_plan(project_root, _plan())
    return project_root, runtime_dir


def _with_frozen_contract(tmp_path: Path, subphase_id: str = "01") -> tuple[Path, Path]:
    project_root, runtime_dir = _frozen_project(tmp_path)
    publish_phase_plan(project_root, runtime_dir, _plan().phases[0])
    freeze_subphase_contract(project_root, runtime_dir, _contract(subphase_id))
    return project_root, runtime_dir


_PATH = (
    WorkflowState.PHASE_PLANNING,
    WorkflowState.SUBPHASE_PLANNING,
    WorkflowState.TEST_AUTHORING,
    WorkflowState.TEST_BASELINE_VERIFY,
    WorkflowState.TEST_COMMIT,
    WorkflowState.IMPLEMENTING,
    WorkflowState.VERIFYING,
    WorkflowState.REVIEWING,
    WorkflowState.IMPLEMENTATION_COMMIT,
    WorkflowState.SUBPHASE_COMPLETE,
)

_WHEN = datetime(2026, 1, 1, tzinfo=UTC)


def _write_transaction(
    runtime_dir: Path,
    *,
    upto: WorkflowState,
    run_id: str = "run-1",
    project_id: str = "lockstep",
    foreign_subphase: str | None = None,
    approve: bool = False,
) -> tuple[Path, Path]:
    """Write a real, replayable single-Sub-phase journal reaching *upto*."""
    journal = runtime_dir / "events.jsonl"
    state = runtime_dir / "state.json"
    rid = RunId.model_validate(run_id)
    append_event(
        journal,
        RunCreatedEvent(
            run_id=rid,
            sequence=1,
            occurred_at=_WHEN,
            project_id=ProjectId.model_validate(project_id),
        ),
    )
    source = WorkflowState.READY
    sequence = 2
    for target in _PATH:
        append_event(
            journal,
            StateTransitionedEvent(
                run_id=rid,
                sequence=sequence,
                occurred_at=_WHEN,
                source=source,
                target=target,
            ),
        )
        sequence += 1
        source = target
        if target is upto:
            break
    if approve:
        append_event(
            journal,
            ExecutionEvent(
                run_id=rid,
                sequence=sequence,
                occurred_at=_WHEN,
                kind=ExecutionEventKind.REVIEW_DECIDED,
                phase_id=_pid("01"),
                subphase_id=_sid("01"),
                verdict=ReviewVerdict.APPROVE,
            ),
        )
        sequence += 1
    if foreign_subphase is not None:
        append_event(
            journal,
            ExecutionEvent(
                run_id=rid,
                sequence=sequence,
                occurred_at=_WHEN,
                kind=ExecutionEventKind.TESTS_FROZEN,
                phase_id=_pid("01"),
                subphase_id=_sid(foreign_subphase),
            ),
        )
    write_state(state, replay_events(read_events(journal)))
    return journal, state


def _fail_replace(monkeypatch: pytest.MonkeyPatch) -> None:
    def fail(source: Path, target: Path) -> None:
        raise OSError("simulated crash before publication")

    monkeypatch.setattr(project_cursor_store, "_replace_atomically", fail)


def _restore_replace(monkeypatch: pytest.MonkeyPatch) -> None:
    monkeypatch.undo()


# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------


def test_public_api_exports_expected_names() -> None:
    assert set(project_cursor_store.__all__) == {
        "ProjectCursorStoreError",
        "bind_frozen_contract",
        "initialize_project_cursor",
        "load_project_cursor",
        "record_completed_subphase",
        "revise_cursor_outline",
    }


# ---------------------------------------------------------------------------
# A / B. Initialization and durable reload
# ---------------------------------------------------------------------------


def test_load_returns_none_before_initialization(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)

    assert load_project_cursor(project_root, runtime_dir) is None


def test_initialize_requires_a_frozen_master_plan(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)

    with pytest.raises(ProjectCursorStoreError):
        initialize_project_cursor(project_root, runtime_dir)
    assert not _cursor_path(runtime_dir).exists()


def test_initialize_persists_and_reloads_semantically_identical_cursor(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)

    created = initialize_project_cursor(project_root, runtime_dir)
    del created  # discard the in-memory object; reconstruct from disk only
    reloaded = load_project_cursor(project_root, runtime_dir)

    assert reloaded is not None
    assert reloaded.current_phase == _pid("01")
    assert reloaded.completed_phases == ()
    assert reloaded.current_subphase == _sid("01")
    assert reloaded.completed_subphases == ()
    assert reloaded.remaining_outline == (_outline("02", ("01",)), _outline("03", ("02",)))
    assert reloaded.active_contract is None
    assert reloaded.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING
    assert reloaded.master_plan_digest == master_plan_digest(_plan())
    assert _cursor_path(runtime_dir).is_file()


def test_initialize_adopts_the_published_provisional_outline(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    revised = _plan().phases[0].model_copy(update={"subphases": (_outline("01"), _outline("05"))})
    publish_phase_plan(project_root, runtime_dir, revised)

    cursor = initialize_project_cursor(project_root, runtime_dir)

    assert cursor.remaining_outline == (_outline("05"),)


def test_initialize_ignores_a_published_outline_for_another_phase(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    publish_phase_plan(project_root, runtime_dir, _plan().phases[1])

    cursor = initialize_project_cursor(project_root, runtime_dir)

    assert cursor.current_phase == _pid("01")
    assert cursor.remaining_outline == (_outline("02", ("01",)), _outline("03", ("02",)))


def test_initialize_twice_is_idempotent_and_never_resets_progress(tmp_path: Path) -> None:
    project_root, runtime_dir = _with_frozen_contract(tmp_path)
    first = initialize_project_cursor(project_root, runtime_dir)
    assert initialize_project_cursor(project_root, runtime_dir) == first

    bind_frozen_contract(project_root, runtime_dir, transaction_run_id=RunId.model_validate("r1"))
    before = _cursor_path(runtime_dir).read_bytes()

    with pytest.raises(ProjectCursorStoreError):
        initialize_project_cursor(project_root, runtime_dir)
    assert _cursor_path(runtime_dir).read_bytes() == before


def test_persisted_cursor_file_is_canonical_json(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    cursor = initialize_project_cursor(project_root, runtime_dir)

    raw = _cursor_path(runtime_dir).read_bytes()

    assert raw.endswith(b"\n")
    assert ProjectCursor.model_validate_json(raw) == cursor
    assert json.loads(raw)["project_id"] == "lockstep"
    assert not [p for p in _cursor_path(runtime_dir).parent.iterdir() if p.name.endswith(".tmp")]


# ---------------------------------------------------------------------------
# Corruption and fail-closed loading
# ---------------------------------------------------------------------------


def test_malformed_cursor_file_fails_closed(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    initialize_project_cursor(project_root, runtime_dir)
    _cursor_path(runtime_dir).write_text("{not json", encoding="utf-8")

    with pytest.raises(ProjectCursorStoreError):
        load_project_cursor(project_root, runtime_dir)


def test_schema_invalid_cursor_file_fails_closed(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    initialize_project_cursor(project_root, runtime_dir)
    data = json.loads(_cursor_path(runtime_dir).read_text(encoding="utf-8"))
    data["unexpected"] = True
    _cursor_path(runtime_dir).write_text(json.dumps(data), encoding="utf-8")

    with pytest.raises(ProjectCursorStoreError):
        load_project_cursor(project_root, runtime_dir)


def test_cursor_for_another_project_is_rejected(tmp_path: Path) -> None:
    project_a = tmp_path / "a"
    runtime_a = tmp_path / "ra"
    project_b = tmp_path / "b"
    runtime_b = tmp_path / "rb"
    for path in (project_a, runtime_a, project_b, runtime_b):
        path.mkdir()
    freeze_master_plan(project_a, _plan("project-a"))
    freeze_master_plan(project_b, _plan("project-b"))
    initialize_project_cursor(project_a, runtime_a)
    (runtime_b / "project").mkdir()
    _cursor_path(runtime_b).write_bytes(_cursor_path(runtime_a).read_bytes())

    with pytest.raises(ProjectCursorError):
        load_project_cursor(project_b, runtime_b)


def test_cursor_for_a_different_master_plan_revision_is_rejected(tmp_path: Path) -> None:
    project_a = tmp_path / "a"
    runtime_a = tmp_path / "ra"
    project_b = tmp_path / "b"
    runtime_b = tmp_path / "rb"
    for path in (project_a, runtime_a, project_b, runtime_b):
        path.mkdir()
    freeze_master_plan(project_a, _plan(title="Version A"))
    freeze_master_plan(project_b, _plan(title="Version B"))
    initialize_project_cursor(project_a, runtime_a)
    (runtime_b / "project").mkdir()
    _cursor_path(runtime_b).write_bytes(_cursor_path(runtime_a).read_bytes())

    with pytest.raises(ProjectCursorError):
        load_project_cursor(project_b, runtime_b)


def test_cursor_that_skips_an_incomplete_phase_is_rejected_on_load(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    initialize_project_cursor(project_root, runtime_dir)
    data = json.loads(_cursor_path(runtime_dir).read_text(encoding="utf-8"))
    data["current_phase"] = "02"
    data["remaining_outline"] = []
    _cursor_path(runtime_dir).write_text(json.dumps(data), encoding="utf-8")

    with pytest.raises(ProjectCursorError):
        load_project_cursor(project_root, runtime_dir)


def test_runtime_directory_inside_the_project_is_rejected(tmp_path: Path) -> None:
    project_root, _runtime_dir = _frozen_project(tmp_path)
    inside = project_root / "runtime"
    inside.mkdir()

    with pytest.raises(ProjectCursorStoreError):
        initialize_project_cursor(project_root, inside)


def test_symlinked_cursor_location_is_rejected(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    try:
        (runtime_dir / "project").symlink_to(elsewhere, target_is_directory=True)
    except (OSError, NotImplementedError) as exc:
        pytest.skip(f"symlink creation unsupported on this platform: {exc}")

    with pytest.raises(ProjectCursorStoreError):
        initialize_project_cursor(project_root, runtime_dir)
    assert not any(elsewhere.iterdir())


# ---------------------------------------------------------------------------
# Active Contract: a reference to the authoritative frozen artifact
# ---------------------------------------------------------------------------


def test_bind_requires_a_frozen_active_contract(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    initialize_project_cursor(project_root, runtime_dir)
    before = _cursor_path(runtime_dir).read_bytes()

    with pytest.raises(ProjectCursorStoreError):
        bind_frozen_contract(project_root, runtime_dir, transaction_run_id=RunId("r1"))
    assert _cursor_path(runtime_dir).read_bytes() == before


def test_bind_requires_an_initialized_cursor(tmp_path: Path) -> None:
    project_root, runtime_dir = _with_frozen_contract(tmp_path)

    with pytest.raises(ProjectCursorStoreError):
        bind_frozen_contract(project_root, runtime_dir, transaction_run_id=RunId("r1"))


def test_bind_references_the_frozen_contract_by_digest_not_by_copy(tmp_path: Path) -> None:
    project_root, runtime_dir = _with_frozen_contract(tmp_path)
    initialize_project_cursor(project_root, runtime_dir)

    bound = bind_frozen_contract(
        project_root, runtime_dir, transaction_run_id=RunId.model_validate("run-1")
    )

    assert bound.active_contract is not None
    assert bound.active_contract.contract_digest == contract_digest(_contract())
    assert bound.active_contract.transaction_run_id == RunId.model_validate("run-1")
    assert load_project_cursor(project_root, runtime_dir) == bound
    persisted = _cursor_path(runtime_dir).read_text(encoding="utf-8")
    assert "Contract objective." not in persisted
    assert "verification_commands" not in persisted


def test_frozen_contract_for_a_future_subphase_cannot_be_bound(tmp_path: Path) -> None:
    project_root, runtime_dir = _with_frozen_contract(tmp_path, subphase_id="02")
    initialize_project_cursor(project_root, runtime_dir)
    before = _cursor_path(runtime_dir).read_bytes()

    with pytest.raises(ProjectCursorError):
        bind_frozen_contract(project_root, runtime_dir, transaction_run_id=RunId("r1"))
    assert _cursor_path(runtime_dir).read_bytes() == before


def test_bind_is_idempotent_for_the_same_run(tmp_path: Path) -> None:
    project_root, runtime_dir = _with_frozen_contract(tmp_path)
    initialize_project_cursor(project_root, runtime_dir)
    first = bind_frozen_contract(project_root, runtime_dir, transaction_run_id=RunId("r1"))
    before = _cursor_path(runtime_dir).read_bytes()

    assert bind_frozen_contract(project_root, runtime_dir, transaction_run_id=RunId("r1")) == first
    assert _cursor_path(runtime_dir).read_bytes() == before
    with pytest.raises(ProjectCursorError):
        bind_frozen_contract(project_root, runtime_dir, transaction_run_id=RunId("r2"))


def test_drift_of_the_frozen_contract_beneath_the_cursor_fails_closed(tmp_path: Path) -> None:
    project_root, runtime_dir = _with_frozen_contract(tmp_path)
    initialize_project_cursor(project_root, runtime_dir)
    bind_frozen_contract(project_root, runtime_dir, transaction_run_id=RunId("r1"))
    active = runtime_dir / "contracts" / "active.json"
    drifted = _contract(title="Silently edited")
    active.write_text(json.dumps(drifted.model_dump(mode="json")) + "\n", encoding="utf-8")

    with pytest.raises(ProjectCursorError):
        load_project_cursor(project_root, runtime_dir)


# ---------------------------------------------------------------------------
# C / D / E. Canonical completion from the authoritative journal
# ---------------------------------------------------------------------------


def _bound_project(tmp_path: Path, run_id: str = "run-1") -> tuple[Path, Path]:
    project_root, runtime_dir = _with_frozen_contract(tmp_path)
    initialize_project_cursor(project_root, runtime_dir)
    bind_frozen_contract(project_root, runtime_dir, transaction_run_id=RunId.model_validate(run_id))
    return project_root, runtime_dir


def test_canonical_completion_is_recorded_from_the_journal(tmp_path: Path) -> None:
    project_root, runtime_dir = _bound_project(tmp_path)
    journal, state = _write_transaction(runtime_dir, upto=WorkflowState.SUBPHASE_COMPLETE)

    cursor = record_completed_subphase(
        project_root, runtime_dir, journal_path=journal, state_path=state
    )

    assert [entry.subphase_id.root for entry in cursor.completed_subphases] == ["01"]
    assert cursor.completed_subphases[0].run_id == RunId.model_validate("run-1")
    assert cursor.current_subphase == _sid("02")
    assert cursor.active_contract is None
    assert load_project_cursor(project_root, runtime_dir) == cursor


def test_reviewer_approve_without_canonical_completion_changes_nothing(tmp_path: Path) -> None:
    project_root, runtime_dir = _bound_project(tmp_path)
    journal, state = _write_transaction(
        runtime_dir, upto=WorkflowState.IMPLEMENTATION_COMMIT, approve=True
    )
    before = _cursor_path(runtime_dir).read_bytes()

    with pytest.raises(ProjectCursorError):
        record_completed_subphase(project_root, runtime_dir, journal_path=journal, state_path=state)

    assert _cursor_path(runtime_dir).read_bytes() == before
    cursor = load_project_cursor(project_root, runtime_dir)
    assert cursor is not None
    verified = load_verified_state(state, journal)
    assert planning_eligibility(cursor, verified).eligible is False


def test_planning_becomes_eligible_only_after_the_completion_is_recorded(tmp_path: Path) -> None:
    project_root, runtime_dir = _bound_project(tmp_path)
    journal, state = _write_transaction(runtime_dir, upto=WorkflowState.SUBPHASE_COMPLETE)
    verified = load_verified_state(state, journal)
    before = load_project_cursor(project_root, runtime_dir)
    assert before is not None

    gap = planning_eligibility(before, verified)
    assert gap.eligible is False
    assert gap.reason is PlanningEligibilityReason.COMPLETION_NOT_RECORDED

    after = record_completed_subphase(
        project_root, runtime_dir, journal_path=journal, state_path=state
    )
    assert planning_eligibility(after, verified).eligible is True


def test_recording_completion_twice_is_idempotent(tmp_path: Path) -> None:
    project_root, runtime_dir = _bound_project(tmp_path)
    journal, state = _write_transaction(runtime_dir, upto=WorkflowState.SUBPHASE_COMPLETE)
    first = record_completed_subphase(
        project_root, runtime_dir, journal_path=journal, state_path=state
    )
    before = _cursor_path(runtime_dir).read_bytes()

    second = record_completed_subphase(
        project_root, runtime_dir, journal_path=journal, state_path=state
    )

    assert second == first
    assert _cursor_path(runtime_dir).read_bytes() == before


def test_completion_from_another_run_journal_is_rejected(tmp_path: Path) -> None:
    project_root, runtime_dir = _bound_project(tmp_path, run_id="run-1")
    journal, state = _write_transaction(
        runtime_dir, upto=WorkflowState.SUBPHASE_COMPLETE, run_id="run-other"
    )
    before = _cursor_path(runtime_dir).read_bytes()

    with pytest.raises(ProjectCursorError):
        record_completed_subphase(project_root, runtime_dir, journal_path=journal, state_path=state)
    assert _cursor_path(runtime_dir).read_bytes() == before


def test_completion_from_another_project_journal_is_rejected(tmp_path: Path) -> None:
    project_root, runtime_dir = _bound_project(tmp_path)
    journal, state = _write_transaction(
        runtime_dir, upto=WorkflowState.SUBPHASE_COMPLETE, project_id="someone-else"
    )

    with pytest.raises(ProjectCursorError):
        record_completed_subphase(project_root, runtime_dir, journal_path=journal, state_path=state)


def test_completion_from_a_journal_naming_another_subphase_is_rejected(tmp_path: Path) -> None:
    project_root, runtime_dir = _bound_project(tmp_path)
    journal, state = _write_transaction(
        runtime_dir, upto=WorkflowState.SUBPHASE_COMPLETE, foreign_subphase="02"
    )

    with pytest.raises(ProjectCursorError):
        record_completed_subphase(project_root, runtime_dir, journal_path=journal, state_path=state)


def test_completion_without_a_journal_is_rejected(tmp_path: Path) -> None:
    project_root, runtime_dir = _bound_project(tmp_path)

    with pytest.raises(ProjectCursorStoreError):
        record_completed_subphase(
            project_root,
            runtime_dir,
            journal_path=runtime_dir / "events.jsonl",
            state_path=runtime_dir / "state.json",
        )


def test_recording_completion_never_touches_the_transaction_journal(tmp_path: Path) -> None:
    project_root, runtime_dir = _bound_project(tmp_path)
    journal, state = _write_transaction(runtime_dir, upto=WorkflowState.SUBPHASE_COMPLETE)
    journal_bytes = journal.read_bytes()
    state_bytes = state.read_bytes()

    record_completed_subphase(project_root, runtime_dir, journal_path=journal, state_path=state)

    assert journal.read_bytes() == journal_bytes
    assert state.read_bytes() == state_bytes


# ---------------------------------------------------------------------------
# Outline revision
# ---------------------------------------------------------------------------


def test_revised_outline_survives_reload(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    initialize_project_cursor(project_root, runtime_dir)

    revised = revise_cursor_outline(project_root, runtime_dir, (_outline("07", ("01",)),))

    assert revised.remaining_outline == (_outline("07", ("01",)),)
    assert load_project_cursor(project_root, runtime_dir) == revised


def test_invalid_outline_revision_leaves_the_file_unchanged(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    initialize_project_cursor(project_root, runtime_dir)
    before = _cursor_path(runtime_dir).read_bytes()

    with pytest.raises(ProjectCursorError):
        revise_cursor_outline(project_root, runtime_dir, (_outline("01"),))
    assert _cursor_path(runtime_dir).read_bytes() == before


# ---------------------------------------------------------------------------
# J. Crash / replay
# ---------------------------------------------------------------------------


def test_crash_during_initialize_leaves_no_cursor_and_is_retryable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    _fail_replace(monkeypatch)

    with pytest.raises(ProjectCursorStoreError):
        initialize_project_cursor(project_root, runtime_dir)
    assert not _cursor_path(runtime_dir).exists()
    assert load_project_cursor(project_root, runtime_dir) is None

    _restore_replace(monkeypatch)
    assert initialize_project_cursor(project_root, runtime_dir).revision == 1


def test_crash_during_bind_keeps_the_previous_cursor_and_is_retryable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project_root, runtime_dir = _with_frozen_contract(tmp_path)
    initialize_project_cursor(project_root, runtime_dir)
    before = _cursor_path(runtime_dir).read_bytes()
    _fail_replace(monkeypatch)

    with pytest.raises(ProjectCursorStoreError):
        bind_frozen_contract(project_root, runtime_dir, transaction_run_id=RunId("r1"))
    assert _cursor_path(runtime_dir).read_bytes() == before
    assert not [p for p in _cursor_path(runtime_dir).parent.iterdir() if p.name.endswith(".tmp")]

    _restore_replace(monkeypatch)
    bound = bind_frozen_contract(project_root, runtime_dir, transaction_run_id=RunId("r1"))
    assert bound.active_contract is not None


def test_crash_during_completion_keeps_previous_cursor_and_recovers_without_duplication(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project_root, runtime_dir = _bound_project(tmp_path)
    journal, state = _write_transaction(runtime_dir, upto=WorkflowState.SUBPHASE_COMPLETE)
    before = _cursor_path(runtime_dir).read_bytes()
    _fail_replace(monkeypatch)

    with pytest.raises(ProjectCursorStoreError):
        record_completed_subphase(project_root, runtime_dir, journal_path=journal, state_path=state)
    assert _cursor_path(runtime_dir).read_bytes() == before

    # Restart: nothing but persisted files. The journal says complete, the
    # cursor has not recorded it yet -- liveness is lost until recorded, and
    # no second execution is authorized.
    _restore_replace(monkeypatch)
    reloaded = load_project_cursor(project_root, runtime_dir)
    assert reloaded is not None
    gap = planning_eligibility(reloaded, load_verified_state(state, journal))
    assert gap.reason is PlanningEligibilityReason.COMPLETION_NOT_RECORDED

    recovered = record_completed_subphase(
        project_root, runtime_dir, journal_path=journal, state_path=state
    )
    assert len(recovered.completed_subphases) == 1
    assert (
        record_completed_subphase(project_root, runtime_dir, journal_path=journal, state_path=state)
        == recovered
    )


def test_crash_during_outline_revision_keeps_previous_cursor(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    initialize_project_cursor(project_root, runtime_dir)
    before = _cursor_path(runtime_dir).read_bytes()
    _fail_replace(monkeypatch)

    with pytest.raises(ProjectCursorStoreError):
        revise_cursor_outline(project_root, runtime_dir, (_outline("07", ("01",)),))
    assert _cursor_path(runtime_dir).read_bytes() == before


def test_each_semantic_transition_reconstructs_from_disk_alone(tmp_path: Path) -> None:
    project_root, runtime_dir = _with_frozen_contract(tmp_path)

    initialized = initialize_project_cursor(project_root, runtime_dir)
    assert load_project_cursor(project_root, runtime_dir) == initialized

    revised = revise_cursor_outline(project_root, runtime_dir, (_outline("02", ("01",)),))
    assert load_project_cursor(project_root, runtime_dir) == revised

    bound = bind_frozen_contract(project_root, runtime_dir, transaction_run_id=RunId("run-1"))
    assert load_project_cursor(project_root, runtime_dir) == bound

    journal, state = _write_transaction(runtime_dir, upto=WorkflowState.SUBPHASE_COMPLETE)
    done = record_completed_subphase(
        project_root, runtime_dir, journal_path=journal, state_path=state
    )
    assert load_project_cursor(project_root, runtime_dir) == done
    assert [c.revision for c in (initialized, revised, bound, done)] == [1, 2, 3, 4]


# ---------------------------------------------------------------------------
# AC-11.1-19: no orchestration pulled forward
# ---------------------------------------------------------------------------

_FORBIDDEN_IMPORT_PREFIXES = (
    "lockstep.agents",
    "lockstep.agent_turn",
    "lockstep.reviewer_turn",
    "lockstep.runtime",
    "lockstep.supervisor",
    "lockstep.planning_workflow",
    "lockstep.planning_transport",
    "lockstep.process",
    "lockstep.git",
    "lockstep.metrics",
    "lockstep.reporting",
    "subprocess",
)


def _imported_modules(module: Any) -> set[str]:
    tree = ast.parse(inspect.getsource(module))
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module is not None:
            names.add(node.module)
    return names


@pytest.mark.parametrize(
    "module_name", ["lockstep.project_cursor", "lockstep.project_cursor_store"]
)
def test_cursor_modules_do_not_import_orchestration_or_provider_layers(module_name: str) -> None:
    import importlib

    imported = _imported_modules(importlib.import_module(module_name))

    offenders = {
        name
        for name in imported
        if any(name == p or name.startswith(p + ".") for p in _FORBIDDEN_IMPORT_PREFIXES)
    }
    assert not offenders
