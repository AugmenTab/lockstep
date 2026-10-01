"""Planner-authored specification of the Phase 4.1 single-subphase Supervisor transaction."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

import pytest

from lockstep.agents import AgentCommand, AgentInvocationRequest
from lockstep.domain import (
    BillingMode,
    PhaseId,
    ProjectId,
    RunId,
    SubphaseId,
)
from lockstep.git import inspect_repository
from lockstep.persistence import (
    ExecutionEvent,
    RunCreatedEvent,
    StateTransitionedEvent,
    read_events,
    read_state,
)
from lockstep.state import WorkflowState
from lockstep.supervisor import (
    SingleSubphaseTransactionRequest,
    SingleSubphaseTransactionResult,
    SupervisorTransactionError,
    run_single_subphase_transaction,
)


class _ScriptAdapter:
    """Deterministic AgentAdapter fixture that runs a fixed Python script."""

    def __init__(self, name: str, script: str) -> None:
        self.name = name
        self._script = script
        self.invocations: list[AgentInvocationRequest] = []

    def build_command(self, request: AgentInvocationRequest) -> AgentCommand:
        self.invocations.append(request)
        return AgentCommand(argv=(sys.executable, "-c", self._script))


def _git(
    repo: Path,
    *args: str,
    check: bool = True,
) -> subprocess.CompletedProcess[str]:
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

_TEST_FILE_GREEN = "def test_already_green() -> None:\n    assert True\n"

_IMPL_CORRECT = "def answer() -> int:\n    return 42\n"

_IMPL_WRONG = "def answer() -> int:\n    return 41\n"


def _script_write_test(content: str) -> str:
    return (
        "import pathlib\n"
        "target = pathlib.Path('tests/test_feature.py')\n"
        "target.parent.mkdir(parents=True, exist_ok=True)\n"
        f"target.write_text({content!r})\n"
    )


def _script_write_impl(content: str) -> str:
    return f"import pathlib\npathlib.Path('feature.py').write_text({content!r})\n"


def _script_write_impl_and_test(impl: str, test: str) -> str:
    return (
        "import pathlib\n"
        f"pathlib.Path('feature.py').write_text({impl!r})\n"
        f"pathlib.Path('tests/test_feature.py').write_text({test!r})\n"
    )


def _reviewer_script(verdict: str, summary: str) -> str:
    payload = json.dumps(
        {
            "schema_version": 1,
            "phase_id": "04",
            "subphase_id": "01",
            "attempt": 1,
            "verdict": verdict,
            "summary": summary,
        }
    )
    return f"import sys\nsys.stdout.write({payload!r})\n"


def _build_request(
    tmp_path: Path,
    source: Path,
    *,
    test_paths: tuple[str, ...] = ("tests/test_feature.py",),
    implementation_paths: tuple[str, ...] = ("feature.py",),
    test_commit_message: str = "test(feature): freeze answer expectation",
    implementation_commit_message: str = "feat(feature): implement answer",
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
        run_id=RunId.model_validate("20260924-001"),
        phase_id=PhaseId.model_validate("04"),
        subphase_id=SubphaseId.model_validate("01"),
        source_path=source,
        worktree_path=tmp_path / "run-worktree",
        runtime_dir=tmp_path / "runtime",
        branch="lockstep/run/run-04-01-supervisor",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        planner_prompt="draft the failing acceptance test",
        implementer_prompt="implement the acceptance test",
        reviewer_prompt="review the implementation",
        test_paths=test_paths,
        implementation_paths=implementation_paths,
        planner_quality_argv=(
            sys.executable,
            "-m",
            "py_compile",
            "tests/test_feature.py",
        ),
        baseline_argv=pytest_argv,
        verification_argv=pytest_argv,
        test_commit_message=test_commit_message,
        implementation_commit_message=implementation_commit_message,
        agent_timeout_seconds=60.0,
        command_timeout_seconds=60.0,
    )


def _parent_env(tmp_path: Path) -> dict[str, str]:
    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    return {
        "HOME": str(home),
        "PATH": "/usr/bin:/bin",
    }


def test_happy_path_completes_transaction(tmp_path: Path) -> None:
    source = _init_source_repo(tmp_path)
    source_head_before = inspect_repository(source).head_sha

    planner = _ScriptAdapter("planner", _script_write_test(_TEST_FILE_RED))
    implementer = _ScriptAdapter("implementer", _script_write_impl(_IMPL_CORRECT))
    reviewer = _ScriptAdapter("reviewer", _reviewer_script("approve", "approved"))

    request = _build_request(tmp_path, source)

    result = run_single_subphase_transaction(
        request,
        parent_env=_parent_env(tmp_path),
        planner_adapter=planner,
        implementer_adapter=implementer,
        reviewer_adapter=reviewer,
    )

    assert isinstance(result, SingleSubphaseTransactionResult)
    assert result.run_id == request.run_id
    assert result.phase_id == request.phase_id
    assert result.subphase_id == request.subphase_id
    assert result.branch == request.branch
    assert result.worktree_root == request.worktree_path.resolve()

    assert result.final_state.workflow_state == WorkflowState.SUBPHASE_COMPLETE
    # Observational execution events (10.2) share the journal sequence.
    assert result.final_state.last_sequence == len(
        read_events(request.runtime_dir / "events.jsonl")
    )
    assert result.review.verdict.value == "approve"
    assert result.review.summary == "approved"

    assert result.test_commit.committed_paths == ("tests/test_feature.py",)
    assert result.implementation_commit.committed_paths == ("feature.py",)
    assert result.test_commit.parent_sha == source_head_before
    assert result.implementation_commit.parent_sha == result.test_commit.commit_sha

    worktree_snapshot = inspect_repository(request.worktree_path)
    assert worktree_snapshot.is_clean
    assert worktree_snapshot.head_sha == result.implementation_commit.commit_sha

    assert inspect_repository(source).head_sha == source_head_before
    assert not (source / "feature.py").exists()
    assert not (source / "tests").exists()

    subjects = _log_subjects(request.worktree_path)
    assert subjects[0] == request.implementation_commit_message
    assert subjects[1] == request.test_commit_message
    assert subjects[2] == "initial"

    events = tuple(
        e
        for e in read_events(request.runtime_dir / "events.jsonl")
        if not isinstance(e, ExecutionEvent)
    )
    assert len(events) == 11
    assert isinstance(events[0], RunCreatedEvent)
    assert events[0].sequence == 1
    assert events[0].run_id == request.run_id
    assert events[0].project_id == request.project_id

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
        assert event.source == src
        assert event.target == dst

    persisted_state = read_state(request.runtime_dir / "state.json")
    assert persisted_state == result.final_state

    assert planner.invocations and planner.invocations[0].role.value == "planner"
    assert implementer.invocations and implementer.invocations[0].role.value == "implementer"
    assert reviewer.invocations and reviewer.invocations[0].role.value == "reviewer"


def test_unexpectedly_green_baseline_prevents_test_commit(tmp_path: Path) -> None:
    source = _init_source_repo(tmp_path)
    source_head_before = inspect_repository(source).head_sha

    planner = _ScriptAdapter("planner", _script_write_test(_TEST_FILE_GREEN))
    implementer = _ScriptAdapter("implementer", _script_write_impl(_IMPL_CORRECT))
    reviewer = _ScriptAdapter("reviewer", _reviewer_script("approve", "approved"))

    request = _build_request(tmp_path, source)

    with pytest.raises(SupervisorTransactionError) as exc_info:
        run_single_subphase_transaction(
            request,
            parent_env=_parent_env(tmp_path),
            planner_adapter=planner,
            implementer_adapter=implementer,
            reviewer_adapter=reviewer,
        )

    assert exc_info.value.stage == "baseline"

    persisted = read_state(request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.TEST_BASELINE_VERIFY

    assert implementer.invocations == []
    assert reviewer.invocations == []

    snapshot = inspect_repository(request.worktree_path)
    assert snapshot.head_sha == source_head_before
    assert snapshot.dirty_paths == ("tests/test_feature.py",)


def test_implementer_modifying_frozen_test_is_rejected(tmp_path: Path) -> None:
    source = _init_source_repo(tmp_path)

    planner = _ScriptAdapter("planner", _script_write_test(_TEST_FILE_RED))
    implementer = _ScriptAdapter(
        "implementer",
        _script_write_impl_and_test(_IMPL_CORRECT, "tampered\n"),
    )
    reviewer = _ScriptAdapter("reviewer", _reviewer_script("approve", "approved"))

    request = _build_request(tmp_path, source)

    with pytest.raises(SupervisorTransactionError) as exc_info:
        run_single_subphase_transaction(
            request,
            parent_env=_parent_env(tmp_path),
            planner_adapter=planner,
            implementer_adapter=implementer,
            reviewer_adapter=reviewer,
        )

    assert exc_info.value.stage == "implementation_scope"

    persisted = read_state(request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.IMPLEMENTING

    subjects = _log_subjects(request.worktree_path)
    assert subjects == [request.test_commit_message, "initial"]

    snapshot = inspect_repository(request.worktree_path)
    assert set(snapshot.dirty_paths) == {"feature.py", "tests/test_feature.py"}

    assert reviewer.invocations == []

    events = read_events(request.runtime_dir / "events.jsonl")
    reached_targets = {
        event.target for event in events if isinstance(event, StateTransitionedEvent)
    }
    assert WorkflowState.VERIFYING not in reached_targets
    assert WorkflowState.REVIEWING not in reached_targets
    assert WorkflowState.IMPLEMENTATION_COMMIT not in reached_targets


def test_failed_verification_prevents_review_and_commit(tmp_path: Path) -> None:
    source = _init_source_repo(tmp_path)

    planner = _ScriptAdapter("planner", _script_write_test(_TEST_FILE_RED))
    implementer = _ScriptAdapter("implementer", _script_write_impl(_IMPL_WRONG))
    reviewer = _ScriptAdapter("reviewer", _reviewer_script("approve", "approved"))

    request = _build_request(tmp_path, source)

    with pytest.raises(SupervisorTransactionError) as exc_info:
        run_single_subphase_transaction(
            request,
            parent_env=_parent_env(tmp_path),
            planner_adapter=planner,
            implementer_adapter=implementer,
            reviewer_adapter=reviewer,
        )

    assert exc_info.value.stage == "verification"

    persisted = read_state(request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.VERIFYING

    subjects = _log_subjects(request.worktree_path)
    assert subjects == [request.test_commit_message, "initial"]

    snapshot = inspect_repository(request.worktree_path)
    assert snapshot.dirty_paths == ("feature.py",)

    assert reviewer.invocations == []


def test_rework_verdict_prevents_implementation_commit(tmp_path: Path) -> None:
    source = _init_source_repo(tmp_path)

    planner = _ScriptAdapter("planner", _script_write_test(_TEST_FILE_RED))
    implementer = _ScriptAdapter("implementer", _script_write_impl(_IMPL_CORRECT))
    reviewer = _ScriptAdapter("reviewer", _reviewer_script("rework", "needs changes"))

    request = _build_request(tmp_path, source)

    with pytest.raises(SupervisorTransactionError) as exc_info:
        run_single_subphase_transaction(
            request,
            parent_env=_parent_env(tmp_path),
            planner_adapter=planner,
            implementer_adapter=implementer,
            reviewer_adapter=reviewer,
        )

    assert exc_info.value.stage == "review"

    persisted = read_state(request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.REVIEWING

    subjects = _log_subjects(request.worktree_path)
    assert subjects == [request.test_commit_message, "initial"]

    snapshot = inspect_repository(request.worktree_path)
    assert snapshot.dirty_paths == ("feature.py",)
