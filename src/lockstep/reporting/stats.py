"""Internal stats / audit projection over the accepted derived transaction metrics.

10.5 (:mod:`lockstep.metrics`) computes the facts; this module only presents them.
It holds no metric formula: a single run reuses that run's accepted ``totals`` and
several runs are combined by :func:`lockstep.metrics.aggregate_metrics` over their
Sub-phases, so ratios are always recomputed from underlying counts and never
averaged.

The projection is derived and replaceable. It is not authoritative state, makes no
model call, parses no free text, appends no events, and expresses no judgement --
it reports.

Two layers:

* :class:`StatsProjection` -- the structured, serializable machine form. It keeps
  exact values (numerators, denominators, known totals, coverage), never
  pre-formatted strings.
* :func:`render_stats` -- a deterministic plain-text view of a projection. Human
  formatting lives only here; nothing parses it back.

Presentation policy (frozen by the 10.6 specification tests): rates render as
``n / d (P%)``, per-success ratios as ``n / d (X.XX)``, an undefined ratio as
``undefined (n / d)``; an aggregate always states how many of the expected
invocations reported; enum categories render in enum definition order, free-text
keys alphabetically, and unsupported metrics are listed with their reasons rather
than omitted.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence
from pathlib import Path

from pydantic import BaseModel, ConfigDict, computed_field

from lockstep.domain import AgentRole, FailureCause, RunId, StopReason
from lockstep.git import RepositoryChange
from lockstep.metrics import (
    Distribution,
    ElapsedAggregate,
    Ratio,
    RunMetrics,
    TransactionMetrics,
    UsageAggregate,
    aggregate_metrics,
    project_runtime_metrics,
)


class StatsProjectionError(Exception):
    """The requested set of runs cannot be presented without misrepresenting it."""


class _Model(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class StatsScope(_Model):
    """Which runs a projection represents (sorted by run id)."""

    run_ids: tuple[RunId, ...]

    @computed_field  # type: ignore[prop-decorator]
    @property
    def run_count(self) -> int:
        return len(self.run_ids)


class StatsProjection(_Model):
    """Structured stats for one run or an explicit set of runs.

    ``metrics.unavailable`` carries every unsupported metric with its reason.
    """

    scope: StatsScope
    metrics: TransactionMetrics


def project_stats(runs: RunMetrics | Sequence[RunMetrics]) -> StatsProjection:
    """Project one run, or an explicit collection of runs, into a :class:`StatsProjection`."""
    collected = [runs] if isinstance(runs, RunMetrics) else list(runs)
    if not collected:
        raise StatsProjectionError("no runs supplied; an empty set has no stats to present")
    ordered = sorted(collected, key=lambda run: run.run_id.root)
    ids = [run.run_id.root for run in ordered]
    duplicated = sorted({i for i in ids if ids.count(i) > 1})
    if duplicated:
        raise StatsProjectionError(
            f"run supplied more than once, which would double-count it: {', '.join(duplicated)}"
        )
    if len(ordered) == 1:
        metrics = ordered[0].totals
    else:
        metrics = aggregate_metrics(s for run in ordered for s in run.subphases)
    return StatsProjection(
        scope=StatsScope(run_ids=tuple(run.run_id for run in ordered)),
        metrics=metrics,
    )


def project_runtime_stats(
    runtime_dir: Path,
    *,
    repository_change: RepositoryChange | None = None,
) -> StatsProjection:
    """Project the journal in ``runtime_dir``. Writes nothing; journal errors propagate."""
    return project_stats(project_runtime_metrics(runtime_dir, repository_change=repository_change))


# ---------------------------------------------------------------------------
# Formatting primitives
# ---------------------------------------------------------------------------


def _rate(ratio: Ratio) -> str:
    if ratio.value is None:
        return f"undefined ({ratio.numerator:,} / {ratio.denominator:,})"
    return f"{ratio.numerator:,} / {ratio.denominator:,} ({ratio.value * 100:.1f}%)"


def _per(ratio: Ratio) -> str:
    if ratio.value is None:
        return f"undefined ({ratio.numerator:,} / {ratio.denominator:,})"
    return f"{ratio.numerator:,} / {ratio.denominator:,} ({ratio.value:.2f})"


def _duration(seconds: float) -> str:
    text = f"{seconds:.1f}s"
    whole = round(seconds)
    if whole < 60:
        return text
    hours, rest = divmod(whole, 3600)
    minutes, secs = divmod(rest, 60)
    if hours:
        return f"{text} ({hours}h{minutes:02d}m{secs:02d}s)"
    return f"{text} ({minutes}m{secs:02d}s)"


def _coverage(value: str, reporting: int, total: int, unit: str, *, known_word: bool = True) -> str:
    if total == 0:
        return f"n/a — no {unit}"
    if reporting == 0:
        return f"unavailable — 0 / {total:,} {unit} reporting"
    status = "complete" if reporting == total else "INCOMPLETE"
    known = " known" if known_word else ""
    return f"{value}{known} — {reporting:,} / {total:,} {unit} reporting — {status}"


def _count(label: str, aggregate: UsageAggregate, unit: str) -> str:
    reporting, total = aggregate.reporting_invocations, aggregate.total_invocations
    return f"{label}: {_coverage(f'{aggregate.known_total:,}', reporting, total, unit)}"


def _elapsed(label: str, aggregate: ElapsedAggregate, unit: str) -> str:
    value = _duration(aggregate.known_total_seconds)
    reporting, total = aggregate.reporting_invocations, aggregate.total_invocations
    return f"{label}: {_coverage(value, reporting, total, unit, known_word=False)}"


def _distribution(label: str, distribution: Distribution) -> str:
    parts = [f"{key} {distribution.counts[key]:,}" for key in sorted(distribution.counts)]
    if distribution.unreported:
        parts.append(f"unreported {distribution.unreported:,}")
    return f"{label}: {', '.join(parts) if parts else 'none'}"


def _categories[T: (FailureCause, StopReason)](
    order: type[T], events: Mapping[T, int], subphases: Mapping[T, int]
) -> list[str]:
    lines = [
        f"{category.value}: events {events[category]:,}, "
        f"affected Sub-phases {subphases.get(category, 0):,}"
        for category in order
        if events.get(category, 0)
    ]
    return lines or ["none recorded"]


# ---------------------------------------------------------------------------
# Sections
# ---------------------------------------------------------------------------

_ROLE_LABELS = (
    (AgentRole.PLANNER, "Planner"),
    (AgentRole.IMPLEMENTER, "Implementer"),
    (AgentRole.REVIEWER, "Reviewer"),
)


def _scope_section(projection: StatsProjection) -> list[str]:
    ids = [run_id.root for run_id in projection.scope.run_ids]
    runs = f"aggregate of {len(ids)} runs ({', '.join(ids)})"
    scope = f"run {ids[0]}" if len(ids) == 1 else runs
    metrics = projection.metrics
    return [
        f"Scope: {scope}",
        f"Sub-phases attempted: {metrics.subphases_attempted:,}",
        f"Sub-phases completed: {metrics.subphases_completed:,}",
    ]


def _success_section(m: TransactionMetrics) -> list[str]:
    return [
        f"First-pass approval (completed Sub-phases): {_rate(m.first_pass_approval_rate)}",
        f"Rework rate (reviewed Sub-phases): {_rate(m.rework_rate)}",
        f"Attempts per success: {_per(m.attempts_per_success)}",
        f"Repeated-attempt rate (executed attempts): {_rate(m.repeated_attempt_rate)}",
        f"Repeated invocations: {m.repeated_invocations:,}",
    ]


def _role_section(m: TransactionMetrics) -> list[str]:
    per_success = {
        AgentRole.PLANNER: m.planner_invocations_per_success,
        AgentRole.IMPLEMENTER: m.implementer_invocations_per_success,
        AgentRole.REVIEWER: m.reviewer_invocations_per_success,
    }
    lines = [
        f"{label} invocations: {m.invocations_by_role.get(role, 0):,} "
        f"(per success: {_per(per_success[role])})"
        for role, label in _ROLE_LABELS
    ]
    other = m.invocations_by_role.get(AgentRole.SCRIBE, 0)
    if other:
        lines.append(f"Scribe invocations: {other:,}")
    lines.append(f"Total invocations: {m.total_invocations:,}")
    return lines


def _verification_section(m: TransactionMetrics) -> list[str]:
    return [
        f"Baseline verification runs: {m.baseline_verification_runs:,}",
        f"Implementation verification runs: {m.implementation_verification_runs:,} "
        f"(per success: {_per(m.implementation_verification_runs_per_success)})",
    ]


def _duration_section(m: TransactionMetrics) -> list[str]:
    return [
        _elapsed(
            "Completed Sub-phase wall clock (first invocation start through SUBPHASE_COMPLETE; "
            "includes halted/waiting time)",
            m.completed_wall_clock,
            "completed Sub-phases",
        ),
        _elapsed("Invocation elapsed", m.usage.elapsed, "invocations"),
    ]


def _provider_section(m: TransactionMetrics) -> list[str]:
    usage = m.usage
    return [
        _distribution("Providers", usage.providers),
        _distribution("Configured models", usage.configured_models),
        _distribution("Configured efforts", usage.configured_efforts),
        _distribution(
            "Reported models (provider-reported, not merged with configured)",
            usage.reported_models,
        ),
        _distribution("Quota status", usage.quota),
    ]


def _usage_section(m: TransactionMetrics) -> list[str]:
    usage = m.usage
    return [
        _count("Input tokens", usage.input_tokens, "invocations"),
        _count("Uncached input tokens", usage.uncached_input_tokens, "invocations"),
        _count("Cache-read tokens", usage.cache_read_tokens, "invocations"),
        _count("Cache-write tokens", usage.cache_write_tokens, "invocations"),
        _count("Output tokens", usage.output_tokens, "invocations"),
    ]


def _human_section(m: TransactionMetrics) -> list[str]:
    return [
        f"Human-intervention events: {m.human_intervention_events:,} "
        f"(cause {FailureCause.HUMAN_REQUIRED_DECISION.value}, or stop reason "
        f"{StopReason.NEEDS_USER.value} / {StopReason.EXTERNAL_SIDE_EFFECT_REQUIRED.value})",
        f"Human-intervention affected Sub-phases: {m.human_intervention_subphases:,}",
    ]


def _repository_section(m: TransactionMetrics) -> list[str]:
    unit = "completed Sub-phases"
    repository = m.repository
    reason = m.unavailable.get("non_generated_diff", "no reason supplied")
    return [
        _count("Files changed", repository.files_changed, unit),
        _count("Lines added", repository.lines_added, unit),
        _count("Lines deleted", repository.lines_deleted, unit),
        _count("Binary files changed", repository.binary_files_changed, unit),
        f"Non-generated diff: unavailable — {reason}",
    ]


def _unavailable_section(m: TransactionMetrics) -> list[str]:
    return [f"{name}: unavailable — {m.unavailable[name]}" for name in sorted(m.unavailable)]


def render_stats(projection: StatsProjection) -> str:
    """Render a projection as deterministic plain text (fixed section order, no blank lines)."""
    m = projection.metrics
    sections: tuple[tuple[str, list[str]], ...] = (
        ("Scope", _scope_section(projection)),
        ("Success and rework", _success_section(m)),
        ("Role workload", _role_section(m)),
        ("Verification", _verification_section(m)),
        ("Duration", _duration_section(m)),
        ("Providers and models", _provider_section(m)),
        ("Usage", _usage_section(m)),
        (
            "Failure / rework causes",
            _categories(FailureCause, m.failure_cause_events, m.failure_cause_subphases),
        ),
        (
            "Stop reasons",
            _categories(StopReason, m.stop_reason_events, m.stop_reason_subphases),
        ),
        ("Human intervention", _human_section(m)),
        ("Repository change", _repository_section(m)),
        ("Unavailable / not yet measurable", _unavailable_section(m)),
    )
    lines = ["Lockstep stats"]
    for title, body in sections:
        lines.append(f"== {title} ==")
        lines.extend(body)
    return "\n".join(lines) + "\n"
