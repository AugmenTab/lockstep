"""Phase 12.8: durable, immutable Phase-context finalization before Phase completion.

At a successful Phase boundary the host freezes one deterministic, immutable
``PhaseContextFinalization`` -- an index over authoritative durable state (cursor, gate
decision and basis, archived Contracts, transaction journals, run-branch refs, the Project
Digest store, the tracked ContextSelection) -- at
``<RUNTIME_ROOT>/project/phase-context/<phase-id>.json``, and only then advances the cursor::

    durable gate PASS -> finalization published + verified -> successor outline -> cursor

A later Phase's finalization must reference the verified finalization of the Phase before it;
there is no legacy / assumed-complete marker. Finalization is deterministic software: no
provider is invoked and no project truth is invented.

Everything runs the real production code against fake provider executables, a real Git
source repository, real worktrees, the real planning/cursor/gate/Digest stores, and real
subprocess gate commands. No real Claude/Codex account, network, or model inference is used.

Baseline classification: RED at entry e0dea1b + 12.8 TEST_CORRECTION_COMMIT
(``lockstep.phase_context_finalization`` does not exist and Phase completion writes no
finalization).
"""

from __future__ import annotations

import ast
import hashlib
import inspect
import json
import os
import shutil
import subprocess
from collections.abc import Callable
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest
from phase_gate_support import (
    CrashError,
    GateProject,
    crash_once,
    fail_once_command,
    failing_command,
    git_head,
    passing_command,
    phase_plan,
    record_calls,
    remediation_plan_response,
    replan_response,
    run_git_text,
    standard_project,
    unit_script,
)
from test_canonical_project_run import _write_recording_claude
from test_supervisor_resume_execution import _budget

import lockstep.phase_context_finalization as finalization
import lockstep.phase_gate_cycle as phase_gate_cycle
from lockstep.context.context_pack import CONTEXT_PACK_HEADER, AuthorityKind
from lockstep.context.context_pack_builder import ContextSources, build_jit_replan_context_pack
from lockstep.context.context_selection_store import (
    context_selection_identity,
    load_context_selection,
    parse_context_selection,
)
from lockstep.context.project_digest import (
    DigestFact,
    DigestSource,
    DigestSourceKind,
    ProjectDigest,
)
from lockstep.context.project_digest_store import freeze_project_digest, load_project_digest
from lockstep.domain import PhaseId, ProjectId
from lockstep.jit_replan import ReplanBasis
from lockstep.phase_context_finalization import (
    PhaseContextFinalization,
    PhaseContextFinalizationError,
    canonical_phase_context_finalization_bytes,
    finalize_phase_context,
    load_phase_context_finalization,
    phase_context_finalization_identity,
    phase_context_finalization_path,
    publish_phase_context_finalization,
)
from lockstep.phase_gate import (
    PhaseGateDecision,
    PhaseGateError,
    PhaseGateEventKind,
    PhaseGateVerdict,
    load_phase_gate_decision,
    read_phase_gate_events,
)
from lockstep.phase_gate_cycle import (
    PhaseGateCycleDisposition,
    PhaseGateCycleResult,
    complete_phase_from_gate_pass,
    run_phase_gate_cycle,
)
from lockstep.planning_store import load_frozen_master_plan, load_phase_plan
from lockstep.project_cursor import PhaseGateStatus, ProjectCursor, master_plan_digest
from lockstep.project_cursor_store import load_project_cursor
from lockstep.project_orchestrator import ProjectRunDisposition, step_project_run

_P1 = PhaseId.model_validate("01")
_P2 = PhaseId.model_validate("02")
_TOP_LEVEL_FIELDS = {
    "schema_version",
    "project_id",
    "master_plan_digest",
    "phase_id",
    "final_repository_basis_commit",
    "final_phase_gate",
    "completed_subphases",
    "project_cursor",
    "project_digest",
    "context_selection",
    "previous_phase_finalization",
}
_AGENTS_TEXT = "Agents: always run the canonical health check before handing back."
_ARCHITECTURE_TEXT = "Architecture: the supervisor composes kernels; adapters stay thin."


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _two_commands(marker: Path) -> tuple[tuple[str, ...], ...]:
    return (passing_command(marker, "first"), passing_command(marker, "second"))


def _cycle(project: GateProject, *, remediations: int = 1) -> PhaseGateCycleResult:
    return run_phase_gate_cycle(
        project.runtime,
        max_gate_remediations=remediations,
        request_factory=project.factory,
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
    )


def _ready(project: GateProject, *, jit: bool = False) -> GateProject:
    assert project.run_phase(jit=jit).disposition is ProjectRunDisposition.PHASE_GATE_READY
    return project


def _two_phase(tmp_path: Path, **kwargs: Any) -> GateProject:
    """Phase 01 has one Sub-phase, Phase 02 one Sub-phase; neither has semantic criteria."""
    return standard_project(
        tmp_path,
        phases={"01": ("01",), "02": ("11",)},
        gate_commands=_two_commands,
        planner_tail=unit_script("02", "11"),
        extra_units=[("02", "11")],
        **kwargs,
    )


def _final_path(project: GateProject, phase: str) -> Path:
    return project.runtime_dir / "project" / "phase-context" / f"{phase}.json"


def _phase_context_names(project: GateProject) -> list[str]:
    directory = project.runtime_dir / "project" / "phase-context"
    return sorted(p.name for p in directory.iterdir()) if directory.exists() else []


