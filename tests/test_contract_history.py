"""Phase 11.2: Contract lifecycle -- retire a completed active Contract into history.

The planning store allows exactly one active Contract and (until 11.2) offered
no way to free that slot. ``retire_active_subphase_contract`` moves the active
Contract into immutable, content-addressed history so the next Sub-phase's
Contract can be frozen without ever overwriting accepted evidence.
"""

import json
from pathlib import Path

import pytest

import lockstep.contract_history as contract_history
from lockstep.contract_history import (
    load_archived_subphase_contract,
    retire_active_subphase_contract,
)
from lockstep.domain import (
    AcceptanceCriterion,
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    SubphaseContract,
    SubphaseId,
    SubphaseOutline,
    TestExpectation,
    TestSpecification,
)
from lockstep.planning_store import (
    PlanningStoreError,
    freeze_master_plan,
    freeze_subphase_contract,
    load_active_subphase_contract,
    publish_phase_plan,
)
from lockstep.project_cursor import contract_digest

_PHASE = PhaseId.model_validate("01")


def _sid(value: str) -> SubphaseId:
    return SubphaseId.model_validate(value)


def _phase_plan() -> PhasePlan:
    return PhasePlan(
        phase_id=_PHASE,
        title="Phase one",
        objective="Phase objective.",
        depends_on=(),
        subphases=(
            SubphaseOutline(subphase_id=_sid("01"), title="One", objective="First.", depends_on=()),
            SubphaseOutline(
                subphase_id=_sid("02"), title="Two", objective="Second.", depends_on=(_sid("01"),)
            ),
        ),
        integration_acceptance_criteria=(),
    )


def _contract(subphase_id: str) -> SubphaseContract:
    return SubphaseContract(
        phase_id=_PHASE,
        subphase_id=_sid(subphase_id),
        title=f"Contract {subphase_id}",
        objective=f"Objective {subphase_id}.",
        acceptance_criteria=(AcceptanceCriterion(criterion_id="AC-1", description="Holds."),),
        tests=(
            TestSpecification(
                path=f"tests/test_{subphase_id}.py",
                expectation=TestExpectation.RED,
                acceptance_criteria=("AC-1",),
            ),
        ),
        allowed_paths=(f"feature_{subphase_id}.py",),
        verification_commands=("pytest",),
    )


def _store(tmp_path: Path) -> tuple[Path, Path]:
    project = tmp_path / "project"
    runtime = tmp_path / "runtime"
    project.mkdir()
    runtime.mkdir()
    plan = MasterPlan(
        project_id=ProjectId.model_validate("lockstep"),
        title="Lockstep",
        objective="Build.",
        phases=(_phase_plan(),),
    )
    freeze_master_plan(project, plan)
    publish_phase_plan(project, runtime, _phase_plan())
    return project, runtime


def _history_files(runtime: Path) -> list[Path]:
    history = runtime / "contracts" / "history"
    return sorted(history.iterdir()) if history.exists() else []


def test_retiring_frees_the_active_slot_and_keeps_the_contract_recoverable(tmp_path: Path) -> None:
    project, runtime = _store(tmp_path)
    first = _contract("01")
    freeze_subphase_contract(project, runtime, first)
    digest = contract_digest(first)

    archived = retire_active_subphase_contract(project, runtime, contract_digest=digest)

    assert load_active_subphase_contract(project, runtime) is None
    assert not (runtime / "contracts" / "active.json").exists()
    assert archived.is_file()
    assert digest in archived.name
    assert (
        load_archived_subphase_contract(
            project, runtime, phase_id=_PHASE, subphase_id=_sid("01"), contract_digest=digest
        )
        == first
    )


def test_next_contract_can_be_frozen_after_retirement_and_history_survives(tmp_path: Path) -> None:
    project, runtime = _store(tmp_path)
    first, second = _contract("01"), _contract("02")
    freeze_subphase_contract(project, runtime, first)
    retire_active_subphase_contract(project, runtime, contract_digest=contract_digest(first))

    freeze_subphase_contract(project, runtime, second)

    assert load_active_subphase_contract(project, runtime) == second
    assert (
        load_archived_subphase_contract(
            project,
            runtime,
            phase_id=_PHASE,
            subphase_id=_sid("01"),
            contract_digest=contract_digest(first),
        )
        == first
    )


def test_archived_bytes_are_the_frozen_bytes_and_are_not_rewritten(tmp_path: Path) -> None:
    project, runtime = _store(tmp_path)
    first = _contract("01")
    freeze_subphase_contract(project, runtime, first)
    frozen_bytes = (runtime / "contracts" / "active.json").read_bytes()

    archived = retire_active_subphase_contract(
        project, runtime, contract_digest=contract_digest(first)
    )

    assert archived.read_bytes() == frozen_bytes


def test_an_unretired_active_contract_is_still_never_overwritten(tmp_path: Path) -> None:
    project, runtime = _store(tmp_path)
    freeze_subphase_contract(project, runtime, _contract("01"))

    with pytest.raises(PlanningStoreError, match="already active"):
        freeze_subphase_contract(project, runtime, _contract("02"))


