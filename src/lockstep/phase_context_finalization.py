"""Durable, immutable Phase-context finalization: the handoff a completed Phase leaves behind.

Before a Phase may join the cursor's completed history, the host freezes one deterministic
index over the authoritative durable state that proves what the Phase established::

    durable gate PASS (decision + basis, latest attempt)
        -> PhaseContextFinalization built from durable state only
        -> published write-once, reloaded and verified
        -> successor outline published, cursor advanced     (lockstep.phase_gate_cycle)

Every fact is read, never inferred or summarized: identity and order from the READY cursor;
the passing decision and its basis from the gate's write-once artifacts; Contract integrity
from the archived Contract; canonical completion from each run's verified transaction
journal; accepted commits from the ``lockstep/run/<run-id>`` branches (each an ancestor of
the gate basis, the basis run's tip equal to it); the boundary snapshots from the verified
Project Digest pointer and the tracked ContextSelection; and the previous Phase's own
verified finalization. No provider is invoked and nothing here writes anywhere else.

Layout beneath the project run root::

    project/phase-context/<phase-id>.json     one immutable artifact per completed Phase

The artifact is canonical compact JSON with one trailing newline; its identity is the
SHA-256 of those bytes. Publication mirrors the gate's write-once rule: an absent artifact is
written atomically (temporary file, ``fsync``, replace, directory ``fsync``) and reloaded; an
identical one is an idempotent success; a different one for the same Phase fails closed and
is never repaired.

The boundary snapshots (Project Digest revision, ContextSelection identity) are historical
facts of the Phase boundary. Once a finalization is published, a resumed completion verifies
the immutable Phase facts against it and reuses the recorded snapshots; later drift of the
Digest or the selection never rewrites a handoff. A later Phase must reference the verified
finalization of the Phase before it; there is no legacy or assumed-complete variant, so a
runtime whose earlier Phase completed without one stops here rather than guess.

Nothing here tears anything down; transient state stays until a later teardown step can use
this artifact to decide that it is safe.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
import uuid
from pathlib import Path
from typing import Annotated, Literal, Self

from pydantic import (
    BaseModel,
    ConfigDict,
    Field,
    StringConstraints,
    ValidationError,
    field_validator,
    model_validator,
)

from lockstep.context.context_selection_store import (
    CONTEXT_SELECTION_SCHEMA_VERSION,
    ContextSelectionStoreError,
    load_context_selection_identity,
)
from lockstep.context.project_digest import project_digest_identity
from lockstep.context.project_digest_store import (
    ProjectDigestStoreError,
    load_project_digest,
    load_project_digest_revision,
)
from lockstep.contract_history import load_archived_subphase_contract
from lockstep.domain import MasterPlan, PhaseId, ProjectId, RunId, SchemaVersion, SubphaseId
from lockstep.git import GitCommandError, inspect_repository
from lockstep.git.evidence import branch_commit, is_ancestor
from lockstep.persistence import (
    ExecutionEvent,
    StateConsistencyError,
    load_verified_state,
    read_events,
)
from lockstep.persistence.journal import JournalIntegrityError
from lockstep.persistence.state_store import StatePersistenceError
from lockstep.phase_gate import (
    PhaseGateBasis,
    PhaseGateBasisRule,
    PhaseGateDecision,
    PhaseGateError,
    PhaseGateRefusal,
    PhaseGateVerdict,
    list_phase_gate_attempts,
    load_phase_gate_basis,
    load_phase_gate_decision,
    phase_gate_attempt_dir,
)
from lockstep.planning_store import (
    PlanningStoreError,
    load_active_subphase_contract,
    load_frozen_master_plan,
)
from lockstep.project_cursor import (
    CompletedSubphase,
    PhaseGateStatus,
    ProjectCursor,
    ProjectCursorError,
)
from lockstep.project_cursor_store import ProjectCursorStoreError, load_project_cursor
from lockstep.project_orchestrator import (
    transaction_branch,
    transaction_runtime_dir,
    transaction_worktree_path,
)
from lockstep.runtime import AgentRuntime
from lockstep.state import WorkflowState

_CURRENT_SCHEMA_VERSION: SchemaVersion = SchemaVersion.model_validate(1)

_PROJECT_DIR_NAME = "project"
_PHASE_CONTEXT_DIR_NAME = "phase-context"
# The gate's write-once artifact names (lockstep.phase_gate keeps them private).
_GATE_DECISION_NAME = "decision.json"
_GATE_BASIS_NAME = "basis.json"
_JOURNAL_NAME = "events.jsonl"
_STATE_NAME = "state.json"

_Sha256Hex = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]
_GitObjectId = Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{40,64}$")]
_PositiveStrictInt = Annotated[int, Field(strict=True, ge=1)]

_JOURNAL_FAILURES = (
    StateConsistencyError,
    StatePersistenceError,
    JournalIntegrityError,
    OSError,
    ValueError,
)


class PhaseContextFinalizationError(PhaseGateError):
    """A Phase finalization could not be built, verified, or published.

    A typed Phase-gate refusal: a Phase whose finalization fails never completes. Carries a
    short, bounded, deterministic ``reason`` that never contains artifact contents.
    """

    def __init__(
        self, reason: str, refusal: PhaseGateRefusal = PhaseGateRefusal.ARTIFACT_INCONSISTENT
    ) -> None:
        super().__init__(refusal, reason)


def _inconsistent(reason: str) -> PhaseContextFinalizationError:
    return PhaseContextFinalizationError(reason)


# --- The artifact model ----------------------------------------------------------------------


class _FinalizationModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class FinalPhaseGate(_FinalizationModel):
    """The passing gate attempt the Phase crossed, bound by the hashes of its artifacts."""

    gate_attempt: _PositiveStrictInt
    basis_run_id: RunId
    rule: PhaseGateBasisRule
    decision_sha256: _Sha256Hex
    basis_sha256: _Sha256Hex
    outcome: Literal[PhaseGateVerdict.PASS]


class FinalizedSubphase(_FinalizationModel):
    """One completed Sub-phase of the Phase: its run, frozen Contract and accepted commit."""

    subphase_id: SubphaseId
    run_id: RunId
    contract_digest: _Sha256Hex
    accepted_commit: _GitObjectId


class ProjectCursorReference(_FinalizationModel):
    """The READY cursor the Phase boundary was crossed from: revision and canonical hash."""

    revision: _PositiveStrictInt
    sha256: _Sha256Hex


class ContextSelectionReference(_FinalizationModel):
    """The tracked ContextSelection in force at the boundary, by version and identity."""

    schema_version: Literal[1]
    identity: _Sha256Hex


class PreviousPhaseFinalization(_FinalizationModel):
    """The verified finalization of the Phase immediately before, by identity."""

    phase_id: PhaseId
    identity: _Sha256Hex


class PhaseContextFinalization(_FinalizationModel):
    """The immutable, deterministic handoff of one completed Phase.

    An index of durable facts, not a narrative: it records which Contracts governed the
    Phase, which commits were accepted, which gate passed on which basis, which cursor the
    boundary was crossed from, and which Project Digest revision and ContextSelection
    applied. ``project_digest`` and ``context_selection`` are ``None`` exactly when none
    existed at the boundary; ``previous_phase_finalization`` is ``None`` exactly for the
    first Master Plan Phase. It confers no authority of its own.
    """

    schema_version: SchemaVersion = _CURRENT_SCHEMA_VERSION
    project_id: ProjectId
    master_plan_digest: _Sha256Hex
    phase_id: PhaseId
    final_repository_basis_commit: _GitObjectId
    final_phase_gate: FinalPhaseGate
    completed_subphases: tuple[FinalizedSubphase, ...]
    project_cursor: ProjectCursorReference
    project_digest: _Sha256Hex | None
    context_selection: ContextSelectionReference | None
    previous_phase_finalization: PreviousPhaseFinalization | None

    @field_validator("schema_version")
    @classmethod
    def _reject_unsupported_schema_version(cls, value: SchemaVersion) -> SchemaVersion:
        if value.root != _CURRENT_SCHEMA_VERSION.root:
            raise ValueError(f"unsupported schema_version {value.root}")
        return value

    @model_validator(mode="after")
    def _enforce_consistency(self) -> Self:
        subphases = [entry.subphase_id for entry in self.completed_subphases]
        runs = [entry.run_id for entry in self.completed_subphases]
        if len(set(subphases)) != len(subphases) or len(set(runs)) != len(runs):
            raise ValueError("a completed subphase or run appears more than once")
        previous = self.previous_phase_finalization
        if previous is not None and previous.phase_id == self.phase_id:
            raise ValueError("a phase cannot follow itself")
        gate = self.final_phase_gate
        if gate.rule is PhaseGateBasisRule.LATEST_PHASE_SUBPHASE:
            if not self.completed_subphases:
                raise ValueError("a latest-subphase basis needs a completed subphase")
            last = self.completed_subphases[-1]
            if (last.run_id, last.accepted_commit) != (
                gate.basis_run_id,
                self.final_repository_basis_commit,
            ):
                raise ValueError("the gate basis is not the last completed subphase")
        elif self.completed_subphases:
            raise ValueError("a prior-phase basis means the phase completed no subphase")
        return self


# --- Canonical bytes, identity and storage ---------------------------------------------------


def canonical_phase_context_finalization_bytes(value: PhaseContextFinalization) -> bytes:
    """The exact canonical bytes a finalization is stored and identified by."""
    text = json.dumps(value.model_dump(mode="json"), ensure_ascii=False, separators=(",", ":"))
    return (text + "\n").encode("utf-8")


def phase_context_finalization_identity(value: PhaseContextFinalization) -> str:
    """The SHA-256 of *value*'s canonical bytes."""
    return hashlib.sha256(canonical_phase_context_finalization_bytes(value)).hexdigest()


