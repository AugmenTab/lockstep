"""Planner-authored specification of Sub-phase 10.6 internal stats / audit projection.

10.5 computes the facts; 10.6 presents them. The projection wraps accepted
``RunMetrics`` / ``TransactionMetrics`` and never recomputes a metric formula.

Public surface under test (all new, in ``lockstep.reporting``):

* ``project_stats(runs)`` -- one ``RunMetrics`` or an explicit sequence of them ->
  ``StatsProjection(scope, metrics)``. One run reuses its accepted ``totals``;
  several runs are combined by ``lockstep.metrics.aggregate_metrics`` over their
  Sub-phases (never by averaging per-run ratios). An empty collection or a repeated
  ``run_id`` raises ``StatsProjectionError``.
* ``project_runtime_stats(runtime_dir, *, repository_change=None)`` -- delegates to
  ``project_runtime_metrics``; ``UnsupportedJournalError`` propagates unchanged.
* ``render_stats(projection)`` -- deterministic plain text, fixed section order.

Frozen presentation policy:

* ratio: ``n / d (P%)`` with one decimal for rates, ``n / d (X.XX)`` for per-success
  ratios, ``undefined (n / d)`` when ``d == 0`` -- never 0%, NaN or infinity.
* counts use thousands separators; durations are ``S.Ss`` plus ``(XmYYs)`` from a
  minute up.
* aggregate: ``<known> known — <r> / <t> <unit> reporting — complete|INCOMPLETE``;
  ``unavailable — 0 / <t> <unit> reporting`` when nothing reported; ``n/a — no
  <unit>`` when nothing was expected. A provider-reported zero is a known ``0``.
* enum categories render in enum definition order, free-text keys alphabetically,
  ``unreported`` last, nonzero categories only.

Baseline classification (pre-implementation): every test in this module is RED
(collection ``ImportError``: ``lockstep.reporting`` exports nothing yet). The
10.1-10.5 suites and the architecture tests are the GREEN_REGRESSION guard; no
existing test is changed.
"""

from __future__ import annotations

import json
from pathlib import Path

import pytest
from test_transaction_metrics import (
    _TO_COMPLETE,
    IMPL,
    K,
    _Journal,
    _subphase_a,
    _subphase_b,
    _subphase_c,
    _usage,
    _write_journal,
)

from lockstep.domain import FailureCause, RunId, StopReason, SubphaseId
from lockstep.git import RepositoryChange
from lockstep.metrics import (
    RunMetrics,
    SubphaseMetrics,
    UnsupportedJournalError,
    aggregate_metrics,
    project_run_metrics,
    project_runtime_metrics,
)
from lockstep.reporting import (
    StatsProjection,
    StatsProjectionError,
    project_runtime_stats,
    project_stats,
    render_stats,
)

_STATS_SOURCE = Path(__file__).resolve().parents[1] / "src" / "lockstep" / "reporting" / "stats.py"


def _run(journal: _Journal) -> RunMetrics:
    return project_run_metrics(journal.events)


def _all_three() -> StatsProjection:
    return project_stats([_run(_subphase_a()), _run(_subphase_b()), _run(_subphase_c())])


def _lines(text: str) -> list[str]:
    return text.splitlines()


def _section(text: str, title: str) -> list[str]:
    lines = _lines(text)
    start = lines.index(f"== {title} ==")
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("== ")), len(lines))
    return lines[start + 1 : end]


def _doc(projection: StatsProjection) -> dict:
    return json.loads(projection.model_dump_json())


# ===========================================================================
# AC-01 / AC-17: one canonical metrics engine; aggregation recomputes from counts
# ===========================================================================


def test_single_run_reuses_the_accepted_totals_unchanged() -> None:
    run = _run(_subphase_b())

    projection = project_stats(run)

    assert projection.metrics == run.totals
    assert project_stats([run]) == projection


def test_multi_run_projection_is_the_accepted_aggregate_of_all_subphases() -> None:
    runs = [_run(_subphase_a()), _run(_subphase_b()), _run(_subphase_c())]

    projection = project_stats(runs)

    expected = aggregate_metrics([s for run in runs for s in run.subphases])
    assert projection.metrics == expected


