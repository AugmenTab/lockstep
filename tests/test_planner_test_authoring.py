"""Planner Test Authoring Bridge (Sub-phase 8.7).

Bridges the frozen active :class:`~lockstep.domain.SubphaseContract` into
actual Planner-authored executable test files:

    frozen Master Plan
        +
    published current PhasePlan
        +
    frozen active SubphaseContract
        +
    explicit isolated clean Git worktree
        ↓
    configured normal writable Planner adapter (``runtime.adapters.planner``)
        ↓
    Planner authors exactly the Contract's TestSpecification.path files
        ↓
    deterministic Git/filesystem scope verification
        ↓
    test-file integrity hashes
        ↓
    PlannerTestAuthoringResult

Core invariant under test: the Planner may write the Contract's exact
test files and nothing else — no production code, no planning
artifacts, no Git history, no Git index. Every fact about what actually
changed is established through the public, read-only
:func:`lockstep.git.inspect_repository` surface (the Sub-phase 8.7
prerequisite); ``test_authoring.py`` itself performs no Git mutation and
no raw Git subprocess invocation.

Uses real production ``ClaudeAdapter``/``CodexAdapter`` instances, real
production agent invocation (``lockstep.agents.invoke_agent``), real
production planning store, real domain models, real ``AgentRuntime``,
and real temporary Git repositories against fake provider executables
under ``tmp_path``. No real Claude/Codex account, no network, no real
model inference. Git repositories are created directly with the system
``git`` executable in test fixture setup only; production
``test_authoring.py`` uses exclusively the public ``lockstep.git``
inspection layer.
"""

from __future__ import annotations

import ast
import base64
import hashlib
import inspect
import json
import stat
import subprocess
import sys
import textwrap
from collections.abc import Mapping, Sequence
from dataclasses import FrozenInstanceError, fields
from pathlib import Path

import pytest

import lockstep.test_authoring as test_authoring_module
from lockstep.agents import (
    AgentAdapter,
    AgentProviderDiagnostics,
    AgentProviderStatuses,
    ClaudeAdapter,
    ClaudeCliStatus,
    CodexAdapter,
    CodexCliStatus,
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
from lockstep.git import GitCommandError, inspect_repository
from lockstep.planning_store import (
    PlanningStoreError,
    freeze_master_plan,
    freeze_subphase_contract,
    publish_phase_plan,
)
from lockstep.process import EnvironmentPolicyError, ProcessLaunchError, ProcessTimeoutError
from lockstep.runtime import AgentRuntime
from lockstep.test_authoring import (
    AuthoredTestFile,
    PlannerTestAuthoringResult,
    TestAuthoringError,
    author_planner_tests,
)

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


def _init_worktree_with_committed_symlink(
    tmp_path: Path,
    *,
    name: str,
    link_path: str,
    link_target: Path,
) -> Path:
    """Build a worktree whose *initial commit* already contains a symlink.

    Unlike :func:`_init_worktree`, the dangerous symlink is created and
    staged before the one and only commit, so the resulting worktree is
    genuinely clean (no staged/unstaged/untracked paths) while still
    containing the symlink — required to exercise a symlink-specific
    rejection path without the earlier clean-baseline check firing first.
    """
    repo = tmp_path / name
    repo.mkdir()

    _git(repo, "init")
    _git(repo, "config", "user.name", "Lockstep Tests")
    _git(repo, "config", "user.email", "lockstep-tests@example.invalid")

    (repo / "README.md").write_text("initial\n", encoding="utf-8")

    link = repo / link_path
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(link_target)

    _git(repo, "add", "README.md", link_path)
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
    stdout: str = "",
    stderr: str = "",
    returncode: int = 0,
    sleep_seconds: float = 0.0,
) -> Path:
    """Write a fake Planner CLI that logs its invocation and acts in its cwd.

    *actions* is a list of small declarative operations (``write``,
    ``delete``, ``symlink``, ``git``) applied relative to the process's
    current working directory — i.e. the authoring worktree, since the
    orchestrator launches the child with ``cwd=worktree_path``.
    """
    bin_dir.mkdir(parents=True, exist_ok=True)
    executable = bin_dir / name
    config_path = bin_dir / f"{name}-response.json"
    config_path.write_text(
        json.dumps(
            {
                "actions": actions if actions is not None else [],
                "stdout": stdout,
                "stderr": stderr,
                "returncode": returncode,
                "sleep_seconds": sleep_seconds,
            }
        ),
        encoding="utf-8",
    )

    script = textwrap.dedent(
        f"""\
        #!{sys.executable}
        import base64
        import json
        import subprocess
        import sys
        import time
        from pathlib import Path

        base = Path(__file__).resolve().parent
        config = json.loads((base / "{name}-response.json").read_text(encoding="utf-8"))
        args = sys.argv[1:]
        stdin_text = sys.stdin.read()

        with (base / "invocations.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({{"exe": "{name}", "argv": args, "stdin": stdin_text}}) + "\\n")

        if config["sleep_seconds"]:
            time.sleep(config["sleep_seconds"])

        cwd = Path.cwd()
        for action in config["actions"]:
            kind = action["kind"]
            if kind == "write":
                target = cwd / action["path"]
                target.parent.mkdir(parents=True, exist_ok=True)
                if action.get("encoding") == "base64":
                    target.write_bytes(base64.b64decode(action["content"]))
                else:
                    target.write_text(action["content"], encoding="utf-8")
            elif kind == "delete":
                (cwd / action["path"]).unlink()
            elif kind == "symlink":
                (cwd / action["path"]).symlink_to(action["target"])
            elif kind == "git":
                subprocess.run(["git", *action["args"]], cwd=cwd, check=True)

        sys.stdout.write(config["stdout"])
        sys.stderr.write(config["stderr"])
        raise SystemExit(int(config["returncode"]))
        """
    )
    executable.write_text(script, encoding="utf-8")
    mode = executable.stat().st_mode
    executable.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


_BILLING_MODE = BillingMode.SUBSCRIPTION_ONLY


def _read_invocations(bin_dir: Path) -> list[dict[str, object]]:
    log_path = bin_dir / "invocations.jsonl"
    if not log_path.exists():
        return []
    return [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines() if line]


