"""Phase 12.9: deterministic teardown of a completed Phase's transient execution residue.

After a Phase is durably finalized *and* recorded complete, the residue that only served to
produce it -- its run worktrees and verification bytecode caches -- is removed, while every
piece of durable truth (cursor, finalizations, gate evidence, archived Contracts, transaction
journals and artifacts, JIT receipts, project-run history, Project Digest, ContextSelection,
Master Plan, run branches and accepted commits) stays byte-identical::

    gate PASS -> finalization -> cursor completion -> teardown -> next-Phase work

Eligibility needs both a verifying finalization and cursor completion. The worktree of the
cursor's latest accepted Sub-phase is the live accepted basis and is never a target. Removal is
Git-aware (``git worktree remove``, never forced), validated before anything is deleted,
idempotent and crash-safe without a receipt, and invokes no provider.

Everything runs the real production code against fake provider executables, a real Git source
repository, real worktrees, the real planning/cursor/gate stores and real subprocess gate
commands. No real Claude/Codex account, network, or model inference is used.

Baseline classification: RED at entry 5c768d5 (``lockstep.phase_teardown`` does not exist and
nothing removes completed-Phase residue).
"""

from __future__ import annotations

import ast
import inspect
import json
import os
import shutil
from pathlib import Path
from types import SimpleNamespace
from typing import Any

import pytest
from autonomous_run_support import FakeClock, autonomous_project, make_policy, run_autonomous
from phase_gate_support import (
    CrashError,
    GateProject,
    crash_after_once,
    crash_once,
    git_head,
    passing_command,
    record_calls,
    run_git_text,
    standard_project,
    unit_script,
)
from test_supervisor_resume_execution import _budget

import lockstep.autonomous_run as autonomous_run
import lockstep.phase_gate_cycle as phase_gate_cycle
import lockstep.phase_teardown as teardown
from lockstep.autonomous_run_control import AutonomousRunDisposition
from lockstep.context.context_pack import CONTEXT_PACK_HEADER
from lockstep.domain import ExecutionEventKind, PhaseId, RunId
from lockstep.git import measure_repository_change
from lockstep.metrics import project_runtime_metrics
from lockstep.persistence import ExecutionEvent, read_events
from lockstep.phase_context_finalization import (
    finalize_phase_context,
    load_phase_context_finalization,
    phase_context_finalization_identity,
)
from lockstep.phase_gate import PhaseGateEventKind, load_phase_gate_decision
from lockstep.phase_gate_cycle import PhaseGateCycleDisposition, run_phase_gate_cycle
from lockstep.phase_teardown import (
    PhaseTeardownError,
    PhaseTeardownResult,
    ensure_completed_phase_teardown,
    phase_teardown_plan,
    teardown_completed_phase,
)
from lockstep.project_cursor import PhaseGateStatus
from lockstep.project_orchestrator import ProjectRunDisposition, step_project_run

_P1 = PhaseId.model_validate("01")
_P2 = PhaseId.model_validate("02")
_SRC = Path(teardown.__file__).parent


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _two_commands(marker: Path) -> tuple[tuple[str, ...], ...]:
    return (passing_command(marker, "first"), passing_command(marker, "second"))


def _cycle(project: GateProject) -> Any:
    return run_phase_gate_cycle(
        project.runtime,
        max_gate_remediations=1,
        request_factory=project.factory,
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
    )


def _ready(project: GateProject) -> GateProject:
    assert project.run_phase(jit=False).disposition is ProjectRunDisposition.PHASE_GATE_READY
    return project


def _step(project: GateProject) -> Any:
    return step_project_run(
        project.runtime,
        request_factory=project.factory,
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
        jit_replan=False,
    )


def _project(
    tmp_path: Path, first: tuple[str, ...], second: tuple[str, ...] = ("11",)
) -> GateProject:
    tmp_path.mkdir(parents=True, exist_ok=True)
    tail: list[dict[str, object]] = []
    for sid in second:
        tail.extend(unit_script("02", sid))
    return standard_project(
        tmp_path,
        phases={"01": first, "02": second},
        gate_commands=_two_commands,
        planner_tail=tail,
        extra_units=[("02", sid) for sid in second],
    )


def _phase_one_complete(tmp_path: Path, first: tuple[str, ...] = ("01", "02", "03")) -> GateProject:
    """Phase 01 gated, finalized and recorded complete; its residue is still on disk."""
    project = _ready(_project(tmp_path, first))
    assert _cycle(project).disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    assert project.cursor().completed_phases == (_P1,)
    return project


def _run(phase: str, sid: str) -> RunId:
    return RunId.model_validate(f"run-{phase}-{sid}")


def _run_cache(project: GateProject, phase: str, sid: str) -> Path:
    return project.runtime_dir / "worktrees" / f".lockstep-pycache-run-{phase}-{sid}"


def _gate_cache(project: GateProject, phase: str, attempt: int = 1) -> Path:
    return project.runtime_dir / ".lockstep-gate-pycache" / f"{phase}-attempt-{attempt}"


