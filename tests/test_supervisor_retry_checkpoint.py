"""Planner-authored specification of Sub-phase 9.10 transaction retry checkpoint integration.

Pins the one additive, provider-neutral production path that integrates the
frozen Sub-phase 9.8 attempt-state/retry-budget protocol
(:mod:`lockstep.retry`) and the frozen Sub-phase 9.9 durable retry checkpoint
store (:mod:`lockstep.retry_checkpoint`) into the Supervisor transaction:

    normal blocker-aware transaction
        -> retry-authority outcome?
        NO  -> existing result unchanged
        YES -> construct RetryCheckpoint -> freeze retry/checkpoint.json
            -> return durable checkpointed transaction result

Supported retry authorities: an Implementer ``BLOCKED`` / Reviewer
``BLOCKED`` escalation resolved to ``RESUME_AGENT``, and a Reviewer
``COMPLETED`` report whose ``ReviewDecision.verdict`` is ``REWORK``. This
module never executes attempt 2 of any agent, never re-enters the
Implementer or Reviewer, never consumes/claims/deletes a checkpoint, and
never modifies the frozen legacy
(:func:`~lockstep.supervisor.transaction.run_single_subphase_transaction`)
or Sub-phase 9.6/9.7 blocker-aware
(:func:`~lockstep.supervisor.transaction.run_single_subphase_transaction_with_blockers`)
entrypoints' behavior.

Uses real production ``ClaudeAdapter`` instances against fake provider
executables under ``tmp_path``, a real Git worktree, a real planning store,
and the real Sub-phase 9.9 checkpoint store (no mocking of
``freeze_retry_checkpoint``/``load_retry_checkpoint``). No real Claude/Codex
account, no network, no real model inference.
"""

from __future__ import annotations

import ast
import inspect
import json
import stat
import subprocess
import sys
import textwrap
from collections.abc import Mapping
from dataclasses import FrozenInstanceError, dataclass, fields
from pathlib import Path

import pytest

import lockstep.retry_checkpoint as retry_checkpoint_module
import lockstep.supervisor.transaction as transaction_module
from lockstep.agent_turn import AgentTurnResult
from lockstep.agents import (
    AgentAdapter,
    AgentProviderDiagnostics,
    AgentProviderStatuses,
    ClaudeAdapter,
    ClaudeCliStatus,
    ResolvedAgentAdapters,
)
from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.config import ProjectConfig
from lockstep.domain import (
    AcceptanceCriterion,
    AgentRole,
    AttemptNumber,
    BillingMode,
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    ReviewDecision,
    RunId,
    SubphaseContract,
    SubphaseId,
    SubphaseOutline,
    TestExpectation,
    TestSpecification,
)
from lockstep.escalation import EscalationAuthority, EscalationCategory
from lockstep.escalation_decision import PlannerDecisionKind
from lockstep.git import inspect_repository
from lockstep.persistence import read_events, read_state
from lockstep.planning_store import freeze_master_plan, freeze_subphase_contract, publish_phase_plan
from lockstep.retry import AttemptState, RetryBudget, RetryBudgetDisposition, RetryReason
from lockstep.retry_checkpoint import (
    RetryAuthorityKind,
    RetryCheckpoint,
    RetryCheckpointStoreError,
    freeze_retry_checkpoint,
    load_retry_checkpoint,
    retry_checkpoint_path,
)
from lockstep.reviewer_turn import ReviewerTurnResult
from lockstep.runtime import AgentRuntime
from lockstep.state import WorkflowState
from lockstep.supervisor.escalation import SupervisorEscalationDisposition
from lockstep.supervisor.transaction import (
    ImplementerBlockedTransactionResult,
    RetryCheckpointedTransactionResult,
    ReviewerBlockedTransactionResult,
    ReviewReworkTransactionResult,
    SingleSubphaseTransactionRequest,
    SingleSubphaseTransactionResult,
    SupervisorTransactionError,
    run_single_subphase_transaction_with_retry_checkpoint,
)

_PHASE_ID = "09"
_SUBPHASE_ID = "10"

_TEST_FILE_RED = (
    "import pathlib\n"
    "import sys\n"
    "\n"
    "sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))\n"
    "\n"
    "from feature import answer\n"
    "\n"
    "\n"
    "def test_answer() -> None:\n"
    "    assert answer() == 42\n"
)

_IMPL_CORRECT = "def answer() -> int:\n    return 42\n"


# ---------------------------------------------------------------------------
# Identifiers
# ---------------------------------------------------------------------------


def _phase_id(value: str = _PHASE_ID) -> PhaseId:
    return PhaseId.model_validate(value)


def _subphase_id(value: str = _SUBPHASE_ID) -> SubphaseId:
    return SubphaseId.model_validate(value)


def _attempt(value: int = 1) -> AttemptNumber:
    return AttemptNumber.model_validate(value)


def _budget(max_attempts: int) -> RetryBudget:
    return RetryBudget(max_attempts=AttemptNumber.model_validate(max_attempts))


def _attempt_state(*, phase_id: str = _PHASE_ID, subphase_id: str = _SUBPHASE_ID) -> AttemptState:
    return AttemptState(
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        current_attempt=_attempt(1),
    )


# ---------------------------------------------------------------------------
# Git source repo helpers (mirrors tests/test_supervisor_implementer_blocker.py)
# ---------------------------------------------------------------------------


def _git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=check,
        capture_output=True,
        text=True,
    )


