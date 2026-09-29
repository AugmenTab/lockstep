"""Planner-authored specification of Sub-phase 9.12 durable resume settlements.

Specifies ``lockstep.resume_settlement`` before it exists: the durable
settlement protocol that explains what happened to an already-``STARTED``
:class:`~lockstep.resume.ResumeClaim` before that claim is ever removed,
built strictly on top of the frozen Sub-phase 9.8 attempt-state/retry-
budget protocol (``lockstep.retry``), the frozen Sub-phase 9.9 durable
retry checkpoint store (``lockstep.retry_checkpoint``), and the frozen
Sub-phase 9.11 durable resume claim protocol (``lockstep.resume``).

A ``ResumeSettlement`` durably records one of four outcomes for a
``STARTED`` claim -- ``COMPLETED``, ``HALTED``, ``NEXT_RETRY``, or
``EXECUTION_FAILED`` -- and, only for ``NEXT_RETRY``, embeds the exact
next ``RetryCheckpoint`` that continues the attempt/phase/subphase/
budget chain. The core invariant: a ``STARTED`` claim is removed only
after a durable settlement explains what happened to it, and (for
``NEXT_RETRY``) only after the next checkpoint is itself durable. This
module never launches an agent, never mutates the Supervisor
transaction, FSM, or event journal, and never re-implements frozen
``RetryCheckpoint`` validation -- it adds only the chain relationship
between an old ``STARTED`` claim and the new checkpoint that settles it.
"""

import ast
import inspect
import json
import subprocess
import sys
from pathlib import Path

import pytest
from pydantic import ValidationError

import lockstep.resume_settlement as resume_settlement_module
import lockstep.retry_checkpoint as retry_checkpoint_module
from lockstep.agents import AgentInvocationResult
from lockstep.domain import (
    AgentRole,
    BillingMode,
    PhaseId,
    SubphaseId,
)
from lockstep.escalation import (
    EscalationAuthority,
    EscalationCategory,
    EscalationRequest,
    route_escalation,
)
from lockstep.escalation_decision import (
    PlannerDecision,
    PlannerDecisionKind,
    escalation_request_digest,
    resolve_planner_decision,
)
from lockstep.escalation_transport import PlannerDecisionTurnResult
from lockstep.process import ProcessResult
from lockstep.resume import (
    ResumeClaim,
    ResumeClaimStatus,
    ResumeDisposition,
    claim_retry_checkpoint,
    inspect_resume,
    mark_resume_started,
    resume_claim_path,
    retry_checkpoint_digest,
)
from lockstep.resume_settlement import (
    ResumeSettlement,
    ResumeSettlementOutcome,
    ResumeSettlementStoreError,
    finalize_resume_settlement,
    freeze_resume_settlement,
    load_resume_settlement,
    resume_settlement_path,
)
from lockstep.retry import AttemptState, RetryBudget, RetryBudgetDisposition
from lockstep.retry_checkpoint import (
    RetryCheckpoint,
    RetryCheckpointStoreError,
    create_retry_checkpoint_from_escalation,
    freeze_retry_checkpoint,
    load_retry_checkpoint,
    retry_checkpoint_path,
)
from lockstep.supervisor.escalation import (
    SupervisorEscalationDisposition,
    SupervisorEscalationResult,
)

_PHASE_ID = "09"
_SUBPHASE_ID = "12"


# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------


def _phase_id(value: str = _PHASE_ID) -> PhaseId:
    return PhaseId.model_validate(value)


def _subphase_id(value: str = _SUBPHASE_ID) -> SubphaseId:
    return SubphaseId.model_validate(value)


def _escalation_request(
    *,
    source_role: AgentRole = AgentRole.IMPLEMENTER,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    attempt: int = 1,
    category: EscalationCategory = EscalationCategory.ARCHITECTURE_CONFLICT,
    question: str = "Is the previously reported blocker now resolved?",
    evidence: tuple[str, ...] = ("The Planner authorized a bounded change.",),
    requested_authority: EscalationAuthority = EscalationAuthority.PLANNER,
) -> EscalationRequest:
    return EscalationRequest(
        source_role=source_role,
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        attempt=attempt,
        category=category,
        question=question,
        evidence=evidence,
        requested_authority=requested_authority,
    )


def _planner_decision(
    request: EscalationRequest,
    *,
    kind: PlannerDecisionKind = PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
    rationale: str = "Bounded correction authorized.",
    instructions: tuple[str, ...] = ("Apply the bounded fix.",),
    authorized_paths: tuple[str, ...] = (),
) -> PlannerDecision:
    return PlannerDecision(
        request_digest=escalation_request_digest(request),
        kind=kind,
        rationale=rationale,
        instructions=instructions,
        authorized_paths=authorized_paths,
    )


def _agent_invocation_result(
    *, stdout: str = "", adapter_name: str = "fake-planner"
) -> AgentInvocationResult:
    process = ProcessResult(
        argv=("fake-planner",),
        cwd=Path("."),
        returncode=0,
        stdout=stdout,
        stderr="",
        stdout_truncated=False,
        stderr_truncated=False,
    )
    return AgentInvocationResult(
        adapter_name=adapter_name,
        role=AgentRole.PLANNER,
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        process=process,
    )


def _planner_turn_result(
    request: EscalationRequest,
    decision: PlannerDecision,
    *,
    invocation: AgentInvocationResult | None = None,
) -> PlannerDecisionTurnResult:
    resolution = resolve_planner_decision(request, decision)
    return PlannerDecisionTurnResult(
        decision=decision,
        resolution=resolution,
        invocation=invocation if invocation is not None else _agent_invocation_result(),
    )


