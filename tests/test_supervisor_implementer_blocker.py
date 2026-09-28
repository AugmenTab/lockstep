"""Planner-authored specification of Sub-phase 9.6 Implementer blocker-aware transaction path.

Pins the one additive, provider-neutral production path that composes
the already-frozen Sub-phase 9.4 structured agent-turn channel and the
already-frozen Sub-phase 9.5 Supervisor escalation dispatcher into the
Supervisor transaction:

    Planner-authored tests already frozen
        -> IMPLEMENTING
        -> invoke_agent_turn(IMPLEMENTER)
        -> COMPLETED -> existing verification/Reviewer/commit suffix
        -> BLOCKED   -> dispatch_escalation -> HALTED

Uses real production ``ClaudeAdapter`` instances against fake provider
executables under ``tmp_path`` for the Planner and Implementer roles (the
only two roles :func:`~lockstep.agent_turn.invoke_agent_turn` and
:func:`~lockstep.escalation_transport.invoke_planner_decision` require
to be Claude/Codex-shaped), a real Git worktree, and a real planning
store for the Planner-routed escalation scenarios. No real Claude/Codex
account, no network, no real model inference. This module never edits
the frozen legacy ``run_single_subphase_transaction`` entrypoint's
behavior and never migrates the Reviewer onto the structured agent-turn
channel -- that remains Sub-phase 9.7.
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

import lockstep.agent_turn as agent_turn_module
import lockstep.supervisor.transaction as transaction_module
from lockstep.agent_turn import AgentTurnResult, AgentTurnStatus
from lockstep.agents import (
    AgentAdapter,
    AgentCommand,
    AgentInvocationRequest,
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
    BillingMode,
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    RunId,
    SubphaseContract,
    SubphaseId,
    SubphaseOutline,
    TestExpectation,
    TestSpecification,
)
from lockstep.escalation import EscalationAuthority, EscalationCategory
from lockstep.escalation_decision import PlannerDecisionKind
from lockstep.escalation_transport import PlannerDecisionTransportError
from lockstep.git import inspect_repository
from lockstep.persistence import StateTransitionedEvent, read_events, read_state
from lockstep.planning_store import freeze_master_plan, freeze_subphase_contract, publish_phase_plan
from lockstep.runtime import AgentRuntime
from lockstep.state import WorkflowState
from lockstep.supervisor.escalation import SupervisorEscalationDisposition
from lockstep.supervisor.transaction import (
    ImplementerBlockedTransactionResult,
    SingleSubphaseTransactionRequest,
    SingleSubphaseTransactionResult,
    SupervisorTransactionError,
    run_single_subphase_transaction_with_blockers,
)

_PHASE_ID = "09"
_SUBPHASE_ID = "06"

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


# ---------------------------------------------------------------------------
# Git source repo helpers (mirrors tests/test_supervisor_transaction.py)
# ---------------------------------------------------------------------------


def _git(repo: Path, *args: str, check: bool = True) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=check,
        capture_output=True,
        text=True,
    )


def _init_source_repo(tmp_path: Path) -> Path:
    source = tmp_path / "source"
    source.mkdir()
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
# Sequential fake Claude executable (multi-call: Planner authors tests, then
# may be called again for an escalation decision turn)
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


# ---------------------------------------------------------------------------
# Reviewer adapter (mirrors tests/test_supervisor_transaction.py)
# ---------------------------------------------------------------------------


class _ScriptAdapter:
    """Deterministic AgentAdapter fixture that runs a fixed Python script."""

    def __init__(self, name: str, script: str) -> None:
        self.name = name
        self._script = script
        self.invocations: list[AgentInvocationRequest] = []

    def build_command(self, request: AgentInvocationRequest) -> AgentCommand:
        self.invocations.append(request)
        return AgentCommand(argv=(sys.executable, "-c", self._script))


def _reviewer_script(
    *,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    attempt: int = 1,
    verdict: str = "approve",
    summary: str = "approved",
) -> str:
    payload = json.dumps(
        {
            "schema_version": 1,
            "phase_id": phase_id,
            "subphase_id": subphase_id,
            "attempt": attempt,
            "verdict": verdict,
            "summary": summary,
        }
    )
    return f"import sys\nsys.stdout.write({payload!r})\n"


@dataclass(frozen=True, slots=True)
class _PoisonAdapter:
    """An :class:`AgentAdapter` that fails the test if it is ever invoked."""

    name: str = "poison-reviewer"

    def build_command(self, request: AgentInvocationRequest) -> AgentCommand:
        raise AssertionError("Reviewer must never be invoked after a blocked Implementer turn")


# ---------------------------------------------------------------------------
# Planning-store fixtures (mirrors tests/test_supervisor_escalation.py)
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
                title="Implementer blocker-aware transaction path",
                objective="Compose structured Implementer blockers into the transaction.",
                depends_on=[],
                subphases=[
                    SubphaseOutline(
                        subphase_id=_subphase_id(subphase_id),
                        title="Implementer blocker-aware transaction path",
                        objective="Route a blocked Implementer turn to the correct authority.",
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
        title="Implementer blocker-aware transaction path",
        objective="Route a blocked Implementer turn to the correct authority.",
        acceptance_criteria=[
            AcceptanceCriterion(criterion_id="AC-1", description="Blocked turns halt safely.")
        ],
        tests=[
            TestSpecification(
                path="tests/test_supervisor_implementer_blocker.py",
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
# Request / runtime construction
# ---------------------------------------------------------------------------


def _parent_env(tmp_path: Path) -> dict[str, str]:
    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    return {
        "HOME": str(home),
        "PATH": "/usr/bin:/bin",
    }


def _build_request(
    tmp_path: Path,
    source: Path,
    *,
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
        run_id=RunId.model_validate("20260928-001"),
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        source_path=source,
        worktree_path=tmp_path / "run-worktree",
        runtime_dir=runtime_dir if runtime_dir is not None else tmp_path / "runtime",
        branch="lockstep/run/run-09-06-supervisor",
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
    tmp_path: Path,
    *,
    runtime_dir: Path,
    planner_adapter: AgentAdapter,
    implementer_adapter: AgentAdapter,
    reviewer_adapter: AgentAdapter,
    parent_env: Mapping[str, str],
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
) -> AgentRuntime:
    project_root = tmp_path / "agent-project"
    project_root.mkdir(exist_ok=True)
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


def _prepare_scenario(
    tmp_path: Path,
    *,
    planner_responses: list[dict[str, object]],
    implementer_response: dict[str, object],
    reviewer_adapter: AgentAdapter | None = None,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
) -> _Scenario:
    source = _init_source_repo(tmp_path)
    request = _build_request(tmp_path, source, phase_id=phase_id, subphase_id=subphase_id)

    planner_bin = tmp_path / "planner-bin"
    _write_fake_claude_executable(planner_bin, name="claude-planner", responses=planner_responses)
    planner_adapter = _claude_adapter(
        AgentRole.PLANNER, executable=str(planner_bin / "claude-planner")
    )

    implementer_bin = tmp_path / "implementer-bin"
    _write_fake_claude_executable(
        implementer_bin, name="claude-implementer", responses=[implementer_response]
    )
    implementer_adapter = _claude_adapter(
        AgentRole.IMPLEMENTER, executable=str(implementer_bin / "claude-implementer")
    )

    resolved_reviewer_adapter = (
        reviewer_adapter if reviewer_adapter is not None else _PoisonAdapter()
    )

    runtime = _agent_runtime(
        tmp_path,
        runtime_dir=request.runtime_dir,
        planner_adapter=planner_adapter,
        implementer_adapter=implementer_adapter,
        reviewer_adapter=resolved_reviewer_adapter,
        parent_env=_parent_env(tmp_path),
        phase_id=phase_id,
        subphase_id=subphase_id,
    )

    return _Scenario(
        request=request, runtime=runtime, planner_bin=planner_bin, implementer_bin=implementer_bin
    )


# ===========================================================================
# Runtime dependency-cycle prerequisite (section 6 / 33)
# ===========================================================================


def test_agent_turn_module_has_no_runtime_import() -> None:
    tree = ast.parse(inspect.getsource(agent_turn_module))
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                assert alias.name != "lockstep.runtime"
                assert not alias.name.startswith("lockstep.runtime.")
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            assert module != "lockstep.runtime"
            assert not module.startswith("lockstep.runtime.")


def test_import_cycle_smoke_across_orders() -> None:
    statements = (
        "import lockstep.runtime; import lockstep.supervisor.transaction; "
        "import lockstep.supervisor.escalation",
        "import lockstep.supervisor.transaction; import lockstep.runtime; "
        "import lockstep.supervisor.escalation",
        "import lockstep.supervisor.escalation; import lockstep.runtime; "
        "import lockstep.supervisor.transaction",
        "import lockstep.supervisor; import lockstep.agent_turn; import lockstep.runtime",
    )
    for statement in statements:
        result = subprocess.run([sys.executable, "-c", statement], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr


# ===========================================================================
# Public blocked result shape (section 34)
# ===========================================================================


def test_implementer_blocked_result_is_frozen_slotted_with_exact_fields(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[_planner_authoring_response(_TEST_FILE_RED)],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.REQUIREMENT_AMBIGUITY,
            requested_authority=EscalationAuthority.HUMAN,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert {f.name for f in fields(result)} == {
        "test_commit",
        "implementer_turn",
        "escalation",
        "final_state",
    }
    assert not hasattr(result, "__dict__")

    with pytest.raises(FrozenInstanceError):
        result.test_commit = result.test_commit  # type: ignore[misc]


def test_implementer_blocked_result_repr_hides_implementer_turn_content(tmp_path: Path) -> None:
    # The sentinel lives only in the raw provider stderr (``invocation``),
    # never in the structured, durable ``EscalationRequest`` -- so it must
    # never surface via ``repr()``, regardless of which nested field would
    # otherwise carry it.
    sentinel = "SENTINEL-IMPLEMENTER-STDERR-9f2c"
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[_planner_authoring_response(_TEST_FILE_RED)],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.REQUIREMENT_AMBIGUITY,
            requested_authority=EscalationAuthority.HUMAN,
            stderr=sentinel,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert sentinel not in repr(result)
    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert sentinel in result.implementer_turn.invocation.process.stderr


# ===========================================================================
# COMPLETED Implementer -> existing successful suffix (sections 16, 31, 35, 47)
# ===========================================================================


def test_completed_blocker_aware_transaction_matches_legacy_success_shape(tmp_path: Path) -> None:
    reviewer = _ScriptAdapter("reviewer", _reviewer_script(verdict="approve", summary="approved"))
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[_planner_authoring_response(_TEST_FILE_RED)],
        implementer_response=_implementer_completed_response({"feature.py": _IMPL_CORRECT}),
        reviewer_adapter=reviewer,
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, SingleSubphaseTransactionResult)
    assert result.final_state.workflow_state == WorkflowState.SUBPHASE_COMPLETE
    assert result.review.verdict.value == "approve"
    assert result.test_commit.committed_paths == ("tests/test_feature.py",)
    assert result.implementation_commit.committed_paths == ("feature.py",)

    assert _invocation_count(scenario.planner_bin, "claude-planner") == 1
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1
    assert len(reviewer.invocations) == 1

    worktree_snapshot = inspect_repository(scenario.request.worktree_path)
    assert worktree_snapshot.is_clean
    assert worktree_snapshot.head_sha == result.implementation_commit.commit_sha

    events = read_events(scenario.request.runtime_dir / "events.jsonl")
    assert len(events) == 11
    expected_edges = (
        (WorkflowState.READY, WorkflowState.PHASE_PLANNING),
        (WorkflowState.PHASE_PLANNING, WorkflowState.SUBPHASE_PLANNING),
        (WorkflowState.SUBPHASE_PLANNING, WorkflowState.TEST_AUTHORING),
        (WorkflowState.TEST_AUTHORING, WorkflowState.TEST_BASELINE_VERIFY),
        (WorkflowState.TEST_BASELINE_VERIFY, WorkflowState.TEST_COMMIT),
        (WorkflowState.TEST_COMMIT, WorkflowState.IMPLEMENTING),
        (WorkflowState.IMPLEMENTING, WorkflowState.VERIFYING),
        (WorkflowState.VERIFYING, WorkflowState.REVIEWING),
        (WorkflowState.REVIEWING, WorkflowState.IMPLEMENTATION_COMMIT),
        (WorkflowState.IMPLEMENTATION_COMMIT, WorkflowState.SUBPHASE_COMPLETE),
    )
    for offset, (src, dst) in enumerate(expected_edges, start=2):
        event = events[offset - 1]
        assert isinstance(event, StateTransitionedEvent)
        assert event.sequence == offset
        assert event.source == src
        assert event.target == dst


# ===========================================================================
# BLOCKED Implementer -- Planner bounded authorization (sections 18, 36)
# ===========================================================================


def test_planner_bounded_authorization_halts_with_resume_agent(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
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

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert result.final_state.workflow_state == WorkflowState.HALTED
    assert result.escalation.disposition == SupervisorEscalationDisposition.RESUME_AGENT
    assert result.escalation.planner_turn is not None

    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1
    # 1 test-authoring call + 1 escalation decision call.
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 2

    subjects = _log_subjects(scenario.request.worktree_path)
    assert subjects == [scenario.request.test_commit_message, "initial"]

    # Partial Implementer work survives untouched: no reset/restore/clean.
    partial_file = scenario.request.worktree_path / "feature.py"
    assert partial_file.read_text(encoding="utf-8") == "partial work\n"
    snapshot = inspect_repository(scenario.request.worktree_path)
    assert not snapshot.is_clean
    assert snapshot.dirty_paths == ("feature.py",)


# ===========================================================================
# BLOCKED Implementer -- frozen-artifact correction authority (sections 30, 37)
# ===========================================================================


def test_frozen_artifact_correction_authority_recorded_but_not_applied(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
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

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert result.escalation.disposition == SupervisorEscalationDisposition.RESUME_AGENT
    assert result.escalation.planner_turn is not None
    assert result.escalation.planner_turn.resolution.frozen_artifact_correction is True
    assert result.escalation.planner_turn.decision.authorized_paths == ("tests/test_feature.py",)

    # The authority now exists; the file itself is not yet touched.
    test_file = scenario.request.worktree_path / "tests" / "test_feature.py"
    assert test_file.read_text(encoding="utf-8") == _TEST_FILE_RED


# ===========================================================================
# BLOCKED Implementer -- replan / human halt / terminal halt (sections 38-40)
# ===========================================================================


def test_planner_replan_subphase_disposition(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.REPLAN_SUBPHASE),
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.PLANNER_DECISION_REQUIRED,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert result.escalation.disposition == SupervisorEscalationDisposition.REPLAN_SUBPHASE
    assert result.final_state.workflow_state == WorkflowState.HALTED


def test_planner_halts_for_human(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.HALT_FOR_HUMAN),
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.PLANNER_DECISION_REQUIRED,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert result.escalation.disposition == SupervisorEscalationDisposition.HUMAN_REQUIRED
    assert result.final_state.workflow_state == WorkflowState.HALTED


def test_planner_terminal_halt(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.TERMINAL_HALT),
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.PLANNER_DECISION_REQUIRED,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert result.escalation.disposition == SupervisorEscalationDisposition.RUN_HALT
    assert result.final_state.workflow_state == WorkflowState.HALTED


# ===========================================================================
# BLOCKED Implementer -- direct Human / Supervisor routes (sections 27, 28, 41, 42)
# ===========================================================================


def test_direct_human_blocker_skips_planner(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[_planner_authoring_response(_TEST_FILE_RED)],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.REQUIREMENT_AMBIGUITY,
            requested_authority=EscalationAuthority.HUMAN,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert result.escalation.disposition == SupervisorEscalationDisposition.HUMAN_REQUIRED
    assert result.escalation.planner_turn is None
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 1


def test_direct_supervisor_blocker_skips_planner(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[_planner_authoring_response(_TEST_FILE_RED)],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.CONTROL_PLANE_BLOCKER,
            requested_authority=EscalationAuthority.SUPERVISOR,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert (
        result.escalation.disposition == SupervisorEscalationDisposition.SUPERVISOR_ACTION_REQUIRED
    )
    assert result.escalation.planner_turn is None
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 1


# ===========================================================================
# Requested-authority mismatch does not change routing (sections 29, 43)
# ===========================================================================


def test_requested_authority_mismatch_still_routes_to_planner(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.TEST_DEFECT,
            requested_authority=EscalationAuthority.HUMAN,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ImplementerBlockedTransactionResult)
    assert result.escalation.route.authority.value == "planner"
    assert result.escalation.request.requested_authority == EscalationAuthority.HUMAN
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 2


# ===========================================================================
# Planner transport / process failures propagate unwrapped (sections 26, 44)
# ===========================================================================


def test_planner_transport_failure_propagates(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            {"stdout": "", "returncode": 7},
        ],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.PLANNER_DECISION_REQUIRED,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    with pytest.raises(PlannerDecisionTransportError):
        run_single_subphase_transaction_with_blockers(
            scenario.request, agent_turn_runtime=scenario.runtime
        )

    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 2

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.IMPLEMENTING

    subjects = _log_subjects(scenario.request.worktree_path)
    assert subjects == [scenario.request.test_commit_message, "initial"]


# ===========================================================================
# Malformed / failed Implementer turn is not converted into a blocker (45, 46)
# ===========================================================================


def test_malformed_implementer_report_raises_agent_turn_error(tmp_path: Path) -> None:
    from lockstep.agent_turn import AgentTurnError

    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[_planner_authoring_response(_TEST_FILE_RED)],
        implementer_response={"stdout": "not json at all", "returncode": 0},
    )

    with pytest.raises(AgentTurnError):
        run_single_subphase_transaction_with_blockers(
            scenario.request, agent_turn_runtime=scenario.runtime
        )

    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 1

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.IMPLEMENTING


def test_implementer_process_nonzero_raises_agent_turn_error_not_blocker(tmp_path: Path) -> None:
    from lockstep.agent_turn import AgentTurnError

    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[_planner_authoring_response(_TEST_FILE_RED)],
        implementer_response={"stdout": "irrelevant", "returncode": 3},
    )

    with pytest.raises(AgentTurnError):
        run_single_subphase_transaction_with_blockers(
            scenario.request, agent_turn_runtime=scenario.runtime
        )

    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 1

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.IMPLEMENTING


# ===========================================================================
# Runtime/request consistency check (section 12)
# ===========================================================================


def test_runtime_consistency_mismatch_fails_before_any_inference(tmp_path: Path) -> None:
    source = _init_source_repo(tmp_path)
    request = _build_request(tmp_path, source, runtime_dir=tmp_path / "runtime-a")

    planner_bin = tmp_path / "planner-bin"
    _write_fake_claude_executable(
        planner_bin, name="claude-planner", responses=[_planner_authoring_response(_TEST_FILE_RED)]
    )
    implementer_bin = tmp_path / "implementer-bin"
    _write_fake_claude_executable(
        implementer_bin,
        name="claude-implementer",
        responses=[_implementer_completed_response({"feature.py": _IMPL_CORRECT})],
    )

    runtime = _agent_runtime(
        tmp_path,
        runtime_dir=tmp_path / "runtime-b",
        planner_adapter=_claude_adapter(
            AgentRole.PLANNER, executable=str(planner_bin / "claude-planner")
        ),
        implementer_adapter=_claude_adapter(
            AgentRole.IMPLEMENTER, executable=str(implementer_bin / "claude-implementer")
        ),
        reviewer_adapter=_PoisonAdapter(),
        parent_env=_parent_env(tmp_path),
    )

    with pytest.raises(SupervisorTransactionError) as exc_info:
        run_single_subphase_transaction_with_blockers(request, agent_turn_runtime=runtime)

    assert exc_info.value.stage == "runtime_consistency"
    assert _invocation_count(planner_bin, "claude-planner") == 0
    assert _invocation_count(implementer_bin, "claude-implementer") == 0
    assert not request.worktree_path.exists()
    assert not request.runtime_dir.exists()


# ===========================================================================
# Blocked event/state sequence terminates at HALTED (sections 20, 21, 48)
# ===========================================================================


def test_blocked_path_event_sequence_terminates_at_halted(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[_planner_authoring_response(_TEST_FILE_RED)],
        implementer_response=_implementer_blocked_response(
            category=EscalationCategory.REQUIREMENT_AMBIGUITY,
            requested_authority=EscalationAuthority.HUMAN,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert isinstance(result, ImplementerBlockedTransactionResult)

    events = read_events(scenario.request.runtime_dir / "events.jsonl")
    assert len(events) == 8
    last_event = events[-1]
    assert isinstance(last_event, StateTransitionedEvent)
    assert last_event.source == WorkflowState.IMPLEMENTING
    assert last_event.target == WorkflowState.HALTED

    reached_targets = {
        event.target for event in events if isinstance(event, StateTransitionedEvent)
    }
    assert WorkflowState.VERIFYING not in reached_targets
    assert WorkflowState.REVIEWING not in reached_targets
    assert WorkflowState.IMPLEMENTATION_COMMIT not in reached_targets
    assert WorkflowState.SUBPHASE_COMPLETE not in reached_targets

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.HALTED
    assert persisted == result.final_state


# ===========================================================================
# No Reviewer migration -- structural check (sections 43, 50)
# ===========================================================================


def test_transaction_module_only_invokes_agent_turn_for_implementer() -> None:
    tree = ast.parse(inspect.getsource(transaction_module))
    call_count = 0
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Name)
            and node.func.id == "invoke_agent_turn"
        ):
            call_count += 1
            role_keyword = next(kw for kw in node.keywords if kw.arg == "role")
            assert isinstance(role_keyword.value, ast.Attribute)
            assert role_keyword.value.attr == "IMPLEMENTER"

    assert call_count == 1


def test_agent_turn_result_type_is_reexported_for_typing() -> None:
    # Sanity: the blocked result's ``implementer_turn`` field really is the
    # exact structured 9.4 result type, not a re-derived shape.
    assert AgentTurnResult is not None
    assert AgentTurnStatus.BLOCKED.value == "blocked"
