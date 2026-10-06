"""Phase 12.8: the durable, tracked, project-owned ContextSelection.

The host's explicit document selection lives in exactly one tracked project file,
``<PROJECT_ROOT>/.lockstep/project/context-selection.json``. It is strict, versioned and
canonical; an absent file means the empty selection and is never created by Lockstep. The
canonical production request paths (the canonical transaction request factory and JIT
replanning) load it freshly through one host-owned loader; ``context_selection=`` remains the
explicit controlled seam. Selection stays explicit and provider-neutral.

Everything runs real production code against recording fake provider executables and a real
Git source repository. No real Claude/Codex account, network, or model inference is used.

Baseline classification: RED at entry e0dea1b + 12.8 TEST_CORRECTION_COMMIT
(``lockstep.context.context_selection_store`` does not exist, and every production caller
supplies an empty ``ContextSelection()``).
"""

from __future__ import annotations

import ast
import dataclasses
import hashlib
import inspect
import json
from pathlib import Path
from types import SimpleNamespace

import pytest
from test_canonical_project_run import _Canon, _make_canonical
from test_project_orchestrator import _contract_payload
from test_supervisor_resume_execution import _git

import lockstep.context.context_selection_store as store
from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.context.context_pack import CONTEXT_PACK_HEADER, ContextOperation, ContextSourceKind
from lockstep.context.context_pack_builder import (
    CONTEXT_DOCUMENTS_MAX_COUNT,
    ContextSelection,
    SelectedContextDocument,
)
from lockstep.context.context_selection_store import (
    ContextSelectionStoreError,
    context_selection_identity,
    context_selection_path,
    load_context_selection,
    load_context_selection_identity,
    parse_context_selection,
    render_context_selection,
)
from lockstep.domain import BillingMode, RunId, SubphaseContract
from lockstep.project_orchestrator import ProjectRunDisposition, TransactionPlacement
from lockstep.supervisor.transaction import SingleSubphaseTransactionRequest
from lockstep.transaction_factory import (
    TransactionFactoryError,
    canonical_transaction_request_factory,
)

_K = ContextSourceKind
_O = ContextOperation

_AGENTS_TEXT = "Agents: always run the canonical health check before handing back."
_ARCHITECTURE_TEXT = "Architecture: the supervisor composes kernels; adapters stay thin."
_SKILL_TEXT = "Skill: review the frozen tests against the Contract first."


def _selection_file(root: Path) -> Path:
    return root / ".lockstep" / "project" / "context-selection.json"


def _write_selection(root: Path, payload: object, *, indent: int | None = None) -> Path:
    path = _selection_file(root)
    path.parent.mkdir(parents=True, exist_ok=True)
    text = payload if isinstance(payload, str) else json.dumps(payload, indent=indent)
    path.write_text(text, encoding="utf-8")
    return path


def _doc(path: str, kind: str, *operations: str) -> dict[str, object]:
    return {"path": path, "kind": kind, "operations": list(operations)}


def _payload(*documents: dict[str, object]) -> dict[str, object]:
    return {"schema_version": 1, "documents": list(documents)}


_SAMPLE = _payload(
    _doc("skill/SKILL.md", "skill", "review"),
    _doc("AGENTS.md", "project_instructions", "review", "implementation"),
    _doc("docs/architecture.md", "project_documentation", "jit_replan", "implementation"),
)


