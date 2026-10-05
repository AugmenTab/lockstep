"""Phase 12.2: ContextPacks through the canonical production path.

Everything here runs the real production code against recording fake provider
executables, a real Git source repository, and the real planning, cursor, evidence
and Project Digest stores. ``run_project_phase`` is called without a
``request_factory`` unless a test is explicitly exercising a seam, so the host-owned
canonical factory builds every request and every role prompt is composed from a
ContextPack assembled at that role's invocation from durable state.

Baseline classification: every test in this module is RED at entry
(``lockstep.context.context_pack`` does not exist at 50b82db).
"""

from __future__ import annotations

import dataclasses
import json
from pathlib import Path

import pytest
from test_canonical_project_run import (
    _EXPANSION_FINDING,
    _FROZEN,
    _Canon,
    _implementation,
    _json,
    _make_canonical,
    _review,
    _sections,
)
from test_supervisor_resume_execution import _budget, _git

from lockstep.context.context_pack import (
    CONTEXT_PACK_HEADER,
    ContextSourceKind,
    render_context_pack,
)
from lockstep.context.context_pack_builder import (
    ContextSelection,
    ContextSources,
    SelectedContextDocument,
    build_reviewer_context_pack,
)
from lockstep.context.project_digest import (
    DigestFact,
    DigestSource,
    DigestSourceKind,
    ProjectDigest,
)
from lockstep.context.project_digest_store import freeze_project_digest
from lockstep.contract_history import load_archived_subphase_contract
from lockstep.domain import AttemptNumber, ProjectId
from lockstep.handoff import (
    build_implementer_handoff,
    build_reviewer_handoff,
    render_implementer_handoff,
)
from lockstep.project_cursor_store import load_project_cursor
from lockstep.project_orchestrator import (
    ProjectRunDisposition,
    TransactionPlacement,
    run_project_phase,
)
from lockstep.supervisor.transaction import SingleSubphaseTransactionRequest
from lockstep.transaction_factory import (
    TransactionFactoryError,
    canonical_transaction_request_factory,
)

_DIGEST_STATEMENT = "Every canonical artifact is written by the host, never by an agent."
_DIGEST_HEADING = "## PROJECT DIGEST / STABLE PROJECT KNOWLEDGE [advisory_context]"
_ARCHITECTURE_TEXT = "The supervisor composes kernels; adapters stay provider-specific."


def _digest() -> ProjectDigest:
    return ProjectDigest(
        project_id=ProjectId.model_validate("lockstep"),
        architecture=(
            DigestFact(
                fact_id="host-owned-artifacts",
                statement=_DIGEST_STATEMENT,
                sources=(
                    DigestSource(kind=DigestSourceKind.TRACKED_CONFIG, locator="lockstep.toml"),
                ),
            ),
        ),
    )


def _with_digest(project: _Canon) -> str:
    return freeze_project_digest(project.project_root, project.runtime_dir, _digest())


def _manifest(prompt: str) -> dict[str, object]:
    start = prompt.index(CONTEXT_PACK_HEADER) + len(CONTEXT_PACK_HEADER)
    value = json.loads(prompt[start:].split("\n", 1)[0])
    assert isinstance(value, dict)
    return value


def _source_kinds(prompt: str) -> list[str]:
    return [s["kind"] for s in _manifest(prompt)["sources"]]  # type: ignore[index, union-attr]


def _files_under(root: Path) -> dict[str, bytes]:
    return {
        str(path.relative_to(root)): path.read_bytes()
        for path in sorted(root.rglob("*"))
        if path.is_file()
    }


@pytest.fixture(scope="module")
def digest_run(tmp_path_factory: pytest.TempPathFactory) -> tuple[_Canon, str, dict[str, bytes]]:
    project = _make_canonical(tmp_path_factory.mktemp("context-digest"))
    identity = _with_digest(project)
    before = _files_under(project.runtime_dir / "project" / "project-digest")
    result = project.run()  # no request_factory: the canonical factory
    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    return project, identity, before


# ===========================================================================
# Canonical role prompts are ContextPacks (scenarios A, B, I, K)
# ===========================================================================


