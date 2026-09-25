"""Planner tests for Codex Reviewer schema materialization (Sub-phase 5.6).

These tests pin the production seam that turns the canonical Lockstep
Reviewer artifact contract into the exact on-disk provider artifact a
Reviewer :class:`CodexAdapter` consumes via ``--output-schema``:

    ReviewDecision.model_json_schema()
            ↓
    to_openai_strict_json_schema(...)
            ↓
    deterministic JSON serialization
            ↓
    run-scoped provider artifact
            ↓
    CodexAdapter(review_output_schema_path=...)

The materialization helper is Reviewer-specific; the adapter itself
remains side-effect free.
"""

from __future__ import annotations

import copy
import json
from pathlib import Path

import pytest

from lockstep.agents import (
    AgentInvocationRequest,
    CodexAdapter,
    CodexCliStatus,
    materialize_codex_review_schema,
    to_openai_strict_json_schema,
)
from lockstep.domain import (
    AgentRole,
    BillingMode,
    ReviewDecision,
)

_SCHEMA_FILENAME = "review-decision.schema.json"


def _healthy_status(executable: str = "/fake/codex") -> CodexCliStatus:
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
        supports_exec_output_schema=True,
    )


def _reviewer_request(cwd: Path, prompt: str = "reviewer-prompt") -> AgentInvocationRequest:
    return AgentInvocationRequest(
        role=AgentRole.REVIEWER,
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        prompt=prompt,
        cwd=cwd,
        timeout_seconds=5,
        termination_grace_seconds=0.1,
    )


def _snapshot_tree(root: Path) -> dict[str, bytes]:
    """Capture a byte-level snapshot of every regular file under *root*."""
    snapshot: dict[str, bytes] = {}
    for path in sorted(root.rglob("*")):
        if path.is_file():
            snapshot[str(path.relative_to(root))] = path.read_bytes()
    return snapshot


# ---------------------------------------------------------------------------
# Section 16 — exact run-scoped materialization path
# ---------------------------------------------------------------------------


def test_materialized_path_uses_exact_run_scoped_provider_layout(tmp_path: Path) -> None:
    runtime_dir = tmp_path / "runtime"

    path = materialize_codex_review_schema(runtime_dir)

    expected = (runtime_dir / "providers" / "codex" / _SCHEMA_FILENAME).resolve()
    assert path == expected
    assert path.exists()
    assert path.is_absolute()


# ---------------------------------------------------------------------------
# Section 17 — materialized contents equal full strict-normalizer result
# ---------------------------------------------------------------------------


def test_materialized_contents_equal_full_strict_normalizer_result(tmp_path: Path) -> None:
    runtime_dir = tmp_path / "runtime"

    path = materialize_codex_review_schema(runtime_dir)

    decoded = json.loads(path.read_text(encoding="utf-8"))
    expected = to_openai_strict_json_schema(ReviewDecision.model_json_schema())
    assert decoded == expected


# ---------------------------------------------------------------------------
# Section 18 — canonical ReviewDecision schema is not mutated
# ---------------------------------------------------------------------------


def test_canonical_review_decision_schema_is_not_mutated(tmp_path: Path) -> None:
    canonical = ReviewDecision.model_json_schema()
    before = copy.deepcopy(canonical)

    materialize_codex_review_schema(tmp_path / "runtime")

    assert canonical == before


# ---------------------------------------------------------------------------
# Section 19 — live 5.4 failure sites become strict
# ---------------------------------------------------------------------------


def test_materialized_schema_pins_5_4_failure_site_required_lists(tmp_path: Path) -> None:
    path = materialize_codex_review_schema(tmp_path / "runtime")
    decoded = json.loads(path.read_text(encoding="utf-8"))

    assert decoded["required"] == [
        "schema_version",
        "phase_id",
        "subphase_id",
        "attempt",
        "verdict",
        "summary",
        "findings",
    ]
    assert decoded["additionalProperties"] is False

    review_finding = decoded["$defs"]["ReviewFinding"]
    assert review_finding["required"] == [
        "summary",
        "evidence",
        "file_path",
        "acceptance_criterion_id",
    ]
    assert review_finding["additionalProperties"] is False