def _tree(root: Path, *, skip: tuple[str, ...] = ()) -> dict[str, bytes]:
    """Every regular file beneath *root* (symlinks not followed), minus top-level *skip*."""
    found: dict[str, bytes] = {}
    for dirpath, dirnames, filenames in os.walk(root):
        rel = Path(dirpath).relative_to(root)
        if rel.parts and rel.parts[0] in skip:
            dirnames[:] = []
            continue
        for name in filenames:
            path = Path(dirpath) / name
            if not path.is_symlink():
                found[str(rel / name)] = path.read_bytes()
    return found


def _durable(project: GateProject) -> dict[str, bytes]:
    """The whole runtime tree outside the two residue roots, plus the project root."""
    runtime = _tree(project.runtime_dir, skip=("worktrees", ".lockstep-gate-pycache"))
    project_files = {f"<project>/{k}": v for k, v in _tree(project.project_root).items()}
    return {**runtime, **project_files}


def _refs(project: GateProject) -> str:
    return run_git_text(project.source, "for-each-ref", "--format=%(refname) %(objectname)")


def _registered(project: GateProject) -> list[Path]:
    text = run_git_text(project.source, "worktree", "list", "--porcelain")
    return [
        Path(line.split(" ", 1)[1]) for line in text.splitlines() if line.startswith("worktree ")
    ]


def _worktree_names(project: GateProject) -> list[str]:
    directory = project.runtime_dir / "worktrees"
    return sorted(p.name for p in directory.iterdir()) if directory.exists() else []


def _snapshot(project: GateProject) -> SimpleNamespace:
    return SimpleNamespace(
        durable=_durable(project),
        refs=_refs(project),
        registered=_registered(project),
        worktrees=_worktree_names(project),
        gate_caches=sorted(
            p.name for p in (project.runtime_dir / ".lockstep-gate-pycache").iterdir()
        )
        if (project.runtime_dir / ".lockstep-gate-pycache").exists()
        else [],
        counts=project.counts(),
    )


def _everything(project: GateProject) -> dict[str, bytes]:
    return _tree(project.runtime_dir)


def _metrics(project: GateProject, phase: str, sid: str) -> Any:
    return project_runtime_metrics(project.txn_dir(phase, sid), repository_change=None)


def _tests_frozen(project: GateProject, phase: str, sid: str) -> str:
    events = read_events(project.txn_dir(phase, sid) / "events.jsonl")
    frozen = [
        e.detail
        for e in events
        if isinstance(e, ExecutionEvent) and e.kind is ExecutionEventKind.TESTS_FROZEN
    ]
    assert frozen and frozen[-1] is not None
    return frozen[-1]


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


# ===========================================================================
# Public shape and boundaries
# ===========================================================================


def test_public_api_exports_expected_names() -> None:
    assert set(teardown.__all__) == {
        "PhaseTeardownError",
        "PhaseTeardownPlan",
        "PhaseTeardownResult",
        "WorktreeTarget",
        "ensure_completed_phase_teardown",
        "phase_teardown_plan",
        "teardown_completed_phase",
    }


def test_the_teardown_module_invokes_no_provider() -> None:  # Test T
    imports = _imports(teardown)
    for module in imports:
        assert not module.startswith(
            (
                "lockstep.agents",
                "lockstep.agent_turn",
                "lockstep.planning_transport",
                "lockstep.planning_workflow",
                "lockstep.implementer_turn",
                "lockstep.reviewer_turn",
                "lockstep.escalation_transport",
                "lockstep.supervisor",
                "lockstep.process",
            )
        ), module
    names = set().union(*imports.values())
    assert not any(name.startswith(("invoke", "run_phase_gate", "run_project")) for name in names)


def test_teardown_never_forces_git_and_never_touches_a_branch() -> None:
    for path in (_SRC / "phase_teardown.py", _SRC / "git" / "worktree.py"):
        source = path.read_text(encoding="utf-8")
        for forbidden in ('"--force"', '"-f"', "branch -D", '"-D"', "update-ref", '"prune"'):
            assert forbidden not in source, (path.name, forbidden)


def test_teardown_writes_nothing_and_never_sweeps_by_age_or_scan() -> None:
    source = (_SRC / "phase_teardown.py").read_text(encoding="utf-8")
    for forbidden in (
        "write_bytes",
        "write_text",
        "open(",
        "iterdir",
        "glob(",
        "os.walk",
        "listdir",
        "scandir",
        "mtime",
        "import time",
        "datetime",
    ):
        assert forbidden not in source, forbidden


def test_teardown_is_not_part_of_the_gate_or_the_subphase_runner() -> None:
    for name in ("phase_gate.py", "phase_gate_cycle.py", "project_orchestrator.py"):
        source = (_SRC / name).read_text(encoding="utf-8")
        assert "phase_teardown" not in source, name