def _three_non_first_pass_run() -> RunMetrics:
    [b] = _run(_subphase_b()).subphases
    copies = tuple(
        b.model_copy(update={"subphase_id": SubphaseId.model_validate(f"0{i}")}) for i in (3, 4, 5)
    )
    return RunMetrics(
        run_id=RunId.model_validate("20261001-050"),
        subphases=copies,
        totals=aggregate_metrics(copies),
    )


def test_aggregate_recomputes_ratios_from_counts_not_from_averaged_percentages() -> None:
    run_x = _run(_subphase_a())  # first pass 1 / 1
    run_y = _three_non_first_pass_run()  # first pass 0 / 3
    assert run_x.totals.first_pass_approval_rate.value == 1.0
    assert run_y.totals.first_pass_approval_rate.value == 0.0

    projection = project_stats([run_x, run_y])

    first_pass = projection.metrics.first_pass_approval_rate
    assert (first_pass.numerator, first_pass.denominator) == (1, 4)
    assert first_pass.value == 0.25  # not (100% + 0%) / 2
    attempts = projection.metrics.attempts_per_success
    assert (attempts.numerator, attempts.denominator) == (1 + 3 * 2, 4)
    text = render_stats(projection)
    assert "First-pass approval (completed Sub-phases): 1 / 4 (25.0%)" in _lines(text)
    assert "Attempts per success: 7 / 4 (1.75)" in _lines(text)
    assert "First-pass approval (completed Sub-phases): 1 / 2 (50.0%)" not in _lines(text)


def test_aggregate_scope_is_not_presented_as_one_run() -> None:
    projection = project_stats([_three_non_first_pass_run(), _run(_subphase_a())])

    assert projection.scope.run_count == 2
    assert projection.scope.run_ids == (
        RunId.model_validate("20261001-001"),
        RunId.model_validate("20261001-050"),
    )
    text = render_stats(projection)
    assert "Scope: aggregate of 2 runs (20261001-001, 20261001-050)" in _lines(text)
    assert not any(line.startswith("Scope: run ") for line in _lines(text))
    assert "Sub-phases attempted: 4" in _lines(text)
    assert "Sub-phases completed: 4" in _lines(text)


def test_projection_is_independent_of_run_order() -> None:
    runs = [_run(_subphase_a()), _run(_subphase_b()), _run(_subphase_c())]

    forward = project_stats(runs)
    backward = project_stats(list(reversed(runs)))

    assert forward == backward
    assert render_stats(forward) == render_stats(backward)


def test_empty_run_collection_is_an_error_not_an_empty_report() -> None:
    with pytest.raises(StatsProjectionError):
        project_stats([])


def test_the_same_run_cannot_be_counted_twice() -> None:
    run = _run(_subphase_a())

    with pytest.raises(StatsProjectionError):
        project_stats([run, run])


# ===========================================================================
# AC-02 / AC-04 / AC-05: structured, serializable, auditable
# ===========================================================================


def test_structured_projection_retains_exact_values_not_formatted_strings() -> None:
    document = _doc(_all_three())

    assert document["scope"]["run_count"] == 3
    assert document["scope"]["run_ids"] == ["20261001-001", "20261001-002", "20261001-003"]
    metrics = document["metrics"]
    assert metrics["subphases_attempted"] == 3
    assert metrics["subphases_completed"] == 2
    assert metrics["first_pass_approval_rate"] == {"numerator": 1, "denominator": 2, "value": 0.5}
    assert metrics["rework_rate"] == {"numerator": 1, "denominator": 2, "value": 0.5}
    assert metrics["attempts_per_success"] == {"numerator": 3, "denominator": 2, "value": 1.5}
    assert metrics["repeated_attempt_rate"] == {"numerator": 2, "denominator": 5, "value": 0.4}
    assert metrics["repeated_invocations"] == 3
    assert metrics["usage"]["input_tokens"] == {
        "known_total": 2650,
        "reporting_invocations": 5,
        "total_invocations": 9,
        "complete": False,
    }


def test_structured_projection_has_no_monetary_vocabulary() -> None:
    keys: set[str] = set()

    def walk(node: object) -> None:
        if isinstance(node, dict):
            for key, value in node.items():
                keys.add(str(key))
                walk(value)
        elif isinstance(node, list):
            for item in node:
                walk(item)

    walk(_doc(_all_three()))

    for forbidden in ("cost", "price", "dollar", "usd", "spend", "billing", "amortiz"):
        assert not [key for key in keys if forbidden in key.lower()], forbidden
    text = render_stats(_all_three()).lower()
    for forbidden in ("cost", "price", "dollar", "$", "usd", "billing"):
        assert forbidden not in text, forbidden


