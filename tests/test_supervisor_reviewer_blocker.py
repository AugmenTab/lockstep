"""Planner-authored specification of Sub-phase 9.7 Reviewer decision/blocker composition.

Pins the one additive, provider-neutral production path that unifies the
Reviewer's two structured-output needs -- deciding whether it can
complete a review at all, and (when it can) producing the normal
``ReviewDecision`` -- into exactly one structured Reviewer inference,
and integrates that composite Reviewer turn into the blocker-aware
Supervisor transaction:

    Planner-authored tests already frozen
        -> IMPLEMENTING -> invoke_agent_turn(IMPLEMENTER) -> COMPLETED
        -> VERIFYING -> REVIEWING
        -> invoke_reviewer_turn(REVIEWER)
        -> COMPLETED + ReviewDecision -> existing verdict handling / commit
        -> BLOCKED + AgentBlockerDraft -> dispatch_escalation -> HALTED

Uses real production ``ClaudeAdapter``/``CodexAdapter`` instances against
fake provider executables under ``tmp_path``, a real Git worktree, and a
real planning store for the Planner-routed escalation scenarios. No real
Claude/Codex account, no network, no real model inference. This module
never edits the frozen legacy ``run_single_subphase_transaction``
entrypoint's behavior, which keeps invoking the Reviewer through the old
raw ``invoke_agent``/``ReviewDecision`` contract unchanged.
"""

from __future__ import annotations

import ast
import inspect
import json
import stat
import subprocess
import sys
import textwrap
from collections.abc import Mapping
from dataclasses import FrozenInstanceError, dataclass, fields
from pathlib import Path

import pytest
from pydantic import ValidationError

import lockstep.reviewer_turn as reviewer_turn_module
import lockstep.supervisor.transaction as transaction_module
from lockstep.agent_turn import AgentBlockerDraft, AgentTurnResult, AgentTurnStatus
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
    AttemptNumber,
    BillingMode,
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    ReviewDecision,
    RunId,
    SubphaseContract,
    SubphaseId,
    SubphaseOutline,
    TestExpectation,
    TestSpecification,
)
from lockstep.escalation import EscalationAuthority, EscalationCategory
from lockstep.escalation_decision import PlannerDecisionKind
from lockstep.escalation_transport import PlannerDecisionTransportError
from lockstep.git import inspect_repository
from lockstep.persistence import StateTransitionedEvent, read_events, read_state
from lockstep.planning_store import freeze_master_plan, freeze_subphase_contract, publish_phase_plan
from lockstep.reviewer_turn import (
    ReviewerTurnError,
    ReviewerTurnReport,
    ReviewerTurnResult,
    invoke_reviewer_turn,
)
from lockstep.runtime import AgentRuntime
from lockstep.state import WorkflowState
from lockstep.supervisor.escalation import SupervisorEscalationDisposition
from lockstep.supervisor.transaction import (
    ReviewerBlockedTransactionResult,
    SingleSubphaseTransactionRequest,
    SingleSubphaseTransactionResult,
    SupervisorTransactionError,
    run_single_subphase_transaction_with_blockers,
)

_PHASE_ID = "09"
_SUBPHASE_ID = "07"

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


# ---------------------------------------------------------------------------
# Identifiers
# ---------------------------------------------------------------------------


def _phase_id(value: str = _PHASE_ID) -> PhaseId:
    return PhaseId.model_validate(value)


def _subphase_id(value: str = _SUBPHASE_ID) -> SubphaseId:
    return SubphaseId.model_validate(value)


def _attempt(value: int = 1) -> AttemptNumber:
    return AttemptNumber.model_validate(value)


# ---------------------------------------------------------------------------
# CLI status / adapter fixtures (mirrors tests/test_agent_turn.py)
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


# ---------------------------------------------------------------------------
# Single-shot fake provider executable (mirrors tests/test_agent_turn.py) --
# used for direct invoke_reviewer_turn unit tests (schema/authority/error).
# ---------------------------------------------------------------------------


