"""Dogfood-04: a durable, actionable human escalation lifecycle.

A structured ``HUMAN_REQUIRED`` blocker becomes a typed durable request *before* the
transaction is durably halted; the operator loads it through a typed API (no grep, no
provider session, no journal ``detail`` parsing), records one bound resolution, and the
same transaction -- and the same autonomous ProjectRun -- continues with an at-most-once,
fresh invocation of the blocked role that receives the original request and the human's
answer as evidence, never as amended scope.

Everything runs the real production code against fake provider executables, a real Git
source repository and the real planning/cursor/run-control stores. No live inference.
"""

from __future__ import annotations

import ast
import json
import shutil
from collections import Counter
from collections.abc import Callable
from dataclasses import replace
from pathlib import Path
from typing import Any

import pytest
from autonomous_run_support import FakeClock, autonomous_project, make_policy, run_autonomous
from phase_gate_support import review_response
from test_project_orchestrator import (
    _impl_response,
    _make_project,
    _Project,
    _review_response,
    _subjects,
)
from test_supervisor_resume_execution import (
    _IMPL_CORRECT,
    _TEST_FILE_RED,
    _git,
    _implementer_blocked_response,
    _implementer_completed_response,
    _invocation_count,
    _planner_authoring_response,
    _planner_decision_response,
    _prepare_scenario,
    _reviewer_turn_blocked_response,
    _reviewer_turn_completed_response,
)
from test_supervisor_resume_execution import _budget as _txn_budget

import lockstep.human_escalation as human_escalation
import lockstep.supervisor.transaction as transaction_module
from lockstep.autonomous_run_control import AutonomousRunDisposition, load_project_run_state
from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    ExecutionEventKind,
    PhaseId,
    RunId,
    StopReason,
    SubphaseContract,
    SubphaseId,
)
from lockstep.escalation import EscalationAuthority, EscalationCategory, EscalationRequest
from lockstep.escalation_decision import PlannerDecisionKind, escalation_request_digest
from lockstep.human_escalation import (
    HumanContinuationStatus,
    HumanEscalationError,
    HumanEscalationRecord,
    HumanRequestReference,
    HumanRequestStatus,
    HumanResolution,
    human_continuation_path,
    human_request_path,
    human_resolution_path,
    inspect_human_escalation,
    load_human_continuation,
    load_pending_human_request,
    record_human_resolution,
)
from lockstep.persistence import ExecutionEvent, StateTransitionedEvent, read_events
from lockstep.project_orchestrator import ProjectRunDisposition, TransactionPlacement
from lockstep.reporting.audit import build_project_audit
from lockstep.state import WorkflowState
from lockstep.supervisor.escalation import SupervisorEscalationDisposition
from lockstep.supervisor.transaction import (
    HumanContinuationDisposition,
    ImplementerBlockedTransactionResult,
    ResumeExecutionDisposition,
    RetryCheckpointedTransactionResult,
    SingleSubphaseTransactionRequest,
    continue_human_escalation,
    resume_single_subphase_transaction,
    run_single_subphase_transaction_with_retry_checkpoint,
)

_SRC = Path(__file__).resolve().parent.parent / "src" / "lockstep"
_QUESTION = "May Lockstep perform one authenticated GET against the vendor sandbox?"
_EVIDENCE = (
    "The frozen test fixture needs one recorded sandbox response.",
    "The request is read-only but leaves the local network.",
)
_ANSWER = "HUMAN-ANSWER-SENTINEL: the recorded response is now at fixtures/sandbox.json."
_OPERATOR_EVIDENCE = ("OPERATOR-EVIDENCE-SENTINEL: captured on 2031-01-01 by the operator.",)
_STDERR = "PROVIDER-STDERR-SENTINEL raw transcript that must never be persisted"


class _CrashError(Exception):
    """Simulated process death at an exact point."""


# ---------------------------------------------------------------------------
# Scenario construction
# ---------------------------------------------------------------------------


def _blocked(
    category: EscalationCategory = EscalationCategory.EXTERNAL_SIDE_EFFECT_REQUIRED,
    *,
    requested: EscalationAuthority = EscalationAuthority.HUMAN,
    files: dict[str, str] | None = None,
) -> dict[str, object]:
    return _implementer_blocked_response(
        category=category,
        question=_QUESTION,
        evidence=_EVIDENCE,
        requested_authority=requested,
        stderr=_STDERR,
        files=files,
    )


def _reviewer_blocked(
    category: EscalationCategory = EscalationCategory.REQUIREMENT_AMBIGUITY,
) -> dict[str, object]:
    return _reviewer_turn_blocked_response(
        category=category,
        question=_QUESTION,
        evidence=_EVIDENCE,
        requested_authority=EscalationAuthority.HUMAN,
        stderr=_STDERR,
    )


def _implementer_human_project(
    tmp_path: Path,
    *,
    implementer: list[dict[str, object]] | None = None,
    reviewer: list[dict[str, object]] | None = None,
    planner: list[dict[str, object]] | None = None,
) -> _Project:
    """One Sub-phase whose first Implementer turn needs a human; the next one completes."""
    return _make_project(
        tmp_path,
        sids=("01",),
        planner=planner,
        implementer=(
            implementer if implementer is not None else [_blocked(), _impl_response("01")]
        ),
        reviewer=reviewer if reviewer is not None else [_review_response("01")],
    )


