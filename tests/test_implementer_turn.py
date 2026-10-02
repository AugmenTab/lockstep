"""Phase 11.4: the specialized structured Implementer turn.

The generic ``AgentTurnReport`` (status + blocker) stays frozen and unchanged.
A canonical Implementer instead returns an ``ImplementerTurnReport``: a
COMPLETED turn must carry an identity-free ``ImplementationReportDraft`` and no
blocker, a BLOCKED turn must carry a blocker and no report. The host builds the
canonical domain ``ImplementationReport`` from the draft plus host-owned
identity and persists it per attempt.

Baseline classification: every test in this module is RED at entry
(``lockstep.implementer_turn`` does not exist).
"""

from __future__ import annotations

import inspect
import json
from pathlib import Path

import pytest
from pydantic import ValidationError
from test_supervisor_resume_execution import (
    _attempt,
    _budget,
    _implementer_blocked_response,
    _implementer_completed_response,
    _phase_id,
    _prepare_scenario,
    _subphase_id,
)

import lockstep.supervisor.transaction as transaction_module
from lockstep.agent_turn import (
    AgentBlockerDraft,
    AgentTurnError,
    AgentTurnReport,
    AgentTurnStatus,
    invoke_agent_turn,
)
from lockstep.domain import ImplementationReport
from lockstep.escalation import EscalationAuthority, EscalationCategory
from lockstep.evidence_store import load_implementation_report
from lockstep.implementer_turn import (
    ImplementationReportDraft,
    ImplementerTurnError,
    ImplementerTurnReport,
    ImplementerTurnResult,
    invoke_implementer_turn,
)
from lockstep.supervisor.transaction import (
    SingleSubphaseTransactionResult,
    run_single_subphase_transaction_with_retry_checkpoint,
)

_BLOCKER = AgentBlockerDraft(
    category=EscalationCategory.ARCHITECTURE_CONFLICT,
    question="Which design?",
    evidence=("two designs fit",),
    requested_authority=EscalationAuthority.PLANNER,
)


def _turn(scenario_root: Path, responses: list[dict[str, object]]) -> ImplementerTurnResult:
    scenario = _prepare_scenario(scenario_root, implementer_responses=responses)
    cwd = scenario_root / "cwd"
    cwd.mkdir()
    return invoke_implementer_turn(
        scenario.runtime,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(1),
        prompt="implement the change",
        cwd=cwd,
        timeout_seconds=30.0,
    )


# --- the report models -----------------------------------------------------------------


def test_a_completed_report_requires_a_draft_and_forbids_a_blocker() -> None:
    draft = ImplementationReportDraft(summary="done")

    ImplementerTurnReport(
        status=AgentTurnStatus.COMPLETED, implementation_report=draft, blocker=None
    )
    with pytest.raises(ValidationError):
        ImplementerTurnReport(
            status=AgentTurnStatus.COMPLETED, implementation_report=None, blocker=None
        )
    with pytest.raises(ValidationError):
        ImplementerTurnReport(
            status=AgentTurnStatus.COMPLETED, implementation_report=draft, blocker=_BLOCKER
        )


def test_a_blocked_report_requires_a_blocker_and_forbids_a_draft() -> None:
    draft = ImplementationReportDraft(summary="done")

    ImplementerTurnReport(
        status=AgentTurnStatus.BLOCKED, implementation_report=None, blocker=_BLOCKER
    )
    with pytest.raises(ValidationError):
        ImplementerTurnReport(
            status=AgentTurnStatus.BLOCKED, implementation_report=None, blocker=None
        )
    with pytest.raises(ValidationError):
        ImplementerTurnReport(
            status=AgentTurnStatus.BLOCKED, implementation_report=draft, blocker=_BLOCKER
        )


def test_unknown_report_fields_are_rejected() -> None:
    with pytest.raises(ValidationError):
        ImplementerTurnReport.model_validate(
            {
                "status": "completed",
                "implementation_report": {"summary": "done"},
                "blocker": None,
                "allowed_paths": ["src/outside_scope.py"],
            }
        )
    with pytest.raises(ValidationError):
        ImplementationReportDraft.model_validate({"summary": "done", "allowed_paths": ["x"]})


def test_the_draft_carries_no_host_owned_identity() -> None:
    assert set(ImplementationReportDraft.model_fields) == {
        "summary",
        "changed_files",
        "decisions",
        "deviations",
        "concerns",
    }
    with pytest.raises(ValidationError):
        ImplementationReportDraft.model_validate(
            {"summary": "done", "phase_id": "01", "subphase_id": "01", "attempt": 1}
        )


def test_the_generic_agent_turn_report_is_unchanged() -> None:
    assert set(AgentTurnReport.model_fields) == {"status", "blocker"}
    AgentTurnReport.model_validate({"status": "completed", "blocker": None})
    assert list(inspect.signature(invoke_agent_turn).parameters) == [
        "runtime",
        "role",
        "phase_id",
        "subphase_id",
        "attempt",
        "prompt",
        "cwd",
        "timeout_seconds",
        "max_output_bytes",
        "termination_grace_seconds",
        "run_id",
    ]


def test_implementer_errors_are_agent_turn_errors() -> None:
    assert issubclass(ImplementerTurnError, AgentTurnError)


# --- the invocation seam -----------------------------------------------------------------


def test_a_completed_turn_returns_the_structured_report(tmp_path: Path) -> None:
    result = _turn(tmp_path / "s", [_implementer_completed_response({"feature.py": "x = 1\n"})])

    assert result.report.status is AgentTurnStatus.COMPLETED
    assert result.report.implementation_report is not None
    assert result.report.implementation_report.summary == "Implemented the requested change."
    assert result.escalation_request is None


def test_a_completed_turn_without_a_report_is_rejected(tmp_path: Path) -> None:
    bare = {"stdout": json.dumps({"status": "completed", "blocker": None}), "returncode": 0}

    with pytest.raises(ImplementerTurnError):
        _turn(tmp_path / "s", [bare])


def test_a_blocked_turn_stays_correctly_structured(tmp_path: Path) -> None:
    result = _turn(
        tmp_path / "s",
        [
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            )
        ],
    )

    assert result.report.status is AgentTurnStatus.BLOCKED
    assert result.report.implementation_report is None
    assert result.escalation_request is not None
    assert result.escalation_request.category is EscalationCategory.ARCHITECTURE_CONFLICT


# --- the transaction composes the seam and persists the report ------------------------------


def test_the_transaction_invokes_the_implementer_through_the_specialized_seam(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = _prepare_scenario(tmp_path / "s")
    real = transaction_module.invoke_implementer_turn
    calls: list[object] = []

    def counting(*args: object, **kwargs: object) -> object:
        calls.append(kwargs["attempt"])
        return real(*args, **kwargs)

    monkeypatch.setattr(transaction_module, "invoke_implementer_turn", counting)

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(1)
    )

    assert isinstance(result, SingleSubphaseTransactionResult)
    assert len(calls) == 1


def test_the_host_persists_the_canonical_report_with_host_owned_identity(tmp_path: Path) -> None:
    scenario = _prepare_scenario(tmp_path / "s")
    request = scenario.request

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(1)
    )
    assert isinstance(result, SingleSubphaseTransactionResult)
    del result  # discard every in-memory transaction/agent object

    reloaded = load_implementation_report(
        request.runtime_dir,
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        attempt=_attempt(1),
    )
    assert reloaded == ImplementationReport(
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        attempt=_attempt(1),
        summary="Implemented the requested change.",
    )
