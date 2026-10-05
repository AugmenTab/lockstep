"""Phase 12.3: deterministic stable-prefix layout of provider-facing context.

A rendered ContextPack is laid out from the most reusable, least volatile material to
the least reusable, most volatile: role instructions, then a stable region (the
Project Digest, selected instructions / documentation / skills, frozen Master Plan
and current-Phase material, with a provenance manifest naming only those sources),
then the volatile region opened by the accepted ``CONTEXT_PACK_HEADER`` and its
complete 12.2 manifest (operation, invocation identity, every source), then the
Contract, tests, evidence, retry control and identity.

Stability is a layout property, not an authority property: it is a fixed host-owned
map from source kind (:data:`SOURCE_STABILITY`), and the 12.2 authority map is
unchanged. The boundary is structural (:class:`ContextLayout`), so the stable prefix
and volatile suffix are obtained without scraping prose. Nothing is cached: a stable
prefix is identical exactly while its stable source bytes are identical, and changes
the moment any of them changes.

Baseline classification: every test in this module is RED at entry (78c04f9 has no
``ContextLayout`` / ``layout_context_pack`` / ``SOURCE_STABILITY``).
"""

from __future__ import annotations

import hashlib
import inspect
import json
import re
import shutil
from pathlib import Path

import pytest
from pydantic import ValidationError
from test_context_pack import (
    _DIGEST_STATEMENT_A,
    _DIGEST_STATEMENT_B,
    _P1,
    _PROJECT,
    _digest,
    _jit_inputs,
    _master,
    _section,
    _sid,
    _write,
)
from test_handoffs import (
    _EXPANSION_FINDING,
    _SCOPE_CLAIM,
    _attempt,
    _contract,
    _implementer_evidence,
    _rework_decision,
    _verification,
)

import lockstep.context.context_pack as context_pack
import lockstep.context.context_pack_builder as context_pack_builder
from lockstep.context.context_pack import (
    CONTEXT_PACK_HEADER,
    SOURCE_AUTHORITY,
    SOURCE_STABILITY,
    STABLE_CONTEXT_HEADER,
    ContextIdentity,
    ContextLayout,
    ContextOperation,
    ContextPack,
    ContextSection,
    ContextSourceKind,
    ContextStability,
    compose_context_prompt,
    layout_context_pack,
    render_context_pack,
)
from lockstep.context.context_pack_builder import (
    ContextSelection,
    ContextSources,
    SelectedContextDocument,
    build_implementer_context_pack,
    build_jit_replan_context_pack,
    build_reviewer_context_pack,
    build_rework_context_pack,
    build_test_authoring_context_pack,
)
from lockstep.context.project_digest import project_digest_identity
from lockstep.context.project_digest_store import freeze_project_digest
from lockstep.domain import AgentRole, ReviewDecision, RunId, SubphaseContract
from lockstep.handoff import (
    REVIEWER_IDENTITY_HEADER,
    AuthorityKind,
    ContractAuthority,
    FileChange,
    HandoffIdentity,
    ImplementerHandoff,
    PlannerTestHandoff,
    ProtectedAcceptance,
    RepositoryBasis,
    RepositoryEvidence,
    RequiredTestPaths,
    RetryControl,
    ReviewerHandoff,
    ReviewEvidence,
    ReviewHistory,
    ReworkHandoff,
    render_implementer_handoff,
    render_planner_test_handoff,
    render_reviewer_handoff,
    render_rework_handoff,
)
from lockstep.planning_store import freeze_master_plan
from lockstep.project_cursor import CompletedSubphase, contract_digest, master_plan_digest
from lockstep.transaction_factory import (
    _IMPLEMENTER_INSTRUCTIONS,
    _PLANNER_INSTRUCTIONS,
    _REVIEWER_INSTRUCTIONS,
)

_K = ContextSourceKind
_ALL_OPERATIONS = tuple(ContextOperation)

_AGENTS_TEXT = "Follow the house rules.\n"
_ARCHITECTURE_TEXT = "# Architecture\nThe supervisor composes kernels.\n"
_SKILL_TEXT = "Review carefully.\n"

_STABLE_KINDS = frozenset(
    {
        _K.PROJECT_DIGEST,
        _K.PROJECT_INSTRUCTIONS,
        _K.PROJECT_DOCUMENTATION,
        _K.SKILL,
        _K.MASTER_PLAN,
        _K.PHASE_CONTEXT,
    }
)

_TEST_SHA = "a" * 40
_BASIS_SHA = "b" * 40
_OTHER_TEST_SHA = "d" * 40
_OTHER_BASIS_SHA = "e" * 40

_ISO_TIMESTAMP = re.compile(r"\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}")


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def stable_sources(tmp_path: Path) -> ContextSources:
    """A project with a frozen Master Plan, a frozen Digest and three selected documents."""
    project_root = tmp_path / "project"
    project_root.mkdir()
    runtime_dir = tmp_path / "runtime"
    runtime_dir.mkdir()
    freeze_master_plan(project_root, _master())
    freeze_project_digest(project_root, runtime_dir, _digest(_DIGEST_STATEMENT_A))
    _write(project_root, "AGENTS.md", _AGENTS_TEXT)
    _write(project_root, "docs/architecture.md", _ARCHITECTURE_TEXT)
    _write(project_root, "skills/review/SKILL.md", _SKILL_TEXT)
    return ContextSources(
        project_id=_PROJECT,
        project_root=project_root,
        runtime_dir=runtime_dir,
        selection=_selection(),
    )


