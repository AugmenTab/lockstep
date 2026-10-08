"""Durable, typed, attempt-bound Implementer and verification evidence.

A Reviewer, or a resumed Reviewer, must rebuild its handoff from disk rather
than from an in-memory Implementer or process result. Each attempt of a
transaction therefore leaves three immutable artifacts beneath that
transaction's own runtime directory::

    <runtime_dir>/artifacts/attempt-<N>/implementation-report.json
    <runtime_dir>/artifacts/attempt-<N>/verification-report.json
    <runtime_dir>/artifacts/attempt-<N>/verification-evidence.json

A transaction attempt whose Planner test candidates were rejected before the tests
froze also keeps one write-once record per rejected candidate, addressed by the
candidate ordinal (never an ``AttemptNumber``), so a later candidate can never
overwrite an earlier one's evidence::

    <runtime_dir>/artifacts/attempt-<N>/planner-candidates/candidate-<K>-rejection.json

The canonical ``baseline-evidence.json`` keeps its meaning: the baseline of the
candidate the transaction finally accepted (or, when every candidate was rejected,
of the last one).

The implementation report and verification report are the existing domain
artifacts; the evidence record is the bounded process-evidence sidecar from
:mod:`lockstep.verification_stack`. All three are evidence. None confers
Contract, scope, test or progress authority, and none is a progress store: the
project cursor and the transaction journal remain the only progress authority.

Every write is atomic (temporary file, ``fsync``, ``os.replace``, directory
``fsync``). An artifact is bound to its attempt by both its path and its
content, bound to its Phase and Sub-phase (and, for the evidence record, its
run) on load, and refused if recorded again with different content.
"""

from __future__ import annotations

import contextlib
import json
import os
import uuid
from pathlib import Path

from pydantic import BaseModel, ValidationError

from lockstep.baseline_expectations import BaselineEvidenceRecord
from lockstep.domain import (
    AttemptNumber,
    ImplementationReport,
    PhaseId,
    RunId,
    SubphaseId,
    VerificationReport,
)
from lockstep.planner_test_candidates import PlannerCandidateRejection
from lockstep.verification_stack import VerificationEvidenceRecord

_ARTIFACTS_DIR_NAME = "artifacts"
_IMPLEMENTATION_REPORT_NAME = "implementation-report.json"
_VERIFICATION_REPORT_NAME = "verification-report.json"
_VERIFICATION_EVIDENCE_NAME = "verification-evidence.json"
_BASELINE_EVIDENCE_NAME = "baseline-evidence.json"
_PLANNER_CANDIDATES_DIR_NAME = "planner-candidates"


class EvidenceStoreError(Exception):
    """An evidence artifact could not be durably recorded or trusted.

    Carries a short, bounded, deterministic ``reason`` that never includes
    artifact contents.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"evidence store error: {reason}")


def attempt_artifact_dir(runtime_dir: Path, attempt: AttemptNumber) -> Path:
    """The directory holding every evidence artifact of one attempt."""
    return Path(runtime_dir) / _ARTIFACTS_DIR_NAME / f"attempt-{attempt.root}"


def implementation_report_path(runtime_dir: Path, attempt: AttemptNumber) -> Path:
    return attempt_artifact_dir(runtime_dir, attempt) / _IMPLEMENTATION_REPORT_NAME


def verification_report_path(runtime_dir: Path, attempt: AttemptNumber) -> Path:
    return attempt_artifact_dir(runtime_dir, attempt) / _VERIFICATION_REPORT_NAME


def verification_evidence_path(runtime_dir: Path, attempt: AttemptNumber) -> Path:
    return attempt_artifact_dir(runtime_dir, attempt) / _VERIFICATION_EVIDENCE_NAME


def baseline_evidence_path(runtime_dir: Path, attempt: AttemptNumber) -> Path:
    return attempt_artifact_dir(runtime_dir, attempt) / _BASELINE_EVIDENCE_NAME


def planner_candidate_rejection_path(
    runtime_dir: Path, attempt: AttemptNumber, candidate: int
) -> Path:
    """Where the rejection evidence of Planner test candidate *candidate* is recorded."""
    if candidate < 1:
        raise EvidenceStoreError("a planner candidate ordinal must be positive")
    return (
        attempt_artifact_dir(runtime_dir, attempt)
        / _PLANNER_CANDIDATES_DIR_NAME
        / f"candidate-{candidate}-rejection.json"
    )


def _canonical_bytes(model: BaseModel) -> bytes:
    text = json.dumps(model.model_dump(mode="json"), ensure_ascii=False, separators=(",", ":"))
    return (text + "\n").encode("utf-8")


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _reject_symlinks(path: Path) -> None:
    for guarded in (path.parent.parent, path.parent, path):
        if guarded.is_symlink():
            raise EvidenceStoreError("evidence storage must not be a symlink")


def _write_once(path: Path, payload: bytes, *, name: str) -> Path:
    _reject_symlinks(path)
    if path.exists():
        try:
            existing = path.read_bytes()
        except OSError as exc:
            raise EvidenceStoreError(f"cannot read the recorded {name}") from exc
        if existing == payload:
            return path
        raise EvidenceStoreError(f"{name} is already recorded with different content")

    parent = path.parent
    temp_path = parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    try:
        try:
            parent.mkdir(parents=True, exist_ok=True)
            fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
            with os.fdopen(fd, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temp_path, path)
            _fsync_directory(parent)
        except OSError as exc:
            raise EvidenceStoreError(f"cannot record the {name}") from exc
    except BaseException:
        with contextlib.suppress(OSError):
            temp_path.unlink()
        raise
    return path


def _load[ModelT: BaseModel](path: Path, model_type: type[ModelT], *, name: str) -> ModelT | None:
    _reject_symlinks(path)
    if not path.exists():
        return None
    try:
        return model_type.model_validate(json.loads(path.read_bytes().decode("utf-8")))
    except (OSError, ValueError, ValidationError) as exc:
        raise EvidenceStoreError(f"the recorded {name} is unreadable or malformed") from exc


def _require_binding(
    artifact: ImplementationReport | VerificationReport | VerificationEvidenceRecord,
    *,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
    name: str,
) -> None:
    if (artifact.phase_id, artifact.subphase_id, artifact.attempt) != (
        phase_id,
        subphase_id,
        attempt,
    ):
        raise EvidenceStoreError(f"the recorded {name} does not belong to this attempt")


def write_implementation_report(runtime_dir: Path, report: ImplementationReport) -> Path:
    """Record *report* for its own attempt; identical re-records are no-ops."""
    return _write_once(
        implementation_report_path(runtime_dir, report.attempt),
        _canonical_bytes(report),
        name="implementation report",
    )


def load_implementation_report(
    runtime_dir: Path,
    *,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
) -> ImplementationReport | None:
    """Load the attempt's implementation report, or ``None`` if none was recorded."""
    report = _load(
        implementation_report_path(runtime_dir, attempt),
        ImplementationReport,
        name="implementation report",
    )
    if report is not None:
        _require_binding(
            report,
            phase_id=phase_id,
            subphase_id=subphase_id,
            attempt=attempt,
            name="implementation report",
        )
    return report


