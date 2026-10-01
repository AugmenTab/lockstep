"""Planner-authored specification of Sub-phase 10.2 per-stage structured execution events.

Pins the contract that significant transaction stages are recorded as typed
``ExecutionEvent`` entries in the existing authoritative event journal, at
the moment the owning deterministic action occurs, correlated to the 10.1
``InvocationIdentity`` where an agent invocation is involved.

Event contract (public surface under test):

* ``lockstep.domain.ExecutionEventKind`` / ``ExecutionOutcome`` -- bounded enums.
* ``lockstep.persistence.ExecutionEvent`` -- a member of the ``LockstepEvent``
  union (``event_type == "execution"``); OBSERVATIONAL: it advances the
  journal sequence but never changes replayed workflow state.
* ``lockstep.persistence.record_execution_event`` -- the sole emission helper.
* ``lockstep.agents.invoke_agent(..., runtime_dir=...)`` -- when the request
  carries an identity and ``runtime_dir`` has a journal, emits
  ``INVOCATION_STARTED`` immediately before process launch and
  ``INVOCATION_RETURNED`` after the process returns.

Baseline classification (pre-implementation): every test in this module is RED
(collection ``ImportError``: ``ExecutionEventKind`` not in ``lockstep.domain``).
The Phase 1 journal/replay, Phase 4 transaction, Phase 9 retry/resume and
Reviewer-identity suites plus the 10.1 identity suites are the
GREEN_REGRESSION guard (AC-10.2-09, AC-10.2-18); the journal-length
assertions in them are narrowly updated to count state-driving events only.

Reuses the Phase 9 reviewer-identity harness (fake provider executables, no
network, no real inference).
"""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path

import pytest
from test_supervisor_reviewer_identity import (
    _GENERIC_PROMPT,
    _IMPL_CORRECT,
    _TEST_FILE_RED,
    _blocker_aware_run,
    _budget,
    _build_request,
    _halt_with_checkpoint,
    _implementer_blocked_response,
    _init_source_repo,
    _parent_env,
    _planner_authoring_response,
    _planner_decision_response,
    _post_implementer_resume,
    _prepare_scenario,
    _resume,
    _review_decision_payload,
    _reviewer_completed_response,
    _reviewer_only_resume,
    _script_write,
    _ScriptAdapter,
)

import lockstep.supervisor.transaction as transaction_module
from lockstep.agents import AgentInvocationRequest, AgentInvocationResult
from lockstep.domain import (
    AgentRole,
    ExecutionEventKind,
    ExecutionOutcome,
    InvocationStage,
    ReviewVerdict,
)
from lockstep.escalation_decision import PlannerDecisionKind
from lockstep.persistence import (
    ExecutionEvent,
    StateTransitionedEvent,
    append_event,
    read_events,
    record_execution_event,
    replay_events,
)
from lockstep.state import WorkflowState
from lockstep.supervisor.transaction import (
    ResumeExecutionDisposition,
    SingleSubphaseTransactionResult,
    SupervisorTransactionError,
    resume_single_subphase_transaction,
    run_single_subphase_transaction,
    run_single_subphase_transaction_with_retry_checkpoint,
)

K = ExecutionEventKind


def _exec(runtime_dir: Path) -> list[ExecutionEvent]:
    return [e for e in read_events(runtime_dir / "events.jsonl") if isinstance(e, ExecutionEvent)]


def _kinds(events: list[ExecutionEvent]) -> list[ExecutionEventKind]:
    return [e.kind for e in events]


def _seq_of(runtime_dir: Path, predicate: Callable[[object], bool]) -> int:
    for event in read_events(runtime_dir / "events.jsonl"):
        if predicate(event):
            return event.sequence
    raise AssertionError("no matching event")


def _transition_to(target: WorkflowState) -> Callable[[object], bool]:
    return lambda e: isinstance(e, StateTransitionedEvent) and e.target is target


def _of_kind(kind: ExecutionEventKind) -> Callable[[object], bool]:
    return lambda e: isinstance(e, ExecutionEvent) and e.kind is kind


