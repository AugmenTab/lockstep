"""Phase 11.4: authority-preserving handoffs through the canonical production factory.

Everything here runs the real production code against recording fake provider
executables, a real Git source repository, and the real planning/cursor/evidence
stores. ``run_project_phase`` is called *without* a ``request_factory``, so the
host-owned canonical factory builds every transaction request, every role
handoff is composed by the host from durable artifacts, and no caller relays
semantic content between roles. JIT replanning stays on (its default).

Baseline classification: every test in this module is RED at entry
(``lockstep.transaction_factory`` / ``lockstep.handoff`` do not exist).
"""

from __future__ import annotations

import json
import shlex
import shutil
import stat
import sys
from collections import Counter
from collections.abc import Callable
from dataclasses import dataclass, replace
from pathlib import Path

import pytest
from test_project_orchestrator import (
    _contract_payload,
    _impl_response,
    _impl_source,
    _make_project,
    _paths_of,
    _phase_plan,
    _review_response,
    _tests_response,
)
from test_supervisor_resume_execution import (
    _budget,
    _claude_adapter,
    _git,
    _init_source_repo,
    _invocation_count,
    _parent_env,
    _review_decision_payload,
)

from lockstep.agents import (
    AgentProviderDiagnostics,
    AgentProviderStatuses,
    ResolvedAgentAdapters,
)
from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.config import ProjectConfig
from lockstep.contract_history import load_archived_subphase_contract
from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    BillingMode,
    ExecutionEventKind,
    ExecutionOutcome,
    MasterPlan,
    PhaseId,
    ProjectId,
    RunId,
    SubphaseContract,
    SubphaseId,
)
from lockstep.evidence_store import (
    load_implementation_report,
    load_verification_evidence,
    load_verification_report,
)
from lockstep.execution_config import ExecutionConfig, ExecutionConfigError
from lockstep.handoff import HandoffError, build_reviewer_handoff, render_reviewer_handoff
from lockstep.jit_replan import load_replan_receipt
from lockstep.metrics import project_runtime_metrics
from lockstep.persistence import ExecutionEvent, read_events
from lockstep.planning_store import (
    PlanningStoreError,
    freeze_master_plan,
    load_active_subphase_contract,
)
from lockstep.project_cursor import ProjectCursorError
from lockstep.project_orchestrator import (
    ProjectOrchestrationError,
    ProjectRunDisposition,
    ProjectRunResult,
    TransactionPlacement,
    run_project_phase,
    step_project_run,
)
from lockstep.runtime import AgentRuntime
from lockstep.transaction_factory import (
    TransactionFactoryError,
    canonical_transaction_request_factory,
)