def write_verification_report(runtime_dir: Path, report: VerificationReport) -> Path:
    """Record the semantic verification report for its own attempt."""
    return _write_once(
        verification_report_path(runtime_dir, report.attempt),
        _canonical_bytes(report),
        name="verification report",
    )


def load_verification_report(
    runtime_dir: Path,
    *,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
) -> VerificationReport | None:
    """Load the attempt's verification report, or ``None`` if none was recorded."""
    report = _load(
        verification_report_path(runtime_dir, attempt),
        VerificationReport,
        name="verification report",
    )
    if report is not None:
        _require_binding(
            report,
            phase_id=phase_id,
            subphase_id=subphase_id,
            attempt=attempt,
            name="verification report",
        )
    return report


def write_verification_evidence(runtime_dir: Path, record: VerificationEvidenceRecord) -> Path:
    """Record the bounded command-evidence sidecar for its own attempt."""
    return _write_once(
        verification_evidence_path(runtime_dir, record.attempt),
        _canonical_bytes(record),
        name="verification evidence",
    )


def write_baseline_evidence(runtime_dir: Path, record: BaselineEvidenceRecord) -> Path:
    """Record the bounded per-specification baseline evidence for its own attempt."""
    return _write_once(
        baseline_evidence_path(runtime_dir, record.attempt),
        _canonical_bytes(record),
        name="baseline evidence",
    )


def write_planner_candidate_rejection(
    runtime_dir: Path, rejection: PlannerCandidateRejection
) -> Path:
    """Record one rejected Planner test candidate's evidence; never overwrites another's."""
    return _write_once(
        planner_candidate_rejection_path(runtime_dir, rejection.attempt, rejection.candidate),
        _canonical_bytes(rejection),
        name="planner candidate rejection",
    )


def load_planner_candidate_rejection(
    runtime_dir: Path,
    *,
    run_id: RunId,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
    candidate: int,
) -> PlannerCandidateRejection | None:
    """Load one rejected candidate's evidence, or ``None`` if none was recorded."""
    rejection = _load(
        planner_candidate_rejection_path(runtime_dir, attempt, candidate),
        PlannerCandidateRejection,
        name="planner candidate rejection",
    )
    if rejection is not None and (
        rejection.run_id,
        rejection.phase_id,
        rejection.subphase_id,
        rejection.attempt,
        rejection.candidate,
    ) != (run_id, phase_id, subphase_id, attempt, candidate):
        raise EvidenceStoreError("the recorded planner candidate rejection belongs elsewhere")
    return rejection


def load_verification_evidence(
    runtime_dir: Path,
    *,
    run_id: RunId,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
) -> VerificationEvidenceRecord | None:
    """Load the attempt's command-evidence sidecar, or ``None`` if none was recorded."""
    record = _load(
        verification_evidence_path(runtime_dir, attempt),
        VerificationEvidenceRecord,
        name="verification evidence",
    )
    if record is not None:
        _require_binding(
            record,
            phase_id=phase_id,
            subphase_id=subphase_id,
            attempt=attempt,
            name="verification evidence",
        )
        if record.run_id != run_id:
            raise EvidenceStoreError("the recorded verification evidence belongs to another run")
    return record


__all__ = [
    "EvidenceStoreError",
    "attempt_artifact_dir",
    "baseline_evidence_path",
    "implementation_report_path",
    "load_implementation_report",
    "load_planner_candidate_rejection",
    "load_verification_evidence",
    "load_verification_report",
    "planner_candidate_rejection_path",
    "verification_evidence_path",
    "verification_report_path",
    "write_baseline_evidence",
    "write_implementation_report",
    "write_planner_candidate_rejection",
    "write_verification_evidence",
    "write_verification_report",
]
