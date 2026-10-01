"""Scribe, audit, and human-facing reporting behavior.

Eventually owns the Scribe: the component that renders run history,
audit trails, and human-readable summaries derived from canonical
state. This package is the only place where presentation-layer
formatting for humans is allowed to live.

Currently provides the internal stats / audit projection over the derived
transaction metrics: a structured :class:`StatsProjection` and a deterministic
plain-text :func:`render_stats`. The final CLI surface belongs to a later phase.
"""

from lockstep.reporting.stats import (
    StatsProjection,
    StatsProjectionError,
    StatsScope,
    project_runtime_stats,
    project_stats,
    render_stats,
)

__all__ = [
    "StatsProjection",
    "StatsProjectionError",
    "StatsScope",
    "project_runtime_stats",
    "project_stats",
    "render_stats",
]