# ===========================================================================
# Scenario A: successful first-pass run
# ===========================================================================


def test_first_pass_run_reports_attempt_completion_and_ratios() -> None:
    projection = project_stats(_run(_subphase_a()))

    metrics = projection.metrics
    assert (metrics.subphases_attempted, metrics.subphases_completed) == (1, 1)
    assert (
        metrics.first_pass_approval_rate.numerator,
        metrics.first_pass_approval_rate.denominator,
    ) == (1, 1)
    assert (metrics.rework_rate.numerator, metrics.rework_rate.denominator) == (0, 1)
    assert metrics.attempts_per_success.value == 1.0

    lines = _lines(render_stats(projection))
    assert lines[0] == "Lockstep stats"
    assert "Scope: run 20261001-001" in lines
    assert "Sub-phases attempted: 1" in lines
    assert "Sub-phases completed: 1" in lines
    assert "First-pass approval (completed Sub-phases): 1 / 1 (100.0%)" in lines
    assert "Rework rate (reviewed Sub-phases): 0 / 1 (0.0%)" in lines
    assert "Attempts per success: 1 / 1 (1.00)" in lines
    assert "Providers: claude 2, codex 1" in lines
    assert "Input tokens: 1,800 known — 3 / 3 invocations reporting — complete" in lines


# ===========================================================================
# Scenario B: reworked successful run (and the three-run scenario, 7.2-7.10)
# ===========================================================================


def test_reworked_run_shows_rework_repeated_work_cause_and_completion() -> None:
    projection = project_stats(_run(_subphase_b()))

    metrics = projection.metrics
    assert metrics.subphases_completed == 1
    assert metrics.first_pass_approval_rate.numerator == 0
    assert metrics.rework_rate.numerator == 1
    assert metrics.attempts_per_success.numerator == 2
    assert metrics.repeated_attempts == 1
    assert metrics.failure_cause_events == {FailureCause.IMPLEMENTATION_DEFECT: 3}

    text = render_stats(projection)
    lines = _lines(text)
    assert "First-pass approval (completed Sub-phases): 0 / 1 (0.0%)" in lines
    assert "Rework rate (reviewed Sub-phases): 1 / 1 (100.0%)" in lines
    assert "Attempts per success: 2 / 1 (2.00)" in lines
    assert "Repeated invocations: 2" in lines
    assert "implementation_defect: events 3, affected Sub-phases 1" in _section(
        text, "Failure / rework causes"
    )


def test_success_and_rework_section_over_the_three_run_scenario() -> None:
    section = _section(render_stats(_all_three()), "Success and rework")

    assert section == [
        "First-pass approval (completed Sub-phases): 1 / 2 (50.0%)",
        "Rework rate (reviewed Sub-phases): 1 / 2 (50.0%)",
        "Attempts per success: 3 / 2 (1.50)",
        "Repeated-attempt rate (executed attempts): 2 / 5 (40.0%)",
        "Repeated invocations: 3",
    ]


def test_role_workload_exposes_raw_counts_and_per_success_ratios() -> None:
    projection = _all_three()

    assert projection.metrics.invocations_by_role  # structured counts remain available
    assert _section(render_stats(projection), "Role workload") == [
        "Planner invocations: 1 (per success: 1 / 2 (0.50))",
        "Implementer invocations: 5 (per success: 5 / 2 (2.50))",
        "Reviewer invocations: 3 (per success: 3 / 2 (1.50))",
        "Total invocations: 9",
    ]


def test_verification_runs_are_never_merged() -> None:
    projection = _all_three()

    assert projection.metrics.baseline_verification_runs == 1
    assert projection.metrics.implementation_verification_runs == 3
    assert _section(render_stats(projection), "Verification") == [
        "Baseline verification runs: 1",
        "Implementation verification runs: 3 (per success: 3 / 2 (1.50))",
    ]


