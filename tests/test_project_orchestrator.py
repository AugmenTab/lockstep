"""Phase 11.2: sequential Sub-phase orchestration over the durable project cursor.

Composes the accepted machinery -- Phase-8 Contract planning/freeze, the
Phase-9 single-Sub-phase transaction with retry checkpointing and at-most-once
resume, and the 11.1 project cursor -- so a current Phase's already-outlined
Sub-phases run one after another with no human relaying one transaction's
result into the next.

Everything here runs the real production code against fake provider
executables, a real Git source repository, and the real planning/cursor stores.
No real Claude/Codex account, network, or model inference is used.

Baseline classification: every test in this module is RED at entry
(``lockstep.project_orchestrator`` does not exist).
"""

from __future__ import annotations

import ast
import inspect
import json
import sys
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from pathlib import Path

import pytest
from test_supervisor_resume_execution import (
    _budget,
    _claude_adapter,
    _git,
    _implementer_blocked_response,
    _implementer_completed_response,
    _init_source_repo,
    _invocation_count,
    _parent_env,
    _process_failure_response,
    _review_decision_payload,
    _write_fake_claude_executable,
)

import lockstep.project_orchestrator as project_orchestrator
from lockstep.agents import (
    AgentProviderDiagnostics,
    AgentProviderStatuses,
    ResolvedAgentAdapters,
)
from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.config import ProjectConfig
from lockstep.contract_history import load_archived_subphase_contract
from lockstep.domain import (
    AgentRole,
    BillingMode,
    ExecutionEventKind,
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    RunId,
    StopReason,
    SubphaseContract,
    SubphaseId,
    SubphaseOutline,
)
from lockstep.escalation import EscalationAuthority, EscalationCategory
from lockstep.metrics import project_runtime_metrics
from lockstep.persistence import (
    ExecutionEvent,
    RunCreatedEvent,
    append_event,
    read_events,
    read_state,
    replay_events,
    write_state,
)
from lockstep.planning_store import (
    PlanningStoreError,
    freeze_master_plan,
    freeze_subphase_contract,
    load_active_subphase_contract,
    publish_phase_plan,
)
from lockstep.project_cursor import (
    PhaseGateStatus,
    PlanningEligibilityReason,
    ProjectCursor,
    ProjectCursorError,
    contract_digest,
    planning_eligibility,
)
from lockstep.project_cursor_store import load_project_cursor
from lockstep.project_orchestrator import (
    ProjectOrchestrationError,
    ProjectRunDisposition,
    ProjectRunResult,
    TransactionPlacement,
    allocate_transaction_run_id,
    run_project_phase,
    step_project_run,
    transaction_runtime_dir,
    transaction_worktree_path,
)
from lockstep.resume import claim_retry_checkpoint, mark_resume_started
from lockstep.runtime import AgentRuntime
from lockstep.state import WorkflowState
from lockstep.supervisor.escalation import SupervisorEscalationDisposition
from lockstep.supervisor.transaction import (
    ResumeExecutionDisposition,
    SingleSubphaseTransactionRequest,
)

_PHASE = "01"
_SRC = Path(__file__).resolve().parent.parent / "src" / "lockstep"
_BASELINE = Path(__file__).parent / "baselines" / "transaction_baseline.json"


# ---------------------------------------------------------------------------
# Scripted provider responses
# ---------------------------------------------------------------------------


def _test_source(sid: str) -> str:
    return (
        "import pathlib\n"
        "import sys\n"
        "\n"
        "sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))\n"
        "\n"
        f"from feature_{sid} import answer\n"
        "\n"
        "\n"
        "def test_answer() -> None:\n"
        f"    assert answer() == {int(sid)}\n"
    )


def _impl_source(sid: str, *, verbose: bool = False) -> str:
    if verbose:
        return f"def answer() -> int:\n    value = {int(sid)}\n    return value\n"
    return f"def answer() -> int:\n    return {int(sid)}\n"


def _contract_payload(sid: str) -> dict[str, object]:
    return {
        "schema_version": 1,
        "phase_id": _PHASE,
        "subphase_id": sid,
        "title": f"Feature {sid}",
        "objective": f"Provide feature {sid}.",
        "acceptance_criteria": [{"criterion_id": "AC-1", "description": f"Feature {sid} works."}],
        "tests": [
            {
                "path": f"tests/test_feature_{sid}.py",
                "expectation": "red",
                "acceptance_criteria": ["AC-1"],
            }
        ],
        "allowed_paths": [f"feature_{sid}.py"],
        "protected_paths": [],
        "forbidden_paths": [],
        "verification_commands": [f"pytest tests/test_feature_{sid}.py"],
    }


def _contract_response(sid: str) -> dict[str, object]:
    return {"stdout": json.dumps(_contract_payload(sid)), "returncode": 0}


def _tests_response(sid: str, *, path: str | None = None) -> dict[str, object]:
    target = path if path is not None else f"tests/test_feature_{sid}.py"
    return {"stdout": "", "returncode": 0, "files": {target: _test_source(sid)}}


def _impl_response(sid: str, *, verbose: bool = False) -> dict[str, object]:
    files = {f"feature_{sid}.py": _impl_source(sid, verbose=verbose)}
    return _implementer_completed_response(files)


def _review_response(sid: str, *, attempt: int = 1, verdict: str = "approve") -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "status": "completed",
                "review_decision": _review_decision_payload(
                    phase_id=_PHASE,
                    subphase_id=sid,
                    attempt=attempt,
                    verdict=verdict,
                    summary=f"{verdict} {sid}",
                ),
                "blocker": None,
            }
        ),
        "returncode": 0,
    }


