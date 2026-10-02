"""Phase 11.6: durable run control -- identity, immutable policy, deadline, budget reservations.

The control artifact owns only run control: unattended-run identity, the immutable policy and its
digest, the start and deadline, Sub-phase budget reservations, the last stop disposition, and an
append-only audit journal. It never claims where the project *is*: that stays in the
``ProjectCursor``.

Layout (beneath the project run root)::

    project-runs/<project-run-id>/policy.json   immutable record: identity, policy, digest, deadline
                                  state.json    reservations and the last stop (atomic replace)
                                  events.jsonl  append-only control-plane audit journal

Baseline classification: every test here is RED at entry (``lockstep.autonomous_run_control``
does not exist).
"""

from __future__ import annotations

import json
from datetime import timedelta
from itertools import pairwise
from pathlib import Path
from typing import Any

import pytest
from autonomous_run_support import FakeClock, make_policy

from lockstep.autonomous_run_control import (
    AutonomousRunDisposition,
    AutonomousRunError,
    AutonomousRunPolicyMismatchError,
    AutonomousRunStoreError,
    ProjectRunEventKind,
    ProjectRunId,
    ReservationOutcome,
    create_project_run,
    list_project_runs,
    load_project_run,
    load_project_run_state,
    policy_digest,
    project_run_dir,
    read_project_run_events,
    record_project_run_stop,
    require_same_policy,
    reserve_subphase,
)
from lockstep.domain import AttemptNumber, PhaseId, ProjectId, RunId, SubphaseId
from lockstep.retry import RetryBudget

_PROJECT = ProjectId.model_validate("lockstep")
_DIGEST = "a" * 64
_FORBIDDEN_PROGRESS_KEYS = {
    "current_phase",
    "current_subphase",
    "completed_phases",
    "completed_subphases",
    "remaining_outline",
    "active_contract",
    "phase_gate_status",
}


def _create(tmp_path: Path, clock: FakeClock, **policy: Any) -> Any:
    return create_project_run(
        tmp_path / "runtime",
        project_id=_PROJECT,
        master_plan_digest=_DIGEST,
        policy=make_policy(**policy),
        clock=clock,
    )


def _reserve(tmp_path: Path, clock: FakeClock, run: ProjectRunId, phase: str, sid: str) -> Any:
    return reserve_subphase(
        tmp_path / "runtime",
        run,
        phase_id=PhaseId.model_validate(phase),
        subphase_id=SubphaseId.model_validate(sid),
        transaction_run_id=RunId.model_validate(f"run-{phase}-{sid}"),
        clock=clock,
    )


def _keys(value: Any) -> set[str]:
    if isinstance(value, dict):
        return set(value) | {k for child in value.values() for k in _keys(child)}
    if isinstance(value, list):
        return {k for child in value for k in _keys(child)}
    return set()


def test_disposition_vocabulary_is_typed_and_reuses_canonical_names() -> None:
    assert {d.name for d in AutonomousRunDisposition} == {
        "PROJECT_COMPLETE",
        "PHASE_BOUNDARY_REACHED",
        "MAX_SUBPHASES_REACHED",
        "WALL_CLOCK_BUDGET_EXHAUSTED",
        "GATE_REMEDIATION_EXHAUSTED",
        "HUMAN_REQUIRED",
        "USAGE_LIMIT",
        "RECOVERY_REQUIRED",
        "TERMINAL_HALT",
    }


def test_project_run_identity_is_allocated_deterministically_and_listed(tmp_path: Path) -> None:
    clock = FakeClock()

    first = _create(tmp_path, clock)
    second = _create(tmp_path, clock)

    assert first.project_run_id == ProjectRunId.model_validate("prun-0001")
    assert second.project_run_id == ProjectRunId.model_validate("prun-0002")
    assert list_project_runs(tmp_path / "runtime") == (first.project_run_id, second.project_run_id)


def test_an_existing_project_run_is_never_recreated_or_overwritten(tmp_path: Path) -> None:
    clock = FakeClock()
    first = _create(tmp_path, clock)

    with pytest.raises(AutonomousRunStoreError):
        create_project_run(
            tmp_path / "runtime",
            project_id=_PROJECT,
            master_plan_digest=_DIGEST,
            policy=make_policy(max_subphases=99),
            clock=clock,
            project_run_id=first.project_run_id,
        )

    assert load_project_run(tmp_path / "runtime", first.project_run_id) == first


def test_the_layout_is_exactly_policy_state_and_an_append_only_journal(tmp_path: Path) -> None:
    run = _create(tmp_path, FakeClock())
    directory = project_run_dir(tmp_path / "runtime", run.project_run_id)

    assert directory == tmp_path / "runtime" / "project-runs" / "prun-0001"
    assert sorted(p.name for p in directory.iterdir()) == [
        "events.jsonl",
        "policy.json",
        "state.json",
    ]