def test_every_canonical_role_prompt_is_a_context_pack_carrying_the_digest(
    digest_run: tuple[_Canon, str, dict[str, bytes]],
) -> None:
    project, identity, _ = digest_run
    prompts = {
        "test_authoring": project.prompt("planner", 1),  # call 0 plans the Contract
        "implementation": project.prompt("implementer", 0),
        "review": project.prompt("reviewer", 0),
    }

    for operation, prompt in prompts.items():
        manifest = _manifest(prompt)
        assert manifest["operation"] == operation
        assert _source_kinds(prompt)[0] == ContextSourceKind.PROJECT_DIGEST.value
        [digest_source] = [
            s
            for s in manifest["sources"]  # type: ignore[attr-defined]
            if s["kind"] == "project_digest"
        ]
        assert digest_source["version"] == identity
        assert digest_source["reference"] == f"project-digest:{identity}"
        assert _DIGEST_HEADING in prompt
        assert _DIGEST_STATEMENT in prompt
        # Stable knowledge precedes the frozen execution authority.
        assert prompt.index(_DIGEST_HEADING) < prompt.index(f"## {_FROZEN} [frozen_requirement]")


def test_the_initial_implementer_pack_has_authority_and_basis_but_no_later_evidence(
    digest_run: tuple[_Canon, str, dict[str, bytes]],
) -> None:
    project, _, _ = digest_run
    prompt = project.prompt("implementer", 0)

    assert _source_kinds(prompt) == [
        "project_digest",
        "contract",
        "frozen_tests",
        "repository_state",
    ]
    identity = _manifest(prompt)["identity"]
    assert identity == {
        "project_id": "lockstep",
        "phase_id": "01",
        "subphase_id": "01",
        "run_id": "run-01-01",
        "attempt": 1,
        "role": "implementer",
    }


def test_the_late_reviewer_pack_carries_report_verification_and_diff_as_evidence(
    digest_run: tuple[_Canon, str, dict[str, bytes]],
) -> None:
    project, _, _ = digest_run
    prompt = project.prompt("reviewer", 0)

    manifest = _manifest(prompt)
    by_kind = {s["kind"]: s for s in manifest["sources"]}  # type: ignore[attr-defined]
    for kind in ("implementation_report", "verification_report", "repository_state"):
        assert by_kind[kind]["authority"] == "execution_evidence"
    assert by_kind["contract"]["authority"] == "frozen_requirement"
    assert by_kind["frozen_tests"]["authority"] == "protected_acceptance"
    assert manifest["identity"]["role"] == "reviewer"  # type: ignore[index]
    assert "Reviewer identity (host-supplied" in prompt
    # The accepted 11.4 section layout is unchanged for the Reviewer.
    assert list(_sections(prompt)) == [
        "PROJECT DIGEST / STABLE PROJECT KNOWLEDGE",
        _FROZEN,
        "PROTECTED ACCEPTANCE ARTIFACT",
        "IMPLEMENTER EVIDENCE",
        "VERIFICATION EVIDENCE",
        "REPOSITORY EVIDENCE",
        "REVIEW HISTORY",
    ]


def test_the_reviewer_pack_rebuilds_from_disk_alone_with_no_provider_state(
    digest_run: tuple[_Canon, str, dict[str, bytes]],
) -> None:
    project, _, _ = digest_run
    # Remove everything the fake providers kept; nothing provider-side may be needed.
    for bin_dir in project.bins.values():
        for leftover in bin_dir.glob("*-invocations.jsonl"):
            leftover.unlink()
    recorded = project.prompt("reviewer", 0)

    cursor = load_project_cursor(project.project_root, project.runtime_dir)
    assert cursor is not None
    entry = cursor.completed_subphases[0]
    contract = load_archived_subphase_contract(
        project.project_root,
        project.runtime_dir,
        phase_id=entry.phase_id,
        subphase_id=entry.subphase_id,
        contract_digest=entry.contract_digest,
    )
    assert contract is not None
    handoff = build_reviewer_handoff(
        runtime_dir=project.txn_dir("01"),
        worktree_path=project.worktree("01"),
        run_id=project.run_id("01"),
        phase_id=contract.phase_id,
        subphase_id=contract.subphase_id,
        attempt=AttemptNumber.model_validate(1),
        contract=contract,
        test_paths=("tests/test_feature_01.py",),
    )
    sources = ContextSources(
        project_id=ProjectId.model_validate("lockstep"),
        project_root=project.project_root,
        runtime_dir=project.runtime_dir,
    )

    rebuilt = render_context_pack(build_reviewer_context_pack(sources, handoff))

    assert rebuilt in recorded


