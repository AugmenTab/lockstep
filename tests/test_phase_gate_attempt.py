"""Phase 11.5: one audit-only Phase-gate attempt (``run_phase_gate_attempt``).

A gate attempt runs the project's configured Phase-gate command stack and (when the frozen
Phase has integration criteria) one fresh read-only Planner review against the final accepted
repository state, durably records the attempt, and reports PASS / FAIL / execution failure.
It never repairs, commits, plans, or touches the cursor.

Everything runs the real production code against fake provider executables, a real Git source
repository, real worktrees, and real subprocess gate commands. No real Claude/Codex account,
network, or model inference is used.

Baseline classification: every test in this module is RED at entry (``lockstep.phase_gate`` does
not exist).
"""

from __future__ import annotations

import inspect
import json
import sys
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest
from phase_gate_support import (
    CRITERIA,
    GateProject,
    crash_after_once,
    crash_on_nth_call,
    crash_once,
    failing_command,
    file_bytes,
    finding,
    gate_review_response,
    git_head,
    mutating_command,
    passing_command,
    record_calls,
    standard_project,
    tracked_state,
)
from test_supervisor_resume_execution import _git

import lockstep.phase_gate as phase_gate
from lockstep.domain import PhaseId
from lockstep.execution_config import ExecutionConfig
from lockstep.phase_gate import (
    PhaseGateAttemptDisposition,
    PhaseGateBasisRule,
    PhaseGateError,
    PhaseGateEventKind,
    PhaseGateExecutionFailure,
    PhaseGateRefusal,
    PhaseGateVerdict,
    list_phase_gate_attempts,
    load_phase_gate_basis,
    load_phase_gate_decision,
    load_phase_gate_evidence,
    load_phase_gate_violation,
    read_phase_gate_events,
    run_phase_gate_attempt,
)
from lockstep.project_cursor import PhaseGateStatus
from lockstep.project_cursor_store import (
    initialize_project_cursor,
    revise_cursor_unfinished_outline,
)
from lockstep.project_orchestrator import ProjectRunDisposition

_PHASE = PhaseId.model_validate("01")


def _attempt(project: GateProject) -> Any:
    return run_phase_gate_attempt(project.runtime, planning_timeout_seconds=60.0)


def _two_commands(marker: Path) -> tuple[tuple[str, ...], ...]:
    return (passing_command(marker, "first"), passing_command(marker, "second"))


def _ready(
    tmp_path: Path,
    planner_tail: list[dict[str, object]],
    *,
    commands: Any = _two_commands,
    criteria: bool = True,
    phases: dict[str, tuple[str, ...]] | None = None,
    execution: ExecutionConfig | None = None,
) -> GateProject:
    project = standard_project(
        tmp_path,
        planner_tail=planner_tail,
        phases=phases,
        criteria={"01": CRITERIA} if criteria else None,
        gate_commands=commands,
        execution=execution,
    )
    assert project.run_phase().disposition is ProjectRunDisposition.PHASE_GATE_READY
    return project


def _kinds(project: GateProject) -> list[PhaseGateEventKind]:
    return [e.kind for e in read_phase_gate_events(project.runtime_dir, _PHASE)]


def _cursor_bytes(project: GateProject) -> bytes:
    return (project.runtime_dir / "project" / "cursor.json").read_bytes()


def _txn_bytes(project: GateProject) -> dict[str, dict[str, bytes]]:
    return {sid: file_bytes(project.txn_dir("01", sid)) for sid in ("01", "02")}


# ===========================================================================
# Public shape
# ===========================================================================


def test_the_attempt_api_takes_an_explicit_planning_timeout_and_nothing_to_repair_with() -> None:
    parameters = inspect.signature(run_phase_gate_attempt).parameters

    assert parameters["planning_timeout_seconds"].kind is inspect.Parameter.KEYWORD_ONLY
    assert parameters["planning_timeout_seconds"].default is inspect.Parameter.empty
    assert not {"request_factory", "retry_budget", "jit_replan"} & set(parameters)


# ===========================================================================
# A clean PASS of one attempt
# ===========================================================================