def _planner_script(sids: tuple[str, ...]) -> list[dict[str, object]]:
    script: list[dict[str, object]] = []
    for sid in sids:
        script.append(_contract_response(sid))
        script.append(_tests_response(sid))
    return script


# ---------------------------------------------------------------------------
# Project construction
# ---------------------------------------------------------------------------

Mutate = Callable[[SingleSubphaseTransactionRequest], SingleSubphaseTransactionRequest]


@dataclass(frozen=True, slots=True)
class _Project:
    root: Path
    source: Path
    project_root: Path
    runtime_dir: Path
    runtime: AgentRuntime
    bins: dict[str, Path]
    sids: tuple[str, ...]
    factory: Callable[[SubphaseContract, TransactionPlacement], SingleSubphaseTransactionRequest]

    def launches(self, role: str) -> int:
        return _invocation_count(self.bins[role], f"claude-{role}")

    def run_id(self, sid: str) -> RunId:
        return RunId.model_validate(f"run-{_PHASE}-{sid}")

    def txn_dir(self, sid: str) -> Path:
        return transaction_runtime_dir(self.runtime_dir, self.run_id(sid))

    def worktree(self, sid: str) -> Path:
        return transaction_worktree_path(self.runtime_dir, self.run_id(sid))

    def state(self, sid: str) -> WorkflowState | None:
        snapshot = read_state(self.txn_dir(sid) / "state.json")
        return snapshot.workflow_state if snapshot is not None else None

    def cursor(self) -> ProjectCursor:
        cursor = load_project_cursor(self.project_root, self.runtime_dir)
        assert cursor is not None
        return cursor

    def run(self, *, budget: int = 3) -> ProjectRunResult:
        return run_project_phase(
            self.runtime,
            request_factory=self.factory,
            retry_budget=_budget(budget),
            planning_timeout_seconds=60.0,
            jit_replan=False,
        )

    def step(self, *, budget: int = 3) -> ProjectRunResult | None:
        return step_project_run(
            self.runtime,
            request_factory=self.factory,
            retry_budget=_budget(budget),
            planning_timeout_seconds=60.0,
            jit_replan=False,
        )

    def counts(self) -> tuple[int, int, int]:
        return (self.launches("planner"), self.launches("implementer"), self.launches("reviewer"))


def _phase_plan(sids: tuple[str, ...], *, title_suffix: str = "") -> PhasePlan:
    outlines = tuple(
        SubphaseOutline(
            subphase_id=SubphaseId.model_validate(sid),
            title=f"Outline {sid}{title_suffix}",
            objective=f"Objective {sid}.",
            depends_on=(SubphaseId.model_validate(sids[i - 1]),) if i else (),
        )
        for i, sid in enumerate(sids)
    )
    return PhasePlan(
        phase_id=PhaseId.model_validate(_PHASE),
        title="Sequential phase",
        objective="Run several Sub-phases in order.",
        depends_on=(),
        subphases=outlines,
        integration_acceptance_criteria=(),
    )


def _default_factory(
    source: Path, mutate: Mutate | None = None
) -> Callable[[SubphaseContract, TransactionPlacement], SingleSubphaseTransactionRequest]:
    def build(
        contract: SubphaseContract, placement: TransactionPlacement
    ) -> SingleSubphaseTransactionRequest:
        sid = contract.subphase_id.root
        test_paths = tuple(spec.path for spec in contract.tests)
        pytest_argv = (sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider", *test_paths)
        request = SingleSubphaseTransactionRequest(
            project_id=ProjectId.model_validate("lockstep"),
            run_id=placement.run_id,
            phase_id=contract.phase_id,
            subphase_id=contract.subphase_id,
            source_path=source,
            worktree_path=placement.worktree_path,
            runtime_dir=placement.runtime_dir,
            branch=placement.branch,
            base_branch=placement.base_branch,
            billing_mode=BillingMode.SUBSCRIPTION_ONLY,
            planner_prompt=f"author the failing tests for {sid}",
            implementer_prompt=f"implement feature {sid}",
            reviewer_prompt=f"review feature {sid}",
            test_paths=test_paths,
            implementation_paths=tuple(contract.allowed_paths),
            planner_quality_argv=(sys.executable, "-m", "py_compile", *test_paths),
            baseline_argv=pytest_argv,
            verification_argv=pytest_argv,
            test_commit_message=f"test(feature-{sid}): freeze answer expectation",
            implementation_commit_message=f"feat(feature-{sid}): implement answer",
            agent_timeout_seconds=60.0,
            command_timeout_seconds=60.0,
        )
        return mutate(request) if mutate is not None else request

    return build


def _make_project(
    tmp_path: Path,
    *,
    sids: tuple[str, ...] = ("01", "02"),
    planner: list[dict[str, object]] | None = None,
    implementer: list[dict[str, object]] | None = None,
    reviewer: list[dict[str, object]] | None = None,
    mutate: Mutate | None = None,
    outline: PhasePlan | None = None,
    initialize_cursor: bool = False,
) -> _Project:
    root = tmp_path / "world"
    root.mkdir()
    source = _init_source_repo(root)
    project_root = root / "agent-project"
    project_root.mkdir()
    runtime_dir = root / "runtime"
    runtime_dir.mkdir()

    master = MasterPlan(
        project_id=ProjectId.model_validate("lockstep"),
        title="Lockstep",
        objective="Build the control plane.",
        phases=(_phase_plan(sids),),
    )
    freeze_master_plan(project_root, master)
    if outline is not None:
        publish_phase_plan(project_root, runtime_dir, outline)
    if initialize_cursor:
        from lockstep.project_cursor_store import initialize_project_cursor

        initialize_project_cursor(project_root, runtime_dir)

    bins: dict[str, Path] = {}
    adapters = {}
    scripts = {
        "planner": planner if planner is not None else _planner_script(sids),
        "implementer": (
            implementer if implementer is not None else [_impl_response(sid) for sid in sids]
        ),
        "reviewer": (reviewer if reviewer is not None else [_review_response(sid) for sid in sids]),
    }
    roles = {
        "planner": AgentRole.PLANNER,
        "implementer": AgentRole.IMPLEMENTER,
        "reviewer": AgentRole.REVIEWER,
    }
    for role, responses in scripts.items():
        bins[role] = root / f"{role}-bin"
        _write_fake_claude_executable(bins[role], name=f"claude-{role}", responses=responses)
        adapters[role] = _claude_adapter(roles[role], executable=str(bins[role] / f"claude-{role}"))

    route = AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model="unused-model",
        effort="unused-effort",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )
    runtime = AgentRuntime(
        project_root=project_root,
        runtime_dir=runtime_dir,
        config=ProjectConfig(
            schema_version=1,
            routing=AgentRoutingPolicy(planner=route, implementer=route, reviewer=route),
        ),
        diagnostics=AgentProviderDiagnostics(statuses=AgentProviderStatuses()),
        adapters=ResolvedAgentAdapters(
            planner=adapters["planner"],
            implementer=adapters["implementer"],
            reviewer=adapters["reviewer"],
        ),
        transaction_parent_env=_parent_env(root),
    )
    return _Project(
        root=root,
        source=source,
        project_root=project_root,
        runtime_dir=runtime_dir,
        runtime=runtime,
        bins=bins,
        sids=sids,
        factory=_default_factory(source, mutate),
    )


