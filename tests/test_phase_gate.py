"""Phase 11.5: the audit-only Phase-gate models, artifact layout, event vocabulary, and boundaries.

Covers what needs no provider: the typed gate artifacts and their invariants, the durable
attempt layout, the project-level gate event model (deliberately *not* a child-transaction
``ExecutionEvent``), and the architectural boundary that keeps a gate attempt inspection-only.

Baseline classification: every test in this module is RED at entry (``lockstep.phase_gate``
does not exist).
"""

from __future__ import annotations

import ast
import json
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import pytest
from pydantic import ValidationError

import lockstep.phase_gate as phase_gate
from lockstep.domain import ExecutionEventKind, PhaseId, ProjectId, RunId, SubphaseId
from lockstep.phase_gate import (
    PhaseGateAttemptDisposition,
    PhaseGateBasis,
    PhaseGateBasisRule,
    PhaseGateDecision,
    PhaseGateError,
    PhaseGateEvent,
    PhaseGateEventKind,
    PhaseGateEvidence,
    PhaseGateExecutionFailure,
    PhaseGateFinding,
    PhaseGateRefusal,
    PhaseGateReview,
    PhaseGateVerdict,
    PhaseGateViolation,
    RemediationReceipt,
    list_phase_gate_attempts,
    phase_gate_attempt_dir,
    phase_gate_dir,
    phase_gate_events_path,
)
from lockstep.verification_stack import CommandEvidence

_SRC = Path(__file__).resolve().parent.parent / "src" / "lockstep"
_DIGEST = "a" * 64
_COMMIT = "b" * 40


def _imported(module_file: str) -> set[str]:
    tree = ast.parse((_SRC / module_file).read_text())
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom | ast.Import):
            names.update(alias.name for alias in node.names)
    return names


def _command(exit_code: int, argv: tuple[str, ...] = ("./scripts/check",)) -> CommandEvidence:
    return CommandEvidence(
        argv=argv,
        exit_code=exit_code,
        stdout="out",
        stderr="err",
        stdout_truncated=False,
        stderr_truncated=False,
    )


def _evidence(*commands: CommandEvidence, configured: int | None = None) -> PhaseGateEvidence:
    return PhaseGateEvidence(
        project_id=ProjectId.model_validate("lockstep"),
        master_plan_digest=_DIGEST,
        phase_id=PhaseId.model_validate("01"),
        gate_attempt=1,
        basis_commit=_COMMIT,
        configured_command_count=configured if configured is not None else len(commands),
        max_output_bytes=1024,
        commands=commands,
    )


def _finding(criterion: str | None = "IC-1") -> PhaseGateFinding:
    return PhaseGateFinding(criterion_id=criterion, observation="It fails.", evidence="Because.")


def _review(verdict: PhaseGateVerdict, *findings: PhaseGateFinding) -> PhaseGateReview:
    return PhaseGateReview(
        phase_id=PhaseId.model_validate("01"),
        verdict=verdict,
        summary="Summary.",
        findings=findings,
    )


def _decision(**overrides: Any) -> PhaseGateDecision:
    data: dict[str, Any] = {
        "project_id": ProjectId.model_validate("lockstep"),
        "master_plan_digest": _DIGEST,
        "phase_id": PhaseId.model_validate("01"),
        "gate_attempt": 1,
        "basis_commit": _COMMIT,
        "outcome": PhaseGateVerdict.PASS,
        "deterministic_passed": True,
        "review": None,
        "summary": "Integrated.",
    }
    data.update(overrides)
    return PhaseGateDecision(**data)


def _event(kind: PhaseGateEventKind, **overrides: Any) -> PhaseGateEvent:
    data: dict[str, Any] = {
        "sequence": 1,
        "occurred_at": datetime(2026, 10, 2, 12, 0, 0, tzinfo=UTC),
        "kind": kind,
        "project_id": ProjectId.model_validate("lockstep"),
        "master_plan_digest": _DIGEST,
        "phase_id": PhaseId.model_validate("01"),
        "gate_attempt": 1,
        "basis_commit": _COMMIT,
    }
    data.update(overrides)
    return PhaseGateEvent(**data)


