"""Phase 12.3: stable-prefix layout of the real provider-facing input.

Runs the canonical production path (no injected ``request_factory`` beyond an explicit
document selection) against recording fake providers and reads back exactly what each
provider received on stdin. For every canonical role the provider input is laid out

    role instructions + stable region | volatile region + (resume tail) + turn protocol

and the bytes before the boundary are identical across Sub-phases, retries and
Reviewer invocations while the stable sources are unchanged. The expected stable
prefixes are rebuilt from durable state through the structural layout API, not
scraped from the recorded text.

Baseline classification: every test in this module is RED at entry (78c04f9 has no
``compose_context_prompt`` / ``STABLE_CONTEXT_HEADER``).
"""

from __future__ import annotations

from pathlib import Path

import pytest
from test_canonical_project_run import (
    _EXPANSION_FINDING,
    _Canon,
    _implementation,
    _make_canonical,
    _review,
)
from test_context_pack_integration import _manifest, _with_digest
from test_supervisor_resume_execution import _budget, _git

from lockstep.agent_turn import _BLOCKER_PROTOCOL_SUFFIX
from lockstep.context.context_pack import (
    CONTEXT_PACK_HEADER,
    STABLE_CONTEXT_HEADER,
    ContextLayout,
    ContextSourceKind,
    compose_context_prompt,
)
from lockstep.context.context_pack_builder import (
    ContextSelection,
    ContextSources,
    SelectedContextDocument,
    build_implementer_context_pack,
    build_reviewer_context_pack,
    build_test_authoring_context_pack,
)
from lockstep.contract_history import load_archived_subphase_contract
from lockstep.domain import AttemptNumber, ProjectId, SubphaseContract
from lockstep.handoff import (
    build_implementer_handoff,
    build_planner_test_handoff,
    build_reviewer_handoff,
)
from lockstep.implementer_turn import _IMPLEMENTER_TURN_PROTOCOL_SUFFIX
from lockstep.jit_replan import _REPLAN_INSTRUCTIONS
from lockstep.planning_store import load_frozen_master_plan
from lockstep.project_cursor import master_plan_digest
from lockstep.project_cursor_store import load_project_cursor
from lockstep.project_orchestrator import ProjectRunDisposition, run_project_phase
from lockstep.reviewer_turn import _REVIEWER_TURN_PROTOCOL_SUFFIX
from lockstep.transaction_factory import (
    _IMPLEMENTER_INSTRUCTIONS,
    _PLANNER_INSTRUCTIONS,
    _REVIEWER_INSTRUCTIONS,
    canonical_transaction_request_factory,
)

_SIDS = ("01", "02", "03")
_ARCHITECTURE_TEXT = "The supervisor composes kernels; adapters stay provider-specific."
_ATTEMPT_1 = AttemptNumber.model_validate(1)


def _selection() -> ContextSelection:
    return ContextSelection(
        documents=(
            SelectedContextDocument(
                path="docs/architecture.md",
                kind=ContextSourceKind.PROJECT_DOCUMENTATION,
                operations=("test_authoring", "implementation", "rework", "review"),  # type: ignore[arg-type]
            ),
        )
    )


def _prepare(project: _Canon) -> str:
    (project.source / "docs").mkdir()
    (project.source / "docs" / "architecture.md").write_text(_ARCHITECTURE_TEXT, encoding="utf-8")
    _git(project.source, "add", "-A")
    _git(project.source, "commit", "-m", "docs")
    return _with_digest(project)


def _run(project: _Canon) -> None:
    factory = canonical_transaction_request_factory(project.runtime, context_selection=_selection())
    result = run_project_phase(
        project.runtime,
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
        request_factory=factory,
    )
    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY


def _sources(project: _Canon) -> ContextSources:
    return ContextSources(
        project_id=ProjectId.model_validate("lockstep"),
        project_root=project.project_root,
        runtime_dir=project.runtime_dir,
        selection=_selection(),
    )


def _archived(project: _Canon, sid: str) -> SubphaseContract:
    cursor = load_project_cursor(project.project_root, project.runtime_dir)
    assert cursor is not None
    [entry] = [e for e in cursor.completed_subphases if e.subphase_id.root == sid]
    contract = load_archived_subphase_contract(
        project.project_root,
        project.runtime_dir,
        phase_id=entry.phase_id,
        subphase_id=entry.subphase_id,
        contract_digest=entry.contract_digest,
    )
    assert contract is not None
    return contract


