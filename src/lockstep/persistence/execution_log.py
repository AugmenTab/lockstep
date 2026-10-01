"""Emission helper for observational execution events.

Appends one :class:`~lockstep.persistence.events.ExecutionEvent` to the
authoritative event journal at ``runtime_dir/events.jsonl`` through the same
validated :func:`~lockstep.persistence.journal.append_event` every other event
uses. The ``run_id`` and the next contiguous sequence come from the journal
itself, so a caller can neither mislabel the run nor create a gap; an event
whose identity names a different run is rejected by the journal. When no
journal exists there is no authoritative run to describe and nothing is
written. Execution events are observational: after appending, the helper
only re-derives the ``state.json`` checkpoint from replay (when one exists),
which changes ``last_sequence`` but never the workflow state.
"""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path

from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    ExecutionEventKind,
    ExecutionOutcome,
    FailureCause,
    InvocationIdentity,
    InvocationStage,
    InvocationUsage,
    PhaseId,
    ReviewVerdict,
    StopReason,
    SubphaseId,
)
from lockstep.persistence.events import ExecutionEvent
from lockstep.persistence.journal import append_event, read_events
from lockstep.persistence.replay import replay_events
from lockstep.persistence.state_store import write_state


def record_execution_event(
    runtime_dir: Path,
    *,
    kind: ExecutionEventKind,
    outcome: ExecutionOutcome | None = None,
    identity: InvocationIdentity | None = None,
    phase_id: PhaseId | None = None,
    subphase_id: SubphaseId | None = None,
    attempt: AttemptNumber | None = None,
    role: AgentRole | None = None,
    stage: InvocationStage | None = None,
    returncode: int | None = None,
    verdict: ReviewVerdict | None = None,
    stop_reason: StopReason | None = None,
    cause: FailureCause | None = None,
    detail: str | None = None,
    usage: InvocationUsage | None = None,
) -> ExecutionEvent | None:
    """Append one execution event; return it, or ``None`` when no journal exists."""
    journal_path = runtime_dir / "events.jsonl"
    if not journal_path.exists():
        return None
    existing = read_events(journal_path)
    if not existing:
        return None

    if identity is not None:
        phase_id = identity.phase_id
        subphase_id = identity.subphase_id
        attempt = identity.attempt
        role = identity.role
        stage = identity.stage

    event = ExecutionEvent(
        run_id=identity.run_id if identity is not None else existing[0].run_id,
        sequence=existing[-1].sequence + 1,
        # The journal serializes timestamps at second precision; truncate so the
        # returned event equals the event a reader reloads.
        occurred_at=datetime.now(UTC).replace(microsecond=0),
        kind=kind,
        outcome=outcome,
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=attempt,
        role=role,
        stage=stage,
        invocation_id=identity.invocation_id if identity is not None else None,
        returncode=returncode,
        verdict=verdict,
        stop_reason=stop_reason,
        cause=cause,
        detail=detail,
        usage=usage,
    )
    append_event(journal_path, event)

    # Keep the replaceable checkpoint equal to the latest replay. A crash
    # between the append and this write leaves a checkpoint behind the
    # journal, which ``load_verified_state`` accepts (prefix-verified).
    state_path = runtime_dir / "state.json"
    if state_path.exists():
        write_state(state_path, replay_events(read_events(journal_path)))
    return event
