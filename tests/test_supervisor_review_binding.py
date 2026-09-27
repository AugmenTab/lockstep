"""Planner-authored specification of Sub-phase 6.5 reviewer transaction binding.

Production Supervisor must reject any schema-valid ``ReviewDecision`` whose
``phase_id``/``subphase_id``/``attempt`` do not exactly match the current
transaction, before the verdict is ever interpreted. A stale or foreign
artifact must not be able to advance, block, or halt a transaction that
never requested it.
"""

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
    ReviewDecision,
    RunId,
    SubphaseId,
)
from lockstep.git import inspect_repository
from lockstep.persistence import StateTransitionedEvent, read_events, read_state
from lockstep.state import WorkflowState
from lockstep.supervisor import (
    SingleSubphaseTransactionRequest,
    SupervisorTransactionError,
    run_single_subphase_transaction,
)

_PHASE_ID = "06"
_SUBPHASE_ID = "05"
_ATTEMPT = 1

_BOUND_REASON = "reviewer decision does not match current transaction"

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


class _ScriptAdapter:
    """Deterministic AgentAdapter fixture that runs a fixed Python script."""

    def __init__(self, name: str, script: str) -> None:
        self.name = name
        self._script = script
        self.invocations: list[AgentInvocationRequest] = []

    def build_command(self, request: AgentInvocationRequest) -> AgentCommand:
        self.invocations.append(request)
        return AgentCommand(argv=(sys.executable, "-c", self._script))


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


def _script_write_test(content: str) -> str:
    return (
        "import pathlib\n"
        "target = pathlib.Path('tests/test_feature.py')\n"
        "target.parent.mkdir(parents=True, exist_ok=True)\n"
        f"target.write_text({content!r})\n"
    )


def _script_write_impl(content: str) -> str:
    return f"import pathlib\npathlib.Path('feature.py').write_text({content!r})\n"