# ---------------------------------------------------------------------------
# Public surface and vocabularies
# ---------------------------------------------------------------------------


def test_public_api_exports_expected_names() -> None:
    assert set(phase_gate.__all__) == {
        "PhaseGateAttemptDisposition",
        "PhaseGateAttemptResult",
        "PhaseGateBasis",
        "PhaseGateBasisRule",
        "PhaseGateDecision",
        "PhaseGateError",
        "PhaseGateEvent",
        "PhaseGateEventKind",
        "PhaseGateEvidence",
        "PhaseGateExecutionFailure",
        "PhaseGateFinding",
        "PhaseGateRefusal",
        "PhaseGateReview",
        "PhaseGateVerdict",
        "PhaseGateViolation",
        "RemediationReceipt",
        "append_phase_gate_event",
        "build_phase_gate_review_prompt",
        "list_phase_gate_attempts",
        "load_phase_gate_basis",
        "load_phase_gate_decision",
        "load_phase_gate_evidence",
        "load_phase_gate_violation",
        "load_remediation_receipt",
        "phase_gate_attempt_dir",
        "phase_gate_dir",
        "phase_gate_events_path",
        "read_phase_gate_events",
        "run_phase_gate_attempt",
        "write_remediation_receipt",
    }


def test_the_gate_vocabularies_are_typed_and_distinct() -> None:
    assert {v.value for v in PhaseGateVerdict} == {"pass", "fail"}
    assert {d.value for d in PhaseGateAttemptDisposition} == {
        "passed",
        "failed",
        "execution_failed",
    }
    assert {f.value for f in PhaseGateExecutionFailure} == {
        "command_error",
        "review_failed",
        "authority_violation",
    }
    assert {k.value for k in PhaseGateEventKind} == {
        "phase_gate_started",
        "phase_gate_passed",
        "phase_gate_failed",
        "phase_gate_execution_failed",
        "phase_gate_remediation_planned",
        "phase_complete",
    }
    assert {r.name for r in PhaseGateRefusal} >= {
        "CURSOR_MISSING",
        "NO_CURRENT_PHASE",
        "NOT_READY",
        "ACTIVE_CONTRACT",
        "COMMANDS_NOT_CONFIGURED",
        "BASIS_UNAVAILABLE",
        "BASIS_DIRTY",
        "BASIS_DRIFT",
        "INVALID_REMEDIATION_BOUND",
    }
    assert {r.value for r in PhaseGateBasisRule} == {"latest_phase_subphase", "prior_phase_tip"}


def test_gate_event_kinds_do_not_pollute_the_child_transaction_event_vocabulary() -> None:
    assert {k.value for k in ExecutionEventKind}.isdisjoint({k.value for k in PhaseGateEventKind})
    assert PhaseGateEvent.model_fields["kind"].annotation is PhaseGateEventKind


def test_a_refusal_is_a_typed_deterministic_error() -> None:
    error = PhaseGateError(PhaseGateRefusal.NOT_READY, "the phase gate is not ready")

    assert error.refusal is PhaseGateRefusal.NOT_READY
    assert error.reason == "the phase gate is not ready"
    assert "not ready" in str(error)


# ---------------------------------------------------------------------------
# Artifact layout
# ---------------------------------------------------------------------------


def test_every_gate_attempt_has_its_own_directory_under_the_phase() -> None:
    runtime = Path("/runtime")
    phase = PhaseId.model_validate("01")

    assert phase_gate_dir(runtime, phase) == runtime / "phase-gates" / "01"
    assert phase_gate_attempt_dir(runtime, phase, 2) == runtime / "phase-gates" / "01" / "attempt-2"
    assert phase_gate_events_path(runtime, phase) == runtime / "phase-gates" / "01" / "events.jsonl"


def test_the_gate_journal_is_not_a_transaction_or_project_journal() -> None:
    runtime = Path("/runtime")
    path = phase_gate_events_path(runtime, PhaseId.model_validate("01"))

    assert path != runtime / "events.jsonl"
    assert "transactions" not in path.parts


