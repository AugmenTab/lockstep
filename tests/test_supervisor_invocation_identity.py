"""Planner-authored specification of Sub-phase 10.1 invocation identity propagation.

Observes the host-issued ``InvocationIdentity`` on every Supervisor-owned
invocation path, by recording the ``AgentInvocationRequest`` and
``AgentInvocationResult`` that each real transport hands to / receives from
``invoke_agent`` (the real implementation still runs):

    legacy Planner test authoring / Implementer / Reviewer   (attempt 1)
    blocker-aware Implementer / Reviewer                     (attempt 1)
    Planner escalation decision                              (attempt N)
    resumed Implementer / Reviewer-only resume / Reviewer after resumed
    Implementer                                              (attempt 2, 3)

Reuses the Phase 9 reviewer-identity harness (fake provider executables, no
network, no real inference).

Baseline classification (pre-implementation): every test is RED
(``AgentInvocationRequest`` has no ``identity``; module import of
``lockstep.domain.InvocationStage`` fails). The Phase 9 suites
(``test_supervisor_reviewer_identity``, ``test_supervisor_resume_execution``,
``test_supervisor_retry_checkpoint``, ``test_supervisor_transaction``, ...) are
the GREEN_REGRESSION guard for AC-10.1-06 and AC-10.1-11.
"""

from __future__ import annotations

from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path

import pytest
from test_supervisor_reviewer_identity import (
    _GENERIC_PROMPT,
    _IMPL_CORRECT,
    _PHASE_ID,
    _SUBPHASE_ID,
    _TEST_FILE_RED,
    _blocker_aware_run,
    _build_request,
    _halt_with_checkpoint,
    _implementer_blocked_response,
    _implementer_completed_response,
    _init_source_repo,
    _legacy_reviewer_prompt,
    _parent_env,
    _planner_authoring_response,
    _planner_decision_response,
    _post_implementer_resume,
    _prepare_scenario,
    _resume,
    _reviewer_blocked_response,
    _reviewer_completed_response,
    _reviewer_only_resume,
    _script_write,
    _ScriptAdapter,
)

import lockstep.agent_turn as agent_turn_module
import lockstep.escalation_transport as escalation_transport_module
import lockstep.reviewer_turn as reviewer_turn_module
import lockstep.supervisor.transaction as transaction_module
from lockstep.agents import AgentInvocationRequest, AgentInvocationResult
from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    InvocationIdentity,
    InvocationStage,
    PhaseId,
    RunId,
    SubphaseId,
)
from lockstep.escalation_decision import PlannerDecisionKind
from lockstep.supervisor.transaction import (
    SingleSubphaseTransactionResult,
    run_single_subphase_transaction,
)

_RUN_ID = "20260929-014"


@dataclass(frozen=True, slots=True)
class _Seen:
    request: AgentInvocationRequest
    result: AgentInvocationResult


@pytest.fixture
def seen(monkeypatch: pytest.MonkeyPatch) -> list[_Seen]:
    """Record every invocation across all four transports; delegate to the real one."""
    recorded: list[_Seen] = []
    real = transaction_module.invoke_agent

    def capture(adapter: object, request: AgentInvocationRequest, **kwargs: object):  # type: ignore[no-untyped-def]
        result = real(adapter, request, **kwargs)  # type: ignore[arg-type]
        recorded.append(_Seen(request=request, result=result))
        return result

    for module in (
        transaction_module,
        agent_turn_module,
        reviewer_turn_module,
        escalation_transport_module,
    ):
        monkeypatch.setattr(module, "invoke_agent", capture)
    return recorded


def _identities(
    seen: list[_Seen], role: AgentRole, stage: InvocationStage
) -> list[InvocationIdentity]:
    found: list[InvocationIdentity] = []
    for item in seen:
        identity = item.request.identity
        if identity is not None and identity.role is role and identity.stage is stage:
            found.append(identity)
    return found


def _assert_tuple(
    identity: InvocationIdentity,
    *,
    attempt: int,
    role: AgentRole,
    stage: InvocationStage,
    run_id: str = _RUN_ID,
) -> None:
    assert identity.run_id == RunId.model_validate(run_id)
    assert identity.phase_id == PhaseId.model_validate(_PHASE_ID)
    assert identity.subphase_id == SubphaseId.model_validate(_SUBPHASE_ID)
    assert identity.attempt == AttemptNumber.model_validate(attempt)
    assert identity.role is role
    assert identity.stage is stage


# ---------------------------------------------------------------------------
# Every request carries identity; result echoes the same object (AC-01, AC-07)
# ---------------------------------------------------------------------------


