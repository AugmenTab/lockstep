"""Phase 12.10-R1: project-level planning basis, ContextPack, identity and invocation evidence.

Every project-level Planner operation that reasons about current or future implementation
runs from the authoritative accepted repository basis, receives a host-assembled ContextPack
of its own operation, carries a host-owned :class:`PlanningInvocationIdentity`, and leaves
durable STARTED / RETURNED evidence in ``<runtime>/planning/invocations.jsonl``::

    | Operation                    | Basis                     | Context              | Journal |
    | Master Plan creation         | source project            | legacy requirements  | none    |
    | Phase planning, no history   | source project            | phase_planning pack  | yes     |
    | Phase planning, history      | latest accepted basis     | phase_planning pack  | yes     |
    | Contract planning, first     | source project            | contract_planning    | yes     |
    | Contract planning, history   | latest accepted basis     | contract_planning    | yes     |
    | JIT replanning               | existing accepted basis   | existing jit_replan  | yes     |
    | Gate remediation             | existing gate basis       | gate_remediation     | yes     |
    | Planner test authoring       | transaction worktree      | existing             | child   |

Everything runs the real production code against scripted fake provider executables, real
Git repositories and worktrees, and the real durable stores. No real Claude/Codex account,
network, or model inference is used.

Baseline classification at entry (386e087 + the R1 test-correction commit): the planning
identity, journal, basis and new ContextPack tests are RED (``lockstep.planning_invocation``
does not exist, Contract and Phase planning run in the source checkout with no ContextPack,
and nothing is journaled). The transaction-identity, Master Plan and child-metric
characterizations are GREEN by design.
"""

from __future__ import annotations

import dataclasses
import importlib
import json
import shutil
import stat
import subprocess
import sys
import textwrap
from pathlib import Path
from types import ModuleType, SimpleNamespace
from typing import Any

import pytest
from phase_gate_support import (
    CRITERIA,
    GateProject,
    finding,
    gate_review_response,
    passing_command,
    remediation_plan_response,
    standard_project,
    unit_script,
)
from test_contract_test_targets import _bad_response
from test_project_orchestrator import (
    _BASELINE,
    _contract_payload,
    _contract_response,
    _make_project,
    _phase_plan,
    _Project,
    _tests_response,
)
from test_supervisor_resume_execution import _budget, _git

import lockstep.phase_gate_cycle as phase_gate_cycle
from lockstep.context.context_pack import CONTEXT_PACK_HEADER
from lockstep.context.project_digest import (
    DigestFact,
    DigestSource,
    DigestSourceKind,
    ProjectDigest,
)
from lockstep.context.project_digest_store import freeze_project_digest
from lockstep.domain import (
    AgentRole,
    BillingMode,
    ExecutionEventKind,
    InvocationIdentity,
    InvocationStage,
    PhaseId,
    ProjectId,
    SubphaseId,
)
from lockstep.metrics import project_runtime_metrics
from lockstep.persistence import ExecutionEvent, read_events
from lockstep.phase_context_finalization import load_phase_context_finalization
from lockstep.phase_gate_cycle import PhaseGateCycleDisposition, run_phase_gate_cycle
from lockstep.planning_store import load_active_subphase_contract
from lockstep.planning_transport import PlanningTransportError
from lockstep.planning_workflow import (
    SubphaseContractPlanningError,
    create_master_plan_candidate,
    create_phase_plan_candidate,
    create_subphase_contract_candidate,
)
from lockstep.project_orchestrator import ProjectRunDisposition, run_project_phase
from lockstep.runtime import AgentRuntime

_REPO = Path(__file__).resolve().parent.parent
_P1 = PhaseId.model_validate("01")
_PROBES = ("feature_01.py", "feature_02.py", "feature_11.py")
_AGENTS_TEXT = "Agents: plan from the accepted basis, never from the stale checkout."
_ARCHITECTURE_TEXT = "Architecture: planning context is host-assembled and provider-neutral."
_SKILL_TEXT = "Skill: implementation-only advice that a Planner must never receive."
_DIGEST_STATEMENT = "Planning reads durable host state, never a provider session."


def _planning() -> ModuleType:
    """The R1 planning-invocation module, imported lazily so characterizations stay green."""
    return importlib.import_module("lockstep.planning_invocation")


def _basis_module() -> ModuleType:
    return importlib.import_module("lockstep.planning_basis")


# ---------------------------------------------------------------------------
# An observing fake Planner: same scripted responses, plus what it saw at launch
# ---------------------------------------------------------------------------

_OBSERVING_SCRIPT = """\
import json
import sys
from pathlib import Path

RUNTIME_DIR = Path(__RUNTIME__)
PROBES = __PROBES__

base = Path(__file__).resolve().parent
responses = json.loads((base / "claude-planner-responses.json").read_text(encoding="utf-8"))
count_path = base / "claude-planner-call-count.txt"
index = int(count_path.read_text()) if count_path.exists() else 0
count_path.write_text(str(index + 1))
response = responses[index] if index < len(responses) else responses[-1]

stdin = sys.stdin.read()
journal = RUNTIME_DIR / "planning" / "invocations.jsonl"
observed = {
    "index": index,
    "cwd": str(Path.cwd()),
    "argv": sys.argv[1:],
    "stdin": stdin,
    "journal": journal.read_text(encoding="utf-8") if journal.exists() else None,
    "probes": {p: (Path.cwd() / p).is_file() for p in PROBES},
}
with (base / "observed.jsonl").open("a", encoding="utf-8") as fh:
    fh.write(json.dumps(observed) + "\\n")
with (base / "claude-planner-invocations.jsonl").open("a", encoding="utf-8") as fh:
    fh.write(json.dumps({"index": index, "cwd": str(Path.cwd())}) + "\\n")

for rel_path, content in response.get("files", {}).items():
    target = Path(rel_path)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(content)

sys.stdout.write(response.get("stdout", ""))
sys.stderr.write(response.get("stderr", ""))
raise SystemExit(int(response.get("returncode", 0)))
"""


