"""Planner-authored specification of Sub-phase 8.4 Master Plan creation.

Pins the first real AI planning workflow:

    human-approved requirements
        -> prepared AgentRuntime
        -> configured structured Planner (lockstep.planning_transport, 8.3)
        -> typed MasterPlan candidate
        -> explicit project binding
        -> semantic validation (lockstep.planning, 8.1)
        -> MasterPlanCandidate returned for human review

        HUMAN APPROVAL BOUNDARY (external caller action)

        explicit lockstep.planning_store.freeze_master_plan(...) (8.2)

The core invariant under test: successful candidate creation never
approves, freezes, or persists a Master Plan. It returns a validated
proposal; only an explicit, separate ``freeze_master_plan`` call (never
imported by the production module under test) makes a plan canonical.

Uses real production ClaudeAdapter/CodexAdapter instances, real
production planning transport (8.3), real production semantic
validation (8.1), and real production planning store (8.2) against fake
provider executables under ``tmp_path``. No real Claude/Codex account,
no network, no real model inference.
"""

from __future__ import annotations

import ast
import inspect
import json
import stat
import sys
import textwrap
from collections.abc import Mapping
from dataclasses import FrozenInstanceError, fields
from pathlib import Path

import pytest

import lockstep.planning_workflow as planning_workflow_module
from lockstep.agents import (
    AgentAdapter,
    AgentProviderDiagnostics,
    AgentProviderStatuses,
    ClaudeAdapter,
    ClaudeAdapterError,
    ClaudeCliStatus,
    CodexAdapter,
    CodexAdapterError,
    CodexCliStatus,
    ResolvedAgentAdapters,
)
from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.config import ProjectConfig
from lockstep.domain import AgentRole, BillingMode, MasterPlan, ProjectId
from lockstep.planning import PlanningValidationError, validate_master_plan
from lockstep.planning_store import PlanningStoreError, freeze_master_plan, load_frozen_master_plan
from lockstep.planning_transport import (
    PlanningArtifactKind,
    PlanningArtifactResult,
    PlanningTransportError,
    invoke_planner_artifact,
)
from lockstep.planning_workflow import (
    MasterPlanCandidate,
    MasterPlanCreationError,
    create_master_plan_candidate,
)
from lockstep.process import EnvironmentPolicyError, ProcessLaunchError, ProcessTimeoutError
from lockstep.runtime import AgentRuntime

# ---------------------------------------------------------------------------
# Construction helpers — CLI status / adapter fixtures (mirrors 8.3)
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


def _claude_planner(
    *, executable: str = "/fake/claude", model: str = "claude-planner-model", effort: str = "high"
) -> ClaudeAdapter:
    return ClaudeAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_claude_status(executable=executable),
        model=model,
        effort=effort,
    )


def _codex_planner(
    *,
    executable: str = "/fake/codex",
    model: str = "codex-planner-model",
    reasoning_effort: str = "high",
) -> CodexAdapter:
    return CodexAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_codex_status(executable=executable),
        model=model,
        reasoning_effort=reasoning_effort,
    )


# ---------------------------------------------------------------------------
# Fake provider executables
# ---------------------------------------------------------------------------


