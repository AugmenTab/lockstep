"""Phase 13.1: rich run metrics / audit projection, and gate-native semantic-review attribution.

The audit projection (``lockstep.reporting.audit``) is a deterministic, read-only view over a
project's durable machine evidence -- cursor, planning journal, child transaction journals and
retry evidence, archived Contracts, verification reports, Phase-gate attempts and the new
gate-owned semantic-review journal, Phase finalizations, autonomous project runs, and the
retained accepted Git refs. Metrics explain authoritative events and artifacts; they never
become execution truth.

Every runtime here is produced by the real production code -- the autonomous driver, the
orchestrator, the Supervisor transaction, the Phase gate, finalization and the 12.9 teardown --
against scripted fake provider executables (some emitting ``claude -p`` result envelopes with
usage), a real Git source repository and real worktrees. No real provider account, network, or
model inference is used.

The representative lifecycle (``lifecycle``)::

    Phase 01 (integration criteria)     01 first pass, JIT replan, 02 REVIEW_REWORK then APPROVE,
                                        gate attempt 1 FAIL (commands) -> remediation 03,
                                        gate attempt 2 PASS with a semantic review
    Phase 02 (no criteria)              11 (first Contract candidate refused, corrected), gate PASS
    then completed-Phase teardown

Scripted usage (``uncached / cache-read / cache-write / output``; ``-`` = not reported)::

    planning     contract 01  11/100/20/5    contract 02  12/200/0/6    remediation 13/0/0/7
                 contract 11 (correction)  -/50/-/4     JIT, contract 03, contract 11 (bad): none
    transaction  tests 01  3/-/-/2    implementer 02 attempt 1  20/0/0/10
                 reviewer 02 attempt 1  5/-/-/-     everything else: none
    phase_gate   semantic review (attempt 2)  14/300/40/8

Baseline classification at entry (14b579a): every audit-projection and gate-attribution test is
RED (``lockstep.reporting.audit`` and ``lockstep.phase_gate_review_invocation`` do not exist,
and the semantic review leaves no durable invocation evidence). The Phase-10 baseline
characterization is GREEN by design.
"""

from __future__ import annotations

import ast
import contextlib
import hashlib
import importlib
import json
import os
import shutil
import subprocess
import sys
from collections.abc import Callable, Iterator
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any

import pytest
from autonomous_run_support import (
    FakeClock,
    after_call,
    append_quota_signal,
    autonomous_project,
    make_policy,
    run_autonomous,
)
from phase_gate_support import (
    CRITERIA,
    GateProject,
    contract_response,
    fail_once_command,
    gate_review_response,
    git_head,
    make_gate_project,
    passing_command,
    phase_plan,
    remediation_plan_response,
    replan_response,
    review_response,
    run_git_text,
    standard_project,
)
from test_project_orchestrator import _impl_response, _impl_source, _test_source, _tests_response
from test_supervisor_resume_execution import _review_decision_payload

import lockstep.agents.invocation as agent_invocation
import lockstep.autonomous_run as autonomous_run
from lockstep.autonomous_run_control import AutonomousRunDisposition
from lockstep.domain import (
    AgentRole,
    ExecutionEventKind,
    ExecutionOutcome,
    FailureCause,
    InvocationIdentity,
    PhaseId,
    ProjectId,
    QuotaStatus,
    SubphaseId,
)
from lockstep.git import RepositoryChange
from lockstep.metrics import project_runtime_metrics
from lockstep.persistence import ExecutionEvent, read_events
from lockstep.phase_context_finalization import (
    load_phase_context_finalization,
    phase_context_finalization_identity,
)
from lockstep.phase_gate import (
    PhaseGateAttemptDisposition,
    PhaseGateEventKind,
    PhaseGateExecutionFailure,
    PhaseGateVerdict,
    load_phase_gate_decision,
    read_phase_gate_events,
    run_phase_gate_attempt,
)
from lockstep.phase_teardown import ensure_completed_phase_teardown
from lockstep.planning_invocation import (
    PlanningInvocationIdentity,
    PlanningInvocationRecorder,
    PlanningStage,
    read_planning_invocation_events,
)
from lockstep.project_cursor import PhaseGateStatus
from lockstep.retry_checkpoint import RetryAuthorityKind
from lockstep.state import WorkflowState

_REPO = Path(__file__).resolve().parent.parent
_SRC = _REPO / "src" / "lockstep"
_BASELINE = Path(__file__).parent / "baselines" / "transaction_baseline.json"
_BASELINE_SHA256 = "30d05f1e482ef339a922ccbd5f787fba8379c715d19b5b954a7d19d8a3e29532"
_P1 = PhaseId.model_validate("01")
_P2 = PhaseId.model_validate("02")
_REVIEW_LABEL = "Frozen Phase integration criteria:"


def _audit() -> ModuleType:
    """The 13.1 projection module, imported lazily so the characterizations stay green."""
    return importlib.import_module("lockstep.reporting.audit")


def _review_journal() -> ModuleType:
    return importlib.import_module("lockstep.phase_gate_review_invocation")


def _build(project: GateProject) -> Any:
    return _audit().build_project_audit(project.project_root, project.runtime_dir)


def _json(projection: Any) -> str:
    text: str = _audit().audit_projection_json(projection)
    return text


# ---------------------------------------------------------------------------
# Scripted responses
# ---------------------------------------------------------------------------


def _envelope(response: dict[str, object], usage: dict[str, int]) -> dict[str, object]:
    """Wrap a fake provider response in a ``claude -p`` result envelope that reports usage."""
    return {
        **response,
        "stdout": json.dumps(
            {
                "type": "result",
                "result": response["stdout"],
                "usage": usage,
                "modelUsage": {"claude-fixture": {}},
                "session_id": "fixture-session",
            }
        ),
    }


def _usage(uncached: int, read: int, write: int, output: int) -> dict[str, int]:
    return {
        "input_tokens": uncached,
        "cache_read_input_tokens": read,
        "cache_creation_input_tokens": write,
        "output_tokens": output,
    }


def _review(phase: str, sid: str, *, attempt: int, verdict: str) -> dict[str, object]:
    decision = _review_decision_payload(
        phase_id=phase,
        subphase_id=sid,
        attempt=attempt,
        verdict=verdict,
        summary=f"{verdict} {sid}",
    )
    return {
        "stdout": json.dumps({"status": "completed", "review_decision": decision, "blocker": None}),
        "returncode": 0,
    }


def _refused_contract(phase: str, sid: str) -> dict[str, object]:
    """A Contract candidate whose test target is a directory: refused, then corrected once."""
    payload = json.loads(str(contract_response(phase, sid)["stdout"]))
    payload["tests"][0]["path"] = "tests"
    return {"stdout": json.dumps(payload), "returncode": 0}


