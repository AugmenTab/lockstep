"""Planner-authored specification of Sub-phase 9.11 durable resume claims.

Specifies ``lockstep.resume`` before it exists: the durable claim/start
boundary that gives Lockstep's autonomous safety contract --
at-most-once launch for a given retry attempt, with conservative
recovery -- built strictly on top of the frozen Sub-phase 9.8
attempt-state/retry-budget protocol (``lockstep.retry``) and the frozen
Sub-phase 9.9 durable retry checkpoint store (``lockstep.retry_checkpoint``).

A ``ResumeClaim`` durably transfers retry authority out of the
"available to claim" ``retry/checkpoint.json`` into an exclusively
claimed ``retry/claim.json``, first as ``CLAIMED`` (the durable launch
boundary has not been crossed) and then, only through
``mark_resume_started``, as ``STARTED`` (the durable launch boundary
has been crossed for attempt N+1 and automatic replay is forbidden).
This module never launches an agent, never mutates the Supervisor
transaction, FSM, or event journal, and never implements claim
completion/settlement -- that is Sub-phase 9.12's job, once actual
re-entry execution semantics exist.
"""

import ast
import inspect
import json
import re
import subprocess
import sys
import threading
from dataclasses import FrozenInstanceError, fields
from pathlib import Path

import pytest
from pydantic import ValidationError

import lockstep.resume as resume_module
from lockstep.agents import AgentInvocationResult
from lockstep.domain import (
    AgentRole,
    BillingMode,
    PhaseId,
    ReviewDecision,
    ReviewFinding,
    ReviewVerdict,
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
    ResumeInspection,
    ResumeStoreError,
    claim_retry_checkpoint,
    inspect_resume,
    mark_resume_started,
    resume_claim_path,
    retry_checkpoint_digest,
)
from lockstep.retry import AttemptState, RetryBudget, RetryBudgetDisposition
from lockstep.retry_checkpoint import (
    RetryCheckpoint,
    create_retry_checkpoint_from_escalation,
    create_retry_checkpoint_from_review,
    freeze_retry_checkpoint,
    retry_checkpoint_path,
)
from lockstep.supervisor.escalation import (
    SupervisorEscalationDisposition,
    SupervisorEscalationResult,
)

_PHASE_ID = "09"
_SUBPHASE_ID = "11"

_DIGEST_PATTERN = re.compile(r"^[0-9a-f]{64}$")


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
    rationale: str = "Bounded correction authorized.",
    instructions: tuple[str, ...] = ("Apply the bounded fix.",),
    authorized_paths: tuple[str, ...] = (),
    question: str = "Is the previously reported blocker now resolved?",
    evidence: tuple[str, ...] = ("The Planner authorized a bounded change.",),
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
    decision = _planner_decision(
        request, rationale=rationale, instructions=instructions, authorized_paths=authorized_paths
    )
    planner_turn = _planner_turn_result(request, decision, invocation=invocation)
    result = _escalation_result(
        request=request,
        disposition=SupervisorEscalationDisposition.RESUME_AGENT,
        planner_turn=planner_turn,
    )
    return request, decision, result


def _review_decision(
    *,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    attempt: int = 1,
    verdict: ReviewVerdict = ReviewVerdict.REWORK,
    summary: str = "Rework requested.",
    findings: tuple[ReviewFinding, ...] = (),
) -> ReviewDecision:
    return ReviewDecision(
        schema_version=1,
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        attempt=attempt,
        verdict=verdict,
        summary=summary,
        findings=findings,
    )


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
) -> tuple[RetryCheckpoint, EscalationRequest, PlannerDecision]:
    request, decision, result = _resume_escalation_result(
        source_role=source_role, attempt=current_attempt
    )
    attempt_state = _attempt_state(current_attempt=current_attempt)
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


