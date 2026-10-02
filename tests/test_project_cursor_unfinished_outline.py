"""Phase 11.3: replacing the entire unfinished suffix of the current Phase outline.

11.1 could revise only the *future* outline entries: the current, still
unfrozen Sub-phase could not be re-selected. JIT replanning needs to replace
the whole unfinished suffix -- the selected-but-unfrozen Sub-phase and every
later provisional entry -- while completed history and any frozen Contract
stay untouched.

Baseline classification: every test in this module is RED at entry
(``revise_unfinished_outline`` and ``revise_cursor_unfinished_outline`` do not
exist). The new operations are deliberately not added to the frozen 11.1
``__all__`` tuples.
"""

from __future__ import annotations

from pathlib import Path
from typing import Any

import pytest

import lockstep.project_cursor_store as project_cursor_store
from lockstep.domain import (
    AcceptanceCriterion,
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    RunId,
    SubphaseId,
    SubphaseOutline,
)
from lockstep.planning_store import freeze_master_plan
from lockstep.project_cursor import (
    ActiveContractBinding,
    CompletedSubphase,
    PhaseGateStatus,
    ProjectCursor,
    ProjectCursorError,
    require_legal_successor,
    revise_remaining_outline,
    revise_unfinished_outline,
)
from lockstep.project_cursor_store import (
    ProjectCursorStoreError,
    initialize_project_cursor,
    load_project_cursor,
    revise_cursor_unfinished_outline,
)


def _sid(value: str) -> SubphaseId:
    return SubphaseId.model_validate(value)


def _outline(subphase_id: str, depends_on: tuple[str, ...] = ()) -> SubphaseOutline:
    return SubphaseOutline(
        subphase_id=_sid(subphase_id),
        title=f"Outline {subphase_id}",
        objective=f"Objective {subphase_id}.",
        depends_on=tuple(_sid(d) for d in depends_on),
    )


def _after_first_completion(*, bound: bool = False) -> ProjectCursor:
    """Sub-phase 01 complete; 02 is the current unfrozen unit; 03 is provisional."""
    return ProjectCursor(
        project_id=ProjectId.model_validate("lockstep"),
        master_plan_digest="a" * 64,
        revision=4,
        current_phase=PhaseId.model_validate("01"),
        current_subphase=_sid("02"),
        completed_subphases=(
            CompletedSubphase(
                phase_id=PhaseId.model_validate("01"),
                subphase_id=_sid("01"),
                run_id=RunId.model_validate("run-01-01"),
                contract_digest="b" * 64,
            ),
        ),
        remaining_outline=(_outline("03", ("02",)),),
        active_contract=(
            ActiveContractBinding(
                phase_id=PhaseId.model_validate("01"),
                subphase_id=_sid("02"),
                contract_digest="c" * 64,
                transaction_run_id=RunId.model_validate("run-01-02"),
            )
            if bound
            else None
        ),
    )


def _ids(outlines: tuple[SubphaseOutline, ...]) -> list[str]:
    return [o.subphase_id.root for o in outlines]


# ---------------------------------------------------------------------------
# Pure transition
# ---------------------------------------------------------------------------


def test_the_current_unfrozen_subphase_and_every_later_entry_can_be_replaced() -> None:
    cursor = _after_first_completion()

    revised = revise_unfinished_outline(cursor, (_outline("05", ("01",)), _outline("06", ("05",))))

    assert revised.current_subphase == _sid("05")
    assert _ids(revised.remaining_outline) == ["06"]
    assert revised.completed_subphases == cursor.completed_subphases
    assert revised.completed_phases == cursor.completed_phases == ()
    assert revised.active_contract is None
    assert revised.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING
    assert revised.revision == cursor.revision + 1
    require_legal_successor(cursor, revised)


def test_an_unchanged_suffix_is_a_valid_replacement() -> None:
    cursor = _after_first_completion()

    revised = revise_unfinished_outline(cursor, (_outline("02", ("01",)), _outline("03", ("02",))))

    assert revised.current_subphase == cursor.current_subphase
    assert revised.remaining_outline == cursor.remaining_outline


def test_a_split_replaces_one_unit_with_several_and_keeps_later_work() -> None:
    cursor = _after_first_completion()

    revised = revise_unfinished_outline(
        cursor,
        (_outline("05", ("01",)), _outline("06", ("05",)), _outline("03", ("06",))),
    )

    assert revised.current_subphase == _sid("05")
    assert _ids(revised.remaining_outline) == ["06", "03"]


def test_an_empty_suffix_makes_the_phase_gate_ready_without_completing_the_phase() -> None:
    cursor = _after_first_completion()

    revised = revise_unfinished_outline(cursor, ())

    assert revised.current_subphase is None
    assert revised.remaining_outline == ()
    assert revised.phase_gate_status is PhaseGateStatus.READY
    assert revised.completed_phases == ()
    assert revised.completed_subphases == cursor.completed_subphases
    require_legal_successor(cursor, revised)


def test_a_frozen_active_contract_cannot_be_revised_away() -> None:
    cursor = _after_first_completion(bound=True)

    with pytest.raises(ProjectCursorError):
        revise_unfinished_outline(cursor, (_outline("05", ("01",)),))
    with pytest.raises(ProjectCursorError):
        revise_unfinished_outline(cursor, ())


def test_a_ready_phase_gate_has_no_outline_to_revise() -> None:
    ready = revise_unfinished_outline(_after_first_completion(), ())

    with pytest.raises(ProjectCursorError):
        revise_unfinished_outline(ready, (_outline("05", ("01",)),))


