"""Planner-authored specification of Sub-phase 9.14-R4 Reviewer host identity binding.

Freezes the invariant that whenever the Supervisor asks a Reviewer for a
structured ``ReviewDecision``, the Supervisor itself supplies the exact
machine-owned identity it will later validate (``phase_id``,
``subphase_id``, ``attempt``, ``role = reviewer``), independent of caller
``reviewer_prompt`` prose. Covers all four Reviewer invocation paths:

    A. attempt-1 legacy Reviewer            (run_single_subphase_transaction)
    B. attempt-1 blocker-aware Reviewer     (run_single_subphase_transaction_with_blockers)
    C. Reviewer-only resume                 (resume_single_subphase_transaction)
    D. Reviewer after a resumed Implementer (resume_single_subphase_transaction)

Path A is observed through the adapter's ``AgentInvocationRequest``; paths
B-D through a capture wrapper around ``invoke_reviewer_turn`` that
delegates to the real implementation (the prompt observed there is the
Supervisor-composed prompt, before the frozen Reviewer-turn protocol
suffix is appended by ``reviewer_turn``). Real ``ClaudeAdapter`` instances
run against fake provider executables under ``tmp_path``; no network and
no real model inference.
"""

from __future__ import annotations

import json
import stat
import subprocess
import sys
import textwrap
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path

import pytest

import lockstep.supervisor.transaction as transaction_module
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
    AttemptNumber,
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
from lockstep.retry import RetryBudget
from lockstep.runtime import AgentRuntime
from lockstep.supervisor.transaction import (
    ResumeExecutionDisposition,
    RetryCheckpointedTransactionResult,
    SingleSubphaseTransactionRequest,
    SingleSubphaseTransactionResult,
    SupervisorTransactionError,
    resume_single_subphase_transaction,
    run_single_subphase_transaction,
    run_single_subphase_transaction_with_blockers,
    run_single_subphase_transaction_with_retry_checkpoint,
)

_PHASE_ID = "09"
_SUBPHASE_ID = "14"

_GENERIC_PROMPT = "review the implementation"
_CONFLICTING_PROMPT = "Review phase WRONG, subphase WRONG, attempt 99"

# The exact host-owned section header. The compact, sorted-key JSON payload
# (the project's existing deterministic serialization) follows on the next
# line and is the last content of the Supervisor-composed prompt.
_IDENTITY_MARKER = (
    "Reviewer identity (host-supplied, deterministic; "
    "the ReviewDecision must copy these values exactly):\n"
)
_RESUME_AUTHORITY_MARKER = "Resume authority (host-supplied, deterministic):"

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


def _budget(max_attempts: int) -> RetryBudget:
    return RetryBudget(max_attempts=AttemptNumber.model_validate(max_attempts))


# ---------------------------------------------------------------------------
# Identity assertions
# ---------------------------------------------------------------------------