def _default_write_actions(paths: Sequence[str]) -> list[dict[str, object]]:
    return [
        {"kind": "write", "path": path, "content": f"# authored content for {path}\n"}
        for path in paths
    ]


# ---------------------------------------------------------------------------
# CLI status / adapter fixtures (mirrors 8.3-8.6)
# ---------------------------------------------------------------------------


def _healthy_claude_status(*, executable: str = "/fake/claude") -> ClaudeCliStatus:
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


def _healthy_codex_status(*, executable: str = "/fake/codex") -> CodexCliStatus:
    return CodexCliStatus(
        executable=executable,
        version="codex-cli test-version",
        doctor_schema_version=1,
        doctor_overall_status="ok",
        doctor_returncode=0,
        auth_check_status="ok",
        stored_auth_mode="chatgpt",
        stored_chatgpt_tokens=True,
        stored_api_key=False,
        supports_exec_ephemeral=True,
        supports_exec_ignore_user_config=True,
        supports_exec_sandbox=True,
        supports_exec_color=True,
        supports_exec_ignore_rules=True,
        supports_exec_output_schema=True,
    )


def _claude_role_adapter(
    role: AgentRole,
    *,
    executable: str,
    model: str = "claude-model",
    effort: str = "high",
) -> ClaudeAdapter:
    return ClaudeAdapter(
        role=role,
        status=_healthy_claude_status(executable=executable),
        model=model,
        effort=effort,
    )


def _codex_role_adapter(
    role: AgentRole,
    *,
    executable: str,
    model: str = "codex-model",
    reasoning_effort: str = "high",
) -> CodexAdapter:
    return CodexAdapter(
        role=role,
        status=_healthy_codex_status(executable=executable),
        model=model,
        reasoning_effort=reasoning_effort,
    )


def _write_planner_adapter(
    bin_dir: Path,
    *,
    provider: str,
    actions: list[dict[str, object]] | None = None,
    stdout: str = "",
    stderr: str = "",
    returncode: int = 0,
    sleep_seconds: float = 0.0,
) -> AgentAdapter:
    name = "claude" if provider == "claude" else "codex"
    executable = _write_fake_planner_executable(
        bin_dir,
        name=name,
        actions=actions,
        stdout=stdout,
        stderr=stderr,
        returncode=returncode,
        sleep_seconds=sleep_seconds,
    )
    if provider == "claude":
        return _claude_role_adapter(AgentRole.PLANNER, executable=str(executable))
    return _codex_role_adapter(AgentRole.PLANNER, executable=str(executable))


# ---------------------------------------------------------------------------
# AgentRuntime construction helper (mirrors 8.3-8.6)
# ---------------------------------------------------------------------------


def _runtime(
    tmp_path: Path,
    *,
    planner_adapter: AgentAdapter,
    implementer_adapter: AgentAdapter | None = None,
    reviewer_adapter: AgentAdapter | None = None,
    parent_env: Mapping[str, str] | None = None,
) -> AgentRuntime:
    project_root = tmp_path / "project"
    project_root.mkdir(exist_ok=True)
    runtime_dir = tmp_path / "runtime"
    runtime_dir.mkdir(exist_ok=True)

    planner_route = AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model="unused-model",
        effort="unused-effort",
        billing_mode=_BILLING_MODE,
    )
    other_route = AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model="unused-model",
        effort="unused-effort",
        billing_mode=_BILLING_MODE,
    )
    policy = AgentRoutingPolicy(
        planner=planner_route, implementer=other_route, reviewer=other_route
    )
    config = ProjectConfig(schema_version=1, routing=policy)

    diagnostics = AgentProviderDiagnostics(statuses=AgentProviderStatuses())
    adapters = ResolvedAgentAdapters(
        planner=planner_adapter,
        implementer=implementer_adapter if implementer_adapter is not None else planner_adapter,
        reviewer=reviewer_adapter if reviewer_adapter is not None else planner_adapter,
    )

    env: Mapping[str, str]
    if parent_env is not None:
        env = parent_env
    else:
        home_dir = tmp_path / "home"
        home_dir.mkdir(exist_ok=True)
        env = {"HOME": str(home_dir), "PATH": "/usr/bin"}

    return AgentRuntime(
        project_root=project_root,
        runtime_dir=runtime_dir,
        config=config,
        diagnostics=diagnostics,
        adapters=adapters,
        transaction_parent_env=env,
    )


# ---------------------------------------------------------------------------
# Master Plan / Phase plan / Contract payload fixtures (mirrors 8.6)
# ---------------------------------------------------------------------------

_DEFAULT_TEST_PATHS: tuple[str, ...] = ("tests/test_a.py", "tests/test_b.py")


def _phase_id(value: str = "01") -> PhaseId:
    return PhaseId.model_validate(value)


def _subphase_id(value: str = "01") -> SubphaseId:
    return SubphaseId.model_validate(value)


def _outline_payload(
    subphase_id: str = "01", depends_on: tuple[str, ...] = ()
) -> dict[str, object]:
    return {
        "subphase_id": subphase_id,
        "title": "Outline title",
        "objective": "Outline objective.",
        "depends_on": list(depends_on),
    }


def _phase_payload(
    phase_id: str = "01",
    subphases: list[dict[str, object]] | None = None,
    depends_on: tuple[str, ...] = (),
    title: str = "Phase title",
    objective: str = "Phase objective.",
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "phase_id": phase_id,
        "title": title,
        "objective": objective,
        "depends_on": list(depends_on),
        "subphases": subphases if subphases is not None else [_outline_payload()],
        "integration_acceptance_criteria": [],
    }


def _master_plan_payload(
    project_id: str = "lockstep", phases: list[dict[str, object]] | None = None
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "project_id": project_id,
        "title": "Lockstep",
        "objective": "Build the local orchestration control plane.",
        "phases": phases if phases is not None else [_phase_payload()],
    }


def _two_phase_master_plan_payload(project_id: str = "lockstep") -> dict[str, object]:
    phase_01 = _phase_payload("01", subphases=[_outline_payload("01"), _outline_payload("02")])
    phase_02 = _phase_payload("02", subphases=[_outline_payload("01")])
    return _master_plan_payload(project_id, phases=[phase_01, phase_02])


def _freeze_master_plan(project_root: Path, payload: dict[str, object]) -> MasterPlan:
    plan = MasterPlan.model_validate(payload)
    freeze_master_plan(project_root, plan)
    return plan


