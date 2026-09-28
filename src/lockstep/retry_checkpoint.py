"""Durable retry authority checkpoint (Phase 9.9).

Gives the frozen 9.8 attempt-state/retry-budget protocol
(:mod:`lockstep.retry`) a durable, reconstructable resting place so this
situation:

    agent BLOCKED
        -> Planner authorizes RESUME_AGENT
        -> RetryBudget says attempt N+1 is available
        -> process exits / machine restarts

does not lose why retry is authorized, which role is authorized, which
exact attempt produced the authority, what Planner instructions
authorized continuation, or which exact next attempt is legal --
likewise for a Reviewer's REWORK verdict.

A :class:`RetryCheckpoint` binds a validated ``AttemptState``/
``RetryBudget``/``RetryRequest`` triple to the exact bounded semantic
evidence that authorized another attempt (:class:`RetryAuthority`): an
Implementer/Reviewer ``RESUME_AGENT`` escalation's structured
``EscalationRequest`` and ``PlannerDecision``, or a Reviewer's ``REWORK``
``ReviewDecision``. Every construction and load re-derives the retry
request from that authority and re-runs
:func:`~lockstep.retry.evaluate_retry`, so a persisted checkpoint is a
durable witness of a control-plane decision, never a trusted opaque
blob. Persists to exactly one location per runtime directory,
``<runtime_dir>/retry/checkpoint.json``, with freeze-once-then-fail-
closed semantics: an absent checkpoint may be frozen, an identical one
is an idempotent no-op, and a different one is rejected outright.

This module creates and freezes checkpoints; it does not consume,
claim, delete, or replay one, does not mutate the Supervisor
transaction, FSM, or event journal, does not re-enter an agent, and
performs no Git or provider I/O. It records bounded semantic authority
-- never raw provider invocation telemetry (stdout/stderr/argv/
environment/provider/model).
"""

from __future__ import annotations

import json
import os
import uuid
from enum import StrEnum
from pathlib import Path
from typing import Literal, Self

from pydantic import BaseModel, ConfigDict, ValidationError, model_validator

from lockstep.domain import ReviewDecision, ReviewVerdict
from lockstep.escalation import EscalationRequest, route_escalation
from lockstep.escalation_decision import (
    PlannerDecision,
    PlannerDecisionDisposition,
    resolve_planner_decision,
)
from lockstep.retry import (
    AttemptState,
    RetryBudget,
    RetryBudgetDisposition,
    RetryRequest,
    evaluate_retry,
    retry_request_from_escalation,
    retry_request_from_review,
)
from lockstep.supervisor.escalation import (
    SupervisorEscalationDisposition,
    SupervisorEscalationResult,
)

_RETRY_SUBDIR_NAME = "retry"
_CHECKPOINT_JSON_NAME = "checkpoint.json"


class RetryAuthorityKind(StrEnum):
    """Why another attempt is durably authorized."""

    ESCALATION_RESUME = "escalation_resume"
    REVIEW_REWORK = "review_rework"


class RetryCheckpointStoreError(Exception):
    """A retry checkpoint could not be durably persisted, frozen, or loaded.

    Carries a short, bounded, deterministic ``reason`` that never
    contains a blocker question, evidence, Planner rationale,
    instructions, Reviewer summary/findings, full JSON, or provider
    information. The optional ``path`` attribute identifies the
    filesystem location involved, when one is relevant.

    Owns store-specific failures: corrupt persisted checkpoints, an
    existing frozen checkpoint that differs from the candidate, unsafe
    symlinked storage locations, and atomic-persistence failures. It
    never wraps :class:`~lockstep.retry.RetryProtocolError` or a
    :class:`pydantic.ValidationError` raised by a lower layer that
    naturally owns that failure.
    """

    def __init__(self, reason: str, *, path: Path | None = None) -> None:
        self.reason = reason
        self.path = path
        super().__init__(f"retry checkpoint store error: {reason}")


