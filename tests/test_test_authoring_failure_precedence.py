"""Planner test-authoring failure-precedence remediation (Phase 8 R1).

Gate attempt #3 (see ``.local/retros/retro-08_integration.md``) found that
a real, correctly qualified Codex Planner turn could complete its process
without the Contract's required test path appearing in the worktree, and
that ``author_planner_tests`` reported this identically to a simple
"process succeeded but never touched the file" case — because the
missing-required-path check ran *before* the Planner process's own exit
status was consulted. That conflation is the defect this module pins
down.

These tests exercise the ordering directly: given the exact same
repository-safety evidence (HEAD/branch, Git index, unexpected paths,
deletion/symlink safety), a non-zero Planner process exit must be
reported ahead of a merely-missing expected path, while every
higher-priority repository-safety diagnostic (unauthorized mutation,
index mutation, HEAD mutation, unsafe deletion) must still outrank the
process-exit diagnosis itself.

Uses a real, disposable Git worktree (created with the system ``git``
executable in fixture setup only) and a fake Planner executable that
performs declarative filesystem/Git actions and exits with a configured
return code — no real Claude/Codex account, no network, no real model
inference. Production ``test_authoring.py`` is exercised exclusively
through its public ``author_planner_tests`` API.
"""

from __future__ import annotations

import json
import stat
import subprocess
import sys
import textwrap
from collections.abc import Mapping
from pathlib import Path

import pytest

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
    AgentRole,
    BillingMode,
    MasterPlan,
    PhaseId,
    PhasePlan,
    SubphaseContract,
    SubphaseId,
)
from lockstep.planning_store import (
    freeze_master_plan,
    freeze_subphase_contract,
    publish_phase_plan,
)
from lockstep.runtime import AgentRuntime
from lockstep.test_authoring import TestAuthoringError, author_planner_tests

_BILLING_MODE = BillingMode.SUBSCRIPTION_ONLY
_DEFAULT_TEST_PATHS: tuple[str, ...] = ("tests/test_a.py", "tests/test_b.py")


# ---------------------------------------------------------------------------
# Git worktree fixtures (fixture setup only; production is public-API-only)
# ---------------------------------------------------------------------------


def _git(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(repo), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def _init_worktree(
    tmp_path: Path,
    *,
    name: str = "worktree",
    extra_files: Mapping[str, str] | None = None,
) -> Path:
    repo = tmp_path / name
    repo.mkdir()

    _git(repo, "init")
    _git(repo, "config", "user.name", "Lockstep Tests")
    _git(repo, "config", "user.email", "lockstep-tests@example.invalid")

    (repo / "README.md").write_text("initial\n", encoding="utf-8")
    tracked_names = ["README.md"]
    if extra_files:
        for rel_path, content in extra_files.items():
            target = repo / rel_path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content, encoding="utf-8")
            tracked_names.append(rel_path)

    _git(repo, "add", *tracked_names)
    _git(repo, "commit", "-m", "initial")
    _git(repo, "branch", "-M", "main")

    return repo


# ---------------------------------------------------------------------------
# Fake Planner executable — performs filesystem/Git actions in its cwd
# ---------------------------------------------------------------------------


def _write_fake_planner_executable(
    bin_dir: Path,
    *,
    name: str,
    actions: list[dict[str, object]] | None = None,
    returncode: int = 0,
) -> Path:
    bin_dir.mkdir(parents=True, exist_ok=True)
    executable = bin_dir / name
    config_path = bin_dir / f"{name}-response.json"
    config_path.write_text(
        json.dumps({"actions": actions if actions is not None else [], "returncode": returncode}),
        encoding="utf-8",
    )

    script = textwrap.dedent(
        f"""\
        #!{sys.executable}
        import json
        import subprocess
        import sys
        from pathlib import Path

        base = Path(__file__).resolve().parent
        config = json.loads((base / "{name}-response.json").read_text(encoding="utf-8"))
        sys.stdin.read()

        cwd = Path.cwd()
        for action in config["actions"]:
            kind = action["kind"]
            if kind == "write":
                target = cwd / action["path"]
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(action["content"], encoding="utf-8")
            elif kind == "delete":
                (cwd / action["path"]).unlink()
            elif kind == "git":
                subprocess.run(["git", *action["args"]], cwd=cwd, check=True)

        raise SystemExit(int(config["returncode"]))
        """
    )
    executable.write_text(script, encoding="utf-8")
    mode = executable.stat().st_mode
    executable.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _default_write_actions(paths: tuple[str, ...]) -> list[dict[str, object]]:
    return [
        {"kind": "write", "path": path, "content": f"# authored content for {path}\n"}
        for path in paths
    ]


