"""Sub-phase 9.14-R1: deterministic regression for the concurrent claim
transfer race Phase-9 Gate Attempt 1 reproduced probabilistically (~3.6%)
in ``tests/test_resume.py::test_concurrent_initial_claim_has_exactly_one_creator``.

The frozen concurrency test is essential but relies on real thread
scheduling to hit the exact interleaving. These tests make the
losing-finisher state deterministic instead: they drive
``lockstep.resume._finish_claim_transfer`` directly through the exact
durable states a second, legitimate concurrent finisher can observe --
including the narrow window where the matching retry checkpoint is
observed present and then disappears before it is loaded -- without any
thread, sleep, or poll. Complements, and does not replace, the original
frozen concurrency test.
"""

import json
from pathlib import Path

import pytest

import lockstep.resume as resume_module
from lockstep.domain import PhaseId, ReviewDecision, ReviewVerdict, SubphaseId
from lockstep.resume import (
    ResumeClaim,
    ResumeClaimStatus,
    ResumeDisposition,
    ResumeStoreError,
    mark_resume_started,
    resume_claim_path,
    retry_checkpoint_digest,
)
from lockstep.retry import AttemptState, RetryBudget
from lockstep.retry_checkpoint import (
    RetryCheckpoint,
    create_retry_checkpoint_from_review,
    freeze_retry_checkpoint,
    retry_checkpoint_path,
)

_PHASE_ID = "09"
_SUBPHASE_ID = "14"


def _phase_id(value: str = _PHASE_ID) -> PhaseId:
    return PhaseId.model_validate(value)


def _subphase_id(value: str = _SUBPHASE_ID) -> SubphaseId:
    return SubphaseId.model_validate(value)


def _attempt_state(*, current_attempt: int = 1) -> AttemptState:
    return AttemptState(
        phase_id=_phase_id(), subphase_id=_subphase_id(), current_attempt=current_attempt
    )


def _review_decision(*, attempt: int = 1) -> ReviewDecision:
    return ReviewDecision(
        schema_version=1,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=attempt,
        verdict=ReviewVerdict.REWORK,
        summary="Rework requested.",
        findings=(),
    )


def _valid_checkpoint(*, current_attempt: int = 1, max_attempts: int = 3) -> RetryCheckpoint:
    decision = _review_decision(attempt=current_attempt)
    attempt_state = _attempt_state(current_attempt=current_attempt)
    budget = RetryBudget(max_attempts=max_attempts)
    checkpoint = create_retry_checkpoint_from_review(
        attempt_state=attempt_state, budget=budget, decision=decision
    )
    assert checkpoint is not None
    return checkpoint


def _runtime_dir(tmp_path: Path) -> Path:
    directory = tmp_path / "runtime"
    directory.mkdir()
    return directory