class _CrashError(Exception):
    """Simulated process death at an exact point."""


def _subjects(worktree: Path) -> list[str]:
    return _git(worktree, "log", "--format=%s").stdout.strip().splitlines()


def _paths_of(worktree: Path, subject: str) -> tuple[str, ...]:
    sha = _git(worktree, "log", "--format=%H", "--grep", subject, "-F").stdout.split()[0]
    out = _git(worktree, "diff-tree", "--no-commit-id", "--name-only", "--no-renames", "-r", sha)
    return tuple(sorted(out.stdout.split()))


def _history_files(project: _Project) -> list[Path]:
    history = project.runtime_dir / "contracts" / "history"
    return sorted(history.iterdir()) if history.exists() else []


def _kinds(project: _Project, sid: str) -> Counter[ExecutionEventKind]:
    return Counter(
        event.kind
        for event in read_events(project.txn_dir(sid) / "events.jsonl")
        if isinstance(event, ExecutionEvent)
    )


# ===========================================================================
# Public surface and layout
# ===========================================================================


def test_public_api_exports_expected_names() -> None:
    assert set(project_orchestrator.__all__) == {
        "ProjectOrchestrationError",
        "ProjectRunDisposition",
        "ProjectRunResult",
        "TransactionPlacement",
        "TransactionRequestFactory",
        "allocate_transaction_run_id",
        "run_project_phase",
        "step_project_run",
        "transaction_runtime_dir",
        "transaction_worktree_path",
    }


def test_disposition_vocabulary_is_typed_and_not_a_duplicate_stop_reason() -> None:
    assert {d.name for d in ProjectRunDisposition} == {
        "PHASE_GATE_READY",
        "HALTED",
        "HUMAN_REQUIRED",
        "RECOVERY_REQUIRED",
        "EXECUTION_FAILED",
    }
    assert {d.value for d in ProjectRunDisposition}.isdisjoint({s.value for s in StopReason})


def test_run_ids_and_paths_are_deterministic_and_per_transaction(tmp_path: Path) -> None:
    phase = PhaseId.model_validate("01")
    first = allocate_transaction_run_id(phase, SubphaseId.model_validate("02"))
    again = allocate_transaction_run_id(phase, SubphaseId.model_validate("02"))
    other = allocate_transaction_run_id(phase, SubphaseId.model_validate("03"))
    assert first == again == RunId.model_validate("run-01-02")
    assert first != other

    runtime = tmp_path / "runtime"
    assert transaction_runtime_dir(runtime, first) == runtime / "transactions" / "run-01-02"
    assert transaction_worktree_path(runtime, first) == runtime / "worktrees" / "run-01-02"
    assert transaction_runtime_dir(runtime, first) != transaction_runtime_dir(runtime, other)


def test_run_signature_requires_explicit_policy_and_has_no_defaults_for_authority() -> None:
    for function in (run_project_phase, step_project_run):
        parameters = inspect.signature(function).parameters
        assert next(iter(parameters)) == "runtime"
        # 11.4: the host owns a canonical transaction-request factory, so an omitted
        # request_factory selects it. Policy-bearing arguments remain explicit.
        assert parameters["request_factory"].kind is inspect.Parameter.KEYWORD_ONLY
        assert parameters["request_factory"].default is None
        for name in ("retry_budget", "planning_timeout_seconds"):
            assert parameters[name].kind is inspect.Parameter.KEYWORD_ONLY
            assert parameters[name].default is inspect.Parameter.empty


# ===========================================================================
# AC-01/02/03/04/07/16/18: two successful Sub-phases, no human relay
# ===========================================================================


@pytest.fixture(scope="module")
def two_subphase_run(tmp_path_factory: pytest.TempPathFactory) -> tuple[_Project, ProjectRunResult]:
    project = _make_project(tmp_path_factory.mktemp("two"))
    return project, project.run()


