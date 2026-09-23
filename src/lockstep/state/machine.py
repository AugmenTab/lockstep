"""Deterministic Lockstep workflow state machine.

Defines the sixteen canonical `WorkflowState` values, the exact legal
transition graph between them, and the deterministic derivation of the
coarse `RunStatus` from a detailed workflow state. This module is
pure: no I/O, no persistence, no event emission, no Git, no
subprocess, no agent behavior. The state machine decides which
transitions are legal; callers do not improvise workflow transitions.
Later orchestration layers associate semantic causes (e.g. REWORK vs.
APPROVE) with legal edges, but that mapping lives outside this module.
"""

from collections.abc import Mapping
from enum import StrEnum

from lockstep.domain import RunStatus


class WorkflowState(StrEnum):
    READY = "ready"
    PHASE_PLANNING = "phase_planning"
    SUBPHASE_PLANNING = "subphase_planning"
    TEST_AUTHORING = "test_authoring"
    TEST_BASELINE_VERIFY = "test_baseline_verify"
    TEST_COMMIT = "test_commit"
    IMPLEMENTING = "implementing"
    TEST_REVIEW = "test_review"
    VERIFYING = "verifying"
    REVIEWING = "reviewing"
    IMPLEMENTATION_COMMIT = "implementation_commit"
    SUBPHASE_COMPLETE = "subphase_complete"
    PHASE_INTEGRATION_GATE = "phase_integration_gate"
    PHASE_COMPLETE = "phase_complete"
    HALTED = "halted"
    COMPLETE = "complete"


class InvalidTransitionError(Exception):
    """Raised when a caller requests a workflow transition that is not in the frozen graph."""

    def __init__(self, source: WorkflowState, target: WorkflowState) -> None:
        self.source = source
        self.target = target
        super().__init__(f"illegal Lockstep workflow transition: {source.value} -> {target.value}")


_TRANSITIONS: Mapping[WorkflowState, frozenset[WorkflowState]] = {
    WorkflowState.READY: frozenset(
        {
            WorkflowState.PHASE_PLANNING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.PHASE_PLANNING: frozenset(
        {
            WorkflowState.SUBPHASE_PLANNING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.SUBPHASE_PLANNING: frozenset(
        {
            WorkflowState.TEST_AUTHORING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.TEST_AUTHORING: frozenset(
        {
            WorkflowState.TEST_BASELINE_VERIFY,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.TEST_BASELINE_VERIFY: frozenset(
        {
            WorkflowState.TEST_COMMIT,
            WorkflowState.SUBPHASE_PLANNING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.TEST_COMMIT: frozenset(
        {
            WorkflowState.IMPLEMENTING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.IMPLEMENTING: frozenset(
        {
            WorkflowState.VERIFYING,
            WorkflowState.TEST_REVIEW,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.TEST_REVIEW: frozenset(
        {
            WorkflowState.TEST_AUTHORING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.VERIFYING: frozenset(
        {
            WorkflowState.REVIEWING,
            WorkflowState.IMPLEMENTING,
            WorkflowState.TEST_REVIEW,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.REVIEWING: frozenset(
        {
            WorkflowState.IMPLEMENTATION_COMMIT,
            WorkflowState.IMPLEMENTING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.IMPLEMENTATION_COMMIT: frozenset(
        {
            WorkflowState.SUBPHASE_COMPLETE,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.SUBPHASE_COMPLETE: frozenset(
        {
            WorkflowState.SUBPHASE_PLANNING,
            WorkflowState.PHASE_INTEGRATION_GATE,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.PHASE_INTEGRATION_GATE: frozenset(
        {
            WorkflowState.PHASE_COMPLETE,
            WorkflowState.SUBPHASE_PLANNING,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.PHASE_COMPLETE: frozenset(
        {
            WorkflowState.PHASE_PLANNING,
            WorkflowState.COMPLETE,
            WorkflowState.HALTED,
        }
    ),
    WorkflowState.HALTED: frozenset(),
    WorkflowState.COMPLETE: frozenset(),
}


def allowed_transitions(state: WorkflowState) -> frozenset[WorkflowState]:
    return _TRANSITIONS[state]


def transition(source: WorkflowState, target: WorkflowState) -> WorkflowState:
    if target not in _TRANSITIONS[source]:
        raise InvalidTransitionError(source, target)
    return target


def run_status_for(state: WorkflowState) -> RunStatus:
    match state:
        case WorkflowState.READY:
            return RunStatus.READY
        case WorkflowState.HALTED:
            return RunStatus.HALTED
        case WorkflowState.COMPLETE:
            return RunStatus.COMPLETE
        case _:
            return RunStatus.RUNNING
