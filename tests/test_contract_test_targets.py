"""11.7-R1: executable Contract test targets, validated before the Contract freezes.

Gate Attempt 1 showed a real Contract Planner emitting ``TestSpecification(path="tests")``.
Semantic Contract validation accepted it, the Contract froze and bound, and the next
deterministic stage (Planner test authoring) could not satisfy it. R1 pins the fix:

    ``TestSpecification.path`` is one exact repository-relative FILE target
        -> a repository-aware check runs before ``freeze_subphase_contract``
        -> the host never guesses a corrected path
        -> exactly one fresh Planner correction is attempted, then the run stops safely

Everything runs the real production code against fake provider executables.

Baseline classification: every test in this module is RED at entry
(``lockstep.contract_test_targets`` and the correction seam do not exist).
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from test_project_orchestrator import (
    _contract_payload,
    _contract_response,
    _make_project,
    _phase_plan,
    _tests_response,
)

import lockstep.planning_workflow as planning_workflow
import lockstep.project_orchestrator as project_orchestrator
from lockstep.contract_test_targets import contract_target_findings, target_path_violation
from lockstep.domain import SubphaseContract
from lockstep.metrics import project_runtime_metrics
from lockstep.planning_store import (
    load_active_subphase_contract,
    load_frozen_master_plan,
    load_phase_plan,
)
from lockstep.planning_workflow import ContractCorrection
from lockstep.project_cursor_store import load_project_cursor
from lockstep.project_orchestrator import ProjectRunDisposition

_BASELINE = Path(__file__).parent / "baselines" / "transaction_baseline.json"


def _contract(path: str, *, sid: str = "01", objective: str | None = None) -> SubphaseContract:
    payload = _contract_payload(sid)
    payload["tests"][0]["path"] = path  # type: ignore[index]
    if objective is not None:
        payload["objective"] = objective
    return SubphaseContract.model_validate(payload)


def _bad_response(path: str = "tests", *, sid: str = "01", objective: str | None = None):
    payload = _contract_payload(sid)
    payload["tests"][0]["path"] = path  # type: ignore[index]
    if objective is not None:
        payload["objective"] = objective
        payload["allowed_paths"] = ["feature_01.py", "everything_else.py"]
    return {"stdout": json.dumps(payload), "returncode": 0}


# ===========================================================================
# The shared structural predicate
# ===========================================================================


@pytest.mark.parametrize(
    "path",
    ["tests/", ".", "", "/abs/tests/test_names.py", "tests/**/*.py", "tests/t?.py", "a/../b.py"],
)
def test_structurally_unsafe_paths_are_violations(path: str) -> None:
    assert target_path_violation(path) is not None


@pytest.mark.parametrize("path", ["tests/test_names.py", "test_names.py", "a/b/test_c.py"])
def test_exact_relative_file_paths_have_no_structural_violation(path: str) -> None:
    assert target_path_violation(path) is None


# ===========================================================================
# A/B/C: repository-aware findings
# ===========================================================================


def test_an_existing_directory_target_is_rejected(tmp_path: Path) -> None:
    (tmp_path / "tests").mkdir()

    findings = contract_target_findings(_contract("tests"), (tmp_path,))

    assert len(findings) == 1
    assert "tests[0].path" in findings[0]
    assert "'tests'" in findings[0]
    assert "directory" in findings[0]


def test_an_existing_regular_file_target_is_valid(tmp_path: Path) -> None:
    (tmp_path / "tests").mkdir()
    (tmp_path / "tests" / "test_names.py").write_text("def test_x():\n    pass\n")

    assert contract_target_findings(_contract("tests/test_names.py"), (tmp_path,)) == ()


def test_a_future_red_file_target_is_not_rejected_for_absence(tmp_path: Path) -> None:
    assert contract_target_findings(_contract("tests/test_not_yet.py"), (tmp_path,)) == ()
    (tmp_path / "tests").mkdir()
    assert contract_target_findings(_contract("tests/test_not_yet.py"), (tmp_path,)) == ()


def test_a_target_below_an_existing_file_is_rejected(tmp_path: Path) -> None:
    (tmp_path / "tests").write_text("not a directory\n")

    findings = contract_target_findings(_contract("tests/test_x.py"), (tmp_path,))

    assert len(findings) == 1


def test_a_symlinked_component_is_rejected(tmp_path: Path) -> None:
    real = tmp_path / "real"
    real.mkdir()
    (tmp_path / "tests").symlink_to(real, target_is_directory=True)

    assert contract_target_findings(_contract("tests/test_x.py"), (tmp_path,)) != ()


def test_a_directory_in_any_supplied_root_is_rejected(tmp_path: Path) -> None:
    source = tmp_path / "source"
    base = tmp_path / "base"
    source.mkdir()
    (base / "tests").mkdir(parents=True)

    assert contract_target_findings(_contract("tests"), (source, base)) != ()


def test_every_offending_test_is_reported_in_contract_order(tmp_path: Path) -> None:
    (tmp_path / "tests").mkdir()
    payload = _contract_payload("01")
    payload["tests"] = [
        {"path": "tests", "expectation": "red", "acceptance_criteria": ["AC-1"]},
        {"path": "tests/test_ok.py", "expectation": "red", "acceptance_criteria": ["AC-1"]},
        {"path": "tests/", "expectation": "red", "acceptance_criteria": ["AC-1"]},
    ]
    contract = SubphaseContract.model_validate(payload)

    findings = contract_target_findings(contract, (tmp_path,))

    assert len(findings) == 2
    assert "tests[0]" in findings[0] and "tests[2]" in findings[1]


# ===========================================================================
# D: Planner instructions
# ===========================================================================


def test_contract_planner_instructions_define_test_paths_as_exact_file_targets() -> None:
    text = planning_workflow._SUBPHASE_CONTRACT_INSTRUCTIONS.lower()

    assert "exact repository-relative test file" in text
    assert "directory" in text and "never" in text
    assert "glob" in text
    assert "baseline" in text and "verification" in text


# ===========================================================================
# The correction seam in Contract creation
# ===========================================================================


def test_correction_evidence_is_labeled_and_never_authority(tmp_path: Path) -> None:
    project = _make_project(tmp_path, sids=("01",), planner=[_contract_response("01")])
    rejected = _contract("tests", objective="Rewrite everything.")
    correction = ContractCorrection(rejected_contract=rejected, findings=("tests[0] bad",))

    prompts: list[str] = []
    original = planning_workflow.invoke_planner_artifact

    def spy(runtime, *, kind, prompt, **kwargs):  # type: ignore[no-untyped-def]
        prompts.append(prompt)
        return original(runtime, kind=kind, prompt=prompt, **kwargs)

    planning_workflow.invoke_planner_artifact = spy  # type: ignore[assignment]
    try:
        project_orchestrator._ensure_outline_published(
            project.project_root, project.runtime_dir, _init_cursor(project)
        )
        planning_workflow.create_subphase_contract_candidate(
            project.runtime,
            phase_id=_cursor(project).current_phase,  # type: ignore[arg-type]
            subphase_id=_cursor(project).current_subphase,  # type: ignore[arg-type]
            timeout_seconds=60.0,
            correction=correction,
        )
    finally:
        planning_workflow.invoke_planner_artifact = original  # type: ignore[assignment]

    [prompt] = prompts
    assert "REJECTED CANDIDATE EVIDENCE" in prompt
    assert "DETERMINISTIC VALIDATION FINDINGS" in prompt
    assert "tests[0] bad" in prompt
    assert "Rewrite everything." in prompt
    assert "evidence only" in prompt.lower()


def _init_cursor(project):  # type: ignore[no-untyped-def]
    from lockstep.project_cursor_store import initialize_project_cursor

    return initialize_project_cursor(project.project_root, project.runtime_dir)


def _cursor(project):  # type: ignore[no-untyped-def]
    cursor = load_project_cursor(project.project_root, project.runtime_dir)
    assert cursor is not None
    return cursor


# ===========================================================================
# E: invalid then corrected
# ===========================================================================


def _spy_orchestrator(monkeypatch: pytest.MonkeyPatch):  # type: ignore[no-untyped-def]
    created: list[ContractCorrection | None] = []
    frozen: list[SubphaseContract] = []
    real_create = project_orchestrator.create_subphase_contract_candidate
    real_freeze = project_orchestrator.freeze_subphase_contract

    def create(runtime, **kwargs):  # type: ignore[no-untyped-def]
        created.append(kwargs.get("correction"))
        return real_create(runtime, **kwargs)

    def freeze(project_root, runtime_dir, contract):  # type: ignore[no-untyped-def]
        frozen.append(contract)
        return real_freeze(project_root, runtime_dir, contract)

    monkeypatch.setattr(project_orchestrator, "create_subphase_contract_candidate", create)
    monkeypatch.setattr(project_orchestrator, "freeze_subphase_contract", freeze)
    return created, frozen


def test_invalid_then_corrected_freezes_only_the_second_candidate(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _make_project(
        tmp_path,
        sids=("01",),
        planner=[_bad_response("tests"), _contract_response("01"), _tests_response("01")],
    )
    (project.project_root / "tests").mkdir()
    created, frozen = _spy_orchestrator(monkeypatch)

    assert project.step() is None

    assert project.launches("planner") == 2
    assert len(created) == 2
    assert created[0] is None
    assert created[1] is not None
    assert created[1].rejected_contract.tests[0].path == "tests"
    assert any("tests[0].path" in finding for finding in created[1].findings)
    assert [c.tests[0].path for c in frozen] == ["tests/test_feature_01.py"]
    active = load_active_subphase_contract(project.project_root, project.runtime_dir)
    assert active == frozen[0]
    assert project.cursor().active_contract is not None

    result = project.run()
    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    # 2 Contract plans (project level) + 1 test-authoring turn.
    assert project.launches("planner") == 3


def test_correction_is_not_a_child_transaction_attempt(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _make_project(
        tmp_path,
        sids=("01",),
        planner=[_bad_response("tests"), _contract_response("01"), _tests_response("01")],
    )
    (project.project_root / "tests").mkdir()
    _spy_orchestrator(monkeypatch)

    project.run()

    totals = project_runtime_metrics(project.txn_dir("01"), repository_change=None).totals
    assert totals.executed_attempts == 1
    assert {role.value: n for role, n in totals.invocations_by_role.items()} == {
        "planner": 1,
        "implementer": 1,
        "reviewer": 1,
    }
    assert json.loads(_BASELINE.read_text())["baseline_version"] == 1


# ===========================================================================
# F: two invalid candidates
# ===========================================================================


def test_two_invalid_candidates_stop_safely_with_no_third_call(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _make_project(
        tmp_path,
        sids=("01",),
        planner=[_bad_response("tests"), _bad_response("tests"), _contract_response("01")],
    )
    (project.project_root / "tests").mkdir()
    created, frozen = _spy_orchestrator(monkeypatch)

    result = project.step()

    assert result is not None
    assert result.disposition is ProjectRunDisposition.EXECUTION_FAILED
    assert result.detail is not None and "contract test target" in result.detail
    assert "tests[0].path" in result.detail
    assert project.launches("planner") == 2
    assert len(created) == 2
    assert frozen == []
    assert load_active_subphase_contract(project.project_root, project.runtime_dir) is None
    assert project.cursor().active_contract is None
    # Not a downstream transaction failure: nothing launched, nothing journaled.
    assert not project.txn_dir("01").exists()
    assert project.launches("implementer") == 0 and project.launches("reviewer") == 0


# ===========================================================================
# G: authority preservation
# ===========================================================================


def test_a_rejected_candidate_never_mutates_planning_authority(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _make_project(
        tmp_path,
        sids=("01",),
        planner=[
            _bad_response("tests", objective="Rewrite the whole project."),
            _contract_response("01"),
            _tests_response("01"),
        ],
        outline=_phase_plan(("01",)),
        initialize_cursor=True,
    )
    (project.project_root / "tests").mkdir()
    _, frozen = _spy_orchestrator(monkeypatch)
    master_before = load_frozen_master_plan(project.project_root)
    phase_before = load_phase_plan(project.project_root, project.runtime_dir)

    assert project.step() is None

    assert load_frozen_master_plan(project.project_root) == master_before
    assert load_phase_plan(project.project_root, project.runtime_dir) == phase_before
    [only] = frozen
    assert only.objective == "Provide feature 01."
    assert "everything_else.py" not in only.allowed_paths
    active = load_active_subphase_contract(project.project_root, project.runtime_dir)
    assert active is not None and active.objective == "Provide feature 01."


def test_exhaustion_leaves_master_plan_phase_plan_and_cursor_untouched(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _make_project(
        tmp_path,
        sids=("01",),
        planner=[_bad_response("tests"), _bad_response("tests")],
        outline=_phase_plan(("01",)),
        initialize_cursor=True,
    )
    (project.project_root / "tests").mkdir()
    _spy_orchestrator(monkeypatch)
    master_before = load_frozen_master_plan(project.project_root)
    phase_before = load_phase_plan(project.project_root, project.runtime_dir)
    cursor_before = project.cursor()

    result = project.step()

    assert result is not None
    assert load_frozen_master_plan(project.project_root) == master_before
    assert load_phase_plan(project.project_root, project.runtime_dir) == phase_before
    assert project.cursor() == cursor_before


# ===========================================================================
# The host never guesses a corrected path
# ===========================================================================


def test_the_host_never_rewrites_a_rejected_path(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _make_project(
        tmp_path,
        sids=("01",),
        planner=[_bad_response("tests"), _bad_response("tests")],
    )
    (project.project_root / "tests").mkdir()
    _, frozen = _spy_orchestrator(monkeypatch)

    project.step()

    assert frozen == []
    assert not (project.project_root / "tests" / "test_feature_01.py").exists()
