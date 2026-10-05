"""Shared scripted-provider support for the Phase 12.5 evaluation-harness tests.

Every provider here is a recording fake executable behind the production
``ClaudeAdapter`` (the same pattern the canonical project-run tests use), bound into
a production :class:`~lockstep.runtime.AgentRuntime` from the fixture repository's
own tracked ``lockstep.toml``. No real Claude/Codex account, network or model call
is involved. The per-trial executables live inside the trial's own directory, so
scripted state (call counters, recorded prompts) is isolated per trial exactly like
the repository state is.
"""

from __future__ import annotations

import json
from collections.abc import Callable
from pathlib import Path

from test_canonical_project_run import (
    _EXECUTION,
    _contract_response,
    _review,
    _write_recording_claude,
)
from test_project_orchestrator import _impl_source, _phase_plan, _tests_response
from test_supervisor_resume_execution import _healthy_claude_status, _invocation_count, _parent_env

from lockstep.agents import (
    AgentProviderDiagnostics,
    AgentProviderStatuses,
    ClaudeAdapter,
    ResolvedAgentAdapters,
)
from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.config import load_project_config
from lockstep.domain import AgentRole, BillingMode, MasterPlan, ProjectId
from lockstep.escalation import EscalationAuthority, EscalationCategory
from lockstep.evaluation.cases import EvalFixture
from lockstep.evaluation.harness import EvalRuntimeSelection, EvalTrialPlacement
from lockstep.runtime import AgentRuntime

Scripts = dict[str, list[dict[str, object]]]
ScriptChooser = Callable[[EvalTrialPlacement], Scripts]

ROLES: tuple[str, ...] = ("planner", "implementer", "reviewer")
_AGENT_ROLES = {
    "planner": AgentRole.PLANNER,
    "implementer": AgentRole.IMPLEMENTER,
    "reviewer": AgentRole.REVIEWER,
}

FEATURE = {"feature_01.py": _impl_source("01")}
WRONG_FEATURE = {"feature_01.py": "def answer() -> int:\n    return 99\n"}


def route(model: str = "eval-model", effort: str = "eval-effort") -> AgentRoleRoute:
    return AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model=model,
        effort=effort,
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )


ROUTING = AgentRoutingPolicy(planner=route(), implementer=route(), reviewer=route())


def master_plan() -> MasterPlan:
    return MasterPlan(
        project_id=ProjectId.model_validate("lockstep"),
        title="Lockstep",
        objective="Build the control plane.",
        phases=(_phase_plan(("01",)),),
    )


def fixture(files: dict[str, str] | None = None) -> EvalFixture:
    return EvalFixture(
        files={"README.md": "eval fixture\n", **(files or {})},
        master_plan=master_plan(),
        execution=_EXECUTION,
    )


def planner_script(allowed_paths: list[str]) -> list[dict[str, object]]:
    """One Sub-phase: the Contract (with *allowed_paths*), then the authored red test."""
    return [_contract_response("01", allowed_paths=allowed_paths), _tests_response("01")]


def implementer_response(files: dict[str, str]) -> dict[str, object]:
    report = {
        "summary": "Implemented the Contract.",
        "changed_files": sorted(files),
        "deviations": [],
    }
    return {
        "stdout": json.dumps(
            {"status": "completed", "implementation_report": report, "blocker": None}
        ),
        "returncode": 0,
        "files": files,
    }


def blocked_response() -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "status": "blocked",
                "blocker": {
                    "category": EscalationCategory.REQUIREMENT_AMBIGUITY.value,
                    "question": "Which of the two documented behaviors is required?",
                    "evidence": ["The objective names two incompatible behaviors."],
                    "requested_authority": EscalationAuthority.HUMAN.value,
                },
            }
        ),
        "returncode": 0,
    }


def provider_crash_response() -> dict[str, object]:
    return {"stdout": "", "stderr": "scripted provider crash", "returncode": 1}


def approve() -> dict[str, object]:
    return _review("01", attempt=1, verdict="approve")


def scripts(implementer: dict[str, object], *, allowed_paths: list[str] | None = None) -> Scripts:
    return {
        "planner": planner_script(allowed_paths or ["feature_01.py"]),
        "implementer": [implementer],
        "reviewer": [approve()],
    }


def scripted_selection(
    choose: ScriptChooser,
    *,
    routing: AgentRoutingPolicy = ROUTING,
    tamper: Callable[[AgentRuntime], AgentRuntime] | None = None,
) -> EvalRuntimeSelection:
    """A provider selection whose adapters run scripted fake executables.

    The runtime's routing is loaded from the fixture's tracked ``lockstep.toml``
    (written by the harness from the requested selection), and each role's adapter is
    built from its own route, the way production resolution builds it.
    """

    def bind(placement: EvalTrialPlacement) -> AgentRuntime:
        config = load_project_config(placement.project_root)
        responses = choose(placement)
        routes = {
            "planner": config.routing.planner,
            "implementer": config.routing.implementer,
            "reviewer": config.routing.reviewer,
        }
        adapters: dict[str, ClaudeAdapter] = {}
        for role in ROLES:
            bin_dir = provider_bin(placement.trial_root, role)
            executable = _write_recording_claude(
                bin_dir, name=f"claude-{role}", responses=responses[role]
            )
            adapters[role] = ClaudeAdapter(
                role=_AGENT_ROLES[role],
                status=_healthy_claude_status(executable=str(executable)),
                model=routes[role].model,
                effort=routes[role].effort,
            )
        runtime = AgentRuntime(
            project_root=placement.project_root,
            runtime_dir=placement.runtime_dir,
            config=config,
            diagnostics=AgentProviderDiagnostics(statuses=AgentProviderStatuses()),
            adapters=ResolvedAgentAdapters(
                planner=adapters["planner"],
                implementer=adapters["implementer"],
                reviewer=adapters["reviewer"],
            ),
            transaction_parent_env=_parent_env(placement.trial_root),
        )
        return tamper(runtime) if tamper is not None else runtime

    return EvalRuntimeSelection(routing=routing, bind_runtime=bind)


def provider_bin(trial_root: Path, role: str) -> Path:
    return trial_root / "provider" / role


def launches(trial_root: Path, role: str) -> int:
    return _invocation_count(provider_bin(trial_root, role), f"claude-{role}")


def recorded_prompts(trial_root: Path, role: str) -> list[str]:
    return [
        (provider_bin(trial_root, role) / f"claude-{role}-prompt-{index}.txt").read_text(
            encoding="utf-8"
        )
        for index in range(launches(trial_root, role))
    ]