def test_two_subphases_complete_sequentially_and_the_phase_gate_becomes_ready(
    two_subphase_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, result = two_subphase_run

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    cursor = project.cursor()
    assert cursor == result.cursor
    assert cursor.phase_gate_status is PhaseGateStatus.READY
    assert cursor.current_subphase is None and cursor.remaining_outline == ()
    assert cursor.active_contract is None
    assert [entry.subphase_id.root for entry in cursor.completed_subphases] == ["01", "02"]
    assert [entry.run_id.root for entry in cursor.completed_subphases] == [
        "run-01-01",
        "run-01-02",
    ]
    assert result.completed == cursor.completed_subphases


def test_each_subphase_has_its_own_run_id_journal_state_and_workflow(
    two_subphase_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, _ = two_subphase_run

    journals = {}
    for sid in project.sids:
        txn = project.txn_dir(sid)
        events = read_events(txn / "events.jsonl")
        [created] = [e for e in events if isinstance(e, RunCreatedEvent)]
        assert created.run_id == project.run_id(sid)
        assert project.state(sid) is WorkflowState.SUBPHASE_COMPLETE
        journals[sid] = events
    assert journals["01"] != journals["02"]
    # No project-level journal or checkpoint competes with the per-transaction ones.
    assert not (project.runtime_dir / "events.jsonl").exists()
    assert not (project.runtime_dir / "state.json").exists()


def test_the_only_progress_authority_is_the_cursor_and_the_layout_is_bounded(
    two_subphase_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, _ = two_subphase_run
    assert {p.name for p in project.runtime_dir.iterdir()} <= {
        "project",
        "planning",
        "contracts",
        "transactions",
        "worktrees",
    }
    assert [p.name for p in (project.runtime_dir / "project").iterdir()] == ["cursor.json"]


def test_git_history_is_independent_test_then_feat_commits_per_subphase(
    two_subphase_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, _ = two_subphase_run

    assert _subjects(project.worktree("02")) == [
        "feat(feature-02): implement answer",
        "test(feature-02): freeze answer expectation",
        "feat(feature-01): implement answer",
        "test(feature-01): freeze answer expectation",
        "initial",
    ]
    assert _subjects(project.worktree("01")) == [
        "feat(feature-01): implement answer",
        "test(feature-01): freeze answer expectation",
        "initial",
    ]
    assert _paths_of(project.worktree("02"), "feat(feature-02)") == ("feature_02.py",)
    assert _paths_of(project.worktree("02"), "feat(feature-01)") == ("feature_01.py",)
    assert _paths_of(project.worktree("02"), "test(feature-02)") == ("tests/test_feature_02.py",)
    assert _git(project.worktree("02"), "log", "--merges", "--format=%H").stdout.strip() == ""


def test_the_source_checkout_is_never_moved_or_dirtied(
    two_subphase_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, _ = two_subphase_run
    assert _subjects(project.source) == ["initial"]
    assert _git(project.source, "status", "--porcelain").stdout.strip() == ""


def test_every_role_launched_exactly_once_per_subphase(
    two_subphase_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, _ = two_subphase_run
    # planner: one Contract plan + one test-authoring turn per Sub-phase.
    assert project.counts() == (4, 2, 2)


def test_completed_contracts_are_history_and_the_active_slot_is_free(
    two_subphase_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, _ = two_subphase_run
    cursor = project.cursor()

    assert load_active_subphase_contract(project.project_root, project.runtime_dir) is None
    assert len(_history_files(project)) == 2
    for entry in cursor.completed_subphases:
        archived = load_archived_subphase_contract(
            project.project_root,
            project.runtime_dir,
            phase_id=entry.phase_id,
            subphase_id=entry.subphase_id,
            contract_digest=entry.contract_digest,
        )
        assert archived is not None
        assert contract_digest(archived) == entry.contract_digest
        assert archived.subphase_id == entry.subphase_id


def test_each_child_transaction_is_independently_measurable(
    two_subphase_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, _ = two_subphase_run
    for sid in project.sids:
        totals = project_runtime_metrics(project.txn_dir(sid), repository_change=None).totals
        assert (totals.subphases_attempted, totals.subphases_completed) == (1, 1)
        assert totals.executed_attempts == 1
        assert {role.value: n for role, n in totals.invocations_by_role.items()} == {
            "planner": 1,
            "implementer": 1,
            "reviewer": 1,
        }


def test_the_phase_10_baseline_is_still_version_1() -> None:
    assert json.loads(_BASELINE.read_text())["baseline_version"] == 1


def test_no_phase_gate_ran_and_no_phase_was_completed(
    two_subphase_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, result = two_subphase_run
    assert result.cursor.completed_phases == ()
    for sid in project.sids:
        states = {
            getattr(e, "target", None) for e in read_events(project.txn_dir(sid) / "events.jsonl")
        }
        assert WorkflowState.PHASE_INTEGRATION_GATE not in states
        assert WorkflowState.PHASE_COMPLETE not in states


def test_rerunning_a_ready_phase_stops_without_any_launch_or_cursor_change(
    two_subphase_run: tuple[_Project, ProjectRunResult],
) -> None:
    project, first = two_subphase_run
    before = project.counts()

    again = project.run()

    assert again.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert again.cursor == first.cursor
    assert again.completed == ()
    assert project.counts() == before


# ===========================================================================
# AC-05/06/17: planning only when eligible, one Contract, no replanning
# ===========================================================================


def test_only_the_current_contract_is_frozen_and_future_ones_are_not_pre_frozen(
    tmp_path: Path,
) -> None:
    project = _make_project(tmp_path, sids=("01", "02", "03"))

    assert project.step() is None  # plan + freeze + bind Sub-phase 01 only

    cursor = project.cursor()
    assert cursor.current_subphase == SubphaseId.model_validate("01")
    assert cursor.active_contract is not None
    assert cursor.active_contract.transaction_run_id == project.run_id("01")
    active = load_active_subphase_contract(project.project_root, project.runtime_dir)
    assert active is not None and active.subphase_id.root == "01"
    assert project.launches("planner") == 1  # a Contract plan only; no test authoring yet
    assert _history_files(project) == []
    assert not project.txn_dir("01").exists()  # bound, not yet launched
    assert [o.subphase_id.root for o in cursor.remaining_outline] == ["02", "03"]


def test_completion_is_recorded_before_the_next_contract_is_planned(tmp_path: Path) -> None:
    """The 11.3 seam: recording completion and planning the next unit are separate steps."""
    project = _make_project(tmp_path, sids=("01", "02", "03"))

    assert project.step() is None  # plan A
    assert project.step() is None  # run A, record, retire

    cursor = project.cursor()
    assert [e.subphase_id.root for e in cursor.completed_subphases] == ["01"]
    assert cursor.current_subphase == SubphaseId.model_validate("02")
    assert cursor.active_contract is None
    assert project.launches("planner") == 2  # Contract A + tests A; nothing for B yet
    assert load_active_subphase_contract(project.project_root, project.runtime_dir) is None

    assert project.step() is None  # plan B
    assert project.launches("planner") == 3
    active = load_active_subphase_contract(project.project_root, project.runtime_dir)
    assert active is not None and active.subphase_id.root == "02"
    # Contract A is recoverable history while Contract B is active.
    [first_entry] = project.cursor().completed_subphases
    assert (
        load_archived_subphase_contract(
            project.project_root,
            project.runtime_dir,
            phase_id=first_entry.phase_id,
            subphase_id=first_entry.subphase_id,
            contract_digest=first_entry.contract_digest,
        )
        is not None
    )


def test_the_provisional_outline_is_never_revised_between_subphases(tmp_path: Path) -> None:
    published = _phase_plan(("01", "02", "03"), title_suffix=" (provisional)")
    project = _make_project(
        tmp_path, sids=("01", "02", "03"), outline=published, initialize_cursor=True
    )
    plan_path = project.runtime_dir / "planning" / "phase-plan.json"
    before = plan_path.read_bytes()

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert plan_path.read_bytes() == before
    # Exactly one Contract plan and one test-authoring turn per Sub-phase: no outline Planner.
    assert project.counts() == (6, 3, 3)


def test_without_a_published_outline_the_frozen_phase_outline_is_adopted_verbatim(
    tmp_path: Path,
) -> None:
    project = _make_project(tmp_path)
    project.run()
    published = json.loads((project.runtime_dir / "planning" / "phase-plan.json").read_text())
    assert [s["subphase_id"] for s in published["subphases"]] == ["01", "02"]


def test_a_frozen_but_unbound_contract_is_bound_without_a_second_planner_call(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _make_project(tmp_path)
    real = project_orchestrator.bind_frozen_contract

    def crash(*args: object, **kwargs: object) -> object:
        raise _CrashError

    monkeypatch.setattr(project_orchestrator, "bind_frozen_contract", crash)
    with pytest.raises(_CrashError):
        project.step()
    monkeypatch.setattr(project_orchestrator, "bind_frozen_contract", real)

    assert project.cursor().active_contract is None
    assert load_active_subphase_contract(project.project_root, project.runtime_dir) is not None
    assert project.launches("planner") == 1

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert project.launches("planner") == 4  # one Contract plan per Sub-phase, never repeated


# ===========================================================================
# AC-10/11: retry / rework composition
# ===========================================================================


def _rework_project(tmp_path: Path, *, sids: tuple[str, ...] = ("01", "02")) -> _Project:
    return _make_project(
        tmp_path,
        sids=sids,
        implementer=[_impl_response("01"), _impl_response("02", verbose=True), _impl_response("02")]
        + [_impl_response(sid) for sid in sids[2:]],
        reviewer=[
            _review_response("01"),
            _review_response("02", attempt=1, verdict="rework"),
            _review_response("02", attempt=2),
        ]
        + [_review_response(sid) for sid in sids[2:]],
    )


def test_a_reworked_subphase_retries_automatically_and_is_recorded_exactly_once(
    tmp_path: Path,
) -> None:
    project = _rework_project(tmp_path)

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    cursor = project.cursor()
    assert [e.run_id.root for e in cursor.completed_subphases] == ["run-01-01", "run-01-02"]
    assert project.state("02") is WorkflowState.SUBPHASE_COMPLETE
    totals = project_runtime_metrics(project.txn_dir("02"), repository_change=None).totals
    assert totals.executed_attempts == 2 and totals.repeated_attempts == 1
    # One implementation commit for the reworked Sub-phase; REWORK never commits.
    subjects = _subjects(project.worktree("02"))
    assert subjects.count("feat(feature-02): implement answer") == 1
    assert subjects.count("feat(feature-01): implement answer") == 1
    assert project.counts() == (4, 3, 3)
    kinds = _kinds(project, "02")
    for kind in (
        ExecutionEventKind.RETRY_AUTHORIZED,
        ExecutionEventKind.RESUME_CLAIMED,
        ExecutionEventKind.RESUME_STARTED,
        ExecutionEventKind.RESUME_SETTLED,
    ):
        assert kinds[kind] == 1


def test_replaying_a_finished_rework_run_launches_nothing_and_records_nothing_twice(
    tmp_path: Path,
) -> None:
    project = _rework_project(tmp_path)
    first = project.run()
    before = project.counts()

    again = project.run()

    assert again.cursor == first.cursor
    assert project.counts() == before
    assert len(project.cursor().completed_subphases) == 2


def test_an_ambiguous_started_retry_is_never_relaunched(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _rework_project(tmp_path, sids=("01", "02", "03"))

    def crash_after_started(request: SingleSubphaseTransactionRequest, **_: object) -> object:
        inspection = claim_retry_checkpoint(request.runtime_dir)
        assert inspection.claim is not None
        mark_resume_started(request.runtime_dir, inspection.claim)
        raise _CrashError

    name = "resume_single_subphase_transaction"
    real = getattr(project_orchestrator, name)
    monkeypatch.setattr(project_orchestrator, name, crash_after_started)
    with pytest.raises(_CrashError):
        project.run()
    monkeypatch.setattr(project_orchestrator, name, real)
    before = project.counts()

    result = project.run()

    assert result.disposition is ProjectRunDisposition.RECOVERY_REQUIRED
    assert result.resume_disposition is ResumeExecutionDisposition.STARTED_RECOVERY_REQUIRED
    assert result.transaction_run_id == project.run_id("02")
    assert project.counts() == before
    cursor = project.cursor()
    assert [e.subphase_id.root for e in cursor.completed_subphases] == ["01"]
    assert cursor.current_subphase == SubphaseId.model_validate("02")
    assert project.launches("planner") == 4  # Sub-phase 03 never starts


def test_an_exhausted_retry_budget_halts_without_advancing(tmp_path: Path) -> None:
    project = _make_project(
        tmp_path,
        sids=("01", "02", "03"),
        reviewer=[_review_response("01"), _review_response("02", verdict="rework")],
    )

    result = project.run(budget=1)

    assert result.disposition is ProjectRunDisposition.HALTED
    assert result.resume_disposition is ResumeExecutionDisposition.RETRY_EXHAUSTED
    cursor = project.cursor()
    assert [e.subphase_id.root for e in cursor.completed_subphases] == ["01"]
    assert cursor.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING
    assert project.launches("planner") == 4  # Sub-phase 03 never starts
    before = project.counts()
    assert project.run(budget=1).disposition is ProjectRunDisposition.HALTED
    assert project.counts() == before


# ===========================================================================
# AC-13/14/15: halts stop progression; no fabricated authority
# ===========================================================================


def test_a_provider_failure_halts_the_phase_and_later_subphases_never_start(
    tmp_path: Path,
) -> None:
    project = _make_project(
        tmp_path,
        sids=("01", "02", "03"),
        implementer=[_impl_response("01"), _process_failure_response()],
    )

    result = project.run()

    assert result.disposition is ProjectRunDisposition.HALTED
    assert result.transaction_run_id == project.run_id("02")
    assert project.state("02") is WorkflowState.HALTED
    cursor = project.cursor()
    assert [e.subphase_id.root for e in cursor.completed_subphases] == ["01"]
    assert cursor.current_subphase == SubphaseId.model_validate("02")
    assert cursor.active_contract is not None
    assert cursor.phase_gate_status is PhaseGateStatus.SUBPHASES_PENDING
    # Contract+tests for 01 and 02; Contract 03 never planned; implementer ran for 01 and 02 only.
    assert project.counts()[0] == 4 and project.counts()[1] == 2


def test_a_halted_transaction_without_a_checkpoint_is_not_relaunched_on_restart(
    tmp_path: Path,
) -> None:
    project = _make_project(
        tmp_path,
        sids=("01", "02", "03"),
        implementer=[_impl_response("01"), _process_failure_response()],
    )
    first = project.run()
    before = project.counts()

    for _ in range(2):
        again = project.run()
        assert again.disposition is ProjectRunDisposition.HALTED
        assert again.cursor == first.cursor
        assert again.transaction_run_id == project.run_id("02")
    assert project.counts() == before
    assert not (project.txn_dir("02") / "retry").exists()


def test_a_human_required_stop_is_typed_durable_and_does_not_advance(tmp_path: Path) -> None:
    project = _make_project(
        tmp_path,
        sids=("01", "02", "03"),
        implementer=[
            _impl_response("01"),
            _implementer_blocked_response(
                category=EscalationCategory.REQUIREMENT_AMBIGUITY,
                requested_authority=EscalationAuthority.HUMAN,
            ),
        ],
    )

    result = project.run()

    assert result.disposition is ProjectRunDisposition.HUMAN_REQUIRED
    assert result.escalation_disposition is SupervisorEscalationDisposition.HUMAN_REQUIRED
    assert result.transaction_run_id == project.run_id("02")
    assert [e.subphase_id.root for e in project.cursor().completed_subphases] == ["01"]
    before = project.counts()

    # The disposition is reconstructed from the journal alone on restart: no relaunch, no skip.
    again = project.run()
    assert again.disposition is ProjectRunDisposition.HUMAN_REQUIRED
    assert again.escalation_disposition is SupervisorEscalationDisposition.HUMAN_REQUIRED
    assert project.counts() == before


def test_an_active_looking_crash_state_fails_closed_with_recovery_required(
    tmp_path: Path,
) -> None:
    project = _make_project(
        tmp_path,
        planner=[
            _contract_response("01"),
            _tests_response("01", path="tests/test_unexpected.py"),  # outside the Contract
        ],
    )

    first = project.run()

    assert first.disposition is ProjectRunDisposition.EXECUTION_FAILED
    assert project.state("01") is WorkflowState.TEST_AUTHORING
    before = project.counts()

    again = project.run()

    assert again.disposition is ProjectRunDisposition.RECOVERY_REQUIRED
    assert again.transaction_run_id == project.run_id("01")
    assert project.counts() == before
    assert project.cursor().completed_subphases == ()


# ===========================================================================
# AC-09/12: canonical completion only, and the completion/cursor crash window
# ===========================================================================


def _crash_recording_once(monkeypatch: pytest.MonkeyPatch, sid: str) -> None:
    real = project_orchestrator.record_completed_subphase
    fired: list[bool] = []

    def patched(
        project_root: Path, runtime_dir: Path, *, journal_path: Path, state_path: Path
    ) -> object:
        if not fired and journal_path.parent.name == f"run-{_PHASE}-{sid}":
            fired.append(True)
            raise _CrashError
        return real(project_root, runtime_dir, journal_path=journal_path, state_path=state_path)

    monkeypatch.setattr(project_orchestrator, "record_completed_subphase", patched)


@pytest.mark.parametrize("crash_on", ["02", "03"])
def test_a_completed_transaction_with_an_unrecorded_cursor_is_reconciled_without_rerun(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, crash_on: str
) -> None:
    project = _make_project(tmp_path, sids=("01", "02", "03"))
    _crash_recording_once(monkeypatch, crash_on)

    with pytest.raises(_CrashError):
        project.run()

    cursor = project.cursor()
    assert project.state(crash_on) is WorkflowState.SUBPHASE_COMPLETE
    assert crash_on not in [e.subphase_id.root for e in cursor.completed_subphases]
    assert cursor.active_contract is not None
    snapshot = read_state(project.txn_dir(crash_on) / "state.json")
    assert snapshot is not None
    assert (
        planning_eligibility(cursor, snapshot).reason
        is PlanningEligibilityReason.COMPLETION_NOT_RECORDED
    )
    before = project.counts()

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    done = [e.subphase_id.root for e in project.cursor().completed_subphases]
    assert done == ["01", "02", "03"]  # exactly once each
    # Sub-phase `crash_on` was not rerun: only the remaining Sub-phases launched anything.
    after = project.counts()
    remaining = 1 if crash_on == "02" else 0
    assert after == (before[0] + 2 * remaining, before[1] + remaining, before[2] + remaining)
    assert (
        _subjects(project.worktree(crash_on)).count(f"feat(feature-{crash_on}): implement answer")
        == 1
    )


def test_completion_is_only_ever_recorded_from_a_subphase_complete_journal(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _make_project(tmp_path)
    recorded: list[Path] = []
    real = project_orchestrator.record_completed_subphase

    def spy(
        project_root: Path, runtime_dir: Path, *, journal_path: Path, state_path: Path
    ) -> object:
        snapshot = read_state(state_path)
        assert snapshot is not None
        assert snapshot.workflow_state is WorkflowState.SUBPHASE_COMPLETE
        recorded.append(journal_path)
        return real(project_root, runtime_dir, journal_path=journal_path, state_path=state_path)

    monkeypatch.setattr(project_orchestrator, "record_completed_subphase", spy)

    project.run()

    assert len(recorded) == 2


# ===========================================================================
# AC-07: contract retirement crash windows
# ===========================================================================


def test_an_interrupted_contract_retirement_is_completed_before_the_next_freeze(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _make_project(tmp_path, sids=("01", "02", "03"))
    real = project_orchestrator.retire_active_subphase_contract
    fired: list[bool] = []

    def crash_once(project_root: Path, runtime_dir: Path, *, contract_digest: str) -> Path:
        if not fired:
            fired.append(True)
            raise _CrashError
        return real(project_root, runtime_dir, contract_digest=contract_digest)

    monkeypatch.setattr(project_orchestrator, "retire_active_subphase_contract", crash_once)
    with pytest.raises(_CrashError):
        project.run()

    # 01 is complete and recorded; its Contract is still the stale active file.
    cursor = project.cursor()
    assert [e.subphase_id.root for e in cursor.completed_subphases] == ["01"]
    assert cursor.active_contract is None
    stale = load_active_subphase_contract(project.project_root, project.runtime_dir)
    assert stale is not None and stale.subphase_id.root == "01"
    # The existing store still refuses to let the next Contract overwrite it.
    with pytest.raises(PlanningStoreError, match="already active"):
        freeze_subphase_contract(
            project.project_root,
            project.runtime_dir,
            SubphaseContract.model_validate(_contract_payload("02")),
        )
    planner_before = project.launches("planner")

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert planner_before == 2  # Contract 02 was never planned over the stale file
    first = cursor.completed_subphases[0]
    archived = load_archived_subphase_contract(
        project.project_root,
        project.runtime_dir,
        phase_id=first.phase_id,
        subphase_id=first.subphase_id,
        contract_digest=first.contract_digest,
    )
    assert archived == stale
    assert len(_history_files(project)) == 3


# ===========================================================================
# AC-20: identity mismatches are rejected, never silently executed
# ===========================================================================


def _bound_unlaunched(tmp_path: Path) -> _Project:
    project = _make_project(tmp_path, sids=("01", "02"))
    assert project.step() is None  # plan + bind 01
    return project


def _write_journal(txn_dir: Path, *, run_id: str, foreign_subphase: str | None = None) -> None:
    journal = txn_dir / "events.jsonl"
    when = datetime(2026, 1, 1, tzinfo=UTC)
    rid = RunId.model_validate(run_id)
    append_event(
        journal,
        RunCreatedEvent(
            run_id=rid,
            sequence=1,
            occurred_at=when,
            project_id=ProjectId.model_validate("lockstep"),
        ),
    )
    if foreign_subphase is not None:
        append_event(
            journal,
            ExecutionEvent(
                run_id=rid,
                sequence=2,
                occurred_at=when,
                kind=ExecutionEventKind.TESTS_FROZEN,
                phase_id=PhaseId.model_validate(_PHASE),
                subphase_id=SubphaseId.model_validate(foreign_subphase),
            ),
        )
    write_state(txn_dir / "state.json", replay_events(read_events(journal)))


def test_a_journal_created_for_another_run_is_rejected(tmp_path: Path) -> None:
    project = _bound_unlaunched(tmp_path)
    project.txn_dir("01").mkdir(parents=True)
    _write_journal(project.txn_dir("01"), run_id="run-01-09")
    before = project.counts()

    with pytest.raises(ProjectCursorError):
        project.step()

    assert project.counts() == before


def test_a_journal_naming_another_subphase_is_rejected(tmp_path: Path) -> None:
    project = _bound_unlaunched(tmp_path)
    project.txn_dir("01").mkdir(parents=True)
    _write_journal(project.txn_dir("01"), run_id="run-01-01", foreign_subphase="02")
    before = project.counts()

    with pytest.raises(ProjectCursorError):
        project.step()

    assert project.counts() == before


def _wrong(**changes: object) -> Mutate:
    def mutate(request: SingleSubphaseTransactionRequest) -> SingleSubphaseTransactionRequest:
        return replace(request, **changes)  # type: ignore[arg-type]

    return mutate


@pytest.mark.parametrize(
    "changes",
    [
        {"run_id": RunId.model_validate("run-01-77")},
        {"subphase_id": SubphaseId.model_validate("02")},
        {"phase_id": PhaseId.model_validate("02")},
        {"test_paths": ("tests/test_something_else.py",)},
        {"runtime_dir": Path("/nonexistent/elsewhere")},
        {"worktree_path": Path("/nonexistent/elsewhere-wt")},
        {"branch": "lockstep/run/not-this-run"},
        {"base_branch": "main"},
    ],
    ids=["run", "subphase", "phase", "tests", "runtime", "worktree", "branch", "base"],
)
def test_a_request_that_does_not_match_the_bound_contract_is_rejected_before_any_launch(
    tmp_path: Path, changes: dict[str, object]
) -> None:
    project = _make_project(tmp_path, mutate=_wrong(**changes))
    assert project.step() is None  # Contract planning is host-side and precedes the request

    with pytest.raises(ProjectOrchestrationError):
        project.step()

    assert project.launches("planner") == 1  # no test-authoring turn
    assert project.launches("implementer") == 0
    assert not project.txn_dir("01").exists()
    assert project.cursor().completed_subphases == ()


def test_the_second_subphase_is_rooted_at_the_first_runs_branch(tmp_path: Path) -> None:
    project = _make_project(tmp_path)
    seen: list[TransactionPlacement] = []
    inner = project.factory

    def spy(
        contract: SubphaseContract, placement: TransactionPlacement
    ) -> SingleSubphaseTransactionRequest:
        seen.append(placement)
        return inner(contract, placement)

    run_project_phase(
        project.runtime,
        request_factory=spy,
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
        jit_replan=False,
    )

    assert [p.run_id.root for p in seen] == ["run-01-01", "run-01-02"]
    assert seen[0].base_branch is None
    assert seen[1].base_branch == seen[0].branch
    assert seen[0].branch != seen[1].branch


# ===========================================================================
# Authority preservation: structure of the orchestrator itself
# ===========================================================================


def _orchestrator_source() -> str:
    return (_SRC / "project_orchestrator.py").read_text()


def _imported_names(tree: ast.Module) -> set[str]:
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom | ast.Import):
            names.update(alias.name for alias in node.names)
    return names


def test_the_orchestrator_composes_transaction_machinery_instead_of_duplicating_it() -> None:
    imported = _imported_names(ast.parse(_orchestrator_source()))
    assert {
        "run_single_subphase_transaction_with_retry_checkpoint",
        "resume_single_subphase_transaction",
        "create_subphase_contract_candidate",
        "freeze_subphase_contract",
        "record_completed_subphase",
        "bind_frozen_contract",
        "planning_eligibility",
    } <= imported
    forbidden = {
        "invoke_agent",
        "invoke_agent_turn",
        "invoke_reviewer_turn",
        "run_process",
        "commit_exact_paths",
        "commit_exact_subset_paths",
        "create_run_worktree",
        "dispatch_escalation",
        "append_event",
        "write_state",
        "record_execution_event",
        "create_phase_plan_candidate",
        "create_master_plan_candidate",
        "revise_cursor_outline",
    }
    assert imported.isdisjoint(forbidden)


def test_the_orchestrator_owns_no_second_progress_file_and_no_gate_or_phase_completion() -> None:
    source = _orchestrator_source()
    assert "cursor.json" not in source
    assert "PHASE_INTEGRATION_GATE" not in source
    exact_symbols = {
        node.attr if isinstance(node, ast.Attribute) else node.id
        for node in ast.walk(ast.parse(source))
        if isinstance(node, ast.Attribute | ast.Name)
    }
    assert "PHASE_COMPLETE" not in exact_symbols
    assert "completed_phases" not in source
    assert "revise_remaining_outline" not in source