def test_canonical_runs_never_write_or_rewrite_the_project_digest(
    digest_run: tuple[_Canon, str, dict[str, bytes]],
) -> None:
    project, identity, before = digest_run
    digest_dir = project.runtime_dir / "project" / "project-digest"

    assert _files_under(digest_dir) == before
    assert sorted(p.name for p in (digest_dir / "history").iterdir()) == [f"{identity}.json"]


# ===========================================================================
# Fresh JIT Planner pack (scenario L)
# ===========================================================================


def test_the_jit_planner_prompt_is_a_fresh_pack_from_durable_project_state(
    digest_run: tuple[_Canon, str, dict[str, bytes]],
) -> None:
    project, identity, _ = digest_run
    prompt = project.prompt("planner", 2)  # contract, tests, then the replan after 01

    manifest = _manifest(prompt)
    assert manifest["operation"] == "jit_replan"
    assert manifest["identity"] == {
        "project_id": "lockstep",
        "phase_id": "01",
        "subphase_id": None,
        "run_id": None,
        "attempt": None,
        "role": "planner",
    }
    assert _source_kinds(prompt) == [
        "project_digest",
        "master_plan",
        "completed_history",
        "provisional_outline",
        "repository_state",
    ]
    sections = _sections(prompt)
    assert _json(sections["COMPLETED HISTORY"])["subphases"][0]["subphase_id"] == "01"  # type: ignore[index]
    unfinished = _json(sections["UNFINISHED PROVISIONAL OUTLINE"])
    assert [o["subphase_id"] for o in unfinished["subphases"]] == ["02"]  # type: ignore[union-attr]
    basis = _json(sections["ACCEPTED REPOSITORY BASIS"])
    assert basis["commit"] == _git(project.worktree("01"), "rev-parse", "HEAD").stdout.strip()
    assert identity in prompt
    # No Implementer or Reviewer prose is elevated into planning context.
    assert "Implemented the requested change." not in prompt
    assert "Return only the structured PhasePlan" in prompt


# ===========================================================================
# Rework (scenario J)
# ===========================================================================


def test_a_canonical_rework_pack_labels_findings_as_evidence_and_keeps_authority(
    tmp_path: Path,
) -> None:
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
    _with_digest(project)

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    first, second = project.prompt("implementer", 0), project.prompt("implementer", 1)
    assert _manifest(second)["operation"] == "rework"
    by_kind = {s["kind"]: s for s in _manifest(second)["sources"]}  # type: ignore[attr-defined]
    assert by_kind["review_findings"]["authority"] == "execution_evidence"
    assert by_kind["verification_report"]["authority"] == "execution_evidence"
    assert by_kind["retry_control"]["authority"] == "control_decision"
    assert (
        by_kind["contract"]
        == {
            s["kind"]: s
            for s in _manifest(first)["sources"]  # type: ignore[attr-defined]
        }["contract"]
    )
    assert _EXPANSION_FINDING not in first
    manifest_line = second[second.index(CONTEXT_PACK_HEADER) :].split("\n\n---\n## ", 1)[0]
    assert _EXPANSION_FINDING not in manifest_line
    assert _EXPANSION_FINDING in _sections(second)["REVIEW EVIDENCE / REPAIR GUIDANCE"]
    assert _manifest(project.prompt("reviewer", 1))["identity"]["attempt"] == 2  # type: ignore[index]


# ===========================================================================
# Selected documents through the canonical factory (scenarios E, F)
# ===========================================================================