def _canonical_claim_bytes(claim: ResumeClaim) -> bytes:
    text = json.dumps(
        claim.model_dump(mode="json"), ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    return (text + "\n").encode("utf-8")


def _claimed_claim(checkpoint: RetryCheckpoint) -> ResumeClaim:
    return ResumeClaim(
        schema_version=1,
        checkpoint_digest=retry_checkpoint_digest(checkpoint),
        checkpoint=checkpoint,
        status=ResumeClaimStatus.CLAIMED,
    )


def _write_claim_file(runtime_dir: Path, claim: ResumeClaim) -> Path:
    path = resume_claim_path(runtime_dir)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(_canonical_claim_bytes(claim))
    return path


def _load_claim(path: Path) -> ResumeClaim:
    return ResumeClaim.model_validate(json.loads(path.read_text(encoding="utf-8")))


# ---------------------------------------------------------------------------
# Deterministic reproduction of the exact TOCTOU race
# ---------------------------------------------------------------------------


def test_finish_claim_transfer_converges_when_checkpoint_vanishes_between_check_and_load(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint = _valid_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)

    claim = _claimed_claim(checkpoint)
    _write_claim_file(runtime_dir, claim)

    checkpoint_path = retry_checkpoint_path(runtime_dir)
    assert checkpoint_path.exists()

    original_load = resume_module.load_retry_checkpoint

    def load_after_concurrent_removal(rd: Path) -> RetryCheckpoint | None:
        # A second legitimate finisher's `.exists()` check (inside
        # `_finish_claim_transfer`) has already observed the checkpoint
        # present; another finisher now completes the exact same transfer
        # and removes it before this load actually runs.
        checkpoint_path.unlink()
        return original_load(rd)

    monkeypatch.setattr(resume_module, "load_retry_checkpoint", load_after_concurrent_removal)

    result = resume_module._finish_claim_transfer(runtime_dir, claim)

    assert result.disposition == ResumeDisposition.CLAIMED
    assert result.claim == claim
    assert result.checkpoint == claim.checkpoint
    assert not checkpoint_path.exists()

    stored = _load_claim(resume_claim_path(runtime_dir))
    assert stored == claim


# ---------------------------------------------------------------------------
# Missing checkpoint is not blanket success
# ---------------------------------------------------------------------------


def test_finish_claim_transfer_rejects_genuine_authority_mismatch_when_checkpoint_already_absent(
    tmp_path: Path,
) -> None:
    runtime_dir = _runtime_dir(tmp_path)

    stored_checkpoint = _valid_checkpoint(current_attempt=1)
    stored_claim = _claimed_claim(stored_checkpoint)
    _write_claim_file(runtime_dir, stored_claim)
    # Deliberately no checkpoint.json: simulates a transfer already fully
    # completed for a *different* authority than the one this caller
    # expects.

    mismatched_checkpoint = _valid_checkpoint(current_attempt=2)
    mismatched_claim = _claimed_claim(mismatched_checkpoint)

    with pytest.raises(ResumeStoreError, match="disagree"):
        resume_module._finish_claim_transfer(runtime_dir, mismatched_claim)

    # The genuinely-stored claim must remain untouched by the rejected call.
    assert _load_claim(resume_claim_path(runtime_dir)) == stored_claim


def test_finish_claim_transfer_still_rejects_disagreement_when_checkpoint_present(
    tmp_path: Path,
) -> None:
    runtime_dir = _runtime_dir(tmp_path)

    stored_checkpoint = _valid_checkpoint(current_attempt=1)
    freeze_retry_checkpoint(runtime_dir, stored_checkpoint)
    claim = _claimed_claim(stored_checkpoint)
    _write_claim_file(runtime_dir, claim)

    mismatched_checkpoint = _valid_checkpoint(current_attempt=2)
    mismatched_claim = _claimed_claim(mismatched_checkpoint)

    with pytest.raises(ResumeStoreError, match="disagree"):
        resume_module._finish_claim_transfer(runtime_dir, mismatched_claim)

    assert retry_checkpoint_path(runtime_dir).exists()


# ---------------------------------------------------------------------------
# Monotonic STARTED handling: the losing finisher must never regress a
# claim that has already legitimately advanced past CLAIMED.
# ---------------------------------------------------------------------------


def test_finish_claim_transfer_does_not_regress_a_started_claim_to_claimed(
    tmp_path: Path,
) -> None:
    runtime_dir = _runtime_dir(tmp_path)
    checkpoint = _valid_checkpoint()
    freeze_retry_checkpoint(runtime_dir, checkpoint)

    claim = _claimed_claim(checkpoint)
    _write_claim_file(runtime_dir, claim)

    checkpoint_path = retry_checkpoint_path(runtime_dir)

    # The winning finisher completes the transfer first.
    first = resume_module._finish_claim_transfer(runtime_dir, claim)
    assert first.disposition == ResumeDisposition.CLAIMED
    assert not checkpoint_path.exists()

    # A third caller legitimately crosses the durable launch boundary
    # before the losing finisher (still holding its own pre-transfer
    # `claim` reference) gets a chance to run.
    started_claim = mark_resume_started(runtime_dir, claim)
    assert started_claim.status == ResumeClaimStatus.STARTED

    # The losing finisher must converge to the durable STARTED state, not
    # raise, not rewrite claim.json, and not restore the checkpoint.
    second = resume_module._finish_claim_transfer(runtime_dir, claim)

    assert second.disposition == ResumeDisposition.STARTED_RECOVERY_REQUIRED
    assert second.claim is not None
    assert second.claim.status == ResumeClaimStatus.STARTED
    assert not checkpoint_path.exists()

    stored = _load_claim(resume_claim_path(runtime_dir))
    assert stored.status == ResumeClaimStatus.STARTED