def _implementer_layout(project: _Canon, sid: str) -> ContextLayout:
    contract = _archived(project, sid)
    handoff = build_implementer_handoff(
        runtime_dir=project.txn_dir(sid),
        worktree_path=project.worktree(sid),
        run_id=project.run_id(sid),
        phase_id=contract.phase_id,
        subphase_id=contract.subphase_id,
        attempt=_ATTEMPT_1,
        contract=contract,
        test_paths=tuple(test.path for test in contract.tests),
    )
    pack = build_implementer_context_pack(_sources(project), handoff)
    return compose_context_prompt(_IMPLEMENTER_INSTRUCTIONS, pack)


def _reviewer_layout(project: _Canon, sid: str) -> ContextLayout:
    contract = _archived(project, sid)
    handoff = build_reviewer_handoff(
        runtime_dir=project.txn_dir(sid),
        worktree_path=project.worktree(sid),
        run_id=project.run_id(sid),
        phase_id=contract.phase_id,
        subphase_id=contract.subphase_id,
        attempt=_ATTEMPT_1,
        contract=contract,
        test_paths=tuple(test.path for test in contract.tests),
    )
    pack = build_reviewer_context_pack(_sources(project), handoff)
    return compose_context_prompt(_REVIEWER_INSTRUCTIONS, pack)


def _planner_layout(project: _Canon, sid: str) -> ContextLayout:
    contract = _archived(project, sid)
    handoff = build_planner_test_handoff(
        run_id=project.run_id(sid),
        phase_id=contract.phase_id,
        subphase_id=contract.subphase_id,
        contract=contract,
    )
    pack = build_test_authoring_context_pack(_sources(project), handoff)
    return compose_context_prompt(_PLANNER_INSTRUCTIONS, pack)


def _prompts(project: _Canon, role: str, operation: str) -> list[str]:
    prompts = [project.prompt(role, i) for i in range(project.launches(role))]
    return [
        p for p in prompts if CONTEXT_PACK_HEADER in p and _manifest(p)["operation"] == operation
    ]


@pytest.fixture(scope="module")
def three_subphases(tmp_path_factory: pytest.TempPathFactory) -> tuple[_Canon, str]:
    project = _make_canonical(tmp_path_factory.mktemp("layout-three"), sids=_SIDS)
    identity = _prepare(project)
    _run(project)
    return project, identity


# ===========================================================================
# Every canonical role: one stable prefix across Sub-phases (B, D, O, AC-12.3-03/04)
# ===========================================================================


def test_implementer_inputs_share_one_stable_prefix_across_subphases(
    three_subphases: tuple[_Canon, str],
) -> None:
    project, identity = three_subphases
    recorded = _prompts(project, "implementer", "implementation")
    layouts = [_implementer_layout(project, sid) for sid in _SIDS]
    assert len(recorded) == len(_SIDS)

    prefix = layouts[0].stable_prefix
    assert all(layout.stable_prefix == prefix for layout in layouts)
    assert len({layout.volatile_suffix for layout in layouts}) == len(_SIDS)
    for prompt, layout in zip(recorded, layouts, strict=True):
        # The provider input is exactly the reconstructed layout, then the turn protocol.
        assert prompt.startswith(layout.text)
        assert prompt[len(prefix) :].startswith(CONTEXT_PACK_HEADER)
    assert prefix.startswith(_IMPLEMENTER_INSTRUCTIONS + STABLE_CONTEXT_HEADER)
    assert identity in prefix and _ARCHITECTURE_TEXT in prefix
    for sid in _SIDS:
        assert project.run_id(sid).root not in prefix


def test_reviewer_inputs_share_one_stable_prefix_across_subphases(
    three_subphases: tuple[_Canon, str],
) -> None:
    project, identity = three_subphases
    recorded = _prompts(project, "reviewer", "review")
    layouts = [_reviewer_layout(project, sid) for sid in _SIDS]
    assert len(recorded) == len(_SIDS)

    prefix = layouts[0].stable_prefix
    assert all(layout.stable_prefix == prefix for layout in layouts)
    for prompt, layout in zip(recorded, layouts, strict=True):
        assert prompt.startswith(layout.text)
    assert prefix.startswith(_REVIEWER_INSTRUCTIONS + STABLE_CONTEXT_HEADER)
    assert identity in prefix
    assert "Reviewer identity (host-supplied" not in prefix
    for sid in _SIDS:
        assert project.run_id(sid).root not in prefix