def _observe(bin_dir: Path, runtime_dir: Path) -> None:
    """Swap the fake Planner for one that also records its cwd, argv, stdin and journal view."""
    executable = bin_dir / "claude-planner"
    script = _OBSERVING_SCRIPT.replace("__RUNTIME__", repr(str(runtime_dir))).replace(
        "__PROBES__", repr(_PROBES)
    )
    executable.write_text(f"#!{sys.executable}\n" + script, encoding="utf-8")
    executable.chmod(executable.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _observed(bin_dir: Path) -> list[dict[str, Any]]:
    path = bin_dir / "observed.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def _project(tmp_path: Path, **kwargs: Any) -> _Project:
    project = _make_project(tmp_path, **kwargs)
    _observe(project.bins["planner"], project.runtime_dir)
    return project


def _gate_project(project: GateProject) -> GateProject:
    _observe(project.bins["planner"], project.runtime_dir)
    return project


def _cwd(call: dict[str, Any]) -> Path:
    return Path(call["cwd"]).resolve()


def _run(project: _Project, *, jit: bool = False) -> None:
    result = run_project_phase(
        project.runtime,
        request_factory=project.factory,
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
        jit_replan=jit,
    )
    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY


def _tip(project: _Project | GateProject, run: str) -> str:
    worktree = project.runtime_dir / "worktrees" / run
    return _git(worktree, "rev-parse", f"lockstep/run/{run}").stdout.strip()


def _phase_plan_response(sids: tuple[str, ...]) -> dict[str, object]:
    return {"stdout": _phase_plan(sids).model_dump_json(), "returncode": 0}


# ---------------------------------------------------------------------------
# Prompt and journal readers
# ---------------------------------------------------------------------------


def _manifest(prompt: str) -> dict[str, Any]:
    start = prompt.index(CONTEXT_PACK_HEADER) + len(CONTEXT_PACK_HEADER)
    manifest = json.loads(prompt[start:].split("\n", 1)[0])
    assert isinstance(manifest, dict)
    return manifest


def _kinds(prompt: str) -> list[str]:
    return [source["kind"] for source in _manifest(prompt)["sources"]]


def _section(prompt: str, title: str) -> dict[str, Any]:
    lines = prompt.splitlines()
    matches = [i for i, line in enumerate(lines) if line.startswith(f"## {title} [")]
    assert len(matches) == 1, title
    value = json.loads(lines[matches[0] + 1])
    assert isinstance(value, dict)
    return value


def _source(prompt: str, kind: str) -> dict[str, Any]:
    [source] = [s for s in _manifest(prompt)["sources"] if s["kind"] == kind]
    return source


def _stable_prefix(prompt: str) -> str:
    return prompt[: prompt.index(CONTEXT_PACK_HEADER)]


def _journal_lines(runtime_dir: Path) -> list[dict[str, Any]]:
    path = runtime_dir / "planning" / "invocations.jsonl"
    if not path.exists():
        return []
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines()]


def _parse_journal(text: str | None) -> list[dict[str, Any]]:
    return [] if text is None else [json.loads(line) for line in text.splitlines()]


def _pairs(events: list[dict[str, Any]]) -> list[tuple[str, str, str | None]]:
    return [
        (e["kind"], e["identity"]["stage"], e["identity"]["target_subphase_id"]) for e in events
    ]


def _digest() -> ProjectDigest:
    return ProjectDigest(
        project_id=ProjectId.model_validate("lockstep"),
        architecture=(
            DigestFact(
                fact_id="host-owned-planning",
                statement=_DIGEST_STATEMENT,
                sources=(
                    DigestSource(kind=DigestSourceKind.TRACKED_CONFIG, locator="lockstep.toml"),
                ),
            ),
        ),
    )


def _write_selection(root: Path, *documents: tuple[str, str, tuple[str, ...]]) -> None:
    path = root / ".lockstep" / "project" / "context-selection.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {
        "schema_version": 1,
        "documents": [{"path": p, "kind": k, "operations": list(ops)} for p, k, ops in documents],
    }
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


def _write_documents(root: Path) -> None:
    (root / "AGENTS.md").write_text(_AGENTS_TEXT, encoding="utf-8")
    (root / "docs").mkdir(exist_ok=True)
    (root / "docs" / "architecture.md").write_text(_ARCHITECTURE_TEXT, encoding="utf-8")
    (root / "skill").mkdir(exist_ok=True)
    (root / "skill" / "SKILL.md").write_text(_SKILL_TEXT, encoding="utf-8")


def _published_project(tmp_path: Path, planner: list[dict[str, object]]) -> _Project:
    """A project with a frozen Master Plan and a published outline, but no cursor yet."""
    return _project(tmp_path, sids=("01", "02"), planner=planner, outline=_phase_plan(("01", "02")))


def _plan_contract(project: _Project, sid: str = "01") -> Any:
    return create_subphase_contract_candidate(
        project.runtime,
        phase_id=_P1,
        subphase_id=SubphaseId.model_validate(sid),
        timeout_seconds=60.0,
    )


def _after_first_accepted(tmp_path: Path, planner: list[dict[str, object]]) -> _Project:
    """Sub-phase 01 accepted and recorded; Sub-phase 02 current with no Contract planned."""
    project = _project(tmp_path, sids=("01", "02"), planner=planner)
    for _ in range(2):
        assert project.step() is None
    cursor = project.cursor()
    assert [e.subphase_id.root for e in cursor.completed_subphases] == ["01"]
    assert cursor.active_contract is None
    return project


# ===========================================================================
# A. PlanningInvocationIdentity / PlanningStage invariants
# ===========================================================================


def test_the_planning_stage_vocabulary_is_exact() -> None:
    stage = _planning().PlanningStage
    assert {s.value for s in stage} == {
        "phase_planning",
        "contract_planning",
        "jit_replan",
        "gate_remediation",
    }


def test_the_transaction_invocation_identity_is_unchanged() -> None:
    assert {s.value for s in InvocationStage} == {
        "test_authoring",
        "implementation",
        "review",
        "escalation_decision",
    }
    assert set(InvocationIdentity.model_fields) == {
        "run_id",
        "phase_id",
        "subphase_id",
        "attempt",
        "role",
        "stage",
        "invocation_id",
    }


def test_the_planning_identity_names_no_run_and_no_attempt() -> None:
    identity = _planning().PlanningInvocationIdentity
    assert set(identity.model_fields) == {
        "project_id",
        "phase_id",
        "target_subphase_id",
        "role",
        "stage",
        "invocation_id",
    }


