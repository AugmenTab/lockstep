"""Phase 11.3: JIT replanning between accepted Sub-phases.

After each canonically completed Sub-phase *with work still unfinished*, a
fresh Planner reconsiders the unfinished provisional outline against the
accepted repository state; the host validates the candidate, durably accepts
it (a replan receipt), publishes the revised outline and cursor, and only
then does the existing 11.2 path plan and freeze the next single Contract::

    record completion -> JIT REPLAN -> plan + freeze next Contract

Everything here runs the real production code against fake provider
executables, a real Git source repository, and the real planning/cursor
stores. No real Claude/Codex account, network, or model inference is used.

Replanning is the orchestrator's default (``jit_replan=True``); the 11.2
fixed-outline behavior remains available as an explicit ``jit_replan=False``.

Baseline classification: every test in this module is RED at entry
(``lockstep.jit_replan`` does not exist and the orchestrator has no
``jit_replan`` parameter).
"""

from __future__ import annotations

import ast
import inspect
import json
import shutil
from pathlib import Path
from typing import Any

import pytest
from test_project_orchestrator import (
    _BASELINE,
    _SRC,
    _contract_payload,
    _contract_response,
    _crash_recording_once,
    _CrashError,
    _history_files,
    _impl_response,
    _make_project,
    _phase_plan,
    _Project,
    _review_response,
    _tests_response,
)
from test_supervisor_resume_execution import (
    _budget,
    _git,
    _implementer_blocked_response,
    _process_failure_response,
)

import lockstep.jit_replan as jit_replan
import lockstep.planning_store as planning_store
import lockstep.project_orchestrator as project_orchestrator
from lockstep.domain import (
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    RunId,
    SubphaseId,
    SubphaseOutline,
)
from lockstep.escalation import EscalationAuthority, EscalationCategory
from lockstep.jit_replan import (
    JitReplanError,
    JitReplanState,
    ReplanBasis,
    ReplanOutcome,
    build_jit_replan_prompt,
    jit_replan_state,
    load_replan_receipt,
    replan_receipt_path,
    run_jit_replan,
)
from lockstep.metrics import project_runtime_metrics
from lockstep.planning_store import (
    PlanningStoreError,
    load_active_subphase_contract,
)
from lockstep.project_cursor import (
    CompletedSubphase,
    PhaseGateStatus,
    ProjectCursor,
    ProjectCursorError,
)
from lockstep.project_orchestrator import (
    ProjectOrchestrationError,
    ProjectRunDisposition,
    ProjectRunResult,
    run_project_phase,
    step_project_run,
)
from lockstep.state import WorkflowState

# ---------------------------------------------------------------------------
# Scripted Planner responses and project construction
# ---------------------------------------------------------------------------

Part = str | dict[str, object]


def _replan(*sids: str) -> dict[str, object]:
    return {"stdout": _phase_plan(sids).model_dump_json(), "returncode": 0}


def _plan_response(plan: PhasePlan) -> dict[str, object]:
    return {"stdout": plan.model_dump_json(), "returncode": 0}


def _script(*parts: Part) -> list[dict[str, object]]:
    """A ``str`` part is one Sub-phase's Contract plan + test authoring; a dict is exact."""
    script: list[dict[str, object]] = []
    for part in parts:
        if isinstance(part, str):
            script.append(_contract_response(part))
            script.append(_tests_response(part))
        else:
            script.append(part)
    return script


def _project(
    tmp_path: Path,
    script: list[dict[str, object]],
    executed: tuple[str, ...],
    *,
    master: tuple[str, ...] = ("01", "02", "03"),
    implementer: list[dict[str, object]] | None = None,
    reviewer: list[dict[str, object]] | None = None,
) -> _Project:
    return _make_project(
        tmp_path,
        sids=master,
        planner=script,
        implementer=implementer
        if implementer is not None
        else [_impl_response(s) for s in executed],
        reviewer=reviewer if reviewer is not None else [_review_response(s) for s in executed],
    )


def _noop_project(tmp_path: Path) -> _Project:
    same = _replan("01", "02", "03")
    return _project(tmp_path, _script("01", same, "02", same, "03"), ("01", "02", "03"))


def _replace_project(tmp_path: Path) -> _Project:
    same = _replan("01", "05", "06")
    return _project(tmp_path, _script("01", same, "05", same, "06"), ("01", "05", "06"))


def _step(project: _Project, *, budget: int = 3) -> ProjectRunResult | None:
    return step_project_run(
        project.runtime,
        request_factory=project.factory,
        retry_budget=_budget(budget),
        planning_timeout_seconds=60.0,
        jit_replan=True,
    )


def _advance(project: _Project, steps: int) -> None:
    for _ in range(steps):
        assert _step(project) is None


def _run(project: _Project, *, budget: int = 3) -> ProjectRunResult:
    return run_project_phase(
        project.runtime,
        request_factory=project.factory,
        retry_budget=_budget(budget),
        planning_timeout_seconds=60.0,
        jit_replan=True,
    )


def _plan_path(project: _Project) -> Path:
    return project.runtime_dir / "planning" / "phase-plan.json"


def _plan_ids(project: _Project) -> list[str]:
    plan = json.loads(_plan_path(project).read_text())
    return [s["subphase_id"] for s in plan["subphases"]]


def _receipt_names(project: _Project) -> list[str]:
    directory = project.runtime_dir / "planning" / "replans"
    return sorted(p.name for p in directory.iterdir()) if directory.exists() else []


def _state(project: _Project) -> JitReplanState:
    return jit_replan_state(project.project_root, project.runtime_dir)


def _ids(outlines: tuple[SubphaseOutline, ...]) -> list[str]:
    return [o.subphase_id.root for o in outlines]


def _planner_cwds(project: _Project) -> list[Path]:
    log = project.bins["planner"] / "claude-planner-invocations.jsonl"
    return [Path(json.loads(line)["cwd"]).resolve() for line in log.read_text().splitlines()]


def _receipt(project: _Project, sid: str) -> jit_replan.ReplanReceipt:
    receipt = load_replan_receipt(project.project_root, project.runtime_dir, project.run_id(sid))
    assert receipt is not None
    return receipt


