"""Planner-authored specification of Sub-phase 8.5 Phase outline planning.

Pins the second real AI planning workflow: a validated provisional
**PhasePlan candidate** for one explicitly selected Phase of an
already-frozen Master Plan.

    frozen Master Plan (8.2)
        +
    explicit current PhaseId
        +
    current read-only repository state
        +
    optional current provisional Phase outline (8.2)
        ↓
    configured structured Planner (8.3)
        ↓
    typed PhasePlan candidate
        ↓
    phase identity / frozen-fact binding
        ↓
    effective Master Plan semantic validation (8.1)
        ↓
    PhasePlanCandidate returned

        caller/orchestration boundary

    publish_phase_plan(...) (8.2)

The core invariant under test: a Phase outline is durable working
planning state, not human-frozen project law. Generation must not
automatically publish it, and publication does not imply permanent
immutability — a published Phase outline may later be replaced while
there is no active Sub-phase Contract.

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
from pydantic import ValidationError

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
from lockstep.domain import AgentRole, BillingMode, MasterPlan, PhaseId, PhasePlan, SubphaseContract
from lockstep.planning import PlanningValidationError, validate_master_plan
from lockstep.planning_store import (
    PlanningStoreError,
    freeze_master_plan,
    freeze_subphase_contract,
    load_phase_plan,
    publish_phase_plan,
)
from lockstep.planning_transport import (
    PlanningArtifactKind,
    PlanningArtifactResult,
    PlanningTransportError,
    invoke_planner_artifact,
)
from lockstep.planning_workflow import (
    PhaseOutlinePlanningError,
    PhasePlanCandidate,
    create_phase_plan_candidate,
)
from lockstep.process import EnvironmentPolicyError, ProcessLaunchError, ProcessTimeoutError
from lockstep.runtime import AgentRuntime

# ---------------------------------------------------------------------------
# Construction helpers — CLI status / adapter fixtures (mirrors 8.3/8.4)
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


def _set_fake_provider_response(bin_dir: Path, *, name: str, stdout: str) -> None:
    config_path = bin_dir / f"{name}-response.json"
    config_path.write_text(
        json.dumps({"stdout": stdout, "stderr": "", "returncode": 0, "sleep_seconds": 0.0}),
        encoding="utf-8",
    )


def _read_invocations(bin_dir: Path) -> list[dict[str, object]]:
    log_path = bin_dir / "invocations.jsonl"
    if not log_path.exists():
        return []
    return [json.loads(line) for line in log_path.read_text(encoding="utf-8").splitlines() if line]


# ---------------------------------------------------------------------------
# AgentRuntime construction helper (mirrors 8.3/8.4)
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
# Master Plan / Phase plan payload fixtures
# ---------------------------------------------------------------------------


def _phase_id(value: str = "01") -> PhaseId:
    return PhaseId.model_validate(value)


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


def _contract_payload(phase_id: str = "01", subphase_id: str = "01") -> dict[str, object]:
    return {
        "schema_version": 1,
        "phase_id": phase_id,
        "subphase_id": subphase_id,
        "title": "Contract title",
        "objective": "Contract objective.",
        "acceptance_criteria": [{"criterion_id": "AC-1", "description": "Criterion."}],
        "tests": [
            {
                "path": "tests/test_example.py",
                "expectation": "red",
                "acceptance_criteria": ["AC-1"],
            }
        ],
        "allowed_paths": ["src/example.py"],
        "protected_paths": [],
        "forbidden_paths": [],
        "verification_commands": ["pytest tests/test_example.py"],
    }


# ---------------------------------------------------------------------------
# Semantically invalid PhasePlan response payload builders (§55)
# ---------------------------------------------------------------------------


def _duplicate_subphase_response_payload(phase_id: str = "01") -> dict[str, object]:
    outline = _outline_payload("01")
    return _phase_payload(phase_id, subphases=[outline, dict(outline)])


def _unknown_dependency_response_payload(phase_id: str = "01") -> dict[str, object]:
    return _phase_payload(phase_id, subphases=[_outline_payload("01", depends_on=("99",))])


def _self_dependency_response_payload(phase_id: str = "01") -> dict[str, object]:
    return _phase_payload(phase_id, subphases=[_outline_payload("01", depends_on=("01",))])


def _future_dependency_response_payload(phase_id: str = "01") -> dict[str, object]:
    return _phase_payload(
        phase_id,
        subphases=[
            _outline_payload("01", depends_on=("02",)),
            _outline_payload("02"),
        ],
    )


def _duplicate_dependency_reference_response_payload(phase_id: str = "01") -> dict[str, object]:
    return _phase_payload(
        phase_id,
        subphases=[
            _outline_payload("01"),
            _outline_payload("02", depends_on=("01", "01")),
        ],
    )


_SEMANTICALLY_INVALID_RESPONSE_BUILDERS = (
    _duplicate_subphase_response_payload,
    _unknown_dependency_response_payload,
    _self_dependency_response_payload,
    _future_dependency_response_payload,
    _duplicate_dependency_reference_response_payload,
)


# ---------------------------------------------------------------------------
# Prompt parsing helpers (mirror the fixed labels the production prompt
# builder is expected to emit)
# ---------------------------------------------------------------------------

_MASTER_PLAN_LABEL = "Frozen Master Plan:"
_TARGET_PHASE_LABEL = "Target phase_id:"
_CURRENT_OUTLINE_LABEL = "Current provisional outline:"


def _extract_line_after(prompt: str, label: str) -> str:
    lines = prompt.splitlines()
    marker_index = lines.index(label)
    return lines[marker_index + 1]


def _extract_master_plan_json(prompt: str) -> dict[str, object]:
    raw = _extract_line_after(prompt, _MASTER_PLAN_LABEL)
    return json.loads(raw)


def _extract_target_phase(prompt: str) -> str:
    return _extract_line_after(prompt, _TARGET_PHASE_LABEL)


def _extract_current_outline_raw(prompt: str) -> str:
    return _extract_line_after(prompt, _CURRENT_OUTLINE_LABEL)


# ---------------------------------------------------------------------------
# Candidate-creation helper
# ---------------------------------------------------------------------------


def _write_provider_response(
    bin_dir: Path, *, provider: str, response_payload: dict[str, object]
) -> AgentAdapter:
    if provider == "claude":
        _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(response_payload))
        return _claude_planner(executable=str(bin_dir / "claude"))
    _write_fake_provider_executable(bin_dir, name="codex", stdout=json.dumps(response_payload))
    return _codex_planner(executable=str(bin_dir / "codex"))


def _create_candidate_and_capture_stdin(
    tmp_path: Path,
    *,
    provider: str = "claude",
    phase_id: str = "01",
    master_plan_payload: dict[str, object] | None = None,
    response_payload: dict[str, object] | None = None,
) -> tuple[str, AgentRuntime, Path, MasterPlan]:
    bin_dir = tmp_path / "bin"
    used_master_plan_payload = (
        master_plan_payload if master_plan_payload is not None else _master_plan_payload()
    )
    used_response_payload = (
        response_payload if response_payload is not None else _phase_payload(phase_id)
    )
    adapter = _write_provider_response(
        bin_dir, provider=provider, response_payload=used_response_payload
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    master_plan = _freeze_master_plan(runtime.project_root, used_master_plan_payload)

    create_phase_plan_candidate(
        runtime,
        phase_id=_phase_id(phase_id),
        timeout_seconds=5.0,
    )

    stdin = _read_invocations(bin_dir)[0]["stdin"]
    assert isinstance(stdin, str)
    return stdin, runtime, bin_dir, master_plan


# ===========================================================================
# PhasePlanCandidate shape and privacy (§43)
# ===========================================================================


def test_phase_plan_candidate_shape_and_privacy(tmp_path: Path) -> None:
    sentinel_title = "SENTINEL-DO-NOT-LEAK-phase-9f3a"
    master_plan_payload = _master_plan_payload(phases=[_phase_payload("01", title=sentinel_title)])
    response_payload = _phase_payload("01", title=sentinel_title)

    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=response_payload
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, master_plan_payload)

    candidate = create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert isinstance(candidate, PhasePlanCandidate)
    assert {f.name for f in fields(candidate)} == {"plan", "invocation"}

    with pytest.raises(FrozenInstanceError):
        candidate.plan = candidate.plan  # type: ignore[misc]

    assert not hasattr(candidate, "__dict__")

    rendered = repr(candidate)
    assert sentinel_title not in rendered


def test_phase_outline_planning_error_carries_bounded_reason() -> None:
    error = PhaseOutlinePlanningError("master plan is not frozen")
    assert error.reason == "master plan is not frozen"
    assert "master plan is not frozen" in str(error)


def test_public_api_exports_expected_names() -> None:
    assert {
        "PhaseOutlinePlanningError",
        "PhasePlanCandidate",
        "create_phase_plan_candidate",
    }.issubset(set(planning_workflow_module.__all__))


def test_no_auto_publish_api_exists() -> None:
    for forbidden in ("publish_and_return", "auto_publish", "publish_phase_plan"):
        assert not hasattr(planning_workflow_module, forbidden)


# ===========================================================================
# Signature shape — explicit phase id, no provider surface
# ===========================================================================


def test_create_phase_plan_candidate_signature_shape() -> None:
    sig = inspect.signature(create_phase_plan_candidate)
    params = sig.parameters

    assert next(iter(params)) == "runtime"
    assert params["runtime"].annotation in (AgentRuntime, "AgentRuntime")

    for name in (
        "phase_id",
        "timeout_seconds",
        "max_output_bytes",
        "termination_grace_seconds",
    ):
        assert params[name].kind is inspect.Parameter.KEYWORD_ONLY

    assert params["phase_id"].default is inspect.Parameter.empty
    assert params["timeout_seconds"].default is inspect.Parameter.empty
    assert params["max_output_bytes"].default == 1_048_576
    assert params["termination_grace_seconds"].default == 0.25

    for forbidden in (
        "project_id",
        "master_plan",
        "provider",
        "model",
        "effort",
        "billing_mode",
        "cwd",
        "schema",
        "prompt",
        "environment",
    ):
        assert forbidden not in params


# ===========================================================================
# Required test — no frozen Master Plan (§44)
# ===========================================================================


def test_no_frozen_master_plan_raises_before_inference(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PhaseOutlinePlanningError) as exc_info:
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert "frozen" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []
    assert not (runtime.runtime_dir / "providers").exists()


def test_no_frozen_master_plan_leaves_no_runtime_planning_state(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PhaseOutlinePlanningError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert not (runtime.runtime_dir / "planning").exists()


# ===========================================================================
# Required test — unknown Phase (§45)
# ===========================================================================


def test_unknown_phase_raises_before_inference(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(PhaseOutlinePlanningError) as exc_info:
        create_phase_plan_candidate(runtime, phase_id=_phase_id("99"), timeout_seconds=5.0)

    assert "phase" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Required test — explicit Phase identity (§46)
# ===========================================================================


def test_explicit_phase_identity_is_not_first_phase(tmp_path: Path) -> None:
    prompt, _runtime, _bin_dir, _plan = _create_candidate_and_capture_stdin(
        tmp_path,
        phase_id="02",
        master_plan_payload=_two_phase_master_plan_payload(),
        response_payload=_phase_payload("02", subphases=[_outline_payload("01")]),
    )

    assert _extract_target_phase(prompt) == "02"


def test_returned_candidate_targets_requested_non_first_phase(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    response_payload = _phase_payload("02", subphases=[_outline_payload("01")])
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=response_payload
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _two_phase_master_plan_payload())

    candidate = create_phase_plan_candidate(runtime, phase_id=_phase_id("02"), timeout_seconds=5.0)

    assert candidate.plan.phase_id == _phase_id("02")


# ===========================================================================
# Deterministic prompt construction (§47)
# ===========================================================================


def test_prompt_is_byte_identical_across_two_clean_calls(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)
    create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    invocations = _read_invocations(bin_dir)
    assert len(invocations) == 2
    assert invocations[0]["stdin"] == invocations[1]["stdin"]


def test_prompt_contains_exact_master_plan_context(tmp_path: Path) -> None:
    prompt, _runtime, _bin_dir, master_plan = _create_candidate_and_capture_stdin(tmp_path)

    assert _extract_master_plan_json(prompt) == master_plan.model_dump(mode="json")


def test_prompt_contains_required_planning_instructions(tmp_path: Path) -> None:
    prompt, _runtime, _bin_dir, _plan = _create_candidate_and_capture_stdin(tmp_path)

    assert "provisional" in prompt
    assert "revisable" in prompt
    assert "Preserve exactly these frozen Phase-level facts" in prompt
    assert "Only the subphases field is provisional" in prompt
    assert "SubphaseContract" in prompt
    assert "TestSpecification" in prompt
    assert "executable tests" in prompt
    assert "read-only" in prompt
    assert "Do not modify files" in prompt
    assert "Return only the structured PhasePlan" in prompt


@pytest.mark.parametrize("provider", ["claude", "codex"])
def test_prompt_does_not_leak_provider_or_host_identity(tmp_path: Path, provider: str) -> None:
    prompt, runtime, _bin_dir, _plan = _create_candidate_and_capture_stdin(
        tmp_path, provider=provider
    )

    assert "claude" not in prompt.lower()
    assert "codex" not in prompt.lower()
    assert "planner-model" not in prompt
    assert str(runtime.project_root) not in prompt
    assert str(runtime.runtime_dir) not in prompt


# ===========================================================================
# Required test — current-outline inclusion / exclusion (§48, §49, §62)
# ===========================================================================


def test_current_outline_is_included_when_published(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    published_response = _phase_payload("01", subphases=[_outline_payload("01")])
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=published_response
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    candidate_a = create_phase_plan_candidate(
        runtime, phase_id=_phase_id("01"), timeout_seconds=5.0
    )
    publish_phase_plan(runtime.project_root, runtime.runtime_dir, candidate_a.plan)

    create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    second_stdin = _read_invocations(bin_dir)[1]["stdin"]
    assert isinstance(second_stdin, str)
    current_outline = json.loads(_extract_current_outline_raw(second_stdin))
    assert current_outline == candidate_a.plan.model_dump(mode="json")


def test_no_current_outline_encodes_explicit_null(tmp_path: Path) -> None:
    prompt, runtime, _bin_dir, _plan = _create_candidate_and_capture_stdin(tmp_path)

    assert load_phase_plan(runtime.project_root, runtime.runtime_dir) is None
    assert _extract_current_outline_raw(prompt) == "null"


def test_other_phase_runtime_plan_not_treated_as_target_outline(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    published_response = _phase_payload("01", subphases=[_outline_payload("01")])
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=published_response
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _two_phase_master_plan_payload())

    candidate_a = create_phase_plan_candidate(
        runtime, phase_id=_phase_id("01"), timeout_seconds=5.0
    )
    publish_phase_plan(runtime.project_root, runtime.runtime_dir, candidate_a.plan)

    response_payload_b = _phase_payload("02", subphases=[_outline_payload("01")])
    _set_fake_provider_response(bin_dir, name="claude", stdout=json.dumps(response_payload_b))

    candidate_b = create_phase_plan_candidate(
        runtime, phase_id=_phase_id("02"), timeout_seconds=5.0
    )

    invocations = _read_invocations(bin_dir)
    second_stdin = invocations[1]["stdin"]
    assert isinstance(second_stdin, str)
    assert _extract_target_phase(second_stdin) == "02"
    assert _extract_current_outline_raw(second_stdin) == "null"
    assert candidate_b.plan.phase_id == _phase_id("02")


def test_frozen_nested_outline_is_not_conflated_with_runtime_outline(tmp_path: Path) -> None:
    master_plan_payload = _master_plan_payload(
        phases=[_phase_payload("01", subphases=[_outline_payload("01"), _outline_payload("02")])]
    )
    prompt, runtime, _bin_dir, _plan = _create_candidate_and_capture_stdin(
        tmp_path, master_plan_payload=master_plan_payload
    )

    assert load_phase_plan(runtime.project_root, runtime.runtime_dir) is None
    assert _extract_current_outline_raw(prompt) == "null"
    master_plan_in_prompt = _extract_master_plan_json(prompt)
    assert master_plan_in_prompt["phases"][0]["subphases"]


# ===========================================================================
# Exact lower-layer transport call (§66)
# ===========================================================================


def test_invoke_planner_artifact_called_exactly_once_with_expected_arguments(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    calls: list[tuple[AgentRuntime, dict[str, object], PlanningArtifactResult]] = []

    def _spy(runtime_arg: AgentRuntime, **kwargs: object) -> PlanningArtifactResult:
        result = invoke_planner_artifact(runtime_arg, **kwargs)  # type: ignore[arg-type]
        calls.append((runtime_arg, kwargs, result))
        return result

    monkeypatch.setattr(planning_workflow_module, "invoke_planner_artifact", _spy)

    candidate = create_phase_plan_candidate(
        runtime,
        phase_id=_phase_id("01"),
        timeout_seconds=5.0,
        max_output_bytes=2048,
        termination_grace_seconds=0.5,
    )

    assert len(calls) == 1
    runtime_arg, kwargs, result = calls[0]
    assert runtime_arg is runtime
    assert kwargs["kind"] is PlanningArtifactKind.PHASE_PLAN
    assert kwargs["timeout_seconds"] == 5.0
    assert kwargs["max_output_bytes"] == 2048
    assert kwargs["termination_grace_seconds"] == 0.5
    assert isinstance(kwargs["prompt"], str)
    assert candidate.invocation is result.invocation


def test_artifact_kind_drift_fails_closed(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    real_invoke = planning_workflow_module.invoke_planner_artifact

    def _drifted(*args: object, **kwargs: object) -> PlanningArtifactResult:
        result = real_invoke(*args, **kwargs)  # type: ignore[arg-type]
        return PlanningArtifactResult(
            kind=PlanningArtifactKind.MASTER_PLAN,
            artifact=result.artifact,
            invocation=result.invocation,
        )

    monkeypatch.setattr(planning_workflow_module, "invoke_planner_artifact", _drifted)

    with pytest.raises(PhaseOutlinePlanningError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)


# ===========================================================================
# Required test — wrong Phase binding (§52)
# ===========================================================================


def test_wrong_phase_binding_raises_after_one_inference_no_mutation(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    wrong_phase_response = _phase_payload("01")
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=wrong_phase_response
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _two_phase_master_plan_payload())

    with pytest.raises(PhaseOutlinePlanningError) as exc_info:
        create_phase_plan_candidate(runtime, phase_id=_phase_id("02"), timeout_seconds=5.0)

    assert "phase" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1
    assert load_phase_plan(runtime.project_root, runtime.runtime_dir) is None


# ===========================================================================
# Required test — frozen Phase fact changes (§53)
# ===========================================================================


def test_frozen_phase_fact_title_change_rejected(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    response_payload = _phase_payload("01", title="Changed title")
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=response_payload
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(PhaseOutlinePlanningError) as exc_info:
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert "frozen" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1


def test_frozen_phase_fact_objective_change_rejected(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    response_payload = _phase_payload("01", objective="Changed objective.")
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=response_payload
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(PhaseOutlinePlanningError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 1


def test_frozen_phase_fact_depends_on_change_rejected(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    master_plan_payload = _two_phase_master_plan_payload()
    # Frozen phase "02" has depends_on == (); planner returns depends_on == ("01",).
    response_payload = _phase_payload("02", subphases=[_outline_payload("01")], depends_on=("01",))
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=response_payload
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, master_plan_payload)

    with pytest.raises(PhaseOutlinePlanningError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("02"), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 1


def test_frozen_phase_fact_integration_criteria_change_rejected(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    response_payload = _phase_payload("01")
    response_payload["integration_acceptance_criteria"] = [
        {"criterion_id": "AC-NEW", "description": "New criterion."}
    ]
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=response_payload
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(PhaseOutlinePlanningError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 1


def test_schema_version_has_no_alternate_legal_construction() -> None:
    """Only schema_version == 1 currently validates.

    A candidate cannot legally arrive with a different schema_version:
    the artifact model itself rejects any other value before this
    workflow ever sees it, so there is no valid-Pydantic-model
    construction that could reach the frozen-fact comparison with a
    schema_version drift. This documents that this sub-case of §53 is
    already foreclosed by the domain layer rather than by this
    workflow, rather than silently skipping it.
    """
    with pytest.raises(ValidationError):
        PhasePlan.model_validate({**_phase_payload("01"), "schema_version": 2})


# ===========================================================================
# Required test — semantic ordering (§54)
# ===========================================================================


def test_wrong_phase_and_duplicate_subphase_surfaces_wrong_phase_error_first(
    tmp_path: Path,
) -> None:
    bin_dir = tmp_path / "bin"
    outline = _outline_payload("01")
    response_payload = _phase_payload("01", subphases=[outline, dict(outline)])
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=response_payload
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _two_phase_master_plan_payload())

    with pytest.raises(PhaseOutlinePlanningError) as exc_info:
        create_phase_plan_candidate(runtime, phase_id=_phase_id("02"), timeout_seconds=5.0)

    assert "phase" in exc_info.value.reason


def test_corrected_phase_id_surfaces_semantic_validation_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    outline = _outline_payload("01")
    response_payload = _phase_payload("01", subphases=[outline, dict(outline)])
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=response_payload
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(PlanningValidationError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Required semantic witnesses (§55)
# ===========================================================================


@pytest.mark.parametrize("payload_builder", _SEMANTICALLY_INVALID_RESPONSE_BUILDERS)
def test_semantic_validation_errors_propagate_unwrapped(
    tmp_path: Path, payload_builder: object
) -> None:
    bin_dir = tmp_path / "bin"
    response_payload = payload_builder("01")  # type: ignore[operator]
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=response_payload
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(PlanningValidationError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 1
    assert load_phase_plan(runtime.project_root, runtime.runtime_dir) is None


# ===========================================================================
# Required test — no auto repair (§56)
# ===========================================================================


def test_no_auto_repair_effective_plan_reaches_validation_unmodified(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    bin_dir = tmp_path / "bin"
    response_payload = _phase_payload(
        "01", subphases=[_outline_payload("02"), _outline_payload("01")]
    )
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=response_payload
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    captured: list[MasterPlan] = []

    def _spy(plan: MasterPlan) -> None:
        captured.append(plan)
        validate_master_plan(plan)

    monkeypatch.setattr(planning_workflow_module, "validate_master_plan", _spy)

    candidate = create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert len(captured) == 1
    effective_phase = next(
        phase for phase in captured[0].phases if phase.phase_id == _phase_id("01")
    )
    assert effective_phase.subphases == candidate.plan.subphases
    assert [s.subphase_id.root for s in effective_phase.subphases] == ["02", "01"]


# ===========================================================================
# Required test — active Contract preflight (§60)
# ===========================================================================


def test_active_contract_blocks_candidate_generation_before_inference(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    published_response = _phase_payload("01", subphases=[_outline_payload("01")])
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=published_response
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    candidate_a = create_phase_plan_candidate(
        runtime, phase_id=_phase_id("01"), timeout_seconds=5.0
    )
    publish_phase_plan(runtime.project_root, runtime.runtime_dir, candidate_a.plan)

    contract = SubphaseContract.model_validate(_contract_payload("01", "01"))
    freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, contract)

    invocation_count_before = len(_read_invocations(bin_dir))

    with pytest.raises(PhaseOutlinePlanningError) as exc_info:
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert "contract" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == invocation_count_before


def test_active_contract_blocks_candidate_generation_codex_schema_untouched(
    tmp_path: Path,
) -> None:
    bin_dir = tmp_path / "bin"
    published_response = _phase_payload("01", subphases=[_outline_payload("01")])
    adapter = _write_provider_response(
        bin_dir, provider="codex", response_payload=published_response
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    candidate_a = create_phase_plan_candidate(
        runtime, phase_id=_phase_id("01"), timeout_seconds=5.0
    )
    publish_phase_plan(runtime.project_root, runtime.runtime_dir, candidate_a.plan)

    contract = SubphaseContract.model_validate(_contract_payload("01", "01"))
    freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, contract)

    schema_path = (
        runtime.runtime_dir / "providers" / "codex" / "planning" / "phase-plan.schema.json"
    )
    schema_bytes_before = schema_path.read_bytes()
    invocation_count_before = len(_read_invocations(bin_dir))

    with pytest.raises(PhaseOutlinePlanningError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == invocation_count_before
    assert schema_path.read_bytes() == schema_bytes_before


# ===========================================================================
# Required test — corrupted active planning store (§61)
# ===========================================================================


def test_corrupted_phase_plan_store_propagates_planning_store_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    published_response = _phase_payload("01", subphases=[_outline_payload("01")])
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=published_response
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    candidate_a = create_phase_plan_candidate(
        runtime, phase_id=_phase_id("01"), timeout_seconds=5.0
    )
    publish_phase_plan(runtime.project_root, runtime.runtime_dir, candidate_a.plan)

    contract = SubphaseContract.model_validate(_contract_payload("01", "01"))
    freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, contract)

    invocation_count_before = len(_read_invocations(bin_dir))

    phase_plan_path = runtime.runtime_dir / "planning" / "phase-plan.json"
    phase_plan_path.write_text("not valid json", encoding="utf-8")

    with pytest.raises(PlanningStoreError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == invocation_count_before


def test_corrupted_active_contract_store_propagates_planning_store_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    published_response = _phase_payload("01", subphases=[_outline_payload("01")])
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=published_response
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    candidate_a = create_phase_plan_candidate(
        runtime, phase_id=_phase_id("01"), timeout_seconds=5.0
    )
    publish_phase_plan(runtime.project_root, runtime.runtime_dir, candidate_a.plan)

    contract = SubphaseContract.model_validate(_contract_payload("01", "01"))
    freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, contract)

    invocation_count_before = len(_read_invocations(bin_dir))

    active_path = runtime.runtime_dir / "contracts" / "active.json"
    active_path.write_text("not valid json", encoding="utf-8")

    with pytest.raises(PlanningStoreError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == invocation_count_before


# ===========================================================================
# Claude / Codex candidate creation, provider neutrality, single inference
# (§50, §51, §67)
# ===========================================================================


def test_claude_candidate_creation_succeeds(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    response_payload = _phase_payload("01")
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=response_payload
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    candidate = create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert candidate.plan == PhasePlan.model_validate(response_payload)
    assert candidate.invocation.adapter_name == "claude"
    assert candidate.invocation.role is AgentRole.PLANNER
    assert len(_read_invocations(bin_dir)) == 1
    assert load_phase_plan(runtime.project_root, runtime.runtime_dir) is None


def test_codex_candidate_creation_succeeds(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    response_payload = _phase_payload("01")
    adapter = _write_provider_response(bin_dir, provider="codex", response_payload=response_payload)
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    candidate = create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert candidate.plan == PhasePlan.model_validate(response_payload)
    assert candidate.invocation.adapter_name == "codex"
    assert candidate.invocation.role is AgentRole.PLANNER
    assert len(_read_invocations(bin_dir)) == 1
    assert load_phase_plan(runtime.project_root, runtime.runtime_dir) is None


def test_claude_read_only_authority_retained(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    argv = _read_invocations(bin_dir)[0]["argv"]
    assert isinstance(argv, list)
    tools_index = argv.index("--tools")
    assert argv[tools_index + 1] == "Read,Glob,Grep"
    assert "--safe-mode" in argv
    assert "--restricted" in argv


def test_codex_read_only_authority_retained(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="codex", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    argv = _read_invocations(bin_dir)[0]["argv"]
    assert isinstance(argv, list)
    sandbox_index = argv.index("--sandbox")
    assert argv[sandbox_index + 1] == "read-only"


# ===========================================================================
# No auto-publication / explicit publication (§57, §58)
# ===========================================================================


def test_creation_does_not_publish_runtime_phase_plan(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert load_phase_plan(runtime.project_root, runtime.runtime_dir) is None
    assert not (runtime.runtime_dir / "planning" / "phase-plan.json").exists()


def test_explicit_publication_adopts_candidate(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    candidate = create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert load_phase_plan(runtime.project_root, runtime.runtime_dir) is None

    publish_phase_plan(runtime.project_root, runtime.runtime_dir, candidate.plan)

    assert load_phase_plan(runtime.project_root, runtime.runtime_dir) == candidate.plan


# ===========================================================================
# Required test — revision before Contract (§59)
# ===========================================================================


def test_revision_before_contract_replaces_a_with_b(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    response_a = _phase_payload("01", subphases=[_outline_payload("01")])
    adapter = _write_provider_response(bin_dir, provider="claude", response_payload=response_a)
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    candidate_a = create_phase_plan_candidate(
        runtime, phase_id=_phase_id("01"), timeout_seconds=5.0
    )
    publish_phase_plan(runtime.project_root, runtime.runtime_dir, candidate_a.plan)

    response_b_payload = json.dumps(
        _phase_payload("01", subphases=[_outline_payload("01"), _outline_payload("02")])
    )
    _set_fake_provider_response(bin_dir, name="claude", stdout=response_b_payload)

    candidate_b = create_phase_plan_candidate(
        runtime, phase_id=_phase_id("01"), timeout_seconds=5.0
    )
    publish_phase_plan(runtime.project_root, runtime.runtime_dir, candidate_b.plan)

    invocations = _read_invocations(bin_dir)
    second_stdin = invocations[1]["stdin"]
    assert isinstance(second_stdin, str)
    assert json.loads(_extract_current_outline_raw(second_stdin)) == candidate_a.plan.model_dump(
        mode="json"
    )

    assert len(invocations) == 2
    assert load_phase_plan(runtime.project_root, runtime.runtime_dir) == candidate_b.plan
    assert candidate_b.plan != candidate_a.plan


# ===========================================================================
# Lower-layer exception transparency (§63, §64)
# ===========================================================================


def test_planner_nonzero_exit_propagates_planning_transport_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="", returncode=3)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(PlanningTransportError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert load_phase_plan(runtime.project_root, runtime.runtime_dir) is None


def test_malformed_structured_output_propagates_planning_transport_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="not json at all")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(PlanningTransportError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)


def test_truncated_output_propagates_planning_transport_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(PlanningTransportError):
        create_phase_plan_candidate(
            runtime, phase_id=_phase_id("01"), timeout_seconds=5.0, max_output_bytes=8
        )


def test_environment_policy_error_propagates_unwrapped(tmp_path: Path) -> None:
    adapter = _claude_planner(executable="/nonexistent/claude")
    runtime = _runtime(tmp_path, planner_adapter=adapter, parent_env={})
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(EnvironmentPolicyError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)


def test_process_launch_error_propagates_unwrapped(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist" / "claude"
    adapter = _claude_planner(executable=str(missing))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(ProcessLaunchError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)


def test_process_timeout_error_propagates_unwrapped(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="irrelevant", sleep_seconds=5.0)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(ProcessTimeoutError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=0.3)


def test_claude_billing_mode_mismatch_propagates_unwrapped(tmp_path: Path) -> None:
    adapter = _claude_planner()
    runtime = _runtime(
        tmp_path, planner_adapter=adapter, planner_billing_mode=BillingMode.API_ALLOWED
    )
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(ClaudeAdapterError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)


def test_codex_billing_mode_mismatch_propagates_unwrapped(tmp_path: Path) -> None:
    adapter = _codex_planner()
    runtime = _runtime(
        tmp_path, planner_adapter=adapter, planner_billing_mode=BillingMode.API_ALLOWED
    )
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(CodexAdapterError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)


# ===========================================================================
# Exactly one inference across outcomes (§65)
# ===========================================================================


def test_exactly_one_inference_on_success(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 1


def test_zero_inference_on_no_frozen_master_plan(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PhaseOutlinePlanningError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 0


def test_zero_inference_on_unknown_phase(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(PhaseOutlinePlanningError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("99"), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 0


def test_zero_inference_on_active_contract(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    published_response = _phase_payload("01", subphases=[_outline_payload("01")])
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=published_response
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    candidate_a = create_phase_plan_candidate(
        runtime, phase_id=_phase_id("01"), timeout_seconds=5.0
    )
    publish_phase_plan(runtime.project_root, runtime.runtime_dir, candidate_a.plan)
    contract = SubphaseContract.model_validate(_contract_payload("01", "01"))
    freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, contract)

    invocation_count_before = len(_read_invocations(bin_dir))

    with pytest.raises(PhaseOutlinePlanningError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == invocation_count_before


def test_one_inference_on_semantic_failure(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    outline = _outline_payload("01")
    response_payload = _phase_payload("01", subphases=[outline, dict(outline)])
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=response_payload
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(PlanningValidationError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("01"), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 1


def test_one_inference_on_wrong_phase(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_phase_payload("01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _two_phase_master_plan_payload())

    with pytest.raises(PhaseOutlinePlanningError):
        create_phase_plan_candidate(runtime, phase_id=_phase_id("02"), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Dependency / authority boundary audit (§68-70)
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
    "publish_phase_plan",
    "freeze_subphase_contract",
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


def test_planning_workflow_module_does_not_import_publish_phase_plan() -> None:
    tree = ast.parse(inspect.getsource(planning_workflow_module))
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            for alias in node.names:
                assert alias.name != "publish_phase_plan"
        if isinstance(node, ast.Import):
            for alias in node.names:
                assert alias.name != "lockstep.planning_store.publish_phase_plan"


def test_planning_workflow_module_does_not_import_contract_freeze_api() -> None:
    tree = ast.parse(inspect.getsource(planning_workflow_module))
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            for alias in node.names:
                assert alias.name != "freeze_subphase_contract"


def test_planning_workflow_module_does_not_touch_ambient_environment_or_subprocess() -> None:
    tree = ast.parse(inspect.getsource(planning_workflow_module))
    attribute_accesses = {node.attr for node in ast.walk(tree) if isinstance(node, ast.Attribute)}
    assert "environ" not in attribute_accesses
    assert "getenv" not in attribute_accesses


def test_create_phase_plan_candidate_has_no_provider_import_or_switch() -> None:
    source = inspect.getsource(planning_workflow_module)
    assert "AgentProvider" not in source
    assert '"claude"' not in source
    assert "'claude'" not in source
    assert '"codex"' not in source
    assert "'codex'" not in source
