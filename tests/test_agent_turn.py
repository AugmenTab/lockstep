"""Planner-authored specification of Sub-phase 9.4 structured agent blocker channel.

Pins the one provider-neutral production path from a normal Implementer
or Reviewer turn to either a plain success signal or a structured,
host-identity-bound ``EscalationRequest``:

    normal task prompt
        -> role authority preserved exactly (Implementer/Reviewer)
        -> exactly one structured inference
        -> AgentTurnReport (status + bounded blocker draft, no identity)
        -> host injects source_role/phase_id/subphase_id/attempt
        -> AgentTurnResult (COMPLETED -> no request, BLOCKED -> EscalationRequest)

Uses real production ``ClaudeAdapter``/``CodexAdapter`` instances and the
real production ``invoke_agent``/``invoke_agent_turn`` composition against
fake provider executables under ``tmp_path``. No real Claude/Codex
account, no network, no real model inference. This module never routes,
resolves, or executes a constructed ``EscalationRequest`` — that remains
a later Sub-phase's concern.
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
from pydantic import ValidationError

import lockstep.agent_turn as agent_turn_module
import lockstep.agents.role_output as role_output_module
from lockstep.agent_turn import (
    AgentBlockerDraft,
    AgentTurnError,
    AgentTurnReport,
    AgentTurnResult,
    AgentTurnStatus,
    invoke_agent_turn,
)
from lockstep.agents import (
    AgentCommand,
    AgentInvocationRequest,
    AgentProviderDiagnostics,
    AgentProviderStatuses,
    ClaudeAdapter,
    ClaudeCliStatus,
    CodexAdapter,
    CodexCliStatus,
    ResolvedAgentAdapters,
)
from lockstep.agents.role_output import RoleOutputAdapterError, prepare_structured_role_adapter
from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.config import ProjectConfig
from lockstep.domain import AgentRole, AttemptNumber, BillingMode, PhaseId, SubphaseId
from lockstep.escalation import EscalationAuthority, EscalationCategory
from lockstep.process import EnvironmentPolicyError, ProcessLaunchError, ProcessTimeoutError
from lockstep.runtime import AgentRuntime

# ---------------------------------------------------------------------------
# Identifiers
# ---------------------------------------------------------------------------


def _phase_id(value: str = "09") -> PhaseId:
    return PhaseId.model_validate(value)


def _subphase_id(value: str = "04") -> SubphaseId:
    return SubphaseId.model_validate(value)


def _attempt(value: int = 1) -> AttemptNumber:
    return AttemptNumber.model_validate(value)


# ---------------------------------------------------------------------------
# CLI status / adapter fixtures (mirrors tests/test_escalation_transport.py)
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


def _claude_adapter(
    role: AgentRole, *, executable: str, model: str = "role-model"
) -> ClaudeAdapter:
    return ClaudeAdapter(
        role=role,
        status=_healthy_claude_status(executable=executable),
        model=model,
        effort="high",
    )


def _codex_adapter(
    role: AgentRole,
    *,
    executable: str,
    model: str = "role-model",
    review_output_schema_path: Path | None = None,
) -> CodexAdapter:
    return CodexAdapter(
        role=role,
        status=_healthy_codex_status(executable=executable),
        model=model,
        reasoning_effort="high",
        review_output_schema_path=review_output_schema_path,
    )


@dataclass(frozen=True, slots=True)
class _FakeAdapter:
    """A minimal :class:`AgentAdapter` that is neither Claude nor Codex."""

    name: str = "fake"

    def build_command(self, request: AgentInvocationRequest) -> AgentCommand:
        return AgentCommand(argv=("fake", "run"), stdin_text=request.prompt)


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
    write_marker: str | None = None,
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
                "write_marker": write_marker,
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

        if config.get("write_marker"):
            marker_path = Path(os.getcwd()) / config["write_marker"]
            marker_path.write_text("partial work", encoding="utf-8")

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


# ---------------------------------------------------------------------------
# AgentRuntime construction helper
# ---------------------------------------------------------------------------


def _runtime(
    tmp_path: Path,
    *,
    implementer_adapter: object,
    reviewer_adapter: object,
    parent_env: Mapping[str, str] | None = None,
) -> AgentRuntime:
    project_root = tmp_path / "project"
    project_root.mkdir(exist_ok=True)
    runtime_dir = tmp_path / "runtime"
    runtime_dir.mkdir(exist_ok=True)

    route = AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model="unused-model",
        effort="unused-effort",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )
    policy = AgentRoutingPolicy(planner=route, implementer=route, reviewer=route)
    config = ProjectConfig(schema_version=1, routing=policy)

    diagnostics = AgentProviderDiagnostics(statuses=AgentProviderStatuses())
    adapters = ResolvedAgentAdapters(
        planner=implementer_adapter,  # type: ignore[arg-type]
        implementer=implementer_adapter,  # type: ignore[arg-type]
        reviewer=reviewer_adapter,  # type: ignore[arg-type]
    )

    if parent_env is not None:
        env: Mapping[str, str] = parent_env
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
# Report payload builders
# ---------------------------------------------------------------------------


def _completed_payload() -> dict[str, object]:
    return {"status": "completed", "blocker": None}


def _blocked_payload(
    *,
    category: EscalationCategory = EscalationCategory.PLANNER_DECISION_REQUIRED,
    question: str = "Bounded question sentinel.",
    evidence: tuple[str, ...] = ("Bounded evidence sentinel.",),
    requested_authority: EscalationAuthority = EscalationAuthority.PLANNER,
) -> dict[str, object]:
    return {
        "status": "blocked",
        "blocker": {
            "category": category.value,
            "question": question,
            "evidence": list(evidence),
            "requested_authority": requested_authority.value,
        },
    }


# ===========================================================================
# Public API surface
# ===========================================================================


def test_public_api_subset() -> None:
    assert {
        "AgentTurnStatus",
        "AgentBlockerDraft",
        "AgentTurnReport",
        "AgentTurnResult",
        "AgentTurnError",
        "invoke_agent_turn",
    }.issubset(set(agent_turn_module.__all__))


def test_agent_turn_error_carries_bounded_reason() -> None:
    error = AgentTurnError("short bounded reason")
    assert error.reason == "short bounded reason"


def test_invoke_agent_turn_has_no_provider_or_schema_parameters() -> None:
    signature = inspect.signature(invoke_agent_turn)
    for forbidden_param in (
        "provider",
        "model",
        "effort",
        "billing_mode",
        "adapter",
        "schema",
        "output_schema",
    ):
        assert forbidden_param not in signature.parameters


# ===========================================================================
# AgentTurnStatus exact vocabulary
# ===========================================================================


def test_agent_turn_status_exact_vocabulary() -> None:
    assert {member.value for member in AgentTurnStatus} == {"completed", "blocked"}


# ===========================================================================
# AgentBlockerDraft shape / bounds
# ===========================================================================


def _draft(**overrides: object) -> AgentBlockerDraft:
    fields_: dict[str, object] = {
        "category": EscalationCategory.PLANNER_DECISION_REQUIRED,
        "question": "A bounded question.",
        "evidence": ("A bounded evidence entry.",),
        "requested_authority": EscalationAuthority.PLANNER,
    }
    fields_.update(overrides)
    return AgentBlockerDraft(**fields_)  # type: ignore[arg-type]


def test_agent_blocker_draft_is_frozen_strict_with_exact_fields() -> None:
    draft = _draft()
    assert set(draft.__class__.model_fields) == {
        "category",
        "question",
        "evidence",
        "requested_authority",
    }

    with pytest.raises(ValidationError):
        AgentBlockerDraft(
            category=EscalationCategory.PLANNER_DECISION_REQUIRED,
            question="q",
            evidence=("e",),
            requested_authority=EscalationAuthority.PLANNER,
            extra_field="not allowed",  # type: ignore[call-arg]
        )

    with pytest.raises(ValidationError):
        draft.question = "mutated"  # type: ignore[misc]


def test_agent_blocker_draft_question_bounds() -> None:
    with pytest.raises(ValidationError):
        _draft(question="   ")
    with pytest.raises(ValidationError):
        _draft(question="x" * 4097)
    # Exactly at the bound must succeed.
    assert _draft(question="x" * 4096) is not None


def test_agent_blocker_draft_evidence_bounds() -> None:
    with pytest.raises(ValidationError):
        _draft(evidence=())
    with pytest.raises(ValidationError):
        _draft(evidence=tuple(f"e{i}" for i in range(33)))
    with pytest.raises(ValidationError):
        _draft(evidence=("   ",))
    with pytest.raises(ValidationError):
        _draft(evidence=("x" * 2049,))
    assert _draft(evidence=tuple(f"e{i}" for i in range(32))) is not None


# ===========================================================================
# AgentTurnReport relationship
# ===========================================================================


def test_agent_turn_report_rejects_completed_with_blocker() -> None:
    with pytest.raises(ValidationError):
        AgentTurnReport(status=AgentTurnStatus.COMPLETED, blocker=_draft())


def test_agent_turn_report_rejects_blocked_without_blocker() -> None:
    with pytest.raises(ValidationError):
        AgentTurnReport(status=AgentTurnStatus.BLOCKED, blocker=None)


def test_agent_turn_report_accepts_valid_shapes() -> None:
    completed = AgentTurnReport(status=AgentTurnStatus.COMPLETED, blocker=None)
    assert completed.blocker is None

    blocked = AgentTurnReport(status=AgentTurnStatus.BLOCKED, blocker=_draft())
    assert blocked.blocker is not None

    with pytest.raises(ValidationError):
        completed.status = AgentTurnStatus.BLOCKED  # type: ignore[misc]


def test_agent_turn_report_has_exactly_two_fields() -> None:
    assert set(AgentTurnReport.model_fields) == {"status", "blocker"}


# ===========================================================================
# Schema excludes host identity
# ===========================================================================

_FORBIDDEN_IDENTITY_KEYS: tuple[str, ...] = (
    "source_role",
    "phase_id",
    "subphase_id",
    "attempt",
    "request_digest",
)


def _assert_schema_excludes_identity(schema: dict[str, object]) -> None:
    serialized = json.dumps(schema)
    for key in _FORBIDDEN_IDENTITY_KEYS:
        assert f'"{key}"' not in serialized


def test_claude_schema_excludes_host_identity(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(_completed_payload()))
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    invoke_agent_turn(
        runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Implement the bounded change.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    argv = _read_invocations(bin_dir)[0]["argv"]
    schema_index = argv.index("--json-schema")
    schema = json.loads(argv[schema_index + 1])
    _assert_schema_excludes_identity(schema)


def test_codex_schema_excludes_host_identity(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="codex", stdout=json.dumps(_completed_payload()))
    implementer = _codex_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "codex"))
    reviewer = _codex_adapter(
        AgentRole.REVIEWER,
        executable=str(bin_dir / "codex"),
        review_output_schema_path=tmp_path / "unused-review-schema.json",
    )
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    invoke_agent_turn(
        runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Implement the bounded change.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    argv = _read_invocations(bin_dir)[0]["argv"]
    schema_index = argv.index("--output-schema")
    schema_path = Path(argv[schema_index + 1])
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    _assert_schema_excludes_identity(schema)


# ===========================================================================
# Result shape
# ===========================================================================


def test_result_is_frozen_slotted_with_exactly_three_fields(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(_completed_payload()))
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    result = invoke_agent_turn(
        runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Implement the bounded change.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    assert isinstance(result, AgentTurnResult)
    assert {f.name for f in fields(result)} == {"report", "escalation_request", "invocation"}
    assert not hasattr(result, "__dict__")

    with pytest.raises(FrozenInstanceError):
        result.report = result.report  # type: ignore[misc]


def test_invocation_field_is_repr_hidden(tmp_path: Path) -> None:
    sentinel = "SENTINEL-INVOCATION-REPR-9f31"
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_completed_payload()), stderr=sentinel
    )
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    result = invoke_agent_turn(
        runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Implement the bounded change.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    assert sentinel not in repr(result)


# ===========================================================================
# COMPLETED Implementer
# ===========================================================================


def test_completed_implementer_returns_no_escalation_request(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(_completed_payload()))
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    result = invoke_agent_turn(
        runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Implement the bounded change.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    assert result.report.status is AgentTurnStatus.COMPLETED
    assert result.report.blocker is None
    assert result.escalation_request is None
    assert result.invocation.role is AgentRole.IMPLEMENTER
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# BLOCKED Implementer / Reviewer — host identity injection
# ===========================================================================


def test_blocked_implementer_constructs_escalation_request_with_host_identity(
    tmp_path: Path,
) -> None:
    payload = _blocked_payload(
        category=EscalationCategory.ARCHITECTURE_CONFLICT,
        question="Bounded sentinel question 71ab.",
        evidence=("Bounded sentinel evidence 8c2f.",),
        requested_authority=EscalationAuthority.PLANNER,
    )
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)
    phase_id = _phase_id("11")
    subphase_id = _subphase_id("05")
    attempt = _attempt(3)

    result = invoke_agent_turn(
        runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=attempt,
        prompt="Implement the bounded change.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    assert result.report.status is AgentTurnStatus.BLOCKED
    request = result.escalation_request
    assert request is not None
    assert request.source_role is AgentRole.IMPLEMENTER
    assert request.phase_id == phase_id
    assert request.subphase_id == subphase_id
    assert request.attempt == attempt
    assert request.category == EscalationCategory.ARCHITECTURE_CONFLICT
    assert request.question == "Bounded sentinel question 71ab."
    assert request.evidence == ("Bounded sentinel evidence 8c2f.",)
    assert request.requested_authority == EscalationAuthority.PLANNER


def test_blocked_reviewer_constructs_escalation_request_with_host_identity(tmp_path: Path) -> None:
    payload = _blocked_payload(
        category=EscalationCategory.TEST_DEFECT,
        question="The frozen Contract and test evidence contradict each other.",
        evidence=("Contract line X requires A; test line Y asserts not-A.",),
        requested_authority=EscalationAuthority.PLANNER,
    )
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)
    phase_id = _phase_id("11")
    subphase_id = _subphase_id("06")
    attempt = _attempt(2)

    result = invoke_agent_turn(
        runtime,
        role=AgentRole.REVIEWER,
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=attempt,
        prompt="Review the implementation against the frozen Contract.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    request = result.escalation_request
    assert request is not None
    assert request.source_role is AgentRole.REVIEWER
    assert request.phase_id == phase_id
    assert request.subphase_id == subphase_id
    assert request.attempt == attempt
    assert request.category == EscalationCategory.TEST_DEFECT


def test_requested_authority_mismatch_is_preserved_not_corrected(tmp_path: Path) -> None:
    payload = _blocked_payload(
        category=EscalationCategory.TEST_DEFECT,
        requested_authority=EscalationAuthority.HUMAN,
    )
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    result = invoke_agent_turn(
        runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Implement the bounded change.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    assert result.escalation_request is not None
    assert result.escalation_request.category == EscalationCategory.TEST_DEFECT
    assert result.escalation_request.requested_authority == EscalationAuthority.HUMAN


def test_human_category_blocker_constructs_request(tmp_path: Path) -> None:
    payload = _blocked_payload(
        category=EscalationCategory.REQUIREMENT_AMBIGUITY,
        requested_authority=EscalationAuthority.HUMAN,
    )
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    result = invoke_agent_turn(
        runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Implement the bounded change.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    assert result.escalation_request is not None
    assert result.escalation_request.category == EscalationCategory.REQUIREMENT_AMBIGUITY


def test_control_plane_blocker_constructs_request(tmp_path: Path) -> None:
    payload = _blocked_payload(
        category=EscalationCategory.CONTROL_PLANE_BLOCKER,
        requested_authority=EscalationAuthority.SUPERVISOR,
    )
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    result = invoke_agent_turn(
        runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Implement the bounded change.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    assert result.escalation_request is not None
    assert result.escalation_request.category == EscalationCategory.CONTROL_PLANE_BLOCKER
    assert result.escalation_request.requested_authority == EscalationAuthority.SUPERVISOR


# ===========================================================================
# Model-authored identity rejected
# ===========================================================================


@pytest.mark.parametrize("field_name,value", [("phase_id", "09"), ("attempt", 9)])
def test_model_authored_identity_field_is_rejected(
    tmp_path: Path, field_name: str, value: object
) -> None:
    payload = _completed_payload()
    payload[field_name] = value
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    with pytest.raises(AgentTurnError):
        invoke_agent_turn(
            runtime,
            role=AgentRole.IMPLEMENTER,
            phase_id=_phase_id(),
            subphase_id=_subphase_id(),
            attempt=_attempt(),
            prompt="Implement the bounded change.",
            cwd=runtime.project_root,
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Planner role rejected
# ===========================================================================


def test_planner_role_rejected_with_zero_inference(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="unused")
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    with pytest.raises(AgentTurnError):
        invoke_agent_turn(
            runtime,
            role=AgentRole.PLANNER,
            phase_id=_phase_id(),
            subphase_id=_subphase_id(),
            attempt=_attempt(),
            prompt="Plan something.",
            cwd=runtime.project_root,
            timeout_seconds=5.0,
        )

    assert _read_invocations(bin_dir) == []


# ===========================================================================
# Process failure / malformed output
# ===========================================================================


@pytest.mark.parametrize("role", [AgentRole.IMPLEMENTER, AgentRole.REVIEWER])
def test_process_nonzero_raises_agent_turn_error(tmp_path: Path, role: AgentRole) -> None:
    stdout_sentinel = "STDOUT-SENTINEL-do-not-leak"
    stderr_sentinel = "STDERR-SENTINEL-do-not-leak"
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=stdout_sentinel, stderr=stderr_sentinel, returncode=7
    )
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    with pytest.raises(AgentTurnError) as exc_info:
        invoke_agent_turn(
            runtime,
            role=role,
            phase_id=_phase_id(),
            subphase_id=_subphase_id(),
            attempt=_attempt(),
            prompt="Do the bounded thing.",
            cwd=runtime.project_root,
            timeout_seconds=5.0,
        )

    assert stdout_sentinel not in exc_info.value.reason
    assert stderr_sentinel not in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1


def test_malformed_structured_output_raises_agent_turn_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="not json at all")
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    with pytest.raises(AgentTurnError) as exc_info:
        invoke_agent_turn(
            runtime,
            role=AgentRole.IMPLEMENTER,
            phase_id=_phase_id(),
            subphase_id=_subphase_id(),
            attempt=_attempt(),
            prompt="Implement the bounded change.",
            cwd=runtime.project_root,
            timeout_seconds=5.0,
        )

    assert "not json at all" not in str(exc_info.value)
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Authority preservation
# ===========================================================================


def test_claude_implementer_authority_preserved(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(_completed_payload()))
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    invoke_agent_turn(
        runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Implement the bounded change.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    argv = _read_invocations(bin_dir)[0]["argv"]
    tools_index = argv.index("--tools")
    assert argv[tools_index + 1] == "Read,Write,Edit,Glob,Grep"
    allowed_index = argv.index("--allowedTools")
    assert argv[allowed_index + 1] == "Read,Write,Edit,Glob,Grep"
    assert argv.count("--json-schema") == 1
    assert "Bash" not in " ".join(argv)


def test_claude_reviewer_authority_preserved(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    payload = _blocked_payload(category=EscalationCategory.TEST_DEFECT)
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    invoke_agent_turn(
        runtime,
        role=AgentRole.REVIEWER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Review the implementation.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    argv = _read_invocations(bin_dir)[0]["argv"]
    tools_index = argv.index("--tools")
    assert argv[tools_index + 1] == "Read,Glob,Grep"
    allowed_index = argv.index("--allowedTools")
    assert argv[allowed_index + 1] == "Read,Glob,Grep"
    assert argv.count("--json-schema") == 1
    assert "Write" not in argv
    assert "Edit" not in argv


def test_codex_implementer_authority_preserved(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="codex", stdout=json.dumps(_completed_payload()))
    implementer = _codex_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "codex"))
    reviewer = _codex_adapter(
        AgentRole.REVIEWER,
        executable=str(bin_dir / "codex"),
        review_output_schema_path=tmp_path / "unused-review-schema.json",
    )
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    invoke_agent_turn(
        runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Implement the bounded change.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    argv = _read_invocations(bin_dir)[0]["argv"]
    sandbox_index = argv.index("--sandbox")
    assert argv[sandbox_index + 1] == "workspace-write"
    assert argv.count("--output-schema") == 1


def test_codex_reviewer_authority_preserved(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    payload = _blocked_payload(category=EscalationCategory.TEST_DEFECT)
    _write_fake_provider_executable(bin_dir, name="codex", stdout=json.dumps(payload))
    implementer = _codex_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "codex"))
    reviewer = _codex_adapter(
        AgentRole.REVIEWER,
        executable=str(bin_dir / "codex"),
        review_output_schema_path=tmp_path / "unused-review-schema.json",
    )
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    invoke_agent_turn(
        runtime,
        role=AgentRole.REVIEWER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Review the implementation.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    argv = _read_invocations(bin_dir)[0]["argv"]
    sandbox_index = argv.index("--sandbox")
    assert argv[sandbox_index + 1] == "read-only"
    assert "workspace-write" not in argv
    assert argv.count("--output-schema") == 1


# ===========================================================================
# Provider-neutral result
# ===========================================================================


def test_provider_neutral_result_equal_across_claude_and_codex(tmp_path: Path) -> None:
    payload = _blocked_payload(
        category=EscalationCategory.ARCHITECTURE_CONFLICT,
        requested_authority=EscalationAuthority.PLANNER,
    )

    claude_root = tmp_path / "claude-env"
    claude_root.mkdir()
    claude_bin = claude_root / "bin"
    _write_fake_provider_executable(claude_bin, name="claude", stdout=json.dumps(payload))
    claude_impl = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(claude_bin / "claude"))
    claude_rev = _claude_adapter(AgentRole.REVIEWER, executable=str(claude_bin / "claude"))
    claude_runtime = _runtime(
        claude_root, implementer_adapter=claude_impl, reviewer_adapter=claude_rev
    )
    claude_result = invoke_agent_turn(
        claude_runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Implement the bounded change.",
        cwd=claude_runtime.project_root,
        timeout_seconds=5.0,
    )

    codex_root = tmp_path / "codex-env"
    codex_root.mkdir()
    codex_bin = codex_root / "bin"
    _write_fake_provider_executable(codex_bin, name="codex", stdout=json.dumps(payload))
    codex_impl = _codex_adapter(AgentRole.IMPLEMENTER, executable=str(codex_bin / "codex"))
    codex_rev = _codex_adapter(
        AgentRole.REVIEWER,
        executable=str(codex_bin / "codex"),
        review_output_schema_path=codex_root / "unused-review-schema.json",
    )
    codex_runtime = _runtime(codex_root, implementer_adapter=codex_impl, reviewer_adapter=codex_rev)
    codex_result = invoke_agent_turn(
        codex_runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Implement the bounded change.",
        cwd=codex_runtime.project_root,
        timeout_seconds=5.0,
    )

    assert claude_result.report == codex_result.report
    assert claude_result.escalation_request == codex_result.escalation_request
    assert claude_result.invocation.adapter_name != codex_result.invocation.adapter_name


# ===========================================================================
# Partial work retained on BLOCKED
# ===========================================================================


def test_partial_work_is_retained_on_blocked(tmp_path: Path) -> None:
    payload = _blocked_payload(category=EscalationCategory.ARCHITECTURE_CONFLICT)
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(payload), write_marker="partial-work.txt"
    )
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    result = invoke_agent_turn(
        runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Implement the bounded change.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    marker = runtime.project_root / "partial-work.txt"
    assert marker.exists()
    assert marker.read_text(encoding="utf-8") == "partial work"
    assert result.report.status is AgentTurnStatus.BLOCKED
    assert result.escalation_request is not None


# ===========================================================================
# Codex schema artifact stays external and deterministic
# ===========================================================================


def test_codex_schema_artifact_lives_outside_project_root(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="codex", stdout=json.dumps(_completed_payload()))
    implementer = _codex_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "codex"))
    reviewer = _codex_adapter(
        AgentRole.REVIEWER,
        executable=str(bin_dir / "codex"),
        review_output_schema_path=tmp_path / "unused-review-schema.json",
    )
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    invoke_agent_turn(
        runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Implement the bounded change.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    argv = _read_invocations(bin_dir)[0]["argv"]
    schema_index = argv.index("--output-schema")
    schema_path = Path(argv[schema_index + 1])
    assert schema_path.exists()
    assert schema_path.is_relative_to(runtime.runtime_dir.resolve())
    assert not schema_path.is_relative_to(runtime.project_root.resolve())


def test_codex_schema_bytes_are_deterministic_across_fresh_runtime_fixtures(
    tmp_path: Path,
) -> None:
    payload = json.dumps(_completed_payload())
    schema_bytes: list[bytes] = []
    for label in ("first", "second"):
        root = tmp_path / label
        root.mkdir()
        bin_dir = root / "bin"
        _write_fake_provider_executable(bin_dir, name="codex", stdout=payload)
        implementer = _codex_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "codex"))
        reviewer = _codex_adapter(
            AgentRole.REVIEWER,
            executable=str(bin_dir / "codex"),
            review_output_schema_path=root / "unused-review-schema.json",
        )
        runtime = _runtime(root, implementer_adapter=implementer, reviewer_adapter=reviewer)

        invoke_agent_turn(
            runtime,
            role=AgentRole.IMPLEMENTER,
            phase_id=_phase_id(),
            subphase_id=_subphase_id(),
            attempt=_attempt(),
            prompt="Implement the bounded change.",
            cwd=runtime.project_root,
            timeout_seconds=5.0,
        )

        argv = _read_invocations(bin_dir)[0]["argv"]
        schema_index = argv.index("--output-schema")
        schema_path = Path(argv[schema_index + 1])
        schema_bytes.append(schema_path.read_bytes())

    assert schema_bytes[0] == schema_bytes[1]


# ===========================================================================
# Prompt determinism / privacy
# ===========================================================================


def test_prompt_suffix_is_byte_identical_across_equivalent_fixtures(tmp_path: Path) -> None:
    payload = json.dumps(_completed_payload())
    stdins: list[str] = []
    for label in ("env-a", "env-b"):
        root = tmp_path / label
        root.mkdir()
        bin_dir = root / "bin"
        _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
        implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
        reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
        runtime = _runtime(root, implementer_adapter=implementer, reviewer_adapter=reviewer)

        invoke_agent_turn(
            runtime,
            role=AgentRole.IMPLEMENTER,
            phase_id=_phase_id(),
            subphase_id=_subphase_id(),
            attempt=_attempt(),
            prompt="Implement the bounded change.",
            cwd=runtime.project_root,
            timeout_seconds=5.0,
        )

        stdins.append(_read_invocations(bin_dir)[0]["stdin"])  # type: ignore[arg-type]

    assert stdins[0] == stdins[1]
    assert len(stdins[0]) > 0


def test_prompt_is_private_stdin_only(tmp_path: Path) -> None:
    sentinel = "SENTINEL-PROMPT-privacy-4d02"
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="codex", stdout=json.dumps(_completed_payload()))
    implementer = _codex_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "codex"))
    reviewer = _codex_adapter(
        AgentRole.REVIEWER,
        executable=str(bin_dir / "codex"),
        review_output_schema_path=tmp_path / "unused-review-schema.json",
    )
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    result = invoke_agent_turn(
        runtime,
        role=AgentRole.IMPLEMENTER,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt=f"{sentinel} do the bounded thing.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    invocation = _read_invocations(bin_dir)[0]
    assert sentinel in invocation["stdin"]  # type: ignore[operator]
    assert sentinel not in json.dumps(invocation["argv"])
    assert sentinel not in json.dumps(invocation["env"])
    assert sentinel not in repr(result)


# ===========================================================================
# Lower-layer exception transparency
# ===========================================================================


def test_environment_policy_error_propagates_unwrapped(tmp_path: Path) -> None:
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable="/nonexistent/claude")
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable="/nonexistent/claude")
    runtime = _runtime(
        tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer, parent_env={}
    )

    with pytest.raises(EnvironmentPolicyError):
        invoke_agent_turn(
            runtime,
            role=AgentRole.IMPLEMENTER,
            phase_id=_phase_id(),
            subphase_id=_subphase_id(),
            attempt=_attempt(),
            prompt="Implement the bounded change.",
            cwd=runtime.project_root,
            timeout_seconds=5.0,
        )


def test_process_launch_error_propagates_unwrapped(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist" / "claude"
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(missing))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(missing))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    with pytest.raises(ProcessLaunchError):
        invoke_agent_turn(
            runtime,
            role=AgentRole.IMPLEMENTER,
            phase_id=_phase_id(),
            subphase_id=_subphase_id(),
            attempt=_attempt(),
            prompt="Implement the bounded change.",
            cwd=runtime.project_root,
            timeout_seconds=5.0,
        )


def test_process_timeout_error_propagates_unwrapped(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="irrelevant", sleep_seconds=5.0)
    implementer = _claude_adapter(AgentRole.IMPLEMENTER, executable=str(bin_dir / "claude"))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, implementer_adapter=implementer, reviewer_adapter=reviewer)

    with pytest.raises(ProcessTimeoutError):
        invoke_agent_turn(
            runtime,
            role=AgentRole.IMPLEMENTER,
            phase_id=_phase_id(),
            subphase_id=_subphase_id(),
            attempt=_attempt(),
            prompt="Implement the bounded change.",
            cwd=runtime.project_root,
            timeout_seconds=0.3,
        )


# ===========================================================================
# Dependency / provider-neutrality boundary (agent_turn.py)
# ===========================================================================

_FORBIDDEN_AGENT_TURN_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.agents.claude",
    "lockstep.agents.codex",
    "lockstep.escalation_transport",
    "lockstep.supervisor",
    "lockstep.state",
    "lockstep.persistence",
    "lockstep.verification",
    "lockstep.reporting",
    "lockstep.cli",
    "lockstep.git",
    "subprocess",
)

_FORBIDDEN_AGENT_TURN_NAMES: tuple[str, ...] = (
    "ClaudeAdapter",
    "CodexAdapter",
    "ClaudeCliStatus",
    "CodexCliStatus",
    "AgentProvider",
    "route_escalation",
    "invoke_planner_decision",
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
    tree = ast.parse(inspect.getsource(agent_turn_module))
    imported_modules, imported_names = _imported_modules_and_names(tree)

    for forbidden in _FORBIDDEN_AGENT_TURN_NAMES:
        assert forbidden not in imported_names

    for forbidden_prefix in _FORBIDDEN_AGENT_TURN_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


def test_module_source_has_no_provider_conditionals() -> None:
    source = inspect.getsource(agent_turn_module)
    lowered = source.lower()
    assert "if provider ==" not in lowered
    assert '"claude"' not in lowered
    assert '"codex"' not in lowered


def test_module_source_has_no_execution_side_effect_calls() -> None:
    tree = ast.parse(inspect.getsource(agent_turn_module))
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
        "route_escalation",
        "invoke_planner_decision",
    }
    assert not (call_names & forbidden_calls)


# ===========================================================================
# role_output.py scope boundary
# ===========================================================================

_FORBIDDEN_ROLE_OUTPUT_NAMES: tuple[str, ...] = (
    "EscalationRequest",
    "PlannerDecision",
    "Supervisor",
    "PhasePlan",
    "SubphaseContract",
)

_FORBIDDEN_ROLE_OUTPUT_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.escalation",
    "lockstep.escalation_decision",
    "lockstep.escalation_transport",
    "lockstep.supervisor",
    "lockstep.planning",
    "lockstep.planning_store",
    "lockstep.planning_transport",
    "lockstep.agent_turn",
)


def test_role_output_module_does_not_know_escalation_or_planning_types() -> None:
    tree = ast.parse(inspect.getsource(role_output_module))
    imported_modules, imported_names = _imported_modules_and_names(tree)

    for forbidden in _FORBIDDEN_ROLE_OUTPUT_NAMES:
        assert forbidden not in imported_names

    for forbidden_prefix in _FORBIDDEN_ROLE_OUTPUT_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


# ===========================================================================
# role_output.py direct unit tests
# ===========================================================================


def test_prepare_rejects_planner_role(tmp_path: Path) -> None:
    adapter = _claude_adapter(AgentRole.PLANNER, executable="/fake/claude")
    with pytest.raises(RoleOutputAdapterError):
        prepare_structured_role_adapter(
            adapter,
            role=AgentRole.PLANNER,
            runtime_dir=tmp_path,
            schema={"type": "object", "properties": {}},
            schema_name="agent-turn-implementer",
        )


def test_prepare_rejects_role_mismatch(tmp_path: Path) -> None:
    adapter = _claude_adapter(AgentRole.IMPLEMENTER, executable="/fake/claude")
    with pytest.raises(RoleOutputAdapterError):
        prepare_structured_role_adapter(
            adapter,
            role=AgentRole.REVIEWER,
            runtime_dir=tmp_path,
            schema={"type": "object", "properties": {}},
            schema_name="agent-turn-reviewer",
        )


def test_prepare_rejects_unsupported_adapter_type(tmp_path: Path) -> None:
    with pytest.raises(RoleOutputAdapterError):
        prepare_structured_role_adapter(
            _FakeAdapter(),
            role=AgentRole.IMPLEMENTER,
            runtime_dir=tmp_path,
            schema={"type": "object", "properties": {}},
            schema_name="agent-turn-implementer",
        )