def _init_source_repo(root: Path) -> Path:
    source = root / "source"
    source.mkdir(parents=True)
    _git(source, "init")
    _git(source, "config", "user.name", "Lockstep Tests")
    _git(source, "config", "user.email", "lockstep-tests@example.invalid")
    _git(source, "config", "commit.gpgsign", "false")
    (source / "README.md").write_text("initial\n")
    _git(source, "add", "README.md")
    _git(source, "commit", "-m", "initial")
    _git(source, "branch", "-M", "main")
    return source


def _log_subjects(worktree: Path) -> list[str]:
    return _git(worktree, "log", "--format=%s").stdout.strip().splitlines()


# ---------------------------------------------------------------------------
# Sequential fake Claude executable (mirrors tests/test_supervisor_reviewer_blocker.py)
# ---------------------------------------------------------------------------


def _write_fake_claude_executable(
    bin_dir: Path,
    *,
    name: str,
    responses: list[dict[str, object]],
) -> Path:
    bin_dir.mkdir(parents=True, exist_ok=True)
    executable = bin_dir / name
    responses_path = bin_dir / f"{name}-responses.json"
    responses_path.write_text(json.dumps(responses), encoding="utf-8")

    script = textwrap.dedent(
        f"""\
        #!{sys.executable}
        import json
        import sys
        from pathlib import Path

        base = Path(__file__).resolve().parent
        responses = json.loads((base / "{name}-responses.json").read_text(encoding="utf-8"))
        count_path = base / "{name}-call-count.txt"
        index = int(count_path.read_text()) if count_path.exists() else 0
        count_path.write_text(str(index + 1))
        response = responses[index] if index < len(responses) else responses[-1]

        sys.stdin.read()

        log_path = base / "{name}-invocations.jsonl"
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({{"index": index, "cwd": str(Path.cwd())}}) + "\\n")

        for rel_path, content in response.get("files", {{}}).items():
            target = Path(rel_path)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)

        sys.stdout.write(response.get("stdout", ""))
        sys.stderr.write(response.get("stderr", ""))
        raise SystemExit(int(response.get("returncode", 0)))
        """
    )
    executable.write_text(script, encoding="utf-8")
    mode = executable.stat().st_mode
    executable.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _invocation_count(bin_dir: Path, name: str) -> int:
    log_path = bin_dir / f"{name}-invocations.jsonl"
    if not log_path.exists():
        return 0
    return len([line for line in log_path.read_text(encoding="utf-8").splitlines() if line])


def _healthy_claude_status(*, executable: str) -> ClaudeCliStatus:
    return ClaudeCliStatus(
        executable=executable,
        version="2.1.259",
        logged_in=True,
        auth_method="claude.ai",
        api_provider="firstParty",
        subscription_type="max",
        supports_print=True,
        supports_model=True,
        supports_effort=True,
        supports_output_format=True,
        supports_json_schema=True,
        supports_permission_mode=True,
        supports_permission_prompts=True,
        supports_no_session_persistence=True,
        supports_restricted=True,
        supports_bare=False,
        supports_tools=True,
        supports_disallowed_tools=True,
        supports_safe_mode=True,
        supports_allowed_tools=True,
    )


def _claude_adapter(
    role: AgentRole, *, executable: str, model: str = "role-model"
) -> ClaudeAdapter:
    return ClaudeAdapter(
        role=role,
        status=_healthy_claude_status(executable=executable),
        model=model,
        effort="high",
    )


# ---------------------------------------------------------------------------
# Response builders
# ---------------------------------------------------------------------------


def _planner_authoring_response(test_content: str) -> dict[str, object]:
    return {"stdout": "", "returncode": 0, "files": {"tests/test_feature.py": test_content}}


def _planner_decision_response(
    *,
    kind: PlannerDecisionKind,
    rationale: str = "Bounded rationale for this decision.",
    instructions: tuple[str, ...] = ("Do the bounded thing.",),
    authorized_paths: tuple[str, ...] = (),
) -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "kind": kind.value,
                "rationale": rationale,
                "instructions": list(instructions),
                "authorized_paths": list(authorized_paths),
            }
        ),
        "returncode": 0,
    }


def _implementer_completed_response(files: dict[str, str]) -> dict[str, object]:
    return {
        "stdout": json.dumps({"status": "completed", "blocker": None}),
        "returncode": 0,
        "files": files,
    }


def _implementer_blocked_response(
    *,
    category: EscalationCategory,
    question: str = "Bounded sentinel question.",
    evidence: tuple[str, ...] = ("Bounded sentinel evidence.",),
    requested_authority: EscalationAuthority,
    stderr: str = "",
    files: dict[str, str] | None = None,
) -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "status": "blocked",
                "blocker": {
                    "category": category.value,
                    "question": question,
                    "evidence": list(evidence),
                    "requested_authority": requested_authority.value,
                },
            }
        ),
        "returncode": 0,
        "stderr": stderr,
        "files": files or {},
    }


def _review_decision_payload(
    *,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    attempt: int = 1,
    verdict: str = "approve",
    summary: str = "approved",
    findings: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "phase_id": phase_id,
        "subphase_id": subphase_id,
        "attempt": attempt,
        "verdict": verdict,
        "summary": summary,
        "findings": findings or [],
    }