def _write_fake_provider_executable(
    bin_dir: Path,
    *,
    name: str,
    stdout: str = "",
    stderr: str = "",
    returncode: int = 0,
    sleep_seconds: float = 0.0,
) -> Path:
    """Write a fake provider CLI that logs every invocation and drains stdin.

    The fake ignores its argv/stdin content for response purposes; the
    response is entirely controlled by *stdout*/*stderr*/*returncode*
    baked into a sibling config file at write time.
    """
    bin_dir.mkdir(parents=True, exist_ok=True)
    executable = bin_dir / name
    config_path = bin_dir / f"{name}-response.json"
    config_path.write_text(
        json.dumps(
            {
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
        import json
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

        sys.stdout.write(config["stdout"])
        sys.stderr.write(config["stderr"])
        raise SystemExit(int(config["returncode"]))
        """
    )
    executable.write_text(script, encoding="utf-8")
    mode = executable.stat().st_mode
    executable.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _read_invocations(bin_dir: Path) -> list[dict[str, object]]:
    log_path = bin_dir / "invocations.jsonl"
    if not log_path.exists():
        return []
    return [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines() if line]


def _snapshot_relative_files(root: Path) -> set[str]:
    if not root.exists():
        return set()
    return {str(path.relative_to(root)) for path in root.rglob("*") if path.is_file()}


# ---------------------------------------------------------------------------
# AgentRuntime construction helper (mirrors 8.3)
# ---------------------------------------------------------------------------


def _runtime(
    tmp_path: Path,
    *,
    planner_adapter: AgentAdapter,
    parent_env: Mapping[str, str] | None = None,
    planner_billing_mode: BillingMode = BillingMode.SUBSCRIPTION_ONLY,
) -> AgentRuntime:
    project_root = tmp_path / "project"
    project_root.mkdir(exist_ok=True)
    runtime_dir = tmp_path / "runtime"
    runtime_dir.mkdir(exist_ok=True)

    planner_route = AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model="unused-model",
        effort="unused-effort",
        billing_mode=planner_billing_mode,
    )
    other_route = AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model="unused-model",
        effort="unused-effort",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )
    policy = AgentRoutingPolicy(
        planner=planner_route, implementer=other_route, reviewer=other_route
    )
    config = ProjectConfig(schema_version=1, routing=policy)

    diagnostics = AgentProviderDiagnostics(statuses=AgentProviderStatuses())
    adapters = ResolvedAgentAdapters(
        planner=planner_adapter, implementer=planner_adapter, reviewer=planner_adapter
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
# Master Plan payload fixtures
# ---------------------------------------------------------------------------


def _project_id(value: str = "lockstep") -> ProjectId:
    return ProjectId.model_validate(value)


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
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "phase_id": phase_id,
        "title": "Phase title",
        "objective": "Phase objective.",
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


def _duplicate_phase_master_plan_payload(project_id: str = "lockstep") -> dict[str, object]:
    phase = _phase_payload("01")
    return _master_plan_payload(project_id, phases=[phase, dict(phase)])


def _unknown_phase_dependency_payload(project_id: str = "lockstep") -> dict[str, object]:
    phase = _phase_payload("01", depends_on=("99",))
    return _master_plan_payload(project_id, phases=[phase])


def _future_phase_dependency_payload(project_id: str = "lockstep") -> dict[str, object]:
    phase_01 = _phase_payload("01", depends_on=("02",))
    phase_02 = _phase_payload("02")
    return _master_plan_payload(project_id, phases=[phase_01, phase_02])


def _duplicate_subphase_master_plan_payload(project_id: str = "lockstep") -> dict[str, object]:
    outline = _outline_payload("01")
    phase = _phase_payload("01", subphases=[outline, dict(outline)])
    return _master_plan_payload(project_id, phases=[phase])


def _future_subphase_dependency_payload(project_id: str = "lockstep") -> dict[str, object]:
    outline_01 = _outline_payload("01", depends_on=("02",))
    outline_02 = _outline_payload("02")
    phase = _phase_payload("01", subphases=[outline_01, outline_02])
    return _master_plan_payload(project_id, phases=[phase])


_SEMANTICALLY_INVALID_PAYLOAD_BUILDERS = (
    _duplicate_phase_master_plan_payload,
    _unknown_phase_dependency_payload,
    _future_phase_dependency_payload,
    _duplicate_subphase_master_plan_payload,
    _future_subphase_dependency_payload,
)


# ---------------------------------------------------------------------------
# Prompt parsing helpers (mirror the fixed labels the production prompt
# builder is expected to emit; see Section 13-17 of the 8.4 plan)
# ---------------------------------------------------------------------------

_PROJECT_ID_LABEL = "Project ID:"
_REQUIREMENTS_LABEL = "Human-approved requirements (JSON-encoded string):"


def _extract_project_id_line(prompt: str) -> str:
    lines = prompt.splitlines()
    marker_index = lines.index(_PROJECT_ID_LABEL)
    return lines[marker_index + 1]


def _extract_requirements(prompt: str) -> str:
    lines = prompt.splitlines()
    marker_index = lines.index(_REQUIREMENTS_LABEL)
    encoded_line = lines[marker_index + 1]
    return json.loads(encoded_line)


def _create_candidate_and_capture_stdin(
    tmp_path: Path,
    *,
    provider: str = "claude",
    project_id: str = "lockstep",
    requirements: str = "Build the thing.",
    payload: dict[str, object] | None = None,
) -> tuple[str, AgentRuntime, Path]:
    bin_dir = tmp_path / "bin"
    used_payload = payload if payload is not None else _master_plan_payload(project_id=project_id)
    if provider == "claude":
        _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(used_payload))
        adapter: AgentAdapter = _claude_planner(executable=str(bin_dir / "claude"))
    else:
        _write_fake_provider_executable(bin_dir, name="codex", stdout=json.dumps(used_payload))
        adapter = _codex_planner(executable=str(bin_dir / "codex"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    create_master_plan_candidate(
        runtime,
        project_id=_project_id(project_id),
        requirements=requirements,
        timeout_seconds=5.0,
    )

    stdin = _read_invocations(bin_dir)[0]["stdin"]
    assert isinstance(stdin, str)
    return stdin, runtime, bin_dir


# ===========================================================================
# MasterPlanCandidate shape and privacy
# ===========================================================================


def test_master_plan_candidate_shape_and_privacy(tmp_path: Path) -> None:
    sentinel = "SENTINEL-DO-NOT-LEAK-req-8f2c"
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    candidate = create_master_plan_candidate(
        runtime, project_id=_project_id("lockstep"), requirements=sentinel, timeout_seconds=5.0
    )

    assert isinstance(candidate, MasterPlanCandidate)
    assert {f.name for f in fields(candidate)} == {"plan", "invocation"}

    with pytest.raises(FrozenInstanceError):
        candidate.plan = candidate.plan  # type: ignore[misc]

    assert not hasattr(candidate, "__dict__")

    rendered = repr(candidate)
    assert sentinel not in rendered
    assert "Lockstep" not in rendered


def test_master_plan_creation_error_carries_bounded_reason() -> None:
    error = MasterPlanCreationError("master plan is already frozen")
    assert error.reason == "master plan is already frozen"
    assert "master plan is already frozen" in str(error)


def test_public_api_exports_expected_names() -> None:
    assert set(planning_workflow_module.__all__) == {
        "MasterPlanCandidate",
        "MasterPlanCreationError",
        "create_master_plan_candidate",
    }


def test_no_auto_freeze_api_exists() -> None:
    for forbidden in (
        "approve_and_freeze",
        "generate_and_freeze",
        "auto_freeze",
        "freeze_master_plan",
    ):
        assert not hasattr(planning_workflow_module, forbidden)


# ===========================================================================
# Signature shape — explicit project id, no provider surface
# ===========================================================================


def test_create_master_plan_candidate_signature_shape() -> None:
    sig = inspect.signature(create_master_plan_candidate)
    params = sig.parameters

    assert next(iter(params)) == "runtime"
    assert params["runtime"].annotation in (AgentRuntime, "AgentRuntime")

    for name in (
        "project_id",
        "requirements",
        "timeout_seconds",
        "max_output_bytes",
        "termination_grace_seconds",
    ):
        assert params[name].kind is inspect.Parameter.KEYWORD_ONLY

    assert params["project_id"].default is inspect.Parameter.empty
    assert params["requirements"].default is inspect.Parameter.empty
    assert params["timeout_seconds"].default is inspect.Parameter.empty
    assert params["max_output_bytes"].default == 1_048_576
    assert params["termination_grace_seconds"].default == 0.25

    for forbidden in ("provider", "model", "effort", "billing_mode", "cwd", "schema", "prompt"):
        assert forbidden not in params


# ===========================================================================
# Requirements validation
# ===========================================================================


@pytest.mark.parametrize("requirements", ["", "   ", "\t\n", "bad\x00nul"])
def test_invalid_requirements_raise_before_any_side_effect(
    tmp_path: Path, requirements: str
) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(MasterPlanCreationError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements=requirements,
            timeout_seconds=5.0,
        )

    assert _read_invocations(bin_dir) == []
    assert not (runtime.runtime_dir / "providers").exists()
    assert load_frozen_master_plan(runtime.project_root) is None


def test_requirements_are_preserved_exactly_in_prompt(tmp_path: Path) -> None:
    requirements = (
        '  Build a "widget" factory.\n'
        "\n"
        "It must handle backslashes like C:\\path\\to\\thing and\n"
        "non-ASCII text like caf\u00e9 r\u00e9sum\u00e9 \u65e5\u672c\u8a9e.\n"
        "  \n"
        "Trailing space at document end.  "
    )

    prompt, _runtime, _bin_dir = _create_candidate_and_capture_stdin(
        tmp_path, requirements=requirements
    )

    assert _extract_requirements(prompt) == requirements


# ===========================================================================
# Deterministic prompt construction
# ===========================================================================


def test_prompt_is_byte_identical_across_two_clean_calls_before_freeze(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    create_master_plan_candidate(
        runtime,
        project_id=_project_id("lockstep"),
        requirements="Build the thing.",
        timeout_seconds=5.0,
    )
    create_master_plan_candidate(
        runtime,
        project_id=_project_id("lockstep"),
        requirements="Build the thing.",
        timeout_seconds=5.0,
    )

    invocations = _read_invocations(bin_dir)
    assert len(invocations) == 2
    assert invocations[0]["stdin"] == invocations[1]["stdin"]


def test_prompt_contains_exact_project_id(tmp_path: Path) -> None:
    prompt, _runtime, _bin_dir = _create_candidate_and_capture_stdin(
        tmp_path, project_id="lockstep-app"
    )

    assert _extract_project_id_line(prompt) == "lockstep-app"


@pytest.mark.parametrize("provider", ["claude", "codex"])
def test_prompt_contains_required_planning_instructions(tmp_path: Path, provider: str) -> None:
    prompt, _runtime, _bin_dir = _create_candidate_and_capture_stdin(tmp_path, provider=provider)

    assert "dependency-ordered" in prompt
    assert "Phase" in prompt
    assert "provisional" in prompt
    assert "Sub-phase outline" in prompt
    assert "SubphaseContract" in prompt
    assert "TestSpecification" in prompt
    assert "executable tests" in prompt
    assert "read-only" in prompt
    assert "Return only the structured MasterPlan" in prompt


@pytest.mark.parametrize("provider", ["claude", "codex"])
def test_prompt_does_not_leak_provider_or_host_identity(tmp_path: Path, provider: str) -> None:
    prompt, runtime, _bin_dir = _create_candidate_and_capture_stdin(tmp_path, provider=provider)

    assert "claude" not in prompt.lower()
    assert "codex" not in prompt.lower()
    assert "planner-model" not in prompt
    assert str(runtime.project_root) not in prompt
    assert str(runtime.runtime_dir) not in prompt


# ===========================================================================
# Already-frozen Master Plan check
# ===========================================================================


def test_frozen_master_plan_blocks_regeneration_before_inference(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    frozen_plan = MasterPlan.model_validate(_master_plan_payload())
    freeze_master_plan(runtime.project_root, frozen_plan)

    with pytest.raises(MasterPlanCreationError) as exc_info:
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements="Build the thing.",
            timeout_seconds=5.0,
        )

    assert _read_invocations(bin_dir) == []
    assert "frozen" in exc_info.value.reason


def test_frozen_master_plan_blocks_regeneration_leaving_codex_schema_untouched(
    tmp_path: Path,
) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="codex", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _codex_planner(executable=str(bin_dir / "codex"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    candidate = create_master_plan_candidate(
        runtime,
        project_id=_project_id("lockstep"),
        requirements="Build the thing.",
        timeout_seconds=5.0,
    )
    freeze_master_plan(runtime.project_root, candidate.plan)

    schema_path = (
        runtime.runtime_dir / "providers" / "codex" / "planning" / "master-plan.schema.json"
    )
    schema_bytes_before = schema_path.read_bytes()
    invocation_count_before = len(_read_invocations(bin_dir))

    with pytest.raises(MasterPlanCreationError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements="Build again.",
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == invocation_count_before
    assert schema_path.read_bytes() == schema_bytes_before


def test_corrupted_frozen_store_propagates_planning_store_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    json_path = runtime.project_root / ".lockstep" / "project" / "master-plan.json"
    json_path.parent.mkdir(parents=True)
    json_path.write_text(json.dumps(_master_plan_payload()), encoding="utf-8")
    # Deliberately no accompanying master-plan.md: an inconsistent pair,
    # distinguishable from a valid existing freeze.

    with pytest.raises(PlanningStoreError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements="Build the thing.",
            timeout_seconds=5.0,
        )

    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Exact lower-layer transport call
# ===========================================================================


def test_invoke_planner_artifact_called_exactly_once_with_expected_arguments(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    calls: list[tuple[AgentRuntime, dict[str, object], PlanningArtifactResult]] = []

    def _spy(runtime_arg: AgentRuntime, **kwargs: object) -> PlanningArtifactResult:
        result = invoke_planner_artifact(runtime_arg, **kwargs)  # type: ignore[arg-type]
        calls.append((runtime_arg, kwargs, result))
        return result

    monkeypatch.setattr(planning_workflow_module, "invoke_planner_artifact", _spy)

    candidate = create_master_plan_candidate(
        runtime,
        project_id=_project_id("lockstep"),
        requirements="Build the thing.",
        timeout_seconds=5.0,
        max_output_bytes=2048,
        termination_grace_seconds=0.5,
    )

    assert len(calls) == 1
    runtime_arg, kwargs, result = calls[0]
    assert runtime_arg is runtime
    assert kwargs["kind"] is PlanningArtifactKind.MASTER_PLAN
    assert kwargs["timeout_seconds"] == 5.0
    assert kwargs["max_output_bytes"] == 2048
    assert kwargs["termination_grace_seconds"] == 0.5
    assert isinstance(kwargs["prompt"], str)
    assert candidate.invocation is result.invocation


def test_artifact_kind_drift_fails_closed(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    real_invoke = planning_workflow_module.invoke_planner_artifact

    def _drifted(*args: object, **kwargs: object) -> PlanningArtifactResult:
        result = real_invoke(*args, **kwargs)  # type: ignore[arg-type]
        return PlanningArtifactResult(
            kind=PlanningArtifactKind.PHASE_PLAN,
            artifact=result.artifact,
            invocation=result.invocation,
        )

    monkeypatch.setattr(planning_workflow_module, "invoke_planner_artifact", _drifted)

    with pytest.raises(MasterPlanCreationError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements="Build the thing.",
            timeout_seconds=5.0,
        )


# ===========================================================================
# Project binding, validation ordering, no auto-repair
# ===========================================================================


def test_project_mismatch_raises_and_does_not_rewrite_returned_model(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    payload = _master_plan_payload(project_id="project-b")
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    sentinel = "REQUIREMENTS-SENTINEL-9f2c"

    with pytest.raises(MasterPlanCreationError) as exc_info:
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("project-a"),
            requirements=sentinel,
            timeout_seconds=5.0,
        )

    assert sentinel not in str(exc_info.value)
    assert sentinel not in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1
    assert load_frozen_master_plan(runtime.project_root) is None


def test_project_mismatch_takes_precedence_over_duplicate_phase_id(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    payload = _duplicate_phase_master_plan_payload(project_id="project-b")
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(MasterPlanCreationError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("project-a"),
            requirements="Build the thing.",
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == 1


def test_corrected_project_id_surfaces_semantic_validation_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    payload = _duplicate_phase_master_plan_payload(project_id="project-a")
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlanningValidationError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("project-a"),
            requirements="Build the thing.",
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == 1


@pytest.mark.parametrize("payload_builder", _SEMANTICALLY_INVALID_PAYLOAD_BUILDERS)
def test_semantic_validation_errors_propagate_unwrapped(
    tmp_path: Path, payload_builder: object
) -> None:
    bin_dir = tmp_path / "bin"
    payload = payload_builder(project_id="lockstep")  # type: ignore[operator]
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlanningValidationError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements="Build the thing.",
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == 1
    assert load_frozen_master_plan(runtime.project_root) is None


def test_invalid_candidate_is_passed_unmodified_to_semantic_validation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    bin_dir = tmp_path / "bin"
    payload = _duplicate_phase_master_plan_payload(project_id="lockstep")
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    captured: list[MasterPlan] = []

    def _spy(plan: MasterPlan) -> None:
        captured.append(plan)
        validate_master_plan(plan)

    monkeypatch.setattr(planning_workflow_module, "validate_master_plan", _spy)

    with pytest.raises(PlanningValidationError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements="Build the thing.",
            timeout_seconds=5.0,
        )

    assert len(captured) == 1
    assert captured[0] == MasterPlan.model_validate(payload)


# ===========================================================================
# Claude / Codex candidate creation, provider neutrality, single inference
# ===========================================================================


def test_claude_candidate_creation_succeeds(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    payload = _master_plan_payload()
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    candidate = create_master_plan_candidate(
        runtime,
        project_id=_project_id("lockstep"),
        requirements="Build the thing.",
        timeout_seconds=5.0,
    )

    assert candidate.plan == MasterPlan.model_validate(payload)
    assert candidate.invocation.adapter_name == "claude"
    assert candidate.invocation.role is AgentRole.PLANNER
    assert len(_read_invocations(bin_dir)) == 1
    assert not (runtime.project_root / ".lockstep").exists()


def test_codex_candidate_creation_succeeds(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    payload = _master_plan_payload()
    _write_fake_provider_executable(bin_dir, name="codex", stdout=json.dumps(payload))
    adapter = _codex_planner(executable=str(bin_dir / "codex"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    candidate = create_master_plan_candidate(
        runtime,
        project_id=_project_id("lockstep"),
        requirements="Build the thing.",
        timeout_seconds=5.0,
    )

    assert candidate.plan == MasterPlan.model_validate(payload)
    assert candidate.invocation.adapter_name == "codex"
    assert candidate.invocation.role is AgentRole.PLANNER
    assert len(_read_invocations(bin_dir)) == 1
    assert not (runtime.project_root / ".lockstep").exists()


def test_claude_read_only_authority_retained(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    create_master_plan_candidate(
        runtime,
        project_id=_project_id("lockstep"),
        requirements="Build the thing.",
        timeout_seconds=5.0,
    )

    argv = _read_invocations(bin_dir)[0]["argv"]
    assert isinstance(argv, list)
    tools_index = argv.index("--tools")
    assert argv[tools_index + 1] == "Read,Glob,Grep"
    assert "--safe-mode" in argv
    assert "--restricted" in argv


def test_codex_read_only_authority_retained(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="codex", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _codex_planner(executable=str(bin_dir / "codex"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    create_master_plan_candidate(
        runtime,
        project_id=_project_id("lockstep"),
        requirements="Build the thing.",
        timeout_seconds=5.0,
    )

    argv = _read_invocations(bin_dir)[0]["argv"]
    assert isinstance(argv, list)
    sandbox_index = argv.index("--sandbox")
    assert argv[sandbox_index + 1] == "read-only"


def test_regeneration_before_freeze_is_allowed_and_not_cached(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    candidate_a = create_master_plan_candidate(
        runtime,
        project_id=_project_id("lockstep"),
        requirements="Requirements A.",
        timeout_seconds=5.0,
    )
    candidate_b = create_master_plan_candidate(
        runtime,
        project_id=_project_id("lockstep"),
        requirements="Requirements B.",
        timeout_seconds=5.0,
    )

    assert len(_read_invocations(bin_dir)) == 2
    assert candidate_a.invocation is not candidate_b.invocation
    assert load_frozen_master_plan(runtime.project_root) is None


# ===========================================================================
# No auto-freeze / no persistence
# ===========================================================================


def test_explicit_freeze_boundary_demonstration(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    candidate = create_master_plan_candidate(
        runtime,
        project_id=_project_id("lockstep"),
        requirements="Build the thing.",
        timeout_seconds=5.0,
    )

    assert load_frozen_master_plan(runtime.project_root) is None

    # Simulated explicit human approval action:
    freeze_master_plan(runtime.project_root, candidate.plan)

    assert load_frozen_master_plan(runtime.project_root) == candidate.plan


def test_no_candidate_persistence_claude(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    create_master_plan_candidate(
        runtime,
        project_id=_project_id("lockstep"),
        requirements="Build the thing.",
        timeout_seconds=5.0,
    )

    assert not (runtime.project_root / ".lockstep").exists()
    assert not (runtime.runtime_dir / "planning").exists()
    assert not (runtime.runtime_dir / "contracts").exists()
    assert not (runtime.runtime_dir / "providers").exists()


def test_no_candidate_persistence_codex_only_schema_artifact(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="codex", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _codex_planner(executable=str(bin_dir / "codex"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    create_master_plan_candidate(
        runtime,
        project_id=_project_id("lockstep"),
        requirements="Build the thing.",
        timeout_seconds=5.0,
    )

    assert not (runtime.project_root / ".lockstep").exists()
    assert not (runtime.runtime_dir / "planning").exists()
    assert not (runtime.runtime_dir / "contracts").exists()
    assert _snapshot_relative_files(runtime.runtime_dir) == {
        "providers/codex/planning/master-plan.schema.json"
    }


# ===========================================================================
# Lower-layer exception transparency
# ===========================================================================


def test_planner_nonzero_exit_propagates_planning_transport_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="", returncode=3)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlanningTransportError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements="Build the thing.",
            timeout_seconds=5.0,
        )

    assert load_frozen_master_plan(runtime.project_root) is None


def test_malformed_structured_output_propagates_planning_transport_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="not json at all")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlanningTransportError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements="Build the thing.",
            timeout_seconds=5.0,
        )


def test_truncated_output_propagates_planning_transport_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlanningTransportError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements="Build the thing.",
            timeout_seconds=5.0,
            max_output_bytes=8,
        )


def test_environment_policy_error_propagates_unwrapped(tmp_path: Path) -> None:
    adapter = _claude_planner(executable="/nonexistent/claude")
    runtime = _runtime(tmp_path, planner_adapter=adapter, parent_env={})

    with pytest.raises(EnvironmentPolicyError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements="Build the thing.",
            timeout_seconds=5.0,
        )


def test_process_launch_error_propagates_unwrapped(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist" / "claude"
    adapter = _claude_planner(executable=str(missing))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(ProcessLaunchError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements="Build the thing.",
            timeout_seconds=5.0,
        )


def test_process_timeout_error_propagates_unwrapped(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="irrelevant", sleep_seconds=5.0)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(ProcessTimeoutError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements="Build the thing.",
            timeout_seconds=0.3,
        )


def test_claude_billing_mode_mismatch_propagates_unwrapped(tmp_path: Path) -> None:
    adapter = _claude_planner()
    runtime = _runtime(
        tmp_path, planner_adapter=adapter, planner_billing_mode=BillingMode.API_ALLOWED
    )

    with pytest.raises(ClaudeAdapterError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements="Build the thing.",
            timeout_seconds=5.0,
        )


def test_codex_billing_mode_mismatch_propagates_unwrapped(tmp_path: Path) -> None:
    adapter = _codex_planner()
    runtime = _runtime(
        tmp_path, planner_adapter=adapter, planner_billing_mode=BillingMode.API_ALLOWED
    )

    with pytest.raises(CodexAdapterError):
        create_master_plan_candidate(
            runtime,
            project_id=_project_id("lockstep"),
            requirements="Build the thing.",
            timeout_seconds=5.0,
        )


# ===========================================================================
# Dependency / authority boundary audit
# ===========================================================================

_FORBIDDEN_WORKFLOW_NAMES: tuple[str, ...] = (
    "ClaudeAdapter",
    "CodexAdapter",
    "ClaudeCliStatus",
    "CodexCliStatus",
    "to_openai_strict_json_schema",
    "invoke_agent",
    "run_process",
    "freeze_master_plan",
)

_FORBIDDEN_WORKFLOW_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.agents.claude",
    "lockstep.agents.codex",
    "lockstep.agents.structured_output",
    "claude",
    "codex",
    "anthropic",
    "openai",
    "lockstep.git",
    "lockstep.persistence",
    "lockstep.state",
    "lockstep.supervisor",
    "lockstep.verification",
    "lockstep.reporting",
    "lockstep.cli",
    "subprocess",
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


def test_planning_workflow_module_has_no_forbidden_imports() -> None:
    tree = ast.parse(inspect.getsource(planning_workflow_module))
    imported_modules, imported_names = _imported_modules_and_names(tree)

    for forbidden in _FORBIDDEN_WORKFLOW_NAMES:
        assert forbidden not in imported_names

    for forbidden_prefix in _FORBIDDEN_WORKFLOW_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


def test_planning_workflow_module_does_not_import_freeze_master_plan() -> None:
    tree = ast.parse(inspect.getsource(planning_workflow_module))
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            for alias in node.names:
                assert alias.name != "freeze_master_plan"
        if isinstance(node, ast.Import):
            for alias in node.names:
                assert alias.name != "lockstep.planning_store.freeze_master_plan"


def test_planning_workflow_module_does_not_touch_ambient_environment_or_subprocess() -> None:
    tree = ast.parse(inspect.getsource(planning_workflow_module))
    attribute_accesses = {node.attr for node in ast.walk(tree) if isinstance(node, ast.Attribute)}
    assert "environ" not in attribute_accesses
    assert "getenv" not in attribute_accesses


def test_create_master_plan_candidate_has_no_provider_import_or_switch() -> None:
    source = inspect.getsource(planning_workflow_module)
    assert "AgentProvider" not in source
    assert '"claude"' not in source
    assert "'claude'" not in source
    assert '"codex"' not in source
    assert "'codex'" not in source
