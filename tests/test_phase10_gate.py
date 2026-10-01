"""Phase 10 integration gate (Sub-phase 10.8): audit-only qualification.

This suite composes the accepted 10.7 transaction harness; it adds no
production behavior and no second harness. Every journal is written by the real
transaction machinery against fake provider executables and then reloaded from
``events.jsonl`` alone.

Classification of each test (see ``.local/audits/phase-10-gate/gate-report.md``):

* GREEN_REGRESSION / GREEN_CHARACTERIZATION -- qualifies accepted behavior.
* ``test_gate_*_RED`` -- a required gate assertion that is RED against the
  accepted system. These are *gate-failure evidence*, deliberately not weakened
  and not repaired inside the gate (plan section 15).
"""

from __future__ import annotations

import ast
from collections import Counter
from pathlib import Path

import pytest
from test_supervisor_implementer_blocker import _implementer_blocked_response
from test_supervisor_resume_execution import (
    _TEST_FILE_RED,
    _budget,
    _implementer_completed_response,
    _planner_authoring_response,
    _prepare_scenario,
)
from test_transaction_baseline import (
    _BUILDERS,
    _IMPLEMENTER_USAGE,
    _PLANNER_USAGE,
    _SCENARIO_NAMES,
    _envelope,
    _failing,
    _reload_dir,
    _reloaded,
    _Run,
    _state,
)

import lockstep.agents.invocation as invocation_module
from lockstep.agent_turn import AgentTurnError
from lockstep.agents.invocation import AdapterOutput
from lockstep.domain import (
    AgentRole,
    ExecutionEventKind,
    FailureCause,
    InvocationUsage,
    ProviderTelemetry,
    QuotaStatus,
    StopReason,
)
from lockstep.escalation import EscalationAuthority, EscalationCategory
from lockstep.failure import cause_for_invocation_failure
from lockstep.metrics import project_runtime_metrics
from lockstep.persistence import ExecutionEvent, read_events
from lockstep.reporting import project_runtime_stats, render_stats
from lockstep.state import WorkflowState
from lockstep.supervisor.transaction import run_single_subphase_transaction_with_retry_checkpoint

_SRC = Path(__file__).resolve().parent.parent / "src" / "lockstep"
_BASELINE = Path(__file__).parent / "baselines" / "transaction_baseline.json"

# Workflow states in which the durable record still says "work is in progress".
_ACTIVE = frozenset(
    {
        WorkflowState.TEST_AUTHORING,
        WorkflowState.TEST_BASELINE_VERIFY,
        WorkflowState.TEST_COMMIT,
        WorkflowState.IMPLEMENTING,
        WorkflowState.TEST_REVIEW,
        WorkflowState.VERIFYING,
        WorkflowState.REVIEWING,
        WorkflowState.IMPLEMENTATION_COMMIT,
    }
)


@pytest.fixture(scope="module")
def runs(tmp_path_factory: pytest.TempPathFactory) -> dict[str, _Run]:
    """The accepted 10.7 scenarios, built by the 10.7 builders (not re-implemented)."""
    return {
        name: _BUILDERS[name](tmp_path_factory.mktemp(name.replace("-", "_")) / "s")
        for name in _SCENARIO_NAMES
    }


def _execution_events(journal: Path) -> list[ExecutionEvent]:
    return [e for e in read_events(journal) if isinstance(e, ExecutionEvent)]


def _kinds(run: _Run) -> Counter[ExecutionEventKind]:
    return Counter(e.kind for e in _execution_events(run.journal))


# ===========================================================================
# A. Attempt-1 success
# ===========================================================================