def _reviewer_turn_completed_response(
    *,
    verdict: str = "approve",
    summary: str = "approved",
    findings: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "status": "completed",
                "review_decision": _review_decision_payload(
                    verdict=verdict, summary=summary, findings=findings
                ),
                "blocker": None,
            }
        ),
        "returncode": 0,
    }


def _reviewer_turn_blocked_response(
    *,
    category: EscalationCategory,
    question: str = "Bounded sentinel question.",
    evidence: tuple[str, ...] = ("Bounded sentinel evidence.",),
    requested_authority: EscalationAuthority,
    stderr: str = "",
) -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "status": "blocked",
                "review_decision": None,
                "blocker": {
                    "category": category.value,
                    "question": question,
                    "evidence": list(evidence),
                    "requested_authority": requested_authority.value,
                },
            }
        ),
        "returncode": 0,
        "stderr": stderr,
    }


# ---------------------------------------------------------------------------
# Planning-store fixtures
# ---------------------------------------------------------------------------


def _master_plan(*, phase_id: str, subphase_id: str) -> MasterPlan:
    return MasterPlan(
        schema_version=1,
        project_id="lockstep",
        title="Lockstep",
        objective="Build the local orchestration control plane.",
        phases=[
            PhasePlan(
                schema_version=1,
                phase_id=_phase_id(phase_id),
                title="Transaction retry checkpoint integration",
                objective="Integrate durable retry checkpoints into the transaction.",
                depends_on=[],
                subphases=[
                    SubphaseOutline(
                        subphase_id=_subphase_id(subphase_id),
                        title="Transaction retry checkpoint integration",
                        objective="Freeze retry authority durably when it occurs.",
                        depends_on=[],
                    )
                ],
                integration_acceptance_criteria=[],
            )
        ],
    )


def _phase_plan(*, phase_id: str, subphase_id: str) -> PhasePlan:
    return _master_plan(phase_id=phase_id, subphase_id=subphase_id).phases[0]


def _contract(*, phase_id: str, subphase_id: str) -> SubphaseContract:
    return SubphaseContract(
        schema_version=1,
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        title="Transaction retry checkpoint integration",
        objective="Freeze retry authority durably when it occurs.",
        acceptance_criteria=[
            AcceptanceCriterion(criterion_id="AC-1", description="Retry authority is durable.")
        ],
        tests=[
            TestSpecification(
                path="tests/test_supervisor_retry_checkpoint.py",
                expectation=TestExpectation.RED,
                acceptance_criteria=["AC-1"],
            )
        ],
        allowed_paths=["src/lockstep/supervisor/transaction.py"],
        protected_paths=[],
        forbidden_paths=[],
        verification_commands=["./scripts/check"],
    )


def _freeze_planning_state(
    project_root: Path,
    runtime_dir: Path,
    *,
    phase_id: str,
    subphase_id: str,
) -> None:
    freeze_master_plan(project_root, _master_plan(phase_id=phase_id, subphase_id=subphase_id))
    publish_phase_plan(
        project_root, runtime_dir, _phase_plan(phase_id=phase_id, subphase_id=subphase_id)
    )
    freeze_subphase_contract(
        project_root, runtime_dir, _contract(phase_id=phase_id, subphase_id=subphase_id)
    )


# ---------------------------------------------------------------------------
# Request / runtime construction -- ``root`` isolates independent scenarios
# sharing one ``tmp_path`` (needed for the identical/different pre-existing
# checkpoint tests, which run two full transactions with deterministic,
# value-equal escalation/decision content into two different runtime dirs).
# ---------------------------------------------------------------------------


def _parent_env(root: Path) -> dict[str, str]:
    home = root / "home"
    home.mkdir(exist_ok=True, parents=True)
    return {
        "HOME": str(home),
        "PATH": "/usr/bin:/bin",
    }


def _build_request(
    root: Path,
    source: Path,
    *,
    run_id: str = "20260928-010",
    runtime_dir: Path | None = None,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
) -> SingleSubphaseTransactionRequest:
    pytest_argv = (
        sys.executable,
        "-m",
        "pytest",
        "-q",
        "-p",
        "no:cacheprovider",
        "tests/test_feature.py",
    )
    return SingleSubphaseTransactionRequest(
        project_id=ProjectId.model_validate("lockstep"),
        run_id=RunId.model_validate(run_id),
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        source_path=source,
        worktree_path=root / "run-worktree",
        runtime_dir=runtime_dir if runtime_dir is not None else root / "runtime",
        branch="lockstep/run/run-09-10-supervisor",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        planner_prompt="draft the failing acceptance test",
        implementer_prompt="implement the acceptance test",
        reviewer_prompt="review the implementation",
        test_paths=("tests/test_feature.py",),
        implementation_paths=("feature.py",),
        planner_quality_argv=(sys.executable, "-m", "py_compile", "tests/test_feature.py"),
        baseline_argv=pytest_argv,
        verification_argv=pytest_argv,
        test_commit_message="test(feature): freeze answer expectation",
        implementation_commit_message="feat(feature): implement answer",
        agent_timeout_seconds=60.0,
        command_timeout_seconds=60.0,
    )


