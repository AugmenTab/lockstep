"""Planner-authored specification of Sub-phase 9.3 structured Planner decision transport.

Pins the one provider-neutral production path from a Planner-routed
``EscalationRequest`` to a validated ``PlannerDecision``:

    EscalationRequest
        -> route_escalation                       (frozen 9.1 policy)
        -> frozen MasterPlan / current PhasePlan / active SubphaseContract
        -> deterministic bounded Planner prompt
        -> exactly one read-only structured Planner inference
        -> structured decision draft (no request identity)
        -> host-injected request digest
        -> PlannerDecision
        -> resolve_planner_decision                (frozen 9.2 policy)
        -> PlannerDecisionTurnResult

Uses the real 9.1/9.2 protocol modules, the real planning store, a real
``AgentRuntime``, and the real production Claude/Codex structured-Planner
preparation against fake provider executables under ``tmp_path``. No real
Claude/Codex account, no network, no real model inference.
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

import lockstep.escalation_transport as escalation_transport_module
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
    AcceptanceCriterion,
    AgentRole,
    BillingMode,
    MasterPlan,
    PhaseId,
    PhasePlan,
    SubphaseContract,
    SubphaseId,
    SubphaseOutline,
    TestExpectation,
    TestSpecification,
)
from lockstep.escalation import (
    EscalationAuthority,
    EscalationCategory,
    EscalationProtocolError,
    EscalationRequest,
)
from lockstep.escalation_decision import (
    PlannerDecisionDisposition,
    PlannerDecisionKind,
    escalation_request_digest,
)
from lockstep.escalation_transport import (
    PlannerDecisionTransportError,
    PlannerDecisionTurnResult,
    invoke_planner_decision,
)
from lockstep.planning_store import freeze_master_plan, freeze_subphase_contract, publish_phase_plan
from lockstep.process import EnvironmentPolicyError, ProcessLaunchError, ProcessTimeoutError
from lockstep.runtime import AgentRuntime

# ---------------------------------------------------------------------------
# Identifiers / planning-state fixtures
# ---------------------------------------------------------------------------


def _phase_id(value: str = "09") -> PhaseId:
    return PhaseId.model_validate(value)


def _subphase_id(value: str = "03") -> SubphaseId:
    return SubphaseId.model_validate(value)


def _master_plan(*, phase_id: str = "09", subphase_id: str = "03") -> MasterPlan:
    return MasterPlan(
        schema_version=1,
        project_id="lockstep",
        title="Lockstep",
        objective="Build the local orchestration control plane.",
        phases=[
            PhasePlan(
                schema_version=1,
                phase_id=_phase_id(phase_id),
                title="Escalation transport",
                objective="Transport structured planner decisions.",
                depends_on=[],
                subphases=[
                    SubphaseOutline(
                        subphase_id=_subphase_id(subphase_id),
                        title="Structured planner decision transport",
                        objective="Invoke a read-only Planner turn for a bounded escalation.",
                        depends_on=[],
                    )
                ],
                integration_acceptance_criteria=[],
            )
        ],
    )


def _phase_plan(*, phase_id: str = "09", subphase_id: str = "03") -> PhasePlan:
    return _master_plan(phase_id=phase_id, subphase_id=subphase_id).phases[0]


def _contract(*, phase_id: str = "09", subphase_id: str = "03") -> SubphaseContract:
    return SubphaseContract(
        schema_version=1,
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        title="Structured planner decision transport",
        objective="Invoke a read-only Planner turn for a bounded escalation.",
        acceptance_criteria=[
            AcceptanceCriterion(criterion_id="AC-1", description="One inference resolves.")
        ],
        tests=[
            TestSpecification(
                path="tests/test_escalation_transport.py",
                expectation=TestExpectation.RED,
                acceptance_criteria=["AC-1"],
            )
        ],
        allowed_paths=["src/lockstep/escalation_transport.py"],
        protected_paths=[],
        forbidden_paths=[],
        verification_commands=["./scripts/check"],
    )


def _freeze_planning_state(
    project_root: Path,
    runtime_dir: Path,
    *,
    phase_id: str = "09",
    subphase_id: str = "03",
    with_master_plan: bool = True,
    with_phase_plan: bool = True,
    with_contract: bool = True,
) -> None:
    if not with_master_plan:
        return
    freeze_master_plan(project_root, _master_plan(phase_id=phase_id, subphase_id=subphase_id))

    if not with_phase_plan:
        return
    publish_phase_plan(
        project_root, runtime_dir, _phase_plan(phase_id=phase_id, subphase_id=subphase_id)
    )

    if not with_contract:
        return
    freeze_subphase_contract(
        project_root, runtime_dir, _contract(phase_id=phase_id, subphase_id=subphase_id)
    )


def _request(
    *,
    source_role: AgentRole = AgentRole.IMPLEMENTER,
    phase_id: str = "09",
    subphase_id: str = "03",
    attempt: int = 1,
    category: EscalationCategory = EscalationCategory.PLANNER_DECISION_REQUIRED,
    question: str = "Which of two Contract-compatible architectures should this Sub-phase use?",
    evidence: tuple[str, ...] = (
        "Both candidate architectures satisfy the frozen Contract as written.",
    ),
    requested_authority: EscalationAuthority = EscalationAuthority.PLANNER,
) -> EscalationRequest:
    return EscalationRequest(
        source_role=source_role,
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        attempt=attempt,
        category=category,
        question=question,
        evidence=evidence,
        requested_authority=requested_authority,
    )


# ---------------------------------------------------------------------------
# CLI status / adapter fixtures (mirrors tests/test_structured_planning_transport.py)
# ---------------------------------------------------------------------------


def _healthy_claude_status(
    *, executable: str = "/fake/claude", supports_json_schema: bool = True
) -> ClaudeCliStatus:
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
        supports_json_schema=supports_json_schema,
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


def _healthy_codex_status(
    *, executable: str = "/fake/codex", supports_exec_output_schema: bool = True
) -> CodexCliStatus:
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
        supports_exec_output_schema=supports_exec_output_schema,
    )


def _claude_planner(
    *, executable: str = "/fake/claude", model: str = "planner-model"
) -> ClaudeAdapter:
    return ClaudeAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_claude_status(executable=executable),
        model=model,
        effort="high",
    )


def _codex_planner(
    *, executable: str = "/fake/codex", model: str = "planner-model"
) -> CodexAdapter:
    return CodexAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_codex_status(executable=executable),
        model=model,
        reasoning_effort="high",
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
        import os
        import sys
        import time
        from pathlib import Path

        base = Path(__file__).resolve().parent
        config = json.loads((base / "{name}-response.json").read_text(encoding="utf-8"))
        args = sys.argv[1:]
        stdin_text = sys.stdin.read()

        with (base / "invocations.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(
                json.dumps(
                    {{
                        "exe": "{name}",
                        "argv": args,
                        "env": dict(os.environ),
                        "cwd": os.getcwd(),
                        "stdin": stdin_text,
                    }}
                )
                + "\\n"
            )

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


def _draft_payload(
    *,
    kind: PlannerDecisionKind,
    rationale: str = "Bounded rationale for this decision.",
    instructions: tuple[str, ...] = ("Do the bounded thing.",),
    authorized_paths: tuple[str, ...] = (),
) -> dict[str, object]:
    return {
        "kind": kind.value,
        "rationale": rationale,
        "instructions": list(instructions),
        "authorized_paths": list(authorized_paths),
    }


# ---------------------------------------------------------------------------
# AgentRuntime construction helper
# ---------------------------------------------------------------------------


def _runtime(
    tmp_path: Path,
    *,
    planner_adapter: AgentAdapter,
    parent_env: Mapping[str, str] | None = None,
    phase_id: str = "09",
    subphase_id: str = "03",
    with_master_plan: bool = True,
    with_phase_plan: bool = True,
    with_contract: bool = True,
) -> AgentRuntime:
    project_root = tmp_path / "project"
    project_root.mkdir(exist_ok=True)
    runtime_dir = tmp_path / "runtime"
    runtime_dir.mkdir(exist_ok=True)

    _freeze_planning_state(
        project_root,
        runtime_dir,
        phase_id=phase_id,
        subphase_id=subphase_id,
        with_master_plan=with_master_plan,
        with_phase_plan=with_phase_plan,
        with_contract=with_contract,
    )

    planner_route = AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model="unused-model",
        effort="unused-effort",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )
    policy = AgentRoutingPolicy(
        planner=planner_route, implementer=planner_route, reviewer=planner_route
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


def _snapshot_relative_files(root: Path) -> set[str]:
    if not root.exists():
        return set()
    return {str(path.relative_to(root)) for path in root.rglob("*") if path.is_file()}


# ===========================================================================
# Section 42 — public API / result shape
# ===========================================================================


def test_public_api_subset() -> None:
    assert {
        "PlannerDecisionTransportError",
        "PlannerDecisionTurnResult",
        "invoke_planner_decision",
    }.issubset(set(escalation_transport_module.__all__))


def test_result_is_frozen_slotted_with_exactly_three_fields(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir,
        name="claude",
        stdout=json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE)),
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    request = _request()

    result = invoke_planner_decision(runtime, request=request, timeout_seconds=5.0)

    assert isinstance(result, PlannerDecisionTurnResult)
    assert {f.name for f in fields(result)} == {"decision", "resolution", "invocation"}
    assert not hasattr(result, "__dict__")

    with pytest.raises(FrozenInstanceError):
        result.decision = result.decision  # type: ignore[misc]


def test_invocation_field_is_repr_hidden(tmp_path: Path) -> None:
    sentinel = "SENTINEL-INVOCATION-REPR-8b21"
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir,
        name="claude",
        stdout=json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE)),
        stderr=sentinel,
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    result = invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    assert sentinel not in repr(result)


# ===========================================================================
# Section 43 — non-Planner-routed requests reject before any inference
# ===========================================================================


@pytest.mark.parametrize(
    "category",
    [
        EscalationCategory.CONTROL_PLANE_BLOCKER,
        EscalationCategory.REQUIREMENT_AMBIGUITY,
        EscalationCategory.EXTERNAL_SIDE_EFFECT_REQUIRED,
        EscalationCategory.HUMAN_AUTHORITY_REQUIRED,
    ],
)
def test_non_planner_category_rejects_before_any_planning_or_provider_access(
    tmp_path: Path, category: EscalationCategory
) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="unused")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    # No planning state frozen at all — a route rejection must precede planning-store access.
    runtime = _runtime(
        tmp_path,
        planner_adapter=adapter,
        with_master_plan=False,
        with_phase_plan=False,
        with_contract=False,
    )
    request = _request(category=category, requested_authority=EscalationAuthority.PLANNER)

    with pytest.raises(PlannerDecisionTransportError):
        invoke_planner_decision(runtime, request=request, timeout_seconds=5.0)

    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Section 44 — missing planning state
# ===========================================================================


def test_missing_master_plan_yields_zero_inference(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="unused")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(
        tmp_path,
        planner_adapter=adapter,
        with_master_plan=False,
        with_phase_plan=False,
        with_contract=False,
    )

    with pytest.raises(PlannerDecisionTransportError):
        invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    assert _read_invocations(bin_dir) == []


def test_missing_phase_plan_yields_zero_inference(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="unused")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(
        tmp_path, planner_adapter=adapter, with_phase_plan=False, with_contract=False
    )

    with pytest.raises(PlannerDecisionTransportError):
        invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    assert _read_invocations(bin_dir) == []


def test_missing_contract_yields_zero_inference(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="unused")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter, with_contract=False)

    with pytest.raises(PlannerDecisionTransportError):
        invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Section 45 — identity mismatch
# ===========================================================================


def test_request_phase_mismatch_yields_zero_inference(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="unused")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter, phase_id="09")
    request = _request(phase_id="10")

    with pytest.raises(PlannerDecisionTransportError):
        invoke_planner_decision(runtime, request=request, timeout_seconds=5.0)

    assert _read_invocations(bin_dir) == []


def test_request_subphase_mismatch_yields_zero_inference(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="unused")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter, subphase_id="03")
    request = _request(subphase_id="99")

    with pytest.raises(PlannerDecisionTransportError):
        invoke_planner_decision(runtime, request=request, timeout_seconds=5.0)

    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Section 46 — deterministic prompt
# ===========================================================================


def test_prompt_is_byte_identical_across_equivalent_runtime_fixtures(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))

    stdins: list[str] = []
    for label in ("env-a", "env-b"):
        root = tmp_path / label
        root.mkdir()
        bin_dir = root / "bin"
        _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
        adapter = _claude_planner(executable=str(bin_dir / "claude"))
        runtime = _runtime(root, planner_adapter=adapter)

        invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

        invocations = _read_invocations(bin_dir)
        assert len(invocations) == 1
        stdins.append(invocations[0]["stdin"])  # type: ignore[arg-type]

    assert stdins[0] == stdins[1]
    assert len(stdins[0]) > 0


def test_prompt_contains_required_content_and_excludes_forbidden_content(
    tmp_path: Path,
) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    request = _request(
        question="A distinctive question sentinel 8f2a.",
        evidence=("A distinctive evidence sentinel 3c91.",),
    )
    digest = escalation_request_digest(request)

    invoke_planner_decision(runtime, request=request, timeout_seconds=5.0)

    prompt = _read_invocations(bin_dir)[0]["stdin"]
    assert isinstance(prompt, str)

    assert digest in prompt
    assert "A distinctive question sentinel 8f2a." in prompt
    assert "A distinctive evidence sentinel 3c91." in prompt
    assert "Escalation transport" in prompt  # phase plan title
    assert "Structured planner decision transport" in prompt  # outline/contract title
    assert "authorize_bounded_change" in prompt
    assert "replan_subphase" in prompt
    assert "halt_for_human" in prompt
    assert "terminal_halt" in prompt

    assert str(runtime.runtime_dir) not in prompt
    assert str(runtime.project_root) not in prompt
    assert "claude" not in prompt.lower()
    assert "codex" not in prompt.lower()
    assert "anthropic" not in prompt.lower()
    assert "openai" not in prompt.lower()


# ===========================================================================
# Section 47 — legal-kind prompt narrowing
# ===========================================================================


def test_architecture_conflict_prompt_does_not_advertise_frozen_correction(
    tmp_path: Path,
) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    request = _request(category=EscalationCategory.ARCHITECTURE_CONFLICT)

    invoke_planner_decision(runtime, request=request, timeout_seconds=5.0)

    prompt = _read_invocations(bin_dir)[0]["stdin"]
    assert "authorize_frozen_artifact_correction" not in prompt


def test_test_defect_prompt_advertises_frozen_correction(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    request = _request(category=EscalationCategory.TEST_DEFECT)

    invoke_planner_decision(runtime, request=request, timeout_seconds=5.0)

    prompt = _read_invocations(bin_dir)[0]["stdin"]
    assert "authorize_frozen_artifact_correction" in prompt


# ===========================================================================
# Section 48 — digest is host-injected, never model-authored
# ===========================================================================


def test_returned_decision_digest_is_exact_local_digest_not_from_model(
    tmp_path: Path,
) -> None:
    payload = _draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE)
    assert "request_digest" not in payload

    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    request = _request()

    result = invoke_planner_decision(runtime, request=request, timeout_seconds=5.0)

    assert result.decision.request_digest == escalation_request_digest(request)


def test_model_authored_digest_field_is_rejected(tmp_path: Path) -> None:
    payload = _draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE)
    payload["request_digest"] = "0" * 64
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlannerDecisionTransportError):
        invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)


# ===========================================================================
# Section 49-53 — decision outcomes
# ===========================================================================


def test_valid_bounded_authorization_resolves_to_resume_agent(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    request = _request(category=EscalationCategory.ARCHITECTURE_CONFLICT)

    result = invoke_planner_decision(runtime, request=request, timeout_seconds=5.0)

    assert result.resolution.disposition == PlannerDecisionDisposition.RESUME_AGENT
    assert result.resolution.frozen_artifact_correction is False
    assert result.invocation is not None
    assert len(_read_invocations(bin_dir)) == 1


def test_valid_frozen_correction_resolves_and_flags_correction(tmp_path: Path) -> None:
    payload = json.dumps(
        _draft_payload(
            kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
            authorized_paths=("tests/test_x.py",),
        )
    )
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    request = _request(category=EscalationCategory.TEST_DEFECT)

    result = invoke_planner_decision(runtime, request=request, timeout_seconds=5.0)

    assert result.resolution.disposition == PlannerDecisionDisposition.RESUME_AGENT
    assert result.resolution.frozen_artifact_correction is True

    assert not (runtime.project_root / "tests" / "test_x.py").exists()


def test_replan_resolves(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.REPLAN_SUBPHASE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    result = invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    assert result.resolution.disposition == PlannerDecisionDisposition.REPLAN_SUBPHASE


def test_halt_for_human_resolves(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.HALT_FOR_HUMAN))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    result = invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    assert result.resolution.disposition == PlannerDecisionDisposition.HUMAN_REQUIRED


def test_terminal_halt_resolves(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.TERMINAL_HALT))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    result = invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    assert result.resolution.disposition == PlannerDecisionDisposition.RUN_HALT


# ===========================================================================
# Section 54 — protocol-invalid structured decision
# ===========================================================================


def test_illegal_kind_for_category_raises_escalation_protocol_error(tmp_path: Path) -> None:
    payload = json.dumps(
        _draft_payload(
            kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
            authorized_paths=("tests/test_x.py",),
        )
    )
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    request = _request(category=EscalationCategory.ARCHITECTURE_CONFLICT)

    with pytest.raises(EscalationProtocolError):
        invoke_planner_decision(runtime, request=request, timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Section 55 — frozen correction missing paths
# ===========================================================================


def test_frozen_correction_with_no_authorized_paths_raises_escalation_protocol_error(
    tmp_path: Path,
) -> None:
    payload = json.dumps(
        _draft_payload(
            kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
            authorized_paths=(),
        )
    )
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    request = _request(category=EscalationCategory.TEST_DEFECT)

    with pytest.raises(EscalationProtocolError):
        invoke_planner_decision(runtime, request=request, timeout_seconds=5.0)


# ===========================================================================
# Section 56/57 — process failure / malformed output
# ===========================================================================


def test_process_nonzero_raises_transport_error(tmp_path: Path) -> None:
    stdout_sentinel = "STDOUT-SENTINEL-do-not-leak"
    stderr_sentinel = "STDERR-SENTINEL-do-not-leak"
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=stdout_sentinel, stderr=stderr_sentinel, returncode=9
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlannerDecisionTransportError) as exc_info:
        invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    assert stdout_sentinel not in exc_info.value.reason
    assert stderr_sentinel not in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1


def test_malformed_structured_output_raises_transport_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="not json at all")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlannerDecisionTransportError) as exc_info:
        invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    assert "not json at all" not in str(exc_info.value)
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Section 58/59 — Claude / Codex success
# ===========================================================================


def test_claude_structured_read_only_transport_succeeds(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    result = invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    invocation = _read_invocations(bin_dir)[0]
    argv = invocation["argv"]
    tools_index = argv.index("--tools")
    assert argv[tools_index + 1] == "Read,Glob,Grep"
    allowed_index = argv.index("--allowedTools")
    assert argv[allowed_index + 1] == "Read,Glob,Grep"
    assert "--json-schema" in argv
    assert result.invocation.adapter_name == "claude"


def test_codex_structured_read_only_transport_succeeds(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="codex", stdout=payload)
    adapter = _codex_planner(executable=str(bin_dir / "codex"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    result = invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    invocation = _read_invocations(bin_dir)[0]
    argv = invocation["argv"]
    sandbox_index = argv.index("--sandbox")
    assert argv[sandbox_index + 1] == "read-only"
    assert "workspace-write" not in argv
    assert "--output-schema" in argv
    assert result.invocation.adapter_name == "codex"


# ===========================================================================
# Section 60 — provider-neutral result
# ===========================================================================


def test_provider_neutral_result_equal_across_claude_and_codex(tmp_path: Path) -> None:
    payload = json.dumps(
        _draft_payload(
            kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
            authorized_paths=("tests/test_x.py",),
        )
    )
    request = _request(category=EscalationCategory.TEST_DEFECT)

    claude_root = tmp_path / "claude-env"
    claude_root.mkdir()
    claude_bin = claude_root / "bin"
    _write_fake_provider_executable(claude_bin, name="claude", stdout=payload)
    claude_runtime = _runtime(
        claude_root, planner_adapter=_claude_planner(executable=str(claude_bin / "claude"))
    )
    claude_result = invoke_planner_decision(claude_runtime, request=request, timeout_seconds=5.0)

    codex_root = tmp_path / "codex-env"
    codex_root.mkdir()
    codex_bin = codex_root / "bin"
    _write_fake_provider_executable(codex_bin, name="codex", stdout=payload)
    codex_runtime = _runtime(
        codex_root, planner_adapter=_codex_planner(executable=str(codex_bin / "codex"))
    )
    codex_result = invoke_planner_decision(codex_runtime, request=request, timeout_seconds=5.0)

    assert claude_result.decision == codex_result.decision
    assert claude_result.resolution.disposition == codex_result.resolution.disposition
    assert (
        claude_result.resolution.frozen_artifact_correction
        == codex_result.resolution.frozen_artifact_correction
    )
    assert claude_result.invocation.adapter_name != codex_result.invocation.adapter_name


# ===========================================================================
# Section 61 — schema excludes request_digest
# ===========================================================================


def test_claude_schema_excludes_request_digest(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    argv = _read_invocations(bin_dir)[0]["argv"]
    schema_index = argv.index("--json-schema")
    decoded_schema = json.loads(argv[schema_index + 1])
    assert "request_digest" not in decoded_schema.get("properties", {})


def test_codex_schema_excludes_request_digest(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="codex", stdout=payload)
    adapter = _codex_planner(executable=str(bin_dir / "codex"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    argv = _read_invocations(bin_dir)[0]["argv"]
    schema_index = argv.index("--output-schema")
    schema_path = Path(argv[schema_index + 1])
    decoded_schema = json.loads(schema_path.read_text(encoding="utf-8"))
    assert "request_digest" not in decoded_schema.get("properties", {})


# ===========================================================================
# Section 62/63 — planning state / repository unchanged
# ===========================================================================


def test_planning_state_is_unchanged_after_a_successful_decision_turn(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    watched = [
        runtime.project_root / ".lockstep" / "project" / "master-plan.json",
        runtime.project_root / ".lockstep" / "project" / "master-plan.md",
        runtime.runtime_dir / "planning" / "phase-plan.json",
        runtime.runtime_dir / "contracts" / "active.json",
    ]
    before = {path: path.read_bytes() for path in watched}

    invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    after = {path: path.read_bytes() for path in watched}
    assert before == after


def test_project_repository_is_unchanged_after_a_successful_decision_turn(
    tmp_path: Path,
) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    before = _snapshot_relative_files(runtime.project_root)

    invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    after = _snapshot_relative_files(runtime.project_root)
    assert before == after


# ===========================================================================
# Section 64 — Codex schema artifact stays external and deterministic
# ===========================================================================


def test_codex_schema_artifact_is_external_to_project_root(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="codex", stdout=payload)
    adapter = _codex_planner(executable=str(bin_dir / "codex"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    schema_path = (
        runtime.runtime_dir.resolve()
        / "providers"
        / "codex"
        / "planning"
        / "planner-decision.schema.json"
    )
    assert schema_path.exists()
    assert not schema_path.is_relative_to(runtime.project_root.resolve())


def test_codex_schema_bytes_are_deterministic_across_fresh_runtime_fixtures(
    tmp_path: Path,
) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))

    schema_bytes: list[bytes] = []
    for label in ("first", "second"):
        root = tmp_path / label
        root.mkdir()
        bin_dir = root / "bin"
        _write_fake_provider_executable(bin_dir, name="codex", stdout=payload)
        adapter = _codex_planner(executable=str(bin_dir / "codex"))
        runtime = _runtime(root, planner_adapter=adapter)

        invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

        schema_path = (
            runtime.runtime_dir.resolve()
            / "providers"
            / "codex"
            / "planning"
            / "planner-decision.schema.json"
        )
        schema_bytes.append(schema_path.read_bytes())

    assert schema_bytes[0] == schema_bytes[1]


# ===========================================================================
# Section 65 — prompt privacy
# ===========================================================================


def test_prompt_is_private_stdin_only(tmp_path: Path) -> None:
    sentinel = "SENTINEL-PROMPT-privacy-7d31"
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="codex", stdout=payload)
    adapter = _codex_planner(executable=str(bin_dir / "codex"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    request = _request(question=f"{sentinel} question", evidence=(f"{sentinel} evidence",))

    result = invoke_planner_decision(runtime, request=request, timeout_seconds=5.0)

    invocation = _read_invocations(bin_dir)[0]
    assert sentinel in invocation["stdin"]
    assert sentinel not in json.dumps(invocation["argv"])
    assert sentinel not in json.dumps(invocation["env"])
    assert sentinel not in repr(result)


# ===========================================================================
# Section 66 — no natural-language interpretation
# ===========================================================================


def test_contradictory_free_form_text_does_not_override_structured_kind(
    tmp_path: Path,
) -> None:
    payload = {
        "kind": PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE.value,
        "rationale": "Bounded rationale.",
        "instructions": ["Do the bounded thing."],
        "authorized_paths": [],
    }
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir,
        name="claude",
        stdout=json.dumps(payload),
        stderr="I actually think we should HALT_FOR_HUMAN and TERMINAL_HALT immediately.",
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    result = invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    assert result.resolution.disposition == PlannerDecisionDisposition.RESUME_AGENT


# ===========================================================================
# Section 67 — exact one-inference count
# ===========================================================================


def test_exactly_one_inference_on_success(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 1


def test_zero_inference_on_preflight_failure(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="unused")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter, with_contract=False)

    with pytest.raises(PlannerDecisionTransportError):
        invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    assert _read_invocations(bin_dir) == []


def test_exactly_one_inference_on_malformed_output_no_retry(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="garbage")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlannerDecisionTransportError):
        invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Section — lower-layer exception transparency
# ===========================================================================


def test_environment_policy_error_propagates_unwrapped(tmp_path: Path) -> None:
    adapter = _claude_planner(executable="/nonexistent/claude")
    runtime = _runtime(tmp_path, planner_adapter=adapter, parent_env={})

    with pytest.raises(EnvironmentPolicyError):
        invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)


def test_process_launch_error_propagates_unwrapped(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist" / "claude"
    adapter = _claude_planner(executable=str(missing))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(ProcessLaunchError):
        invoke_planner_decision(runtime, request=_request(), timeout_seconds=5.0)


def test_process_timeout_error_propagates_unwrapped(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="irrelevant", sleep_seconds=5.0)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(ProcessTimeoutError):
        invoke_planner_decision(runtime, request=_request(), timeout_seconds=0.3)


# ===========================================================================
# Section 68 — dependency boundary
# ===========================================================================

_FORBIDDEN_TRANSPORT_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.agents.claude",
    "lockstep.agents.codex",
    "claude",
    "codex",
    "anthropic",
    "openai",
    "lockstep.supervisor",
    "lockstep.state",
    "lockstep.persistence",
    "lockstep.verification",
    "lockstep.reporting",
    "lockstep.cli",
    "lockstep.git",
    "subprocess",
)

_FORBIDDEN_TRANSPORT_NAMES: tuple[str, ...] = (
    "ClaudeAdapter",
    "CodexAdapter",
    "ClaudeCliStatus",
    "CodexCliStatus",
    "AgentProvider",
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
    tree = ast.parse(inspect.getsource(escalation_transport_module))
    imported_modules, imported_names = _imported_modules_and_names(tree)

    for forbidden in _FORBIDDEN_TRANSPORT_NAMES:
        assert forbidden not in imported_names

    for forbidden_prefix in _FORBIDDEN_TRANSPORT_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


# ===========================================================================
# Section 69 — no provider-name branching
# ===========================================================================


def test_module_source_has_no_provider_conditionals() -> None:
    source = inspect.getsource(escalation_transport_module)
    lowered = source.lower()
    assert "if provider ==" not in lowered
    assert '"claude"' not in lowered
    assert '"codex"' not in lowered


# ===========================================================================
# Section 70 — no execution semantics
# ===========================================================================


def test_module_source_has_no_execution_side_effect_calls() -> None:
    tree = ast.parse(inspect.getsource(escalation_transport_module))
    call_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            if isinstance(node.func, ast.Name):
                call_names.add(node.func.id)
            elif isinstance(node.func, ast.Attribute):
                call_names.add(node.func.attr)

    forbidden_calls = {
        "input",
        "commit",
        "reset",
        "resume",
        "system",
        "popen",
    }
    assert not (call_names & forbidden_calls)


def test_module_does_not_call_planning_mutation_apis() -> None:
    tree = ast.parse(inspect.getsource(escalation_transport_module))
    call_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            call_names.add(node.func.id)

    for forbidden in ("freeze_master_plan", "publish_phase_plan", "freeze_subphase_contract"):
        assert forbidden not in call_names


# ===========================================================================
# Public API surface sanity
# ===========================================================================


def test_transport_error_carries_bounded_reason() -> None:
    error = PlannerDecisionTransportError("short bounded reason")
    assert error.reason == "short bounded reason"


def test_invoke_planner_decision_has_no_provider_or_schema_parameters() -> None:
    signature = inspect.signature(invoke_planner_decision)
    for forbidden_param in ("provider", "model", "effort", "billing_mode", "adapter", "prompt"):
        assert forbidden_param not in signature.parameters