def phase_context_finalization_path(runtime_dir: Path, phase_id: PhaseId) -> Path:
    """Where the one finalization of *phase_id* lives beneath the project run root."""
    return Path(runtime_dir) / _PROJECT_DIR_NAME / _PHASE_CONTEXT_DIR_NAME / f"{phase_id.root}.json"


def _reject_symlinks(path: Path) -> None:
    for guarded in (path.parent.parent, path.parent, path):
        if guarded.is_symlink():
            raise _inconsistent("phase finalization storage must not be a symlink")


def load_phase_context_finalization(
    runtime_dir: Path, phase_id: PhaseId
) -> PhaseContextFinalization | None:
    """Load and verify the finalization of *phase_id*, or ``None`` if none was published.

    Read-only. The stored bytes must be exactly the canonical bytes of a valid
    finalization of *phase_id*; anything else fails closed.
    """
    path = phase_context_finalization_path(runtime_dir, phase_id)
    _reject_symlinks(path)
    if not path.exists():
        return None
    if not path.is_file():
        raise _inconsistent("the phase finalization is not a regular file")
    try:
        raw = path.read_bytes()
        loaded = PhaseContextFinalization.model_validate(json.loads(raw.decode("utf-8")))
    except (OSError, ValueError, ValidationError) as exc:
        raise _inconsistent("the phase finalization is unreadable or malformed") from exc
    if canonical_phase_context_finalization_bytes(loaded) != raw:
        raise _inconsistent("the phase finalization is not canonical")
    if loaded.phase_id != phase_id:
        raise _inconsistent("the phase finalization belongs to another phase")
    return loaded


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _write_once(path: Path, payload: bytes) -> None:
    _reject_symlinks(path)
    if path.exists():
        try:
            existing = path.read_bytes()
        except OSError as exc:
            raise _inconsistent("cannot read the recorded phase finalization") from exc
        if existing == payload:
            return
        raise _inconsistent("the phase finalization is already recorded with different content")

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
            raise _inconsistent("cannot record the phase finalization") from exc
    except BaseException:
        with contextlib.suppress(OSError):
            temp_path.unlink()
        raise


