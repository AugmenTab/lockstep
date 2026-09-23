"""Deterministic replay of a Lockstep event stream into current state.

Replay independently re-enforces the same invariants the journal
enforces on disk -- correct bootstrap, contiguous sequence numbers,
stable ``run_id``, no second ``RunCreatedEvent``, and legal state
transitions -- because callers may hand in an in-memory event tuple
that never touched the journal. Transitions are checked by delegating
back to :func:`lockstep.state.transition` so there is exactly one
authoritative transition graph. Replay failures are reported through
:class:`ReplayError`; the underlying :class:`InvalidTransitionError`
is never leaked to callers.
"""

from __future__ import annotations

from collections.abc import Sequence

from lockstep.persistence.events import (
    LockstepEvent,
    RunCreatedEvent,
    RunHaltedEvent,
    StateTransitionedEvent,
)
from lockstep.state import (
    InvalidTransitionError,
    RunStateSnapshot,
    WorkflowState,
    transition,
)


class ReplayError(Exception):
    """Raised when an event stream cannot be deterministically replayed."""

    def __init__(self, reason: str, *, sequence: int | None = None) -> None:
        self.reason = reason
        self.sequence = sequence

        if sequence is None:
            message = f"event replay error: {reason}"
        else:
            message = f"event replay error at sequence {sequence}: {reason}"

        super().__init__(message)


def replay_events(events: Sequence[LockstepEvent]) -> RunStateSnapshot:
    if not events:
        raise ReplayError("event stream is empty")

    first = events[0]
    if not isinstance(first, RunCreatedEvent):
        raise ReplayError(
            "first event must be a RunCreatedEvent",
            sequence=first.sequence,
        )
    if first.sequence != 1:
        raise ReplayError(
            f"first event sequence must be 1; got {first.sequence}",
            sequence=first.sequence,
        )

    run_id = first.run_id
    project_id = first.project_id
    workflow_state: WorkflowState = WorkflowState.READY
    last_sequence = first.sequence

    for event in events[1:]:
        expected_sequence = last_sequence + 1
        if event.sequence != expected_sequence:
            raise ReplayError(
                f"non-contiguous sequence: expected {expected_sequence}, got {event.sequence}",
                sequence=event.sequence,
            )
        if event.run_id != run_id:
            raise ReplayError(
                "run_id changed mid-stream",
                sequence=event.sequence,
            )
        if isinstance(event, RunCreatedEvent):
            raise ReplayError(
                "unexpected second RunCreatedEvent",
                sequence=event.sequence,
            )

        if isinstance(event, StateTransitionedEvent):
            if event.source != workflow_state:
                raise ReplayError(
                    (
                        f"transition source {event.source.value!r} does not match "
                        f"current workflow state {workflow_state.value!r}"
                    ),
                    sequence=event.sequence,
                )
            try:
                workflow_state = transition(workflow_state, event.target)
            except InvalidTransitionError as exc:
                raise ReplayError(str(exc), sequence=event.sequence) from exc
        elif isinstance(event, RunHaltedEvent):
            try:
                workflow_state = transition(workflow_state, WorkflowState.HALTED)
            except InvalidTransitionError as exc:
                raise ReplayError(str(exc), sequence=event.sequence) from exc

        last_sequence = event.sequence

    return RunStateSnapshot(
        run_id=run_id,
        project_id=project_id,
        workflow_state=workflow_state,
        last_sequence=last_sequence,
    )