def _expected_identity_section(attempt: int) -> str:
    payload = json.dumps(
        {
            "phase_id": _PHASE_ID,
            "subphase_id": _SUBPHASE_ID,
            "attempt": attempt,
            "role": "reviewer",
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return _IDENTITY_MARKER + payload + "\n"


def _assert_host_identity(prompt: str, *, attempt: int) -> None:
    # Exactly one host identity section, carrying the exact machine identity,
    # positioned last in the Supervisor-composed prompt.
    assert prompt.count(_IDENTITY_MARKER) == 1
    assert prompt.endswith(_expected_identity_section(attempt))
    section = prompt[prompt.index(_IDENTITY_MARKER) :]
    assert json.loads(section[len(_IDENTITY_MARKER) :]) == {
        "phase_id": _PHASE_ID,
        "subphase_id": _SUBPHASE_ID,
        "attempt": attempt,
        "role": "reviewer",
    }


# ---------------------------------------------------------------------------
# Git / provider fixtures
# ---------------------------------------------------------------------------


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
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


def _write_fake_claude_executable(
    bin_dir: Path, *, name: str, responses: list[dict[str, object]]
) -> Path:
    bin_dir.mkdir(parents=True, exist_ok=True)
    executable = bin_dir / name
    (bin_dir / f"{name}-responses.json").write_text(json.dumps(responses), encoding="utf-8")
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

        for rel_path, content in response.get("files", {{}}).items():
            target = Path(rel_path)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)

        sys.stdout.write(response.get("stdout", ""))
        raise SystemExit(int(response.get("returncode", 0)))
        """
    )
    executable.write_text(script, encoding="utf-8")
    executable.chmod(executable.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


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


def _claude_adapter(role: AgentRole, *, executable: str) -> ClaudeAdapter:
    return ClaudeAdapter(
        role=role,
        status=_healthy_claude_status(executable=executable),
        model="role-model",
        effort="high",
    )


# ---------------------------------------------------------------------------
# Response builders
# ---------------------------------------------------------------------------


def _planner_authoring_response() -> dict[str, object]:
    return {"stdout": "", "returncode": 0, "files": {"tests/test_feature.py": _TEST_FILE_RED}}


def _planner_decision_response(kind: PlannerDecisionKind) -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "kind": kind.value,
                "rationale": "Bounded rationale for this decision.",
                "instructions": ["Do the bounded thing."],
                "authorized_paths": [],
            }
        ),
        "returncode": 0,
    }


def _implementer_completed_response() -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "status": "completed",
                "implementation_report": {"summary": "Implemented the requested change."},
                "blocker": None,
            }
        ),
        "returncode": 0,
        "files": {"feature.py": _IMPL_CORRECT},
    }


def _implementer_blocked_response() -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "status": "blocked",
                "blocker": {
                    "category": EscalationCategory.ARCHITECTURE_CONFLICT.value,
                    "question": "Bounded sentinel question.",
                    "evidence": ["Bounded sentinel evidence."],
                    "requested_authority": EscalationAuthority.PLANNER.value,
                },
            }
        ),
        "returncode": 0,
    }


def _review_decision_payload(
    *,
    attempt: int,
    verdict: str = "approve",
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "phase_id": phase_id,
        "subphase_id": subphase_id,
        "attempt": attempt,
        "verdict": verdict,
        "summary": "reviewed",
        "findings": [],
    }


def _reviewer_completed_response(
    *,
    attempt: int,
    verdict: str = "approve",
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
) -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "status": "completed",
                "review_decision": _review_decision_payload(
                    attempt=attempt,
                    verdict=verdict,
                    phase_id=phase_id,
                    subphase_id=subphase_id,
                ),
                "blocker": None,
            }
        ),
        "returncode": 0,
    }


def _reviewer_blocked_response() -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "status": "blocked",
                "review_decision": None,
                "blocker": {
                    "category": EscalationCategory.ARCHITECTURE_CONFLICT.value,
                    "question": "Bounded sentinel question.",
                    "evidence": ["Bounded sentinel evidence."],
                    "requested_authority": EscalationAuthority.PLANNER.value,
                },
            }
        ),
        "returncode": 0,
    }


# ---------------------------------------------------------------------------
# Planning-store / request / runtime construction
# ---------------------------------------------------------------------------


def _master_plan() -> MasterPlan:
    return MasterPlan(
        schema_version=1,
        project_id="lockstep",
        title="Lockstep",
        objective="Build the local orchestration control plane.",
        phases=[
            PhasePlan(
                schema_version=1,
                phase_id=_phase_id(),
                title="Reviewer identity",
                objective="Bind Reviewer host identity.",
                depends_on=[],
                subphases=[
                    SubphaseOutline(
                        subphase_id=_subphase_id(),
                        title="Reviewer identity",
                        objective="Bind Reviewer host identity.",
                        depends_on=[],
                    )
                ],
                integration_acceptance_criteria=[],
            )
        ],
    )


def _contract() -> SubphaseContract:
    return SubphaseContract(
        schema_version=1,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        title="Reviewer identity",
        objective="Bind Reviewer host identity.",
        acceptance_criteria=[
            AcceptanceCriterion(criterion_id="AC-1", description="Identity is host supplied.")
        ],
        tests=[
            TestSpecification(
                path="tests/test_supervisor_reviewer_identity.py",
                expectation=TestExpectation.RED,
                acceptance_criteria=["AC-1"],
            )
        ],
        allowed_paths=["src/lockstep/supervisor/transaction.py"],
        protected_paths=[],
        forbidden_paths=[],
        verification_commands=["./scripts/check"],
    )


def _freeze_planning_state(project_root: Path, runtime_dir: Path) -> None:
    from lockstep.planning_store import (
        freeze_master_plan,
        freeze_subphase_contract,
        publish_phase_plan,
    )

    freeze_master_plan(project_root, _master_plan())
    publish_phase_plan(project_root, runtime_dir, _master_plan().phases[0])
    freeze_subphase_contract(project_root, runtime_dir, _contract())


def _parent_env(root: Path) -> dict[str, str]:
    home = root / "home"
    home.mkdir(exist_ok=True, parents=True)
    return {"HOME": str(home), "PATH": "/usr/bin:/bin"}


def _build_request(
    root: Path, source: Path, *, reviewer_prompt: str, run_id: str = "20260929-014"
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
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        source_path=source,
        worktree_path=root / "run-worktree",
        runtime_dir=root / "runtime",
        branch="lockstep/run/run-09-14-reviewer-identity",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        planner_prompt="draft the failing acceptance test",
        implementer_prompt="implement the acceptance test",
        reviewer_prompt=reviewer_prompt,
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
) -> AgentRuntime:
    project_root = root / "agent-project"
    project_root.mkdir(exist_ok=True, parents=True)
    _freeze_planning_state(project_root, runtime_dir)

    route = AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model="unused-model",
        effort="unused-effort",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )
    policy = AgentRoutingPolicy(planner=route, implementer=route, reviewer=route)
    return AgentRuntime(
        project_root=project_root,
        runtime_dir=runtime_dir,
        config=ProjectConfig(schema_version=1, routing=policy),
        diagnostics=AgentProviderDiagnostics(statuses=AgentProviderStatuses()),
        adapters=ResolvedAgentAdapters(
            planner=planner_adapter,
            implementer=implementer_adapter,
            reviewer=reviewer_adapter,
        ),
        transaction_parent_env=_parent_env(root),
    )


@dataclass(frozen=True, slots=True)
class _Scenario:
    request: SingleSubphaseTransactionRequest
    runtime: AgentRuntime


def _prepare_scenario(
    root: Path,
    *,
    reviewer_prompt: str = _GENERIC_PROMPT,
    planner_responses: list[dict[str, object]] | None = None,
    implementer_responses: list[dict[str, object]] | None = None,
    reviewer_responses: list[dict[str, object]] | None = None,
    run_id: str = "20260929-014",
) -> _Scenario:
    root.mkdir(exist_ok=True, parents=True)
    request = _build_request(
        root, _init_source_repo(root), reviewer_prompt=reviewer_prompt, run_id=run_id
    )

    adapters: dict[AgentRole, AgentAdapter] = {}
    role_responses: dict[AgentRole, list[dict[str, object]]] = {
        AgentRole.PLANNER: planner_responses or [_planner_authoring_response()],
        AgentRole.IMPLEMENTER: implementer_responses or [_implementer_completed_response()],
        AgentRole.REVIEWER: reviewer_responses or [_reviewer_completed_response(attempt=1)],
    }
    for role, responses in role_responses.items():
        bin_dir = root / f"{role.value}-bin"
        name = f"claude-{role.value}"
        _write_fake_claude_executable(bin_dir, name=name, responses=responses)
        adapters[role] = _claude_adapter(role, executable=str(bin_dir / name))

    runtime = _agent_runtime(
        root,
        runtime_dir=request.runtime_dir,
        planner_adapter=adapters[AgentRole.PLANNER],
        implementer_adapter=adapters[AgentRole.IMPLEMENTER],
        reviewer_adapter=adapters[AgentRole.REVIEWER],
    )
    return _Scenario(request=request, runtime=runtime)


def _halt_with_checkpoint(scenario: _Scenario, *, max_attempts: int = 3) -> None:
    result = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request,
        agent_turn_runtime=scenario.runtime,
        retry_budget=_budget(max_attempts),
    )
    assert isinstance(result, RetryCheckpointedTransactionResult)


@pytest.fixture
def reviewer_prompts(monkeypatch: pytest.MonkeyPatch) -> list[str]:
    """Capture every prompt the Supervisor hands to ``invoke_reviewer_turn``.

    Delegates to the real implementation, so no Supervisor prompt
    construction is bypassed.
    """
    captured: list[str] = []
    real: Callable[..., object] = transaction_module.invoke_reviewer_turn

    def capture(runtime: AgentRuntime, **kwargs: object) -> object:
        prompt = kwargs["prompt"]
        assert isinstance(prompt, str)
        captured.append(prompt)
        return real(runtime, **kwargs)

    monkeypatch.setattr(transaction_module, "invoke_reviewer_turn", capture)
    return captured


# ---------------------------------------------------------------------------
# Scenario drivers, one per Reviewer invocation path
# ---------------------------------------------------------------------------


def _script_write(rel_path: str, content: str) -> str:
    return (
        "import pathlib\n"
        f"target = pathlib.Path({rel_path!r})\n"
        "target.parent.mkdir(parents=True, exist_ok=True)\n"
        f"target.write_text({content!r})\n"
    )


class _ScriptAdapter:
    def __init__(self, name: str, script: str) -> None:
        self.name = name
        self._script = script
        self.invocations: list[AgentInvocationRequest] = []

    def build_command(self, request: AgentInvocationRequest) -> AgentCommand:
        self.invocations.append(request)
        return AgentCommand(argv=(sys.executable, "-c", self._script))


def _legacy_reviewer_prompt(tmp_path: Path, *, reviewer_prompt: str) -> str:
    """Path A: attempt-1 legacy Reviewer request prompt."""
    root = tmp_path / "legacy"
    root.mkdir()
    request = _build_request(root, _init_source_repo(root), reviewer_prompt=reviewer_prompt)
    payload = json.dumps(_review_decision_payload(attempt=1))
    reviewer = _ScriptAdapter("reviewer", f"import sys\nsys.stdout.write({payload!r})\n")
    result = run_single_subphase_transaction(
        request,
        parent_env=_parent_env(root),
        planner_adapter=_ScriptAdapter(
            "planner", _script_write("tests/test_feature.py", _TEST_FILE_RED)
        ),
        implementer_adapter=_ScriptAdapter(
            "implementer", _script_write("feature.py", _IMPL_CORRECT)
        ),
        reviewer_adapter=reviewer,
    )
    assert isinstance(result, SingleSubphaseTransactionResult)
    assert len(reviewer.invocations) == 1
    return reviewer.invocations[0].prompt


def _blocker_aware_run(root: Path, *, reviewer_prompt: str, run_id: str = "20260929-014") -> None:
    """Path B: attempt-1 blocker-aware Reviewer."""
    scenario = _prepare_scenario(root, reviewer_prompt=reviewer_prompt, run_id=run_id)
    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert isinstance(result, SingleSubphaseTransactionResult)


def _reviewer_only_resume(root: Path, *, reviewer_prompt: str = _GENERIC_PROMPT) -> _Scenario:
    """Path C: durable attempt-2 authority targeting the Reviewer."""
    scenario = _prepare_scenario(
        root,
        reviewer_prompt=reviewer_prompt,
        planner_responses=[
            _planner_authoring_response(),
            _planner_decision_response(PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        reviewer_responses=[
            _reviewer_blocked_response(),
            _reviewer_completed_response(attempt=2),
        ],
    )
    _halt_with_checkpoint(scenario)
    return scenario


def _post_implementer_resume(root: Path, *, reviewer_prompt: str = _GENERIC_PROMPT) -> _Scenario:
    """Path D: durable attempt-2 authority targeting the Implementer."""
    scenario = _prepare_scenario(
        root,
        reviewer_prompt=reviewer_prompt,
        planner_responses=[
            _planner_authoring_response(),
            _planner_decision_response(PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[_implementer_blocked_response(), _implementer_completed_response()],
        reviewer_responses=[_reviewer_completed_response(attempt=2)],
    )
    _halt_with_checkpoint(scenario)
    return scenario


def _resume(scenario: _Scenario) -> None:
    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert result.disposition == ResumeExecutionDisposition.SETTLED


# ===========================================================================
# A. attempt-1 legacy Reviewer
# ===========================================================================


def test_attempt1_legacy_reviewer_receives_host_identity(tmp_path: Path) -> None:
    prompt = _legacy_reviewer_prompt(tmp_path, reviewer_prompt=_GENERIC_PROMPT)

    assert prompt.startswith(_GENERIC_PROMPT)
    _assert_host_identity(prompt, attempt=1)


# ===========================================================================
# B. attempt-1 blocker-aware Reviewer
# ===========================================================================


def test_attempt1_blocker_aware_reviewer_receives_host_identity(
    tmp_path: Path, reviewer_prompts: list[str]
) -> None:
    _blocker_aware_run(tmp_path / "scenario", reviewer_prompt=_GENERIC_PROMPT)

    assert len(reviewer_prompts) == 1
    assert reviewer_prompts[0].startswith(_GENERIC_PROMPT)
    _assert_host_identity(reviewer_prompts[0], attempt=1)
    assert _RESUME_AUTHORITY_MARKER not in reviewer_prompts[0]


# ===========================================================================
# C. Reviewer-only resume
# ===========================================================================


def test_reviewer_only_resume_receives_host_identity(
    tmp_path: Path, reviewer_prompts: list[str]
) -> None:
    scenario = _reviewer_only_resume(tmp_path / "scenario")
    assert len(reviewer_prompts) == 1  # the attempt-1 Reviewer blocked

    _resume(scenario)

    assert len(reviewer_prompts) == 2
    resumed = reviewer_prompts[1]
    _assert_host_identity(resumed, attempt=2)

    # Ordering: caller prose, then semantic resume authority, then identity LAST.
    assert resumed.startswith(_GENERIC_PROMPT)
    assert resumed.count(_RESUME_AUTHORITY_MARKER) == 1
    assert resumed.index(_RESUME_AUTHORITY_MARKER) < resumed.index(_IDENTITY_MARKER)
    assert "architecture_conflict" in resumed
    assert "authorize_bounded_change" in resumed


# ===========================================================================
# D. Reviewer after a resumed Implementer
# ===========================================================================


def test_post_implementer_resumed_reviewer_receives_host_identity(
    tmp_path: Path, reviewer_prompts: list[str]
) -> None:
    scenario = _post_implementer_resume(tmp_path / "scenario")
    assert reviewer_prompts == []  # the attempt-1 Implementer blocked first

    _resume(scenario)

    assert len(reviewer_prompts) == 1
    _assert_host_identity(reviewer_prompts[0], attempt=2)
    assert reviewer_prompts[0].startswith(_GENERIC_PROMPT)


# ===========================================================================
# Attempt identity comes from durable state, per retry
# ===========================================================================


def test_attempt_identity_follows_executed_attempt_across_retries(
    tmp_path: Path, reviewer_prompts: list[str]
) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        implementer_responses=[_implementer_completed_response()],
        reviewer_responses=[
            _reviewer_completed_response(attempt=1, verdict="rework"),
            _reviewer_completed_response(attempt=2, verdict="rework"),
            _reviewer_completed_response(attempt=3, verdict="approve"),
        ],
    )
    _halt_with_checkpoint(scenario, max_attempts=3)
    _resume(scenario)
    _resume(scenario)

    assert len(reviewer_prompts) == 3
    for index, prompt in enumerate(reviewer_prompts, start=1):
        _assert_host_identity(prompt, attempt=index)


# ===========================================================================
# Conflicting caller prose cannot displace host authority
# ===========================================================================


@pytest.mark.parametrize("path", ["legacy", "blocker_aware", "reviewer_only", "post_implementer"])
def test_conflicting_caller_prose_precedes_authoritative_host_identity(
    tmp_path: Path, reviewer_prompts: list[str], path: str
) -> None:
    root = tmp_path / "scenario"
    expected_attempt = 1
    if path == "legacy":
        prompt = _legacy_reviewer_prompt(tmp_path, reviewer_prompt=_CONFLICTING_PROMPT)
    elif path == "blocker_aware":
        _blocker_aware_run(root, reviewer_prompt=_CONFLICTING_PROMPT)
        prompt = reviewer_prompts[-1]
    elif path == "reviewer_only":
        _resume(_reviewer_only_resume(root, reviewer_prompt=_CONFLICTING_PROMPT))
        prompt = reviewer_prompts[-1]
        expected_attempt = 2
    else:
        _resume(_post_implementer_resume(root, reviewer_prompt=_CONFLICTING_PROMPT))
        prompt = reviewer_prompts[-1]
        expected_attempt = 2

    # Wrong caller prose is neither parsed nor removed, and comes first.
    assert prompt.startswith(_CONFLICTING_PROMPT)
    assert prompt.index(_CONFLICTING_PROMPT) < prompt.index(_IDENTITY_MARKER)
    _assert_host_identity(prompt, attempt=expected_attempt)
    section = prompt[prompt.index(_IDENTITY_MARKER) :]
    assert "WRONG" not in section
    assert "99" not in section


# ===========================================================================
# Determinism and privacy of the host identity section
# ===========================================================================


def test_host_identity_section_is_byte_identical_for_identical_inputs(
    tmp_path: Path, reviewer_prompts: list[str]
) -> None:
    _blocker_aware_run(tmp_path / "a", reviewer_prompt=_GENERIC_PROMPT, run_id="20260929-014-a")
    _blocker_aware_run(tmp_path / "b", reviewer_prompt=_GENERIC_PROMPT, run_id="20260929-014-b")

    assert len(reviewer_prompts) == 2
    assert reviewer_prompts[0].encode("utf-8") == reviewer_prompts[1].encode("utf-8")


def test_host_identity_section_carries_only_machine_identity(
    tmp_path: Path, reviewer_prompts: list[str]
) -> None:
    _resume(_post_implementer_resume(tmp_path / "scenario"))

    prompt = reviewer_prompts[-1]
    section = prompt[prompt.index(_IDENTITY_MARKER) :]
    payload = json.loads(section[len(_IDENTITY_MARKER) :])
    assert set(payload) == {"phase_id", "subphase_id", "attempt", "role"}
    for forbidden in (
        "role-model",
        "unused-model",
        "subscription_only",
        "stdout",
        "stderr",
        "HOME",
        "Bounded rationale",
        "Bounded sentinel",
    ):
        assert forbidden not in section


# ===========================================================================
# Output validation stays strict (host supplies identity; it does not excuse
# a Reviewer that returns a different one)
# ===========================================================================


def test_attempt1_blocker_aware_wrong_identity_still_rejected(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        reviewer_responses=[_reviewer_completed_response(attempt=1, phase_id="99")],
    )

    with pytest.raises(SupervisorTransactionError) as excinfo:
        run_single_subphase_transaction_with_blockers(
            scenario.request, agent_turn_runtime=scenario.runtime
        )
    assert excinfo.value.reason == "reviewer decision does not match current transaction"


@pytest.mark.parametrize(
    "wrong",
    [
        {"attempt": 1},
        {"attempt": 3},
        {"attempt": 2, "phase_id": "99"},
        {"attempt": 2, "subphase_id": "99"},
    ],
)
def test_resumed_reviewer_wrong_identity_still_rejected(
    tmp_path: Path, wrong: Mapping[str, object]
) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(),
            _planner_decision_response(PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[_implementer_blocked_response(), _implementer_completed_response()],
        reviewer_responses=[_reviewer_completed_response(**wrong)],  # type: ignore[arg-type]
    )
    _halt_with_checkpoint(scenario)

    with pytest.raises(SupervisorTransactionError) as excinfo:
        resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)
    assert excinfo.value.reason == "reviewer decision does not match the current resumed attempt"