def _selection(*, reverse: bool = False) -> ContextSelection:
    documents = (
        SelectedContextDocument(
            path="skills/review/SKILL.md", kind=_K.SKILL, operations=_ALL_OPERATIONS
        ),
        SelectedContextDocument(
            path="docs/architecture.md", kind=_K.PROJECT_DOCUMENTATION, operations=_ALL_OPERATIONS
        ),
        SelectedContextDocument(
            path="AGENTS.md", kind=_K.PROJECT_INSTRUCTIONS, operations=_ALL_OPERATIONS
        ),
    )
    return ContextSelection(documents=tuple(reversed(documents)) if reverse else documents)


def _with(sources: ContextSources, selection: ContextSelection) -> ContextSources:
    return ContextSources(
        project_id=sources.project_id,
        project_root=sources.project_root,
        runtime_dir=sources.runtime_dir,
        selection=selection,
    )


def _handoff_identity(
    role: AgentRole, *, sid: str = "01", run: str | None = None, attempt: int = 1
) -> HandoffIdentity:
    return HandoffIdentity(
        run_id=RunId.model_validate(run if run is not None else f"run-01-{sid}"),
        phase_id=_P1,
        subphase_id=_sid(sid),
        attempt=_attempt(attempt),
        role=role,
    )


def _contract_for(sid: str = "01", *, objective: str | None = None) -> ContractAuthority:
    contract = SubphaseContract.model_validate(
        {
            **_contract().model_dump(mode="json"),
            "subphase_id": sid,
            "title": f"Feature {sid}",
            "objective": objective if objective is not None else f"Provide feature {sid}.",
        }
    )
    return ContractAuthority(contract_digest=contract_digest(contract), contract=contract)


def _protected(test_sha: str = _TEST_SHA) -> ProtectedAcceptance:
    return ProtectedAcceptance(test_paths=("tests/test_feature_01.py",), test_commit_sha=test_sha)


def _basis(
    sid: str = "01", *, test_sha: str = _TEST_SHA, basis_sha: str = _BASIS_SHA
) -> RepositoryBasis:
    return RepositoryBasis(
        branch=f"lockstep/run/run-01-{sid}", basis_commit_sha=basis_sha, test_commit_sha=test_sha
    )


def _implementer(
    sid: str = "01",
    *,
    run: str | None = None,
    contract: ContractAuthority | None = None,
    test_sha: str = _TEST_SHA,
    basis_sha: str = _BASIS_SHA,
) -> ImplementerHandoff:
    return ImplementerHandoff(
        identity=_handoff_identity(AgentRole.IMPLEMENTER, sid=sid, run=run),
        contract=contract if contract is not None else _contract_for(sid),
        protected_tests=_protected(test_sha),
        basis=_basis(sid, test_sha=test_sha, basis_sha=basis_sha),
    )


def _rework(attempt: int = 2) -> ReworkHandoff:
    return ReworkHandoff(
        identity=_handoff_identity(AgentRole.IMPLEMENTER, attempt=attempt),
        contract=_contract_for("01"),
        protected_tests=_protected(),
        basis=_basis("01"),
        retry=RetryControl(kind="review_rework", attempt=_attempt(attempt)),
        review=ReviewEvidence(decision=_rework_decision()),
        verification=_verification(attempt=attempt - 1),
    )


def _repository(patch: str, base: str = _TEST_SHA) -> RepositoryEvidence:
    return RepositoryEvidence(
        base_commit_sha=base,
        changes=(
            FileChange(path="feature_01.py", status="added", patch=patch, patch_truncated=False),
        ),
    )


def _reviewer(
    *,
    run: str | None = None,
    attempt: int = 1,
    patch: str = "+def answer() -> int:\n+    return 1\n",
    history: tuple[ReviewDecision, ...] = (),
) -> ReviewerHandoff:
    return ReviewerHandoff(
        identity=_handoff_identity(AgentRole.REVIEWER, run=run, attempt=attempt),
        contract=_contract_for("01"),
        protected_tests=_protected(),
        implementer=_implementer_evidence(attempt),
        verification=_verification(attempt),
        repository=_repository(patch),
        history=ReviewHistory(decisions=history),
    )


def _planner(sid: str = "01") -> PlannerTestHandoff:
    return PlannerTestHandoff(
        identity=_handoff_identity(AgentRole.PLANNER, sid=sid),
        contract=_contract_for(sid),
        test_paths=RequiredTestPaths(paths=("tests/test_feature_01.py",)),
    )