def _issue(stage: str, target: str | None) -> Any:
    module = _planning()
    return module.PlanningInvocationIdentity.issue(
        project_id=ProjectId.model_validate("lockstep"),
        phase_id=_P1,
        target_subphase_id=None if target is None else SubphaseId.model_validate(target),
        stage=module.PlanningStage(stage),
    )


def test_the_planning_identity_is_host_issued_frozen_and_unique() -> None:
    first, second = _issue("contract_planning", "02"), _issue("contract_planning", "02")

    assert first.role is AgentRole.PLANNER
    assert first.invocation_id != second.invocation_id
    for identity in (first, second):
        assert identity.invocation_id.root.startswith("inv-")
        assert len(identity.invocation_id.root) == len("inv-") + 32
    with pytest.raises(Exception):  # noqa: B017 - frozen model
        first.stage = second.stage
    payload = first.model_dump(mode="json")
    with pytest.raises(ValueError):
        type(first).model_validate({**payload, "run_id": "run-01-02"})
    with pytest.raises(ValueError):
        type(first).model_validate({**payload, "role": "implementer"})


@pytest.mark.parametrize(
    ("stage", "target", "valid"),
    [
        ("contract_planning", "02", True),
        ("contract_planning", None, False),
        ("phase_planning", None, True),
        ("phase_planning", "02", False),
        ("jit_replan", None, True),
        ("jit_replan", "02", False),
        ("gate_remediation", "03", True),
        ("gate_remediation", None, False),
    ],
)
def test_the_stage_determines_the_identity_shape(
    stage: str, target: str | None, valid: bool
) -> None:
    if valid:
        identity = _issue(stage, target)
        assert identity.stage.value == stage
        assert (identity.target_subphase_id.root if identity.target_subphase_id else None) == target
    else:
        with pytest.raises(ValueError):
            _issue(stage, target)


# ===========================================================================
# B. Contract planning from the accepted basis (two accepted Sub-phases, then Phase planning)
# ===========================================================================