def publish_phase_context_finalization(runtime_dir: Path, value: PhaseContextFinalization) -> str:
    """Durably publish *value* write-once, reload and verify it, and return its identity.

    An identical existing artifact is an idempotent success; a different one for the same
    Phase fails closed and is left untouched.
    """
    payload = canonical_phase_context_finalization_bytes(value)
    _write_once(phase_context_finalization_path(runtime_dir, value.phase_id), payload)
    if load_phase_context_finalization(runtime_dir, value.phase_id) != value:
        raise _inconsistent("the published phase finalization does not reload equal")
    return hashlib.sha256(payload).hexdigest()


# --- Reading the durable facts ---------------------------------------------------------------


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canonical_model_bytes(model: BaseModel) -> bytes:
    text = json.dumps(model.model_dump(mode="json"), ensure_ascii=False, separators=(",", ":"))
    return (text + "\n").encode("utf-8")


def _load_cursor(runtime: AgentRuntime) -> ProjectCursor:
    try:
        cursor = load_project_cursor(runtime.project_root, runtime.runtime_dir)
    except (ProjectCursorStoreError, ProjectCursorError, PlanningStoreError) as exc:
        raise _inconsistent("the project cursor cannot be loaded") from exc
    if cursor is None:
        raise PhaseContextFinalizationError(
            "the project cursor is not initialized", PhaseGateRefusal.CURSOR_MISSING
        )
    return cursor