@pytest.fixture
def seen(monkeypatch: pytest.MonkeyPatch) -> list[AgentInvocationResult]:
    """Record every invocation result across all transports; delegate to the real one."""
    import lockstep.agent_turn as agent_turn_module
    import lockstep.escalation_transport as escalation_transport_module
    import lockstep.reviewer_turn as reviewer_turn_module

    recorded: list[AgentInvocationResult] = []
    real = transaction_module.invoke_agent

    def capture(adapter: object, request: AgentInvocationRequest, **kwargs: object):  # type: ignore[no-untyped-def]
        result = real(adapter, request, **kwargs)  # type: ignore[arg-type]
        recorded.append(result)
        return result

    for module in (
        transaction_module,
        agent_turn_module,
        reviewer_turn_module,
        escalation_transport_module,
    ):
        monkeypatch.setattr(module, "invoke_agent", capture)
    return recorded


# ===========================================================================
# Event model: serialization, journal, replay (AC-01, 12, 13, 16, 17)
# ===========================================================================


def _journal_with_run(tmp_path: Path) -> Path:
    from datetime import UTC, datetime

    from lockstep.domain import ProjectId, RunId
    from lockstep.persistence import RunCreatedEvent

    runtime = tmp_path / "rt"
    runtime.mkdir()
    append_event(
        runtime / "events.jsonl",
        RunCreatedEvent(
            run_id=RunId.model_validate("20260929-014"),
            sequence=1,
            occurred_at=datetime.now(UTC),
            project_id=ProjectId.model_validate("lockstep"),
        ),
    )
    return runtime


def test_execution_event_round_trips_through_the_canonical_journal(tmp_path: Path) -> None:
    runtime = _journal_with_run(tmp_path)

    written = record_execution_event(
        runtime,
        kind=K.BASELINE_VERIFIED,
        outcome=ExecutionOutcome.SUCCESS,
        detail="red",
    )

    assert written is not None
    events = read_events(runtime / "events.jsonl")
    assert len(events) == 2
    assert events[1] == written
    assert isinstance(events[1], ExecutionEvent)
    assert events[1].sequence == 2
    assert events[1].event_type == "execution"
    assert events[1].run_id == events[0].run_id
    assert events[1].kind is K.BASELINE_VERIFIED
    assert events[1].outcome is ExecutionOutcome.SUCCESS


def test_record_execution_event_without_a_journal_is_a_noop(tmp_path: Path) -> None:
    assert record_execution_event(tmp_path, kind=K.TESTS_FROZEN) is None
    assert not (tmp_path / "events.jsonl").exists()


def test_replay_ignores_execution_events_for_workflow_state(tmp_path: Path) -> None:
    runtime = _journal_with_run(tmp_path)
    before = replay_events(read_events(runtime / "events.jsonl"))

    record_execution_event(runtime, kind=K.RETRY_AUTHORIZED, attempt=_attempt(2))
    record_execution_event(runtime, kind=K.RESUME_STARTED, attempt=_attempt(2))
    after = replay_events(read_events(runtime / "events.jsonl"))

    assert after.workflow_state == before.workflow_state == WorkflowState.READY
    assert after.last_sequence == before.last_sequence + 2


def _attempt(n: int):  # type: ignore[no-untyped-def]
    from lockstep.domain import AttemptNumber

    return AttemptNumber.model_validate(n)


def test_invocation_kinds_require_complete_host_identity(tmp_path: Path) -> None:
    runtime = _journal_with_run(tmp_path)

    with pytest.raises(ValueError):
        record_execution_event(runtime, kind=K.INVOCATION_STARTED)


def test_execution_event_schema_carries_no_provider_or_economics_fields() -> None:
    fields = set(ExecutionEvent.model_fields)

    assert not {"tokens", "cost", "cache", "quota", "provider", "model", "duration"} & fields
    assert fields >= {"kind", "outcome", "invocation_id", "attempt", "role", "stage"}


