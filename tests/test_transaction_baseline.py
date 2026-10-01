"""Planner-authored qualification of the Phase 10 transaction baseline (Sub-phase 10.7).

Question under test: can Lockstep reconstruct the real cost and outcome of a
Sub-phase from authoritative machine evidence alone?

Every journal here is produced by the real Supervisor transaction machinery
(``run_single_subphase_transaction_with_retry_checkpoint`` and
``resume_single_subphase_transaction``) driving the real ``ClaudeAdapter``
against fake ``claude`` executables that emit result envelopes. Nothing is
hand-built: the journal is written by the code being qualified, then reloaded
from ``events.jsonl`` alone and projected through ``project_runtime_metrics``
and the 10.6 stats projection.

Expected values are derived independently from each scenario definition (the
scripted responses and fixture usage below) and frozen in
``tests/baselines/transaction_baseline.json`` (``baseline_version`` 1). Nothing
is compared to another call of the projector alone.

Scenarios (fixture usage as ``uncached / cache-read / cache-write / output``):

    attempt-1-success        Planner(10/100/0/5)  Impl(20/200/30/40)  Review(5/50/0/10)
    rework-retry-success     above, REWORK, resume: Impl2(8/80/0/12) Review2(4/40/0/6)
    failed-transaction       attempt-1 REWORK with retry budget 1 -> exhausted
    failed-provider-process  Implementer exits 1 (usage 7/70/0/0) -> aborted
    missing-telemetry        Planner full, Implementer no envelope, Reviewer partial

Baseline classification: every test is GREEN_CHARACTERIZATION (the accepted
10.1-10.6 system already satisfies it; no production change is required). The
10.1-10.6 suites remain the GREEN_REGRESSION guard.
"""

from __future__ import annotations

import ast
import json
import re
import shutil
import time
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import pytest
from test_supervisor_resume_execution import (
    _IMPL_CORRECT,
    _TEST_FILE_RED,
    _budget,
    _git,
    _halt_with_checkpoint,
    _implementer_completed_response,
    _invocation_count,
    _planner_authoring_response,
    _prepare_scenario,
    _reviewer_turn_completed_response,
    _Scenario,
)

from lockstep.agent_turn import AgentTurnError
from lockstep.domain import AgentRole, ExecutionEventKind, InvocationStage
from lockstep.git import RepositoryChange, measure_repository_change
from lockstep.metrics import (
    RunMetrics,
    UsageAggregate,
    project_run_metrics,
    project_runtime_metrics,
)
from lockstep.persistence import ExecutionEvent, read_events, read_state
from lockstep.reporting import project_runtime_stats, render_stats
from lockstep.state import WorkflowState
from lockstep.supervisor.transaction import (
    SingleSubphaseTransactionResult,
    resume_single_subphase_transaction,
    run_single_subphase_transaction_with_retry_checkpoint,
)

_BASELINE_PATH = Path(__file__).parent / "baselines" / "transaction_baseline.json"
_REPO_ROOT = Path(__file__).resolve().parent.parent

_SCENARIO_NAMES = (
    "attempt-1-success",
    "rework-retry-success",
    "failed-transaction",
    "failed-provider-process",
    "missing-telemetry",
)

_UNAVAILABLE_NAMES = [
    "escalation_categories",
    "non_generated_diff",
    "planner_implementer_disagreement",
    "test_counts",
]

# A first draft that passes verification but is judged to need rework.
_IMPL_ATTEMPT_1_VERBOSE = "def answer() -> int:\n    half = 21\n    return half + half\n"


# ---------------------------------------------------------------------------
# Fixture usage (the only provider telemetry in these scenarios)
# ---------------------------------------------------------------------------


def _usage(
    uncached: int | None,
    cache_read: int | None,
    cache_write: int | None,
    output: int | None,
) -> dict[str, int]:
    fields = {
        "input_tokens": uncached,
        "cache_read_input_tokens": cache_read,
        "cache_creation_input_tokens": cache_write,
        "output_tokens": output,
    }
    return {name: value for name, value in fields.items() if value is not None}


_PLANNER_USAGE = _usage(10, 100, 0, 5)
_IMPLEMENTER_USAGE = _usage(20, 200, 30, 40)
_REVIEWER_USAGE = _usage(5, 50, 0, 10)
_IMPLEMENTER_2_USAGE = _usage(8, 80, 0, 12)
_REVIEWER_2_USAGE = _usage(4, 40, 0, 6)
_FAILED_IMPLEMENTER_USAGE = _usage(7, 70, 0, 0)
# Reports only the two fields a minimal CLI result exposes.
_PARTIAL_REVIEWER_USAGE = _usage(5, None, None, 10)


def _envelope(response: dict[str, object], usage: dict[str, int]) -> dict[str, object]:
    """Wrap a fake provider response in a ``claude -p`` result envelope."""
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


def _failing(response: dict[str, object]) -> dict[str, object]:
    return {**response, "returncode": 1}


# ---------------------------------------------------------------------------
# Scenario execution
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class _Run:
    name: str
    scenario: _Scenario
    change: RepositoryChange | None
    final_state: WorkflowState | None

    @property
    def runtime_dir(self) -> Path:
        return self.scenario.request.runtime_dir

    @property
    def journal(self) -> Path:
        return self.runtime_dir / "events.jsonl"

    def launches(self, role: str) -> int:
        bin_dir = getattr(self.scenario, f"{role}_bin")
        return _invocation_count(bin_dir, f"claude-{role}")


def _accepted_change(worktree: Path) -> RepositoryChange:
    """Measure the accepted implementation commit against the frozen test commit."""
    test_sha = _git(worktree, "rev-parse", "HEAD~1").stdout.strip()
    impl_sha = _git(worktree, "rev-parse", "HEAD").stdout.strip()
    subjects = _git(worktree, "log", "--format=%s", "-2").stdout.splitlines()
    assert subjects == [
        "feat(feature): implement answer",
        "test(feature): freeze answer expectation",
    ]
    return measure_repository_change(worktree, test_sha, impl_sha)


def _state(runtime_dir: Path) -> WorkflowState | None:
    state = read_state(runtime_dir / "state.json")
    return state.workflow_state if state is not None else None


