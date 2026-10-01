"""Planner-authored specification of Sub-phase 10.1 canonical invocation identity (domain layer).

Pins the host-owned identity tuple

    run_id, phase_id, subphase_id, attempt, role, stage, invocation_id

as a canonical domain value that composes the existing identifier and role
vocabulary, is generated only by host infrastructure, rides the
provider-neutral ``AgentInvocationRequest``/``AgentInvocationResult``
boundary, and grants no authority. Supervisor-level propagation is pinned in
``tests/test_supervisor_invocation_identity.py``.

Baseline classification (pre-implementation): every test in this module is
RED -- ``InvocationIdentity``, ``InvocationStage`` and ``InvocationId`` do not
exist, so the module fails at import.
"""

from __future__ import annotations

import sys
from dataclasses import fields
from pathlib import Path

import pytest
from pydantic import ValidationError

from lockstep.agents import (
    AgentCommand,
    AgentInvocationRequest,
    AgentInvocationResult,
    invoke_agent,
)
from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    BillingMode,
    InvocationId,
    InvocationIdentity,
    InvocationStage,
    PhaseId,
    RunId,
    SubphaseId,
)
from lockstep.domain.enums import AgentRole as EnumsAgentRole
from lockstep.domain.identifiers import AttemptNumber as IdentifiersAttemptNumber
from lockstep.domain.identifiers import PhaseId as IdentifiersPhaseId
from lockstep.domain.identifiers import RunId as IdentifiersRunId
from lockstep.domain.identifiers import SubphaseId as IdentifiersSubphaseId


def _issue(
    *,
    attempt: int = 1,
    role: AgentRole = AgentRole.IMPLEMENTER,
    stage: InvocationStage = InvocationStage.IMPLEMENTATION,
) -> InvocationIdentity:
    return InvocationIdentity.issue(
        run_id=RunId.model_validate("run-1"),
        phase_id=PhaseId.model_validate("10"),
        subphase_id=SubphaseId.model_validate("01"),
        attempt=AttemptNumber.model_validate(attempt),
        role=role,
        stage=stage,
    )


# AC-10.1-01 / AC-10.1-04 ----------------------------------------------------


def test_identity_has_exactly_the_seven_canonical_fields() -> None:
    assert list(InvocationIdentity.model_fields) == [
        "run_id",
        "phase_id",
        "subphase_id",
        "attempt",
        "role",
        "stage",
        "invocation_id",
    ]


def test_identity_reuses_existing_domain_vocabulary() -> None:
    fields_ = InvocationIdentity.model_fields
    assert fields_["run_id"].annotation is IdentifiersRunId is RunId
    assert fields_["phase_id"].annotation is IdentifiersPhaseId is PhaseId
    assert fields_["subphase_id"].annotation is IdentifiersSubphaseId is SubphaseId
    assert fields_["attempt"].annotation is IdentifiersAttemptNumber is AttemptNumber
    assert fields_["role"].annotation is EnumsAgentRole is AgentRole
    assert fields_["stage"].annotation is InvocationStage
    assert fields_["invocation_id"].annotation is InvocationId


def test_stage_vocabulary_is_bounded_and_distinct_from_role() -> None:
    assert {stage.value for stage in InvocationStage} == {
        "test_authoring",
        "implementation",
        "review",
        "escalation_decision",
    }
    assert {stage.value for stage in InvocationStage}.isdisjoint({role.value for role in AgentRole})


def test_identity_is_frozen_and_rejects_unknown_fields() -> None:
    identity = _issue()
    with pytest.raises(ValidationError):
        identity.attempt = AttemptNumber.model_validate(2)  # type: ignore[misc]
    with pytest.raises(ValidationError):
        InvocationIdentity.model_validate({**identity.model_dump(mode="json"), "scope": "all"})


@pytest.mark.parametrize(
    ("role", "stage"),
    [
        (AgentRole.IMPLEMENTER, InvocationStage.REVIEW),
        (AgentRole.REVIEWER, InvocationStage.IMPLEMENTATION),
        (AgentRole.PLANNER, InvocationStage.REVIEW),
        (AgentRole.SCRIBE, InvocationStage.REVIEW),
    ],
)
def test_role_and_stage_must_be_consistent(role: AgentRole, stage: InvocationStage) -> None:
    with pytest.raises(ValidationError):
        _issue(role=role, stage=stage)


@pytest.mark.parametrize(
    ("role", "stage"),
    [
        (AgentRole.PLANNER, InvocationStage.TEST_AUTHORING),
        (AgentRole.IMPLEMENTER, InvocationStage.IMPLEMENTATION),
        (AgentRole.REVIEWER, InvocationStage.REVIEW),
        (AgentRole.PLANNER, InvocationStage.ESCALATION_DECISION),
    ],
)
def test_each_legal_role_stage_pair_is_representable(
    role: AgentRole, stage: InvocationStage
) -> None:
    identity = _issue(role=role, stage=stage)
    assert identity.role is role
    assert identity.stage is stage


# AC-10.1-02 / AC-10.1-03 ----------------------------------------------------


def test_issue_generates_host_owned_invocation_id() -> None:
    identity = _issue()
    assert isinstance(identity.invocation_id, InvocationId)
    assert identity.invocation_id.root