def test_test_authoring_inputs_share_one_stable_prefix_across_subphases(
    three_subphases: tuple[_Canon, str],
) -> None:
    project, _ = three_subphases
    recorded = _prompts(project, "planner", "test_authoring")
    layouts = [_planner_layout(project, sid) for sid in _SIDS]
    assert len(recorded) == len(_SIDS)

    prefix = layouts[0].stable_prefix
    assert all(layout.stable_prefix == prefix for layout in layouts)
    for prompt, layout in zip(recorded, layouts, strict=True):
        assert prompt == layout.text  # the test-authoring Planner gets no turn protocol
    master = load_frozen_master_plan(project.project_root)
    assert master is not None
    assert master_plan_digest(master) in prefix


def test_jit_planner_inputs_share_one_stable_prefix_across_replans(
    three_subphases: tuple[_Canon, str],
) -> None:
    project, identity = three_subphases
    recorded = _prompts(project, "planner", "jit_replan")
    assert len(recorded) == 2

    first, second = recorded
    boundary = first.index(CONTEXT_PACK_HEADER)
    prefix = first[:boundary]
    assert prefix.startswith(STABLE_CONTEXT_HEADER)
    assert second.startswith(prefix) and second[boundary:].startswith(CONTEXT_PACK_HEADER)
    assert first[boundary:] != second[boundary:]
    master = load_frozen_master_plan(project.project_root)
    assert master is not None
    assert master_plan_digest(master) in prefix and identity in prefix
    for sid in _SIDS:
        assert project.run_id(sid).root not in prefix
    # The replan instructions keep their place after the material they refer to ("above").
    assert first.endswith("\n" + _REPLAN_INSTRUCTIONS)
    assert second.endswith("\n" + _REPLAN_INSTRUCTIONS)


def test_roles_have_distinct_stable_prefixes(three_subphases: tuple[_Canon, str]) -> None:
    project, _ = three_subphases
    prefixes = {
        _implementer_layout(project, "01").stable_prefix,
        _reviewer_layout(project, "01").stable_prefix,
        _planner_layout(project, "01").stable_prefix,
    }
    assert len(prefixes) == 3


# ===========================================================================
# L -- the turn protocol keeps its accepted place after the volatile suffix
# ===========================================================================


def test_the_turn_protocol_still_follows_the_volatile_suffix_byte_for_byte(
    three_subphases: tuple[_Canon, str],
) -> None:
    project, _ = three_subphases

    implementer = _prompts(project, "implementer", "implementation")[0]
    assert implementer == (
        _implementer_layout(project, "01").text
        + _BLOCKER_PROTOCOL_SUFFIX
        + _IMPLEMENTER_TURN_PROTOCOL_SUFFIX
    )
    reviewer = _prompts(project, "reviewer", "review")[0]
    assert reviewer == _reviewer_layout(project, "01").text + _REVIEWER_TURN_PROTOCOL_SUFFIX


# ===========================================================================
# C -- a canonical retry keeps the stable prefixes (AC-12.3-05/06)
# ===========================================================================


def test_a_canonical_retry_keeps_both_stable_prefixes(tmp_path: Path) -> None:
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
            _implementation("01", "attempt one summary"),
            _implementation("01", "attempt two summary"),
        ],
        reviewer=[
            _review("01", attempt=1, verdict="rework", findings=[finding]),
            _review("01", attempt=2, verdict="approve"),
        ],
    )
    _prepare(project)
    _run(project)

    implementer_prefix = _implementer_layout(project, "01").stable_prefix
    reviewer_prefix = _reviewer_layout(project, "01").stable_prefix
    first, second = project.prompt("implementer", 0), project.prompt("implementer", 1)
    assert _manifest(second)["operation"] == "rework"
    assert first.startswith(implementer_prefix) and second.startswith(implementer_prefix)
    assert second[len(implementer_prefix) :].startswith(CONTEXT_PACK_HEADER)
    assert _EXPANSION_FINDING in second[len(implementer_prefix) :]
    assert _EXPANSION_FINDING not in implementer_prefix

    review_one, review_two = project.prompt("reviewer", 0), project.prompt("reviewer", 1)
    assert review_one.startswith(reviewer_prefix) and review_two.startswith(reviewer_prefix)
    assert _manifest(review_two)["identity"]["attempt"] == 2  # type: ignore[index]
    assert "attempt one summary" not in reviewer_prefix