def test_wall_clock_is_labelled_by_its_actual_semantics() -> None:
    section = _section(render_stats(_all_three()), "Duration")

    wall = next(line for line in section if line.startswith("Completed Sub-phase wall clock"))
    assert "first invocation start through SUBPHASE_COMPLETE" in wall
    assert "includes halted/waiting time" in wall
    assert wall.endswith(": 320.0s (5m20s) — 2 / 2 completed Sub-phases reporting — complete")
    assert "active" not in "\n".join(section).lower()
    assert "Invocation elapsed: 95.0s (1m35s) — 8 / 9 invocations reporting — INCOMPLETE" in section


# ===========================================================================
# AC-09 / AC-19: provider and model distributions, stable ordering
# ===========================================================================


def test_provider_model_and_effort_distributions_render_deterministically() -> None:
    section = _section(render_stats(_all_three()), "Providers and models")

    assert section == [
        "Providers: claude 4, codex 4, unreported 1",
        "Configured models: gpt-5 4, haiku 2, opus 2, unreported 1",
        "Configured efforts: high 2, low 2, medium 4, unreported 1",
        "Reported models (provider-reported, not merged with configured): "
        "claude-haiku-4-5-20251001 1, unreported 8",
        "Quota status: unknown 8, unreported 1",
    ]


def test_configured_and_reported_model_names_are_not_normalised() -> None:
    text = render_stats(_all_three())

    section = _section(text, "Providers and models")
    configured = next(line for line in section if line.startswith("Configured models"))
    reported = next(line for line in section if line.startswith("Reported models"))
    assert "claude-haiku-4-5-20251001" not in configured
    assert "haiku 2" in configured
    assert "claude-haiku-4-5-20251001 1" in reported


def test_categories_render_in_definition_order_whatever_the_dict_order() -> None:
    base = _all_three()
    shuffled = base.metrics.model_copy(
        update={
            "failure_cause_events": {
                FailureCause.SCOPE_VIOLATION: 1,
                FailureCause.TEST_DEFECT: 2,
            },
            "failure_cause_subphases": {
                FailureCause.SCOPE_VIOLATION: 1,
                FailureCause.TEST_DEFECT: 2,
            },
        }
    )
    projection = StatsProjection(scope=base.scope, metrics=shuffled)

    assert _section(render_stats(projection), "Failure / rework causes") == [
        "test_defect: events 2, affected Sub-phases 2",
        "scope_violation: events 1, affected Sub-phases 1",
    ]


def test_free_text_distribution_keys_render_alphabetically() -> None:
    base = _all_three()
    unsorted_usage = base.metrics.usage.model_copy(
        update={
            "providers": base.metrics.usage.providers.model_copy(
                update={"counts": {"zeta": 1, "alpha": 2}, "unreported": 0}
            )
        }
    )
    projection = StatsProjection(
        scope=base.scope, metrics=base.metrics.model_copy(update={"usage": unsorted_usage})
    )

    assert "Providers: alpha 2, zeta 1" in _lines(render_stats(projection))


# ===========================================================================
# AC-10 / AC-11 / Scenario D: usage coverage, known zero, unavailable
# ===========================================================================


def test_usage_section_shows_partial_coverage_for_every_field() -> None:
    projection = _all_three()

    assert _section(render_stats(projection), "Usage") == [
        "Input tokens: 2,650 known — 5 / 9 invocations reporting — INCOMPLETE",
        "Uncached input tokens: 650 known — 4 / 9 invocations reporting — INCOMPLETE",
        "Cache-read tokens: 1,300 known — 4 / 9 invocations reporting — INCOMPLETE",
        "Cache-write tokens: 200 known — 4 / 9 invocations reporting — INCOMPLETE",
        "Output tokens: 250 known — 5 / 9 invocations reporting — INCOMPLETE",
    ]
    totals = projection.metrics.usage.input_tokens
    assert (totals.known_total, totals.reporting_invocations, totals.total_invocations) == (
        2650,
        5,
        9,
    )
    assert totals.complete is False


def test_a_partial_total_never_reads_as_a_complete_one() -> None:
    partial = render_stats(_all_three())
    complete = render_stats(project_stats(_run(_subphase_a())))

    assert "Input tokens: 2,650 known" in partial
    assert "Input tokens: 2,650 — " not in partial
    partial_line = next(x for x in _lines(partial) if x.startswith("Input tokens"))
    complete_line = next(x for x in _lines(complete) if x.startswith("Input tokens"))
    assert partial_line.endswith("INCOMPLETE")
    assert complete_line.endswith("complete")
    assert "INCOMPLETE" not in complete_line