def _load_master(runtime: AgentRuntime) -> MasterPlan:
    try:
        master = load_frozen_master_plan(runtime.project_root)
    except PlanningStoreError as exc:
        raise _inconsistent("the master plan cannot be loaded") from exc
    if master is None:
        raise _inconsistent("the master plan is not frozen")
    return master


def _gate_artifact_bytes(
    runtime_dir: Path, phase_id: PhaseId, gate_attempt: int, name: str, model: BaseModel
) -> bytes:
    """The exact stored bytes of a loaded gate artifact; they must be its canonical bytes."""
    path = phase_gate_attempt_dir(runtime_dir, phase_id, gate_attempt) / name
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise _inconsistent("a gate artifact cannot be read") from exc
    if raw != _canonical_model_bytes(model):
        raise _inconsistent("a gate artifact is not canonical")
    return raw


def _passing_gate(
    runtime_dir: Path, phase_id: PhaseId, gate_attempt: int
) -> tuple[PhaseGateDecision, PhaseGateBasis, bytes, bytes]:
    decision = load_phase_gate_decision(runtime_dir, phase_id, gate_attempt)
    basis = load_phase_gate_basis(runtime_dir, phase_id, gate_attempt)
    if decision is None or basis is None:
        raise _inconsistent("the passing gate decision or its basis is not durable")
    if decision.outcome is not PhaseGateVerdict.PASS:
        raise PhaseContextFinalizationError(
            "the gate decision did not pass", PhaseGateRefusal.GATE_NOT_PASSED
        )
    if (basis.project_id, basis.master_plan_digest, basis.phase_id) != (
        decision.project_id,
        decision.master_plan_digest,
        decision.phase_id,
    ) or basis.commit != decision.basis_commit:
        raise _inconsistent("the gate decision does not match its basis")
    decision_raw = _gate_artifact_bytes(
        runtime_dir, phase_id, gate_attempt, _GATE_DECISION_NAME, decision
    )
    basis_raw = _gate_artifact_bytes(runtime_dir, phase_id, gate_attempt, _GATE_BASIS_NAME, basis)
    return decision, basis, decision_raw, basis_raw