def _agent_runtime(
    root: Path,
    *,
    runtime_dir: Path,
    planner_adapter: AgentAdapter,
    implementer_adapter: AgentAdapter,
    reviewer_adapter: AgentAdapter,
    parent_env: Mapping[str, str],
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
) -> AgentRuntime:
    project_root = root / "agent-project"
    project_root.mkdir(exist_ok=True, parents=True)
    _freeze_planning_state(project_root, runtime_dir, phase_id=phase_id, subphase_id=subphase_id)

    route = AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model="unused-model",
        effort="unused-effort",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )
    policy = AgentRoutingPolicy(planner=route, implementer=route, reviewer=route)
    config = ProjectConfig(schema_version=1, routing=policy)
    diagnostics = AgentProviderDiagnostics(statuses=AgentProviderStatuses())
    adapters = ResolvedAgentAdapters(
        planner=planner_adapter,
        implementer=implementer_adapter,
        reviewer=reviewer_adapter,
    )

    return AgentRuntime(
        project_root=project_root,
        runtime_dir=runtime_dir,
        config=config,
        diagnostics=diagnostics,
        adapters=adapters,
        transaction_parent_env=parent_env,
    )


@dataclass(frozen=True, slots=True)
class _Scenario:
    request: SingleSubphaseTransactionRequest
    runtime: AgentRuntime
    planner_bin: Path
    implementer_bin: Path
    reviewer_bin: Path


def _prepare_scenario(
    root: Path,
    *,
    planner_responses: list[dict[str, object]] | None = None,
    implementer_response: dict[str, object] | None = None,
    reviewer_response: dict[str, object] | None = None,
    run_id: str = "20260928-010",
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
) -> _Scenario:
    root.mkdir(exist_ok=True, parents=True)
    source = _init_source_repo(root)
    request = _build_request(
        root, source, run_id=run_id, phase_id=phase_id, subphase_id=subphase_id
    )

    resolved_planner_responses = (
        planner_responses
        if planner_responses is not None
        else [_planner_authoring_response(_TEST_FILE_RED)]
    )
    planner_bin = root / "planner-bin"
    _write_fake_claude_executable(
        planner_bin, name="claude-planner", responses=resolved_planner_responses
    )
    planner_adapter = _claude_adapter(
        AgentRole.PLANNER, executable=str(planner_bin / "claude-planner")
    )

    resolved_implementer_response = (
        implementer_response
        if implementer_response is not None
        else _implementer_completed_response({"feature.py": _IMPL_CORRECT})
    )
    implementer_bin = root / "implementer-bin"
    _write_fake_claude_executable(
        implementer_bin, name="claude-implementer", responses=[resolved_implementer_response]
    )
    implementer_adapter = _claude_adapter(
        AgentRole.IMPLEMENTER, executable=str(implementer_bin / "claude-implementer")
    )

    resolved_reviewer_response = (
        reviewer_response if reviewer_response is not None else _reviewer_turn_completed_response()
    )
    reviewer_bin = root / "reviewer-bin"
    _write_fake_claude_executable(
        reviewer_bin, name="claude-reviewer", responses=[resolved_reviewer_response]
    )
    reviewer_adapter = _claude_adapter(
        AgentRole.REVIEWER, executable=str(reviewer_bin / "claude-reviewer")
    )

    runtime = _agent_runtime(
        root,
        runtime_dir=request.runtime_dir,
        planner_adapter=planner_adapter,
        implementer_adapter=implementer_adapter,
        reviewer_adapter=reviewer_adapter,
        parent_env=_parent_env(root),
        phase_id=phase_id,
        subphase_id=subphase_id,
    )

    return _Scenario(
        request=request,
        runtime=runtime,
        planner_bin=planner_bin,
        implementer_bin=implementer_bin,
        reviewer_bin=reviewer_bin,
    )


# ===========================================================================
# Signature: explicit required RetryBudget, no default, no config/env/CLI
# lookup (sections 32-33, 43; AC-9.10.8/9/10)
# ===========================================================================


def test_new_entrypoint_requires_retry_budget_with_no_default() -> None:
    signature = inspect.signature(run_single_subphase_transaction_with_retry_checkpoint)
    assert "retry_budget" in signature.parameters
    param = signature.parameters["retry_budget"]
    assert param.default is inspect.Parameter.empty
    assert param.kind is inspect.Parameter.KEYWORD_ONLY
    assert param.annotation == "RetryBudget"


def test_new_entrypoint_has_no_config_env_cli_budget_source() -> None:
    signature = inspect.signature(run_single_subphase_transaction_with_retry_checkpoint)
    for forbidden_param in ("config", "environ", "env", "cli", "toml", "max_attempts"):
        assert forbidden_param not in signature.parameters


def test_new_entrypoint_does_not_alter_existing_entrypoint_signatures() -> None:
    from lockstep.supervisor.transaction import (
        run_single_subphase_transaction,
        run_single_subphase_transaction_with_blockers,
    )

    blockers_signature = inspect.signature(run_single_subphase_transaction_with_blockers)
    assert set(blockers_signature.parameters) == {"request", "agent_turn_runtime"}

    legacy_signature = inspect.signature(run_single_subphase_transaction)
    assert set(legacy_signature.parameters) == {
        "request",
        "parent_env",
        "planner_adapter",
        "implementer_adapter",
        "reviewer_adapter",
    }


# ===========================================================================
# Public result shapes (section 42)
# ===========================================================================


