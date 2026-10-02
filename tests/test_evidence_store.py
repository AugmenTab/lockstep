"""Phase 11.4: durable, typed, attempt-bound Implementer and verification evidence.

A Reviewer (or a resumed Reviewer) must rebuild its handoff from disk, never
from an in-memory Implementer or process result. Each artifact is written
atomically under the transaction runtime directory, bound to one attempt by
both its path and its content, and refused if re-recorded with different
content.

Baseline classification: every test in this module is RED at entry
(``lockstep.evidence_store`` does not exist).
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

from lockstep.domain import (
    AttemptNumber,
    ImplementationReport,
    PhaseId,
    RunId,
    SubphaseId,
    VerificationReport,
)
from lockstep.evidence_store import (
    EvidenceStoreError,
    implementation_report_path,
    load_implementation_report,
    load_verification_evidence,
    load_verification_report,
    verification_evidence_path,
    verification_report_path,
    write_implementation_report,
    write_verification_evidence,
    write_verification_report,
)
from lockstep.verification_stack import run_verification_stack

_PHASE = PhaseId.model_validate("01")
_SUBPHASE = SubphaseId.model_validate("02")
_RUN = RunId.model_validate("run-01-02")


def _attempt(value: int) -> AttemptNumber:
    return AttemptNumber.model_validate(value)


def _report(attempt: int = 1, *, summary: str = "implemented") -> ImplementationReport:
    return ImplementationReport(
        phase_id=_PHASE,
        subphase_id=_SUBPHASE,
        attempt=_attempt(attempt),
        summary=summary,
        changed_files=("feature_02.py",),
        decisions=("kept it small",),
        deviations=("I also need src/outside_scope.py",),
        concerns=("none",),
    )


def _load_report(runtime: Path, attempt: int = 1) -> ImplementationReport | None:
    return load_implementation_report(
        runtime, phase_id=_PHASE, subphase_id=_SUBPHASE, attempt=_attempt(attempt)
    )


def test_artifacts_live_under_a_per_attempt_directory() -> None:
    runtime = Path("/r")

    assert implementation_report_path(runtime, _attempt(2)) == (
        runtime / "artifacts" / "attempt-2" / "implementation-report.json"
    )
    assert verification_report_path(runtime, _attempt(2)).parent == (
        runtime / "artifacts" / "attempt-2"
    )
    assert verification_evidence_path(runtime, _attempt(2)).parent == (
        runtime / "artifacts" / "attempt-2"
    )
    assert (
        len(
            {
                implementation_report_path(runtime, _attempt(1)),
                verification_report_path(runtime, _attempt(1)),
                verification_evidence_path(runtime, _attempt(1)),
            }
        )
        == 3
    )


def test_a_persisted_implementation_report_reloads_exactly_without_the_agent_result(
    tmp_path: Path,
) -> None:
    written = _report()
    write_implementation_report(tmp_path, written)
    del written  # the in-memory object is gone; only the artifact on disk remains

    reloaded = _load_report(tmp_path)

    assert reloaded == _report()
    assert isinstance(reloaded, ImplementationReport)
    assert json.loads(implementation_report_path(tmp_path, _attempt(1)).read_text())["summary"] == (
        "implemented"
    )


def test_writes_are_atomic_and_leave_no_temporary_files(tmp_path: Path) -> None:
    write_implementation_report(tmp_path, _report())

    names = sorted(
        p.name for p in implementation_report_path(tmp_path, _attempt(1)).parent.iterdir()
    )
    assert names == ["implementation-report.json"]


def test_a_missing_artifact_loads_as_none(tmp_path: Path) -> None:
    assert _load_report(tmp_path) is None
    write_implementation_report(tmp_path, _report(1))
    assert _load_report(tmp_path, 2) is None


def test_rewriting_identical_content_is_idempotent_and_different_content_is_refused(
    tmp_path: Path,
) -> None:
    write_implementation_report(tmp_path, _report())
    write_implementation_report(tmp_path, _report())

    with pytest.raises(EvidenceStoreError):
        write_implementation_report(tmp_path, _report(summary="a different claim"))
    assert _load_report(tmp_path) == _report()


def test_attempt_binding_rejects_a_report_copied_into_another_attempt(tmp_path: Path) -> None:
    source = write_implementation_report(tmp_path, _report(1))
    target = implementation_report_path(tmp_path, _attempt(2))
    target.parent.mkdir(parents=True)
    target.write_bytes(source.read_bytes())

    with pytest.raises(EvidenceStoreError):
        _load_report(tmp_path, 2)


def test_identity_binding_rejects_a_report_for_another_subphase(tmp_path: Path) -> None:
    write_implementation_report(tmp_path, _report())

    with pytest.raises(EvidenceStoreError):
        load_implementation_report(
            tmp_path,
            phase_id=_PHASE,
            subphase_id=SubphaseId.model_validate("03"),
            attempt=_attempt(1),
        )


def test_a_malformed_artifact_is_a_typed_error_not_a_partial_read(tmp_path: Path) -> None:
    path = implementation_report_path(tmp_path, _attempt(1))
    path.parent.mkdir(parents=True)
    path.write_text("{not json", encoding="utf-8")

    with pytest.raises(EvidenceStoreError):
        _load_report(tmp_path)


def test_the_verification_report_and_its_evidence_sidecar_round_trip_separately(
    tmp_path: Path,
) -> None:
    stack = run_verification_stack(
        ((sys.executable, "-c", "print('ok')"),),
        run_id=_RUN,
        phase_id=_PHASE,
        subphase_id=_SUBPHASE,
        attempt=_attempt(1),
        cwd=tmp_path,
        env={"PATH": "/usr/bin:/bin"},
        timeout_seconds=30.0,
        max_output_bytes=4096,
        termination_grace_seconds=0.25,
    )

    write_verification_report(tmp_path, stack.report)
    write_verification_evidence(tmp_path, stack.evidence)

    report = load_verification_report(
        tmp_path, phase_id=_PHASE, subphase_id=_SUBPHASE, attempt=_attempt(1)
    )
    evidence = load_verification_evidence(
        tmp_path, run_id=_RUN, phase_id=_PHASE, subphase_id=_SUBPHASE, attempt=_attempt(1)
    )
    assert report == stack.report
    assert isinstance(report, VerificationReport)
    assert evidence == stack.evidence
    assert evidence is not None and evidence.commands[0].stdout.strip() == "ok"


def test_evidence_is_run_bound(tmp_path: Path) -> None:
    stack = run_verification_stack(
        ((sys.executable, "-c", "pass"),),
        run_id=_RUN,
        phase_id=_PHASE,
        subphase_id=_SUBPHASE,
        attempt=_attempt(1),
        cwd=tmp_path,
        env={"PATH": "/usr/bin:/bin"},
        timeout_seconds=30.0,
        max_output_bytes=4096,
        termination_grace_seconds=0.25,
    )
    write_verification_evidence(tmp_path, stack.evidence)

    with pytest.raises(EvidenceStoreError):
        load_verification_evidence(
            tmp_path,
            run_id=RunId.model_validate("run-01-99"),
            phase_id=_PHASE,
            subphase_id=_SUBPHASE,
            attempt=_attempt(1),
        )