def _expected_basis(cursor: ProjectCursor, phase_id: PhaseId) -> tuple[CompletedSubphase, str]:
    """The accepted Sub-phase the cursor history says a gate of *phase_id* must audit."""
    in_phase = [e for e in cursor.completed_subphases if e.phase_id == phase_id]
    if in_phase:
        return in_phase[-1], PhaseGateBasisRule.LATEST_PHASE_SUBPHASE.value
    if cursor.completed_subphases:
        return cursor.completed_subphases[-1], PhaseGateBasisRule.PRIOR_PHASE_TIP.value
    raise _inconsistent("no accepted subphase exists to finalize")


def _require_clean_basis(worktree: Path, basis: PhaseGateBasis) -> None:
    try:
        snapshot = inspect_repository(worktree)
    except (GitCommandError, OSError) as exc:
        raise PhaseContextFinalizationError(
            "the accepted basis worktree is unavailable", PhaseGateRefusal.BASIS_UNAVAILABLE
        ) from exc
    if snapshot.root != worktree.resolve() or snapshot.branch != basis.branch:
        raise PhaseContextFinalizationError(
            "the accepted basis worktree is not on its branch", PhaseGateRefusal.BASIS_UNAVAILABLE
        )
    if snapshot.staged_paths or snapshot.unstaged_paths:
        raise PhaseContextFinalizationError(
            "the accepted basis has uncommitted tracked changes", PhaseGateRefusal.BASIS_DIRTY
        )
    if snapshot.head_sha != basis.commit:
        raise PhaseContextFinalizationError(
            "the accepted basis moved since the gate passed", PhaseGateRefusal.BASIS_DRIFT
        )


def _require_archived_contract(runtime: AgentRuntime, entry: CompletedSubphase) -> None:
    try:
        archived = load_archived_subphase_contract(
            runtime.project_root,
            runtime.runtime_dir,
            phase_id=entry.phase_id,
            subphase_id=entry.subphase_id,
            contract_digest=entry.contract_digest,
        )
    except PlanningStoreError as exc:
        raise _inconsistent(f"subphase {entry.subphase_id.root} has an invalid contract") from exc
    if archived is None:
        raise _inconsistent(f"subphase {entry.subphase_id.root} has no archived contract")


def _require_subphase_complete(
    runtime_dir: Path, cursor: ProjectCursor, entry: CompletedSubphase
) -> None:
    directory = transaction_runtime_dir(runtime_dir, entry.run_id)
    journal = directory / _JOURNAL_NAME
    where = f"subphase {entry.subphase_id.root}"
    try:
        snapshot = load_verified_state(directory / _STATE_NAME, journal)
        events = read_events(journal)
    except _JOURNAL_FAILURES as exc:
        raise _inconsistent(f"{where} has an unverifiable transaction journal") from exc
    if (
        snapshot is None
        or snapshot.run_id != entry.run_id
        or snapshot.project_id != cursor.project_id
        or snapshot.workflow_state is not WorkflowState.SUBPHASE_COMPLETE
    ):
        raise _inconsistent(f"{where} has no canonical completion for its run")
    for event in events:
        if not isinstance(event, ExecutionEvent):
            continue
        if (event.phase_id is not None and event.phase_id != entry.phase_id) or (
            event.subphase_id is not None and event.subphase_id != entry.subphase_id
        ):
            raise _inconsistent(f"{where} has a transaction journal for another unit")


def _accepted_commit(worktree: Path, entry: CompletedSubphase, basis: PhaseGateBasis) -> str:
    where = f"subphase {entry.subphase_id.root}"
    try:
        commit = branch_commit(worktree, transaction_branch(entry.run_id))
        if commit is None:
            raise _inconsistent(f"{where} has no accepted run branch")
        ancestor = is_ancestor(worktree, commit, basis.commit)
    except GitCommandError as exc:
        raise _inconsistent(f"{where} has an unresolvable accepted commit") from exc
    if not ancestor:
        raise _inconsistent(f"{where} is not an ancestor of the gate basis")
    if entry.run_id == basis.basis_run_id and commit != basis.commit:
        raise _inconsistent("the gate basis run's branch is not the gate basis")
    return commit