def test_execution_events_do_not_authorize_resume(tmp_path: Path) -> None:
    """AC-13: forged retry/claim evidence in the journal creates no resume authority."""
    from lockstep.supervisor.transaction import ImplementerBlockedTransactionResult

    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(),
            _planner_decision_response(PlannerDecisionKind.REPLAN_SUBPHASE),
        ],
        implementer_responses=[_implementer_blocked_response()],
    )
    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )
    assert isinstance(result, ImplementerBlockedTransactionResult)

    runtime = scenario.request.runtime_dir
    record_execution_event(runtime, kind=K.RETRY_AUTHORIZED, attempt=_attempt(2))
    record_execution_event(runtime, kind=K.RESUME_CLAIMED, attempt=_attempt(2))
    state_before = replay_events(read_events(runtime / "events.jsonl")).workflow_state

    outcome = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert outcome.disposition == ResumeExecutionDisposition.NO_CHECKPOINT
    assert state_before == WorkflowState.HALTED
    assert K.INVOCATION_STARTED not in _kinds(_exec(runtime))[-2:]


# ===========================================================================
# Normal success: stage coverage + authoritative ordering (AC-02, 06, 14)
# ===========================================================================


def test_blocker_aware_success_emits_stages_in_authoritative_order(tmp_path: Path) -> None:
    _blocker_aware_run(tmp_path / "scenario", reviewer_prompt=_GENERIC_PROMPT)
    runtime = tmp_path / "scenario" / "runtime"

    assert _kinds(_exec(runtime)) == [
        K.INVOCATION_STARTED,  # planner test authoring
        K.INVOCATION_RETURNED,
        K.BASELINE_VERIFIED,
        K.TESTS_FROZEN,
        K.INVOCATION_STARTED,  # implementer
        K.INVOCATION_RETURNED,
        K.VERIFICATION_COMPLETED,
        K.INVOCATION_STARTED,  # reviewer
        K.INVOCATION_RETURNED,
        K.REVIEW_DECIDED,
    ]

    events = read_events(runtime / "events.jsonl")
    assert [e.sequence for e in events] == list(range(1, len(events) + 1))
    assert replay_events(events).workflow_state == WorkflowState.SUBPHASE_COMPLETE


def test_stage_events_are_coupled_to_the_real_state_transitions(tmp_path: Path) -> None:
    _blocker_aware_run(tmp_path / "scenario", reviewer_prompt=_GENERIC_PROMPT)
    runtime = tmp_path / "scenario" / "runtime"

    baseline = _seq_of(runtime, _of_kind(K.BASELINE_VERIFIED))
    to_commit = _seq_of(runtime, _transition_to(WorkflowState.TEST_COMMIT))
    frozen = _seq_of(runtime, _of_kind(K.TESTS_FROZEN))
    to_impl = _seq_of(runtime, _transition_to(WorkflowState.IMPLEMENTING))
    assert baseline < to_commit < frozen < to_impl

    verification = _seq_of(runtime, _of_kind(K.VERIFICATION_COMPLETED))
    to_verifying = _seq_of(runtime, _transition_to(WorkflowState.VERIFYING))
    to_reviewing = _seq_of(runtime, _transition_to(WorkflowState.REVIEWING))
    assert to_verifying < verification < to_reviewing

    decided = _seq_of(runtime, _of_kind(K.REVIEW_DECIDED))
    to_impl_commit = _seq_of(runtime, _transition_to(WorkflowState.IMPLEMENTATION_COMMIT))
    assert to_reviewing < decided < to_impl_commit


def test_review_decided_preserves_the_canonical_verdict(tmp_path: Path) -> None:
    _blocker_aware_run(tmp_path / "scenario", reviewer_prompt=_GENERIC_PROMPT)

    decided = [e for e in _exec(tmp_path / "scenario" / "runtime") if e.kind is K.REVIEW_DECIDED]

    assert len(decided) == 1
    assert decided[0].verdict is ReviewVerdict.APPROVE
    assert decided[0].attempt == _attempt(1)
    assert decided[0].role is AgentRole.REVIEWER