def _canonical_claim_bytes(claim: ResumeClaim) -> bytes:
    text = json.dumps(
        claim.model_dump(mode="json"),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return (text + "\n").encode("utf-8")


def _write_claim_file(runtime_dir: Path, claim: ResumeClaim) -> Path:
    path = resume_claim_path(runtime_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(_canonical_claim_bytes(claim))
    return path


def _claimed_claim(checkpoint: RetryCheckpoint) -> ResumeClaim:
    return ResumeClaim(
        schema_version=1,
        checkpoint_digest=retry_checkpoint_digest(checkpoint),
        checkpoint=checkpoint,
        status=ResumeClaimStatus.CLAIMED,
    )


def _load_claim(path: Path) -> ResumeClaim:
    return ResumeClaim.model_validate(json.loads(path.read_text(encoding="utf-8")))


def _symlink_or_skip(link: Path, target: Path) -> None:
    try:
        link.symlink_to(target)
    except OSError as exc:
        pytest.skip(f"symlink creation unsupported on this platform: {exc}")


# ---------------------------------------------------------------------------
# Public surface (Section 51)
# ---------------------------------------------------------------------------


def test_public_api_exports_expected_names() -> None:
    assert {
        "ResumeClaimStatus",
        "ResumeDisposition",
        "ResumeClaim",
        "ResumeInspection",
        "ResumeStoreError",
        "retry_checkpoint_digest",
        "resume_claim_path",
        "inspect_resume",
        "claim_retry_checkpoint",
        "mark_resume_started",
    }.issubset(set(resume_module.__all__))


def test_public_names_are_importable_from_the_module() -> None:
    assert ResumeClaimStatus is not None
    assert ResumeDisposition is not None
    assert ResumeClaim is not None
    assert ResumeInspection is not None
    assert ResumeStoreError is not None
    assert callable(retry_checkpoint_digest)
    assert callable(resume_claim_path)
    assert callable(inspect_resume)
    assert callable(claim_retry_checkpoint)
    assert callable(mark_resume_started)


def test_public_api_has_no_root_package_export() -> None:
    import lockstep

    assert not hasattr(lockstep, "ResumeClaim")
    assert not hasattr(lockstep, "ResumeInspection")


# ---------------------------------------------------------------------------
# Exact enums (Section 52)
# ---------------------------------------------------------------------------


def test_resume_claim_status_values_are_exact() -> None:
    assert {member.name: member.value for member in ResumeClaimStatus} == {
        "CLAIMED": "claimed",
        "STARTED": "started",
    }
    forbidden_names = {"COMPLETED", "FAILED", "CONSUMED", "RETRYING", "UNKNOWN"}
    assert forbidden_names.isdisjoint(set(ResumeClaimStatus.__members__))


def test_resume_disposition_values_are_exact() -> None:
    assert {member.name: member.value for member in ResumeDisposition} == {
        "NO_CHECKPOINT": "no_checkpoint",
        "RETRY_AVAILABLE": "retry_available",
        "RETRY_EXHAUSTED": "retry_exhausted",
        "CLAIMED": "claimed",
        "STARTED_RECOVERY_REQUIRED": "started_recovery_required",
    }
    forbidden_names = {"FAILED", "UNKNOWN", "RETRY"}
    assert forbidden_names.isdisjoint(set(ResumeDisposition.__members__))


def test_resume_claim_status_rejects_unknown_value() -> None:
    with pytest.raises(ValueError):
        ResumeClaimStatus("not_a_real_status")


def test_resume_disposition_rejects_unknown_value() -> None:
    with pytest.raises(ValueError):
        ResumeDisposition("not_a_real_disposition")


# ---------------------------------------------------------------------------
# Digest determinism (Section 53)
# ---------------------------------------------------------------------------


def test_retry_checkpoint_digest_is_deterministic_for_equivalent_checkpoints() -> None:
    checkpoint_a, *_ = _valid_escalation_checkpoint()
    checkpoint_b, *_ = _valid_escalation_checkpoint()
    assert checkpoint_a == checkpoint_b

    digest_a = retry_checkpoint_digest(checkpoint_a)
    digest_b = retry_checkpoint_digest(checkpoint_b)

    assert digest_a == digest_b
    assert _DIGEST_PATTERN.fullmatch(digest_a)


def test_retry_checkpoint_digest_changes_with_meaningful_content() -> None:
    checkpoint_a, *_ = _valid_escalation_checkpoint(current_attempt=1, max_attempts=3)
    checkpoint_b, *_ = _valid_escalation_checkpoint(current_attempt=2, max_attempts=3)

    assert retry_checkpoint_digest(checkpoint_a) != retry_checkpoint_digest(checkpoint_b)


# ---------------------------------------------------------------------------
# Claim model (Section 54)
# ---------------------------------------------------------------------------


def test_resume_claim_has_exactly_expected_fields() -> None:
    assert set(ResumeClaim.model_fields) == {
        "schema_version",
        "checkpoint_digest",
        "checkpoint",
        "status",
    }


def test_resume_claim_is_frozen() -> None:
    checkpoint, *_ = _valid_escalation_checkpoint()
    claim = _claimed_claim(checkpoint)
    with pytest.raises(ValidationError):
        claim.status = ResumeClaimStatus.STARTED  # type: ignore[misc]


def test_resume_claim_rejects_unknown_fields() -> None:
    checkpoint, *_ = _valid_escalation_checkpoint()
    with pytest.raises(ValidationError):
        ResumeClaim(
            schema_version=1,
            checkpoint_digest=retry_checkpoint_digest(checkpoint),
            checkpoint=checkpoint,
            status=ResumeClaimStatus.CLAIMED,
            provider="claude",
        )  # type: ignore[call-arg]


def test_resume_claim_rejects_forged_digest() -> None:
    checkpoint, *_ = _valid_escalation_checkpoint()
    with pytest.raises(ValidationError):
        ResumeClaim(
            schema_version=1,
            checkpoint_digest="0" * 64,
            checkpoint=checkpoint,
            status=ResumeClaimStatus.CLAIMED,
        )


def test_resume_claim_rejects_an_exhausted_checkpoint() -> None:
    checkpoint, *_ = _valid_escalation_checkpoint(current_attempt=3, max_attempts=3)
    assert checkpoint.budget_disposition == RetryBudgetDisposition.RETRY_EXHAUSTED
    with pytest.raises(ValidationError):
        ResumeClaim(
            schema_version=1,
            checkpoint_digest=retry_checkpoint_digest(checkpoint),
            checkpoint=checkpoint,
            status=ResumeClaimStatus.CLAIMED,
        )


# ---------------------------------------------------------------------------
# Inspection shape (Section 55)
# ---------------------------------------------------------------------------


def test_resume_inspection_is_frozen_slotted_with_exact_fields() -> None:
    assert {f.name for f in fields(ResumeInspection)} == {"disposition", "checkpoint", "claim"}

    inspection = ResumeInspection(
        disposition=ResumeDisposition.NO_CHECKPOINT, checkpoint=None, claim=None
    )
    assert not hasattr(inspection, "__dict__")
    with pytest.raises(FrozenInstanceError):
        inspection.disposition = ResumeDisposition.RETRY_AVAILABLE  # type: ignore[misc]


# ---------------------------------------------------------------------------
# No state (Section 56)
# ---------------------------------------------------------------------------


def test_no_checkpoint_and_no_claim_yield_no_checkpoint_disposition(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)

    inspection = inspect_resume(runtime_dir)
    assert inspection == ResumeInspection(
        disposition=ResumeDisposition.NO_CHECKPOINT, checkpoint=None, claim=None
    )
    assert not (runtime_dir / "retry").exists()

    claim_inspection = claim_retry_checkpoint(runtime_dir)
    assert claim_inspection == ResumeInspection(
        disposition=ResumeDisposition.NO_CHECKPOINT, checkpoint=None, claim=None
    )
    assert not (runtime_dir / "retry").exists()


# ---------------------------------------------------------------------------
# Available inspection (Section 57)
# ---------------------------------------------------------------------------


def test_available_checkpoint_inspection_is_read_only(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)
    checkpoint_path = retry_checkpoint_path(runtime_dir)
    before = checkpoint_path.read_bytes()

    inspection = inspect_resume(runtime_dir)

    assert inspection.disposition == ResumeDisposition.RETRY_AVAILABLE
    assert inspection.checkpoint == checkpoint
    assert inspection.claim is None
    assert checkpoint_path.read_bytes() == before
    assert not resume_claim_path(runtime_dir).exists()


# ---------------------------------------------------------------------------
# Exhausted inspection (Section 58)
# ---------------------------------------------------------------------------


def test_exhausted_checkpoint_inspection_and_claim_leave_checkpoint_untouched(
    tmp_path: Path,
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint(current_attempt=3, max_attempts=3)
    freeze_retry_checkpoint(runtime_dir, checkpoint)
    checkpoint_path = retry_checkpoint_path(runtime_dir)
    before = checkpoint_path.read_bytes()

    inspection = inspect_resume(runtime_dir)
    assert inspection.disposition == ResumeDisposition.RETRY_EXHAUSTED
    assert inspection.checkpoint == checkpoint
    assert inspection.claim is None
    assert checkpoint_path.read_bytes() == before

    claim_inspection = claim_retry_checkpoint(runtime_dir)
    assert claim_inspection.disposition == ResumeDisposition.RETRY_EXHAUSTED
    assert claim_inspection.claim is None
    assert checkpoint_path.read_bytes() == before
    assert not resume_claim_path(runtime_dir).exists()


# ---------------------------------------------------------------------------
# First claim (Sections 59 / 60 / 61)
# ---------------------------------------------------------------------------


def test_resume_claim_path_is_exact(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    assert resume_claim_path(runtime_dir) == runtime_dir / "retry" / "claim.json"


def test_first_claim_transfers_authority_and_removes_checkpoint(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)
    checkpoint_path = retry_checkpoint_path(runtime_dir)
    claim_path = resume_claim_path(runtime_dir)

    inspection = claim_retry_checkpoint(runtime_dir)

    assert inspection.disposition == ResumeDisposition.CLAIMED
    assert inspection.claim is not None
    assert inspection.claim.status == ResumeClaimStatus.CLAIMED
    assert inspection.claim.checkpoint == checkpoint
    assert inspection.checkpoint == checkpoint
    assert claim_path.exists()
    assert not checkpoint_path.exists()
    assert {p.name for p in claim_path.parent.iterdir()} == {"claim.json"}


def test_claim_preserves_full_semantic_authority_and_excludes_provider_telemetry(
    tmp_path: Path,
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    invocation = _agent_invocation_result(
        stdout="SENTINEL-STDOUT-RESUME-CLAIM", adapter_name="SENTINEL-ADAPTER-RESUME-CLAIM"
    )
    _request, _decision, result = _resume_escalation_result(
        question="SENTINEL-QUESTION-RESUME-CLAIM",
        evidence=("SENTINEL-EVIDENCE-RESUME-CLAIM",),
        rationale="SENTINEL-RATIONALE-RESUME-CLAIM",
        instructions=("SENTINEL-INSTRUCTION-RESUME-CLAIM",),
        authorized_paths=("src/sentinel/resume_claim.py",),
        invocation=invocation,
    )
    attempt_state = _attempt_state(current_attempt=1)
    budget = RetryBudget(max_attempts=3)
    checkpoint = create_retry_checkpoint_from_escalation(
        attempt_state=attempt_state, budget=budget, result=result
    )
    assert checkpoint is not None
    freeze_retry_checkpoint(runtime_dir, checkpoint)

    inspection = claim_retry_checkpoint(runtime_dir)
    assert inspection.disposition == ResumeDisposition.CLAIMED
    assert inspection.claim is not None
    assert inspection.claim.checkpoint == checkpoint

    serialized = resume_claim_path(runtime_dir).read_text(encoding="utf-8")

    assert "SENTINEL-QUESTION-RESUME-CLAIM" in serialized
    assert "SENTINEL-EVIDENCE-RESUME-CLAIM" in serialized
    assert "SENTINEL-RATIONALE-RESUME-CLAIM" in serialized
    assert "SENTINEL-INSTRUCTION-RESUME-CLAIM" in serialized
    assert "src/sentinel/resume_claim.py" in serialized

    assert "SENTINEL-STDOUT-RESUME-CLAIM" not in serialized
    assert "SENTINEL-ADAPTER-RESUME-CLAIM" not in serialized
    assert "stdout" not in serialized
    assert "provider" not in serialized


def test_claim_preserves_review_findings(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    decision = _review_decision(
        summary="SENTINEL-SUMMARY-REVIEW-CLAIM",
        findings=(
            ReviewFinding(summary="SENTINEL-FINDING-SUMMARY", evidence="SENTINEL-FINDING-EVIDENCE"),
        ),
    )
    attempt_state = _attempt_state(current_attempt=1)
    budget = RetryBudget(max_attempts=3)
    checkpoint = create_retry_checkpoint_from_review(
        attempt_state=attempt_state, budget=budget, decision=decision
    )
    assert checkpoint is not None
    freeze_retry_checkpoint(runtime_dir, checkpoint)

    claim_retry_checkpoint(runtime_dir)
    serialized = resume_claim_path(runtime_dir).read_text(encoding="utf-8")

    assert "SENTINEL-SUMMARY-REVIEW-CLAIM" in serialized
    assert "SENTINEL-FINDING-SUMMARY" in serialized
    assert "SENTINEL-FINDING-EVIDENCE" in serialized


# ---------------------------------------------------------------------------
# CLAIMED idempotence (Section 62)
# ---------------------------------------------------------------------------


def test_claim_is_idempotent_for_an_already_claimed_checkpoint(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)

    first = claim_retry_checkpoint(runtime_dir)
    claim_path = resume_claim_path(runtime_dir)
    bytes_after_first = claim_path.read_bytes()

    second = claim_retry_checkpoint(runtime_dir)

    assert second.disposition == ResumeDisposition.CLAIMED
    assert second.claim == first.claim
    assert claim_path.read_bytes() == bytes_after_first


# ---------------------------------------------------------------------------
# Interrupted transfer recovery (Section 63)
# ---------------------------------------------------------------------------


def test_claim_recovers_an_interrupted_transfer(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    claim = _claimed_claim(checkpoint)
    _write_claim_file(runtime_dir, claim)
    freeze_retry_checkpoint(runtime_dir, checkpoint)
    checkpoint_path = retry_checkpoint_path(runtime_dir)
    assert checkpoint_path.exists()

    inspection = claim_retry_checkpoint(runtime_dir)

    assert inspection.disposition == ResumeDisposition.CLAIMED
    assert inspection.claim == claim
    assert not checkpoint_path.exists()


# ---------------------------------------------------------------------------
# Conflicting dual state (Section 64)
# ---------------------------------------------------------------------------


def test_conflicting_dual_state_fails_closed_for_inspect_and_claim(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint_a, *_ = _valid_escalation_checkpoint(current_attempt=1, max_attempts=3)
    checkpoint_b, *_ = _valid_escalation_checkpoint(current_attempt=1, max_attempts=5)

    claim_a = _claimed_claim(checkpoint_a)
    _write_claim_file(runtime_dir, claim_a)
    freeze_retry_checkpoint(runtime_dir, checkpoint_b)

    claim_path = resume_claim_path(runtime_dir)
    checkpoint_path = retry_checkpoint_path(runtime_dir)
    claim_bytes_before = claim_path.read_bytes()
    checkpoint_bytes_before = checkpoint_path.read_bytes()

    with pytest.raises(ResumeStoreError):
        inspect_resume(runtime_dir)

    assert claim_path.read_bytes() == claim_bytes_before
    assert checkpoint_path.read_bytes() == checkpoint_bytes_before

    with pytest.raises(ResumeStoreError):
        claim_retry_checkpoint(runtime_dir)

    assert claim_path.read_bytes() == claim_bytes_before
    assert checkpoint_path.read_bytes() == checkpoint_bytes_before


# ---------------------------------------------------------------------------
# STARTED inspection (Section 65)
# ---------------------------------------------------------------------------


def test_started_claim_requires_recovery_and_is_read_only(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    started = _claimed_claim(checkpoint).model_copy(update={"status": ResumeClaimStatus.STARTED})
    _write_claim_file(runtime_dir, started)
    claim_path = resume_claim_path(runtime_dir)
    bytes_before = claim_path.read_bytes()

    inspection = inspect_resume(runtime_dir)
    assert inspection.disposition == ResumeDisposition.STARTED_RECOVERY_REQUIRED
    assert inspection.claim == started
    assert inspection.checkpoint == checkpoint

    claim_inspection = claim_retry_checkpoint(runtime_dir)
    assert claim_inspection.disposition == ResumeDisposition.STARTED_RECOVERY_REQUIRED
    assert claim_inspection.claim == started

    assert claim_path.read_bytes() == bytes_before
    assert not retry_checkpoint_path(runtime_dir).exists()


def test_started_claim_with_lingering_checkpoint_fails_closed(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    started = _claimed_claim(checkpoint).model_copy(update={"status": ResumeClaimStatus.STARTED})
    _write_claim_file(runtime_dir, started)
    freeze_retry_checkpoint(runtime_dir, checkpoint)

    with pytest.raises(ResumeStoreError):
        inspect_resume(runtime_dir)
    with pytest.raises(ResumeStoreError):
        claim_retry_checkpoint(runtime_dir)


# ---------------------------------------------------------------------------
# Mark STARTED (Section 66)
# ---------------------------------------------------------------------------


def test_mark_resume_started_transitions_claimed_to_started(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)
    inspection = claim_retry_checkpoint(runtime_dir)
    assert inspection.claim is not None
    claim = inspection.claim

    started = mark_resume_started(runtime_dir, claim)

    assert started.status == ResumeClaimStatus.STARTED
    assert started.checkpoint == claim.checkpoint
    assert started.checkpoint_digest == claim.checkpoint_digest
    assert started.schema_version == claim.schema_version

    claim_path = resume_claim_path(runtime_dir)
    assert _load_claim(claim_path) == started
    assert not retry_checkpoint_path(runtime_dir).exists()
    assert not (runtime_dir / "retry" / "start.lock").exists()


# ---------------------------------------------------------------------------
# STARTED non-idempotence (Section 67)
# ---------------------------------------------------------------------------


def test_mark_resume_started_rejects_replay_on_already_started_claim(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)
    inspection = claim_retry_checkpoint(runtime_dir)
    assert inspection.claim is not None
    started = mark_resume_started(runtime_dir, inspection.claim)

    with pytest.raises(ResumeStoreError):
        mark_resume_started(runtime_dir, started)

    claim_path = resume_claim_path(runtime_dir)
    assert _load_claim(claim_path).status == ResumeClaimStatus.STARTED


# ---------------------------------------------------------------------------
# Stale supplied claim (Section 68)
# ---------------------------------------------------------------------------


def test_mark_resume_started_rejects_a_stale_supplied_claim(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint_a, *_ = _valid_escalation_checkpoint(current_attempt=1, max_attempts=3)
    freeze_retry_checkpoint(runtime_dir, checkpoint_a)
    inspection = claim_retry_checkpoint(runtime_dir)
    assert inspection.claim is not None
    claim_a = inspection.claim

    checkpoint_b, *_ = _valid_escalation_checkpoint(current_attempt=1, max_attempts=5)
    claim_b = _claimed_claim(checkpoint_b)
    claim_path = _write_claim_file(runtime_dir, claim_b)
    bytes_before = claim_path.read_bytes()

    with pytest.raises(ResumeStoreError):
        mark_resume_started(runtime_dir, claim_a)

    assert claim_path.read_bytes() == bytes_before


# ---------------------------------------------------------------------------
# Checkpoint still present at start (Section 69)
# ---------------------------------------------------------------------------


def test_mark_resume_started_requires_completed_transfer(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    claim = _claimed_claim(checkpoint)
    _write_claim_file(runtime_dir, claim)
    freeze_retry_checkpoint(runtime_dir, checkpoint)

    with pytest.raises(ResumeStoreError):
        mark_resume_started(runtime_dir, claim)

    assert retry_checkpoint_path(runtime_dir).exists()
    claim_path = resume_claim_path(runtime_dir)
    assert _load_claim(claim_path).status == ResumeClaimStatus.CLAIMED


# ---------------------------------------------------------------------------
# Concurrent initial claim (Section 70)
# ---------------------------------------------------------------------------


def test_concurrent_initial_claim_has_exactly_one_creator(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)

    barrier = threading.Barrier(2)
    original_write = resume_module._write_new_claim_exclusive

    def synced_write(path: Path, payload: bytes) -> None:
        barrier.wait(timeout=5)
        original_write(path, payload)

    monkeypatch.setattr(resume_module, "_write_new_claim_exclusive", synced_write)

    results: list[ResumeInspection] = []
    errors: list[BaseException] = []
    results_lock = threading.Lock()

    def worker() -> None:
        try:
            outcome = claim_retry_checkpoint(runtime_dir)
        except BaseException as exc:
            with results_lock:
                errors.append(exc)
            return
        with results_lock:
            results.append(outcome)

    threads = [threading.Thread(target=worker) for _ in range(2)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join(timeout=5)

    assert not errors
    assert len(results) == 2
    assert all(result.disposition == ResumeDisposition.CLAIMED for result in results)
    assert results[0].claim == results[1].claim

    retry_dir = runtime_dir / "retry"
    assert sorted(p.name for p in retry_dir.iterdir()) == ["claim.json"]


# ---------------------------------------------------------------------------
# Start-lock contention (Section 71)
# ---------------------------------------------------------------------------


def test_mark_resume_started_rejects_a_contended_start_lock(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)
    inspection = claim_retry_checkpoint(runtime_dir)
    assert inspection.claim is not None
    claim = inspection.claim

    lock_path = runtime_dir / "retry" / "start.lock"
    lock_path.write_text("held", encoding="utf-8")

    with pytest.raises(ResumeStoreError):
        mark_resume_started(runtime_dir, claim)

    assert lock_path.read_text(encoding="utf-8") == "held"
    claim_path = resume_claim_path(runtime_dir)
    assert _load_claim(claim_path).status == ResumeClaimStatus.CLAIMED


# ---------------------------------------------------------------------------
# Retry-dir symlink (Section 72)
# ---------------------------------------------------------------------------


def test_retry_dir_symlink_is_rejected_by_every_entry_point(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    real_dir = tmp_path / "real-retry-dir"
    real_dir.mkdir()
    _symlink_or_skip(runtime_dir / "retry", real_dir)

    checkpoint, *_ = _valid_escalation_checkpoint()
    claim = _claimed_claim(checkpoint)

    with pytest.raises(ResumeStoreError):
        inspect_resume(runtime_dir)
    with pytest.raises(ResumeStoreError):
        claim_retry_checkpoint(runtime_dir)
    with pytest.raises(ResumeStoreError):
        mark_resume_started(runtime_dir, claim)

    assert list(real_dir.iterdir()) == []


# ---------------------------------------------------------------------------
# Claim symlink (Section 73)
# ---------------------------------------------------------------------------


def test_claim_file_symlink_is_rejected_by_every_entry_point(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    retry_dir = runtime_dir / "retry"
    retry_dir.mkdir(parents=True)
    external_target = tmp_path / "external-claim.json"
    external_target.write_text("external", encoding="utf-8")
    _symlink_or_skip(retry_dir / "claim.json", external_target)

    checkpoint, *_ = _valid_escalation_checkpoint()
    claim = _claimed_claim(checkpoint)

    with pytest.raises(ResumeStoreError):
        inspect_resume(runtime_dir)
    with pytest.raises(ResumeStoreError):
        claim_retry_checkpoint(runtime_dir)
    with pytest.raises(ResumeStoreError):
        mark_resume_started(runtime_dir, claim)

    assert external_target.read_text(encoding="utf-8") == "external"


# ---------------------------------------------------------------------------
# Start-lock symlink (Section 74)
# ---------------------------------------------------------------------------


def test_start_lock_symlink_is_rejected(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)
    inspection = claim_retry_checkpoint(runtime_dir)
    assert inspection.claim is not None
    claim = inspection.claim

    external_target = tmp_path / "external-lock"
    external_target.write_text("external", encoding="utf-8")
    _symlink_or_skip(runtime_dir / "retry" / "start.lock", external_target)

    with pytest.raises(ResumeStoreError):
        mark_resume_started(runtime_dir, claim)

    assert external_target.read_text(encoding="utf-8") == "external"
    claim_path = resume_claim_path(runtime_dir)
    assert _load_claim(claim_path).status == ResumeClaimStatus.CLAIMED


# ---------------------------------------------------------------------------
# Corrupt claim (Section 75)
# ---------------------------------------------------------------------------


def test_corrupt_claim_file_fails_closed(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    claim_path = resume_claim_path(runtime_dir)
    claim_path.parent.mkdir(parents=True)
    claim_path.write_text("{not valid json", encoding="utf-8")

    with pytest.raises(ResumeStoreError):
        inspect_resume(runtime_dir)
    with pytest.raises(ResumeStoreError):
        claim_retry_checkpoint(runtime_dir)

    checkpoint, *_ = _valid_escalation_checkpoint()
    forged_claim = _claimed_claim(checkpoint)
    with pytest.raises(ResumeStoreError):
        mark_resume_started(runtime_dir, forged_claim)

    assert claim_path.read_text(encoding="utf-8") == "{not valid json"


# ---------------------------------------------------------------------------
# Forged claim relationship (Section 76)
# ---------------------------------------------------------------------------


def test_forged_claim_relationship_fails_closed_on_load(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    payload = {
        "schema_version": 1,
        "checkpoint_digest": "0" * 64,
        "checkpoint": checkpoint.model_dump(mode="json"),
        "status": ResumeClaimStatus.CLAIMED.value,
    }
    claim_path = resume_claim_path(runtime_dir)
    claim_path.parent.mkdir(parents=True)
    claim_path.write_text(json.dumps(payload), encoding="utf-8")

    with pytest.raises(ResumeStoreError):
        inspect_resume(runtime_dir)
    with pytest.raises(ResumeStoreError):
        claim_retry_checkpoint(runtime_dir)


# ---------------------------------------------------------------------------
# Claim-write failure (Section 77)
# ---------------------------------------------------------------------------


def test_claim_write_failure_preserves_checkpoint_and_creates_no_claim(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)
    checkpoint_path = retry_checkpoint_path(runtime_dir)
    checkpoint_bytes_before = checkpoint_path.read_bytes()

    def fail_write(path: Path, payload: bytes) -> None:
        raise OSError("simulated claim write failure")

    monkeypatch.setattr(resume_module, "_write_new_claim_exclusive", fail_write)

    with pytest.raises(ResumeStoreError):
        claim_retry_checkpoint(runtime_dir)

    assert checkpoint_path.read_bytes() == checkpoint_bytes_before
    assert not resume_claim_path(runtime_dir).exists()


# ---------------------------------------------------------------------------
# Checkpoint-unlink failure (Section 78)
# ---------------------------------------------------------------------------


def test_checkpoint_unlink_failure_is_recoverable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)

    def fail_remove(path: Path) -> None:
        raise OSError("simulated unlink failure")

    monkeypatch.setattr(resume_module, "_remove_transferred_checkpoint", fail_remove)

    with pytest.raises(ResumeStoreError):
        claim_retry_checkpoint(runtime_dir)

    claim_path = resume_claim_path(runtime_dir)
    checkpoint_path = retry_checkpoint_path(runtime_dir)
    assert claim_path.exists()
    assert checkpoint_path.exists()
    on_disk_claim = _load_claim(claim_path)
    assert on_disk_claim.status == ResumeClaimStatus.CLAIMED
    assert on_disk_claim.checkpoint == checkpoint

    monkeypatch.undo()

    inspection = claim_retry_checkpoint(runtime_dir)
    assert inspection.disposition == ResumeDisposition.CLAIMED
    assert not checkpoint_path.exists()


# ---------------------------------------------------------------------------
# STARTED replacement failure (Section 79)
# ---------------------------------------------------------------------------


def test_started_replacement_failure_leaves_claim_claimed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)
    inspection = claim_retry_checkpoint(runtime_dir)
    assert inspection.claim is not None
    claim = inspection.claim

    def fail_replace(source: Path, target: Path) -> None:
        raise OSError("simulated replace failure")

    monkeypatch.setattr(resume_module, "_replace_atomically", fail_replace)

    with pytest.raises(ResumeStoreError):
        mark_resume_started(runtime_dir, claim)

    claim_path = resume_claim_path(runtime_dir)
    assert _load_claim(claim_path).status == ResumeClaimStatus.CLAIMED
    assert not (runtime_dir / "retry" / "start.lock").exists()


# ---------------------------------------------------------------------------
# Deterministic bytes (Section 80)
# ---------------------------------------------------------------------------


def test_claim_bytes_are_deterministic_across_separate_runtimes(tmp_path: Path) -> None:
    runtime_a = tmp_path / "runtime-a"
    runtime_a.mkdir()
    runtime_b = tmp_path / "runtime-b"
    runtime_b.mkdir()

    checkpoint_a, *_ = _valid_escalation_checkpoint()
    checkpoint_b, *_ = _valid_escalation_checkpoint()

    freeze_retry_checkpoint(runtime_a, checkpoint_a)
    freeze_retry_checkpoint(runtime_b, checkpoint_b)

    claim_retry_checkpoint(runtime_a)
    claim_retry_checkpoint(runtime_b)

    assert resume_claim_path(runtime_a).read_bytes() == resume_claim_path(runtime_b).read_bytes()


# ---------------------------------------------------------------------------
# Inspect is read-only (Section 81)
# ---------------------------------------------------------------------------


def test_inspect_resume_never_mutates_disk_state(tmp_path: Path) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint, *_ = _valid_escalation_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)
    checkpoint_path = retry_checkpoint_path(runtime_dir)
    before_available = checkpoint_path.read_bytes()

    inspect_resume(runtime_dir)
    assert checkpoint_path.read_bytes() == before_available

    claim_retry_checkpoint(runtime_dir)
    claim_path = resume_claim_path(runtime_dir)
    before_claimed = claim_path.read_bytes()

    inspect_resume(runtime_dir)
    assert claim_path.read_bytes() == before_claimed
    assert not checkpoint_path.exists()


# ---------------------------------------------------------------------------
# No completion/consume API (Section 82)
# ---------------------------------------------------------------------------


def test_no_claim_completion_or_settlement_api_exists() -> None:
    forbidden_names = {
        "complete_resume",
        "consume_resume",
        "consume_claim",
        "delete_claim",
        "archive_claim",
        "settle_claim",
    }
    assert forbidden_names.isdisjoint(set(resume_module.__all__))
    for name in forbidden_names:
        assert not hasattr(resume_module, name)


# ---------------------------------------------------------------------------
# Dependency boundary (Section 83)
# ---------------------------------------------------------------------------

_ALLOWED_LOCKSTEP_IMPORTS = frozenset({"lockstep.retry", "lockstep.retry_checkpoint"})

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


def test_resume_module_only_imports_from_the_allowed_pure_surface() -> None:
    tree = ast.parse(inspect.getsource(resume_module))
    imported_modules = _imported_modules(tree)

    lockstep_imports = {
        module
        for module in imported_modules
        if module == "lockstep" or module.startswith("lockstep.")
    }
    assert lockstep_imports <= _ALLOWED_LOCKSTEP_IMPORTS


def test_resume_module_has_no_forbidden_imports() -> None:
    tree = ast.parse(inspect.getsource(resume_module))
    imported_modules = _imported_modules(tree)

    for forbidden_prefix in _FORBIDDEN_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


# ---------------------------------------------------------------------------
# No execution calls (Section 84)
# ---------------------------------------------------------------------------


def test_resume_module_has_no_execution_primitives() -> None:
    source = inspect.getsource(resume_module)
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
# Import-cycle smoke (Section 85)
# ---------------------------------------------------------------------------


def test_import_cycle_smoke_across_orders() -> None:
    statements = (
        "import lockstep.resume; import lockstep.retry; import lockstep.retry_checkpoint; "
        "import lockstep.runtime; import lockstep.supervisor.transaction",
        "import lockstep.retry; import lockstep.retry_checkpoint; import lockstep.resume; "
        "import lockstep.runtime; import lockstep.supervisor.transaction",
        "import lockstep.supervisor.transaction; import lockstep.runtime; "
        "import lockstep.resume; import lockstep.retry; import lockstep.retry_checkpoint",
        "import lockstep.runtime; import lockstep.supervisor.transaction; "
        "import lockstep.retry_checkpoint; import lockstep.retry; import lockstep.resume",
        "import lockstep.resume; import lockstep.supervisor.transaction; "
        "import lockstep.runtime; import lockstep.retry",
    )
    for statement in statements:
        result = subprocess.run([sys.executable, "-c", statement], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr
