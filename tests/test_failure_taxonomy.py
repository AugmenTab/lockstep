"""Planner-authored specification of Sub-phase 10.4 rework and failure taxonomy.

Pins the contract that *why work failed, repeated, or stopped* is a bounded,
typed, deterministic attribution carried by the execution event that marks the
real boundary -- and that attribution is history, never authority.

Public surface under test (all new unless noted):

* ``lockstep.domain.FailureCause`` -- bounded enum answering "why did this
  attempt fail or repeat". ``StopReason`` (existing) keeps answering "why
  automation finally stopped"; the two are separate fields so a retry-exhaustion
  event can carry the original defect *and* the terminal stop without
  conflation.
* ``lockstep.failure`` -- pure, deterministic projections from existing control
  vocabulary: ``cause_for_escalation``, ``stop_reason_for_escalation``,
  ``cause_for_review_verdict``, ``cause_for_invocation_failure``.
* ``ExecutionEvent.cause`` (new typed field) and the previously unused
  ``ExecutionEvent.stop_reason`` (now populated where the mapping is exact).
* ``ExecutionEventKind.TRANSACTION_ABORTED`` -- recorded when the deterministic
  transaction raises before reaching a halt (scope/authority/malformed output),
  the only boundary that had no event to carry a classification.
* ``record_execution_event`` / ``record_invocation_returned`` accept ``cause``.

Mapping table (source evidence -> classification; every owner is deterministic):

* Reviewer verdict REWORK -> cause IMPLEMENTATION_DEFECT.
* escalation test_defect -> TEST_DEFECT (no stop_reason: StopReason has no exact match).
* escalation architecture_conflict -> ARCHITECTURE_CONFLICT (no stop_reason: not exact).
* escalation requirement_ambiguity -> REQUIREMENT_AMBIGUITY / StopReason.REQUIREMENT_AMBIGUITY.
* escalation external_side_effect_required -> HUMAN_REQUIRED_DECISION /
  StopReason.EXTERNAL_SIDE_EFFECT_REQUIRED.
* escalation human_authority_required -> HUMAN_REQUIRED_DECISION / StopReason.NEEDS_USER.
* escalation control_plane_blocker, planner_decision_required -> no deterministic cause.
* RED baseline unexpectedly passed -> TEST_DEFECT.
* post-implementer verification command failed -> VERIFICATION_FAILURE.
* protected test path touched (or HEAD advanced) -> AUTHORITY_VIOLATION /
  StopReason.PROTECTED_ARTIFACT_CHANGED (abort event).
* other dirty path outside the approved set -> SCOPE_VIOLATION /
  StopReason.OUT_OF_SCOPE_CHANGE (abort event).
* provider process nonzero exit or timeout -> PROVIDER_PROCESS_FAILURE.
* process could not be launched -> ENVIRONMENT_FAILURE.
* authoritative QuotaStatus.EXHAUSTED on the failed invocation -> USAGE_EXHAUSTION.
* structured output invalid or over budget -> MALFORMED_OUTPUT; the legacy Reviewer abort
  also carries StopReason.MALFORMED_AGENT_OUTPUT.
* retry budget exhausted -> the original cause is preserved and stop_reason is
  StopReason.MAX_REWORK_EXCEEDED.

Deliberately not categories: PLANNING_DEFECT, CONTEXT_MISSING and
REPEATED_DEAD_END have no deterministic evidence source in the current
architecture, and retry exhaustion already has ``StopReason.MAX_REWORK_EXCEEDED``.

Baseline classification (pre-implementation): every test that touches the new
surface is RED (``ImportError`` for ``FailureCause`` at collection). The
provider-boundary and authority tests are GREEN_CHARACTERIZATION guards for
behavior that must not change; 10.1-10.3 suites are the GREEN_REGRESSION guard.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from test_execution_events import _attempt, _exec, _kinds, _legacy_run
from test_invocation_usage import (
    _claude,
    _claude_status,
    _envelope,
    _fake_cli,
    _identity,
    _parent_env,
    _request,
    _returned,
    _runtime_with_journal,
)
from test_supervisor_reviewer_identity import (
    _GENERIC_PROMPT,
    _IMPL_CORRECT,
    _TEST_FILE_RED,
    _budget,
    _build_request,
    _halt_with_checkpoint,
    _init_source_repo,
    _planner_authoring_response,
    _planner_decision_response,
    _prepare_scenario,
    _resume,
    _reviewer_completed_response,
    _script_write,
    _ScriptAdapter,
)
from test_supervisor_reviewer_identity import _parent_env as _reviewer_env

from lockstep.agent_turn import AgentTurnError
from lockstep.agents import invoke_agent
from lockstep.domain import (
    ExecutionEventKind,
    ExecutionOutcome,
    FailureCause,
    InvocationUsage,
    ProcessTermination,
    QuotaStatus,
    ReviewVerdict,
    StopReason,
)
from lockstep.escalation import EscalationCategory
from lockstep.escalation_decision import PlannerDecisionKind
from lockstep.failure import (
    cause_for_escalation,
    cause_for_invocation_failure,
    cause_for_review_verdict,
    stop_reason_for_escalation,
)
from lockstep.persistence import (
    ExecutionEvent,
    read_events,
    record_execution_event,
    replay_events,
)
from lockstep.process import ProcessLaunchError, ProcessTimeoutError
from lockstep.state import WorkflowState
from lockstep.supervisor.transaction import (
    ResumeExecutionDisposition,
    SupervisorTransactionError,
    resume_single_subphase_transaction,
    run_single_subphase_transaction,
    run_single_subphase_transaction_with_blockers,
    run_single_subphase_transaction_with_retry_checkpoint,
)

K = ExecutionEventKind
C = FailureCause


def _blocked_response(category: EscalationCategory, authority: str) -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "status": "blocked",
                "blocker": {
                    "category": category.value,
                    "question": "Bounded sentinel question.",
                    "evidence": ["Bounded sentinel evidence."],
                    "requested_authority": authority,
                },
            }
        ),
        "returncode": 0,
    }


def _blocked_run(tmp_path: Path, category: EscalationCategory, authority: str) -> Path:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(),
            _planner_decision_response(PlannerDecisionKind.REPLAN_SUBPHASE),
        ],
        implementer_responses=[_blocked_response(category, authority)],
    )
    run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )
    return scenario.request.runtime_dir


def _usage(
    *,
    exit_code: int | None = 0,
    termination: ProcessTermination = ProcessTermination.EXITED,
    quota: QuotaStatus = QuotaStatus.UNKNOWN,
) -> InvocationUsage:
    return InvocationUsage(
        provider="claude",
        termination=termination,
        exit_code=exit_code,
        quota_status=quota,
    )


# ===========================================================================
# AC-10.4-01/02/16: bounded typed taxonomy; existing vocabulary reused
# ===========================================================================


def test_failure_cause_is_the_exact_bounded_set() -> None:
    assert {c.name for c in FailureCause} == {
        "IMPLEMENTATION_DEFECT",
        "TEST_DEFECT",
        "SCOPE_VIOLATION",
        "AUTHORITY_VIOLATION",
        "ARCHITECTURE_CONFLICT",
        "REQUIREMENT_AMBIGUITY",
        "ENVIRONMENT_FAILURE",
        "PROVIDER_PROCESS_FAILURE",
        "USAGE_EXHAUSTION",
        "VERIFICATION_FAILURE",
        "MALFORMED_OUTPUT",
        "HUMAN_REQUIRED_DECISION",
    }
    assert all(c.value == c.name.lower() for c in FailureCause)


def test_overlapping_vocabulary_shares_serialized_values_with_stop_reason() -> None:
    # Where an existing canonical type already says the same thing the wire value
    # is identical, so a consumer never needs a translation table.
    assert FailureCause.REQUIREMENT_AMBIGUITY.value == StopReason.REQUIREMENT_AMBIGUITY.value
    assert FailureCause.ENVIRONMENT_FAILURE.value == StopReason.ENVIRONMENT_FAILURE.value


def test_events_carry_typed_fields_not_metrics_strings() -> None:
    fields = ExecutionEvent.model_fields
    assert fields["cause"].annotation == FailureCause | None
    assert fields["stop_reason"].annotation == StopReason | None
    assert not {"failure_reason", "category", "reason"} & set(fields)


def test_taxonomy_extends_event_kinds_by_exactly_one_abort_boundary() -> None:
    assert ExecutionEventKind.TRANSACTION_ABORTED.value == "transaction_aborted"


# ===========================================================================
# Pure projections over existing control vocabulary (AC-04/06/11/12)
# ===========================================================================


@pytest.mark.parametrize(
    ("category", "cause", "stop"),
    [
        (EscalationCategory.CONTROL_PLANE_BLOCKER, None, None),
        (EscalationCategory.PLANNER_DECISION_REQUIRED, None, None),
        (EscalationCategory.TEST_DEFECT, C.TEST_DEFECT, None),
        (EscalationCategory.ARCHITECTURE_CONFLICT, C.ARCHITECTURE_CONFLICT, None),
        (
            EscalationCategory.REQUIREMENT_AMBIGUITY,
            C.REQUIREMENT_AMBIGUITY,
            StopReason.REQUIREMENT_AMBIGUITY,
        ),
        (
            EscalationCategory.EXTERNAL_SIDE_EFFECT_REQUIRED,
            C.HUMAN_REQUIRED_DECISION,
            StopReason.EXTERNAL_SIDE_EFFECT_REQUIRED,
        ),
        (
            EscalationCategory.HUMAN_AUTHORITY_REQUIRED,
            C.HUMAN_REQUIRED_DECISION,
            StopReason.NEEDS_USER,
        ),
    ],
)
def test_escalation_category_projection_is_total_and_exact(
    category: EscalationCategory, cause: FailureCause | None, stop: StopReason | None
) -> None:
    assert cause_for_escalation(category) is cause
    assert stop_reason_for_escalation(category) is stop


def test_escalation_projection_covers_every_category() -> None:
    for category in EscalationCategory:
        cause_for_escalation(category)
        stop_reason_for_escalation(category)


def test_only_rework_verdict_is_attributed_to_an_implementation_defect() -> None:
    assert cause_for_review_verdict(ReviewVerdict.REWORK) is C.IMPLEMENTATION_DEFECT
    assert cause_for_review_verdict(ReviewVerdict.APPROVE) is None
    assert cause_for_review_verdict(ReviewVerdict.HALT) is None


# ===========================================================================
# AC-10.4-07/08/15: provider/process failure, environment, usage exhaustion
# ===========================================================================


def test_invocation_failure_projection() -> None:
    assert cause_for_invocation_failure(_usage(exit_code=0)) is None
    assert cause_for_invocation_failure(_usage(exit_code=1)) is C.PROVIDER_PROCESS_FAILURE
    assert (
        cause_for_invocation_failure(
            _usage(exit_code=None, termination=ProcessTermination.TIMED_OUT)
        )
        is C.PROVIDER_PROCESS_FAILURE
    )
    assert cause_for_invocation_failure(None, launch_failed=True) is C.ENVIRONMENT_FAILURE
    assert cause_for_invocation_failure(None) is C.PROVIDER_PROCESS_FAILURE


def test_usage_exhaustion_requires_authoritative_exhausted_quota() -> None:
    assert (
        cause_for_invocation_failure(_usage(exit_code=1, quota=QuotaStatus.EXHAUSTED))
        is C.USAGE_EXHAUSTION
    )
    for quota in (QuotaStatus.UNKNOWN, QuotaStatus.SAFE, QuotaStatus.LOW):
        assert cause_for_invocation_failure(_usage(exit_code=1, quota=quota)) is (
            C.PROVIDER_PROCESS_FAILURE
        )


def test_nonzero_provider_exit_is_attributed_with_process_evidence_retained(
    tmp_path: Path,
) -> None:
    executable = _fake_cli(tmp_path, "claude", stdout=_envelope(is_error=True), exit_code=1)
    adapter = _claude(status=_claude_status(executable=str(executable)))
    runtime_dir = _runtime_with_journal(tmp_path)

    invoke_agent(
        adapter,
        _request(tmp_path, identity=_identity()),
        parent_env=_parent_env(),
        runtime_dir=runtime_dir,
    )

    (event,) = _returned(runtime_dir)
    assert event.outcome is ExecutionOutcome.FAILURE
    assert event.cause is C.PROVIDER_PROCESS_FAILURE
    assert event.usage is not None
    assert event.usage.exit_code == 1
    assert event.usage.reported.output_tokens == 39


def test_provider_timeout_is_attributed_with_timing_retained(tmp_path: Path) -> None:
    executable = _fake_cli(tmp_path, "claude", stdout=_envelope(), sleep=30)
    adapter = _claude(status=_claude_status(executable=str(executable)))
    runtime_dir = _runtime_with_journal(tmp_path)

    with pytest.raises(ProcessTimeoutError):
        invoke_agent(
            adapter,
            _request(tmp_path, identity=_identity(), timeout=0.3),
            parent_env=_parent_env(),
            runtime_dir=runtime_dir,
        )

    (event,) = _returned(runtime_dir)
    assert event.cause is C.PROVIDER_PROCESS_FAILURE
    assert event.usage is not None
    assert event.usage.termination is ProcessTermination.TIMED_OUT
    assert event.usage.elapsed_seconds is not None


def test_unlaunchable_executable_is_an_environment_failure_not_a_provider_failure(
    tmp_path: Path,
) -> None:
    adapter = _claude(status=_claude_status(executable=str(tmp_path / "does-not-exist")))
    runtime_dir = _runtime_with_journal(tmp_path)

    with pytest.raises(ProcessLaunchError):
        invoke_agent(
            adapter,
            _request(tmp_path, identity=_identity()),
            parent_env=_parent_env(),
            runtime_dir=runtime_dir,
        )

    (event,) = _returned(runtime_dir)
    assert event.outcome is ExecutionOutcome.FAILURE
    assert event.cause is C.ENVIRONMENT_FAILURE
    assert event.usage is None


def test_unknown_claude_failure_metadata_never_becomes_a_precise_category(
    tmp_path: Path,
) -> None:
    """AC-15 / 8.10: terminal_reason / api_error_status carry no stable witnessed meaning."""
    envelope = _envelope(
        is_error=True,
        terminal_reason="some_future_value",
        api_error_status=429,
        result="rate limited",
    )
    executable = _fake_cli(tmp_path, "claude", stdout=envelope, exit_code=1)
    adapter = _claude(status=_claude_status(executable=str(executable)))
    runtime_dir = _runtime_with_journal(tmp_path)

    invoke_agent(
        adapter,
        _request(tmp_path, identity=_identity()),
        parent_env=_parent_env(),
        runtime_dir=runtime_dir,
    )

    (event,) = _returned(runtime_dir)
    assert event.cause is C.PROVIDER_PROCESS_FAILURE
    assert event.usage is not None
    assert event.usage.quota_status is QuotaStatus.UNKNOWN


def test_provider_failure_metadata_is_parsed_nowhere_in_the_supervisor_layer() -> None:
    root = Path(__file__).resolve().parent.parent / "src" / "lockstep"
    for path in root.rglob("*.py"):
        text = path.read_text(encoding="utf-8")
        for token in ("terminal_reason", "api_error_status"):
            if token in text:
                assert path.name == "claude.py", f"{token} leaked into {path}"


def test_simulated_usage_limit_is_recorded_as_usage_exhaustion(tmp_path: Path) -> None:
    from lockstep.agents import record_invocation_returned

    runtime_dir = _runtime_with_journal(tmp_path)
    record_invocation_returned(
        runtime_dir,
        _identity(),
        outcome=ExecutionOutcome.FAILURE,
        returncode=1,
        usage=_usage(exit_code=1, quota=QuotaStatus.EXHAUSTED),
    )

    (event,) = _returned(runtime_dir)
    assert event.cause is C.USAGE_EXHAUSTION


# ===========================================================================
# AC-10.4-10: malformed output
# ===========================================================================


def test_invalid_structured_agent_output_is_attributed_as_malformed(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        implementer_responses=[{"stdout": "this is not json", "returncode": 0}],
    )

    with pytest.raises(AgentTurnError):
        run_single_subphase_transaction_with_blockers(
            scenario.request, agent_turn_runtime=scenario.runtime
        )

    returned = [
        e
        for e in _exec(scenario.request.runtime_dir)
        if e.kind is K.INVOCATION_RETURNED and e.role is not None and e.role.value == "implementer"
    ]
    assert [(e.outcome, e.cause) for e in returned] == [
        (ExecutionOutcome.FAILURE, C.MALFORMED_OUTPUT)
    ]


def test_nonzero_structured_agent_exit_is_a_provider_failure_not_malformed(
    tmp_path: Path,
) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        implementer_responses=[{"stdout": "", "returncode": 1}],
    )

    with pytest.raises(AgentTurnError):
        run_single_subphase_transaction_with_blockers(
            scenario.request, agent_turn_runtime=scenario.runtime
        )

    returned = [
        e
        for e in _exec(scenario.request.runtime_dir)
        if e.kind is K.INVOCATION_RETURNED and e.role is not None and e.role.value == "implementer"
    ]
    assert [e.cause for e in returned] == [C.PROVIDER_PROCESS_FAILURE]


def test_legacy_reviewer_returning_an_invalid_review_decision_aborts_as_malformed(
    tmp_path: Path,
) -> None:
    root = tmp_path / "bad-review"
    root.mkdir()
    request = _build_request(root, _init_source_repo(root), reviewer_prompt=_GENERIC_PROMPT)
    with pytest.raises(SupervisorTransactionError):
        run_single_subphase_transaction(
            request,
            parent_env=_reviewer_env(root),
            planner_adapter=_ScriptAdapter(
                "planner", _script_write("tests/test_feature.py", _TEST_FILE_RED)
            ),
            implementer_adapter=_ScriptAdapter(
                "implementer", _script_write("feature.py", _IMPL_CORRECT)
            ),
            reviewer_adapter=_ScriptAdapter(
                "reviewer", "import sys\nsys.stdout.write('not a review decision')\n"
            ),
        )

    aborted = [e for e in _exec(request.runtime_dir) if e.kind is K.TRANSACTION_ABORTED]
    assert len(aborted) == 1
    assert aborted[0].outcome is ExecutionOutcome.FAILURE
    assert aborted[0].cause is C.MALFORMED_OUTPUT
    assert aborted[0].stop_reason is StopReason.MALFORMED_AGENT_OUTPUT


# ===========================================================================
# AC-10.4-05: scope vs authority violations (deterministic evidence only)
# ===========================================================================


def _aborted(runtime: Path) -> list[ExecutionEvent]:
    return [e for e in _exec(runtime) if e.kind is K.TRANSACTION_ABORTED]


def test_modifying_a_protected_frozen_test_is_an_authority_violation(tmp_path: Path) -> None:
    runtime, run = _legacy_run(
        tmp_path / "legacy",
        test_body=_TEST_FILE_RED,
        implementer_script=_script_write("tests/test_feature.py", "def test_x():\n    pass\n"),
    )

    with pytest.raises(SupervisorTransactionError):
        run()

    (event,) = _aborted(runtime)
    assert event.cause is C.AUTHORITY_VIOLATION
    assert event.stop_reason is StopReason.PROTECTED_ARTIFACT_CHANGED
    assert K.VERIFICATION_COMPLETED not in _kinds(_exec(runtime))


def test_changing_a_path_outside_the_approved_set_is_a_scope_violation(tmp_path: Path) -> None:
    runtime, run = _legacy_run(
        tmp_path / "legacy",
        test_body=_TEST_FILE_RED,
        implementer_script=(
            _script_write("feature.py", _IMPL_CORRECT) + _script_write("extra.py", "x = 1\n")
        ),
    )

    with pytest.raises(SupervisorTransactionError):
        run()

    (event,) = _aborted(runtime)
    assert event.cause is C.SCOPE_VIOLATION
    assert event.stop_reason is StopReason.OUT_OF_SCOPE_CHANGE


def test_scope_violation_is_not_inferred_from_diff_size(tmp_path: Path) -> None:
    runtime, run = _legacy_run(
        tmp_path / "legacy",
        test_body=_TEST_FILE_RED,
        implementer_script=_script_write("feature.py", _IMPL_CORRECT * 200),
    )

    run()  # a very large in-scope change still succeeds

    assert _aborted(runtime) == []


# ===========================================================================
# AC-10.4-09/03: verification failure and implementation defect
# ===========================================================================


def test_failed_verification_is_attributed_without_inventing_a_deeper_cause(
    tmp_path: Path,
) -> None:
    runtime, run = _legacy_run(
        tmp_path / "legacy",
        test_body=_TEST_FILE_RED,
        implementer_script=_script_write("feature.py", "def answer():\n    return 0\n"),
    )

    with pytest.raises(SupervisorTransactionError):
        run()

    (verification,) = [e for e in _exec(runtime) if e.kind is K.VERIFICATION_COMPLETED]
    assert verification.outcome is ExecutionOutcome.FAILURE  # stage observation retained
    assert verification.cause is C.VERIFICATION_FAILURE


def test_unexpectedly_green_red_baseline_is_a_test_defect(tmp_path: Path) -> None:
    runtime, run = _legacy_run(
        tmp_path / "legacy",
        test_body="def test_green():\n    assert True\n",
        implementer_script="pass\n",
    )

    with pytest.raises(SupervisorTransactionError):
        run()

    (baseline,) = [e for e in _exec(runtime) if e.kind is K.BASELINE_VERIFIED]
    assert baseline.outcome is ExecutionOutcome.FAILURE
    assert baseline.cause is C.TEST_DEFECT


def test_successful_stages_carry_no_cause(tmp_path: Path) -> None:
    runtime, run = _legacy_run(
        tmp_path / "legacy",
        test_body=_TEST_FILE_RED,
        implementer_script=_script_write("feature.py", _IMPL_CORRECT),
    )

    run()

    assert [e for e in _exec(runtime) if e.cause is not None] == []


# ===========================================================================
# AC-10.4-04/06/11: escalation attribution without granting authority
# ===========================================================================


def test_test_defect_escalation_is_attributed_without_correcting_the_frozen_test(
    tmp_path: Path,
) -> None:
    runtime = _blocked_run(tmp_path, EscalationCategory.TEST_DEFECT, "planner")
    events = _exec(runtime)

    (dispatched,) = [e for e in events if e.kind is K.ESCALATION_DISPATCHED]
    (halted,) = [e for e in events if e.kind is K.TRANSACTION_HALTED]
    assert dispatched.cause is C.TEST_DEFECT
    assert halted.cause is C.TEST_DEFECT
    assert halted.stop_reason is None  # StopReason has no exact "test defect, requirement valid"
    # Classification granted nothing: no retry, no resume, frozen test untouched.
    assert K.RETRY_AUTHORIZED not in _kinds(events)
    assert K.RESUME_CLAIMED not in _kinds(events)
    frozen = runtime.parent / "run-worktree" / "tests" / "test_feature.py"
    assert frozen.read_text(encoding="utf-8") == _TEST_FILE_RED


def test_architecture_conflict_escalation_stays_distinct_from_ambiguity(
    tmp_path: Path,
) -> None:
    runtime = _blocked_run(tmp_path, EscalationCategory.ARCHITECTURE_CONFLICT, "planner")

    (halted,) = [e for e in _exec(runtime) if e.kind is K.TRANSACTION_HALTED]
    assert halted.cause is C.ARCHITECTURE_CONFLICT
    assert halted.stop_reason is None


def test_requirement_ambiguity_escalation_is_attributed(tmp_path: Path) -> None:
    runtime = _blocked_run(tmp_path, EscalationCategory.REQUIREMENT_AMBIGUITY, "human")

    (halted,) = [e for e in _exec(runtime) if e.kind is K.TRANSACTION_HALTED]
    assert halted.cause is C.REQUIREMENT_AMBIGUITY
    assert halted.stop_reason is StopReason.REQUIREMENT_AMBIGUITY


def test_human_required_halt_is_attributed_by_the_existing_escalation_path(
    tmp_path: Path,
) -> None:
    runtime = _blocked_run(tmp_path, EscalationCategory.HUMAN_AUTHORITY_REQUIRED, "human")
    events = _exec(runtime)

    (dispatched,) = [e for e in events if e.kind is K.ESCALATION_DISPATCHED]
    assert dispatched.detail == "human_required"  # control truth decided before attribution
    (halted,) = [e for e in events if e.kind is K.TRANSACTION_HALTED]
    assert halted.cause is C.HUMAN_REQUIRED_DECISION
    assert halted.stop_reason is StopReason.NEEDS_USER


def test_uncategorized_blockers_carry_no_invented_cause(tmp_path: Path) -> None:
    runtime = _blocked_run(tmp_path, EscalationCategory.CONTROL_PLANE_BLOCKER, "supervisor")

    (halted,) = [e for e in _exec(runtime) if e.kind is K.TRANSACTION_HALTED]
    assert halted.cause is None
    assert halted.stop_reason is None


# ===========================================================================
# AC-10.4-12/13: REWORK chain and retry exhaustion stay distinct
# ===========================================================================


def test_review_rework_chain_attributes_why_work_repeated(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        reviewer_responses=[
            _reviewer_completed_response(attempt=1, verdict="rework"),
            _reviewer_completed_response(attempt=2, verdict="approve"),
        ],
    )
    _halt_with_checkpoint(scenario, max_attempts=3)
    _resume(scenario)
    events = _exec(scenario.request.runtime_dir)

    decided = [e for e in events if e.kind is K.REVIEW_DECIDED]
    assert [(e.verdict, e.cause) for e in decided] == [
        (ReviewVerdict.REWORK, C.IMPLEMENTATION_DEFECT),
        (ReviewVerdict.APPROVE, None),
    ]
    (authorized,) = [e for e in events if e.kind is K.RETRY_AUTHORIZED]
    assert authorized.attempt == _attempt(2)
    assert authorized.cause is C.IMPLEMENTATION_DEFECT  # why the repeat happened
    assert authorized.stop_reason is None  # a retry is not a stop
    (halted,) = [e for e in events if e.kind is K.TRANSACTION_HALTED]
    assert halted.cause is C.IMPLEMENTATION_DEFECT
    assert halted.stop_reason is None
    # Eventual outcome: approved, no failure attributed to the final attempt.
    settled = [e for e in events if e.kind is K.RESUME_SETTLED]
    assert [e.detail for e in settled] == ["completed"]
    final_attempt = [e for e in events if e.attempt == _attempt(2)]
    assert [e.cause for e in final_attempt if e.kind in (K.REVIEW_DECIDED, K.RESUME_SETTLED)] == [
        None,
        None,
    ]


def test_retry_exhaustion_preserves_original_cause_and_records_the_terminal_stop(
    tmp_path: Path,
) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        reviewer_responses=[_reviewer_completed_response(attempt=1, verdict="rework")],
    )
    run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(1)
    )
    events = _exec(scenario.request.runtime_dir)

    (exhausted,) = [e for e in events if e.kind is K.RETRY_EXHAUSTED]
    assert exhausted.cause is C.IMPLEMENTATION_DEFECT  # why attempts failed
    assert exhausted.stop_reason is StopReason.MAX_REWORK_EXCEEDED  # why automation stopped
    assert K.RETRY_AUTHORIZED not in _kinds(events)
    # Exhaustion is never itself written as the engineering defect on other events.
    (decided,) = [e for e in events if e.kind is K.REVIEW_DECIDED]
    assert decided.stop_reason is None


# ===========================================================================
# AC-10.4-17/18: observational only; persistence and replay integrity
# ===========================================================================


def test_event_validation_rejects_a_cause_on_a_successful_stage(tmp_path: Path) -> None:
    runtime = _runtime_with_journal(tmp_path)

    with pytest.raises(ValueError):
        record_execution_event(
            runtime,
            kind=K.VERIFICATION_COMPLETED,
            outcome=ExecutionOutcome.SUCCESS,
            cause=C.IMPLEMENTATION_DEFECT,
        )


def test_event_validation_rejects_a_stop_reason_on_non_boundary_kinds(tmp_path: Path) -> None:
    runtime = _runtime_with_journal(tmp_path)

    with pytest.raises(ValueError):
        record_execution_event(
            runtime,
            kind=K.TESTS_FROZEN,
            outcome=ExecutionOutcome.SUCCESS,
            stop_reason=StopReason.NEEDS_USER,
        )


def test_classification_survives_persistence_and_reload(tmp_path: Path) -> None:
    runtime = _runtime_with_journal(tmp_path)
    written = record_execution_event(
        runtime,
        kind=K.RETRY_EXHAUSTED,
        cause=C.IMPLEMENTATION_DEFECT,
        stop_reason=StopReason.MAX_REWORK_EXCEEDED,
    )

    events = read_events(runtime / "events.jsonl")
    assert events[-1] == written
    raw = json.loads((runtime / "events.jsonl").read_text().splitlines()[-1])
    assert raw["cause"] == "implementation_defect"
    assert raw["stop_reason"] == "max_rework_exceeded"


def test_events_written_before_10_4_still_load_with_no_classification(tmp_path: Path) -> None:
    runtime = _runtime_with_journal(tmp_path)
    record_execution_event(runtime, kind=K.TESTS_FROZEN, outcome=ExecutionOutcome.SUCCESS)

    (event,) = [e for e in read_events(runtime / "events.jsonl") if isinstance(e, ExecutionEvent)]
    assert event.cause is None
    assert event.stop_reason is None
    raw = json.loads((runtime / "events.jsonl").read_text().splitlines()[-1])
    assert "cause" not in raw or raw["cause"] is None


def test_forged_classification_cannot_change_replayed_workflow_state(tmp_path: Path) -> None:
    runtime = _runtime_with_journal(tmp_path)
    before = replay_events(read_events(runtime / "events.jsonl"))

    record_execution_event(
        runtime,
        kind=K.TRANSACTION_HALTED,
        cause=C.HUMAN_REQUIRED_DECISION,
        stop_reason=StopReason.NEEDS_USER,
    )
    record_execution_event(
        runtime,
        kind=K.TRANSACTION_ABORTED,
        outcome=ExecutionOutcome.FAILURE,
        cause=C.AUTHORITY_VIOLATION,
        stop_reason=StopReason.PROTECTED_ARTIFACT_CHANGED,
    )
    after = replay_events(read_events(runtime / "events.jsonl"))

    assert after.workflow_state == before.workflow_state == WorkflowState.READY
    assert after.last_sequence == before.last_sequence + 2


def test_forged_test_defect_classification_does_not_authorize_retry_or_test_correction(
    tmp_path: Path,
) -> None:
    runtime = _blocked_run(tmp_path, EscalationCategory.TEST_DEFECT, "planner")
    for kind in (K.RETRY_AUTHORIZED, K.RESUME_CLAIMED):
        record_execution_event(runtime, kind=kind, attempt=_attempt(2), cause=C.TEST_DEFECT)
    state_after = replay_events(read_events(runtime / "events.jsonl")).workflow_state

    assert state_after == WorkflowState.HALTED
    # No checkpoint exists: the forged events created no retry authority and the
    # frozen test is byte-identical.
    assert not (runtime / "retry").exists()
    frozen = runtime.parent / "run-worktree" / "tests" / "test_feature.py"
    assert frozen.read_text(encoding="utf-8") == _TEST_FILE_RED


def test_forged_rework_classification_cannot_resume_a_halted_run(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(),
            _planner_decision_response(PlannerDecisionKind.REPLAN_SUBPHASE),
        ],
        implementer_responses=[_blocked_response(EscalationCategory.TEST_DEFECT, "planner")],
    )
    run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )
    runtime = scenario.request.runtime_dir
    record_execution_event(
        runtime, kind=K.RETRY_AUTHORIZED, attempt=_attempt(2), cause=C.IMPLEMENTATION_DEFECT
    )

    outcome = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert outcome.disposition == ResumeExecutionDisposition.NO_CHECKPOINT
