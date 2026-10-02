"""A run-wide wall-clock budget that every process launch consults.

An unattended project run owns one total wall-clock budget. Every provider and command launch in
Lockstep funnels through :func:`lockstep.process.run_process`, so that is the one place the
budget needs to be enforced: before a launch it asks how much unattended time remains, refuses
the launch when none does, and caps the stage's own timeout to what remains. A single shared
guard therefore covers every long-running seam (Planner, Implementer, Reviewer, verification and
Phase-gate commands) instead of each layer growing its own check.

The budget is a *stricter upper bound for the duration of one run*, never a configuration
change: the project's per-operation limits stay the normal maximum and the effective limit is
whichever stops the operation sooner. This module is pure and low-level: it reads the injected
clock and nothing else, and it depends on no other Lockstep module.
"""

from __future__ import annotations

import contextlib
import contextvars
from collections.abc import Callable, Iterator
from datetime import UTC, datetime


def _utc_now() -> datetime:
    return datetime.now(UTC)


class RunTimeBudget:
    """The deadline of one unattended run, evaluated against an injectable clock.

    ``exhausted`` records only that the budget *itself* refused a launch or was the limiting
    timeout of one -- the clock passing the deadline never sets it -- so a stop caused by the
    run policy can be told apart from an ordinary provider or command timeout.
    """

    def __init__(self, *, deadline: datetime, clock: Callable[[], datetime] = _utc_now) -> None:
        if deadline.tzinfo is None or deadline.tzinfo.utcoffset(deadline) is None:
            raise ValueError("the run deadline must be timezone-aware")
        self._deadline = deadline
        self._clock = clock
        self._exhausted = False

    @property
    def deadline(self) -> datetime:
        return self._deadline

    @property
    def exhausted(self) -> bool:
        return self._exhausted

    def remaining_seconds(self) -> float:
        """Seconds of unattended time left; zero or negative once the deadline has passed."""
        return (self._deadline - self._clock()).total_seconds()

    def mark_exhausted(self) -> None:
        self._exhausted = True


_ACTIVE: contextvars.ContextVar[RunTimeBudget | None] = contextvars.ContextVar(
    "lockstep_run_time_budget", default=None
)


def active_run_time_budget() -> RunTimeBudget | None:
    """The budget the current run installed, or ``None`` outside an unattended run."""
    return _ACTIVE.get()


@contextlib.contextmanager
def run_time_budget(budget: RunTimeBudget) -> Iterator[RunTimeBudget]:
    """Make *budget* the active run budget for the duration of the block."""
    token = _ACTIVE.set(budget)
    try:
        yield budget
    finally:
        _ACTIVE.reset(token)
