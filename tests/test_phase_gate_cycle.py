"""Phase 11.5: the Phase-gate cycle -- PASS completion, bounded remediation, rerun, and crashes.

``run_phase_gate_cycle`` composes one audit-only gate attempt with the host's PASS / FAIL
transitions: a PASS completes the Phase and advances the cursor deterministically; a FAIL has a
fresh Planner create exactly one remediation Sub-phase, which runs through the ordinary 11.2-11.4
machinery, and the gate then reruns on the new accepted basis, up to an explicit finite bound.

Everything runs the real production code against fake provider executables, a real Git source
repository, real worktrees, the real planning/cursor stores, and real subprocess gate commands.
No real Claude/Codex account, network, or model inference is used.

Baseline classification: every test in this module is RED at entry (``lockstep.phase_gate`` and
``lockstep.phase_gate_cycle`` do not exist).
"""

from __future__ import annotations

import inspect
import json
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest
from phase_gate_support import (
    CRITERIA,
    GateProject,
    crash_once,
    fail_once_command,
    failing_command,
    file_bytes,
    finding,
    gate_review_response,
    git_head,
    make_gate_project,
    mutating_command,
    passing_command,
    phase_plan,
    record_calls,
    remediation_chain_response,
    remediation_plan_response,
    replan_response,
    review_response,
    run_git_text,
    standard_project,
    subjects,
    tracked_state,
    unit_script,
)
from test_project_orchestrator import _impl_response
from test_supervisor_resume_execution import _budget, _implementer_blocked_response

import lockstep.phase_gate as phase_gate
import lockstep.phase_gate_cycle as phase_gate_cycle
from lockstep.domain import PhaseId, SubphaseId
from lockstep.escalation import EscalationAuthority, EscalationCategory
from lockstep.metrics import project_runtime_metrics
from lockstep.persistence import read_state
from lockstep.phase_gate import (
    PhaseGateAttemptDisposition,
    PhaseGateError,
    PhaseGateEventKind,
    PhaseGateExecutionFailure,
    PhaseGateRefusal,
    PhaseGateVerdict,
    list_phase_gate_attempts,
    load_phase_gate_basis,
    load_phase_gate_decision,
    load_phase_gate_evidence,
    load_remediation_receipt,
    read_phase_gate_events,
)
from lockstep.phase_gate_cycle import (
    PhaseGateCycleDisposition,
    PhaseGateCycleResult,
    complete_phase_from_gate_pass,
    run_phase_gate_cycle,
)
from lockstep.planning_store import load_frozen_master_plan, load_phase_plan
from lockstep.project_cursor import PhaseGateStatus
from lockstep.project_orchestrator import (
    ProjectOrchestrationError,
    ProjectRunDisposition,
    run_project_phase,
    step_project_run,
)
from lockstep.state import WorkflowState

_P1 = PhaseId.model_validate("01")
_P2 = PhaseId.model_validate("02")


def _cycle(project: GateProject, *, remediations: int = 1, budget: int = 3) -> PhaseGateCycleResult:
    return run_phase_gate_cycle(
        project.runtime,
        max_gate_remediations=remediations,
        request_factory=project.factory,
        retry_budget=_budget(budget),
        planning_timeout_seconds=60.0,
    )


def _two_commands(marker: Path) -> tuple[tuple[str, ...], ...]:
    return (passing_command(marker, "first"), passing_command(marker, "second"))


def _failing(marker: Path) -> tuple[tuple[str, ...], ...]:
    return (failing_command(marker, "gate"),)


def _kinds(project: GateProject, phase: PhaseId = _P1) -> list[PhaseGateEventKind]:
    return [e.kind for e in read_phase_gate_events(project.runtime_dir, phase)]


def _cursor_bytes(project: GateProject) -> bytes:
    return (project.runtime_dir / "project" / "cursor.json").read_bytes()


def _master_path(project: GateProject) -> Path:
    return project.project_root / ".lockstep" / "project" / "master-plan.json"


def _receipt_names(project: GateProject) -> list[str]:
    pattern = "phase-gates/*/attempt-*/remediation.json"
    return sorted(
        str(p.relative_to(project.runtime_dir)) for p in project.runtime_dir.glob(pattern)
    )


def _ready(project: GateProject) -> GateProject:
    assert project.run_phase().disposition is ProjectRunDisposition.PHASE_GATE_READY
    return project


def _txn_bytes(project: GateProject) -> dict[str, dict[str, bytes]]:
    return {sid: file_bytes(project.txn_dir("01", sid)) for sid in ("01", "02")}


# ===========================================================================
# Public shape
# ===========================================================================


def test_public_api_exports_expected_names() -> None:
    assert set(phase_gate_cycle.__all__) == {
        "PhaseGateCycleDisposition",
        "PhaseGateCycleResult",
        "build_gate_remediation_prompt",
        "complete_phase_from_gate_pass",
        "run_phase_gate_cycle",
    }


def test_the_cycle_disposition_vocabulary_is_typed() -> None:
    assert {d.name for d in PhaseGateCycleDisposition} == {
        "PHASE_COMPLETE",
        "PROJECT_COMPLETE",
        "GATE_REMEDIATION_EXHAUSTED",
        "EXECUTION_FAILED",
        "HALTED",
        "HUMAN_REQUIRED",
        "RECOVERY_REQUIRED",
    }


def test_the_remediation_bound_is_a_required_keyword_with_no_default() -> None:
    parameter = inspect.signature(run_phase_gate_cycle).parameters["max_gate_remediations"]

    assert parameter.kind is inspect.Parameter.KEYWORD_ONLY
    assert parameter.default is inspect.Parameter.empty


