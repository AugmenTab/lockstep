"""Planner-authored specification of Sub-phase 9.13 controlled resume execution.

Pins the first production path that may actually execute attempt N+1:

    HALTED + retry/checkpoint.json
        -> inspect_resume                                 (frozen 9.11)
        -> claim_retry_checkpoint / existing CLAIMED       (frozen 9.11)
        -> request/runtime/state preflight
        -> target-role executability validation
        -> mark_resume_started                             (frozen 9.11)
        -> durable STARTED boundary
        -> HALTED -> IMPLEMENTING / HALTED -> REVIEWING     (9.13 FSM edges)
        -> invoke the exact target role at the exact attempt N+1
        -> known result
        -> ResumeSettlement                                 (frozen 9.12)
        -> finalize_resume_settlement                       (frozen 9.12)

Core invariants pinned here: ``RetryRequest.target_role`` is the sole
authority for which role resumes; ``RetryCheckpoint.next_attempt_state``
is the sole authority for the resumed attempt number; ``STARTED`` is
durable before any agent launch; a pre-existing ``STARTED`` claim without
a settlement is never automatically replayed; a known resumed result is
durably settled before the old ``STARTED`` claim disappears. 9.13
provides at-most-once automatic launch per retry attempt, never
exactly-once external inference.

Uses real production ``ClaudeAdapter`` instances against fake provider
executables under ``tmp_path``, a real Git worktree, a real planning
store, and the real frozen 9.9/9.11/9.12 checkpoint/claim/settlement
stores (no mocking of their public API). No real Claude/Codex account,
no network, no real model inference.
"""

from __future__ import annotations

import ast
import inspect
import json
import stat
import subprocess
import sys
import textwrap
import threading
from collections.abc import Mapping
from dataclasses import FrozenInstanceError, dataclass, fields
from pathlib import Path

import pytest

import lockstep.supervisor.transaction as transaction_module
from lockstep.agent_turn import AgentTurnError, AgentTurnResult
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
from lockstep.resume import resume_claim_path
from lockstep.resume_settlement import (
    ResumeSettlement,
    ResumeSettlementOutcome,
    freeze_resume_settlement,
)
from lockstep.retry import RetryBudget
from lockstep.retry_checkpoint import load_retry_checkpoint, retry_checkpoint_path
from lockstep.reviewer_turn import ReviewerTurnError
from lockstep.runtime import AgentRuntime
from lockstep.state import WorkflowState, allowed_transitions
from lockstep.supervisor.transaction import (
    ResumeExecutionDisposition,
    ResumeExecutionError,
    ResumeExecutionResult,
    RetryCheckpointedTransactionResult,
    SingleSubphaseTransactionRequest,
    SupervisorTransactionError,
    resume_single_subphase_transaction,
    run_single_subphase_transaction_with_retry_checkpoint,
)

_PHASE_ID = "09"
_SUBPHASE_ID = "13"

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

_TEST_FILE_CORRECTED = (
    "import pathlib\n"
    "import sys\n"
    "\n"
    "sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))\n"
    "\n"
    "from feature import answer\n"
    "\n"
    "\n"
    "def test_answer() -> None:\n"
    "    assert answer() == 43\n"
)

_IMPL_CORRECT = "def answer() -> int:\n    return 42\n"
_IMPL_CORRECTED_FOR_FIXED_TEST = "def answer() -> int:\n    return 43\n"


# ---------------------------------------------------------------------------
# Identifiers
# ---------------------------------------------------------------------------


def _phase_id(value: str = _PHASE_ID) -> PhaseId:
    return PhaseId.model_validate(value)


def _subphase_id(value: str = _SUBPHASE_ID) -> SubphaseId:
    return SubphaseId.model_validate(value)


def _attempt(value: int) -> AttemptNumber:
    return AttemptNumber.model_validate(value)


def _budget(max_attempts: int) -> RetryBudget:
    return RetryBudget(max_attempts=_attempt(max_attempts))


# ---------------------------------------------------------------------------
# Git source repo helpers (mirrors tests/test_supervisor_retry_checkpoint.py)
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


def _log_paths_for(worktree: Path, subject: str) -> tuple[str, ...]:
    revision = _git(worktree, "log", "--format=%H", "--grep", subject, "-F").stdout.strip()
    sha = revision.splitlines()[0]
    output = _git(
        worktree, "diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", sha
    ).stdout.strip()
    return tuple(sorted(output.splitlines())) if output else ()


# ---------------------------------------------------------------------------
# Sequential fake Claude executable, with optional claim/state observation
# (mirrors tests/test_supervisor_retry_checkpoint.py, extended for section
# 92-93's load-bearing STARTED/transition-before-launch ordering proof)
# ---------------------------------------------------------------------------


def _write_fake_claude_executable(
    bin_dir: Path,
    *,
    name: str,
    responses: list[dict[str, object]],
    observe_runtime_dir: Path | None = None,
) -> Path:
    bin_dir.mkdir(parents=True, exist_ok=True)
    executable = bin_dir / name
    responses_path = bin_dir / f"{name}-responses.json"
    responses_path.write_text(json.dumps(responses), encoding="utf-8")

    observation_snippet = ""
    if observe_runtime_dir is not None:
        raw_snippet = textwrap.dedent(
            f"""
            runtime_dir = Path({str(observe_runtime_dir)!r})
            claim_path = runtime_dir / "retry" / "claim.json"
            state_path = runtime_dir / "state.json"
            observed = {{
                "claim": (
                    json.loads(claim_path.read_text(encoding="utf-8"))
                    if claim_path.exists()
                    else None
                ),
                "state": (
                    json.loads(state_path.read_text(encoding="utf-8"))
                    if state_path.exists()
                    else None
                ),
            }}
            (base / f"{name}-observed-{{index}}.json").write_text(json.dumps(observed))
            """
        ).strip("\n")
        # Re-indent to match the surrounding 8-space template context;
        # otherwise this snippet's own column-0 lines would poison the
        # single outer textwrap.dedent() call below (its common-prefix
        # computation sees a 0-space line and strips nothing at all,
        # corrupting the shebang line into a non-executable file).
        observation_snippet = textwrap.indent(raw_snippet, "        ").lstrip(" ")

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
        {observation_snippet}
        log_path = base / "{name}-invocations.jsonl"
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({{"index": index, "cwd": str(Path.cwd())}}) + "\\n")

        for rel_path, content in response.get("files", {{}}).items():
            target = Path(rel_path)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)

        for rel_path in response.get("delete_files", []):
            target = Path(rel_path)
            if target.exists():
                target.unlink()

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