def test_every_blocker_aware_invocation_carries_complete_identity(
    tmp_path: Path, seen: list[_Seen]
) -> None:
    _blocker_aware_run(tmp_path / "scenario", reviewer_prompt=_GENERIC_PROMPT)

    assert len(seen) == 3  # test authoring, implementer, reviewer
    for item in seen:
        assert item.request.identity is not None
        assert item.result.identity is item.request.identity
    pairs = [
        (i.request.identity.role, i.request.identity.stage) for i in seen if i.request.identity
    ]
    assert pairs == [
        (AgentRole.PLANNER, InvocationStage.TEST_AUTHORING),
        (AgentRole.IMPLEMENTER, InvocationStage.IMPLEMENTATION),
        (AgentRole.REVIEWER, InvocationStage.REVIEW),
    ]
    for item in seen:
        assert item.request.identity is not None
        _assert_tuple(
            item.request.identity,
            attempt=1,
            role=item.request.identity.role,
            stage=item.request.identity.stage,
        )


def test_legacy_transaction_invocations_carry_complete_identity(
    tmp_path: Path, seen: list[_Seen]
) -> None:
    root = tmp_path / "legacy"
    root.mkdir()
    request = _build_request(root, _init_source_repo(root), reviewer_prompt=_GENERIC_PROMPT)
    import json

    from test_supervisor_reviewer_identity import _review_decision_payload

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

    assert [
        (i.request.identity.role, i.request.identity.stage) for i in seen if i.request.identity
    ] == [
        (AgentRole.PLANNER, InvocationStage.TEST_AUTHORING),
        (AgentRole.IMPLEMENTER, InvocationStage.IMPLEMENTATION),
        (AgentRole.REVIEWER, InvocationStage.REVIEW),
    ]
    assert len(seen) == 3
    for item in seen:
        assert item.request.identity is not None
        _assert_tuple(
            item.request.identity,
            attempt=1,
            role=item.request.identity.role,
            stage=item.request.identity.stage,
        )


# ---------------------------------------------------------------------------
# Distinct invocations get distinct ids (AC-03)
# ---------------------------------------------------------------------------


def test_all_invocations_in_a_retry_chain_have_distinct_invocation_ids(
    tmp_path: Path, seen: list[_Seen]
) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        implementer_responses=[_implementer_completed_response()],
        reviewer_responses=[
            _reviewer_completed_response(attempt=1, verdict="rework"),
            _reviewer_completed_response(attempt=2, verdict="rework"),
            _reviewer_completed_response(attempt=3, verdict="approve"),
        ],
    )
    _halt_with_checkpoint(scenario, max_attempts=3)
    _resume(scenario)
    _resume(scenario)

    ids = [i.request.identity.invocation_id.root for i in seen if i.request.identity]
    assert len(ids) == len(seen) >= 5
    assert len(set(ids)) == len(ids)


def test_two_runs_of_same_coordinates_do_not_share_invocation_ids(
    tmp_path: Path, seen: list[_Seen]
) -> None:
    _blocker_aware_run(tmp_path / "a", reviewer_prompt=_GENERIC_PROMPT)
    _blocker_aware_run(tmp_path / "b", reviewer_prompt=_GENERIC_PROMPT)

    ids = [i.request.identity.invocation_id.root for i in seen if i.request.identity]
    assert len(ids) == 6
    assert len(set(ids)) == 6


# ---------------------------------------------------------------------------
# Actual durable attempt on retry/resume paths (AC-05, AC-06)
# ---------------------------------------------------------------------------


def test_reviewer_only_resume_identity_uses_durable_attempt_two(
    tmp_path: Path, seen: list[_Seen]
) -> None:
    scenario = _reviewer_only_resume(tmp_path / "scenario")
    _resume(scenario)

    reviews = _identities(seen, AgentRole.REVIEWER, InvocationStage.REVIEW)
    assert len(reviews) == 2
    _assert_tuple(reviews[0], attempt=1, role=AgentRole.REVIEWER, stage=InvocationStage.REVIEW)
    _assert_tuple(reviews[1], attempt=2, role=AgentRole.REVIEWER, stage=InvocationStage.REVIEW)
    assert reviews[0].invocation_id != reviews[1].invocation_id
    # Reviewer-only resume must not launch an Implementer.
    assert len(_identities(seen, AgentRole.IMPLEMENTER, InvocationStage.IMPLEMENTATION)) == 1


def test_resumed_implementer_and_following_reviewer_identity_use_attempt_two(
    tmp_path: Path, seen: list[_Seen]
) -> None:
    scenario = _post_implementer_resume(tmp_path / "scenario")
    _resume(scenario)

    implementers = _identities(seen, AgentRole.IMPLEMENTER, InvocationStage.IMPLEMENTATION)
    reviews = _identities(seen, AgentRole.REVIEWER, InvocationStage.REVIEW)
    assert [i.attempt.root for i in implementers] == [1, 2]
    assert [i.attempt.root for i in reviews] == [2]
    for identity in (*implementers, *reviews):
        assert identity.run_id == RunId.model_validate(_RUN_ID)