def test_issue_has_no_invocation_id_parameter() -> None:
    with pytest.raises(TypeError):
        InvocationIdentity.issue(  # type: ignore[call-arg]
            run_id=RunId.model_validate("run-1"),
            phase_id=PhaseId.model_validate("10"),
            subphase_id=SubphaseId.model_validate("01"),
            attempt=AttemptNumber.model_validate(1),
            role=AgentRole.IMPLEMENTER,
            stage=InvocationStage.IMPLEMENTATION,
            invocation_id=InvocationId.model_validate("agent-chosen"),
        )


def test_identical_semantic_coordinates_get_distinct_invocation_ids() -> None:
    ids = {_issue().invocation_id.root for _ in range(200)}
    assert len(ids) == 200


def test_invocation_id_is_independent_of_other_fields() -> None:
    first = _issue(attempt=1)
    second = _issue(attempt=1)
    assert first != second
    assert first.model_dump(exclude={"invocation_id"}) == second.model_dump(
        exclude={"invocation_id"}
    )


# AC-10.1-09 -----------------------------------------------------------------


def test_json_round_trip_preserves_exact_identity_without_regeneration() -> None:
    identity = _issue(attempt=3)
    payload = identity.model_dump_json()
    restored = InvocationIdentity.model_validate_json(payload)
    assert restored == identity
    assert restored.invocation_id == identity.invocation_id
    assert restored.model_dump_json() == payload
    assert InvocationIdentity.model_validate(identity.model_dump(mode="json")) == identity


def test_serialized_identity_uses_canonical_scalar_forms() -> None:
    dumped = _issue(attempt=2).model_dump(mode="json")
    assert dumped["run_id"] == "run-1"
    assert dumped["phase_id"] == "10"
    assert dumped["subphase_id"] == "01"
    assert dumped["attempt"] == 2
    assert dumped["role"] == "implementer"
    assert dumped["stage"] == "implementation"
    assert isinstance(dumped["invocation_id"], str)


@pytest.mark.parametrize("bad", ["", " ", "has space", "../x", "a/b"])
def test_invocation_id_rejects_non_identifier_text(bad: str) -> None:
    with pytest.raises(ValidationError):
        InvocationId.model_validate(bad)


# AC-10.1-05 -----------------------------------------------------------------


def test_identity_carries_actual_attempt_above_one() -> None:
    assert _issue(attempt=3).attempt == AttemptNumber.model_validate(3)


# AC-10.1-07 / AC-10.1-08 / AC-10.1-10 --------------------------------------


class _RecordingAdapter:
    name = "recording"

    def __init__(self) -> None:
        self.requests: list[AgentInvocationRequest] = []

    def build_command(self, request: AgentInvocationRequest) -> AgentCommand:
        self.requests.append(request)
        return AgentCommand(argv=(sys.executable, "-c", "print('ok')"))


def _request(tmp_path: Path, **overrides: object) -> AgentInvocationRequest:
    kwargs: dict[str, object] = {
        "role": AgentRole.IMPLEMENTER,
        "billing_mode": BillingMode.SUBSCRIPTION_ONLY,
        "prompt": "p",
        "cwd": tmp_path,
        "timeout_seconds": 10.0,
    }
    kwargs.update(overrides)
    return AgentInvocationRequest(**kwargs)  # type: ignore[arg-type]


def test_request_identity_defaults_to_none(tmp_path: Path) -> None:
    assert _request(tmp_path).identity is None


def test_invoke_agent_returns_the_requests_identity_unchanged(tmp_path: Path) -> None:
    identity = _issue(attempt=2)
    adapter = _RecordingAdapter()
    result = invoke_agent(
        adapter, _request(tmp_path, identity=identity), parent_env={"PATH": "/usr/bin:/bin"}
    )
    assert isinstance(result, AgentInvocationResult)
    assert result.identity == identity
    assert result.identity is identity
    assert adapter.requests[0].identity is identity


def test_result_identity_is_none_without_request_identity(tmp_path: Path) -> None:
    result = invoke_agent(
        _RecordingAdapter(), _request(tmp_path), parent_env={"PATH": "/usr/bin:/bin"}
    )
    assert result.identity is None


def test_request_rejects_identity_whose_role_differs_from_request_role(tmp_path: Path) -> None:
    with pytest.raises(ValueError):
        _request(tmp_path, role=AgentRole.REVIEWER, identity=_issue())


def test_identity_does_not_change_execution_constraints(tmp_path: Path) -> None:
    plain = _request(tmp_path)
    tagged = _request(tmp_path, identity=_issue(attempt=4))
    for field in fields(AgentInvocationRequest):
        if field.name == "identity":
            continue
        assert getattr(plain, field.name) == getattr(tagged, field.name)


def test_identity_carries_no_provider_session_state() -> None:
    names = set(InvocationIdentity.model_fields)
    assert not any("session" in name or "conversation" in name for name in names)
    assert not any("session" in name for name in (f.name for f in fields(AgentInvocationResult)))


def test_identity_mentions_no_authority_fields() -> None:
    forbidden = {"allowed_paths", "authorized_paths", "cwd", "billing_mode", "budget", "decision"}
    assert forbidden.isdisjoint(InvocationIdentity.model_fields)


def test_adapters_receive_identity_without_being_able_to_mutate_it(tmp_path: Path) -> None:
    request = _request(tmp_path, identity=_issue())
    with pytest.raises(AttributeError):
        request.identity = None  # type: ignore[misc]
