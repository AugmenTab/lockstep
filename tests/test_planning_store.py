import ast
import inspect
import os
from pathlib import Path

import pytest

import lockstep.planning_store as planning_store
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
from lockstep.planning import PlanningValidationError
from lockstep.planning_store import (
    PlanningStoreError,
    freeze_master_plan,
    freeze_subphase_contract,
    load_active_subphase_contract,
    load_frozen_master_plan,
    load_phase_plan,
    publish_phase_plan,
)

# ---------------------------------------------------------------------------
# Construction helpers
# ---------------------------------------------------------------------------


def _project_id(value: str = "lockstep") -> ProjectId:
    return ProjectId.model_validate(value)


def _phase_id(value: str) -> PhaseId:
    return PhaseId.model_validate(value)


def _subphase_id(value: str) -> SubphaseId:
    return SubphaseId.model_validate(value)


def _criterion(
    criterion_id: str, description: str = "Observable behavior holds."
) -> AcceptanceCriterion:
    return AcceptanceCriterion(criterion_id=criterion_id, description=description)


def _test_spec(
    path: str,
    acceptance_criteria: tuple[str, ...],
    expectation: TestExpectation = TestExpectation.RED,
) -> TestSpecification:
    return TestSpecification(
        path=path,
        expectation=expectation,
        acceptance_criteria=acceptance_criteria,
    )


def _outline(
    subphase_id: str,
    depends_on: tuple[str, ...] = (),
    title: str = "Outline title",
    objective: str = "Outline objective.",
) -> SubphaseOutline:
    return SubphaseOutline(
        subphase_id=_subphase_id(subphase_id),
        title=title,
        objective=objective,
        depends_on=tuple(_subphase_id(d) for d in depends_on),
    )


def _phase(
    phase_id: str,
    subphases: tuple[SubphaseOutline, ...],
    depends_on: tuple[str, ...] = (),
    integration_acceptance_criteria: tuple[AcceptanceCriterion, ...] = (),
    title: str = "Phase title",
    objective: str = "Phase objective.",
) -> PhasePlan:
    return PhasePlan(
        phase_id=_phase_id(phase_id),
        title=title,
        objective=objective,
        depends_on=tuple(_phase_id(d) for d in depends_on),
        subphases=subphases,
        integration_acceptance_criteria=integration_acceptance_criteria,
    )


def _plan(
    phases: tuple[PhasePlan, ...],
    project_id: str = "lockstep",
    title: str = "Lockstep",
    objective: str = "Build the local orchestration control plane.",
) -> MasterPlan:
    return MasterPlan(
        project_id=_project_id(project_id),
        title=title,
        objective=objective,
        phases=phases,
    )


def _valid_plan() -> MasterPlan:
    phase_01 = _phase(
        "01",
        subphases=(_outline("01"), _outline("02", depends_on=("01",))),
        integration_acceptance_criteria=(_criterion("IC-1"),),
    )
    phase_02 = _phase("02", depends_on=("01",), subphases=(_outline("01"),))
    return _plan((phase_01, phase_02))


def _contract(
    *,
    phase_id: str = "01",
    subphase_id: str = "02",
    title: str = "Contract title",
    objective: str = "Contract objective.",
    acceptance_criteria: tuple[AcceptanceCriterion, ...] = (_criterion("AC-1"),),
    tests: tuple[TestSpecification, ...] = (_test_spec("tests/test_one.py", ("AC-1",)),),
) -> SubphaseContract:
    return SubphaseContract(
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        title=title,
        objective=objective,
        acceptance_criteria=acceptance_criteria,
        tests=tests,
        allowed_paths=("src/lockstep/**",),
        verification_commands=("./scripts/check",),
    )


def _revise_subphases(frozen_phase: PhasePlan, subphases: tuple[SubphaseOutline, ...]) -> PhasePlan:
    return frozen_phase.model_copy(update={"subphases": subphases})


def _two_subphase_revision(frozen_plan: MasterPlan) -> PhasePlan:
    return _revise_subphases(
        frozen_plan.phases[0],
        (_outline("01"), _outline("02", depends_on=("01",))),
    )


def _prepare_active_phase(project_root: Path, runtime_dir: Path) -> MasterPlan:
    frozen_plan = _valid_plan()
    freeze_master_plan(project_root, frozen_plan)
    publish_phase_plan(project_root, runtime_dir, _two_subphase_revision(frozen_plan))
    return frozen_plan


def _roots(tmp_path: Path) -> tuple[Path, Path]:
    project_root = tmp_path / "project"
    project_root.mkdir()
    runtime_dir = tmp_path / "runtime"
    runtime_dir.mkdir()
    return project_root, runtime_dir