def _usage_journal(run_id: str, **telemetry: int | None) -> _Journal:
    j = _Journal(run_id)
    j.invoke("inv-u1", *IMPL, usage=_usage("claude", model="opus", effort="high", **telemetry))
    return j


def test_provider_reported_zero_is_a_known_zero_and_absent_telemetry_is_unavailable() -> None:
    zero = project_stats(
        _run(
            _usage_journal(
                "20261001-060",
                input_tokens=0,
                uncached=0,
                cache_read=0,
                cache_write=0,
                output=0,
            )
        )
    )
    absent = project_stats(_run(_usage_journal("20261001-061")))

    zero_usage = _section(render_stats(zero), "Usage")
    assert zero_usage[0] == "Input tokens: 0 known — 1 / 1 invocations reporting — complete"
    assert zero.metrics.usage.input_tokens.reporting_invocations == 1
    absent_usage = _section(render_stats(absent), "Usage")
    assert absent_usage[0] == "Input tokens: unavailable — 0 / 1 invocations reporting"
    assert all("0 known" not in line for line in absent_usage)
    assert absent.metrics.usage.input_tokens.reporting_invocations == 0


def test_thousands_separators_keep_exact_values() -> None:
    projection = project_stats(
        _run(_usage_journal("20261001-062", input_tokens=1234567, output=2650))
    )

    usage = _section(render_stats(projection), "Usage")
    assert usage[0].startswith("Input tokens: 1,234,567 known")
    output = next(x for x in usage if x.startswith("Output tokens"))
    assert output.startswith("Output tokens: 2,650 known")


# ===========================================================================
# Scenario C / AC-16: failed run is still informative; AC-12 / AC-13
# ===========================================================================


def test_failed_run_reports_usage_causes_and_stop_reason_without_success_ratios() -> None:
    projection = project_stats(_run(_subphase_c()))

    metrics = projection.metrics
    assert (metrics.subphases_attempted, metrics.subphases_completed) == (1, 0)
    assert metrics.attempts_per_success.value is None
    assert metrics.implementer_invocations_per_success.numerator == 2
    assert metrics.implementer_invocations_per_success.value is None

    text = render_stats(projection)
    lines = _lines(text)
    assert "Sub-phases attempted: 1" in lines
    assert "Sub-phases completed: 0" in lines
    assert "First-pass approval (completed Sub-phases): undefined (0 / 0)" in lines
    assert "Rework rate (reviewed Sub-phases): undefined (0 / 0)" in lines
    assert "Attempts per success: undefined (0 / 0)" in lines
    assert "Implementer invocations: 2 (per success: undefined (2 / 0))" in lines
    assert "Repeated-attempt rate (executed attempts): 1 / 2 (50.0%)" in lines
    assert "Providers: codex 1, unreported 1" in lines
    assert "Input tokens: unavailable — 0 / 2 invocations reporting" in lines
    assert "provider_process_failure: events 5, affected Sub-phases 1" in _section(
        text, "Failure / rework causes"
    )
    assert "max_rework_exceeded: events 1, affected Sub-phases 1" in _section(text, "Stop reasons")
    duration = _section(text, "Duration")
    wall = next(x for x in duration if x.startswith("Completed Sub-phase wall"))
    assert wall.endswith(": n/a — no completed Sub-phases")


def test_failure_causes_and_stop_reasons_stay_in_separate_sections() -> None:
    text = render_stats(_all_three())

    failure = "\n".join(_section(text, "Failure / rework causes"))
    stops = "\n".join(_section(text, "Stop reasons"))
    assert "provider_process_failure" in failure
    assert "implementation_defect" in failure
    assert "max_rework_exceeded" not in failure
    assert "max_rework_exceeded" in stops
    assert "provider_process_failure" not in stops
    assert "implementation_defect" not in stops
    assert _doc(_all_three())["metrics"]["stop_reason_events"] == {"max_rework_exceeded": 1}


def test_empty_cause_and_stop_sections_say_none_recorded() -> None:
    text = render_stats(project_stats(_run(_subphase_a())))

    assert _section(text, "Failure / rework causes") == ["none recorded"]
    assert _section(text, "Stop reasons") == ["none recorded"]