def _all_packs(sources: ContextSources) -> dict[str, ContextPack]:
    master, plan, cursor, basis = _jit_inputs()
    return {
        "test_authoring": build_test_authoring_context_pack(sources, _planner()),
        "implementation": build_implementer_context_pack(sources, _implementer()),
        "rework": build_rework_context_pack(sources, _rework()),
        "review": build_reviewer_context_pack(sources, _reviewer()),
        "jit_replan": build_jit_replan_context_pack(
            sources, master_plan=master, phase_plan=plan, cursor=cursor, basis=basis
        ),
    }


def _manifest_after(text: str, header: str) -> dict[str, object]:
    assert text.startswith(header)
    value = json.loads(text[len(header) :].split("\n", 1)[0])
    assert isinstance(value, dict)
    return value


def _provenance(section: ContextSection) -> dict[str, object]:
    return {
        "title": section.title,
        "kind": section.kind.value,
        "authority": section.authority.value,
        "reference": section.reference,
        "completeness": section.completeness.value,
        "version": section.version,
    }


def _stable(pack: ContextPack) -> list[ContextSection]:
    return [s for s in pack.sections if s.kind in _STABLE_KINDS]


def _volatile(pack: ContextPack) -> list[ContextSection]:
    return [s for s in pack.sections if s.kind not in _STABLE_KINDS]


# ===========================================================================
# The stability map is host-owned and orthogonal to authority
# ===========================================================================


def test_stability_is_a_fixed_host_mapping_over_every_source_kind() -> None:
    assert set(SOURCE_STABILITY) == set(ContextSourceKind)
    assert {kind for kind, s in SOURCE_STABILITY.items() if s is ContextStability.STABLE} == (
        _STABLE_KINDS
    )
    assert {s.value for s in ContextStability} == {"stable", "volatile"}
    with pytest.raises(TypeError):
        SOURCE_STABILITY[_K.CONTRACT] = ContextStability.STABLE  # type: ignore[index]


def test_stability_leaves_the_accepted_authority_mapping_and_section_fields_unchanged() -> None:
    a = AuthorityKind
    assert dict(SOURCE_AUTHORITY) == {
        _K.PROJECT_DIGEST: a.ADVISORY_CONTEXT,
        _K.MASTER_PLAN: a.FROZEN_REQUIREMENT,
        _K.PHASE_CONTEXT: a.FROZEN_REQUIREMENT,
        _K.COMPLETED_HISTORY: a.FROZEN_REQUIREMENT,
        _K.PROVISIONAL_OUTLINE: a.PROVISIONAL_PLAN,
        _K.CONTRACT: a.FROZEN_REQUIREMENT,
        _K.REQUIRED_TESTS: a.FROZEN_REQUIREMENT,
        _K.FROZEN_TESTS: a.PROTECTED_ACCEPTANCE,
        _K.PROJECT_INSTRUCTIONS: a.ADVISORY_CONTEXT,
        _K.PROJECT_DOCUMENTATION: a.ADVISORY_CONTEXT,
        _K.SKILL: a.ADVISORY_CONTEXT,
        _K.RETRY_CONTROL: a.CONTROL_DECISION,
        _K.IMPLEMENTATION_REPORT: a.EXECUTION_EVIDENCE,
        _K.VERIFICATION_REPORT: a.EXECUTION_EVIDENCE,
        _K.REVIEW_FINDINGS: a.EXECUTION_EVIDENCE,
        _K.REVIEW_HISTORY: a.EXECUTION_EVIDENCE,
        _K.REPOSITORY_STATE: a.EXECUTION_EVIDENCE,
    }
    # Stable authoritative sources and volatile authoritative sources both exist.
    assert SOURCE_STABILITY[_K.MASTER_PLAN] is ContextStability.STABLE
    assert SOURCE_STABILITY[_K.CONTRACT] is ContextStability.VOLATILE
    # No second meaning was added to the section model.
    assert set(ContextSection.model_fields) == {
        "kind",
        "authority",
        "title",
        "reference",
        "completeness",
        "version",
        "content",
    }


def test_a_pack_must_place_every_stable_source_before_any_volatile_source() -> None:
    identity = ContextIdentity(
        project_id=_PROJECT,
        phase_id=_P1,
        subphase_id=_sid("01"),
        run_id=RunId.model_validate("run-01-01"),
        attempt=_attempt(1),
        role=AgentRole.IMPLEMENTER,
    )
    volatile = (
        _section(_K.CONTRACT, {"c": 1}, reference="contract:x"),
        _section(_K.FROZEN_TESTS, {"t": 1}, reference="git:x"),
        _section(_K.REPOSITORY_STATE, {"b": 1}, reference="git:y"),
    )
    digest = _section(_K.PROJECT_DIGEST, {"d": 1}, reference="project-digest:x")

    ContextPack(
        operation=ContextOperation.IMPLEMENTATION, identity=identity, sections=(digest, *volatile)
    )
    with pytest.raises(ValidationError):
        ContextPack(
            operation=ContextOperation.IMPLEMENTATION,
            identity=identity,
            sections=(volatile[0], digest, *volatile[1:]),
        )