def _cursor_reference(cursor: ProjectCursor) -> ProjectCursorReference:
    return ProjectCursorReference(
        revision=cursor.revision, sha256=_sha256(_canonical_model_bytes(cursor))
    )


def _verify_historical(
    runtime_dir: Path, cursor: ProjectCursor, value: PhaseContextFinalization
) -> None:
    """Prove an earlier Phase's finalization still agrees with immutable durable history."""
    if (value.project_id, value.master_plan_digest) != (
        cursor.project_id,
        cursor.master_plan_digest,
    ):
        raise _inconsistent("the previous phase finalization belongs to another plan")
    recorded = [(e.subphase_id, e.run_id, e.contract_digest) for e in value.completed_subphases]
    history = [
        (e.subphase_id, e.run_id, e.contract_digest)
        for e in cursor.completed_subphases
        if e.phase_id == value.phase_id
    ]
    if recorded != history:
        raise _inconsistent("the previous phase finalization disagrees with the cursor history")
    gate = value.final_phase_gate
    decision, basis, decision_raw, basis_raw = _passing_gate(
        runtime_dir, value.phase_id, gate.gate_attempt
    )
    if (
        _sha256(decision_raw) != gate.decision_sha256
        or _sha256(basis_raw) != gate.basis_sha256
        or decision.basis_commit != value.final_repository_basis_commit
        or basis.basis_run_id != gate.basis_run_id
    ):
        raise _inconsistent("the previous phase finalization disagrees with its gate")


def _previous_reference(
    runtime_dir: Path, cursor: ProjectCursor, master: MasterPlan, phase_id: PhaseId
) -> PreviousPhaseFinalization | None:
    order = [phase.phase_id for phase in master.phases]
    if phase_id not in order:
        raise _inconsistent("the phase is not in the master plan")
    index = order.index(phase_id)
    if index == 0:
        return None
    previous_id = order[index - 1]
    if previous_id not in cursor.completed_phases:
        raise _inconsistent("the previous phase is not complete")
    previous = load_phase_context_finalization(runtime_dir, previous_id)
    if previous is None:
        raise _inconsistent(f"phase {previous_id.root} completed without a phase finalization")
    _verify_historical(runtime_dir, cursor, previous)
    return PreviousPhaseFinalization(
        phase_id=previous_id, identity=phase_context_finalization_identity(previous)
    )