def _run_attempt_1_success(root: Path) -> _Run:
    scenario = _prepare_scenario(
        root,
        planner_responses=[_envelope(_planner_authoring_response(_TEST_FILE_RED), _PLANNER_USAGE)],
        implementer_responses=[
            _envelope(
                _implementer_completed_response({"feature.py": _IMPL_CORRECT}), _IMPLEMENTER_USAGE
            )
        ],
        reviewer_responses=[_envelope(_reviewer_turn_completed_response(), _REVIEWER_USAGE)],
    )
    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )
    assert isinstance(result, SingleSubphaseTransactionResult)
    change = measure_repository_change(
        result.worktree_root,
        result.test_commit.commit_sha,
        result.implementation_commit.commit_sha,
    )
    assert change == _accepted_change(result.worktree_root)
    return _Run("attempt-1-success", scenario, change, _state(scenario.request.runtime_dir))


def _run_rework_retry_success(root: Path) -> _Run:
    scenario = _prepare_scenario(
        root,
        planner_responses=[_envelope(_planner_authoring_response(_TEST_FILE_RED), _PLANNER_USAGE)],
        implementer_responses=[
            _envelope(
                _implementer_completed_response({"feature.py": _IMPL_ATTEMPT_1_VERBOSE}),
                _IMPLEMENTER_USAGE,
            ),
            _envelope(
                _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
                _IMPLEMENTER_2_USAGE,
            ),
        ],
        reviewer_responses=[
            _envelope(
                _reviewer_turn_completed_response(
                    attempt=1, verdict="rework", summary="simplify the implementation"
                ),
                _REVIEWER_USAGE,
            ),
            _envelope(
                _reviewer_turn_completed_response(attempt=2, verdict="approve"),
                _REVIEWER_2_USAGE,
            ),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))
    # Waiting time between the halt and the resume is part of wall clock by design.
    time.sleep(0.3)
    resumed = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert resumed.final_state is not None
    assert resumed.final_state.workflow_state is WorkflowState.SUBPHASE_COMPLETE
    return _Run(
        "rework-retry-success",
        scenario,
        _accepted_change(scenario.request.worktree_path),
        _state(scenario.request.runtime_dir),
    )


def _run_failed_transaction(root: Path) -> _Run:
    scenario = _prepare_scenario(
        root,
        planner_responses=[_envelope(_planner_authoring_response(_TEST_FILE_RED), _PLANNER_USAGE)],
        implementer_responses=[
            _envelope(
                _implementer_completed_response({"feature.py": _IMPL_CORRECT}), _IMPLEMENTER_USAGE
            )
        ],
        reviewer_responses=[
            _envelope(
                _reviewer_turn_completed_response(attempt=1, verdict="rework", summary="not good"),
                _REVIEWER_USAGE,
            )
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(1))
    return _Run("failed-transaction", scenario, None, _state(scenario.request.runtime_dir))


def _run_failed_provider_process(root: Path) -> _Run:
    scenario = _prepare_scenario(
        root,
        planner_responses=[_envelope(_planner_authoring_response(_TEST_FILE_RED), _PLANNER_USAGE)],
        implementer_responses=[
            _envelope(
                _failing(_implementer_completed_response({"feature.py": _IMPL_CORRECT})),
                _FAILED_IMPLEMENTER_USAGE,
            )
        ],
    )
    with pytest.raises(AgentTurnError):
        run_single_subphase_transaction_with_retry_checkpoint(
            scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
        )
    return _Run("failed-provider-process", scenario, None, _state(scenario.request.runtime_dir))


def _run_missing_telemetry(root: Path) -> _Run:
    scenario = _prepare_scenario(
        root,
        planner_responses=[_envelope(_planner_authoring_response(_TEST_FILE_RED), _PLANNER_USAGE)],
        # No envelope at all: a provider result that exposes no usage fields.
        implementer_responses=[_implementer_completed_response({"feature.py": _IMPL_CORRECT})],
        reviewer_responses=[
            _envelope(_reviewer_turn_completed_response(), _PARTIAL_REVIEWER_USAGE)
        ],
    )
    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )
    assert isinstance(result, SingleSubphaseTransactionResult)
    change = measure_repository_change(
        result.worktree_root,
        result.test_commit.commit_sha,
        result.implementation_commit.commit_sha,
    )
    return _Run("missing-telemetry", scenario, change, _state(scenario.request.runtime_dir))


_BUILDERS: dict[str, Callable[[Path], _Run]] = {
    "attempt-1-success": _run_attempt_1_success,
    "rework-retry-success": _run_rework_retry_success,
    "failed-transaction": _run_failed_transaction,
    "failed-provider-process": _run_failed_provider_process,
    "missing-telemetry": _run_missing_telemetry,
}


@pytest.fixture(scope="module")
def runs(tmp_path_factory: pytest.TempPathFactory) -> dict[str, _Run]:
    """Execute every scenario once through the real transaction path."""
    return {
        name: _BUILDERS[name](tmp_path_factory.mktemp(name.replace("-", "_")) / "s")
        for name in _SCENARIO_NAMES
    }


# ---------------------------------------------------------------------------
# Durable reload seam: only ``events.jsonl`` crosses it
# ---------------------------------------------------------------------------


def _reload_dir(run: _Run, tmp_path: Path) -> Path:
    """A fresh directory holding a byte copy of the journal and nothing else.

    No state.json, retry checkpoint, claim, planning store, worktree or
    in-memory transaction object survives. This is the closest deterministic
    boundary to a process restart the current API offers (the journal path is
    the only input); it is weaker than a literal restart.
    """
    fresh = tmp_path / f"reload-{run.name}"
    fresh.mkdir(exist_ok=True)
    shutil.copyfile(run.journal, fresh / "events.jsonl")
    assert sorted(path.name for path in fresh.iterdir()) == ["events.jsonl"]
    return fresh


def _reloaded(run: _Run, tmp_path: Path) -> RunMetrics:
    return project_runtime_metrics(_reload_dir(run, tmp_path), repository_change=run.change)