def _publish_phase_plan(runtime: AgentRuntime, payload: dict[str, object]) -> PhasePlan:
    plan = PhasePlan.model_validate(payload)
    publish_phase_plan(runtime.project_root, runtime.runtime_dir, plan)
    return plan


def _contract_payload(
    phase_id: str = "01",
    subphase_id: str = "01",
    *,
    tests: list[dict[str, object]] | None = None,
    title: str = "Contract title",
    objective: str = "Contract objective.",
) -> dict[str, object]:
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
        "phase_id": phase_id,
        "subphase_id": subphase_id,
        "title": title,
        "objective": objective,
        "acceptance_criteria": [{"criterion_id": "AC-1", "description": "Criterion."}],
        "tests": used_tests,
        "allowed_paths": ["src/example.py"],
        "protected_paths": [],
        "forbidden_paths": [],
        "verification_commands": ["pytest tests/test_a.py tests/test_b.py"],
    }


def _freeze_contract(runtime: AgentRuntime, payload: dict[str, object]) -> SubphaseContract:
    contract = SubphaseContract.model_validate(payload)
    freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, contract)
    return contract


# ---------------------------------------------------------------------------
# Full setup helper — frozen Master Plan + published Phase plan + active
# Contract + isolated clean worktree, wired to a fake Planner.
# ---------------------------------------------------------------------------


def _setup_active_contract_with_worktree(
    tmp_path: Path,
    worktree_path: Path,
    *,
    provider: str = "claude",
    phase_id: str = "01",
    subphase_id: str = "01",
    contract_payload: dict[str, object] | None = None,
    planner_actions: list[dict[str, object]] | None = None,
    planner_returncode: int = 0,
    planner_stdout: str = "",
    planner_max_output_bytes: int | None = None,
    parent_env: Mapping[str, str] | None = None,
) -> tuple[AgentRuntime, Path, Path, SubphaseContract]:
    bin_dir = tmp_path / "bin"
    used_contract_payload = (
        contract_payload
        if contract_payload is not None
        else _contract_payload(phase_id, subphase_id)
    )
    contract = SubphaseContract.model_validate(used_contract_payload)

    used_actions = (
        planner_actions
        if planner_actions is not None
        else _default_write_actions(tuple(test.path for test in contract.tests))
    )

    adapter = _write_planner_adapter(
        bin_dir,
        provider=provider,
        actions=used_actions,
        stdout=planner_stdout,
        returncode=planner_returncode,
    )

    runtime = _runtime(tmp_path, planner_adapter=adapter, parent_env=parent_env)

    _freeze_master_plan(
        runtime.project_root, _master_plan_payload(phases=[_phase_payload(phase_id)])
    )
    _publish_phase_plan(
        runtime, _phase_payload(phase_id, subphases=[_outline_payload(subphase_id)])
    )
    _freeze_contract(runtime, used_contract_payload)

    return runtime, bin_dir, worktree_path, contract


def _setup_active_contract(
    tmp_path: Path,
    *,
    provider: str = "claude",
    phase_id: str = "01",
    subphase_id: str = "01",
    contract_payload: dict[str, object] | None = None,
    planner_actions: list[dict[str, object]] | None = None,
    planner_returncode: int = 0,
    planner_stdout: str = "",
    planner_max_output_bytes: int | None = None,
    parent_env: Mapping[str, str] | None = None,
    extra_worktree_files: Mapping[str, str] | None = None,
    worktree_name: str = "worktree",
) -> tuple[AgentRuntime, Path, Path, SubphaseContract]:
    worktree_path = _init_worktree(tmp_path, name=worktree_name, extra_files=extra_worktree_files)
    return _setup_active_contract_with_worktree(
        tmp_path,
        worktree_path,
        provider=provider,
        phase_id=phase_id,
        subphase_id=subphase_id,
        contract_payload=contract_payload,
        planner_actions=planner_actions,
        planner_returncode=planner_returncode,
        planner_stdout=planner_stdout,
        planner_max_output_bytes=planner_max_output_bytes,
        parent_env=parent_env,
    )


def _author(
    runtime: AgentRuntime,
    worktree_path: Path,
    *,
    phase_id: str = "01",
    subphase_id: str = "01",
    timeout_seconds: float = 5.0,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
) -> PlannerTestAuthoringResult:
    return author_planner_tests(
        runtime,
        worktree_path=worktree_path,
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=termination_grace_seconds,
    )


# ===========================================================================
# Required test — result types (§54)
# ===========================================================================


def test_authored_test_file_shape_and_immutability() -> None:
    instance = AuthoredTestFile(path="tests/test_a.py", sha256="a" * 64)
    assert {f.name for f in fields(instance)} == {"path", "sha256"}

    with pytest.raises(FrozenInstanceError):
        instance.path = "tests/test_b.py"  # type: ignore[misc]

    assert not hasattr(instance, "__dict__")


def test_planner_test_authoring_result_shape_and_privacy(tmp_path: Path) -> None:
    sentinel = "SENTINEL-DO-NOT-LEAK-8f21"
    runtime, _bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path,
        contract_payload=_contract_payload(title=sentinel),
    )

    result = _author(runtime, worktree_path)

    assert isinstance(result, PlannerTestAuthoringResult)
    assert {f.name for f in fields(result)} == {"files", "invocation"}

    with pytest.raises(FrozenInstanceError):
        result.files = result.files  # type: ignore[misc]

    assert not hasattr(result, "__dict__")

    rendered = repr(result)
    assert sentinel not in rendered
    for authored in result.files:
        assert sentinel not in repr(authored)


def test_test_authoring_error_carries_bounded_reason() -> None:
    error = TestAuthoringError("worktree is not clean")
    assert error.reason == "worktree is not clean"
    assert "worktree is not clean" in str(error)


def test_public_api_exports_expected_names() -> None:
    assert set(test_authoring_module.__all__) == {
        "AuthoredTestFile",
        "PlannerTestAuthoringResult",
        "TestAuthoringError",
        "author_planner_tests",
    }


# ===========================================================================
# Signature shape — no caller-supplied provider/prompt/Contract surface
# ===========================================================================