def test_human_intervention_is_labelled_and_not_every_halt() -> None:
    projection = _all_three()  # two halted Sub-phases, zero human-required evidence
    assert projection.metrics.human_intervention_events == 0

    section = _section(render_stats(projection), "Human intervention")

    assert section[0].startswith("Human-intervention events: 0 (")
    assert "human_required_decision" in section[0]
    assert "needs_user" in section[0]
    assert "external_side_effect_required" in section[0]
    assert section[1] == "Human-intervention affected Sub-phases: 0"


def test_human_required_evidence_is_counted_when_present() -> None:
    j = _Journal("20261001-070")
    j.invoke("inv-h1", *IMPL)
    j.event(
        K.TRANSACTION_HALTED,
        stop=StopReason.NEEDS_USER,
        cause=FailureCause.HUMAN_REQUIRED_DECISION,
    )

    section = _section(render_stats(project_stats(_run(j))), "Human intervention")

    assert section[0].startswith("Human-intervention events: 1 (")
    assert section[1] == "Human-intervention affected Sub-phases: 1"


# ===========================================================================
# AC-14: repository change evidence and its coverage
# ===========================================================================


def test_repository_change_is_shown_with_coverage_and_non_generated_stays_unavailable() -> None:
    run = project_run_metrics(
        _subphase_a().events, repository_change=RepositoryChange(3, 120, 7, 1)
    )

    section = _section(render_stats(project_stats(run)), "Repository change")

    assert section[:4] == [
        "Files changed: 3 known — 1 / 1 completed Sub-phases reporting — complete",
        "Lines added: 120 known — 1 / 1 completed Sub-phases reporting — complete",
        "Lines deleted: 7 known — 1 / 1 completed Sub-phases reporting — complete",
        "Binary files changed: 1 known — 1 / 1 completed Sub-phases reporting — complete",
    ]
    assert section[4].startswith("Non-generated diff: unavailable — ")


def test_unmeasured_repository_change_is_unavailable_not_zero() -> None:
    section = _section(render_stats(project_stats(_run(_subphase_a()))), "Repository change")

    assert section[0] == "Files changed: unavailable — 0 / 1 completed Sub-phases reporting"
    assert all("0 known" not in line for line in section)


# ===========================================================================
# AC-15 / Scenario E: unsupported metrics are visible with their reasons
# ===========================================================================


def test_all_unsupported_metrics_are_listed_with_their_reasons() -> None:
    projection = _all_three()
    unavailable = projection.metrics.unavailable
    assert set(unavailable) == {
        "escalation_categories",
        "planner_implementer_disagreement",
        "test_counts",
        "non_generated_diff",
    }

    section = _section(render_stats(projection), "Unavailable / not yet measurable")

    assert section == [f"{name}: unavailable — {unavailable[name]}" for name in sorted(unavailable)]
    assert all(reason for reason in unavailable.values())


def test_unavailable_section_is_present_even_when_nothing_was_attempted() -> None:
    empty = RunMetrics(
        run_id=RunId.model_validate("20261001-080"),
        subphases=(),
        totals=aggregate_metrics([]),
    )

    text = render_stats(project_stats(empty))

    assert len(_section(text, "Unavailable / not yet measurable")) == 4


# ===========================================================================
# Scenario F / AC-11: zero denominators
# ===========================================================================


def test_run_with_no_attempts_renders_without_nan_infinity_or_misleading_zero_percent() -> None:
    empty = RunMetrics(
        run_id=RunId.model_validate("20261001-081"),
        subphases=(),
        totals=aggregate_metrics([]),
    )

    text = render_stats(project_stats(empty))

    lowered = text.lower()
    assert "nan" not in lowered
    assert "inf" not in lowered
    assert "0.0%" not in text
    assert "Sub-phases attempted: 0" in _lines(text)
    assert "First-pass approval (completed Sub-phases): undefined (0 / 0)" in _lines(text)
    assert "Repeated-attempt rate (executed attempts): undefined (0 / 0)" in _lines(text)


# ===========================================================================
# AC-03 / AC-18 / AC-19: deterministic, idempotent, fixed section order
# ===========================================================================