def _with_contract(project: _Project) -> _Project:
    """The same project, but every transaction request carries its frozen Contract."""
    base = project.factory

    def build(
        contract: SubphaseContract, placement: TransactionPlacement
    ) -> SingleSubphaseTransactionRequest:
        return replace(base(contract, placement), contract=contract)

    return replace(project, factory=build)


def _request(project: _Project, sid: str = "01") -> SingleSubphaseTransactionRequest:
    cursor = project.cursor()
    assert cursor.active_contract is not None
    from lockstep.planning_store import load_active_subphase_contract
    from lockstep.project_orchestrator import _placement

    contract = load_active_subphase_contract(project.project_root, project.runtime_dir)
    assert contract is not None
    return project.factory(contract, _placement(project.runtime_dir, cursor, project.run_id(sid)))


def _txn_runtime(project: _Project, request: SingleSubphaseTransactionRequest) -> Any:
    return replace(project.runtime, runtime_dir=request.runtime_dir)


def _resolve(project: _Project, sid: str = "01", **overrides: Any) -> HumanResolution:
    pending = load_pending_human_request(project.txn_dir(sid))
    assert pending is not None
    ref = pending.reference
    arguments: dict[str, Any] = {
        "run_id": ref.run_id,
        "phase_id": ref.phase_id,
        "subphase_id": ref.subphase_id,
        "attempt": ref.attempt,
        "ordinal": ref.ordinal,
        "request_digest": ref.request_digest,
        "answer": _ANSWER,
        "evidence": _OPERATOR_EVIDENCE,
        "resolved_by": "operator@example.test",
    }
    arguments.update(overrides)
    return record_human_resolution(project.txn_dir(sid), **arguments)


def _events(project: _Project, sid: str = "01") -> list[ExecutionEvent]:
    return [
        e
        for e in read_events(project.txn_dir(sid) / "events.jsonl")
        if isinstance(e, ExecutionEvent)
    ]


def _kinds(project: _Project, sid: str = "01") -> Counter[ExecutionEventKind]:
    return Counter(e.kind for e in _events(project, sid))


def _human_dir(project: _Project, sid: str = "01", attempt: int = 1) -> Path:
    return project.txn_dir(sid) / "artifacts" / f"attempt-{attempt}" / "human"


def _capture_prompts(monkeypatch: pytest.MonkeyPatch, name: str) -> list[str]:
    original = getattr(transaction_module, name)
    prompts: list[str] = []

    def spy(*args: Any, **kwargs: Any) -> Any:
        prompts.append(kwargs["prompt"])
        return original(*args, **kwargs)

    monkeypatch.setattr(transaction_module, name, spy)
    return prompts


def _crash_once(
    monkeypatch: pytest.MonkeyPatch,
    module: Any,
    name: str,
    *,
    when: Callable[..., bool] = lambda *a, **k: True,
) -> list[bool]:
    original = getattr(module, name)
    fired: list[bool] = []

    def patched(*args: Any, **kwargs: Any) -> Any:
        if not fired and when(*args, **kwargs):
            fired.append(True)
            raise _CrashError
        return original(*args, **kwargs)

    monkeypatch.setattr(module, name, patched)
    return fired


# ===========================================================================
# 1-3, 5: the request is persisted, exact, typed, before HALTED, and loadable
# ===========================================================================


def test_an_implementer_human_blocker_persists_the_exact_typed_request(tmp_path: Path) -> None:
    project = _implementer_human_project(tmp_path)

    result = project.run()

    assert result.disposition is ProjectRunDisposition.HUMAN_REQUIRED
    pending = load_pending_human_request(project.txn_dir("01"))
    assert pending is not None
    assert pending.status is HumanRequestStatus.AWAITING_RESOLUTION
    record = pending.record
    assert record.request == EscalationRequest(
        source_role=AgentRole.IMPLEMENTER,
        phase_id=PhaseId.model_validate("01"),
        subphase_id=SubphaseId.model_validate("01"),
        attempt=AttemptNumber.model_validate(1),
        category=EscalationCategory.EXTERNAL_SIDE_EFFECT_REQUIRED,
        question=_QUESTION,
        evidence=_EVIDENCE,
        requested_authority=EscalationAuthority.HUMAN,
    )
    assert record.request_digest == escalation_request_digest(record.request)
    assert record.run_id == project.run_id("01")
    assert record.ordinal == 1
    assert record.planner_decision is None
    assert record.retry_checkpoint is None

    # The frozen test commit the transaction recorded, and the untouched basis on top of it.
    frozen = [e.detail for e in _events(project) if e.kind is ExecutionEventKind.TESTS_FROZEN]
    assert [record.frozen_test_commit] == frozen
    assert record.worktree_head == frozen[0]
    assert record.dirty_paths == ()

    path = human_request_path(project.txn_dir("01"), record.request.attempt, 1)
    assert path == _human_dir(project) / "request-1.json"
    raw = path.read_text(encoding="utf-8")
    assert _STDERR not in raw  # never raw provider output
    assert HumanEscalationRecord.model_validate_json(raw) == record