def test_canonical_selection_includes_exact_documents_only_for_their_operations(
    tmp_path: Path,
) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    (project.source / "docs").mkdir()
    (project.source / "docs" / "architecture.md").write_text(_ARCHITECTURE_TEXT, encoding="utf-8")
    (project.source / "docs" / "review.md").write_text("Reviewer-only guide.", encoding="utf-8")
    _git(project.source, "add", "-A")
    _git(project.source, "commit", "-m", "docs")
    selection = ContextSelection(
        documents=(
            SelectedContextDocument(
                path="docs/architecture.md",
                kind=ContextSourceKind.PROJECT_DOCUMENTATION,
                operations=("implementation", "rework"),  # type: ignore[arg-type]
            ),
            SelectedContextDocument(
                path="docs/review.md",
                kind=ContextSourceKind.PROJECT_DOCUMENTATION,
                operations=("review",),  # type: ignore[arg-type]
            ),
        )
    )
    factory = canonical_transaction_request_factory(project.runtime, context_selection=selection)

    result = run_project_phase(
        project.runtime,
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
        request_factory=factory,
    )

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    implementer, reviewer = project.prompt("implementer", 0), project.prompt("reviewer", 0)
    assert _ARCHITECTURE_TEXT in implementer and "Reviewer-only guide." not in implementer
    assert "Reviewer-only guide." in reviewer and _ARCHITECTURE_TEXT not in reviewer
    assert _ARCHITECTURE_TEXT not in project.prompt("planner", 1)
    assert "file:docs/architecture.md" in {
        s["reference"]
        for s in _manifest(implementer)["sources"]  # type: ignore[attr-defined]
    }


def test_a_required_digest_that_is_absent_fails_closed_before_any_role_launch(
    tmp_path: Path,
) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    factory = canonical_transaction_request_factory(
        project.runtime, context_selection=ContextSelection(require_project_digest=True)
    )

    with pytest.raises(TransactionFactoryError):
        run_project_phase(
            project.runtime,
            retry_budget=_budget(3),
            planning_timeout_seconds=60.0,
            request_factory=factory,
        )
    assert project.counts() == (1, 0, 0)  # only the Contract was planned


# ===========================================================================
# Phase-11 pins and the retained legacy seam (scenarios P, Q)
# ===========================================================================


def test_a_canonical_run_without_a_digest_creates_none_and_keeps_the_cursor_alone(
    tmp_path: Path,
) -> None:
    project = _make_canonical(tmp_path, sids=("01",))

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert sorted(p.name for p in (project.runtime_dir / "project").iterdir()) == ["cursor.json"]
    prompt = project.prompt("implementer", 0)
    assert "project_digest" not in _source_kinds(prompt)
    assert _DIGEST_HEADING not in prompt


def test_an_injected_request_without_context_sources_keeps_the_accepted_handoff_prompt(
    tmp_path: Path,
) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    _with_digest(project)
    canonical = canonical_transaction_request_factory(project.runtime)
    seen: list[SingleSubphaseTransactionRequest] = []

    def legacy(
        contract: object, placement: TransactionPlacement
    ) -> SingleSubphaseTransactionRequest:
        request = dataclasses.replace(canonical(contract, placement), context=None)  # type: ignore[arg-type]
        seen.append(request)
        return request

    result = run_project_phase(
        project.runtime,
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
        request_factory=legacy,
    )

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    [request] = seen
    assert request.contract is not None
    handoff = build_implementer_handoff(
        runtime_dir=project.txn_dir("01"),
        worktree_path=project.worktree("01"),
        run_id=project.run_id("01"),
        phase_id=request.phase_id,
        subphase_id=request.subphase_id,
        attempt=AttemptNumber.model_validate(1),
        contract=request.contract,
        test_paths=request.test_paths,
    )
    prompt = project.prompt("implementer", 0)
    composed = request.implementer_prompt + render_implementer_handoff(handoff)
    # Exactly the accepted 11.4 bytes, followed directly by the turn layer's own protocol.
    assert prompt.startswith(composed)
    assert prompt[len(composed) :].startswith("\n\n---\nStructured turn-completion protocol")
    assert CONTEXT_PACK_HEADER not in prompt
    assert CONTEXT_PACK_HEADER not in project.prompt("reviewer", 0)