def test_legacy_transaction_emits_invocation_and_stage_events(tmp_path: Path) -> None:
    root = tmp_path / "legacy"
    root.mkdir()
    request = _build_request(root, _init_source_repo(root), reviewer_prompt=_GENERIC_PROMPT)
    payload = json.dumps(_review_decision_payload(attempt=1))

    result = run_single_subphase_transaction(
        request,
        parent_env=_parent_env(root),
        planner_adapter=_ScriptAdapter(
            "planner", _script_write("tests/test_feature.py", _TEST_FILE_RED)
        ),
        implementer_adapter=_ScriptAdapter(
            "implementer", _script_write("feature.py", _IMPL_CORRECT)
        ),
        reviewer_adapter=_ScriptAdapter("reviewer", f"import sys\nsys.stdout.write({payload!r})\n"),
    )
    assert isinstance(result, SingleSubphaseTransactionResult)

    assert _kinds(_exec(request.runtime_dir)) == [
        K.INVOCATION_STARTED,
        K.INVOCATION_RETURNED,
        K.BASELINE_VERIFIED,
        K.TESTS_FROZEN,
        K.INVOCATION_STARTED,
        K.INVOCATION_RETURNED,
        K.VERIFICATION_COMPLETED,
        K.INVOCATION_STARTED,
        K.INVOCATION_RETURNED,
        K.REVIEW_DECIDED,
    ]


# ===========================================================================
# Invocation correlation (AC-03, 08)
# ===========================================================================


def test_invocation_events_carry_the_issued_identity(
    tmp_path: Path, seen: list[AgentInvocationResult]
) -> None:
    _blocker_aware_run(tmp_path / "scenario", reviewer_prompt=_GENERIC_PROMPT)
    events = [
        e
        for e in _exec(tmp_path / "scenario" / "runtime")
        if e.kind in (K.INVOCATION_STARTED, K.INVOCATION_RETURNED)
    ]

    identities = [r.identity for r in seen]
    assert len(identities) == 3
    for index, identity in enumerate(identities):
        assert identity is not None
        started, returned = events[2 * index], events[2 * index + 1]
        assert started.kind is K.INVOCATION_STARTED
        assert returned.kind is K.INVOCATION_RETURNED
        for event in (started, returned):
            assert event.run_id == identity.run_id
            assert event.phase_id == identity.phase_id
            assert event.subphase_id == identity.subphase_id
            assert event.attempt == identity.attempt
            assert event.role is identity.role
            assert event.stage is identity.stage
            assert event.invocation_id == identity.invocation_id
        assert returned.outcome is ExecutionOutcome.SUCCESS
        assert returned.returncode == 0

    assert [e.stage for e in events[::2]] == [
        InvocationStage.TEST_AUTHORING,
        InvocationStage.IMPLEMENTATION,
        InvocationStage.REVIEW,
    ]


def test_each_concrete_invocation_is_started_and_returned_exactly_once(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        reviewer_responses=[
            _reviewer_completed_response(attempt=1, verdict="rework"),
            _reviewer_completed_response(attempt=2, verdict="rework"),
            _reviewer_completed_response(attempt=3, verdict="approve"),
        ],
    )
    _halt_with_checkpoint(scenario, max_attempts=3)
    _resume(scenario)
    _resume(scenario)

    events = _exec(scenario.request.runtime_dir)
    started = [
        e.invocation_id.root for e in events if e.kind is K.INVOCATION_STARTED if e.invocation_id
    ]
    returned = [
        e.invocation_id.root for e in events if e.kind is K.INVOCATION_RETURNED if e.invocation_id
    ]

    assert len(started) == 7  # test authoring, 3 implementers, 3 reviewers
    assert len(set(started)) == len(started)
    assert started == returned


# ===========================================================================
# Retry / resume / settlement ordering, attempt > 1 (AC-04, 05, 08, 10)
# ===========================================================================