def test_a_reviewer_human_blocker_uses_the_same_mechanism(tmp_path: Path) -> None:
    project = _implementer_human_project(
        tmp_path,
        implementer=[_impl_response("01")],
        reviewer=[_reviewer_blocked(), _review_response("01")],
    )

    result = project.run()

    assert result.disposition is ProjectRunDisposition.HUMAN_REQUIRED
    pending = load_pending_human_request(project.txn_dir("01"))
    assert pending is not None
    request = pending.record.request
    assert request.source_role is AgentRole.REVIEWER
    assert request.category is EscalationCategory.REQUIREMENT_AMBIGUITY
    assert (request.question, request.evidence) == (_QUESTION, _EVIDENCE)
    # The Implementer's verified, uncommitted work is the basis the Reviewer must judge.
    assert pending.record.dirty_paths == ("feature_01.py",)
    assert project.state("01") is WorkflowState.HALTED


def _transaction_scenario(
    tmp_path: Path,
    *,
    implementer: list[dict[str, object]],
    planner_decision: dict[str, object] | None = None,
    reviewer: list[dict[str, object]] | None = None,
) -> Any:
    """A transaction-level scenario whose runtime directory also holds the planning store.

    Planner-routed escalations are exercised here: inside an orchestrated run the transaction
    runtime is rebound away from the project's planning store, so the Planner decision
    transport cannot reach the Planner there (a pre-existing limitation, see the dogfood-04
    retro).
    """
    planner = [_planner_authoring_response(_TEST_FILE_RED)]
    if planner_decision is not None:
        planner.append(planner_decision)
    return _prepare_scenario(
        tmp_path / "txn",
        planner_responses=planner,
        implementer_responses=implementer,
        reviewer_responses=reviewer,
    )


def _blocked_transaction(scenario: Any) -> Any:
    return run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_txn_budget(3)
    )


