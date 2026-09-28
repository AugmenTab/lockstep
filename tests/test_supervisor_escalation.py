"""Planner-authored specification of Sub-phase 9.5 Supervisor escalation dispatch.

Pins the one provider-neutral production path from an already-produced,
structured ``EscalationRequest`` to a deterministic authority-routing
disposition:

    EscalationRequest
        -> route_escalation                         (frozen 9.1 policy)
        -> SUPERVISOR -> SUPERVISOR_ACTION_REQUIRED  (0 inference)
        -> HUMAN      -> HUMAN_REQUIRED              (0 inference)
        -> PLANNER    -> invoke_planner_decision     (frozen 9.3 transport)
                      -> PlannerDecisionResolution.disposition mapped
                         to a SupervisorEscalationDisposition

Uses the real 9.1 routing policy, the real 9.3 Planner decision
transport, the real planning store, and a real ``AgentRuntime`` against
fake provider executables under ``tmp_path``. No real Claude/Codex
account, no network, no real model inference. This module never
re-enters a blocked agent, never executes REPLAN/RUN_HALT, never
prompts a human, and never mutates persistence, Git, or FSM state --
those remain later Sub-phases' concern.
"""

from __future__ import annotations

import ast
import inspect
import json
import stat
import sys
import textwrap
from collections.abc import Mapping
from dataclasses import FrozenInstanceError, dataclass, fields
from pathlib import Path

import pytest

import lockstep.supervisor.escalation as escalation_module
from lockstep.agents import (
    AgentAdapter,
    AgentCommand,
    AgentInvocationRequest,
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
    EscalationRoute,
    route_escalation,
)
from lockstep.escalation_decision import PlannerDecisionKind
from lockstep.escalation_transport import PlannerDecisionTransportError, PlannerDecisionTurnResult
from lockstep.planning_store import freeze_master_plan, freeze_subphase_contract, publish_phase_plan
from lockstep.runtime import AgentRuntime
from lockstep.supervisor.escalation import (
    SupervisorEscalationDisposition,
    SupervisorEscalationResult,
    dispatch_escalation,
)

# ---------------------------------------------------------------------------
# Identifiers / planning-state fixtures
# ---------------------------------------------------------------------------


def _phase_id(value: str = "09") -> PhaseId:
    return PhaseId.model_validate(value)


def _subphase_id(value: str = "05") -> SubphaseId:
    return SubphaseId.model_validate(value)


def _attempt(value: int = 1) -> AttemptNumber:
    return AttemptNumber.model_validate(value)


def _master_plan(*, phase_id: str = "09", subphase_id: str = "05") -> MasterPlan:
    return MasterPlan(
        schema_version=1,
        project_id="lockstep",
        title="Lockstep",
        objective="Build the local orchestration control plane.",
        phases=[
            PhasePlan(
                schema_version=1,
                phase_id=_phase_id(phase_id),
                title="Supervisor escalation dispatch",
                objective="Dispatch structured escalations to the correct authority.",
                depends_on=[],
                subphases=[
                    SubphaseOutline(
                        subphase_id=_subphase_id(subphase_id),
                        title="Supervisor escalation dispatcher",
                        objective="Route a blocker to Supervisor/Planner/Human authority.",
                        depends_on=[],
                    )
                ],
                integration_acceptance_criteria=[],
            )
        ],
    )


def _phase_plan(*, phase_id: str = "09", subphase_id: str = "05") -> PhasePlan:
    return _master_plan(phase_id=phase_id, subphase_id=subphase_id).phases[0]


def _contract(*, phase_id: str = "09", subphase_id: str = "05") -> SubphaseContract:
    return SubphaseContract(
        schema_version=1,
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        title="Supervisor escalation dispatcher",
        objective="Route a blocker to Supervisor/Planner/Human authority.",
        acceptance_criteria=[
            AcceptanceCriterion(criterion_id="AC-1", description="Dispatch resolves.")
        ],
        tests=[
            TestSpecification(
                path="tests/test_supervisor_escalation.py",
                expectation=TestExpectation.RED,
                acceptance_criteria=["AC-1"],
            )
        ],
        allowed_paths=["src/lockstep/supervisor/escalation.py"],
        protected_paths=[],
        forbidden_paths=[],
        verification_commands=["./scripts/check"],
    )