_SECTION_ORDER = (
    "Scope",
    "Success and rework",
    "Role workload",
    "Verification",
    "Duration",
    "Providers and models",
    "Usage",
    "Failure / rework causes",
    "Stop reasons",
    "Human intervention",
    "Repository change",
    "Unavailable / not yet measurable",
)


def test_sections_appear_in_fixed_order() -> None:
    lines = _lines(render_stats(_all_three()))

    headers = [line[3:-3] for line in lines if line.startswith("== ")]
    assert headers == list(_SECTION_ORDER)


def test_rendering_is_idempotent_and_ends_with_a_newline() -> None:
    projection = _all_three()

    first = render_stats(projection)
    second = render_stats(
        project_stats([_run(_subphase_a()), _run(_subphase_b()), _run(_subphase_c())])
    )

    assert first == second
    assert first == render_stats(projection)
    assert first.endswith("\n")
    assert projection.model_dump_json() == _all_three().model_dump_json()


def test_rendering_does_not_alter_the_structured_projection() -> None:
    projection = _all_three()
    before = projection.model_dump_json()

    render_stats(projection)

    assert projection.model_dump_json() == before


# ===========================================================================
# One-run path from a runtime directory (AC-23, section 11, section 16)
# ===========================================================================


def test_runtime_projection_matches_metrics_projection_and_writes_nothing(tmp_path: Path) -> None:
    runtime = tmp_path / "rt"
    _write_journal(runtime, _subphase_b())
    (runtime / "state.json").write_text('{"sentinel": true}\n')
    journal_before = (runtime / "events.jsonl").read_bytes()
    state_before = (runtime / "state.json").read_bytes()
    listing_before = sorted(p.name for p in runtime.iterdir())

    projection = project_runtime_stats(runtime)

    assert projection == project_stats(project_runtime_metrics(runtime))
    assert render_stats(projection) == render_stats(project_stats(_run(_subphase_b())))
    assert (runtime / "events.jsonl").read_bytes() == journal_before
    assert (runtime / "state.json").read_bytes() == state_before
    assert sorted(p.name for p in runtime.iterdir()) == listing_before


def test_runtime_projection_accepts_caller_supplied_repository_change(tmp_path: Path) -> None:
    runtime = tmp_path / "rt"
    _write_journal(runtime, _subphase_a())

    projection = project_runtime_stats(runtime, repository_change=RepositoryChange(2, 10, 4, 0))

    assert projection.metrics.repository.lines_added.known_total == 10
    assert projection.metrics.repository.files_changed.complete is True


def test_unsupported_journal_shape_remains_an_error(tmp_path: Path) -> None:
    j = _Journal("20261001-090")
    j.go(*_TO_COMPLETE[:6])
    j.invoke("inv-m1", *IMPL)
    j.subphase = SubphaseId.model_validate("06")
    j.invoke("inv-m2", *IMPL)
    runtime = tmp_path / "rt"
    _write_journal(runtime, j)

    with pytest.raises(UnsupportedJournalError):
        project_runtime_stats(runtime)


# ===========================================================================
# AC-20 / AC-21 / AC-22: no formulas, no prose, no inference, no model calls
# ===========================================================================


def test_stats_module_does_not_reimplement_metric_semantics_or_touch_other_layers() -> None:
    source = _STATS_SOURCE.read_text()

    for forbidden in (
        "lockstep.agents",
        "lockstep.process",
        "lockstep.supervisor",
        "lockstep.agent_turn",
        "subprocess",
        "ExecutionEvent",
        "StateTransitionedEvent",
        "read_events",
        "REVIEW_DECIDED",
        ".detail",
        "import re\n",
    ):
        assert forbidden not in source, forbidden


def test_rendered_text_makes_no_interpretive_claims() -> None:
    text = render_stats(_all_three()).lower()

    for opinion in ("poor", "bad", "good", "inefficient", "too large", "should", "recommend"):
        assert opinion not in text, opinion


def test_scenario_metrics_are_unchanged_by_stats_projection() -> None:
    runs = [_run(_subphase_a()), _run(_subphase_b()), _run(_subphase_c())]
    before = [r.model_dump_json() for r in runs]

    project_stats(runs)
    render_stats(project_stats(runs))

    assert [r.model_dump_json() for r in runs] == before
    assert all(isinstance(s, SubphaseMetrics) for r in runs for s in r.subphases)