class RetryAuthority(BaseModel):
    """The durable, bounded semantic evidence authorizing one retry attempt.

    Strict and frozen. Carries exactly the structured artifacts 9.10/
    9.11 will need to re-enter the correct role with the correct
    context -- never an invocation result, provider/model identity,
    prompt, or raw process output. For :attr:`RetryAuthorityKind.ESCALATION_RESUME`,
    ``escalation_request`` and ``planner_decision`` are required,
    ``review_decision`` must be absent, and the Planner decision must be
    bound to the exact request (:func:`~lockstep.escalation_decision.resolve_planner_decision`)
    and resolve to :attr:`~lockstep.escalation_decision.PlannerDecisionDisposition.RESUME_AGENT`.
    For :attr:`RetryAuthorityKind.REVIEW_REWORK`, ``review_decision`` is
    required with verdict :attr:`~lockstep.domain.ReviewVerdict.REWORK`,
    and ``escalation_request``/``planner_decision`` must be absent.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    kind: RetryAuthorityKind
    escalation_request: EscalationRequest | None = None
    planner_decision: PlannerDecision | None = None
    review_decision: ReviewDecision | None = None

    @model_validator(mode="after")
    def _validate_authority_relationship(self) -> Self:
        if self.kind == RetryAuthorityKind.ESCALATION_RESUME:
            if self.escalation_request is None:
                raise ValueError("escalation resume authority requires an escalation request")
            if self.planner_decision is None:
                raise ValueError("escalation resume authority requires a planner decision")
            if self.review_decision is not None:
                raise ValueError("escalation resume authority must not carry a review decision")

            resolution = resolve_planner_decision(self.escalation_request, self.planner_decision)
            if resolution.disposition != PlannerDecisionDisposition.RESUME_AGENT:
                raise ValueError("planner decision does not authorize resuming the agent")
            return self

        if self.review_decision is None:
            raise ValueError("review rework authority requires a review decision")
        if self.escalation_request is not None:
            raise ValueError("review rework authority must not carry an escalation request")
        if self.planner_decision is not None:
            raise ValueError("review rework authority must not carry a planner decision")
        if self.review_decision.verdict != ReviewVerdict.REWORK:
            raise ValueError("review decision is not a rework verdict")
        return self


def _derive_retry_request(authority: RetryAuthority) -> RetryRequest:
    """Re-derive the exact :class:`RetryRequest` implied by *authority*.

    Delegates to the frozen 9.8 extraction functions rather than
    reimplementing their field mapping or target-role legality, so this
    module never duplicates that protocol.
    """

    if authority.kind == RetryAuthorityKind.ESCALATION_RESUME:
        assert authority.escalation_request is not None
        synthetic_result = SupervisorEscalationResult(
            request=authority.escalation_request,
            route=route_escalation(authority.escalation_request),
            disposition=SupervisorEscalationDisposition.RESUME_AGENT,
        )
        derived = retry_request_from_escalation(synthetic_result)
        assert derived is not None
        return derived

    assert authority.review_decision is not None
    derived = retry_request_from_review(authority.review_decision)
    assert derived is not None
    return derived


class RetryCheckpoint(BaseModel):
    """Durable, reconstructable retry authority for one halted Sub-phase.

    Strict and frozen. On every construction and load, re-derives the
    :class:`~lockstep.retry.RetryRequest` implied by ``authority`` and
    re-runs :func:`~lockstep.retry.evaluate_retry` against
    ``attempt_state``/``budget``/``retry_request``, requiring the
    result to reproduce ``budget_disposition`` and ``next_attempt_state``
    exactly and the derived request to equal ``retry_request``.
    Persisted evaluation fields are durable witnesses and corruption
    detectors, never an authority that overrides re-evaluation. A stale
    or otherwise inconsistent ``attempt_state``/``retry_request`` pair
    raises :class:`~lockstep.retry.RetryProtocolError` unchanged, exactly
    as :func:`~lockstep.retry.evaluate_retry` does.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    schema_version: Literal[1]
    attempt_state: AttemptState
    budget: RetryBudget
    retry_request: RetryRequest
    budget_disposition: RetryBudgetDisposition
    next_attempt_state: AttemptState | None
    authority: RetryAuthority

    @model_validator(mode="after")
    def _validate_checkpoint_consistency(self) -> Self:
        derived_request = _derive_retry_request(self.authority)
        if derived_request != self.retry_request:
            raise ValueError("retry request does not match the persisted authority")

        evaluation = evaluate_retry(self.attempt_state, self.budget, self.retry_request)
        if evaluation.disposition != self.budget_disposition:
            raise ValueError("budget disposition does not match the retry evaluation")
        if evaluation.next_state != self.next_attempt_state:
            raise ValueError("next attempt state does not match the retry evaluation")

        return self