def test_attempts_are_listed_in_numeric_order(tmp_path: Path) -> None:
    phase = PhaseId.model_validate("01")
    for number in (10, 2, 1):
        phase_gate_attempt_dir(tmp_path, phase, number).mkdir(parents=True)
    (phase_gate_dir(tmp_path, phase) / "attempt-x").mkdir()
    (phase_gate_dir(tmp_path, phase) / "events.jsonl").write_text("")

    assert list_phase_gate_attempts(tmp_path, phase) == (1, 2, 10)


def test_no_attempts_are_listed_for_a_phase_that_never_gated(tmp_path: Path) -> None:
    assert list_phase_gate_attempts(tmp_path, PhaseId.model_validate("01")) == ()


# ---------------------------------------------------------------------------
# Basis
# ---------------------------------------------------------------------------


def test_the_basis_names_the_accepted_run_branch_and_commit() -> None:
    basis = PhaseGateBasis(
        project_id=ProjectId.model_validate("lockstep"),
        master_plan_digest=_DIGEST,
        phase_id=PhaseId.model_validate("01"),
        gate_attempt=1,
        basis_phase_id=PhaseId.model_validate("01"),
        basis_subphase_id=SubphaseId.model_validate("02"),
        basis_run_id=RunId.model_validate("run-01-02"),
        branch="lockstep/run/run-01-02",
        commit=_COMMIT,
        rule=PhaseGateBasisRule.LATEST_PHASE_SUBPHASE,
    )

    assert PhaseGateBasis.model_validate_json(basis.model_dump_json()) == basis


@pytest.mark.parametrize("commit", ["abc", "G" * 40, "b" * 39, ""])
def test_a_basis_commit_must_be_a_git_object_id(commit: str) -> None:
    with pytest.raises(ValidationError):
        PhaseGateBasis(
            project_id=ProjectId.model_validate("lockstep"),
            master_plan_digest=_DIGEST,
            phase_id=PhaseId.model_validate("01"),
            gate_attempt=1,
            basis_phase_id=PhaseId.model_validate("01"),
            basis_subphase_id=SubphaseId.model_validate("02"),
            basis_run_id=RunId.model_validate("run-01-02"),
            branch="b",
            commit=commit,
            rule=PhaseGateBasisRule.LATEST_PHASE_SUBPHASE,
        )


# ---------------------------------------------------------------------------
# Deterministic evidence
# ---------------------------------------------------------------------------


def test_evidence_of_a_fully_passing_stack_passes() -> None:
    evidence = _evidence(_command(0), _command(0, ("./scripts/smoke",)))

    assert evidence.passed
    assert PhaseGateEvidence.model_validate_json(evidence.model_dump_json()) == evidence


def test_evidence_stops_at_the_first_required_failure() -> None:
    evidence = _evidence(_command(0), _command(2), configured=3)

    assert not evidence.passed
    assert [c.exit_code for c in evidence.commands] == [0, 2]


def test_evidence_cannot_show_commands_run_after_a_failure() -> None:
    with pytest.raises(ValidationError):
        _evidence(_command(2), _command(0), configured=2)


def test_evidence_cannot_stop_early_without_a_failure() -> None:
    with pytest.raises(ValidationError):
        _evidence(_command(0), configured=2)


def test_evidence_cannot_exceed_the_configured_stack() -> None:
    with pytest.raises(ValidationError):
        _evidence(_command(0), _command(0), configured=1)


def test_evidence_requires_at_least_one_command() -> None:
    with pytest.raises(ValidationError):
        _evidence(configured=1)


def test_evidence_output_is_bounded_by_the_recorded_limit() -> None:
    big = CommandEvidence(
        argv=("x",),
        exit_code=0,
        stdout="x" * 2048,
        stderr="",
        stdout_truncated=False,
        stderr_truncated=False,
    )

    with pytest.raises(ValidationError):
        _evidence(big)


# ---------------------------------------------------------------------------
# The Phase-gate review (a distinct decision type from the Sub-phase ReviewDecision)
# ---------------------------------------------------------------------------