@pytest.fixture(scope="module")
def accepted_run(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    planner = [
        _contract_response("01"),
        _tests_response("01"),
        _contract_response("02"),
        _tests_response("02"),
        _phase_plan_response(("01", "02")),
    ]
    project = _project(tmp_path_factory.mktemp("accepted"), sids=("01", "02"), planner=planner)
    _run(project)
    # Both units accepted: Phase-outline planning now plans from the newest accepted basis.
    create_phase_plan_candidate(project.runtime, phase_id=_P1, timeout_seconds=60.0)
    calls = _observed(project.bins["planner"])
    assert len(calls) == 5
    return SimpleNamespace(
        project=project,
        calls=calls,
        first=calls[0]["stdin"],
        second=calls[2]["stdin"],
        outline=calls[4]["stdin"],
        tip_01=_tip(project, "run-01-01"),
        tip_02=_tip(project, "run-01-02"),
    )


def test_first_unit_contract_planning_runs_in_the_source_checkout(
    accepted_run: SimpleNamespace,
) -> None:
    project = accepted_run.project
    assert _cwd(accepted_run.calls[0]) == project.project_root.resolve()


def test_later_contract_planning_runs_in_the_latest_accepted_worktree(
    accepted_run: SimpleNamespace,
) -> None:
    project = accepted_run.project
    assert _cwd(accepted_run.calls[2]) == project.worktree("01").resolve()
    assert _cwd(accepted_run.calls[2]) != project.project_root.resolve()


def test_the_planner_can_inspect_accepted_code_the_source_checkout_lacks(
    accepted_run: SimpleNamespace,
) -> None:
    project = accepted_run.project
    assert accepted_run.calls[0]["probes"]["feature_01.py"] is False
    assert accepted_run.calls[2]["probes"]["feature_01.py"] is True
    assert not (project.project_root / "feature_01.py").exists()
    assert not (project.source / "feature_01.py").exists()


def test_the_source_checkout_is_never_moved_or_dirtied_by_planning(
    accepted_run: SimpleNamespace,
) -> None:
    project = accepted_run.project
    assert _git(project.source, "log", "--format=%s").stdout.split("\n")[0] == "initial"
    assert _git(project.source, "rev-list", "--count", "HEAD").stdout.strip() == "1"
    assert _git(project.source, "status", "--porcelain").stdout.strip() == ""
    assert _git(project.source, "branch", "--show-current").stdout.strip() == "main"


def test_contract_planning_receives_a_contract_planning_context_pack(
    accepted_run: SimpleNamespace,
) -> None:
    first, second = accepted_run.first, accepted_run.second

    for prompt, target in ((first, "01"), (second, "02")):
        manifest = _manifest(prompt)
        assert manifest["operation"] == "contract_planning"
        assert manifest["identity"] == {
            "project_id": "lockstep",
            "phase_id": "01",
            "subphase_id": target,
            "run_id": None,
            "attempt": None,
            "role": "planner",
        }
    # The first-ever unit has no accepted history to fabricate.
    assert _kinds(first) == ["master_plan", "provisional_outline"]
    assert _kinds(second) == [
        "master_plan",
        "completed_history",
        "provisional_outline",
        "repository_state",
    ]
    expected = {
        "master_plan": ("frozen_requirement", "exact"),
        "completed_history": ("frozen_requirement", "exact"),
        "provisional_outline": ("provisional_plan", "exact"),
        "repository_state": ("execution_evidence", "exact"),
    }
    for kind, (authority, completeness) in expected.items():
        source = _source(second, kind)
        assert (source["authority"], source["completeness"]) == (authority, completeness)


def test_the_master_plan_and_outline_reach_the_planner_exactly_once(
    accepted_run: SimpleNamespace,
) -> None:
    project = accepted_run.project
    prompt = accepted_run.second
    master = _section(prompt, "MASTER PLAN")
    outline = _section(prompt, "CURRENT PROVISIONAL PHASE PLAN")

    assert master["master_plan"]["project_id"] == "lockstep"
    assert _source(prompt, "master_plan")["reference"] == (
        f"master-plan:{master['master_plan_digest']}"
    )
    assert [o["subphase_id"] for o in outline["phase_plan"]["subphases"]] == ["01", "02"]
    assert prompt.count('"master_plan":') == 1
    assert prompt.count('"phase_plan":') == 1
    assert "Frozen Master Plan:" not in prompt.splitlines()
    assert "Current Phase plan:" not in prompt.splitlines()
    assert str(project.project_root) not in prompt
    assert str(project.runtime_dir) not in prompt


def test_contract_planning_repository_state_names_the_accepted_commit(
    accepted_run: SimpleNamespace,
) -> None:
    project = accepted_run.project
    prompt = accepted_run.second
    [entry] = project.cursor().completed_subphases[:1]
    source = _source(prompt, "repository_state")

    assert _section(prompt, "ACCEPTED REPOSITORY BASIS") == {
        "phase_id": "01",
        "subphase_id": "01",
        "run_id": "run-01-01",
        "contract_digest": entry.contract_digest,
        "branch": "lockstep/run/run-01-01",
        "commit": accepted_run.tip_01,
    }
    assert source["reference"] == f"git:{accepted_run.tip_01}#accepted-basis"
    assert source["version"] == accepted_run.tip_01


def test_contract_planning_completed_history_is_reconstructed_from_durable_state(
    accepted_run: SimpleNamespace,
) -> None:
    project = accepted_run.project
    [entry] = project.cursor().completed_subphases[:1]
    history = _section(accepted_run.second, "COMPLETED HISTORY")

    assert history == {
        "phase_id": "01",
        "subphases": [_phase_plan(("01", "02")).subphases[0].model_dump(mode="json")],
        "accepted": [entry.model_dump(mode="json")],
    }


def test_the_contract_planning_trailer_keeps_only_the_target_request(
    accepted_run: SimpleNamespace,
) -> None:
    prompt = accepted_run.second
    trailer = prompt[prompt.index("## ACCEPTED REPOSITORY BASIS [") :]

    assert "Target phase_id:\n01\n" in trailer
    assert "Target subphase_id:\n02\n" in trailer
    assert "Target subphase outline:\n" in trailer
    assert "Produce exactly one SubphaseContract" in trailer
    assert "Return only the structured SubphaseContract" in trailer


def test_the_stable_prefix_is_shared_and_names_no_invocation(
    accepted_run: SimpleNamespace,
) -> None:
    first, second = _stable_prefix(accepted_run.first), _stable_prefix(accepted_run.second)

    assert first == second
    assert "## MASTER PLAN [frozen_requirement]" in first
    # The invocation identity and the operation live only in the volatile manifest.
    for volatile in ('"identity":', '"operation":', "run-01-01", accepted_run.tip_01, "inv-"):
        assert volatile not in first


def test_provider_isolation_is_unchanged_in_the_accepted_basis(
    accepted_run: SimpleNamespace,
) -> None:
    source_argv, basis_argv = accepted_run.calls[0]["argv"], accepted_run.calls[2]["argv"]

    assert source_argv == basis_argv
    assert "--safe-mode" in basis_argv
    assert "--restricted" in basis_argv
    assert "--no-session-persistence" in basis_argv


def test_contract_planning_invocations_are_journaled_with_host_identity(
    accepted_run: SimpleNamespace,
) -> None:
    events = _journal_lines(accepted_run.project.runtime_dir)
    contract = [e for e in events if e["identity"]["stage"] == "contract_planning"]

    assert _pairs(contract) == [
        ("started", "contract_planning", "01"),
        ("returned", "contract_planning", "01"),
        ("started", "contract_planning", "02"),
        ("returned", "contract_planning", "02"),
    ]
    assert contract[0]["identity"] == contract[1]["identity"]
    assert contract[2]["identity"] == contract[3]["identity"]
    assert contract[0]["identity"]["invocation_id"] != contract[2]["identity"]["invocation_id"]
    for event in contract:
        assert event["schema_version"] == 1
        assert event["identity"]["project_id"] == "lockstep"
        assert event["identity"]["phase_id"] == "01"
        assert event["identity"]["role"] == "planner"
        # The adapter's configured routing, the same source InvocationUsage records.
        assert (event["provider"], event["configured_model"], event["configured_effort"]) == (
            "claude",
            "role-model",
            "high",
        )
    assert [e["sequence"] for e in events] == list(range(1, len(events) + 1))


def test_returned_carries_the_process_result_and_leaves_unreported_usage_unavailable(
    accepted_run: SimpleNamespace,
) -> None:
    events = _journal_lines(accepted_run.project.runtime_dir)
    started = [e for e in events if e["kind"] == "started"]
    returned = [e for e in events if e["kind"] == "returned"]
    # Two Contract plans and one Phase-outline plan, each started and returned.
    assert len(started) == len(returned) == 3

    for event in started:
        assert (event["outcome"], event["returncode"], event["usage"], event["cause"]) == (
            None,
            None,
            None,
            None,
        )
    for event in returned:
        assert (event["outcome"], event["returncode"], event["cause"]) == ("success", 0, None)
        usage = event["usage"]
        assert (usage["termination"], usage["exit_code"]) == ("exited", 0)
        assert usage["elapsed_seconds"] is not None
        # The fake reports no telemetry: unavailable stays unavailable, never zero.
        assert set(usage["reported"].values()) == {None}
        assert "cost" not in json.dumps(usage)


def test_started_is_durable_before_the_provider_launches(accepted_run: SimpleNamespace) -> None:
    calls = accepted_run.calls
    at_first = _parse_journal(calls[0]["journal"])
    at_second = _parse_journal(calls[2]["journal"])

    assert _pairs(at_first) == [("started", "contract_planning", "01")]
    assert _pairs(at_second)[-1] == ("started", "contract_planning", "02")
    launched = at_second[-1]["identity"]["invocation_id"]
    assert [e for e in at_second if e["identity"]["invocation_id"] == launched] == [at_second[-1]]


def test_planner_test_authoring_keeps_its_transaction_identity(
    accepted_run: SimpleNamespace,
) -> None:
    project = accepted_run.project
    calls = accepted_run.calls
    # Test authoring (call 1) adds nothing to the planning journal: the next Contract
    # planning call sees exactly what test authoring saw, plus its own STARTED.
    assert _parse_journal(calls[2]["journal"])
    assert _parse_journal(calls[1]["journal"]) == _parse_journal(calls[2]["journal"])[:-1]
    stages = {e["identity"]["stage"] for e in _journal_lines(project.runtime_dir)}
    assert "test_authoring" not in stages
    for sid in ("01", "02"):
        started = [
            event
            for event in read_events(project.txn_dir(sid) / "events.jsonl")
            if isinstance(event, ExecutionEvent)
            and event.kind is ExecutionEventKind.INVOCATION_STARTED
        ]
        assert all(event.run_id.root == f"run-01-{sid}" for event in started)
        assert [event.stage for event in started] == [
            InvocationStage.TEST_AUTHORING,
            InvocationStage.IMPLEMENTATION,
            InvocationStage.REVIEW,
        ]


def test_the_planning_journal_reloads_in_a_fresh_process(accepted_run: SimpleNamespace) -> None:
    runtime_dir = accepted_run.project.runtime_dir
    code = textwrap.dedent(
        f"""
        import json
        from pathlib import Path
        from lockstep.planning_invocation import read_planning_invocation_events
        events = read_planning_invocation_events(Path({str(runtime_dir)!r}))
        print(json.dumps([e.model_dump(mode="json") for e in events]))
        """
    )
    output = subprocess.run(
        [sys.executable, "-c", code], check=True, capture_output=True, text=True, cwd=_REPO
    ).stdout
    reloaded = json.loads(output)

    assert reloaded == _journal_lines(runtime_dir)
    assert _pairs(reloaded)[:4] == [
        ("started", "contract_planning", "01"),
        ("returned", "contract_planning", "01"),
        ("started", "contract_planning", "02"),
        ("returned", "contract_planning", "02"),
    ]


def test_planning_creates_no_fake_child_transaction_and_leaves_child_metrics_alone(
    accepted_run: SimpleNamespace,
) -> None:
    project = accepted_run.project
    assert sorted(p.name for p in (project.runtime_dir / "transactions").iterdir()) == [
        "run-01-01",
        "run-01-02",
    ]
    assert not (project.runtime_dir / "events.jsonl").exists()
    assert not (project.runtime_dir / "state.json").exists()
    for sid in ("01", "02"):
        totals = project_runtime_metrics(project.txn_dir(sid), repository_change=None).totals
        assert totals.executed_attempts == 1
        assert {role.value: n for role, n in totals.invocations_by_role.items()} == {
            "planner": 1,
            "implementer": 1,
            "reviewer": 1,
        }
    committed = _git(_REPO, "show", "HEAD:tests/baselines/transaction_baseline.json").stdout
    assert _BASELINE.read_text(encoding="utf-8") == committed
    assert json.loads(committed)["baseline_version"] == 1


# ===========================================================================
# C. Phase-outline planning
# ===========================================================================


def test_phase_planning_without_history_uses_the_source_and_a_phase_planning_pack(
    tmp_path: Path,
) -> None:
    project = _project(tmp_path, sids=("01", "02"), planner=[_phase_plan_response(("01", "02"))])

    create_phase_plan_candidate(project.runtime, phase_id=_P1, timeout_seconds=60.0)

    [call] = _observed(project.bins["planner"])
    prompt = call["stdin"]
    assert _cwd(call) == project.project_root.resolve()
    assert _manifest(prompt)["operation"] == "phase_planning"
    assert _manifest(prompt)["identity"] == {
        "project_id": "lockstep",
        "phase_id": "01",
        "subphase_id": None,
        "run_id": None,
        "attempt": None,
        "role": "planner",
    }
    assert _kinds(prompt) == ["master_plan"]
    assert "Target phase_id:\n01\n" in prompt
    assert "Current provisional outline:\nnull\n" in prompt
    assert _pairs(_journal_lines(project.runtime_dir)) == [
        ("started", "phase_planning", None),
        ("returned", "phase_planning", None),
    ]


def test_phase_planning_after_acceptance_uses_the_newest_accepted_basis(
    accepted_run: SimpleNamespace,
) -> None:
    project = accepted_run.project
    call, prompt = accepted_run.calls[4], accepted_run.outline

    assert _cwd(call) == project.worktree("02").resolve()
    assert call["probes"]["feature_01.py"] and call["probes"]["feature_02.py"]
    assert _manifest(prompt)["operation"] == "phase_planning"
    assert _kinds(prompt) == ["master_plan", "completed_history", "repository_state"]
    basis = _section(prompt, "ACCEPTED REPOSITORY BASIS")
    # A newly accepted commit changes what later planning observes.
    assert (basis["run_id"], basis["commit"]) == ("run-01-02", accepted_run.tip_02)
    assert accepted_run.tip_02 != accepted_run.tip_01
    events = _journal_lines(project.runtime_dir)
    assert _pairs(events)[-2:] == [
        ("started", "phase_planning", None),
        ("returned", "phase_planning", None),
    ]


# ===========================================================================
# D. Durable selection and Project Digest
# ===========================================================================


def test_durable_selection_applies_only_to_the_operations_it_names(tmp_path: Path) -> None:
    project = _published_project(tmp_path, [_contract_response("01")])
    _write_documents(project.project_root)
    _write_selection(
        project.project_root,
        ("AGENTS.md", "project_instructions", ("contract_planning",)),
        ("docs/architecture.md", "project_documentation", ("jit_replan",)),
        ("skill/SKILL.md", "skill", ("implementation",)),
    )

    _plan_contract(project)
    _write_selection(
        project.project_root,
        ("AGENTS.md", "project_instructions", ("contract_planning",)),
        ("docs/architecture.md", "project_documentation", ("jit_replan", "contract_planning")),
        ("skill/SKILL.md", "skill", ("implementation",)),
    )
    _plan_contract(project)

    first, second = (call["stdin"] for call in _observed(project.bins["planner"]))
    assert _AGENTS_TEXT in _stable_prefix(first)
    # No implicit inheritance from jit_replan or implementation.
    assert _ARCHITECTURE_TEXT not in first
    assert _SKILL_TEXT not in first
    # The durable selection is loaded afresh for every invocation.
    assert _ARCHITECTURE_TEXT in _stable_prefix(second)
    assert _SKILL_TEXT not in second
    assert _source(second, "project_documentation")["reference"] == "file:docs/architecture.md"


def test_the_project_digest_is_loaded_from_its_store(tmp_path: Path) -> None:
    project = _published_project(
        tmp_path, [_contract_response("01"), _phase_plan_response(("01", "02"))]
    )
    identity = freeze_project_digest(project.project_root, project.runtime_dir, _digest())

    _plan_contract(project)
    create_phase_plan_candidate(project.runtime, phase_id=_P1, timeout_seconds=60.0)

    for call in _observed(project.bins["planner"]):
        prompt = call["stdin"]
        assert _kinds(prompt)[0] == "project_digest"
        assert _source(prompt, "project_digest")["reference"] == f"project-digest:{identity}"
        assert _DIGEST_STATEMENT in _stable_prefix(prompt)


# ===========================================================================
# E. Usage, failures and candidates
# ===========================================================================


def test_reported_usage_is_preserved_on_returned(tmp_path: Path) -> None:
    envelope = {
        "type": "result",
        "result": json.dumps(_contract_payload("01")),
        "session_id": "session-r1",
        "usage": {
            "input_tokens": 11,
            "cache_read_input_tokens": 20,
            "cache_creation_input_tokens": 5,
            "output_tokens": 7,
        },
        "modelUsage": {"reported-model": {}},
    }
    project = _published_project(tmp_path, [{"stdout": json.dumps(envelope), "returncode": 0}])

    _plan_contract(project)

    started, returned = _journal_lines(project.runtime_dir)
    assert started["kind"] == "started" and returned["kind"] == "returned"
    assert returned["usage"]["reported"] == {
        "reported_model": "reported-model",
        "provider_session_id": "session-r1",
        "input_tokens": 36,
        "uncached_input_tokens": 11,
        "cache_read_tokens": 20,
        "cache_write_tokens": 5,
        "output_tokens": 7,
    }
    assert (returned["usage"]["provider"], returned["usage"]["configured_model"]) == (
        "claude",
        "role-model",
    )


def test_a_provider_failure_is_journaled_and_freezes_nothing(tmp_path: Path) -> None:
    project = _published_project(tmp_path, [{"stdout": "", "returncode": 3}])

    with pytest.raises(PlanningTransportError):
        _plan_contract(project)

    started, returned = _journal_lines(project.runtime_dir)
    assert started["identity"] == returned["identity"]
    assert (returned["kind"], returned["outcome"], returned["returncode"]) == (
        "returned",
        "failure",
        3,
    )
    assert returned["cause"] == "provider_process_failure"
    assert returned["usage"]["exit_code"] == 3
    assert load_active_subphase_contract(project.project_root, project.runtime_dir) is None


def test_malformed_planner_output_is_journaled_as_malformed(tmp_path: Path) -> None:
    project = _published_project(tmp_path, [{"stdout": "not a contract", "returncode": 0}])

    with pytest.raises(PlanningTransportError):
        _plan_contract(project)

    _, returned = _journal_lines(project.runtime_dir)
    assert (returned["outcome"], returned["returncode"], returned["cause"]) == (
        "failure",
        0,
        "malformed_output",
    )


def test_a_failure_before_any_launch_fabricates_no_invocation(tmp_path: Path) -> None:
    project = _published_project(tmp_path, [_contract_response("01")])
    config = project.runtime.config
    route = dataclasses.replace(config.routing.planner, billing_mode=BillingMode.API_ALLOWED)
    routing = dataclasses.replace(config.routing, planner=route)
    runtime = dataclasses.replace(
        project.runtime, config=dataclasses.replace(config, routing=routing)
    )

    with pytest.raises(Exception):  # noqa: B017 - the adapter refuses before any launch
        create_subphase_contract_candidate(
            runtime,
            phase_id=_P1,
            subphase_id=SubphaseId.model_validate("01"),
            timeout_seconds=60.0,
        )

    assert _observed(project.bins["planner"]) == []
    assert not (project.runtime_dir / "planning" / "invocations.jsonl").exists()

    # The same project journals normally once a launch can happen: exactly one invocation.
    _plan_contract(project)
    assert _pairs(_journal_lines(project.runtime_dir)) == [
        ("started", "contract_planning", "01"),
        ("returned", "contract_planning", "01"),
    ]


def test_each_contract_candidate_keeps_its_own_journaled_invocation(tmp_path: Path) -> None:
    project = _project(
        tmp_path,
        sids=("01",),
        planner=[_bad_response("tests"), _contract_response("01"), _tests_response("01")],
    )
    (project.project_root / "tests").mkdir()

    assert project.step() is None

    events = _journal_lines(project.runtime_dir)
    assert _pairs(events) == [
        ("started", "contract_planning", "01"),
        ("returned", "contract_planning", "01"),
        ("started", "contract_planning", "01"),
        ("returned", "contract_planning", "01"),
    ]
    assert events[0]["identity"]["invocation_id"] != events[2]["identity"]["invocation_id"]
    assert {e["outcome"] for e in events if e["kind"] == "returned"} == {"success"}
    history = project.runtime_dir / "contracts" / "history"
    assert not history.exists() or not any(history.iterdir())
    active = load_active_subphase_contract(project.project_root, project.runtime_dir)
    assert active is not None and active.tests[0].path == "tests/test_feature_01.py"


class _CrashError(BaseException):
    """Simulated death of the host process."""


def test_an_unmatched_started_is_preserved_and_never_reused(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _published_project(tmp_path, [_contract_response("01")])
    module = _planning()
    real_append = module.append_planning_invocation_event

    def crash_on_return(runtime_dir: Path, event: Any) -> Any:
        if event.kind.value == "returned":
            raise _CrashError
        return real_append(runtime_dir, event)

    monkeypatch.setattr(module, "append_planning_invocation_event", crash_on_return)
    with pytest.raises(_CrashError):
        _plan_contract(project)
    monkeypatch.undo()
    path = project.runtime_dir / "planning" / "invocations.jsonl"
    abandoned = path.read_bytes()

    _plan_contract(project)

    events = _journal_lines(project.runtime_dir)
    assert path.read_bytes().startswith(abandoned)
    assert _pairs(events) == [
        ("started", "contract_planning", "01"),
        ("started", "contract_planning", "01"),
        ("returned", "contract_planning", "01"),
    ]
    old, new = events[0]["identity"]["invocation_id"], events[1]["identity"]["invocation_id"]
    assert old != new
    assert events[2]["identity"]["invocation_id"] == new


# ===========================================================================
# F. The accepted basis fails closed and is reverified
# ===========================================================================


def _second_contract_script() -> list[dict[str, object]]:
    return [_contract_response("01"), _tests_response("01"), _contract_response("02")]


def test_a_dirty_accepted_basis_fails_closed_before_any_launch(tmp_path: Path) -> None:
    project = _after_first_accepted(tmp_path, _second_contract_script())
    (project.worktree("01") / "feature_01.py").write_text("def answer() -> int:\n    return 0\n")
    launches, journal = project.launches("planner"), _journal_lines(project.runtime_dir)

    with pytest.raises(SubphaseContractPlanningError) as raised:
        _plan_contract(project, "02")

    assert "accepted" in raised.value.reason
    assert project.launches("planner") == launches
    assert _journal_lines(project.runtime_dir) == journal


def test_a_missing_accepted_basis_fails_closed_instead_of_planning_from_the_source(
    tmp_path: Path,
) -> None:
    project = _after_first_accepted(tmp_path, _second_contract_script())
    shutil.rmtree(project.worktree("01"))
    launches = project.launches("planner")

    with pytest.raises(SubphaseContractPlanningError):
        _plan_contract(project, "02")

    assert project.launches("planner") == launches


def test_a_planner_that_moves_the_basis_is_rejected_with_its_evidence_kept(
    tmp_path: Path,
) -> None:
    moving = {**_contract_response("02"), "files": {"feature_01.py": "tampered = True\n"}}
    project = _after_first_accepted(tmp_path, [*_second_contract_script()[:2], moving])

    with pytest.raises(SubphaseContractPlanningError) as raised:
        _plan_contract(project, "02")

    assert "moved" in raised.value.reason
    assert _pairs(_journal_lines(project.runtime_dir))[-2:] == [
        ("started", "contract_planning", "02"),
        ("returned", "contract_planning", "02"),
    ]
    assert load_active_subphase_contract(project.project_root, project.runtime_dir) is None


def test_the_accepted_basis_helper_has_no_alternate_basis_without_history(
    tmp_path: Path,
) -> None:
    project = _project(tmp_path, sids=("01",), initialize_cursor=True)
    helper = _basis_module().accepted_planning_basis

    assert helper(project.runtime_dir, None) is None
    assert helper(project.runtime_dir, project.cursor()) is None


def test_the_accepted_basis_helper_verifies_the_latest_accepted_unit(tmp_path: Path) -> None:
    project = _after_first_accepted(tmp_path, _second_contract_script())
    module = _basis_module()

    selected = module.accepted_planning_basis(project.runtime_dir, project.cursor())

    assert Path(selected.worktree).resolve() == project.worktree("01").resolve()
    assert selected.basis.commit == _tip(project, "run-01-01")
    assert selected.basis.branch == "lockstep/run/run-01-01"
    _git(project.worktree("01"), "checkout", "--detach", "HEAD")
    with pytest.raises(module.PlanningBasisError):
        module.accepted_planning_basis(project.runtime_dir, project.cursor())


# ===========================================================================
# G. JIT replanning: newly journaled, ContextPack unchanged
# ===========================================================================


def test_jit_replanning_is_journaled_without_changing_its_context_pack(tmp_path: Path) -> None:
    same = _phase_plan_response(("01", "02", "03"))
    planner = [
        _contract_response("01"),
        _tests_response("01"),
        same,
        _contract_response("02"),
        _tests_response("02"),
        same,
        _contract_response("03"),
        _tests_response("03"),
    ]
    project = _project(tmp_path, sids=("01", "02", "03"), planner=planner)
    _run(project, jit=True)

    calls = _observed(project.bins["planner"])
    jit_calls = [c for c in calls if '"operation":"jit_replan"' in c["stdin"]]
    assert [_cwd(c) for c in jit_calls] == [
        project.worktree("01").resolve(),
        project.worktree("02").resolve(),
    ]
    for call in jit_calls:
        manifest = _manifest(call["stdin"])
        assert manifest["identity"]["subphase_id"] is None
        assert _kinds(call["stdin"]) == [
            "master_plan",
            "completed_history",
            "provisional_outline",
            "repository_state",
        ]
        assert "## UNFINISHED PROVISIONAL OUTLINE [provisional_plan]" in call["stdin"]
    jit_events = [
        e for e in _journal_lines(project.runtime_dir) if e["identity"]["stage"] == "jit_replan"
    ]
    assert _pairs(jit_events) == [
        ("started", "jit_replan", None),
        ("returned", "jit_replan", None),
        ("started", "jit_replan", None),
        ("returned", "jit_replan", None),
    ]
    assert {e["outcome"] for e in jit_events if e["kind"] == "returned"} == {"success"}


# ===========================================================================
# H. Gate remediation: ContextPack, identity and evidence
# ===========================================================================


@pytest.fixture(scope="module")
def remediated(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    project = _gate_project(
        standard_project(
            tmp_path_factory.mktemp("remediated"),
            phases={"01": ("01", "02")},
            criteria={"01": CRITERIA},
            gate_commands=lambda marker: (passing_command(marker, "smoke"),),
            planner_tail=[
                gate_review_response("01", "fail", findings=[finding()]),
                remediation_plan_response("01", ("01", "02"), "03", criteria=CRITERIA),
                *unit_script("01", "03"),
                gate_review_response("01", "pass"),
            ],
            extra_units=[("01", "03")],
        )
    )
    _write_documents(project.project_root)
    _write_selection(
        project.project_root,
        ("AGENTS.md", "project_instructions", ("gate_remediation",)),
        ("docs/architecture.md", "project_documentation", ("contract_planning",)),
    )
    assert project.run_phase().disposition is ProjectRunDisposition.PHASE_GATE_READY
    with pytest.MonkeyPatch.context() as patch:
        from phase_gate_support import record_calls

        prompts = record_calls(patch, phase_gate_cycle, "invoke_planner_artifact")
        result = run_phase_gate_cycle(
            project.runtime,
            max_gate_remediations=1,
            request_factory=project.factory,
            retry_budget=_budget(3),
            planning_timeout_seconds=60.0,
        )
    assert result.disposition is PhaseGateCycleDisposition.PROJECT_COMPLETE
    [call] = prompts
    return SimpleNamespace(project=project, prompt=call["prompt"], tip=_tip(project, "run-01-02"))


def test_gate_remediation_receives_a_gate_remediation_context_pack(
    remediated: SimpleNamespace,
) -> None:
    prompt = remediated.prompt
    manifest = _manifest(prompt)

    assert manifest["operation"] == "gate_remediation"
    assert manifest["identity"] == {
        "project_id": "lockstep",
        "phase_id": "01",
        "subphase_id": "03",
        "run_id": None,
        "attempt": None,
        "role": "planner",
    }
    assert _kinds(prompt) == [
        "project_instructions",
        "master_plan",
        "completed_history",
        "repository_state",
        "review_findings",
        "verification_report",
    ]
    for kind in ("repository_state", "review_findings", "verification_report"):
        assert _source(prompt, kind)["authority"] == "execution_evidence"
    assert _source(prompt, "repository_state")["version"] == remediated.tip


def test_gate_failure_evidence_stays_volatile_and_is_not_duplicated(
    remediated: SimpleNamespace,
) -> None:
    prompt = remediated.prompt
    stable = _stable_prefix(prompt)

    assert "The two features do not integrate." in prompt
    assert "The two features do not integrate." not in stable
    assert "integration boom" not in stable
    assert _AGENTS_TEXT in stable
    assert _ARCHITECTURE_TEXT not in prompt  # selected for contract_planning only
    assert prompt.count('"master_plan":') == 1
    assert "Remediation subphase_id:\n03\n" in prompt
    assert "evidence, not requirements" in prompt


def test_gate_remediation_is_journaled_with_its_allocated_target(
    remediated: SimpleNamespace,
) -> None:
    project = remediated.project
    events = _journal_lines(project.runtime_dir)
    remediation = [e for e in events if e["identity"]["stage"] == "gate_remediation"]

    assert _pairs(remediation) == [
        ("started", "gate_remediation", "03"),
        ("returned", "gate_remediation", "03"),
    ]
    remediation_calls = [
        c
        for c in _observed(project.bins["planner"])
        if '"operation":"gate_remediation"' in c["stdin"]
    ]
    assert [_cwd(c) for c in remediation_calls] == [project.worktree("01", "02").resolve()]
    contract_targets = [
        target for (_, stage, target) in _pairs(events) if stage == "contract_planning"
    ]
    assert contract_targets == ["01", "01", "02", "02", "03", "03"]


# ===========================================================================
# I. Phase 2 planning reconstructs the finalized Phase 1 from durable history
# ===========================================================================


def test_successor_phase_contract_planning_uses_the_finalized_basis_and_history(
    tmp_path: Path,
) -> None:
    project = _gate_project(
        standard_project(
            tmp_path,
            phases={"01": ("01",), "02": ("11",)},
            gate_commands=lambda marker: (passing_command(marker, "smoke"),),
            planner_tail=unit_script("02", "11"),
            extra_units=[("02", "11")],
        )
    )
    assert project.run_phase().disposition is ProjectRunDisposition.PHASE_GATE_READY
    first = run_phase_gate_cycle(
        project.runtime,
        max_gate_remediations=0,
        request_factory=project.factory,
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
    )
    assert first.disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    assert project.run_phase().disposition is ProjectRunDisposition.PHASE_GATE_READY

    finalization = load_phase_context_finalization(project.runtime_dir, _P1)
    assert finalization is not None
    final_bytes = (project.runtime_dir / "project" / "phase-context" / "01.json").read_bytes()
    identity = __import__("hashlib").sha256(final_bytes).hexdigest()
    [call] = [
        c
        for c in _observed(project.bins["planner"])
        if CONTEXT_PACK_HEADER in c["stdin"]
        and _manifest(c["stdin"])["operation"] == "contract_planning"
        and _manifest(c["stdin"])["identity"]["phase_id"] == "02"
    ]
    prompt = call["stdin"]

    assert _cwd(call) == project.worktree("01", "01").resolve()
    assert call["probes"]["feature_01.py"] is True
    history = _section(prompt, "COMPLETED HISTORY")
    assert history["phase_id"] == "02"
    assert history["accepted"] == []
    assert history["finalized_phases"] == [
        {"phase_id": "01", "identity": identity, "reference": f"phase-context:01@{identity}"}
    ]
    basis = _section(prompt, "ACCEPTED REPOSITORY BASIS")
    assert basis["commit"] == finalization.final_repository_basis_commit
    assert basis["run_id"] == "run-01-01"


# ===========================================================================
# J. The planning-path matrix
# ===========================================================================


def test_master_plan_creation_stays_pre_project_with_no_planning_identity(
    tmp_path: Path,
) -> None:
    project = _project(tmp_path, sids=("01",), planner=[])
    fresh_root, fresh_runtime = tmp_path / "fresh-project", tmp_path / "fresh-runtime"
    fresh_root.mkdir()
    fresh_runtime.mkdir()
    master_payload = json.loads(
        (project.project_root / ".lockstep" / "project" / "master-plan.json").read_text()
    )
    responses = project.bins["planner"] / "claude-planner-responses.json"
    responses.write_text(json.dumps([{"stdout": json.dumps(master_payload), "returncode": 0}]))
    runtime: AgentRuntime = dataclasses.replace(
        project.runtime, project_root=fresh_root, runtime_dir=fresh_runtime
    )

    create_master_plan_candidate(
        runtime,
        project_id=ProjectId.model_validate("lockstep"),
        requirements="Build the control plane.",
        timeout_seconds=60.0,
    )

    [call] = _observed(project.bins["planner"])
    assert _cwd(call) == fresh_root.resolve()
    assert CONTEXT_PACK_HEADER not in call["stdin"]
    assert call["journal"] is None
    assert not (fresh_runtime / "planning").exists()


def test_the_planning_path_matrix_is_exact() -> None:
    from lockstep.context.context_pack import ContextOperation

    stages = {s.value for s in _planning().PlanningStage}
    operations = {o.value for o in ContextOperation}
    # Every project-planning stage has its own semantically named ContextOperation ...
    assert stages <= operations
    # ... Master Plan creation has neither, and test authoring stays a transaction stage.
    assert "master_plan" not in stages and "master_plan_creation" not in operations
    assert "test_authoring" not in stages
    assert InvocationStage.TEST_AUTHORING.value in operations