def _freeze_planning_state(
    project_root: Path,
    runtime_dir: Path,
    *,
    phase_id: str = "09",
    subphase_id: str = "05",
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
    subphase_id: str = "05",
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
        attempt=_attempt(attempt),
        category=category,
        question=question,
        evidence=evidence,
        requested_authority=requested_authority,
    )


# ---------------------------------------------------------------------------
# CLI status / adapter fixtures (mirrors tests/test_escalation_transport.py)
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


def _claude_planner(
    *, executable: str = "/fake/claude", model: str = "planner-model"
) -> ClaudeAdapter:
    return ClaudeAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_claude_status(executable=executable),
        model=model,
        effort="high",
    )


@dataclass(frozen=True, slots=True)
class _PoisonAdapter:
    """An :class:`AgentAdapter` that fails the test if it is ever invoked.

    Stands in for the Implementer/Reviewer adapters on a Supervisor
    dispatcher's :class:`~lockstep.runtime.AgentRuntime` so any call to
    ``build_command`` proves the dispatcher tried to invoke an agent it
    has no authority to invoke.
    """

    name: str = "poison"

    def build_command(self, request: AgentInvocationRequest) -> AgentCommand:
        raise AssertionError(
            "Supervisor escalation dispatch must never invoke the Implementer/Reviewer adapter"
        )


# ---------------------------------------------------------------------------
# Fake provider executables (mirrors tests/test_escalation_transport.py)
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
    subphase_id: str = "05",
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
        planner=planner_adapter,
        implementer=_PoisonAdapter(name="poison-implementer"),
        reviewer=_PoisonAdapter(name="poison-reviewer"),
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


def _bare_runtime(tmp_path: Path, *, planner_adapter: AgentAdapter) -> AgentRuntime:
    """A runtime with zero frozen planning state at all."""
    return _runtime(
        tmp_path,
        planner_adapter=planner_adapter,
        with_master_plan=False,
        with_phase_plan=False,
        with_contract=False,
    )


# ===========================================================================
# Public API / vocabulary
# ===========================================================================


def test_public_api_subset() -> None:
    assert {
        "SupervisorEscalationDisposition",
        "SupervisorEscalationResult",
        "dispatch_escalation",
    }.issubset(set(escalation_module.__all__))


def test_disposition_enum_has_exact_members_and_values() -> None:
    members = {member.name: member.value for member in SupervisorEscalationDisposition}
    assert members == {
        "SUPERVISOR_ACTION_REQUIRED": "supervisor_action_required",
        "RESUME_AGENT": "resume_agent",
        "REPLAN_SUBPHASE": "replan_subphase",
        "HUMAN_REQUIRED": "human_required",
        "RUN_HALT": "run_halt",
    }
    forbidden_names = {"RETRY", "FAILED", "UNKNOWN", "OTHER"}
    assert forbidden_names.isdisjoint(members)


def test_dispatch_escalation_has_no_caller_supplied_authority_parameters() -> None:
    signature = inspect.signature(dispatch_escalation)
    forbidden_params = (
        "route",
        "authority",
        "provider",
        "adapter",
        "prompt",
        "planner_decision",
        "disposition",
    )
    for forbidden in forbidden_params:
        assert forbidden not in signature.parameters


# ===========================================================================
# Section 29 — result shape
# ===========================================================================


def test_result_is_frozen_slotted_with_exactly_four_fields(tmp_path: Path) -> None:
    adapter = _claude_planner()
    runtime = _bare_runtime(tmp_path, planner_adapter=adapter)
    request = _request(
        category=EscalationCategory.CONTROL_PLANE_BLOCKER,
        requested_authority=EscalationAuthority.SUPERVISOR,
    )

    result = dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert isinstance(result, SupervisorEscalationResult)
    assert {f.name for f in fields(result)} == {"request", "route", "disposition", "planner_turn"}
    assert not hasattr(result, "__dict__")

    with pytest.raises(FrozenInstanceError):
        result.disposition = result.disposition  # type: ignore[misc]


def test_planner_turn_field_is_repr_hidden(tmp_path: Path) -> None:
    sentinel = "SENTINEL-PLANNER-TURN-REPR-9c31"
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload, stderr=sentinel)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    result = dispatch_escalation(runtime, request=_request(), timeout_seconds=5.0)

    assert sentinel not in repr(result)