def test_resumed_implementer_path_emits_retry_resume_and_settlement_in_order(
    tmp_path: Path,
) -> None:
    scenario = _post_implementer_resume(tmp_path / "scenario")
    runtime = scenario.request.runtime_dir

    authorized = [e for e in _exec(runtime) if e.kind is K.RETRY_AUTHORIZED]
    assert len(authorized) == 1
    assert authorized[0].attempt == _attempt(2)
    assert authorized[0].role is AgentRole.IMPLEMENTER
    before = len(_exec(runtime))

    _resume(scenario)

    resumed = _exec(runtime)[before:]
    assert _kinds(resumed) == [
        K.RESUME_CLAIMED,
        K.RESUME_STARTED,
        K.INVOCATION_STARTED,  # implementer attempt 2
        K.INVOCATION_RETURNED,
        K.VERIFICATION_COMPLETED,
        K.INVOCATION_STARTED,  # reviewer attempt 2
        K.INVOCATION_RETURNED,
        K.REVIEW_DECIDED,
        K.RESUME_SETTLED,
    ]
    for event in resumed:
        assert event.attempt == _attempt(2)
    assert resumed[2].role is AgentRole.IMPLEMENTER
    assert resumed[5].role is AgentRole.REVIEWER
    assert resumed[-1].detail == "completed"


def test_resume_started_precedes_the_resumed_invocation_and_follows_the_claim(
    tmp_path: Path,
) -> None:
    scenario = _reviewer_only_resume(tmp_path / "scenario")
    runtime = scenario.request.runtime_dir
    _resume(scenario)

    claimed = _seq_of(runtime, _of_kind(K.RESUME_CLAIMED))
    started = _seq_of(runtime, _of_kind(K.RESUME_STARTED))
    to_reviewing = [
        e.sequence
        for e in read_events(runtime / "events.jsonl")
        if isinstance(e, StateTransitionedEvent)
        and e.source is WorkflowState.HALTED
        and e.target is WorkflowState.REVIEWING
    ]
    resumed_invocation = [
        e.sequence
        for e in _exec(runtime)
        if e.kind is K.INVOCATION_STARTED and e.attempt == _attempt(2)
    ]

    assert len(to_reviewing) == 1
    assert len(resumed_invocation) == 1
    assert claimed < started < resumed_invocation[0]
    # Reviewer-only resume must not launch an Implementer for attempt 2.
    assert not [
        e
        for e in _exec(runtime)
        if e.kind is K.INVOCATION_STARTED
        and e.role is AgentRole.IMPLEMENTER
        and e.attempt == _attempt(2)
    ]


def test_rework_chain_records_non_completed_and_completed_settlements(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        reviewer_responses=[
            _reviewer_completed_response(attempt=1, verdict="rework"),
            _reviewer_completed_response(attempt=2, verdict="rework"),
            _reviewer_completed_response(attempt=3, verdict="approve"),
        ],
    )
    _halt_with_checkpoint(scenario, max_attempts=3)
    _resume(scenario)
    _resume(scenario)
    events = _exec(scenario.request.runtime_dir)

    verdicts = [e.verdict for e in events if e.kind is K.REVIEW_DECIDED]
    assert verdicts == [ReviewVerdict.REWORK, ReviewVerdict.REWORK, ReviewVerdict.APPROVE]
    assert [e.attempt.root for e in events if e.kind is K.REVIEW_DECIDED if e.attempt] == [1, 2, 3]
    assert [e.detail for e in events if e.kind is K.RESUME_SETTLED] == [
        "next_retry",
        "completed",
    ]
    assert [e.attempt.root for e in events if e.kind is K.RETRY_AUTHORIZED if e.attempt] == [2, 3]
    halted = [e for e in events if e.kind is K.TRANSACTION_HALTED]
    assert [e.detail for e in halted] == ["review_rework", "review_rework"]


def test_event_journal_survives_reload_and_replays_to_the_same_state(tmp_path: Path) -> None:
    scenario = _post_implementer_resume(tmp_path / "scenario")
    _resume(scenario)
    runtime = scenario.request.runtime_dir

    events = read_events(runtime / "events.jsonl")
    again = read_events(runtime / "events.jsonl")
    assert events == again
    snapshot = replay_events(events)
    assert snapshot.workflow_state == WorkflowState.SUBPHASE_COMPLETE
    assert snapshot.last_sequence == len(events)
    state_only = tuple(e for e in events if not isinstance(e, ExecutionEvent))
    assert (
        replay_events(
            tuple(
                e.model_copy(update={"sequence": i + 1}) if i else e
                for i, e in enumerate(state_only)
            )
        ).workflow_state
        == snapshot.workflow_state
    )