def test_the_autonomous_run_is_the_teardown_hook() -> None:
    assert autonomous_run.ensure_completed_phase_teardown is ensure_completed_phase_teardown


def test_no_new_control_plane_state_or_event_is_introduced() -> None:
    assert {s.value for s in PhaseGateStatus} == {"subphases_pending", "ready", "project_complete"}
    assert "teardown" not in " ".join(k.value for k in PhaseGateEventKind)
    assert "teardown" not in " ".join(d.value for d in AutonomousRunDisposition)


# ===========================================================================
# Tests A, B, N: no verified finalization and cursor completion, no teardown
# ===========================================================================


def _garbage(path: Path) -> None:
    path.write_bytes(path.read_bytes() + b" ")


def test_a_tampered_finalization_refuses_teardown_and_removes_nothing(tmp_path: Path) -> None:
    project = _phase_one_complete(tmp_path)
    _garbage(project.runtime_dir / "project" / "phase-context" / "01.json")
    before, everything = _snapshot(project), _everything(project)

    with pytest.raises(PhaseTeardownError, match="does not verify"):
        teardown_completed_phase(project.runtime, _P1)
    for call in (
        lambda: teardown_completed_phase(project.runtime, _P1),
        lambda: phase_teardown_plan(project.runtime, _P1),
        lambda: ensure_completed_phase_teardown(project.runtime),
    ):
        with pytest.raises(PhaseTeardownError):
            call()
        assert _everything(project) == everything
        assert _snapshot(project) == before