# ===========================================================================
# Section 30 — Supervisor route
# ===========================================================================


def test_supervisor_route_returns_action_required_with_zero_planner_inference(
    tmp_path: Path,
) -> None:
    adapter = _claude_planner()
    runtime = _bare_runtime(tmp_path, planner_adapter=adapter)
    request = _request(
        category=EscalationCategory.CONTROL_PLANE_BLOCKER,
        requested_authority=EscalationAuthority.SUPERVISOR,
    )

    result = dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert result.disposition == SupervisorEscalationDisposition.SUPERVISOR_ACTION_REQUIRED
    assert result.planner_turn is None
    assert result.route.authority == EscalationAuthority.SUPERVISOR
    assert result.request is request


# ===========================================================================
# Section 31 — Supervisor requested-authority mismatch
# ===========================================================================


def test_supervisor_route_with_human_requested_authority_mismatch(tmp_path: Path) -> None:
    adapter = _claude_planner()
    runtime = _bare_runtime(tmp_path, planner_adapter=adapter)
    request = _request(
        category=EscalationCategory.CONTROL_PLANE_BLOCKER,
        requested_authority=EscalationAuthority.HUMAN,
    )

    result = dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert result.disposition == SupervisorEscalationDisposition.SUPERVISOR_ACTION_REQUIRED
    assert result.route.authority_mismatch is True
    assert result.planner_turn is None


# ===========================================================================
# Section 32 — direct Human routes
# ===========================================================================


@pytest.mark.parametrize(
    "category",
    [
        EscalationCategory.REQUIREMENT_AMBIGUITY,
        EscalationCategory.EXTERNAL_SIDE_EFFECT_REQUIRED,
        EscalationCategory.HUMAN_AUTHORITY_REQUIRED,
    ],
)
def test_human_routed_categories_return_human_required(
    tmp_path: Path, category: EscalationCategory
) -> None:
    adapter = _claude_planner()
    runtime = _bare_runtime(tmp_path, planner_adapter=adapter)
    request = _request(category=category, requested_authority=EscalationAuthority.HUMAN)

    result = dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert result.disposition == SupervisorEscalationDisposition.HUMAN_REQUIRED
    assert result.planner_turn is None
    assert result.route.authority == EscalationAuthority.HUMAN


# ===========================================================================
# Section 33 — Human requested-authority spoof
# ===========================================================================


def test_human_route_with_planner_requested_authority_spoof(tmp_path: Path) -> None:
    adapter = _claude_planner()
    runtime = _bare_runtime(tmp_path, planner_adapter=adapter)
    request = _request(
        category=EscalationCategory.REQUIREMENT_AMBIGUITY,
        requested_authority=EscalationAuthority.PLANNER,
    )

    result = dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert result.disposition == SupervisorEscalationDisposition.HUMAN_REQUIRED
    assert result.planner_turn is None
    assert result.route.authority_mismatch is True


# ===========================================================================
# Section 34 — Planner bounded authorization
# ===========================================================================


def test_planner_bounded_authorization_resolves_to_resume_agent(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    request = _request(category=EscalationCategory.ARCHITECTURE_CONFLICT)

    result = dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert result.disposition == SupervisorEscalationDisposition.RESUME_AGENT
    assert result.planner_turn is not None
    assert isinstance(result.planner_turn, PlannerDecisionTurnResult)
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Section 35 — TEST_DEFECT frozen correction
# ===========================================================================


def test_planner_frozen_correction_resolves_and_preserves_correction_flag(
    tmp_path: Path,
) -> None:
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

    result = dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert result.disposition == SupervisorEscalationDisposition.RESUME_AGENT
    assert result.planner_turn is not None
    assert result.planner_turn.resolution.frozen_artifact_correction is True
    assert not (runtime.project_root / "tests" / "test_x.py").exists()


# ===========================================================================
# Section 36 — Architecture replan
# ===========================================================================


def test_planner_replan_resolves_to_replan_subphase_with_no_planning_mutation(
    tmp_path: Path,
) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.REPLAN_SUBPHASE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    request = _request(category=EscalationCategory.ARCHITECTURE_CONFLICT)

    contract_path = runtime.runtime_dir / "contracts" / "active.json"
    before = contract_path.read_bytes()

    result = dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    after = contract_path.read_bytes()
    assert before == after
    assert result.disposition == SupervisorEscalationDisposition.REPLAN_SUBPHASE


# ===========================================================================
# Section 37 — Planner asks Human
# ===========================================================================


def test_planner_halt_for_human_resolves_to_human_required(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.HALT_FOR_HUMAN))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    result = dispatch_escalation(runtime, request=_request(), timeout_seconds=5.0)

    assert result.disposition == SupervisorEscalationDisposition.HUMAN_REQUIRED
    assert result.planner_turn is not None
    assert result.route.authority == EscalationAuthority.PLANNER


