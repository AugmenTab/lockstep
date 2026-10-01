"""String-backed enumerations for the Lockstep protocol.

Every enum here is a Python 3.12 ``StrEnum`` whose serialized string
values are part of Lockstep's long-term protocol surface and must not
be reordered or renamed without a schema-version bump.
"""

from enum import StrEnum


class RunStatus(StrEnum):
    READY = "ready"
    RUNNING = "running"
    HALTED = "halted"
    COMPLETE = "complete"


class AgentRole(StrEnum):
    PLANNER = "planner"
    IMPLEMENTER = "implementer"
    REVIEWER = "reviewer"
    SCRIBE = "scribe"


class InvocationStage(StrEnum):
    """Execution stage responsible for one invocation (attribution only)."""

    TEST_AUTHORING = "test_authoring"
    IMPLEMENTATION = "implementation"
    REVIEW = "review"
    ESCALATION_DECISION = "escalation_decision"


class ExecutionEventKind(StrEnum):
    """Significant transaction stage recorded as an observational execution event."""

    INVOCATION_STARTED = "invocation_started"
    INVOCATION_RETURNED = "invocation_returned"
    BASELINE_VERIFIED = "baseline_verified"
    TESTS_FROZEN = "tests_frozen"
    VERIFICATION_COMPLETED = "verification_completed"
    REVIEW_DECIDED = "review_decided"
    ESCALATION_DISPATCHED = "escalation_dispatched"
    RETRY_AUTHORIZED = "retry_authorized"
    RETRY_EXHAUSTED = "retry_exhausted"
    RESUME_CLAIMED = "resume_claimed"
    RESUME_STARTED = "resume_started"
    RESUME_SETTLED = "resume_settled"
    TRANSACTION_HALTED = "transaction_halted"


class ExecutionOutcome(StrEnum):
    """Coarse result class of a recorded stage; richer taxonomy belongs to later work."""

    SUCCESS = "success"
    FAILURE = "failure"
    BLOCKED = "blocked"


class ReviewVerdict(StrEnum):
    APPROVE = "approve"
    REWORK = "rework"
    HALT = "halt"


class TestExpectation(StrEnum):
    __test__ = False
    RED = "red"
    GREEN_REGRESSION = "green_regression"
    GREEN_CHARACTERIZATION = "green_characterization"


class BillingMode(StrEnum):
    SUBSCRIPTION_ONLY = "subscription_only"
    API_ALLOWED = "api_allowed"


class QuotaStatus(StrEnum):
    SAFE = "safe"
    LOW = "low"
    EXHAUSTED = "exhausted"
    UNKNOWN = "unknown"


class StopReason(StrEnum):
    NEEDS_USER = "needs_user"
    USAGE_LIMIT = "usage_limit"
    AUTH_FAILURE = "auth_failure"
    AGENT_PROCESS_FAILURE = "agent_process_failure"
    MALFORMED_AGENT_OUTPUT = "malformed_agent_output"
    COMMAND_TIMEOUT = "command_timeout"
    MAX_REWORK_EXCEEDED = "max_rework_exceeded"
    UNEXPECTED_GIT_STATE = "unexpected_git_state"
    PROTECTED_ARTIFACT_CHANGED = "protected_artifact_changed"
    OUT_OF_SCOPE_CHANGE = "out_of_scope_change"
    ARCHITECTURAL_AMBIGUITY = "architectural_ambiguity"
    REQUIREMENT_AMBIGUITY = "requirement_ambiguity"
    TEST_DEFECT_REQUIRING_REQUIREMENT_CHANGE = "test_defect_requiring_requirement_change"
    EXTERNAL_SIDE_EFFECT_REQUIRED = "external_side_effect_required"
    SECRET_REQUIRED = "secret_required"
    MERGE_CONFLICT = "merge_conflict"
    ENVIRONMENT_FAILURE = "environment_failure"
    USER_REQUESTED_STOP = "user_requested_stop"
    UNKNOWN_ERROR = "unknown_error"