def test_gate_a_attempt_1_success_is_fully_attributed(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    run = runs["attempt-1-success"]
    m = _reloaded(run, tmp_path).totals

    assert (m.subphases_attempted, m.subphases_completed, m.executed_attempts) == (1, 1, 1)
    assert (m.first_pass_approval_rate.numerator, m.first_pass_approval_rate.denominator) == (1, 1)
    assert (m.rework_rate.numerator, m.rework_rate.denominator) == (0, 1)
    assert m.repeated_attempts == 0
    assert {r.value: n for r, n in m.invocations_by_role.items()} == {
        "planner": 1,
        "implementer": 1,
        "reviewer": 1,
    }
    assert (m.baseline_verification_runs, m.implementation_verification_runs) == (1, 1)
    assert m.failure_cause_events == {} and m.stop_reason_events == {}
    assert m.repository.files_changed.known_total == 1
    assert run.final_state is WorkflowState.SUBPHASE_COMPLETE
    for role in ("planner", "implementer", "reviewer"):
        assert run.launches(role) == 1


def test_gate_a_in_place_projection_equals_durable_reconstruction(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    for run in runs.values():
        in_place = project_runtime_metrics(run.runtime_dir, repository_change=run.change)
        assert in_place == _reloaded(run, tmp_path)


# ===========================================================================
# B. REVIEW_REWORK  /  C. retry-resume safety
# ===========================================================================


def test_gate_b_rework_explains_why_work_repeated(runs: dict[str, _Run], tmp_path: Path) -> None:
    run = runs["rework-retry-success"]
    rm = _reloaded(run, tmp_path)
    m = rm.totals
    [sub] = rm.subphases

    assert sub.first_pass is False and sub.reworked is True and sub.completed is True
    assert m.executed_attempts == 2 and m.repeated_attempts == 1
    assert m.repeated_invocations == 2
    assert {r.value: n for r, n in m.invocations_by_role.items()} == {
        "planner": 1,
        "implementer": 2,
        "reviewer": 2,
    }
    assert {c.value for c in m.failure_cause_subphases} == {"implementation_defect"}
    assert m.failure_cause_subphases[FailureCause.IMPLEMENTATION_DEFECT] == 1
    assert m.stop_reason_events == {}
    assert run.final_state is WorkflowState.SUBPHASE_COMPLETE


def test_gate_c_retry_resume_is_at_most_once_and_counted_once(runs: dict[str, _Run]) -> None:
    run = runs["rework-retry-success"]
    kinds = _kinds(run)

    for kind in (
        ExecutionEventKind.RETRY_AUTHORIZED,
        ExecutionEventKind.RESUME_CLAIMED,
        ExecutionEventKind.RESUME_STARTED,
        ExecutionEventKind.RESUME_SETTLED,
    ):
        assert kinds[kind] == 1, kind
    assert kinds[ExecutionEventKind.INVOCATION_STARTED] == 5
    assert kinds[ExecutionEventKind.INVOCATION_RETURNED] == 5
    # One real provider launch per recorded invocation: journal vs. executable counters.
    assert (run.launches("planner"), run.launches("implementer"), run.launches("reviewer")) == (
        1,
        2,
        2,
    )
    ids = [
        e.invocation_id
        for e in _execution_events(run.journal)
        if e.kind is ExecutionEventKind.INVOCATION_STARTED
    ]
    assert len(ids) == len(set(ids)) == 5
    # Attempt 2 attribution is carried by the real invocations themselves.
    attempts = Counter(
        (e.role, e.attempt.root if e.attempt is not None else None)
        for e in _execution_events(run.journal)
        if e.kind is ExecutionEventKind.INVOCATION_STARTED
    )
    assert attempts[(AgentRole.IMPLEMENTER, 1)] == attempts[(AgentRole.IMPLEMENTER, 2)] == 1
    assert attempts[(AgentRole.REVIEWER, 1)] == attempts[(AgentRole.REVIEWER, 2)] == 1


# ===========================================================================
# D. Blocker / escalation
# ===========================================================================


@pytest.fixture(scope="module")
def blocker_run(tmp_path_factory: pytest.TempPathFactory) -> _Run:
    scenario = _prepare_scenario(
        tmp_path_factory.mktemp("gate_blocker") / "s",
        planner_responses=[_envelope(_planner_authoring_response(_TEST_FILE_RED), _PLANNER_USAGE)],
        implementer_responses=[
            _envelope(
                _implementer_blocked_response(
                    category=EscalationCategory.REQUIREMENT_AMBIGUITY,
                    requested_authority=EscalationAuthority.HUMAN,
                ),
                _IMPLEMENTER_USAGE,
            )
        ],
    )
    run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )
    return _Run("blocker", scenario, None, _state(scenario.request.runtime_dir))


def test_gate_d_blocker_is_attributed_with_cause_stop_reason_and_halt(
    blocker_run: _Run, tmp_path: Path
) -> None:
    run = blocker_run
    events = _execution_events(run.journal)
    kinds = _kinds(run)

    assert run.final_state is WorkflowState.HALTED
    assert kinds[ExecutionEventKind.ESCALATION_DISPATCHED] == 1
    assert kinds[ExecutionEventKind.TRANSACTION_HALTED] == 1
    [halt] = [e for e in events if e.kind is ExecutionEventKind.TRANSACTION_HALTED]
    assert halt.cause is FailureCause.REQUIREMENT_AMBIGUITY
    assert halt.stop_reason is StopReason.REQUIREMENT_AMBIGUITY
    # The blocking invocation is identified by role/attempt/stage.
    blocked = [
        e
        for e in events
        if e.kind is ExecutionEventKind.INVOCATION_STARTED and e.role is AgentRole.IMPLEMENTER
    ]
    assert (
        len(blocked) == 1
        and blocked[0].attempt is not None
        and blocked[0].attempt.root == 1
        and blocked[0].stage is not None
    )
    assert run.launches("implementer") == 1

    m = _reloaded(run, tmp_path).totals
    assert m.stop_reason_events == {StopReason.REQUIREMENT_AMBIGUITY: 1}
    assert FailureCause.REQUIREMENT_AMBIGUITY in m.failure_cause_events
    assert m.subphases_completed == 0
    # Accepted, documented omission: no typed escalation-category metric.
    assert "escalation_categories" in m.unavailable


# ===========================================================================
# E. Provider failure -- RED gate assertions (PRODUCT_DEFECT evidence)
# ===========================================================================


def test_gate_e_provider_failure_retains_consumed_work_and_cause(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    run = runs["failed-provider-process"]
    kinds = _kinds(run)
    m = _reloaded(run, tmp_path).totals

    assert kinds[ExecutionEventKind.INVOCATION_STARTED] == 2
    assert kinds[ExecutionEventKind.INVOCATION_RETURNED] == 2
    assert m.failure_cause_events == {FailureCause.PROVIDER_PROCESS_FAILURE: 1}
    assert m.usage.input_tokens.known_total == 187  # failed call's tokens are counted
    assert m.usage.elapsed.reporting_invocations == 2
    assert "provider_process_failure" in render_stats(
        project_runtime_stats(_reload_dir(run, tmp_path))
    )


def test_gate_e_RED_failed_provider_transaction_has_a_non_active_durable_disposition(
    runs: dict[str, _Run],
) -> None:
    """AC-10.8-06: after an irrecoverable provider failure the durable state must not read active.

    Observed: the exception escapes ``invoke_agent_turn`` for attempt 1, no
    HALTED transition and no TRANSACTION_HALTED/ABORTED event is written, and
    ``state.json`` still says IMPLEMENTING -- indistinguishable from live work.
    """
    run = runs["failed-provider-process"]
    terminal = (
        _kinds(run)[ExecutionEventKind.TRANSACTION_HALTED]
        + _kinds(run)[ExecutionEventKind.TRANSACTION_ABORTED]
    )

    assert run.final_state not in _ACTIVE, f"durable state still active: {run.final_state}"
    assert terminal >= 1, "no terminal/recovery disposition event in the journal"


# ===========================================================================
# F. Quota exhaustion
# ===========================================================================


def test_gate_f_taxonomy_maps_authoritative_exhaustion_but_never_infers_it() -> None:
    exhausted = InvocationUsage(
        provider="claude",
        termination=invocation_module.ProcessTermination.EXITED,
        exit_code=1,
        quota_status=QuotaStatus.EXHAUSTED,
    )
    unknown = exhausted.model_copy(update={"quota_status": QuotaStatus.UNKNOWN})

    assert cause_for_invocation_failure(exhausted) is FailureCause.USAGE_EXHAUSTION
    assert cause_for_invocation_failure(unknown) is FailureCause.PROVIDER_PROCESS_FAILURE


def test_gate_f_RED_an_adapter_can_supply_an_authoritative_quota_signal() -> None:
    """MISSING_REQUIRED_SEAM: no production path can carry ``EXHAUSTED`` into a usage record.

    ``AdapterOutput``/``ProviderTelemetry`` have no quota field and
    ``_build_usage`` never sets ``quota_status``, so it is always UNKNOWN.
    """
    fields = set(ProviderTelemetry.model_fields) | set(AdapterOutput.__dataclass_fields__)
    assert any("quota" in name for name in fields), sorted(fields)


def test_gate_f_RED_authoritative_exhaustion_yields_a_safe_non_active_disposition(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Narrowest fixture: wrap the real ``_build_usage`` so its record is EXHAUSTED.

    The classification half passes (USAGE_EXHAUSTION is journaled); the
    disposition half is RED for the same reason as provider failure.
    """
    real = invocation_module._build_usage

    def exhausted(*args: object, **kwargs: object) -> InvocationUsage:
        usage = real(*args, **kwargs)  # type: ignore[arg-type]
        return usage.model_copy(update={"quota_status": QuotaStatus.EXHAUSTED})

    monkeypatch.setattr(invocation_module, "_build_usage", exhausted)
    scenario = _prepare_scenario(
        tmp_path / "s",
        planner_responses=[_envelope(_planner_authoring_response(_TEST_FILE_RED), _PLANNER_USAGE)],
        implementer_responses=[
            _envelope(
                _failing(_implementer_completed_response({"feature.py": "x = 1\n"})),
                _IMPLEMENTER_USAGE,
            )
        ],
    )
    with pytest.raises(AgentTurnError):
        run_single_subphase_transaction_with_retry_checkpoint(
            scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
        )
    runtime_dir = scenario.request.runtime_dir
    returned = [
        e
        for e in _execution_events(runtime_dir / "events.jsonl")
        if e.kind is ExecutionEventKind.INVOCATION_RETURNED and e.role is AgentRole.IMPLEMENTER
    ]
    assert [e.cause for e in returned] == [FailureCause.USAGE_EXHAUSTION]  # classification works
    assert _state(runtime_dir) not in _ACTIVE, "exhaustion left the transaction durably active"


# ===========================================================================
# H. Phase-gate event: no executable Phase Integration Gate action exists
# ===========================================================================


def test_gate_h_no_executable_phase_integration_gate_exists() -> None:
    """DEFERRED_BY_DEPENDENCY -> Phase 11.5: nothing but the state graph names the gate."""
    users = [
        str(path.relative_to(_SRC))
        for path in _SRC.rglob("*.py")
        if "PHASE_INTEGRATION_GATE" in path.read_text()
    ]
    assert users == ["state/machine.py"]
    for path in _SRC.rglob("*.py"):
        for node in ast.walk(ast.parse(path.read_text())):
            if isinstance(node, ast.FunctionDef):
                assert "integration_gate" not in node.name, (path, node.name)


# ===========================================================================
# Missing telemetry / no prose / money
# ===========================================================================


def test_gate_missing_telemetry_stays_unknown_not_zero(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    # Reuses the frozen 10.7 scenario rather than a new fixture.
    m = _reloaded(runs["attempt-1-success"], tmp_path).totals
    assert set(m.usage.quota.counts) == {"unknown"}
    assert m.usage.quota.unreported == 0


def test_gate_stats_are_deterministic_and_carry_no_monetary_vocabulary(
    runs: dict[str, _Run], tmp_path: Path
) -> None:
    for run in runs.values():
        first = render_stats(project_runtime_stats(_reload_dir(run, tmp_path)))
        (tmp_path / "again").mkdir(exist_ok=True)
        second = render_stats(project_runtime_stats(_reload_dir(run, tmp_path / "again")))
        assert first == second
        assert "$" not in first and "cost" not in first.lower()


def test_gate_baseline_artifact_is_still_version_1() -> None:
    import json

    assert json.loads(_BASELINE.read_text())["baseline_version"] == 1