def test_every_builder_orders_its_sources_stable_first(stable_sources: ContextSources) -> None:
    for pack in _all_packs(stable_sources).values():
        kinds = [s.kind for s in pack.sections]
        stable_count = sum(1 for k in kinds if k in _STABLE_KINDS)
        assert stable_count > 0
        assert all(k in _STABLE_KINDS for k in kinds[:stable_count])
        assert all(k not in _STABLE_KINDS for k in kinds[stable_count:])


# ===========================================================================
# Structural boundary (AC-12.3-01, AC-12.3-02)
# ===========================================================================


def test_the_layout_is_a_structural_stable_prefix_and_volatile_suffix(
    stable_sources: ContextSources,
) -> None:
    for operation, pack in _all_packs(stable_sources).items():
        layout = layout_context_pack(pack)

        assert isinstance(layout, ContextLayout)
        assert layout.text == layout.stable_prefix + layout.volatile_suffix
        assert render_context_pack(pack) == layout.text, operation
        assert layout.stable_prefix.startswith(STABLE_CONTEXT_HEADER)
        assert layout.volatile_suffix.startswith(CONTEXT_PACK_HEADER)
        assert CONTEXT_PACK_HEADER not in layout.stable_prefix
        # Every stable section is rendered before the boundary, every volatile one after.
        for section in _stable(pack):
            heading = f"\n## {section.title} [{section.authority.value}]\n{section.content}\n"
            assert heading in layout.stable_prefix
            assert heading not in layout.volatile_suffix
        for section in _volatile(pack):
            heading = f"\n## {section.title} [{section.authority.value}]\n{section.content}\n"
            assert heading in layout.volatile_suffix
            assert heading not in layout.stable_prefix


def test_composition_puts_role_instructions_ahead_of_the_stable_region(
    stable_sources: ContextSources,
) -> None:
    pack = build_implementer_context_pack(stable_sources, _implementer())
    layout = layout_context_pack(pack)

    composed = compose_context_prompt(_IMPLEMENTER_INSTRUCTIONS, pack)
    assert composed.stable_prefix == _IMPLEMENTER_INSTRUCTIONS + layout.stable_prefix
    assert composed.volatile_suffix == layout.volatile_suffix
    assert composed.text == _IMPLEMENTER_INSTRUCTIONS + render_context_pack(pack)

    trailed = compose_context_prompt("", pack, trailer="\nINSTRUCTIONS")
    assert trailed.stable_prefix == layout.stable_prefix
    assert trailed.volatile_suffix == layout.volatile_suffix + "\nINSTRUCTIONS"


def test_the_accepted_handoff_sections_stay_contiguous_in_the_volatile_suffix(
    stable_sources: ContextSources,
) -> None:
    implementer, rework, reviewer, planner = _implementer(), _rework(), _reviewer(), _planner()

    def suffix(pack: ContextPack) -> str:
        return layout_context_pack(pack).volatile_suffix

    assert render_implementer_handoff(implementer) in suffix(
        build_implementer_context_pack(stable_sources, implementer)
    )
    assert render_rework_handoff(rework) in suffix(
        build_rework_context_pack(stable_sources, rework)
    )
    assert suffix(build_reviewer_context_pack(stable_sources, reviewer)).endswith(
        render_reviewer_handoff(reviewer)
    )
    assert render_planner_test_handoff(planner) in suffix(
        build_test_authoring_context_pack(stable_sources, planner)
    )


# ===========================================================================
# A -- deterministic partition
# ===========================================================================


def test_a_construction_order_does_not_change_the_prefix_suffix_or_rendering(
    stable_sources: ContextSources,
) -> None:
    forward = _all_packs(stable_sources)
    backward = _all_packs(_with(stable_sources, _selection(reverse=True)))

    for operation in forward:
        first, second = (
            layout_context_pack(forward[operation]),
            layout_context_pack(backward[operation]),
        )
        assert first.stable_prefix == second.stable_prefix, operation
        assert first.volatile_suffix == second.volatile_suffix, operation
        assert first.text == second.text, operation
        assert layout_context_pack(forward[operation]) == first


# ===========================================================================
# B -- Sub-phase reuse; G -- Contract isolation (AC-12.3-03, AC-12.3-04)
# ===========================================================================


def test_b_sequential_subphases_share_the_stable_implementer_prefix(
    stable_sources: ContextSources,
) -> None:
    a = compose_context_prompt(
        _IMPLEMENTER_INSTRUCTIONS,
        build_implementer_context_pack(stable_sources, _implementer("01")),
    )
    b = compose_context_prompt(
        _IMPLEMENTER_INSTRUCTIONS,
        build_implementer_context_pack(
            stable_sources,
            _implementer("02", test_sha=_OTHER_TEST_SHA, basis_sha=_OTHER_BASIS_SHA),
        ),
    )

    assert a.stable_prefix == b.stable_prefix
    assert a.volatile_suffix != b.volatile_suffix
    assert b.text.startswith(a.stable_prefix)
    for volatile in ("run-01-02", _OTHER_TEST_SHA, _OTHER_BASIS_SHA, "Feature 02"):
        assert volatile in b.volatile_suffix
        assert volatile not in b.stable_prefix