# ===========================================================================
# Escalation observability (AC-03)
# ===========================================================================


def test_planner_escalation_is_observable_and_correlated(
    tmp_path: Path, seen: list[AgentInvocationResult]
) -> None:
    scenario = _post_implementer_resume(tmp_path / "scenario")
    events = _exec(scenario.request.runtime_dir)

    decisions = [
        e
        for e in events
        if e.stage is InvocationStage.ESCALATION_DECISION
        and e.kind in (K.INVOCATION_STARTED, K.INVOCATION_RETURNED)
    ]
    assert [e.kind for e in decisions] == [K.INVOCATION_STARTED, K.INVOCATION_RETURNED]
    assert decisions[0].role is AgentRole.PLANNER
    assert decisions[0].invocation_id == decisions[1].invocation_id
    planner_decision_ids = [
        r.identity.invocation_id
        for r in seen
        if r.identity is not None and r.identity.stage is InvocationStage.ESCALATION_DECISION
    ]
    assert planner_decision_ids == [decisions[0].invocation_id]

    dispatched = [e for e in events if e.kind is K.ESCALATION_DISPATCHED]
    assert len(dispatched) == 1
    assert dispatched[0].detail == "resume_agent"
    assert dispatched[0].role is AgentRole.IMPLEMENTER
    assert dispatched[0].attempt == _attempt(1)
    runtime = scenario.request.runtime_dir
    decision_returned = _seq_of(
        runtime,
        lambda e: (
            isinstance(e, ExecutionEvent)
            and e.kind is K.INVOCATION_RETURNED
            and e.stage is InvocationStage.ESCALATION_DECISION
        ),
    )
    assert decision_returned < _seq_of(runtime, _of_kind(K.ESCALATION_DISPATCHED))


# ===========================================================================
# Non-success outcomes stay observable (AC-07)
# ===========================================================================


def _legacy_run(
    root: Path,
    *,
    test_body: str,
    implementer_script: str,
    review_attempt: int = 1,
) -> tuple[Path, Callable[[], object]]:
    root.mkdir()
    request = _build_request(root, _init_source_repo(root), reviewer_prompt=_GENERIC_PROMPT)
    payload = json.dumps(_review_decision_payload(attempt=review_attempt))

    def run() -> object:
        return run_single_subphase_transaction(
            request,
            parent_env=_parent_env(root),
            planner_adapter=_ScriptAdapter(
                "planner", _script_write("tests/test_feature.py", test_body)
            ),
            implementer_adapter=_ScriptAdapter("implementer", implementer_script),
            reviewer_adapter=_ScriptAdapter(
                "reviewer", f"import sys\nsys.stdout.write({payload!r})\n"
            ),
        )

    return request.runtime_dir, run


def test_unexpectedly_passing_baseline_is_recorded_as_failed_baseline(tmp_path: Path) -> None:
    runtime, run = _legacy_run(
        tmp_path / "legacy",
        test_body="def test_green():\n    assert True\n",
        implementer_script="pass\n",
    )

    with pytest.raises(SupervisorTransactionError):
        run()

    events = _exec(runtime)
    baseline = [e for e in events if e.kind is K.BASELINE_VERIFIED]
    assert len(baseline) == 1
    assert baseline[0].outcome is ExecutionOutcome.FAILURE
    assert K.TESTS_FROZEN not in _kinds(events)


def test_failed_implementer_process_is_recorded_with_its_returncode(tmp_path: Path) -> None:
    runtime, run = _legacy_run(
        tmp_path / "legacy",
        test_body=_TEST_FILE_RED,
        implementer_script="import sys\nsys.exit(3)\n",
    )

    with pytest.raises(SupervisorTransactionError):
        run()

    events = _exec(runtime)
    returned = [
        e for e in events if e.kind is K.INVOCATION_RETURNED and e.role is AgentRole.IMPLEMENTER
    ]
    assert len(returned) == 1
    assert returned[0].outcome is ExecutionOutcome.FAILURE
    assert returned[0].returncode == 3
    assert K.VERIFICATION_COMPLETED not in _kinds(events)
    assert K.INVOCATION_STARTED not in _kinds(events)[-1:]