def test_author_planner_tests_signature_shape() -> None:
    sig = inspect.signature(author_planner_tests)
    params = sig.parameters

    assert next(iter(params)) == "runtime"
    assert params["runtime"].annotation in ("AgentRuntime", AgentRuntime)

    for name in (
        "worktree_path",
        "phase_id",
        "subphase_id",
        "timeout_seconds",
        "max_output_bytes",
        "termination_grace_seconds",
    ):
        assert params[name].kind is inspect.Parameter.KEYWORD_ONLY

    assert params["worktree_path"].default is inspect.Parameter.empty
    assert params["phase_id"].default is inspect.Parameter.empty
    assert params["subphase_id"].default is inspect.Parameter.empty
    assert params["timeout_seconds"].default is inspect.Parameter.empty
    assert params["max_output_bytes"].default == 1_048_576
    assert params["termination_grace_seconds"].default == 0.25

    for forbidden in (
        "master_plan",
        "phase_plan",
        "subphase_outline",
        "contract",
        "provider",
        "model",
        "effort",
        "billing_mode",
        "cwd",
        "schema",
        "prompt",
        "environment",
        "test_paths",
        "adapter",
    ):
        assert forbidden not in params


# ===========================================================================
# Required test — worktree path structural preconditions (§62, §63)
# ===========================================================================


def test_canonical_source_checkout_rejected_before_inference(tmp_path: Path) -> None:
    runtime, bin_dir, _worktree_path, _contract = _setup_active_contract(tmp_path)

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, runtime.project_root)

    assert "checkout" in exc_info.value.reason or "project" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


@pytest.mark.parametrize(
    "overlap",
    ["worktree_equals_runtime_dir", "worktree_beneath_runtime_dir", "runtime_dir_beneath_worktree"],
)
def test_runtime_worktree_overlap_rejected_before_inference(tmp_path: Path, overlap: str) -> None:
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(tmp_path)

    if overlap == "worktree_equals_runtime_dir":
        candidate = runtime.runtime_dir
    elif overlap == "worktree_beneath_runtime_dir":
        candidate = runtime.runtime_dir / "nested"
        candidate.mkdir(parents=True, exist_ok=True)
    else:
        candidate = worktree_path
        # Make runtime_dir sit beneath the worktree instead.
        nested_runtime = worktree_path / "nested-runtime"
        nested_runtime.mkdir(parents=True, exist_ok=True)
        object.__setattr__(runtime, "runtime_dir", nested_runtime)

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, candidate)

    assert "runtime" in exc_info.value.reason or "overlap" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Required test — Git worktree precondition (§16, §83)
# ===========================================================================


def test_non_git_worktree_path_raises_git_command_error(tmp_path: Path) -> None:
    runtime, bin_dir, _worktree_path, _contract = _setup_active_contract(tmp_path)

    not_a_repo = tmp_path / "not-a-repo"
    not_a_repo.mkdir()

    with pytest.raises(GitCommandError):
        _author(runtime, not_a_repo)

    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Required test — dirty worktree rejected before inference (§61)
# ===========================================================================


def test_unstaged_modification_rejects_before_inference(tmp_path: Path) -> None:
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(tmp_path)
    (worktree_path / "README.md").write_text("dirty\n", encoding="utf-8")

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "clean" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


def test_staged_modification_rejects_before_inference(tmp_path: Path) -> None:
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(tmp_path)
    (worktree_path / "README.md").write_text("dirty\n", encoding="utf-8")
    _git(worktree_path, "add", "README.md")

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "clean" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


def test_untracked_file_rejects_before_inference(tmp_path: Path) -> None:
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(tmp_path)
    (worktree_path / "stray.txt").write_text("stray\n", encoding="utf-8")

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "clean" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


def test_deleted_tracked_file_rejects_before_inference(tmp_path: Path) -> None:
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(tmp_path)
    (worktree_path / "README.md").unlink()

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "clean" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Required test — planning-state preflight (§55, §56, §57)
# ===========================================================================


def test_no_frozen_master_plan_raises_before_inference(tmp_path: Path) -> None:
    worktree_path = _init_worktree(tmp_path)
    bin_dir = tmp_path / "bin"
    adapter = _write_planner_adapter(bin_dir, provider="claude", actions=[])
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "master plan" in exc_info.value.reason or "frozen" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


def test_no_published_phase_plan_raises_before_inference(tmp_path: Path) -> None:
    worktree_path = _init_worktree(tmp_path)
    bin_dir = tmp_path / "bin"
    adapter = _write_planner_adapter(bin_dir, provider="claude", actions=[])
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "phase plan" in exc_info.value.reason or "published" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


def test_no_active_contract_raises_before_inference(tmp_path: Path) -> None:
    worktree_path = _init_worktree(tmp_path)
    bin_dir = tmp_path / "bin"
    adapter = _write_planner_adapter(bin_dir, provider="claude", actions=[])
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())
    _publish_phase_plan(runtime, _phase_payload())

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "contract" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Required test — explicit identity mismatch (§58)
# ===========================================================================


def test_requested_phase_mismatches_published_phase_raises_before_inference(
    tmp_path: Path,
) -> None:
    worktree_path = _init_worktree(tmp_path)
    bin_dir = tmp_path / "bin"
    adapter = _write_planner_adapter(bin_dir, provider="claude", actions=[])
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _two_phase_master_plan_payload())
    _publish_phase_plan(runtime, _phase_payload("01", subphases=[_outline_payload("01")]))
    _freeze_contract(runtime, _contract_payload("01", "01"))

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path, phase_id="02", subphase_id="01")

    assert "phase" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


def test_requested_subphase_mismatches_active_contract_raises_before_inference(
    tmp_path: Path,
) -> None:
    worktree_path = _init_worktree(tmp_path)
    bin_dir = tmp_path / "bin"
    adapter = _write_planner_adapter(bin_dir, provider="claude", actions=[])
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(
        runtime.project_root,
        _master_plan_payload(
            phases=[
                _phase_payload("01", subphases=[_outline_payload("01"), _outline_payload("02")])
            ]
        ),
    )
    _publish_phase_plan(
        runtime,
        _phase_payload("01", subphases=[_outline_payload("01"), _outline_payload("02")]),
    )
    _freeze_contract(runtime, _contract_payload("01", "01"))

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path, phase_id="01", subphase_id="02")

    assert "subphase" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Required test — unsafe TestSpecification paths (§59)
# ===========================================================================