def test_a_passing_review_carries_no_findings() -> None:
    assert _review(PhaseGateVerdict.PASS).findings == ()
    with pytest.raises(ValidationError):
        _review(PhaseGateVerdict.PASS, _finding())


def test_a_failing_review_needs_concrete_findings() -> None:
    assert _review(PhaseGateVerdict.FAIL, _finding()).verdict is PhaseGateVerdict.FAIL
    with pytest.raises(ValidationError):
        _review(PhaseGateVerdict.FAIL)


def test_a_finding_may_name_no_criterion_but_never_a_blank_observation() -> None:
    assert _finding(None).criterion_id is None
    with pytest.raises(ValidationError):
        PhaseGateFinding(criterion_id=None, observation=" ", evidence="e")


def test_the_review_is_a_versioned_strict_artifact() -> None:
    review = _review(PhaseGateVerdict.PASS)

    assert review.schema_version.root == 1
    assert PhaseGateReview.model_validate_json(review.model_dump_json()) == review
    with pytest.raises(ValidationError):
        PhaseGateReview.model_validate(
            {**json.loads(review.model_dump_json()), "unexpected": "field"}
        )
    with pytest.raises(ValidationError):
        PhaseGateReview.model_validate(
            {**json.loads(review.model_dump_json()), "schema_version": 2}
        )


def test_the_review_schema_is_derivable_for_structured_transport() -> None:
    schema = PhaseGateReview.model_json_schema()

    assert set(schema["properties"]) >= {"phase_id", "verdict", "summary", "findings"}


# ---------------------------------------------------------------------------
# The decision: the single durable acceptance point of a gate attempt
# ---------------------------------------------------------------------------


def test_a_deterministic_and_semantic_pass_is_a_pass() -> None:
    decision = _decision(review=_review(PhaseGateVerdict.PASS))

    assert decision.outcome is PhaseGateVerdict.PASS
    assert PhaseGateDecision.model_validate_json(decision.model_dump_json()) == decision


def test_a_pass_without_a_review_is_valid_when_the_phase_has_no_semantic_criteria() -> None:
    assert _decision(review=None).outcome is PhaseGateVerdict.PASS


def test_a_deterministic_failure_is_a_fail_without_any_review() -> None:
    decision = _decision(outcome=PhaseGateVerdict.FAIL, deterministic_passed=False, review=None)

    assert decision.outcome is PhaseGateVerdict.FAIL


def test_a_semantic_failure_is_a_fail_when_the_commands_passed() -> None:
    decision = _decision(
        outcome=PhaseGateVerdict.FAIL,
        review=_review(PhaseGateVerdict.FAIL, _finding()),
    )

    assert decision.review is not None
    assert decision.review.findings[0].criterion_id == "IC-1"


@pytest.mark.parametrize(
    "overrides",
    [
        # A PASS never survives a failed deterministic stack.
        {"outcome": PhaseGateVerdict.PASS, "deterministic_passed": False},
        # A PASS never survives a failing review.
        {
            "outcome": PhaseGateVerdict.PASS,
            "review": _review(PhaseGateVerdict.FAIL, _finding()),
        },
        # A FAIL needs a reason: a failed stack or a failing review.
        {"outcome": PhaseGateVerdict.FAIL, "deterministic_passed": True, "review": None},
        {
            "outcome": PhaseGateVerdict.FAIL,
            "deterministic_passed": True,
            "review": _review(PhaseGateVerdict.PASS),
        },
        # A model is never asked about a failed command, so no review accompanies it.
        {
            "outcome": PhaseGateVerdict.FAIL,
            "deterministic_passed": False,
            "review": _review(PhaseGateVerdict.FAIL, _finding()),
        },
    ],
)
def test_an_inconsistent_decision_is_unrepresentable(overrides: dict[str, Any]) -> None:
    with pytest.raises(ValidationError):
        _decision(**overrides)