def _lifecycle_project(tmp_path: Path) -> GateProject:
    planner = [
        _envelope(contract_response("01", "01"), _usage(11, 100, 20, 5)),
        _envelope(_tests_response("01"), {"input_tokens": 3, "output_tokens": 2}),
        replan_response(phase_plan("01", ("01", "02"), criteria=CRITERIA)),
        _envelope(contract_response("01", "02"), _usage(12, 200, 0, 6)),
        _tests_response("02"),
        _envelope(
            remediation_plan_response("01", ("01", "02"), "03", criteria=CRITERIA),
            _usage(13, 0, 0, 7),
        ),
        contract_response("01", "03"),
        _tests_response("03"),
        _envelope(gate_review_response("01", "pass"), _usage(14, 300, 40, 8)),
        _refused_contract("02", "11"),
        _envelope(
            contract_response("02", "11"), {"cache_read_input_tokens": 50, "output_tokens": 4}
        ),
        _tests_response("11"),
    ]
    implementer = [
        _impl_response("01"),
        _envelope(_impl_response("02"), _usage(20, 0, 0, 10)),
        _impl_response("02", verbose=True),
        _impl_response("03"),
        _impl_response("11"),
    ]
    reviewer = [
        review_response("01", "01"),
        _envelope(_review("01", "02", attempt=1, verdict="rework"), {"input_tokens": 5}),
        _review("01", "02", attempt=2, verdict="approve"),
        review_response("01", "03"),
        review_response("02", "11"),
    ]
    return make_gate_project(
        tmp_path,
        phases={"01": ("01", "02"), "02": ("11",)},
        criteria={"01": CRITERIA},
        planner=planner,
        implementer=implementer,
        reviewer=reviewer,
        gate_commands=lambda marker: (
            fail_once_command(marker, marker.parent / "gate.flag", "gate"),
        ),
    )


def _worktrees(project: GateProject) -> list[str]:
    root = project.runtime_dir / "worktrees"
    if not root.is_dir():
        return []
    return sorted(p.name for p in root.iterdir() if p.name.startswith("run-"))