_UNSAFE_PATHS = (
    "/tests/test_x.py",
    "../tests/test_x.py",
    "tests/../test_x.py",
    "tests//test_x.py",
    "tests\\test_x.py",
    ".git/test_x.py",
    ".lockstep/test_x.py",
    "tests/*.py",
    "tests/test_[x].py",
    "tests/test_x.py\x00",
)


@pytest.mark.parametrize("unsafe_path", _UNSAFE_PATHS)
def test_unsafe_test_specification_path_rejected_before_inference(
    tmp_path: Path, unsafe_path: str
) -> None:
    contract_payload = _contract_payload(
        tests=[{"path": unsafe_path, "expectation": "red", "acceptance_criteria": ["AC-1"]}]
    )
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path, contract_payload=contract_payload, planner_actions=[]
    )

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "path" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


def test_safe_nested_test_specification_path_is_accepted(tmp_path: Path) -> None:
    contract_payload = _contract_payload(
        tests=[
            {
                "path": "tests/feature/test_x.py",
                "expectation": "red",
                "acceptance_criteria": ["AC-1"],
            }
        ]
    )
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path,
        contract_payload=contract_payload,
        planner_actions=_default_write_actions(["tests/feature/test_x.py"]),
    )

    result = _author(runtime, worktree_path)

    assert result.files[0].path == "tests/feature/test_x.py"
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Required test — symlink path component rejected (§60)
# ===========================================================================


def test_symlink_path_component_rejected_before_inference(tmp_path: Path) -> None:
    contract_payload = _contract_payload(
        tests=[{"path": "tests/test_x.py", "expectation": "red", "acceptance_criteria": ["AC-1"]}]
    )

    outside_dir = tmp_path / "outside-directory"
    outside_dir.mkdir()

    try:
        worktree_path = _init_worktree_with_committed_symlink(
            tmp_path, name="worktree", link_path="tests", link_target=outside_dir
        )
    except OSError:
        pytest.skip("host cannot create symlinks")

    runtime, bin_dir, worktree_path, _contract = _setup_active_contract_with_worktree(
        tmp_path, worktree_path, contract_payload=contract_payload, planner_actions=[]
    )

    snapshot = inspect_repository(worktree_path)
    assert snapshot.staged_paths == ()
    assert snapshot.unstaged_paths == ()
    assert snapshot.untracked_paths == ()
    assert snapshot.dirty_paths == ()

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "symlink" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


def test_existing_symlink_expected_file_rejected_before_inference(tmp_path: Path) -> None:
    contract_payload = _contract_payload(
        tests=[{"path": "tests/test_x.py", "expectation": "red", "acceptance_criteria": ["AC-1"]}]
    )

    outside_file = tmp_path / "outside-file.py"
    outside_file.write_text("outside\n", encoding="utf-8")

    try:
        worktree_path = _init_worktree_with_committed_symlink(
            tmp_path, name="worktree", link_path="tests/test_x.py", link_target=outside_file
        )
    except OSError:
        pytest.skip("host cannot create symlinks")

    runtime, bin_dir, worktree_path, _contract = _setup_active_contract_with_worktree(
        tmp_path, worktree_path, contract_payload=contract_payload, planner_actions=[]
    )

    snapshot = inspect_repository(worktree_path)
    assert snapshot.staged_paths == ()
    assert snapshot.unstaged_paths == ()
    assert snapshot.untracked_paths == ()
    assert snapshot.dirty_paths == ()

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "symlink" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Deterministic authoring prompt (§64)
# ===========================================================================


def test_prompt_is_byte_identical_across_two_independent_clean_worktrees(
    tmp_path: Path,
) -> None:
    bin_dir = tmp_path / "bin"
    contract_payload = _contract_payload()
    contract = SubphaseContract.model_validate(contract_payload)
    actions = _default_write_actions(tuple(t.path for t in contract.tests))
    adapter = _write_planner_adapter(bin_dir, provider="claude", actions=actions)
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())
    _publish_phase_plan(runtime, _phase_payload())
    _freeze_contract(runtime, contract_payload)

    worktree_one = _init_worktree(tmp_path, name="worktree-one")
    worktree_two = _init_worktree(tmp_path, name="worktree-two")

    _author(runtime, worktree_one)
    _set_fake_planner_actions(bin_dir, name="claude", actions=actions)
    _author(runtime, worktree_two)

    invocations = _read_invocations(bin_dir)
    assert len(invocations) == 2
    assert invocations[0]["stdin"] == invocations[1]["stdin"]


def _set_fake_planner_actions(
    bin_dir: Path, *, name: str, actions: list[dict[str, object]]
) -> None:
    config_path = bin_dir / f"{name}-response.json"
    config_path.write_text(
        json.dumps(
            {"actions": actions, "stdout": "", "stderr": "", "returncode": 0, "sleep_seconds": 0.0}
        ),
        encoding="utf-8",
    )


def test_prompt_contains_no_host_or_provider_identity(tmp_path: Path) -> None:
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(tmp_path)
    _author(runtime, worktree_path)

    prompt = _read_invocations(bin_dir)[0]["stdin"]
    assert isinstance(prompt, str)
    assert "claude" not in prompt.lower()
    assert "codex" not in prompt.lower()
    assert "claude-model" not in prompt
    assert "codex-model" not in prompt
    assert str(runtime.project_root) not in prompt
    assert str(runtime.runtime_dir) not in prompt
    assert str(worktree_path) not in prompt


def test_prompt_contains_exact_writable_test_paths_and_contract(tmp_path: Path) -> None:
    runtime, bin_dir, worktree_path, contract = _setup_active_contract(tmp_path)
    _author(runtime, worktree_path)

    prompt = _read_invocations(bin_dir)[0]["stdin"]
    assert isinstance(prompt, str)
    for path in _DEFAULT_TEST_PATHS:
        assert path in prompt
    assert (
        json.dumps(contract.model_dump(mode="json"), ensure_ascii=False, separators=(",", ":"))
        in prompt
    )


def test_prompt_contains_required_authoring_instructions(tmp_path: Path) -> None:
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(tmp_path)
    _author(runtime, worktree_path)

    prompt = _read_invocations(bin_dir)[0]["stdin"]
    assert isinstance(prompt, str)
    assert "Do not modify production code" in prompt
    assert "Do not modify planning artifacts" in prompt
    assert "Do not alter the Contract" in prompt
    assert "Do not stage, commit, reset, checkout, rebase, merge" in prompt
    assert "Do not implement the production behavior" in prompt
    assert "red" in prompt
    assert "green_regression" in prompt
    assert "green_characterization" in prompt
    assert "traceable" in prompt