_PHASE = "01"
_BASELINE = Path(__file__).parent / "baselines" / "transaction_baseline.json"
_PYTEST = (sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider")
_EXECUTION = ExecutionConfig(
    baseline_argv=_PYTEST,
    planner_quality_argv=(sys.executable, "-m", "py_compile"),
    agent_timeout_seconds=60.0,
    command_timeout_seconds=60.0,
)
_FROZEN = "FROZEN REQUIREMENT AUTHORITY"
_PROTECTED = "PROTECTED ACCEPTANCE ARTIFACT"
_SCOPE_CLAIM = "I also need src/outside_scope.py"
_EXPANSION_FINDING = "also add unrelated endpoint Z"


# ---------------------------------------------------------------------------
# A recording fake provider: like the shared fake executable, plus the prompt it was given
# ---------------------------------------------------------------------------

_RECORDING_SCRIPT = """\
import json
import sys
from pathlib import Path

base = Path(__file__).resolve().parent
responses = json.loads((base / "__NAME__-responses.json").read_text(encoding="utf-8"))
count_path = base / "__NAME__-call-count.txt"
index = int(count_path.read_text()) if count_path.exists() else 0
count_path.write_text(str(index + 1))
response = responses[index] if index < len(responses) else responses[-1]

prompt = sys.stdin.read()
(base / f"__NAME__-prompt-{index}.txt").write_text(prompt, encoding="utf-8")
with (base / "__NAME__-invocations.jsonl").open("a", encoding="utf-8") as fh:
    fh.write(json.dumps({"index": index, "cwd": str(Path.cwd())}) + "\\n")

for rel_path, content in response.get("files", {}).items():
    target = Path(rel_path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)

sys.stdout.write(response.get("stdout", ""))
sys.stderr.write(response.get("stderr", ""))
raise SystemExit(int(response.get("returncode", 0)))
"""


def _write_recording_claude(
    bin_dir: Path, *, name: str, responses: list[dict[str, object]]
) -> Path:
    bin_dir.mkdir(parents=True, exist_ok=True)
    (bin_dir / f"{name}-responses.json").write_text(json.dumps(responses), encoding="utf-8")
    executable = bin_dir / name
    executable.write_text(
        f"#!{sys.executable}\n" + _RECORDING_SCRIPT.replace("__NAME__", name), encoding="utf-8"
    )
    executable.chmod(executable.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


# ---------------------------------------------------------------------------
# Scripted provider responses
# ---------------------------------------------------------------------------


def _verify_command(sid: str) -> str:
    return " ".join(shlex.quote(part) for part in (*_PYTEST, f"tests/test_feature_{sid}.py"))


def _contract_response(sid: str, **overrides: object) -> dict[str, object]:
    payload = {**_contract_payload(sid), "verification_commands": [_verify_command(sid)]}
    payload.update(overrides)
    return {"stdout": json.dumps(payload), "returncode": 0}


def _replan_response(sids: tuple[str, ...]) -> dict[str, object]:
    return {"stdout": json.dumps(_phase_plan(sids).model_dump(mode="json")), "returncode": 0}


def _planner_script(sids: tuple[str, ...], *, replan: bool = True) -> list[dict[str, object]]:
    script: list[dict[str, object]] = []
    for index, sid in enumerate(sids):
        script.append(_contract_response(sid))
        script.append(_tests_response(sid))
        if replan and index < len(sids) - 1:
            script.append(_replan_response(sids))
    return script


def _implementation(
    sid: str, summary: str, *, verbose: bool = False, deviations: tuple[str, ...] = ()
) -> dict[str, object]:
    report = {
        "summary": summary,
        "changed_files": [f"feature_{sid}.py"],
        "deviations": list(deviations),
    }
    return {
        "stdout": json.dumps(
            {"status": "completed", "implementation_report": report, "blocker": None}
        ),
        "returncode": 0,
        "files": {f"feature_{sid}.py": _impl_source(sid, verbose=verbose)},
    }


def _review(
    sid: str, *, attempt: int, verdict: str, findings: list[dict[str, object]] | None = None
) -> dict[str, object]:
    decision = _review_decision_payload(
        phase_id=_PHASE,
        subphase_id=sid,
        attempt=attempt,
        verdict=verdict,
        summary=f"{verdict} {sid}",
        findings=findings,
    )
    return {
        "stdout": json.dumps({"status": "completed", "review_decision": decision, "blocker": None}),
        "returncode": 0,
    }


# ---------------------------------------------------------------------------
# Project construction
# ---------------------------------------------------------------------------


@dataclass(frozen=True, slots=True)
class _Canon:
    root: Path
    source: Path
    project_root: Path
    runtime_dir: Path
    runtime: AgentRuntime
    bins: dict[str, Path]
    sids: tuple[str, ...]

    def launches(self, role: str) -> int:
        return _invocation_count(self.bins[role], f"claude-{role}")

    def counts(self) -> tuple[int, int, int]:
        return (self.launches("planner"), self.launches("implementer"), self.launches("reviewer"))

    def prompt(self, role: str, index: int) -> str:
        path = self.bins[role] / f"claude-{role}-prompt-{index}.txt"
        return path.read_text(encoding="utf-8")

    def run_id(self, sid: str) -> RunId:
        return RunId.model_validate(f"run-{_PHASE}-{sid}")

    def txn_dir(self, sid: str) -> Path:
        return self.runtime_dir / "transactions" / self.run_id(sid).root

    def worktree(self, sid: str) -> Path:
        return self.runtime_dir / "worktrees" / self.run_id(sid).root

    def run(self, *, budget: int = 3, **kwargs: object) -> ProjectRunResult:
        return run_project_phase(
            self.runtime,
            retry_budget=_budget(budget),
            planning_timeout_seconds=60.0,
            **kwargs,  # type: ignore[arg-type]
        )

    def kinds(self, sid: str) -> Counter[ExecutionEventKind]:
        return Counter(
            e.kind
            for e in read_events(self.txn_dir(sid) / "events.jsonl")
            if isinstance(e, ExecutionEvent)
        )

    def tests_frozen_sha(self, sid: str) -> str:
        [sha] = [
            e.detail
            for e in read_events(self.txn_dir(sid) / "events.jsonl")
            if isinstance(e, ExecutionEvent) and e.kind is ExecutionEventKind.TESTS_FROZEN
        ]
        assert sha is not None
        return sha


def _make_canonical(
    tmp_path: Path,
    *,
    sids: tuple[str, ...] = ("01", "02"),
    planner: list[dict[str, object]] | None = None,
    implementer: list[dict[str, object]] | None = None,
    reviewer: list[dict[str, object]] | None = None,
    execution: ExecutionConfig = _EXECUTION,
) -> _Canon:
    root = tmp_path / "world"
    root.mkdir()
    # Production composition: the project root is itself the clean Git source checkout,
    # and the frozen Master Plan is tracked in it.
    source = _init_source_repo(root)
    project_root = source
    runtime_dir = root / "runtime"
    runtime_dir.mkdir()

    freeze_master_plan(
        project_root,
        MasterPlan(
            project_id=ProjectId.model_validate("lockstep"),
            title="Lockstep",
            objective="Build the control plane.",
            phases=(_phase_plan(sids),),
        ),
    )
    _git(source, "add", "-A")
    _git(source, "commit", "-m", "freeze master plan")

    scripts = {
        "planner": planner if planner is not None else _planner_script(sids),
        "implementer": (
            implementer if implementer is not None else [_impl_response(sid) for sid in sids]
        ),
        "reviewer": (reviewer if reviewer is not None else [_review_response(sid) for sid in sids]),
    }
    roles = {
        "planner": AgentRole.PLANNER,
        "implementer": AgentRole.IMPLEMENTER,
        "reviewer": AgentRole.REVIEWER,
    }
    bins: dict[str, Path] = {}
    adapters = {}
    for role, responses in scripts.items():
        bins[role] = root / f"{role}-bin"
        _write_recording_claude(bins[role], name=f"claude-{role}", responses=responses)
        adapters[role] = _claude_adapter(roles[role], executable=str(bins[role] / f"claude-{role}"))

    route = AgentRoleRoute(
        provider=AgentProvider.CLAUDE,
        model="unused-model",
        effort="unused-effort",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )
    runtime = AgentRuntime(
        project_root=project_root,
        runtime_dir=runtime_dir,
        config=ProjectConfig(
            schema_version=1,
            routing=AgentRoutingPolicy(planner=route, implementer=route, reviewer=route),
            execution=execution,
        ),
        diagnostics=AgentProviderDiagnostics(statuses=AgentProviderStatuses()),
        adapters=ResolvedAgentAdapters(
            planner=adapters["planner"],
            implementer=adapters["implementer"],
            reviewer=adapters["reviewer"],
        ),
        transaction_parent_env=_parent_env(root),
    )
    return _Canon(
        root=root,
        source=source,
        project_root=project_root,
        runtime_dir=runtime_dir,
        runtime=runtime,
        bins=bins,
        sids=sids,
    )


def _sections(text: str) -> dict[str, str]:
    import re

    pattern = re.compile(r"^## (?P<title>[A-Z /]+?) \[(?P<authority>[a-z_]+)\]$", re.MULTILINE)
    matches = list(pattern.finditer(text))
    return {
        m["title"]: text[m.end() : matches[i + 1].start() if i + 1 < len(matches) else len(text)]
        for i, m in enumerate(matches)
    }


def _json(section: str) -> dict[str, object]:
    value = json.JSONDecoder().raw_decode(section.lstrip())[0]
    assert isinstance(value, dict)
    return value


def _ids(sid: str) -> tuple[PhaseId, SubphaseId]:
    return PhaseId.model_validate(_PHASE), SubphaseId.model_validate(sid)


@pytest.fixture(scope="module")
def two_run(tmp_path_factory: pytest.TempPathFactory) -> tuple[_Canon, ProjectRunResult]:
    project = _make_canonical(tmp_path_factory.mktemp("canonical"))
    return project, project.run()  # no request_factory; jit_replan left at its default


# ===========================================================================
# Scenario A/J/L: the canonical factory is the default and drives two Sub-phases
# ===========================================================================


def test_a_default_run_completes_two_subphases_with_the_canonical_factory_and_default_jit(
    two_run: tuple[_Canon, ProjectRunResult],
) -> None:
    project, result = two_run

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert [e.subphase_id.root for e in result.cursor.completed_subphases] == ["01", "02"]
    # planner: (contract + tests) per Sub-phase plus one JIT replan between them.
    assert project.counts() == (5, 2, 2)
    receipt = load_replan_receipt(project.project_root, project.runtime_dir, project.run_id("01"))
    assert receipt is not None


def test_commit_messages_are_deterministic_host_policy_and_agent_prose_is_not_used(
    two_run: tuple[_Canon, ProjectRunResult],
) -> None:
    project, _ = two_run

    subjects = _git(project.worktree("02"), "log", "--format=%s").stdout.splitlines()
    assert subjects == [
        "feat(01.02): accepted implementation",
        "test(01.02): freeze acceptance tests",
        "feat(01.01): accepted implementation",
        "test(01.01): freeze acceptance tests",
        "freeze master plan",
        "initial",
    ]


def test_every_child_transaction_is_one_measurable_verification_stage_and_baseline_v1_holds(
    two_run: tuple[_Canon, ProjectRunResult],
) -> None:
    project, _ = two_run

    for sid in project.sids:
        assert project.kinds(sid)[ExecutionEventKind.VERIFICATION_COMPLETED] == 1
        totals = project_runtime_metrics(project.txn_dir(sid), repository_change=None).totals
        assert (totals.subphases_attempted, totals.subphases_completed) == (1, 1)
    assert json.loads(_BASELINE.read_text())["baseline_version"] == 1


# ===========================================================================
# Durable Implementation / Verification evidence
# ===========================================================================


def test_each_attempt_leaves_typed_durable_report_and_evidence(
    two_run: tuple[_Canon, ProjectRunResult],
) -> None:
    project, _ = two_run
    for sid in project.sids:
        phase_id, subphase_id = _ids(sid)
        attempt = AttemptNumber.model_validate(1)
        runtime = project.txn_dir(sid)

        implementation = load_implementation_report(
            runtime, phase_id=phase_id, subphase_id=subphase_id, attempt=attempt
        )
        verification = load_verification_report(
            runtime, phase_id=phase_id, subphase_id=subphase_id, attempt=attempt
        )
        evidence = load_verification_evidence(
            runtime,
            run_id=project.run_id(sid),
            phase_id=phase_id,
            subphase_id=subphase_id,
            attempt=attempt,
        )

        assert implementation is not None and implementation.summary
        assert verification is not None and verification.passed is True
        assert evidence is not None
        assert [c.exit_code for c in evidence.commands] == [0]
        assert evidence.commands[0].argv[0] == sys.executable
        assert verification.commands == (shlex.join(evidence.commands[0].argv),)


# ===========================================================================
# Scenario B/D: the handoffs the roles actually receive
# ===========================================================================


def test_the_planner_test_handoff_carries_the_frozen_contract_and_required_tests(
    two_run: tuple[_Canon, ProjectRunResult],
) -> None:
    project, result = two_run
    sections = _sections(project.prompt("planner", 1))  # call 0 plans the Contract

    digest = result.cursor.completed_subphases[0].contract_digest
    assert _json(sections[_FROZEN])["contract_digest"] == digest
    assert "tests/test_feature_01.py" in sections["REQUIRED TEST PATHS"]


def test_the_implementer_handoff_binds_contract_tests_paths_and_the_accepted_basis(
    two_run: tuple[_Canon, ProjectRunResult],
) -> None:
    project, result = two_run

    first = _sections(project.prompt("implementer", 0))
    frozen = _json(first[_FROZEN])
    assert frozen["contract_digest"] == result.cursor.completed_subphases[0].contract_digest
    assert frozen["contract"]["allowed_paths"] == ["feature_01.py"]  # type: ignore[index]
    protected = _json(first[_PROTECTED])
    assert protected["test_commit_sha"] == project.tests_frozen_sha("01")
    assert protected["test_paths"] == ["tests/test_feature_01.py"]
    basis = _json(first["REPOSITORY BASIS"])
    assert basis["basis_commit_sha"] == _git(project.source, "rev-parse", "HEAD").stdout.strip()

    # Sub-phase 02's basis is Sub-phase 01's accepted implementation commit.
    second = _sections(project.prompt("implementer", 1))
    accepted = _git(project.worktree("01"), "rev-parse", "HEAD").stdout.strip()
    assert _json(second["REPOSITORY BASIS"])["basis_commit_sha"] == accepted


def test_the_reviewer_handoff_is_built_late_from_separate_authority_and_evidence(
    two_run: tuple[_Canon, ProjectRunResult],
) -> None:
    project, result = two_run
    prompt = project.prompt("reviewer", 0)
    sections = _sections(prompt)

    assert list(sections) == [
        _FROZEN,
        _PROTECTED,
        "IMPLEMENTER EVIDENCE",
        "VERIFICATION EVIDENCE",
        "REPOSITORY EVIDENCE",
        "REVIEW HISTORY",
    ]
    assert _json(sections[_FROZEN])["contract_digest"] == (
        result.cursor.completed_subphases[0].contract_digest
    )
    assert _json(sections[_PROTECTED])["test_commit_sha"] == project.tests_frozen_sha("01")
    assert "Implemented the requested change." in sections["IMPLEMENTER EVIDENCE"]
    verification = _json(sections["VERIFICATION EVIDENCE"])
    assert verification["report"]["passed"] is True  # type: ignore[index]
    assert verification["commands"]["commands"][0]["exit_code"] == 0  # type: ignore[index]
    repository = _json(sections["REPOSITORY EVIDENCE"])
    assert repository["base_commit_sha"] == project.tests_frozen_sha("01")
    [change] = repository["changes"]  # type: ignore[misc]
    assert change["path"] == "feature_01.py" and change["status"] == "added"
    assert "return 1" in change["patch"]
    assert "Reviewer identity (host-supplied" in prompt


def test_the_reviewer_handoff_rebuilds_identically_from_durable_state_alone(
    two_run: tuple[_Canon, ProjectRunResult],
) -> None:
    project, result = two_run
    entry = result.cursor.completed_subphases[0]
    contract = load_archived_subphase_contract(
        project.project_root,
        project.runtime_dir,
        phase_id=entry.phase_id,
        subphase_id=entry.subphase_id,
        contract_digest=entry.contract_digest,
    )
    assert contract is not None

    # Nothing from the original run is reused: only paths, ids, the archived Contract and Git.
    rebuilt = build_reviewer_handoff(
        runtime_dir=project.txn_dir("01"),
        worktree_path=project.worktree("01"),
        run_id=project.run_id("01"),
        phase_id=entry.phase_id,
        subphase_id=entry.subphase_id,
        attempt=AttemptNumber.model_validate(1),
        contract=contract,
        test_paths=("tests/test_feature_01.py",),
        prior_decisions=(),
    )

    assert render_reviewer_handoff(rebuilt) in project.prompt("reviewer", 0)


# ===========================================================================
# Complete verification stack, one stage
# ===========================================================================


def test_every_contract_verification_command_runs_in_one_stage_and_report(tmp_path: Path) -> None:
    second = " ".join(shlex.quote(p) for p in (sys.executable, "-c", "print('second')"))
    project = _make_canonical(
        tmp_path,
        sids=("01",),
        planner=[
            _contract_response("01", verification_commands=[_verify_command("01"), second]),
            _tests_response("01"),
        ],
    )

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert project.kinds("01")[ExecutionEventKind.VERIFICATION_COMPLETED] == 1
    phase_id, subphase_id = _ids("01")
    attempt = AttemptNumber.model_validate(1)
    report = load_verification_report(
        project.txn_dir("01"), phase_id=phase_id, subphase_id=subphase_id, attempt=attempt
    )
    evidence = load_verification_evidence(
        project.txn_dir("01"),
        run_id=project.run_id("01"),
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=attempt,
    )
    assert report is not None and evidence is not None
    assert len(report.commands) == 2
    assert [c.exit_code for c in evidence.commands] == [0, 0]
    assert evidence.commands[1].stdout.strip() == "second"


def test_a_failing_verification_command_stops_the_stack_and_never_reaches_the_reviewer(
    tmp_path: Path,
) -> None:
    failing = " ".join(shlex.quote(p) for p in (sys.executable, "-c", "raise SystemExit(5)"))
    never = " ".join(shlex.quote(p) for p in (sys.executable, "-c", "print('never')"))
    project = _make_canonical(
        tmp_path,
        sids=("01",),
        planner=[
            _contract_response("01", verification_commands=[_verify_command("01"), failing, never]),
            _tests_response("01"),
        ],
    )

    result = project.run()

    assert result.disposition is ProjectRunDisposition.EXECUTION_FAILED
    assert project.launches("reviewer") == 0
    phase_id, subphase_id = _ids("01")
    attempt = AttemptNumber.model_validate(1)
    report = load_verification_report(
        project.txn_dir("01"), phase_id=phase_id, subphase_id=subphase_id, attempt=attempt
    )
    evidence = load_verification_evidence(
        project.txn_dir("01"),
        run_id=project.run_id("01"),
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=attempt,
    )
    assert report is not None and report.passed is False and len(report.commands) == 2
    assert evidence is not None and [c.exit_code for c in evidence.commands] == [0, 5]
    completed = [
        e
        for e in read_events(project.txn_dir("01") / "events.jsonl")
        if isinstance(e, ExecutionEvent) and e.kind is ExecutionEventKind.VERIFICATION_COMPLETED
    ]
    assert [e.outcome for e in completed] == [ExecutionOutcome.FAILURE]


# ===========================================================================
# Authority is not inflated by evidence
# ===========================================================================


def test_an_implementation_report_scope_request_never_becomes_authority(tmp_path: Path) -> None:
    project = _make_canonical(
        tmp_path,
        sids=("01",),
        implementer=[_implementation("01", "did it", deviations=(_SCOPE_CLAIM,))],
    )

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert _paths_of(project.worktree("01"), "feat(01.01): accepted implementation") == (
        "feature_01.py",
    )
    assert not (project.worktree("01") / "src" / "outside_scope.py").exists()
    sections = _sections(project.prompt("reviewer", 0))
    assert _SCOPE_CLAIM in sections["IMPLEMENTER EVIDENCE"]
    for title, body in sections.items():
        if title != "IMPLEMENTER EVIDENCE":
            assert "outside_scope" not in body
    assert _json(sections[_FROZEN])["contract"]["allowed_paths"] == ["feature_01.py"]  # type: ignore[index]
    entry = result.cursor.completed_subphases[0]
    assert _json(sections[_FROZEN])["contract_digest"] == entry.contract_digest
    assert load_active_subphase_contract(project.project_root, project.runtime_dir) is None


def _rework_run(tmp_path: Path) -> tuple[_Canon, ProjectRunResult]:
    finding = {
        "summary": _EXPANSION_FINDING,
        "evidence": "requested by the reviewer",
        "file_path": None,
        "acceptance_criterion_id": None,
    }
    project = _make_canonical(
        tmp_path,
        sids=("01",),
        implementer=[
            _implementation("01", "attempt one summary", verbose=True),
            _implementation("01", "attempt two summary"),
        ],
        reviewer=[
            _review("01", attempt=1, verdict="rework", findings=[finding]),
            _review("01", attempt=2, verdict="approve"),
        ],
    )
    return project, project.run()


def test_rework_gives_a_fresh_implementer_the_original_authority_and_findings_as_evidence(
    tmp_path: Path,
) -> None:
    project, result = _rework_run(tmp_path)

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert project.counts() == (2, 2, 2)
    first_prompt, second_prompt = project.prompt("implementer", 0), project.prompt("implementer", 1)
    first, second = _sections(first_prompt), _sections(second_prompt)

    # Contract authority is byte-identical across attempts.
    assert first[_FROZEN] == second[_FROZEN]
    assert _json(second[_FROZEN])["contract"]["allowed_paths"] == ["feature_01.py"]  # type: ignore[index]
    assert _json(second[_FROZEN])["contract_digest"] == (
        result.cursor.completed_subphases[0].contract_digest
    )
    assert first[_PROTECTED] == second[_PROTECTED]

    # The finding is repair evidence, not authority and not retry control.
    assert _EXPANSION_FINDING not in first_prompt
    assert _EXPANSION_FINDING in second["REVIEW EVIDENCE / REPAIR GUIDANCE"]
    for title, body in second.items():
        if title != "REVIEW EVIDENCE / REPAIR GUIDANCE":
            assert _EXPANSION_FINDING not in body
    assert "resume authority" not in second_prompt.lower()
    assert _json(second["RETRY CONTROL AUTHORITY"])["authorized_paths"] == []

    # Reproduction evidence from the previous attempt is carried distinctly.
    assert _json(second["VERIFICATION EVIDENCE"])["report"]["attempt"] == 1  # type: ignore[index]


def test_a_finding_that_asks_for_new_behavior_never_mutates_the_contract(tmp_path: Path) -> None:
    project, result = _rework_run(tmp_path)

    entry = result.cursor.completed_subphases[0]
    archived = load_archived_subphase_contract(
        project.project_root,
        project.runtime_dir,
        phase_id=entry.phase_id,
        subphase_id=entry.subphase_id,
        contract_digest=entry.contract_digest,
    )
    assert archived is not None
    assert archived.allowed_paths == ("feature_01.py",)
    assert _EXPANSION_FINDING not in archived.model_dump_json()
    assert _paths_of(project.worktree("01"), "feat(01.01): accepted implementation") == (
        "feature_01.py",
    )


def test_the_second_reviewer_sees_prior_findings_as_history_and_the_new_attempts_evidence(
    tmp_path: Path,
) -> None:
    project, _ = _rework_run(tmp_path)

    sections = _sections(project.prompt("reviewer", 1))

    assert _EXPANSION_FINDING in sections["REVIEW HISTORY"]
    assert "attempt two summary" in sections["IMPLEMENTER EVIDENCE"]
    assert "attempt one summary" not in sections["IMPLEMENTER EVIDENCE"]
    assert _json(sections["VERIFICATION EVIDENCE"])["report"]["attempt"] == 2  # type: ignore[index]


# ===========================================================================
# Drift fails closed before any role launches
# ===========================================================================


def test_a_substituted_active_contract_is_rejected_before_any_implementer_launch(
    tmp_path: Path,
) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    assert (
        step_project_run(project.runtime, retry_budget=_budget(3), planning_timeout_seconds=60.0)
        is None
    )  # plan, freeze and bind
    active = project.runtime_dir / "contracts" / "active.json"
    document = json.loads(active.read_text(encoding="utf-8"))
    document["title"] = "A substituted Contract"
    active.write_text(json.dumps(document), encoding="utf-8")

    with pytest.raises((ProjectOrchestrationError, PlanningStoreError, ProjectCursorError)):
        step_project_run(project.runtime, retry_budget=_budget(3), planning_timeout_seconds=60.0)

    assert project.counts() == (1, 0, 0)


def test_the_reviewer_handoff_refuses_a_run_that_does_not_own_the_evidence(
    tmp_path: Path,
) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    result = project.run()
    entry = result.cursor.completed_subphases[0]
    contract = load_archived_subphase_contract(
        project.project_root,
        project.runtime_dir,
        phase_id=entry.phase_id,
        subphase_id=entry.subphase_id,
        contract_digest=entry.contract_digest,
    )
    assert contract is not None

    def rebuild(run_id: RunId) -> object:
        return build_reviewer_handoff(
            runtime_dir=project.txn_dir("01"),
            worktree_path=project.worktree("01"),
            run_id=run_id,
            phase_id=entry.phase_id,
            subphase_id=entry.subphase_id,
            attempt=AttemptNumber.model_validate(1),
            contract=contract,
            test_paths=("tests/test_feature_01.py",),
            prior_decisions=(),
        )

    rebuild(project.run_id("01"))
    with pytest.raises(HandoffError):
        rebuild(RunId.model_validate("run-01-99"))

    # A protected test that no longer matches the frozen test commit is drift.
    test_file = project.worktree("01") / "tests" / "test_feature_01.py"
    test_file.write_text(test_file.read_text() + "\n# tampered\n", encoding="utf-8")
    with pytest.raises(HandoffError):
        rebuild(project.run_id("01"))


# ===========================================================================
# The canonical factory
# ===========================================================================


def _placement(project: _Canon) -> TransactionPlacement:
    return TransactionPlacement(
        run_id=project.run_id("01"),
        runtime_dir=project.txn_dir("01"),
        worktree_path=project.worktree("01"),
        branch="lockstep/run/run-01-01",
        base_branch=None,
    )


def _contract(sid: str = "01", **overrides: object) -> SubphaseContract:
    payload = {**_contract_payload(sid), "verification_commands": [_verify_command(sid)]}
    payload.update(overrides)
    return SubphaseContract.model_validate(payload)


def test_exact_paths_build_a_canonical_request_from_config_contract_and_placement(
    tmp_path: Path,
) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    factory = canonical_transaction_request_factory(project.runtime)
    contract = _contract()

    request = factory(contract, _placement(project))

    assert request.project_id == ProjectId.model_validate("lockstep")
    assert request.run_id == project.run_id("01")
    assert request.source_path == project.project_root.resolve()
    assert request.implementation_paths == ("feature_01.py",)
    assert request.test_paths == ("tests/test_feature_01.py",)
    assert request.verification_commands == ((*_PYTEST, "tests/test_feature_01.py"),)
    assert request.baseline_argv == (*_PYTEST, "tests/test_feature_01.py")
    assert request.planner_quality_argv == (
        sys.executable,
        "-m",
        "py_compile",
        "tests/test_feature_01.py",
    )
    assert request.agent_timeout_seconds == 60.0
    assert request.command_timeout_seconds == 60.0
    assert request.max_output_bytes == _EXECUTION.max_output_bytes
    assert request.termination_grace_seconds == _EXECUTION.termination_grace_seconds
    assert request.billing_mode is BillingMode.SUBSCRIPTION_ONLY
    assert request.test_commit_message == "test(01.01): freeze acceptance tests"
    assert request.implementation_commit_message == "feat(01.01): accepted implementation"
    assert request.contract == contract
    assert _FROZEN in _sections(request.planner_prompt)


@pytest.mark.parametrize(
    "allowed",
    [
        "src/**/*.py",
        "src/*.py",
        "src/a?.py",
        "src/[ab].py",
        "src/{a,b}.py",
        "/etc/passwd",
        "../x.py",
    ],
)
def test_unsupported_path_syntax_in_allowed_paths_fails_closed_without_expansion(
    tmp_path: Path, allowed: str
) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    factory = canonical_transaction_request_factory(project.runtime)

    with pytest.raises(TransactionFactoryError):
        factory(_contract(allowed_paths=[allowed]), _placement(project))


@pytest.mark.parametrize("test_path", ["tests/test_*.py", "tests/**/test_a.py", "tests/t[12].py"])
def test_unsupported_path_syntax_in_test_paths_fails_closed(tmp_path: Path, test_path: str) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    factory = canonical_transaction_request_factory(project.runtime)
    tests = [{"path": test_path, "expectation": "red", "acceptance_criteria": ["AC-1"]}]

    with pytest.raises(TransactionFactoryError):
        factory(_contract(tests=tests), _placement(project))


def test_shell_syntax_in_a_contract_verification_command_fails_closed(tmp_path: Path) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    factory = canonical_transaction_request_factory(project.runtime)

    with pytest.raises(TransactionFactoryError):
        factory(
            _contract(verification_commands=["pytest tests/a.py && ruff check"]),
            _placement(project),
        )


# ---------------------------------------------------------------------------
# execution.verification_prefix_argv: tracked policy says where verification runs
# ---------------------------------------------------------------------------

_DOCKER_PREFIX = ("docker", "compose", "run", "--rm", "dev")


def test_without_a_prefix_contract_verification_argv_is_unchanged(tmp_path: Path) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    factory = canonical_transaction_request_factory(project.runtime)

    request = factory(
        _contract(verification_commands=["npm run build", "npm test"]), _placement(project)
    )

    assert request.verification_commands == (("npm", "run", "build"), ("npm", "test"))
    assert request.verification_argv == ("npm", "run", "build")


def test_a_configured_prefix_is_prepended_to_every_verification_command_in_order(
    tmp_path: Path,
) -> None:
    execution = replace(
        _EXECUTION,
        verification_prefix_argv=_DOCKER_PREFIX,
        phase_gate_commands=(("./scripts/test",),),
    )
    project = _make_canonical(tmp_path, sids=("01",), execution=execution)
    factory = canonical_transaction_request_factory(project.runtime)
    commands = [
        "npm run build",
        "node --test dist/test/a.test.js dist/test/b.test.js",
        "npm test",
    ]
    contract = _contract(verification_commands=commands)
    before = contract.model_dump()

    request = factory(contract, _placement(project))

    assert request.verification_commands == (
        (*_DOCKER_PREFIX, "npm", "run", "build"),
        (*_DOCKER_PREFIX, "node", "--test", "dist/test/a.test.js", "dist/test/b.test.js"),
        (*_DOCKER_PREFIX, "npm", "test"),
    )
    assert request.verification_argv == (*_DOCKER_PREFIX, "npm", "run", "build")
    # The Contract is authority and is never rewritten by environment policy.
    assert request.contract == contract
    assert contract.model_dump() == before
    assert tuple(contract.verification_commands) == tuple(commands)
    assert tuple(request.contract.verification_commands) == tuple(commands)
    # The prefix belongs to Contract verification only.
    assert request.baseline_argv == (*_PYTEST, "tests/test_feature_01.py")
    assert request.planner_quality_argv == (
        sys.executable,
        "-m",
        "py_compile",
        "tests/test_feature_01.py",
    )
    assert project.runtime.config.execution.phase_gate_commands == (("./scripts/test",),)


def test_a_prefix_does_not_relax_shell_free_contract_verification_parsing(
    tmp_path: Path,
) -> None:
    execution = replace(_EXECUTION, verification_prefix_argv=_DOCKER_PREFIX)
    project = _make_canonical(tmp_path, sids=("01",), execution=execution)
    factory = canonical_transaction_request_factory(project.runtime)

    with pytest.raises(TransactionFactoryError):
        factory(_contract(verification_commands=["npm run build && npm test"]), _placement(project))


_ENTER_ENV_SCRIPT = """\
import json
import os
import sys
from pathlib import Path

kit = Path(__file__).resolve().parent
with (kit / "entered.jsonl").open("a", encoding="utf-8") as fh:
    fh.write(json.dumps(sys.argv[1:]) + "\\n")
os.environ["PATH"] = str(kit / "inner") + os.pathsep + os.environ.get("PATH", "")
os.execvp(sys.argv[1], sys.argv[1:])
"""

_ONLY_IN_ENV_SCRIPT = """\
import sys

print("inside env:" + " ".join(sys.argv[1:]))
"""


def _write_executable(path: Path, body: str) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(f"#!{sys.executable}\n" + body, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return path


def test_verification_launches_through_the_prefix_into_an_environment_the_host_lacks(
    tmp_path: Path,
) -> None:
    # Regression for the black-demo dogfood defect: the Contract names a tool that exists only
    # inside the project's verification environment. Without a prefix it was launched directly
    # on the host and failed; with the tracked prefix it runs through the environment entry.
    kit = tmp_path / "envkit"
    enter_env = _write_executable(kit / "enter-env", _ENTER_ENV_SCRIPT)
    _write_executable(kit / "inner" / "only-in-env", _ONLY_IN_ENV_SCRIPT)
    host_path = _parent_env(tmp_path / "probe")["PATH"]
    assert shutil.which("only-in-env", path=host_path) is None

    execution = replace(_EXECUTION, verification_prefix_argv=(str(enter_env),))
    project = _make_canonical(
        tmp_path,
        sids=("01",),
        planner=[
            _contract_response(
                "01", verification_commands=[_verify_command("01"), "only-in-env build"]
            ),
            _tests_response("01"),
        ],
        execution=execution,
    )

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    entered = [
        json.loads(line)
        for line in (kit / "entered.jsonl").read_text(encoding="utf-8").splitlines()
    ]
    # Only Contract verification entered the environment, once per command, in order;
    # the baseline and Planner-quality commands ran directly.
    assert entered == [[*_PYTEST, "tests/test_feature_01.py"], ["only-in-env", "build"]]
    phase_id, subphase_id = _ids("01")
    evidence = load_verification_evidence(
        project.txn_dir("01"),
        run_id=project.run_id("01"),
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=AttemptNumber.model_validate(1),
    )
    assert evidence is not None
    assert [c.argv for c in evidence.commands] == [
        (str(enter_env), *_PYTEST, "tests/test_feature_01.py"),
        (str(enter_env), "only-in-env", "build"),
    ]
    assert [c.exit_code for c in evidence.commands] == [0, 0]
    assert evidence.commands[1].stdout.strip() == "inside env:build"


def test_a_wildcard_contract_fails_before_test_authoring_or_any_implementer_launch(
    tmp_path: Path,
) -> None:
    project = _make_canonical(
        tmp_path,
        sids=("01",),
        planner=[_contract_response("01", allowed_paths=["feature_**.py"]), _tests_response("01")],
    )

    with pytest.raises(TransactionFactoryError):
        project.run()

    assert project.counts() == (1, 0, 0)  # only the Contract-planning call
    assert not project.worktree("01").exists()


def test_an_unconfigured_project_is_not_ready_for_autonomous_execution(tmp_path: Path) -> None:
    project = _make_canonical(tmp_path, sids=("01",), execution=ExecutionConfig())

    with pytest.raises(ExecutionConfigError):
        project.run()

    assert project.counts() == (0, 0, 0)


def test_an_explicit_factory_is_still_used_instead_of_the_canonical_one(tmp_path: Path) -> None:
    legacy = _make_project(tmp_path, sids=("01",))  # no [execution] configured at all
    calls: list[str] = []
    build: Callable[..., object] = legacy.factory

    def injected(contract: SubphaseContract, placement: TransactionPlacement) -> object:
        calls.append(contract.subphase_id.root)
        return build(contract, placement)

    result = run_project_phase(
        legacy.runtime,
        request_factory=injected,  # type: ignore[arg-type]
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
        jit_replan=False,
    )

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert calls and set(calls) == {"01"}
