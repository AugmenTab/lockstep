"""Durable serialization and storage of Lockstep run state.

Owns the on-disk representation of the append-only event journal that
records every Lockstep run. Consumers import event models and journal
operations from this package rather than from its submodules so the
public persistence surface stays explicit. Storage-format decisions,
JSONL layout, and crash-tail semantics all live inside this package.
"""

from lockstep.persistence.events import (
    ExecutionEvent,
    LockstepEvent,
    RunCreatedEvent,
    RunHaltedEvent,
    StateTransitionedEvent,
)
from lockstep.persistence.execution_log import record_execution_event
from lockstep.persistence.journal import (
    JournalIntegrityError,
    append_event,
    read_events,
)
from lockstep.persistence.replay import ReplayError, replay_events
from lockstep.persistence.state_store import (
    StateConsistencyError,
    StatePersistenceError,
    load_verified_state,
    read_state,
    write_state,
)

__all__ = [
    "ExecutionEvent",
    "JournalIntegrityError",
    "LockstepEvent",
    "ReplayError",
    "RunCreatedEvent",
    "RunHaltedEvent",
    "StateConsistencyError",
    "StatePersistenceError",
    "StateTransitionedEvent",
    "append_event",
    "load_verified_state",
    "read_events",
    "read_state",
    "record_execution_event",
    "replay_events",
    "write_state",
]