# ===========================================================================
# Section 38 — Planner terminal halt
# ===========================================================================


def test_planner_terminal_halt_resolves_to_run_halt(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.TERMINAL_HALT))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    result = dispatch_escalation(runtime, request=_request(), timeout_seconds=5.0)

    assert result.disposition == SupervisorEscalationDisposition.RUN_HALT


# ===========================================================================
# Section 39 — requested authority mismatch still routes to Planner
# ===========================================================================


def test_test_defect_with_human_requested_authority_still_routes_planner_exactly_once(
    tmp_path: Path,
) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    request = _request(
        category=EscalationCategory.TEST_DEFECT,
        requested_authority=EscalationAuthority.HUMAN,
    )

    result = dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert result.route.authority == EscalationAuthority.PLANNER
    assert result.route.authority_mismatch is True
    assert result.disposition == SupervisorEscalationDisposition.RESUME_AGENT
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Section 40 — Planner transport failure
# ===========================================================================


def test_planner_transport_failure_propagates_unwrapped(tmp_path: Path) -> None:
    stdout_sentinel = "STDOUT-SENTINEL-do-not-leak"
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=stdout_sentinel, returncode=9)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlannerDecisionTransportError) as exc_info:
        dispatch_escalation(runtime, request=_request(), timeout_seconds=5.0)

    assert stdout_sentinel not in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Section 41 — protocol failure
# ===========================================================================


def test_planner_protocol_failure_propagates_unwrapped(tmp_path: Path) -> None:
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
        dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Section 42 — planning-state dependence is Planner-branch-only
# ===========================================================================


def test_planner_route_without_frozen_contract_raises_transport_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="unused")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter, with_contract=False)

    with pytest.raises(PlannerDecisionTransportError):
        dispatch_escalation(runtime, request=_request(), timeout_seconds=5.0)

    assert _read_invocations(bin_dir) == []


def test_supervisor_route_succeeds_without_any_frozen_planning_state(tmp_path: Path) -> None:
    adapter = _claude_planner()
    runtime = _bare_runtime(tmp_path, planner_adapter=adapter)
    request = _request(
        category=EscalationCategory.CONTROL_PLANE_BLOCKER,
        requested_authority=EscalationAuthority.SUPERVISOR,
    )

    result = dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert result.disposition == SupervisorEscalationDisposition.SUPERVISOR_ACTION_REQUIRED


def test_human_route_succeeds_without_any_frozen_planning_state(tmp_path: Path) -> None:
    adapter = _claude_planner()
    runtime = _bare_runtime(tmp_path, planner_adapter=adapter)
    request = _request(
        category=EscalationCategory.REQUIREMENT_AMBIGUITY,
        requested_authority=EscalationAuthority.HUMAN,
    )

    result = dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert result.disposition == SupervisorEscalationDisposition.HUMAN_REQUIRED


# ===========================================================================
# Section 43 — no duplicate category mapping; route_escalation is sole source
# ===========================================================================


def test_module_calls_route_escalation_exactly_once_per_dispatch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    calls: list[EscalationRequest] = []
    real_route_escalation = route_escalation

    def _wrapped(request: EscalationRequest) -> EscalationRoute:
        calls.append(request)
        return real_route_escalation(request)

    monkeypatch.setattr(escalation_module, "route_escalation", _wrapped)

    adapter = _claude_planner()
    runtime = _bare_runtime(tmp_path, planner_adapter=adapter)
    request = _request(
        category=EscalationCategory.CONTROL_PLANE_BLOCKER,
        requested_authority=EscalationAuthority.SUPERVISOR,
    )

    result = dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert calls == [request]
    assert result.route == real_route_escalation(request)