def test_retirement_is_idempotent_when_history_already_holds_the_contract(tmp_path: Path) -> None:
    project, runtime = _store(tmp_path)
    first = _contract("01")
    freeze_subphase_contract(project, runtime, first)
    digest = contract_digest(first)

    one = retire_active_subphase_contract(project, runtime, contract_digest=digest)
    again = retire_active_subphase_contract(project, runtime, contract_digest=digest)

    assert one == again
    assert len(_history_files(runtime)) == 1


def test_a_crash_after_archiving_but_before_clearing_active_is_completed_on_retry(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project, runtime = _store(tmp_path)
    first = _contract("01")
    freeze_subphase_contract(project, runtime, first)
    digest = contract_digest(first)

    real_unlink = Path.unlink

    def crash_on_active(self: Path, *args: object, **kwargs: object) -> None:
        if self.name == "active.json":
            raise OSError("simulated crash")
        real_unlink(self, *args, **kwargs)  # type: ignore[arg-type]

    monkeypatch.setattr(Path, "unlink", crash_on_active)
    with pytest.raises((OSError, PlanningStoreError)):
        retire_active_subphase_contract(project, runtime, contract_digest=digest)
    monkeypatch.undo()

    # Archived, but the active slot is still occupied: the next freeze is still refused.
    assert len(_history_files(runtime)) == 1
    assert (runtime / "contracts" / "active.json").exists()
    with pytest.raises(PlanningStoreError, match="already active"):
        freeze_subphase_contract(project, runtime, _contract("02"))

    retire_active_subphase_contract(project, runtime, contract_digest=digest)
    assert not (runtime / "contracts" / "active.json").exists()
    assert len(_history_files(runtime)) == 1
    freeze_subphase_contract(project, runtime, _contract("02"))


def test_a_wrong_digest_is_rejected_and_nothing_moves(tmp_path: Path) -> None:
    project, runtime = _store(tmp_path)
    freeze_subphase_contract(project, runtime, _contract("01"))

    with pytest.raises(PlanningStoreError, match="digest"):
        retire_active_subphase_contract(project, runtime, contract_digest="0" * 64)

    assert (runtime / "contracts" / "active.json").exists()
    assert _history_files(runtime) == []


def test_retiring_with_nothing_active_and_nothing_archived_is_rejected(tmp_path: Path) -> None:
    project, runtime = _store(tmp_path)
    with pytest.raises(PlanningStoreError):
        retire_active_subphase_contract(project, runtime, contract_digest="a" * 64)


def test_a_conflicting_history_entry_is_never_overwritten(tmp_path: Path) -> None:
    project, runtime = _store(tmp_path)
    first = _contract("01")
    freeze_subphase_contract(project, runtime, first)
    digest = contract_digest(first)
    retire_active_subphase_contract(project, runtime, contract_digest=digest)
    [entry] = _history_files(runtime)
    tampered = json.loads(entry.read_text())
    tampered["title"] = "Tampered"
    entry.write_text(json.dumps(tampered))

    with pytest.raises(PlanningStoreError):
        load_archived_subphase_contract(
            project, runtime, phase_id=_PHASE, subphase_id=_sid("01"), contract_digest=digest
        )


def test_loading_an_unknown_archive_returns_none(tmp_path: Path) -> None:
    project, runtime = _store(tmp_path)
    assert (
        load_archived_subphase_contract(
            project, runtime, phase_id=_PHASE, subphase_id=_sid("01"), contract_digest="b" * 64
        )
        is None
    )


def test_a_symlinked_history_directory_is_rejected(tmp_path: Path) -> None:
    project, runtime = _store(tmp_path)
    first = _contract("01")
    freeze_subphase_contract(project, runtime, first)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    (runtime / "contracts" / "history").symlink_to(elsewhere, target_is_directory=True)

    with pytest.raises(PlanningStoreError, match="symlink"):
        retire_active_subphase_contract(project, runtime, contract_digest=contract_digest(first))
    assert list(elsewhere.iterdir()) == []


def test_phase_plan_may_be_republished_only_after_retirement(tmp_path: Path) -> None:
    project, runtime = _store(tmp_path)
    first = _contract("01")
    freeze_subphase_contract(project, runtime, first)
    with pytest.raises(PlanningStoreError):
        publish_phase_plan(project, runtime, _phase_plan())

    retire_active_subphase_contract(project, runtime, contract_digest=contract_digest(first))

    publish_phase_plan(project, runtime, _phase_plan())


def test_archive_publication_uses_the_private_atomic_replace_seam() -> None:
    import ast
    import inspect

    source = inspect.getsource(contract_history.retire_active_subphase_contract)
    names = {
        node.func.id
        for node in ast.walk(ast.parse(source))
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
    }
    assert "_atomic_write_bytes" in names


def test_public_api_exports_expected_names() -> None:
    assert set(contract_history.__all__) == {
        "load_archived_subphase_contract",
        "retire_active_subphase_contract",
    }