# ---------------------------------------------------------------------------
# Independent normalization of metrics into the baseline vocabulary
# ---------------------------------------------------------------------------


def _pair(ratio_like: object) -> list[int]:
    numerator = getattr(ratio_like, "numerator")  # noqa: B009
    denominator = getattr(ratio_like, "denominator")  # noqa: B009
    return [numerator, denominator]


def _triple(aggregate: UsageAggregate) -> list[int]:
    return [aggregate.known_total, aggregate.reporting_invocations, aggregate.total_invocations]


def _view(run: RunMetrics) -> dict[str, object]:
    """Project metrics onto the stable semantic vocabulary the baseline freezes."""
    m = run.totals
    [sub] = run.subphases
    roles = (AgentRole.PLANNER, AgentRole.IMPLEMENTER, AgentRole.REVIEWER)
    return {
        "subphases_attempted": m.subphases_attempted,
        "subphases_completed": m.subphases_completed,
        "executed_attempts": m.executed_attempts,
        "first_pass_approval": _pair(m.first_pass_approval_rate),
        "rework_rate": _pair(m.rework_rate),
        "attempts_per_success": _pair(m.attempts_per_success),
        "repeated_attempts": m.repeated_attempts,
        "repeated_attempt_rate": _pair(m.repeated_attempt_rate),
        "repeated_invocations": m.repeated_invocations,
        "invocations_by_role": {r.value: m.invocations_by_role.get(r, 0) for r in roles},
        "invocations_by_stage": {
            s.value: sub.invocations_by_stage.get(s, 0) for s in InvocationStage
        },
        "total_invocations": m.total_invocations,
        "planner_invocations_per_success": _pair(m.planner_invocations_per_success),
        "implementer_invocations_per_success": _pair(m.implementer_invocations_per_success),
        "reviewer_invocations_per_success": _pair(m.reviewer_invocations_per_success),
        "baseline_verification_runs": m.baseline_verification_runs,
        "implementation_verification_runs": m.implementation_verification_runs,
        "implementation_verification_runs_per_success": _pair(
            m.implementation_verification_runs_per_success
        ),
        "wall_clock_reporting": [
            m.completed_wall_clock.reporting_invocations,
            m.completed_wall_clock.total_invocations,
        ],
        "elapsed_reporting": [
            m.usage.elapsed.reporting_invocations,
            m.usage.elapsed.total_invocations,
        ],
        "providers": _dist(m.usage.providers),
        "configured_models": _dist(m.usage.configured_models),
        "configured_efforts": _dist(m.usage.configured_efforts),
        "reported_models": _dist(m.usage.reported_models),
        "quota": _dist(m.usage.quota),
        "usage": {
            "input_tokens": _triple(m.usage.input_tokens),
            "uncached_input_tokens": _triple(m.usage.uncached_input_tokens),
            "cache_read_tokens": _triple(m.usage.cache_read_tokens),
            "cache_write_tokens": _triple(m.usage.cache_write_tokens),
            "output_tokens": _triple(m.usage.output_tokens),
        },
        "failure_cause_events": {k.value: v for k, v in m.failure_cause_events.items()},
        "failure_cause_subphases": {k.value: v for k, v in m.failure_cause_subphases.items()},
        "stop_reason_events": {k.value: v for k, v in m.stop_reason_events.items()},
        "stop_reason_subphases": {k.value: v for k, v in m.stop_reason_subphases.items()},
        "human_intervention_events": m.human_intervention_events,
        "human_intervention_subphases": m.human_intervention_subphases,
        "repository": {
            "files_changed": _triple(m.repository.files_changed),
            "lines_added": _triple(m.repository.lines_added),
            "lines_deleted": _triple(m.repository.lines_deleted),
            "binary_files_changed": _triple(m.repository.binary_files_changed),
        },
    }


def _dist(distribution: object) -> dict[str, object]:
    return {
        "counts": dict(getattr(distribution, "counts")),  # noqa: B009
        "unreported": getattr(distribution, "unreported"),  # noqa: B009
    }


def _baseline() -> dict[str, object]:
    loaded = json.loads(_BASELINE_PATH.read_text(encoding="utf-8"))
    assert isinstance(loaded, dict)
    return loaded


def _journal_kinds(run: _Run) -> Counter[ExecutionEventKind]:
    return Counter(
        event.kind for event in read_events(run.journal) if isinstance(event, ExecutionEvent)
    )


# ===========================================================================
# AC-10.7-01 -- the journals come from the real transaction machinery
# ===========================================================================

_EXPECTED_LAUNCHES: dict[str, dict[str, int]] = {
    "attempt-1-success": {"planner": 1, "implementer": 1, "reviewer": 1},
    "rework-retry-success": {"planner": 1, "implementer": 2, "reviewer": 2},
    "failed-transaction": {"planner": 1, "implementer": 1, "reviewer": 1},
    "failed-provider-process": {"planner": 1, "implementer": 1, "reviewer": 0},
    "missing-telemetry": {"planner": 1, "implementer": 1, "reviewer": 1},
}


@pytest.mark.parametrize("name", _SCENARIO_NAMES)
def test_projected_invocations_equal_real_provider_process_launches(
    runs: dict[str, _Run], name: str
) -> None:
    run = runs[name]
    projected = project_runtime_metrics(run.runtime_dir).totals

    launched = {role: run.launches(role) for role in ("planner", "implementer", "reviewer")}

    # Independent evidence: the fake executables count their own launches.
    assert launched == _EXPECTED_LAUNCHES[name]
    assert {
        role.value: projected.invocations_by_role.get(role, 0)
        for role in (AgentRole.PLANNER, AgentRole.IMPLEMENTER, AgentRole.REVIEWER)
    } == launched
    assert projected.total_invocations == sum(launched.values())


@pytest.mark.parametrize("name", _SCENARIO_NAMES)
def test_journals_carry_the_real_transaction_lifecycle(runs: dict[str, _Run], name: str) -> None:
    kinds = _journal_kinds(runs[name])
    assert kinds[ExecutionEventKind.INVOCATION_STARTED] == sum(_EXPECTED_LAUNCHES[name].values())
    assert (
        kinds[ExecutionEventKind.INVOCATION_RETURNED]
        == kinds[ExecutionEventKind.INVOCATION_STARTED]
    )
    assert kinds[ExecutionEventKind.BASELINE_VERIFIED] == 1
    assert kinds[ExecutionEventKind.TESTS_FROZEN] == 1