def test_module_does_not_import_escalation_category() -> None:
    source = inspect.getsource(escalation_module)
    tree = ast.parse(source)
    imported_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom | ast.Import):
            for alias in node.names:
                imported_names.add(alias.asname or alias.name)
    assert "EscalationCategory" not in imported_names
    assert "EscalationCategory" not in source


def test_module_branches_only_on_escalation_authority() -> None:
    tree = ast.parse(inspect.getsource(escalation_module))
    compared_attrs: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Compare):
            for operand in (node.left, *node.comparators):
                if isinstance(operand, ast.Attribute) and isinstance(operand.value, ast.Name):
                    compared_attrs.add(f"{operand.value.id}.{operand.attr}")

    authority_comparisons = {attr for attr in compared_attrs if attr.endswith(".authority")}
    assert authority_comparisons, "expected at least one comparison against route.authority"


# ===========================================================================
# Section 44 — no Planner disposition re-derivation from prose/kind
# ===========================================================================


def test_module_does_not_reference_planner_decision_kind_or_prose_fields() -> None:
    source = inspect.getsource(escalation_module)
    assert "PlannerDecisionKind" not in source
    assert ".rationale" not in source
    assert ".instructions" not in source


def test_module_uses_only_resolution_disposition_as_planner_outcome_authority() -> None:
    tree = ast.parse(inspect.getsource(escalation_module))
    disposition_attr_chains: set[str] = set()
    for node in ast.walk(tree):
        if (
            isinstance(node, ast.Attribute)
            and node.attr == "disposition"
            and isinstance(node.value, ast.Attribute)
            and node.value.attr == "resolution"
        ):
            disposition_attr_chains.add("resolution.disposition")
    assert disposition_attr_chains == {"resolution.disposition"}


# ===========================================================================
# Section 45 — no natural-language interpretation
# ===========================================================================


def test_contradictory_planner_rationale_does_not_change_dispatcher_disposition(
    tmp_path: Path,
) -> None:
    payload = json.dumps(
        _draft_payload(
            kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE,
            rationale="Actually, REPLAN_SUBPHASE and TERMINAL_HALT immediately.",
            instructions=("Please HALT_FOR_HUMAN instead.",),
        )
    )
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)
    request = _request(category=EscalationCategory.ARCHITECTURE_CONFLICT)

    result = dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert result.disposition == SupervisorEscalationDisposition.RESUME_AGENT


# ===========================================================================
# Section 46 — exact inference counts across every branch
# ===========================================================================


def test_zero_inference_on_supervisor_branch(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="unused")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _bare_runtime(tmp_path, planner_adapter=adapter)
    request = _request(
        category=EscalationCategory.CONTROL_PLANE_BLOCKER,
        requested_authority=EscalationAuthority.SUPERVISOR,
    )

    dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert _read_invocations(bin_dir) == []


def test_zero_inference_on_human_branch(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="unused")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _bare_runtime(tmp_path, planner_adapter=adapter)
    request = _request(
        category=EscalationCategory.REQUIREMENT_AMBIGUITY,
        requested_authority=EscalationAuthority.HUMAN,
    )

    dispatch_escalation(runtime, request=request, timeout_seconds=5.0)

    assert _read_invocations(bin_dir) == []