@pytest.fixture(scope="module")
def passing(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    project = _ready(
        tmp_path_factory.mktemp("passing"), [gate_review_response("01", "pass")], criteria=True
    )
    worktree = project.worktree("01", "02")
    before = SimpleNamespace(
        tracked=tracked_state(worktree),
        cursor=_cursor_bytes(project),
        txn=_txn_bytes(project),
        counts=project.counts(),
        tip=git_head(worktree, project.branch("01", "02")),
    )
    with pytest.MonkeyPatch.context() as patch:
        calls = record_calls(patch, phase_gate, "invoke_planner_review")
        result = _attempt(project)
    after = SimpleNamespace(
        tracked=tracked_state(worktree),
        cursor=_cursor_bytes(project),
        txn=_txn_bytes(project),
        counts=project.counts(),
    )
    return SimpleNamespace(
        project=project, worktree=worktree, before=before, after=after, result=result, calls=calls
    )


def test_a_clean_attempt_passes_with_a_structured_decision(passing: SimpleNamespace) -> None:
    result = passing.result

    assert result.disposition is PhaseGateAttemptDisposition.PASSED
    assert result.gate_attempt == 1
    assert result.failure is None
    assert result.reused is False
    assert result.decision.outcome is PhaseGateVerdict.PASS
    assert result.decision.deterministic_passed is True
    assert result.decision.review is not None
    assert result.decision.review.verdict is PhaseGateVerdict.PASS


def test_the_attempt_is_bound_to_the_final_accepted_subphase_of_the_phase(
    passing: SimpleNamespace,
) -> None:
    project, basis = passing.project, passing.result.basis

    assert basis.rule is PhaseGateBasisRule.LATEST_PHASE_SUBPHASE
    assert basis.phase_id == _PHASE
    assert basis.basis_phase_id == _PHASE
    assert basis.basis_subphase_id.root == "02"
    assert basis.basis_run_id == project.run_id("01", "02")
    assert basis.branch == project.branch("01", "02")
    assert basis.commit == passing.before.tip
    assert basis.gate_attempt == 1
    assert basis.project_id == project.cursor().project_id
    assert basis.master_plan_digest == project.cursor().master_plan_digest
    assert load_phase_gate_basis(project.runtime_dir, _PHASE, 1) == basis


def test_every_gate_command_runs_in_the_accepted_worktree_at_the_accepted_commit(
    passing: SimpleNamespace,
) -> None:
    project = passing.project
    rows = project.markers()

    assert [label for label, _, _ in rows] == ["first", "second"]
    for _, cwd, head in rows:
        assert Path(cwd).resolve() == passing.worktree.resolve()
        assert head == passing.before.tip
        assert Path(cwd).resolve() not in (project.source.resolve(), project.project_root.resolve())


def test_the_semantic_review_inspects_the_accepted_worktree_not_the_source_checkout(
    passing: SimpleNamespace,
) -> None:
    project = passing.project

    assert project.planner_prompts_cwds()[-1] == passing.worktree.resolve()
    assert len(passing.calls) == 1


def test_a_successful_attempt_leaves_the_tracked_tree_exactly_as_it_found_it(
    passing: SimpleNamespace,
) -> None:
    assert passing.after.tracked == passing.before.tracked
    assert passing.after.tracked[1] == ""


def test_an_attempt_never_changes_the_cursor_or_any_transaction_journal(
    passing: SimpleNamespace,
) -> None:
    assert passing.after.cursor == passing.before.cursor
    assert passing.after.txn == passing.before.txn
    cursor = passing.project.cursor()
    assert cursor.completed_phases == ()
    assert cursor.phase_gate_status is PhaseGateStatus.READY


def test_an_attempt_invokes_no_implementer_or_reviewer_and_exactly_one_planner_review(
    passing: SimpleNamespace,
) -> None:
    planner, implementer, reviewer = passing.before.counts

    assert passing.after.counts == (planner + 1, implementer, reviewer)


def test_the_attempt_is_durably_reconstructable_from_its_artifacts(
    passing: SimpleNamespace,
) -> None:
    project = passing.project
    directory = project.attempt_dir("01", 1)

    assert {p.name for p in directory.iterdir()} == {"basis.json", "evidence.json", "decision.json"}
    evidence = load_phase_gate_evidence(project.runtime_dir, _PHASE, 1)
    assert evidence is not None
    assert evidence.configured_command_count == 2
    assert [c.exit_code for c in evidence.commands] == [0, 0]
    assert [c.argv[0] for c in evidence.commands] == [sys.executable, sys.executable]
    assert evidence.basis_commit == passing.result.basis.commit
    assert load_phase_gate_decision(project.runtime_dir, _PHASE, 1) == passing.result.decision
    assert load_phase_gate_violation(project.runtime_dir, _PHASE, 1) is None
    assert list_phase_gate_attempts(project.runtime_dir, _PHASE) == (1,)


def test_the_decision_binds_project_phase_attempt_and_basis(passing: SimpleNamespace) -> None:
    decision, basis = passing.result.decision, passing.result.basis

    assert (
        decision.project_id,
        decision.master_plan_digest,
        decision.phase_id,
        decision.gate_attempt,
        decision.basis_commit,
    ) == (basis.project_id, basis.master_plan_digest, basis.phase_id, 1, basis.commit)


def test_the_attempt_emits_typed_started_and_passed_events_bound_to_the_basis(
    passing: SimpleNamespace,
) -> None:
    project = passing.project
    events = read_phase_gate_events(project.runtime_dir, _PHASE)

    assert [e.kind for e in events] == [
        PhaseGateEventKind.PHASE_GATE_STARTED,
        PhaseGateEventKind.PHASE_GATE_PASSED,
    ]
    assert [e.sequence for e in events] == [1, 2]
    for event in events:
        assert event.project_id == project.cursor().project_id
        assert event.phase_id == _PHASE
        assert event.gate_attempt == 1
        assert event.basis_commit == passing.result.basis.commit
        assert event.basis_run_id == project.run_id("01", "02")
    assert events[1].verdict is PhaseGateVerdict.PASS
    assert events[0].verdict is None


def test_the_review_prompt_carries_frozen_criteria_and_the_authoritative_evidence(
    passing: SimpleNamespace,
) -> None:
    prompt: str = passing.calls[0]["prompt"]

    for label in (
        "Frozen Master Plan:",
        "Target phase_id:",
        "Frozen Phase integration criteria:",
        "Accepted repository basis:",
        "Deterministic gate evidence:",
    ):
        assert label in prompt
    assert "The completed features integrate." in prompt
    assert passing.result.basis.commit in prompt
    assert '"exit_code":0' in prompt
    assert "Do not modify files" in prompt
    assert "Do not invent criteria" in prompt
    assert "evidence, not requirements" in prompt


def test_the_review_is_requested_through_the_planner_with_a_bounded_timeout(
    passing: SimpleNamespace,
) -> None:
    call = passing.calls[0]

    assert call["timeout_seconds"] == 60.0
    assert call["args"][0].project_root == passing.worktree.resolve()


def test_re_running_an_accepted_attempt_reuses_its_decision_without_any_work(
    passing: SimpleNamespace,
) -> None:
    project = passing.project
    markers, counts = project.markers(), project.counts()
    events = read_phase_gate_events(project.runtime_dir, _PHASE)

    again = _attempt(project)

    assert again.disposition is PhaseGateAttemptDisposition.PASSED
    assert again.gate_attempt == 1
    assert again.reused is True
    assert again.decision == passing.result.decision
    assert project.markers() == markers
    assert project.counts() == counts
    assert read_phase_gate_events(project.runtime_dir, _PHASE) == events
    assert list_phase_gate_attempts(project.runtime_dir, _PHASE) == (1,)


# ===========================================================================
# A deterministic FAIL stops at the first required failure and never asks a model
# ===========================================================================


@pytest.fixture(scope="module")
def failing(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    def commands(marker: Path) -> tuple[tuple[str, ...], ...]:
        return (
            passing_command(marker, "first"),
            failing_command(marker, "second"),
            passing_command(marker, "third"),
        )

    project = _ready(tmp_path_factory.mktemp("failing"), [], commands=commands)
    before_counts = project.counts()
    result = _attempt(project)
    return SimpleNamespace(project=project, result=result, before_counts=before_counts)


def test_a_failed_command_is_a_durable_fail_without_a_semantic_review(
    failing: SimpleNamespace,
) -> None:
    result, project = failing.result, failing.project

    assert result.disposition is PhaseGateAttemptDisposition.FAILED
    assert result.decision.outcome is PhaseGateVerdict.FAIL
    assert result.decision.deterministic_passed is False
    assert result.decision.review is None
    assert project.counts() == failing.before_counts
    assert load_phase_gate_decision(project.runtime_dir, _PHASE, 1) == result.decision


def test_commands_run_in_order_and_stop_at_the_first_required_failure(
    failing: SimpleNamespace,
) -> None:
    project = failing.project
    evidence = load_phase_gate_evidence(project.runtime_dir, _PHASE, 1)

    assert [label for label, _, _ in project.markers()] == ["first", "second"]
    assert evidence is not None
    assert evidence.configured_command_count == 3
    assert [c.exit_code for c in evidence.commands] == [0, 3]
    assert "integration boom" in evidence.commands[1].stdout
    assert not evidence.passed


def test_a_failed_attempt_emits_started_then_failed_and_never_phase_complete(
    failing: SimpleNamespace,
) -> None:
    events = read_phase_gate_events(failing.project.runtime_dir, _PHASE)

    assert [e.kind for e in events] == [
        PhaseGateEventKind.PHASE_GATE_STARTED,
        PhaseGateEventKind.PHASE_GATE_FAILED,
    ]
    assert events[1].verdict is PhaseGateVerdict.FAIL


def test_a_failed_attempt_plans_nothing_and_leaves_the_phase_ready_and_incomplete(
    failing: SimpleNamespace,
) -> None:
    project = failing.project
    cursor = project.cursor()

    assert cursor.phase_gate_status is PhaseGateStatus.READY
    assert cursor.current_subphase is None
    assert cursor.completed_phases == ()
    assert not (project.attempt_dir("01", 1) / "remediation.json").exists()


def test_an_accepted_failure_is_never_reconsidered_by_re_running_the_same_attempt(
    failing: SimpleNamespace,
) -> None:
    project = failing.project
    rows = project.markers()

    again = _attempt(project)

    assert again.disposition is PhaseGateAttemptDisposition.FAILED
    assert again.gate_attempt == 1
    assert again.reused is True
    assert again.decision == failing.result.decision
    assert project.markers() == rows
    assert list_phase_gate_attempts(project.runtime_dir, _PHASE) == (1,)


# ===========================================================================
# Semantic review: FAIL, no criteria, and review failure that is not a FAIL
# ===========================================================================


def test_a_semantic_failure_is_a_fail_with_structured_findings(tmp_path: Path) -> None:
    project = _ready(
        tmp_path,
        [gate_review_response("01", "fail", findings=[finding()])],
        phases={"01": ("01",)},
    )

    result = _attempt(project)

    assert result.disposition is PhaseGateAttemptDisposition.FAILED
    assert result.decision.deterministic_passed is True
    review = result.decision.review
    assert review is not None and review.verdict is PhaseGateVerdict.FAIL
    assert review.findings[0].criterion_id == "IC-1"
    assert review.findings[0].observation == "The two features do not integrate."
    assert [label for label, _, _ in project.markers()] == ["first", "second"]


def test_a_phase_without_integration_criteria_passes_on_the_command_stack_alone(
    tmp_path: Path,
) -> None:
    project = _ready(tmp_path, [], criteria=False, phases={"01": ("01",)})
    before = project.counts()

    result = _attempt(project)

    assert result.disposition is PhaseGateAttemptDisposition.PASSED
    assert result.decision.review is None
    assert project.counts() == before
    assert _kinds(project) == [
        PhaseGateEventKind.PHASE_GATE_STARTED,
        PhaseGateEventKind.PHASE_GATE_PASSED,
    ]


def test_an_untracked_file_created_by_the_review_is_not_a_tracked_change(tmp_path: Path) -> None:
    project = _ready(
        tmp_path,
        [gate_review_response("01", "pass", files={"scratch-notes.txt": "notes"})],
        phases={"01": ("01",)},
    )

    result = _attempt(project)

    assert result.disposition is PhaseGateAttemptDisposition.PASSED


_BAD_REVIEWS: list[tuple[str, dict[str, object]]] = [
    ("process-failure", gate_review_response("01", "pass", returncode=1)),
    ("not-json", gate_review_response("01", stdout="this is not json")),
    ("wrong-phase", gate_review_response("02", "pass")),
    (
        "invented-criterion",
        gate_review_response("01", "fail", findings=[finding(criterion_id="IC-99")]),
    ),
    ("fail-without-findings", gate_review_response("01", "fail")),
    ("pass-with-findings", gate_review_response("01", "pass", findings=[finding()])),
]


@pytest.mark.parametrize(("label", "bad"), _BAD_REVIEWS, ids=[b[0] for b in _BAD_REVIEWS])
def test_missing_or_invalid_review_evidence_is_an_execution_failure_not_a_verdict(
    tmp_path: Path, label: str, bad: dict[str, object]
) -> None:
    project = _ready(tmp_path, [bad], phases={"01": ("01",)})
    before_cursor = _cursor_bytes(project)

    result = _attempt(project)

    assert result.disposition is PhaseGateAttemptDisposition.EXECUTION_FAILED
    assert result.failure is PhaseGateExecutionFailure.REVIEW_FAILED
    assert result.decision is None
    assert load_phase_gate_decision(project.runtime_dir, _PHASE, 1) is None
    assert _cursor_bytes(project) == before_cursor
    assert project.cursor().phase_gate_status is PhaseGateStatus.READY
    assert not (project.attempt_dir("01", 1) / "remediation.json").exists()
    kinds = _kinds(project)
    assert PhaseGateEventKind.PHASE_GATE_EXECUTION_FAILED in kinds
    assert PhaseGateEventKind.PHASE_GATE_PASSED not in kinds
    assert PhaseGateEventKind.PHASE_GATE_FAILED not in kinds


def test_a_review_provider_failure_resumes_the_same_attempt_without_rerunning_commands(
    tmp_path: Path,
) -> None:
    project = _ready(
        tmp_path,
        [gate_review_response("01", "pass", returncode=1), gate_review_response("01", "pass")],
        phases={"01": ("01",)},
    )

    first = _attempt(project)
    rows = project.markers()
    planner_after_failure = project.launches("planner")
    second = _attempt(project)

    assert first.disposition is PhaseGateAttemptDisposition.EXECUTION_FAILED
    assert second.disposition is PhaseGateAttemptDisposition.PASSED
    assert second.gate_attempt == first.gate_attempt == 1
    assert project.markers() == rows  # the durable command evidence was reused
    assert project.launches("planner") == planner_after_failure + 1
    assert list_phase_gate_attempts(project.runtime_dir, _PHASE) == (1,)
    assert _kinds(project) == [
        PhaseGateEventKind.PHASE_GATE_STARTED,
        PhaseGateEventKind.PHASE_GATE_EXECUTION_FAILED,
        PhaseGateEventKind.PHASE_GATE_PASSED,
    ]


# ===========================================================================
# Command problems that are not a product failure
# ===========================================================================


def test_a_command_that_cannot_launch_is_an_execution_failure_and_records_no_evidence(
    tmp_path: Path,
) -> None:
    project = _ready(
        tmp_path,
        [],
        commands=lambda marker: (("/nonexistent/lockstep-gate-binary",),),
        criteria=False,
        phases={"01": ("01",)},
    )

    result = _attempt(project)

    assert result.disposition is PhaseGateAttemptDisposition.EXECUTION_FAILED
    assert result.failure is PhaseGateExecutionFailure.COMMAND_ERROR
    assert result.decision is None
    assert load_phase_gate_evidence(project.runtime_dir, _PHASE, 1) is None
    assert load_phase_gate_decision(project.runtime_dir, _PHASE, 1) is None


def test_a_command_that_times_out_is_an_execution_failure_not_a_fail(tmp_path: Path) -> None:
    execution = ExecutionConfig(
        phase_gate_commands=((sys.executable, "-c", "import time; time.sleep(60)"),),
        agent_timeout_seconds=60.0,
        command_timeout_seconds=1.0,
        termination_grace_seconds=0.25,
    )
    project = _ready(tmp_path, [], criteria=False, phases={"01": ("01",)}, execution=execution)

    result = _attempt(project)

    assert result.disposition is PhaseGateAttemptDisposition.EXECUTION_FAILED
    assert result.failure is PhaseGateExecutionFailure.COMMAND_ERROR
    assert load_phase_gate_decision(project.runtime_dir, _PHASE, 1) is None


# ===========================================================================
# The gate never repairs: tracked mutation is an authority failure, not a verdict
# ===========================================================================


def test_a_command_that_edits_a_tracked_file_is_an_authority_violation(tmp_path: Path) -> None:
    project = _ready(
        tmp_path,
        [gate_review_response("01", "pass")],
        commands=lambda marker: (
            passing_command(marker, "first"),
            mutating_command("feature_02.py"),
        ),
        phases={"01": ("01", "02")},
    )
    before_cursor, before_counts = _cursor_bytes(project), project.counts()

    result = _attempt(project)

    assert result.disposition is PhaseGateAttemptDisposition.EXECUTION_FAILED
    assert result.failure is PhaseGateExecutionFailure.AUTHORITY_VIOLATION
    assert result.decision is None
    assert load_phase_gate_decision(project.runtime_dir, _PHASE, 1) is None
    violation = load_phase_gate_violation(project.runtime_dir, _PHASE, 1)
    assert violation is not None
    assert violation.stage == "commands"
    assert violation.changed_paths == ("feature_02.py",)
    assert violation.observed_head == violation.basis_commit
    assert violation.evidence is not None
    assert [c.exit_code for c in violation.evidence.commands] == [0, 0]
    # No semantic review was asked about a tree the gate itself had changed.
    assert project.counts() == before_counts
    assert _cursor_bytes(project) == before_cursor
    assert PhaseGateEventKind.PHASE_GATE_PASSED not in _kinds(project)
    assert _kinds(project)[-1] is PhaseGateEventKind.PHASE_GATE_EXECUTION_FAILED


_SNEAKY_COMMIT = (
    "import subprocess; "
    "subprocess.run(['git', 'commit', '--allow-empty', '-m', 'sneaky'], check=True)"
)


def test_a_command_that_commits_is_an_authority_violation(tmp_path: Path) -> None:
    project = _ready(
        tmp_path,
        [],
        commands=lambda marker: ((sys.executable, "-c", _SNEAKY_COMMIT),),
        criteria=False,
        phases={"01": ("01",)},
    )
    worktree = project.worktree("01", "01")
    tip = git_head(worktree)

    result = _attempt(project)

    assert result.disposition is PhaseGateAttemptDisposition.EXECUTION_FAILED
    assert result.failure is PhaseGateExecutionFailure.AUTHORITY_VIOLATION
    violation = load_phase_gate_violation(project.runtime_dir, _PHASE, 1)
    assert violation is not None
    assert violation.basis_commit == tip
    assert violation.observed_head != tip
    assert load_phase_gate_decision(project.runtime_dir, _PHASE, 1) is None


def test_a_review_that_edits_a_tracked_file_is_an_authority_violation(tmp_path: Path) -> None:
    project = _ready(
        tmp_path,
        [
            gate_review_response(
                "01", "pass", files={"feature_01.py": "def answer():\n    return 9\n"}
            )
        ],
        phases={"01": ("01",)},
    )

    result = _attempt(project)

    assert result.disposition is PhaseGateAttemptDisposition.EXECUTION_FAILED
    assert result.failure is PhaseGateExecutionFailure.AUTHORITY_VIOLATION
    assert result.decision is None
    violation = load_phase_gate_violation(project.runtime_dir, _PHASE, 1)
    assert violation is not None
    assert violation.stage == "review"
    assert violation.changed_paths == ("feature_01.py",)
    assert load_phase_gate_decision(project.runtime_dir, _PHASE, 1) is None
    # The command evidence that was legitimately gathered is retained, not discarded.
    assert load_phase_gate_evidence(project.runtime_dir, _PHASE, 1) is not None
    assert project.cursor().phase_gate_status is PhaseGateStatus.READY


def test_a_tree_the_gate_dirtied_is_refused_until_restored_then_a_new_attempt_begins(
    tmp_path: Path,
) -> None:
    project = _ready(
        tmp_path,
        [],
        commands=lambda marker: (mutating_command("feature_01.py"),),
        criteria=False,
        phases={"01": ("01",)},
    )
    worktree = project.worktree("01", "01")
    assert _attempt(project).failure is PhaseGateExecutionFailure.AUTHORITY_VIOLATION

    with pytest.raises(PhaseGateError) as dirty:
        _attempt(project)
    assert dirty.value.refusal is PhaseGateRefusal.BASIS_DIRTY

    _git(worktree, "checkout", "--", ".")
    second = _attempt(project)

    # The violated attempt is terminal: the next try is a new, explicitly numbered attempt.
    assert second.gate_attempt == 2
    assert second.failure is PhaseGateExecutionFailure.AUTHORITY_VIOLATION
    assert list_phase_gate_attempts(project.runtime_dir, _PHASE) == (1, 2)
    assert load_phase_gate_violation(project.runtime_dir, _PHASE, 1) is not None


# ===========================================================================
# Preconditions: refuse deterministically, run nothing, mutate nothing
# ===========================================================================


def _assert_untouched(project: GateProject, counts: tuple[int, int, int]) -> None:
    assert project.markers() == []
    assert project.counts() == counts
    assert not project.gate_dir("01").exists()


def test_a_phase_that_still_has_subphase_work_is_refused(tmp_path: Path) -> None:
    project = standard_project(
        tmp_path, planner_tail=[], criteria={"01": CRITERIA}, gate_commands=_two_commands
    )
    initialize_project_cursor(project.project_root, project.runtime_dir)
    before = _cursor_bytes(project)

    with pytest.raises(PhaseGateError) as refused:
        _attempt(project)

    assert refused.value.refusal is PhaseGateRefusal.NOT_READY
    assert _cursor_bytes(project) == before
    _assert_untouched(project, (0, 0, 0))


def test_a_project_with_no_cursor_is_refused(tmp_path: Path) -> None:
    project = standard_project(
        tmp_path, planner_tail=[], criteria={"01": CRITERIA}, gate_commands=_two_commands
    )

    with pytest.raises(PhaseGateError) as refused:
        _attempt(project)

    assert refused.value.refusal is PhaseGateRefusal.CURSOR_MISSING
    assert not (project.runtime_dir / "project").exists()
    _assert_untouched(project, (0, 0, 0))


def test_an_unconfigured_gate_stack_fails_closed_even_when_contract_commands_exist(
    tmp_path: Path,
) -> None:
    execution = ExecutionConfig(
        baseline_argv=(sys.executable, "-m", "pytest"),
        planner_quality_argv=(sys.executable, "-m", "py_compile"),
        agent_timeout_seconds=60.0,
        command_timeout_seconds=60.0,
    )
    project = _ready(tmp_path, [], criteria=False, phases={"01": ("01",)}, execution=execution)
    counts = project.counts()
    before = _cursor_bytes(project)

    with pytest.raises(PhaseGateError) as refused:
        _attempt(project)

    assert refused.value.refusal is PhaseGateRefusal.COMMANDS_NOT_CONFIGURED
    assert _cursor_bytes(project) == before
    _assert_untouched(project, counts)


def test_a_ready_phase_with_no_accepted_basis_is_refused(tmp_path: Path) -> None:
    project = standard_project(
        tmp_path, planner_tail=[], criteria={"01": CRITERIA}, gate_commands=_two_commands
    )
    initialize_project_cursor(project.project_root, project.runtime_dir)
    revise_cursor_unfinished_outline(project.project_root, project.runtime_dir, ())
    assert project.cursor().phase_gate_status is PhaseGateStatus.READY
    assert project.cursor().completed_subphases == ()

    with pytest.raises(PhaseGateError) as refused:
        _attempt(project)

    assert refused.value.refusal is PhaseGateRefusal.BASIS_UNAVAILABLE
    _assert_untouched(project, (0, 0, 0))


def test_a_missing_accepted_worktree_is_refused_rather_than_substituted(tmp_path: Path) -> None:
    project = _ready(tmp_path, [], criteria=False, phases={"01": ("01",)})
    counts = project.counts()
    worktree = project.worktree("01", "01")
    worktree.rename(worktree.with_name("moved-away"))

    with pytest.raises(PhaseGateError) as refused:
        _attempt(project)

    assert refused.value.refusal is PhaseGateRefusal.BASIS_UNAVAILABLE
    _assert_untouched(project, counts)


def test_a_tracked_change_in_the_accepted_worktree_is_refused(tmp_path: Path) -> None:
    project = _ready(tmp_path, [], criteria=False, phases={"01": ("01",)})
    counts = project.counts()
    (project.worktree("01", "01") / "feature_01.py").write_text("tampered\n")

    with pytest.raises(PhaseGateError) as refused:
        _attempt(project)

    assert refused.value.refusal is PhaseGateRefusal.BASIS_DIRTY
    _assert_untouched(project, counts)


def test_a_worktree_on_the_wrong_branch_is_refused(tmp_path: Path) -> None:
    project = _ready(tmp_path, [], criteria=False, phases={"01": ("01",)})
    counts = project.counts()
    _git(project.worktree("01", "01"), "checkout", "--detach")

    with pytest.raises(PhaseGateError) as refused:
        _attempt(project)

    assert refused.value.refusal is PhaseGateRefusal.BASIS_UNAVAILABLE
    _assert_untouched(project, counts)


# ===========================================================================
# Crash boundaries inside one attempt
# ===========================================================================


def test_a_crash_before_the_command_stack_runs_simply_resumes_the_attempt_on_restart(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _ready(tmp_path, [], criteria=False, phases={"01": ("01",)})
    crash_once(monkeypatch, phase_gate, "run_command_evidence")

    with pytest.raises(Exception, match="run_command_evidence"):
        _attempt(project)
    assert project.markers() == []

    result = _attempt(project)

    assert result.disposition is PhaseGateAttemptDisposition.PASSED
    assert result.gate_attempt == 1
    assert list_phase_gate_attempts(project.runtime_dir, _PHASE) == (1,)


def test_a_crash_during_the_command_stack_reruns_it_against_the_same_basis(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _ready(tmp_path, [gate_review_response("01", "pass")], phases={"01": ("01",)})
    original = phase_gate.run_command_evidence

    def die_after_first(commands: Any, **kwargs: Any) -> Any:
        original(commands[:1], **kwargs)
        raise RuntimeError("died during the stack")

    monkeypatch.setattr(phase_gate, "run_command_evidence", die_after_first)
    with pytest.raises(RuntimeError, match="died during the stack"):
        _attempt(project)
    basis = load_phase_gate_basis(project.runtime_dir, _PHASE, 1)
    assert basis is not None
    assert load_phase_gate_evidence(project.runtime_dir, _PHASE, 1) is None
    assert [label for label, _, _ in project.markers()] == ["first"]
    monkeypatch.setattr(phase_gate, "run_command_evidence", original)

    result = _attempt(project)

    assert result.disposition is PhaseGateAttemptDisposition.PASSED
    assert result.gate_attempt == 1
    assert result.basis == basis
    assert [label for label, _, _ in project.markers()] == ["first", "first", "second"]
    assert _kinds(project).count(PhaseGateEventKind.PHASE_GATE_STARTED) == 1


def test_a_crash_during_the_stack_with_a_moved_basis_is_refused_not_silently_rerun(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _ready(tmp_path, [], criteria=False, phases={"01": ("01",)})
    original = phase_gate.run_command_evidence

    def die(commands: Any, **kwargs: Any) -> Any:
        raise RuntimeError("died during the stack")

    monkeypatch.setattr(phase_gate, "run_command_evidence", die)
    with pytest.raises(RuntimeError):
        _attempt(project)
    monkeypatch.setattr(phase_gate, "run_command_evidence", original)
    _git(project.worktree("01", "01"), "commit", "--allow-empty", "-m", "moved")

    with pytest.raises(PhaseGateError) as refused:
        _attempt(project)

    assert refused.value.refusal is PhaseGateRefusal.BASIS_DRIFT
    assert project.markers() == []


def test_a_crash_after_command_evidence_reuses_it_instead_of_rerunning_the_stack(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _ready(tmp_path, [gate_review_response("01", "pass")], phases={"01": ("01",)})
    crash_once(monkeypatch, phase_gate, "invoke_planner_review")

    with pytest.raises(Exception, match="invoke_planner_review"):
        _attempt(project)
    rows, planner_before = project.markers(), project.launches("planner")
    assert load_phase_gate_evidence(project.runtime_dir, _PHASE, 1) is not None
    assert load_phase_gate_decision(project.runtime_dir, _PHASE, 1) is None

    result = _attempt(project)

    assert result.disposition is PhaseGateAttemptDisposition.PASSED
    assert project.markers() == rows
    assert project.launches("planner") == planner_before + 1
    assert _kinds(project).count(PhaseGateEventKind.PHASE_GATE_STARTED) == 1


def test_a_crash_after_the_started_event_does_not_duplicate_it_on_restart(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _ready(tmp_path, [], criteria=False, phases={"01": ("01",)})
    crash_after_once(monkeypatch, phase_gate, "append_phase_gate_event")

    with pytest.raises(Exception, match="append_phase_gate_event"):
        _attempt(project)
    assert _kinds(project) == [PhaseGateEventKind.PHASE_GATE_STARTED]

    result = _attempt(project)

    assert result.disposition is PhaseGateAttemptDisposition.PASSED
    assert _kinds(project) == [
        PhaseGateEventKind.PHASE_GATE_STARTED,
        PhaseGateEventKind.PHASE_GATE_PASSED,
    ]


def test_a_crash_after_the_accepted_decision_reuses_it_and_repairs_the_missing_event(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _ready(tmp_path, [gate_review_response("01", "pass")], phases={"01": ("01",)})
    crash_on_nth_call(monkeypatch, phase_gate, "append_phase_gate_event", 2)

    with pytest.raises(Exception, match="append_phase_gate_event"):
        _attempt(project)
    decision = load_phase_gate_decision(project.runtime_dir, _PHASE, 1)
    assert decision is not None  # the acceptance point was crossed before the crash
    rows, counts = project.markers(), project.counts()
    assert _kinds(project) == [PhaseGateEventKind.PHASE_GATE_STARTED]

    result = _attempt(project)

    assert result.disposition is PhaseGateAttemptDisposition.PASSED
    assert result.reused is True
    assert result.decision == decision
    assert project.markers() == rows  # no command rerun
    assert project.counts() == counts  # no Planner rerun
    assert _kinds(project) == [
        PhaseGateEventKind.PHASE_GATE_STARTED,
        PhaseGateEventKind.PHASE_GATE_PASSED,
    ]


def test_the_gate_journal_is_one_phase_scoped_jsonl_file(tmp_path: Path) -> None:
    project = _ready(tmp_path, [], criteria=False, phases={"01": ("01",)})
    _attempt(project)

    lines = (project.gate_dir("01") / "events.jsonl").read_text().splitlines()

    assert len(lines) == 2
    assert [json.loads(line)["kind"] for line in lines] == [
        "phase_gate_started",
        "phase_gate_passed",
    ]