def test_scenario_terminal_workflow_states_are_the_transaction_outcomes(
    runs: dict[str, _Run],
) -> None:
    assert {name: run.final_state for name, run in runs.items()} == {
        "attempt-1-success": WorkflowState.SUBPHASE_COMPLETE,
        "rework-retry-success": WorkflowState.SUBPHASE_COMPLETE,
        "failed-transaction": WorkflowState.HALTED,
        "failed-provider-process": WorkflowState.HALTED,
        "missing-telemetry": WorkflowState.SUBPHASE_COMPLETE,
    }


# ===========================================================================
# AC-10.7-17/18/19 -- the frozen baseline artifact
# ===========================================================================


def test_baseline_artifact_is_versioned_and_names_exactly_the_qualified_scenarios() -> None:
    baseline = _baseline()
    assert baseline["baseline_version"] == 1
    scenarios = baseline["scenarios"]
    assert isinstance(scenarios, dict)
    assert tuple(scenarios) == _SCENARIO_NAMES


@pytest.mark.parametrize("name", _SCENARIO_NAMES)
def test_reconstructed_metrics_equal_the_frozen_baseline(
    runs: dict[str, _Run], tmp_path: Path, name: str
) -> None:
    scenarios = _baseline()["scenarios"]
    assert isinstance(scenarios, dict)

    assert _view(_reloaded(runs[name], tmp_path)) == scenarios[name]


def test_baseline_artifact_excludes_unstable_incidental_values() -> None:
    text = _BASELINE_PATH.read_text(encoding="utf-8")

    assert not re.search(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}", text)  # uuid-shaped ids
    assert not re.search(r"\d{4}-\d{2}-\d{2}T", text)  # absolute timestamps
    assert not re.search(r"\d{8}-\d{3}", text)  # run ids
    assert not re.search(r"[0-9a-f]{40}", text)  # commit shas
    for incidental in ("/tmp", "session", "seconds", "elapsed_seconds", "occurred_at", "sequence"):
        assert incidental not in text.replace("elapsed_reporting", "")


def test_baseline_artifact_declares_the_unsupported_metrics_once() -> None:
    assert _baseline()["unavailable"] == _UNAVAILABLE_NAMES


@pytest.mark.parametrize("name", _SCENARIO_NAMES)
def test_unsupported_metrics_stay_unavailable_with_reasons(
    runs: dict[str, _Run], tmp_path: Path, name: str
) -> None:
    metrics = _reloaded(runs[name], tmp_path).totals

    assert sorted(metrics.unavailable) == _UNAVAILABLE_NAMES
    assert all(reason.strip() for reason in metrics.unavailable.values())
    rendered = render_stats(project_runtime_stats(_reload_dir(runs[name], tmp_path)))
    for unavailable in _UNAVAILABLE_NAMES:
        assert any(
            line.startswith(f"{unavailable}: unavailable — ") for line in rendered.splitlines()
        )


# ===========================================================================
# AC-10.7-02 -- Scenario A, attempt-1 success (explicit, not only via the artifact)
# ===========================================================================


def test_attempt_1_success_is_one_first_pass_attempt(runs: dict[str, _Run]) -> None:
    run = project_runtime_metrics(runs["attempt-1-success"].runtime_dir)
    [sub] = run.subphases
    m = run.totals

    assert (m.subphases_attempted, m.subphases_completed) == (1, 1)
    assert sub.executed_attempts == 1
    assert (m.first_pass_approval_rate.numerator, m.first_pass_approval_rate.denominator) == (1, 1)
    assert sub.reworked is False
    assert sub.repeated_attempts == 0
    assert sub.repeated_invocations == 0
    assert dict(sub.invocations_by_stage) == {
        InvocationStage.TEST_AUTHORING: 1,
        InvocationStage.IMPLEMENTATION: 1,
        InvocationStage.REVIEW: 1,
    }
    assert (sub.baseline_verification_runs, sub.implementation_verification_runs) == (1, 1)
    assert m.failure_cause_events == {}
    assert m.stop_reason_events == {}


def test_attempt_1_success_usage_is_attributed_exactly(runs: dict[str, _Run]) -> None:
    usage = project_runtime_metrics(runs["attempt-1-success"].runtime_dir).totals.usage

    # Planner 10/100/0/5 + Implementer 20/200/30/40 + Reviewer 5/50/0/10.
    assert (usage.uncached_input_tokens.known_total, usage.uncached_input_tokens.complete) == (
        35,
        True,
    )
    assert usage.cache_read_tokens.known_total == 350
    assert usage.cache_write_tokens.known_total == 30
    assert usage.input_tokens.known_total == 110 + 250 + 55
    assert usage.output_tokens.known_total == 55
    assert dict(usage.providers.counts) == {"claude": 3}
    assert dict(usage.reported_models.counts) == {"claude-fixture": 3}
    assert dict(usage.configured_models.counts) == {"role-model": 3}


# ===========================================================================
# AC-10.7-03/04 -- Scenario B, rework -> retry/resume -> success
# ===========================================================================


def test_rework_retry_counts_two_attempts_and_five_invocations_once(
    runs: dict[str, _Run],
) -> None:
    run = project_runtime_metrics(runs["rework-retry-success"].runtime_dir)
    [sub] = run.subphases
    m = run.totals

    assert (m.subphases_attempted, m.subphases_completed) == (1, 1)
    assert sub.executed_attempts == 2
    assert sub.repeated_attempts == 1
    assert (m.first_pass_approval_rate.numerator, m.first_pass_approval_rate.denominator) == (0, 1)
    assert sub.reworked is True
    assert {role.value: n for role, n in sub.invocations_by_role.items()} == {
        "planner": 1,
        "implementer": 2,
        "reviewer": 2,
    }
    assert m.total_invocations == 5
    # Only attempt-2 invocations are repeated work; attempt-1 work did not disappear.
    assert sub.repeated_invocations == 2
    assert sub.implementation_verification_runs == 2
    assert sub.baseline_verification_runs == 1