def _symlink_or_skip(link: Path, target: Path) -> None:
    try:
        link.symlink_to(target)
    except (OSError, NotImplementedError) as exc:
        pytest.skip(f"symlink creation unsupported on this platform: {exc}")


def _master_plan_json_path(project_root: Path) -> Path:
    return project_root / ".lockstep" / "project" / "master-plan.json"


def _master_plan_md_path(project_root: Path) -> Path:
    return project_root / ".lockstep" / "project" / "master-plan.md"


def _phase_plan_json_path(runtime_dir: Path) -> Path:
    return runtime_dir / "planning" / "phase-plan.json"


def _active_contract_json_path(runtime_dir: Path) -> Path:
    return runtime_dir / "contracts" / "active.json"


# ---------------------------------------------------------------------------
# Public API surface
# ---------------------------------------------------------------------------


def test_public_api_exports_expected_names() -> None:
    assert set(planning_store.__all__) == {
        "PlanningStoreError",
        "freeze_master_plan",
        "load_frozen_master_plan",
        "publish_phase_plan",
        "load_phase_plan",
        "freeze_subphase_contract",
        "load_active_subphase_contract",
    }


# ---------------------------------------------------------------------------
# Master Plan freeze (Section 44)
# ---------------------------------------------------------------------------


def test_freeze_master_plan_creates_exact_canonical_pair(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    plan = _valid_plan()

    freeze_master_plan(project_root, plan)

    json_path = _master_plan_json_path(project_root)
    md_path = _master_plan_md_path(project_root)
    assert json_path.is_file()
    assert md_path.is_file()

    loaded = MasterPlan.model_validate_json(json_path.read_text(encoding="utf-8"))
    assert loaded == plan

    md_text = md_path.read_text(encoding="utf-8")
    assert md_text
    assert md_text.endswith("\n")
    assert not md_text.endswith("\n\n")

    created_files = {p for p in (project_root / ".lockstep").rglob("*") if p.is_file()}
    assert created_files == {json_path, md_path}


# ---------------------------------------------------------------------------
# Validation before side effects (Section 45)
# ---------------------------------------------------------------------------


def test_freeze_invalid_master_plan_has_no_side_effects(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    phase_a = _phase("01", subphases=(_outline("01"),))
    phase_b = _phase("01", subphases=(_outline("01"),))
    invalid_plan = _plan((phase_a, phase_b))

    with pytest.raises(PlanningValidationError):
        freeze_master_plan(project_root, invalid_plan)

    assert not (project_root / ".lockstep").exists()


# ---------------------------------------------------------------------------
# Master Plan idempotency (Section 46)
# ---------------------------------------------------------------------------


def test_freeze_master_plan_is_idempotent_and_rejects_different_candidate(
    tmp_path: Path,
) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    plan = _valid_plan()
    freeze_master_plan(project_root, plan)

    json_path = _master_plan_json_path(project_root)
    md_path = _master_plan_md_path(project_root)
    json_bytes = json_path.read_bytes()
    md_bytes = md_path.read_bytes()
    json_mtime = json_path.stat().st_mtime_ns
    md_mtime = md_path.stat().st_mtime_ns

    freeze_master_plan(project_root, plan)

    assert json_path.read_bytes() == json_bytes
    assert md_path.read_bytes() == md_bytes
    assert json_path.stat().st_mtime_ns == json_mtime
    assert md_path.stat().st_mtime_ns == md_mtime

    different_plan = _plan((_phase("01", subphases=(_outline("01"),)),))

    with pytest.raises(PlanningStoreError):
        freeze_master_plan(project_root, different_plan)

    assert json_path.read_bytes() == json_bytes
    assert md_path.read_bytes() == md_bytes


# ---------------------------------------------------------------------------
# Master Plan pair integrity (Section 47)
# ---------------------------------------------------------------------------


def test_load_frozen_master_plan_json_only_fails(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    freeze_master_plan(project_root, _valid_plan())
    _master_plan_md_path(project_root).unlink()

    with pytest.raises(PlanningStoreError):
        load_frozen_master_plan(project_root)


def test_load_frozen_master_plan_markdown_only_fails(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    freeze_master_plan(project_root, _valid_plan())
    _master_plan_json_path(project_root).unlink()

    with pytest.raises(PlanningStoreError):
        load_frozen_master_plan(project_root)


def test_load_frozen_master_plan_mismatched_markdown_fails(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    freeze_master_plan(project_root, _valid_plan())
    md_path = _master_plan_md_path(project_root)
    md_path.write_text(md_path.read_text(encoding="utf-8") + "tampered\n", encoding="utf-8")

    with pytest.raises(PlanningStoreError):
        load_frozen_master_plan(project_root)


def test_load_frozen_master_plan_malformed_json_fails(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    freeze_master_plan(project_root, _valid_plan())
    _master_plan_json_path(project_root).write_text("{not json", encoding="utf-8")

    with pytest.raises(PlanningStoreError):
        load_frozen_master_plan(project_root)


def test_load_frozen_master_plan_invalid_utf8_markdown_fails(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    freeze_master_plan(project_root, _valid_plan())
    _master_plan_md_path(project_root).write_bytes(b"\xff\xfe not utf-8")

    with pytest.raises(PlanningStoreError):
        load_frozen_master_plan(project_root)


def test_load_frozen_master_plan_invalid_utf8_json_fails(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    freeze_master_plan(project_root, _valid_plan())
    _master_plan_json_path(project_root).write_bytes(b"\xff\xfe not utf-8")

    with pytest.raises(PlanningStoreError):
        load_frozen_master_plan(project_root)


# ---------------------------------------------------------------------------
# Orphan Markdown crash retry (Section 48)
# ---------------------------------------------------------------------------


def test_freeze_master_plan_replaces_orphan_markdown(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    plan = _valid_plan()
    md_path = _master_plan_md_path(project_root)
    md_path.parent.mkdir(parents=True)
    md_path.write_text("stale orphan content\n", encoding="utf-8")

    freeze_master_plan(project_root, plan)

    assert load_frozen_master_plan(project_root) == plan
    assert md_path.read_text(encoding="utf-8") != "stale orphan content\n"


# ---------------------------------------------------------------------------
# Atomic publication failure (Section 49)
# ---------------------------------------------------------------------------


def test_master_plan_json_replace_failure_leaves_orphan_markdown_and_no_json(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    plan = _valid_plan()
    json_path = _master_plan_json_path(project_root)
    real_replace = planning_store.os.replace

    def fail_only_json(source: object, target: object) -> None:
        if Path(str(target)) == json_path:
            raise OSError("simulated json replace failure")
        real_replace(source, target)

    monkeypatch.setattr(planning_store.os, "replace", fail_only_json)

    with pytest.raises(PlanningStoreError):
        freeze_master_plan(project_root, plan)

    assert not json_path.exists()
    assert _master_plan_md_path(project_root).exists()
    assert list(json_path.parent.glob(".master-plan.json.*.tmp")) == []


def test_phase_plan_replace_failure_preserves_previous_plan(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    frozen_plan = _valid_plan()
    freeze_master_plan(project_root, frozen_plan)
    plan_a = _two_subphase_revision(frozen_plan)
    publish_phase_plan(project_root, runtime_dir, plan_a)

    phase_plan_path = _phase_plan_json_path(runtime_dir)
    original_bytes = phase_plan_path.read_bytes()

    def fail_replace(source: object, target: object) -> None:
        raise OSError("simulated replace failure")

    monkeypatch.setattr(planning_store.os, "replace", fail_replace)

    plan_b = _revise_subphases(frozen_plan.phases[0], (_outline("01"),))

    with pytest.raises(PlanningStoreError):
        publish_phase_plan(project_root, runtime_dir, plan_b)

    assert phase_plan_path.read_bytes() == original_bytes
    assert list(phase_plan_path.parent.glob(".phase-plan.json.*.tmp")) == []


def test_active_contract_replace_failure_leaves_no_active_contract(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    _prepare_active_phase(project_root, runtime_dir)

    def fail_replace(source: object, target: object) -> None:
        raise OSError("simulated replace failure")

    monkeypatch.setattr(planning_store.os, "replace", fail_replace)

    with pytest.raises(PlanningStoreError):
        freeze_subphase_contract(project_root, runtime_dir, _contract())

    assert not _active_contract_json_path(runtime_dir).exists()
    assert list((runtime_dir / "contracts").glob(".active.json.*.tmp")) == []


# ---------------------------------------------------------------------------
# Markdown determinism (Section 50)
# ---------------------------------------------------------------------------


def test_master_plan_markdown_and_json_are_deterministic_across_roots(tmp_path: Path) -> None:
    plan = _plan(
        (
            _phase(
                "01",
                subphases=(_outline("01", title="Café Résumé"),),
                integration_acceptance_criteria=(_criterion("IC-1", "Non-ASCII: 日本語 ✓"),),
            ),
        ),
        title="Lockstep Café",
        objective="Ünïcödé objective naïve.",
    )

    root_a = tmp_path / "a"
    root_a.mkdir()
    root_b = tmp_path / "b"
    root_b.mkdir()

    freeze_master_plan(root_a, plan)
    freeze_master_plan(root_b, plan)

    json_a = _master_plan_json_path(root_a).read_bytes()
    json_b = _master_plan_json_path(root_b).read_bytes()
    md_a = _master_plan_md_path(root_a).read_bytes()
    md_b = _master_plan_md_path(root_b).read_bytes()

    assert json_a == json_b
    assert md_a == md_b
    assert json_a.endswith(b"\n")
    assert not json_a.endswith(b"\n\n")
    assert md_a.endswith(b"\n")
    assert not md_a.endswith(b"\n\n")


# ---------------------------------------------------------------------------
# Loader is read-only (Section 51)
# ---------------------------------------------------------------------------


def test_load_frozen_master_plan_does_not_mutate_files(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    plan = _valid_plan()
    freeze_master_plan(project_root, plan)

    json_path = _master_plan_json_path(project_root)
    md_path = _master_plan_md_path(project_root)
    json_bytes = json_path.read_bytes()
    md_bytes = md_path.read_bytes()
    json_mtime = json_path.stat().st_mtime_ns
    md_mtime = md_path.stat().st_mtime_ns

    for _ in range(3):
        assert load_frozen_master_plan(project_root) == plan

    assert json_path.read_bytes() == json_bytes
    assert md_path.read_bytes() == md_bytes
    assert json_path.stat().st_mtime_ns == json_mtime
    assert md_path.stat().st_mtime_ns == md_mtime
    assert list(json_path.parent.glob(".*.tmp")) == []


# ---------------------------------------------------------------------------
# Phase plan publication (Section 52)
# ---------------------------------------------------------------------------


def test_publish_phase_plan_writes_only_runtime_planning_file(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    frozen_plan = _valid_plan()
    freeze_master_plan(project_root, frozen_plan)

    phase_plan = _two_subphase_revision(frozen_plan)
    publish_phase_plan(project_root, runtime_dir, phase_plan)

    phase_plan_path = _phase_plan_json_path(runtime_dir)
    assert phase_plan_path.is_file()

    created = {p for p in runtime_dir.rglob("*") if p.is_file()}
    assert created == {phase_plan_path}
    assert not (runtime_dir / "contracts").exists()

    assert load_phase_plan(project_root, runtime_dir) == phase_plan


# ---------------------------------------------------------------------------
# Phase facts remain frozen (Section 53)
# ---------------------------------------------------------------------------


def test_revised_phase_plan_rejects_any_non_subphase_field_change(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    frozen_plan = _valid_plan()
    freeze_master_plan(project_root, frozen_plan)
    frozen_phase = frozen_plan.phases[0]

    field_names = set(PhasePlan.model_fields)
    assert field_names == {
        "schema_version",
        "phase_id",
        "title",
        "objective",
        "depends_on",
        "subphases",
        "integration_acceptance_criteria",
    }

    mutations: dict[str, object] = {
        "phase_id": _phase_id("02"),
        "title": frozen_phase.title + " mutated",
        "objective": frozen_phase.objective + " mutated",
        "depends_on": (*frozen_phase.depends_on, _phase_id("99")),
        "integration_acceptance_criteria": (
            *frozen_phase.integration_acceptance_criteria,
            _criterion("EXTRA-CRITERION"),
        ),
    }

    # schema_version is excluded: the frozen domain schema currently admits
    # only one legal value, so no legally constructed candidate can differ.
    revisable_fields = field_names - {"subphases", "schema_version"}
    assert set(mutations) == revisable_fields

    for field_name, mutated_value in mutations.items():
        candidate = frozen_phase.model_copy(update={field_name: mutated_value})
        with pytest.raises(PlanningValidationError):
            publish_phase_plan(project_root, runtime_dir, candidate)

    revised = _revise_subphases(
        frozen_phase,
        (_outline("01"), _outline("02", depends_on=("01",)), _outline("03", depends_on=("02",))),
    )
    publish_phase_plan(project_root, runtime_dir, revised)

    assert load_phase_plan(project_root, runtime_dir) == revised


# ---------------------------------------------------------------------------
# Revised Phase semantics (Section 54)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "subphases",
    [
        (_outline("01"), _outline("01")),
        (_outline("01", depends_on=("99",)),),
        (_outline("01", depends_on=("02",)), _outline("02")),
    ],
    ids=["duplicate", "unknown", "future"],
)
def test_revised_phase_plan_propagates_planning_validation_error(
    tmp_path: Path, subphases: tuple[SubphaseOutline, ...]
) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    frozen_plan = _valid_plan()
    freeze_master_plan(project_root, frozen_plan)
    frozen_phase = frozen_plan.phases[0]

    candidate = _revise_subphases(frozen_phase, subphases)

    with pytest.raises(PlanningValidationError):
        publish_phase_plan(project_root, runtime_dir, candidate)

    assert not _phase_plan_json_path(runtime_dir).exists()


# ---------------------------------------------------------------------------
# Provisional replacement (Section 55)
# ---------------------------------------------------------------------------


def test_publish_phase_plan_replaces_previous_valid_plan(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    frozen_plan = _valid_plan()
    freeze_master_plan(project_root, frozen_plan)
    frozen_phase = frozen_plan.phases[0]

    plan_a = _two_subphase_revision(frozen_plan)
    publish_phase_plan(project_root, runtime_dir, plan_a)

    plan_b = _revise_subphases(frozen_phase, (_outline("01"),))
    publish_phase_plan(project_root, runtime_dir, plan_b)

    phase_plan_path = _phase_plan_json_path(runtime_dir)
    assert load_phase_plan(project_root, runtime_dir) == plan_b
    assert list(phase_plan_path.parent.glob(".*.tmp")) == []


# ---------------------------------------------------------------------------
# Active Contract blocks outline revision (Section 56)
# ---------------------------------------------------------------------------


def test_active_contract_blocks_phase_plan_revision(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    frozen_plan = _prepare_active_phase(project_root, runtime_dir)
    frozen_phase = frozen_plan.phases[0]

    contract = _contract(phase_id="01", subphase_id="02")
    freeze_subphase_contract(project_root, runtime_dir, contract)

    phase_plan_bytes = _phase_plan_json_path(runtime_dir).read_bytes()
    contract_bytes = _active_contract_json_path(runtime_dir).read_bytes()

    same_plan = _two_subphase_revision(frozen_plan)
    with pytest.raises(PlanningStoreError):
        publish_phase_plan(project_root, runtime_dir, same_plan)

    different_plan = _revise_subphases(frozen_phase, (_outline("01"),))
    with pytest.raises(PlanningStoreError):
        publish_phase_plan(project_root, runtime_dir, different_plan)

    assert _phase_plan_json_path(runtime_dir).read_bytes() == phase_plan_bytes
    assert _active_contract_json_path(runtime_dir).read_bytes() == contract_bytes


# ---------------------------------------------------------------------------
# Contract requires Phase plan (Section 57)
# ---------------------------------------------------------------------------


def test_freeze_contract_requires_current_phase_plan(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    freeze_master_plan(project_root, _valid_plan())

    with pytest.raises(PlanningStoreError):
        freeze_subphase_contract(project_root, runtime_dir, _contract())

    assert not (runtime_dir / "contracts").exists()


# ---------------------------------------------------------------------------
# Contract validates against revised outline (Section 58)
# ---------------------------------------------------------------------------


def test_contract_freeze_validates_against_revised_outline(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    frozen_plan = _valid_plan()
    freeze_master_plan(project_root, frozen_plan)
    frozen_phase = frozen_plan.phases[0]

    revised = _revise_subphases(
        frozen_phase,
        (_outline("01"), _outline("02", depends_on=("01",)), _outline("03", depends_on=("02",))),
    )
    publish_phase_plan(project_root, runtime_dir, revised)

    contract = _contract(phase_id="01", subphase_id="03")
    freeze_subphase_contract(project_root, runtime_dir, contract)

    assert load_active_subphase_contract(project_root, runtime_dir) == contract


# ---------------------------------------------------------------------------
# Contract semantic error transparency (Section 59)
# ---------------------------------------------------------------------------


def test_freeze_contract_semantic_error_propagates_unchanged(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    _prepare_active_phase(project_root, runtime_dir)

    malformed_contract = _contract(
        acceptance_criteria=(_criterion("AC-1"),),
        tests=(_test_spec("tests/test_one.py", ("AC-1", "AC-99")),),
    )

    with pytest.raises(PlanningValidationError):
        freeze_subphase_contract(project_root, runtime_dir, malformed_contract)

    assert not _active_contract_json_path(runtime_dir).exists()


# ---------------------------------------------------------------------------
# One active Contract (Section 60)
# ---------------------------------------------------------------------------


def test_freeze_subphase_contract_is_idempotent_and_rejects_different_candidate(
    tmp_path: Path,
) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    _prepare_active_phase(project_root, runtime_dir)

    contract_a = _contract()
    freeze_subphase_contract(project_root, runtime_dir, contract_a)

    active_path = _active_contract_json_path(runtime_dir)
    original_bytes = active_path.read_bytes()

    freeze_subphase_contract(project_root, runtime_dir, contract_a)
    assert active_path.read_bytes() == original_bytes

    contract_b = _contract(title="A different title")
    with pytest.raises(PlanningStoreError):
        freeze_subphase_contract(project_root, runtime_dir, contract_b)

    assert active_path.read_bytes() == original_bytes


# ---------------------------------------------------------------------------
# Active Contract read integrity (Section 61)
# ---------------------------------------------------------------------------


def test_load_active_subphase_contract_returns_exact_model(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    _prepare_active_phase(project_root, runtime_dir)
    contract = _contract()
    freeze_subphase_contract(project_root, runtime_dir, contract)

    assert load_active_subphase_contract(project_root, runtime_dir) == contract


def test_load_active_subphase_contract_missing_returns_none(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    freeze_master_plan(project_root, _valid_plan())

    assert load_active_subphase_contract(project_root, runtime_dir) is None


def test_load_active_subphase_contract_fails_closed_on_malformed_json(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    _prepare_active_phase(project_root, runtime_dir)
    freeze_subphase_contract(project_root, runtime_dir, _contract())

    _active_contract_json_path(runtime_dir).write_text("{not json", encoding="utf-8")

    with pytest.raises(PlanningStoreError):
        load_active_subphase_contract(project_root, runtime_dir)


def test_load_active_subphase_contract_fails_when_phase_plan_missing(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    _prepare_active_phase(project_root, runtime_dir)
    freeze_subphase_contract(project_root, runtime_dir, _contract())

    _phase_plan_json_path(runtime_dir).unlink()

    with pytest.raises(PlanningStoreError):
        load_active_subphase_contract(project_root, runtime_dir)


def test_load_active_subphase_contract_fails_when_referenced_subphase_no_longer_exists(
    tmp_path: Path,
) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    frozen_plan = _valid_plan()
    freeze_master_plan(project_root, frozen_plan)
    revised = _two_subphase_revision(frozen_plan)
    publish_phase_plan(project_root, runtime_dir, revised)
    freeze_subphase_contract(project_root, runtime_dir, _contract())

    # Simulate drift beneath the frozen artifacts: directly tamper with the
    # on-disk phase plan so it no longer contains the contracted subphase.
    tampered = _revise_subphases(revised, (_outline("01"),))
    _phase_plan_json_path(runtime_dir).write_text(
        tampered.model_dump_json() + "\n", encoding="utf-8"
    )

    with pytest.raises((PlanningStoreError, PlanningValidationError)):
        load_active_subphase_contract(project_root, runtime_dir)


def test_load_active_subphase_contract_fails_when_contract_phase_mismatches_current_plan(
    tmp_path: Path,
) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    _prepare_active_phase(project_root, runtime_dir)
    contract = _contract()
    freeze_subphase_contract(project_root, runtime_dir, contract)

    # Simulate drift beneath the frozen artifacts: directly tamper with the
    # on-disk active contract so its phase no longer matches the phase plan.
    tampered = contract.model_copy(update={"phase_id": _phase_id("02")})
    _active_contract_json_path(runtime_dir).write_text(
        tampered.model_dump_json() + "\n", encoding="utf-8"
    )

    with pytest.raises((PlanningStoreError, PlanningValidationError)):
        load_active_subphase_contract(project_root, runtime_dir)


# ---------------------------------------------------------------------------
# Runtime externality (Section 62)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("runtime_relative", [None, "runtime-subdir"], ids=["equal", "beneath"])
def test_runtime_directory_must_be_external_to_project_root(
    tmp_path: Path, runtime_relative: str | None
) -> None:
    project_root = tmp_path / "project"
    project_root.mkdir()
    runtime_dir = project_root if runtime_relative is None else project_root / runtime_relative
    if runtime_relative is not None:
        runtime_dir.mkdir()

    frozen_plan = _valid_plan()
    freeze_master_plan(project_root, frozen_plan)
    phase_plan = _two_subphase_revision(frozen_plan)
    contract = _contract()

    with pytest.raises(PlanningStoreError):
        publish_phase_plan(project_root, runtime_dir, phase_plan)
    with pytest.raises(PlanningStoreError):
        load_phase_plan(project_root, runtime_dir)
    with pytest.raises(PlanningStoreError):
        freeze_subphase_contract(project_root, runtime_dir, contract)
    with pytest.raises(PlanningStoreError):
        load_active_subphase_contract(project_root, runtime_dir)

    assert not (runtime_dir / "planning").exists()
    assert not (runtime_dir / "contracts").exists()


# ---------------------------------------------------------------------------
# Symlinks (Section 63)
# ---------------------------------------------------------------------------


def test_freeze_master_plan_rejects_master_plan_json_symlink(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    real_target = tmp_path / "elsewhere.json"
    json_path = _master_plan_json_path(project_root)
    json_path.parent.mkdir(parents=True)
    _symlink_or_skip(json_path, real_target)

    with pytest.raises(PlanningStoreError):
        freeze_master_plan(project_root, _valid_plan())

    assert not real_target.exists()


def test_freeze_master_plan_rejects_master_plan_markdown_symlink(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    real_target = tmp_path / "elsewhere.md"
    md_path = _master_plan_md_path(project_root)
    md_path.parent.mkdir(parents=True)
    _symlink_or_skip(md_path, real_target)

    with pytest.raises(PlanningStoreError):
        freeze_master_plan(project_root, _valid_plan())

    assert not real_target.exists()


def test_freeze_master_plan_rejects_project_planning_directory_symlink(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    real_dir = tmp_path / "real-planning-dir"
    real_dir.mkdir()
    (project_root / ".lockstep").mkdir()
    _symlink_or_skip(project_root / ".lockstep" / "project", real_dir)

    with pytest.raises(PlanningStoreError):
        freeze_master_plan(project_root, _valid_plan())

    assert list(real_dir.iterdir()) == []


def test_load_frozen_master_plan_rejects_json_symlink(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    freeze_master_plan(project_root, _valid_plan())
    real_backup = tmp_path / "backup.json"
    json_path = _master_plan_json_path(project_root)
    real_backup.write_bytes(json_path.read_bytes())
    json_path.unlink()
    _symlink_or_skip(json_path, real_backup)

    with pytest.raises(PlanningStoreError):
        load_frozen_master_plan(project_root)


def test_publish_phase_plan_rejects_phase_plan_json_symlink(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    frozen_plan = _valid_plan()
    freeze_master_plan(project_root, frozen_plan)
    phase_plan = _two_subphase_revision(frozen_plan)

    real_target = tmp_path / "elsewhere-phase-plan.json"
    phase_plan_path = _phase_plan_json_path(runtime_dir)
    phase_plan_path.parent.mkdir(parents=True)
    _symlink_or_skip(phase_plan_path, real_target)

    with pytest.raises(PlanningStoreError):
        publish_phase_plan(project_root, runtime_dir, phase_plan)

    assert not real_target.exists()


def test_publish_phase_plan_rejects_planning_directory_symlink(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    frozen_plan = _valid_plan()
    freeze_master_plan(project_root, frozen_plan)
    phase_plan = _two_subphase_revision(frozen_plan)

    real_dir = tmp_path / "real-runtime-planning"
    real_dir.mkdir()
    _symlink_or_skip(runtime_dir / "planning", real_dir)

    with pytest.raises(PlanningStoreError):
        publish_phase_plan(project_root, runtime_dir, phase_plan)

    assert list(real_dir.iterdir()) == []


def test_freeze_subphase_contract_rejects_active_json_symlink(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    _prepare_active_phase(project_root, runtime_dir)

    real_target = tmp_path / "elsewhere-active.json"
    active_path = _active_contract_json_path(runtime_dir)
    active_path.parent.mkdir(parents=True)
    _symlink_or_skip(active_path, real_target)

    with pytest.raises(PlanningStoreError):
        freeze_subphase_contract(project_root, runtime_dir, _contract())

    assert not real_target.exists()


def test_freeze_subphase_contract_rejects_contracts_directory_symlink(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    _prepare_active_phase(project_root, runtime_dir)

    real_dir = tmp_path / "real-contracts-dir"
    real_dir.mkdir()
    _symlink_or_skip(runtime_dir / "contracts", real_dir)

    with pytest.raises(PlanningStoreError):
        freeze_subphase_contract(project_root, runtime_dir, _contract())

    assert list(real_dir.iterdir()) == []


# ---------------------------------------------------------------------------
# No Markdown authority (Section 64)
# ---------------------------------------------------------------------------


def test_load_frozen_master_plan_rejects_markdown_describing_different_plan(
    tmp_path: Path,
) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    plan = _valid_plan()
    freeze_master_plan(project_root, plan)

    md_path = _master_plan_md_path(project_root)
    original = md_path.read_text(encoding="utf-8")
    forged = original.replace(plan.title, "A Completely Different Title")
    assert forged != original
    md_path.write_text(forged, encoding="utf-8")

    with pytest.raises(PlanningStoreError):
        load_frozen_master_plan(project_root)


def test_load_frozen_master_plan_does_not_reconstruct_from_markdown(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    plan = _valid_plan()
    freeze_master_plan(project_root, plan)
    _master_plan_json_path(project_root).unlink()

    with pytest.raises(PlanningStoreError):
        load_frozen_master_plan(project_root)


# ---------------------------------------------------------------------------
# Dependency boundary (Section 65)
# ---------------------------------------------------------------------------

_FORBIDDEN_PLANNING_STORE_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.agents",
    "lockstep.runtime",
    "lockstep.config",
    "lockstep.git",
    "lockstep.process",
    "lockstep.persistence",
    "lockstep.state",
    "lockstep.supervisor",
    "lockstep.verification",
    "lockstep.reporting",
    "lockstep.cli",
    "subprocess",
)

_FORBIDDEN_OS_REFERENCES: tuple[str, ...] = (
    "os.environ",
    "os.getenv",
    "os.system",
    "os.popen",
)


def _imported_module_names(tree: ast.Module) -> set[str]:
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                names.add(alias.name)
        elif isinstance(node, ast.ImportFrom) and node.module:
            names.add(node.module)
    return names


def test_planning_store_module_imports_only_domain_planning_and_stdlib() -> None:
    source = inspect.getsource(planning_store)
    tree = ast.parse(source)

    imported = _imported_module_names(tree)

    for module in imported:
        if module == "lockstep" or module.startswith("lockstep."):
            assert module in {"lockstep.domain", "lockstep.planning"} or module.startswith(
                ("lockstep.domain.", "lockstep.planning.")
            )
        for forbidden in _FORBIDDEN_PLANNING_STORE_MODULE_PREFIXES:
            assert module != forbidden
            assert not module.startswith(forbidden + ".")


def test_planning_store_module_does_not_reference_forbidden_os_apis() -> None:
    source = inspect.getsource(planning_store)
    for forbidden in _FORBIDDEN_OS_REFERENCES:
        assert forbidden not in source


def test_planning_store_module_never_touches_environment_or_process(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    def _fail(*args: object, **kwargs: object) -> object:
        raise AssertionError("must not be called")

    monkeypatch.setattr(os, "getenv", _fail)
    monkeypatch.setattr(os, "system", _fail)
    monkeypatch.setattr(Path, "home", _fail)
    monkeypatch.setattr("lockstep.process.run_process", _fail)

    project_root, runtime_dir = _roots(tmp_path)
    plan = _valid_plan()
    freeze_master_plan(project_root, plan)
    assert load_frozen_master_plan(project_root) == plan

    phase_plan = _two_subphase_revision(plan)
    publish_phase_plan(project_root, runtime_dir, phase_plan)
    assert load_phase_plan(project_root, runtime_dir) == phase_plan

    contract = _contract()
    freeze_subphase_contract(project_root, runtime_dir, contract)
    assert load_active_subphase_contract(project_root, runtime_dir) == contract


# ---------------------------------------------------------------------------
# No hidden mutation authority (Section 66)
# ---------------------------------------------------------------------------

_FORBIDDEN_PLANNING_STORE_REFERENCES: tuple[str, ...] = (
    "subprocess",
    "socket",
    "urllib",
    "requests",
    "append_event",
    "write_state",
    "read_state",
    "RunCreatedEvent",
    "RunHaltedEvent",
    "StateTransitionedEvent",
    "invoke_agent",
    "run_process",
    "prepare_agent_runtime",
    "diagnose_agent_providers",
    "resolve_agent_adapters",
    "Repository",
    "Worktree",
    "Supervisor",
)


def test_planning_store_module_has_no_forbidden_symbol_references() -> None:
    source = inspect.getsource(planning_store)
    for forbidden in _FORBIDDEN_PLANNING_STORE_REFERENCES:
        assert forbidden not in source


def test_planning_store_writes_stay_within_managed_directories(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    written_paths: list[Path] = []

    real_replace = planning_store.os.replace

    def tracking_replace(source: object, target: object) -> None:
        written_paths.append(Path(str(target)))
        real_replace(source, target)

    monkeypatch.setattr(planning_store.os, "replace", tracking_replace)

    plan = _valid_plan()
    freeze_master_plan(project_root, plan)
    phase_plan = _two_subphase_revision(plan)
    publish_phase_plan(project_root, runtime_dir, phase_plan)
    contract = _contract()
    freeze_subphase_contract(project_root, runtime_dir, contract)

    allowed_parents = (
        project_root / ".lockstep" / "project",
        runtime_dir / "planning",
        runtime_dir / "contracts",
    )
    assert written_paths
    for path in written_paths:
        assert path.parent in allowed_parents


# ---------------------------------------------------------------------------
# PlanningStoreError shape (Section 7)
# ---------------------------------------------------------------------------


def test_planning_store_error_reason_is_bounded(tmp_path: Path) -> None:
    project_root, _runtime_dir = _roots(tmp_path)
    freeze_master_plan(project_root, _valid_plan())
    different_plan = _plan((_phase("01", subphases=(_outline("01"),)),))

    with pytest.raises(PlanningStoreError) as excinfo:
        freeze_master_plan(project_root, different_plan)

    reason = excinfo.value.reason
    assert isinstance(reason, str)
    assert reason
    assert len(reason) <= 200
    assert "\n" not in reason
