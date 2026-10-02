"""Planner-authored specification of Sub-phase 9.14-R3 verification bytecode isolation.

Pins the product invariant established by the 9.14-R2 investigation: each
logically distinct deterministic verification invocation that may observe a
different worktree state runs against a bytecode-cache namespace
(``PYTHONPYCACHEPREFIX``) that cannot contain bytecode produced for an earlier
worktree state. Correctness must not depend on source mtime advancing, source
byte length changing, scheduler delay, or agent latency.

The hostile cache conditions from the R2 reproducer are recreated
deterministically, with no sleeps: rewritten sources keep the same absolute
path, the same encoded byte size, and the same integer-second mtime as the
sources whose bytecode the baseline run already cached. Fake provider
executables perform the rewrites (preserving the integer mtime); the
Supervisor's real verification subprocess path is exercised end to end. The
only test seam is a pass-through spy on ``run_process`` that records the
``PYTHONPYCACHEPREFIX`` each call receives and then delegates to the real
implementation.
"""

from __future__ import annotations

import json
import stat
import subprocess
import sys
import textwrap
from collections.abc import Mapping, Sequence
from pathlib import Path

import pytest

import lockstep.supervisor.transaction as transaction_module
from lockstep.agents import (
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
from lockstep.process import ProcessResult, run_process
from lockstep.resume_settlement import ResumeSettlementOutcome
from lockstep.retry import RetryBudget
from lockstep.runtime import AgentRuntime
from lockstep.state import WorkflowState
from lockstep.supervisor.transaction import (
    ResumeExecutionDisposition,
    RetryCheckpointedTransactionResult,
    SingleSubphaseTransactionRequest,
    resume_single_subphase_transaction,
    run_single_subphase_transaction_with_retry_checkpoint,
)

_PHASE_ID = "09"
_SUBPHASE_ID = "14"

# Every A/B pair below is intentionally the SAME encoded byte size. The
# product must not rely on size differences to detect a rewritten source.
_TEST_EXPECTS_42 = (
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
_TEST_EXPECTS_43 = _TEST_EXPECTS_42.replace("== 42", "== 43")

_IMPL_RETURNS_41 = "def answer() -> int:\n    return 41\n"
_IMPL_RETURNS_42 = _IMPL_RETURNS_41.replace("41", "42")
_IMPL_RETURNS_43 = _IMPL_RETURNS_41.replace("41", "43")


def test_hostile_fixture_pairs_have_equal_encoded_sizes() -> None:
    assert len(_TEST_EXPECTS_42.encode()) == len(_TEST_EXPECTS_43.encode())
    assert len(_IMPL_RETURNS_41.encode()) == len(_IMPL_RETURNS_42.encode())
    assert len(_IMPL_RETURNS_41.encode()) == len(_IMPL_RETURNS_43.encode())
    assert _TEST_EXPECTS_42 != _TEST_EXPECTS_43
    assert len({_IMPL_RETURNS_41, _IMPL_RETURNS_42, _IMPL_RETURNS_43}) == 3


# ---------------------------------------------------------------------------
# Git source repo -- feature.py is committed so the baseline run imports (and
# therefore caches bytecode for) both feature.py and the test module.
# ---------------------------------------------------------------------------


def _git(repo: Path, *args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        ["git", "-C", str(repo), *args], check=True, capture_output=True, text=True
    )


def _init_source_repo(root: Path) -> Path:
    source = root / "source"
    source.mkdir(parents=True)
    _git(source, "init")
    _git(source, "config", "user.name", "Lockstep Tests")
    _git(source, "config", "user.email", "lockstep-tests@example.invalid")
    _git(source, "config", "commit.gpgsign", "false")
    (source / "README.md").write_text("initial\n")
    (source / "feature.py").write_text(_IMPL_RETURNS_41)
    _git(source, "add", "README.md", "feature.py")
    _git(source, "commit", "-m", "initial")
    _git(source, "branch", "-M", "main")
    return source


# ---------------------------------------------------------------------------
# Fake provider executable. Rewrites preserve the integer-second mtime of any
# file that already exists, deterministically recreating the hostile
# (same path, same size, same mtime second) cache-validity identity.
# ---------------------------------------------------------------------------


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
        import os
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
            previous = int(target.stat().st_mtime) if target.exists() else None
            target.write_text(content)
            if previous is not None:
                os.utime(target, (previous, previous))

        sys.stdout.write(response.get("stdout", ""))
        raise SystemExit(int(response.get("returncode", 0)))
        """
    )
    executable.write_text(script, encoding="utf-8")
    executable.chmod(executable.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _claude_adapter(role: AgentRole, *, executable: str) -> ClaudeAdapter:
    return ClaudeAdapter(
        role=role,
        status=ClaudeCliStatus(
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
        ),
        model="role-model",
        effort="high",
    )


# ---------------------------------------------------------------------------
# Response builders
# ---------------------------------------------------------------------------


def _planner_authoring_response(test_content: str) -> dict[str, object]:
    return {"stdout": "", "returncode": 0, "files": {"tests/test_feature.py": test_content}}


def _planner_decision_response(
    *, kind: PlannerDecisionKind, authorized_paths: tuple[str, ...] = ()
) -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "kind": kind.value,
                "rationale": "Bounded rationale for this decision.",
                "instructions": ["Do the bounded thing."],
                "authorized_paths": list(authorized_paths),
            }
        ),
        "returncode": 0,
    }


def _implementer_completed_response(files: dict[str, str]) -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "status": "completed",
                "implementation_report": {"summary": "Implemented the requested change."},
                "blocker": None,
            }
        ),
        "returncode": 0,
        "files": files,
    }


def _implementer_test_defect_blocked_response() -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "status": "blocked",
                "blocker": {
                    "category": EscalationCategory.TEST_DEFECT.value,
                    "question": "Bounded sentinel question.",
                    "evidence": ["Bounded sentinel evidence."],
                    "requested_authority": EscalationAuthority.PLANNER.value,
                },
            }
        ),
        "returncode": 0,
    }


def _reviewer_response(*, attempt: int, verdict: str) -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "status": "completed",
                "review_decision": {
                    "schema_version": 1,
                    "phase_id": _PHASE_ID,
                    "subphase_id": _SUBPHASE_ID,
                    "attempt": attempt,
                    "verdict": verdict,
                    "summary": "bounded summary",
                    "findings": [],
                },
                "blocker": None,
            }
        ),
        "returncode": 0,
    }


# ---------------------------------------------------------------------------
# Planning store, request, runtime
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
                phase_id=PhaseId.model_validate(_PHASE_ID),
                title="Verification cache isolation",
                objective="Isolate verification bytecode caches.",
                depends_on=[],
                subphases=[
                    SubphaseOutline(
                        subphase_id=SubphaseId.model_validate(_SUBPHASE_ID),
                        title="Verification cache isolation",
                        objective="Never verify against stale bytecode.",
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
        phase_id=PhaseId.model_validate(_PHASE_ID),
        subphase_id=SubphaseId.model_validate(_SUBPHASE_ID),
        title="Verification cache isolation",
        objective="Never verify against stale bytecode.",
        acceptance_criteria=[
            AcceptanceCriterion(criterion_id="AC-1", description="Verification sees fresh code.")
        ],
        tests=[
            TestSpecification(
                path="tests/test_supervisor_verification_cache.py",
                expectation=TestExpectation.RED,
                acceptance_criteria=["AC-1"],
            )
        ],
        allowed_paths=["src/lockstep/supervisor/transaction.py"],
        protected_paths=[],
        forbidden_paths=[],
        verification_commands=["./scripts/check"],
    )


def _build_request(root: Path, source: Path) -> SingleSubphaseTransactionRequest:
    pytest_argv = (sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider")
    return SingleSubphaseTransactionRequest(
        project_id=ProjectId.model_validate("lockstep"),
        run_id=RunId.model_validate("20260929-914"),
        phase_id=PhaseId.model_validate(_PHASE_ID),
        subphase_id=SubphaseId.model_validate(_SUBPHASE_ID),
        source_path=source,
        worktree_path=root / "run-worktree",
        runtime_dir=root / "runtime",
        branch="lockstep/run/run-09-14-cache",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        planner_prompt="draft the failing acceptance test",
        implementer_prompt="implement the acceptance test",
        reviewer_prompt="review the implementation",
        test_paths=("tests/test_feature.py",),
        implementation_paths=("feature.py",),
        planner_quality_argv=(sys.executable, "-m", "py_compile", "tests/test_feature.py"),
        # The extra ``-x`` keeps baseline_argv distinguishable from
        # verification_argv when the spy classifies recorded calls.
        baseline_argv=(*pytest_argv, "-x", "tests/test_feature.py"),
        verification_argv=(*pytest_argv, "tests/test_feature.py"),
        test_commit_message="test(feature): freeze answer expectation",
        implementation_commit_message="feat(feature): implement answer",
        agent_timeout_seconds=60.0,
        command_timeout_seconds=60.0,
    )


class _Scenario:
    def __init__(
        self,
        root: Path,
        *,
        planner_responses: list[dict[str, object]],
        implementer_responses: list[dict[str, object]],
        reviewer_responses: list[dict[str, object]],
    ) -> None:
        root.mkdir(parents=True, exist_ok=True)
        self.request = _build_request(root, _init_source_repo(root))

        adapters = {}
        for role, name, responses in (
            (AgentRole.PLANNER, "claude-planner", planner_responses),
            (AgentRole.IMPLEMENTER, "claude-implementer", implementer_responses),
            (AgentRole.REVIEWER, "claude-reviewer", reviewer_responses),
        ):
            bin_dir = root / f"{role.value}-bin"
            _write_fake_claude_executable(bin_dir, name=name, responses=responses)
            adapters[role] = _claude_adapter(role, executable=str(bin_dir / name))

        project_root = root / "agent-project"
        project_root.mkdir(parents=True, exist_ok=True)
        from lockstep.planning_store import (
            freeze_master_plan,
            freeze_subphase_contract,
            publish_phase_plan,
        )

        freeze_master_plan(project_root, _master_plan())
        publish_phase_plan(project_root, self.request.runtime_dir, _master_plan().phases[0])
        freeze_subphase_contract(project_root, self.request.runtime_dir, _contract())

        route = AgentRoleRoute(
            provider=AgentProvider.CLAUDE,
            model="unused-model",
            effort="unused-effort",
            billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        )
        home = root / "home"
        home.mkdir(parents=True, exist_ok=True)
        self.runtime = AgentRuntime(
            project_root=project_root,
            runtime_dir=self.request.runtime_dir,
            config=ProjectConfig(
                schema_version=1,
                routing=AgentRoutingPolicy(planner=route, implementer=route, reviewer=route),
            ),
            diagnostics=AgentProviderDiagnostics(statuses=AgentProviderStatuses()),
            adapters=ResolvedAgentAdapters(
                planner=adapters[AgentRole.PLANNER],
                implementer=adapters[AgentRole.IMPLEMENTER],
                reviewer=adapters[AgentRole.REVIEWER],
            ),
            transaction_parent_env={"HOME": str(home), "PATH": "/usr/bin:/bin"},
        )


class _CacheSpy:
    """Pass-through ``run_process`` spy recording each call's bytecode-cache prefix."""

    def __init__(self, request: SingleSubphaseTransactionRequest) -> None:
        self._request = request
        self.baseline_prefixes: list[str | None] = []
        self.verification_prefixes: list[str | None] = []

    def __call__(self, argv: Sequence[str], **kwargs: object) -> ProcessResult:
        env = kwargs.get("env")
        assert isinstance(env, Mapping)
        prefix = env.get("PYTHONPYCACHEPREFIX")
        if tuple(argv) == self._request.baseline_argv:
            self.baseline_prefixes.append(prefix)
        elif tuple(argv) == self._request.verification_argv:
            self.verification_prefixes.append(prefix)
        return run_process(argv, **kwargs)  # type: ignore[arg-type]


def _install_spy(
    monkeypatch: pytest.MonkeyPatch, request: SingleSubphaseTransactionRequest
) -> _CacheSpy:
    spy = _CacheSpy(request)
    monkeypatch.setattr(transaction_module, "run_process", spy)
    return spy


def _budget(max_attempts: int) -> RetryBudget:
    return RetryBudget(max_attempts=AttemptNumber.model_validate(max_attempts))


# ===========================================================================
# Ordinary-import bytecode (feature.py) -- baseline -> attempt 1 -> 2 -> 3
# ===========================================================================


def test_rewritten_implementation_is_fresh_and_every_attempt_has_its_own_cache(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = _Scenario(
        tmp_path / "scenario",
        planner_responses=[_planner_authoring_response(_TEST_EXPECTS_42)],
        # Attempt 1 rewrites the committed feature.py (41 -> 42) with equal size
        # and equal integer mtime; attempts 2 and 3 rewrite the still-dirty file.
        implementer_responses=[
            _implementer_completed_response({"feature.py": _IMPL_RETURNS_42}),
            _implementer_completed_response({"feature.py": _IMPL_RETURNS_42}),
            _implementer_completed_response({"feature.py": _IMPL_RETURNS_42}),
        ],
        reviewer_responses=[
            _reviewer_response(attempt=1, verdict="rework"),
            _reviewer_response(attempt=2, verdict="rework"),
            _reviewer_response(attempt=3, verdict="approve"),
        ],
    )
    spy = _install_spy(monkeypatch, scenario.request)

    halted = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )
    assert isinstance(halted, RetryCheckpointedTransactionResult)

    second = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert second.disposition == ResumeExecutionDisposition.SETTLED
    assert second.settlement is not None
    assert second.settlement.outcome == ResumeSettlementOutcome.NEXT_RETRY

    third = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert third.disposition == ResumeExecutionDisposition.SETTLED
    assert third.settlement is not None
    assert third.settlement.outcome == ResumeSettlementOutcome.COMPLETED
    assert third.final_state is not None
    assert third.final_state.workflow_state == WorkflowState.SUBPHASE_COMPLETE

    assert len(spy.baseline_prefixes) == 1
    assert len(spy.verification_prefixes) == 3
    baseline = spy.baseline_prefixes[0]
    attempt_1, attempt_2, attempt_3 = spy.verification_prefixes
    assert baseline is not None
    assert None not in spy.verification_prefixes
    # Semantic separation: every verification that may observe a different
    # worktree state gets a namespace no earlier state could have populated.
    assert len({baseline, attempt_1, attempt_2, attempt_3}) == 4


# ===========================================================================
# Pytest assertion-rewrite bytecode (tests/test_feature.py) -- frozen correction
# ===========================================================================


def test_rewritten_frozen_test_and_implementation_are_fresh_on_resume(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    scenario = _Scenario(
        tmp_path / "scenario",
        planner_responses=[
            _planner_authoring_response(_TEST_EXPECTS_42),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
                authorized_paths=("tests/test_feature.py",),
            ),
        ],
        implementer_responses=[
            _implementer_test_defect_blocked_response(),
            # The resumed Implementer rewrites BOTH the frozen test (42 -> 43) and
            # feature.py (41 -> 43) with equal sizes and equal integer mtimes.
            # Verification passes only if the rewrite-cached test module AND the
            # ordinary-cached implementation module are both observed fresh.
            _implementer_completed_response(
                {
                    "tests/test_feature.py": _TEST_EXPECTS_43,
                    "feature.py": _IMPL_RETURNS_43,
                }
            ),
        ],
        reviewer_responses=[_reviewer_response(attempt=2, verdict="approve")],
    )
    spy = _install_spy(monkeypatch, scenario.request)

    halted = run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )
    assert isinstance(halted, RetryCheckpointedTransactionResult)

    resumed = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert resumed.disposition == ResumeExecutionDisposition.SETTLED
    assert resumed.settlement is not None
    assert resumed.settlement.outcome == ResumeSettlementOutcome.COMPLETED

    assert len(spy.baseline_prefixes) == 1
    assert len(spy.verification_prefixes) == 1
    assert spy.baseline_prefixes[0] is not None
    assert spy.verification_prefixes[0] is not None
    assert spy.baseline_prefixes[0] != spy.verification_prefixes[0]
