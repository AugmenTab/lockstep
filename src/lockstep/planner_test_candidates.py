"""Pre-freeze Planner test-candidate rejection evidence and correction prompts.

Before ``TEST_COMMIT`` the Planner's authored tests are only a *candidate*. A
candidate the deterministic harness rejects at the Planner quality gate or at the
baseline expectation stage may be replaced by a fresh Planner invocation, within the
same transaction attempt, from the exact pristine pre-Planner worktree::

    candidate 1 -> quality fails   -> evidence recorded, worktree restored
    candidate 2 -> baseline fails  -> evidence recorded, worktree restored
    candidate 3 -> accepted        -> tests frozen, Implementer begins

The candidate *ordinal* counts Planner test candidates inside one transaction
attempt. It is not, and never becomes, a transaction ``AttemptNumber``: correcting a
candidate creates no retry checkpoint and never touches post-freeze retry authority.

A rejected candidate is evidence only. Its record (:class:`PlannerCandidateRejection`)
carries the deterministic findings the harness produced -- never provider prose and
never the candidate's file contents -- and confers no Contract, scope, test or
expectation authority. :func:`render_planner_correction_prompt` appends that evidence,
clearly labeled, after the original canonical test-authoring prompt; the frozen
Contract in that prompt stays the only requirement authority.

Pure: no I/O, no Git, no process launches. Durable storage lives in
:mod:`lockstep.evidence_store`; the loop itself is Supervisor-owned.
"""

from __future__ import annotations

import json
from collections.abc import Sequence
from enum import StrEnum
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, model_validator

from lockstep.baseline_expectations import BaselineEvidenceRecord
from lockstep.domain import AttemptNumber, PhaseId, RunId, SubphaseId
from lockstep.verification_stack import _bound

_CURRENT_SCHEMA_VERSION = 1

# How much of each captured stream a correction prompt quotes. The durable record keeps
# the full bounded output; the prompt only needs the diagnostic tail.
PROMPT_OUTPUT_TAIL_BYTES = 8_192

# Generic, repository-neutral statement of where a candidate is judged and what RED
# means relative to that order. Shared by every Planner test-authoring instruction.
PLANNER_QUALITY_INVARIANT = (
    "Planner-authored tests must pass the configured Planner quality command before "
    "baseline expectations are evaluated; the quality gate precedes baseline "
    "classification. For a red test, the intended failure must occur when the baseline "
    "test execution runs the test, not during the compilation, typechecking or linting "
    "performed by the Planner quality gate. When a required future module, API or type "
    "does not exist yet, author the test in a repository-appropriate way that still "
    "passes the current quality checks: do not create static references or imports whose "
    "mere absence makes the quality stage fail."
)

_TITLE_REJECTED = "REJECTED TEST CANDIDATE"
_TITLE_FINDINGS = "DETERMINISTIC VALIDATION FINDINGS"
_TITLE_INSTRUCTIONS = "CORRECTION INSTRUCTIONS"

# Authority labels match :class:`lockstep.handoff.AuthorityKind` values. The literals are
# used here because handoff imports the evidence store, which imports this module.
_EXECUTION_EVIDENCE = "execution_evidence"
_CONTROL_DECISION = "control_decision"

CORRECTION_INSTRUCTIONS = (
    "A previous unfrozen test candidate for this same frozen Contract was rejected by the "
    "host's deterministic validation. The rejected candidate and its findings are evidence "
    "only: they amend no Contract, acceptance criterion, test expectation, writable path or "
    "implementation scope. The frozen Contract above remains the only requirement "
    "authority.\n"
    "The worktree has been restored to its exact state before the rejected candidate; none "
    "of the rejected files remain. Author a complete replacement candidate that satisfies "
    "the frozen Contract and resolves every deterministic finding.\n"
    + PLANNER_QUALITY_INVARIANT
    + "\nDo not modify production code, configuration, planning authority, Git history, the "
    "Git index, or any path outside the authorized test paths."
)


class CandidateRejectionStage(StrEnum):
    """The deterministic stage that rejected a Planner test candidate (correctable only)."""

    TEST_QUALITY = "test_quality"
    BASELINE = "baseline"


class _CandidateModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class QualityCommandEvidence(_CandidateModel):
    """What the Planner quality command did for one candidate (bounded)."""

    argv: Annotated[tuple[str, ...], Field(min_length=1)]
    exit_code: int
    stdout: str = ""
    stderr: str = ""
    stdout_truncated: bool = False
    stderr_truncated: bool = False
    elapsed_seconds: float | None = None


class PlannerCandidateRejection(_CandidateModel):
    """Durable, deterministic evidence of why one Planner test candidate was rejected.

    ``attempt`` is the transaction attempt the candidate belongs to; ``candidate`` is its
    ordinal within that attempt. Exactly one of ``quality`` / ``baseline`` is present,
    matching ``stage``. ``test_paths`` are the Contract test paths the candidate authored
    (and that the Supervisor restored). Evidence only.
    """

    schema_version: int = _CURRENT_SCHEMA_VERSION
    run_id: RunId
    phase_id: PhaseId
    subphase_id: SubphaseId
    attempt: AttemptNumber
    candidate: Annotated[int, Field(ge=1)]
    stage: CandidateRejectionStage
    test_paths: tuple[str, ...]
    findings: Annotated[tuple[str, ...], Field(min_length=1)]
    max_output_bytes: Annotated[int, Field(ge=1)]
    quality: QualityCommandEvidence | None = None
    baseline: BaselineEvidenceRecord | None = None

    @model_validator(mode="after")
    def _evidence_matches_stage(self) -> PlannerCandidateRejection:
        if self.stage is CandidateRejectionStage.TEST_QUALITY:
            if self.quality is None or self.baseline is not None:
                raise ValueError("a test_quality rejection carries only quality evidence")
            for text in (self.quality.stdout, self.quality.stderr):
                if len(text.encode("utf-8")) > self.max_output_bytes:
                    raise ValueError("captured output exceeds the recorded bound")
        elif self.baseline is None or self.quality is not None:
            raise ValueError("a baseline rejection carries only baseline evidence")
        return self