def test_a_planner_halt_for_human_records_the_request_and_the_planner_decision(
    tmp_path: Path,
) -> None:
    scenario = _transaction_scenario(
        tmp_path,
        implementer=[
            _blocked(
                EscalationCategory.ARCHITECTURE_CONFLICT, requested=EscalationAuthority.PLANNER
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
        planner_decision=_planner_decision_response(
            kind=PlannerDecisionKind.HALT_FOR_HUMAN,
            rationale="Only the product owner can choose between the two architectures.",
        ),
    )

    result = _blocked_transaction(scenario)

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert result.escalation.disposition is SupervisorEscalationDisposition.HUMAN_REQUIRED
    runtime_dir = scenario.request.runtime_dir
    pending = load_pending_human_request(runtime_dir)
    assert pending is not None
    decision = pending.record.planner_decision
    assert decision is not None and decision.kind is PlannerDecisionKind.HALT_FOR_HUMAN
    assert decision.request_digest == pending.record.request_digest
    assert pending.record.retry_budget == _txn_budget(3)

    # The same lifecycle at the transaction API: answer it, then continue exactly once.
    ref = pending.reference
    record_human_resolution(
        runtime_dir,
        run_id=ref.run_id,
        phase_id=ref.phase_id,
        subphase_id=ref.subphase_id,
        attempt=ref.attempt,
        ordinal=ref.ordinal,
        request_digest=ref.request_digest,
        answer=_ANSWER,
        resolved_by="operator@example.test",
    )
    continued = continue_human_escalation(scenario.request, agent_turn_runtime=scenario.runtime)

    assert continued.disposition is HumanContinuationDisposition.SETTLED
    assert continued.final_state is not None
    assert continued.final_state.workflow_state is WorkflowState.SUBPHASE_COMPLETE
    again = continue_human_escalation(scenario.request, agent_turn_runtime=scenario.runtime)
    assert again.disposition is HumanContinuationDisposition.NO_HUMAN_REQUEST
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 2


def test_the_request_is_durable_before_the_transaction_is_durably_halted(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _implementer_human_project(tmp_path)
    original = transaction_module._persist_transition
    seen: list[bool] = []

    def spy(**kwargs: Any) -> None:
        if kwargs["target"] is WorkflowState.HALTED:
            seen.append((_human_dir(project) / "request-1.json").exists())
        original(**kwargs)

    monkeypatch.setattr(transaction_module, "_persist_transition", spy)

    project.run()

    assert seen == [True]
    events = read_events(project.txn_dir("01") / "events.jsonl")
    recorded = next(
        e.sequence
        for e in events
        if isinstance(e, ExecutionEvent) and e.kind is ExecutionEventKind.HUMAN_REQUEST_RECORDED
    )
    halted = next(
        e.sequence
        for e in events
        if isinstance(e, StateTransitionedEvent) and e.target is WorkflowState.HALTED
    )
    assert recorded < halted


def test_a_crash_between_request_persistence_and_halt_recovers_without_relaunch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _implementer_human_project(tmp_path)
    fired = _crash_once(
        monkeypatch,
        transaction_module,
        "_persist_transition",
        when=lambda **kwargs: kwargs["target"] is WorkflowState.HALTED,
    )

    with pytest.raises(_CrashError):
        project.run()

    assert fired == [True]
    assert project.state("01") is WorkflowState.IMPLEMENTING
    assert (_human_dir(project) / "request-1.json").exists()
    before = project.counts()

    again = project.run()

    assert again.disposition is ProjectRunDisposition.HUMAN_REQUIRED
    assert project.state("01") is WorkflowState.HALTED
    assert project.counts() == before  # nothing relaunched
    assert _kinds(project)[ExecutionEventKind.TRANSACTION_HALTED] == 1
    pending = load_pending_human_request(project.txn_dir("01"))
    assert pending is not None and pending.record.request.question == _QUESTION


def test_the_request_loads_from_disk_alone_with_no_provider_or_session(tmp_path: Path) -> None:
    project = _implementer_human_project(tmp_path)
    result = project.run()
    for bins in project.bins.values():
        shutil.rmtree(bins)  # no provider, no session, nothing to recover from

    pending = load_pending_human_request(project.txn_dir("01"))

    assert pending is not None
    reference = pending.reference
    assert isinstance(reference, HumanRequestReference)
    assert reference.run_id == project.run_id("01")
    assert (reference.attempt.root, reference.ordinal) == (1, 1)
    assert reference.source_role is AgentRole.IMPLEMENTER
    assert reference.category is EscalationCategory.EXTERNAL_SIDE_EFFECT_REQUIRED
    assert reference.artifact == "artifacts/attempt-1/human/request-1.json"
    assert result.human_request == reference
    # The run result is actionable, bounded, and never carries the agent's prose.
    assert result.detail is not None
    assert reference.request_digest in result.detail
    assert _QUESTION not in result.detail and len(result.detail) <= 512


# ===========================================================================
# 6-9: one bound, operator-authored resolution
# ===========================================================================


def test_a_correctly_bound_resolution_is_accepted_and_journaled_by_identity(
    tmp_path: Path,
) -> None:
    project = _implementer_human_project(tmp_path)
    project.run()

    resolution = _resolve(project)

    assert resolution.answer == _ANSWER and resolution.evidence == _OPERATOR_EVIDENCE
    path = human_resolution_path(project.txn_dir("01"), AttemptNumber.model_validate(1), 1)
    assert HumanResolution.model_validate_json(path.read_text(encoding="utf-8")) == resolution
    inspection = inspect_human_escalation(project.txn_dir("01"))
    assert inspection is not None and inspection.status is HumanRequestStatus.RESOLVED
    assert load_pending_human_request(project.txn_dir("01")) is None  # no longer awaiting
    assert _kinds(project)[ExecutionEventKind.HUMAN_RESOLUTION_RECORDED] == 1
    journal = (project.txn_dir("01") / "events.jsonl").read_text(encoding="utf-8")
    assert "HUMAN-ANSWER-SENTINEL" not in journal
    assert "OPERATOR-EVIDENCE-SENTINEL" not in journal


@pytest.mark.parametrize(
    ("field", "value"),
    [
        ("run_id", RunId.model_validate("run-01-99")),
        ("phase_id", PhaseId.model_validate("02")),
        ("subphase_id", SubphaseId.model_validate("02")),
        ("attempt", AttemptNumber.model_validate(2)),
        ("ordinal", 2),
        ("request_digest", "0" * 64),
    ],
)
def test_a_resolution_bound_to_anything_else_is_refused(
    tmp_path: Path, field: str, value: object
) -> None:
    project = _implementer_human_project(tmp_path)
    project.run()

    with pytest.raises(HumanEscalationError):
        _resolve(project, **{field: value})

    assert not human_resolution_path(
        project.txn_dir("01"), AttemptNumber.model_validate(1), 1
    ).exists()
    pending = load_pending_human_request(project.txn_dir("01"))
    assert pending is not None and pending.status is HumanRequestStatus.AWAITING_RESOLUTION


def test_a_duplicate_or_conflicting_resolution_is_refused_deterministically(
    tmp_path: Path,
) -> None:
    project = _implementer_human_project(tmp_path)
    project.run()
    first = _resolve(project)
    path = human_resolution_path(project.txn_dir("01"), AttemptNumber.model_validate(1), 1)
    stored = path.read_bytes()

    for answer in (_ANSWER, "A different answer."):
        with pytest.raises(HumanEscalationError, match="already recorded"):
            record_human_resolution(
                project.txn_dir("01"),
                run_id=first.run_id,
                phase_id=first.phase_id,
                subphase_id=first.subphase_id,
                attempt=first.attempt,
                ordinal=first.ordinal,
                request_digest=first.request_digest,
                answer=answer,
                evidence=_OPERATOR_EVIDENCE,
                resolved_by="operator@example.test",
            )

    assert path.read_bytes() == stored
    assert HumanResolution.model_validate_json(stored) == first
    assert _kinds(project)[ExecutionEventKind.HUMAN_RESOLUTION_RECORDED] == 1


@pytest.mark.parametrize(
    "extra",
    [
        {"allowed_paths": ["other.py"]},
        {"authorized_paths": ["tests/test_feature_01.py"]},
        {"test_paths": []},
        {"retry_budget": {"max_attempts": 9}},
        {"contract": {}},
        {"master_plan": {}},
        {"routing": "planner"},
    ],
)
def test_a_resolution_cannot_carry_scope_plan_test_budget_or_routing(
    tmp_path: Path, extra: dict[str, object]
) -> None:
    project = _implementer_human_project(tmp_path)
    project.run()
    resolution = _resolve(project)
    payload = {**resolution.model_dump(mode="json"), **extra}

    with pytest.raises(ValueError, match="Extra inputs are not permitted"):
        HumanResolution.model_validate(payload)


def test_runtime_code_never_creates_operator_authority(tmp_path: Path) -> None:
    project = _implementer_human_project(tmp_path)
    first = project.run()
    before = project.counts()

    for _ in range(3):
        again = project.run()
        assert again.disposition is ProjectRunDisposition.HUMAN_REQUIRED
    assert project.counts() == before
    assert sorted(p.name for p in _human_dir(project).iterdir()) == ["request-1.json"]
    assert first.human_request == again.human_request

    # Statically: only the operator API in lockstep.human_escalation records a resolution.
    for module in sorted(_SRC.rglob("*.py")):
        tree = ast.parse(module.read_text(encoding="utf-8"))
        named = {
            node.id if isinstance(node, ast.Name) else node.attr
            for node in ast.walk(tree)
            if isinstance(node, ast.Name | ast.Attribute)
        }
        if module.name == "human_escalation.py":
            continue
        assert "record_human_resolution" not in named, module
        assert "HumanResolution" not in named or module.name == "transaction.py", module
        assert "_write_resolution" not in named, module


def test_a_planted_resolution_that_does_not_bind_is_never_consumed(tmp_path: Path) -> None:
    project = _implementer_human_project(tmp_path)
    project.run()
    good = _resolve(project)
    path = human_resolution_path(project.txn_dir("01"), AttemptNumber.model_validate(1), 1)
    forged = good.model_copy(update={"request_digest": "f" * 64})
    path.write_text(json.dumps(forged.model_dump(mode="json")), encoding="utf-8")
    before = project.counts()

    with pytest.raises(HumanEscalationError):
        inspect_human_escalation(project.txn_dir("01"))
    with pytest.raises(HumanEscalationError):
        project.run()

    assert project.counts() == before
    assert not human_continuation_path(
        project.txn_dir("01"), AttemptNumber.model_validate(1), 1
    ).exists()


# ===========================================================================
# 10-14: controlled, fresh, at-most-once re-entry of the blocked role
# ===========================================================================


def test_reentry_receives_the_original_request_and_the_human_resolution(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _with_contract(_implementer_human_project(tmp_path))
    project.run()
    _resolve(project)
    prompts = _capture_prompts(monkeypatch, "invoke_implementer_turn")

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert len(prompts) == 1
    prompt = prompts[0]
    assert prompt.startswith("implement feature 01")
    # The original frozen transaction authority, unchanged.
    assert "FROZEN REQUIREMENT AUTHORITY" in prompt
    assert "PROTECTED ACCEPTANCE ARTIFACT" in prompt
    # The original structured request and the human's answer, labelled as evidence.
    for text in (_QUESTION, *_EVIDENCE, _ANSWER, *_OPERATOR_EVIDENCE):
        assert json.dumps(text)[1:-1] in prompt
    assert "HUMAN ESCALATION ANSWER" in prompt
    assert "not amended scope" in prompt
    assert prompt.index("FROZEN REQUIREMENT AUTHORITY") < prompt.index("HUMAN ESCALATION ANSWER")


def test_reentry_is_a_fresh_invocation_of_the_same_attempt(tmp_path: Path) -> None:
    project = _implementer_human_project(tmp_path)
    project.run()
    _resolve(project)

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert project.counts() == (2, 2, 1)
    implementer_starts = [
        e
        for e in _events(project)
        if e.kind is ExecutionEventKind.INVOCATION_STARTED and e.role is AgentRole.IMPLEMENTER
    ]
    assert [e.attempt.root for e in implementer_starts if e.attempt] == [1, 1]
    assert len({e.invocation_id for e in implementer_starts}) == 2
    kinds = _kinds(project)
    assert kinds[ExecutionEventKind.HUMAN_CONTINUATION_STARTED] == 1
    assert kinds[ExecutionEventKind.HUMAN_CONTINUATION_SETTLED] == 1
    assert kinds[ExecutionEventKind.RESUME_STARTED] == 0  # not a retry: no budget consumed
    assert kinds[ExecutionEventKind.RETRY_AUTHORIZED] == 0
    continuation = load_human_continuation(
        project.txn_dir("01"), AttemptNumber.model_validate(1), 1
    )
    assert continuation is not None and continuation.status is HumanContinuationStatus.SETTLED


def test_reentry_preserves_the_frozen_tests_and_the_production_scope(tmp_path: Path) -> None:
    project = _implementer_human_project(tmp_path)
    project.run()
    record = load_pending_human_request(project.txn_dir("01"))
    assert record is not None
    frozen = record.record.frozen_test_commit
    _resolve(project)

    project.run()

    worktree = project.worktree("01")
    assert _subjects(worktree)[:2] == [
        "feat(feature-01): implement answer",
        "test(feature-01): freeze answer expectation",
    ]
    assert _git(worktree, "rev-parse", "HEAD~1").stdout.strip() == frozen
    changed = _git(worktree, "diff-tree", "--no-commit-id", "--name-only", "-r", "HEAD")
    assert changed.stdout.split() == ["feature_01.py"]


def test_a_continuation_that_touches_a_frozen_test_is_refused(tmp_path: Path) -> None:
    tampering = _implementer_completed_response(
        {"feature_01.py": "def answer() -> int:\n    return 1\n", "tests/test_feature_01.py": "x"}
    )
    project = _implementer_human_project(tmp_path, implementer=[_blocked(), tampering])
    project.run()
    record = load_pending_human_request(project.txn_dir("01"))
    assert record is not None
    _resolve(project)

    result = project.run()

    assert result.disposition is ProjectRunDisposition.EXECUTION_FAILED
    aborted = [e for e in _events(project) if e.kind is ExecutionEventKind.TRANSACTION_ABORTED]
    assert [e.stop_reason for e in aborted] == [StopReason.PROTECTED_ARTIFACT_CHANGED]
    assert _git(project.worktree("01"), "rev-parse", "HEAD").stdout.strip() == (
        record.record.frozen_test_commit
    )
    assert project.cursor().completed_subphases == ()


def test_a_drifted_basis_is_refused_before_anything_launches(tmp_path: Path) -> None:
    project = _implementer_human_project(tmp_path)
    project.run()
    _resolve(project)
    (project.worktree("01") / "stray.py").write_text("x = 1\n", encoding="utf-8")
    before = project.counts()

    result = project.run()

    assert result.disposition is ProjectRunDisposition.RECOVERY_REQUIRED
    assert result.detail is not None and "basis" in result.detail
    assert project.counts() == before
    assert not human_continuation_path(
        project.txn_dir("01"), AttemptNumber.model_validate(1), 1
    ).exists()


def test_a_crash_after_the_continuation_started_is_never_replayed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _implementer_human_project(tmp_path)
    project.run()
    _resolve(project)
    _crash_once(monkeypatch, transaction_module, "invoke_implementer_turn")

    with pytest.raises(_CrashError):
        project.run()

    continuation = load_human_continuation(
        project.txn_dir("01"), AttemptNumber.model_validate(1), 1
    )
    assert continuation is not None and continuation.status is HumanContinuationStatus.STARTED
    monkeypatch.undo()
    before = project.counts()

    for _ in range(2):
        again = project.run()
        assert again.disposition is ProjectRunDisposition.RECOVERY_REQUIRED
    assert project.counts() == before
    assert _kinds(project)[ExecutionEventKind.HUMAN_CONTINUATION_STARTED] == 1


def test_a_crash_after_the_claim_but_before_the_start_launches_exactly_once(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _implementer_human_project(tmp_path)
    project.run()
    _resolve(project)
    _crash_once(monkeypatch, human_escalation, "mark_human_continuation_started")

    with pytest.raises(_CrashError):
        project.run()

    continuation = load_human_continuation(
        project.txn_dir("01"), AttemptNumber.model_validate(1), 1
    )
    assert continuation is not None and continuation.status is HumanContinuationStatus.CLAIMED
    assert project.counts() == (2, 1, 0)

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert project.counts() == (2, 2, 1)


def test_the_continuation_runs_at_most_once_per_resolution(tmp_path: Path) -> None:
    project = _implementer_human_project(
        tmp_path, implementer=[_blocked(), _blocked(EscalationCategory.REQUIREMENT_AMBIGUITY)]
    )
    project.run()
    _resolve(project)
    request = _request(project)
    runtime = _txn_runtime(project, request)

    first = continue_human_escalation(request, agent_turn_runtime=runtime)
    second = continue_human_escalation(request, agent_turn_runtime=runtime)

    assert first.disposition is HumanContinuationDisposition.SETTLED
    # The continuation itself needed a human again: a new, second request awaits an answer.
    assert second.disposition is HumanContinuationDisposition.AWAITING_RESOLUTION
    assert project.counts() == (2, 2, 0)
    pending = load_pending_human_request(project.txn_dir("01"))
    assert pending is not None and pending.record.ordinal == 2
    assert pending.record.request.category is EscalationCategory.REQUIREMENT_AMBIGUITY
    settled = load_human_continuation(project.txn_dir("01"), AttemptNumber.model_validate(1), 1)
    assert settled is not None and settled.status is HumanContinuationStatus.SETTLED


def test_a_reviewer_continuation_reenters_the_reviewer_with_the_answer(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _implementer_human_project(
        tmp_path,
        implementer=[_impl_response("01")],
        reviewer=[_reviewer_blocked(), _review_response("01")],
    )
    project.run()
    _resolve(project)
    prompts = _capture_prompts(monkeypatch, "invoke_reviewer_turn")

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert project.counts() == (2, 1, 2)
    assert len(prompts) == 1 and json.dumps(_ANSWER)[1:-1] in prompts[0]
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == ["01"]


# ===========================================================================
# 9, 14-16: the same autonomous ProjectRun waits, then continues; legacy fails closed
# ===========================================================================


def _autonomous_human_project(tmp_path: Path) -> Any:
    return autonomous_project(
        tmp_path,
        phases={"01": ("01", "02")},
        implementer=[_impl_response("01"), _blocked(), _impl_response("02")],
        reviewer=[review_response("01", "01"), review_response("01", "02")],
    )


def _resolve_dir(txn_dir: Path) -> HumanResolution:
    pending = load_pending_human_request(txn_dir)
    assert pending is not None
    ref = pending.reference
    return record_human_resolution(
        txn_dir,
        run_id=ref.run_id,
        phase_id=ref.phase_id,
        subphase_id=ref.subphase_id,
        attempt=ref.attempt,
        ordinal=ref.ordinal,
        request_digest=ref.request_digest,
        answer=_ANSWER,
        resolved_by="operator@example.test",
    )


def test_the_same_project_run_waits_for_and_then_consumes_the_resolution(
    tmp_path: Path,
) -> None:
    project = _autonomous_human_project(tmp_path)
    clock = FakeClock()
    policy = make_policy()

    first = run_autonomous(project, policy, clock=clock)

    assert first.disposition is AutonomousRunDisposition.HUMAN_REQUIRED
    assert first.human_request is not None
    assert first.human_request.run_id == project.run_id("01", "02")
    assert first.detail is not None and first.human_request.request_digest in first.detail
    before = project.counts()

    # Until a resolution exists the same run keeps answering HUMAN_REQUIRED, launching nothing.
    waiting = run_autonomous(project, policy, clock=clock, project_run_id=first.project_run_id)
    assert waiting.disposition is AutonomousRunDisposition.HUMAN_REQUIRED
    assert waiting.human_request == first.human_request
    assert project.counts() == before

    _resolve_dir(project.txn_dir("01", "02"))
    done = run_autonomous(project, policy, clock=clock, project_run_id=first.project_run_id)

    assert done.disposition is AutonomousRunDisposition.PROJECT_COMPLETE
    assert done.project_run_id == first.project_run_id
    state = load_project_run_state(project.runtime_dir, first.project_run_id)
    assert [(r.phase_id.root, r.subphase_id.root) for r in state.reservations] == [
        ("01", "01"),
        ("01", "02"),
    ]
    assert project.counts()[1:] == (3, 2)


def test_a_legacy_human_halt_without_a_request_fails_closed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _autonomous_human_project(tmp_path)
    clock = FakeClock()
    policy = make_policy()
    # The pre-dogfood-04 runtime: the request existed only in memory and was discarded.
    monkeypatch.setattr(transaction_module, "_persist_human_request", lambda *a, **k: None)
    first = run_autonomous(project, policy, clock=clock)
    # Even within the call that halted, a human halt with no durable request fails closed.
    assert first.disposition is AutonomousRunDisposition.RECOVERY_REQUIRED
    assert first.escalation_disposition is SupervisorEscalationDisposition.HUMAN_REQUIRED
    monkeypatch.undo()
    txn = project.txn_dir("01", "02")
    assert not (txn / "artifacts" / "attempt-1" / "human").exists()
    before = project.counts()

    again = run_autonomous(project, policy, clock=clock, project_run_id=first.project_run_id)

    assert again.disposition is AutonomousRunDisposition.RECOVERY_REQUIRED
    assert again.child_disposition is ProjectRunDisposition.RECOVERY_REQUIRED
    assert again.escalation_disposition is SupervisorEscalationDisposition.HUMAN_REQUIRED
    assert again.human_request is None
    assert again.detail is not None and "no durable human request" in again.detail
    assert project.counts() == before  # the blocked agent is never rerun
    assert inspect_human_escalation(txn) is None  # nothing synthesized
    assert not (txn / "artifacts" / "attempt-1" / "human").exists()
    with pytest.raises(HumanEscalationError):
        record_human_resolution(
            txn,
            run_id=project.run_id("01", "02"),
            phase_id=PhaseId.model_validate("01"),
            subphase_id=SubphaseId.model_validate("02"),
            attempt=AttemptNumber.model_validate(1),
            ordinal=1,
            request_digest="0" * 64,
            answer="An answer to a question nobody can read.",
            resolved_by="operator@example.test",
        )


# ===========================================================================
# 17-18: retryable and non-human escalations are unchanged and acquire no human authority
# ===========================================================================


def _no_human_artifacts(runtime_dir: Path) -> None:
    kinds = Counter(
        e.kind for e in read_events(runtime_dir / "events.jsonl") if isinstance(e, ExecutionEvent)
    )
    for kind in (
        ExecutionEventKind.HUMAN_REQUEST_RECORDED,
        ExecutionEventKind.HUMAN_RESOLUTION_RECORDED,
        ExecutionEventKind.HUMAN_CONTINUATION_STARTED,
        ExecutionEventKind.HUMAN_CONTINUATION_SETTLED,
    ):
        assert kinds[kind] == 0
    assert inspect_human_escalation(runtime_dir) is None
    assert load_pending_human_request(runtime_dir) is None


def test_a_retryable_escalation_still_resumes_through_the_retry_checkpoint(
    tmp_path: Path,
) -> None:
    scenario = _transaction_scenario(
        tmp_path,
        implementer=[
            _blocked(
                EscalationCategory.ARCHITECTURE_CONFLICT, requested=EscalationAuthority.PLANNER
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
        planner_decision=_planner_decision_response(
            kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE
        ),
        reviewer=[_reviewer_turn_completed_response(attempt=2)],
    )

    result = _blocked_transaction(scenario)

    assert isinstance(result, RetryCheckpointedTransactionResult)
    resumed = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert resumed.disposition is ResumeExecutionDisposition.SETTLED
    assert resumed.final_state is not None
    assert resumed.final_state.workflow_state is WorkflowState.SUBPHASE_COMPLETE
    _no_human_artifacts(scenario.request.runtime_dir)


def _refuse_any_resolution(runtime_dir: Path, run_id: RunId, phase: str, sid: str) -> None:
    with pytest.raises(HumanEscalationError):
        record_human_resolution(
            runtime_dir,
            run_id=run_id,
            phase_id=PhaseId.model_validate(phase),
            subphase_id=SubphaseId.model_validate(sid),
            attempt=AttemptNumber.model_validate(1),
            ordinal=1,
            request_digest="0" * 64,
            answer="Go ahead.",
            resolved_by="operator@example.test",
        )


def test_a_supervisor_routed_halt_acquires_no_human_authority(tmp_path: Path) -> None:
    project = _implementer_human_project(
        tmp_path,
        implementer=[
            _blocked(
                EscalationCategory.CONTROL_PLANE_BLOCKER, requested=EscalationAuthority.SUPERVISOR
            )
        ],
    )

    result = project.run()

    assert result.disposition is ProjectRunDisposition.HALTED
    assert (
        result.escalation_disposition is SupervisorEscalationDisposition.SUPERVISOR_ACTION_REQUIRED
    )
    assert result.human_request is None
    _no_human_artifacts(project.txn_dir("01"))
    _refuse_any_resolution(project.txn_dir("01"), project.run_id("01"), "01", "01")


@pytest.mark.parametrize(
    ("category", "planner_kind", "escalation"),
    [
        (
            EscalationCategory.PLANNER_DECISION_REQUIRED,
            PlannerDecisionKind.REPLAN_SUBPHASE,
            SupervisorEscalationDisposition.REPLAN_SUBPHASE,
        ),
        (
            EscalationCategory.TEST_DEFECT,
            PlannerDecisionKind.TERMINAL_HALT,
            SupervisorEscalationDisposition.RUN_HALT,
        ),
    ],
)
def test_planner_replan_and_run_halt_acquire_no_human_authority(
    tmp_path: Path,
    category: EscalationCategory,
    planner_kind: PlannerDecisionKind,
    escalation: SupervisorEscalationDisposition,
) -> None:
    scenario = _transaction_scenario(
        tmp_path,
        implementer=[_blocked(category, requested=EscalationAuthority.PLANNER)],
        planner_decision=_planner_decision_response(kind=planner_kind),
    )

    result = _blocked_transaction(scenario)

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert result.escalation.disposition is escalation
    runtime_dir = scenario.request.runtime_dir
    _no_human_artifacts(runtime_dir)
    _refuse_any_resolution(runtime_dir, scenario.request.run_id, "09", "13")
    continued = continue_human_escalation(scenario.request, agent_turn_runtime=scenario.runtime)
    assert continued.disposition is HumanContinuationDisposition.NO_HUMAN_REQUEST
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1


def test_a_record_cannot_be_built_for_a_request_that_does_not_need_a_human(
    tmp_path: Path,
) -> None:
    project = _implementer_human_project(tmp_path)
    project.run()
    pending = load_pending_human_request(project.txn_dir("01"))
    assert pending is not None
    payload = pending.record.model_dump(mode="json")
    supervisor_request = pending.record.request.model_copy(
        update={"category": EscalationCategory.CONTROL_PLANE_BLOCKER}
    )
    payload["request"] = supervisor_request.model_dump(mode="json")
    payload["request_digest"] = escalation_request_digest(supervisor_request)

    with pytest.raises(ValueError, match="human"):
        HumanEscalationRecord.model_validate(payload)

    tampered = pending.record.model_dump(mode="json")
    tampered["request_digest"] = "0" * 64
    with pytest.raises(ValueError, match="digest"):
        HumanEscalationRecord.model_validate(tampered)


# ===========================================================================
# Evidence / reporting
# ===========================================================================


def test_audit_distinguishes_every_step_of_the_human_lifecycle(tmp_path: Path) -> None:
    project = _implementer_human_project(tmp_path)
    project.run()
    _resolve(project)
    project.run()

    events = _events(project)
    order = [
        e.kind
        for e in events
        if e.kind
        in (
            ExecutionEventKind.HUMAN_REQUEST_RECORDED,
            ExecutionEventKind.HUMAN_RESOLUTION_RECORDED,
            ExecutionEventKind.HUMAN_CONTINUATION_STARTED,
            ExecutionEventKind.HUMAN_CONTINUATION_SETTLED,
        )
    ]
    assert order == [
        ExecutionEventKind.HUMAN_REQUEST_RECORDED,
        ExecutionEventKind.HUMAN_RESOLUTION_RECORDED,
        ExecutionEventKind.HUMAN_CONTINUATION_STARTED,
        ExecutionEventKind.HUMAN_CONTINUATION_SETTLED,
    ]
    for event in events:
        assert event.detail is None or len(event.detail) <= 128
        assert event.detail is None or "SENTINEL" not in event.detail

    audit = build_project_audit(project.project_root, project.runtime_dir)
    (row,) = audit.subphases
    lifecycle = row.human_escalation
    assert (
        lifecycle.requested,
        lifecycle.resolved,
        lifecycle.continuations_started,
        lifecycle.continuations_settled,
    ) == (1, 1, 1, 1)