def test_review_rework_result_is_frozen_slotted_with_exact_fields(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        reviewer_response=_reviewer_turn_completed_response(verdict="rework", summary="needs work"),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result, RetryCheckpointedTransactionResult)
    rework = result.source_result
    assert isinstance(rework, ReviewReworkTransactionResult)
    assert {f.name for f in fields(rework)} == {
        "test_commit",
        "implementer_turn",
        "reviewer_turn",
        "review_decision",
        "final_state",
    }
    assert not hasattr(rework, "__dict__")
    with pytest.raises(FrozenInstanceError):
        rework.test_commit = rework.test_commit  # type: ignore[misc]

    assert isinstance(rework.implementer_turn, AgentTurnResult)
    assert isinstance(rework.reviewer_turn, ReviewerTurnResult)
    assert isinstance(rework.review_decision, ReviewDecision)
    assert rework.final_state.workflow_state == WorkflowState.HALTED


def test_retry_checkpointed_result_is_frozen_slotted_with_exact_fields(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.REQUIREMENT_AMBIGUITY,
            requested_authority=EscalationAuthority.HUMAN,
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    # HUMAN_REQUIRED carries no retry authority -- this asserts the wrapper's
    # shape via a scenario that *does* checkpoint, below; here we only assert
    # the non-checkpoint result is returned unchanged.
    assert isinstance(result, ImplementerBlockedTransactionResult)


def test_retry_checkpointed_result_shape_and_repr(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.ARCHITECTURE_CONFLICT,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result, RetryCheckpointedTransactionResult)
    assert {f.name for f in fields(result)} == {"source_result", "checkpoint"}
    assert not hasattr(result, "__dict__")
    with pytest.raises(FrozenInstanceError):
        result.checkpoint = result.checkpoint  # type: ignore[misc]

    assert isinstance(result.checkpoint, RetryCheckpoint)
    assert "source_result" not in repr(result)


# ===========================================================================
# Ordinary success -- Review APPROVE (sections 21, 44, 50)
# ===========================================================================


def test_checkpoint_aware_approve_matches_blocker_aware_success_shape(tmp_path: Path) -> None:
    root = tmp_path / "scenario"
    scenario = _prepare_scenario(
        root, reviewer_response=_reviewer_turn_completed_response(verdict="approve")
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result, SingleSubphaseTransactionResult)
    assert result.final_state.workflow_state == WorkflowState.SUBPHASE_COMPLETE
    assert result.review.verdict.value == "approve"

    assert _invocation_count(scenario.planner_bin, "claude-planner") == 1
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1

    events = read_events(scenario.request.runtime_dir / "events.jsonl")
    assert len(events) == 11

    assert not retry_checkpoint_path(scenario.request.runtime_dir).exists()


# ===========================================================================
# Review HALT regression (sections 22, 51)
# ===========================================================================


def test_checkpoint_aware_halt_preserves_existing_semantics_no_checkpoint(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        reviewer_response=_reviewer_turn_completed_response(verdict="halt", summary="must halt"),
    )

    with pytest.raises(SupervisorTransactionError) as exc_info:
        run_single_subphase_transaction_with_retry_checkpoint(
            scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
        )

    assert exc_info.value.stage == "review"

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.REVIEWING

    assert not retry_checkpoint_path(scenario.request.runtime_dir).exists()


# ===========================================================================
# Implementer RESUME -- available / exhausted (sections 45, 46)
# ===========================================================================


def test_implementer_resume_available_creates_checkpoint(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.ARCHITECTURE_CONFLICT,
            requested_authority=EscalationAuthority.PLANNER,
            files={"feature.py": "partial work\n"},
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result, RetryCheckpointedTransactionResult)
    source = result.source_result
    assert isinstance(source, ImplementerBlockedTransactionResult)
    assert source.final_state.workflow_state == WorkflowState.HALTED
    assert source.escalation.disposition == SupervisorEscalationDisposition.RESUME_AGENT

    checkpoint = result.checkpoint
    assert checkpoint.authority.kind == RetryAuthorityKind.ESCALATION_RESUME
    assert checkpoint.retry_request.reason == RetryReason.ESCALATION_RESUME
    assert checkpoint.retry_request.target_role == AgentRole.IMPLEMENTER
    assert checkpoint.attempt_state.current_attempt == _attempt(1)
    assert checkpoint.next_attempt_state is not None
    assert checkpoint.next_attempt_state.current_attempt == _attempt(2)
    assert checkpoint.budget_disposition == RetryBudgetDisposition.RETRY_AVAILABLE

    loaded = load_retry_checkpoint(scenario.request.runtime_dir)
    assert loaded == checkpoint

    # No Reviewer invocation, no second Implementer invocation.
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 0
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 2

    # Partial work survives untouched.
    partial_file = scenario.request.worktree_path / "feature.py"
    assert partial_file.read_text(encoding="utf-8") == "partial work\n"


def test_implementer_resume_exhausted_creates_checkpoint(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.ARCHITECTURE_CONFLICT,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(1)
    )

    assert isinstance(result, RetryCheckpointedTransactionResult)
    checkpoint = result.checkpoint
    assert checkpoint.budget_disposition == RetryBudgetDisposition.RETRY_EXHAUSTED
    assert checkpoint.next_attempt_state is None

    source = result.source_result
    assert isinstance(source, ImplementerBlockedTransactionResult)
    assert source.final_state.workflow_state == WorkflowState.HALTED

    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 0


# ===========================================================================
# Reviewer RESUME -- available / exhausted (section 47)
# ===========================================================================


def test_reviewer_resume_available_creates_checkpoint(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        reviewer_response=_reviewer_turn_blocked_response(
            category=EscalationCategory.ARCHITECTURE_CONFLICT,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result, RetryCheckpointedTransactionResult)
    source = result.source_result
    assert isinstance(source, ReviewerBlockedTransactionResult)
    assert source.final_state.workflow_state == WorkflowState.HALTED

    checkpoint = result.checkpoint
    assert checkpoint.authority.kind == RetryAuthorityKind.ESCALATION_RESUME
    assert checkpoint.retry_request.target_role == AgentRole.REVIEWER
    assert checkpoint.next_attempt_state is not None
    assert checkpoint.next_attempt_state.current_attempt == _attempt(2)
    assert checkpoint.budget_disposition == RetryBudgetDisposition.RETRY_AVAILABLE

    # No second Reviewer invocation.
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1


def test_reviewer_resume_exhausted_creates_checkpoint(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        reviewer_response=_reviewer_turn_blocked_response(
            category=EscalationCategory.ARCHITECTURE_CONFLICT,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(1)
    )

    assert isinstance(result, RetryCheckpointedTransactionResult)
    checkpoint = result.checkpoint
    assert checkpoint.budget_disposition == RetryBudgetDisposition.RETRY_EXHAUSTED
    assert checkpoint.next_attempt_state is None
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1


# ===========================================================================
# Review REWORK -- available / exhausted (sections 20, 48, 49)
# ===========================================================================


def test_review_rework_available_creates_checkpoint(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        reviewer_response=_reviewer_turn_completed_response(
            verdict="rework", summary="needs changes"
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result, RetryCheckpointedTransactionResult)
    rework = result.source_result
    assert isinstance(rework, ReviewReworkTransactionResult)
    assert rework.review_decision.verdict.value == "rework"
    assert rework.final_state.workflow_state == WorkflowState.HALTED

    checkpoint = result.checkpoint
    assert checkpoint.authority.kind == RetryAuthorityKind.REVIEW_REWORK
    assert checkpoint.retry_request.reason == RetryReason.REVIEW_REWORK
    assert checkpoint.retry_request.target_role == AgentRole.IMPLEMENTER
    assert checkpoint.next_attempt_state is not None
    assert checkpoint.next_attempt_state.current_attempt == _attempt(2)
    assert checkpoint.budget_disposition == RetryBudgetDisposition.RETRY_AVAILABLE

    loaded = load_retry_checkpoint(scenario.request.runtime_dir)
    assert loaded == checkpoint

    # No production commit; no second Implementer.
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1

    worktree_snapshot = inspect_repository(scenario.request.worktree_path)
    assert not worktree_snapshot.is_clean

    impl_file = scenario.request.worktree_path / "feature.py"
    assert impl_file.read_text(encoding="utf-8") == _IMPL_CORRECT

    events = read_events(scenario.request.runtime_dir / "events.jsonl")
    assert len(events) == 10
    last_event = events[-1]
    assert last_event.source == WorkflowState.REVIEWING
    assert last_event.target == WorkflowState.HALTED


def test_review_rework_exhausted_creates_checkpoint(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        reviewer_response=_reviewer_turn_completed_response(
            verdict="rework", summary="needs changes"
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(1)
    )

    assert isinstance(result, RetryCheckpointedTransactionResult)
    checkpoint = result.checkpoint
    assert checkpoint.budget_disposition == RetryBudgetDisposition.RETRY_EXHAUSTED
    assert checkpoint.next_attempt_state is None

    rework = result.source_result
    assert isinstance(rework, ReviewReworkTransactionResult)
    assert rework.final_state.workflow_state == WorkflowState.HALTED

    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1


# ===========================================================================
# Nonretryable blockers create no checkpoint (sections 18, 41, 52-55)
# ===========================================================================


def test_direct_human_blocker_no_checkpoint(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.REQUIREMENT_AMBIGUITY,
            requested_authority=EscalationAuthority.HUMAN,
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert result.escalation.disposition == SupervisorEscalationDisposition.HUMAN_REQUIRED
    assert not retry_checkpoint_path(scenario.request.runtime_dir).exists()


def test_direct_supervisor_blocker_no_checkpoint(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.CONTROL_PLANE_BLOCKER,
            requested_authority=EscalationAuthority.SUPERVISOR,
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert (
        result.escalation.disposition == SupervisorEscalationDisposition.SUPERVISOR_ACTION_REQUIRED
    )
    assert not retry_checkpoint_path(scenario.request.runtime_dir).exists()


def test_replan_blocker_no_checkpoint(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.REPLAN_SUBPHASE),
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.PLANNER_DECISION_REQUIRED,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert result.escalation.disposition == SupervisorEscalationDisposition.REPLAN_SUBPHASE
    assert not retry_checkpoint_path(scenario.request.runtime_dir).exists()


def test_run_halt_blocker_no_checkpoint(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.TERMINAL_HALT),
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.PLANNER_DECISION_REQUIRED,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert result.escalation.disposition == SupervisorEscalationDisposition.RUN_HALT
    assert not retry_checkpoint_path(scenario.request.runtime_dir).exists()


# ===========================================================================
# Checkpoint freeze failure after HALTED (sections 23-26, 56)
# ===========================================================================


def test_checkpoint_freeze_failure_leaves_run_halted_no_checkpoint(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.REQUIREMENT_AMBIGUITY,
            requested_authority=EscalationAuthority.HUMAN,
        ),
    )
    # HUMAN_REQUIRED never checkpoints; use a RESUME-authorizing scenario
    # instead so a real freeze is attempted.
    scenario = _prepare_scenario(
        tmp_path / "scenario2",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.ARCHITECTURE_CONFLICT,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    def _fail_replace(source: Path, target: Path) -> None:
        raise OSError("simulated durable-store failure")

    monkeypatch.setattr(retry_checkpoint_module, "_replace_atomically", _fail_replace)

    with pytest.raises(RetryCheckpointStoreError):
        run_single_subphase_transaction_with_retry_checkpoint(
            scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
        )

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.HALTED

    assert not retry_checkpoint_path(scenario.request.runtime_dir).exists()
    assert scenario.request.worktree_path.exists()


# ===========================================================================
# Corrupt pre-existing checkpoint fails closed (section 57)
# ===========================================================================


def test_corrupt_existing_checkpoint_fails_closed(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.ARCHITECTURE_CONFLICT,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    checkpoint_path = retry_checkpoint_path(scenario.request.runtime_dir)
    checkpoint_path.parent.mkdir(parents=True)
    corrupt_bytes = b"not valid json at all"
    checkpoint_path.write_bytes(corrupt_bytes)

    with pytest.raises(RetryCheckpointStoreError):
        run_single_subphase_transaction_with_retry_checkpoint(
            scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
        )

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.HALTED

    assert checkpoint_path.read_bytes() == corrupt_bytes


# ===========================================================================
# Identical / different pre-existing checkpoint (sections 26-27, 58-59)
# ===========================================================================


def _resume_scenario(root: Path, *, run_id: str) -> _Scenario:
    return _prepare_scenario(
        root,
        run_id=run_id,
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.ARCHITECTURE_CONFLICT,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )


def test_identical_preexisting_checkpoint_is_idempotent(tmp_path: Path) -> None:
    scenario_a = _resume_scenario(tmp_path / "scenario-a", run_id="20260928-010")
    result_a = run_single_subphase_transaction_with_retry_checkpoint(
        scenario_a.request, agent_turn_runtime=scenario_a.runtime, retry_budget=_budget(3)
    )
    assert isinstance(result_a, RetryCheckpointedTransactionResult)

    scenario_b = _resume_scenario(tmp_path / "scenario-b", run_id="20260928-011")
    pre_freeze = freeze_retry_checkpoint(scenario_b.request.runtime_dir, result_a.checkpoint)
    assert pre_freeze == result_a.checkpoint
    checkpoint_path_b = retry_checkpoint_path(scenario_b.request.runtime_dir)
    bytes_before = checkpoint_path_b.read_bytes()

    result_b = run_single_subphase_transaction_with_retry_checkpoint(
        scenario_b.request, agent_turn_runtime=scenario_b.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result_b, RetryCheckpointedTransactionResult)
    assert result_b.checkpoint == result_a.checkpoint
    assert checkpoint_path_b.read_bytes() == bytes_before


def test_different_preexisting_checkpoint_is_rejected(tmp_path: Path) -> None:
    scenario_a = _resume_scenario(tmp_path / "scenario-a", run_id="20260928-010")
    result_a = run_single_subphase_transaction_with_retry_checkpoint(
        scenario_a.request, agent_turn_runtime=scenario_a.runtime, retry_budget=_budget(5)
    )
    assert isinstance(result_a, RetryCheckpointedTransactionResult)

    scenario_b = _resume_scenario(tmp_path / "scenario-b", run_id="20260928-011")
    freeze_retry_checkpoint(scenario_b.request.runtime_dir, result_a.checkpoint)
    checkpoint_path_b = retry_checkpoint_path(scenario_b.request.runtime_dir)
    bytes_before = checkpoint_path_b.read_bytes()

    # Different budget -> a structurally different derived checkpoint.
    with pytest.raises(RetryCheckpointStoreError):
        run_single_subphase_transaction_with_retry_checkpoint(
            scenario_b.request, agent_turn_runtime=scenario_b.runtime, retry_budget=_budget(3)
        )

    persisted = read_state(scenario_b.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.HALTED
    assert checkpoint_path_b.read_bytes() == bytes_before


# ===========================================================================
# No attempt-2 execution / no retry loop (sections 14, 28-31, 60-61)
# ===========================================================================


def test_one_attempt_budget_exhausts_without_retry_major_witness(tmp_path: Path) -> None:
    scenario = _resume_scenario(tmp_path / "scenario", run_id="20260928-010")

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(1)
    )

    assert isinstance(result, RetryCheckpointedTransactionResult)
    assert result.checkpoint.budget_disposition == RetryBudgetDisposition.RETRY_EXHAUSTED
    assert result.checkpoint.next_attempt_state is None
    assert result.checkpoint.attempt_state.current_attempt == _attempt(1)

    source = result.source_result
    assert isinstance(source, ImplementerBlockedTransactionResult)
    assert source.final_state.workflow_state == WorkflowState.HALTED

    # Exactly one Implementer invocation total -- no attempt-2 execution.
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1


def test_no_reviewer_invoked_after_implementer_checkpoint(tmp_path: Path) -> None:
    scenario = _resume_scenario(tmp_path / "scenario", run_id="20260928-010")

    run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 0


# ===========================================================================
# Frozen-artifact-correction authority survives persistence, uncorrected
# (section 62)
# ===========================================================================


def test_frozen_artifact_correction_authority_persists_without_applying_correction(
    tmp_path: Path,
) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
                authorized_paths=("tests/test_feature.py",),
            ),
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.TEST_DEFECT,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result, RetryCheckpointedTransactionResult)
    authority = result.checkpoint.authority
    assert authority.kind == RetryAuthorityKind.ESCALATION_RESUME
    assert authority.escalation_request is not None
    assert authority.escalation_request.category == EscalationCategory.TEST_DEFECT
    assert authority.planner_decision is not None
    assert authority.planner_decision.authorized_paths == ("tests/test_feature.py",)

    # The file is not actually corrected.
    test_file = scenario.request.worktree_path / "tests" / "test_feature.py"
    assert test_file.read_text(encoding="utf-8") == _TEST_FILE_RED

    loaded = load_retry_checkpoint(scenario.request.runtime_dir)
    assert loaded is not None
    assert loaded.authority.planner_decision is not None
    assert loaded.authority.planner_decision.authorized_paths == ("tests/test_feature.py",)


# ===========================================================================
# Reviewer findings survive persistence (section 63)
# ===========================================================================


def test_reviewer_rework_findings_survive_persistence(tmp_path: Path) -> None:
    distinctive_summary = "Sentinel summary needs distinct rework SENTINEL-A1B2"
    distinctive_evidence = "Sentinel finding evidence SENTINEL-C3D4"
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        reviewer_response=_reviewer_turn_completed_response(
            verdict="rework",
            summary=distinctive_summary,
            findings=[
                {
                    "summary": "Distinctive finding summary SENTINEL-E5F6",
                    "evidence": distinctive_evidence,
                    "file_path": None,
                    "acceptance_criterion_id": None,
                }
            ],
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result, RetryCheckpointedTransactionResult)
    review_decision = result.checkpoint.authority.review_decision
    assert review_decision is not None
    assert review_decision.summary == distinctive_summary
    assert len(review_decision.findings) == 1
    assert review_decision.findings[0].evidence == distinctive_evidence

    checkpoint_bytes = retry_checkpoint_path(scenario.request.runtime_dir).read_bytes()
    assert distinctive_summary.encode("utf-8") in checkpoint_bytes
    assert distinctive_evidence.encode("utf-8") in checkpoint_bytes


# ===========================================================================
# No provider telemetry persisted (section 64)
# ===========================================================================


def test_checkpoint_excludes_provider_telemetry(tmp_path: Path) -> None:
    stdout_sentinel = "STDOUT-TELEMETRY-SENTINEL-9f2c"
    stderr_sentinel = "STDERR-TELEMETRY-SENTINEL-7a1e"
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.ARCHITECTURE_CONFLICT,
            requested_authority=EscalationAuthority.PLANNER,
            stderr=stderr_sentinel,
        ),
    )

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result, RetryCheckpointedTransactionResult)
    checkpoint_bytes = retry_checkpoint_path(scenario.request.runtime_dir).read_bytes()
    assert stdout_sentinel.encode("utf-8") not in checkpoint_bytes
    assert stderr_sentinel.encode("utf-8") not in checkpoint_bytes
    assert b"stdout" not in checkpoint_bytes
    assert b"stderr" not in checkpoint_bytes
    assert b"adapter" not in checkpoint_bytes
    assert b"provider" not in checkpoint_bytes


# ===========================================================================
# Checkpoint written only at the canonical path (section 65)
# ===========================================================================


def test_checkpoint_written_only_at_canonical_runtime_path(tmp_path: Path) -> None:
    scenario = _resume_scenario(tmp_path / "scenario", run_id="20260928-010")

    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert isinstance(result, RetryCheckpointedTransactionResult)
    assert retry_checkpoint_path(scenario.request.runtime_dir).exists()

    # No checkpoint file written under the source checkout or worktree.
    assert not list(scenario.request.source_path.rglob("checkpoint.json"))
    assert not list(scenario.request.worktree_path.rglob("checkpoint.json"))


# ===========================================================================
# Import-cycle smoke (section 68)
# ===========================================================================


def test_import_cycle_smoke_across_orders() -> None:
    statements = (
        "import lockstep.runtime; import lockstep.retry; import lockstep.retry_checkpoint; "
        "import lockstep.supervisor.transaction; import lockstep.supervisor.escalation",
        "import lockstep.retry; import lockstep.retry_checkpoint; import lockstep.runtime; "
        "import lockstep.supervisor.transaction",
        "import lockstep.supervisor.transaction; import lockstep.retry; "
        "import lockstep.retry_checkpoint; import lockstep.runtime",
        "import lockstep.supervisor.transaction; import lockstep.runtime; "
        "import lockstep.retry_checkpoint; import lockstep.retry",
        "import lockstep.retry_checkpoint; import lockstep.supervisor.transaction; "
        "import lockstep.runtime; import lockstep.retry",
    )
    for statement in statements:
        result = subprocess.run([sys.executable, "-c", statement], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr


def test_transaction_module_has_no_top_level_retry_import() -> None:
    tree = ast.parse(inspect.getsource(transaction_module))
    module_body_names: set[str] = set()
    for node in tree.body:
        if isinstance(node, ast.ImportFrom):
            module = node.module or ""
            if module in ("lockstep.retry", "lockstep.retry_checkpoint"):
                module_body_names.add(module)
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name in ("lockstep.retry", "lockstep.retry_checkpoint"):
                    module_body_names.add(alias.name)
    assert not module_body_names