# ---------------------------------------------------------------------------
# CLI status / adapter / runtime fixtures (mirrors 8.7's own fixtures)
# ---------------------------------------------------------------------------


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


def _planner_adapter(
    bin_dir: Path,
    *,
    actions: list[dict[str, object]] | None = None,
    returncode: int = 0,
) -> AgentAdapter:
    executable = _write_fake_planner_executable(
        bin_dir, name="claude", actions=actions, returncode=returncode
    )
    return ClaudeAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_claude_status(executable=str(executable)),
        model="claude-model",
        effort="high",
    )


def _runtime(tmp_path: Path, *, planner_adapter: AgentAdapter) -> AgentRuntime:
    project_root = tmp_path / "project"
    project_root.mkdir(exist_ok=True)
    runtime_dir = tmp_path / "runtime"
    runtime_dir.mkdir(exist_ok=True)

    route = AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model="unused-model",
        effort="unused-effort",
        billing_mode=_BILLING_MODE,
    )
    policy = AgentRoutingPolicy(planner=route, implementer=route, reviewer=route)
    config = ProjectConfig(schema_version=1, routing=policy)

    diagnostics = AgentProviderDiagnostics(statuses=AgentProviderStatuses())
    adapters = ResolvedAgentAdapters(
        planner=planner_adapter, implementer=planner_adapter, reviewer=planner_adapter
    )

    home_dir = tmp_path / "home"
    home_dir.mkdir(exist_ok=True)

    return AgentRuntime(
        project_root=project_root,
        runtime_dir=runtime_dir,
        config=config,
        diagnostics=diagnostics,
        adapters=adapters,
        transaction_parent_env={"HOME": str(home_dir), "PATH": "/usr/bin"},
    )


# ---------------------------------------------------------------------------
# Master Plan / Phase plan / Contract payload fixtures (mirrors 8.7's own)
# ---------------------------------------------------------------------------


def _outline_payload(subphase_id: str = "01") -> dict[str, object]:
    return {
        "subphase_id": subphase_id,
        "title": "Outline title",
        "objective": "Outline objective.",
        "depends_on": [],
    }


def _phase_payload(phase_id: str = "01") -> dict[str, object]:
    return {
        "schema_version": 1,
        "phase_id": phase_id,
        "title": "Phase title",
        "objective": "Phase objective.",
        "depends_on": [],
        "subphases": [_outline_payload()],
        "integration_acceptance_criteria": [],
    }


def _master_plan_payload() -> dict[str, object]:
    return {
        "schema_version": 1,
        "project_id": "lockstep",
        "title": "Lockstep",
        "objective": "Build the local orchestration control plane.",
        "phases": [_phase_payload()],
    }


def _contract_payload(*, tests: list[dict[str, object]] | None = None) -> dict[str, object]:
    used_tests = (
        tests
        if tests is not None
        else [
            {"path": path, "expectation": "red", "acceptance_criteria": ["AC-1"]}
            for path in _DEFAULT_TEST_PATHS
        ]
    )
    return {
        "schema_version": 1,
        "phase_id": "01",
        "subphase_id": "01",
        "title": "Contract title",
        "objective": "Contract objective.",
        "acceptance_criteria": [{"criterion_id": "AC-1", "description": "Criterion."}],
        "tests": used_tests,
        "allowed_paths": ["src/example.py"],
        "protected_paths": [],
        "forbidden_paths": [],
        "verification_commands": ["pytest tests/test_a.py tests/test_b.py"],
    }


def _setup(
    tmp_path: Path,
    *,
    contract_payload: dict[str, object] | None = None,
    planner_actions: list[dict[str, object]] | None = None,
    planner_returncode: int = 0,
    extra_worktree_files: Mapping[str, str] | None = None,
) -> tuple[AgentRuntime, Path]:
    bin_dir = tmp_path / "bin"
    used_contract_payload = (
        contract_payload if contract_payload is not None else _contract_payload()
    )
    contract = SubphaseContract.model_validate(used_contract_payload)

    used_actions = (
        planner_actions
        if planner_actions is not None
        else _default_write_actions(tuple(test.path for test in contract.tests))
    )

    adapter = _planner_adapter(bin_dir, actions=used_actions, returncode=planner_returncode)
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    freeze_master_plan(runtime.project_root, MasterPlan.model_validate(_master_plan_payload()))
    publish_phase_plan(
        runtime.project_root, runtime.runtime_dir, PhasePlan.model_validate(_phase_payload())
    )
    freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, contract)

    worktree_path = _init_worktree(tmp_path, extra_files=extra_worktree_files)
    return runtime, worktree_path