def _canonical_text(payload: dict[str, object]) -> bytes:
    order = list(ContextOperation)
    documents = sorted(
        (
            {
                "path": d["path"],
                "kind": d["kind"],
                "operations": sorted(
                    d["operations"], key=lambda o: order.index(ContextOperation(o))
                ),  # type: ignore[arg-type]
            }
            for d in payload["documents"]  # type: ignore[attr-defined]
        ),
        key=lambda d: d["path"],  # type: ignore[arg-type, return-value]
    )
    canonical = {"schema_version": 1, "documents": documents}
    text = json.dumps(canonical, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return (text + "\n").encode("utf-8")


def _tree(root: Path) -> dict[str, bytes]:
    return {
        str(p.relative_to(root)): p.read_bytes()
        for p in sorted(root.rglob("*"))
        if p.is_file() and ".git" not in p.relative_to(root).parts
    }


# ===========================================================================
# Public shape
# ===========================================================================


def test_public_api_exports_expected_names() -> None:
    assert set(store.__all__) == {
        "CONTEXT_SELECTION_SCHEMA_VERSION",
        "ContextSelectionStoreError",
        "context_selection_identity",
        "context_selection_path",
        "load_context_selection",
        "load_context_selection_identity",
        "parse_context_selection",
        "render_context_selection",
    }
    assert store.CONTEXT_SELECTION_SCHEMA_VERSION == 1


def test_the_canonical_destination_is_the_tracked_project_file(tmp_path: Path) -> None:
    assert context_selection_path(tmp_path) == _selection_file(tmp_path)


def test_the_store_never_writes_anything() -> None:
    source = Path(inspect.getfile(store)).read_text(encoding="utf-8")

    for token in (".write(", "write_text", "write_bytes", "os.replace", "mkdir", "os.open("):
        assert token not in source, token


# ===========================================================================
# Test A: durable selection round trip, canonical rendering and identity
# ===========================================================================


def test_parse_render_parse_preserves_exact_semantics() -> None:
    parsed = parse_context_selection(json.dumps(_SAMPLE).encode("utf-8"))
    rendered = render_context_selection(parsed)

    assert parse_context_selection(rendered) == parsed
    assert render_context_selection(parse_context_selection(rendered)) == rendered
    assert {(d.path, d.kind, d.operations) for d in parsed.documents} == {
        ("AGENTS.md", _K.PROJECT_INSTRUCTIONS, (_O.IMPLEMENTATION, _O.REVIEW)),
        ("docs/architecture.md", _K.PROJECT_DOCUMENTATION, (_O.IMPLEMENTATION, _O.JIT_REPLAN)),
        ("skill/SKILL.md", _K.SKILL, (_O.REVIEW,)),
    }
    assert parsed.require_project_digest is False


def test_the_canonical_rendering_is_sorted_compact_json_with_a_trailing_newline() -> None:
    parsed = parse_context_selection(json.dumps(_SAMPLE).encode("utf-8"))

    assert render_context_selection(parsed) == _canonical_text(_SAMPLE)
    assert [d.path for d in parsed.documents] == [
        "AGENTS.md",
        "docs/architecture.md",
        "skill/SKILL.md",
    ]


def test_identity_is_the_sha256_of_the_canonical_rendering() -> None:
    parsed = parse_context_selection(json.dumps(_SAMPLE).encode("utf-8"))

    assert (
        context_selection_identity(parsed) == hashlib.sha256(_canonical_text(_SAMPLE)).hexdigest()
    )


def test_whitespace_and_order_in_a_hand_edited_file_do_not_change_identity() -> None:
    reordered = _payload(*reversed(_SAMPLE["documents"]))  # type: ignore[call-overload]
    variants = [
        json.dumps(_SAMPLE).encode("utf-8"),
        json.dumps(_SAMPLE, indent=4).encode("utf-8"),
        json.dumps(reordered, indent=2).encode("utf-8") + b"\n\n",
    ]

    identities = {context_selection_identity(parse_context_selection(v)) for v in variants}
    assert len(identities) == 1
    assert len({parse_context_selection(v) for v in variants}) == 1


def test_the_empty_selection_has_a_canonical_rendering_and_identity() -> None:
    empty = parse_context_selection(b'{"schema_version": 1, "documents": []}')

    assert empty == ContextSelection()
    assert render_context_selection(empty) == b'{"documents":[],"schema_version":1}\n'
    assert (
        context_selection_identity(empty)
        == hashlib.sha256(b'{"documents":[],"schema_version":1}\n').hexdigest()
    )


def test_require_project_digest_is_not_persisted_and_cannot_be_rendered() -> None:
    with pytest.raises(ContextSelectionStoreError):
        render_context_selection(ContextSelection(require_project_digest=True))


@pytest.mark.parametrize(
    "payload",
    [
        {**_SAMPLE, "extra": 1},
        {**_SAMPLE, "require_project_digest": True},
        _payload({**_doc("AGENTS.md", "project_instructions", "review"), "text": "copied"}),
        _payload({**_doc("AGENTS.md", "project_instructions", "review"), "sha256": "0" * 64}),
    ],
    ids=["top-level", "require-digest", "document-text", "document-sha"],
)
def test_unknown_fields_fail_closed(payload: dict[str, object]) -> None:
    with pytest.raises(ContextSelectionStoreError):
        parse_context_selection(json.dumps(payload).encode("utf-8"))


@pytest.mark.parametrize(
    "path",
    [
        "/etc/passwd",
        "../outside.md",
        "docs/../AGENTS.md",
        "./AGENTS.md",
        ".git/config",
        ".lockstep/project/master-plan.json",
        "docs/*.md",
        "docs\\architecture.md",
        "",
        "docs//architecture.md",
    ],
)
def test_unsafe_document_paths_fail_closed(path: str) -> None:
    payload = _payload(_doc(path, "project_documentation", "review"))

    with pytest.raises(ContextSelectionStoreError):
        parse_context_selection(json.dumps(payload).encode("utf-8"))


@pytest.mark.parametrize(
    "payload",
    [
        _payload(
            _doc("AGENTS.md", "project_instructions", "review"),
            _doc("AGENTS.md", "project_documentation", "implementation"),
        ),
        _payload(_doc("AGENTS.md", "project_instructions", "review", "review")),
        _payload(_doc("AGENTS.md", "project_instructions")),
        _payload(_doc("AGENTS.md", "contract", "review")),
        _payload(_doc("AGENTS.md", "project_digest", "review")),
        _payload(_doc("AGENTS.md", "project_instructions", "deploy")),
        {"schema_version": 2, "documents": []},
        {"schema_version": "1", "documents": []},
        {"schema_version": True, "documents": []},
        {"documents": []},
        {"schema_version": 1},
        _payload(
            *(
                _doc(f"docs/d{i}.md", "project_documentation", "review")
                for i in range(CONTEXT_DOCUMENTS_MAX_COUNT + 1)
            )
        ),
    ],
    ids=[
        "duplicate-document",
        "duplicate-operation",
        "no-operation",
        "foreign-kind",
        "digest-kind",
        "unknown-operation",
        "future-schema",
        "string-schema",
        "bool-schema",
        "missing-schema",
        "missing-documents",
        "too-many",
    ],
)
def test_malformed_selections_fail_closed(payload: dict[str, object]) -> None:
    with pytest.raises(ContextSelectionStoreError):
        parse_context_selection(json.dumps(payload).encode("utf-8"))


@pytest.mark.parametrize("raw", [b"", b"[]", b"not json", b"\xff\xfe{}", b"null"])
def test_unparseable_bytes_fail_closed(raw: bytes) -> None:
    with pytest.raises(ContextSelectionStoreError):
        parse_context_selection(raw)


def test_a_valid_file_loads_through_the_project_root(tmp_path: Path) -> None:
    _write_selection(tmp_path, _SAMPLE, indent=2)

    loaded = load_context_selection(tmp_path)

    assert loaded == parse_context_selection(json.dumps(_SAMPLE).encode("utf-8"))
    assert load_context_selection_identity(tmp_path) == context_selection_identity(loaded)


def test_a_symlinked_selection_file_fails_closed(tmp_path: Path) -> None:
    real = tmp_path / "elsewhere.json"
    real.write_text(json.dumps(_SAMPLE), encoding="utf-8")
    link = _selection_file(tmp_path)
    link.parent.mkdir(parents=True)
    link.symlink_to(real)

    with pytest.raises(ContextSelectionStoreError):
        load_context_selection(tmp_path)


@pytest.mark.parametrize("level", [".lockstep", ".lockstep/project"])
def test_a_symlinked_lockstep_directory_fails_closed(tmp_path: Path, level: str) -> None:
    project, outside = tmp_path / "project", tmp_path / "outside"
    project.mkdir()
    _write_selection(outside, _SAMPLE)
    target = outside / level
    link = project / level
    link.parent.mkdir(parents=True, exist_ok=True)
    link.symlink_to(target, target_is_directory=True)

    with pytest.raises(ContextSelectionStoreError):
        load_context_selection(project)


def test_a_directory_in_place_of_the_selection_file_fails_closed(tmp_path: Path) -> None:
    _selection_file(tmp_path).mkdir(parents=True)

    with pytest.raises(ContextSelectionStoreError):
        load_context_selection(tmp_path)


def test_a_selected_document_that_traverses_a_symlink_fails_closed(tmp_path: Path) -> None:
    (tmp_path / "real-docs").mkdir()
    (tmp_path / "real-docs" / "architecture.md").write_text("x", encoding="utf-8")
    (tmp_path / "docs").symlink_to(tmp_path / "real-docs", target_is_directory=True)
    _write_selection(
        tmp_path, _payload(_doc("docs/architecture.md", "project_documentation", "review"))
    )

    with pytest.raises(ContextSelectionStoreError):
        load_context_selection(tmp_path)


def test_a_selected_document_that_is_not_a_regular_file_fails_closed(tmp_path: Path) -> None:
    (tmp_path / "docs" / "architecture.md").mkdir(parents=True)
    _write_selection(
        tmp_path, _payload(_doc("docs/architecture.md", "project_documentation", "review"))
    )

    with pytest.raises(ContextSelectionStoreError):
        load_context_selection(tmp_path)


# ===========================================================================
# Test B: absent selection compatibility
# ===========================================================================


def test_an_absent_file_is_the_empty_selection_and_nothing_is_created(tmp_path: Path) -> None:
    (tmp_path / "README.md").write_text("project", encoding="utf-8")
    before = _tree(tmp_path)

    assert load_context_selection(tmp_path) == ContextSelection()
    assert load_context_selection_identity(tmp_path) is None
    assert _tree(tmp_path) == before
    assert not (tmp_path / ".lockstep").exists()


def test_an_absent_file_is_distinct_from_an_explicitly_empty_file(tmp_path: Path) -> None:
    assert load_context_selection_identity(tmp_path) is None

    _write_selection(tmp_path, _payload())

    assert load_context_selection(tmp_path) == ContextSelection()
    assert load_context_selection_identity(tmp_path) == context_selection_identity(
        ContextSelection()
    )


def test_a_canonical_run_without_a_selection_file_never_creates_one(tmp_path: Path) -> None:
    project = _make_canonical(tmp_path, sids=("01",))

    result = project.run()

    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    assert not context_selection_path(project.project_root).exists()
    assert _git(project.source, "status", "--porcelain").stdout == ""


# ===========================================================================
# Test C: the tracked selection reaches canonical production packs
# ===========================================================================

_TRACKED = _payload(
    _doc("AGENTS.md", "project_instructions", "test_authoring", "implementation", "review"),
    _doc("docs/architecture.md", "project_documentation", "implementation", "jit_replan"),
    _doc("skill/SKILL.md", "skill", "review"),
)


def _track_selection(project: _Canon, payload: dict[str, object]) -> None:
    root = project.project_root
    (root / "AGENTS.md").write_text(_AGENTS_TEXT, encoding="utf-8")
    (root / "docs").mkdir(exist_ok=True)
    (root / "docs" / "architecture.md").write_text(_ARCHITECTURE_TEXT, encoding="utf-8")
    (root / "skill").mkdir(exist_ok=True)
    (root / "skill" / "SKILL.md").write_text(_SKILL_TEXT, encoding="utf-8")
    _write_selection(root, payload, indent=2)
    _git(project.source, "add", "-A")
    _git(project.source, "commit", "-m", "track context selection")


def _manifest_references(prompt: str) -> set[str]:
    start = prompt.index(CONTEXT_PACK_HEADER) + len(CONTEXT_PACK_HEADER)
    manifest = json.loads(prompt[start:].split("\n", 1)[0])
    return {source["reference"] for source in manifest["sources"]}


@pytest.fixture(scope="module")
def tracked_run(tmp_path_factory: pytest.TempPathFactory) -> SimpleNamespace:
    project = _make_canonical(tmp_path_factory.mktemp("tracked-selection"))  # 01, 02 + JIT
    _track_selection(project, _TRACKED)
    before = _tree(project.project_root)
    result = project.run()  # no request_factory, no context_selection: the production path
    return SimpleNamespace(project=project, result=result, before=before)


def test_the_tracked_run_reaches_the_phase_gate(tracked_run: SimpleNamespace) -> None:
    assert tracked_run.result.disposition is ProjectRunDisposition.PHASE_GATE_READY


def test_the_test_authoring_pack_carries_only_the_documents_selected_for_it(
    tracked_run: SimpleNamespace,
) -> None:
    prompt = tracked_run.project.prompt("planner", 1)  # call 0 plans the Contract

    assert _AGENTS_TEXT in prompt
    assert _ARCHITECTURE_TEXT not in prompt
    assert _SKILL_TEXT not in prompt
    assert "file:AGENTS.md" in _manifest_references(prompt)


def test_the_implementer_pack_carries_instructions_and_documentation(
    tracked_run: SimpleNamespace,
) -> None:
    prompt = tracked_run.project.prompt("implementer", 0)

    assert _AGENTS_TEXT in prompt
    assert _ARCHITECTURE_TEXT in prompt
    assert _SKILL_TEXT not in prompt
    assert {"file:AGENTS.md", "file:docs/architecture.md"} <= _manifest_references(prompt)


def test_the_reviewer_pack_carries_instructions_and_the_skill(
    tracked_run: SimpleNamespace,
) -> None:
    prompt = tracked_run.project.prompt("reviewer", 0)

    assert _AGENTS_TEXT in prompt
    assert _SKILL_TEXT in prompt
    assert _ARCHITECTURE_TEXT not in prompt
    assert {"file:AGENTS.md", "file:skill/SKILL.md"} <= _manifest_references(prompt)


def test_the_jit_replan_pack_loads_the_durable_selection_by_default(
    tracked_run: SimpleNamespace,
) -> None:
    prompt = tracked_run.project.prompt("planner", 2)  # contract 01, tests 01, then the replan

    assert '"operation":"jit_replan"' in prompt
    assert _ARCHITECTURE_TEXT in prompt
    assert _AGENTS_TEXT not in prompt
    assert "file:docs/architecture.md" in _manifest_references(prompt)


def test_the_run_mutates_neither_the_selection_nor_the_selected_documents(
    tracked_run: SimpleNamespace,
) -> None:
    project = tracked_run.project

    assert _tree(project.project_root) == tracked_run.before
    assert _git(project.source, "status", "--porcelain").stdout == ""


# --- direct request construction -------------------------------------------------------


def _contract() -> SubphaseContract:
    return SubphaseContract.model_validate(_contract_payload("01"))


def _placement(project: _Canon) -> TransactionPlacement:
    run_id = RunId.model_validate("run-01-01")
    return TransactionPlacement(
        run_id=run_id,
        runtime_dir=project.runtime_dir / "transactions" / run_id.root,
        worktree_path=project.runtime_dir / "worktrees" / run_id.root,
        branch=f"lockstep/run/{run_id.root}",
        base_branch=None,
    )


def _request(project: _Canon, **kwargs: object) -> SingleSubphaseTransactionRequest:
    factory = canonical_transaction_request_factory(project.runtime, **kwargs)  # type: ignore[arg-type]
    return factory(_contract(), _placement(project))


def test_the_factory_default_is_the_durable_selection(tmp_path: Path) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    _track_selection(project, _TRACKED)

    request = _request(project)

    assert request.context is not None
    assert request.context.selection == load_context_selection(project.project_root)
    assert len(request.context.selection.documents) == 3
    assert _AGENTS_TEXT in request.planner_prompt


def test_an_explicit_selection_remains_the_controlled_seam(tmp_path: Path) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    _track_selection(project, _TRACKED)

    request = _request(project, context_selection=ContextSelection())

    assert request.context is not None
    assert request.context.selection == ContextSelection()
    assert _AGENTS_TEXT not in request.planner_prompt


def test_each_request_reads_the_selection_freshly(tmp_path: Path) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    _track_selection(project, _payload())
    factory = canonical_transaction_request_factory(project.runtime)

    first = factory(_contract(), _placement(project))
    _write_selection(project.project_root, _TRACKED)
    second = factory(_contract(), _placement(project))

    assert first.context is not None and second.context is not None
    assert first.context.selection == ContextSelection()
    assert second.context.selection == load_context_selection(project.project_root)
    assert _AGENTS_TEXT not in first.planner_prompt
    assert _AGENTS_TEXT in second.planner_prompt


def test_an_invalid_tracked_selection_fails_closed_before_any_launch(tmp_path: Path) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    _write_selection(project.project_root, {**_TRACKED, "unexpected": True})

    with pytest.raises(TransactionFactoryError):
        _request(project)
    assert project.counts() == (0, 0, 0)


# ===========================================================================
# Test D: provider neutrality
# ===========================================================================


def _routed(project: _Canon, provider: AgentProvider) -> _Canon:
    route = AgentRoleRoute(
        provider=provider,
        model="unused-model",
        effort="unused-effort",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )
    config = dataclasses.replace(
        project.runtime.config,
        routing=AgentRoutingPolicy(planner=route, implementer=route, reviewer=route),
    )
    return dataclasses.replace(project, runtime=dataclasses.replace(project.runtime, config=config))


def test_the_durable_selection_is_identical_under_claude_and_codex_routing(
    tmp_path: Path,
) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    _track_selection(project, _TRACKED)

    claude = _request(_routed(project, AgentProvider.CLAUDE))
    codex = _request(_routed(project, AgentProvider.CODEX))

    assert claude.context == codex.context
    assert claude.context is not None
    assert claude.context.selection == load_context_selection(project.project_root)
    assert claude.planner_prompt == codex.planner_prompt
    assert _AGENTS_TEXT in codex.planner_prompt


def test_selection_names_no_provider_and_carries_no_provider_vocabulary() -> None:
    fields = set(SelectedContextDocument.model_fields) | set(ContextSelection.model_fields)
    rendered = render_context_selection(
        parse_context_selection(json.dumps(_SAMPLE).encode("utf-8"))
    ).decode("utf-8")

    assert fields == {"path", "kind", "operations", "documents", "require_project_digest"}
    for word in ("claude", "codex", "provider", "session", "model"):
        assert word not in rendered.lower()


def test_only_the_host_loader_reads_the_selection_file() -> None:
    src = Path(inspect.getfile(store)).resolve().parents[1]
    readers = sorted(
        path.relative_to(src).as_posix()
        for path in src.rglob("*.py")
        if "context-selection.json" in path.read_text(encoding="utf-8")
    )
    callers = sorted(
        path.relative_to(src).as_posix()
        for path in src.rglob("*.py")
        if "load_context_selection" in path.read_text(encoding="utf-8")
        and path.name != "context_selection_store.py"
    )

    assert readers == ["context/context_selection_store.py"]
    assert callers == [
        "jit_replan.py",
        "phase_context_finalization.py",
        "transaction_factory.py",
    ]
    for module in ("agents", "agent_turn.py", "implementer_turn.py", "reviewer_turn.py"):
        for path in callers:
            assert not path.startswith(module)


def test_the_store_imports_no_provider_or_orchestration_module() -> None:
    tree = ast.parse(Path(inspect.getfile(store)).read_text(encoding="utf-8"))
    imported = {
        node.module
        for node in ast.walk(tree)
        if isinstance(node, ast.ImportFrom) and node.module is not None
    }

    for name in imported:
        assert not name.startswith(
            ("lockstep.agents", "lockstep.supervisor", "lockstep.project_orchestrator")
        ), name