# ---------------------------------------------------------------------------
# Section 20 — nullable semantics survive materialization
# ---------------------------------------------------------------------------


def test_materialized_schema_preserves_nullable_review_finding_fields(tmp_path: Path) -> None:
    path = materialize_codex_review_schema(tmp_path / "runtime")
    decoded = json.loads(path.read_text(encoding="utf-8"))

    props = decoded["$defs"]["ReviewFinding"]["properties"]

    for field_name in ("file_path", "acceptance_criterion_id"):
        node = props[field_name]
        assert "default" not in node
        variants = node.get("anyOf")
        assert isinstance(variants, list)
        variant_types = {variant.get("type") for variant in variants if isinstance(variant, dict)}
        assert "null" in variant_types
        assert "string" in variant_types


# ---------------------------------------------------------------------------
# Section 21 — deterministic UTF-8 bytes with exactly one trailing newline
# ---------------------------------------------------------------------------


def test_repeated_materialization_produces_identical_bytes_and_one_trailing_newline(
    tmp_path: Path,
) -> None:
    runtime_dir = tmp_path / "runtime"

    first_path = materialize_codex_review_schema(runtime_dir)
    first = first_path.read_bytes()

    second_path = materialize_codex_review_schema(runtime_dir)
    second = second_path.read_bytes()

    assert first_path == second_path
    assert first == second
    assert first.endswith(b"\n")
    assert not first.endswith(b"\n\n")
    # No BOM; strictly ASCII/UTF-8 JSON.
    assert not first.startswith(b"\xef\xbb\xbf")
    # Compact separators — no ASCII space between key/value pairs.
    assert b", " not in first
    assert b": " not in first


# ---------------------------------------------------------------------------
# Section 22 — stale existing file is atomically replaced
# ---------------------------------------------------------------------------


def test_stale_existing_schema_file_is_replaced(tmp_path: Path) -> None:
    runtime_dir = tmp_path / "runtime"
    provider_dir = runtime_dir / "providers" / "codex"
    provider_dir.mkdir(parents=True)
    stale_path = provider_dir / _SCHEMA_FILENAME
    stale_path.write_bytes(b"THIS IS STALE")

    result = materialize_codex_review_schema(runtime_dir)

    contents = result.read_bytes()
    assert b"THIS IS STALE" not in contents
    decoded = json.loads(contents)
    expected = to_openai_strict_json_schema(ReviewDecision.model_json_schema())
    assert decoded == expected


# ---------------------------------------------------------------------------
# Section 23 — publication failure preserves prior final file and cleans up
# ---------------------------------------------------------------------------