def test_a_decision_binds_the_gate_identity() -> None:
    decision = _decision()

    assert decision.project_id == ProjectId.model_validate("lockstep")
    assert decision.master_plan_digest == _DIGEST
    assert decision.phase_id == PhaseId.model_validate("01")
    assert decision.gate_attempt == 1
    assert decision.basis_commit == _COMMIT
    with pytest.raises(ValidationError):
        _decision(gate_attempt=0)


# ---------------------------------------------------------------------------
# Violation and remediation receipt artifacts
# ---------------------------------------------------------------------------


def test_a_violation_records_where_tracked_content_changed() -> None:
    violation = PhaseGateViolation(
        project_id=ProjectId.model_validate("lockstep"),
        master_plan_digest=_DIGEST,
        phase_id=PhaseId.model_validate("01"),
        gate_attempt=1,
        basis_commit=_COMMIT,
        stage="commands",
        observed_head=_COMMIT,
        changed_paths=("feature_02.py",),
    )

    assert PhaseGateViolation.model_validate_json(violation.model_dump_json()) == violation
    with pytest.raises(ValidationError):
        PhaseGateViolation.model_validate({**json.loads(violation.model_dump_json()), "stage": "x"})


def test_a_remediation_receipt_holds_one_outline_and_the_gate_identity() -> None:
    from lockstep.domain import SubphaseOutline

    receipt = RemediationReceipt(
        project_id=ProjectId.model_validate("lockstep"),
        master_plan_digest=_DIGEST,
        phase_id=PhaseId.model_validate("01"),
        gate_attempt=1,
        basis_commit=_COMMIT,
        outline=SubphaseOutline(
            subphase_id=SubphaseId.model_validate("03"),
            title="Repair",
            objective="Repair the integration.",
            depends_on=(SubphaseId.model_validate("02"),),
        ),
    )

    assert RemediationReceipt.model_validate_json(receipt.model_dump_json()) == receipt
    assert "outlines" not in RemediationReceipt.model_fields


# ---------------------------------------------------------------------------
# Gate events: typed, project-level, bound to project / Phase / attempt / basis
# ---------------------------------------------------------------------------


def test_a_gate_event_binds_project_phase_attempt_and_basis() -> None:
    event = _event(PhaseGateEventKind.PHASE_GATE_STARTED)

    assert event.project_id == ProjectId.model_validate("lockstep")
    assert event.phase_id == PhaseId.model_validate("01")
    assert event.gate_attempt == 1
    assert event.basis_commit == _COMMIT
    assert PhaseGateEvent.model_validate_json(event.model_dump_json()) == event


def test_a_gate_event_does_not_carry_a_fake_subphase_identity() -> None:
    assert not {"subphase_id", "run_id"} & set(PhaseGateEvent.model_fields) - {"basis_run_id"}


def test_gate_event_timestamps_serialize_as_utc_with_a_z_suffix() -> None:
    payload = json.loads(_event(PhaseGateEventKind.PHASE_COMPLETE).model_dump_json())

    assert payload["occurred_at"] == "2026-10-02T12:00:00Z"


def test_a_gate_event_requires_a_timezone_aware_timestamp() -> None:
    with pytest.raises(ValidationError):
        _event(PhaseGateEventKind.PHASE_GATE_STARTED, occurred_at=datetime(2026, 10, 2))


def test_the_verdict_events_carry_exactly_their_verdict() -> None:
    assert _event(PhaseGateEventKind.PHASE_GATE_PASSED, verdict=PhaseGateVerdict.PASS).verdict
    assert _event(PhaseGateEventKind.PHASE_GATE_FAILED, verdict=PhaseGateVerdict.FAIL).verdict
    with pytest.raises(ValidationError):
        _event(PhaseGateEventKind.PHASE_GATE_PASSED, verdict=PhaseGateVerdict.FAIL)
    with pytest.raises(ValidationError):
        _event(PhaseGateEventKind.PHASE_GATE_FAILED)
    with pytest.raises(ValidationError):
        _event(PhaseGateEventKind.PHASE_GATE_STARTED, verdict=PhaseGateVerdict.PASS)