@pytest.mark.parametrize(
    "unfinished",
    [
        (_outline("01"),),  # reintroduces a completed unit
        (_outline("05", ("01",)), _outline("01", ("05",))),  # reintroduces it later
        (_outline("05", ("01",)), _outline("05", ("01",))),  # duplicate ids
    ],
    ids=["completed-first", "completed-later", "duplicate"],
)
def test_identity_collisions_with_history_or_within_the_suffix_are_rejected(
    unfinished: tuple[SubphaseOutline, ...],
) -> None:
    with pytest.raises(ProjectCursorError):
        revise_unfinished_outline(_after_first_completion(), unfinished)


@pytest.mark.parametrize(
    "unfinished",
    [
        (_outline("05", ("09",)),),  # first unit: dangling dependency
        (_outline("05", ("06",)), _outline("06", ("01",))),  # first unit: forward dependency
        (_outline("05", ("01",)), _outline("06", ("99",))),  # later unit: dangling dependency
        (_outline("05", ("01",)), _outline("06", ("07",)), _outline("07", ("05",))),  # forward
    ],
    ids=["first-dangling", "first-forward", "later-dangling", "later-forward"],
)
def test_dependencies_must_resolve_to_completed_or_earlier_unfinished_units(
    unfinished: tuple[SubphaseOutline, ...],
) -> None:
    with pytest.raises(ProjectCursorError):
        revise_unfinished_outline(_after_first_completion(), unfinished)


def test_the_first_unfinished_unit_may_depend_on_completed_history() -> None:
    revised = revise_unfinished_outline(_after_first_completion(), (_outline("05", ("01",)),))

    assert revised.current_subphase == _sid("05")


def test_the_existing_remaining_outline_revision_is_unchanged() -> None:
    """11.1 behavior is preserved: it still cannot re-select the current unit."""
    cursor = _after_first_completion()
    revised = revise_remaining_outline(cursor, (_outline("04", ("02",)),))

    assert revised.current_subphase == cursor.current_subphase


# ---------------------------------------------------------------------------
# Durable store operation
# ---------------------------------------------------------------------------


def _store(tmp_path: Path) -> tuple[Path, Path]:
    project_root = tmp_path / "project"
    runtime_dir = tmp_path / "runtime"
    runtime_dir.mkdir()
    phase = PhasePlan(
        phase_id=PhaseId.model_validate("01"),
        title="Phase",
        objective="Objective.",
        depends_on=(),
        subphases=(_outline("01"), _outline("02", ("01",)), _outline("03", ("02",))),
        integration_acceptance_criteria=(
            AcceptanceCriterion(criterion_id="IC-1", description="Integration holds."),
        ),
    )
    freeze_master_plan(
        project_root,
        MasterPlan(
            project_id=ProjectId.model_validate("lockstep"),
            title="Lockstep",
            objective="Build the control plane.",
            phases=(phase,),
        ),
    )
    initialize_project_cursor(project_root, runtime_dir)
    return project_root, runtime_dir


def test_the_store_replaces_the_current_and_remaining_outline_durably(tmp_path: Path) -> None:
    project_root, runtime_dir = _store(tmp_path)
    before = load_project_cursor(project_root, runtime_dir)
    assert before is not None

    revised = revise_cursor_unfinished_outline(
        project_root, runtime_dir, (_outline("05"), _outline("06", ("05",)))
    )

    assert revised.current_subphase == _sid("05")
    assert _ids(revised.remaining_outline) == ["06"]
    assert revised.revision == before.revision + 1
    assert load_project_cursor(project_root, runtime_dir) == revised


def test_the_store_persists_an_empty_suffix_as_a_ready_gate(tmp_path: Path) -> None:
    project_root, runtime_dir = _store(tmp_path)

    revised = revise_cursor_unfinished_outline(project_root, runtime_dir, ())

    reloaded = load_project_cursor(project_root, runtime_dir)
    assert reloaded == revised
    assert reloaded is not None
    assert reloaded.phase_gate_status is PhaseGateStatus.READY
    assert reloaded.current_subphase is None
    assert reloaded.completed_phases == ()


def test_a_failed_publication_leaves_the_previous_cursor_byte_for_byte(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project_root, runtime_dir = _store(tmp_path)
    path = runtime_dir / "project" / "cursor.json"
    before = path.read_bytes()

    def fail(source: Path, target: Path) -> None:
        raise OSError("simulated publication failure")

    monkeypatch.setattr(project_cursor_store, "_replace_atomically", fail)
    with pytest.raises(ProjectCursorStoreError):
        revise_cursor_unfinished_outline(project_root, runtime_dir, (_outline("05"),))

    assert path.read_bytes() == before
    assert [p.name for p in path.parent.iterdir()] == ["cursor.json"]


def test_the_store_refuses_an_invalid_suffix_without_writing(tmp_path: Path) -> None:
    project_root, runtime_dir = _store(tmp_path)
    path = runtime_dir / "project" / "cursor.json"
    before = path.read_bytes()

    bad: Any = (_outline("05", ("99",)),)
    with pytest.raises(ProjectCursorError):
        revise_cursor_unfinished_outline(project_root, runtime_dir, bad)

    assert path.read_bytes() == before


def test_the_store_requires_an_initialized_cursor(tmp_path: Path) -> None:
    project_root = tmp_path / "project"
    runtime_dir = tmp_path / "runtime"
    runtime_dir.mkdir()

    with pytest.raises(ProjectCursorStoreError):
        revise_cursor_unfinished_outline(project_root, runtime_dir, ())