# --- Checkpoint creation ----------------------------------------------------


def create_retry_checkpoint_from_escalation(
    *,
    attempt_state: AttemptState,
    budget: RetryBudget,
    result: SupervisorEscalationResult,
) -> RetryCheckpoint | None:
    """Build a :class:`RetryCheckpoint` from a dispatched escalation, if retryable.

    Pure: performs no filesystem, network, or agent I/O. Returns
    ``None`` unless :func:`~lockstep.retry.retry_request_from_escalation`
    yields a request -- exactly the dispositions that already carry
    retry authority. On ``RESUME_AGENT``, requires ``result.planner_turn``
    to be present (a legally producible ``RESUME_AGENT`` result always
    has one); its absence raises :class:`RetryCheckpointStoreError`
    rather than silently producing an incomplete checkpoint. Delegates
    identity/budget validation entirely to
    :func:`~lockstep.retry.evaluate_retry`; a stale or otherwise
    inconsistent *attempt_state* raises
    :class:`~lockstep.retry.RetryProtocolError` unchanged.
    """

    retry_request = retry_request_from_escalation(result)
    if retry_request is None:
        return None

    if result.planner_turn is None:
        raise RetryCheckpointStoreError("resume escalation has no planner decision")

    authority = RetryAuthority(
        kind=RetryAuthorityKind.ESCALATION_RESUME,
        escalation_request=result.request,
        planner_decision=result.planner_turn.decision,
    )

    evaluation = evaluate_retry(attempt_state, budget, retry_request)

    return RetryCheckpoint(
        schema_version=1,
        attempt_state=attempt_state,
        budget=budget,
        retry_request=retry_request,
        budget_disposition=evaluation.disposition,
        next_attempt_state=evaluation.next_state,
        authority=authority,
    )


def create_retry_checkpoint_from_review(
    *,
    attempt_state: AttemptState,
    budget: RetryBudget,
    decision: ReviewDecision,
) -> RetryCheckpoint | None:
    """Build a :class:`RetryCheckpoint` from a Reviewer decision, if retryable.

    Pure: performs no filesystem, network, or agent I/O. Returns
    ``None`` unless :func:`~lockstep.retry.retry_request_from_review`
    yields a request -- only a ``REWORK`` verdict does; ``APPROVE`` and
    ``HALT`` never carry retry authority. Delegates identity/budget
    validation entirely to :func:`~lockstep.retry.evaluate_retry`; a
    stale or otherwise inconsistent *attempt_state* raises
    :class:`~lockstep.retry.RetryProtocolError` unchanged.
    """

    retry_request = retry_request_from_review(decision)
    if retry_request is None:
        return None

    authority = RetryAuthority(kind=RetryAuthorityKind.REVIEW_REWORK, review_decision=decision)

    evaluation = evaluate_retry(attempt_state, budget, retry_request)

    return RetryCheckpoint(
        schema_version=1,
        attempt_state=attempt_state,
        budget=budget,
        retry_request=retry_request,
        budget_disposition=evaluation.disposition,
        next_attempt_state=evaluation.next_state,
        authority=authority,
    )


# --- Runtime path -------------------------------------------------------


def retry_checkpoint_path(runtime_dir: Path) -> Path:
    """Return the one canonical durable retry-checkpoint location.

    Pure path composition; performs no filesystem access. Always
    ``<runtime_dir>/retry/checkpoint.json`` -- runtime state only, never
    under the project root, a source checkout, or a worktree.
    """

    return runtime_dir / _RETRY_SUBDIR_NAME / _CHECKPOINT_JSON_NAME


# --- Canonical serialization and atomic publication -------------------------