def test_the_record_binds_identity_policy_digest_start_and_deadline(tmp_path: Path) -> None:
    clock = FakeClock()
    run = _create(tmp_path, clock, wall_clock_seconds=600.0)

    assert run.project_id == _PROJECT
    assert run.master_plan_digest == _DIGEST
    assert run.policy == make_policy(wall_clock_seconds=600.0)
    assert run.policy_digest == policy_digest(run.policy)
    assert run.started_at == clock()
    assert run.deadline_at == clock() + timedelta(seconds=600)


def test_the_deadline_is_durable_and_never_resets_when_the_record_is_reloaded(
    tmp_path: Path,
) -> None:
    clock = FakeClock()
    run = _create(tmp_path, clock, wall_clock_seconds=600.0)
    deadline = run.deadline_at

    clock.advance(100_000)  # the process was dead for a long time
    reloaded = load_project_run(tmp_path / "runtime", run.project_run_id)

    assert reloaded is not None
    assert reloaded.deadline_at == deadline
    assert reloaded.started_at == run.started_at
    assert reloaded == run


def test_a_missing_project_run_loads_as_none_and_a_missing_state_as_an_error(
    tmp_path: Path,
) -> None:
    unknown = ProjectRunId.model_validate("prun-0042")

    assert load_project_run(tmp_path / "runtime", unknown) is None
    with pytest.raises(AutonomousRunStoreError):
        load_project_run_state(tmp_path / "runtime", unknown)


def test_a_tampered_policy_record_is_detected_by_its_digest(tmp_path: Path) -> None:
    run = _create(tmp_path, FakeClock())
    path = project_run_dir(tmp_path / "runtime", run.project_run_id) / "policy.json"
    original = path.read_text(encoding="utf-8")
    tampered = original.replace('"max_subphases":10', '"max_subphases":99')
    assert tampered != original
    path.write_text(tampered, encoding="utf-8")

    with pytest.raises(AutonomousRunStoreError):
        load_project_run(tmp_path / "runtime", run.project_run_id)


@pytest.mark.parametrize(
    "changes",
    [
        {"max_subphases": 11},
        {"max_unattended_wall_clock_seconds": 3601.0},
        {"retry_budget": RetryBudget(max_attempts=AttemptNumber.model_validate(4))},
        {"max_gate_remediations": 2},
        {"until_phase": PhaseId.model_validate("02")},
    ],
)
def test_resuming_under_any_other_policy_is_refused(
    tmp_path: Path, changes: dict[str, Any]
) -> None:
    run = _create(tmp_path, FakeClock())

    require_same_policy(run, make_policy())
    with pytest.raises(AutonomousRunPolicyMismatchError) as refused:
        require_same_policy(run, make_policy().model_copy(update=changes))

    assert isinstance(refused.value, AutonomousRunError)


def test_a_sub_phase_is_reserved_once_and_a_repeat_costs_nothing(tmp_path: Path) -> None:
    clock = FakeClock()
    run = _create(tmp_path, clock, max_subphases=2)

    assert _reserve(tmp_path, clock, run.project_run_id, "01", "01") is ReservationOutcome.RESERVED
    assert (
        _reserve(tmp_path, clock, run.project_run_id, "01", "01")
        is ReservationOutcome.ALREADY_RESERVED
    )
    assert _reserve(tmp_path, clock, run.project_run_id, "01", "02") is ReservationOutcome.RESERVED

    state = load_project_run_state(tmp_path / "runtime", run.project_run_id)
    assert [(r.phase_id.root, r.subphase_id.root) for r in state.reservations] == [
        ("01", "01"),
        ("01", "02"),
    ]
    assert [r.transaction_run_id.root for r in state.reservations] == ["run-01-01", "run-01-02"]


def test_the_budget_is_finite_and_an_over_budget_unit_is_not_recorded(tmp_path: Path) -> None:
    clock = FakeClock()
    run = _create(tmp_path, clock, max_subphases=1)
    _reserve(tmp_path, clock, run.project_run_id, "01", "01")

    refused = _reserve(tmp_path, clock, run.project_run_id, "01", "02")

    assert refused is ReservationOutcome.EXHAUSTED
    state = load_project_run_state(tmp_path / "runtime", run.project_run_id)
    assert len(state.reservations) == 1
    # An existing reservation is still honoured once the budget is spent.
    assert (
        _reserve(tmp_path, clock, run.project_run_id, "01", "01")
        is ReservationOutcome.ALREADY_RESERVED
    )


def test_a_zero_budget_reserves_nothing(tmp_path: Path) -> None:
    clock = FakeClock()
    run = _create(tmp_path, clock, max_subphases=0)

    assert _reserve(tmp_path, clock, run.project_run_id, "01", "01") is ReservationOutcome.EXHAUSTED
    assert load_project_run_state(tmp_path / "runtime", run.project_run_id).reservations == ()