def test_rework_retry_usage_counts_attempt_2_exactly_once(runs: dict[str, _Run]) -> None:
    usage = project_runtime_metrics(runs["rework-retry-success"].runtime_dir).totals.usage

    # attempt 1: 10/100/0/5 + 20/200/30/40 + 5/50/0/10; attempt 2: 8/80/0/12 + 4/40/0/6.
    assert usage.uncached_input_tokens.known_total == 35 + 12
    assert usage.cache_read_tokens.known_total == 350 + 120
    assert usage.cache_write_tokens.known_total == 30
    assert usage.input_tokens.known_total == 415 + 88 + 44
    assert usage.output_tokens.known_total == 55 + 18
    assert usage.input_tokens.total_invocations == 5
    assert usage.input_tokens.complete is True


def test_retry_resume_lifecycle_events_are_each_present_once_and_add_no_invocations(
    runs: dict[str, _Run],
) -> None:
    kinds = _journal_kinds(runs["rework-retry-success"])

    for lifecycle in (
        ExecutionEventKind.RETRY_AUTHORIZED,
        ExecutionEventKind.RESUME_CLAIMED,
        ExecutionEventKind.RESUME_STARTED,
        ExecutionEventKind.RESUME_SETTLED,
        ExecutionEventKind.TRANSACTION_HALTED,
    ):
        assert kinds[lifecycle] == 1, lifecycle
    assert kinds[ExecutionEventKind.INVOCATION_STARTED] == 5
    assert kinds[ExecutionEventKind.INVOCATION_RETURNED] == 5

    events = [
        e
        for e in read_events(runs["rework-retry-success"].journal)
        if isinstance(e, ExecutionEvent)
    ]
    started_ids = [
        e.invocation_id for e in events if e.kind is ExecutionEventKind.INVOCATION_STARTED
    ]
    assert len(set(started_ids)) == 5  # one canonical invocation_id per real provider call


def test_replaying_the_journal_twice_does_not_inflate_attempts_invocations_or_usage(
    runs: dict[str, _Run],
) -> None:
    events = read_events(runs["rework-retry-success"].journal)

    once = project_run_metrics(events).totals
    twice = project_run_metrics([*events, *events]).totals

    assert twice.executed_attempts == once.executed_attempts == 2
    assert twice.total_invocations == once.total_invocations == 5
    assert twice.invocations_by_role == once.invocations_by_role
    assert twice.repeated_invocations == once.repeated_invocations
    assert twice.usage.model_dump() == once.usage.model_dump()


def test_removing_resume_lifecycle_events_changes_neither_attempts_nor_invocations(
    runs: dict[str, _Run],
) -> None:
    lifecycle = {
        ExecutionEventKind.RETRY_AUTHORIZED,
        ExecutionEventKind.RESUME_CLAIMED,
        ExecutionEventKind.RESUME_STARTED,
        ExecutionEventKind.RESUME_SETTLED,
    }
    events = read_events(runs["rework-retry-success"].journal)
    stripped = [e for e in events if not (isinstance(e, ExecutionEvent) and e.kind in lifecycle)]

    with_lifecycle = project_run_metrics(events).totals
    without = project_run_metrics(stripped).totals

    # Attempt 2 is still evidenced by its INVOCATION_STARTED, so no authority or
    # claim event is what makes it count.
    assert without.executed_attempts == with_lifecycle.executed_attempts == 2
    assert without.total_invocations == with_lifecycle.total_invocations == 5


def test_failure_cause_survives_and_event_multiplicity_is_not_collapsed(
    runs: dict[str, _Run],
) -> None:
    m = project_runtime_metrics(runs["rework-retry-success"].runtime_dir).totals
    cause = next(iter(m.failure_cause_events))

    # REVIEW_DECIDED, TRANSACTION_HALTED and RETRY_AUTHORIZED each carry the cause.
    assert cause.value == "implementation_defect"
    assert m.failure_cause_events[cause] == 3
    assert m.failure_cause_subphases[cause] == 1
    assert m.stop_reason_events == {}


def test_completion_is_distinct_from_prior_halt_and_rework_evidence(
    runs: dict[str, _Run],
) -> None:
    run = runs["rework-retry-success"]
    kinds = _journal_kinds(run)
    metrics = project_runtime_metrics(run.runtime_dir).totals

    assert kinds[ExecutionEventKind.TRANSACTION_HALTED] == 1
    assert kinds[ExecutionEventKind.REVIEW_DECIDED] == 2  # REWORK then APPROVE
    assert run.final_state is WorkflowState.SUBPHASE_COMPLETE
    assert metrics.subphases_completed == 1


def test_accepted_commit_change_excludes_the_reworked_attempt(runs: dict[str, _Run]) -> None:
    run = runs["rework-retry-success"]

    assert run.change == RepositoryChange(
        files_changed=1, lines_added=2, lines_deleted=0, binary_files_changed=0
    )
    totals = project_runtime_metrics(run.runtime_dir, repository_change=run.change).totals
    # Attempt 1's 3-line draft was never committed, so it is not repository change.
    assert totals.repository.lines_added.known_total == 2


# ===========================================================================
# AC-10.7-05/06/11/12 -- failed / abandoned work stays attributable
# ===========================================================================


