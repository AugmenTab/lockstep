import json

from lockstep.domain import (
    AgentRole,
    BillingMode,
    QuotaStatus,
    ReviewVerdict,
    RunStatus,
    StopReason,
    TestExpectation,
)


def test_run_status_values_are_stable() -> None:
    assert {member.name: member.value for member in RunStatus} == {
        "READY": "ready",
        "RUNNING": "running",
        "HALTED": "halted",
        "COMPLETE": "complete",
    }


def test_agent_role_values_are_stable() -> None:
    assert {member.name: member.value for member in AgentRole} == {
        "PLANNER": "planner",
        "IMPLEMENTER": "implementer",
        "REVIEWER": "reviewer",
        "SCRIBE": "scribe",
    }


def test_review_verdict_values_are_stable() -> None:
    assert {member.name: member.value for member in ReviewVerdict} == {
        "APPROVE": "approve",
        "REWORK": "rework",
        "HALT": "halt",
    }


def test_test_expectation_values_are_stable() -> None:
    assert {member.name: member.value for member in TestExpectation} == {
        "RED": "red",
        "GREEN_REGRESSION": "green_regression",
        "GREEN_CHARACTERIZATION": "green_characterization",
    }


def test_billing_mode_values_are_stable() -> None:
    assert {member.name: member.value for member in BillingMode} == {
        "SUBSCRIPTION_ONLY": "subscription_only",
        "API_ALLOWED": "api_allowed",
    }


def test_quota_status_values_are_stable() -> None:
    assert {member.name: member.value for member in QuotaStatus} == {
        "SAFE": "safe",
        "LOW": "low",
        "EXHAUSTED": "exhausted",
        "UNKNOWN": "unknown",
    }


def test_stop_reason_values_are_stable() -> None:
    assert {member.name: member.value for member in StopReason} == {
        "NEEDS_USER": "needs_user",
        "USAGE_LIMIT": "usage_limit",
        "AUTH_FAILURE": "auth_failure",
        "AGENT_PROCESS_FAILURE": "agent_process_failure",
        "MALFORMED_AGENT_OUTPUT": "malformed_agent_output",
        "COMMAND_TIMEOUT": "command_timeout",
        "MAX_REWORK_EXCEEDED": "max_rework_exceeded",
        "UNEXPECTED_GIT_STATE": "unexpected_git_state",
        "PROTECTED_ARTIFACT_CHANGED": "protected_artifact_changed",
        "OUT_OF_SCOPE_CHANGE": "out_of_scope_change",
        "ARCHITECTURAL_AMBIGUITY": "architectural_ambiguity",
        "REQUIREMENT_AMBIGUITY": "requirement_ambiguity",
        "TEST_DEFECT_REQUIRING_REQUIREMENT_CHANGE": "test_defect_requiring_requirement_change",
        "EXTERNAL_SIDE_EFFECT_REQUIRED": "external_side_effect_required",
        "SECRET_REQUIRED": "secret_required",
        "MERGE_CONFLICT": "merge_conflict",
        "ENVIRONMENT_FAILURE": "environment_failure",
        "USER_REQUESTED_STOP": "user_requested_stop",
        "UNKNOWN_ERROR": "unknown_error",
    }


def test_domain_enums_are_json_strings() -> None:
    values = [
        RunStatus.READY,
        AgentRole.PLANNER,
        ReviewVerdict.APPROVE,
        TestExpectation.RED,
        BillingMode.SUBSCRIPTION_ONLY,
        QuotaStatus.UNKNOWN,
        StopReason.NEEDS_USER,
    ]

    assert json.loads(json.dumps(values)) == [
        "ready",
        "planner",
        "approve",
        "red",
        "subscription_only",
        "unknown",
        "needs_user",
    ]