def test_publication_failure_preserves_prior_file_and_leaves_no_orphan_temps(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from lockstep.agents import codex_review as materializer_module

    runtime_dir = tmp_path / "runtime"
    good_path = materialize_codex_review_schema(runtime_dir)
    good_bytes = good_path.read_bytes()

    provider_dir = runtime_dir / "providers" / "codex"

    def _boom(*_args: object, **_kwargs: object) -> None:
        raise RuntimeError("simulated atomic-replace failure")

    monkeypatch.setattr(materializer_module, "_replace_atomically", _boom)

    with pytest.raises(RuntimeError):
        materialize_codex_review_schema(runtime_dir)

    assert good_path.read_bytes() == good_bytes

    leftover = [entry for entry in provider_dir.iterdir() if entry.name != _SCHEMA_FILENAME]
    assert leftover == []


def test_publication_failure_without_prior_file_produces_no_final_or_orphan(
    tmp_path: Path,
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    from lockstep.agents import codex_review as materializer_module

    runtime_dir = tmp_path / "runtime"

    def _boom(*_args: object, **_kwargs: object) -> None:
        raise RuntimeError("simulated atomic-replace failure")

    monkeypatch.setattr(materializer_module, "_replace_atomically", _boom)

    with pytest.raises(RuntimeError):
        materialize_codex_review_schema(runtime_dir)

    provider_dir = runtime_dir / "providers" / "codex"
    schema_path = provider_dir / _SCHEMA_FILENAME
    assert not schema_path.exists()

    if provider_dir.exists():
        assert list(provider_dir.iterdir()) == []


# ---------------------------------------------------------------------------
# Section 24 — returned path composes directly with Reviewer CodexAdapter
# ---------------------------------------------------------------------------


def test_returned_path_composes_directly_with_reviewer_codex_adapter(
    tmp_path: Path,
) -> None:
    runtime_dir = tmp_path / "runtime"
    schema_path = materialize_codex_review_schema(runtime_dir)

    adapter = CodexAdapter(
        role=AgentRole.REVIEWER,
        status=_healthy_status(),
        model="gpt-5-reviewer",
        reasoning_effort="high",
        review_output_schema_path=schema_path,
    )
    command = adapter.build_command(_reviewer_request(tmp_path))

    assert "--output-schema" in command.argv
    schema_index = command.argv.index("--output-schema")
    assert command.argv[schema_index + 1] == str(schema_path)
    assert command.argv[schema_index + 1] == str(schema_path.resolve())


# ---------------------------------------------------------------------------
# Section 25 — no Planner/Implementer convenience materializer exists
# ---------------------------------------------------------------------------


def test_no_planner_or_implementer_materializer_exists_in_public_api() -> None:
    import lockstep.agents as agents

    assert hasattr(agents, "materialize_codex_review_schema")
    assert not hasattr(agents, "materialize_codex_planner_schema")
    assert not hasattr(agents, "materialize_codex_implementer_schema")


# ---------------------------------------------------------------------------
# Section 26 — worktree directory is untouched
# ---------------------------------------------------------------------------


def test_materialization_does_not_touch_worktree_directory(tmp_path: Path) -> None:
    runtime_dir = tmp_path / "runtime"
    worktree_dir = tmp_path / "worktree"
    worktree_dir.mkdir()
    (worktree_dir / "sentinel_a.txt").write_text("A", encoding="utf-8")
    nested = worktree_dir / "sub"
    nested.mkdir()
    (nested / "sentinel_b.txt").write_text("B", encoding="utf-8")

    before = _snapshot_tree(worktree_dir)
    materialize_codex_review_schema(runtime_dir)
    after = _snapshot_tree(worktree_dir)

    assert before == after


# ---------------------------------------------------------------------------
# Section 27 — public API export
# ---------------------------------------------------------------------------


def test_public_api_exports_materializer_from_lockstep_agents() -> None:
    import lockstep.agents as agents

    assert hasattr(agents, "materialize_codex_review_schema")
    assert agents.materialize_codex_review_schema is materialize_codex_review_schema


def test_existing_public_api_surface_preserved() -> None:
    from lockstep.agents import (
        AgentAdapter,
        AgentCommand,
        AgentInvocationRequest,
        AgentInvocationResult,
        CodexAdapter,
        CodexAdapterError,
        CodexCliStatus,
        CodexPreflightError,
        OpenAIStrictSchemaError,
        invoke_agent,
        probe_codex_cli,
        require_codex_subscription_ready,
        to_openai_strict_json_schema,
    )

    for symbol in (
        AgentAdapter,
        AgentCommand,
        AgentInvocationRequest,
        AgentInvocationResult,
        CodexAdapter,
        CodexAdapterError,
        CodexCliStatus,
        CodexPreflightError,
        OpenAIStrictSchemaError,
        invoke_agent,
        probe_codex_cli,
        require_codex_subscription_ready,
        to_openai_strict_json_schema,
    ):
        assert symbol is not None