def test_failed_verification_is_recorded_as_failed_and_review_never_starts(
    tmp_path: Path,
) -> None:
    runtime, run = _legacy_run(
        tmp_path / "legacy",
        test_body=_TEST_FILE_RED,
        implementer_script=_script_write("feature.py", "def answer():\n    return 0\n"),
    )

    with pytest.raises(SupervisorTransactionError):
        run()

    events = _exec(runtime)
    verification = [e for e in events if e.kind is K.VERIFICATION_COMPLETED]
    assert len(verification) == 1
    assert verification[0].outcome is ExecutionOutcome.FAILURE
    assert [e for e in events if e.role is AgentRole.REVIEWER] == []


def test_blocked_implementer_records_blocked_outcome_escalation_and_halt(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(),
            _planner_decision_response(PlannerDecisionKind.REPLAN_SUBPHASE),
        ],
        implementer_responses=[_implementer_blocked_response()],
    )
    run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )
    events = _exec(scenario.request.runtime_dir)

    returned = [
        e for e in events if e.kind is K.INVOCATION_RETURNED and e.role is AgentRole.IMPLEMENTER
    ]
    assert [e.outcome for e in returned] == [ExecutionOutcome.BLOCKED]
    dispatched = [e for e in events if e.kind is K.ESCALATION_DISPATCHED]
    assert [e.detail for e in dispatched] == ["replan_subphase"]
    halted = [e for e in events if e.kind is K.TRANSACTION_HALTED]
    assert [e.detail for e in halted] == ["architecture_conflict"]
    assert K.RETRY_AUTHORIZED not in _kinds(events)
    assert K.VERIFICATION_COMPLETED not in _kinds(events)


# ===========================================================================
# Crash safety at the resume boundary (AC-09, 15)
# ===========================================================================


def test_crash_after_started_leaves_no_invocation_evidence_and_never_double_launches(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = _post_implementer_resume(tmp_path / "scenario")
    runtime = scenario.request.runtime_dir
    before = _kinds(_exec(runtime))

    def crash(*args: object, **kwargs: object) -> object:
        raise RuntimeError("simulated crash after STARTED, before launch")

    monkeypatch.setattr(transaction_module, "invoke_agent_turn", crash)
    with pytest.raises(RuntimeError):
        resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)

    after_crash = _exec(runtime)
    new = _kinds(after_crash)[len(before) :]
    # Resume was claimed and durably STARTED, but no agent ever began: the
    # stream must not claim an invocation started.
    assert new == [K.RESUME_CLAIMED, K.RESUME_STARTED]

    monkeypatch.undo()
    again = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert again.disposition == ResumeExecutionDisposition.STARTED_RECOVERY_REQUIRED
    final = _exec(runtime)
    assert _kinds(final) == _kinds(after_crash)
    assert len([e for e in final if e.kind is K.RESUME_STARTED]) == 1
    assert [e for e in final if e.kind is K.INVOCATION_STARTED and e.attempt == _attempt(2)] == []


def test_invoke_agent_emits_nothing_without_identity_or_journal(tmp_path: Path) -> None:
    import sys

    from lockstep.agents import AgentCommand, invoke_agent
    from lockstep.domain import BillingMode

    class _Adapter:
        name = "script"

        def build_command(self, request: AgentInvocationRequest) -> AgentCommand:
            return AgentCommand(argv=(sys.executable, "-c", "pass"))

    runtime = _journal_with_run(tmp_path)
    request = AgentInvocationRequest(
        role=AgentRole.PLANNER,
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        prompt="p",
        cwd=tmp_path,
        timeout_seconds=30.0,
    )

    invoke_agent(_Adapter(), request, parent_env={"PATH": "/usr/bin:/bin"}, runtime_dir=runtime)
    invoke_agent(
        _Adapter(), request, parent_env={"PATH": "/usr/bin:/bin"}, runtime_dir=tmp_path / "none"
    )

    assert _exec(runtime) == []