@pytest.fixture(scope="module")
def lifecycle(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    project = _lifecycle_project(tmp_path_factory.mktemp("lifecycle"))
    with pytest.MonkeyPatch.context() as patch:
        # Teardown is deferred (never skipped) so the projection can be taken on both sides.
        patch.setattr(autonomous_run, "ensure_completed_phase_teardown", lambda runtime: ())
        result = run_autonomous(
            project,
            make_policy(max_subphases=10, retry_attempts=3, max_gate_remediations=1),
            clock=FakeClock(),
        )
    assert result.disposition is AutonomousRunDisposition.PROJECT_COMPLETE
    before = _build(project)
    worktrees_before = _worktrees(project)
    ensure_completed_phase_teardown(project.runtime)
    after = _build(project)
    return SimpleNamespace(
        project=project,
        result=result,
        before=before,
        before_json=_json(before),
        after=after,
        after_json=_json(after),
        worktrees_before=worktrees_before,
        worktrees_after=_worktrees(project),
    )


def _row(lifecycle: SimpleNamespace, phase: str, sid: str) -> Any:
    rows = [
        s
        for s in lifecycle.after.subphases
        if (s.phase_id.root, s.subphase_id.root) == (phase, sid)
    ]
    assert len(rows) == 1
    return rows[0]


def _group(groups: Any, key: str | None) -> Any:
    matches = [g for g in groups if g.key == key]
    assert len(matches) == 1, key
    return matches[0]


def _total(value: Any) -> tuple[Any, int, int, int, str]:
    return (
        value.observed_sum,
        value.observed,
        value.eligible,
        value.not_recorded,
        value.coverage.value,
    )


@contextlib.contextmanager
def _preserved(*paths: Path) -> Iterator[None]:
    """Restore the exact bytes (or absence) of *paths* after a deliberate corruption."""
    saved = {path: path.read_bytes() if path.exists() else None for path in paths}
    try:
        yield
    finally:
        for path, data in saved.items():
            if data is None:
                if path.is_dir():
                    shutil.rmtree(path)
                elif path.exists():
                    path.unlink()
            else:
                path.write_bytes(data)


# ===========================================================================
# Test A -- simple first-pass success
# ===========================================================================


def test_a_a_first_pass_unit_has_exact_counts_and_terminal_state(
    lifecycle: SimpleNamespace,
) -> None:
    row = _row(lifecycle, "01", "01")
    cursor = lifecycle.project.cursor()

    assert row.run_id.root == "run-01-01"
    assert row.contract_digest == cursor.completed_subphases[0].contract_digest
    assert row.terminal_state is WorkflowState.SUBPHASE_COMPLETE
    assert (row.completion_recorded, row.completed) == (True, True)
    assert (row.attempts_observed, row.final_attempt, row.first_pass) == (1, 1, True)
    assert (row.review_rework_count, row.retry_count, row.retries) == (0, 0, ())
    assert (row.resumed_attempts, row.abandoned_invocations) == (0, 0)
    assert (
        row.contract_planning_invocations,
        row.planner_invocations,
        row.test_authoring_invocations,
        row.implementer_invocations,
        row.reviewer_invocations,
        row.escalation_invocations,
    ) == (1, 1, 1, 1, 1, 0)
    assert row.failure_causes == {} and row.stop_reasons == {} and row.halts == ()
    assert row.tests.verification_runs == 1 and row.tests.verification_failures == 0
    assert row.tests.acceptance_tests == 1 and row.tests.verification_commands == 1
    assert row.tests.final_verification_passed is True
    assert row.accepted_commit == git_head(
        lifecycle.project.source, lifecycle.project.branch("01", "01")
    )


# ===========================================================================
# Test B -- REVIEW_REWORK
# ===========================================================================


def test_b_review_rework_is_one_completed_unit_attributed_to_review_rework(
    lifecycle: SimpleNamespace,
) -> None:
    row = _row(lifecycle, "01", "02")

    assert (row.completed, row.first_pass) == (True, False)
    assert (row.attempts_observed, row.final_attempt) == (2, 2)
    assert (row.review_rework_count, row.retry_count) == (1, 1)
    (retry,) = row.retries
    assert (retry.attempt, retry.role, retry.cause, retry.authority, retry.executed) == (
        2,
        AgentRole.IMPLEMENTER,
        FailureCause.IMPLEMENTATION_DEFECT,
        RetryAuthorityKind.REVIEW_REWORK,
        True,
    )
    assert (row.implementer_invocations, row.reviewer_invocations) == (2, 2)
    assert (row.planner_invocations, row.contract_planning_invocations) == (1, 1)
    rework = [
        w
        for w in lifecycle.after.repeated_work
        if w.source.value == "transaction_attempt" and w.run_id == row.run_id
    ]
    assert [(w.category.value, w.cause, w.attempt) for w in rework] == [
        ("review_rework", FailureCause.IMPLEMENTATION_DEFECT, 2)
    ]
    project = lifecycle.after.project
    assert (project.subphases_completed, project.review_rework_count, project.retry_count) == (
        4,
        1,
        1,
    )


# ===========================================================================
# Test C -- retry / resume
# ===========================================================================


def test_c_a_resumed_retry_keeps_its_cause_and_never_duplicates_an_invocation(
    lifecycle: SimpleNamespace,
) -> None:
    row = _row(lifecycle, "01", "02")
    rows = [r for r in lifecycle.after.invocations if r.run_id == row.run_id]

    assert row.resumed_attempts == 1
    assert [(r.stage.value, r.attempt) for r in rows] == [
        ("test_authoring", 1),
        ("implementation", 1),
        ("review", 1),
        ("implementation", 2),
        ("review", 2),
    ]
    assert len({r.invocation_id for r in rows}) == len(rows) == 5
    assert all(r.started and r.returned and r.outcome is ExecutionOutcome.SUCCESS for r in rows)
    journal = read_events(lifecycle.project.txn_dir("01", "02") / "events.jsonl")
    started = [
        e
        for e in journal
        if isinstance(e, ExecutionEvent) and e.kind is ExecutionEventKind.INVOCATION_STARTED
    ]
    assert len(started) == len(rows)
    assert [s.subphase_id.root for s in lifecycle.after.subphases if s.completed].count("02") == 1


def test_c_attempt_elapsed_follows_the_frozen_boundaries(lifecycle: SimpleNamespace) -> None:
    row = _row(lifecycle, "01", "02")
    events = read_events(lifecycle.project.txn_dir("01", "02") / "events.jsonl")
    executions = [e for e in events if isinstance(e, ExecutionEvent)]

    for attempt in (1, 2):
        starts = [
            e.occurred_at
            for e in executions
            if e.kind in (ExecutionEventKind.INVOCATION_STARTED, ExecutionEventKind.RESUME_STARTED)
            and e.attempt is not None
            and e.attempt.root == attempt
        ]
        ends = [
            e.occurred_at
            for e in executions
            if e.kind is ExecutionEventKind.INVOCATION_RETURNED
            and e.attempt is not None
            and e.attempt.root == attempt
        ]
        (window,) = [a for a in row.elapsed.attempts if a.attempt == attempt]
        assert (window.started_at, window.finished_at) == (min(starts), max(ends))
        assert window.seconds == (max(ends) - min(starts)).total_seconds()
    metrics = project_runtime_metrics(lifecycle.project.txn_dir("01", "02")).subphases[0]
    assert row.elapsed.wall_clock_seconds == metrics.wall_clock_seconds
    assert (
        row.elapsed.journal_span_seconds
        == (events[-1].occurred_at - events[0].occurred_at).total_seconds()
    )
    assert row.elapsed.invocations.observed == row.elapsed.invocations.eligible == 5


# ===========================================================================
# Test D -- provider failure / quota halt
# ===========================================================================


def test_d_a_provider_process_failure_halt_is_typed_and_its_usage_stays_unavailable(
    tmp_path: Path,
) -> None:
    project = autonomous_project(
        tmp_path,
        phases={"01": ("01", "02", "03")},
        implementer=[_impl_response("01"), {"stdout": "", "returncode": 1, "stderr": ""}],
    )
    result = run_autonomous(project, make_policy(), clock=FakeClock())
    assert result.disposition is AutonomousRunDisposition.TERMINAL_HALT

    projection = _build(project)
    failed = [s for s in projection.subphases if s.subphase_id.root == "02"]
    assert len(failed) == 1
    row = failed[0]

    assert (row.completed, row.first_pass, row.repository) == (False, False, None)
    assert row.terminal_state is WorkflowState.HALTED
    assert row.failure_causes == {FailureCause.PROVIDER_PROCESS_FAILURE: 1}
    # The cause rides the failed return; the halt boundary itself records none.
    assert [(h.kind.value, h.cause, h.stop_reason) for h in row.halts] == [
        ("transaction_halted", None, None)
    ]
    (impl,) = [
        r
        for r in projection.invocations
        if r.run_id == row.run_id and r.role is AgentRole.IMPLEMENTER
    ]
    assert (impl.outcome, impl.returncode, impl.cause) == (
        ExecutionOutcome.FAILURE,
        1,
        FailureCause.PROVIDER_PROCESS_FAILURE,
    )
    assert impl.input_tokens is None and impl.output_tokens is None
    assert impl.elapsed_seconds is not None  # host-measured, unlike provider telemetry
    assert _total(row.usage.input_tokens) == (None, 0, 2, 0, "unavailable")
    assert projection.project.final_stop is AutonomousRunDisposition.TERMINAL_HALT
    assert projection.project.status.value == "in_progress"
    active = projection.project.active_unit
    assert active is not None and active.run_id == row.run_id and active.attempted is True
    assert (projection.project.subphases_attempted, projection.project.subphases_completed) == (
        2,
        1,
    )


def test_d_an_authoritative_quota_exhaustion_stop_is_typed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = autonomous_project(tmp_path, phases={"01": ("01", "02")})
    after_call(
        monkeypatch,
        autonomous_run,
        "step_project_run",
        2,
        lambda: append_quota_signal(project, "01", "01", QuotaStatus.EXHAUSTED),
    )
    result = run_autonomous(project, make_policy(), clock=FakeClock())
    assert result.disposition is AutonomousRunDisposition.USAGE_LIMIT

    projection = _build(project)

    assert projection.project.final_stop is AutonomousRunDisposition.USAGE_LIMIT
    (run,) = projection.project.project_runs
    assert run.stop_disposition is AutonomousRunDisposition.USAGE_LIMIT
    quota = projection.invocation_summary.total.usage.quota
    assert quota.counts["exhausted"] == 1
    signal = [r for r in projection.invocations if r.quota_status is QuotaStatus.EXHAUSTED]
    assert len(signal) == 1 and signal[0].started is False and signal[0].returned is True
    assert signal[0].input_tokens is None  # a quota fact is not token telemetry
    assert [(s.subphase_id.root, s.completed) for s in projection.subphases] == [("01", True)]


# ===========================================================================
# Test E -- project planning journal
# ===========================================================================


def test_e_the_planning_journal_projects_stage_counts_pairing_and_routing(
    lifecycle: SimpleNamespace,
) -> None:
    planning = lifecycle.after.planning
    rows = [r for r in lifecycle.after.invocations if r.family.value == "planning"]

    assert planning.journal.value == "recorded"
    assert [(g.key, g.invocations) for g in planning.by_stage] == [
        ("phase_planning", 0),
        ("contract_planning", 5),
        ("jit_replan", 1),
        ("gate_remediation", 1),
    ]
    total = planning.total
    assert (total.started, total.returned, total.succeeded, total.failed, total.abandoned) == (
        7,
        7,
        7,
        0,
        0,
    )
    assert planning.unmatched_started == 0
    assert len(rows) == len(read_planning_invocation_events(lifecycle.project.runtime_dir)) // 2
    assert {(r.provider, r.configured_model, r.configured_effort) for r in rows} == {
        ("claude", "role-model", "high")
    }
    assert {r.reported_model for r in rows} == {"claude-fixture", None}
    assert all(r.run_id is None and r.attempt is None and r.role is AgentRole.PLANNER for r in rows)
    assert all(r.elapsed_seconds is not None for r in rows)
    assert [r.subphase_id.root if r.subphase_id else None for r in rows] == [
        "01",
        None,
        "02",
        "03",
        "03",
        "11",
        "11",
    ]
    # No child-transaction inflation: each child journal still holds only its own Planner turn.
    for phase, sid in (("01", "01"), ("01", "02"), ("01", "03"), ("02", "11")):
        totals = project_runtime_metrics(lifecycle.project.txn_dir(phase, sid)).totals
        assert totals.invocations_by_role[AgentRole.PLANNER] == 1


def test_e_a_refused_contract_candidate_is_typed_repeated_planning_work(
    lifecycle: SimpleNamespace,
) -> None:
    planning = [w for w in lifecycle.after.repeated_work if w.source.value == "planning_invocation"]

    assert [(w.category.value, w.cause, w.phase_id, w.subphase_id) for w in planning] == [
        ("superseded_planning_candidate", None, _P2, SubphaseId.model_validate("11"))
    ]
    assert _row(lifecycle, "02", "11").contract_planning_invocations == 2


def _failed_planning_project(tmp_path: Path) -> GateProject:
    project = make_gate_project(
        tmp_path,
        phases={"01": ("01", "02")},
        planner=[{"stdout": "", "returncode": 1}],
        implementer=[],
        reviewer=[],
    )
    with contextlib.suppress(Exception):
        project.run_phase()
    return project


def test_e_a_failed_planning_invocation_is_retained_and_attempts_nothing(
    tmp_path: Path,
) -> None:
    project = _failed_planning_project(tmp_path)

    projection = _build(project)

    (row,) = projection.invocations
    assert (row.family.value, row.stage.value, row.outcome, row.cause, row.returncode) == (
        "planning",
        "contract_planning",
        ExecutionOutcome.FAILURE,
        FailureCause.PROVIDER_PROCESS_FAILURE,
        1,
    )
    total = projection.planning.total
    assert (total.started, total.returned, total.succeeded, total.failed) == (1, 1, 0, 1)
    assert projection.subphases == ()
    assert projection.project.subphases_attempted == 0
    assert projection.project.active_unit is None


# ===========================================================================
# Test F -- unmatched planning STARTED
# ===========================================================================


def test_f_an_unmatched_started_is_counted_as_started_and_never_as_returned(
    tmp_path: Path,
) -> None:
    project = _failed_planning_project(tmp_path)
    identity = PlanningInvocationIdentity.issue(
        project_id=project.cursor().project_id,
        phase_id=_P1,
        target_subphase_id=SubphaseId.model_validate("01"),
        stage=PlanningStage.CONTRACT_PLANNING,
    )
    PlanningInvocationRecorder(
        runtime_dir=project.runtime_dir, identity=identity, adapter=project.runtime.adapters.planner
    ).started()
    journal = project.runtime_dir / "planning" / "invocations.jsonl"
    before = journal.read_bytes()

    projection = _build(project)

    planning = projection.planning
    assert planning.unmatched_started == 1
    total = planning.total
    assert (total.invocations, total.started, total.returned) == (2, 2, 1)
    assert (total.succeeded, total.failed, total.abandoned) == (0, 1, 1)
    (abandoned,) = [
        r for r in projection.invocations if r.invocation_id == identity.invocation_id.root
    ]
    assert (abandoned.started, abandoned.returned, abandoned.abandoned) == (True, False, True)
    assert (abandoned.outcome, abandoned.cause, abandoned.returncode) == (None, None, None)
    assert abandoned.provider == "claude" and abandoned.input_tokens is None
    (repeated,) = projection.repeated_work
    assert (repeated.category.value, repeated.cause) == (
        "planning_failure",
        FailureCause.PROVIDER_PROCESS_FAILURE,
    )
    assert journal.read_bytes() == before  # no synthetic RETURNED was written


# ===========================================================================
# Test G -- Phase-gate semantic review attribution
# ===========================================================================


def test_g_the_review_identity_is_gate_scoped_and_reuses_no_other_family() -> None:
    module = _review_journal()
    identity = module.PhaseGateReviewInvocationIdentity.issue(
        project_id=ProjectId.model_validate("lockstep"),
        phase_id=_P1,
        gate_attempt=2,
    )

    assert set(module.PhaseGateReviewInvocationIdentity.model_fields) == {
        "project_id",
        "phase_id",
        "gate_attempt",
        "role",
        "stage",
        "invocation_id",
    }
    assert identity.role is AgentRole.PLANNER
    assert identity.stage.value == "semantic_review"
    assert not isinstance(identity, PlanningInvocationIdentity | InvocationIdentity)
    assert "semantic_review" not in {s.value for s in PlanningStage}
    with pytest.raises(ValueError):
        module.PhaseGateReviewInvocationIdentity(
            **{**identity.model_dump(), "role": AgentRole.IMPLEMENTER}
        )
    with pytest.raises(ValueError):
        module.PhaseGateReviewInvocationIdentity(**{**identity.model_dump(), "gate_attempt": 0})


def test_g_the_semantic_review_leaves_durable_gate_native_evidence(
    lifecycle: SimpleNamespace,
) -> None:
    module = _review_journal()
    runtime_dir = lifecycle.project.runtime_dir
    events = module.read_phase_gate_review_invocation_events(runtime_dir, _P1)

    assert [e.kind.value for e in events] == ["started", "returned"]
    started, returned = events
    assert started.identity == returned.identity
    identity = started.identity
    assert (identity.project_id.root, identity.phase_id, identity.gate_attempt) == (
        "lockstep",
        _P1,
        2,
    )
    assert (identity.role, identity.stage.value) == (AgentRole.PLANNER, "semantic_review")
    for event in events:
        assert (event.provider, event.configured_model, event.configured_effort) == (
            "claude",
            "role-model",
            "high",
        )
    assert (started.outcome, started.usage) == (None, None)
    assert (returned.outcome, returned.returncode, returned.cause) == (
        ExecutionOutcome.SUCCESS,
        0,
        None,
    )
    assert returned.usage is not None
    telemetry = returned.usage.reported
    assert (
        telemetry.input_tokens,
        telemetry.uncached_input_tokens,
        telemetry.cache_read_tokens,
        telemetry.cache_write_tokens,
        telemetry.output_tokens,
        telemetry.reported_model,
    ) == (354, 14, 300, 40, 8, "claude-fixture")
    assert module.phase_gate_review_invocations_path(runtime_dir, _P1) == (
        runtime_dir / "phase-gates" / "01" / "review-invocations.jsonl"
    )
    assert not module.read_phase_gate_review_invocation_events(runtime_dir, _P2)
    # The attempt directory keeps exactly its accepted artifacts.
    assert sorted(p.name for p in lifecycle.project.attempt_dir("01", 2).iterdir()) == [
        "basis.json",
        "decision.json",
        "evidence.json",
    ]
    planning_ids = {e.identity.invocation_id for e in read_planning_invocation_events(runtime_dir)}
    assert identity.invocation_id not in planning_ids


def test_g_the_projection_lists_the_review_under_phase_gate(lifecycle: SimpleNamespace) -> None:
    (row,) = [r for r in lifecycle.after.invocations if r.family.value == "phase_gate"]
    gate = next(p for p in lifecycle.after.phases if p.phase_id == _P1).gate

    assert (row.stage.value, row.role, row.phase_id, row.gate_attempt) == (
        "semantic_review",
        AgentRole.PLANNER,
        _P1,
        2,
    )
    assert (row.subphase_id, row.run_id, row.attempt) == (None, None, None)
    assert (row.provider, row.configured_model, row.reported_model) == (
        "claude",
        "role-model",
        "claude-fixture",
    )
    assert gate is not None
    assert [a.semantic_review.value for a in gate.attempts] == ["not_applicable", "recorded"]
    assert [a.semantic_review_invocations for a in gate.attempts] == [0, 1]
    assert _total(gate.semantic_review.usage.input_tokens) == (354, 1, 1, 0, "complete")
    assert lifecycle.after.coverage.semantic_reviews_recorded == 1
    assert lifecycle.after.coverage.semantic_reviews_not_recorded == 0


def _gate_ready(tmp_path: Path, review: dict[str, object]) -> GateProject:
    project = standard_project(
        tmp_path,
        phases={"01": ("01",)},
        criteria={"01": CRITERIA},
        gate_commands=lambda marker: (passing_command(marker, "gate"),),
        planner_tail=[review],
    )
    project.run_phase()
    assert project.cursor().phase_gate_status is PhaseGateStatus.READY
    return project


def test_g_started_is_durable_before_the_review_process_launches(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    module = _review_journal()
    project = _gate_ready(
        tmp_path, _envelope(gate_review_response("01", "pass"), _usage(1, 2, 3, 4))
    )
    seen: list[list[str]] = []
    original = agent_invocation.run_process

    def observing(*args: Any, **kwargs: Any) -> Any:
        if _REVIEW_LABEL in (kwargs.get("stdin_text") or ""):
            events = module.read_phase_gate_review_invocation_events(project.runtime_dir, _P1)
            seen.append([e.kind.value for e in events])
        return original(*args, **kwargs)

    monkeypatch.setattr(agent_invocation, "run_process", observing)
    result = run_phase_gate_attempt(project.runtime, planning_timeout_seconds=60.0)

    assert result.disposition is PhaseGateAttemptDisposition.PASSED
    assert seen == [["started"]]
    events = module.read_phase_gate_review_invocation_events(project.runtime_dir, _P1)
    assert [e.kind.value for e in events] == ["started", "returned"]
    assert {e.identity.gate_attempt for e in events} == {1}


@pytest.mark.parametrize(
    ("review", "cause", "returncode"),
    [
        (gate_review_response("01", stdout="not a review"), FailureCause.MALFORMED_OUTPUT, 0),
        (
            gate_review_response("01", stdout="", returncode=1),
            FailureCause.PROVIDER_PROCESS_FAILURE,
            1,
        ),
    ],
    ids=["malformed", "process-failure"],
)
def test_g_a_failed_review_return_is_recorded_and_the_gate_decides_exactly_as_before(
    tmp_path: Path, review: dict[str, object], cause: FailureCause, returncode: int
) -> None:
    module = _review_journal()
    project = _gate_ready(tmp_path, review)

    result = run_phase_gate_attempt(project.runtime, planning_timeout_seconds=60.0)

    assert result.disposition is PhaseGateAttemptDisposition.EXECUTION_FAILED
    assert result.failure is PhaseGateExecutionFailure.REVIEW_FAILED
    assert load_phase_gate_decision(project.runtime_dir, _P1, 1) is None
    assert sorted(p.name for p in project.attempt_dir("01", 1).iterdir()) == [
        "basis.json",
        "evidence.json",
    ]
    assert [e.kind for e in read_phase_gate_events(project.runtime_dir, _P1)] == [
        PhaseGateEventKind.PHASE_GATE_STARTED,
        PhaseGateEventKind.PHASE_GATE_EXECUTION_FAILED,
    ]
    started, returned = module.read_phase_gate_review_invocation_events(project.runtime_dir, _P1)
    assert started.kind.value == "started"
    assert (returned.outcome, returned.cause, returned.returncode) == (
        ExecutionOutcome.FAILURE,
        cause,
        returncode,
    )
    projection = _build(project)
    (attempt,) = projection.phases[0].gate.attempts
    assert attempt.semantic_review.value == "recorded"
    assert attempt.execution_failures == (PhaseGateExecutionFailure.REVIEW_FAILED,)
    assert attempt.outcome is None
    gate_family = _group(projection.invocation_summary.by_family, "phase_gate")
    assert (gate_family.invocations, gate_family.failed, gate_family.succeeded) == (1, 1, 0)


# ===========================================================================
# Test H -- historical gate compatibility
# ===========================================================================


def test_h_a_historical_gate_without_review_telemetry_is_not_recorded_never_zero(
    lifecycle: SimpleNamespace,
) -> None:
    journal = _review_journal().phase_gate_review_invocations_path(
        lifecycle.project.runtime_dir, _P1
    )
    with _preserved(journal):
        journal.unlink()  # exactly what a pre-13.1 gate attempt left behind
        projection = _build(lifecycle.project)

    gate = projection.phases[0].gate
    second = gate.attempts[1]
    assert (second.outcome, second.review_verdict) == (PhaseGateVerdict.PASS, PhaseGateVerdict.PASS)
    assert (second.semantic_review.value, second.semantic_review_invocations) == ("not_recorded", 0)
    assert second.semantic_review_not_recorded == 1
    family = _group(projection.invocation_summary.by_family, "phase_gate")
    assert (family.invocations, family.recorded, family.not_recorded) == (1, 0, 1)
    for field in ("input_tokens", "cache_read_tokens", "output_tokens"):
        assert _total(getattr(family.usage, field)) == (None, 0, 1, 1, "not_recorded")
    assert family.usage.elapsed.observed_seconds is None
    assert projection.coverage.semantic_reviews_not_recorded == 1
    assert not [r for r in projection.invocations if r.family.value == "phase_gate"]
    assert _json(_build(lifecycle.project)) == lifecycle.after_json  # restored exactly


# ===========================================================================
# Tests I / J -- usage and cache coverage
# ===========================================================================


def test_i_usage_sums_and_coverage_are_exact_per_family_and_overall(
    lifecycle: SimpleNamespace,
) -> None:
    summary = lifecycle.after.invocation_summary
    expected = {
        "planning": {
            "input_tokens": (356, 3, 7, 0, "partial"),
            "uncached_input_tokens": (36, 3, 7, 0, "partial"),
            "output_tokens": (22, 4, 7, 0, "partial"),
        },
        "transaction": {
            "input_tokens": (20, 1, 14, 0, "partial"),
            "uncached_input_tokens": (28, 3, 14, 0, "partial"),
            "output_tokens": (12, 2, 14, 0, "partial"),
        },
        "phase_gate": {
            "input_tokens": (354, 1, 1, 0, "complete"),
            "uncached_input_tokens": (14, 1, 1, 0, "complete"),
            "output_tokens": (8, 1, 1, 0, "complete"),
        },
    }
    assert [g.key for g in summary.by_family] == ["planning", "transaction", "phase_gate"]
    for family, fields in expected.items():
        usage = _group(summary.by_family, family).usage
        for field, values in fields.items():
            assert _total(getattr(usage, field)) == values, (family, field)
    total = summary.total.usage
    assert _total(total.input_tokens) == (730, 5, 22, 0, "partial")
    assert _total(total.uncached_input_tokens) == (78, 7, 22, 0, "partial")
    assert _total(total.output_tokens) == (42, 7, 22, 0, "partial")
    assert total.elapsed.observed == total.elapsed.eligible == 22
    assert summary.total.invocations == 22


def test_i_a_unit_without_any_telemetry_is_unavailable_not_zero(lifecycle: SimpleNamespace) -> None:
    row = _row(lifecycle, "01", "03")

    for field in ("input_tokens", "uncached_input_tokens", "cache_read_tokens", "output_tokens"):
        assert _total(getattr(row.usage, field)) == (None, 0, 3, 0, "unavailable")


def test_i_aggregate_views_keep_configured_and_reported_identity_apart(
    lifecycle: SimpleNamespace,
) -> None:
    summary = lifecycle.after.invocation_summary

    assert [(g.key, g.invocations) for g in summary.by_role] == [
        ("planner", 12),
        ("implementer", 5),
        ("reviewer", 5),
    ]
    assert [(g.key, g.invocations) for g in summary.by_stage] == [
        ("test_authoring", 4),
        ("implementation", 5),
        ("review", 5),
        ("contract_planning", 5),
        ("jit_replan", 1),
        ("gate_remediation", 1),
        ("semantic_review", 1),
    ]
    assert [(g.key, g.invocations) for g in summary.by_provider] == [("claude", 22)]
    assert [(g.key, g.invocations) for g in summary.by_configured_model] == [("role-model", 22)]
    assert [(g.key, g.invocations) for g in summary.by_configured_effort] == [("high", 22)]
    assert [(g.key, g.invocations) for g in summary.by_reported_model] == [
        ("claude-fixture", 8),
        (None, 14),
    ]


def test_j_cache_read_write_and_uncached_coverage_are_independent(
    lifecycle: SimpleNamespace,
) -> None:
    summary = lifecycle.after.invocation_summary
    expected = {
        "planning": ((350, 4, 7, 0, "partial"), (20, 3, 7, 0, "partial")),
        "transaction": ((0, 1, 14, 0, "partial"), (0, 1, 14, 0, "partial")),
        "phase_gate": ((300, 1, 1, 0, "complete"), (40, 1, 1, 0, "complete")),
    }
    for family, (read, write) in expected.items():
        usage = _group(summary.by_family, family).usage
        assert _total(usage.cache_read_tokens) == read, family
        assert _total(usage.cache_write_tokens) == write, family
    total = summary.total.usage
    assert _total(total.cache_read_tokens) == (650, 6, 22, 0, "partial")
    assert _total(total.cache_write_tokens) == (60, 5, 22, 0, "partial")
    assert _total(total.uncached_input_tokens) == (78, 7, 22, 0, "partial")
    # A provider-reported zero is a known zero, not missing evidence.
    transaction = _group(summary.by_family, "transaction").usage
    assert transaction.cache_read_tokens.observed_sum == 0
    assert transaction.cache_read_tokens.observed == 1


# ===========================================================================
# Test K -- Git metrics after teardown
# ===========================================================================


def test_k_teardown_removed_completed_worktrees(lifecycle: SimpleNamespace) -> None:
    assert lifecycle.worktrees_before == ["run-01-01", "run-01-02", "run-01-03", "run-02-11"]
    assert lifecycle.worktrees_after == ["run-02-11"]


def test_k_every_durable_metric_is_identical_after_teardown(lifecycle: SimpleNamespace) -> None:
    assert lifecycle.after == lifecycle.before
    assert lifecycle.after_json == lifecycle.before_json
    assert [s.repository for s in lifecycle.after.subphases] == [
        s.repository for s in lifecycle.before.subphases
    ]


def test_k_accepted_diff_statistics_are_exact_from_retained_refs(
    lifecycle: SimpleNamespace,
) -> None:
    project = lifecycle.project
    previous: str | None = None
    for phase, sid, impl in (
        ("01", "01", _impl_source("01")),
        ("01", "02", _impl_source("02", verbose=True)),
        ("01", "03", _impl_source("03")),
        ("02", "11", _impl_source("11")),
    ):
        repository = _row(lifecycle, phase, sid).repository
        tests = _test_source(sid).count("\n")
        lines = impl.count("\n")
        assert repository is not None
        assert repository.accepted_commit == git_head(project.source, project.branch(phase, sid))
        assert repository.test_paths == (f"tests/test_feature_{sid}.py",)
        assert repository.implementation_paths == (f"feature_{sid}.py",)
        assert repository.test_change == RepositoryChange(1, tests, 0, 0)
        assert repository.implementation_change == RepositoryChange(1, lines, 0, 0)
        assert repository.accepted_change == RepositoryChange(2, tests + lines, 0, 0)
        assert (
            repository.base_commit
            == run_git_text(project.source, "rev-parse", f"{repository.test_commit}^").strip()
        )
        if previous is not None:
            assert repository.base_commit == previous
        previous = repository.accepted_commit
    totals = lifecycle.after.project.repository
    assert _total(totals.files_changed) == (8, 4, 4, 0, "complete")
    assert totals.lines_deleted.observed_sum == 0


# ===========================================================================
# Test L -- multi-Phase aggregate
# ===========================================================================


def test_l_project_phase_and_subphase_aggregates(lifecycle: SimpleNamespace) -> None:
    projection = lifecycle.after
    project = projection.project

    assert project.project_id == "lockstep"
    assert project.status.value == "complete"
    assert project.phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE
    assert (project.phases_planned, project.completed_phases) == (2, (_P1, _P2))
    assert (project.current_phase, project.current_subphase, project.active_unit) == (
        None,
        None,
        None,
    )
    assert (
        project.subphases_attempted,
        project.subphases_completed,
        project.first_pass_subphases,
    ) == (4, 4, 3)
    assert project.final_stop is AutonomousRunDisposition.PROJECT_COMPLETE
    (run,) = project.project_runs
    assert [(r.phase_id.root, r.subphase_id.root) for r in run.reservations] == [
        ("01", "01"),
        ("01", "02"),
        ("01", "03"),
        ("02", "11"),
    ]
    assert (run.stop_disposition, run.elapsed_seconds) == (
        AutonomousRunDisposition.PROJECT_COMPLETE,
        0.0,
    )
    phases = {p.phase_id.root: p for p in projection.phases}
    one, two = phases["01"], phases["02"]
    assert [s.root for s in one.subphase_ids] == ["01", "02", "03"]
    assert (one.subphases_attempted, one.subphases_completed, one.first_pass_subphases) == (3, 3, 2)
    assert (one.review_rework_count, one.retry_count) == (1, 1)
    assert {f.value: n for f, n in one.invocations_by_family.items()} == {
        "planning": 5,
        "transaction": 11,
        "phase_gate": 1,
    }
    assert (two.subphases_attempted, two.subphases_completed, two.first_pass_subphases) == (1, 1, 1)
    assert {f.value: n for f, n in two.invocations_by_family.items()} == {
        "planning": 2,
        "transaction": 3,
        "phase_gate": 0,
    }
    assert [p.status.value for p in projection.phases] == ["completed", "completed"]
    assert [i.family.value for i in projection.invocations] == (
        ["planning"] * 7 + ["transaction"] * 14 + ["phase_gate"]
    )


def test_l_gate_history_keeps_the_failed_attempt_and_its_remediation(
    lifecycle: SimpleNamespace,
) -> None:
    phases = {p.phase_id.root: p for p in lifecycle.after.phases}
    gate = phases["01"].gate
    assert gate is not None
    first, second = gate.attempts

    assert (gate.attempt_count, gate.passed, gate.final_outcome, gate.remediation_count) == (
        2,
        True,
        PhaseGateVerdict.PASS,
        1,
    )
    assert (first.outcome, first.deterministic_passed, first.review_verdict) == (
        PhaseGateVerdict.FAIL,
        False,
        None,
    )
    assert (first.configured_command_count, first.commands_run) == (1, 1)
    assert first.remediation_subphase_id == SubphaseId.model_validate("03")
    assert (second.outcome, second.deterministic_passed, second.review_verdict) == (
        PhaseGateVerdict.PASS,
        True,
        PhaseGateVerdict.PASS,
    )
    assert second.basis_run_id is not None and second.basis_run_id.root == "run-01-03"
    assert gate.final_basis_commit == second.basis_commit
    assert {k.value: n for k, n in gate.event_counts.items()} == {
        "phase_complete": 1,
        "phase_gate_failed": 1,
        "phase_gate_passed": 1,
        "phase_gate_remediation_planned": 1,
        "phase_gate_started": 2,
    }
    gate_work = [w for w in lifecycle.after.repeated_work if w.source.value == "gate_attempt"]
    assert [(w.phase_id, w.gate_attempt, w.category.value) for w in gate_work] == [
        (_P1, 2, "gate_command_failure")
    ]
    later = phases["02"].gate
    assert later is not None
    assert [(a.outcome, a.semantic_review.value) for a in later.attempts] == [
        (PhaseGateVerdict.PASS, "not_applicable")
    ]


def test_l_finalization_relates_phase_subphases_commits_and_gate(
    lifecycle: SimpleNamespace,
) -> None:
    runtime_dir = lifecycle.project.runtime_dir
    for phase in lifecycle.after.phases:
        stored = load_phase_context_finalization(runtime_dir, phase.phase_id)
        assert stored is not None and phase.finalization is not None
        assert phase.finalization.identity == phase_context_finalization_identity(stored)
        assert phase.finalization.subphases == stored.completed_subphases
        assert phase.finalization.gate_attempt == stored.final_phase_gate.gate_attempt
        assert phase.finalization.final_repository_basis_commit == phase.gate.final_basis_commit
        for entry in stored.completed_subphases:
            row = _row(lifecycle, phase.phase_id.root, entry.subphase_id.root)
            assert row.accepted_commit == entry.accepted_commit
    assert lifecycle.after.coverage.finalizations == 2
    assert lifecycle.after.coverage.completed_phases_without_finalization == 0


# ===========================================================================
# Test M -- deterministic ordering
# ===========================================================================


def test_m_fresh_construction_and_reversed_directory_order_are_byte_identical(
    lifecycle: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    assert _json(_build(lifecycle.project)) == lifecycle.after_json
    original = Path.iterdir

    def reversed_iterdir(self: Path) -> Iterator[Path]:
        return iter(sorted(original(self), reverse=True))

    monkeypatch.setattr(Path, "iterdir", reversed_iterdir)
    assert _json(_build(lifecycle.project)) == lifecycle.after_json


def test_m_the_projection_carries_no_projection_time_facts(lifecycle: SimpleNamespace) -> None:
    text = lifecycle.after_json
    assert lifecycle.after.projection_version == 1
    assert os.uname().nodename not in text
    assert str(lifecycle.project.runtime_dir) not in text
    assert str(lifecycle.project.root) not in text


# ===========================================================================
# Test N -- corrupt authoritative evidence fails closed
# ===========================================================================


def _append_garbage(path: Path) -> None:
    with path.open("a", encoding="utf-8") as handle:
        handle.write('{"not": "an event"}\n')


_Corruption = tuple[list[Path], Callable[[], None], str]


def _corruptions(project: GateProject) -> tuple[dict[str, _Corruption], Callable[[], None]]:
    runtime = project.runtime_dir
    txn = project.txn_dir("01", "02")
    finalization = runtime / "project" / "phase-context" / "01.json"
    settlements = sorted((txn / "retry" / "settlements").iterdir())
    branch = f"refs/heads/{project.branch('01', '01')}"
    accepted = git_head(project.source, project.branch("01", "01"))
    other = git_head(project.source, project.branch("01", "02"))
    orphan = runtime / "transactions" / "run-09-99"

    def git_conflict() -> None:
        run_git_text(project.source, "update-ref", branch, other)

    def restore_ref() -> None:
        run_git_text(project.source, "update-ref", branch, accepted)

    def orphaned() -> None:
        shutil.copytree(project.txn_dir("01", "01"), orphan)

    def rewrite_canonically_but_differently() -> None:
        decision = project.attempt_dir("01", 2) / "decision.json"
        payload = json.loads(decision.read_text())
        payload["summary"] = "a different summary"
        decision.write_text(json.dumps(payload, separators=(",", ":")) + "\n")

    return {
        "transaction-journal": (
            [txn / "events.jsonl"],
            lambda: _append_garbage(txn / "events.jsonl"),
            "transaction_journal",
        ),
        "transaction-state": (
            [txn / "state.json"],
            lambda: (txn / "state.json").write_text("{"),
            "transaction_journal",
        ),
        "planning-journal": (
            [runtime / "planning" / "invocations.jsonl"],
            lambda: _append_garbage(runtime / "planning" / "invocations.jsonl"),
            "planning_journal",
        ),
        "cursor": (
            [runtime / "project" / "cursor.json"],
            lambda: (runtime / "project" / "cursor.json").write_text("{}"),
            "project_cursor",
        ),
        "finalization": (
            [finalization],
            lambda: finalization.write_text(
                json.dumps(json.loads(finalization.read_text()), indent=2)
            ),
            "phase_finalization",
        ),
        "gate-decision-identity": (
            [project.attempt_dir("01", 2) / "decision.json"],
            rewrite_canonically_but_differently,
            "phase_finalization",
        ),
        "gate-review-journal": (
            [runtime / "phase-gates" / "01" / "review-invocations.jsonl"],
            lambda: _append_garbage(runtime / "phase-gates" / "01" / "review-invocations.jsonl"),
            "gate_review_journal",
        ),
        "project-run-state": (
            [runtime / "project-runs" / "prun-0001" / "state.json"],
            lambda: (runtime / "project-runs" / "prun-0001" / "state.json").write_text("{"),
            "project_run",
        ),
        "retry-settlement": (
            [settlements[0]],
            lambda: settlements[0].write_text("{"),
            "retry_evidence",
        ),
        "orphan-transaction": ([orphan], orphaned, "transaction_journal"),
        "accepted-git-identity": ([], git_conflict, "git"),
    }, restore_ref


_CORRUPTIONS = (
    "transaction-journal",
    "transaction-state",
    "planning-journal",
    "cursor",
    "finalization",
    "gate-decision-identity",
    "gate-review-journal",
    "project-run-state",
    "retry-settlement",
    "orphan-transaction",
    "accepted-git-identity",
)


@pytest.mark.parametrize("name", _CORRUPTIONS)
def test_n_corrupt_authoritative_evidence_fails_closed_with_its_source(
    lifecycle: SimpleNamespace, name: str
) -> None:
    project = lifecycle.project
    corruptions, restore_ref = _corruptions(project)
    paths, corrupt, source = corruptions[name]
    try:
        with _preserved(*paths):
            corrupt()
            with pytest.raises(_audit().ProjectAuditError) as refused:
                _build(project)
    finally:
        restore_ref()
    assert refused.value.source.value == source
    assert _json(_build(project)) == lifecycle.after_json


# ===========================================================================
# Test O -- no provider requirement; read-only
# ===========================================================================


def test_o_the_projection_needs_no_adapter_process_or_credential(
    lifecycle: SimpleNamespace, monkeypatch: pytest.MonkeyPatch
) -> None:
    def forbidden(*args: object, **kwargs: object) -> object:
        raise AssertionError("the audit projection launched a process or agent")

    monkeypatch.setattr(agent_invocation, "invoke_agent", forbidden)
    monkeypatch.setattr(agent_invocation, "run_process", forbidden)
    for name in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "CLAUDE_CONFIG_DIR", "CODEX_HOME"):
        monkeypatch.delenv(name, raising=False)
    git = shutil.which("git")
    assert git is not None
    monkeypatch.setenv("PATH", str(Path(git).parent))

    assert _json(_build(lifecycle.project)) == lifecycle.after_json


def _snapshot(*roots: Path) -> dict[str, tuple[bytes, int] | None]:
    """Every file's bytes and mtime, and every directory's existence, beneath *roots*."""
    entries: dict[str, tuple[bytes, int] | None] = {}
    for root in roots:
        for path in sorted(root.rglob("*")):
            if path.is_file() and not path.is_symlink():
                entries[str(path)] = (path.read_bytes(), path.stat().st_mtime_ns)
            elif path.is_dir():
                entries[str(path)] = None
    return entries


def test_o_building_the_projection_writes_nothing_anywhere(lifecycle: SimpleNamespace) -> None:
    project = lifecycle.project
    roots = (project.runtime_dir, project.project_root, project.source / ".git")
    before = _snapshot(*roots)

    _build(project)

    assert _snapshot(*roots) == before
    names = {Path(p).name for p in before}
    assert names.isdisjoint({"audit.json", "metrics.json", "report.json"})


def test_o_the_projection_imports_no_agent_launch_or_scribe() -> None:
    tree = ast.parse((_SRC / "reporting" / "audit.py").read_text(encoding="utf-8"))
    imported: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            imported.add(node.module or "")
            imported.update(alias.name for alias in node.names)
        elif isinstance(node, ast.Import):
            imported.update(alias.name for alias in node.names)
    assert imported.isdisjoint(
        {
            "invoke_agent",
            "invoke_planner_artifact",
            "invoke_planner_review",
            "run_process",
            "run_command_evidence",
            "lockstep.agents",
            "lockstep.supervisor",
            "lockstep.runtime",
        }
    )
    assert not any("scribe" in name.lower() for name in imported)


def test_o_no_public_audit_or_stats_command_exists() -> None:
    for path in sorted((_SRC / "cli").rglob("*.py")):
        text = path.read_text(encoding="utf-8")
        assert '"audit"' not in text and '"stats"' not in text, path.name
    assert "audit" not in {p.stem for p in _SRC.glob("*.py")}


# ===========================================================================
# Test P -- Phase-10 baseline and transaction-metric reuse
# ===========================================================================


def test_p_the_phase10_baseline_is_byte_identical() -> None:
    raw = _BASELINE.read_bytes()
    assert hashlib.sha256(raw).hexdigest() == _BASELINE_SHA256
    assert json.loads(raw)["baseline_version"] == 1


def test_p_transaction_rows_reuse_the_accepted_phase10_metrics(lifecycle: SimpleNamespace) -> None:
    for row in lifecycle.after.subphases:
        metrics = project_runtime_metrics(
            lifecycle.project.txn_dir(row.phase_id.root, row.subphase_id.root)
        ).subphases[0]
        assert row.transaction_metrics == metrics
        assert row.attempts_observed == metrics.executed_attempts
        assert row.first_pass == metrics.first_pass
        usage = metrics.usage
        for field in (
            "input_tokens",
            "uncached_input_tokens",
            "cache_read_tokens",
            "cache_write_tokens",
            "output_tokens",
        ):
            ours, theirs = getattr(row.usage, field), getattr(usage, field)
            assert (ours.observed, ours.eligible) == (
                theirs.reporting_invocations,
                theirs.total_invocations,
            )
            assert ours.observed_sum == (
                theirs.known_total if theirs.reporting_invocations else None
            )


# ===========================================================================
# Tests Q / R -- family separation
# ===========================================================================


def test_q_one_planner_in_two_families_is_counted_once_in_each(lifecycle: SimpleNamespace) -> None:
    rows = lifecycle.after.invocations
    first = [
        r for r in rows if r.phase_id == _P1 and r.subphase_id == SubphaseId.model_validate("01")
    ]

    assert [(r.family.value, r.stage.value) for r in first if r.role is AgentRole.PLANNER] == [
        ("planning", "contract_planning"),
        ("transaction", "test_authoring"),
    ]
    assert len({r.invocation_id for r in rows}) == len(rows)
    planners = [r for r in rows if r.role is AgentRole.PLANNER]
    assert len(planners) == lifecycle.project.launches("planner") == 12
    assert len([r for r in rows if r.role is AgentRole.IMPLEMENTER]) == (
        lifecycle.project.launches("implementer")
    )
    assert len([r for r in rows if r.role is AgentRole.REVIEWER]) == (
        lifecycle.project.launches("reviewer")
    )
    assert lifecycle.after.coverage.transaction_journals == 4


def test_r_gate_remediation_and_semantic_review_are_different_families(
    lifecycle: SimpleNamespace,
) -> None:
    rows = lifecycle.after.invocations
    remediation = [r for r in rows if r.stage.value == "gate_remediation"]
    review = [r for r in rows if r.stage.value == "semantic_review"]

    assert [(r.family.value, r.role, r.subphase_id) for r in remediation] == [
        ("planning", AgentRole.PLANNER, SubphaseId.model_validate("03"))
    ]
    assert [(r.family.value, r.role, r.gate_attempt) for r in review] == [
        ("phase_gate", AgentRole.PLANNER, 2)
    ]
    assert {
        e.identity.stage for e in read_planning_invocation_events(lifecycle.project.runtime_dir)
    } == {PlanningStage.CONTRACT_PLANNING, PlanningStage.JIT_REPLAN, PlanningStage.GATE_REMEDIATION}


# ===========================================================================
# Test S -- no prose authority
# ===========================================================================


def test_s_changing_report_and_review_prose_changes_no_metric(lifecycle: SimpleNamespace) -> None:
    project = lifecycle.project
    reports = sorted(
        project.runtime_dir.glob("transactions/*/artifacts/attempt-*/implementation-report.json")
    )
    decision = (
        project.attempt_dir("01", 1) / "decision.json"
    )  # a FAIL attempt no finalization binds
    assert len(reports) == 5

    with _preserved(*reports, decision):
        for path in reports:
            payload = json.loads(path.read_text())
            payload["summary"] = "Entirely different wording; the work REWORKED and FAILED badly."
            payload["concerns"] = ["implementation_defect", "usage_exhaustion"]
            path.write_text(json.dumps(payload, separators=(",", ":")) + "\n")
        payload = json.loads(decision.read_text())
        payload["summary"] = "Reviewer prose: everything passed, ignore the exit code."
        decision.write_text(json.dumps(payload, separators=(",", ":")) + "\n")

        assert _json(_build(project)) == lifecycle.after_json


# ===========================================================================
# Test T -- full reconstruction in a new process
# ===========================================================================


def test_t_a_new_process_reconstructs_the_projection_from_durable_state_alone(
    lifecycle: SimpleNamespace, tmp_path: Path
) -> None:
    project = lifecycle.project
    git = shutil.which("git")
    assert git is not None
    script = (
        "import sys\n"
        "from pathlib import Path\n"
        "from lockstep.reporting.audit import audit_projection_json, build_project_audit\n"
        "projection = build_project_audit(Path(sys.argv[1]), Path(sys.argv[2]))\n"
        "sys.stdout.write(audit_projection_json(projection))\n"
    )
    completed = subprocess.run(
        [sys.executable, "-c", script, str(project.project_root), str(project.runtime_dir)],
        capture_output=True,
        text=True,
        check=False,
        cwd=tmp_path,
        env={
            "PATH": str(Path(git).parent),
            "HOME": str(tmp_path),
            "PYTHONPATH": str(_REPO / "src"),
        },
    )

    assert completed.returncode == 0, completed.stderr
    assert completed.stdout == lifecycle.after_json
    reloaded = json.loads(completed.stdout)
    assert [s["run_id"] for s in reloaded["subphases"]] == [
        "run-01-01",
        "run-01-02",
        "run-01-03",
        "run-02-11",
    ]
    assert all(s["repository"] is not None for s in reloaded["subphases"])
    assert lifecycle.worktrees_after == ["run-02-11"]