# ===========================================================================
# Claude / Codex successful authorship (§65, §66)
# ===========================================================================


def test_claude_successful_authorship(tmp_path: Path) -> None:
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(tmp_path, provider="claude")

    result = _author(runtime, worktree_path)

    assert result.invocation.adapter_name == "claude"
    assert result.invocation.role is AgentRole.PLANNER
    assert {f.path for f in result.files} == set(_DEFAULT_TEST_PATHS)
    for authored in result.files:
        target = worktree_path / authored.path
        assert target.is_file()
        assert authored.sha256 == hashlib.sha256(target.read_bytes()).hexdigest()
    assert len(_read_invocations(bin_dir)) == 1


def test_codex_successful_authorship(tmp_path: Path) -> None:
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(tmp_path, provider="codex")

    result = _author(runtime, worktree_path)

    assert result.invocation.adapter_name == "codex"
    assert result.invocation.role is AgentRole.PLANNER
    assert {f.path for f in result.files} == set(_DEFAULT_TEST_PATHS)
    assert len(_read_invocations(bin_dir)) == 1


def test_claude_normal_writable_planner_authority_retained(tmp_path: Path) -> None:
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(tmp_path, provider="claude")
    _author(runtime, worktree_path)

    argv = _read_invocations(bin_dir)[0]["argv"]
    assert isinstance(argv, list)
    tools_index = argv.index("--tools")
    assert argv[tools_index + 1] == "Read,Write,Edit,Glob,Grep"
    allowed_index = argv.index("--allowedTools")
    assert argv[allowed_index + 1] == "Read,Write,Edit,Glob,Grep"
    assert "--json-schema" not in argv
    assert "--safe-mode" in argv
    assert "--restricted" in argv


def test_codex_workspace_write_planner_authority_retained(tmp_path: Path) -> None:
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(tmp_path, provider="codex")
    _author(runtime, worktree_path)

    argv = _read_invocations(bin_dir)[0]["argv"]
    assert isinstance(argv, list)
    sandbox_index = argv.index("--sandbox")
    assert argv[sandbox_index + 1] == "workspace-write"
    assert "--output-schema" not in argv


def test_no_structured_output_schema_artifact_created(tmp_path: Path) -> None:
    runtime, _bin_dir, worktree_path, _contract = _setup_active_contract(tmp_path, provider="codex")
    _author(runtime, worktree_path)

    assert not (runtime.runtime_dir / "providers").exists()


# ===========================================================================
# Required test — exact path set / Contract order retained (§68, §78)
# ===========================================================================


def test_exact_path_set_and_contract_order_retained_over_git_alphabetical_order(
    tmp_path: Path,
) -> None:
    contract_payload = _contract_payload(
        tests=[
            {"path": "tests/test_b.py", "expectation": "red", "acceptance_criteria": ["AC-1"]},
            {"path": "tests/test_a.py", "expectation": "red", "acceptance_criteria": ["AC-1"]},
            {"path": "tests/test_c.py", "expectation": "red", "acceptance_criteria": ["AC-1"]},
        ]
    )
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path,
        contract_payload=contract_payload,
        planner_actions=_default_write_actions(
            ["tests/test_b.py", "tests/test_a.py", "tests/test_c.py"]
        ),
    )

    result = _author(runtime, worktree_path)

    assert [f.path for f in result.files] == [
        "tests/test_b.py",
        "tests/test_a.py",
        "tests/test_c.py",
    ]
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Required test — unexpected production mutation (§69)
# ===========================================================================


def test_unexpected_production_mutation_rejected_and_left_intact(tmp_path: Path) -> None:
    actions = [
        *_default_write_actions(list(_DEFAULT_TEST_PATHS)),
        {"kind": "write", "path": "src/lockstep/feature.py", "content": "unauthorized\n"},
    ]
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path, planner_actions=actions
    )

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "outside" in exc_info.value.reason or "unexpected" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1
    assert (worktree_path / "src" / "lockstep" / "feature.py").exists()
    for path in _DEFAULT_TEST_PATHS:
        assert (worktree_path / path).exists()


# ===========================================================================
# Required test — missing expected path (§70)
# ===========================================================================


def test_missing_expected_path_rejected(tmp_path: Path) -> None:
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path,
        planner_actions=_default_write_actions(["tests/test_a.py"]),
    )

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "not changed" in exc_info.value.reason or "missing" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Required test — expected path deletion (§71)
# ===========================================================================


def test_expected_path_deletion_rejected(tmp_path: Path) -> None:
    contract_payload = _contract_payload(
        tests=[{"path": "tests/test_a.py", "expectation": "red", "acceptance_criteria": ["AC-1"]}]
    )
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path,
        contract_payload=contract_payload,
        planner_actions=[{"kind": "delete", "path": "tests/test_a.py"}],
        extra_worktree_files={"tests/test_a.py": "pre-existing\n"},
    )

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "delet" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Required test — critical staged-new-file witness (§5 update2, §72)
# ===========================================================================


def test_staged_new_file_rejected_as_index_mutation(tmp_path: Path) -> None:
    contract_payload = _contract_payload(
        tests=[{"path": "tests/test_a.py", "expectation": "red", "acceptance_criteria": ["AC-1"]}]
    )
    actions = [
        {"kind": "write", "path": "tests/test_a.py", "content": "content\n"},
        {"kind": "git", "args": ["add", "tests/test_a.py"]},
    ]
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path, contract_payload=contract_payload, planner_actions=actions
    )

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "index" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1
    # The file exists (untracked-then-staged), proving it is observably
    # distinct from a merely untracked authored file, and is rejected
    # specifically as an index mutation rather than accepted as authored.
    assert (worktree_path / "tests" / "test_a.py").exists()


# ===========================================================================
# Required test — staged then modified again (§6 update2)
# ===========================================================================


