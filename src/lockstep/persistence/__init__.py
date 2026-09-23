"""Durable serialization and storage of Lockstep run state.

Owns the on-disk representation of the append-only event journal that
records every Lockstep run. Consumers import event models and journal
operations from this package rather than from its submodules so the
public persistence surface stays explicit. Storage-format decisions,
JSONL layout, and crash-tail semantics all live inside this package.
"""

from lockstep.persistence.events import (
    LockstepEvent,
    RunCreatedEvent,
    RunHaltedEvent,
    StateTransitionedEvent,
)
from lockstep.persistence.journal import (
    JournalIntegrityError,
    append_event,
    read_events,
)

__all__ = [
    "JournalIntegrityError",
    "LockstepEvent",
    "RunCreatedEvent",
    "RunHaltedEvent",
    "StateTransitionedEvent",
    "append_event",
    "read_events",
]