def test_b_sequential_subphases_share_the_stable_test_authoring_prefix(
    stable_sources: ContextSources,
) -> None:
    a = compose_context_prompt(
        _PLANNER_INSTRUCTIONS, build_test_authoring_context_pack(stable_sources, _planner("01"))
    )
    b = compose_context_prompt(
        _PLANNER_INSTRUCTIONS, build_test_authoring_context_pack(stable_sources, _planner("02"))
    )

    assert a.stable_prefix == b.stable_prefix
    assert a.volatile_suffix != b.volatile_suffix
    # The current-Phase excerpt comes from the frozen Master Plan, not the identity.
    assert "## MASTER PLAN EXCERPT / CURRENT PHASE [frozen_requirement]" in a.stable_prefix
    assert master_plan_digest(_master()) in a.stable_prefix


def test_g_changing_only_the_contract_alters_no_byte_before_the_boundary(
    stable_sources: ContextSources,
) -> None:
    original = _implementer()
    changed = _implementer(contract=_contract_for("01", objective="Provide feature 01, revised."))
    first = compose_context_prompt(
        _IMPLEMENTER_INSTRUCTIONS, build_implementer_context_pack(stable_sources, original)
    )
    second = compose_context_prompt(
        _IMPLEMENTER_INSTRUCTIONS, build_implementer_context_pack(stable_sources, changed)
    )

    assert first.text != second.text
    assert first.stable_prefix == second.stable_prefix
    differ = next(
        i for i, (x, y) in enumerate(zip(first.text, second.text, strict=False)) if x != y
    )
    assert differ >= len(first.stable_prefix)
    assert changed.contract is not None
    assert changed.contract.contract_digest not in second.stable_prefix
    assert changed.contract.contract_digest in second.volatile_suffix


# ===========================================================================
# C -- retry reuse (AC-12.3-05)
# ===========================================================================


def test_c_a_retry_keeps_the_stable_prefix_and_carries_rework_material_in_the_suffix(
    stable_sources: ContextSources,
) -> None:
    attempt_one = compose_context_prompt(
        _IMPLEMENTER_INSTRUCTIONS, build_implementer_context_pack(stable_sources, _implementer())
    )
    attempt_two = compose_context_prompt(
        _IMPLEMENTER_INSTRUCTIONS, build_rework_context_pack(stable_sources, _rework(2))
    )
    attempt_three = compose_context_prompt(
        _IMPLEMENTER_INSTRUCTIONS, build_rework_context_pack(stable_sources, _rework(3))
    )

    assert attempt_one.stable_prefix == attempt_two.stable_prefix == attempt_three.stable_prefix
    assert attempt_two.volatile_suffix != attempt_three.volatile_suffix
    for marker in (
        _EXPANSION_FINDING,
        "## RETRY CONTROL AUTHORITY [control_decision]",
        "## REVIEW EVIDENCE / REPAIR GUIDANCE [execution_evidence]",
        "## VERIFICATION EVIDENCE [execution_evidence]",
        "retry:attempt-2:review_rework",
    ):
        assert marker in attempt_two.volatile_suffix
        assert marker not in attempt_two.stable_prefix


# ===========================================================================
# D -- Reviewer reuse; H -- diff / verification isolation (AC-12.3-06)
# ===========================================================================


def test_d_reviewer_invocations_share_the_stable_reviewer_prefix(
    stable_sources: ContextSources,
) -> None:
    first = compose_context_prompt(
        _REVIEWER_INSTRUCTIONS, build_reviewer_context_pack(stable_sources, _reviewer())
    )
    second = compose_context_prompt(
        _REVIEWER_INSTRUCTIONS,
        build_reviewer_context_pack(
            stable_sources,
            _reviewer(
                run="run-01-01-retry",
                attempt=2,
                patch="+def answer() -> int:\n+    return 2\n",
                history=(_rework_decision(),),
            ),
        ),
    )

    assert first.stable_prefix == second.stable_prefix
    assert first.volatile_suffix != second.volatile_suffix
    assert _EXPANSION_FINDING in second.volatile_suffix
    assert "return 2" in second.volatile_suffix
    assert "run-01-01-retry" in second.volatile_suffix
    for text in (_EXPANSION_FINDING, "return 2", "return 1", "run-01-01", _SCOPE_CLAIM):
        assert text not in second.stable_prefix


def test_h_diff_and_verification_changes_do_not_touch_the_stable_prefix(
    stable_sources: ContextSources,
) -> None:
    base = _reviewer()
    failing = _verification(1)
    failing = failing.model_copy(
        update={"report": failing.report.model_copy(update={"passed": False})}
    )
    changed = base.model_copy(
        update={"repository": _repository("+broken\n"), "verification": failing}
    )

    first = layout_context_pack(build_reviewer_context_pack(stable_sources, base))
    second = layout_context_pack(build_reviewer_context_pack(stable_sources, changed))

    assert first.stable_prefix == second.stable_prefix
    assert first.volatile_suffix != second.volatile_suffix
    assert "+broken" in second.volatile_suffix and "+broken" not in second.stable_prefix


# ===========================================================================
# I -- identity isolation (AC-12.3-07)
# ===========================================================================


