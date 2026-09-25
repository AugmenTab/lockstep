"""Deterministic composition of Lockstep's Phase 1-3 kernels into a run.

Exposes the Supervisor-owned transaction API that drives a single
already-defined Sub-phase from ``READY`` to ``SUBPHASE_COMPLETE`` by
composing worktree creation, agent invocation, deterministic process
execution, canonical Git commits, and append-only event/state
persistence. Nothing in this package duplicates lower-layer machinery;
callers of Lockstep at the composition layer depend on this package
rather than orchestrating the kernels themselves.
"""

from lockstep.supervisor.transaction import (
    SingleSubphaseTransactionRequest,
    SingleSubphaseTransactionResult,
    SupervisorTransactionError,
    run_single_subphase_transaction,
)

__all__ = [
    "SingleSubphaseTransactionRequest",
    "SingleSubphaseTransactionResult",
    "SupervisorTransactionError",
    "run_single_subphase_transaction",
]