@pytest.mark.parametrize("bound", [-1, True, False, 1.5, None, "2"])
def test_an_invalid_remediation_bound_is_refused_before_anything_happens(
    tmp_path: Path, bound: Any
) -> None:
    project = standard_project(tmp_path, planner_tail=[], gate_commands=_two_commands)

    with pytest.raises(PhaseGateError) as refused:
        run_phase_gate_cycle(
            project.runtime,
            max_gate_remediations=bound,
            request_factory=project.factory,
            retry_budget=_budget(3),
            planning_timeout_seconds=60.0,
        )

    assert refused.value.refusal is PhaseGateRefusal.INVALID_REMEDIATION_BOUND
    assert not (project.runtime_dir / "project").exists()
    assert project.counts() == (0, 0, 0)


def test_the_ordinary_phase_runner_keeps_jit_replanning_on_by_default() -> None:
    for function in (run_project_phase, step_project_run):
        assert inspect.signature(function).parameters["jit_replan"].default is True


# ===========================================================================
# Scenario A: clean PASS completes the Phase and starts the next one
# ===========================================================================


@pytest.fixture(scope="module")
def advance(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    project = standard_project(
        tmp_path_factory.mktemp("advance"),
        phases={"01": ("01", "02"), "02": ("11",)},
        criteria={"01": CRITERIA},
        gate_commands=_two_commands,
        planner_tail=[gate_review_response("01", "pass"), *unit_script("02", "11")],
        extra_units=[("02", "11")],
    )
    _ready(project)
    worktree = project.worktree("01", "02")
    before = SimpleNamespace(
        tracked=tracked_state(worktree),
        txn=_txn_bytes(project),
        counts=project.counts(),
        metrics={
            sid: project_runtime_metrics(project.txn_dir("01", sid)).model_dump_json()
            for sid in ("01", "02")
        },
        tip=git_head(worktree, project.branch("01", "02")),
        revision=project.cursor().revision,
    )
    result = _cycle(project)
    return SimpleNamespace(project=project, before=before, result=result)


def test_a_clean_pass_completes_the_phase(advance: SimpleNamespace) -> None:
    result = advance.result

    assert result.disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    assert [a.disposition for a in result.attempts] == [PhaseGateAttemptDisposition.PASSED]
    assert result.remediations == ()
    assert result.remediation_result is None


def test_only_the_pass_appends_the_phase_and_the_host_derives_the_next_one(
    advance: SimpleNamespace,
) -> None:
    cursor = advance.project.cursor()

    assert cursor.completed_phases == (_P1,)
    assert cursor.current_phase == _P2
    assert cursor.current_subphase == SubphaseId.model_validate("11")
    assert cursor.remaining_outline == ()
    assert cursor.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING
    assert cursor.active_contract is None
    assert cursor.revision == advance.before.revision + 1
    assert [e.subphase_id.root for e in cursor.completed_subphases] == ["01", "02"]
    assert advance.result.cursor == cursor


def test_the_next_phase_starts_from_its_frozen_outline_with_only_its_head_current(
    advance: SimpleNamespace,
) -> None:
    project = advance.project
    master = load_frozen_master_plan(project.project_root)
    assert master is not None

    assert load_phase_plan(project.project_root, project.runtime_dir) == master.phases[1]
    assert not (project.runtime_dir / "contracts" / "active.json").exists()


def test_a_pass_performs_no_production_work(advance: SimpleNamespace) -> None:
    project, before = advance.project, advance.before
    planner, implementer, reviewer = before.counts

    assert project.counts() == (planner + 1, implementer, reviewer)
    assert tracked_state(project.worktree("01", "02")) == before.tracked
    assert git_head(project.worktree("01", "02"), project.branch("01", "02")) == before.tip
    assert _receipt_names(project) == []


def test_the_gate_events_bind_the_attempt_and_end_in_phase_complete(
    advance: SimpleNamespace,
) -> None:
    project = advance.project
    events = read_phase_gate_events(project.runtime_dir, _P1)

    assert [e.kind for e in events] == [
        PhaseGateEventKind.PHASE_GATE_STARTED,
        PhaseGateEventKind.PHASE_GATE_PASSED,
        PhaseGateEventKind.PHASE_COMPLETE,
    ]
    assert {e.gate_attempt for e in events} == {1}
    assert {e.basis_commit for e in events} == {advance.before.tip}
    assert {e.phase_id for e in events} == {_P1}
    assert not project.gate_dir("02").exists()


def test_gate_evidence_leaves_every_child_transaction_journal_and_metric_unchanged(
    advance: SimpleNamespace,
) -> None:
    project, before = advance.project, advance.before

    assert _txn_bytes(project) == before.txn
    for sid in ("01", "02"):
        after = project_runtime_metrics(project.txn_dir("01", sid)).model_dump_json()
        assert after == before.metrics[sid]
    assert not (project.runtime_dir / "events.jsonl").exists()


def test_the_cycle_has_no_further_gate_work_for_a_phase_that_is_pending_again(
    advance: SimpleNamespace,
) -> None:
    project = advance.project
    before = _cursor_bytes(project)

    with pytest.raises(PhaseGateError) as refused:
        _cycle(project)

    assert refused.value.refusal is PhaseGateRefusal.NOT_READY
    assert _cursor_bytes(project) == before


def test_the_next_phase_then_runs_through_the_ordinary_orchestrator_from_the_accepted_branch(
    tmp_path: Path,
) -> None:
    project = standard_project(
        tmp_path,
        phases={"01": ("01", "02"), "02": ("11",)},
        criteria={"01": CRITERIA},
        gate_commands=_two_commands,
        planner_tail=[gate_review_response("01", "pass"), *unit_script("02", "11")],
        extra_units=[("02", "11")],
    )
    _ready(project)
    basis_tip = git_head(project.worktree("01", "02"), project.branch("01", "02"))
    assert _cycle(project).disposition is PhaseGateCycleDisposition.PHASE_COMPLETE

    result = project.run_phase()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    cursor = project.cursor()
    assert [(e.phase_id.root, e.subphase_id.root) for e in cursor.completed_subphases] == [
        ("01", "01"),
        ("01", "02"),
        ("02", "11"),
    ]
    assert cursor.completed_phases == (_P1,)
    assert cursor.current_phase == _P2
    assert cursor.phase_gate_status is PhaseGateStatus.READY
    # The new Phase's branch is rooted at the previous Phase's accepted tip.
    worktree = project.worktree("02", "11")
    run_git_text(worktree, "merge-base", "--is-ancestor", basis_tip, "HEAD")
    state = read_state(project.txn_dir("02", "11") / "state.json")
    assert state is not None and state.workflow_state is WorkflowState.SUBPHASE_COMPLETE


# ===========================================================================
# Scenario J: the final Phase of the Master Plan
# ===========================================================================


@pytest.fixture(scope="module")
def final(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    project = standard_project(
        tmp_path_factory.mktemp("final"),
        phases={"01": ("01",)},
        gate_commands=_two_commands,
        planner_tail=[],
    )
    _ready(project)
    return SimpleNamespace(project=project, result=_cycle(project))


def test_passing_the_final_phase_leaves_a_valid_project_complete_cursor(
    final: SimpleNamespace,
) -> None:
    cursor = final.project.cursor()  # reloads and re-validates against the frozen Master Plan

    assert final.result.disposition is PhaseGateCycleDisposition.PROJECT_COMPLETE
    assert cursor.current_phase is None
    assert cursor.completed_phases == (_P1,)
    assert cursor.phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE
    assert cursor.current_subphase is None
    assert cursor.remaining_outline == ()
    assert cursor.active_contract is None


def test_a_complete_project_does_no_further_gate_work(final: SimpleNamespace) -> None:
    project = final.project
    rows, counts, before = project.markers(), project.counts(), _cursor_bytes(project)
    events = read_phase_gate_events(project.runtime_dir, _P1)

    again = _cycle(project)

    assert again.disposition is PhaseGateCycleDisposition.PROJECT_COMPLETE
    assert again.attempts == ()
    assert project.markers() == rows
    assert project.counts() == counts
    assert _cursor_bytes(project) == before
    assert read_phase_gate_events(project.runtime_dir, _P1) == events


def test_the_ordinary_orchestrator_refuses_to_run_a_complete_project(
    final: SimpleNamespace,
) -> None:
    with pytest.raises(ProjectOrchestrationError):
        final.project.run_phase()


def test_the_final_pass_emits_phase_complete_exactly_once(final: SimpleNamespace) -> None:
    assert _kinds(final.project) == [
        PhaseGateEventKind.PHASE_GATE_STARTED,
        PhaseGateEventKind.PHASE_GATE_PASSED,
        PhaseGateEventKind.PHASE_COMPLETE,
    ]


# ===========================================================================
# Scenarios B / D: deterministic FAIL -> one remediation -> ordinary execution -> rerun -> PASS
# ===========================================================================


@pytest.fixture(scope="module")
def remediated(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    root = tmp_path_factory.mktemp("remediated")
    flag = root / "gate-fail-once.flag"
    planner = [
        *unit_script("01", "01"),
        replan_response(phase_plan("01", ("01", "02"), criteria=CRITERIA)),
        *unit_script("01", "02"),
        remediation_plan_response("01", ("01", "02"), "03", criteria=CRITERIA),
        *unit_script("01", "03"),
        gate_review_response("01", "pass"),
    ]
    project = make_gate_project(
        root,
        phases={"01": ("01", "02")},
        criteria={"01": CRITERIA},
        planner=planner,
        implementer=[_impl_response(sid) for sid in ("01", "02", "03")],
        reviewer=[review_response("01", sid) for sid in ("01", "02", "03")],
        gate_commands=lambda marker: (
            fail_once_command(marker, flag, "gate"),
            passing_command(marker, "smoke"),
        ),
    )
    assert project.run_phase(jit=True).disposition is ProjectRunDisposition.PHASE_GATE_READY
    master_before = _master_path(project).read_bytes()
    worktree_two = project.worktree("01", "02")
    before = SimpleNamespace(
        tracked=tracked_state(worktree_two),
        subjects=subjects(worktree_two),
        tip=git_head(worktree_two, project.branch("01", "02")),
        counts=project.counts(),
    )
    snapshots: list[dict[str, bytes]] = []
    with pytest.MonkeyPatch.context() as patch:
        remediation_prompts = record_calls(patch, phase_gate_cycle, "invoke_planner_artifact")
        review_calls = record_calls(patch, phase_gate, "invoke_planner_review")
        original = phase_gate_cycle.run_project_phase
        phase_runs: list[dict[str, Any]] = []

        def spy(*args: Any, **kwargs: Any) -> Any:
            phase_runs.append(kwargs)
            snapshots.append(file_bytes(project.attempt_dir("01", 1)))
            return original(*args, **kwargs)

        patch.setattr(phase_gate_cycle, "run_project_phase", spy)
        result = _cycle(project)
    return SimpleNamespace(
        project=project,
        result=result,
        before=before,
        master_before=master_before,
        prompts=remediation_prompts,
        reviews=review_calls,
        phase_runs=phase_runs,
        attempt1_at_remediation=snapshots,
    )


def test_a_failed_gate_leads_to_one_remediation_and_a_passing_rerun(
    remediated: SimpleNamespace,
) -> None:
    result = remediated.result

    assert result.disposition is PhaseGateCycleDisposition.PROJECT_COMPLETE
    assert [(a.gate_attempt, a.disposition) for a in result.attempts] == [
        (1, PhaseGateAttemptDisposition.FAILED),
        (2, PhaseGateAttemptDisposition.PASSED),
    ]
    assert result.remediations == (SubphaseId.model_validate("03"),)


def test_the_failure_is_durable_and_asked_no_model_about_the_failed_command(
    remediated: SimpleNamespace,
) -> None:
    project = remediated.project
    first = load_phase_gate_decision(project.runtime_dir, _P1, 1)

    assert first is not None
    assert first.outcome is PhaseGateVerdict.FAIL
    assert first.deterministic_passed is False
    assert first.review is None
    evidence = load_phase_gate_evidence(project.runtime_dir, _P1, 1)
    assert evidence is not None
    assert [c.exit_code for c in evidence.commands] == [3]
    assert "integration boom" in evidence.commands[0].stdout
    assert len(remediated.reviews) == 1  # only attempt 2 had a semantic review


def test_exactly_one_remediation_subphase_is_accepted_for_the_failure(
    remediated: SimpleNamespace,
) -> None:
    project = remediated.project
    receipt = load_remediation_receipt(project.runtime_dir, _P1, 1)

    assert receipt is not None
    assert receipt.outline.subphase_id == SubphaseId.model_validate("03")
    assert receipt.outline.depends_on == (SubphaseId.model_validate("02"),)
    assert receipt.phase_id == _P1
    assert receipt.gate_attempt == 1
    assert receipt.basis_commit == remediated.before.tip
    assert receipt.project_id == project.cursor().project_id
    assert receipt.master_plan_digest == project.cursor().master_plan_digest
    assert _receipt_names(project) == ["phase-gates/01/attempt-1/remediation.json"]
    published = load_phase_plan(project.project_root, project.runtime_dir)
    assert published is not None
    assert [o.subphase_id.root for o in published.subphases] == ["01", "02", "03"]


def test_the_remediation_planner_receives_the_frozen_authority_and_the_gate_evidence(
    remediated: SimpleNamespace,
) -> None:
    project = remediated.project
    call = remediated.prompts[0]
    prompt: str = call["prompt"]

    for label in (
        "Frozen Master Plan:",
        "Target phase_id:",
        "Completed Sub-phases (immutable):",
        "Accepted repository basis:",
        "Phase gate failure evidence:",
        "Remediation subphase_id:",
    ):
        assert label in prompt
    assert "The completed features integrate." in prompt  # frozen Phase authority
    assert remediated.before.tip in prompt  # the accepted basis
    assert "integration boom" in prompt  # deterministic gate evidence
    assert "evidence, not requirements" in prompt
    assert "exactly one" in prompt
    assert "03" in prompt.split("Remediation subphase_id:")[1].splitlines()[1]
    # The fresh Planner inspects the accepted worktree, not the source checkout.
    assert call["args"][0].project_root == project.worktree("01", "02").resolve()


def test_the_gate_itself_changed_no_code_and_made_no_commit(remediated: SimpleNamespace) -> None:
    project, before = remediated.project, remediated.before
    worktree_two = project.worktree("01", "02")

    assert tracked_state(worktree_two) == before.tracked
    assert subjects(worktree_two) == before.subjects
    # Exactly the three Sub-phases' own test + feature commits, nothing from the gate.
    assert subjects(project.worktree("01", "03")) == [
        "feat(feature-03): implement answer",
        "test(feature-03): freeze answer expectation",
        *before.subjects,
    ]


def test_the_remediation_ran_through_the_ordinary_contract_test_implement_review_path(
    remediated: SimpleNamespace,
) -> None:
    project = remediated.project
    planner, implementer, reviewer = remediated.before.counts

    # Contract plan + tests (2), one Implementer, one Sub-phase Reviewer, one gate review (2nd).
    assert project.counts() == (planner + 1 + 2 + 1, implementer + 1, reviewer + 1)
    state = read_state(project.txn_dir("01", "03") / "state.json")
    assert state is not None and state.workflow_state is WorkflowState.SUBPHASE_COMPLETE
    assert len(list((project.runtime_dir / "contracts" / "history").iterdir())) == 3
    cursor = project.cursor()
    last = cursor.completed_subphases[-1]
    assert (last.subphase_id.root, last.run_id) == ("03", project.run_id("01", "03"))
    assert [e.subphase_id.root for e in cursor.completed_subphases] == ["01", "02", "03"]


def test_the_remediation_started_from_the_accepted_branch_via_the_ordinary_runner(
    remediated: SimpleNamespace,
) -> None:
    project = remediated.project

    run_git_text(
        project.worktree("01", "03"), "merge-base", "--is-ancestor", remediated.before.tip, "HEAD"
    )
    assert len(remediated.phase_runs) == 1
    assert remediated.phase_runs[0]["request_factory"] is project.factory


def test_jit_replanning_is_not_used_to_invent_work_around_the_remediation(
    remediated: SimpleNamespace,
) -> None:
    project = remediated.project
    replans = sorted(p.name for p in (project.runtime_dir / "planning" / "replans").iterdir())

    assert remediated.phase_runs[0]["jit_replan"] is False
    assert replans == ["run-01-01.json"]  # only the ordinary pre-gate replan ever ran


def test_the_rerun_is_a_new_numbered_attempt_on_the_remediated_basis(
    remediated: SimpleNamespace,
) -> None:
    project = remediated.project
    first = load_phase_gate_basis(project.runtime_dir, _P1, 1)
    second = load_phase_gate_basis(project.runtime_dir, _P1, 2)

    assert list_phase_gate_attempts(project.runtime_dir, _P1) == (1, 2)
    assert first is not None and second is not None
    assert first.commit == remediated.before.tip
    assert second.basis_run_id == project.run_id("01", "03")
    assert second.branch == project.branch("01", "03")
    assert second.commit == git_head(project.worktree("01", "03"), project.branch("01", "03"))
    assert second.commit != first.commit
    run_git_text(
        project.worktree("01", "03"), "merge-base", "--is-ancestor", first.commit, second.commit
    )
    decision = load_phase_gate_decision(project.runtime_dir, _P1, 2)
    assert decision is not None and decision.outcome is PhaseGateVerdict.PASS
    assert decision.basis_commit == second.commit


def test_previous_attempt_evidence_is_never_overwritten_by_the_rerun(
    remediated: SimpleNamespace,
) -> None:
    project = remediated.project

    assert remediated.attempt1_at_remediation[0]
    assert file_bytes(project.attempt_dir("01", 1)) == remediated.attempt1_at_remediation[0]
    assert {p.name for p in project.attempt_dir("01", 1).iterdir()} == {
        "basis.json",
        "evidence.json",
        "decision.json",
        "remediation.json",
    }


def test_the_phase_completes_exactly_once_after_the_rerun_passes(
    remediated: SimpleNamespace,
) -> None:
    project = remediated.project
    cursor = project.cursor()

    assert cursor.completed_phases == (_P1,)
    assert cursor.phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE
    assert _kinds(project) == [
        PhaseGateEventKind.PHASE_GATE_STARTED,
        PhaseGateEventKind.PHASE_GATE_FAILED,
        PhaseGateEventKind.PHASE_GATE_REMEDIATION_PLANNED,
        PhaseGateEventKind.PHASE_GATE_STARTED,
        PhaseGateEventKind.PHASE_GATE_PASSED,
        PhaseGateEventKind.PHASE_COMPLETE,
    ]
    events = read_phase_gate_events(project.runtime_dir, _P1)
    assert [e.gate_attempt for e in events] == [1, 1, 1, 2, 2, 2]


def test_gate_findings_never_changed_the_frozen_requirements(remediated: SimpleNamespace) -> None:
    project = remediated.project
    master_path = project.project_root / ".lockstep" / "project" / "master-plan.json"
    master = load_frozen_master_plan(project.project_root)
    published = load_phase_plan(project.project_root, project.runtime_dir)

    assert master_path.read_bytes() == remediated.master_before
    assert master is not None and published is not None
    assert published.integration_acceptance_criteria == CRITERIA
    frozen = master.phases[0]
    assert published.model_copy(update={"subphases": frozen.subphases}) == frozen


def test_the_planner_spent_exactly_one_extra_call_on_the_whole_gate_cycle(
    remediated: SimpleNamespace,
) -> None:
    # Plan the remediation (1), its Contract and tests (2), and attempt 2's review (1).
    assert len(remediated.prompts) == 1
    assert remediated.project.launches("planner") == remediated.before.counts[0] + 4


# ===========================================================================
# Scenario C: a semantic FAIL (commands pass) produces structured findings and one remediation
# ===========================================================================


@pytest.fixture(scope="module")
def semantic(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    project = standard_project(
        tmp_path_factory.mktemp("semantic"),
        phases={"01": ("01", "02")},
        criteria={"01": CRITERIA},
        gate_commands=_two_commands,
        planner_tail=[
            gate_review_response("01", "fail", findings=[finding()]),
            remediation_plan_response("01", ("01", "02"), "03", criteria=CRITERIA),
            *unit_script("01", "03"),
            gate_review_response("01", "pass"),
        ],
        extra_units=[("01", "03")],
    )
    _ready(project)
    master_before = _master_path(project).read_bytes()
    with pytest.MonkeyPatch.context() as patch:
        prompts = record_calls(patch, phase_gate_cycle, "invoke_planner_artifact")
        result = _cycle(project)
    return SimpleNamespace(
        project=project, result=result, prompts=prompts, master_before=master_before
    )


def test_a_semantic_failure_records_structured_findings_and_still_remediates_once(
    semantic: SimpleNamespace,
) -> None:
    project = semantic.project
    first = load_phase_gate_decision(project.runtime_dir, _P1, 1)

    assert first is not None
    assert first.outcome is PhaseGateVerdict.FAIL
    assert first.deterministic_passed is True
    assert first.review is not None
    assert first.review.findings[0].criterion_id == "IC-1"
    assert semantic.result.disposition is PhaseGateCycleDisposition.PROJECT_COMPLETE
    assert semantic.result.remediations == (SubphaseId.model_validate("03"),)
    assert len(_receipt_names(project)) == 1


def test_the_semantic_findings_reach_the_remediation_planner_as_evidence_only(
    semantic: SimpleNamespace,
) -> None:
    prompt: str = semantic.prompts[0]["prompt"]

    assert "The two features do not integrate." in prompt
    assert "feature_01 and feature_02 disagree on the shared answer." in prompt
    assert "IC-1" in prompt
    assert "evidence, not requirements" in prompt


def test_the_frozen_phase_requirements_are_unchanged_by_a_semantic_failure(
    semantic: SimpleNamespace,
) -> None:
    project = semantic.project
    master_path = project.project_root / ".lockstep" / "project" / "master-plan.json"
    published = load_phase_plan(project.project_root, project.runtime_dir)

    assert master_path.read_bytes() == semantic.master_before
    assert published is not None
    assert published.integration_acceptance_criteria == CRITERIA
    second = load_phase_gate_decision(project.runtime_dir, _P1, 2)
    assert second is not None and second.outcome is PhaseGateVerdict.PASS


def test_both_semantic_reviews_were_fresh_planner_invocations_in_their_own_basis(
    semantic: SimpleNamespace,
) -> None:
    project = semantic.project
    cwds = project.planner_prompts_cwds()
    first = load_phase_gate_basis(project.runtime_dir, _P1, 1)
    second = load_phase_gate_basis(project.runtime_dir, _P1, 2)

    assert first is not None and second is not None
    assert first.basis_run_id == project.run_id("01", "02")
    assert second.basis_run_id == project.run_id("01", "03")
    assert project.worktree("01", "02").resolve() in cwds
    assert project.worktree("01", "03").resolve() in cwds


# ===========================================================================
# Scenario E: the remediation budget is finite
# ===========================================================================


@pytest.fixture(scope="module")
def exhausted(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    project = standard_project(
        tmp_path_factory.mktemp("exhausted"),
        phases={"01": ("01", "02")},
        gate_commands=_failing,
        planner_tail=[
            remediation_plan_response("01", ("01", "02"), "03"),
            *unit_script("01", "03"),
        ],
        extra_units=[("01", "03")],
    )
    _ready(project)
    return SimpleNamespace(project=project, result=_cycle(project, remediations=1))


def test_every_failing_rerun_ends_in_a_typed_exhaustion_stop(exhausted: SimpleNamespace) -> None:
    result = exhausted.result

    assert result.disposition is PhaseGateCycleDisposition.GATE_REMEDIATION_EXHAUSTED
    assert [(a.gate_attempt, a.disposition) for a in result.attempts] == [
        (1, PhaseGateAttemptDisposition.FAILED),
        (2, PhaseGateAttemptDisposition.FAILED),
    ]
    assert result.remediations == (SubphaseId.model_validate("03"),)


def test_exhaustion_leaves_the_phase_incomplete_and_the_evidence_intact(
    exhausted: SimpleNamespace,
) -> None:
    project = exhausted.project
    cursor = project.cursor()

    assert cursor.completed_phases == ()
    assert cursor.current_phase == _P1
    assert cursor.phase_gate_status is PhaseGateStatus.READY
    assert [e.subphase_id.root for e in cursor.completed_subphases] == ["01", "02", "03"]
    assert list_phase_gate_attempts(project.runtime_dir, _P1) == (1, 2)
    for attempt in (1, 2):
        decision = load_phase_gate_decision(project.runtime_dir, _P1, attempt)
        assert decision is not None and decision.outcome is PhaseGateVerdict.FAIL
        assert load_phase_gate_evidence(project.runtime_dir, _P1, attempt) is not None
    assert PhaseGateEventKind.PHASE_COMPLETE not in _kinds(project)
    assert len(_receipt_names(project)) == 1
    assert (project.attempt_dir("01", 2) / "remediation.json").exists() is False


def test_an_exhausted_phase_invokes_no_further_planner_or_implementer(
    exhausted: SimpleNamespace,
) -> None:
    project = exhausted.project
    counts, rows, before = project.counts(), project.markers(), _cursor_bytes(project)

    again = _cycle(project, remediations=1)

    assert again.disposition is PhaseGateCycleDisposition.GATE_REMEDIATION_EXHAUSTED
    assert project.counts() == counts
    assert project.markers() == rows
    assert _cursor_bytes(project) == before
    assert list_phase_gate_attempts(project.runtime_dir, _P1) == (1, 2)


def test_a_zero_budget_stops_at_the_first_failure_without_planning_anything(
    tmp_path: Path,
) -> None:
    project = _ready(
        standard_project(tmp_path, phases={"01": ("01",)}, gate_commands=_failing, planner_tail=[])
    )
    counts, before = project.counts(), _cursor_bytes(project)

    result = _cycle(project, remediations=0)

    assert result.disposition is PhaseGateCycleDisposition.GATE_REMEDIATION_EXHAUSTED
    assert result.remediations == ()
    assert project.counts() == counts
    assert _cursor_bytes(project) == before
    assert _receipt_names(project) == []
    assert load_phase_gate_decision(project.runtime_dir, _P1, 1) is not None


def test_a_larger_budget_keeps_trying_until_it_is_spent(tmp_path: Path) -> None:
    project = standard_project(
        tmp_path,
        phases={"01": ("01",)},
        gate_commands=_failing,
        planner_tail=[
            remediation_plan_response("01", ("01",), "02"),
            *unit_script("01", "02"),
            remediation_chain_response("01", ("01",), ("02", "03")),
            *unit_script("01", "03"),
        ],
        extra_units=[("01", "02"), ("01", "03")],
    )
    _ready(project)

    result = _cycle(project, remediations=2)

    assert result.disposition is PhaseGateCycleDisposition.GATE_REMEDIATION_EXHAUSTED
    assert result.remediations == (SubphaseId.model_validate("02"), SubphaseId.model_validate("03"))
    assert list_phase_gate_attempts(project.runtime_dir, _P1) == (1, 2, 3)
    assert len(_receipt_names(project)) == 2
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == ["01", "02", "03"]


# ===========================================================================
# Scenarios F / G through the cycle: execution failures never become remediation
# ===========================================================================


def test_a_review_provider_failure_stops_the_cycle_without_planning_remediation(
    tmp_path: Path,
) -> None:
    project = _ready(
        standard_project(
            tmp_path,
            phases={"01": ("01",)},
            criteria={"01": CRITERIA},
            gate_commands=_two_commands,
            planner_tail=[gate_review_response("01", "pass", returncode=1)],
        )
    )
    counts, before = project.counts(), _cursor_bytes(project)

    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.EXECUTION_FAILED
    assert result.attempts[-1].failure is PhaseGateExecutionFailure.REVIEW_FAILED
    assert project.counts() == (counts[0] + 1, counts[1], counts[2])
    assert _cursor_bytes(project) == before
    assert _receipt_names(project) == []
    assert project.cursor().phase_gate_status is PhaseGateStatus.READY


def test_a_gate_that_mutates_the_repository_stops_the_cycle_with_no_remediation(
    tmp_path: Path,
) -> None:
    project = _ready(
        standard_project(
            tmp_path,
            phases={"01": ("01",)},
            gate_commands=lambda marker: (mutating_command("feature_01.py"),),
            planner_tail=[],
        )
    )
    counts, before = project.counts(), _cursor_bytes(project)

    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.EXECUTION_FAILED
    assert result.attempts[-1].failure is PhaseGateExecutionFailure.AUTHORITY_VIOLATION
    assert project.counts() == counts
    assert _cursor_bytes(project) == before
    assert _receipt_names(project) == []
    assert load_phase_gate_decision(project.runtime_dir, _P1, 1) is None


def test_the_cycle_refuses_an_unconfigured_gate_stack_before_doing_anything(
    tmp_path: Path,
) -> None:
    project = _ready(standard_project(tmp_path, phases={"01": ("01",)}, planner_tail=[]))
    counts, before = project.counts(), _cursor_bytes(project)

    with pytest.raises(PhaseGateError) as refused:
        _cycle(project)

    assert refused.value.refusal is PhaseGateRefusal.COMMANDS_NOT_CONFIGURED
    assert project.counts() == counts
    assert _cursor_bytes(project) == before
    assert not project.gate_dir("01").exists()


# ===========================================================================
# An invalid remediation plan is an execution failure: nothing is accepted or invented
# ===========================================================================


def _outline_dict(sid: str, depends_on: tuple[str, ...] = ("01",), title: str | None = None) -> Any:
    return {
        "subphase_id": sid,
        "title": title or f"Gate remediation {sid}",
        "objective": "Repair the integration defect.",
        "depends_on": list(depends_on),
    }


def _raw_plan(
    subphases: list[dict[str, Any]], *, title: str = "Phase 01", phase: str = "01"
) -> dict[str, object]:
    base = phase_plan("01", ("01",))
    payload = json.loads(base.model_dump_json())
    payload["title"] = title
    payload["phase_id"] = phase
    payload["subphases"] = [json.loads(o.model_dump_json()) for o in base.subphases] + subphases
    return {"stdout": json.dumps(payload), "returncode": 0}


_BAD_PLANS: list[tuple[str, dict[str, object]]] = [
    ("two-new-outlines", _raw_plan([_outline_dict("02"), _outline_dict("03", ("02",))])),
    ("wrong-id", _raw_plan([_outline_dict("07")])),
    ("unknown-dependency", _raw_plan([_outline_dict("02", ("09",))])),
    ("no-new-outline", _raw_plan([])),
    ("changed-frozen-fact", _raw_plan([_outline_dict("02")], title="A rewritten title")),
    ("wrong-phase", _raw_plan([_outline_dict("02")], phase="02")),
    ("process-failure", {"stdout": "", "returncode": 1}),
    ("not-json", {"stdout": "no plan", "returncode": 0}),
    (
        "edits-tracked-files",
        {**_raw_plan([_outline_dict("02")]), "files": {"feature_01.py": "tampered\n"}},
    ),
]


@pytest.mark.parametrize(("label", "bad"), _BAD_PLANS, ids=[b[0] for b in _BAD_PLANS])
def test_an_invalid_remediation_plan_is_never_accepted(
    tmp_path: Path, label: str, bad: dict[str, object]
) -> None:
    project = _ready(
        standard_project(
            tmp_path, phases={"01": ("01",)}, gate_commands=_failing, planner_tail=[bad]
        )
    )
    before = _cursor_bytes(project)
    counts = project.counts()

    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.EXECUTION_FAILED
    assert result.remediations == ()
    assert _cursor_bytes(project) == before
    assert _receipt_names(project) == []
    assert project.counts() == (counts[0] + 1, counts[1], counts[2])
    assert load_phase_gate_decision(project.runtime_dir, _P1, 1) is not None
    assert PhaseGateEventKind.PHASE_GATE_REMEDIATION_PLANNED not in _kinds(project)
    published = load_phase_plan(project.project_root, project.runtime_dir)
    assert published is not None
    assert [o.subphase_id.root for o in published.subphases] == ["01"]


# ===========================================================================
# Crash boundaries: an accepted PASS / FAIL / remediation is reused, never re-decided
# ===========================================================================


@pytest.mark.parametrize("seam", ["publish_phase_plan", "record_phase_completion"])
def test_a_crash_after_the_pass_is_accepted_completes_the_phase_once_without_rerunning_anything(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, seam: str
) -> None:
    project = _ready(
        standard_project(
            tmp_path,
            phases={"01": ("01",), "02": ("11",)},
            gate_commands=_two_commands,
            planner_tail=[],
        )
    )
    crash_once(monkeypatch, phase_gate_cycle, seam)

    with pytest.raises(Exception, match=seam):
        _cycle(project)
    decision = load_phase_gate_decision(project.runtime_dir, _P1, 1)
    assert decision is not None and decision.outcome is PhaseGateVerdict.PASS
    assert project.cursor().completed_phases == ()  # PASS is accepted, not yet applied
    assert project.cursor().phase_gate_status is PhaseGateStatus.READY
    rows, counts = project.markers(), project.counts()

    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    assert [a.reused for a in result.attempts] == [True]
    assert project.markers() == rows  # no command rerun
    assert project.counts() == counts  # no Planner rerun
    cursor = project.cursor()
    assert cursor.completed_phases == (_P1,)
    assert cursor.current_phase == _P2
    assert cursor.current_subphase == SubphaseId.model_validate("11")
    master = load_frozen_master_plan(project.project_root)
    assert master is not None
    assert load_phase_plan(project.project_root, project.runtime_dir) == master.phases[1]
    assert _kinds(project).count(PhaseGateEventKind.PHASE_COMPLETE) == 1
    assert list_phase_gate_attempts(project.runtime_dir, _P1) == (1,)


def test_applying_a_pass_twice_cannot_complete_the_phase_twice(tmp_path: Path) -> None:
    project = _ready(
        standard_project(
            tmp_path,
            phases={"01": ("01",), "02": ("11",)},
            gate_commands=_two_commands,
            planner_tail=[],
        )
    )
    assert _cycle(project).disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    decision = load_phase_gate_decision(project.runtime_dir, _P1, 1)
    assert decision is not None
    before = _cursor_bytes(project)

    again = complete_phase_from_gate_pass(project.runtime, decision)

    assert again == project.cursor()
    assert _cursor_bytes(project) == before
    assert again.completed_phases == (_P1,)
    assert _kinds(project).count(PhaseGateEventKind.PHASE_COMPLETE) == 1


def test_only_a_pass_decision_can_complete_a_phase(tmp_path: Path) -> None:
    project = _ready(
        standard_project(tmp_path, phases={"01": ("01",)}, gate_commands=_failing, planner_tail=[])
    )
    assert _cycle(project, remediations=0).disposition is (
        PhaseGateCycleDisposition.GATE_REMEDIATION_EXHAUSTED
    )
    failed = load_phase_gate_decision(project.runtime_dir, _P1, 1)
    assert failed is not None
    before = _cursor_bytes(project)

    with pytest.raises(PhaseGateError):
        complete_phase_from_gate_pass(project.runtime, failed)

    assert _cursor_bytes(project) == before
    assert project.cursor().completed_phases == ()


def _resumable_failure_project(tmp_path: Path) -> GateProject:
    """Attempt 1 fails deterministically once; the remediation then lets attempt 2 pass."""
    flag = tmp_path / "fail-once.flag"
    (tmp_path / "p").mkdir()
    project = standard_project(
        tmp_path / "p",
        phases={"01": ("01", "02")},
        gate_commands=lambda marker: (fail_once_command(marker, flag, "gate"),),
        planner_tail=[
            remediation_plan_response("01", ("01", "02"), "03"),
            *unit_script("01", "03"),
        ],
        extra_units=[("01", "03")],
    )
    return _ready(project)


def _assert_finished_exactly_once(project: GateProject) -> None:
    assert project.cursor().phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE
    assert len(_receipt_names(project)) == 1
    # Contract + tests for 01, 02, 03 and exactly one remediation plan.
    assert project.launches("planner") == 7
    assert project.launches("implementer") == 3
    assert [label for label, _, _ in project.markers()] == ["gate", "gate"]  # one per attempt
    assert list_phase_gate_attempts(project.runtime_dir, _P1) == (1, 2)


def test_a_crash_after_the_fail_is_accepted_does_not_rerun_the_gate_and_plans_one_remediation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _resumable_failure_project(tmp_path)
    crash_once(monkeypatch, phase_gate_cycle, "invoke_planner_artifact")

    with pytest.raises(Exception, match="invoke_planner_artifact"):
        _cycle(project)
    failed = load_phase_gate_decision(project.runtime_dir, _P1, 1)
    assert failed is not None and failed.outcome is PhaseGateVerdict.FAIL
    assert _receipt_names(project) == []  # the FAIL is accepted; no remediation exists yet
    assert [label for label, _, _ in project.markers()] == ["gate"]

    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.PROJECT_COMPLETE
    assert load_phase_gate_decision(project.runtime_dir, _P1, 1) == failed
    _assert_finished_exactly_once(project)


@pytest.mark.parametrize(
    "seam", ["publish_phase_plan", "reopen_cursor_for_remediation", "run_project_phase"]
)
def test_a_crash_after_the_remediation_is_accepted_never_asks_for_a_second_one(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, seam: str
) -> None:
    project = _resumable_failure_project(tmp_path)
    crash_once(monkeypatch, phase_gate_cycle, seam)

    with pytest.raises(Exception, match=seam):
        _cycle(project)
    receipt = load_remediation_receipt(project.runtime_dir, _P1, 1)
    assert receipt is not None  # the accepted remediation plan is durable
    receipt_bytes = (project.attempt_dir("01", 1) / "remediation.json").read_bytes()
    planner_after_crash = project.launches("planner")
    assert planner_after_crash == 5  # four unit calls and the one remediation plan

    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.PROJECT_COMPLETE
    assert (project.attempt_dir("01", 1) / "remediation.json").read_bytes() == receipt_bytes
    _assert_finished_exactly_once(project)


def test_a_remediation_in_flight_resumes_through_the_cycle_without_a_second_plan(
    tmp_path: Path,
) -> None:
    project = _resumable_failure_project(tmp_path)
    # Run the cycle only as far as the remediation being applied, then stop before it runs.
    original = phase_gate_cycle.run_project_phase

    class InterruptError(Exception):
        pass

    def stop(*args: Any, **kwargs: Any) -> Any:
        raise InterruptError

    with pytest.MonkeyPatch.context() as patch:
        patch.setattr(phase_gate_cycle, "run_project_phase", stop)
        with pytest.raises(InterruptError):
            _cycle(project)
    cursor = project.cursor()
    assert cursor.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING
    assert cursor.current_subphase == SubphaseId.model_validate("03")
    assert cursor.remaining_outline == ()
    assert phase_gate_cycle.run_project_phase is original

    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.PROJECT_COMPLETE
    _assert_finished_exactly_once(project)


def test_a_pending_phase_without_a_remediation_in_flight_is_refused(tmp_path: Path) -> None:
    project = standard_project(
        tmp_path, phases={"01": ("01", "02")}, gate_commands=_two_commands, planner_tail=[]
    )
    # Plan and bind the first Contract only: ordinary Sub-phase work remains.
    assert (
        step_project_run(
            project.runtime,
            request_factory=project.factory,
            retry_budget=_budget(3),
            planning_timeout_seconds=60.0,
            jit_replan=False,
        )
        is None
    )
    before = _cursor_bytes(project)

    with pytest.raises(PhaseGateError) as refused:
        _cycle(project)

    assert refused.value.refusal is PhaseGateRefusal.NOT_READY
    assert _cursor_bytes(project) == before
    assert project.markers() == []


# ===========================================================================
# Transaction halts during remediation surface as typed stops, never as a gate verdict
# ===========================================================================


def test_a_remediation_that_needs_a_human_stops_the_cycle_typed_and_durable(
    tmp_path: Path,
) -> None:
    project = make_gate_project(
        tmp_path,
        phases={"01": ("01",)},
        planner=[
            *unit_script("01", "01"),
            remediation_plan_response("01", ("01",), "02"),
            *unit_script("01", "02"),
        ],
        implementer=[
            _impl_response("01"),
            _implementer_blocked_response(
                category=EscalationCategory.REQUIREMENT_AMBIGUITY,
                requested_authority=EscalationAuthority.HUMAN,
            ),
        ],
        reviewer=[review_response("01", "01")],
        gate_commands=_failing,
    )
    _ready(project)

    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.HUMAN_REQUIRED
    assert result.remediation_result is not None
    assert result.remediation_result.disposition is ProjectRunDisposition.HUMAN_REQUIRED
    assert result.remediations == (SubphaseId.model_validate("02"),)
    cursor = project.cursor()
    assert cursor.completed_phases == ()
    assert cursor.current_subphase == SubphaseId.model_validate("02")
    assert cursor.active_contract is not None
    counts = project.counts()

    # The stop is reconstructed from durable state: nothing is relaunched, planned, or re-gated.
    again = _cycle(project)

    assert again.disposition is PhaseGateCycleDisposition.HUMAN_REQUIRED
    assert project.counts() == counts
    assert list_phase_gate_attempts(project.runtime_dir, _P1) == (1,)
    assert len(_receipt_names(project)) == 1