def _canonical_json_bytes(checkpoint: RetryCheckpoint) -> bytes:
    text = json.dumps(
        checkpoint.model_dump(mode="json"),
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return (text + "\n").encode("utf-8")


def _replace_atomically(source: Path, target: Path) -> None:
    os.replace(source, target)


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _reject_symlink(path: Path, name: str) -> None:
    if path.is_symlink():
        raise RetryCheckpointStoreError(f"{name} must not be a symlink", path=path)


def _atomic_write_checkpoint(
    retry_dir: Path, checkpoint_path: Path, checkpoint: RetryCheckpoint
) -> None:
    try:
        retry_dir.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise RetryCheckpointStoreError("cannot create retry directory", path=retry_dir) from exc

    payload = _canonical_json_bytes(checkpoint)
    temp_path = retry_dir / f".{checkpoint_path.name}.{uuid.uuid4().hex}.tmp"

    try:
        try:
            fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except OSError as exc:
            raise RetryCheckpointStoreError(
                "cannot create temporary retry checkpoint file", path=temp_path
            ) from exc

        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as exc:
            raise RetryCheckpointStoreError(
                "cannot write temporary retry checkpoint file", path=temp_path
            ) from exc

        try:
            _replace_atomically(temp_path, checkpoint_path)
        except OSError as exc:
            raise RetryCheckpointStoreError(
                "cannot publish retry checkpoint", path=checkpoint_path
            ) from exc

        try:
            _fsync_directory(retry_dir)
        except OSError as exc:
            raise RetryCheckpointStoreError("cannot fsync retry directory", path=retry_dir) from exc
    except BaseException:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass
        raise


def _read_utf8(path: Path) -> str:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise RetryCheckpointStoreError("cannot read retry checkpoint", path=path) from exc
    try:
        return raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise RetryCheckpointStoreError("retry checkpoint is not valid UTF-8", path=path) from exc


def _hydrate_checkpoint(path: Path) -> RetryCheckpoint:
    text = _read_utf8(path)
    try:
        raw = json.loads(text)
    except json.JSONDecodeError as exc:
        raise RetryCheckpointStoreError("retry checkpoint is malformed JSON", path=path) from exc
    try:
        return RetryCheckpoint.model_validate(raw)
    except ValidationError as exc:
        raise RetryCheckpointStoreError(
            "retry checkpoint does not match the expected schema", path=path
        ) from exc


# --- Freeze / load ------------------------------------------------------


def freeze_retry_checkpoint(runtime_dir: Path, checkpoint: RetryCheckpoint) -> RetryCheckpoint:
    """Freeze *checkpoint* as the one active durable retry checkpoint.

    An absent checkpoint is atomically persisted. A semantically
    identical existing checkpoint is an idempotent no-op. A different
    existing checkpoint fails closed with
    :class:`RetryCheckpointStoreError` -- there is no ``force``,
    overwrite, amend, or merge: a second different checkpoint appearing
    at the same runtime location without an explicit state transition
    is a control-plane conflict, not a last-writer-wins update.
    """

    retry_dir = runtime_dir / _RETRY_SUBDIR_NAME
    checkpoint_path = retry_checkpoint_path(runtime_dir)

    _reject_symlink(retry_dir, "retry directory")
    _reject_symlink(checkpoint_path, "retry checkpoint")

    if checkpoint_path.exists():
        existing = _hydrate_checkpoint(checkpoint_path)
        if existing == checkpoint:
            return existing
        raise RetryCheckpointStoreError("a different retry checkpoint is already frozen")

    _atomic_write_checkpoint(retry_dir, checkpoint_path, checkpoint)
    return checkpoint


def load_retry_checkpoint(runtime_dir: Path) -> RetryCheckpoint | None:
    """Load the active durable retry checkpoint, or ``None`` if none is frozen.

    Read-only: never repairs, reformats, or rewrites. A missing
    checkpoint is ``None``; a present-but-corrupt or inconsistent
    checkpoint raises :class:`RetryCheckpointStoreError` (or, for a
    stale attempt/budget relationship,
    :class:`~lockstep.retry.RetryProtocolError` propagated unchanged) --
    absence and corruption are materially different and are never
    conflated.
    """

    retry_dir = runtime_dir / _RETRY_SUBDIR_NAME
    checkpoint_path = retry_checkpoint_path(runtime_dir)

    _reject_symlink(retry_dir, "retry directory")
    _reject_symlink(checkpoint_path, "retry checkpoint")

    if not checkpoint_path.exists():
        return None

    return _hydrate_checkpoint(checkpoint_path)


__all__ = [
    "RetryAuthority",
    "RetryAuthorityKind",
    "RetryCheckpoint",
    "RetryCheckpointStoreError",
    "create_retry_checkpoint_from_escalation",
    "create_retry_checkpoint_from_review",
    "freeze_retry_checkpoint",
    "load_retry_checkpoint",
    "retry_checkpoint_path",
]