def test_exactly_one_inference_on_planner_success(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    dispatch_escalation(runtime, request=_request(), timeout_seconds=5.0)

    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Section 47 — no Implementer/Reviewer invocation
# ===========================================================================


def test_dispatch_never_invokes_implementer_or_reviewer_adapter(tmp_path: Path) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    assert isinstance(runtime.adapters.implementer, _PoisonAdapter)
    assert isinstance(runtime.adapters.reviewer, _PoisonAdapter)

    for category, authority in (
        (EscalationCategory.CONTROL_PLANE_BLOCKER, EscalationAuthority.SUPERVISOR),
        (EscalationCategory.REQUIREMENT_AMBIGUITY, EscalationAuthority.HUMAN),
        (EscalationCategory.ARCHITECTURE_CONFLICT, EscalationAuthority.PLANNER),
    ):
        request = _request(category=category, requested_authority=authority)
        # A _PoisonAdapter.build_command call would raise AssertionError,
        # which would fail this test outright.
        dispatch_escalation(runtime, request=request, timeout_seconds=5.0)


# ===========================================================================
# Section 48 — no human prompt
# ===========================================================================


def test_module_source_has_no_human_prompt_calls() -> None:
    tree = ast.parse(inspect.getsource(escalation_module))
    call_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            if isinstance(node.func, ast.Name):
                call_names.add(node.func.id)
            elif isinstance(node.func, ast.Attribute):
                call_names.add(node.func.attr)

    forbidden_calls = {"input", "print"}
    assert not (call_names & forbidden_calls)


# ===========================================================================
# Section 49 — no persistence/state
# ===========================================================================


def test_module_has_no_persistence_or_state_imports() -> None:
    tree = ast.parse(inspect.getsource(escalation_module))
    imported_modules: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imported_modules.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            imported_modules.add(node.module or "")

    for forbidden_prefix in ("lockstep.persistence", "lockstep.state"):
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


# ===========================================================================
# Section 50 — no Git
# ===========================================================================


def test_module_has_no_git_imports() -> None:
    tree = ast.parse(inspect.getsource(escalation_module))
    imported_modules: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                imported_modules.add(alias.name)
        elif isinstance(node, ast.ImportFrom):
            imported_modules.add(node.module or "")

    for forbidden_prefix in ("lockstep.git", "subprocess"):
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


# ===========================================================================
# Section 51 — dependency direction
# ===========================================================================

_FORBIDDEN_DISPATCH_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.agent_turn",
    "lockstep.planning_workflow",
    "lockstep.git",
    "lockstep.verification",
    "lockstep.reporting",
    "lockstep.cli",
    "lockstep.agents.claude",
    "lockstep.agents.codex",
    "lockstep.state",
    "lockstep.persistence",
    "claude",
    "codex",
    "anthropic",
    "openai",
    "subprocess",
)

_FORBIDDEN_DISPATCH_NAMES: tuple[str, ...] = (
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
    tree = ast.parse(inspect.getsource(escalation_module))
    imported_modules, imported_names = _imported_modules_and_names(tree)

    for forbidden in _FORBIDDEN_DISPATCH_NAMES:
        assert forbidden not in imported_names

    for forbidden_prefix in _FORBIDDEN_DISPATCH_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


def test_module_does_not_produce_escalation_requests() -> None:
    # 9.5 dispatches an already-produced EscalationRequest; it does not
    # produce one. Confirmed by the absence of any construction call.
    tree = ast.parse(inspect.getsource(escalation_module))
    call_names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            call_names.add(node.func.id)
    assert "EscalationRequest" not in call_names
    assert "invoke_agent_turn" not in call_names


# ===========================================================================
# Section 52 — provider neutrality
# ===========================================================================


def test_module_source_has_no_provider_conditionals() -> None:
    source = inspect.getsource(escalation_module)
    lowered = source.lower()
    assert "if provider ==" not in lowered
    assert '"claude"' not in lowered
    assert '"codex"' not in lowered
    assert "anthropic" not in lowered
    assert "openai" not in lowered


# ===========================================================================
# Attempt is read-only protocol evidence — never mutated
# ===========================================================================


def test_module_never_reads_or_mutates_request_attempt() -> None:
    tree = ast.parse(inspect.getsource(escalation_module))
    for node in ast.walk(tree):
        if isinstance(node, ast.Attribute):
            assert node.attr != "attempt"
        if isinstance(node, ast.Name):
            assert node.id != "attempt"


# ===========================================================================
# Branch invariants — identity preservation
# ===========================================================================


def test_planner_branch_preserves_exact_invoke_planner_decision_result(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    payload = json.dumps(_draft_payload(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE))
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    from lockstep.escalation_transport import invoke_planner_decision as real_invoke

    captured: list[PlannerDecisionTurnResult] = []

    def _wrapped(runtime_arg: AgentRuntime, **kwargs: object) -> PlannerDecisionTurnResult:
        turn = real_invoke(runtime_arg, **kwargs)  # type: ignore[arg-type]
        captured.append(turn)
        return turn

    monkeypatch.setattr(escalation_module, "invoke_planner_decision", _wrapped)

    result = dispatch_escalation(runtime, request=_request(), timeout_seconds=5.0)

    assert len(captured) == 1
    assert result.planner_turn is captured[0]
