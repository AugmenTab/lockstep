"""Phase 11.6: the frozen, finite, host-owned autonomous-run policy and project-run identity.

Every control of an unattended run is a finite host input. No value may mean "unlimited", and an
unbounded policy must be refused before any provider could launch. Reasonable zero values are
valid and mean "none".

Baseline classification: every test here is RED at entry (``lockstep.autonomous_run_control``
does not exist).
"""

from __future__ import annotations

import hashlib
import json
import math
from typing import Any

import pytest
from autonomous_run_support import make_policy
from pydantic import ValidationError

from lockstep.autonomous_run_control import (
    AutonomousRunError,
    AutonomousRunPolicy,
    AutonomousRunPolicyError,
    ProjectRunId,
    policy_digest,
    require_finite_policy,
)
from lockstep.domain import AttemptNumber, PhaseId, RunId
from lockstep.retry import RetryBudget


def test_the_policy_carries_exactly_the_finite_controls() -> None:
    assert set(AutonomousRunPolicy.model_fields) == {
        "max_subphases",
        "max_unattended_wall_clock_seconds",
        "retry_budget",
        "max_gate_remediations",
        "until_phase",
        "jit_replan",
    }


def test_the_retry_control_reuses_the_phase_9_budget_not_a_second_vocabulary() -> None:
    assert AutonomousRunPolicy.model_fields["retry_budget"].annotation is RetryBudget


def test_a_policy_is_immutable_and_rejects_unknown_fields() -> None:
    policy = make_policy()

    with pytest.raises(ValidationError):
        policy.max_subphases = 99
    with pytest.raises(ValidationError):
        AutonomousRunPolicy.model_validate({**policy.model_dump(), "unbounded": True})


def test_zero_values_are_valid_and_mean_none() -> None:
    policy = make_policy(max_subphases=0, wall_clock_seconds=0.0, max_gate_remediations=0)

    assert policy.max_subphases == 0
    assert policy.max_unattended_wall_clock_seconds == 0.0
    assert policy.max_gate_remediations == 0
    assert policy.until_phase is None


@pytest.mark.parametrize("value", [-1, None, True, False, 1.5, "3", math.inf])
def test_max_subphases_must_be_a_finite_non_negative_integer(value: Any) -> None:
    with pytest.raises(ValidationError):
        make_policy(max_subphases=value)


@pytest.mark.parametrize("value", [-1, None, True, False, 1.5, "3", math.inf])
def test_max_gate_remediations_must_be_a_finite_non_negative_integer(value: Any) -> None:
    with pytest.raises(ValidationError):
        make_policy(max_gate_remediations=value)


@pytest.mark.parametrize("value", [-0.5, None, True, False, "60", math.inf, -math.inf, math.nan])
def test_the_wall_clock_budget_must_be_a_finite_non_negative_number(value: Any) -> None:
    with pytest.raises(ValidationError):
        make_policy(wall_clock_seconds=value)


def test_the_retry_budget_and_until_phase_are_validated_by_their_own_types() -> None:
    with pytest.raises(ValidationError):
        AutonomousRunPolicy(
            max_subphases=1,
            max_unattended_wall_clock_seconds=10.0,
            retry_budget=None,  # type: ignore[arg-type]
            max_gate_remediations=0,
        )
    with pytest.raises(ValidationError):
        make_policy(until_phase="not-a-phase")


def test_an_integer_wall_clock_is_accepted_as_a_number_of_seconds() -> None:
    assert make_policy(wall_clock_seconds=90).max_unattended_wall_clock_seconds == 90.0


@pytest.mark.parametrize(
    "changes",
    [
        {"max_subphases": math.inf},
        {"max_subphases": None},
        {"max_subphases": -1},
        {"max_unattended_wall_clock_seconds": math.inf},
        {"max_unattended_wall_clock_seconds": math.nan},
        {"max_unattended_wall_clock_seconds": None},
        {"max_gate_remediations": math.inf},
        {"max_gate_remediations": -1},
        {"retry_budget": None},
        {"jit_replan": None},
        {"jit_replan": 0},
        {"jit_replan": 1},
        {"jit_replan": "false"},
    ],
)
def test_a_policy_that_bypassed_validation_is_still_refused_as_unbounded(
    changes: dict[str, Any],
) -> None:
    good = make_policy()
    unbounded = AutonomousRunPolicy.model_construct(**{**dict(good), **changes})

    with pytest.raises(AutonomousRunPolicyError):
        require_finite_policy(unbounded)