def _phase_facts(
    runtime: AgentRuntime, cursor: ProjectCursor, master: MasterPlan, decision: PhaseGateDecision
) -> PhaseContextFinalization:
    """Everything a finalization records except the boundary snapshots, from durable state."""
    project_root, runtime_dir = runtime.project_root, runtime.runtime_dir
    phase_id = decision.phase_id
    if cursor.current_phase != phase_id:
        raise _inconsistent("the gate decision is not for the current phase")
    if cursor.active_contract is not None:
        raise PhaseContextFinalizationError(
            "a subphase contract is active", PhaseGateRefusal.ACTIVE_CONTRACT
        )
    if (
        cursor.phase_gate_status is not PhaseGateStatus.READY
        or cursor.current_subphase is not None
        or cursor.remaining_outline
    ):
        raise PhaseContextFinalizationError(
            "the phase has unfinished subphases", PhaseGateRefusal.NOT_READY
        )
    try:
        active = load_active_subphase_contract(project_root, runtime_dir)
    except PlanningStoreError as exc:
        raise _inconsistent("the planning store holds an unreadable active contract") from exc
    if active is not None:
        raise PhaseContextFinalizationError(
            "a subphase contract is frozen", PhaseGateRefusal.ACTIVE_CONTRACT
        )

    attempts = list_phase_gate_attempts(runtime_dir, phase_id)
    if not attempts or attempts[-1] != decision.gate_attempt:
        raise _inconsistent("the passing gate decision is not the latest gate attempt")
    durable, basis, decision_raw, basis_raw = _passing_gate(
        runtime_dir, phase_id, decision.gate_attempt
    )
    if durable != decision:
        raise _inconsistent("the gate decision is not the durable decision")
    entry, rule = _expected_basis(cursor, phase_id)
    if (
        basis.basis_phase_id,
        basis.basis_subphase_id,
        basis.basis_run_id,
        basis.rule.value,
        basis.branch,
    ) != (entry.phase_id, entry.subphase_id, entry.run_id, rule, transaction_branch(entry.run_id)):
        raise _inconsistent("the gate basis is inconsistent with the cursor history")
    worktree = transaction_worktree_path(runtime_dir, basis.basis_run_id)
    _require_clean_basis(worktree, basis)

    subphases: list[FinalizedSubphase] = []
    for completed in cursor.completed_subphases:
        if completed.phase_id != phase_id:
            continue
        _require_archived_contract(runtime, completed)
        _require_subphase_complete(runtime_dir, cursor, completed)
        subphases.append(
            FinalizedSubphase(
                subphase_id=completed.subphase_id,
                run_id=completed.run_id,
                contract_digest=completed.contract_digest,
                accepted_commit=_accepted_commit(worktree, completed, basis),
            )
        )

    try:
        return PhaseContextFinalization(
            project_id=cursor.project_id,
            master_plan_digest=cursor.master_plan_digest,
            phase_id=phase_id,
            final_repository_basis_commit=basis.commit,
            final_phase_gate=FinalPhaseGate(
                gate_attempt=decision.gate_attempt,
                basis_run_id=basis.basis_run_id,
                rule=basis.rule,
                decision_sha256=_sha256(decision_raw),
                basis_sha256=_sha256(basis_raw),
                outcome=PhaseGateVerdict.PASS,
            ),
            completed_subphases=tuple(subphases),
            project_cursor=_cursor_reference(cursor),
            project_digest=None,
            context_selection=None,
            previous_phase_finalization=_previous_reference(runtime_dir, cursor, master, phase_id),
        )
    except ValidationError as exc:
        raise _inconsistent("the phase facts do not form a valid finalization") from exc


# --- Boundary snapshots ------------------------------------------------------------------------


def _digest_snapshot(runtime: AgentRuntime, cursor: ProjectCursor) -> str | None:
    try:
        digest = load_project_digest(runtime.project_root, runtime.runtime_dir)
    except (ProjectDigestStoreError, PlanningStoreError) as exc:
        raise _inconsistent("the project digest cannot be verified") from exc
    if digest is None:
        return None
    if digest.project_id != cursor.project_id:
        raise _inconsistent("the project digest names a different project")
    return project_digest_identity(digest)


def _selection_snapshot(runtime: AgentRuntime) -> ContextSelectionReference | None:
    try:
        identity = load_context_selection_identity(runtime.project_root)
    except ContextSelectionStoreError as exc:
        raise _inconsistent(f"context selection: {exc.reason}") from exc
    if identity is None:
        return None
    return ContextSelectionReference(
        schema_version=CONTEXT_SELECTION_SCHEMA_VERSION, identity=identity
    )


def _require_recorded_digest(runtime: AgentRuntime, revision: str | None) -> None:
    if revision is None:
        return
    try:
        recorded = load_project_digest_revision(runtime.project_root, runtime.runtime_dir, revision)
    except (ProjectDigestStoreError, PlanningStoreError) as exc:
        raise _inconsistent("the recorded project digest revision is invalid") from exc
    if recorded is None:
        raise _inconsistent("the recorded project digest revision does not exist")


# --- The completion hook -----------------------------------------------------------------------