def quality_rejection(
    *,
    run_id: RunId,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
    candidate: int,
    test_paths: Sequence[str],
    argv: Sequence[str],
    exit_code: int,
    stdout: str,
    stderr: str,
    stdout_truncated: bool,
    stderr_truncated: bool,
    elapsed_seconds: float | None,
    max_output_bytes: int,
) -> PlannerCandidateRejection:
    """The rejection record for a candidate whose Planner quality command failed."""
    out, out_truncated = _bound(stdout, max_output_bytes, stdout_truncated)
    err, err_truncated = _bound(stderr, max_output_bytes, stderr_truncated)
    return PlannerCandidateRejection(
        run_id=run_id,
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=attempt,
        candidate=candidate,
        stage=CandidateRejectionStage.TEST_QUALITY,
        test_paths=tuple(test_paths),
        findings=(f"planner_quality_failed exit={exit_code}",),
        max_output_bytes=max_output_bytes,
        quality=QualityCommandEvidence(
            argv=tuple(argv),
            exit_code=exit_code,
            stdout=out,
            stderr=err,
            stdout_truncated=out_truncated,
            stderr_truncated=err_truncated,
            elapsed_seconds=elapsed_seconds,
        ),
    )


def baseline_rejection(
    *,
    candidate: int,
    test_paths: Sequence[str],
    record: BaselineEvidenceRecord,
) -> PlannerCandidateRejection:
    """The rejection record for a candidate that violated a baseline expectation."""
    findings = tuple(
        f"{entry.finding} path={entry.path} expected={entry.expectation.value} "
        f"exit={'none' if entry.exit_code is None else entry.exit_code}"
        for entry in record.specs
        if not entry.satisfied and entry.finding is not None
    )
    return PlannerCandidateRejection(
        run_id=record.run_id,
        phase_id=record.phase_id,
        subphase_id=record.subphase_id,
        attempt=record.attempt,
        candidate=candidate,
        stage=CandidateRejectionStage.BASELINE,
        test_paths=tuple(test_paths),
        findings=findings or ("baseline_expectation_violated",),
        max_output_bytes=record.max_output_bytes,
        baseline=record,
    )


def _json(value: object) -> str:
    return json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def _section(title: str, payload: object, authority: str) -> str:
    return f"\n\n---\n## {title} [{authority}]\n{_json(payload)}\n"


def _tail(text: str) -> str:
    return _bound(text, PROMPT_OUTPUT_TAIL_BYTES, False)[0]


def _finding_payload(rejection: PlannerCandidateRejection) -> dict[str, object]:
    payload: dict[str, object] = {
        "candidate": rejection.candidate,
        "stage": rejection.stage.value,
        "findings": list(rejection.findings),
    }
    if rejection.quality is not None:
        payload["quality_command"] = {
            "argv": list(rejection.quality.argv),
            "exit_code": rejection.quality.exit_code,
            "stdout_tail": _tail(rejection.quality.stdout),
            "stderr_tail": _tail(rejection.quality.stderr),
        }
    if rejection.baseline is not None:
        payload["baseline"] = [
            {
                "path": entry.path,
                "expectation": entry.expectation.value,
                "argv": list(entry.argv),
                "termination": entry.termination,
                "exit_code": entry.exit_code,
                "satisfied": entry.satisfied,
                "finding": entry.finding,
                "stdout_tail": _tail(entry.stdout),
                "stderr_tail": _tail(entry.stderr),
            }
            for entry in rejection.baseline.specs
        ]
    return payload


def render_planner_correction_prompt(
    base_prompt: str, rejections: Sequence[PlannerCandidateRejection]
) -> str:
    """The original canonical test-authoring prompt plus a labeled correction section.

    *rejections* are every rejected candidate of this transaction attempt, oldest first.
    Sufficient for a fresh Planner invocation: nothing relies on provider session state.
    Quotes deterministic findings and a bounded tail of command output, never the
    rejected test source.
    """
    if not rejections:
        raise ValueError("a correction prompt requires at least one rejected candidate")
    rejected = [
        {
            "candidate": rejection.candidate,
            "stage": rejection.stage.value,
            "test_paths": list(rejection.test_paths),
        }
        for rejection in rejections
    ]
    findings = [_finding_payload(rejection) for rejection in rejections]
    return (
        base_prompt
        + _section(_TITLE_REJECTED, rejected, _EXECUTION_EVIDENCE)
        + _section(_TITLE_FINDINGS, findings, _EXECUTION_EVIDENCE)
        + f"\n\n---\n## {_TITLE_INSTRUCTIONS} [{_CONTROL_DECISION}]\n{CORRECTION_INSTRUCTIONS}\n"
    )


__all__ = [
    "CORRECTION_INSTRUCTIONS",
    "PLANNER_QUALITY_INVARIANT",
    "PROMPT_OUTPUT_TAIL_BYTES",
    "CandidateRejectionStage",
    "PlannerCandidateRejection",
    "QualityCommandEvidence",
    "baseline_rejection",
    "quality_rejection",
    "render_planner_correction_prompt",
]
