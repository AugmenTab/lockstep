"""Phase 11.5: accepted behavior the Phase gate must not disturb.

Baseline classification: every test in this module is GREEN_REGRESSION -- the accepted 10.x /
11.1-11.4 system already satisfies it and it must stay green (it imports nothing 11.5 adds):

* the Phase-10 child-transaction event vocabulary and metrics baseline v1 are unchanged, so
  project-level gate telemetry can only ever be a separate stream;
* an accepted v1 cursor (the pre-gate field set) still loads and re-serializes identically;
* the ordinary Phase runner keeps its 11.3 JIT-replanning default.
"""

from __future__ import annotations

import inspect
import json
import subprocess
from pathlib import Path

from lockstep.domain import ExecutionEventKind
from lockstep.project_cursor import PhaseGateStatus, ProjectCursor
from lockstep.project_orchestrator import run_project_phase, step_project_run

_REPO = Path(__file__).resolve().parent.parent
_BASELINE = Path(__file__).parent / "baselines" / "transaction_baseline.json"

_V1_CURSOR = {
    "schema_version": 1,
    "project_id": "lockstep",
    "master_plan_digest": "a" * 64,
    "revision": 4,
    "current_phase": "02",
    "completed_phases": ["01"],
    "current_subphase": "02",
    "completed_subphases": [
        {"phase_id": "01", "subphase_id": "01", "run_id": "run-01-01", "contract_digest": "b" * 64},
        {"phase_id": "02", "subphase_id": "01", "run_id": "run-02-01", "contract_digest": "c" * 64},
    ],
    "remaining_outline": [
        {
            "subphase_id": "03",
            "title": "Outline 03",
            "objective": "Objective 03.",
            "depends_on": ["02"],
        }
    ],
    "active_contract": None,
    "phase_gate_status": "subphases_pending",
}


def test_the_child_transaction_event_vocabulary_is_exactly_the_phase_10_set() -> None:
    assert {kind.value for kind in ExecutionEventKind} == {
        "invocation_started",
        "invocation_returned",
        "baseline_verified",
        "tests_frozen",
        "verification_completed",
        "review_decided",
        "escalation_dispatched",
        "retry_authorized",
        "retry_exhausted",
        "resume_claimed",
        "resume_started",
        "resume_settled",
        "transaction_halted",
        "transaction_aborted",
    }


def test_the_transaction_metrics_baseline_is_still_version_one_and_unmodified() -> None:
    assert json.loads(_BASELINE.read_text(encoding="utf-8"))["baseline_version"] == 1

    unmodified = subprocess.run(
        ["git", "-C", str(_REPO), "diff", "--quiet", "HEAD", "--", str(_BASELINE)],
        check=False,
    )
    assert unmodified.returncode == 0


def test_an_accepted_v1_cursor_loads_and_reserializes_identically() -> None:
    cursor = ProjectCursor.model_validate(_V1_CURSOR)

    assert cursor.schema_version.root == 1
    assert cursor.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING
    assert cursor.completed_phases[0].root == "01"
    assert cursor.model_dump(mode="json") == _V1_CURSOR


def test_the_ordinary_phase_runner_keeps_its_default_on_jit_replanning() -> None:
    for function in (run_project_phase, step_project_run):
        parameter = inspect.signature(function).parameters["jit_replan"]
        assert parameter.kind is inspect.Parameter.KEYWORD_ONLY
        assert parameter.default is True