def finalize_phase_context(
    runtime: AgentRuntime, decision: PhaseGateDecision
) -> PhaseContextFinalization:
    """Build, publish and verify the finalization of the Phase *decision* passed.

    Requires a durable, latest-attempt PASS for the cursor's current ``READY`` Phase, with
    no active Contract, a clean basis that matches the cursor history, and complete durable
    evidence for every completed Sub-phase; a later Phase also requires the verified
    finalization of the Phase before it. Anything else fails closed with a typed
    :class:`PhaseContextFinalizationError`, publishing nothing.

    Safe to call again. When the finalization is already published (a crash before the
    cursor advanced), the immutable Phase facts are recomputed and must equal it, its
    recorded boundary snapshots are reused, and nothing is rewritten. When the cursor already
    records the Phase complete, its finalization must exist and verify. Invokes no provider.
    """
    if decision.outcome is not PhaseGateVerdict.PASS:
        raise PhaseContextFinalizationError(
            "only a passing gate decision is finalized", PhaseGateRefusal.GATE_NOT_PASSED
        )
    runtime_dir = runtime.runtime_dir
    cursor = _load_cursor(runtime)
    if (decision.project_id, decision.master_plan_digest) != (
        cursor.project_id,
        cursor.master_plan_digest,
    ):
        raise _inconsistent("the gate decision belongs to another plan")
    master = _load_master(runtime)

    if decision.phase_id in cursor.completed_phases:
        existing = load_phase_context_finalization(runtime_dir, decision.phase_id)
        if existing is None:
            raise _inconsistent("a completed phase has no phase finalization")
        _verify_historical(runtime_dir, cursor, existing)
        if existing.previous_phase_finalization != _previous_reference(
            runtime_dir, cursor, master, decision.phase_id
        ):
            raise _inconsistent("the phase finalization disagrees with its previous phase")
        return existing

    facts = _phase_facts(runtime, cursor, master, decision)
    existing = load_phase_context_finalization(runtime_dir, decision.phase_id)
    if existing is not None:
        _require_recorded_digest(runtime, existing.project_digest)
        recorded = facts.model_copy(
            update={
                "project_digest": existing.project_digest,
                "context_selection": existing.context_selection,
            }
        )
        if recorded != existing:
            raise _inconsistent("the recorded phase finalization disagrees with durable state")
        return existing

    built = facts.model_copy(
        update={
            "project_digest": _digest_snapshot(runtime, cursor),
            "context_selection": _selection_snapshot(runtime),
        }
    )
    publish_phase_context_finalization(runtime_dir, built)
    return built


def finalized_phase_references(
    runtime_dir: Path, cursor: ProjectCursor
) -> tuple[tuple[PhaseId, str], ...]:
    """``(phase_id, identity)`` of each completed Phase's verified finalization, in order.

    The compact completed-history view a fresh Planner may receive. Every finalization
    present must load, verify and belong to the cursor's plan; a completed Phase without one
    contributes nothing here (Phase completion itself refuses to build on such a Phase).
    """
    references: list[tuple[PhaseId, str]] = []
    for phase_id in cursor.completed_phases:
        value = load_phase_context_finalization(runtime_dir, phase_id)
        if value is None:
            continue
        if (value.project_id, value.master_plan_digest) != (
            cursor.project_id,
            cursor.master_plan_digest,
        ):
            raise _inconsistent("a phase finalization belongs to another plan")
        references.append((phase_id, phase_context_finalization_identity(value)))
    return tuple(references)


__all__ = [
    "ContextSelectionReference",
    "FinalPhaseGate",
    "FinalizedSubphase",
    "PhaseContextFinalization",
    "PhaseContextFinalizationError",
    "PreviousPhaseFinalization",
    "ProjectCursorReference",
    "canonical_phase_context_finalization_bytes",
    "finalize_phase_context",
    "finalized_phase_references",
    "load_phase_context_finalization",
    "phase_context_finalization_identity",
    "phase_context_finalization_path",
    "publish_phase_context_finalization",
]