def test_i_identity_is_volatile_but_present_and_authoritative_in_the_suffix(
    stable_sources: ContextSources,
) -> None:
    original = layout_context_pack(build_reviewer_context_pack(stable_sources, _reviewer()))
    moved = layout_context_pack(
        build_reviewer_context_pack(stable_sources, _reviewer(run="run-01-01-b", attempt=3))
    )

    assert original.stable_prefix == moved.stable_prefix
    manifest = _manifest_after(moved.volatile_suffix, CONTEXT_PACK_HEADER)
    assert manifest["identity"] == {
        "project_id": "lockstep",
        "phase_id": "01",
        "subphase_id": "01",
        "run_id": "run-01-01-b",
        "attempt": 3,
        "role": "reviewer",
    }
    # The host identity the Review Decision must copy is still the exact tail.
    tail = moved.volatile_suffix[moved.volatile_suffix.index(REVIEWER_IDENTITY_HEADER) :]
    assert json.loads(tail[len(REVIEWER_IDENTITY_HEADER) :]) == {
        "phase_id": "01",
        "subphase_id": "01",
        "attempt": 3,
        "role": "reviewer",
    }
    assert REVIEWER_IDENTITY_HEADER not in moved.stable_prefix
    assert '"identity"' not in moved.stable_prefix

    implementer_a = layout_context_pack(
        build_implementer_context_pack(stable_sources, _implementer(run="run-01-01"))
    )
    implementer_b = layout_context_pack(
        build_implementer_context_pack(stable_sources, _implementer(run="run-01-01-later"))
    )
    assert implementer_a.stable_prefix == implementer_b.stable_prefix
    assert "run-01-01-later" in implementer_b.volatile_suffix


# ===========================================================================
# J -- no timestamps, session ids or volatile Git basis in stable prefixes
# ===========================================================================


def test_j_stable_prefixes_carry_no_clock_session_invocation_or_git_basis(
    stable_sources: ContextSources,
) -> None:
    _, _, cursor, basis = _jit_inputs()
    for operation, pack in _all_packs(stable_sources).items():
        prefix = layout_context_pack(pack).stable_prefix
        assert not _ISO_TIMESTAMP.search(prefix), operation
        assert "session" not in prefix.lower(), operation
        assert '"identity"' not in prefix, operation
        assert '"operation"' not in prefix, operation
        for volatile in (
            "run-01-01",
            _TEST_SHA,
            _BASIS_SHA,
            basis.commit,
            f"revision-{cursor.revision}",
            "attempt-",
            _contract_for("01").contract_digest,
        ):
            assert volatile not in prefix, (operation, volatile)


# ===========================================================================
# K -- provenance partition (AC-12.3-10)
# ===========================================================================


def test_k_stable_provenance_precedes_the_boundary_and_volatile_provenance_follows_it(
    stable_sources: ContextSources,
) -> None:
    for operation, pack in _all_packs(stable_sources).items():
        layout = layout_context_pack(pack)

        stable_manifest = _manifest_after(layout.stable_prefix, STABLE_CONTEXT_HEADER)
        assert stable_manifest == {
            "schema_version": 1,
            "sources": [_provenance(s) for s in _stable(pack)],
        }, operation
        complete = _manifest_after(layout.volatile_suffix, CONTEXT_PACK_HEADER)
        assert complete["schema_version"] == 1
        assert complete["operation"] == operation
        assert complete["identity"] == pack.identity.model_dump(mode="json")
        # No provenance is lost: the accepted complete manifest still names every source.
        assert complete["sources"] == [_provenance(s) for s in pack.sections]
        for section in _volatile(pack):
            assert section.reference not in layout.stable_prefix, (operation, section.reference)
            if section.version is not None:
                assert section.version not in layout.stable_prefix, (operation, section.kind)
        for section in _stable(pack):
            assert section.reference in layout.stable_prefix


# ===========================================================================
# E, F, M -- stable-source changes invalidate the prefix immediately (AC-12.3-08, -14)
# ===========================================================================


def test_e_a_new_digest_revision_changes_the_stable_prefix_and_leaves_no_stale_copy(
    stable_sources: ContextSources,
) -> None:
    before = layout_context_pack(build_implementer_context_pack(stable_sources, _implementer()))
    first = project_digest_identity(_digest(_DIGEST_STATEMENT_A))
    second = freeze_project_digest(
        stable_sources.project_root,
        stable_sources.runtime_dir,
        _digest(_DIGEST_STATEMENT_B, previous=first),
    )

    after = layout_context_pack(build_implementer_context_pack(stable_sources, _implementer()))

    assert after.stable_prefix != before.stable_prefix
    assert second in after.stable_prefix and _DIGEST_STATEMENT_B in after.stable_prefix
    assert _DIGEST_STATEMENT_A not in after.text
    assert f"project-digest:{first}" not in after.text
    # Only stable material changed; the suffix's own sources are the same.
    assert after.volatile_suffix.replace(second, first) == before.volatile_suffix