def test_crash_window_b_is_not_teardown_eligible(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _ready(_project(tmp_path, ("01", "02", "03")))
    crash_once(monkeypatch, phase_gate_cycle, "record_phase_completion")
    with pytest.raises(CrashError):
        _cycle(project)
    assert (project.runtime_dir / "project" / "phase-context" / "01.json").is_file()
    assert project.cursor().completed_phases == ()
    before, everything = _snapshot(project), _everything(project)

    with pytest.raises(PhaseTeardownError, match="not recorded complete"):
        teardown_completed_phase(project.runtime, _P1)
    assert ensure_completed_phase_teardown(project.runtime) == ()

    assert _everything(project) == everything
    assert _snapshot(project) == before
    assert _worktree_names(project) == [
        ".lockstep-pycache-run-01-01",
        ".lockstep-pycache-run-01-02",
        ".lockstep-pycache-run-01-03",
        "run-01-01",
        "run-01-02",
        "run-01-03",
    ]


def test_a_legacy_completed_phase_without_finalization_is_never_torn_down(
    tmp_path: Path,
) -> None:
    project = _phase_one_complete(tmp_path)
    (project.runtime_dir / "project" / "phase-context" / "01.json").unlink()  # pre-12.8
    before, everything = _snapshot(project), _everything(project)

    with pytest.raises(PhaseTeardownError, match="no phase finalization"):
        teardown_completed_phase(project.runtime, _P1)
    assert ensure_completed_phase_teardown(project.runtime) == ()

    assert _everything(project) == everything
    assert _snapshot(project) == before
    assert not (project.runtime_dir / "project" / "phase-context" / "01.json").exists()


def test_the_current_phase_is_never_teardown_eligible(tmp_path: Path) -> None:
    project = _ready(_project(tmp_path, ("01", "02")))
    everything = _everything(project)

    with pytest.raises(PhaseTeardownError, match="not recorded complete"):
        teardown_completed_phase(project.runtime, _P1)
    assert _everything(project) == everything


# ===========================================================================
# Tests C, D, E, G, H, I, K, M, P, Q, R, S, T: one project through every boundary
# ===========================================================================


@pytest.fixture(scope="module")
def lifecycle(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    project = _phase_one_complete(tmp_path_factory.mktemp("lifecycle"))
    accepted = {
        sid: git_head(project.worktree("01", sid), project.branch("01", sid))
        for sid in ("01", "02", "03")
    }
    frozen = {sid: _tests_frozen(project, "01", sid) for sid in ("01", "02", "03")}
    changes = {
        sid: measure_repository_change(project.worktree("01", sid), frozen[sid], accepted[sid])
        for sid in ("01", "02", "03")
    }
    metrics = {sid: _metrics(project, "01", sid) for sid in ("01", "02", "03")}
    s0 = _snapshot(project)
    p1_bytes = (project.runtime_dir / "project" / "phase-context" / "01.json").read_bytes()

    first = teardown_completed_phase(project.runtime, _P1)
    s1 = _snapshot(project)

    _ready(project)  # Phase 02 executes its Sub-phase on the accepted Phase-01 branch
    s2_before = _snapshot(project)
    second = ensure_completed_phase_teardown(project.runtime)
    s2 = _snapshot(project)
    again = ensure_completed_phase_teardown(project.runtime)
    s3 = _snapshot(project)

    observed: dict[str, object] = {}
    original = phase_gate_cycle.finalize_phase_context

    def watch(*args: Any, **kwargs: Any) -> Any:
        observed["p1_worktrees_at_p2_finalization"] = [
            name for name in _worktree_names(project) if name.startswith("run-01")
        ]
        return original(*args, **kwargs)

    with pytest.MonkeyPatch.context() as patch:
        patch.setattr(phase_gate_cycle, "finalize_phase_context", watch)
        p2 = _cycle(project)
    s4_before = _snapshot(project)
    final = ensure_completed_phase_teardown(project.runtime)
    s4 = _snapshot(project)
    return SimpleNamespace(
        project=project,
        accepted=accepted,
        frozen=frozen,
        changes=changes,
        metrics=metrics,
        p1_bytes=p1_bytes,
        s0=s0,
        first=first,
        s1=s1,
        s2_before=s2_before,
        second=second,
        s2=s2,
        again=again,
        s3=s3,
        p2=p2,
        observed=observed,
        s4_before=s4_before,
        final=final,
        s4=s4,
    )


def test_completed_phase_residue_is_present_before_teardown(lifecycle: SimpleNamespace) -> None:
    assert lifecycle.s0.worktrees == [
        ".lockstep-pycache-run-01-01",
        ".lockstep-pycache-run-01-02",
        ".lockstep-pycache-run-01-03",
        "run-01-01",
        "run-01-02",
        "run-01-03",
    ]
    assert lifecycle.s0.gate_caches == ["01-attempt-1"]


def test_an_eligible_completed_phase_loses_its_transient_residue(  # Test C
    lifecycle: SimpleNamespace,
) -> None:
    assert lifecycle.first == PhaseTeardownResult(
        phase_id=_P1,
        removed_worktrees=(_run("01", "01"), _run("01", "02")),
        removed_caches=(
            _run_cache(lifecycle.project, "01", "01"),
            _run_cache(lifecycle.project, "01", "02"),
            _run_cache(lifecycle.project, "01", "03"),
            _gate_cache(lifecycle.project, "01"),
        ),
        retained_basis=_run("01", "03"),
    )
    # The live accepted basis (the latest accepted Sub-phase) is never torn down.
    assert lifecycle.s1.worktrees == ["run-01-03"]
    assert lifecycle.s1.gate_caches == []


def test_retained_durable_evidence_is_byte_identical(lifecycle: SimpleNamespace) -> None:  # G
    assert lifecycle.s1.durable == lifecycle.s0.durable
    assert lifecycle.s1.refs == lifecycle.s0.refs
    assert lifecycle.s3.durable == lifecycle.s2.durable == lifecycle.s2_before.durable
    assert lifecycle.s4.durable == lifecycle.s4_before.durable
    durable = lifecycle.s4.durable
    for name in (
        "project/cursor.json",
        "project/phase-context/01.json",
        "project/phase-context/02.json",
        "phase-gates/01/events.jsonl",
        "phase-gates/01/attempt-1/decision.json",
        "phase-gates/01/attempt-1/basis.json",
        "phase-gates/01/attempt-1/evidence.json",
        "transactions/run-01-01/events.jsonl",
        "transactions/run-01-01/state.json",
        "transactions/run-01-01/artifacts/attempt-1/verification-evidence.json",
        "planning/phase-plan.json",
    ):
        assert name in durable, name
    assert len([k for k in durable if k.startswith("contracts/history/")]) == 4
    assert durable["project/phase-context/01.json"] == lifecycle.p1_bytes


def test_phase_gate_evidence_is_retained(lifecycle: SimpleNamespace) -> None:  # Test I
    for phase in ("01", "02"):
        attempt = lifecycle.project.attempt_dir(phase, 1)
        assert sorted(p.name for p in attempt.iterdir()) == [
            "basis.json",
            "decision.json",
            "evidence.json",
        ]
        assert (lifecycle.project.gate_dir(phase) / "events.jsonl").is_file()


def test_git_registration_is_clean_and_history_is_retained(  # Test E
    lifecycle: SimpleNamespace,
) -> None:
    project = lifecycle.project
    registered = lifecycle.s1.registered
    assert project.worktree("01", "01").resolve() not in registered
    assert project.worktree("01", "02").resolve() not in registered
    assert project.worktree("01", "03").resolve() in registered
    for sid, commit in lifecycle.accepted.items():
        assert git_head(project.source, project.branch("01", sid)) == commit
    basis = load_phase_gate_decision(project.runtime_dir, _P1, 1)
    assert basis is not None
    run_git_text(project.source, "cat-file", "-e", f"{basis.basis_commit}^{{commit}}")
    run_git_text(
        project.source,
        "merge-base",
        "--is-ancestor",
        basis.basis_commit,
        project.branch("02", "11"),
    )


def test_the_previous_tip_goes_once_the_next_phase_accepts_work(  # Test D
    lifecycle: SimpleNamespace,
) -> None:
    project = lifecycle.project
    assert lifecycle.s2_before.worktrees == [
        ".lockstep-pycache-run-02-11",
        "run-01-03",
        "run-02-11",
    ]
    [result] = lifecycle.second
    assert result.removed_worktrees == (_run("01", "03"),)
    assert result.retained_basis is None
    # Only finalization-listed Phase-01 residue went; the current Phase's worktree remains.
    assert lifecycle.s2.worktrees == [".lockstep-pycache-run-02-11", "run-02-11"]
    assert project.worktree("01", "03").resolve() not in lifecycle.s2.registered
    assert project.worktree("02", "11").resolve() in lifecycle.s2.registered


def test_teardown_is_idempotent(lifecycle: SimpleNamespace) -> None:  # Test K
    [result] = lifecycle.again
    assert result == PhaseTeardownResult(
        phase_id=_P1, removed_worktrees=(), removed_caches=(), retained_basis=None
    )
    assert lifecycle.s3 == lifecycle.s2


def test_historical_finalization_verifies_after_teardown(  # Test H
    lifecycle: SimpleNamespace,
) -> None:
    project = lifecycle.project
    decision = load_phase_gate_decision(project.runtime_dir, _P1, 1)
    assert decision is not None
    p1 = load_phase_context_finalization(project.runtime_dir, _P1)
    assert p1 is not None
    assert finalize_phase_context(project.runtime, decision) == p1
    # Phase 02 crossed its boundary, verifying Phase 01, with no Phase-01 worktree on disk.
    assert lifecycle.p2.disposition is PhaseGateCycleDisposition.PROJECT_COMPLETE
    assert lifecycle.observed["p1_worktrees_at_p2_finalization"] == []
    p2 = load_phase_context_finalization(project.runtime_dir, _P2)
    assert p2 is not None and p2.previous_phase_finalization is not None
    assert p2.previous_phase_finalization.identity == phase_context_finalization_identity(p1)


def test_a_complete_project_keeps_only_its_final_accepted_checkout(  # Test M
    lifecycle: SimpleNamespace,
) -> None:
    project = lifecycle.project
    assert project.cursor().phase_gate_status is PhaseGateStatus.PROJECT_COMPLETE
    assert [r.phase_id for r in lifecycle.final] == [_P1, _P2]
    assert lifecycle.final[1].retained_basis == _run("02", "11")
    assert lifecycle.final[1].removed_caches == (
        _run_cache(project, "02", "11"),
        _gate_cache(project, "02"),
    )
    assert lifecycle.s4.worktrees == ["run-02-11"]
    assert lifecycle.s4.gate_caches == []
    assert lifecycle.s4.registered == [
        project.source.resolve(),
        project.worktree("02", "11").resolve(),
    ]
    for phase in (_P1, _P2):
        assert load_phase_context_finalization(project.runtime_dir, phase) is not None


def test_teardown_made_no_provider_call(lifecycle: SimpleNamespace) -> None:  # Test T
    assert lifecycle.s1.counts == lifecycle.s0.counts
    assert lifecycle.s2.counts == lifecycle.s2_before.counts
    assert lifecycle.s4.counts == lifecycle.s4_before.counts


def test_phase10_metrics_are_reconstructable_after_teardown(  # Test R
    lifecycle: SimpleNamespace,
) -> None:
    project = lifecycle.project
    for sid in ("01", "02", "03"):
        assert _metrics(project, "01", sid) == lifecycle.metrics[sid]
        # The repository change is rebuilt from the retained journal and accepted branch.
        rebuilt = measure_repository_change(
            project.source,
            _tests_frozen(project, "01", sid),
            git_head(project.source, project.branch("01", sid)),
        )
        assert rebuilt == lifecycle.changes[sid]


def test_phase13_inputs_remain_available(lifecycle: SimpleNamespace) -> None:  # Test S
    project = lifecycle.project
    durable = lifecycle.s4.durable
    p1 = load_phase_context_finalization(project.runtime_dir, _P1)
    assert p1 is not None
    for entry in p1.completed_subphases:
        run = entry.run_id.root
        sid = entry.subphase_id.root
        # Contract, implementation and verification evidence, review findings, telemetry.
        assert f"contracts/history/01-{sid}-{entry.contract_digest}.json" in durable
        for artifact in ("implementation-report.json", "verification-evidence.json"):
            assert f"transactions/{run}/artifacts/attempt-1/{artifact}" in durable
        events = read_events(project.runtime_dir / "transactions" / run / "events.jsonl")
        kinds = {e.kind for e in events if isinstance(e, ExecutionEvent)}
        assert ExecutionEventKind.REVIEW_DECIDED in kinds or any(
            e.verdict is not None for e in events if isinstance(e, ExecutionEvent)
        )
        assert any(
            e.usage is not None for e in events if isinstance(e, ExecutionEvent)
        )  # telemetry
        # Git history and diffs from the retained accepted branch.
        assert run_git_text(
            project.source, "diff", "--stat", lifecycle.frozen[sid], entry.accepted_commit
        )
    # Relevant context references.
    assert "context_selection" in json.loads(lifecycle.p1_bytes)
    assert "project_digest" in json.loads(lifecycle.p1_bytes)
    assert any(k.startswith("project-runs/") or k.startswith("planning/") for k in durable)


def test_no_provider_session_state_is_persisted(lifecycle: SimpleNamespace) -> None:  # Test P
    project = lifecycle.project
    for path in _everything(project):
        lowered = path.lower()
        assert "session" not in lowered and "conversation" not in lowered, path
    # The only trace is the provider-reported identifier inside immutable usage telemetry.
    events = read_events(project.txn_dir("01", "01") / "events.jsonl")
    reported = [e.usage.reported for e in events if isinstance(e, ExecutionEvent) and e.usage]
    assert reported and all(hasattr(r, "provider_session_id") for r in reported)


def test_provider_sessions_are_ephemeral_and_never_resumed() -> None:  # Test P
    claude = (_SRC / "agents" / "claude.py").read_text(encoding="utf-8")
    codex = (_SRC / "agents" / "codex.py").read_text(encoding="utf-8")
    assert '"--no-session-persistence"' in claude
    assert '"--ephemeral"' in codex
    readers: set[str] = set()
    for path in _SRC.rglob("*.py"):
        source = path.read_text(encoding="utf-8")
        for flag in ('"--resume"', '"--continue"', '"resume"', "--session-id"):
            assert flag not in source, (path.name, flag)
        if "provider_session_id" in source:
            readers.add(str(path.relative_to(_SRC)))
    # Captured as telemetry by the adapters and modeled once; never read back to continue.
    assert readers == {"agents/claude.py", "agents/codex.py", "domain/usage.py"}


def test_no_rendered_prompt_or_context_pack_is_persisted(  # Test Q
    lifecycle: SimpleNamespace,
) -> None:
    project = lifecycle.project
    header = CONTEXT_PACK_HEADER.strip().encode("utf-8")
    for root in (project.runtime_dir, project.project_root):
        for name, data in _tree(root).items():
            assert header not in data, name
    runner = (_SRC / "process" / "runner.py").read_text(encoding="utf-8")
    assert "NamedTemporaryFile" not in runner and "mkstemp" not in runner


# ===========================================================================
# Test F: an unexpectedly dirty or moved completed worktree fails closed
# ===========================================================================


def _tracked(worktree: Path) -> None:
    (worktree / "feature_01.py").write_text("# changed after acceptance\n", encoding="utf-8")


def _staged(worktree: Path) -> None:
    _tracked(worktree)
    run_git_text(worktree, "add", "feature_01.py")


def _untracked(worktree: Path) -> None:
    (worktree / "notes.txt").write_text("unique data\n", encoding="utf-8")


def _moved(worktree: Path) -> None:
    run_git_text(
        worktree,
        "-c",
        "user.name=t",
        "-c",
        "user.email=t@example.com",
        "commit",
        "--allow-empty",
        "-m",
        "after acceptance",
    )


@pytest.mark.parametrize(
    ("dirty", "reason"),
    [
        (_tracked, "uncommitted or untracked"),
        (_staged, "uncommitted or untracked"),
        (_untracked, "uncommitted or untracked"),
        (_moved, "not at its accepted commit"),
    ],
    ids=["tracked", "staged", "untracked", "moved"],
)
def test_a_dirty_completed_worktree_refuses_destructive_cleanup(
    tmp_path: Path, dirty: Any, reason: str
) -> None:
    project = _phase_one_complete(tmp_path)
    dirty(project.worktree("01", "02"))
    before, everything = _snapshot(project), _everything(project)

    with pytest.raises(PhaseTeardownError, match=reason):
        teardown_completed_phase(project.runtime, _P1)

    # Nothing at all was removed -- not even the clean worktree or a cache.
    assert _everything(project) == everything
    assert _snapshot(project) == before


# ===========================================================================
# Test J: a crash mid-teardown resumes deterministically
# ===========================================================================


def test_a_crash_after_one_removal_resumes_and_finishes_once(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _phase_one_complete(tmp_path)
    durable, refs, counts = _durable(project), _refs(project), project.counts()
    crash_after_once(monkeypatch, teardown, "remove_linked_worktree")

    with pytest.raises(CrashError):
        teardown_completed_phase(project.runtime, _P1)
    assert not project.worktree("01", "01").exists()
    assert project.worktree("01", "02").is_dir()

    monkeypatch.undo()
    calls = record_calls(monkeypatch, teardown, "remove_linked_worktree")
    result = teardown_completed_phase(project.runtime, _P1)

    assert result.removed_worktrees == (_run("01", "02"),)
    assert [Path(c["args"][1]) for c in calls] == [project.worktree("01", "02").resolve()]
    assert _worktree_names(project) == ["run-01-03"]
    assert _durable(project) == durable
    assert _refs(project) == refs
    assert project.counts() == counts


def test_a_crash_before_the_first_removal_resumes(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _phase_one_complete(tmp_path)
    everything = _everything(project)
    crash_once(monkeypatch, teardown, "remove_linked_worktree")

    with pytest.raises(CrashError):
        teardown_completed_phase(project.runtime, _P1)
    assert _everything(project) == everything

    teardown_completed_phase(project.runtime, _P1)
    assert _worktree_names(project) == ["run-01-03"]


def test_a_registration_left_behind_its_deleted_directory_is_unregistered(
    tmp_path: Path,
) -> None:
    project = _phase_one_complete(tmp_path)
    # A crash inside Git's own removal: the directory is gone, its registration is not.
    shutil.rmtree(project.worktree("01", "01"))
    assert project.worktree("01", "01").resolve() in _registered(project)
    refs = _refs(project)

    result = teardown_completed_phase(project.runtime, _P1)

    assert result.removed_worktrees == (_run("01", "02"),)
    assert _registered(project) == [
        project.source.resolve(),
        project.worktree("01", "03").resolve(),
    ]
    assert _refs(project) == refs


# ===========================================================================
# Test L: the current Phase is never touched
# ===========================================================================


def test_tearing_down_a_completed_phase_leaves_the_active_phase_untouched(
    tmp_path: Path,
) -> None:
    project = _ready(_project(tmp_path, ("01", "02"), ("11", "12")))
    assert _cycle(project).disposition is PhaseGateCycleDisposition.PHASE_COMPLETE
    for _ in range(3):  # bind 11, run and record 11, bind 12
        assert _step(project) is None
    cursor = project.cursor()
    assert cursor.active_contract is not None and cursor.current_subphase is not None
    assert cursor.current_subphase.root == "12"

    def phase_two() -> dict[str, object]:
        return {
            "cursor": (project.runtime_dir / "project" / "cursor.json").read_bytes(),
            "outline": (project.runtime_dir / "planning" / "phase-plan.json").read_bytes(),
            "contracts": _tree(project.runtime_dir / "contracts"),
            "transaction": _tree(project.txn_dir("02", "11")),
            "worktree": _tree(project.worktree("02", "11"), skip=(".git",)),
            "head": git_head(project.worktree("02", "11")),
            "registered": project.worktree("02", "11").resolve() in _registered(project),
        }

    before = phase_two()

    result = teardown_completed_phase(project.runtime, _P1)

    assert result.removed_worktrees == (_run("01", "01"), _run("01", "02"))
    assert phase_two() == before
    assert _worktree_names(project) == [".lockstep-pycache-run-02-11", "run-02-11"]


# ===========================================================================
# Test O: no target may escape through a symlink
# ===========================================================================


def test_a_symlinked_worktree_target_fails_closed(tmp_path: Path) -> None:
    project = _phase_one_complete(tmp_path / "p")
    outside = tmp_path / "outside"
    shutil.move(str(project.worktree("01", "01")), str(outside))
    project.worktree("01", "01").symlink_to(outside, target_is_directory=True)
    outside_tree, everything = _tree(outside), _everything(project)

    with pytest.raises(PhaseTeardownError, match="symlink"):
        teardown_completed_phase(project.runtime, _P1)

    assert _tree(outside) == outside_tree
    assert _everything(project) == everything
    assert project.worktree("01", "02").is_dir()


def test_a_symlinked_cache_target_fails_closed(tmp_path: Path) -> None:
    project = _phase_one_complete(tmp_path / "p")
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "precious.txt").write_text("not Lockstep's\n", encoding="utf-8")
    cache = _gate_cache(project, "01")
    shutil.rmtree(cache)
    cache.symlink_to(outside, target_is_directory=True)
    everything = _everything(project)

    with pytest.raises(PhaseTeardownError, match="symlink"):
        teardown_completed_phase(project.runtime, _P1)

    assert (outside / "precious.txt").read_text(encoding="utf-8") == "not Lockstep's\n"
    assert _everything(project) == everything
    assert project.worktree("01", "01").is_dir()


def test_a_symlinked_worktrees_root_fails_closed(tmp_path: Path) -> None:
    project = _phase_one_complete(tmp_path / "p")
    outside = tmp_path / "outside"
    shutil.move(str(project.runtime_dir / "worktrees"), str(outside))
    (project.runtime_dir / "worktrees").symlink_to(outside, target_is_directory=True)
    outside_names = sorted(p.name for p in outside.iterdir())

    with pytest.raises(PhaseTeardownError, match="parent directory"):
        teardown_completed_phase(project.runtime, _P1)

    assert sorted(p.name for p in outside.iterdir()) == outside_names


# ===========================================================================
# Orchestration: the autonomous run never starts next-Phase work before teardown
# ===========================================================================


def _autonomous(tmp_path: Path) -> GateProject:
    return autonomous_project(tmp_path)


def _clock() -> Any:
    return FakeClock()


def test_the_autonomous_run_tears_down_before_next_phase_work(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _autonomous(tmp_path)
    order: list[tuple[str, object]] = []
    original_ensure = autonomous_run.ensure_completed_phase_teardown
    original_step = autonomous_run.step_project_run
    original_record = phase_gate_cycle.record_phase_completion

    def ensure(runtime: Any) -> Any:
        results = original_ensure(runtime)
        order.append(("teardown", tuple(r.phase_id.root for r in results if r.removed_worktrees)))
        return results

    def step(runtime: Any, **kwargs: Any) -> Any:
        cursor = project.cursor()
        order.append(("step", cursor.current_phase.root if cursor.current_phase else None))
        if cursor.current_phase == _P2:
            assert not project.worktree("01", "01").exists()
        return original_step(runtime, **kwargs)

    def record(*args: Any, **kwargs: Any) -> Any:
        order.append(("complete", kwargs["phase_id"].root))
        return original_record(*args, **kwargs)

    monkeypatch.setattr(autonomous_run, "ensure_completed_phase_teardown", ensure)
    monkeypatch.setattr(autonomous_run, "step_project_run", step)
    monkeypatch.setattr(phase_gate_cycle, "record_phase_completion", record)

    result = run_autonomous(project, make_policy(), clock=_clock())

    assert result.disposition is AutonomousRunDisposition.PROJECT_COMPLETE
    complete = order.index(("complete", "01"))
    assert order[complete + 1] == ("teardown", ("01",))
    assert ("step", "02") in order[complete + 1 :]
    assert _worktree_names(project) == ["run-02-11"]
    assert not (project.runtime_dir / ".lockstep-gate-pycache" / "01-attempt-1").exists()


def test_a_crash_after_completion_finishes_teardown_on_resume_before_any_work(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _autonomous(tmp_path)
    crash_after_once(monkeypatch, phase_gate_cycle, "record_phase_completion")
    with pytest.raises(CrashError):
        run_autonomous(project, make_policy(), clock=_clock())
    monkeypatch.undo()
    assert project.cursor().completed_phases == (_P1,)
    assert project.worktree("01", "01").is_dir()  # Phase complete, teardown pending
    counts, gates = project.counts(), project.markers()

    first_launch: dict[str, bool] = {}
    original = autonomous_run.step_project_run

    def step(runtime: Any, **kwargs: Any) -> Any:
        first_launch.setdefault("p1_residue", project.worktree("01", "01").exists())
        return original(runtime, **kwargs)

    monkeypatch.setattr(autonomous_run, "step_project_run", step)
    result = run_autonomous(project, make_policy(), clock=_clock())

    assert result.disposition is AutonomousRunDisposition.PROJECT_COMPLETE
    assert first_launch == {"p1_residue": False}
    assert project.markers()[: len(gates)] == gates  # no gate rerun
    assert project.counts()[0] >= counts[0]
    assert _worktree_names(project) == ["run-02-11"]


def test_a_pending_teardown_refusal_blocks_the_next_phase(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _autonomous(tmp_path)
    crash_after_once(monkeypatch, phase_gate_cycle, "record_phase_completion")
    with pytest.raises(CrashError):
        run_autonomous(project, make_policy(), clock=_clock())
    monkeypatch.undo()
    (project.worktree("01", "01") / "notes.txt").write_text("unique\n", encoding="utf-8")
    cursor, counts = project.cursor(), project.counts()
    residue = {
        name: _tree(project.runtime_dir / name) for name in ("worktrees", ".lockstep-gate-pycache")
    }
    transactions = sorted(p.name for p in (project.runtime_dir / "transactions").iterdir())

    with pytest.raises(PhaseTeardownError):
        run_autonomous(project, make_policy(), clock=_clock())

    # The Phase stays complete, nothing ran, nothing was deleted; the stop is durable.
    assert project.cursor() == cursor
    assert project.counts() == counts
    assert {
        name: _tree(project.runtime_dir / name) for name in ("worktrees", ".lockstep-gate-pycache")
    } == residue
    assert sorted(p.name for p in (project.runtime_dir / "transactions").iterdir()) == transactions
    stops = [
        json.loads(path.read_text(encoding="utf-8"))["stop"]
        for path in sorted((project.runtime_dir / "project-runs").glob("*/state.json"))
    ]
    assert stops[-1]["disposition"] == AutonomousRunDisposition.TERMINAL_HALT.value
    assert stops[-1]["detail"] == "PhaseTeardownError"

    (project.worktree("01", "01") / "notes.txt").unlink()
    result = run_autonomous(project, make_policy(), clock=_clock())
    assert result.disposition is AutonomousRunDisposition.PROJECT_COMPLETE
    assert _worktree_names(project) == ["run-02-11"]


def test_a_stopped_teardown_never_rolls_the_cursor_back(tmp_path: Path) -> None:
    project = _phase_one_complete(tmp_path, ("01", "02"))
    _untracked(project.worktree("01", "01"))
    cursor = project.cursor()

    with pytest.raises(PhaseTeardownError):
        ensure_completed_phase_teardown(project.runtime)

    assert project.cursor() == cursor
    assert project.cursor().completed_phases == (_P1,)