def _snapshot(*roots: Path) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    for root in roots:
        for path in sorted(root.rglob("*")):
            if path.is_file():
                files[str(path)] = path.read_bytes()
    return files


def _direct_replan(project: _Project, sid: str) -> jit_replan.ReplanReceipt | None:
    return run_jit_replan(
        project.runtime,
        worktree_path=project.worktree(sid),
        branch=f"lockstep/run/{project.run_id(sid).root}",
        timeout_seconds=60.0,
    )


# ===========================================================================
# Public surface
# ===========================================================================


def test_public_api_exports_expected_names() -> None:
    assert set(jit_replan.__all__) == {
        "JitReplanError",
        "JitReplanState",
        "ReplanBasis",
        "ReplanOutcome",
        "ReplanReceipt",
        "build_jit_replan_prompt",
        "jit_replan_state",
        "load_replan_receipt",
        "replan_receipt_path",
        "run_jit_replan",
    }


def test_the_state_and_outcome_vocabularies_are_typed() -> None:
    assert {s.name for s in JitReplanState} == {
        "NOT_APPLICABLE",
        "REPLAN_REQUIRED",
        "REPLAN_ACCEPTED",
        "REPLAN_APPLIED",
    }
    assert {o.value for o in ReplanOutcome} == {"unchanged", "revised"}


def test_the_orchestrator_replans_by_default_with_an_explicit_opt_out() -> None:
    for function in (run_project_phase, step_project_run):
        parameter = inspect.signature(function).parameters["jit_replan"]
        assert parameter.kind is inspect.Parameter.KEYWORD_ONLY
        assert parameter.default is True


def test_the_receipt_path_is_per_completed_run_under_the_planning_directory(
    tmp_path: Path,
) -> None:
    run_id = RunId.model_validate("run-01-01")

    assert (
        replan_receipt_path(tmp_path, run_id)
        == tmp_path / "planning" / "replans" / "run-01-01.json"
    )


# ===========================================================================
# Scenario A: no-op replans -- AC-01/02/03/07/08/12/17/19/20/22
# ===========================================================================


@pytest.fixture(scope="module")
def noop_run(tmp_path_factory: pytest.TempPathFactory) -> tuple[_Project, ProjectRunResult]:
    project = _noop_project(tmp_path_factory.mktemp("noop"))
    return project, _run(project)