def test_staged_then_modified_again_still_rejected_as_index_mutation(tmp_path: Path) -> None:
    contract_payload = _contract_payload(
        tests=[{"path": "tests/test_a.py", "expectation": "red", "acceptance_criteria": ["AC-1"]}]
    )
    actions = [
        {"kind": "write", "path": "tests/test_a.py", "content": "version one\n"},
        {"kind": "git", "args": ["add", "tests/test_a.py"]},
        {"kind": "write", "path": "tests/test_a.py", "content": "version two\n"},
    ]
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path, contract_payload=contract_payload, planner_actions=actions
    )

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "index" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Required test — HEAD mutation (§73)
# ===========================================================================


def test_head_mutation_rejected_before_generic_changed_path_interpretation(
    tmp_path: Path,
) -> None:
    actions = [
        *_default_write_actions(list(_DEFAULT_TEST_PATHS)),
        {"kind": "git", "args": ["add", "."]},
        {"kind": "git", "args": ["commit", "-m", "planner committed"]},
    ]
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path, planner_actions=actions
    )

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "history" in exc_info.value.reason or "head" in exc_info.value.reason.lower()
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Required test — process failure ordering (§74, §75)
# ===========================================================================


def test_unauthorized_mutation_outranks_generic_process_failure(tmp_path: Path) -> None:
    actions = [{"kind": "write", "path": "src/lockstep/feature.py", "content": "unauthorized\n"}]
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path, planner_actions=actions, planner_returncode=1
    )

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "outside" in exc_info.value.reason or "unexpected" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1


def test_process_failure_with_only_expected_mutations_reports_process_failure(
    tmp_path: Path,
) -> None:
    actions = _default_write_actions(list(_DEFAULT_TEST_PATHS))
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path, planner_actions=actions, planner_returncode=1
    )

    with pytest.raises(TestAuthoringError) as exc_info:
        _author(runtime, worktree_path)

    assert "process" in exc_info.value.reason or "status" in exc_info.value.reason
    assert "outside" not in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1
    for path in _DEFAULT_TEST_PATHS:
        assert (worktree_path / path).exists()


# ===========================================================================
# Required test — stdout truncation irrelevant (§76)
# ===========================================================================


def test_stdout_truncation_does_not_invalidate_filesystem_success(tmp_path: Path) -> None:
    actions = _default_write_actions(list(_DEFAULT_TEST_PATHS))
    runtime, _bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path, planner_actions=actions, planner_stdout="x" * 4096
    )

    result = _author(runtime, worktree_path, max_output_bytes=64)

    assert result.invocation.process.stdout_truncated is True
    assert {f.path for f in result.files} == set(_DEFAULT_TEST_PATHS)


# ===========================================================================
# Required test — exact-byte hashing (§77)
# ===========================================================================


def test_hashes_exact_bytes_including_non_ascii_and_line_endings(tmp_path: Path) -> None:
    raw_bytes = "café \r\n data \r\n".encode() + b"\x00trailing-newline\n"
    encoded = base64.b64encode(raw_bytes).decode("ascii")
    contract_payload = _contract_payload(
        tests=[{"path": "tests/test_a.py", "expectation": "red", "acceptance_criteria": ["AC-1"]}]
    )
    actions = [
        {"kind": "write", "path": "tests/test_a.py", "content": encoded, "encoding": "base64"}
    ]
    runtime, _bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path, contract_payload=contract_payload, planner_actions=actions
    )

    result = _author(runtime, worktree_path)

    assert result.files[0].sha256 == hashlib.sha256(raw_bytes).hexdigest()
    assert (worktree_path / "tests" / "test_a.py").read_bytes() == raw_bytes


# ===========================================================================
# Required test — prompt private stdin (§79)
# ===========================================================================


def test_prompt_arrives_only_through_private_stdin(tmp_path: Path) -> None:
    sentinel = "SENTINEL-CRITERION-9f13-do-not-leak"
    sentinel_criterion_id = "AC-SENTINEL"
    contract_payload = _contract_payload(
        tests=[
            {
                "path": "tests/test_a.py",
                "expectation": "red",
                "acceptance_criteria": [sentinel_criterion_id],
            }
        ],
    )
    contract_payload["acceptance_criteria"] = [
        {"criterion_id": sentinel_criterion_id, "description": sentinel}
    ]
    runtime, bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path,
        contract_payload=contract_payload,
        planner_actions=_default_write_actions(["tests/test_a.py"]),
    )

    result = _author(runtime, worktree_path)

    invocation = _read_invocations(bin_dir)[0]
    assert sentinel in invocation["stdin"]
    argv = invocation["argv"]
    assert isinstance(argv, list)
    assert not any(sentinel in token for token in argv)
    assert sentinel not in repr(result)
    for authored in result.files:
        assert sentinel not in repr(authored)


# ===========================================================================
# Required test — planning state remains unchanged (§80)
# ===========================================================================


def test_planning_state_unchanged_after_successful_authoring(tmp_path: Path) -> None:
    runtime, _bin_dir, worktree_path, _contract = _setup_active_contract(tmp_path)

    master_plan_json = (
        runtime.project_root / ".lockstep" / "project" / "master-plan.json"
    ).read_bytes()
    master_plan_md = (
        runtime.project_root / ".lockstep" / "project" / "master-plan.md"
    ).read_bytes()
    phase_plan_json = (runtime.runtime_dir / "planning" / "phase-plan.json").read_bytes()
    active_contract_json = (runtime.runtime_dir / "contracts" / "active.json").read_bytes()

    _author(runtime, worktree_path)

    assert (
        runtime.project_root / ".lockstep" / "project" / "master-plan.json"
    ).read_bytes() == master_plan_json
    assert (
        runtime.project_root / ".lockstep" / "project" / "master-plan.md"
    ).read_bytes() == master_plan_md
    assert (runtime.runtime_dir / "planning" / "phase-plan.json").read_bytes() == phase_plan_json
    assert (runtime.runtime_dir / "contracts" / "active.json").read_bytes() == active_contract_json


# ===========================================================================
# Required test — only Planner invoked, no baseline/verification execution
# (§81, §82)
# ===========================================================================