def test_an_execution_failure_event_names_its_failure_and_no_verdict() -> None:
    event = _event(
        PhaseGateEventKind.PHASE_GATE_EXECUTION_FAILED,
        failure=PhaseGateExecutionFailure.REVIEW_FAILED,
    )

    assert event.verdict is None
    with pytest.raises(ValidationError):
        _event(PhaseGateEventKind.PHASE_GATE_EXECUTION_FAILED)
    with pytest.raises(ValidationError):
        _event(
            PhaseGateEventKind.PHASE_GATE_EXECUTION_FAILED,
            failure=PhaseGateExecutionFailure.REVIEW_FAILED,
            verdict=PhaseGateVerdict.FAIL,
        )
    with pytest.raises(ValidationError):
        _event(
            PhaseGateEventKind.PHASE_GATE_STARTED, failure=PhaseGateExecutionFailure.COMMAND_ERROR
        )


# ---------------------------------------------------------------------------
# Boundaries: the gate attempt is inspection only; PASS authority lives in one place
# ---------------------------------------------------------------------------

_MUTATION_AUTHORITY = {
    "record_phase_completion",
    "reopen_cursor_for_remediation",
    "record_phase_gate_pass",
    "reopen_phase_for_remediation",
    "publish_phase_plan",
    "freeze_master_plan",
    "freeze_subphase_contract",
    "bind_frozen_contract",
    "record_completed_subphase",
    "retire_active_subphase_contract",
    "initialize_project_cursor",
    "revise_cursor_outline",
    "revise_cursor_unfinished_outline",
    "run_project_phase",
    "step_project_run",
    "run_single_subphase_transaction",
    "run_single_subphase_transaction_with_retry_checkpoint",
    "resume_single_subphase_transaction",
    "commit_exact_paths",
    "commit_exact_subset_paths",
    "create_run_worktree",
    "invoke_implementer_turn",
    "invoke_reviewer_turn",
    "append_event",
    "write_state",
}


def test_a_gate_attempt_holds_no_production_mutation_authority() -> None:
    assert _imported("phase_gate.py").isdisjoint(_MUTATION_AUTHORITY)


def test_a_gate_attempt_reads_the_cursor_but_never_writes_it() -> None:
    imported = _imported("phase_gate.py")

    assert "load_project_cursor" in imported
    source = (_SRC / "phase_gate.py").read_text()
    assert "cursor.json" not in source


def test_phase_completion_authority_lives_only_in_the_cursor_modules_and_the_gate_cycle() -> None:
    allowed = {"project_cursor.py", "project_cursor_store.py", "phase_gate_cycle.py"}
    holders = {
        path.name
        for path in _SRC.rglob("*.py")
        if "record_phase_completion" in path.read_text()
        or "record_phase_gate_pass" in path.read_text()
    }

    assert holders <= allowed
    assert "phase_gate_cycle.py" in holders


def test_the_gate_cycle_composes_the_ordinary_phase_runner_for_remediation() -> None:
    imported = _imported("phase_gate_cycle.py")

    assert "run_project_phase" in imported
    assert imported.isdisjoint(
        {
            "run_single_subphase_transaction",
            "run_single_subphase_transaction_with_retry_checkpoint",
            "resume_single_subphase_transaction",
            "freeze_subphase_contract",
            "bind_frozen_contract",
            "record_completed_subphase",
            "create_run_worktree",
            "commit_exact_paths",
            "invoke_implementer_turn",
            "invoke_reviewer_turn",
            "step_project_run",
        }
    )


def test_the_ordinary_orchestrator_still_owns_no_phase_completion() -> None:
    source = (_SRC / "project_orchestrator.py").read_text()

    assert "completed_phases" not in source
    assert "phase_gate" not in _imported("project_orchestrator.py")
    assert "phase_gate_cycle" not in _imported("project_orchestrator.py")
    assert "record_phase_completion" not in source


def test_the_phase_gate_event_journal_is_never_written_by_the_transaction_layer() -> None:
    for path in (_SRC / "supervisor").rglob("*.py"):
        assert "phase_gate" not in path.read_text(), path.name
    assert "phase_gate" not in (_SRC / "metrics.py").read_text()