def test_a_noop_replan_runs_after_each_nonfinal_subphase_and_never_after_the_last(
    noop_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, result = noop_run

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == ["01", "02", "03"]
    assert _receipt_names(project) == ["run-01-01.json", "run-01-02.json"]
    # Contract plan + tests per Sub-phase (6) plus exactly one replan per nonfinal Sub-phase (2).
    assert project.counts() == (8, 3, 3)


def test_an_unchanged_outline_is_durably_recorded_as_replanned(
    noop_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, _ = noop_run
    expected = _phase_plan(("01", "02", "03")).subphases

    first, second = _receipt(project, "01"), _receipt(project, "02")

    assert first.outcome is ReplanOutcome.UNCHANGED
    assert first.unfinished_outline == expected[1:]
    assert second.outcome is ReplanOutcome.UNCHANGED
    assert second.unfinished_outline == expected[2:]


def test_the_replan_basis_names_the_completed_run_and_its_accepted_commit(
    noop_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, _ = noop_run
    for index, sid in enumerate(("01", "02")):
        receipt = _receipt(project, sid)
        entry = project.cursor().completed_subphases[index]
        branch = f"lockstep/run/run-01-{sid}"

        assert receipt.basis.phase_id == entry.phase_id
        assert receipt.basis.subphase_id == entry.subphase_id
        assert receipt.basis.run_id == entry.run_id
        assert receipt.basis.contract_digest == entry.contract_digest
        assert receipt.basis.branch == branch
        tip = _git(project.source, "rev-parse", f"refs/heads/{branch}").stdout.strip()
        assert receipt.basis.commit == tip
        assert _git(project.worktree(sid), "rev-parse", "HEAD").stdout.strip() == tip


def test_the_replan_planner_runs_inside_the_latest_accepted_worktree(
    noop_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, _ = noop_run
    cwds = _planner_cwds(project)

    # Planner launches: contract 01, tests 01, REPLAN, contract 02, tests 02, REPLAN, ...
    assert cwds[2] == project.worktree("01").resolve()
    assert cwds[5] == project.worktree("02").resolve()
    assert project.source.resolve() not in {cwds[2], cwds[5]}

    first, second = _receipt(project, "01").basis.commit, _receipt(project, "02").basis.commit
    assert _git(project.source, "show", f"{first}:feature_01.py").returncode == 0
    assert _git(project.source, "show", f"{second}:feature_02.py").returncode == 0
    ancestry = _git(project.source, "merge-base", "--is-ancestor", first, second, check=False)
    assert ancestry.returncode == 0  # the next transaction inherits the planned-from lineage


def test_each_replan_is_a_separate_planner_process(
    noop_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, _ = noop_run
    log = project.bins["planner"] / "claude-planner-invocations.jsonl"
    indexes = [json.loads(line)["index"] for line in log.read_text().splitlines()]

    assert indexes == list(range(8))


def test_a_noop_replan_leaves_cursor_outline_and_history_untouched(tmp_path: Path) -> None:
    project = _noop_project(tmp_path)
    _advance(project, 2)  # plan + run Sub-phase 01
    cursor, plan_bytes = project.cursor(), _plan_path(project).read_bytes()
    assert _state(project) is JitReplanState.REPLAN_REQUIRED

    assert _step(project) is None  # the replan

    assert project.cursor() == cursor
    assert _plan_path(project).read_bytes() == plan_bytes
    assert _receipt(project, "01").outcome is ReplanOutcome.UNCHANGED
    assert _state(project) is JitReplanState.REPLAN_APPLIED
    assert project.launches("planner") == 3
    assert load_active_subphase_contract(project.project_root, project.runtime_dir) is None


def test_an_accepted_noop_replan_is_not_repeated_after_restart(tmp_path: Path) -> None:
    project = _noop_project(tmp_path)
    _advance(project, 3)  # plan 01, run 01, replan
    assert project.launches("planner") == 3

    result = _run(project)  # a fresh call: all progress is re-derived from durable state

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert project.counts() == (8, 3, 3)
    assert _receipt_names(project) == ["run-01-01.json", "run-01-02.json"]


def test_replanning_is_idempotent_when_called_directly(tmp_path: Path) -> None:
    project = _noop_project(tmp_path)
    assert _direct_replan(project, "01") is None  # nothing completed: not applicable
    _advance(project, 3)
    before = project.counts()

    again = _direct_replan(project, "01")

    assert again == _receipt(project, "01")
    assert project.counts() == before


def test_the_replan_lifecycle_states_are_distinguishable(tmp_path: Path) -> None:
    project = _noop_project(tmp_path)
    assert _state(project) is JitReplanState.NOT_APPLICABLE  # nothing initialized
    _advance(project, 1)
    assert _state(project) is JitReplanState.NOT_APPLICABLE  # nothing completed yet
    _advance(project, 1)
    assert _state(project) is JitReplanState.REPLAN_REQUIRED
    _advance(project, 1)
    assert _state(project) is JitReplanState.REPLAN_APPLIED
    assert _run(project).disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert _state(project) is JitReplanState.NOT_APPLICABLE  # nothing unfinished remains


def test_the_receipt_is_not_a_competing_progress_authority(
    noop_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, _ = noop_run
    raw = json.loads(replan_receipt_path(project.runtime_dir, project.run_id("01")).read_text())

    assert set(raw) == {
        "schema_version",
        "project_id",
        "master_plan_digest",
        "basis",
        "outcome",
        "unfinished_outline",
    }
    assert set(raw["basis"]) == {
        "phase_id",
        "subphase_id",
        "run_id",
        "contract_digest",
        "branch",
        "commit",
    }
    assert [p.name for p in (project.runtime_dir / "project").iterdir()] == ["cursor.json"]
    assert {p.name for p in project.runtime_dir.iterdir()} <= {
        "project",
        "planning",
        "contracts",
        "transactions",
        "worktrees",
    }
    assert {p.name for p in (project.runtime_dir / "planning").iterdir()} == {
        "phase-plan.json",
        "replans",
    }


def test_replanning_does_not_distort_child_transaction_metrics(
    noop_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, _ = noop_run
    assert json.loads(_BASELINE.read_text())["baseline_version"] == 1
    for sid in project.sids:
        totals = project_runtime_metrics(project.txn_dir(sid), repository_change=None).totals
        assert (totals.subphases_attempted, totals.subphases_completed) == (1, 1)
        assert totals.executed_attempts == 1
        assert {role.value: n for role, n in totals.invocations_by_role.items()} == {
            "planner": 1,
            "implementer": 1,
            "reviewer": 1,
        }


def test_no_phase_gate_ran_and_the_phase_is_not_completed_by_replanning(
    noop_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, result = noop_run
    assert result.cursor.completed_phases == ()
    for sid in project.sids:
        targets = {
            getattr(e, "target", None)
            for e in project_orchestrator.read_events(project.txn_dir(sid) / "events.jsonl")
        }
        assert WorkflowState.PHASE_COMPLETE not in targets
        assert WorkflowState.PHASE_INTEGRATION_GATE not in targets


# ===========================================================================
# Scenario B/C: replacing the current provisional unit; add / split / reorder
# ===========================================================================


def test_the_selected_but_unfrozen_next_unit_can_be_replaced_and_never_gets_a_contract(
    tmp_path: Path,
) -> None:
    project = _replace_project(tmp_path)
    _advance(project, 2)  # plan + run Sub-phase 01
    before = project.cursor()
    assert before.current_subphase == SubphaseId.model_validate("02")
    history_before = _snapshot(project.txn_dir("01"), project.runtime_dir / "contracts" / "history")
    master = project.project_root / ".lockstep" / "project"
    master_before = _snapshot(master)

    assert _step(project) is None  # the replan

    cursor = project.cursor()
    assert cursor.completed_subphases == before.completed_subphases
    assert cursor.current_subphase == SubphaseId.model_validate("05")
    assert _ids(cursor.remaining_outline) == ["06"]
    assert cursor.active_contract is None
    assert cursor.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING
    assert cursor.revision == before.revision + 1
    assert _plan_ids(project) == ["01", "05", "06"]
    assert _receipt(project, "01").outcome is ReplanOutcome.REVISED
    assert _ids(_receipt(project, "01").unfinished_outline) == ["05", "06"]
    assert _state(project) is JitReplanState.REPLAN_APPLIED
    # Revised outline authority is provisional: nothing frozen, nothing launched.
    assert load_active_subphase_contract(project.project_root, project.runtime_dir) is None
    assert project.counts() == (3, 1, 1)
    assert not project.txn_dir("02").exists()
    # Completed history, the frozen Master Plan, and child artifacts are immutable.
    assert _snapshot(project.txn_dir("01"), project.runtime_dir / "contracts" / "history") == (
        history_before
    )
    assert _snapshot(master) == master_before


def test_only_the_new_current_unit_is_frozen_and_the_rest_stay_provisional(
    tmp_path: Path,
) -> None:
    project = _replace_project(tmp_path)
    _advance(project, 3)  # plan 01, run 01, replan

    assert _step(project) is None  # plan + freeze + bind

    active = load_active_subphase_contract(project.project_root, project.runtime_dir)
    assert active is not None and active.subphase_id.root == "05"
    cursor = project.cursor()
    assert cursor.active_contract is not None
    assert cursor.active_contract.transaction_run_id == project.run_id("05")
    assert _ids(cursor.remaining_outline) == ["06"]
    assert project.launches("planner") == 4  # one Contract plan; none for 06
    assert not project.txn_dir("06").exists()


def test_a_replaced_unit_run_completes_without_a_human_relay_through_two_replans(
    tmp_path: Path,
) -> None:
    project = _replace_project(tmp_path)

    result = _run(project)

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    cursor = project.cursor()
    assert [e.subphase_id.root for e in cursor.completed_subphases] == ["01", "05", "06"]
    assert [e.run_id.root for e in cursor.completed_subphases] == [
        "run-01-01",
        "run-01-05",
        "run-01-06",
    ]
    assert not project.txn_dir("02").exists() and not project.txn_dir("03").exists()
    assert sorted(p.name.rsplit("-", 1)[0] for p in _history_files(project)) == [
        "01-01",
        "01-05",
        "01-06",
    ]
    assert _receipt_names(project) == ["run-01-01.json", "run-01-05.json"]
    assert project.counts() == (8, 3, 3)
    assert _plan_ids(project) == ["01", "05", "06"]


def test_a_split_and_added_work_is_durable_provisional_and_only_the_first_unit_freezes(
    tmp_path: Path,
) -> None:
    same = _replan("01", "05", "06", "03")
    project = _project(
        tmp_path,
        _script("01", same, "05", same, "06", same, "03"),
        ("01", "05", "06", "03"),
    )
    _advance(project, 3)  # plan 01, run 01, replan: 02 split into 05 + 06, 03 kept

    cursor = project.cursor()
    assert cursor.current_subphase == SubphaseId.model_validate("05")
    assert _ids(cursor.remaining_outline) == ["06", "03"]
    assert _plan_ids(project) == ["01", "05", "06", "03"]

    assert _step(project) is None
    active = load_active_subphase_contract(project.project_root, project.runtime_dir)
    assert active is not None and active.subphase_id.root == "05"
    assert project.launches("planner") == 4

    result = _run(project)
    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == [
        "01",
        "05",
        "06",
        "03",
    ]
    assert project.counts() == (11, 4, 4)


def test_newly_discovered_work_is_added_as_provisional_future_work(tmp_path: Path) -> None:
    grown = _replan("01", "02", "03", "04")
    project = _project(
        tmp_path,
        _script("01", grown, "02", grown, "03", grown, "04"),
        ("01", "02", "03", "04"),
    )
    _advance(project, 3)

    cursor = project.cursor()
    assert cursor.current_subphase == SubphaseId.model_validate("02")
    assert _ids(cursor.remaining_outline) == ["03", "04"]
    assert _receipt(project, "01").outcome is ReplanOutcome.REVISED
    assert project.launches("planner") == 3  # nothing was pre-frozen

    assert _run(project).disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == [
        "01",
        "02",
        "03",
        "04",
    ]


def test_reordering_provisional_work_is_persisted_before_the_next_contract(
    tmp_path: Path,
) -> None:
    swapped = _replan("01", "03", "02")
    project = _project(tmp_path, _script("01", swapped, "03", swapped, "02"), ("01", "03", "02"))
    _advance(project, 3)

    cursor = project.cursor()
    assert cursor.current_subphase == SubphaseId.model_validate("03")
    assert _ids(cursor.remaining_outline) == ["02"]
    assert _plan_ids(project) == ["01", "03", "02"]

    assert _run(project).disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == ["01", "03", "02"]


# ===========================================================================
# Scenario D: removing all remaining work -- AC-14/17
# ===========================================================================


def test_removing_all_remaining_work_makes_the_gate_ready_without_completing_the_phase(
    tmp_path: Path,
) -> None:
    project = _project(tmp_path, _script("01", _replan("01")), ("01",))

    result = _run(project)

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    cursor = project.cursor()
    assert cursor == result.cursor
    assert [e.subphase_id.root for e in cursor.completed_subphases] == ["01"]
    assert cursor.current_subphase is None and cursor.remaining_outline == ()
    assert cursor.phase_gate_status is PhaseGateStatus.READY
    assert cursor.completed_phases == ()
    assert cursor.active_contract is None
    assert _plan_ids(project) == ["01"]
    receipt = _receipt(project, "01")
    assert receipt.outcome is ReplanOutcome.REVISED
    assert receipt.unfinished_outline == ()
    # No Contract planning, no Implementer, and no extra Planner call for the empty remainder.
    assert project.counts() == (3, 1, 1)
    assert not project.txn_dir("02").exists()
    assert _state(project) is JitReplanState.NOT_APPLICABLE

    before = project.counts()
    again = _run(project)
    assert again.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert project.counts() == before


# ===========================================================================
# Scenarios E/F/G: refused candidates and Planner failures -- AC-04/09/11/15
# ===========================================================================


def _retitled_history() -> PhasePlan:
    plan = _phase_plan(("01", "02", "03"))
    first = plan.subphases[0].model_copy(update={"title": "Rewritten history"})
    return plan.model_copy(update={"subphases": (first, *plan.subphases[1:])})


def _rewritten_objective() -> PhasePlan:
    plan = _phase_plan(("01", "02", "03"))
    first = plan.subphases[0].model_copy(update={"objective": "A different objective."})
    return plan.model_copy(update={"subphases": (first, *plan.subphases[1:])})


def _dangling_dependency() -> dict[str, Any]:
    raw: dict[str, Any] = _phase_plan(("01", "05", "06")).model_dump(mode="json")
    raw["subphases"][2]["depends_on"] = ["99"]
    return raw


def _forward_dependency() -> dict[str, Any]:
    raw: dict[str, Any] = _phase_plan(("01", "05", "06")).model_dump(mode="json")
    raw["subphases"][1]["depends_on"] = ["06"]
    return raw


def _duplicate_ids() -> dict[str, Any]:
    raw: dict[str, Any] = _phase_plan(("01", "05", "06")).model_dump(mode="json")
    raw["subphases"][2]["subphase_id"] = "05"
    return raw


def _response_of(raw: dict[str, Any]) -> dict[str, object]:
    return {"stdout": json.dumps(raw), "returncode": 0}


_HISTORY_REWRITES: dict[str, dict[str, object]] = {
    "retitled-completed": _plan_response(_retitled_history()),
    "objective-rewritten": _plan_response(_rewritten_objective()),
    "completed-dropped": _replan("02", "03"),
    "completed-renamed": _replan("09", "02", "03"),
    "completed-reordered": _replan("02", "01", "03"),
    "phase-facts-changed": _plan_response(
        _phase_plan(("01", "02", "03")).model_copy(update={"title": "Hijacked phase"})
    ),
}

_INVALID_GRAPHS: dict[str, dict[str, object]] = {
    "dangling-dependency": _response_of(_dangling_dependency()),
    "forward-dependency": _response_of(_forward_dependency()),
    "duplicate-ids": _response_of(_duplicate_ids()),
}

_PLANNER_FAILURES: dict[str, dict[str, object]] = {
    "nonzero-exit": {"stdout": "", "returncode": 1},
    "malformed-output": {"stdout": "this is not json", "returncode": 0},
    "wrong-artifact": {"stdout": json.dumps(_contract_payload("05")), "returncode": 0},
}


def _assert_refused_and_nothing_authoritative(
    project: _Project,
    result: ProjectRunResult | None,
    *,
    cursor: ProjectCursor,
    plan_bytes: bytes,
    counts: tuple[int, int, int],
) -> None:
    assert result is not None
    assert result.disposition is ProjectRunDisposition.EXECUTION_FAILED
    assert result.detail is not None and result.detail.startswith("jit replan")
    assert project.cursor() == cursor
    assert _plan_path(project).read_bytes() == plan_bytes
    assert _receipt_names(project) == []
    assert _state(project) is JitReplanState.REPLAN_REQUIRED
    # The next Contract was not planned or frozen and no Implementer ran.
    assert load_active_subphase_contract(project.project_root, project.runtime_dir) is None
    assert project.counts() == counts
    assert not project.txn_dir("02").exists()


def _refusal_project(tmp_path: Path, bad: dict[str, object]) -> _Project:
    return _project(
        tmp_path,
        _script("01", bad, _replan("01", "05", "06"), "05", _replan("01", "05", "06"), "06"),
        ("01", "05", "06"),
    )


@pytest.mark.parametrize("name", sorted(_HISTORY_REWRITES))
def test_a_candidate_that_rewrites_completed_history_or_frozen_facts_is_rejected(
    tmp_path: Path, name: str
) -> None:
    project = _refusal_project(tmp_path, _HISTORY_REWRITES[name])
    _advance(project, 2)
    cursor, plan_bytes = project.cursor(), _plan_path(project).read_bytes()

    result = _step(project)

    _assert_refused_and_nothing_authoritative(
        project, result, cursor=cursor, plan_bytes=plan_bytes, counts=(3, 1, 1)
    )


@pytest.mark.parametrize("name", sorted(_INVALID_GRAPHS))
def test_a_candidate_with_an_invalid_dependency_graph_is_rejected(
    tmp_path: Path, name: str
) -> None:
    project = _refusal_project(tmp_path, _INVALID_GRAPHS[name])
    _advance(project, 2)
    cursor, plan_bytes = project.cursor(), _plan_path(project).read_bytes()

    result = _step(project)

    _assert_refused_and_nothing_authoritative(
        project, result, cursor=cursor, plan_bytes=plan_bytes, counts=(3, 1, 1)
    )


@pytest.mark.parametrize("name", sorted(_PLANNER_FAILURES))
def test_a_planner_failure_stops_progression_instead_of_executing_stale_work(
    tmp_path: Path, name: str
) -> None:
    project = _refusal_project(tmp_path, _PLANNER_FAILURES[name])
    _advance(project, 2)
    cursor, plan_bytes = project.cursor(), _plan_path(project).read_bytes()

    result = _step(project)

    _assert_refused_and_nothing_authoritative(
        project, result, cursor=cursor, plan_bytes=plan_bytes, counts=(3, 1, 1)
    )
    assert cursor.current_subphase == SubphaseId.model_validate("02")  # stale work not started


def test_an_unaccepted_candidate_is_not_authority_and_a_fresh_call_may_succeed(
    tmp_path: Path,
) -> None:
    project = _refusal_project(tmp_path, _HISTORY_REWRITES["completed-dropped"])
    _advance(project, 2)
    assert _step(project) is not None  # refused

    result = _run(project)

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == ["01", "05", "06"]
    # contract+tests 01, refused candidate, accepted candidate, then 05 and its replan, then 06.
    assert project.counts() == (9, 3, 3)
    assert _receipt_names(project) == ["run-01-01.json", "run-01-05.json"]


# ===========================================================================
# Scenario H: the planned-from repository state must be verified -- AC-03
# ===========================================================================


def test_a_tracked_modification_of_the_accepted_state_fails_closed_before_any_call(
    tmp_path: Path,
) -> None:
    project = _replace_project(tmp_path)
    _advance(project, 2)
    (project.worktree("01") / "feature_01.py").write_text("def answer() -> int:\n    return 99\n")
    cursor = project.cursor()

    result = _step(project)

    assert result is not None and result.disposition is ProjectRunDisposition.EXECUTION_FAILED
    assert project.counts() == (2, 1, 1)  # no replan Planner call
    assert project.cursor() == cursor
    assert _receipt_names(project) == []


def test_a_detached_accepted_worktree_fails_closed_before_any_call(tmp_path: Path) -> None:
    project = _replace_project(tmp_path)
    _advance(project, 2)
    _git(project.worktree("01"), "checkout", "--detach")

    result = _step(project)

    assert result is not None and result.disposition is ProjectRunDisposition.EXECUTION_FAILED
    assert project.counts() == (2, 1, 1)
    assert _receipt_names(project) == []


def test_a_missing_accepted_worktree_fails_closed_before_any_call(tmp_path: Path) -> None:
    project = _replace_project(tmp_path)
    _advance(project, 2)
    shutil.rmtree(project.worktree("01"))

    result = _step(project)

    assert result is not None and result.disposition is ProjectRunDisposition.EXECUTION_FAILED
    assert project.counts() == (2, 1, 1)
    assert _receipt_names(project) == []


def test_untracked_scratch_files_do_not_block_replanning(tmp_path: Path) -> None:
    project = _replace_project(tmp_path)
    _advance(project, 2)
    (project.worktree("01") / "scratch.tmp").write_text("left behind by verification\n")

    assert _step(project) is None

    assert _state(project) is JitReplanState.REPLAN_APPLIED


def test_a_planner_that_modifies_the_accepted_repository_cannot_have_its_candidate_accepted(
    tmp_path: Path,
) -> None:
    tampering = {
        **_replan("01", "05", "06"),
        "files": {"feature_01.py": "def answer() -> int:\n    return 99\n"},
    }
    project = _refusal_project(tmp_path, tampering)
    _advance(project, 2)
    cursor, plan_bytes = project.cursor(), _plan_path(project).read_bytes()

    result = _step(project)

    _assert_refused_and_nothing_authoritative(
        project, result, cursor=cursor, plan_bytes=plan_bytes, counts=(3, 1, 1)
    )


# ===========================================================================
# Crash boundaries -- AC-08/09/10
# ===========================================================================


def _crash_once(monkeypatch: pytest.MonkeyPatch, module: object, name: str) -> list[bool]:
    real = getattr(module, name)
    fired: list[bool] = []

    def patched(*args: object, **kwargs: object) -> object:
        if not fired:
            fired.append(True)
            raise _CrashError
        return real(*args, **kwargs)

    monkeypatch.setattr(module, name, patched)
    return fired


def test_a_crash_before_the_candidate_is_accepted_may_call_the_planner_again(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    same = _replan("01", "05", "06")
    project = _project(
        tmp_path,
        _script("01", same, same, "05", same, "06"),  # the first candidate is lost in the crash
        ("01", "05", "06"),
    )
    _advance(project, 2)
    cursor, plan_bytes = project.cursor(), _plan_path(project).read_bytes()
    real = jit_replan.invoke_planner_artifact
    fired: list[bool] = []

    def lose_the_answer(*args: object, **kwargs: object) -> object:
        result = real(*args, **kwargs)  # type: ignore[arg-type]
        if not fired:
            fired.append(True)
            raise _CrashError
        return result

    monkeypatch.setattr(jit_replan, "invoke_planner_artifact", lose_the_answer)
    with pytest.raises(_CrashError):
        _step(project)

    assert project.launches("planner") == 3
    assert _receipt_names(project) == []
    assert project.cursor() == cursor
    assert _plan_path(project).read_bytes() == plan_bytes
    assert _state(project) is JitReplanState.REPLAN_REQUIRED

    result = _run(project)

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert project.launches("planner") == 9  # exactly one extra, regenerated replan call
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == ["01", "05", "06"]


def test_a_crash_after_acceptance_before_publication_applies_the_receipt_without_a_planner(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _replace_project(tmp_path)
    _advance(project, 2)
    before = project.cursor()
    _crash_once(monkeypatch, jit_replan, "publish_phase_plan")

    with pytest.raises(_CrashError):
        _step(project)

    assert _receipt(project, "01").outcome is ReplanOutcome.REVISED  # durably accepted
    assert _plan_ids(project) == ["01", "02", "03"]  # nothing published yet
    assert project.cursor() == before
    assert _state(project) is JitReplanState.REPLAN_ACCEPTED
    assert project.launches("planner") == 3

    result = _run(project)

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == ["01", "05", "06"]
    assert project.counts() == (8, 3, 3)  # the accepted replan was never decided again


def test_a_crash_between_plan_and_cursor_publication_is_completed_on_restart(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _replace_project(tmp_path)
    _advance(project, 2)
    before = project.cursor()
    _crash_once(monkeypatch, jit_replan, "revise_cursor_unfinished_outline")

    with pytest.raises(_CrashError):
        _step(project)

    assert _plan_ids(project) == ["01", "05", "06"]  # outline published ...
    assert project.cursor() == before  # ... but the cursor still disagrees
    assert _state(project) is JitReplanState.REPLAN_ACCEPTED
    with pytest.raises(ProjectOrchestrationError, match="diverges"):
        step_project_run(
            project.runtime,
            request_factory=project.factory,
            retry_budget=_budget(3),
            planning_timeout_seconds=60.0,
            jit_replan=False,
        )  # the 11.2 path alone refuses to run on a disagreeing outline

    result = _run(project)

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == ["01", "05", "06"]
    assert project.counts() == (8, 3, 3)


def test_a_failed_outline_publication_keeps_the_previous_plan_and_is_recoverable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _replace_project(tmp_path)
    _advance(project, 2)
    cursor, plan_bytes = project.cursor(), _plan_path(project).read_bytes()
    real = planning_store._replace_atomically

    def fail(source: Path, target: Path) -> None:
        raise OSError("simulated publication failure")

    monkeypatch.setattr(planning_store, "_replace_atomically", fail)
    with pytest.raises(PlanningStoreError):
        _step(project)
    monkeypatch.setattr(planning_store, "_replace_atomically", real)

    assert _plan_path(project).read_bytes() == plan_bytes
    assert project.cursor() == cursor
    assert _state(project) is JitReplanState.REPLAN_ACCEPTED

    assert _run(project).disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert project.counts() == (8, 3, 3)


def test_a_crash_after_replan_but_before_the_next_contract_freeze_does_not_replan_again(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _replace_project(tmp_path)
    _advance(project, 2)
    _crash_once(monkeypatch, project_orchestrator, "create_subphase_contract_candidate")
    assert _step(project) is None  # the replan; accepted and applied
    with pytest.raises(_CrashError):
        _step(project)  # planning the next Contract dies before any Planner call

    assert _state(project) is JitReplanState.REPLAN_APPLIED
    assert project.launches("planner") == 3

    result = _run(project)

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert project.counts() == (8, 3, 3)


def test_a_crash_after_the_next_contract_froze_keeps_the_replan_and_binds_it(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _replace_project(tmp_path)
    _advance(project, 3)
    _crash_once(monkeypatch, project_orchestrator, "bind_frozen_contract")

    with pytest.raises(_CrashError):
        _step(project)  # Contract 05 frozen but not bound

    assert project.cursor().active_contract is None
    frozen = load_active_subphase_contract(project.project_root, project.runtime_dir)
    assert frozen is not None and frozen.subphase_id.root == "05"
    assert _state(project) is JitReplanState.REPLAN_APPLIED
    assert project.launches("planner") == 4

    result = _run(project)

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert project.counts() == (8, 3, 3)  # no second replan, no second Contract plan for 05


# ===========================================================================
# AC-06: an active frozen Contract is never revised away
# ===========================================================================


def test_a_replan_is_refused_while_a_bound_contract_is_active(tmp_path: Path) -> None:
    project = _replace_project(tmp_path)
    _advance(project, 4)  # plan 01, run 01, replan, plan + bind 05
    replan_receipt_path(project.runtime_dir, project.run_id("01")).unlink()
    assert _state(project) is JitReplanState.REPLAN_REQUIRED
    cursor, before = project.cursor(), project.counts()
    plan_bytes = _plan_path(project).read_bytes()

    with pytest.raises(JitReplanError):
        _direct_replan(project, "01")

    assert project.counts() == before
    assert project.cursor() == cursor
    assert _plan_path(project).read_bytes() == plan_bytes
    active = load_active_subphase_contract(project.project_root, project.runtime_dir)
    assert active is not None and active.subphase_id.root == "05"


def test_an_unbound_frozen_contract_blocks_an_outstanding_replan_instead_of_being_rewritten(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _replace_project(tmp_path)
    _advance(project, 3)
    _crash_once(monkeypatch, project_orchestrator, "bind_frozen_contract")
    with pytest.raises(_CrashError):
        _step(project)
    replan_receipt_path(project.runtime_dir, project.run_id("01")).unlink()
    before = project.counts()

    with pytest.raises(ProjectOrchestrationError):
        _step(project)

    assert project.counts() == before
    frozen = load_active_subphase_contract(project.project_root, project.runtime_dir)
    assert frozen is not None and frozen.subphase_id.root == "05"


# ===========================================================================
# AC-16/18: only canonical completion triggers a replan
# ===========================================================================


def test_a_reworked_subphase_replans_only_on_its_eventual_completion(tmp_path: Path) -> None:
    same = _replan("01", "02", "03")
    project = _project(
        tmp_path,
        _script("01", same, "02", same, "03"),
        ("01", "02", "03"),
        implementer=[
            _impl_response("01"),
            _impl_response("02", verbose=True),
            _impl_response("02"),
            _impl_response("03"),
        ],
        reviewer=[
            _review_response("01"),
            _review_response("02", attempt=1, verdict="rework"),
            _review_response("02", attempt=2),
            _review_response("03"),
        ],
    )

    result = _run(project)

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert _receipt_names(project) == ["run-01-01.json", "run-01-02.json"]
    assert project.counts() == (8, 4, 4)  # the retry itself called no replan


def test_a_halted_subphase_does_not_replan(tmp_path: Path) -> None:
    same = _replan("01", "02", "03")
    project = _project(
        tmp_path,
        _script("01", same, "02", same, "03"),
        ("01", "02", "03"),
        implementer=[_impl_response("01"), _process_failure_response()],
    )

    result = _run(project)

    assert result.disposition is ProjectRunDisposition.HALTED
    assert _receipt_names(project) == ["run-01-01.json"]
    before = project.counts()
    for _ in range(2):
        assert _run(project).disposition is ProjectRunDisposition.HALTED
    assert project.counts() == before
    assert _receipt_names(project) == ["run-01-01.json"]


def test_a_human_required_stop_does_not_replan_and_no_model_decides_it(tmp_path: Path) -> None:
    same = _replan("01", "02", "03")
    project = _project(
        tmp_path,
        _script("01", same, "02", same, "03"),
        ("01", "02", "03"),
        implementer=[
            _impl_response("01"),
            _implementer_blocked_response(
                category=EscalationCategory.REQUIREMENT_AMBIGUITY,
                requested_authority=EscalationAuthority.HUMAN,
            ),
        ],
    )

    result = _run(project)

    assert result.disposition is ProjectRunDisposition.HUMAN_REQUIRED
    assert _receipt_names(project) == ["run-01-01.json"]
    before = project.counts()
    assert _run(project).disposition is ProjectRunDisposition.HUMAN_REQUIRED
    assert project.counts() == before


def test_a_completed_but_unrecorded_subphase_replans_only_after_it_is_recorded(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    same = _replan("01", "02", "03")
    project = _project(tmp_path, _script("01", same, "02", same, "03"), ("01", "02", "03"))
    _crash_recording_once(monkeypatch, "02")

    with pytest.raises(_CrashError):
        _run(project)

    assert project.state("02") is WorkflowState.SUBPHASE_COMPLETE
    assert _receipt_names(project) == ["run-01-01.json"]  # nothing for the unrecorded completion
    assert project.launches("planner") == 5

    result = _run(project)

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert _receipt_names(project) == ["run-01-01.json", "run-01-02.json"]
    assert project.counts() == (8, 3, 3)


# ===========================================================================
# Prompt, structure, and authority preservation
# ===========================================================================


def test_the_replan_prompt_separates_immutable_history_from_the_provisional_suffix() -> None:
    plan = _phase_plan(("01", "02", "03"))
    master = MasterPlan(
        project_id=ProjectId.model_validate("lockstep"),
        title="Lockstep",
        objective="Build the control plane.",
        phases=(plan,),
    )
    cursor = ProjectCursor(
        project_id=ProjectId.model_validate("lockstep"),
        master_plan_digest="a" * 64,
        revision=4,
        current_phase=PhaseId.model_validate("01"),
        current_subphase=SubphaseId.model_validate("02"),
        completed_subphases=(
            CompletedSubphase(
                phase_id=PhaseId.model_validate("01"),
                subphase_id=SubphaseId.model_validate("01"),
                run_id=RunId.model_validate("run-01-01"),
                contract_digest="b" * 64,
            ),
        ),
        remaining_outline=plan.subphases[2:],
    )
    basis = ReplanBasis(
        phase_id=PhaseId.model_validate("01"),
        subphase_id=SubphaseId.model_validate("01"),
        run_id=RunId.model_validate("run-01-01"),
        contract_digest="b" * 64,
        branch="lockstep/run/run-01-01",
        commit="c" * 40,
    )

    prompt = build_jit_replan_prompt(master, plan, cursor, basis)

    completed = "Completed Sub-phases (immutable):"
    unfinished = "Unfinished provisional outline:"
    repository = "Accepted repository basis:"
    assert prompt.index(completed) < prompt.index(unfinished) < prompt.index(repository)
    history = prompt.split(completed)[1].split(unfinished)[0]
    suffix = prompt.split(unfinished)[1].split(repository)[0]
    assert '"01"' in history and '"02"' not in history and '"03"' not in history
    assert '"02"' in suffix and '"03"' in suffix and "Outline 01" not in suffix
    assert "c" * 40 in prompt.split(repository)[1]
    assert "lockstep/run/run-01-01" in prompt.split(repository)[1]
    assert "PhasePlan" in prompt


def _code_tokens(source: str) -> set[str]:
    tree = ast.parse(source)
    docstrings: set[int] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Module | ast.ClassDef | ast.FunctionDef | ast.AsyncFunctionDef):
            first = node.body[0] if node.body else None
            if (
                isinstance(first, ast.Expr)
                and isinstance(first.value, ast.Constant)
                and isinstance(first.value.value, str)
            ):
                docstrings.add(id(first.value))
    tokens: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Name):
            tokens.add(node.id)
        elif isinstance(node, ast.Attribute):
            tokens.add(node.attr)
        elif isinstance(node, ast.alias):
            tokens.add(node.name)
        elif isinstance(node, ast.arg | ast.keyword) and node.arg is not None:
            tokens.add(node.arg)
        elif (
            isinstance(node, ast.Constant)
            and isinstance(node.value, str)
            and id(node) not in docstrings
        ):
            tokens.add(node.value)
    return tokens


def _imported_names(source: str) -> set[str]:
    names: set[str] = set()
    for node in ast.walk(ast.parse(source)):
        if isinstance(node, ast.ImportFrom | ast.Import):
            names.update(alias.name for alias in node.names)
    return names


def test_replanning_depends_on_no_provider_conversation_state() -> None:
    tokens = _code_tokens((_SRC / "jit_replan.py").read_text())

    for token in tokens:
        lowered = token.lower()
        assert "session" not in lowered
        assert "thread" not in lowered
        assert "resume" not in lowered
        assert "conversation" not in lowered


def test_the_replan_module_composes_planning_machinery_and_owns_no_execution_or_progress() -> None:
    source = (_SRC / "jit_replan.py").read_text()
    imported = _imported_names(source)

    assert {
        "invoke_planner_artifact",
        "publish_phase_plan",
        "revise_cursor_unfinished_outline",
        "load_project_cursor",
        "inspect_repository",
    } <= imported
    forbidden = {
        "invoke_agent",
        "run_process",
        "commit_exact_paths",
        "create_run_worktree",
        "append_event",
        "write_state",
        "record_execution_event",
        "freeze_subphase_contract",
        "create_subphase_contract_candidate",
        "bind_frozen_contract",
        "record_completed_subphase",
        "retire_active_subphase_contract",
        "run_single_subphase_transaction_with_retry_checkpoint",
        "resume_single_subphase_transaction",
        "revise_cursor_outline",
        "project_orchestrator",
    }
    assert imported.isdisjoint(forbidden)
    assert "cursor.json" not in source
    tokens = _code_tokens(source)
    assert "PHASE_COMPLETE" not in tokens and "PHASE_INTEGRATION_GATE" not in tokens
    assert "completed_phases" not in tokens


def test_the_orchestrator_delegates_replanning_instead_of_duplicating_it() -> None:
    source = (_SRC / "project_orchestrator.py").read_text()
    imported = _imported_names(source)

    assert {"run_jit_replan", "jit_replan_state"} <= imported
    assert "create_phase_plan_candidate" not in imported
    assert "invoke_planner_artifact" not in imported
    assert "revise_cursor_unfinished_outline" not in imported


def test_with_the_explicit_opt_out_the_orchestrator_never_replans(tmp_path: Path) -> None:
    project = _make_project(tmp_path, sids=("01", "02", "03"))

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert _receipt_names(project) == []
    assert not (project.runtime_dir / "planning" / "replans").exists()
    assert project.counts() == (6, 3, 3)  # the 11.2 behavior: no outline Planner at all


def _run_by_default(project: _Project) -> ProjectRunResult:
    """The ordinary Phase-run call: no ``jit_replan`` argument at all."""
    return run_project_phase(
        project.runtime,
        request_factory=project.factory,
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
    )


def test_the_default_phase_run_replans_after_a_nonfinal_subphase(tmp_path: Path) -> None:
    project = _replace_project(tmp_path)

    result = _run_by_default(project)

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert _receipt_names(project) == ["run-01-01.json", "run-01-05.json"]
    assert _plan_ids(project) == ["01", "05", "06"]  # the revised outline was applied
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == ["01", "05", "06"]
    assert project.counts() == (8, 3, 3)  # a replan Planner call after each nonfinal Sub-phase


def test_explicit_opt_out_keeps_the_fixed_outline(tmp_path: Path) -> None:
    project = _project(tmp_path, _script("01", "02", "03"), ("01", "02", "03"))

    result = run_project_phase(
        project.runtime,
        request_factory=project.factory,
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
        jit_replan=False,
    )

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert _receipt_names(project) == []
    assert _plan_ids(project) == ["01", "02", "03"]
    assert project.counts() == (6, 3, 3)  # no JIT Planner invocation


def test_the_default_phase_run_does_not_replan_after_the_final_subphase(tmp_path: Path) -> None:
    project = _project(tmp_path, _script("01"), ("01",), master=("01",))

    result = _run_by_default(project)

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert _receipt_names(project) == []
    assert project.counts() == (2, 1, 1)  # contract plan + tests only; no final replan


def test_cursor_errors_stay_distinct_from_replan_errors() -> None:
    assert not issubclass(JitReplanError, ProjectCursorError)
    assert not issubclass(JitReplanError, ProjectOrchestrationError)