def test_attempt_three_identity_is_preserved_across_retries(
    tmp_path: Path, seen: list[_Seen]
) -> None:
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

    reviews = _identities(seen, AgentRole.REVIEWER, InvocationStage.REVIEW)
    assert [i.attempt.root for i in reviews] == [1, 2, 3]
    implementers = _identities(seen, AgentRole.IMPLEMENTER, InvocationStage.IMPLEMENTATION)
    assert [i.attempt.root for i in implementers] == [1, 2, 3]


# ---------------------------------------------------------------------------
# Planner escalation decision (AC-01)
# ---------------------------------------------------------------------------


def test_planner_escalation_decision_carries_identity_for_blocked_attempt(
    tmp_path: Path, seen: list[_Seen]
) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(),
            _planner_decision_response(PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[_implementer_blocked_response(), _implementer_completed_response()],
        reviewer_responses=[_reviewer_completed_response(attempt=2)],
    )
    _halt_with_checkpoint(scenario)

    decisions = _identities(seen, AgentRole.PLANNER, InvocationStage.ESCALATION_DECISION)
    assert len(decisions) == 1
    _assert_tuple(
        decisions[0],
        attempt=1,
        role=AgentRole.PLANNER,
        stage=InvocationStage.ESCALATION_DECISION,
    )


def test_planner_decision_for_resumed_blocker_uses_resumed_attempt(
    tmp_path: Path, seen: list[_Seen]
) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(),
            _planner_decision_response(PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
            _planner_decision_response(PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[_implementer_blocked_response(), _implementer_blocked_response()],
        reviewer_responses=[_reviewer_blocked_response()],
    )
    _halt_with_checkpoint(scenario)
    _resume_blocked(scenario)

    decisions = _identities(seen, AgentRole.PLANNER, InvocationStage.ESCALATION_DECISION)
    assert [d.attempt.root for d in decisions] == [1, 2]


def _resume_blocked(scenario: object) -> None:
    from lockstep.supervisor.transaction import resume_single_subphase_transaction

    resume_single_subphase_transaction(
        scenario.request,  # type: ignore[attr-defined]
        agent_turn_runtime=scenario.runtime,  # type: ignore[attr-defined]
    )


# ---------------------------------------------------------------------------
# Host owns identity: model output cannot supply it (AC-02)
# ---------------------------------------------------------------------------


def test_agent_reported_invocation_id_is_not_part_of_report_schemas() -> None:
    from lockstep.agent_turn import AgentTurnReport
    from lockstep.reviewer_turn import ReviewerTurnReport

    for model in (AgentTurnReport, ReviewerTurnReport):
        assert "invocation_id" not in model.model_json_schema().get("properties", {})
        assert "identity" not in model.model_json_schema().get("properties", {})


def test_reviewer_prompt_identity_payload_is_unchanged_by_invocation_identity(
    tmp_path: Path,
) -> None:
    # The Phase 9 host-identity section stays exactly {phase_id, subphase_id, attempt, role};
    # invocation_id is deliberately not injected into prompt text.
    prompt = _legacy_reviewer_prompt(tmp_path, reviewer_prompt=_GENERIC_PROMPT)
    assert "invocation_id" not in prompt


# ---------------------------------------------------------------------------
# No authority change (AC-10)
# ---------------------------------------------------------------------------


def test_identity_does_not_alter_execution_constraints_on_supervisor_requests(
    tmp_path: Path, seen: list[_Seen]
) -> None:
    _blocker_aware_run(tmp_path / "scenario", reviewer_prompt=_GENERIC_PROMPT)

    for item in seen:
        assert item.request.timeout_seconds == 60.0
        assert item.request.max_output_bytes == 1_048_576
        assert item.request.billing_mode.value == "subscription_only"
        assert item.request.identity is not None
        assert item.request.role is item.request.identity.role


# ---------------------------------------------------------------------------
# Transport entry points expose an optional run_id; absent -> no identity
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "target",
    [
        lambda: agent_turn_module.invoke_agent_turn,
        lambda: reviewer_turn_module.invoke_reviewer_turn,
        lambda: escalation_transport_module.invoke_planner_decision,
    ],
)
def test_transports_accept_optional_host_run_id(
    target: Callable[[], Callable[..., object]],
) -> None:
    import inspect

    parameter = inspect.signature(target()).parameters["run_id"]
    assert parameter.default is None
    assert parameter.kind is inspect.Parameter.KEYWORD_ONLY


def test_transports_without_run_id_issue_no_identity(tmp_path: Path, seen: list[_Seen]) -> None:
    scenario = _prepare_scenario(tmp_path / "scenario")
    turn = agent_turn_module.invoke_agent_turn(
        scenario.runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=PhaseId.model_validate(_PHASE_ID),
        subphase_id=SubphaseId.model_validate(_SUBPHASE_ID),
        attempt=AttemptNumber.model_validate(1),
        prompt="implement",
        cwd=scenario.request.source_path,
        timeout_seconds=30.0,
    )
    assert turn.invocation.identity is None
    assert seen[-1].request.identity is None