def test_reservations_survive_a_restart_because_they_are_durable_state(tmp_path: Path) -> None:
    clock = FakeClock()
    run = _create(tmp_path, clock, max_subphases=1)
    _reserve(tmp_path, clock, run.project_run_id, "01", "01")
    before = load_project_run_state(tmp_path / "runtime", run.project_run_id)

    clock.advance(10_000)
    again = load_project_run_state(tmp_path / "runtime", run.project_run_id)

    assert again == before
    assert _reserve(tmp_path, clock, run.project_run_id, "01", "01") is (
        ReservationOutcome.ALREADY_RESERVED
    )
    assert load_project_run_state(tmp_path / "runtime", run.project_run_id) == before


def test_the_last_stop_is_recorded_without_touching_the_immutable_policy(tmp_path: Path) -> None:
    clock = FakeClock()
    run = _create(tmp_path, clock)
    directory = project_run_dir(tmp_path / "runtime", run.project_run_id)
    policy_bytes = (directory / "policy.json").read_bytes()
    assert load_project_run_state(tmp_path / "runtime", run.project_run_id).stop is None

    record_project_run_stop(
        tmp_path / "runtime",
        run.project_run_id,
        disposition=AutonomousRunDisposition.MAX_SUBPHASES_REACHED,
        detail="budget spent",
        clock=clock,
    )

    stop = load_project_run_state(tmp_path / "runtime", run.project_run_id).stop
    assert stop is not None
    assert stop.disposition is AutonomousRunDisposition.MAX_SUBPHASES_REACHED
    assert stop.detail == "budget spent"
    assert (directory / "policy.json").read_bytes() == policy_bytes


def test_the_journal_is_append_only_typed_and_contiguous(tmp_path: Path) -> None:
    clock = FakeClock()
    run = _create(tmp_path, clock, max_subphases=2)
    journal = project_run_dir(tmp_path / "runtime", run.project_run_id) / "events.jsonl"
    snapshots = [journal.read_bytes()]

    _reserve(tmp_path, clock, run.project_run_id, "01", "01")
    snapshots.append(journal.read_bytes())
    _reserve(tmp_path, clock, run.project_run_id, "01", "01")  # a repeat appends nothing
    assert journal.read_bytes() == snapshots[-1]
    record_project_run_stop(
        tmp_path / "runtime",
        run.project_run_id,
        disposition=AutonomousRunDisposition.PROJECT_COMPLETE,
        clock=clock,
    )
    snapshots.append(journal.read_bytes())

    events = read_project_run_events(tmp_path / "runtime", run.project_run_id)
    assert [e.kind for e in events] == [
        ProjectRunEventKind.RUN_STARTED,
        ProjectRunEventKind.SUBPHASE_RESERVED,
        ProjectRunEventKind.RUN_STOPPED,
    ]
    assert [e.sequence for e in events] == [1, 2, 3]
    assert {e.project_run_id for e in events} == {run.project_run_id}
    for earlier, later in pairwise(snapshots):
        assert later.startswith(earlier)
    assert events[1].phase_id == PhaseId.model_validate("01")
    assert events[2].disposition is AutonomousRunDisposition.PROJECT_COMPLETE


def test_run_control_never_claims_where_the_project_is(tmp_path: Path) -> None:
    clock = FakeClock()
    run = _create(tmp_path, clock, max_subphases=1)
    _reserve(tmp_path, clock, run.project_run_id, "01", "01")
    record_project_run_stop(
        tmp_path / "runtime",
        run.project_run_id,
        disposition=AutonomousRunDisposition.MAX_SUBPHASES_REACHED,
        clock=clock,
    )
    directory = project_run_dir(tmp_path / "runtime", run.project_run_id)

    for name in ("policy.json", "state.json"):
        assert _keys(json.loads((directory / name).read_text(encoding="utf-8"))).isdisjoint(
            _FORBIDDEN_PROGRESS_KEYS
        )
    for line in (directory / "events.jsonl").read_text(encoding="utf-8").splitlines():
        assert _keys(json.loads(line)).isdisjoint(_FORBIDDEN_PROGRESS_KEYS)


def test_no_temporary_files_are_left_behind(tmp_path: Path) -> None:
    clock = FakeClock()
    run = _create(tmp_path, clock, max_subphases=2)
    _reserve(tmp_path, clock, run.project_run_id, "01", "01")
    record_project_run_stop(
        tmp_path / "runtime",
        run.project_run_id,
        disposition=AutonomousRunDisposition.TERMINAL_HALT,
        clock=clock,
    )

    directory = project_run_dir(tmp_path / "runtime", run.project_run_id)

    assert sorted(p.name for p in directory.iterdir()) == [
        "events.jsonl",
        "policy.json",
        "state.json",
    ]