def _observed(bin_dir: Path, name: str, index: int) -> dict[str, object]:
    path = bin_dir / f"{name}-observed-{index}.json"
    return json.loads(path.read_text(encoding="utf-8"))


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


def _implementer_completed_response(
    files: dict[str, str], *, delete_files: tuple[str, ...] = ()
) -> dict[str, object]:
    return {
        "stdout": json.dumps({"status": "completed", "blocker": None}),
        "returncode": 0,
        "files": files,
        "delete_files": list(delete_files),
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
    attempt: int = 1,
    verdict: str = "approve",
    summary: str = "approved",
    findings: list[dict[str, object]] | None = None,
) -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "status": "completed",
                "review_decision": _review_decision_payload(
                    attempt=attempt, verdict=verdict, summary=summary, findings=findings
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


def _malformed_stdout_response() -> dict[str, object]:
    return {"stdout": "not valid json at all", "returncode": 0}


def _process_failure_response() -> dict[str, object]:
    return {"stdout": "", "returncode": 1}


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
                title="Controlled resume execution",
                objective="Execute durable retry authority at attempt N+1.",
                depends_on=[],
                subphases=[
                    SubphaseOutline(
                        subphase_id=_subphase_id(subphase_id),
                        title="Controlled resume execution",
                        objective="Execute at-most-once resumed attempts.",
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
        title="Controlled resume execution",
        objective="Execute at-most-once resumed attempts.",
        acceptance_criteria=[
            AcceptanceCriterion(criterion_id="AC-1", description="Resume executes at most once.")
        ],
        tests=[
            TestSpecification(
                path="tests/test_supervisor_resume_execution.py",
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
    from lockstep.planning_store import (
        freeze_master_plan,
        freeze_subphase_contract,
        publish_phase_plan,
    )

    freeze_master_plan(project_root, _master_plan(phase_id=phase_id, subphase_id=subphase_id))
    publish_phase_plan(
        project_root, runtime_dir, _phase_plan(phase_id=phase_id, subphase_id=subphase_id)
    )
    freeze_subphase_contract(
        project_root, runtime_dir, _contract(phase_id=phase_id, subphase_id=subphase_id)
    )


# ---------------------------------------------------------------------------
# Request / runtime construction
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
    run_id: str = "20260928-013",
    runtime_dir: Path | None = None,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    implementation_paths: tuple[str, ...] = ("feature.py",),
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
        branch="lockstep/run/run-09-13-supervisor",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        planner_prompt="draft the failing acceptance test",
        implementer_prompt="implement the acceptance test",
        reviewer_prompt="review the implementation",
        test_paths=("tests/test_feature.py",),
        implementation_paths=implementation_paths,
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
    implementer_responses: list[dict[str, object]] | None = None,
    reviewer_responses: list[dict[str, object]] | None = None,
    run_id: str = "20260928-013",
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    implementation_paths: tuple[str, ...] = ("feature.py",),
    observe_implementer_runtime_dir: Path | None = None,
    observe_reviewer_runtime_dir: Path | None = None,
) -> _Scenario:
    root.mkdir(exist_ok=True, parents=True)
    source = _init_source_repo(root)
    request = _build_request(
        root,
        source,
        run_id=run_id,
        phase_id=phase_id,
        subphase_id=subphase_id,
        implementation_paths=implementation_paths,
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

    resolved_implementer_responses = (
        implementer_responses
        if implementer_responses is not None
        else [_implementer_completed_response({"feature.py": _IMPL_CORRECT})]
    )
    implementer_bin = root / "implementer-bin"
    _write_fake_claude_executable(
        implementer_bin,
        name="claude-implementer",
        responses=resolved_implementer_responses,
        observe_runtime_dir=observe_implementer_runtime_dir,
    )
    implementer_adapter = _claude_adapter(
        AgentRole.IMPLEMENTER, executable=str(implementer_bin / "claude-implementer")
    )

    resolved_reviewer_responses = (
        reviewer_responses
        if reviewer_responses is not None
        else [_reviewer_turn_completed_response()]
    )
    reviewer_bin = root / "reviewer-bin"
    _write_fake_claude_executable(
        reviewer_bin,
        name="claude-reviewer",
        responses=resolved_reviewer_responses,
        observe_runtime_dir=observe_reviewer_runtime_dir,
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


def _halt_with_checkpoint(
    scenario: _Scenario, *, retry_budget: RetryBudget
) -> RetryCheckpointedTransactionResult:
    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=retry_budget
    )
    assert isinstance(result, RetryCheckpointedTransactionResult)
    return result


# ===========================================================================
# Section A -- result shapes (AC-9.13.4/5)
# ===========================================================================


def test_disposition_enum_exact_vocabulary() -> None:
    assert {member.name: member.value for member in ResumeExecutionDisposition} == {
        "NO_CHECKPOINT": "no_checkpoint",
        "RETRY_EXHAUSTED": "retry_exhausted",
        "STARTED_RECOVERY_REQUIRED": "started_recovery_required",
        "AUTHORITY_NOT_EXECUTABLE": "authority_not_executable",
        "SETTLED": "settled",
    }


def test_resume_execution_result_is_frozen_slotted_with_exact_fields(tmp_path: Path) -> None:
    scenario = _prepare_scenario(tmp_path / "scenario")

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ResumeExecutionResult)
    assert {f.name for f in fields(result)} == {"disposition", "claim", "settlement", "final_state"}
    assert not hasattr(result, "__dict__")
    with pytest.raises(FrozenInstanceError):
        result.disposition = result.disposition  # type: ignore[misc]
    assert "claim" not in repr(result)


def test_resume_single_subphase_transaction_signature() -> None:
    signature = inspect.signature(resume_single_subphase_transaction)
    assert set(signature.parameters) == {"request", "agent_turn_runtime"}
    assert signature.parameters["agent_turn_runtime"].kind is inspect.Parameter.KEYWORD_ONLY
    for forbidden in ("retry_budget", "attempt", "target_role", "planner_decision", "prompt"):
        assert forbidden not in signature.parameters


# ===========================================================================
# Section B -- inspection matrix (sections 18-24, 87-90, 55)
# ===========================================================================


def test_no_checkpoint_returns_disposition_with_no_mutation(tmp_path: Path) -> None:
    scenario = _prepare_scenario(tmp_path / "scenario")
    scenario.request.runtime_dir.mkdir(parents=True, exist_ok=True)

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.NO_CHECKPOINT
    assert result.claim is None
    assert result.settlement is None
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 0
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 0
    assert not retry_checkpoint_path(scenario.request.runtime_dir).exists()
    assert not resume_claim_path(scenario.request.runtime_dir).exists()


def test_retry_exhausted_returns_disposition_checkpoint_untouched(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            )
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(1))
    checkpoint_bytes_before = retry_checkpoint_path(scenario.request.runtime_dir).read_bytes()

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.RETRY_EXHAUSTED
    assert result.claim is None
    assert result.settlement is None
    assert (
        retry_checkpoint_path(scenario.request.runtime_dir).read_bytes() == checkpoint_bytes_before
    )
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1


def test_existing_claimed_restart_does_not_reclaim(tmp_path: Path) -> None:
    from lockstep.resume import claim_retry_checkpoint

    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
        reviewer_responses=[_reviewer_turn_completed_response(attempt=2, verdict="approve")],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    pre_claim_inspection = claim_retry_checkpoint(scenario.request.runtime_dir)
    assert pre_claim_inspection.claim is not None
    claim_path = resume_claim_path(scenario.request.runtime_dir)
    claim_bytes_before = claim_path.read_bytes()

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert not claim_path.exists()
    # No second claim.json was ever written between the pre-existing CLAIMED
    # restart and the eventual STARTED transition -- proven indirectly by the
    # single Implementer invocation and successful settlement below.
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 2
    del claim_bytes_before


def test_started_without_settlement_is_recovery_required_zero_inference(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))
    baseline_invocations = _invocation_count(scenario.implementer_bin, "claude-implementer")

    from lockstep.resume import claim_retry_checkpoint, mark_resume_started

    inspection = claim_retry_checkpoint(scenario.request.runtime_dir)
    assert inspection.claim is not None
    mark_resume_started(scenario.request.runtime_dir, inspection.claim)

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.STARTED_RECOVERY_REQUIRED
    assert result.claim is not None
    assert result.claim.status.value == "started"
    assert result.settlement is None
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == baseline_invocations

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.HALTED


def test_started_with_completed_settlement_finalizes_only(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))
    baseline_invocations = _invocation_count(scenario.implementer_bin, "claude-implementer")

    from lockstep.resume import claim_retry_checkpoint, mark_resume_started

    inspection = claim_retry_checkpoint(scenario.request.runtime_dir)
    assert inspection.claim is not None
    started_claim = mark_resume_started(scenario.request.runtime_dir, inspection.claim)
    settlement = ResumeSettlement(
        schema_version=1, claim=started_claim, outcome=ResumeSettlementOutcome.COMPLETED
    )
    freeze_resume_settlement(scenario.request.runtime_dir, settlement)

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert result.settlement is not None
    assert result.settlement.outcome == ResumeSettlementOutcome.COMPLETED
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == baseline_invocations
    assert not resume_claim_path(scenario.request.runtime_dir).exists()


def test_started_with_next_retry_settlement_finalizes_only(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    from lockstep.resume import claim_retry_checkpoint, mark_resume_started
    from lockstep.retry_checkpoint import create_retry_checkpoint_from_review

    inspection = claim_retry_checkpoint(scenario.request.runtime_dir)
    assert inspection.claim is not None
    started_claim = mark_resume_started(scenario.request.runtime_dir, inspection.claim)

    executed_attempt = started_claim.checkpoint.next_attempt_state
    assert executed_attempt is not None
    next_budget = started_claim.checkpoint.budget

    # A synthetic, but structurally real, retry authority for the executed
    # attempt (2) -- a REWORK verdict is the simplest way to construct a
    # valid RetryCheckpoint chaining from `next_attempt_state`; the actual
    # role invocation that would have produced it never happens here, since
    # this test only exercises the settlement-recovery finalize-only path.
    synthetic_rework = ReviewDecision(
        schema_version=1,
        phase_id=executed_attempt.phase_id,
        subphase_id=executed_attempt.subphase_id,
        attempt=executed_attempt.current_attempt,
        verdict="rework",
        summary="synthetic rework for settlement-recovery fixture",
    )
    next_checkpoint = create_retry_checkpoint_from_review(
        attempt_state=executed_attempt, budget=next_budget, decision=synthetic_rework
    )
    assert next_checkpoint is not None

    settlement = ResumeSettlement(
        schema_version=1,
        claim=started_claim,
        outcome=ResumeSettlementOutcome.NEXT_RETRY,
        next_checkpoint=next_checkpoint,
    )
    # Freeze only -- simulating an interrupted finalization that recorded the
    # settlement but never removed the STARTED claim. resume_single_subphase_
    # transaction must complete exactly that finalization, idempotently, with
    # zero role inference.
    freeze_resume_settlement(scenario.request.runtime_dir, settlement)

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert result.settlement is not None
    assert result.settlement.outcome == ResumeSettlementOutcome.NEXT_RETRY
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1
    assert not resume_claim_path(scenario.request.runtime_dir).exists()
    assert load_retry_checkpoint(scenario.request.runtime_dir) == next_checkpoint


# ===========================================================================
# Section C -- request/runtime/state preflights (sections 27, 90-91)
# ===========================================================================


def test_request_phase_mismatch_rejected_before_started(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            )
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    object.__setattr__(scenario.request, "phase_id", _phase_id("99"))

    with pytest.raises(ResumeExecutionError) as exc_info:
        resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)

    assert exc_info.value.stage == "resume_identity"
    claim_path = resume_claim_path(scenario.request.runtime_dir)
    assert claim_path.exists()
    from lockstep.resume import ResumeClaimStatus, _hydrate_claim  # type: ignore[attr-defined]

    stored_claim = _hydrate_claim(claim_path)
    assert stored_claim.status == ResumeClaimStatus.CLAIMED
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1


def test_request_subphase_mismatch_rejected_before_started(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            )
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    object.__setattr__(scenario.request, "subphase_id", _subphase_id("99"))

    with pytest.raises(ResumeExecutionError) as exc_info:
        resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)

    assert exc_info.value.stage == "resume_identity"
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1