@pytest.mark.parametrize(
    ("path", "old"),
    [
        ("AGENTS.md", _AGENTS_TEXT),
        ("docs/architecture.md", _ARCHITECTURE_TEXT),
        ("skills/review/SKILL.md", _SKILL_TEXT),
    ],
)
def test_f_editing_a_selected_stable_document_invalidates_the_prefix(
    stable_sources: ContextSources, path: str, old: str
) -> None:
    before = layout_context_pack(build_reviewer_context_pack(stable_sources, _reviewer()))
    new = old.rstrip("\n") + " Revised.\n"
    _write(stable_sources.project_root, path, new)

    after = layout_context_pack(build_reviewer_context_pack(stable_sources, _reviewer()))

    assert after.stable_prefix != before.stable_prefix
    assert json.dumps(new)[1:-1] in after.stable_prefix
    assert json.dumps(old)[1:-1] not in after.text
    assert hashlib.sha256(new.encode()).hexdigest() in after.stable_prefix
    assert hashlib.sha256(old.encode()).hexdigest() not in after.text


def test_f_a_different_frozen_master_plan_invalidates_the_planner_prefix(
    stable_sources: ContextSources, tmp_path: Path
) -> None:
    # A frozen Master Plan cannot be re-frozen in place, so compare an otherwise identical
    # project whose frozen Master Plan differs.
    before = layout_context_pack(build_test_authoring_context_pack(stable_sources, _planner()))
    revised = _master().model_copy(update={"objective": "Build the revised control plane."})
    other = tmp_path / "revised"
    shutil.copytree(stable_sources.runtime_dir, other / "runtime")
    (other / "project").mkdir()
    freeze_master_plan(other / "project", revised)
    for relative in ("AGENTS.md", "docs/architecture.md", "skills/review/SKILL.md"):
        _write(
            other / "project",
            relative,
            (stable_sources.project_root / relative).read_text(encoding="utf-8"),
        )
    revised_sources = ContextSources(
        project_id=_PROJECT,
        project_root=other / "project",
        runtime_dir=other / "runtime",
        selection=_selection(),
    )

    after = layout_context_pack(build_test_authoring_context_pack(revised_sources, _planner()))

    assert after.stable_prefix != before.stable_prefix
    assert "Build the revised control plane." in after.stable_prefix
    assert master_plan_digest(revised) in after.stable_prefix
    assert master_plan_digest(_master()) not in after.text


def test_m_freshness_beats_reuse_and_rendering_is_a_pure_function_of_current_sources(
    stable_sources: ContextSources,
) -> None:
    original = layout_context_pack(build_implementer_context_pack(stable_sources, _implementer()))
    _write(stable_sources.project_root, "AGENTS.md", "Different house rules.\n")
    changed = layout_context_pack(build_implementer_context_pack(stable_sources, _implementer()))
    _write(stable_sources.project_root, "AGENTS.md", _AGENTS_TEXT)
    restored = layout_context_pack(build_implementer_context_pack(stable_sources, _implementer()))

    assert changed.stable_prefix != original.stable_prefix
    assert "Different house rules." in changed.stable_prefix
    assert restored == original
    # Nothing accepts a previous layout or prefix to return in place of a fresh one.
    assert list(inspect.signature(layout_context_pack).parameters) == ["pack"]
    assert list(inspect.signature(compose_context_prompt).parameters) == [
        "instructions",
        "pack",
        "trailer",
    ]


# ===========================================================================
# N -- cache-state independence; no provider cache integration (AC-12.3-11..13)
# ===========================================================================


def test_n_a_fresh_reconstruction_from_copied_durable_sources_is_identical(
    stable_sources: ContextSources, tmp_path: Path
) -> None:
    original = {op: layout_context_pack(p) for op, p in _all_packs(stable_sources).items()}
    elsewhere = tmp_path / "elsewhere"
    shutil.copytree(stable_sources.project_root, elsewhere / "project")
    shutil.copytree(stable_sources.runtime_dir, elsewhere / "runtime")
    copied = ContextSources(
        project_id=_PROJECT,
        project_root=elsewhere / "project",
        runtime_dir=elsewhere / "runtime",
        selection=_selection(),
    )

    rebuilt = {op: layout_context_pack(p) for op, p in _all_packs(copied).items()}

    assert rebuilt == original


def test_n_layout_has_no_cache_and_no_provider_cache_control() -> None:
    for module in (context_pack, context_pack_builder):
        source = inspect.getsource(module)
        for token in ("lru_cache", "functools", "@cache", "_cache"):
            assert token not in source, (module.__name__, token)
    root = Path(context_pack.__file__).resolve().parents[1]
    for path in sorted(root.rglob("*.py")):
        text = path.read_text(encoding="utf-8")
        for token in ("cache_control", "cachedContent", "prompt_cache", "cache_ttl", "cache_id"):
            assert token not in text, (path.relative_to(root).as_posix(), token)


# ===========================================================================
# O -- role isolation; P -- JIT Planner
# ===========================================================================