def test_only_planner_invoked_no_implementer_reviewer_or_verification(tmp_path: Path) -> None:
    worktree_path = _init_worktree(tmp_path)
    bin_dir = tmp_path / "bin"
    planner_actions = _default_write_actions(list(_DEFAULT_TEST_PATHS))
    planner_adapter = _write_planner_adapter(bin_dir, provider="claude", actions=planner_actions)

    implementer_bin = tmp_path / "implementer-bin"
    implementer_adapter = _claude_role_adapter(
        AgentRole.IMPLEMENTER,
        executable=str(_write_fake_planner_executable(implementer_bin, name="claude-implementer")),
    )
    reviewer_bin = tmp_path / "reviewer-bin"
    reviewer_adapter = _claude_role_adapter(
        AgentRole.REVIEWER,
        executable=str(_write_fake_planner_executable(reviewer_bin, name="claude-reviewer")),
    )

    runtime = _runtime(
        tmp_path,
        planner_adapter=planner_adapter,
        implementer_adapter=implementer_adapter,
        reviewer_adapter=reviewer_adapter,
    )
    _freeze_master_plan(runtime.project_root, _master_plan_payload())
    _publish_phase_plan(runtime, _phase_payload())
    _freeze_contract(runtime, _contract_payload())

    _author(runtime, worktree_path)

    assert len(_read_invocations(bin_dir)) == 1
    assert _read_invocations(implementer_bin) == []
    assert _read_invocations(reviewer_bin) == []


# ===========================================================================
# Required test — lower-layer transparency (§83)
# ===========================================================================


def test_environment_policy_error_propagates_unwrapped(tmp_path: Path) -> None:
    runtime, _bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path, parent_env={"PATH": "/usr/bin"}
    )

    with pytest.raises(EnvironmentPolicyError):
        _author(runtime, worktree_path)


def test_process_launch_error_propagates_unwrapped(tmp_path: Path) -> None:
    worktree_path = _init_worktree(tmp_path)
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir(parents=True, exist_ok=True)
    adapter = _claude_role_adapter(AgentRole.PLANNER, executable=str(bin_dir / "does-not-exist"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())
    _publish_phase_plan(runtime, _phase_payload())
    _freeze_contract(runtime, _contract_payload())

    with pytest.raises(ProcessLaunchError):
        _author(runtime, worktree_path)


def test_process_timeout_error_propagates_unwrapped(tmp_path: Path) -> None:
    actions = _default_write_actions(list(_DEFAULT_TEST_PATHS))
    runtime, _bin_dir, worktree_path, _contract = _setup_active_contract(
        tmp_path, planner_actions=actions
    )
    # Reconfigure the already-written fake to sleep past a tiny timeout.
    bin_dir = tmp_path / "bin"
    config_path = bin_dir / "claude-response.json"
    config_path.write_text(
        json.dumps(
            {"actions": actions, "stdout": "", "stderr": "", "returncode": 0, "sleep_seconds": 2.0}
        ),
        encoding="utf-8",
    )

    with pytest.raises(ProcessTimeoutError):
        _author(runtime, worktree_path, timeout_seconds=0.05)


def test_planning_store_error_propagates_unwrapped(tmp_path: Path) -> None:
    runtime, _bin_dir, worktree_path, _contract = _setup_active_contract(tmp_path)

    phase_plan_path = runtime.runtime_dir / "planning" / "phase-plan.json"
    phase_plan_path.write_text("not valid json", encoding="utf-8")

    with pytest.raises(PlanningStoreError):
        _author(runtime, worktree_path)


def test_git_inspection_error_propagates_unwrapped_for_invalid_worktree(tmp_path: Path) -> None:
    runtime, _bin_dir, _worktree_path, _contract = _setup_active_contract(tmp_path)

    not_a_repo = tmp_path / "plain-directory"
    not_a_repo.mkdir()

    with pytest.raises(GitCommandError):
        _author(runtime, not_a_repo)


# ===========================================================================
# Required test — no provider branching (§84)
# ===========================================================================


def test_module_source_has_no_provider_literal_or_switch() -> None:
    source = inspect.getsource(test_authoring_module)
    assert "AgentProvider" not in source
    assert '"claude"' not in source
    assert "'claude'" not in source
    assert '"codex"' not in source
    assert "'codex'" not in source
    assert "ClaudeAdapter" not in source
    assert "CodexAdapter" not in source
    assert "ClaudeCliStatus" not in source
    assert "CodexCliStatus" not in source
    assert "to_openai_strict_json_schema" not in source
    assert "prepare_structured_planner_adapter" not in source


# ===========================================================================
# Required test — dependency boundary (§85)
# ===========================================================================

_FORBIDDEN_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.agents.claude",
    "lockstep.agents.codex",
    "lockstep.agents.structured_output",
    "lockstep.planning_transport",
    "lockstep.planning_workflow",
    "lockstep.supervisor",
    "lockstep.state",
    "lockstep.persistence",
    "lockstep.verification",
    "lockstep.reporting",
    "lockstep.cli",
    "subprocess",
    "os",
    "claude",
    "codex",
    "anthropic",
    "openai",
)


def _imported_modules_and_names(tree: ast.Module) -> tuple[set[str], set[str]]:
    imported_names: set[str] = set()
    imported_modules: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imported_names.add(alias.asname or alias.name)
                imported_modules.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            imported_modules.add(module)
            for alias in node.names:
                imported_names.add(alias.asname or alias.name)
    return imported_modules, imported_names


def test_module_has_no_forbidden_imports() -> None:
    tree = ast.parse(inspect.getsource(test_authoring_module))
    imported_modules, _imported_names = _imported_modules_and_names(tree)

    for forbidden_prefix in _FORBIDDEN_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


def test_module_does_not_touch_ambient_environment() -> None:
    tree = ast.parse(inspect.getsource(test_authoring_module))
    attribute_accesses = {node.attr for node in ast.walk(tree) if isinstance(node, ast.Attribute)}
    assert "environ" not in attribute_accesses
    assert "getenv" not in attribute_accesses
    assert "system" not in attribute_accesses
    assert "popen" not in attribute_accesses.union({a.lower() for a in attribute_accesses})


def test_module_imports_only_public_git_inspection_surface() -> None:
    tree = ast.parse(inspect.getsource(test_authoring_module))
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module == "lockstep.git":
            for alias in node.names:
                assert alias.name in {"GitRepositorySnapshot", "inspect_repository"}
        if (
            isinstance(node, ast.ImportFrom)
            and node.module
            and node.module.startswith("lockstep.git.")
        ):
            pytest.fail(f"test_authoring.py must not import lockstep.git internals: {node.module}")
