"""Planner-authored specification of Sub-phase 8.6 next Contract planning.

Pins the third real AI planning workflow: a validated **SubphaseContract
candidate** for one explicitly selected Sub-phase of the current
published Phase outline.

    frozen Master Plan (8.2)
        +
    current published PhasePlan (8.2)
        +
    explicit PhaseId
        +
    explicit SubphaseId
        +
    current read-only repository state
        ↓
    configured structured Planner (8.3)
        ↓
    typed SubphaseContract candidate
        ↓
    phase/subphase identity binding
        ↓
    8.1 contract semantic validation against the effective current
    Master Plan
        ↓
    SubphaseContractCandidate returned

        caller / control-plane boundary

    freeze_subphase_contract(...) (8.2)
        ↓
    immutable active Contract

The core invariant under test: the Phase outline is provisional, but
the active Sub-phase Contract is not. Generation must not automatically
freeze the candidate, "next" is never inferred (the caller always
supplies an explicit phase_id/subphase_id), and the Sub-phase must
exist in the *current published* Phase outline rather than the stale
outline nested in the frozen Master Plan.

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
from lockstep.domain import (
    AgentRole,
    BillingMode,
    MasterPlan,
    PhaseId,
    PhasePlan,
    SubphaseContract,
    SubphaseId,
)
from lockstep.planning import PlanningValidationError, validate_subphase_contract
from lockstep.planning_store import (
    PlanningStoreError,
    freeze_master_plan,
    freeze_subphase_contract,
    load_active_subphase_contract,
    publish_phase_plan,
)
from lockstep.planning_transport import (
    PlanningArtifactKind,
    PlanningArtifactResult,
    PlanningTransportError,
    invoke_planner_artifact,
)
from lockstep.planning_workflow import (
    SubphaseContractCandidate,
    SubphaseContractPlanningError,
    create_subphase_contract_candidate,
)
from lockstep.process import EnvironmentPolicyError, ProcessLaunchError, ProcessTimeoutError
from lockstep.runtime import AgentRuntime

# ---------------------------------------------------------------------------
# Construction helpers — CLI status / adapter fixtures (mirrors 8.3/8.4/8.5)
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
# AgentRuntime construction helper (mirrors 8.3/8.4/8.5)
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
# Master Plan / Phase plan / Contract payload fixtures
# ---------------------------------------------------------------------------


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
    acceptance_criteria: list[dict[str, object]] | None = None,
    tests: list[dict[str, object]] | None = None,
    title: str = "Contract title",
    objective: str = "Contract objective.",
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "phase_id": phase_id,
        "subphase_id": subphase_id,
        "title": title,
        "objective": objective,
        "acceptance_criteria": (
            acceptance_criteria
            if acceptance_criteria is not None
            else [{"criterion_id": "AC-1", "description": "Criterion."}]
        ),
        "tests": (
            tests
            if tests is not None
            else [
                {
                    "path": "tests/test_example.py",
                    "expectation": "red",
                    "acceptance_criteria": ["AC-1"],
                }
            ]
        ),
        "allowed_paths": ["src/example.py"],
        "protected_paths": [],
        "forbidden_paths": [],
        "verification_commands": ["pytest tests/test_example.py"],
    }


def _write_provider_response(
    bin_dir: Path, *, provider: str, response_payload: dict[str, object]
) -> AgentAdapter:
    if provider == "claude":
        _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(response_payload))
        return _claude_planner(executable=str(bin_dir / "claude"))
    _write_fake_provider_executable(bin_dir, name="codex", stdout=json.dumps(response_payload))
    return _codex_planner(executable=str(bin_dir / "codex"))


# ---------------------------------------------------------------------------
# Semantically invalid SubphaseContract response payload builders (§70)
# ---------------------------------------------------------------------------


def _duplicate_criterion_response_payload(phase_id: str = "01", subphase_id: str = "01") -> dict:
    return _contract_payload(
        phase_id,
        subphase_id,
        acceptance_criteria=[
            {"criterion_id": "AC-1", "description": "Criterion one."},
            {"criterion_id": "AC-1", "description": "Criterion one, duplicated."},
        ],
        tests=[
            {
                "path": "tests/test_example.py",
                "expectation": "red",
                "acceptance_criteria": ["AC-1"],
            }
        ],
    )


def _duplicate_test_path_response_payload(phase_id: str = "01", subphase_id: str = "01") -> dict:
    return _contract_payload(
        phase_id,
        subphase_id,
        tests=[
            {
                "path": "tests/test_example.py",
                "expectation": "red",
                "acceptance_criteria": ["AC-1"],
            },
            {
                "path": "tests/test_example.py",
                "expectation": "green_regression",
                "acceptance_criteria": ["AC-1"],
            },
        ],
    )


def _unknown_test_criterion_reference_response_payload(
    phase_id: str = "01", subphase_id: str = "01"
) -> dict:
    return _contract_payload(
        phase_id,
        subphase_id,
        tests=[
            {
                "path": "tests/test_example.py",
                "expectation": "red",
                "acceptance_criteria": ["AC-UNKNOWN"],
            }
        ],
    )


def _duplicate_test_criterion_reference_response_payload(
    phase_id: str = "01", subphase_id: str = "01"
) -> dict:
    return _contract_payload(
        phase_id,
        subphase_id,
        tests=[
            {
                "path": "tests/test_example.py",
                "expectation": "red",
                "acceptance_criteria": ["AC-1", "AC-1"],
            }
        ],
    )


_SEMANTICALLY_INVALID_RESPONSE_BUILDERS = (
    _duplicate_criterion_response_payload,
    _duplicate_test_path_response_payload,
    _unknown_test_criterion_reference_response_payload,
    _duplicate_test_criterion_reference_response_payload,
)


# ---------------------------------------------------------------------------
# Prompt parsing helpers (mirror the fixed labels the production prompt
# builder is expected to emit)
# ---------------------------------------------------------------------------

_MASTER_PLAN_LABEL = "Frozen Master Plan:"
_PHASE_PLAN_LABEL = "Current Phase plan:"
_TARGET_PHASE_LABEL = "Target phase_id:"
_TARGET_SUBPHASE_LABEL = "Target subphase_id:"
_TARGET_OUTLINE_LABEL = "Target subphase outline:"


def _extract_line_after(prompt: str, label: str) -> str:
    lines = prompt.splitlines()
    marker_index = lines.index(label)
    return lines[marker_index + 1]


# 12.10-R1: the Master Plan and the current Phase plan reach the Contract Planner exactly
# once, through their ContextPack sections; the trailer no longer repeats either payload.
_MASTER_PLAN_SECTION = "## MASTER PLAN [frozen_requirement]"
_PHASE_PLAN_SECTION = "## CURRENT PROVISIONAL PHASE PLAN [provisional_plan]"


def _extract_section(prompt: str, heading: str) -> dict[str, object]:
    lines = prompt.splitlines()
    assert lines.count(heading) == 1
    section = json.loads(lines[lines.index(heading) + 1])
    assert isinstance(section, dict)
    return section


def _extract_master_plan_json(prompt: str) -> dict[str, object]:
    master_plan = _extract_section(prompt, _MASTER_PLAN_SECTION)["master_plan"]
    assert isinstance(master_plan, dict)
    return master_plan


def _extract_phase_plan_json(prompt: str) -> dict[str, object]:
    phase_plan = _extract_section(prompt, _PHASE_PLAN_SECTION)["phase_plan"]
    assert isinstance(phase_plan, dict)
    return phase_plan


def _legacy_payload(model: MasterPlan | PhasePlan) -> str:
    """The pre-R1 trailer serialization of a plan payload."""
    return json.dumps(model.model_dump(mode="json"), ensure_ascii=False, separators=(",", ":"))


def _extract_target_phase(prompt: str) -> str:
    return _extract_line_after(prompt, _TARGET_PHASE_LABEL)


def _extract_target_subphase(prompt: str) -> str:
    return _extract_line_after(prompt, _TARGET_SUBPHASE_LABEL)


def _extract_target_outline_json(prompt: str) -> dict[str, object]:
    return json.loads(_extract_line_after(prompt, _TARGET_OUTLINE_LABEL))


# ---------------------------------------------------------------------------
# Candidate-creation helper
# ---------------------------------------------------------------------------


def _setup_published_phase(
    tmp_path: Path,
    *,
    provider: str = "claude",
    master_plan_payload: dict[str, object] | None = None,
    phase_plan_payload: dict[str, object] | None = None,
    response_payload: dict[str, object] | None = None,
) -> tuple[AgentRuntime, Path, MasterPlan, PhasePlan]:
    """Freeze a Master Plan and publish a matching current Phase plan."""
    bin_dir = tmp_path / "bin"
    used_master_plan_payload = (
        master_plan_payload if master_plan_payload is not None else _master_plan_payload()
    )
    used_response_payload = (
        response_payload if response_payload is not None else _contract_payload()
    )
    adapter = _write_provider_response(
        bin_dir, provider=provider, response_payload=used_response_payload
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    master_plan = _freeze_master_plan(runtime.project_root, used_master_plan_payload)

    used_phase_plan_payload = (
        phase_plan_payload if phase_plan_payload is not None else _phase_payload()
    )
    phase_plan = _publish_phase_plan(runtime, used_phase_plan_payload)

    return runtime, bin_dir, master_plan, phase_plan


def _create_candidate_and_capture_stdin(
    tmp_path: Path,
    *,
    provider: str = "claude",
    phase_id: str = "01",
    subphase_id: str = "01",
    master_plan_payload: dict[str, object] | None = None,
    phase_plan_payload: dict[str, object] | None = None,
    response_payload: dict[str, object] | None = None,
) -> tuple[str, AgentRuntime, Path, MasterPlan, PhasePlan]:
    runtime, bin_dir, master_plan, phase_plan = _setup_published_phase(
        tmp_path,
        provider=provider,
        master_plan_payload=master_plan_payload,
        phase_plan_payload=phase_plan_payload,
        response_payload=(
            response_payload
            if response_payload is not None
            else _contract_payload(phase_id, subphase_id)
        ),
    )

    create_subphase_contract_candidate(
        runtime,
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        timeout_seconds=5.0,
    )

    stdin = _read_invocations(bin_dir)[0]["stdin"]
    assert isinstance(stdin, str)
    return stdin, runtime, bin_dir, master_plan, phase_plan


# ===========================================================================
# SubphaseContractCandidate shape and privacy (§7, §55)
# ===========================================================================


def test_subphase_contract_candidate_shape_and_privacy(tmp_path: Path) -> None:
    sentinel_title = "SENTINEL-DO-NOT-LEAK-contract-4f21"
    response_payload = _contract_payload(title=sentinel_title)
    runtime, _bin_dir, _mp, _pp = _setup_published_phase(
        tmp_path, response_payload=response_payload
    )

    candidate = create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    assert isinstance(candidate, SubphaseContractCandidate)
    assert {f.name for f in fields(candidate)} == {"contract", "invocation"}

    with pytest.raises(FrozenInstanceError):
        candidate.contract = candidate.contract  # type: ignore[misc]

    assert not hasattr(candidate, "__dict__")

    rendered = repr(candidate)
    assert sentinel_title not in rendered


def test_subphase_contract_planning_error_carries_bounded_reason() -> None:
    error = SubphaseContractPlanningError("master plan is not frozen")
    assert error.reason == "master plan is not frozen"
    assert "master plan is not frozen" in str(error)


def test_public_api_exports_expected_names() -> None:
    assert {
        "SubphaseContractPlanningError",
        "SubphaseContractCandidate",
        "create_subphase_contract_candidate",
    }.issubset(set(planning_workflow_module.__all__))


def test_no_auto_freeze_api_exists() -> None:
    for forbidden in ("freeze_and_return", "auto_freeze", "freeze_subphase_contract"):
        assert not hasattr(planning_workflow_module, forbidden)


# ===========================================================================
# Signature shape — explicit phase/subphase id, no provider surface
# ===========================================================================


def test_create_subphase_contract_candidate_signature_shape() -> None:
    sig = inspect.signature(create_subphase_contract_candidate)
    params = sig.parameters

    assert next(iter(params)) == "runtime"
    assert params["runtime"].annotation in (AgentRuntime, "AgentRuntime")

    for name in (
        "phase_id",
        "subphase_id",
        "timeout_seconds",
        "max_output_bytes",
        "termination_grace_seconds",
    ):
        assert params[name].kind is inspect.Parameter.KEYWORD_ONLY

    assert params["phase_id"].default is inspect.Parameter.empty
    assert params["subphase_id"].default is inspect.Parameter.empty
    assert params["timeout_seconds"].default is inspect.Parameter.empty
    assert params["max_output_bytes"].default == 1_048_576
    assert params["termination_grace_seconds"].default == 0.25

    for forbidden in (
        "master_plan",
        "phase_plan",
        "subphase_outline",
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
# Required test — no frozen Master Plan (§56, §11)
# ===========================================================================


def test_no_frozen_master_plan_raises_before_inference(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_contract_payload()
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(SubphaseContractPlanningError) as exc_info:
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert "frozen" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []
    assert not (runtime.runtime_dir / "providers").exists()
    assert not (runtime.runtime_dir / "contracts").exists()


# ===========================================================================
# Required test — no published PhasePlan (§57, §46)
# ===========================================================================


def test_no_published_phase_plan_raises_before_inference(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_contract_payload()
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(SubphaseContractPlanningError) as exc_info:
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert "published" in exc_info.value.reason or "phase plan" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Required test — wrong published Phase (§58, §12)
# ===========================================================================


def test_wrong_published_phase_raises_before_inference(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_contract_payload("02", "01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _two_phase_master_plan_payload())
    _publish_phase_plan(runtime, _phase_payload("01", subphases=[_outline_payload("01")]))

    with pytest.raises(SubphaseContractPlanningError) as exc_info:
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("02"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert "phase" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Required test — active Contract preflight (§59, §13, §14)
# ===========================================================================


def test_active_contract_blocks_candidate_generation_before_inference(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, phase_plan = _setup_published_phase(tmp_path)
    contract = SubphaseContract.model_validate(_contract_payload("01", "01"))
    freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, contract)

    invocation_count_before = len(_read_invocations(bin_dir))

    with pytest.raises(SubphaseContractPlanningError) as exc_info:
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert "contract" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == invocation_count_before
    assert phase_plan is not None


def test_active_contract_blocks_candidate_generation_codex_schema_untouched(
    tmp_path: Path,
) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path, provider="codex")

    candidate = create_subphase_contract_candidate(
        runtime,
        phase_id=_phase_id("01"),
        subphase_id=_subphase_id("01"),
        timeout_seconds=5.0,
    )
    freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, candidate.contract)

    schema_path = (
        runtime.runtime_dir / "providers" / "codex" / "planning" / "subphase-contract.schema.json"
    )
    schema_bytes_before = schema_path.read_bytes()
    invocation_count_before = len(_read_invocations(bin_dir))

    with pytest.raises(SubphaseContractPlanningError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == invocation_count_before
    assert schema_path.read_bytes() == schema_bytes_before
    assert (
        load_active_subphase_contract(runtime.project_root, runtime.runtime_dir)
        == candidate.contract
    )


# ===========================================================================
# Required test — corrupted active planning state (§60)
# ===========================================================================


def test_corrupted_phase_plan_store_propagates_planning_store_error(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path)
    invocation_count_before = len(_read_invocations(bin_dir))

    phase_plan_path = runtime.runtime_dir / "planning" / "phase-plan.json"
    phase_plan_path.write_text("not valid json", encoding="utf-8")

    with pytest.raises(PlanningStoreError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == invocation_count_before


def test_corrupted_active_contract_store_propagates_planning_store_error(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path)
    contract = SubphaseContract.model_validate(_contract_payload("01", "01"))
    freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, contract)

    invocation_count_before = len(_read_invocations(bin_dir))

    active_path = runtime.runtime_dir / "contracts" / "active.json"
    active_path.write_text("not valid json", encoding="utf-8")

    with pytest.raises(PlanningStoreError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == invocation_count_before


# ===========================================================================
# Required test — target membership (§61, §15)
# ===========================================================================


def test_unknown_subphase_raises_before_inference(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(
        tmp_path,
        phase_plan_payload=_phase_payload(
            "01", subphases=[_outline_payload("01"), _outline_payload("02")]
        ),
    )

    with pytest.raises(SubphaseContractPlanningError) as exc_info:
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("03"),
            timeout_seconds=5.0,
        )

    assert "subphase" in exc_info.value.reason
    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Required test — current runtime outline wins over frozen nested outline
# (§62, §17)
# ===========================================================================


def test_current_published_outline_wins_over_frozen_nested_outline(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_contract_payload("01", "02")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload(phases=[_phase_payload("01")]))
    _publish_phase_plan(runtime, _phase_payload("01", subphases=[_outline_payload("02")]))

    candidate = create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("02"), timeout_seconds=5.0
    )
    assert candidate.contract.subphase_id == _subphase_id("02")
    assert len(_read_invocations(bin_dir)) == 1

    with pytest.raises(SubphaseContractPlanningError) as exc_info:
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert "subphase" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Deterministic prompt construction (§19-24, §63)
# ===========================================================================


def test_prompt_is_byte_identical_across_two_clean_calls(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path)

    create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )
    create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    invocations = _read_invocations(bin_dir)
    assert len(invocations) == 2
    assert invocations[0]["stdin"] == invocations[1]["stdin"]


def test_prompt_contains_exact_master_plan_context(tmp_path: Path) -> None:
    prompt, _runtime, _bin_dir, master_plan, _pp = _create_candidate_and_capture_stdin(tmp_path)

    assert _extract_master_plan_json(prompt) == master_plan.model_dump(mode="json")
    # Exactly once: the ContextPack is the only carrier; no duplicate trailer payload.
    assert prompt.count('"master_plan":') == 1
    assert _MASTER_PLAN_LABEL not in prompt.splitlines()
    assert _legacy_payload(master_plan) not in prompt


def test_prompt_contains_exact_current_phase_plan_context(tmp_path: Path) -> None:
    prompt, _runtime, _bin_dir, _mp, phase_plan = _create_candidate_and_capture_stdin(tmp_path)

    assert _extract_phase_plan_json(prompt) == phase_plan.model_dump(mode="json")
    # Exactly once: the ContextPack is the only carrier; no duplicate trailer payload.
    assert prompt.count('"phase_plan":') == 1
    assert _PHASE_PLAN_LABEL not in prompt.splitlines()
    assert _legacy_payload(phase_plan) not in prompt


def test_prompt_contains_exact_target_outline_context(tmp_path: Path) -> None:
    phase_plan_payload = _phase_payload(
        "01", subphases=[_outline_payload("01"), _outline_payload("02")]
    )
    prompt, _runtime, _bin_dir, _mp, phase_plan = _create_candidate_and_capture_stdin(
        tmp_path, phase_plan_payload=phase_plan_payload, subphase_id="02"
    )

    expected_outline = next(s for s in phase_plan.subphases if s.subphase_id == _subphase_id("02"))
    assert _extract_target_outline_json(prompt) == expected_outline.model_dump(mode="json")


def test_prompt_contains_exact_target_identity(tmp_path: Path) -> None:
    prompt, _runtime, _bin_dir, _mp, _pp = _create_candidate_and_capture_stdin(tmp_path)

    assert _extract_target_phase(prompt) == "01"
    assert _extract_target_subphase(prompt) == "01"


def test_prompt_contains_required_planning_instructions(tmp_path: Path) -> None:
    prompt, _runtime, _bin_dir, _mp, _pp = _create_candidate_and_capture_stdin(tmp_path)

    assert "exactly one implementation Sub-phase" in prompt
    assert "planning truth" in prompt
    assert "Produce exactly one SubphaseContract" in prompt
    assert "Do not implement code" in prompt
    assert "Do not write files" in prompt
    assert "Do not author executable test files" in prompt
    assert "Do not plan another Sub-phase" in prompt
    assert "specific" in prompt
    assert "observable" in prompt
    assert "independently falsifiable" in prompt
    assert "traceable" in prompt
    assert "test-authoring specification" in prompt
    assert "red" in prompt
    assert "green_regression" in prompt
    assert "green_characterization" in prompt
    assert "opaque scope declarations" in prompt
    assert "verification_commands" in prompt
    assert "deterministic evidence" in prompt
    assert "configured verification execution environment" in prompt
    assert "not how that environment is entered" in prompt
    assert "docker compose run" in prompt
    assert "whose sole purpose is to enter that same configured environment" in prompt
    assert "owns the environment boundary" in prompt
    assert "do not execute them" in prompt
    assert "safe to land independently" in prompt
    assert "read-only" in prompt
    assert "Do not modify files" in prompt
    assert "Return only the structured SubphaseContract" in prompt


@pytest.mark.parametrize("provider", ["claude", "codex"])
def test_prompt_does_not_leak_provider_or_host_identity(tmp_path: Path, provider: str) -> None:
    prompt, runtime, _bin_dir, _mp, _pp = _create_candidate_and_capture_stdin(
        tmp_path, provider=provider
    )

    assert "claude" not in prompt.lower()
    assert "codex" not in prompt.lower()
    assert "planner-model" not in prompt
    assert str(runtime.project_root) not in prompt
    assert str(runtime.runtime_dir) not in prompt


# ===========================================================================
# Exact lower-layer transport call (§31, §81)
# ===========================================================================


def test_invoke_planner_artifact_called_exactly_once_with_expected_arguments(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime, _bin_dir, _mp, _pp = _setup_published_phase(tmp_path)

    calls: list[tuple[AgentRuntime, dict[str, object], PlanningArtifactResult]] = []

    def _spy(runtime_arg: AgentRuntime, **kwargs: object) -> PlanningArtifactResult:
        result = invoke_planner_artifact(runtime_arg, **kwargs)  # type: ignore[arg-type]
        calls.append((runtime_arg, kwargs, result))
        return result

    monkeypatch.setattr(planning_workflow_module, "invoke_planner_artifact", _spy)

    candidate = create_subphase_contract_candidate(
        runtime,
        phase_id=_phase_id("01"),
        subphase_id=_subphase_id("01"),
        timeout_seconds=5.0,
        max_output_bytes=2048,
        termination_grace_seconds=0.5,
    )

    assert len(calls) == 1
    runtime_arg, kwargs, result = calls[0]
    assert runtime_arg is runtime
    assert kwargs["kind"] is PlanningArtifactKind.SUBPHASE_CONTRACT
    assert kwargs["timeout_seconds"] == 5.0
    assert kwargs["max_output_bytes"] == 2048
    assert kwargs["termination_grace_seconds"] == 0.5
    assert isinstance(kwargs["prompt"], str)
    assert candidate.invocation is result.invocation


def test_artifact_kind_drift_fails_closed(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    runtime, _bin_dir, _mp, _pp = _setup_published_phase(tmp_path)

    real_invoke = planning_workflow_module.invoke_planner_artifact

    def _drifted(*args: object, **kwargs: object) -> PlanningArtifactResult:
        result = real_invoke(*args, **kwargs)  # type: ignore[arg-type]
        return PlanningArtifactResult(
            kind=PlanningArtifactKind.PHASE_PLAN,
            artifact=result.artifact,
            invocation=result.invocation,
        )

    monkeypatch.setattr(planning_workflow_module, "invoke_planner_artifact", _drifted)

    with pytest.raises(SubphaseContractPlanningError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )


# ===========================================================================
# Required test — wrong Phase / wrong Sub-phase binding (§67, §68)
# ===========================================================================


def test_wrong_phase_binding_raises_after_one_inference(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(
        tmp_path, response_payload=_contract_payload("99", "01")
    )

    with pytest.raises(SubphaseContractPlanningError) as exc_info:
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert "phase" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1
    assert load_active_subphase_contract(runtime.project_root, runtime.runtime_dir) is None


def test_wrong_subphase_binding_raises_after_one_inference(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(
        tmp_path, response_payload=_contract_payload("01", "99")
    )

    with pytest.raises(SubphaseContractPlanningError) as exc_info:
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert "subphase" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Required test — binding validation ordering (§36, §69)
# ===========================================================================


def test_wrong_phase_and_more_surfaces_wrong_phase_error_first(tmp_path: Path) -> None:
    response_payload = _duplicate_criterion_response_payload("99", "99")
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path, response_payload=response_payload)

    with pytest.raises(SubphaseContractPlanningError) as exc_info:
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert "phase" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1


def test_correct_phase_wrong_subphase_surfaces_wrong_subphase_error(tmp_path: Path) -> None:
    response_payload = _duplicate_criterion_response_payload("01", "99")
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path, response_payload=response_payload)

    with pytest.raises(SubphaseContractPlanningError) as exc_info:
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert "subphase" in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1


def test_correct_identity_surfaces_semantic_validation_error(tmp_path: Path) -> None:
    response_payload = _duplicate_criterion_response_payload("01", "01")
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path, response_payload=response_payload)

    with pytest.raises(PlanningValidationError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Required semantic witnesses (§70)
# ===========================================================================


@pytest.mark.parametrize("payload_builder", _SEMANTICALLY_INVALID_RESPONSE_BUILDERS)
def test_semantic_validation_errors_propagate_unwrapped(
    tmp_path: Path, payload_builder: object
) -> None:
    response_payload = payload_builder("01", "01")  # type: ignore[operator]
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path, response_payload=response_payload)

    with pytest.raises(PlanningValidationError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == 1
    assert load_active_subphase_contract(runtime.project_root, runtime.runtime_dir) is None


def test_partial_acceptance_criteria_coverage_by_tests_is_legal(tmp_path: Path) -> None:
    response_payload = _contract_payload(
        "01",
        "01",
        acceptance_criteria=[
            {"criterion_id": "AC-1", "description": "Criterion one."},
            {"criterion_id": "AC-2", "description": "Criterion two."},
        ],
        tests=[
            {
                "path": "tests/test_example.py",
                "expectation": "red",
                "acceptance_criteria": ["AC-1"],
            }
        ],
    )
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path, response_payload=response_payload)

    candidate = create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    assert len(candidate.contract.acceptance_criteria) == 2
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Required test — exact semantic-validator input (§71)
# ===========================================================================


def test_semantic_validator_receives_effective_plan_and_exact_contract(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    phase_plan_payload = _phase_payload(
        "01", subphases=[_outline_payload("01"), _outline_payload("02")]
    )
    runtime, _bin_dir, master_plan, phase_plan = _setup_published_phase(
        tmp_path,
        master_plan_payload=_two_phase_master_plan_payload(),
        phase_plan_payload=phase_plan_payload,
    )

    captured: list[tuple[MasterPlan, SubphaseContract]] = []

    def _spy(plan: MasterPlan, contract: SubphaseContract) -> None:
        captured.append((plan, contract))
        validate_subphase_contract(plan, contract)

    monkeypatch.setattr(planning_workflow_module, "validate_subphase_contract", _spy)

    candidate = create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    assert len(captured) == 1
    effective_plan, validated_contract = captured[0]

    effective_phase_01 = next(p for p in effective_plan.phases if p.phase_id == _phase_id("01"))
    assert effective_phase_01 == phase_plan
    assert effective_phase_01.subphases == phase_plan.subphases

    effective_phase_02 = next(p for p in effective_plan.phases if p.phase_id == _phase_id("02"))
    frozen_phase_02 = next(p for p in master_plan.phases if p.phase_id == _phase_id("02"))
    assert effective_phase_02 == frozen_phase_02

    assert validated_contract is candidate.contract


# ===========================================================================
# Candidate prose may refine outline prose (§16, §38, §64)
# ===========================================================================


def test_refined_contract_prose_is_legal(tmp_path: Path) -> None:
    phase_plan_payload = _phase_payload(
        "01",
        subphases=[
            {
                "subphase_id": "01",
                "title": "Broad provisional title",
                "objective": "Broad provisional objective.",
                "depends_on": [],
            }
        ],
    )
    response_payload = _contract_payload(
        "01", "01", title="Refined implementation-ready title", objective="Refined objective."
    )
    runtime, _bin_dir, _mp, _pp = _setup_published_phase(
        tmp_path, phase_plan_payload=phase_plan_payload, response_payload=response_payload
    )

    candidate = create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    assert candidate.contract.title == "Refined implementation-ready title"
    assert candidate.contract.objective == "Refined objective."


# ===========================================================================
# Claude / Codex candidate creation, provider neutrality, single inference
# (§50, §51, §65, §66)
# ===========================================================================


def test_claude_candidate_creation_succeeds(tmp_path: Path) -> None:
    response_payload = _contract_payload("01", "01")
    runtime, bin_dir, _mp, _pp = _setup_published_phase(
        tmp_path, provider="claude", response_payload=response_payload
    )

    candidate = create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    assert candidate.contract == SubphaseContract.model_validate(response_payload)
    assert candidate.invocation.adapter_name == "claude"
    assert candidate.invocation.role is AgentRole.PLANNER
    assert len(_read_invocations(bin_dir)) == 1
    assert load_active_subphase_contract(runtime.project_root, runtime.runtime_dir) is None


def test_codex_candidate_creation_succeeds(tmp_path: Path) -> None:
    response_payload = _contract_payload("01", "01")
    runtime, bin_dir, _mp, _pp = _setup_published_phase(
        tmp_path, provider="codex", response_payload=response_payload
    )

    candidate = create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    assert candidate.contract == SubphaseContract.model_validate(response_payload)
    assert candidate.invocation.adapter_name == "codex"
    assert candidate.invocation.role is AgentRole.PLANNER
    assert len(_read_invocations(bin_dir)) == 1
    assert load_active_subphase_contract(runtime.project_root, runtime.runtime_dir) is None


def test_claude_read_only_authority_retained(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path, provider="claude")

    create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    argv = _read_invocations(bin_dir)[0]["argv"]
    assert isinstance(argv, list)
    tools_index = argv.index("--tools")
    assert argv[tools_index + 1] == "Read,Glob,Grep"
    assert "--safe-mode" in argv
    assert "--restricted" in argv
    assert "--disallowed-tools" not in argv or "Write" not in argv
    for forbidden_tool in ("Write", "Edit", "Bash"):
        assert forbidden_tool not in argv


def test_codex_read_only_authority_retained(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path, provider="codex")

    create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    argv = _read_invocations(bin_dir)[0]["argv"]
    assert isinstance(argv, list)
    sandbox_index = argv.index("--sandbox")
    assert argv[sandbox_index + 1] == "read-only"


# ===========================================================================
# No auto freeze / explicit freeze demonstration (§40, §41, §72, §73)
# ===========================================================================


def test_candidate_generation_does_not_freeze_contract(tmp_path: Path) -> None:
    runtime, _bin_dir, _mp, _pp = _setup_published_phase(tmp_path)

    create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    assert load_active_subphase_contract(runtime.project_root, runtime.runtime_dir) is None
    assert not (runtime.runtime_dir / "contracts" / "active.json").exists()


def test_explicit_freeze_adopts_candidate(tmp_path: Path) -> None:
    runtime, _bin_dir, _mp, _pp = _setup_published_phase(tmp_path)

    candidate = create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    assert load_active_subphase_contract(runtime.project_root, runtime.runtime_dir) is None

    freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, candidate.contract)

    assert (
        load_active_subphase_contract(runtime.project_root, runtime.runtime_dir)
        == candidate.contract
    )


# ===========================================================================
# Required test — regeneration before freeze (§42, §74)
# ===========================================================================


def test_regeneration_before_freeze_produces_two_independent_candidates(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(
        tmp_path, response_payload=_contract_payload("01", "01", title="Candidate A")
    )

    candidate_a = create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    _set_fake_provider_response(
        bin_dir,
        name="claude",
        stdout=json.dumps(_contract_payload("01", "01", title="Candidate B")),
    )

    candidate_b = create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    assert len(_read_invocations(bin_dir)) == 2
    assert load_active_subphase_contract(runtime.project_root, runtime.runtime_dir) is None
    assert candidate_a.contract != candidate_b.contract
    assert candidate_a.contract.title == "Candidate A"
    assert candidate_b.contract.title == "Candidate B"


# ===========================================================================
# Required test — post-freeze block (§43, §75)
# ===========================================================================


def test_frozen_active_contract_blocks_later_generation(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path)

    candidate_a = create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )
    freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, candidate_a.contract)

    invocation_count_before = len(_read_invocations(bin_dir))

    with pytest.raises(SubphaseContractPlanningError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == invocation_count_before
    assert (
        load_active_subphase_contract(runtime.project_root, runtime.runtime_dir)
        == candidate_a.contract
    )


# ===========================================================================
# Required test — active Contract locks Phase publication (§44, §76)
# ===========================================================================


def test_active_contract_locks_phase_plan_publication(tmp_path: Path) -> None:
    runtime, _bin_dir, _mp, _pp = _setup_published_phase(tmp_path)

    candidate = create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )
    freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, candidate.contract)

    revised_phase_plan = PhasePlan.model_validate(
        _phase_payload("01", subphases=[_outline_payload("01"), _outline_payload("02")])
    )

    with pytest.raises(PlanningStoreError):
        publish_phase_plan(runtime.project_root, runtime.runtime_dir, revised_phase_plan)


# ===========================================================================
# Required test — no executable test files authored (§53, §77)
# ===========================================================================


def _snapshot_project_files(project_root: Path) -> set[str]:
    return {str(p.relative_to(project_root)) for p in project_root.rglob("*") if p.is_file()}


@pytest.mark.parametrize("provider", ["claude", "codex"])
def test_no_test_files_authored_by_candidate_generation(tmp_path: Path, provider: str) -> None:
    response_payload = _contract_payload(
        "01",
        "01",
        tests=[
            {
                "path": "tests/test_new_feature.py",
                "expectation": "red",
                "acceptance_criteria": ["AC-1"],
            }
        ],
    )
    runtime, _bin_dir, _mp, _pp = _setup_published_phase(
        tmp_path, provider=provider, response_payload=response_payload
    )

    before = _snapshot_project_files(runtime.project_root)

    create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    after = _snapshot_project_files(runtime.project_root)
    assert before == after
    assert not (runtime.project_root / "tests" / "test_new_feature.py").exists()


# ===========================================================================
# Lower-layer exception transparency (§78, §79)
# ===========================================================================


def test_planner_nonzero_exit_propagates_planning_transport_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="", returncode=3)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())
    _publish_phase_plan(runtime, _phase_payload())

    with pytest.raises(PlanningTransportError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert load_active_subphase_contract(runtime.project_root, runtime.runtime_dir) is None


def test_malformed_structured_output_propagates_planning_transport_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="not json at all")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())
    _publish_phase_plan(runtime, _phase_payload())

    with pytest.raises(PlanningTransportError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )


def test_truncated_output_propagates_planning_transport_error(tmp_path: Path) -> None:
    runtime, _bin_dir, _mp, _pp = _setup_published_phase(tmp_path)

    with pytest.raises(PlanningTransportError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
            max_output_bytes=8,
        )


def test_environment_policy_error_propagates_unwrapped(tmp_path: Path) -> None:
    adapter = _claude_planner(executable="/nonexistent/claude")
    runtime = _runtime(tmp_path, planner_adapter=adapter, parent_env={})
    _freeze_master_plan(runtime.project_root, _master_plan_payload())
    _publish_phase_plan(runtime, _phase_payload())

    with pytest.raises(EnvironmentPolicyError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )


def test_process_launch_error_propagates_unwrapped(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist" / "claude"
    adapter = _claude_planner(executable=str(missing))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())
    _publish_phase_plan(runtime, _phase_payload())

    with pytest.raises(ProcessLaunchError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )


def test_process_timeout_error_propagates_unwrapped(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="irrelevant", sleep_seconds=5.0)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())
    _publish_phase_plan(runtime, _phase_payload())

    with pytest.raises(ProcessTimeoutError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=0.3,
        )


def test_claude_billing_mode_mismatch_propagates_unwrapped(tmp_path: Path) -> None:
    adapter = _claude_planner()
    runtime = _runtime(
        tmp_path, planner_adapter=adapter, planner_billing_mode=BillingMode.API_ALLOWED
    )
    _freeze_master_plan(runtime.project_root, _master_plan_payload())
    _publish_phase_plan(runtime, _phase_payload())

    with pytest.raises(ClaudeAdapterError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )


def test_codex_billing_mode_mismatch_propagates_unwrapped(tmp_path: Path) -> None:
    adapter = _codex_planner()
    runtime = _runtime(
        tmp_path, planner_adapter=adapter, planner_billing_mode=BillingMode.API_ALLOWED
    )
    _freeze_master_plan(runtime.project_root, _master_plan_payload())
    _publish_phase_plan(runtime, _phase_payload())

    with pytest.raises(CodexAdapterError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )


# ===========================================================================
# Required test — inference counts across outcomes (§80)
# ===========================================================================


def test_exactly_one_inference_on_success(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path)

    create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )

    assert len(_read_invocations(bin_dir)) == 1


def test_zero_inference_on_no_frozen_master_plan(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_contract_payload()
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(SubphaseContractPlanningError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == 0


def test_zero_inference_on_no_published_phase_plan(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_contract_payload()
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _master_plan_payload())

    with pytest.raises(SubphaseContractPlanningError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == 0


def test_zero_inference_on_wrong_published_phase(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    adapter = _write_provider_response(
        bin_dir, provider="claude", response_payload=_contract_payload("02", "01")
    )
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    _freeze_master_plan(runtime.project_root, _two_phase_master_plan_payload())
    _publish_phase_plan(runtime, _phase_payload("01", subphases=[_outline_payload("01")]))

    with pytest.raises(SubphaseContractPlanningError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("02"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == 0


def test_zero_inference_on_unknown_subphase(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path)

    with pytest.raises(SubphaseContractPlanningError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("99"),
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == 0


def test_zero_inference_on_active_contract(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path)
    candidate = create_subphase_contract_candidate(
        runtime, phase_id=_phase_id("01"), subphase_id=_subphase_id("01"), timeout_seconds=5.0
    )
    freeze_subphase_contract(runtime.project_root, runtime.runtime_dir, candidate.contract)

    invocation_count_before = len(_read_invocations(bin_dir))

    with pytest.raises(SubphaseContractPlanningError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == invocation_count_before


def test_one_inference_on_semantic_failure(tmp_path: Path) -> None:
    response_payload = _duplicate_criterion_response_payload("01", "01")
    runtime, bin_dir, _mp, _pp = _setup_published_phase(tmp_path, response_payload=response_payload)

    with pytest.raises(PlanningValidationError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == 1


def test_one_inference_on_wrong_phase(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(
        tmp_path, response_payload=_contract_payload("99", "01")
    )

    with pytest.raises(SubphaseContractPlanningError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == 1


def test_one_inference_on_wrong_subphase(tmp_path: Path) -> None:
    runtime, bin_dir, _mp, _pp = _setup_published_phase(
        tmp_path, response_payload=_contract_payload("01", "99")
    )

    with pytest.raises(SubphaseContractPlanningError):
        create_subphase_contract_candidate(
            runtime,
            phase_id=_phase_id("01"),
            subphase_id=_subphase_id("01"),
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Dependency / authority boundary audit (§83-85)
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


def test_create_subphase_contract_candidate_has_no_provider_import_or_switch() -> None:
    source = inspect.getsource(planning_workflow_module)
    assert "AgentProvider" not in source
    assert '"claude"' not in source
    assert "'claude'" not in source
    assert '"codex"' not in source
    assert "'codex'" not in source