def _write_fake_provider_executable(
    bin_dir: Path,
    *,
    name: str,
    stdout: str = "",
    stderr: str = "",
    returncode: int = 0,
) -> Path:
    bin_dir.mkdir(parents=True, exist_ok=True)
    executable = bin_dir / name
    config_path = bin_dir / f"{name}-response.json"
    config_path.write_text(
        json.dumps({"stdout": stdout, "stderr": stderr, "returncode": returncode}),
        encoding="utf-8",
    )

    script = textwrap.dedent(
        f"""\
        #!{sys.executable}
        import json
        import os
        import sys
        from pathlib import Path

        base = Path(__file__).resolve().parent
        config = json.loads((base / "{name}-response.json").read_text(encoding="utf-8"))
        args = sys.argv[1:]
        stdin_text = sys.stdin.read()

        record = {{"exe": "{name}", "argv": args, "cwd": os.getcwd(), "stdin": stdin_text}}
        with (base / "invocations.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record) + "\\n")

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


def _bare_runtime(
    tmp_path: Path,
    *,
    reviewer_adapter: object,
    implementer_adapter: object | None = None,
) -> AgentRuntime:
    project_root = tmp_path / "bare-project"
    project_root.mkdir(exist_ok=True)
    runtime_dir = tmp_path / "bare-runtime"
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
    filler = implementer_adapter if implementer_adapter is not None else reviewer_adapter
    adapters = ResolvedAgentAdapters(
        planner=filler,  # type: ignore[arg-type]
        implementer=filler,  # type: ignore[arg-type]
        reviewer=reviewer_adapter,  # type: ignore[arg-type]
    )

    home_dir = tmp_path / "bare-home"
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


def _review_decision_payload(
    *,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
    attempt: int = 1,
    verdict: str = "approve",
    summary: str = "approved",
) -> dict[str, object]:
    return {
        "schema_version": 1,
        "phase_id": phase_id,
        "subphase_id": subphase_id,
        "attempt": attempt,
        "verdict": verdict,
        "summary": summary,
        "findings": [],
    }


def _completed_payload(**review_overrides: object) -> dict[str, object]:
    return {
        "status": "completed",
        "review_decision": _review_decision_payload(**review_overrides),
        "blocker": None,
    }


def _blocked_payload(
    *,
    category: EscalationCategory = EscalationCategory.PLANNER_DECISION_REQUIRED,
    question: str = "Bounded question sentinel.",
    evidence: tuple[str, ...] = ("Bounded evidence sentinel.",),
    requested_authority: EscalationAuthority = EscalationAuthority.PLANNER,
) -> dict[str, object]:
    return {
        "status": "blocked",
        "review_decision": None,
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
        "ReviewerTurnReport",
        "ReviewerTurnResult",
        "ReviewerTurnError",
        "invoke_reviewer_turn",
    }.issubset(set(reviewer_turn_module.__all__))


def test_reviewer_turn_error_carries_bounded_reason() -> None:
    error = ReviewerTurnError("short bounded reason")
    assert error.reason == "short bounded reason"


def test_invoke_reviewer_turn_has_no_provider_or_schema_parameters() -> None:
    signature = inspect.signature(invoke_reviewer_turn)
    for forbidden_param in (
        "role",
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
# ReviewerTurnReport composite model (section 51)
# ===========================================================================


def _blocker(**overrides: object) -> AgentBlockerDraft:
    fields_: dict[str, object] = {
        "category": EscalationCategory.PLANNER_DECISION_REQUIRED,
        "question": "A bounded question.",
        "evidence": ("A bounded evidence entry.",),
        "requested_authority": EscalationAuthority.PLANNER,
    }
    fields_.update(overrides)
    return AgentBlockerDraft(**fields_)  # type: ignore[arg-type]


def _review_decision(**overrides: object) -> ReviewDecision:
    fields_: dict[str, object] = _review_decision_payload()
    fields_.update(overrides)
    return ReviewDecision(**fields_)  # type: ignore[arg-type]


def test_reviewer_turn_report_accepts_completed_with_review_decision_no_blocker() -> None:
    report = ReviewerTurnReport(
        status=AgentTurnStatus.COMPLETED, review_decision=_review_decision(), blocker=None
    )
    assert report.status is AgentTurnStatus.COMPLETED
    assert report.blocker is None
    assert report.review_decision is not None


def test_reviewer_turn_report_accepts_blocked_with_blocker_no_review_decision() -> None:
    report = ReviewerTurnReport(
        status=AgentTurnStatus.BLOCKED, review_decision=None, blocker=_blocker()
    )
    assert report.status is AgentTurnStatus.BLOCKED
    assert report.review_decision is None
    assert report.blocker is not None


def test_reviewer_turn_report_rejects_completed_without_review_decision() -> None:
    with pytest.raises(ValidationError):
        ReviewerTurnReport(status=AgentTurnStatus.COMPLETED, review_decision=None, blocker=None)


def test_reviewer_turn_report_rejects_completed_with_blocker() -> None:
    with pytest.raises(ValidationError):
        ReviewerTurnReport(
            status=AgentTurnStatus.COMPLETED,
            review_decision=_review_decision(),
            blocker=_blocker(),
        )


def test_reviewer_turn_report_rejects_blocked_with_review_decision() -> None:
    with pytest.raises(ValidationError):
        ReviewerTurnReport(
            status=AgentTurnStatus.BLOCKED,
            review_decision=_review_decision(),
            blocker=_blocker(),
        )


def test_reviewer_turn_report_rejects_blocked_without_blocker() -> None:
    with pytest.raises(ValidationError):
        ReviewerTurnReport(status=AgentTurnStatus.BLOCKED, review_decision=None, blocker=None)


def test_reviewer_turn_report_rejects_unknown_field() -> None:
    with pytest.raises(ValidationError):
        ReviewerTurnReport(
            status=AgentTurnStatus.COMPLETED,
            review_decision=_review_decision(),
            blocker=None,
            extra_field="nope",  # type: ignore[call-arg]
        )


def test_reviewer_turn_report_is_frozen() -> None:
    report = ReviewerTurnReport(
        status=AgentTurnStatus.COMPLETED, review_decision=_review_decision(), blocker=None
    )
    with pytest.raises(ValidationError):
        report.status = AgentTurnStatus.BLOCKED  # type: ignore[misc]


def test_reviewer_turn_report_has_exactly_three_fields() -> None:
    assert set(ReviewerTurnReport.model_fields) == {"status", "review_decision", "blocker"}


# ===========================================================================
# Composite schema shape / host identity (section 52)
# ===========================================================================

_FORBIDDEN_BLOCKER_IDENTITY_KEYS: tuple[str, ...] = (
    "source_role",
    "phase_id",
    "subphase_id",
    "attempt",
    "request_digest",
)


def _assert_blocker_def_excludes_identity(schema: dict[str, object]) -> None:
    defs = schema.get("$defs")
    assert isinstance(defs, dict)
    blocker_def = defs.get("AgentBlockerDraft")
    assert isinstance(blocker_def, dict)
    properties = blocker_def.get("properties")
    assert isinstance(properties, dict)
    assert set(properties) == {"category", "question", "evidence", "requested_authority"}
    for key in _FORBIDDEN_BLOCKER_IDENTITY_KEYS:
        assert key not in properties


def test_canonical_schema_has_status_review_decision_blocker() -> None:
    schema = ReviewerTurnReport.model_json_schema()
    assert set(schema["properties"]) == {"status", "review_decision", "blocker"}


def test_canonical_schema_blocker_def_excludes_host_identity() -> None:
    schema = ReviewerTurnReport.model_json_schema()
    _assert_blocker_def_excludes_identity(schema)


def test_claude_reviewer_schema_has_exactly_one_schema_flag(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(_completed_payload()))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _bare_runtime(tmp_path, reviewer_adapter=reviewer)

    invoke_reviewer_turn(
        runtime,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Review the implementation.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    argv = _read_invocations(bin_dir)[0]["argv"]
    assert argv.count("--json-schema") == 1
    schema_index = argv.index("--json-schema")
    schema = json.loads(argv[schema_index + 1])
    assert set(schema["properties"]) == {"status", "review_decision", "blocker"}
    _assert_blocker_def_excludes_identity(schema)


def test_codex_reviewer_schema_has_exactly_one_schema_flag(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="codex", stdout=json.dumps(_completed_payload()))
    reviewer = _codex_adapter(
        AgentRole.REVIEWER,
        executable=str(bin_dir / "codex"),
        review_output_schema_path=tmp_path / "unused-review-schema.json",
    )
    runtime = _bare_runtime(tmp_path, reviewer_adapter=reviewer)

    invoke_reviewer_turn(
        runtime,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Review the implementation.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    argv = _read_invocations(bin_dir)[0]["argv"]
    assert argv.count("--output-schema") == 1
    schema_index = argv.index("--output-schema")
    schema_path = Path(argv[schema_index + 1])
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    assert set(schema["properties"]) == {"status", "review_decision", "blocker"}
    _assert_blocker_def_excludes_identity(schema)


# ===========================================================================
# Authority preservation (section 53)
# ===========================================================================


def test_claude_reviewer_authority_preserved_by_invoke_reviewer_turn(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir,
        name="claude",
        stdout=json.dumps(_blocked_payload(category=EscalationCategory.TEST_DEFECT)),
    )
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _bare_runtime(tmp_path, reviewer_adapter=reviewer)

    invoke_reviewer_turn(
        runtime,
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
    assert "Write" not in argv
    assert "Edit" not in argv


def test_codex_reviewer_authority_preserved_by_invoke_reviewer_turn(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir,
        name="codex",
        stdout=json.dumps(_blocked_payload(category=EscalationCategory.TEST_DEFECT)),
    )
    reviewer = _codex_adapter(
        AgentRole.REVIEWER,
        executable=str(bin_dir / "codex"),
        review_output_schema_path=tmp_path / "unused-review-schema.json",
    )
    runtime = _bare_runtime(tmp_path, reviewer_adapter=reviewer)

    invoke_reviewer_turn(
        runtime,
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


# ===========================================================================
# Result shape / host identity injection (direct unit level)
# ===========================================================================


def test_result_is_frozen_slotted_with_exactly_three_fields(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(_completed_payload()))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _bare_runtime(tmp_path, reviewer_adapter=reviewer)

    result = invoke_reviewer_turn(
        runtime,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Review the implementation.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    assert isinstance(result, ReviewerTurnResult)
    assert {f.name for f in fields(result)} == {"report", "escalation_request", "invocation"}
    assert not hasattr(result, "__dict__")

    with pytest.raises(FrozenInstanceError):
        result.report = result.report  # type: ignore[misc]


def test_invocation_field_is_repr_hidden(tmp_path: Path) -> None:
    sentinel = "SENTINEL-REVIEWER-INVOCATION-REPR-9f31"
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_completed_payload()), stderr=sentinel
    )
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _bare_runtime(tmp_path, reviewer_adapter=reviewer)

    result = invoke_reviewer_turn(
        runtime,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Review the implementation.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    assert sentinel not in repr(result)


def test_completed_reviewer_returns_no_escalation_request(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(_completed_payload()))
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _bare_runtime(tmp_path, reviewer_adapter=reviewer)

    result = invoke_reviewer_turn(
        runtime,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Review the implementation.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    assert result.escalation_request is None
    assert result.report.status is AgentTurnStatus.COMPLETED
    assert result.report.review_decision is not None


def test_blocked_reviewer_constructs_escalation_request_with_host_identity(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir,
        name="claude",
        stdout=json.dumps(_blocked_payload(category=EscalationCategory.ARCHITECTURE_CONFLICT)),
    )
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _bare_runtime(tmp_path, reviewer_adapter=reviewer)

    result = invoke_reviewer_turn(
        runtime,
        phase_id=_phase_id(),
        subphase_id=_subphase_id(),
        attempt=_attempt(),
        prompt="Review the implementation.",
        cwd=runtime.project_root,
        timeout_seconds=5.0,
    )

    assert result.escalation_request is not None
    request = result.escalation_request
    assert request.source_role is AgentRole.REVIEWER
    assert request.phase_id == _phase_id()
    assert request.subphase_id == _subphase_id()
    assert request.attempt == _attempt()
    assert request.category is EscalationCategory.ARCHITECTURE_CONFLICT


# ===========================================================================
# Malformed / failed Reviewer turn (unit level; sections 21, 22, 64, 65)
# ===========================================================================


def test_malformed_reviewer_output_raises_reviewer_turn_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="not json at all")
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _bare_runtime(tmp_path, reviewer_adapter=reviewer)

    with pytest.raises(ReviewerTurnError) as exc_info:
        invoke_reviewer_turn(
            runtime,
            phase_id=_phase_id(),
            subphase_id=_subphase_id(),
            attempt=_attempt(),
            prompt="Review the implementation.",
            cwd=runtime.project_root,
            timeout_seconds=5.0,
        )

    assert "not json at all" not in str(exc_info.value)
    assert len(_read_invocations(bin_dir)) == 1


def test_reviewer_process_nonzero_raises_reviewer_turn_error(tmp_path: Path) -> None:
    stdout_sentinel = "STDOUT-SENTINEL-do-not-leak"
    stderr_sentinel = "STDERR-SENTINEL-do-not-leak"
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=stdout_sentinel, stderr=stderr_sentinel, returncode=7
    )
    reviewer = _claude_adapter(AgentRole.REVIEWER, executable=str(bin_dir / "claude"))
    runtime = _bare_runtime(tmp_path, reviewer_adapter=reviewer)

    with pytest.raises(ReviewerTurnError) as exc_info:
        invoke_reviewer_turn(
            runtime,
            phase_id=_phase_id(),
            subphase_id=_subphase_id(),
            attempt=_attempt(),
            prompt="Review the implementation.",
            cwd=runtime.project_root,
            timeout_seconds=5.0,
        )

    assert stdout_sentinel not in exc_info.value.reason
    assert stderr_sentinel not in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# reviewer_turn.py import-cycle prerequisite (sections 12, 70)
# ===========================================================================


def test_reviewer_turn_module_has_no_runtime_import() -> None:
    tree = ast.parse(inspect.getsource(reviewer_turn_module))
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                assert alias.name != "lockstep.runtime"
                assert not alias.name.startswith("lockstep.runtime.")
        elif isinstance(node, ast.ImportFrom):
            module = node.module or ""
            assert module != "lockstep.runtime"
            assert not module.startswith("lockstep.runtime.")


def test_import_cycle_smoke_across_orders() -> None:
    statements = (
        "import lockstep.runtime; import lockstep.reviewer_turn; "
        "import lockstep.supervisor.transaction",
        "import lockstep.reviewer_turn; import lockstep.runtime; "
        "import lockstep.supervisor.transaction",
        "import lockstep.supervisor.transaction; import lockstep.reviewer_turn; "
        "import lockstep.runtime",
        "import lockstep.supervisor; import lockstep.reviewer_turn; import lockstep.runtime",
    )
    for statement in statements:
        result = subprocess.run([sys.executable, "-c", statement], capture_output=True, text=True)
        assert result.returncode == 0, result.stderr


# ===========================================================================
# No duplicate Reviewer contract types / exactly one composite call site
# (sections 20, 67)
# ===========================================================================


def _call_owner_functions(module: object, target_name: str) -> tuple[dict[str, int], int]:
    """Map each enclosing function name to its call count for *target_name*.

    Walks the AST with an explicit stack of enclosing ``def``/``async def``
    scopes (never source substrings, regex, or line numbers), so a call
    inside a nested function is attributed only to that nested function,
    never to any ancestor. Returns ``(owners, total)`` where ``total`` is
    the whole-module call count, including any (unexpected) call that sits
    outside every function and therefore has no owner -- so a caller can
    distinguish "no owner map entry because it never occurred" from
    "no owner map entry because it occurred outside any function."
    """
    tree = ast.parse(inspect.getsource(module))
    stack: list[str] = []
    owners: dict[str, int] = {}
    total = 0

    class _Visitor(ast.NodeVisitor):
        def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
            stack.append(node.name)
            self.generic_visit(node)
            stack.pop()

        def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
            stack.append(node.name)
            self.generic_visit(node)
            stack.pop()

        def visit_Call(self, node: ast.Call) -> None:
            nonlocal total
            if isinstance(node.func, ast.Name) and node.func.id == target_name:
                total += 1
                if stack:
                    owners[stack[-1]] = owners.get(stack[-1], 0) + 1
            self.generic_visit(node)

    _Visitor().visit(tree)
    return owners, total


def test_transaction_module_has_exact_reviewer_turn_call_sites() -> None:
    # Superseding the pre-9.13 "exactly one call site for the whole module"
    # invariant: Sub-phase 9.13 intentionally adds a second, independent
    # composite-Reviewer invocation family (resumed-attempt execution)
    # alongside the frozen attempt-1 family, because the two have materially
    # different attempt identity, authority prompts, scope rules, and
    # settlement handling. The corrected invariant pins the exact two
    # legal owner functions instead of a bare count, so "no hidden
    # additional role inference" still holds.
    owners, total = _call_owner_functions(transaction_module, "invoke_reviewer_turn")

    assert owners == {
        "_complete_after_implementer_success_with_reviewer_turn": 1,
        "_invoke_and_handle_resumed_reviewer": 1,
    }
    assert total == 2

    # The legacy raw ``invoke_agent`` Reviewer call site is untouched by
    # 9.13: it builds its request via the pre-existing
    # ``_agent_request(role=..., ...)`` helper rather than passing ``role=``
    # directly to ``invoke_agent``, so that (not the outer ``invoke_agent``
    # call) is where the Reviewer role keyword actually appears.
    tree = ast.parse(inspect.getsource(transaction_module))
    legacy_reviewer_calls = 0
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        if isinstance(node.func, ast.Name) and node.func.id == "_agent_request":
            role_keyword = next((kw for kw in node.keywords if kw.arg == "role"), None)
            if (
                role_keyword is not None
                and isinstance(role_keyword.value, ast.Attribute)
                and role_keyword.value.attr == "REVIEWER"
            ):
                legacy_reviewer_calls += 1

    assert legacy_reviewer_calls == 1


# ===========================================================================
# Transaction-level fixtures (mirrors tests/test_supervisor_implementer_blocker.py)
# ===========================================================================


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


def _write_fake_claude_executable(
    bin_dir: Path,
    *,
    name: str,
    responses: list[dict[str, object]],
) -> Path:
    bin_dir.mkdir(parents=True, exist_ok=True)
    executable = bin_dir / name
    responses_path = bin_dir / f"{name}-responses.json"
    responses_path.write_text(json.dumps(responses), encoding="utf-8")

    script = textwrap.dedent(
        f"""\
        #!{sys.executable}
        import json
        import sys
        from pathlib import Path

        base = Path(__file__).resolve().parent
        responses = json.loads((base / "{name}-responses.json").read_text(encoding="utf-8"))
        count_path = base / "{name}-call-count.txt"
        index = int(count_path.read_text()) if count_path.exists() else 0
        count_path.write_text(str(index + 1))
        response = responses[index] if index < len(responses) else responses[-1]

        sys.stdin.read()

        log_path = base / "{name}-invocations.jsonl"
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({{"index": index, "cwd": str(Path.cwd())}}) + "\\n")

        for rel_path, content in response.get("files", {{}}).items():
            target = Path(rel_path)
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(content)

        sys.stdout.write(response.get("stdout", ""))
        sys.stderr.write(response.get("stderr", ""))
        raise SystemExit(int(response.get("returncode", 0)))
        """
    )
    executable.write_text(script, encoding="utf-8")
    mode = executable.stat().st_mode
    executable.chmod(mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _invocation_count(bin_dir: Path, name: str) -> int:
    log_path = bin_dir / f"{name}-invocations.jsonl"
    if not log_path.exists():
        return 0
    return len([line for line in log_path.read_text(encoding="utf-8").splitlines() if line])


def _planner_authoring_response(test_content: str) -> dict[str, object]:
    return {"stdout": "", "returncode": 0, "files": {"tests/test_feature.py": test_content}}


def _planner_decision_response(
    *,
    kind: PlannerDecisionKind,
    rationale: str = "Bounded rationale for this decision.",
    instructions: tuple[str, ...] = ("Do the bounded thing.",),
    authorized_paths: tuple[str, ...] = (),
) -> dict[str, object]:
    return {
        "stdout": json.dumps(
            {
                "kind": kind.value,
                "rationale": rationale,
                "instructions": list(instructions),
                "authorized_paths": list(authorized_paths),
            }
        ),
        "returncode": 0,
    }


def _implementer_completed_response(files: dict[str, str]) -> dict[str, object]:
    return {
        "stdout": json.dumps({"status": "completed", "blocker": None}),
        "returncode": 0,
        "files": files,
    }


def _reviewer_completed_response(
    *,
    verdict: str = "approve",
    summary: str = "approved",
    stderr: str = "",
) -> dict[str, object]:
    return {
        "stdout": json.dumps(_completed_payload(verdict=verdict, summary=summary)),
        "returncode": 0,
        "stderr": stderr,
    }


def _reviewer_blocked_response(
    *,
    category: EscalationCategory,
    question: str = "Bounded sentinel question.",
    evidence: tuple[str, ...] = ("Bounded sentinel evidence.",),
    requested_authority: EscalationAuthority,
    stderr: str = "",
) -> dict[str, object]:
    return {
        "stdout": json.dumps(
            _blocked_payload(
                category=category,
                question=question,
                evidence=evidence,
                requested_authority=requested_authority,
            )
        ),
        "returncode": 0,
        "stderr": stderr,
    }


def _master_plan(*, phase_id: str, subphase_id: str) -> MasterPlan:
    return MasterPlan(
        schema_version=1,
        project_id="lockstep",
        title="Lockstep",
        objective="Build the local orchestration control plane.",
        phases=[
            PhasePlan(
                schema_version=1,
                phase_id=_phase_id(phase_id),
                title="Reviewer decision/blocker composition",
                objective="Compose structured Reviewer blockers into the transaction.",
                depends_on=[],
                subphases=[
                    SubphaseOutline(
                        subphase_id=_subphase_id(subphase_id),
                        title="Reviewer decision/blocker composition",
                        objective="Route a blocked Reviewer turn to the correct authority.",
                        depends_on=[],
                    )
                ],
                integration_acceptance_criteria=[],
            )
        ],
    )


def _phase_plan(*, phase_id: str, subphase_id: str) -> PhasePlan:
    return _master_plan(phase_id=phase_id, subphase_id=subphase_id).phases[0]


def _contract(*, phase_id: str, subphase_id: str) -> SubphaseContract:
    return SubphaseContract(
        schema_version=1,
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        title="Reviewer decision/blocker composition",
        objective="Route a blocked Reviewer turn to the correct authority.",
        acceptance_criteria=[
            AcceptanceCriterion(criterion_id="AC-1", description="Blocked reviews halt safely.")
        ],
        tests=[
            TestSpecification(
                path="tests/test_supervisor_reviewer_blocker.py",
                expectation=TestExpectation.RED,
                acceptance_criteria=["AC-1"],
            )
        ],
        allowed_paths=["src/lockstep/reviewer_turn.py", "src/lockstep/supervisor/transaction.py"],
        protected_paths=[],
        forbidden_paths=[],
        verification_commands=["./scripts/check"],
    )


def _freeze_planning_state(
    project_root: Path,
    runtime_dir: Path,
    *,
    phase_id: str,
    subphase_id: str,
) -> None:
    freeze_master_plan(project_root, _master_plan(phase_id=phase_id, subphase_id=subphase_id))
    publish_phase_plan(
        project_root, runtime_dir, _phase_plan(phase_id=phase_id, subphase_id=subphase_id)
    )
    freeze_subphase_contract(
        project_root, runtime_dir, _contract(phase_id=phase_id, subphase_id=subphase_id)
    )


def _parent_env(tmp_path: Path) -> dict[str, str]:
    home = tmp_path / "home"
    home.mkdir(exist_ok=True)
    return {
        "HOME": str(home),
        "PATH": "/usr/bin:/bin",
    }


def _build_request(
    tmp_path: Path,
    source: Path,
    *,
    runtime_dir: Path | None = None,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
) -> SingleSubphaseTransactionRequest:
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
        run_id=RunId.model_validate("20260928-002"),
        phase_id=_phase_id(phase_id),
        subphase_id=_subphase_id(subphase_id),
        source_path=source,
        worktree_path=tmp_path / "run-worktree",
        runtime_dir=runtime_dir if runtime_dir is not None else tmp_path / "runtime",
        branch="lockstep/run/run-09-07-supervisor",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        planner_prompt="draft the failing acceptance test",
        implementer_prompt="implement the acceptance test",
        reviewer_prompt="review the implementation",
        test_paths=("tests/test_feature.py",),
        implementation_paths=("feature.py",),
        planner_quality_argv=(sys.executable, "-m", "py_compile", "tests/test_feature.py"),
        baseline_argv=pytest_argv,
        verification_argv=pytest_argv,
        test_commit_message="test(feature): freeze answer expectation",
        implementation_commit_message="feat(feature): implement answer",
        agent_timeout_seconds=60.0,
        command_timeout_seconds=60.0,
    )


def _agent_runtime(
    tmp_path: Path,
    *,
    runtime_dir: Path,
    planner_adapter: AgentAdapter,
    implementer_adapter: AgentAdapter,
    reviewer_adapter: AgentAdapter,
    parent_env: Mapping[str, str],
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
) -> AgentRuntime:
    project_root = tmp_path / "agent-project"
    project_root.mkdir(exist_ok=True)
    _freeze_planning_state(project_root, runtime_dir, phase_id=phase_id, subphase_id=subphase_id)

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
        planner=planner_adapter,
        implementer=implementer_adapter,
        reviewer=reviewer_adapter,
    )

    return AgentRuntime(
        project_root=project_root,
        runtime_dir=runtime_dir,
        config=config,
        diagnostics=diagnostics,
        adapters=adapters,
        transaction_parent_env=parent_env,
    )


@dataclass(frozen=True, slots=True)
class _Scenario:
    request: SingleSubphaseTransactionRequest
    runtime: AgentRuntime
    planner_bin: Path
    implementer_bin: Path
    reviewer_bin: Path


def _prepare_scenario(
    tmp_path: Path,
    *,
    reviewer_response: dict[str, object],
    planner_responses: list[dict[str, object]] | None = None,
    implementer_response: dict[str, object] | None = None,
    phase_id: str = _PHASE_ID,
    subphase_id: str = _SUBPHASE_ID,
) -> _Scenario:
    source = _init_source_repo(tmp_path)
    request = _build_request(tmp_path, source, phase_id=phase_id, subphase_id=subphase_id)

    resolved_planner_responses = (
        planner_responses
        if planner_responses is not None
        else [_planner_authoring_response(_TEST_FILE_RED)]
    )
    planner_bin = tmp_path / "planner-bin"
    _write_fake_claude_executable(
        planner_bin, name="claude-planner", responses=resolved_planner_responses
    )
    planner_adapter = _claude_adapter(
        AgentRole.PLANNER, executable=str(planner_bin / "claude-planner")
    )

    resolved_implementer_response = (
        implementer_response
        if implementer_response is not None
        else _implementer_completed_response({"feature.py": _IMPL_CORRECT})
    )
    implementer_bin = tmp_path / "implementer-bin"
    _write_fake_claude_executable(
        implementer_bin, name="claude-implementer", responses=[resolved_implementer_response]
    )
    implementer_adapter = _claude_adapter(
        AgentRole.IMPLEMENTER, executable=str(implementer_bin / "claude-implementer")
    )

    reviewer_bin = tmp_path / "reviewer-bin"
    _write_fake_claude_executable(
        reviewer_bin, name="claude-reviewer", responses=[reviewer_response]
    )
    reviewer_adapter = _claude_adapter(
        AgentRole.REVIEWER, executable=str(reviewer_bin / "claude-reviewer")
    )

    runtime = _agent_runtime(
        tmp_path,
        runtime_dir=request.runtime_dir,
        planner_adapter=planner_adapter,
        implementer_adapter=implementer_adapter,
        reviewer_adapter=reviewer_adapter,
        parent_env=_parent_env(tmp_path),
        phase_id=phase_id,
        subphase_id=subphase_id,
    )

    return _Scenario(
        request=request,
        runtime=runtime,
        planner_bin=planner_bin,
        implementer_bin=implementer_bin,
        reviewer_bin=reviewer_bin,
    )


# ===========================================================================
# COMPLETED Reviewer + APPROVE matches legacy success shape (sections 26, 54)
# ===========================================================================


def test_composite_reviewer_approve_matches_legacy_success_shape(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path, reviewer_response=_reviewer_completed_response(verdict="approve")
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, SingleSubphaseTransactionResult)
    assert result.final_state.workflow_state == WorkflowState.SUBPHASE_COMPLETE
    assert result.review.verdict.value == "approve"
    assert result.test_commit.committed_paths == ("tests/test_feature.py",)
    assert result.implementation_commit.committed_paths == ("feature.py",)

    assert _invocation_count(scenario.planner_bin, "claude-planner") == 1
    assert _invocation_count(scenario.implementer_bin, "claude-implementer") == 1
    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1

    worktree_snapshot = inspect_repository(scenario.request.worktree_path)
    assert worktree_snapshot.is_clean
    assert worktree_snapshot.head_sha == result.implementation_commit.commit_sha

    events = read_events(scenario.request.runtime_dir / "events.jsonl")
    assert len(events) == 11
    expected_edges = (
        (WorkflowState.READY, WorkflowState.PHASE_PLANNING),
        (WorkflowState.PHASE_PLANNING, WorkflowState.SUBPHASE_PLANNING),
        (WorkflowState.SUBPHASE_PLANNING, WorkflowState.TEST_AUTHORING),
        (WorkflowState.TEST_AUTHORING, WorkflowState.TEST_BASELINE_VERIFY),
        (WorkflowState.TEST_BASELINE_VERIFY, WorkflowState.TEST_COMMIT),
        (WorkflowState.TEST_COMMIT, WorkflowState.IMPLEMENTING),
        (WorkflowState.IMPLEMENTING, WorkflowState.VERIFYING),
        (WorkflowState.VERIFYING, WorkflowState.REVIEWING),
        (WorkflowState.REVIEWING, WorkflowState.IMPLEMENTATION_COMMIT),
        (WorkflowState.IMPLEMENTATION_COMMIT, WorkflowState.SUBPHASE_COMPLETE),
    )
    for offset, (src, dst) in enumerate(expected_edges, start=2):
        event = events[offset - 1]
        assert isinstance(event, StateTransitionedEvent)
        assert event.sequence == offset
        assert event.source == src
        assert event.target == dst


# ===========================================================================
# COMPLETED Reviewer + REWORK / HALT preserve existing semantics (sections
# 27, 28, 55, 56)
# ===========================================================================


def test_composite_reviewer_rework_preserves_existing_semantics(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        reviewer_response=_reviewer_completed_response(verdict="rework", summary="needs changes"),
    )

    with pytest.raises(SupervisorTransactionError) as exc_info:
        run_single_subphase_transaction_with_blockers(
            scenario.request, agent_turn_runtime=scenario.runtime
        )

    assert exc_info.value.stage == "review"

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.REVIEWING

    subjects = _log_subjects(scenario.request.worktree_path)
    assert subjects == [scenario.request.test_commit_message, "initial"]

    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1


def test_composite_reviewer_halt_preserves_existing_semantics(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        reviewer_response=_reviewer_completed_response(verdict="halt", summary="must halt"),
    )

    with pytest.raises(SupervisorTransactionError) as exc_info:
        run_single_subphase_transaction_with_blockers(
            scenario.request, agent_turn_runtime=scenario.runtime
        )

    assert exc_info.value.stage == "review"

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.REVIEWING

    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1


# ===========================================================================
# BLOCKED Reviewer -- frozen-correction (TEST_DEFECT) (sections 30, 37, 57)
# ===========================================================================


def test_reviewer_test_defect_routes_to_frozen_artifact_correction(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_FROZEN_ARTIFACT_CORRECTION,
                authorized_paths=("tests/test_feature.py",),
            ),
        ],
        reviewer_response=_reviewer_blocked_response(
            category=EscalationCategory.TEST_DEFECT,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ReviewerBlockedTransactionResult)
    assert result.escalation.disposition == SupervisorEscalationDisposition.RESUME_AGENT
    assert result.escalation.planner_turn is not None
    assert result.escalation.planner_turn.resolution.frozen_artifact_correction is True
    assert result.escalation.planner_turn.decision.authorized_paths == ("tests/test_feature.py",)
    assert result.final_state.workflow_state == WorkflowState.HALTED

    # The authority now exists; the file itself is not yet touched.
    test_file = scenario.request.worktree_path / "tests" / "test_feature.py"
    assert test_file.read_text(encoding="utf-8") == _TEST_FILE_RED

    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 2


# ===========================================================================
# BLOCKED Reviewer -- Planner bounded authorization (ARCHITECTURE_CONFLICT)
# (sections 40, 58)
# ===========================================================================


def test_reviewer_architecture_conflict_routes_to_planner_bounded_authorization(
    tmp_path: Path,
) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        reviewer_response=_reviewer_blocked_response(
            category=EscalationCategory.ARCHITECTURE_CONFLICT,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ReviewerBlockedTransactionResult)
    assert result.final_state.workflow_state == WorkflowState.HALTED
    assert result.escalation.disposition == SupervisorEscalationDisposition.RESUME_AGENT
    assert result.escalation.planner_turn is not None

    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1
    # 1 test-authoring call + 1 escalation decision call; no Reviewer re-entry.
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 2


# ===========================================================================
# BLOCKED Reviewer -- direct Human / Supervisor routes (sections 38, 39, 59, 60)
# ===========================================================================


def test_reviewer_requirement_ambiguity_routes_to_human_skips_planner(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        reviewer_response=_reviewer_blocked_response(
            category=EscalationCategory.REQUIREMENT_AMBIGUITY,
            requested_authority=EscalationAuthority.HUMAN,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ReviewerBlockedTransactionResult)
    assert result.escalation.disposition == SupervisorEscalationDisposition.HUMAN_REQUIRED
    assert result.escalation.planner_turn is None
    assert result.final_state.workflow_state == WorkflowState.HALTED

    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 1


def test_reviewer_control_plane_blocker_routes_to_supervisor_skips_planner(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        reviewer_response=_reviewer_blocked_response(
            category=EscalationCategory.CONTROL_PLANE_BLOCKER,
            requested_authority=EscalationAuthority.SUPERVISOR,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ReviewerBlockedTransactionResult)
    assert (
        result.escalation.disposition == SupervisorEscalationDisposition.SUPERVISOR_ACTION_REQUIRED
    )
    assert result.escalation.planner_turn is None
    assert result.final_state.workflow_state == WorkflowState.HALTED

    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 1


# ===========================================================================
# Requested-authority mismatch does not change routing (section 61)
# ===========================================================================


def test_reviewer_requested_authority_mismatch_still_routes_to_planner(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        reviewer_response=_reviewer_blocked_response(
            category=EscalationCategory.TEST_DEFECT,
            requested_authority=EscalationAuthority.HUMAN,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ReviewerBlockedTransactionResult)
    assert result.escalation.route.authority.value == "planner"
    assert result.escalation.request.requested_authority == EscalationAuthority.HUMAN
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 2


# ===========================================================================
# Partial (already-verified) implementation preserved on Reviewer block
# (sections 34, 36, 62)
# ===========================================================================


def test_reviewer_blocked_preserves_verified_implementation_no_commit(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        reviewer_response=_reviewer_blocked_response(
            category=EscalationCategory.REQUIREMENT_AMBIGUITY,
            requested_authority=EscalationAuthority.HUMAN,
        ),
    )

    run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    impl_file = scenario.request.worktree_path / "feature.py"
    assert impl_file.read_text(encoding="utf-8") == _IMPL_CORRECT

    subjects = _log_subjects(scenario.request.worktree_path)
    assert subjects == [scenario.request.test_commit_message, "initial"]

    snapshot = inspect_repository(scenario.request.worktree_path)
    assert not snapshot.is_clean
    assert snapshot.dirty_paths == ("feature.py",)


# ===========================================================================
# Event sequence terminates at HALTED via REVIEWING (sections 32, 34, 63)
# ===========================================================================


def test_reviewer_blocked_event_sequence_terminates_at_halted(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        reviewer_response=_reviewer_blocked_response(
            category=EscalationCategory.REQUIREMENT_AMBIGUITY,
            requested_authority=EscalationAuthority.HUMAN,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )
    assert isinstance(result, ReviewerBlockedTransactionResult)

    events = read_events(scenario.request.runtime_dir / "events.jsonl")
    assert len(events) == 10
    last_event = events[-1]
    assert isinstance(last_event, StateTransitionedEvent)
    assert last_event.source == WorkflowState.REVIEWING
    assert last_event.target == WorkflowState.HALTED

    reached_targets = {
        event.target for event in events if isinstance(event, StateTransitionedEvent)
    }
    assert WorkflowState.VERIFYING in reached_targets
    assert WorkflowState.REVIEWING in reached_targets
    assert WorkflowState.IMPLEMENTATION_COMMIT not in reached_targets
    assert WorkflowState.SUBPHASE_COMPLETE not in reached_targets

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.HALTED
    assert persisted == result.final_state


# ===========================================================================
# Malformed / failed Reviewer turn is not converted into a blocker
# (transaction level; sections 41, 42, 64, 65)
# ===========================================================================


def test_transaction_malformed_reviewer_report_raises_reviewer_turn_error(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path, reviewer_response={"stdout": "not json at all", "returncode": 0}
    )

    with pytest.raises(ReviewerTurnError):
        run_single_subphase_transaction_with_blockers(
            scenario.request, agent_turn_runtime=scenario.runtime
        )

    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 1

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.REVIEWING


def test_transaction_reviewer_process_nonzero_raises_reviewer_turn_error(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path, reviewer_response={"stdout": "irrelevant", "returncode": 3}
    )

    with pytest.raises(ReviewerTurnError):
        run_single_subphase_transaction_with_blockers(
            scenario.request, agent_turn_runtime=scenario.runtime
        )

    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.REVIEWING


# ===========================================================================
# Planner escalation failure propagates unwrapped (sections 41, 66)
# ===========================================================================


def test_reviewer_planner_transport_failure_propagates(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        planner_responses=[
            _planner_authoring_response(_TEST_FILE_RED),
            {"stdout": "", "returncode": 7},
        ],
        reviewer_response=_reviewer_blocked_response(
            category=EscalationCategory.PLANNER_DECISION_REQUIRED,
            requested_authority=EscalationAuthority.PLANNER,
        ),
    )

    with pytest.raises(PlannerDecisionTransportError):
        run_single_subphase_transaction_with_blockers(
            scenario.request, agent_turn_runtime=scenario.runtime
        )

    assert _invocation_count(scenario.reviewer_bin, "claude-reviewer") == 1
    assert _invocation_count(scenario.planner_bin, "claude-planner") == 2

    persisted = read_state(scenario.request.runtime_dir / "state.json")
    assert persisted is not None
    assert persisted.workflow_state == WorkflowState.REVIEWING

    subjects = _log_subjects(scenario.request.worktree_path)
    assert subjects == [scenario.request.test_commit_message, "initial"]

    impl_file = scenario.request.worktree_path / "feature.py"
    assert impl_file.read_text(encoding="utf-8") == _IMPL_CORRECT


# ===========================================================================
# ReviewerBlockedTransactionResult shape (section 31)
# ===========================================================================


def test_reviewer_blocked_result_is_frozen_slotted_with_exact_fields(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path,
        reviewer_response=_reviewer_blocked_response(
            category=EscalationCategory.REQUIREMENT_AMBIGUITY,
            requested_authority=EscalationAuthority.HUMAN,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert isinstance(result, ReviewerBlockedTransactionResult)
    assert {f.name for f in fields(result)} == {
        "test_commit",
        "implementer_turn",
        "reviewer_turn",
        "escalation",
        "final_state",
    }
    assert not hasattr(result, "__dict__")

    with pytest.raises(FrozenInstanceError):
        result.test_commit = result.test_commit  # type: ignore[misc]

    assert isinstance(result.implementer_turn, AgentTurnResult)
    assert result.implementer_turn.report.status is AgentTurnStatus.COMPLETED
    assert isinstance(result.reviewer_turn, ReviewerTurnResult)
    assert result.reviewer_turn.report.status is AgentTurnStatus.BLOCKED


def test_reviewer_blocked_result_repr_hides_reviewer_turn_content(tmp_path: Path) -> None:
    sentinel = "SENTINEL-REVIEWER-STDERR-9f2c"
    scenario = _prepare_scenario(
        tmp_path,
        reviewer_response=_reviewer_blocked_response(
            category=EscalationCategory.REQUIREMENT_AMBIGUITY,
            requested_authority=EscalationAuthority.HUMAN,
            stderr=sentinel,
        ),
    )

    result = run_single_subphase_transaction_with_blockers(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert sentinel not in repr(result)
    assert isinstance(result, ReviewerBlockedTransactionResult)
    assert sentinel in result.reviewer_turn.invocation.process.stderr