def _reviewer_script(
    *,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    attempt: int = _ATTEMPT,
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


def _build_request(tmp_path: Path, source: Path) -> SingleSubphaseTransactionRequest:
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
        run_id=RunId.model_validate("20260927-001"),
        phase_id=PhaseId.model_validate(_PHASE_ID),
        subphase_id=SubphaseId.model_validate(_SUBPHASE_ID),
        source_path=source,
        worktree_path=tmp_path / "run-worktree",
        runtime_dir=tmp_path / "runtime",
        branch="lockstep/run/run-06-05-review-binding",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        planner_prompt="draft the failing acceptance test",
        implementer_prompt="implement the acceptance test",
        reviewer_prompt="review the implementation",
        test_paths=("tests/test_feature.py",),
        implementation_paths=("feature.py",),
        planner_quality_argv=(
            sys.executable,
            "-m",
            "py_compile",
            "tests/test_feature.py",
        ),
        baseline_argv=pytest_argv,
        verification_argv=pytest_argv,
        test_commit_message="test(feature): freeze answer expectation",
        implementation_commit_message="feat(feature): implement answer",
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


def _run_transaction(
    tmp_path: Path,
    source: Path,
    *,
    reviewer_script: str,
):
    request = _build_request(tmp_path, source)
    planner = _ScriptAdapter("planner", _script_write_test(_TEST_FILE_RED))
    implementer = _ScriptAdapter("implementer", _script_write_impl(_IMPL_CORRECT))
    reviewer = _ScriptAdapter("reviewer", reviewer_script)

    result = run_single_subphase_transaction(
        request,
        parent_env=_parent_env(tmp_path),
        planner_adapter=planner,
        implementer_adapter=implementer,
        reviewer_adapter=reviewer,
    )
    return request, result


def _run_transaction_expecting_error(
    tmp_path: Path,
    source: Path,
    *,
    reviewer_script: str,
) -> tuple[SingleSubphaseTransactionRequest, pytest.ExceptionInfo[SupervisorTransactionError]]:
    request = _build_request(tmp_path, source)
    planner = _ScriptAdapter("planner", _script_write_test(_TEST_FILE_RED))
    implementer = _ScriptAdapter("implementer", _script_write_impl(_IMPL_CORRECT))
    reviewer = _ScriptAdapter("reviewer", reviewer_script)

    with pytest.raises(SupervisorTransactionError) as exc_info:
        run_single_subphase_transaction(
            request,
            parent_env=_parent_env(tmp_path),
            planner_adapter=planner,
            implementer_adapter=implementer,
            reviewer_adapter=reviewer,
        )
    return request, exc_info


def test_correctly_bound_approve_completes_transaction(tmp_path: Path) -> None:
    source = _init_source_repo(tmp_path)

    request, result = _run_transaction(
        tmp_path,
        source,
        reviewer_script=_reviewer_script(verdict="approve", summary="approved"),
    )

    assert result.final_state.workflow_state == WorkflowState.SUBPHASE_COMPLETE
    assert result.implementation_commit.committed_paths == ("feature.py",)

    expected_review = ReviewDecision.model_validate(
        {
            "schema_version": 1,
            "phase_id": _PHASE_ID,
            "subphase_id": _SUBPHASE_ID,
            "attempt": _ATTEMPT,
            "verdict": "approve",
            "summary": "approved",
        }
    )
    assert result.review == expected_review

    subjects = _log_subjects(request.worktree_path)
    assert subjects[0] == request.implementation_commit_message


@pytest.mark.parametrize(
    ("phase_id", "subphase_id", "attempt"),
    [
        pytest.param("99", _SUBPHASE_ID, _ATTEMPT, id="wrong-phase"),
        pytest.param(_PHASE_ID, "99", _ATTEMPT, id="wrong-subphase"),
        pytest.param(_PHASE_ID, _SUBPHASE_ID, 2, id="wrong-attempt"),
    ],
)
@pytest.mark.parametrize("verdict", ["approve", "rework", "halt"])
def test_mismatched_metadata_fails_closed_for_every_verdict(
    tmp_path: Path,
    phase_id: str,
    subphase_id: str,
    attempt: int,
    verdict: str,
) -> None:
    source = _init_source_repo(tmp_path)

    request, exc_info = _run_transaction_expecting_error(
        tmp_path,
        source,
        reviewer_script=_reviewer_script(
            phase_id=phase_id,
            subphase_id=subphase_id,
            attempt=attempt,
            verdict=verdict,
            summary="mismatched",
        ),
    )

    assert exc_info.value.stage == "review"
    assert exc_info.value.reason == _BOUND_REASON

    persisted = read_state(request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.REVIEWING

    subjects = _log_subjects(request.worktree_path)
    assert subjects == [request.test_commit_message, "initial"]
    assert request.implementation_commit_message not in subjects

    snapshot = inspect_repository(request.worktree_path)
    assert snapshot.dirty_paths == ("feature.py",)

    events = read_events(request.runtime_dir / "events.jsonl")
    reached_targets = {
        event.target for event in events if isinstance(event, StateTransitionedEvent)
    }
    assert WorkflowState.IMPLEMENTATION_COMMIT not in reached_targets
    assert WorkflowState.SUBPHASE_COMPLETE not in reached_targets


def test_mismatch_error_does_not_leak_reviewer_output(tmp_path: Path) -> None:
    source = _init_source_repo(tmp_path)
    sentinel = "SENTINEL-6F3C9B21-DO-NOT-LEAK"

    _request, exc_info = _run_transaction_expecting_error(
        tmp_path,
        source,
        reviewer_script=_reviewer_script(
            phase_id="99",
            verdict="approve",
            summary=sentinel,
        ),
    )

    assert sentinel not in str(exc_info.value)
    assert sentinel not in exc_info.value.reason
    assert exc_info.value.reason == _BOUND_REASON