def test_workflow_state_not_halted_rejected_before_started(tmp_path: Path) -> None:
    from datetime import UTC, datetime

    from lockstep.persistence import append_event, replay_events, write_state
    from lockstep.persistence.events import StateTransitionedEvent

    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            )
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    journal_path = scenario.request.runtime_dir / "events.jsonl"
    state_path = scenario.request.runtime_dir / "state.json"
    events = read_events(journal_path)
    next_sequence = len(events) + 1
    event = StateTransitionedEvent(
        run_id=scenario.request.run_id,
        sequence=next_sequence,
        occurred_at=datetime.now(UTC),
        source=WorkflowState.HALTED,
        target=WorkflowState.IMPLEMENTING,
    )
    append_event(journal_path, event)
    write_state(state_path, replay_events(read_events(journal_path)))

    with pytest.raises(ResumeExecutionError) as exc_info:
        resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)

    assert exc_info.value.stage == "workflow_state"
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1


# ===========================================================================
# Section D -- executability matrix (sections 36-41 original; 28 update2)
# ===========================================================================


def test_review_rework_target_implementer_is_executable(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        reviewer_responses=[
            _reviewer_turn_completed_response(verdict="rework", summary="needs changes"),
            _reviewer_turn_completed_response(attempt=2, verdict="approve"),
        ],
        implementer_responses=[
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert result.settlement is not None
    assert result.settlement.outcome == ResumeSettlementOutcome.COMPLETED


def test_implementer_bounded_change_is_executable(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
        reviewer_responses=[_reviewer_turn_completed_response(attempt=2, verdict="approve")],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 2


def test_reviewer_bounded_change_no_paths_is_executable(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE, authorized_paths=()
            ),
        ],
        reviewer_responses=[
            _reviewer_turn_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _reviewer_turn_completed_response(attempt=2, verdict="approve"),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 2
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1


def test_reviewer_bounded_change_with_paths_is_not_executable(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
                authorized_paths=("extra.txt",),
            ),
        ],
        reviewer_responses=[
            _reviewer_turn_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.AUTHORITY_NOT_EXECUTABLE
    assert result.claim is not None
    assert result.claim.status.value == "claimed"
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.HALTED
    assert resume_claim_path(scenario.request.runtime_dir).exists()


def test_reviewer_frozen_correction_is_not_executable(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
                authorized_paths=("tests/test_feature.py",),
            ),
        ],
        reviewer_responses=[
            _reviewer_turn_blocked_response(
                category=EscalationCategory.TEST_DEFECT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.AUTHORITY_NOT_EXECUTABLE
    assert result.claim is not None
    assert result.claim.status.value == "claimed"
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1
    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.HALTED


def test_implementer_frozen_correction_is_executable(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
                authorized_paths=("tests/test_feature.py",),
            ),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.TEST_DEFECT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response(
                {
                    "tests/test_feature.py": _TEST_FILE_CORRECTED,
                    "feature.py": _IMPL_CORRECTED_FOR_FIXED_TEST,
                }
            ),
        ],
        reviewer_responses=[_reviewer_turn_completed_response(attempt=2, verdict="approve")],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED


# ===========================================================================
# Section E -- STARTED-before-launch, transition-before-launch, at-most-once
# (sections 92-94 original)
# ===========================================================================


def test_mark_started_and_transition_persisted_before_agent_launch(tmp_path: Path) -> None:
    root = tmp_path / "scenario"
    root.mkdir(parents=True)
    runtime_dir = root / "runtime"

    scenario = _prepare_scenario(
        root,
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
        reviewer_responses=[_reviewer_turn_completed_response(attempt=2, verdict="approve")],
        observe_implementer_runtime_dir=runtime_dir,
    )
    assert scenario.request.runtime_dir == runtime_dir
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert result.disposition == ResumeExecutionDisposition.SETTLED

    observed = _observed(scenario.implementer_bin, "claude-implementer", 1)
    assert observed["claim"] is not None
    assert observed["claim"]["status"] == "started"
    assert observed["state"] is not None
    assert observed["state"]["workflow_state"] == "implementing"


def test_reviewer_transition_persisted_before_agent_launch(tmp_path: Path) -> None:
    root = tmp_path / "scenario"
    root.mkdir(parents=True)
    runtime_dir = root / "runtime"

    scenario = _prepare_scenario(
        root,
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE, authorized_paths=()
            ),
        ],
        reviewer_responses=[
            _reviewer_turn_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _reviewer_turn_completed_response(attempt=2, verdict="approve"),
        ],
        observe_reviewer_runtime_dir=runtime_dir,
    )
    assert scenario.request.runtime_dir == runtime_dir
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert result.disposition == ResumeExecutionDisposition.SETTLED

    observed = _observed(scenario.reviewer_bin, "claude-reviewer", 1)
    assert observed["claim"] is not None
    assert observed["claim"]["status"] == "started"
    assert observed["state"] is not None
    assert observed["state"]["workflow_state"] == "reviewing"


def test_at_most_one_invocation_per_resume_call(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
        reviewer_responses=[_reviewer_turn_completed_response(attempt=2, verdict="approve")],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)

    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 2
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1


# ===========================================================================
# Section F -- concurrency (section 95 original; 50 update2)
# ===========================================================================


def test_concurrent_second_caller_gets_recovery_required(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
        reviewer_responses=[_reviewer_turn_completed_response(attempt=2, verdict="approve")],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    original_invoke_agent_turn = transaction_module.invoke_agent_turn
    entered = threading.Event()
    release = threading.Event()

    def blocking_invoke_agent_turn(*args: object, **kwargs: object) -> AgentTurnResult:
        entered.set()
        release.wait(timeout=5)
        return original_invoke_agent_turn(*args, **kwargs)  # type: ignore[arg-type]

    monkeypatch.setattr(transaction_module, "invoke_agent_turn", blocking_invoke_agent_turn)

    results: list[ResumeExecutionResult] = []
    errors: list[BaseException] = []

    def caller_a() -> None:
        try:
            results.append(
                resume_single_subphase_transaction(
                    scenario.request, agent_turn_runtime=scenario.runtime
                )
            )
        except BaseException as exc:
            errors.append(exc)

    thread_a = threading.Thread(target=caller_a)
    thread_a.start()
    assert entered.wait(timeout=5)

    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1

    result_b = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result_b.disposition == ResumeExecutionDisposition.STARTED_RECOVERY_REQUIRED
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1

    release.set()
    thread_a.join(timeout=5)

    assert not errors
    assert len(results) == 1
    assert results[0].disposition == ResumeExecutionDisposition.SETTLED
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 2


# ===========================================================================
# Section G -- outcomes (sections 56-61 original; 41-44 update2)
# ===========================================================================


def test_resumed_approve_reaches_subphase_complete_and_settles(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
        reviewer_responses=[_reviewer_turn_completed_response(attempt=2, verdict="approve")],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert result.final_state is not None
    assert result.final_state.workflow_state == WorkflowState.SUBPHASE_COMPLETE
    assert result.settlement is not None
    assert result.settlement.outcome == ResumeSettlementOutcome.COMPLETED
    assert result.settlement.next_checkpoint is None
    assert not retry_checkpoint_path(scenario.request.runtime_dir).exists()
    assert not resume_claim_path(scenario.request.runtime_dir).exists()
    assert _log_subjects(scenario.request.worktree_path)[0] == "feat(feature): implement answer"

    # Subsequent resume calls see no checkpoint -- no replay.
    second = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert second.disposition == ResumeExecutionDisposition.NO_CHECKPOINT
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 2


def test_resumed_rework_creates_next_retry_checkpoint(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
        reviewer_responses=[
            _reviewer_turn_completed_response(attempt=2, verdict="rework", summary="needs more")
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert result.settlement is not None
    assert result.settlement.outcome == ResumeSettlementOutcome.NEXT_RETRY
    checkpoint = result.settlement.next_checkpoint
    assert checkpoint is not None
    assert checkpoint.attempt_state.current_attempt == _attempt(2)
    assert checkpoint.next_attempt_state is not None
    assert checkpoint.next_attempt_state.current_attempt == _attempt(3)
    assert checkpoint.retry_request.target_role == AgentRole.IMPLEMENTER

    loaded = load_retry_checkpoint(scenario.request.runtime_dir)
    assert loaded == checkpoint

    from lockstep.resume import ResumeDisposition, inspect_resume

    inspection = inspect_resume(scenario.request.runtime_dir)
    assert inspection.disposition == ResumeDisposition.RETRY_AVAILABLE


def test_resumed_retryable_blocker_creates_next_retry(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert result.settlement is not None
    assert result.settlement.outcome == ResumeSettlementOutcome.NEXT_RETRY
    checkpoint = result.settlement.next_checkpoint
    assert checkpoint is not None
    assert checkpoint.next_attempt_state is not None
    assert checkpoint.next_attempt_state.current_attempt == _attempt(3)


def test_resumed_nonretryable_blocker_settles_halted(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
            _planner_decision_response(kind=PlannerDecisionKind.TERMINAL_HALT),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_blocked_response(
                category=EscalationCategory.PLANNER_DECISION_REQUIRED,
                requested_authority=EscalationAuthority.PLANNER,
            ),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert result.settlement is not None
    assert result.settlement.outcome == ResumeSettlementOutcome.HALTED
    assert result.settlement.next_checkpoint is None
    assert not retry_checkpoint_path(scenario.request.runtime_dir).exists()

    second = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert second.disposition == ResumeExecutionDisposition.NO_CHECKPOINT


def test_resumed_reviewer_halt_settles_halted(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
        reviewer_responses=[
            _reviewer_turn_completed_response(attempt=2, verdict="halt", summary="must halt")
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert result.settlement is not None
    assert result.settlement.outcome == ResumeSettlementOutcome.HALTED
    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.HALTED


# ===========================================================================
# Section H -- known typed failures (sections 63-67 original; 45-47 update2)
# ===========================================================================


def test_agent_turn_error_settles_execution_failed_and_reraises(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _process_failure_response(),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    with pytest.raises(AgentTurnError):
        resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.HALTED
    assert not resume_claim_path(scenario.request.runtime_dir).exists()

    second = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert second.disposition == ResumeExecutionDisposition.NO_CHECKPOINT
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 2


def test_reviewer_turn_error_settles_execution_failed_and_reraises(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
        reviewer_responses=[_malformed_stdout_response()],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    with pytest.raises(ReviewerTurnError):
        resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.HALTED
    assert not resume_claim_path(scenario.request.runtime_dir).exists()


def test_planner_dispatch_failure_after_blocked_settles_execution_failed(
    tmp_path: Path,
) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
            _malformed_stdout_response(),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    from lockstep.escalation_transport import PlannerDecisionTransportError

    with pytest.raises(PlannerDecisionTransportError):
        resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.HALTED
    assert not retry_checkpoint_path(scenario.request.runtime_dir).exists()
    assert not resume_claim_path(scenario.request.runtime_dir).exists()


def test_unexpected_exception_leaves_started_ambiguous(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    def _boom(*args: object, **kwargs: object) -> object:
        raise RuntimeError("injected unexpected bug")

    monkeypatch.setattr(transaction_module, "invoke_agent_turn", _boom)

    with pytest.raises(RuntimeError, match="injected unexpected bug"):
        resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)

    claim_path = resume_claim_path(scenario.request.runtime_dir)
    assert claim_path.exists()
    from lockstep.resume import ResumeClaimStatus, _hydrate_claim  # type: ignore[attr-defined]

    assert _hydrate_claim(claim_path).status == ResumeClaimStatus.STARTED
    settlement_dir = scenario.request.runtime_dir / "retry" / "settlements"
    assert not settlement_dir.exists() or not list(settlement_dir.iterdir())

    monkeypatch.undo()
    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert result.disposition == ResumeExecutionDisposition.STARTED_RECOVERY_REQUIRED
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1


# ===========================================================================
# Section I -- multi-attempt chain, one attempt per call (sections 71-73
# original; 48-49 update2)
# ===========================================================================


def test_two_call_attempt_chain_2_then_3(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        reviewer_responses=[
            _reviewer_turn_completed_response(attempt=1, verdict="rework", summary="round 1"),
            _reviewer_turn_completed_response(attempt=2, verdict="rework", summary="round 2"),
            _reviewer_turn_completed_response(attempt=3, verdict="approve"),
        ],
        implementer_responses=[
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    from lockstep.resume import ResumeDisposition, inspect_resume

    assert (
        inspect_resume(scenario.request.runtime_dir).disposition
        == ResumeDisposition.RETRY_AVAILABLE
    )
    checkpoint_before_call_1 = load_retry_checkpoint(scenario.request.runtime_dir)
    assert checkpoint_before_call_1 is not None
    assert checkpoint_before_call_1.next_attempt_state is not None
    assert checkpoint_before_call_1.next_attempt_state.current_attempt == _attempt(2)

    result_1 = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert result_1.disposition == ResumeExecutionDisposition.SETTLED
    assert result_1.settlement is not None
    assert result_1.settlement.outcome == ResumeSettlementOutcome.NEXT_RETRY
    checkpoint_after_call_1 = result_1.settlement.next_checkpoint
    assert checkpoint_after_call_1 is not None
    assert checkpoint_after_call_1.attempt_state.current_attempt == _attempt(2)
    assert checkpoint_after_call_1.next_attempt_state is not None
    assert checkpoint_after_call_1.next_attempt_state.current_attempt == _attempt(3)
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 2
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 2

    assert (
        inspect_resume(scenario.request.runtime_dir).disposition
        == ResumeDisposition.RETRY_AVAILABLE
    )

    result_2 = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert result_2.disposition == ResumeExecutionDisposition.SETTLED
    assert result_2.settlement is not None
    assert result_2.settlement.outcome == ResumeSettlementOutcome.COMPLETED
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 3
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 3


def test_exhausted_chain_no_further_launch(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        reviewer_responses=[
            _reviewer_turn_completed_response(attempt=1, verdict="rework", summary="round 1"),
            _reviewer_turn_completed_response(attempt=2, verdict="rework", summary="round 2"),
        ],
        implementer_responses=[
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(2))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert result.settlement is not None
    checkpoint = result.settlement.next_checkpoint
    assert checkpoint is not None
    assert checkpoint.next_attempt_state is None

    from lockstep.resume import ResumeDisposition, inspect_resume

    assert (
        inspect_resume(scenario.request.runtime_dir).disposition
        == ResumeDisposition.RETRY_EXHAUSTED
    )

    result_2 = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert result_2.disposition == ResumeExecutionDisposition.RETRY_EXHAUSTED
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 2


# ===========================================================================
# Section J -- frozen-artifact correction (sections 74-75, 105-107 original;
# 51-53 update2)
# ===========================================================================


def test_frozen_correction_major_witness_two_commits(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
                authorized_paths=("tests/test_feature.py",),
            ),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.TEST_DEFECT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response(
                {
                    "tests/test_feature.py": _TEST_FILE_CORRECTED,
                    "feature.py": _IMPL_CORRECTED_FOR_FIXED_TEST,
                }
            ),
        ],
        reviewer_responses=[_reviewer_turn_completed_response(attempt=2, verdict="approve")],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert result.settlement is not None
    assert result.settlement.outcome == ResumeSettlementOutcome.COMPLETED
    assert result.final_state is not None
    assert result.final_state.workflow_state == WorkflowState.SUBPHASE_COMPLETE

    subjects = _log_subjects(scenario.request.worktree_path)
    assert subjects[:3] == [
        "feat(feature): implement answer",
        "fix: correct frozen retry artifacts",
        "test(feature): freeze answer expectation",
    ]
    assert _log_paths_for(
        scenario.request.worktree_path, "fix: correct frozen retry artifacts"
    ) == ("tests/test_feature.py",)
    assert _log_paths_for(scenario.request.worktree_path, "feat(feature): implement answer") == (
        "feature.py",
    )
    assert inspect_repository(scenario.request.worktree_path).is_clean


def test_frozen_correction_unauthorized_path_rejected_before_commit(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
                authorized_paths=("tests/test_feature.py",),
            ),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.TEST_DEFECT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response(
                {
                    "tests/test_feature.py": _TEST_FILE_CORRECTED,
                    "unauthorized_extra.txt": "unauthorized content\n",
                }
            ),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    with pytest.raises(SupervisorTransactionError) as exc_info:
        resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)

    assert exc_info.value.stage == "frozen_correction_scope"
    assert (
        _log_subjects(scenario.request.worktree_path)[0]
        == "test(feature): freeze answer expectation"
    )
    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.HALTED
    assert not resume_claim_path(scenario.request.runtime_dir).exists()


def test_frozen_correction_no_authorized_change_rejected(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
                authorized_paths=("tests/test_feature.py",),
            ),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.TEST_DEFECT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    with pytest.raises(SupervisorTransactionError) as exc_info:
        resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)

    assert exc_info.value.stage == "frozen_correction_scope"
    assert (
        _log_subjects(scenario.request.worktree_path)[0]
        == "test(feature): freeze answer expectation"
    )


def test_frozen_correction_no_commit_when_resumed_agent_reblocks(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
                authorized_paths=("tests/test_feature.py",),
            ),
            _planner_decision_response(kind=PlannerDecisionKind.TERMINAL_HALT),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.TEST_DEFECT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_blocked_response(
                category=EscalationCategory.PLANNER_DECISION_REQUIRED,
                requested_authority=EscalationAuthority.PLANNER,
                files={"tests/test_feature.py": _TEST_FILE_CORRECTED},
            ),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert result.settlement is not None
    assert result.settlement.outcome == ResumeSettlementOutcome.HALTED
    assert (
        _log_subjects(scenario.request.worktree_path)[0]
        == "test(feature): freeze answer expectation"
    )
    assert not inspect_repository(scenario.request.worktree_path).is_clean


# ===========================================================================
# Section K -- bounded-change extra write path (sections 108-109 original;
# 54 update2)
# ===========================================================================


def test_bounded_change_extra_path_included_in_production_commit(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
                authorized_paths=("extra_feature.py",),
            ),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response(
                {"feature.py": _IMPL_CORRECT, "extra_feature.py": "extra = True\n"}
            ),
        ],
        reviewer_responses=[_reviewer_turn_completed_response(attempt=2, verdict="approve")],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    committed = _log_paths_for(scenario.request.worktree_path, "feat(feature): implement answer")
    assert committed == ("extra_feature.py", "feature.py")


def test_bounded_change_unauthorized_extra_path_rejected(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response(
                {"feature.py": _IMPL_CORRECT, "unauthorized_extra.py": "nope = True\n"}
            ),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    with pytest.raises(SupervisorTransactionError) as exc_info:
        resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)

    assert exc_info.value.stage == "implementation_scope"
    assert (
        _log_subjects(scenario.request.worktree_path)[0]
        == "test(feature): freeze answer expectation"
    )


# ===========================================================================
# Section L -- deterministic resume-authority prompt (sections 30-33
# original; 29 update2)
# ===========================================================================


def test_deterministic_resume_prompt_byte_identical(tmp_path: Path) -> None:
    # Two independently-constructed, value-equal claims (same request/claim/
    # base-prompt content, different run identifiers) must yield a
    # byte-identical resume-authority prompt suffix.
    scenario_a = _prepare_scenario(
        tmp_path / "a",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
                rationale="Deterministic sentinel rationale.",
                instructions=("Deterministic sentinel instruction.",),
            ),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                question="Deterministic sentinel question?",
                evidence=("Deterministic sentinel evidence.",),
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
        run_id="20260928-013-a",
    )
    scenario_b = _prepare_scenario(
        tmp_path / "b",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
                rationale="Deterministic sentinel rationale.",
                instructions=("Deterministic sentinel instruction.",),
            ),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                question="Deterministic sentinel question?",
                evidence=("Deterministic sentinel evidence.",),
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        ],
        run_id="20260928-013-b",
    )
    checkpointed_a = _halt_with_checkpoint(scenario_a, retry_budget=_budget(3))
    checkpointed_b = _halt_with_checkpoint(scenario_b, retry_budget=_budget(3))

    assert checkpointed_a.checkpoint.authority == checkpointed_b.checkpoint.authority
    assert (
        checkpointed_a.checkpoint.next_attempt_state == checkpointed_b.checkpoint.next_attempt_state
    )

    from lockstep.resume import claim_retry_checkpoint
    from lockstep.supervisor.transaction import _resume_prompt_suffix  # type: ignore[attr-defined]

    claim_a = claim_retry_checkpoint(scenario_a.request.runtime_dir).claim
    claim_b = claim_retry_checkpoint(scenario_b.request.runtime_dir).claim
    assert claim_a is not None
    assert claim_b is not None

    suffix_a = _resume_prompt_suffix(claim_a, _attempt(2), AgentRole.IMPLEMENTER)
    suffix_b = _resume_prompt_suffix(claim_b, _attempt(2), AgentRole.IMPLEMENTER)
    assert suffix_a == suffix_b
    assert suffix_a.encode("utf-8") == suffix_b.encode("utf-8")


def test_escalation_resume_prompt_contains_required_fields(tmp_path: Path) -> None:
    from lockstep.resume import claim_retry_checkpoint
    from lockstep.supervisor.transaction import _resume_prompt_suffix  # type: ignore[attr-defined]

    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
                rationale="SENTINEL-RATIONALE-9f2c",
                instructions=("SENTINEL-INSTRUCTION-7a1e",),
                authorized_paths=("extra_feature.py",),
            ),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                question="SENTINEL-QUESTION-3d5e",
                evidence=("SENTINEL-EVIDENCE-1b4f",),
                requested_authority=EscalationAuthority.PLANNER,
            ),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    claim = claim_retry_checkpoint(scenario.request.runtime_dir).claim
    assert claim is not None
    suffix = _resume_prompt_suffix(claim, _attempt(2), AgentRole.IMPLEMENTER)

    for sentinel in (
        "SENTINEL-RATIONALE-9f2c",
        "SENTINEL-INSTRUCTION-7a1e",
        "SENTINEL-QUESTION-3d5e",
        "SENTINEL-EVIDENCE-1b4f",
        "extra_feature.py",
        "architecture_conflict",
        "authorize_bounded_change",
        "implementer",
    ):
        assert sentinel in suffix
    assert "2" in suffix


def test_review_rework_prompt_contains_required_fields(tmp_path: Path) -> None:
    from lockstep.resume import claim_retry_checkpoint
    from lockstep.supervisor.transaction import _resume_prompt_suffix  # type: ignore[attr-defined]

    scenario = _prepare_scenario(
        tmp_path / "scenario",
        reviewer_responses=[
            _reviewer_turn_completed_response(
                verdict="rework",
                summary="SENTINEL-SUMMARY-6c2d",
                findings=[
                    {
                        "summary": "SENTINEL-FINDING-SUMMARY-8e1a",
                        "evidence": "SENTINEL-FINDING-EVIDENCE-4f9b",
                        "file_path": None,
                        "acceptance_criterion_id": None,
                    }
                ],
            )
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    claim = claim_retry_checkpoint(scenario.request.runtime_dir).claim
    assert claim is not None
    suffix = _resume_prompt_suffix(claim, _attempt(2), AgentRole.IMPLEMENTER)

    for sentinel in (
        "SENTINEL-SUMMARY-6c2d",
        "SENTINEL-FINDING-SUMMARY-8e1a",
        "SENTINEL-FINDING-EVIDENCE-4f9b",
        "implementer",
    ):
        assert sentinel in suffix


def test_resume_prompt_excludes_provider_telemetry(tmp_path: Path) -> None:
    from lockstep.resume import claim_retry_checkpoint
    from lockstep.supervisor.transaction import _resume_prompt_suffix  # type: ignore[attr-defined]

    stdout_sentinel = "STDOUT-TELEMETRY-SENTINEL-2a7c"
    stderr_sentinel = "STDERR-TELEMETRY-SENTINEL-5b3d"
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
                stderr=stderr_sentinel,
            ),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    claim = claim_retry_checkpoint(scenario.request.runtime_dir).claim
    assert claim is not None
    suffix = _resume_prompt_suffix(claim, _attempt(2), AgentRole.IMPLEMENTER)

    assert stdout_sentinel not in suffix
    assert stderr_sentinel not in suffix
    assert "stdout" not in suffix
    assert "stderr" not in suffix
    assert "provider" not in suffix
    assert "adapter" not in suffix


# ===========================================================================
# Section M -- FSM regression pinned from this test file too (section 27
# update2)
# ===========================================================================


def test_fsm_pins_halted_reentry_edges_and_complete_terminality() -> None:
    assert allowed_transitions(WorkflowState.HALTED) == frozenset(
        {WorkflowState.IMPLEMENTING, WorkflowState.REVIEWING}
    )
    assert allowed_transitions(WorkflowState.COMPLETE) == frozenset()


# ===========================================================================
# Section N -- import/dependency boundary (sections 68/116 original)
# ===========================================================================


def test_import_cycle_smoke_across_orders() -> None:
    statements = (
        "import lockstep.runtime; import lockstep.resume; import lockstep.resume_settlement; "
        "import lockstep.retry_checkpoint; import lockstep.supervisor.transaction",
        "import lockstep.resume; import lockstep.resume_settlement; import lockstep.runtime; "
        "import lockstep.supervisor.transaction",
        "import lockstep.supervisor.transaction; import lockstep.resume; "
        "import lockstep.resume_settlement; import lockstep.runtime",
        "import lockstep.supervisor.transaction; import lockstep.runtime; "
        "import lockstep.resume_settlement; import lockstep.resume",
        "import lockstep.resume_settlement; import lockstep.supervisor.transaction; "
        "import lockstep.runtime; import lockstep.resume",
    )
    for statement in statements:
        result = subprocess.run([sys.executable, "-c", statement], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr


def test_transaction_module_has_no_top_level_resume_import() -> None:
    tree = ast.parse(inspect.getsource(transaction_module))
    module_body_names: set[str] = set()
    for node in tree.body:
        if isinstance(node, ast.ImportFrom):
            module = node.module or ""
            if module in ("lockstep.resume", "lockstep.resume_settlement"):
                module_body_names.add(module)
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.name in ("lockstep.resume", "lockstep.resume_settlement"):
                    module_body_names.add(alias.name)
    assert not module_body_names


def test_no_supervisor_package_reexport() -> None:
    import lockstep.supervisor as supervisor_package

    assert "resume_single_subphase_transaction" not in supervisor_package.__all__
    assert not hasattr(supervisor_package, "ResumeExecutionResult")