def _author(runtime: AgentRuntime, worktree_path: Path) -> object:
    return author_planner_tests(
        runtime,
        worktree_path=worktree_path,
        phase_id=PhaseId.model_validate("01"),
        subphase_id=SubphaseId.model_validate("01"),
        timeout_seconds=5.0,
    )


# ===========================================================================
# §9 — successful process, missing required file: unchanged behavior
# ===========================================================================


def test_successful_process_with_missing_file_reports_missing_path(tmp_path: Path) -> None:
    runtime, worktree_path = _setup(tmp_path, planner_actions=[], planner_returncode=0)

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "not changed" in exc_info.value.reason or "missing" in exc_info.value.reason


# ===========================================================================
# §10 — non-zero process, no repository mutation: process failure wins
# ===========================================================================


def test_non_zero_process_with_no_mutation_reports_process_failure(tmp_path: Path) -> None:
    runtime, worktree_path = _setup(tmp_path, planner_actions=[], planner_returncode=1)

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "process" in exc_info.value.reason or "status" in exc_info.value.reason
    assert "not changed" not in exc_info.value.reason
    assert "missing" not in exc_info.value.reason


# ===========================================================================
# §11 — non-zero process, partial expected writes: process failure wins
# over the still-missing expected path
# ===========================================================================


def test_non_zero_process_with_partial_writes_reports_process_failure(tmp_path: Path) -> None:
    runtime, worktree_path = _setup(
        tmp_path,
        planner_actions=_default_write_actions(("tests/test_a.py",)),
        planner_returncode=1,
    )

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "process" in exc_info.value.reason or "status" in exc_info.value.reason
    assert "not changed" not in exc_info.value.reason
    assert "missing" not in exc_info.value.reason
    assert (worktree_path / "tests" / "test_a.py").exists()


# ===========================================================================
# §12 — unauthorized mutation outranks process failure
# ===========================================================================


def test_unauthorized_mutation_outranks_process_failure(tmp_path: Path) -> None:
    actions = [
        *_default_write_actions(("tests/test_a.py",)),
        {"kind": "write", "path": "src/lockstep/bad.py", "content": "unauthorized\n"},
    ]
    contract_payload = _contract_payload(
        tests=[{"path": "tests/test_a.py", "expectation": "red", "acceptance_criteria": ["AC-1"]}]
    )
    runtime, worktree_path = _setup(
        tmp_path,
        contract_payload=contract_payload,
        planner_actions=actions,
        planner_returncode=1,
    )

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "outside" in exc_info.value.reason or "unexpected" in exc_info.value.reason
    assert (worktree_path / "src" / "lockstep" / "bad.py").exists()
    assert (worktree_path / "tests" / "test_a.py").exists()


# ===========================================================================
# §13 — staged/index mutation outranks process failure
# ===========================================================================


def test_staged_index_mutation_outranks_process_failure(tmp_path: Path) -> None:
    contract_payload = _contract_payload(
        tests=[{"path": "tests/test_a.py", "expectation": "red", "acceptance_criteria": ["AC-1"]}]
    )
    actions = [
        {"kind": "write", "path": "tests/test_a.py", "content": "content\n"},
        {"kind": "git", "args": ["add", "tests/test_a.py"]},
    ]
    runtime, worktree_path = _setup(
        tmp_path,
        contract_payload=contract_payload,
        planner_actions=actions,
        planner_returncode=1,
    )

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "index" in exc_info.value.reason


# ===========================================================================
# §14 — HEAD mutation outranks process failure
# ===========================================================================


def test_head_mutation_outranks_process_failure(tmp_path: Path) -> None:
    actions = [
        *_default_write_actions(_DEFAULT_TEST_PATHS),
        {"kind": "git", "args": ["add", "."]},
        {"kind": "git", "args": ["commit", "-m", "planner committed"]},
    ]
    runtime, worktree_path = _setup(tmp_path, planner_actions=actions, planner_returncode=1)

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "history" in exc_info.value.reason or "head" in exc_info.value.reason.lower()


# ===========================================================================
# §15 — expected-path deletion safety outranks process failure
# ===========================================================================


def test_expected_path_deletion_outranks_process_failure(tmp_path: Path) -> None:
    contract_payload = _contract_payload(
        tests=[{"path": "tests/test_a.py", "expectation": "red", "acceptance_criteria": ["AC-1"]}]
    )
    runtime, worktree_path = _setup(
        tmp_path,
        contract_payload=contract_payload,
        planner_actions=[{"kind": "delete", "path": "tests/test_a.py"}],
        planner_returncode=1,
        extra_worktree_files={"tests/test_a.py": "pre-existing\n"},
    )

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "delet" in exc_info.value.reason