def _escalation_result(
    *,
    request: EscalationRequest,
    disposition: SupervisorEscalationDisposition,
    planner_turn: PlannerDecisionTurnResult | None = None,
) -> SupervisorEscalationResult:
    return SupervisorEscalationResult(
        request=request,
        route=route_escalation(request),
        disposition=disposition,
        planner_turn=planner_turn,
    )


def _resume_escalation_result(
    *,
    source_role: AgentRole = AgentRole.IMPLEMENTER,
    attempt: int = 1,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    question: str = "Is the previously reported blocker now resolved?",
    evidence: tuple[str, ...] = ("The Planner authorized a bounded change.",),
    rationale: str = "Bounded correction authorized.",
    instructions: tuple[str, ...] = ("Apply the bounded fix.",),
    invocation: AgentInvocationResult | None = None,
) -> tuple[EscalationRequest, PlannerDecision, SupervisorEscalationResult]:
    request = _escalation_request(
        source_role=source_role,
        attempt=attempt,
        phase_id=phase_id,
        subphase_id=subphase_id,
        question=question,
        evidence=evidence,
    )
    decision = _planner_decision(request, rationale=rationale, instructions=instructions)
    planner_turn = _planner_turn_result(request, decision, invocation=invocation)
    result = _escalation_result(
        request=request,
        disposition=SupervisorEscalationDisposition.RESUME_AGENT,
        planner_turn=planner_turn,
    )
    return request, decision, result


def _attempt_state(
    *,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    current_attempt: int = 1,
) -> AttemptState:
    return AttemptState(
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        current_attempt=current_attempt,
    )


def _valid_escalation_checkpoint(
    *,
    current_attempt: int = 1,
    max_attempts: int = 3,
    source_role: AgentRole = AgentRole.IMPLEMENTER,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    question: str = "Is the previously reported blocker now resolved?",
    evidence: tuple[str, ...] = ("The Planner authorized a bounded change.",),
    invocation: AgentInvocationResult | None = None,
) -> tuple[RetryCheckpoint, EscalationRequest, PlannerDecision]:
    request, decision, result = _resume_escalation_result(
        source_role=source_role,
        attempt=current_attempt,
        phase_id=phase_id,
        subphase_id=subphase_id,
        question=question,
        evidence=evidence,
        invocation=invocation,
    )
    attempt_state = _attempt_state(
        phase_id=phase_id, subphase_id=subphase_id, current_attempt=current_attempt
    )
    budget = RetryBudget(max_attempts=max_attempts)
    checkpoint = create_retry_checkpoint_from_escalation(
        attempt_state=attempt_state, budget=budget, result=result
    )
    assert checkpoint is not None
    return checkpoint, request, decision


def _runtime_dir(tmp_path: Path) -> Path:
    directory = tmp_path / "runtime"
    directory.mkdir()
    return directory


def _claimed_claim(checkpoint: RetryCheckpoint) -> ResumeClaim:
    return ResumeClaim(
        schema_version=1,
        checkpoint_digest=retry_checkpoint_digest(checkpoint),
        checkpoint=checkpoint,
        status=ResumeClaimStatus.CLAIMED,
    )


def _started_claim_object(checkpoint: RetryCheckpoint) -> ResumeClaim:
    return _claimed_claim(checkpoint).model_copy(update={"status": ResumeClaimStatus.STARTED})