def test_a_finite_policy_passes_the_production_guard() -> None:
    require_finite_policy(make_policy())
    require_finite_policy(make_policy(max_subphases=0, wall_clock_seconds=0.0))


def test_the_policy_error_is_a_typed_run_error_with_a_bounded_reason() -> None:
    assert issubclass(AutonomousRunPolicyError, AutonomousRunError)
    error = AutonomousRunPolicyError("max_subphases must be finite")
    assert error.reason == "max_subphases must be finite"


def test_the_policy_digest_is_stable_and_sensitive_to_every_control() -> None:
    base = make_policy()

    assert policy_digest(base) == policy_digest(make_policy())
    assert len(policy_digest(base)) == 64
    variants = [
        make_policy(max_subphases=11),
        make_policy(wall_clock_seconds=3601.0),
        make_policy(retry_attempts=4),
        make_policy(max_gate_remediations=2),
        make_policy(until_phase="01"),
        make_policy(jit_replan=False),
    ]
    digests = {policy_digest(base), *(policy_digest(v) for v in variants)}
    assert len(digests) == 7


def test_the_digest_does_not_depend_on_the_attempt_type_instance() -> None:
    first = make_policy(retry_attempts=3)
    second = AutonomousRunPolicy(
        max_subphases=10,
        max_unattended_wall_clock_seconds=3600.0,
        retry_budget=RetryBudget(max_attempts=AttemptNumber.model_validate(3)),
        max_gate_remediations=1,
        until_phase=None,
    )

    assert policy_digest(first) == policy_digest(second)


def test_jit_replan_defaults_to_true_and_false_is_a_valid_fixed_outline_choice() -> None:
    implicit = AutonomousRunPolicy(
        max_subphases=1,
        max_unattended_wall_clock_seconds=10.0,
        retry_budget=RetryBudget(max_attempts=AttemptNumber.model_validate(1)),
        max_gate_remediations=0,
    )

    assert implicit.jit_replan is True
    assert make_policy(jit_replan=False).jit_replan is False
    require_finite_policy(make_policy(jit_replan=False))


@pytest.mark.parametrize("value", [None, 0, 1, "true", "false", 1.0])
def test_jit_replan_must_be_a_strict_boolean(value: Any) -> None:
    with pytest.raises(ValidationError):
        make_policy(jit_replan=value)


# The pre-jit_replan digest of make_policy(): a policy recorded before the field existed.
_LEGACY_DEFAULT_DIGEST = "ba5490b9a9f36ca4c1f7104f2429e9bec7d1ddac152c04d8593cdd752f7a8a88"


def test_a_true_jit_replan_keeps_the_legacy_digest_and_false_changes_it() -> None:
    legacy_payload = {
        key: value
        for key, value in make_policy().model_dump(mode="json").items()
        if key != "jit_replan"
    }
    legacy_text = json.dumps(
        legacy_payload, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    legacy = hashlib.sha256(legacy_text.encode("utf-8")).hexdigest()
    absent = AutonomousRunPolicy.model_validate(legacy_payload)

    assert legacy == _LEGACY_DEFAULT_DIGEST
    assert policy_digest(absent) == _LEGACY_DEFAULT_DIGEST
    assert policy_digest(make_policy()) == _LEGACY_DEFAULT_DIGEST
    assert policy_digest(make_policy(jit_replan=True)) == _LEGACY_DEFAULT_DIGEST
    assert policy_digest(make_policy(jit_replan=False)) != _LEGACY_DEFAULT_DIGEST


def test_until_phase_is_a_phase_id() -> None:
    assert make_policy(until_phase="02").until_phase == PhaseId.model_validate("02")


def test_a_project_run_id_is_its_own_type_independent_of_child_transaction_run_ids() -> None:
    identity = ProjectRunId.model_validate("prun-0001")

    assert identity.root == "prun-0001"
    assert ProjectRunId is not RunId
    assert not isinstance(identity, RunId)
    assert identity != RunId.model_validate("prun-0001")


@pytest.mark.parametrize("value", ["", " ", "../escape", "a/b", "-leading"])
def test_a_project_run_id_must_be_a_safe_identifier(value: str) -> None:
    with pytest.raises(ValidationError):
        ProjectRunId.model_validate(value)