def _cursor_bytes(project: GateProject) -> bytes:
    return (project.runtime_dir / "project" / "cursor.json").read_bytes()


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canonical(value: object) -> bytes:
    return (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")


def _kinds(project: GateProject, phase: PhaseId = _P1) -> list[PhaseGateEventKind]:
    return [e.kind for e in read_phase_gate_events(project.runtime_dir, phase)]


def _decision(project: GateProject, phase: PhaseId = _P1, attempt: int = 1) -> PhaseGateDecision:
    decision = load_phase_gate_decision(project.runtime_dir, phase, attempt)
    assert decision is not None
    return decision


def _stat(path: Path) -> tuple[int, int]:
    info = os.stat(path)
    return info.st_ino, info.st_mtime_ns


def _tree(root: Path) -> dict[str, bytes]:
    return {
        str(p.relative_to(root)): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()
    }


def _selection(*documents: tuple[str, str, tuple[str, ...]]) -> dict[str, object]:
    return {
        "schema_version": 1,
        "documents": [{"path": p, "kind": k, "operations": list(ops)} for p, k, ops in documents],
    }


def _write_selection(root: Path, payload: dict[str, object]) -> None:
    path = root / ".lockstep" / "project" / "context-selection.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2), encoding="utf-8")


_SELECTION_A = _selection(("AGENTS.md", "project_instructions", ("jit_replan",)))
_SELECTION_B = _selection(
    ("AGENTS.md", "project_instructions", ("jit_replan",)),
    ("docs/architecture.md", "project_documentation", ("jit_replan",)),
)


def _write_documents(root: Path) -> None:
    (root / "AGENTS.md").write_text(_AGENTS_TEXT, encoding="utf-8")
    (root / "CLAUDE.md").write_text("Claude-native instructions.", encoding="utf-8")
    (root / "docs").mkdir(exist_ok=True)
    (root / "docs" / "architecture.md").write_text(_ARCHITECTURE_TEXT, encoding="utf-8")
    (root / "skill").mkdir(exist_ok=True)
    (root / "skill" / "SKILL.md").write_text("A skill.", encoding="utf-8")


def _digest(statement: str, previous: str | None = None) -> ProjectDigest:
    return ProjectDigest(
        project_id=ProjectId.model_validate("lockstep"),
        previous_revision=previous,
        architecture=(
            DigestFact(
                fact_id="host-owned-artifacts",
                statement=statement,
                sources=(
                    DigestSource(kind=DigestSourceKind.TRACKED_CONFIG, locator="lockstep.toml"),
                ),
            ),
        ),
    )


def _digest_dir(project: GateProject) -> Path:
    return project.runtime_dir / "project" / "project-digest"


def _recording_planner(project: GateProject) -> None:
    """Swap the Planner's fake for one that also records prompts; responses keep their index."""
    bins = project.bins["planner"]
    responses = json.loads((bins / "claude-planner-responses.json").read_text(encoding="utf-8"))
    _write_recording_claude(bins, name="claude-planner", responses=responses)


def _planner_prompts(project: GateProject) -> list[str]:
    bins = project.bins["planner"]
    return [
        p.read_text(encoding="utf-8")
        for p in sorted(
            bins.glob("claude-planner-prompt-*.txt"), key=lambda p: int(p.stem.rsplit("-", 1)[1])
        )
    ]


def _section_after(prompt: str, heading: str) -> dict[str, Any]:
    marker = f"\n## {heading} ["
    start = prompt.index(marker)
    line = prompt[start:].split("\n")[2]  # "", "## HEADING [authority]", content
    value = json.loads(line)
    assert isinstance(value, dict)
    return value


def _manifest_sources(prompt: str) -> list[dict[str, Any]]:
    start = prompt.index(CONTEXT_PACK_HEADER) + len(CONTEXT_PACK_HEADER)
    sources = json.loads(prompt[start:].split("\n", 1)[0])["sources"]
    assert isinstance(sources, list)
    return sources


# ===========================================================================
# Public shape and boundaries
# ===========================================================================


def test_public_api_exports_expected_names() -> None:
    assert set(finalization.__all__) == {
        "ContextSelectionReference",
        "FinalPhaseGate",
        "FinalizedSubphase",
        "PhaseContextFinalization",
        "PhaseContextFinalizationError",
        "PreviousPhaseFinalization",
        "ProjectCursorReference",
        "canonical_phase_context_finalization_bytes",
        "finalize_phase_context",
        "finalized_phase_references",
        "load_phase_context_finalization",
        "phase_context_finalization_identity",
        "phase_context_finalization_path",
        "publish_phase_context_finalization",
    }


def test_finalization_errors_are_typed_phase_gate_refusals() -> None:
    assert issubclass(PhaseContextFinalizationError, PhaseGateError)


def test_the_destination_is_one_file_per_phase_under_runtime_project(tmp_path: Path) -> None:
    assert phase_context_finalization_path(tmp_path, _P1) == (
        tmp_path / "project" / "phase-context" / "01.json"
    )


def test_the_model_carries_no_session_transcript_time_or_prose_field() -> None:
    assert set(PhaseContextFinalization.model_fields) == _TOP_LEVEL_FIELDS
    schema = json.dumps(PhaseContextFinalization.model_json_schema()).lower()
    for word in ("session", "transcript", "timestamp", "occurred_at", "summary", "prompt", "cache"):
        assert word not in schema, word


def _imports(module: object) -> dict[str, set[str]]:
    tree = ast.parse(Path(inspect.getfile(module)).read_text(encoding="utf-8"))  # type: ignore[arg-type]
    found: dict[str, set[str]] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module is not None:
            found.setdefault(node.module, set()).update(alias.name for alias in node.names)
        elif isinstance(node, ast.Import):
            for alias in node.names:
                found.setdefault(alias.name, set())
    return found


def test_the_finalization_module_reads_the_project_digest_only() -> None:
    imports = _imports(finalization)
    source = Path(inspect.getfile(finalization)).read_text(encoding="utf-8")

    assert imports.get("lockstep.context.project_digest_store", set()) <= {
        "ProjectDigestStoreError",
        "load_project_digest",
        "load_project_digest_revision",
    }
    assert imports.get("lockstep.context.project_digest", set()) <= {"project_digest_identity"}
    for forbidden in ("freeze_project_digest", "current.json", "project-digest", "history/"):
        assert forbidden not in source, forbidden


def test_the_finalization_module_invokes_no_provider() -> None:
    imports = _imports(finalization)

    for module in imports:
        assert not module.startswith(
            (
                "lockstep.agents",
                "lockstep.agent_turn",
                "lockstep.planning_transport",
                "lockstep.implementer_turn",
                "lockstep.reviewer_turn",
                "lockstep.supervisor",
            )
        ), module
    names = set().union(*imports.values())
    assert not any(name.startswith("invoke") for name in names)


def test_the_completion_hook_is_imported_by_the_phase_gate_cycle() -> None:
    assert phase_gate_cycle.finalize_phase_context is finalize_phase_context


# ===========================================================================
# Tests F, G, O(absent), P, Q: a successful Phase finalization
# ===========================================================================


@pytest.fixture(scope="module")
def finalized(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    project = _ready(
        standard_project(
            tmp_path_factory.mktemp("finalized"),
            phases={"01": ("01", "02"), "02": ("11",)},
            gate_commands=_two_commands,
            planner_tail=unit_script("02", "11"),
            extra_units=[("02", "11")],
        )
    )
    ready = project.cursor()
    before = SimpleNamespace(
        cursor_bytes=_cursor_bytes(project),
        revision=ready.revision,
        counts=project.counts(),
        project_tree=_tree(project.project_root),
        tips={
            sid: git_head(project.worktree("01", sid), project.branch("01", sid))
            for sid in ("01", "02")
        },
    )
    result = _cycle(project)
    return SimpleNamespace(project=project, before=before, result=result)


def test_a_successful_phase_publishes_exactly_one_finalization(
    finalized: SimpleNamespace,
) -> None:
    project = finalized.project

    assert finalized.result.disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    assert _phase_context_names(project) == ["01.json"]
    assert sorted(p.name for p in (project.runtime_dir / "project").iterdir()) == [
        "cursor.json",
        "phase-context",
    ]


def test_the_published_bytes_are_canonical_and_reload_equal(finalized: SimpleNamespace) -> None:
    project = finalized.project
    raw = _final_path(project, "01").read_bytes()

    loaded = load_phase_context_finalization(project.runtime_dir, _P1)

    assert loaded is not None
    assert canonical_phase_context_finalization_bytes(loaded) == raw
    assert raw == _canonical(json.loads(raw))
    assert raw.endswith(b"}\n") and raw.count(b"\n") == 1
    assert phase_context_finalization_identity(loaded) == _sha(raw)
    assert PhaseContextFinalization.model_validate_json(raw) == loaded


def test_the_finalization_names_the_master_plan_phase_and_final_basis(
    finalized: SimpleNamespace,
) -> None:
    project = finalized.project
    data = json.loads(_final_path(project, "01").read_bytes())
    cursor = project.cursor()

    assert set(data) == _TOP_LEVEL_FIELDS
    assert data["schema_version"] == 1
    assert data["project_id"] == "lockstep"
    assert data["master_plan_digest"] == cursor.master_plan_digest
    assert data["phase_id"] == "01"
    assert data["final_repository_basis_commit"] == finalized.before.tips["02"]


def test_the_finalization_names_the_exact_passing_gate(finalized: SimpleNamespace) -> None:
    project = finalized.project
    data = json.loads(_final_path(project, "01").read_bytes())
    attempt = project.attempt_dir("01", 1)

    assert data["final_phase_gate"] == {
        "gate_attempt": 1,
        "basis_run_id": "run-01-02",
        "rule": "latest_phase_subphase",
        "decision_sha256": _sha((attempt / "decision.json").read_bytes()),
        "basis_sha256": _sha((attempt / "basis.json").read_bytes()),
        "outcome": "pass",
    }


def test_the_finalization_names_every_completed_subphase_in_order(
    finalized: SimpleNamespace,
) -> None:
    project = finalized.project
    data = json.loads(_final_path(project, "01").read_bytes())
    entries = [e for e in project.cursor().completed_subphases if e.phase_id == _P1]

    assert data["completed_subphases"] == [
        {
            "subphase_id": entry.subphase_id.root,
            "run_id": entry.run_id.root,
            "contract_digest": entry.contract_digest,
            "accepted_commit": finalized.before.tips[entry.subphase_id.root],
        }
        for entry in entries
    ]
    assert [e["subphase_id"] for e in data["completed_subphases"]] == ["01", "02"]


def test_the_finalization_names_the_ready_cursor_it_crossed(finalized: SimpleNamespace) -> None:
    data = json.loads(_final_path(finalized.project, "01").read_bytes())

    assert data["project_cursor"] == {
        "revision": finalized.before.revision,
        "sha256": _sha(finalized.before.cursor_bytes),
    }
    assert finalized.project.cursor().revision == finalized.before.revision + 1


def test_absent_digest_selection_and_first_phase_are_explicit_nulls(
    finalized: SimpleNamespace,
) -> None:
    project = finalized.project
    data = json.loads(_final_path(project, "01").read_bytes())

    assert data["project_digest"] is None
    assert data["context_selection"] is None
    assert data["previous_phase_finalization"] is None
    assert not _digest_dir(project).exists()


def test_finalization_authors_no_project_context(finalized: SimpleNamespace) -> None:
    project = finalized.project

    assert _tree(project.project_root) == finalized.before.project_tree
    assert not (project.project_root / ".lockstep" / "project" / "context-selection.json").exists()


def test_finalization_invokes_no_provider(finalized: SimpleNamespace) -> None:
    assert finalized.project.counts() == finalized.before.counts


# ===========================================================================
# Tests M, N, O(present), P, T: a recorded boundary, drift, chain, completed history
# ===========================================================================


@pytest.fixture(scope="module")
def chain(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    project = standard_project(
        tmp_path_factory.mktemp("chain"),
        phases={"01": ("01",), "02": ("11", "12")},
        gate_commands=_two_commands,
        planner_tail=[
            *unit_script("02", "11"),
            # The JIT Planner keeps Phase 02's frozen outline unchanged.
            replan_response(phase_plan("02", ("11", "12"), depends_on=("01",))),
            *unit_script("02", "12"),
        ],
        extra_units=[("02", "11"), ("02", "12")],
    )

    root = project.project_root
    _write_documents(root)
    _write_selection(root, _SELECTION_A)
    d1 = freeze_project_digest(root, project.runtime_dir, _digest("First revision."))
    project_tree = _tree(root)
    digest_tree = _tree(_digest_dir(project))

    _ready(project)
    counts_before_gate = project.counts()
    first = _cycle(project)
    p1_bytes, p1_stat = _final_path(project, "01").read_bytes(), _stat(_final_path(project, "01"))
    after_first = SimpleNamespace(
        project_tree=_tree(root),
        digest_tree=_tree(_digest_dir(project)),
        counts=project.counts(),
    )

    _write_selection(root, _SELECTION_B)  # drift after Phase 01 completed
    _recording_planner(project)
    _ready(project, jit=True)
    second = _cycle(project)
    return SimpleNamespace(
        project=project,
        d1=d1,
        first=first,
        second=second,
        p1_bytes=p1_bytes,
        p1_stat=p1_stat,
        project_tree=project_tree,
        digest_tree=digest_tree,
        counts_before_gate=counts_before_gate,
        after_first=after_first,
    )


def test_both_phases_complete_through_their_finalizations(chain: SimpleNamespace) -> None:
    project = chain.project

    assert chain.first.disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    assert chain.second.disposition is PhaseGateCycleDisposition.PROJECT_COMPLETE
    assert project.cursor().phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE
    assert _phase_context_names(project) == ["01.json", "02.json"]


def test_the_boundary_records_the_digest_revision_and_selection_identity(
    chain: SimpleNamespace,
) -> None:
    data = json.loads(chain.p1_bytes)
    selection_a = context_selection_identity(
        parse_context_selection(json.dumps(_SELECTION_A).encode("utf-8"))
    )

    assert data["project_digest"] == chain.d1
    assert data["context_selection"] == {"schema_version": 1, "identity": selection_a}


def test_finalization_never_mutates_the_project_digest(chain: SimpleNamespace) -> None:
    assert chain.after_first.digest_tree == chain.digest_tree
    assert _tree(_digest_dir(chain.project)) == chain.digest_tree
    loaded = load_project_digest(chain.project.project_root, chain.project.runtime_dir)
    assert loaded is not None


def test_finalization_never_mutates_permanent_project_context(chain: SimpleNamespace) -> None:
    assert chain.after_first.project_tree == chain.project_tree
    master = chain.project.project_root / ".lockstep" / "project" / "master-plan.json"
    assert master.read_bytes() == chain.project_tree[".lockstep/project/master-plan.json"]


def test_the_gate_boundary_invokes_no_provider(chain: SimpleNamespace) -> None:
    assert chain.after_first.counts == chain.counts_before_gate


def test_a_later_phase_references_the_exact_previous_finalization(chain: SimpleNamespace) -> None:
    project = chain.project
    p2 = json.loads(_final_path(project, "02").read_bytes())

    assert p2["previous_phase_finalization"] == {"phase_id": "01", "identity": _sha(chain.p1_bytes)}
    assert p2["phase_id"] == "02"
    assert [e["subphase_id"] for e in p2["completed_subphases"]] == ["11", "12"]


def test_selection_drift_never_rewrites_the_earlier_handoff(chain: SimpleNamespace) -> None:
    project = chain.project
    path = _final_path(project, "01")
    p2 = json.loads(_final_path(project, "02").read_bytes())
    selection_b = context_selection_identity(load_context_selection(project.project_root))

    assert path.read_bytes() == chain.p1_bytes
    assert _stat(path) == chain.p1_stat
    assert json.loads(chain.p1_bytes)["context_selection"]["identity"] != selection_b
    assert p2["context_selection"] == {"schema_version": 1, "identity": selection_b}


def _jit_prompt(chain: SimpleNamespace) -> str:
    prompts = [p for p in _planner_prompts(chain.project) if '"operation":"jit_replan"' in p]
    assert len(prompts) == 1
    return prompts[0]


def test_the_next_phase_context_uses_the_newer_selection(chain: SimpleNamespace) -> None:
    prompt = _jit_prompt(chain)

    assert _ARCHITECTURE_TEXT in prompt
    assert _AGENTS_TEXT in prompt


def test_completed_history_carries_the_finalized_phase_reference(chain: SimpleNamespace) -> None:
    prompt = _jit_prompt(chain)
    history = _section_after(prompt, "COMPLETED HISTORY")
    identity = _sha(chain.p1_bytes)

    assert history["finalized_phases"] == [
        {"phase_id": "01", "identity": identity, "reference": f"phase-context:01@{identity}"}
    ]
    assert history["phase_id"] == "02"


def test_completed_history_stays_compact_and_keeps_its_authority(chain: SimpleNamespace) -> None:
    prompt = _jit_prompt(chain)
    history = _section_after(prompt, "COMPLETED HISTORY")
    [source] = [s for s in _manifest_sources(prompt) if s["kind"] == "completed_history"]

    assert set(history) == {"phase_id", "subphases", "accepted", "finalized_phases"}
    for entry in history["finalized_phases"]:
        assert set(entry) == {"phase_id", "identity", "reference"}
    assert source["authority"] == AuthorityKind.FROZEN_REQUIREMENT.value
    assert "## COMPLETED HISTORY [frozen_requirement]" in prompt
    for evidence in ("decision.json", "events.jsonl", "subphase_complete", "test_commit"):
        assert evidence not in prompt.lower()


def test_a_first_phase_completed_history_has_no_finalized_member(tmp_path: Path) -> None:
    project = standard_project(
        tmp_path, phases={"01": ("01", "02")}, gate_commands=_two_commands, planner_tail=[]
    )
    master = load_frozen_master_plan(project.project_root)
    assert master is not None
    outline = master.phases[0].subphases
    cursor = ProjectCursor(
        project_id=master.project_id,
        master_plan_digest=master_plan_digest(master),
        revision=1,
        current_phase=_P1,
        current_subphase=outline[0].subphase_id,
        remaining_outline=outline[1:],
    )
    basis = ReplanBasis.model_validate(
        {
            "phase_id": "01",
            "subphase_id": "01",
            "run_id": "run-01-01",
            "contract_digest": "0" * 64,
            "branch": "lockstep/run/run-01-01",
            "commit": "0" * 40,
        }
    )
    sources = ContextSources(
        project_id=master.project_id,
        project_root=project.project_root,
        runtime_dir=project.runtime_dir,
    )

    pack = build_jit_replan_context_pack(
        sources, master_plan=master, phase_plan=master.phases[0], cursor=cursor, basis=basis
    )

    [history] = [s for s in pack.sections if s.kind.value == "completed_history"]
    assert set(json.loads(history.content)) == {"phase_id", "subphases", "accepted"}


# ===========================================================================
# Test H: publish before completion; a failed publication blocks completion
# ===========================================================================


def test_finalization_precedes_successor_publication_and_cursor_advance(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _ready(_two_phase(tmp_path))
    order: list[str] = []
    observed: dict[str, object] = {}

    def watch(name: str) -> None:
        original = getattr(phase_gate_cycle, name)

        def wrapper(*args: Any, **kwargs: Any) -> Any:
            order.append(name)
            if name == "record_phase_completion":
                observed["final_exists"] = _final_path(project, "01").is_file()
                observed["cursor_ready"] = (
                    project.cursor().phase_gate_status is PhaseGateStatus.READY
                )
            result = original(*args, **kwargs)
            if name == "finalize_phase_context":
                observed["published"] = _final_path(project, "01").is_file()
                observed["cursor_after_finalize"] = project.cursor().current_phase
            return result

        monkeypatch.setattr(phase_gate_cycle, name, wrapper)

    for name in ("finalize_phase_context", "publish_phase_plan", "record_phase_completion"):
        watch(name)

    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    assert order == ["finalize_phase_context", "publish_phase_plan", "record_phase_completion"]
    assert observed == {
        "published": True,
        "cursor_after_finalize": _P1,
        "final_exists": True,
        "cursor_ready": True,
    }


def test_a_failed_publication_leaves_the_phase_incomplete(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _ready(_two_phase(tmp_path))
    before = _cursor_bytes(project)
    crash_once(monkeypatch, finalization, "publish_phase_context_finalization")

    with pytest.raises(CrashError):
        _cycle(project)

    assert _phase_context_names(project) == []
    assert _cursor_bytes(project) == before
    assert project.cursor().phase_gate_status is PhaseGateStatus.READY
    published = load_phase_plan(project.project_root, project.runtime_dir)
    assert published is not None and published.phase_id == _P1  # no successor outline
    assert PhaseGateEventKind.PHASE_COMPLETE not in _kinds(project)


def test_crash_window_a_rebuilds_the_finalization_from_the_settled_pass(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _ready(_two_phase(tmp_path))
    crash_once(monkeypatch, phase_gate_cycle, "finalize_phase_context")
    with pytest.raises(CrashError):
        _cycle(project)
    assert _phase_context_names(project) == []
    rows, counts = project.markers(), project.counts()

    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    assert [a.reused for a in result.attempts] == [True]
    assert project.markers() == rows  # no gate rerun
    assert project.counts() == counts  # no provider call
    assert _phase_context_names(project) == ["01.json"]


# ===========================================================================
# Test I: crash after finalization, before cursor advancement (crash window B)
# ===========================================================================


@pytest.mark.parametrize("seam", ["publish_phase_plan", "record_phase_completion"])
def test_crash_window_b_resumes_without_rerun_or_rewrite_and_advances_once(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, seam: str
) -> None:
    project = _ready(_two_phase(tmp_path))
    ready_revision = project.cursor().revision
    crash_once(monkeypatch, phase_gate_cycle, seam)
    with pytest.raises(CrashError):
        _cycle(project)
    path = _final_path(project, "01")
    assert path.is_file()
    assert project.cursor().phase_gate_status is PhaseGateStatus.READY
    raw, stat = path.read_bytes(), _stat(path)
    rows, counts = project.markers(), project.counts()
    publications = record_calls(monkeypatch, finalization, "publish_phase_context_finalization")

    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    assert [a.reused for a in result.attempts] == [True]
    assert project.markers() == rows
    assert project.counts() == counts
    assert publications == []
    assert path.read_bytes() == raw
    assert _stat(path) == stat
    cursor = project.cursor()
    assert cursor.completed_phases == (_P1,)
    assert cursor.revision == ready_revision + 1
    assert _kinds(project).count(PhaseGateEventKind.PHASE_COMPLETE) == 1


# ===========================================================================
# Test J: idempotent replay; conflicting state fails closed
# ===========================================================================


def _crashed_before_cursor(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> GateProject:
    project = _ready(_two_phase(tmp_path))
    crash_once(monkeypatch, phase_gate_cycle, "record_phase_completion")
    with pytest.raises(CrashError):
        _cycle(project)
    return project


def test_finalizing_identical_durable_state_again_is_idempotent(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _crashed_before_cursor(tmp_path, monkeypatch)
    raw = _final_path(project, "01").read_bytes()

    first = finalize_phase_context(project.runtime, _decision(project))
    second = finalize_phase_context(project.runtime, _decision(project))

    assert first == second
    assert phase_context_finalization_identity(first) == _sha(raw)
    assert _final_path(project, "01").read_bytes() == raw
    assert _phase_context_names(project) == ["01.json"]
    assert publish_phase_context_finalization(project.runtime_dir, first) == _sha(raw)


def test_completing_an_already_completed_phase_reuses_its_finalization(
    tmp_path: Path,
) -> None:
    project = _ready(_two_phase(tmp_path))
    assert _cycle(project).disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    path = _final_path(project, "01")
    raw, stat, cursor = path.read_bytes(), _stat(path), _cursor_bytes(project)

    again = complete_phase_from_gate_pass(project.runtime, _decision(project))

    assert again.completed_phases == (_P1,)
    assert path.read_bytes() == raw and _stat(path) == stat
    assert _cursor_bytes(project) == cursor


def test_a_conflicting_finalization_for_the_same_phase_is_refused(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _crashed_before_cursor(tmp_path, monkeypatch)
    path = _final_path(project, "01")
    raw = path.read_bytes()
    existing = load_phase_context_finalization(project.runtime_dir, _P1)
    assert existing is not None
    conflicting = existing.model_copy(update={"final_repository_basis_commit": "f" * 40})

    with pytest.raises(PhaseContextFinalizationError):
        publish_phase_context_finalization(project.runtime_dir, conflicting)

    assert path.read_bytes() == raw


def test_a_tampered_finalization_blocks_resumed_completion(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _crashed_before_cursor(tmp_path, monkeypatch)
    path = _final_path(project, "01")
    data = json.loads(path.read_bytes())
    data["completed_subphases"][0]["contract_digest"] = "0" * 64  # valid, but not the truth
    path.write_bytes(_canonical(data))
    before = _cursor_bytes(project)

    with pytest.raises(PhaseGateError):
        _cycle(project)

    assert _cursor_bytes(project) == before
    assert path.read_bytes() == _canonical(data)  # never repaired


def test_completed_phase_without_finalization_fails_closed_on_replay(tmp_path: Path) -> None:
    project = _ready(_two_phase(tmp_path))
    assert _cycle(project).disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    _final_path(project, "01").unlink()
    before = _cursor_bytes(project)

    with pytest.raises(PhaseGateError):
        complete_phase_from_gate_pass(project.runtime, _decision(project))

    assert _cursor_bytes(project) == before
    assert _phase_context_names(project) == []


# ===========================================================================
# Test K: the final Phase also finalizes before project completion
# ===========================================================================


def test_the_final_phase_finalizes_before_project_complete(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _ready(
        standard_project(
            tmp_path, phases={"01": ("01",)}, gate_commands=_two_commands, planner_tail=[]
        )
    )
    order: list[str] = []

    def watch(name: str) -> None:
        original = getattr(phase_gate_cycle, name)

        def wrapper(*args: Any, **kwargs: Any) -> Any:
            order.append(name)
            return original(*args, **kwargs)

        monkeypatch.setattr(phase_gate_cycle, name, wrapper)

    for name in ("finalize_phase_context", "publish_phase_plan", "record_phase_completion"):
        watch(name)

    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.PROJECT_COMPLETE
    assert order == ["finalize_phase_context", "record_phase_completion"]
    assert project.cursor().phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE
    data = json.loads(_final_path(project, "01").read_bytes())
    assert data["phase_id"] == "01"
    assert data["previous_phase_finalization"] is None


# ===========================================================================
# Test L: a failed gate and its remediation never finalize prematurely
# ===========================================================================


def test_only_the_eventual_passing_basis_is_finalized(tmp_path: Path) -> None:
    flag = tmp_path / "fail-once.flag"
    (tmp_path / "p").mkdir()
    project = _ready(
        standard_project(
            tmp_path / "p",
            phases={"01": ("01", "02")},
            gate_commands=lambda marker: (fail_once_command(marker, flag, "gate"),),
            planner_tail=[
                remediation_plan_response("01", ("01", "02"), "03"),
                *unit_script("01", "03"),
            ],
            extra_units=[("01", "03")],
        )
    )

    exhausted = _cycle(project, remediations=0)
    assert exhausted.disposition is PhaseGateCycleDisposition.GATE_REMEDIATION_EXHAUSTED
    assert _phase_context_names(project) == []

    result = _cycle(project, remediations=1)

    assert result.disposition is PhaseGateCycleDisposition.PROJECT_COMPLETE
    assert _phase_context_names(project) == ["01.json"]
    data = json.loads(_final_path(project, "01").read_bytes())
    attempt_two = project.attempt_dir("01", 2)
    assert data["final_phase_gate"]["gate_attempt"] == 2
    assert data["final_phase_gate"]["basis_run_id"] == "run-01-03"
    assert data["final_phase_gate"]["decision_sha256"] == _sha(
        (attempt_two / "decision.json").read_bytes()
    )
    assert data["final_repository_basis_commit"] == git_head(
        project.worktree("01", "03"), project.branch("01", "03")
    )
    assert [e["subphase_id"] for e in data["completed_subphases"]] == ["01", "02", "03"]
    failed = load_phase_gate_decision(project.runtime_dir, _P1, 1)
    assert failed is not None and failed.outcome is PhaseGateVerdict.FAIL  # evidence only


def test_a_failing_decision_never_finalizes(tmp_path: Path) -> None:
    project = _ready(
        standard_project(
            tmp_path,
            phases={"01": ("01",)},
            gate_commands=lambda marker: (failing_command(marker, "gate"),),
            planner_tail=[],
        )
    )
    assert _cycle(project, remediations=0).disposition is (
        PhaseGateCycleDisposition.GATE_REMEDIATION_EXHAUSTED
    )
    failed = _decision(project)
    before = _cursor_bytes(project)

    with pytest.raises(PhaseGateError):
        finalize_phase_context(project.runtime, failed)
    with pytest.raises(PhaseGateError):
        complete_phase_from_gate_pass(project.runtime, failed)

    assert _phase_context_names(project) == []
    assert _cursor_bytes(project) == before


# ===========================================================================
# Test E and the impossible states: preconditions fail closed
# ===========================================================================


def _crashed_before_finalization(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> GateProject:
    """Durable PASS for Phase 01 (Sub-phases 01, 02); the process died before finalization."""
    project = _ready(
        standard_project(
            tmp_path,
            phases={"01": ("01", "02"), "02": ("11",)},
            gate_commands=_two_commands,
            planner_tail=unit_script("02", "11"),
            extra_units=[("02", "11")],
        )
    )
    crash_once(monkeypatch, phase_gate_cycle, "finalize_phase_context")
    with pytest.raises(CrashError):
        _cycle(project)
    assert _decision(project).outcome is PhaseGateVerdict.PASS
    return project


def _later_attempt(project: GateProject) -> None:
    project.attempt_dir("01", 2).mkdir()


def _basis_mismatch(project: GateProject) -> None:
    path = project.attempt_dir("01", 1) / "basis.json"
    data = json.loads(path.read_bytes())
    data["commit"] = git_head(project.worktree("01", "02"), "HEAD~1")
    path.write_bytes(_canonical(data))


def _decision_mismatch(project: GateProject) -> None:
    path = project.attempt_dir("01", 1) / "decision.json"
    data = json.loads(path.read_bytes())
    data["basis_commit"] = git_head(project.worktree("01", "02"), "HEAD~1")
    path.write_bytes(_canonical(data))


def _dirty_basis(project: GateProject) -> None:
    (project.worktree("01", "02") / "feature_02.py").write_text("# drifted\n", encoding="utf-8")


def _moved_basis(project: GateProject) -> None:
    worktree = project.worktree("01", "02")
    (worktree / "feature_02.py").write_text("# moved\n", encoding="utf-8")
    run_git_text(worktree, "commit", "-am", "move the accepted branch")


def _missing_contract(project: GateProject) -> None:
    [archived] = (project.runtime_dir / "contracts" / "history").glob("01-01-*.json")
    archived.unlink()


def _missing_journal(project: GateProject) -> None:
    shutil.rmtree(project.txn_dir("01", "01"))


def _missing_ref(project: GateProject) -> None:
    run_git_text(project.source, "update-ref", "-d", "refs/heads/lockstep/run/run-01-01")


def _not_ancestor(project: GateProject) -> None:
    empty_tree = run_git_text(project.source, "hash-object", "-t", "tree", "/dev/null").strip()
    orphan = subprocess.run(
        ["git", "-C", str(project.source), "commit-tree", empty_tree, "-m", "orphan"],
        check=True,
        capture_output=True,
        text=True,
        env={**os.environ, **_git_identity()},
    ).stdout.strip()
    run_git_text(project.source, "update-ref", "refs/heads/lockstep/run/run-01-01", orphan)


def _git_identity() -> dict[str, str]:
    return {
        "GIT_AUTHOR_NAME": "t",
        "GIT_AUTHOR_EMAIL": "t@example.invalid",
        "GIT_COMMITTER_NAME": "t",
        "GIT_COMMITTER_EMAIL": "t@example.invalid",
    }


def _active_planning_contract(project: GateProject) -> None:
    [archived] = (project.runtime_dir / "contracts" / "history").glob("01-01-*.json")
    shutil.copyfile(archived, project.runtime_dir / "contracts" / "active.json")


_TAMPERS: dict[str, Callable[[GateProject], None]] = {
    "later-attempt": _later_attempt,
    "basis-mismatch": _basis_mismatch,
    "decision-mismatch": _decision_mismatch,
    "dirty-basis": _dirty_basis,
    "moved-basis": _moved_basis,
    "missing-contract": _missing_contract,
    "missing-journal": _missing_journal,
    "missing-ref": _missing_ref,
    "not-ancestor": _not_ancestor,
    "active-planning-contract": _active_planning_contract,
}


@pytest.mark.parametrize("tamper", sorted(_TAMPERS))
def test_inconsistent_durable_evidence_blocks_finalization_and_completion(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, tamper: str
) -> None:
    project = _crashed_before_finalization(tmp_path, monkeypatch)
    decision = _decision(project)  # the PASS the cycle accepted
    _TAMPERS[tamper](project)
    before = _cursor_bytes(project)

    with pytest.raises(PhaseGateError):
        complete_phase_from_gate_pass(project.runtime, decision)

    assert _phase_context_names(project) == []
    assert _cursor_bytes(project) == before
    published = load_phase_plan(project.project_root, project.runtime_dir)
    assert published is not None and published.phase_id == _P1
    assert PhaseGateEventKind.PHASE_COMPLETE not in _kinds(project)


def test_a_pass_that_was_never_durably_decided_cannot_finalize(tmp_path: Path) -> None:
    project = _ready(_two_phase(tmp_path))
    cursor = project.cursor()
    fabricated = PhaseGateDecision(
        project_id=cursor.project_id,
        master_plan_digest=cursor.master_plan_digest,
        phase_id=_P1,
        gate_attempt=1,
        basis_commit=git_head(project.worktree("01", "01"), project.branch("01", "01")),
        outcome=PhaseGateVerdict.PASS,
        deterministic_passed=True,
        summary="never run",
    )
    before = _cursor_bytes(project)

    with pytest.raises(PhaseGateError):
        finalize_phase_context(project.runtime, fabricated)
    with pytest.raises(PhaseGateError):
        complete_phase_from_gate_pass(project.runtime, fabricated)

    assert _phase_context_names(project) == []
    assert _cursor_bytes(project) == before


def test_unfinished_subphases_and_an_active_contract_cannot_finalize(
    tmp_path: Path,
) -> None:
    project = standard_project(
        tmp_path, phases={"01": ("01", "02")}, gate_commands=_two_commands, planner_tail=[]
    )

    def step() -> None:
        outcome = step_project_run(
            project.runtime,
            request_factory=project.factory,
            retry_budget=_budget(3),
            planning_timeout_seconds=60.0,
            jit_replan=False,
        )
        assert outcome is None

    def completed() -> int:
        cursor = load_project_cursor(project.project_root, project.runtime_dir)
        return 0 if cursor is None else len(cursor.completed_subphases)

    while not completed():
        step()
    unfinished = project.cursor()
    assert unfinished.current_subphase is not None and unfinished.active_contract is None
    fabricated = PhaseGateDecision(
        project_id=unfinished.project_id,
        master_plan_digest=unfinished.master_plan_digest,
        phase_id=_P1,
        gate_attempt=1,
        basis_commit=git_head(project.worktree("01", "01"), project.branch("01", "01")),
        outcome=PhaseGateVerdict.PASS,
        deterministic_passed=True,
        summary="premature",
    )

    def refused() -> None:
        before = _cursor_bytes(project)
        with pytest.raises(PhaseGateError):
            finalize_phase_context(project.runtime, fabricated)
        assert _phase_context_names(project) == []
        assert _cursor_bytes(project) == before

    refused()  # an unfinished Sub-phase remains
    step()  # the next Contract is frozen and bound
    assert project.cursor().active_contract is not None
    refused()  # an active Contract


# ===========================================================================
# Tests S, T, U: the strict previous-finalization chain
# ===========================================================================


def _phase_one_complete_then_ready(tmp_path: Path) -> GateProject:
    project = _ready(_two_phase(tmp_path))
    assert _cycle(project).disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    assert _final_path(project, "01").is_file()
    return project


def test_a_missing_previous_finalization_stops_the_next_completion(tmp_path: Path) -> None:
    project = _phase_one_complete_then_ready(tmp_path)
    _final_path(project, "01").unlink()  # a runtime that completed Phase 01 before 12.8
    _ready(project)
    before, counts = _cursor_bytes(project), project.counts()

    for _ in range(2):  # deterministic: the same refusal every time
        with pytest.raises(PhaseGateError):
            _cycle(project)
        assert _phase_context_names(project) == []
        assert _cursor_bytes(project) == before
        assert project.cursor().current_phase == _P2
        assert project.counts() == counts
    assert PhaseGateEventKind.PHASE_COMPLETE not in _kinds(project, _P2)


def test_a_valid_previous_chain_completes_the_next_phase(tmp_path: Path) -> None:
    project = _phase_one_complete_then_ready(tmp_path)
    p1 = _final_path(project, "01").read_bytes()
    _ready(project)

    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.PROJECT_COMPLETE
    p2 = json.loads(_final_path(project, "02").read_bytes())
    assert p2["previous_phase_finalization"] == {"phase_id": "01", "identity": _sha(p1)}
    assert _final_path(project, "01").read_bytes() == p1


def _garbage(path: Path) -> None:
    path.write_bytes(path.read_bytes() + b" ")


def _rewritten(path: Path) -> None:
    data = json.loads(path.read_bytes())
    data["final_phase_gate"]["decision_sha256"] = "0" * 64
    path.write_bytes(_canonical(data))


def _foreign_phase(path: Path) -> None:
    data = json.loads(path.read_bytes())
    data["completed_subphases"][0]["contract_digest"] = "0" * 64
    path.write_bytes(_canonical(data))


@pytest.mark.parametrize(
    "tamper", [_garbage, _rewritten, _foreign_phase], ids=["bytes", "gate", "subphases"]
)
def test_a_tampered_previous_finalization_stops_the_next_completion(
    tmp_path: Path, tamper: Callable[[Path], None]
) -> None:
    project = _phase_one_complete_then_ready(tmp_path)
    tamper(_final_path(project, "01"))
    _ready(project)
    before = _cursor_bytes(project)

    with pytest.raises(PhaseGateError):
        _cycle(project)

    assert _phase_context_names(project) == ["01.json"]
    assert _cursor_bytes(project) == before


def test_a_changed_previous_finalization_contradicts_a_recorded_reference(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _phase_one_complete_then_ready(tmp_path)
    _ready(project)
    crash_once(monkeypatch, phase_gate_cycle, "record_phase_completion")
    with pytest.raises(CrashError):
        _cycle(project)
    assert _final_path(project, "02").is_file()
    # A *valid, canonical* replacement of Phase 01's artifact: only the reference catches it.
    previous = load_phase_context_finalization(project.runtime_dir, _P1)
    assert previous is not None
    replaced = previous.model_copy(
        update={"project_cursor": previous.project_cursor.model_copy(update={"revision": 1})}
    )
    _final_path(project, "01").write_bytes(canonical_phase_context_finalization_bytes(replaced))
    before = _cursor_bytes(project)

    with pytest.raises(PhaseGateError):
        _cycle(project)

    assert _cursor_bytes(project) == before


# ===========================================================================
# Tests V, W: boundary snapshot drift inside crash window B
# ===========================================================================


def test_selection_drift_inside_the_crash_window_keeps_the_recorded_boundary(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _two_phase(tmp_path)
    _write_documents(project.project_root)
    _write_selection(project.project_root, _SELECTION_A)
    identity_a = context_selection_identity(load_context_selection(project.project_root))
    _ready(project)
    crash_once(monkeypatch, phase_gate_cycle, "record_phase_completion")
    with pytest.raises(CrashError):
        _cycle(project)
    path = _final_path(project, "01")
    raw, stat = path.read_bytes(), _stat(path)
    assert json.loads(raw)["context_selection"] == {"schema_version": 1, "identity": identity_a}

    _write_selection(project.project_root, _SELECTION_B)
    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    assert path.read_bytes() == raw and _stat(path) == stat
    assert project.cursor().completed_phases == (_P1,)
    future = load_context_selection(project.project_root)  # what the next request loads
    assert context_selection_identity(future) != identity_a
    assert len(future.documents) == 2


def test_digest_drift_inside_the_crash_window_keeps_the_recorded_revision(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _two_phase(tmp_path)
    root, runtime_dir = project.project_root, project.runtime_dir
    d1 = freeze_project_digest(root, runtime_dir, _digest("First revision."))
    _ready(project)
    crash_once(monkeypatch, phase_gate_cycle, "record_phase_completion")
    with pytest.raises(CrashError):
        _cycle(project)
    path = _final_path(project, "01")
    raw, stat = path.read_bytes(), _stat(path)
    assert json.loads(raw)["project_digest"] == d1

    d2 = freeze_project_digest(root, runtime_dir, _digest("Second revision.", previous=d1))
    result = _cycle(project)

    assert result.disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    assert path.read_bytes() == raw and _stat(path) == stat
    assert d2 != d1
    current = load_project_digest(root, runtime_dir)
    assert current is not None and current.previous_revision == d1  # the next Phase sees d2


def test_an_invalid_recorded_digest_revision_fails_closed(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _two_phase(tmp_path)
    root, runtime_dir = project.project_root, project.runtime_dir
    d1 = freeze_project_digest(root, runtime_dir, _digest("First revision."))
    _ready(project)
    crash_once(monkeypatch, phase_gate_cycle, "record_phase_completion")
    with pytest.raises(CrashError):
        _cycle(project)
    freeze_project_digest(root, runtime_dir, _digest("Second revision.", previous=d1))
    history = _digest_dir(project) / "history" / f"{d1}.json"
    history.write_bytes(history.read_bytes() + b" ")
    before = _cursor_bytes(project)

    with pytest.raises(PhaseGateError):
        _cycle(project)

    assert _cursor_bytes(project) == before