def _write_claim_file(runtime_dir: Path, claim: ResumeClaim) -> Path:
    path = resume_claim_path(runtime_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(
        claim.model_dump(mode="json"), ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    path.write_bytes((text + "\n").encode("utf-8"))
    return path


def _started_claim(
    runtime_dir: Path,
    *,
    current_attempt: int = 1,
    max_attempts: int = 3,
    source_role: AgentRole = AgentRole.IMPLEMENTER,
) -> ResumeClaim:
    checkpoint, *_ = _valid_escalation_checkpoint(
        current_attempt=current_attempt, max_attempts=max_attempts, source_role=source_role
    )
    freeze_retry_checkpoint(runtime_dir, checkpoint)
    inspection = claim_retry_checkpoint(runtime_dir)
    assert inspection.claim is not None
    return mark_resume_started(runtime_dir, inspection.claim)


def _executed_next_checkpoint(
    claim: ResumeClaim,
    *,
    max_attempts: int | None = None,
    source_role: AgentRole = AgentRole.IMPLEMENTER,
    subphase_id: str = _SUBPHASE_ID,
) -> RetryCheckpoint:
    executed = claim.checkpoint.next_attempt_state
    assert executed is not None
    budget = max_attempts if max_attempts is not None else claim.checkpoint.budget.max_attempts.root
    checkpoint, *_ = _valid_escalation_checkpoint(
        current_attempt=executed.current_attempt.root,
        max_attempts=budget,
        source_role=source_role,
        subphase_id=subphase_id,
    )
    return checkpoint


def _terminal_settlement(claim: ResumeClaim, outcome: ResumeSettlementOutcome) -> ResumeSettlement:
    return ResumeSettlement(schema_version=1, claim=claim, outcome=outcome, next_checkpoint=None)


def _next_retry_settlement(
    claim: ResumeClaim, next_checkpoint: RetryCheckpoint
) -> ResumeSettlement:
    return ResumeSettlement(
        schema_version=1,
        claim=claim,
        outcome=ResumeSettlementOutcome.NEXT_RETRY,
        next_checkpoint=next_checkpoint,
    )


def _symlink_or_skip(link: Path, target: Path) -> None:
    try:
        link.symlink_to(target)
    except OSError as exc:
        pytest.skip(f"symlink creation unsupported on this platform: {exc}")


_TERMINAL_OUTCOMES = (
    ResumeSettlementOutcome.COMPLETED,
    ResumeSettlementOutcome.HALTED,
    ResumeSettlementOutcome.EXECUTION_FAILED,
)


# ---------------------------------------------------------------------------
# Public surface (Section 51)
# ---------------------------------------------------------------------------


def test_public_api_exports_expected_names() -> None:
    assert {
        "ResumeSettlementOutcome",
        "ResumeSettlement",
        "ResumeSettlementStoreError",
        "resume_settlement_path",
        "freeze_resume_settlement",
        "load_resume_settlement",
        "finalize_resume_settlement",
    }.issubset(set(resume_settlement_module.__all__))


def test_public_names_are_importable_from_the_module() -> None:
    assert ResumeSettlementOutcome is not None
    assert ResumeSettlement is not None
    assert ResumeSettlementStoreError is not None
    assert callable(resume_settlement_path)
    assert callable(freeze_resume_settlement)
    assert callable(load_resume_settlement)
    assert callable(finalize_resume_settlement)


def test_public_api_has_no_root_package_export() -> None:
    import lockstep

    assert not hasattr(lockstep, "ResumeSettlement")
    assert not hasattr(lockstep, "ResumeSettlementOutcome")


# ---------------------------------------------------------------------------
# Exact outcome enum (Section 52)
# ---------------------------------------------------------------------------


def test_resume_settlement_outcome_values_are_exact() -> None:
    assert {member.name: member.value for member in ResumeSettlementOutcome} == {
        "COMPLETED": "completed",
        "HALTED": "halted",
        "NEXT_RETRY": "next_retry",
        "EXECUTION_FAILED": "execution_failed",
    }
    forbidden_names = {"UNKNOWN", "OTHER", "RETRYING", "STARTED"}
    assert forbidden_names.isdisjoint(set(ResumeSettlementOutcome.__members__))


def test_resume_settlement_outcome_rejects_unknown_value() -> None:
    with pytest.raises(ValueError):
        ResumeSettlementOutcome("not_a_real_outcome")


# ---------------------------------------------------------------------------
# Settlement shape (Section 53)
# ---------------------------------------------------------------------------


def test_resume_settlement_has_exactly_expected_fields() -> None:
    assert set(ResumeSettlement.model_fields) == {
        "schema_version",
        "claim",
        "outcome",
        "next_checkpoint",
    }


def test_resume_settlement_is_frozen(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    settlement = _terminal_settlement(started, ResumeSettlementOutcome.COMPLETED)
    with pytest.raises(ValidationError):
        settlement.outcome = ResumeSettlementOutcome.HALTED  # type: ignore[misc]


def test_resume_settlement_rejects_unknown_fields(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    with pytest.raises(ValidationError):
        ResumeSettlement(
            schema_version=1,
            claim=started,
            outcome=ResumeSettlementOutcome.COMPLETED,
            next_checkpoint=None,
            provider="claude",
        )  # type: ignore[call-arg]


# ---------------------------------------------------------------------------
# STARTED required (Section 54)
# ---------------------------------------------------------------------------


def test_settlement_requires_started_claim_for_every_outcome(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)
    inspection = claim_retry_checkpoint(runtime_dir)
    assert inspection.claim is not None
    claimed = inspection.claim
    assert claimed.status == ResumeClaimStatus.CLAIMED

    for outcome in _TERMINAL_OUTCOMES:
        with pytest.raises(ValidationError):
            ResumeSettlement(schema_version=1, claim=claimed, outcome=outcome, next_checkpoint=None)

    next_checkpoint = _executed_next_checkpoint(claimed)
    with pytest.raises(ValidationError):
        ResumeSettlement(
            schema_version=1,
            claim=claimed,
            outcome=ResumeSettlementOutcome.NEXT_RETRY,
            next_checkpoint=next_checkpoint,
        )


# ---------------------------------------------------------------------------
# Outcome / next-checkpoint relationship matrix (Section 55)
# ---------------------------------------------------------------------------


def test_outcome_next_checkpoint_relationship_matrix(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    next_checkpoint = _executed_next_checkpoint(started)

    for outcome in _TERMINAL_OUTCOMES:
        ResumeSettlement(schema_version=1, claim=started, outcome=outcome, next_checkpoint=None)
    ResumeSettlement(
        schema_version=1,
        claim=started,
        outcome=ResumeSettlementOutcome.NEXT_RETRY,
        next_checkpoint=next_checkpoint,
    )

    for outcome in _TERMINAL_OUTCOMES:
        with pytest.raises(ValidationError):
            ResumeSettlement(
                schema_version=1, claim=started, outcome=outcome, next_checkpoint=next_checkpoint
            )

    with pytest.raises(ValidationError):
        ResumeSettlement(
            schema_version=1,
            claim=started,
            outcome=ResumeSettlementOutcome.NEXT_RETRY,
            next_checkpoint=None,
        )


# ---------------------------------------------------------------------------
# Attempt identity chain (Section 56)
# ---------------------------------------------------------------------------


def test_next_checkpoint_must_begin_at_the_exact_executed_attempt(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir, current_attempt=1, max_attempts=3)

    valid_next = _executed_next_checkpoint(started)
    ResumeSettlement(
        schema_version=1,
        claim=started,
        outcome=ResumeSettlementOutcome.NEXT_RETRY,
        next_checkpoint=valid_next,
    )

    stale_next, *_ = _valid_escalation_checkpoint(current_attempt=1, max_attempts=3)
    with pytest.raises(ValidationError):
        ResumeSettlement(
            schema_version=1,
            claim=started,
            outcome=ResumeSettlementOutcome.NEXT_RETRY,
            next_checkpoint=stale_next,
        )

    skipped_next, *_ = _valid_escalation_checkpoint(current_attempt=3, max_attempts=3)
    with pytest.raises(ValidationError):
        ResumeSettlement(
            schema_version=1,
            claim=started,
            outcome=ResumeSettlementOutcome.NEXT_RETRY,
            next_checkpoint=skipped_next,
        )


# ---------------------------------------------------------------------------
# Phase / subphase chain (Section 57)
# ---------------------------------------------------------------------------


def test_next_checkpoint_phase_subphase_mismatch_rejected(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir, current_attempt=1, max_attempts=3)

    mismatched = _executed_next_checkpoint(started, subphase_id="13")
    with pytest.raises(ValidationError):
        ResumeSettlement(
            schema_version=1,
            claim=started,
            outcome=ResumeSettlementOutcome.NEXT_RETRY,
            next_checkpoint=mismatched,
        )


# ---------------------------------------------------------------------------
# Retry budget continuity (Section 58)
# ---------------------------------------------------------------------------


def test_next_checkpoint_budget_must_match_exactly(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir, current_attempt=1, max_attempts=3)

    mismatched_budget = _executed_next_checkpoint(started, max_attempts=4)
    with pytest.raises(ValidationError):
        ResumeSettlement(
            schema_version=1,
            claim=started,
            outcome=ResumeSettlementOutcome.NEXT_RETRY,
            next_checkpoint=mismatched_budget,
        )


# ---------------------------------------------------------------------------
# Target role may change (Section 59)
# ---------------------------------------------------------------------------


def test_next_checkpoint_may_target_a_different_role(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(
        runtime_dir, current_attempt=1, max_attempts=3, source_role=AgentRole.IMPLEMENTER
    )
    next_checkpoint = _executed_next_checkpoint(started, source_role=AgentRole.REVIEWER)
    assert next_checkpoint.retry_request.target_role == AgentRole.REVIEWER

    settlement = ResumeSettlement(
        schema_version=1,
        claim=started,
        outcome=ResumeSettlementOutcome.NEXT_RETRY,
        next_checkpoint=next_checkpoint,
    )
    assert settlement.next_checkpoint == next_checkpoint


# ---------------------------------------------------------------------------
# Settlement path (Section 60)
# ---------------------------------------------------------------------------


def test_resume_settlement_path_is_exact(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    expected = runtime_dir / "retry" / "settlements" / f"{started.checkpoint_digest}.json"
    assert resume_settlement_path(runtime_dir, started) == expected


# ---------------------------------------------------------------------------
# Canonical bytes (Section 61)
# ---------------------------------------------------------------------------


def test_equivalent_settlements_produce_identical_canonical_bytes(tmp_path: Path) -> None:
    runtime_a = tmp_path / "runtime-a"
    runtime_a.mkdir()
    runtime_b = tmp_path / "runtime-b"
    runtime_b.mkdir()

    started_a = _started_claim(runtime_a)
    started_b = _started_claim(runtime_b)
    assert started_a == started_b

    settlement_a = _terminal_settlement(started_a, ResumeSettlementOutcome.COMPLETED)
    settlement_b = _terminal_settlement(started_b, ResumeSettlementOutcome.COMPLETED)

    freeze_resume_settlement(runtime_a, settlement_a)
    freeze_resume_settlement(runtime_b, settlement_b)

    path_a = resume_settlement_path(runtime_a, started_a)
    path_b = resume_settlement_path(runtime_b, started_b)
    assert path_a.read_bytes() == path_b.read_bytes()


# ---------------------------------------------------------------------------
# Freeze absent / roundtrip (Section 62)
# ---------------------------------------------------------------------------


def test_freeze_persists_absent_settlement_and_loads_it_back(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    settlement = _terminal_settlement(started, ResumeSettlementOutcome.HALTED)

    frozen = freeze_resume_settlement(runtime_dir, settlement)
    assert frozen == settlement

    path = resume_settlement_path(runtime_dir, started)
    assert path.exists()
    loaded = load_resume_settlement(runtime_dir, started)
    assert loaded == settlement


# ---------------------------------------------------------------------------
# Idempotent freeze (Section 63)
# ---------------------------------------------------------------------------


def test_freeze_is_idempotent_for_an_identical_settlement(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    settlement = _terminal_settlement(started, ResumeSettlementOutcome.COMPLETED)
    freeze_resume_settlement(runtime_dir, settlement)
    path = resume_settlement_path(runtime_dir, started)
    before = path.read_bytes()

    freeze_resume_settlement(runtime_dir, settlement.model_copy())

    assert path.read_bytes() == before


# ---------------------------------------------------------------------------
# Conflicting freeze (Section 64)
# ---------------------------------------------------------------------------


def test_freeze_rejects_a_conflicting_settlement_at_the_same_digest(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    settlement_a = _terminal_settlement(started, ResumeSettlementOutcome.COMPLETED)
    settlement_b = _terminal_settlement(started, ResumeSettlementOutcome.HALTED)

    freeze_resume_settlement(runtime_dir, settlement_a)
    path = resume_settlement_path(runtime_dir, started)
    before = path.read_bytes()

    with pytest.raises(ResumeSettlementStoreError):
        freeze_resume_settlement(runtime_dir, settlement_b)

    assert path.read_bytes() == before


# ---------------------------------------------------------------------------
# Corrupt settlement (Section 65)
# ---------------------------------------------------------------------------


def test_corrupt_settlement_file_fails_closed(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    path = resume_settlement_path(runtime_dir, started)
    path.parent.mkdir(parents=True)
    path.write_text("{not valid json", encoding="utf-8")

    with pytest.raises(ResumeSettlementStoreError):
        load_resume_settlement(runtime_dir, started)

    settlement = _terminal_settlement(started, ResumeSettlementOutcome.COMPLETED)
    with pytest.raises(ResumeSettlementStoreError):
        freeze_resume_settlement(runtime_dir, settlement)

    assert path.read_text(encoding="utf-8") == "{not valid json"


# ---------------------------------------------------------------------------
# Settlement-directory symlink (Section 66)
# ---------------------------------------------------------------------------


def test_settlement_directory_symlink_is_rejected(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    real_dir = tmp_path / "real-settlements-dir"
    real_dir.mkdir()
    _symlink_or_skip(runtime_dir / "retry" / "settlements", real_dir)

    settlement = _terminal_settlement(started, ResumeSettlementOutcome.COMPLETED)

    with pytest.raises(ResumeSettlementStoreError):
        freeze_resume_settlement(runtime_dir, settlement)
    with pytest.raises(ResumeSettlementStoreError):
        load_resume_settlement(runtime_dir, started)
    with pytest.raises(ResumeSettlementStoreError):
        finalize_resume_settlement(runtime_dir, settlement)

    assert list(real_dir.iterdir()) == []


# ---------------------------------------------------------------------------
# Settlement-file symlink (Section 67)
# ---------------------------------------------------------------------------


def test_settlement_file_symlink_is_rejected(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    settlements_dir = runtime_dir / "retry" / "settlements"
    settlements_dir.mkdir(parents=True)
    external_target = tmp_path / "external-settlement.json"
    external_target.write_text("external", encoding="utf-8")
    _symlink_or_skip(settlements_dir / f"{started.checkpoint_digest}.json", external_target)

    settlement = _terminal_settlement(started, ResumeSettlementOutcome.COMPLETED)

    with pytest.raises(ResumeSettlementStoreError):
        freeze_resume_settlement(runtime_dir, settlement)
    with pytest.raises(ResumeSettlementStoreError):
        load_resume_settlement(runtime_dir, started)
    with pytest.raises(ResumeSettlementStoreError):
        finalize_resume_settlement(runtime_dir, settlement)

    assert external_target.read_text(encoding="utf-8") == "external"


# ---------------------------------------------------------------------------
# Terminal finalization (Sections 68-70)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("outcome", _TERMINAL_OUTCOMES)
def test_terminal_finalization_removes_claim_and_is_idempotent(
    tmp_path: Path, outcome: ResumeSettlementOutcome
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    settlement = _terminal_settlement(started, outcome)

    result = finalize_resume_settlement(runtime_dir, settlement)
    assert result == settlement

    claim_path = resume_claim_path(runtime_dir)
    assert not claim_path.exists()
    assert not retry_checkpoint_path(runtime_dir).exists()
    assert load_resume_settlement(runtime_dir, started) == settlement

    repeat = finalize_resume_settlement(runtime_dir, settlement)
    assert repeat == settlement
    assert not claim_path.exists()


# ---------------------------------------------------------------------------
# NEXT_RETRY available (Section 71)
# ---------------------------------------------------------------------------


def test_next_retry_finalization_installs_available_checkpoint(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir, current_attempt=1, max_attempts=3)
    next_checkpoint = _executed_next_checkpoint(started)
    assert next_checkpoint.budget_disposition == RetryBudgetDisposition.RETRY_AVAILABLE
    settlement = _next_retry_settlement(started, next_checkpoint)

    result = finalize_resume_settlement(runtime_dir, settlement)
    assert result == settlement

    assert not resume_claim_path(runtime_dir).exists()
    assert load_retry_checkpoint(runtime_dir) == next_checkpoint

    inspection = inspect_resume(runtime_dir)
    assert inspection.disposition == ResumeDisposition.RETRY_AVAILABLE
    assert inspection.checkpoint == next_checkpoint


# ---------------------------------------------------------------------------
# NEXT_RETRY exhausted (Section 72)
# ---------------------------------------------------------------------------


def test_next_retry_finalization_preserves_exhaustion(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir, current_attempt=2, max_attempts=3)
    next_checkpoint = _executed_next_checkpoint(started)
    assert next_checkpoint.budget_disposition == RetryBudgetDisposition.RETRY_EXHAUSTED
    settlement = _next_retry_settlement(started, next_checkpoint)

    finalize_resume_settlement(runtime_dir, settlement)

    inspection = inspect_resume(runtime_dir)
    assert inspection.disposition == ResumeDisposition.RETRY_EXHAUSTED
    assert inspection.checkpoint == next_checkpoint


# ---------------------------------------------------------------------------
# Interrupted terminal finalization (Section 73)
# ---------------------------------------------------------------------------


def test_interrupted_terminal_finalization_completes_claim_removal(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    settlement = _terminal_settlement(started, ResumeSettlementOutcome.COMPLETED)
    freeze_resume_settlement(runtime_dir, settlement)
    assert resume_claim_path(runtime_dir).exists()

    result = finalize_resume_settlement(runtime_dir, settlement)
    assert result == settlement
    assert not resume_claim_path(runtime_dir).exists()


# ---------------------------------------------------------------------------
# Interrupted NEXT_RETRY, settlement-only (Section 74)
# ---------------------------------------------------------------------------


def test_interrupted_next_retry_finalization_freezes_checkpoint_then_removes_claim(
    tmp_path: Path,
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    next_checkpoint = _executed_next_checkpoint(started)
    settlement = _next_retry_settlement(started, next_checkpoint)
    freeze_resume_settlement(runtime_dir, settlement)
    assert load_retry_checkpoint(runtime_dir) is None
    assert resume_claim_path(runtime_dir).exists()

    finalize_resume_settlement(runtime_dir, settlement)

    assert load_retry_checkpoint(runtime_dir) == next_checkpoint
    assert not resume_claim_path(runtime_dir).exists()


# ---------------------------------------------------------------------------
# Interrupted NEXT_RETRY, checkpointed state (Section 75)
# ---------------------------------------------------------------------------


def test_interrupted_next_retry_finalization_with_checkpoint_already_present(
    tmp_path: Path,
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    next_checkpoint = _executed_next_checkpoint(started)
    settlement = _next_retry_settlement(started, next_checkpoint)
    freeze_resume_settlement(runtime_dir, settlement)
    freeze_retry_checkpoint(runtime_dir, next_checkpoint)
    assert resume_claim_path(runtime_dir).exists()

    finalize_resume_settlement(runtime_dir, settlement)

    assert not resume_claim_path(runtime_dir).exists()
    assert load_retry_checkpoint(runtime_dir) == next_checkpoint


# ---------------------------------------------------------------------------
# Conflicting active checkpoint (Section 76)
# ---------------------------------------------------------------------------


def test_conflicting_active_checkpoint_fails_closed(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir, current_attempt=1, max_attempts=3)
    next_checkpoint_a = _executed_next_checkpoint(started, source_role=AgentRole.IMPLEMENTER)
    settlement = _next_retry_settlement(started, next_checkpoint_a)

    checkpoint_b, *_ = _valid_escalation_checkpoint(
        current_attempt=2, max_attempts=3, source_role=AgentRole.REVIEWER
    )
    assert checkpoint_b != next_checkpoint_a
    freeze_retry_checkpoint(runtime_dir, checkpoint_b)

    claim_path = resume_claim_path(runtime_dir)
    claim_bytes_before = claim_path.read_bytes()
    checkpoint_path = retry_checkpoint_path(runtime_dir)
    checkpoint_bytes_before = checkpoint_path.read_bytes()

    with pytest.raises(RetryCheckpointStoreError):
        finalize_resume_settlement(runtime_dir, settlement)

    assert claim_path.read_bytes() == claim_bytes_before
    assert checkpoint_path.read_bytes() == checkpoint_bytes_before
    assert resume_settlement_path(runtime_dir, started).exists()


# ---------------------------------------------------------------------------
# Terminal settlement with unexpected checkpoint (Section 77)
# ---------------------------------------------------------------------------


def test_terminal_settlement_rejects_unexpected_checkpoint(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    stray_checkpoint, *_ = _valid_escalation_checkpoint(
        current_attempt=1, max_attempts=3, source_role=AgentRole.REVIEWER
    )
    freeze_retry_checkpoint(runtime_dir, stray_checkpoint)
    settlement = _terminal_settlement(started, ResumeSettlementOutcome.COMPLETED)

    claim_path = resume_claim_path(runtime_dir)
    before = claim_path.read_bytes()

    with pytest.raises(ResumeSettlementStoreError):
        finalize_resume_settlement(runtime_dir, settlement)

    assert claim_path.read_bytes() == before


# ---------------------------------------------------------------------------
# Claim mismatch (Section 78)
# ---------------------------------------------------------------------------


def test_finalize_rejects_a_stored_claim_that_does_not_match(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint_a, *_ = _valid_escalation_checkpoint(current_attempt=1, max_attempts=3)
    checkpoint_b, *_ = _valid_escalation_checkpoint(current_attempt=1, max_attempts=5)
    started_a = _started_claim_object(checkpoint_a)
    started_b = _started_claim_object(checkpoint_b)
    _write_claim_file(runtime_dir, started_b)

    settlement = _terminal_settlement(started_a, ResumeSettlementOutcome.COMPLETED)
    claim_path = resume_claim_path(runtime_dir)
    before = claim_path.read_bytes()

    with pytest.raises(ResumeSettlementStoreError):
        finalize_resume_settlement(runtime_dir, settlement)

    assert claim_path.read_bytes() == before
    assert not resume_settlement_path(runtime_dir, started_a).exists()


def test_finalize_rejects_when_stored_claim_is_still_claimed(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    claimed = _claimed_claim(checkpoint)
    _write_claim_file(runtime_dir, claimed)
    started = claimed.model_copy(update={"status": ResumeClaimStatus.STARTED})
    settlement = _terminal_settlement(started, ResumeSettlementOutcome.COMPLETED)

    claim_path = resume_claim_path(runtime_dir)
    before = claim_path.read_bytes()

    with pytest.raises(ResumeSettlementStoreError):
        finalize_resume_settlement(runtime_dir, settlement)

    assert claim_path.read_bytes() == before


# ---------------------------------------------------------------------------
# Missing claim without settlement (Section 79)
# ---------------------------------------------------------------------------


def test_finalize_rejects_missing_claim_without_settlement_evidence(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    settlement = _terminal_settlement(started, ResumeSettlementOutcome.COMPLETED)
    resume_claim_path(runtime_dir).unlink()

    with pytest.raises(ResumeSettlementStoreError):
        finalize_resume_settlement(runtime_dir, settlement)


# ---------------------------------------------------------------------------
# Finalized idempotence, NEXT_RETRY (Section 81)
# ---------------------------------------------------------------------------


def test_finalized_next_retry_operation_is_idempotent(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    next_checkpoint = _executed_next_checkpoint(started)
    settlement = _next_retry_settlement(started, next_checkpoint)
    finalize_resume_settlement(runtime_dir, settlement)
    assert not resume_claim_path(runtime_dir).exists()

    result = finalize_resume_settlement(runtime_dir, settlement)
    assert result == settlement


# ---------------------------------------------------------------------------
# Missing next checkpoint after claim already removed (Section 82)
# ---------------------------------------------------------------------------


def test_missing_next_checkpoint_after_claim_already_removed_fails_closed(
    tmp_path: Path,
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    next_checkpoint = _executed_next_checkpoint(started)
    settlement = _next_retry_settlement(started, next_checkpoint)
    finalize_resume_settlement(runtime_dir, settlement)
    retry_checkpoint_path(runtime_dir).unlink()

    with pytest.raises(ResumeSettlementStoreError):
        finalize_resume_settlement(runtime_dir, settlement)


# ---------------------------------------------------------------------------
# Stale start lock (Section 83)
# ---------------------------------------------------------------------------


def test_stale_start_lock_fails_closed_during_finalization(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    lock_path = runtime_dir / "retry" / "start.lock"
    lock_path.write_text("held", encoding="utf-8")
    settlement = _terminal_settlement(started, ResumeSettlementOutcome.COMPLETED)

    with pytest.raises(ResumeSettlementStoreError):
        finalize_resume_settlement(runtime_dir, settlement)

    assert lock_path.read_text(encoding="utf-8") == "held"
    assert resume_claim_path(runtime_dir).exists()


# ---------------------------------------------------------------------------
# Settlement write failure (Section 84)
# ---------------------------------------------------------------------------


def test_settlement_publication_failure_preserves_claim(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    settlement = _terminal_settlement(started, ResumeSettlementOutcome.COMPLETED)

    def fail_write(path: Path, payload: bytes) -> None:
        raise OSError("simulated settlement write failure")

    monkeypatch.setattr(resume_settlement_module, "_write_new_settlement_exclusive", fail_write)

    with pytest.raises(ResumeSettlementStoreError):
        finalize_resume_settlement(runtime_dir, settlement)

    assert resume_claim_path(runtime_dir).exists()
    assert not resume_settlement_path(runtime_dir, started).exists()
    assert load_retry_checkpoint(runtime_dir) is None


# ---------------------------------------------------------------------------
# Next-checkpoint freeze failure (Section 85)
# ---------------------------------------------------------------------------


def test_next_checkpoint_freeze_failure_preserves_settlement_and_claim(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    next_checkpoint = _executed_next_checkpoint(started)
    settlement = _next_retry_settlement(started, next_checkpoint)

    def fail_replace(source: Path, target: Path) -> None:
        raise OSError("simulated replace failure")

    monkeypatch.setattr(retry_checkpoint_module, "_replace_atomically", fail_replace)

    with pytest.raises(RetryCheckpointStoreError):
        finalize_resume_settlement(runtime_dir, settlement)

    assert resume_claim_path(runtime_dir).exists()
    assert load_resume_settlement(runtime_dir, started) == settlement
    assert load_retry_checkpoint(runtime_dir) is None

    monkeypatch.undo()

    result = finalize_resume_settlement(runtime_dir, settlement)
    assert result == settlement
    assert not resume_claim_path(runtime_dir).exists()
    assert load_retry_checkpoint(runtime_dir) == next_checkpoint


# ---------------------------------------------------------------------------
# Claim-removal failure (Section 86)
# ---------------------------------------------------------------------------


def test_claim_removal_failure_is_recoverable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started = _started_claim(runtime_dir)
    settlement = _terminal_settlement(started, ResumeSettlementOutcome.COMPLETED)

    def fail_remove(path: Path) -> None:
        raise OSError("simulated claim removal failure")

    monkeypatch.setattr(resume_settlement_module, "_remove_started_claim", fail_remove)

    with pytest.raises(ResumeSettlementStoreError):
        finalize_resume_settlement(runtime_dir, settlement)

    assert resume_claim_path(runtime_dir).exists()
    assert load_resume_settlement(runtime_dir, started) == settlement

    monkeypatch.undo()

    result = finalize_resume_settlement(runtime_dir, settlement)
    assert result == settlement
    assert not resume_claim_path(runtime_dir).exists()


# ---------------------------------------------------------------------------
# Semantic authority preserved / provider telemetry excluded (Sections 87-88)
# ---------------------------------------------------------------------------


def test_semantic_authority_is_preserved_and_provider_telemetry_is_excluded(
    tmp_path: Path,
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    old_invocation = _agent_invocation_result(
        stdout="SENTINEL-STDOUT-OLD", adapter_name="SENTINEL-ADAPTER-OLD"
    )
    old_checkpoint, *_ = _valid_escalation_checkpoint(
        current_attempt=1,
        max_attempts=3,
        question="SENTINEL-QUESTION-OLD",
        evidence=("SENTINEL-EVIDENCE-OLD",),
        invocation=old_invocation,
    )
    freeze_retry_checkpoint(runtime_dir, old_checkpoint)
    inspection = claim_retry_checkpoint(runtime_dir)
    assert inspection.claim is not None
    started = mark_resume_started(runtime_dir, inspection.claim)

    new_invocation = _agent_invocation_result(
        stdout="SENTINEL-STDOUT-NEW", adapter_name="SENTINEL-ADAPTER-NEW"
    )
    next_checkpoint, *_ = _valid_escalation_checkpoint(
        current_attempt=2,
        max_attempts=3,
        question="SENTINEL-QUESTION-NEW",
        evidence=("SENTINEL-EVIDENCE-NEW",),
        invocation=new_invocation,
    )

    settlement = _next_retry_settlement(started, next_checkpoint)
    freeze_resume_settlement(runtime_dir, settlement)

    serialized = resume_settlement_path(runtime_dir, started).read_text(encoding="utf-8")

    assert "SENTINEL-QUESTION-OLD" in serialized
    assert "SENTINEL-EVIDENCE-OLD" in serialized
    assert "SENTINEL-QUESTION-NEW" in serialized
    assert "SENTINEL-EVIDENCE-NEW" in serialized

    assert "SENTINEL-STDOUT-OLD" not in serialized
    assert "SENTINEL-ADAPTER-OLD" not in serialized
    assert "SENTINEL-STDOUT-NEW" not in serialized
    assert "SENTINEL-ADAPTER-NEW" not in serialized
    assert "stdout" not in serialized
    assert "provider" not in serialized


# ---------------------------------------------------------------------------
# Immutable settlement history (Section 89)
# ---------------------------------------------------------------------------


def test_two_settlements_for_different_digests_coexist(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    started_1 = _started_claim(runtime_dir, current_attempt=1, max_attempts=3)
    settlement_1 = _terminal_settlement(started_1, ResumeSettlementOutcome.COMPLETED)
    finalize_resume_settlement(runtime_dir, settlement_1)

    started_2 = _started_claim(
        runtime_dir, current_attempt=1, max_attempts=5, source_role=AgentRole.REVIEWER
    )
    settlement_2 = _terminal_settlement(started_2, ResumeSettlementOutcome.HALTED)
    finalize_resume_settlement(runtime_dir, settlement_2)

    assert started_1.checkpoint_digest != started_2.checkpoint_digest
    assert resume_settlement_path(runtime_dir, started_1).exists()
    assert resume_settlement_path(runtime_dir, started_2).exists()
    assert load_resume_settlement(runtime_dir, started_1) == settlement_1
    assert load_resume_settlement(runtime_dir, started_2) == settlement_2


# ---------------------------------------------------------------------------
# No execution dependencies (Section 90)
# ---------------------------------------------------------------------------

_ALLOWED_LOCKSTEP_IMPORTS = frozenset(
    {"lockstep.resume", "lockstep.retry", "lockstep.retry_checkpoint"}
)

_FORBIDDEN_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.runtime",
    "lockstep.agent_turn",
    "lockstep.reviewer_turn",
    "lockstep.supervisor.transaction",
    "lockstep.supervisor.escalation",
    "lockstep.planning_store",
    "lockstep.planning_workflow",
    "lockstep.planning_transport",
    "lockstep.planning",
    "lockstep.git",
    "lockstep.process",
    "lockstep.persistence",
    "lockstep.verification",
    "lockstep.reporting",
    "lockstep.cli",
    "lockstep.agents",
    "lockstep.context",
    "lockstep.state",
    "subprocess",
)


def _imported_modules(tree: ast.Module) -> set[str]:
    imported_modules: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imported_modules.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            imported_modules.add(node.module or "")
    return imported_modules


def test_resume_settlement_module_only_imports_from_the_allowed_pure_surface() -> None:
    tree = ast.parse(inspect.getsource(resume_settlement_module))
    imported_modules = _imported_modules(tree)

    lockstep_imports = {
        module
        for module in imported_modules
        if module == "lockstep" or module.startswith("lockstep.")
    }
    assert lockstep_imports <= _ALLOWED_LOCKSTEP_IMPORTS


def test_resume_settlement_module_has_no_forbidden_imports() -> None:
    tree = ast.parse(inspect.getsource(resume_settlement_module))
    imported_modules = _imported_modules(tree)

    for forbidden_prefix in _FORBIDDEN_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


# ---------------------------------------------------------------------------
# No execution calls (Section 91)
# ---------------------------------------------------------------------------


def test_resume_settlement_module_has_no_execution_primitives() -> None:
    source = inspect.getsource(resume_settlement_module)
    tree = ast.parse(source)

    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            assert node.func.id not in {
                "invoke_agent",
                "invoke_agent_turn",
                "invoke_reviewer_turn",
                "invoke_planner_decision",
                "dispatch_escalation",
                "run_single_subphase_transaction",
                "run_single_subphase_transaction_with_blockers",
                "run_single_subphase_transaction_with_retry_checkpoint",
                "sleep",
                "input",
                "print",
            }

    for forbidden in (
        "invoke_agent",
        "invoke_agent_turn",
        "invoke_reviewer_turn",
        "invoke_planner_decision",
        "dispatch_escalation",
        "run_single_subphase",
        "subprocess",
        "time.sleep",
    ):
        assert forbidden not in source


# ---------------------------------------------------------------------------
# Import-cycle smoke (Section 92)
# ---------------------------------------------------------------------------


def test_import_cycle_smoke_across_orders() -> None:
    statements = (
        "import lockstep.resume_settlement; import lockstep.resume; "
        "import lockstep.retry_checkpoint; import lockstep.retry; "
        "import lockstep.runtime; import lockstep.supervisor.transaction",
        "import lockstep.retry; import lockstep.retry_checkpoint; import lockstep.resume; "
        "import lockstep.resume_settlement; import lockstep.runtime; "
        "import lockstep.supervisor.transaction",
        "import lockstep.supervisor.transaction; import lockstep.runtime; "
        "import lockstep.resume_settlement; import lockstep.resume; "
        "import lockstep.retry; import lockstep.retry_checkpoint",
        "import lockstep.runtime; import lockstep.supervisor.transaction; "
        "import lockstep.retry_checkpoint; import lockstep.retry; import lockstep.resume; "
        "import lockstep.resume_settlement",
        "import lockstep.resume_settlement; import lockstep.supervisor.transaction; "
        "import lockstep.runtime; import lockstep.retry; import lockstep.resume",
    )
    for statement in statements:
        result = subprocess.run([sys.executable, "-c", statement], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