def test_retry_exhaustion_keeps_consumed_work_cause_and_stop_reason(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    m = _reloaded(runs["failed-transaction"], tmp_path).totals

    assert (m.subphases_attempted, m.subphases_completed) == (1, 0)
    assert m.total_invocations == 3
    assert m.usage.input_tokens.known_total == 415
    assert m.usage.elapsed.reporting_invocations == 3
    assert {k.value: v for k, v in m.failure_cause_events.items()} == {"implementation_defect": 3}
    assert {k.value: v for k, v in m.failure_cause_subphases.items()} == {
        "implementation_defect": 1
    }
    assert {k.value: v for k, v in m.stop_reason_events.items()} == {"max_rework_exceeded": 1}
    assert {k.value: v for k, v in m.stop_reason_subphases.items()} == {"max_rework_exceeded": 1}


@pytest.mark.parametrize("name", ["failed-transaction", "failed-provider-process"])
def test_zero_success_ratios_are_undefined_not_zero(
    runs: dict[str, _Run], tmp_path: Path, name: str
) -> None:
    m = _reloaded(runs[name], tmp_path).totals

    for ratio in (
        m.first_pass_approval_rate,
        m.attempts_per_success,
        m.planner_invocations_per_success,
        m.implementer_invocations_per_success,
        m.reviewer_invocations_per_success,
        m.implementation_verification_runs_per_success,
    ):
        assert ratio.denominator == 0
        assert ratio.value is None
    assert m.completed_wall_clock.reporting_invocations == 0
    assert m.completed_wall_clock.total_invocations == 0
    # Raw consumption is not erased by the absence of a success.
    assert m.total_invocations > 0
    assert m.usage.input_tokens.known_total > 0
    assert m.usage.elapsed.known_total_seconds > 0.0


def test_failed_provider_process_still_contributes_its_usage_and_timing(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    m = _reloaded(runs["failed-provider-process"], tmp_path).totals

    assert (m.subphases_attempted, m.subphases_completed) == (1, 0)
    assert {role.value: n for role, n in m.invocations_by_role.items()} == {
        "planner": 1,
        "implementer": 1,
    }
    # Planner 10/100/0/5 + failed Implementer 7/70/0/0: the failed call's tokens count.
    assert m.usage.uncached_input_tokens.known_total == 17
    assert m.usage.cache_read_tokens.known_total == 170
    assert m.usage.input_tokens.known_total == 187
    assert m.usage.input_tokens.complete is True
    assert m.usage.elapsed.reporting_invocations == 2
    assert {k.value: v for k, v in m.failure_cause_events.items()} == {
        "provider_process_failure": 1
    }
    assert {k.value: v for k, v in m.failure_cause_subphases.items()} == {
        "provider_process_failure": 1
    }
    assert m.implementation_verification_runs == 0


def test_failed_provider_process_records_no_typed_stop_reason(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    # Observed baseline fact: this path attributes a FailureCause but emits no
    # TRANSACTION_ABORTED/StopReason, so none is invented.
    m = _reloaded(runs["failed-provider-process"], tmp_path).totals

    assert m.stop_reason_events == {}
    assert m.stop_reason_subphases == {}


def test_failure_cause_and_stop_reason_remain_separate_after_reload(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    m = _reloaded(runs["failed-transaction"], tmp_path).totals

    cause_names = {c.value for c in m.failure_cause_events}
    stop_names = {s.value for s in m.stop_reason_events}
    assert cause_names == {"implementation_defect"}
    assert stop_names == {"max_rework_exceeded"}
    assert cause_names.isdisjoint(stop_names)


# ===========================================================================
# AC-10.7-09/10 -- missing provider telemetry is tolerated and never zero
# ===========================================================================


def test_missing_telemetry_transaction_still_completes_and_projects(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    run = runs["missing-telemetry"]
    m = _reloaded(run, tmp_path).totals

    assert run.final_state is WorkflowState.SUBPHASE_COMPLETE
    assert (m.subphases_attempted, m.subphases_completed) == (1, 1)
    assert m.total_invocations == 3
    assert dict(m.usage.providers.counts) == {"claude": 3}
    assert m.usage.providers.unreported == 0
    assert dict(m.usage.configured_models.counts) == {"role-model": 3}
    # Host-observed process timing exists for all three even without provider usage.
    assert m.usage.elapsed.reporting_invocations == 3


def test_missing_telemetry_reports_incomplete_coverage_without_false_zeros(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    usage = _reloaded(runs["missing-telemetry"], tmp_path).totals.usage

    assert usage.input_tokens.reporting_invocations < usage.input_tokens.total_invocations
    for aggregate in (
        usage.input_tokens,
        usage.uncached_input_tokens,
        usage.cache_read_tokens,
        usage.cache_write_tokens,
        usage.output_tokens,
    ):
        assert aggregate.total_invocations == 3
        assert aggregate.complete is False
    # Known usage from the invocations that did report remains available.
    assert usage.input_tokens.known_total == 110
    assert usage.uncached_input_tokens.known_total == 15
    assert usage.output_tokens.known_total == 15
    assert dict(usage.reported_models.counts) == {"claude-fixture": 2}
    assert usage.reported_models.unreported == 1


def test_positive_zero_and_unavailable_are_three_distinct_states(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    usage = _reloaded(runs["missing-telemetry"], tmp_path).totals.usage

    positive = usage.cache_read_tokens  # reported 100 by the Planner only
    zero = usage.cache_write_tokens  # provider-reported 0 by the Planner only

    assert (positive.known_total, positive.reporting_invocations) == (100, 1)
    # A reported zero still counts as reporting; the two silent invocations do not.
    assert (zero.known_total, zero.reporting_invocations, zero.total_invocations) == (0, 1, 3)
    assert zero.complete is False


def test_failed_provider_process_reports_a_provider_reported_zero(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    usage = _reloaded(runs["failed-provider-process"], tmp_path).totals.usage

    # The failed Implementer reported 0 output tokens and 0 cache writes: reporting, not absent.
    assert usage.cache_write_tokens.known_total == 0
    assert usage.cache_write_tokens.reporting_invocations == 2
    assert usage.cache_write_tokens.complete is True
    assert usage.output_tokens.known_total == 5


def test_stats_projection_stays_honest_about_partial_coverage(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    rendered = render_stats(project_runtime_stats(_reload_dir(runs["missing-telemetry"], tmp_path)))
    lines = rendered.splitlines()

    assert "Input tokens: 110 known — 1 / 3 invocations reporting — INCOMPLETE" in lines
    assert "Uncached input tokens: 15 known — 2 / 3 invocations reporting — INCOMPLETE" in lines
    assert "Cache-read tokens: 100 known — 1 / 3 invocations reporting — INCOMPLETE" in lines
    assert "Cache-write tokens: 0 known — 1 / 3 invocations reporting — INCOMPLETE" in lines
    assert "Output tokens: 15 known — 2 / 3 invocations reporting — INCOMPLETE" in lines
    assert (
        "Reported models (provider-reported, not merged with configured): "
        "claude-fixture 2, unreported 1"
    ) in lines


# ===========================================================================
# AC-10.7-07/08 -- durable, deterministic reconstruction
# ===========================================================================


@pytest.mark.parametrize("name", _SCENARIO_NAMES)
def test_reconstruction_from_the_journal_alone_matches_the_original_directory(
    runs: dict[str, _Run], tmp_path: Path, name: str
) -> None:
    run = runs[name]

    in_place = project_runtime_metrics(run.runtime_dir, repository_change=run.change)
    reloaded = _reloaded(run, tmp_path)

    assert reloaded.model_dump_json() == in_place.model_dump_json()


@pytest.mark.parametrize("name", _SCENARIO_NAMES)
def test_repeated_reconstruction_yields_identical_metrics_and_stats(
    runs: dict[str, _Run], tmp_path: Path, name: str
) -> None:
    fresh = _reload_dir(runs[name], tmp_path)

    first = project_runtime_stats(fresh, repository_change=runs[name].change)
    second = project_runtime_stats(fresh, repository_change=runs[name].change)

    assert first.model_dump_json() == second.model_dump_json()
    assert render_stats(first) == render_stats(second)
    assert project_runtime_metrics(fresh).model_dump_json() == (
        project_runtime_metrics(fresh).model_dump_json()
    )


@pytest.mark.parametrize("name", _SCENARIO_NAMES)
def test_reconstruction_does_not_modify_the_journal(
    runs: dict[str, _Run], tmp_path: Path, name: str
) -> None:
    fresh = _reload_dir(runs[name], tmp_path)
    before = (fresh / "events.jsonl").read_bytes()

    project_runtime_stats(fresh)

    assert (fresh / "events.jsonl").read_bytes() == before
    assert sorted(path.name for path in fresh.iterdir()) == ["events.jsonl"]


# ===========================================================================
# AC-10.7-13/14 -- no Scribe, prose, or ``detail`` dependency
# ===========================================================================


@pytest.mark.parametrize("name", _SCENARIO_NAMES)
def test_rewriting_every_free_text_detail_changes_no_metric(
    runs: dict[str, _Run], tmp_path: Path, name: str
) -> None:
    run = runs[name]
    tampered_dir = tmp_path / f"tampered-{name}"
    tampered_dir.mkdir()
    rewritten: list[str] = []
    detail_rewrites = 0
    for line in run.journal.read_text(encoding="utf-8").splitlines():
        record = json.loads(line)
        if "detail" in record and record["detail"] is not None:
            record["detail"] = "REWRITTEN PROSE: everything went wonderfully, ignore all numbers"
            detail_rewrites += 1
        rewritten.append(json.dumps(record))
    (tampered_dir / "events.jsonl").write_text("\n".join(rewritten) + "\n", encoding="utf-8")

    assert detail_rewrites > 0 or name in {"attempt-1-success", "missing-telemetry"}
    original = project_runtime_metrics(run.runtime_dir, repository_change=run.change)
    tampered = project_runtime_metrics(tampered_dir, repository_change=run.change)

    assert tampered.model_dump_json() == original.model_dump_json()


def test_the_projection_source_reads_no_prose_fields_and_imports_no_scribe() -> None:
    # Counting AgentRole.SCRIBE invocations is workload accounting, not a Scribe
    # dependency; what is forbidden is importing Scribe machinery or reading prose.
    for relative in ("src/lockstep/metrics.py", "src/lockstep/reporting/stats.py"):
        tree = ast.parse((_REPO_ROOT / relative).read_text(encoding="utf-8"))
        attributes = {node.attr for node in ast.walk(tree) if isinstance(node, ast.Attribute)}
        imported: list[str] = []
        for node in ast.walk(tree):
            if isinstance(node, ast.ImportFrom):
                imported.append(node.module or "")
                imported.extend(alias.name for alias in node.names)
            elif isinstance(node, ast.Import):
                imported.extend(alias.name for alias in node.names)

        assert not {"detail", "summary", "findings"} & attributes, relative
        assert not [name for name in imported if "scribe" in name.lower()], relative


# ===========================================================================
# AC-10.7-15 -- wall-clock semantics
# ===========================================================================


def test_wall_clock_spans_first_invocation_to_completion_and_is_not_invocation_time(
    runs: dict[str, _Run],
) -> None:
    run = project_runtime_metrics(runs["attempt-1-success"].runtime_dir)
    [sub] = run.subphases

    assert sub.wall_clock_seconds is not None
    elapsed = sub.usage.elapsed.known_total_seconds
    assert elapsed > 0.0
    # Verification and commit work sit inside the window but outside any invocation.
    assert sub.wall_clock_seconds >= elapsed
    assert run.totals.completed_wall_clock.known_total_seconds == sub.wall_clock_seconds


def test_wall_clock_includes_halted_waiting_time_as_distinct_from_invocation_time(
    runs: dict[str, _Run],
) -> None:
    run = project_runtime_metrics(runs["rework-retry-success"].runtime_dir)
    [sub] = run.subphases

    assert sub.wall_clock_seconds is not None
    # The fixture waited 0.3s between the halt and the resume.
    assert sub.wall_clock_seconds - sub.usage.elapsed.known_total_seconds >= 0.3


def test_stats_label_wall_clock_as_including_halted_and_waiting_time(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    rendered = render_stats(
        project_runtime_stats(_reload_dir(runs["rework-retry-success"], tmp_path))
    )

    [line] = [
        candidate
        for candidate in rendered.splitlines()
        if candidate.startswith("Completed Sub-phase wall clock")
    ]
    assert "first invocation start through SUBPHASE_COMPLETE; includes halted/waiting time" in line
    assert line.endswith("1 / 1 completed Sub-phases reporting — complete")
    assert "Invocation elapsed:" in rendered


# ===========================================================================
# AC-10.7-16 -- repository-change evidence
# ===========================================================================


def test_repository_change_derives_from_the_accepted_commit_objects(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    run = runs["attempt-1-success"]
    assert run.change == RepositoryChange(
        files_changed=1, lines_added=2, lines_deleted=0, binary_files_changed=0
    )

    repository = _reloaded(run, tmp_path).totals.repository

    assert _triple(repository.files_changed) == [1, 1, 1]
    assert _triple(repository.lines_added) == [2, 1, 1]
    assert _triple(repository.lines_deleted) == [0, 1, 1]
    assert _triple(repository.binary_files_changed) == [0, 1, 1]


def test_repository_change_without_commit_evidence_is_unavailable_not_fabricated(
    runs: dict[str, _Run],
) -> None:
    repository = project_runtime_metrics(runs["attempt-1-success"].runtime_dir).totals.repository

    # Completed, but no commit boundary was supplied: coverage 0 / 1, never a zero change.
    assert _triple(repository.files_changed) == [0, 0, 1]
    assert repository.files_changed.complete is False


@pytest.mark.parametrize("name", ["failed-transaction", "failed-provider-process"])
def test_uncompleted_transactions_have_no_repository_change(
    runs: dict[str, _Run], tmp_path: Path, name: str
) -> None:
    assert runs[name].change is None
    repository = _reloaded(runs[name], tmp_path).totals.repository

    assert _triple(repository.files_changed) == [0, 0, 0]
    assert _triple(repository.lines_added) == [0, 0, 0]


# ===========================================================================
# AC-10.7-20 -- the stats projection agrees with the metrics
# ===========================================================================

_EXPECTED_STATS_LINES: dict[str, tuple[str, ...]] = {
    "attempt-1-success": (
        "Sub-phases attempted: 1",
        "Sub-phases completed: 1",
        "First-pass approval (completed Sub-phases): 1 / 1 (100.0%)",
        "Rework rate (reviewed Sub-phases): 0 / 1 (0.0%)",
        "Attempts per success: 1 / 1 (1.00)",
        "Repeated-attempt rate (executed attempts): 0 / 1 (0.0%)",
        "Repeated invocations: 0",
        "Total invocations: 3",
        "Input tokens: 415 known — 3 / 3 invocations reporting — complete",
        "Cache-write tokens: 30 known — 3 / 3 invocations reporting — complete",
        "Output tokens: 55 known — 3 / 3 invocations reporting — complete",
        "== Failure / rework causes ==\nnone recorded\n== Stop reasons ==\nnone recorded",
    ),
    "rework-retry-success": (
        "Sub-phases attempted: 1",
        "Sub-phases completed: 1",
        "First-pass approval (completed Sub-phases): 0 / 1 (0.0%)",
        "Rework rate (reviewed Sub-phases): 1 / 1 (100.0%)",
        "Attempts per success: 2 / 1 (2.00)",
        "Repeated-attempt rate (executed attempts): 1 / 2 (50.0%)",
        "Repeated invocations: 2",
        "Implementer invocations: 2 (per success: 2 / 1 (2.00))",
        "Total invocations: 5",
        "Implementation verification runs: 2 (per success: 2 / 1 (2.00))",
        "Input tokens: 547 known — 5 / 5 invocations reporting — complete",
        "implementation_defect: events 3, affected Sub-phases 1",
    ),
    "failed-transaction": (
        "Sub-phases attempted: 1",
        "Sub-phases completed: 0",
        "First-pass approval (completed Sub-phases): undefined (0 / 0)",
        "Rework rate (reviewed Sub-phases): 1 / 1 (100.0%)",
        "Attempts per success: undefined (0 / 0)",
        "Total invocations: 3",
        "Input tokens: 415 known — 3 / 3 invocations reporting — complete",
        "implementation_defect: events 3, affected Sub-phases 1",
        "max_rework_exceeded: events 1, affected Sub-phases 1",
    ),
    "failed-provider-process": (
        "Sub-phases attempted: 1",
        "Sub-phases completed: 0",
        "First-pass approval (completed Sub-phases): undefined (0 / 0)",
        "Rework rate (reviewed Sub-phases): undefined (0 / 0)",
        "Reviewer invocations: 0 (per success: undefined (0 / 0))",
        "Total invocations: 2",
        "Input tokens: 187 known — 2 / 2 invocations reporting — complete",
        "provider_process_failure: events 1, affected Sub-phases 1",
    ),
    "missing-telemetry": (
        "Sub-phases attempted: 1",
        "Sub-phases completed: 1",
        "First-pass approval (completed Sub-phases): 1 / 1 (100.0%)",
        "Total invocations: 3",
        "Input tokens: 110 known — 1 / 3 invocations reporting — INCOMPLETE",
    ),
}


@pytest.mark.parametrize("name", _SCENARIO_NAMES)
def test_rendered_stats_pin_the_semantic_lines(
    runs: dict[str, _Run], tmp_path: Path, name: str
) -> None:
    rendered = render_stats(project_runtime_stats(_reload_dir(runs[name], tmp_path)))
    lines = rendered.splitlines()

    for expected in _EXPECTED_STATS_LINES[name]:
        if "\n" in expected:
            assert expected in rendered
        else:
            assert expected in lines, expected


@pytest.mark.parametrize("name", _SCENARIO_NAMES)
def test_structured_stats_carry_the_same_values_as_the_metrics(
    runs: dict[str, _Run], tmp_path: Path, name: str
) -> None:
    fresh = _reload_dir(runs[name], tmp_path)

    projection = project_runtime_stats(fresh, repository_change=runs[name].change)
    metrics = project_runtime_metrics(fresh, repository_change=runs[name].change)

    assert projection.metrics == metrics.totals
    assert projection.scope.run_count == 1
    assert projection.scope.run_ids == (metrics.run_id,)
    assert json.loads(projection.model_dump_json())["metrics"] == json.loads(
        metrics.totals.model_dump_json()
    )


def test_stats_projection_has_no_monetary_or_opinion_vocabulary(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    for name in _SCENARIO_NAMES:
        rendered = render_stats(project_runtime_stats(_reload_dir(runs[name], tmp_path))).lower()
        for forbidden in ("$", "usd", "cost", "price", "dollar"):
            assert forbidden not in rendered, (name, forbidden)