def test_o_roles_may_differ_but_each_role_is_deterministic(
    stable_sources: ContextSources,
) -> None:
    packs = _all_packs(stable_sources)
    prefixes = {
        "planner": compose_context_prompt(
            _PLANNER_INSTRUCTIONS, packs["test_authoring"]
        ).stable_prefix,
        "implementer": compose_context_prompt(
            _IMPLEMENTER_INSTRUCTIONS, packs["implementation"]
        ).stable_prefix,
        "reviewer": compose_context_prompt(_REVIEWER_INSTRUCTIONS, packs["review"]).stable_prefix,
    }
    assert len(set(prefixes.values())) == 3

    again = _all_packs(stable_sources)
    assert (
        compose_context_prompt(_REVIEWER_INSTRUCTIONS, again["review"]).stable_prefix
        == prefixes["reviewer"]
    )
    assert (
        compose_context_prompt(_IMPLEMENTER_INSTRUCTIONS, again["rework"]).stable_prefix
        == prefixes["implementer"]
    )


def test_p_jit_invocations_share_the_stable_prefix_while_history_moves(
    stable_sources: ContextSources,
) -> None:
    master, plan, cursor, basis = _jit_inputs()
    later_cursor = cursor.model_copy(
        update={
            "revision": cursor.revision + 3,
            "current_subphase": _sid("03"),
            "completed_subphases": (
                *cursor.completed_subphases,
                CompletedSubphase(
                    phase_id=_P1,
                    subphase_id=_sid("02"),
                    run_id=RunId.model_validate("run-01-02"),
                    contract_digest="f" * 64,
                ),
            ),
            "remaining_outline": (),
        }
    )
    later_basis = basis.model_copy(
        update={
            "subphase_id": _sid("02"),
            "run_id": RunId.model_validate("run-01-02"),
            "contract_digest": "f" * 64,
            "branch": "lockstep/run/run-01-02",
            "commit": "9" * 40,
        }
    )

    first = layout_context_pack(
        build_jit_replan_context_pack(
            stable_sources, master_plan=master, phase_plan=plan, cursor=cursor, basis=basis
        )
    )
    second = layout_context_pack(
        build_jit_replan_context_pack(
            stable_sources,
            master_plan=master,
            phase_plan=plan,
            cursor=later_cursor,
            basis=later_basis,
        )
    )

    assert first.stable_prefix == second.stable_prefix
    assert first.volatile_suffix != second.volatile_suffix
    assert "## MASTER PLAN [frozen_requirement]" in first.stable_prefix
    assert "## COMPLETED HISTORY [frozen_requirement]" in first.volatile_suffix
    assert "## UNFINISHED PROVISIONAL OUTLINE [provisional_plan]" in first.volatile_suffix
    assert "9" * 40 in second.volatile_suffix and "9" * 40 not in second.stable_prefix
    complete = _manifest_after(second.volatile_suffix, CONTEXT_PACK_HEADER)
    assert complete["identity"] == {
        "project_id": "lockstep",
        "phase_id": "01",
        "subphase_id": None,
        "run_id": None,
        "attempt": None,
        "role": "planner",
    }


# ===========================================================================
# Q -- seams; L -- turn protocol is not part of the pack layout
# ===========================================================================


def test_q_a_pack_without_stable_sources_renders_exactly_the_accepted_12_2_bytes(
    tmp_path: Path,
) -> None:
    project_root = tmp_path / "project"
    project_root.mkdir()
    runtime_dir = tmp_path / "runtime"
    runtime_dir.mkdir()
    plain = ContextSources(project_id=_PROJECT, project_root=project_root, runtime_dir=runtime_dir)
    handoff = _implementer()
    pack = build_implementer_context_pack(plain, handoff)

    layout = layout_context_pack(pack)

    assert layout.stable_prefix == ""
    assert STABLE_CONTEXT_HEADER not in layout.text
    manifest = json.dumps(
        {
            "schema_version": 1,
            "operation": "implementation",
            "identity": pack.identity.model_dump(mode="json"),
            "sources": [_provenance(s) for s in pack.sections],
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    assert layout.volatile_suffix == (
        CONTEXT_PACK_HEADER + manifest + "\n" + render_implementer_handoff(handoff)
    )


def test_l_the_layout_carries_no_turn_protocol_and_the_turn_layer_still_appends_it(
    stable_sources: ContextSources,
) -> None:
    from lockstep.agent_turn import _BLOCKER_PROTOCOL_SUFFIX
    from lockstep.implementer_turn import _IMPLEMENTER_TURN_PROTOCOL_SUFFIX
    from lockstep.reviewer_turn import _REVIEWER_TURN_PROTOCOL_SUFFIX

    for pack in _all_packs(stable_sources).values():
        text = layout_context_pack(pack).text
        assert "Structured turn-completion protocol" not in text
        assert "Structured review-completion protocol" not in text
    # The turn layer's protocol text is unchanged by 12.3.
    assert _BLOCKER_PROTOCOL_SUFFIX.startswith("\n\n---\nStructured turn-completion protocol:")
    assert _IMPLEMENTER_TURN_PROTOCOL_SUFFIX.startswith(
        "\n---\nStructured implementation-report protocol:"
    )
    assert _REVIEWER_TURN_PROTOCOL_SUFFIX.startswith(
        "\n\n---\nStructured review-completion protocol:"
    )
