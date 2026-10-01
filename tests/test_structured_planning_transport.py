"""Planner-authored specification of Sub-phase 8.3 structured Planner transport.

Pins the one provider-neutral production path from a configured Planner
adapter to a typed planning artifact:

    AgentRuntime
        -> configured runtime.adapters.planner
        -> provider-specific structured-output adaptation (agents/structured_output.py)
        -> private-stdin Planner inference
        -> schema-constrained final-message JSON
        -> Pydantic hydration
        -> typed planning artifact (lockstep/planning_transport.py)

Uses real production ClaudeAdapter/CodexAdapter instances and real
production invoke_agent/invoke_planner_artifact composition against fake
provider executables under tmp_path. No real Claude/Codex account, no
network, no real model inference. Adapters are constructed directly from
hand-built CliStatus evidence, so the Phase-6/5 preflight probes
(``--version``/``--help``/``auth status``/``doctor --json``) are never
exercised here; only the frozen inference-time argv/stdin/environment
contract is.
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

import lockstep.agents.structured_output as structured_output_module
import lockstep.planning_transport as planning_transport_module
from lockstep.agents import (
    AgentAdapter,
    AgentInvocationRequest,
    AgentProviderDiagnostics,
    AgentProviderStatuses,
    ClaudeAdapter,
    ClaudeAdapterError,
    ClaudeCliStatus,
    CodexAdapter,
    CodexAdapterError,
    CodexCliStatus,
    OpenAIStrictSchemaError,
    ResolvedAgentAdapters,
    StructuredOutputAdapterError,
    materialize_codex_review_schema,
    prepare_structured_planner_adapter,
    to_openai_strict_json_schema,
)
from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.config import ProjectConfig
from lockstep.domain import AgentRole, BillingMode, MasterPlan, PhasePlan, SubphaseContract
from lockstep.planning import PlanningValidationError, validate_master_plan
from lockstep.planning_transport import (
    PlanningArtifactKind,
    PlanningArtifactResult,
    PlanningTransportError,
    invoke_planner_artifact,
)
from lockstep.process import EnvironmentPolicyError, ProcessLaunchError, ProcessTimeoutError
from lockstep.runtime import AgentRuntime

# ---------------------------------------------------------------------------
# Construction helpers — CLI status / adapter fixtures
# ---------------------------------------------------------------------------


def _healthy_claude_status(
    *,
    executable: str = "/fake/claude",
    supports_json_schema: bool = True,
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
    *,
    executable: str = "/fake/codex",
    supports_exec_output_schema: bool = True,
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
    *,
    executable: str = "/fake/claude",
    supports_json_schema: bool = True,
    model: str = "claude-planner-model",
    effort: str = "high",
) -> ClaudeAdapter:
    return ClaudeAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_claude_status(
            executable=executable, supports_json_schema=supports_json_schema
        ),
        model=model,
        effort=effort,
    )


def _codex_planner(
    *,
    executable: str = "/fake/codex",
    supports_exec_output_schema: bool = True,
    model: str = "codex-planner-model",
    reasoning_effort: str = "high",
) -> CodexAdapter:
    return CodexAdapter(
        role=AgentRole.PLANNER,
        status=_healthy_codex_status(
            executable=executable, supports_exec_output_schema=supports_exec_output_schema
        ),
        model=model,
        reasoning_effort=reasoning_effort,
    )


def _planner_request(
    cwd: Path,
    *,
    prompt: str = "planner-prompt",
    timeout_seconds: float = 5.0,
    max_output_bytes: int = 1_048_576,
) -> AgentInvocationRequest:
    return AgentInvocationRequest(
        role=AgentRole.PLANNER,
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        prompt=prompt,
        cwd=cwd,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=0.1,
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

    The fake ignores its argv and stdin content for response purposes; the
    response is entirely controlled by *stdout*/*stderr*/*returncode* baked
    into a sibling config file at write time. This keeps the prompt (stdin)
    fully decoupled from provider behavior, so a test can send a
    distinctive prompt sentinel without needing the fake to interpret it.

    Each invocation record also carries ``process_start_env``: the exact
    name/value environment the parent process supplied at ``exec`` time,
    read from ``/proc/self/environ`` (``None`` when that path is
    unavailable). The fake executable is itself a Python script, so
    ordinary ``os.environ`` reflects CPython's own post-exec PEP 538
    C-locale coercion (which can inject ``LC_CTYPE``) in addition to
    whatever the parent actually launched it with; reading the raw
    NUL-separated ``/proc/self/environ`` bytes instead observes the true
    launch environment, unpolluted by interpreter startup behavior. This
    mirrors the technique already established in
    ``tests/test_claude_adapter.py``'s ``_write_recording_claude``.
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
        import os
        import sys
        import time
        from pathlib import Path


        def _process_start_env():
            proc_environ = Path("/proc/self/environ")
            try:
                raw = proc_environ.read_bytes()
            except OSError:
                return None
            env = {{}}
            for entry in raw.split(b"\\0"):
                if not entry or b"=" not in entry:
                    continue
                key, _, value = entry.partition(b"=")
                env[key.decode("utf-8", "strict")] = value.decode("utf-8", "strict")
            return env


        base = Path(__file__).resolve().parent
        config = json.loads((base / "{name}-response.json").read_text(encoding="utf-8"))
        args = sys.argv[1:]
        stdin_text = sys.stdin.read()
        process_start_env = _process_start_env()

        with (base / "invocations.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(
                json.dumps(
                    {{
                        "exe": "{name}",
                        "argv": args,
                        "env": dict(os.environ),
                        "process_start_env": process_start_env,
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


# ---------------------------------------------------------------------------
# Planning artifact payload fixtures (plain JSON dicts — no Pydantic import
# of the nested artifact-piece models is required to build valid payloads).
# ---------------------------------------------------------------------------


def _phase_plan_payload(phase_id: str = "01") -> dict[str, object]:
    return {
        "schema_version": 1,
        "phase_id": phase_id,
        "title": "Phase title",
        "objective": "Phase objective.",
        "depends_on": [],
        "subphases": [
            {
                "subphase_id": "01",
                "title": "Outline title",
                "objective": "Outline objective.",
                "depends_on": [],
            }
        ],
        "integration_acceptance_criteria": [],
    }


def _master_plan_payload() -> dict[str, object]:
    return {
        "schema_version": 1,
        "project_id": "lockstep",
        "title": "Lockstep",
        "objective": "Build the local orchestration control plane.",
        "phases": [_phase_plan_payload("01")],
    }


def _duplicate_phase_master_plan_payload() -> dict[str, object]:
    phase = _phase_plan_payload("01")
    return {
        "schema_version": 1,
        "project_id": "lockstep",
        "title": "Lockstep",
        "objective": "Build the local orchestration control plane.",
        "phases": [phase, dict(phase)],
    }


def _subphase_contract_payload() -> dict[str, object]:
    return {
        "schema_version": 1,
        "phase_id": "01",
        "subphase_id": "01",
        "title": "Contract title",
        "objective": "Contract objective.",
        "acceptance_criteria": [
            {"criterion_id": "AC-1", "description": "Observable behavior holds."}
        ],
        "tests": [
            {
                "path": "tests/test_one.py",
                "expectation": "red",
                "acceptance_criteria": ["AC-1"],
            }
        ],
        "allowed_paths": ["src/lockstep/**"],
        "protected_paths": [],
        "forbidden_paths": [],
        "verification_commands": ["./scripts/check"],
    }


_ARTIFACT_TYPES: dict[PlanningArtifactKind, type] = {
    PlanningArtifactKind.MASTER_PLAN: MasterPlan,
    PlanningArtifactKind.PHASE_PLAN: PhasePlan,
    PlanningArtifactKind.SUBPHASE_CONTRACT: SubphaseContract,
}

_ARTIFACT_PAYLOADS: dict[PlanningArtifactKind, object] = {
    PlanningArtifactKind.MASTER_PLAN: _master_plan_payload,
    PlanningArtifactKind.PHASE_PLAN: _phase_plan_payload,
    PlanningArtifactKind.SUBPHASE_CONTRACT: _subphase_contract_payload,
}


# ---------------------------------------------------------------------------
# AgentRuntime construction helper — bypasses config-file/preflight
# machinery entirely so tests exercise only the planning-transport seam.
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
        planner=planner_adapter,
        implementer=planner_adapter,
        reviewer=planner_adapter,
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
# Section 43 — PlanningArtifactKind vocabulary
# ===========================================================================


def test_planning_artifact_kind_has_exactly_three_values() -> None:
    assert {kind.value for kind in PlanningArtifactKind} == {
        "master-plan",
        "phase-plan",
        "subphase-contract",
    }
    assert PlanningArtifactKind("master-plan") is PlanningArtifactKind.MASTER_PLAN
    assert PlanningArtifactKind("phase-plan") is PlanningArtifactKind.PHASE_PLAN
    assert PlanningArtifactKind("subphase-contract") is PlanningArtifactKind.SUBPHASE_CONTRACT

    with pytest.raises(ValueError):
        PlanningArtifactKind("review")
    with pytest.raises(ValueError):
        PlanningArtifactKind("implementation-report")
    with pytest.raises(ValueError):
        PlanningArtifactKind("verification-report")
    with pytest.raises(ValueError):
        PlanningArtifactKind("scribe")


def test_planning_artifact_kind_is_not_declared_in_domain_package() -> None:
    import lockstep.domain as domain

    assert not hasattr(domain, "PlanningArtifactKind")


# ===========================================================================
# Section 44/45 — Claude structured wrapper preserves base authority
# ===========================================================================


def test_claude_structured_wrapper_preserves_base_command_and_reduces_authority(
    tmp_path: Path,
) -> None:
    base_adapter = _claude_planner()
    request = _planner_request(tmp_path)
    base_command = base_adapter.build_command(request)

    canonical_schema = MasterPlan.model_json_schema()
    structured_adapter = prepare_structured_planner_adapter(
        base_adapter,
        canonical_schema=canonical_schema,
        runtime_dir=tmp_path / "runtime",
        schema_name="master-plan",
    )
    structured_command = structured_adapter.build_command(request)

    tools_index = base_command.argv.index("--tools")
    allowed_index = base_command.argv.index("--allowedTools")
    assert base_command.argv[tools_index + 1] == "Read,Write,Edit,Glob,Grep"
    assert base_command.argv[allowed_index + 1] == "Read,Write,Edit,Glob,Grep"

    expected_argv = list(base_command.argv)
    expected_argv[tools_index + 1] = "Read,Glob,Grep"
    expected_argv[allowed_index + 1] = "Read,Glob,Grep"
    schema_json = json.dumps(
        canonical_schema, ensure_ascii=False, separators=(",", ":"), sort_keys=True
    )
    expected_argv.extend(("--json-schema", schema_json))

    assert structured_command.argv == tuple(expected_argv)
    assert structured_command.stdin_text == base_command.stdin_text
    assert structured_command.inherit_names == base_command.inherit_names
    assert dict(structured_command.explicit_env) == dict(base_command.explicit_env)
    assert structured_command.required_names == base_command.required_names

    assert structured_adapter.name == "claude"


def test_claude_structured_command_shape_and_capabilities(tmp_path: Path) -> None:
    base_adapter = _claude_planner(model="planner-model-x", effort="max-effort")
    request = _planner_request(tmp_path)
    canonical_schema = MasterPlan.model_json_schema()

    structured_adapter = prepare_structured_planner_adapter(
        base_adapter,
        canonical_schema=canonical_schema,
        runtime_dir=tmp_path / "runtime",
        schema_name="master-plan",
    )
    command = structured_adapter.build_command(request)
    argv = command.argv

    assert "--safe-mode" in argv
    assert "--restricted" in argv
    assert "--no-session-persistence" in argv
    perm_index = argv.index("--permission-prompts")
    assert argv[perm_index + 1] == "none"
    fmt_index = argv.index("--output-format")
    assert argv[fmt_index + 1] == "json"
    model_index = argv.index("--model")
    assert argv[model_index + 1] == "planner-model-x"
    effort_index = argv.index("--effort")
    assert argv[effort_index + 1] == "max-effort"
    tools_index = argv.index("--tools")
    assert argv[tools_index + 1] == "Read,Glob,Grep"
    allowed_index = argv.index("--allowedTools")
    assert argv[allowed_index + 1] == "Read,Glob,Grep"
    disallowed_index = argv.index("--disallowedTools")
    assert argv[disallowed_index + 1] == "mcp__*"

    schema_index = argv.index("--json-schema")
    decoded = json.loads(argv[schema_index + 1])
    assert decoded == canonical_schema

    assert not (tmp_path / "runtime" / "providers" / "claude").exists()


def test_claude_missing_json_schema_capability_fails_closed(tmp_path: Path) -> None:
    adapter = _claude_planner(supports_json_schema=False)

    with pytest.raises(StructuredOutputAdapterError):
        prepare_structured_planner_adapter(
            adapter,
            canonical_schema=MasterPlan.model_json_schema(),
            runtime_dir=tmp_path / "runtime",
            schema_name="master-plan",
        )

    assert not (tmp_path / "runtime").exists() or list((tmp_path / "runtime").rglob("*")) == []


# ===========================================================================
# Section 44/46 — Codex structured wrapper preserves base authority
# ===========================================================================


def test_codex_structured_wrapper_preserves_base_command_and_reduces_authority(
    tmp_path: Path,
) -> None:
    base_adapter = _codex_planner()
    request = _planner_request(tmp_path)
    base_command = base_adapter.build_command(request)

    runtime_dir = tmp_path / "runtime"
    canonical_schema = MasterPlan.model_json_schema()
    structured_adapter = prepare_structured_planner_adapter(
        base_adapter,
        canonical_schema=canonical_schema,
        runtime_dir=runtime_dir,
        schema_name="master-plan",
    )
    structured_command = structured_adapter.build_command(request)

    sandbox_index = base_command.argv.index("--sandbox")
    assert base_command.argv[sandbox_index + 1] == "workspace-write"
    assert base_command.argv[-1] == "-"

    schema_path = (
        runtime_dir.resolve() / "providers" / "codex" / "planning" / "master-plan.schema.json"
    )
    assert schema_path.exists()

    expected_argv = list(base_command.argv)
    expected_argv[sandbox_index + 1] = "read-only"
    expected_argv[-1:-1] = ["--output-schema", str(schema_path)]

    assert structured_command.argv == tuple(expected_argv)
    assert structured_command.stdin_text == base_command.stdin_text
    assert structured_command.inherit_names == base_command.inherit_names
    assert dict(structured_command.explicit_env) == dict(base_command.explicit_env)
    assert structured_command.required_names == base_command.required_names

    assert structured_adapter.name == "codex"


def test_codex_structured_command_shape_and_capabilities(tmp_path: Path) -> None:
    base_adapter = _codex_planner(model="planner-model-y", reasoning_effort="max-effort")
    request = _planner_request(tmp_path)
    runtime_dir = tmp_path / "runtime"
    canonical_schema = MasterPlan.model_json_schema()

    structured_adapter = prepare_structured_planner_adapter(
        base_adapter,
        canonical_schema=canonical_schema,
        runtime_dir=runtime_dir,
        schema_name="master-plan",
    )
    command = structured_adapter.build_command(request)
    argv = command.argv

    assert "--ephemeral" in argv
    assert "--ignore-user-config" in argv
    assert "--ignore-rules" in argv
    color_index = argv.index("--color")
    assert argv[color_index + 1] == "never"
    model_index = argv.index("--model")
    assert argv[model_index + 1] == "planner-model-y"
    assert any("model_reasoning_effort" in token for token in argv)
    sandbox_index = argv.index("--sandbox")
    assert argv[sandbox_index + 1] == "read-only"
    assert argv[-1] == "-"
    assert "--json" in argv
    assert "workspace-write" not in argv

    schema_index = argv.index("--output-schema")
    schema_path = Path(argv[schema_index + 1])
    decoded = json.loads(schema_path.read_text(encoding="utf-8"))
    assert decoded == to_openai_strict_json_schema(canonical_schema)
    assert canonical_schema == MasterPlan.model_json_schema()


def test_codex_missing_output_schema_capability_fails_closed(tmp_path: Path) -> None:
    adapter = _codex_planner(supports_exec_output_schema=False)
    runtime_dir = tmp_path / "runtime"

    with pytest.raises(StructuredOutputAdapterError):
        prepare_structured_planner_adapter(
            adapter,
            canonical_schema=MasterPlan.model_json_schema(),
            runtime_dir=runtime_dir,
            schema_name="master-plan",
        )

    assert not (runtime_dir / "providers" / "codex" / "planning").exists()


def test_codex_reviewer_materializer_and_planner_materializer_do_not_collide(
    tmp_path: Path,
) -> None:
    runtime_dir = tmp_path / "runtime"
    review_path = materialize_codex_review_schema(runtime_dir)

    adapter = _codex_planner()
    prepare_structured_planner_adapter(
        adapter,
        canonical_schema=MasterPlan.model_json_schema(),
        runtime_dir=runtime_dir,
        schema_name="master-plan",
    )
    planning_path = (
        runtime_dir.resolve() / "providers" / "codex" / "planning" / "master-plan.schema.json"
    )

    assert review_path.exists()
    assert planning_path.exists()
    assert review_path != planning_path


# ===========================================================================
# Section 47 — schema-name safety
# ===========================================================================


@pytest.mark.parametrize(
    "schema_name",
    ["", " ", "../x", "x/y", "x\\y", "-x", "MasterPlan", "x\x00y"],
)
def test_invalid_schema_names_are_rejected_before_filesystem_mutation(
    tmp_path: Path, schema_name: str
) -> None:
    adapter = _codex_planner()
    runtime_dir = tmp_path / "runtime"

    with pytest.raises(StructuredOutputAdapterError):
        prepare_structured_planner_adapter(
            adapter,
            canonical_schema=MasterPlan.model_json_schema(),
            runtime_dir=runtime_dir,
            schema_name=schema_name,
        )

    assert not (runtime_dir / "providers" / "codex" / "planning").exists()


@pytest.mark.parametrize("schema_name", ["master-plan", "phase-plan", "subphase-contract"])
def test_valid_schema_names_are_accepted(tmp_path: Path, schema_name: str) -> None:
    adapter = _codex_planner()
    runtime_dir = tmp_path / "runtime"

    prepare_structured_planner_adapter(
        adapter,
        canonical_schema=MasterPlan.model_json_schema(),
        runtime_dir=runtime_dir,
        schema_name=schema_name,
    )

    assert (
        runtime_dir / "providers" / "codex" / "planning" / f"{schema_name}.schema.json"
    ).exists()


# ===========================================================================
# Section 49/50 — unsupported adapter / role mismatch
# ===========================================================================


class _FakeUnsupportedAdapter:
    name = "fake-provider"
    role = AgentRole.PLANNER

    def build_command(self, request: AgentInvocationRequest) -> object:
        raise AssertionError(
            "structured preparation must not build a command for an unknown adapter"
        )


def test_unknown_adapter_type_fails_closed(tmp_path: Path) -> None:
    with pytest.raises(StructuredOutputAdapterError):
        prepare_structured_planner_adapter(
            _FakeUnsupportedAdapter(),  # type: ignore[arg-type]
            canonical_schema=MasterPlan.model_json_schema(),
            runtime_dir=tmp_path / "runtime",
            schema_name="master-plan",
        )


def test_claude_implementer_role_is_rejected(tmp_path: Path) -> None:
    adapter = ClaudeAdapter(
        role=AgentRole.IMPLEMENTER,
        status=_healthy_claude_status(),
        model="m",
        effort="e",
    )

    with pytest.raises(StructuredOutputAdapterError):
        prepare_structured_planner_adapter(
            adapter,
            canonical_schema=MasterPlan.model_json_schema(),
            runtime_dir=tmp_path / "runtime",
            schema_name="master-plan",
        )


def test_codex_reviewer_role_is_rejected(tmp_path: Path) -> None:
    adapter = CodexAdapter(
        role=AgentRole.REVIEWER,
        status=_healthy_codex_status(),
        model="m",
        reasoning_effort="e",
        review_output_schema_path=tmp_path / "unused-review-schema.json",
    )

    with pytest.raises(StructuredOutputAdapterError):
        prepare_structured_planner_adapter(
            adapter,
            canonical_schema=MasterPlan.model_json_schema(),
            runtime_dir=tmp_path / "runtime",
            schema_name="master-plan",
        )


# ===========================================================================
# Section 51 — command-shape drift fails closed
# ===========================================================================


def test_claude_command_shape_drift_fails_closed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    adapter = _claude_planner()
    structured_adapter = prepare_structured_planner_adapter(
        adapter,
        canonical_schema=MasterPlan.model_json_schema(),
        runtime_dir=tmp_path / "runtime",
        schema_name="master-plan",
    )

    def _drifted_build_command(self: ClaudeAdapter, request: AgentInvocationRequest) -> object:
        from lockstep.agents import AgentCommand

        return AgentCommand(argv=(self.status.executable, "-p", "--model", self.model))

    monkeypatch.setattr(ClaudeAdapter, "build_command", _drifted_build_command)

    with pytest.raises(StructuredOutputAdapterError):
        structured_adapter.build_command(_planner_request(tmp_path))


def test_codex_command_shape_drift_missing_stdin_marker_fails_closed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    adapter = _codex_planner()
    structured_adapter = prepare_structured_planner_adapter(
        adapter,
        canonical_schema=MasterPlan.model_json_schema(),
        runtime_dir=tmp_path / "runtime",
        schema_name="master-plan",
    )

    def _drifted_build_command(self: CodexAdapter, request: AgentInvocationRequest) -> object:
        from lockstep.agents import AgentCommand

        return AgentCommand(
            argv=(
                self.status.executable,
                "exec",
                "--sandbox",
                "workspace-write",
                "not-a-stdin-marker",
            )
        )

    monkeypatch.setattr(CodexAdapter, "build_command", _drifted_build_command)

    with pytest.raises(StructuredOutputAdapterError):
        structured_adapter.build_command(_planner_request(tmp_path))


def test_codex_command_shape_drift_duplicate_sandbox_token_fails_closed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    adapter = _codex_planner()
    structured_adapter = prepare_structured_planner_adapter(
        adapter,
        canonical_schema=MasterPlan.model_json_schema(),
        runtime_dir=tmp_path / "runtime",
        schema_name="master-plan",
    )

    def _drifted_build_command(self: CodexAdapter, request: AgentInvocationRequest) -> object:
        from lockstep.agents import AgentCommand

        return AgentCommand(
            argv=(
                self.status.executable,
                "exec",
                "--sandbox",
                "workspace-write",
                "--sandbox",
                "workspace-write",
                "-",
            )
        )

    monkeypatch.setattr(CodexAdapter, "build_command", _drifted_build_command)

    with pytest.raises(StructuredOutputAdapterError):
        structured_adapter.build_command(_planner_request(tmp_path))


# ===========================================================================
# Section 52/53/54 — Codex schema determinism, staleness, publication failure
# ===========================================================================


@pytest.mark.parametrize(
    ("kind", "schema_name"),
    [
        (PlanningArtifactKind.MASTER_PLAN, "master-plan"),
        (PlanningArtifactKind.PHASE_PLAN, "phase-plan"),
        (PlanningArtifactKind.SUBPHASE_CONTRACT, "subphase-contract"),
    ],
)
def test_codex_schema_materialization_is_deterministic(
    tmp_path: Path, kind: PlanningArtifactKind, schema_name: str
) -> None:
    runtime_dir = tmp_path / "runtime"
    artifact_type = _ARTIFACT_TYPES[kind]
    canonical_schema = artifact_type.model_json_schema()

    prepare_structured_planner_adapter(
        _codex_planner(),
        canonical_schema=canonical_schema,
        runtime_dir=runtime_dir,
        schema_name=schema_name,
    )
    schema_path = (
        runtime_dir.resolve() / "providers" / "codex" / "planning" / f"{schema_name}.schema.json"
    )
    first_bytes = schema_path.read_bytes()

    prepare_structured_planner_adapter(
        _codex_planner(),
        canonical_schema=canonical_schema,
        runtime_dir=runtime_dir,
        schema_name=schema_name,
    )
    second_bytes = schema_path.read_bytes()

    assert first_bytes == second_bytes
    assert first_bytes.endswith(b"\n")
    assert not first_bytes.endswith(b"\n\n")
    decoded = json.loads(first_bytes)
    assert decoded == to_openai_strict_json_schema(canonical_schema)

    directory = schema_path.parent
    assert [entry.name for entry in directory.iterdir()] == [schema_path.name]


def test_codex_stale_schema_is_replaced(tmp_path: Path) -> None:
    runtime_dir = tmp_path / "runtime"
    schema_dir = runtime_dir / "providers" / "codex" / "planning"
    schema_dir.mkdir(parents=True)
    stale_path = schema_dir / "master-plan.schema.json"
    stale_path.write_bytes(b"THIS IS STALE")

    prepare_structured_planner_adapter(
        _codex_planner(),
        canonical_schema=MasterPlan.model_json_schema(),
        runtime_dir=runtime_dir,
        schema_name="master-plan",
    )

    contents = stale_path.read_bytes()
    assert b"THIS IS STALE" not in contents
    decoded = json.loads(contents)
    assert decoded == to_openai_strict_json_schema(MasterPlan.model_json_schema())


def test_codex_publication_failure_preserves_prior_schema_and_leaves_no_orphan_temp(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    runtime_dir = tmp_path / "runtime"
    prepare_structured_planner_adapter(
        _codex_planner(),
        canonical_schema=MasterPlan.model_json_schema(),
        runtime_dir=runtime_dir,
        schema_name="master-plan",
    )
    schema_path = (
        runtime_dir.resolve() / "providers" / "codex" / "planning" / "master-plan.schema.json"
    )
    good_bytes = schema_path.read_bytes()

    def _boom(*_args: object, **_kwargs: object) -> None:
        raise RuntimeError("simulated atomic-replace failure")

    monkeypatch.setattr(structured_output_module, "_replace_atomically", _boom)

    with pytest.raises(RuntimeError):
        prepare_structured_planner_adapter(
            _codex_planner(),
            canonical_schema=MasterPlan.model_json_schema(),
            runtime_dir=runtime_dir,
            schema_name="master-plan",
        )

    assert schema_path.read_bytes() == good_bytes
    leftover = [entry for entry in schema_path.parent.iterdir() if entry.name != schema_path.name]
    assert leftover == []


def _call_names(tree: ast.AST) -> set[str]:
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
            names.add(node.func.id)
    return names


def test_atomically_publish_calls_private_replace_seam() -> None:
    source = inspect.getsource(structured_output_module._atomically_publish)
    called = _call_names(ast.parse(source))

    assert "_replace_atomically" in called
    assert "replace" not in called


def test_replace_atomically_is_a_thin_wrapper_around_os_replace() -> None:
    source = inspect.getsource(structured_output_module._replace_atomically)
    tree = ast.parse(source)

    os_replace_calls = [
        node
        for node in ast.walk(tree)
        if isinstance(node, ast.Call)
        and isinstance(node.func, ast.Attribute)
        and node.func.attr == "replace"
        and isinstance(node.func.value, ast.Name)
        and node.func.value.id == "os"
    ]
    assert len(os_replace_calls) == 1


def test_no_test_in_this_file_patches_the_shared_os_replace_seam() -> None:
    test_source = Path(__file__).read_text(encoding="utf-8")
    tree = ast.parse(test_source)

    for node in ast.walk(tree):
        if not (
            isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr == "setattr"
            and len(node.args) >= 2
        ):
            continue

        target_arg, name_arg = node.args[0], node.args[1]
        if not (isinstance(name_arg, ast.Constant) and name_arg.value == "replace"):
            continue

        is_bare_os = isinstance(target_arg, ast.Name) and target_arg.id == "os"
        is_module_os_attr = isinstance(target_arg, ast.Attribute) and target_arg.attr == "os"
        assert not is_bare_os, "test must not patch the shared os.replace function"
        assert not is_module_os_attr, (
            "test must not patch structured_output.os.replace; "
            "patch structured_output._replace_atomically instead"
        )


# ===========================================================================
# Section 55 — PlanningArtifactResult shape
# ===========================================================================


def test_planning_artifact_result_is_frozen_slotted_and_privacy_safe(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    result = invoke_planner_artifact(
        runtime,
        kind=PlanningArtifactKind.MASTER_PLAN,
        prompt="SENTINEL-DO-NOT-LEAK-9f3a2b",
        timeout_seconds=5.0,
    )

    assert isinstance(result, PlanningArtifactResult)
    assert {f.name for f in fields(result)} == {"kind", "artifact", "invocation"}

    with pytest.raises(FrozenInstanceError):
        result.kind = PlanningArtifactKind.PHASE_PLAN  # type: ignore[misc]

    assert not hasattr(result, "__dict__")

    rendered = repr(result)
    assert "SENTINEL-DO-NOT-LEAK-9f3a2b" not in rendered
    assert "Lockstep" not in rendered  # title text from the hydrated artifact stays out of repr


# ===========================================================================
# Section 56 — all six provider/artifact combinations
# ===========================================================================


@pytest.mark.parametrize(
    ("provider", "kind"),
    [
        (AgentProvider.CLAUDE, PlanningArtifactKind.MASTER_PLAN),
        (AgentProvider.CLAUDE, PlanningArtifactKind.PHASE_PLAN),
        (AgentProvider.CLAUDE, PlanningArtifactKind.SUBPHASE_CONTRACT),
        (AgentProvider.CODEX, PlanningArtifactKind.MASTER_PLAN),
        (AgentProvider.CODEX, PlanningArtifactKind.PHASE_PLAN),
        (AgentProvider.CODEX, PlanningArtifactKind.SUBPHASE_CONTRACT),
    ],
)
def test_all_provider_artifact_combinations_hydrate(
    tmp_path: Path, provider: AgentProvider, kind: PlanningArtifactKind
) -> None:
    bin_dir = tmp_path / "bin"
    payload = _ARTIFACT_PAYLOADS[kind]()
    artifact_type = _ARTIFACT_TYPES[kind]

    if provider is AgentProvider.CLAUDE:
        _write_fake_provider_executable(bin_dir, name="claude", stdout=json.dumps(payload))
        adapter: AgentAdapter = _claude_planner(executable=str(bin_dir / "claude"))
        expected_name = "claude"
    else:
        _write_fake_provider_executable(bin_dir, name="codex", stdout=json.dumps(payload))
        adapter = _codex_planner(executable=str(bin_dir / "codex"))
        expected_name = "codex"

    runtime = _runtime(tmp_path, planner_adapter=adapter)

    result = invoke_planner_artifact(
        runtime,
        kind=kind,
        prompt="generate the artifact",
        timeout_seconds=5.0,
    )

    assert result.kind is kind
    assert isinstance(result.artifact, artifact_type)
    assert result.invocation.adapter_name == expected_name
    assert result.invocation.role is AgentRole.PLANNER


# ===========================================================================
# Section 57 — cwd bound to project root
# ===========================================================================


def test_invoke_planner_artifact_has_no_cwd_parameter() -> None:
    assert "cwd" not in inspect.signature(invoke_planner_artifact).parameters


def test_planner_invocation_cwd_is_the_project_root(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    result = invoke_planner_artifact(
        runtime,
        kind=PlanningArtifactKind.MASTER_PLAN,
        prompt="generate",
        timeout_seconds=5.0,
    )

    assert result.invocation.process.cwd == runtime.project_root.resolve()
    assert result.invocation.process.cwd != runtime.runtime_dir.resolve()


# ===========================================================================
# Section 58 — exact runtime environment, no widening
# ===========================================================================


def test_structured_planner_invocation_uses_exactly_the_prepared_runtime_environment(
    tmp_path: Path,
) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    home_dir = tmp_path / "home"
    home_dir.mkdir()
    parent_env = {"HOME": str(home_dir), "PATH": str(bin_dir)}
    runtime = _runtime(tmp_path, planner_adapter=adapter, parent_env=parent_env)

    invoke_planner_artifact(
        runtime,
        kind=PlanningArtifactKind.MASTER_PLAN,
        prompt="generate",
        timeout_seconds=5.0,
    )

    invocations = _read_invocations(bin_dir)
    assert len(invocations) == 1
    process_start_env = invocations[0]["process_start_env"]

    if process_start_env is None:
        pytest.skip(
            "/proc/self/environ is unavailable on this host, so the exact "
            "process-start launch environment cannot be observed here; "
            "falling back to ordinary os.environ would not be proof of the "
            "launch environment, only of the fake provider's post-exec state. "
            "Linux/Docker hosts must exercise the exact assertion below."
        )

    assert isinstance(process_start_env, dict)
    assert process_start_env == {"HOME": str(home_dir), "PATH": str(bin_dir)}


# ===========================================================================
# Section 59 — prompt privacy
# ===========================================================================


def test_prompt_is_private_stdin_only(tmp_path: Path) -> None:
    sentinel = "SENTINEL-PROMPT-b7e21c-must-not-leak"
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="codex", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _codex_planner(executable=str(bin_dir / "codex"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    structured_adapter = prepare_structured_planner_adapter(
        adapter,
        canonical_schema=MasterPlan.model_json_schema(),
        runtime_dir=runtime.runtime_dir,
        schema_name="master-plan",
    )
    assert sentinel not in repr(structured_adapter)

    result = invoke_planner_artifact(
        runtime,
        kind=PlanningArtifactKind.MASTER_PLAN,
        prompt=sentinel,
        timeout_seconds=5.0,
    )

    invocations = _read_invocations(bin_dir)
    assert len(invocations) == 1
    entry = invocations[0]
    assert entry["stdin"] == sentinel
    assert sentinel not in json.dumps(entry["argv"])
    assert sentinel not in json.dumps(entry["env"])

    schema_path = (
        runtime.runtime_dir.resolve()
        / "providers"
        / "codex"
        / "planning"
        / "master-plan.schema.json"
    )
    assert sentinel not in schema_path.read_text(encoding="utf-8")
    assert sentinel not in repr(result)


# ===========================================================================
# Section 60 — non-zero exit
# ===========================================================================


def test_nonzero_planner_exit_raises_bounded_transport_error(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    stdout_sentinel = "STDOUT-SENTINEL-do-not-leak"
    stderr_sentinel = "STDERR-SENTINEL-do-not-leak"
    _write_fake_provider_executable(
        bin_dir,
        name="claude",
        stdout=stdout_sentinel,
        stderr=stderr_sentinel,
        returncode=7,
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlanningTransportError) as exc_info:
        invoke_planner_artifact(
            runtime,
            kind=PlanningArtifactKind.MASTER_PLAN,
            prompt="generate",
            timeout_seconds=5.0,
        )

    assert stdout_sentinel not in str(exc_info.value)
    assert stderr_sentinel not in str(exc_info.value)
    assert stdout_sentinel not in exc_info.value.reason
    assert stderr_sentinel not in exc_info.value.reason
    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Section 61 — truncated stdout
# ===========================================================================


def test_truncated_stdout_is_rejected_before_hydration(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    payload = json.dumps(_master_plan_payload())
    _write_fake_provider_executable(bin_dir, name="claude", stdout=payload)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlanningTransportError):
        invoke_planner_artifact(
            runtime,
            kind=PlanningArtifactKind.MASTER_PLAN,
            prompt="generate",
            timeout_seconds=5.0,
            max_output_bytes=8,
        )


# ===========================================================================
# Section 62 — malformed structured output
# ===========================================================================


def test_malformed_stdout_is_rejected(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="not json at all")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlanningTransportError) as exc_info:
        invoke_planner_artifact(
            runtime,
            kind=PlanningArtifactKind.MASTER_PLAN,
            prompt="generate",
            timeout_seconds=5.0,
        )

    assert "not json at all" not in str(exc_info.value)


# ===========================================================================
# Section 63 — wrong artifact shape
# ===========================================================================


def test_wrong_artifact_shape_is_rejected(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_phase_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlanningTransportError):
        invoke_planner_artifact(
            runtime,
            kind=PlanningArtifactKind.MASTER_PLAN,
            prompt="generate",
            timeout_seconds=5.0,
        )


# ===========================================================================
# Section 64 — semantically invalid candidate remains transport-valid
# ===========================================================================


def test_semantically_invalid_candidate_hydrates_but_fails_8_1_validation(
    tmp_path: Path,
) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_duplicate_phase_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    result = invoke_planner_artifact(
        runtime,
        kind=PlanningArtifactKind.MASTER_PLAN,
        prompt="generate",
        timeout_seconds=5.0,
    )

    assert isinstance(result.artifact, MasterPlan)

    with pytest.raises(PlanningValidationError):
        validate_master_plan(result.artifact)  # type: ignore[arg-type]


def test_planning_transport_does_not_import_planning_module() -> None:
    tree = ast.parse(inspect.getsource(planning_transport_module))
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module == "lockstep.planning":
            raise AssertionError("planning_transport.py must not import lockstep.planning")
        if isinstance(node, ast.Import):
            for alias in node.names:
                assert alias.name != "lockstep.planning"


# ===========================================================================
# Section 65 — no persistence
# ===========================================================================


def test_claude_structured_transport_persists_nothing(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    invoke_planner_artifact(
        runtime,
        kind=PlanningArtifactKind.MASTER_PLAN,
        prompt="generate",
        timeout_seconds=5.0,
    )

    assert not (runtime.project_root / ".lockstep").exists()
    assert not (runtime.runtime_dir / "planning").exists()
    assert not (runtime.runtime_dir / "contracts").exists()


def test_codex_structured_transport_persists_only_the_planning_schema_file(
    tmp_path: Path,
) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="codex", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _codex_planner(executable=str(bin_dir / "codex"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    invoke_planner_artifact(
        runtime,
        kind=PlanningArtifactKind.MASTER_PLAN,
        prompt="generate",
        timeout_seconds=5.0,
    )

    assert not (runtime.project_root / ".lockstep").exists()
    assert not (runtime.runtime_dir / "planning").exists()
    assert not (runtime.runtime_dir / "contracts").exists()
    assert _snapshot_relative_files(runtime.runtime_dir) == {
        "providers/codex/planning/master-plan.schema.json"
    }


# ===========================================================================
# Section 66 — exactly one inference per call
# ===========================================================================


def test_exactly_one_inference_per_call_success(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(
        bin_dir, name="claude", stdout=json.dumps(_master_plan_payload())
    )
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    invoke_planner_artifact(
        runtime,
        kind=PlanningArtifactKind.MASTER_PLAN,
        prompt="generate",
        timeout_seconds=5.0,
    )

    assert len(_read_invocations(bin_dir)) == 1


def test_exactly_one_inference_per_call_malformed_output_no_retry(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="garbage")
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(PlanningTransportError):
        invoke_planner_artifact(
            runtime,
            kind=PlanningArtifactKind.MASTER_PLAN,
            prompt="generate",
            timeout_seconds=5.0,
        )

    assert len(_read_invocations(bin_dir)) == 1


# ===========================================================================
# Section 67 — lower-layer exception transparency
# ===========================================================================


def test_environment_policy_error_propagates_unwrapped(tmp_path: Path) -> None:
    adapter = _claude_planner(executable="/nonexistent/claude")
    runtime = _runtime(tmp_path, planner_adapter=adapter, parent_env={})

    with pytest.raises(EnvironmentPolicyError):
        invoke_planner_artifact(
            runtime,
            kind=PlanningArtifactKind.MASTER_PLAN,
            prompt="generate",
            timeout_seconds=5.0,
        )


def test_process_launch_error_propagates_unwrapped(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist" / "claude"
    adapter = _claude_planner(executable=str(missing))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(ProcessLaunchError):
        invoke_planner_artifact(
            runtime,
            kind=PlanningArtifactKind.MASTER_PLAN,
            prompt="generate",
            timeout_seconds=5.0,
        )


def test_process_timeout_error_propagates_unwrapped(tmp_path: Path) -> None:
    bin_dir = tmp_path / "bin"
    _write_fake_provider_executable(bin_dir, name="claude", stdout="irrelevant", sleep_seconds=5.0)
    adapter = _claude_planner(executable=str(bin_dir / "claude"))
    runtime = _runtime(tmp_path, planner_adapter=adapter)

    with pytest.raises(ProcessTimeoutError):
        invoke_planner_artifact(
            runtime,
            kind=PlanningArtifactKind.MASTER_PLAN,
            prompt="generate",
            timeout_seconds=0.3,
        )


def test_base_adapter_billing_mismatch_propagates_unwrapped_claude(tmp_path: Path) -> None:
    adapter = _claude_planner()
    runtime = _runtime(
        tmp_path,
        planner_adapter=adapter,
        planner_billing_mode=BillingMode.API_ALLOWED,
    )

    with pytest.raises(ClaudeAdapterError):
        invoke_planner_artifact(
            runtime,
            kind=PlanningArtifactKind.MASTER_PLAN,
            prompt="generate",
            timeout_seconds=5.0,
        )


def test_base_adapter_billing_mismatch_propagates_unwrapped_codex(tmp_path: Path) -> None:
    adapter = _codex_planner()
    runtime = _runtime(
        tmp_path,
        planner_adapter=adapter,
        planner_billing_mode=BillingMode.API_ALLOWED,
    )

    with pytest.raises(CodexAdapterError):
        invoke_planner_artifact(
            runtime,
            kind=PlanningArtifactKind.MASTER_PLAN,
            prompt="generate",
            timeout_seconds=5.0,
        )


# ===========================================================================
# Section 68 — planning_transport dependency boundary
# ===========================================================================

_FORBIDDEN_PLANNING_TRANSPORT_NAMES: tuple[str, ...] = (
    "ClaudeAdapter",
    "CodexAdapter",
    "ClaudeCliStatus",
    "CodexCliStatus",
    "to_openai_strict_json_schema",
)

_FORBIDDEN_PLANNING_TRANSPORT_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.agents.claude",
    "lockstep.agents.codex",
    "claude",
    "codex",
    "anthropic",
    "openai",
    "lockstep.planning",
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


def test_planning_transport_module_has_no_forbidden_imports() -> None:
    tree = ast.parse(inspect.getsource(planning_transport_module))
    imported_modules, imported_names = _imported_modules_and_names(tree)

    for forbidden in _FORBIDDEN_PLANNING_TRANSPORT_NAMES:
        assert forbidden not in imported_names

    for forbidden_prefix in _FORBIDDEN_PLANNING_TRANSPORT_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


def test_planning_transport_module_does_not_touch_ambient_environment_or_subprocess() -> None:
    tree = ast.parse(inspect.getsource(planning_transport_module))
    attribute_accesses = {node.attr for node in ast.walk(tree) if isinstance(node, ast.Attribute)}
    assert "environ" not in attribute_accesses
    assert "getenv" not in attribute_accesses


# ===========================================================================
# Section 69 — structured_output.py dependency boundary
# ===========================================================================

_FORBIDDEN_STRUCTURED_OUTPUT_MODULE_PREFIXES: tuple[str, ...] = (
    "lockstep.runtime",
    "lockstep.planning",
    "lockstep.git",
    "lockstep.persistence",
    "lockstep.state",
    "lockstep.supervisor",
    "lockstep.verification",
    "lockstep.reporting",
    "lockstep.cli",
    "subprocess",
)


def test_structured_output_module_has_no_forbidden_imports() -> None:
    tree = ast.parse(inspect.getsource(structured_output_module))
    imported_modules, _imported_names = _imported_modules_and_names(tree)

    for forbidden_prefix in _FORBIDDEN_STRUCTURED_OUTPUT_MODULE_PREFIXES:
        assert not any(
            module == forbidden_prefix or module.startswith(forbidden_prefix + ".")
            for module in imported_modules
        )


def test_structured_output_module_os_usage_is_limited_to_durability_primitives() -> None:
    tree = ast.parse(inspect.getsource(structured_output_module))

    forbidden_os_attrs = {"environ", "getenv", "system", "popen"}
    os_attribute_accesses = {
        node.attr
        for node in ast.walk(tree)
        if isinstance(node, ast.Attribute)
        and isinstance(node.value, ast.Name)
        and node.value.id == "os"
    }
    assert not (os_attribute_accesses & forbidden_os_attrs)


# ===========================================================================
# Section — public API surface
# ===========================================================================


def test_existing_public_api_surface_preserved() -> None:
    from lockstep.agents import (
        AgentAdapter,
        AgentCommand,
        AgentInvocationRequest,
        AgentInvocationResult,
        ClaudeAdapter,
        ClaudeAdapterError,
        ClaudeCliStatus,
        ClaudePreflightError,
        CodexAdapter,
        CodexAdapterError,
        CodexCliStatus,
        CodexPreflightError,
        OpenAIStrictSchemaError,
        invoke_agent,
        materialize_codex_review_schema,
        probe_claude_cli,
        probe_codex_cli,
        require_claude_subscription_ready,
        require_codex_subscription_ready,
        to_openai_strict_json_schema,
    )

    for symbol in (
        AgentAdapter,
        AgentCommand,
        AgentInvocationRequest,
        AgentInvocationResult,
        ClaudeAdapter,
        ClaudeAdapterError,
        ClaudeCliStatus,
        ClaudePreflightError,
        CodexAdapter,
        CodexAdapterError,
        CodexCliStatus,
        CodexPreflightError,
        OpenAIStrictSchemaError,
        invoke_agent,
        materialize_codex_review_schema,
        probe_claude_cli,
        probe_codex_cli,
        require_claude_subscription_ready,
        require_codex_subscription_ready,
        to_openai_strict_json_schema,
    ):
        assert symbol is not None


def test_new_public_api_exported_from_lockstep_agents() -> None:
    import lockstep.agents as agents

    assert agents.StructuredOutputAdapterError is StructuredOutputAdapterError
    assert agents.prepare_structured_planner_adapter is prepare_structured_planner_adapter
    assert not hasattr(agents, "_StructuredPlannerAdapter")


def test_structured_output_adapter_error_carries_bounded_reason() -> None:
    error = StructuredOutputAdapterError(reason="short bounded reason")
    assert error.reason == "short bounded reason"


def test_planning_transport_error_carries_bounded_reason() -> None:
    error = PlanningTransportError("short bounded reason")
    assert error.reason == "short bounded reason"


def test_openai_strict_schema_error_still_importable() -> None:
    assert OpenAIStrictSchemaError is not None
