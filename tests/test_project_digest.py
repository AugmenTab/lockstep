"""Phase 12.1: the Project Digest -- structure, canonical identity, authority, persistence."""

import ast
import hashlib
import inspect
import json
from pathlib import Path

import pytest
from pydantic import ValidationError

import lockstep.context.project_digest as project_digest
import lockstep.context.project_digest_store as project_digest_store
from lockstep.context.project_digest import (
    PROJECT_DIGEST_MAX_BYTES,
    DigestFact,
    DigestSource,
    DigestSourceKind,
    ProjectDigest,
    ProjectDigestError,
    canonical_project_digest_bytes,
    project_digest_identity,
)
from lockstep.context.project_digest_store import (
    ProjectDigestStoreError,
    freeze_project_digest,
    load_project_digest,
    load_project_digest_revision,
)
from lockstep.domain import (
    AcceptanceCriterion,
    MasterPlan,
    PhaseId,
    PhasePlan,
    ProjectId,
    RunId,
    SubphaseContract,
    SubphaseId,
    SubphaseOutline,
    TestExpectation,
    TestSpecification,
)
from lockstep.planning_store import (
    freeze_master_plan,
    freeze_subphase_contract,
    load_active_subphase_contract,
    load_frozen_master_plan,
    publish_phase_plan,
)
from lockstep.project_cursor import contract_digest, master_plan_digest
from lockstep.project_cursor_store import (
    bind_frozen_contract,
    initialize_project_cursor,
    load_project_cursor,
)

_SECTIONS = (
    "architecture",
    "module_boundaries",
    "technology_stack",
    "standard_commands",
    "test_strategy",
    "git_conventions",
    "invariants",
    "architectural_constraints",
)

# ---------------------------------------------------------------------------
# Construction helpers
# ---------------------------------------------------------------------------


def _pid(value: str) -> PhaseId:
    return PhaseId.model_validate(value)


def _sid(value: str) -> SubphaseId:
    return SubphaseId.model_validate(value)


def _plan(project_id: str = "lockstep") -> MasterPlan:
    return MasterPlan(
        project_id=ProjectId.model_validate(project_id),
        title="Lockstep",
        objective="Build the control plane.",
        phases=(
            PhasePlan(
                phase_id=_pid("01"),
                title="Phase 01",
                objective="Phase objective.",
                subphases=(
                    SubphaseOutline(subphase_id=_sid("01"), title="One", objective="First."),
                ),
                integration_acceptance_criteria=(
                    AcceptanceCriterion(criterion_id="IC-1", description="Integration holds."),
                ),
            ),
        ),
    )


def _contract() -> SubphaseContract:
    return SubphaseContract(
        phase_id=_pid("01"),
        subphase_id=_sid("01"),
        title="Contract",
        objective="Contract objective.",
        acceptance_criteria=(AcceptanceCriterion(criterion_id="AC-1", description="Holds."),),
        tests=(
            TestSpecification(
                path="tests/test_one.py",
                expectation=TestExpectation.RED,
                acceptance_criteria=("AC-1",),
            ),
        ),
        allowed_paths=("src/lockstep/**",),
        verification_commands=("./scripts/check",),
    )


def _roots(tmp_path: Path) -> tuple[Path, Path]:
    project_root = tmp_path / "project"
    project_root.mkdir()
    runtime_dir = tmp_path / "runtime"
    runtime_dir.mkdir()
    return project_root, runtime_dir


def _frozen_project(tmp_path: Path) -> tuple[Path, Path]:
    project_root, runtime_dir = _roots(tmp_path)
    freeze_master_plan(project_root, _plan())
    return project_root, runtime_dir


def _digest_dir(runtime_dir: Path) -> Path:
    return runtime_dir / "project" / "project-digest"


def _current_path(runtime_dir: Path) -> Path:
    return _digest_dir(runtime_dir) / "current.json"


def _history_path(runtime_dir: Path, identity: str) -> Path:
    return _digest_dir(runtime_dir) / "history" / f"{identity}.json"


def _source(
    kind: DigestSourceKind = DigestSourceKind.TRACKED_CONFIG,
    locator: str = "pyproject.toml",
    digest: str | None = None,
) -> DigestSource:
    return DigestSource(kind=kind, locator=locator, digest=digest)


def _fact(fact_id: str, statement: str, *sources: DigestSource) -> DigestFact:
    return DigestFact(fact_id=fact_id, statement=statement, sources=sources or (_source(),))


def _full_digest(
    *, previous_revision: str | None = None, marker: str = "A", project_id: str = "lockstep"
) -> ProjectDigest:
    plan_source = _source(DigestSourceKind.MASTER_PLAN, "master-plan", master_plan_digest(_plan()))
    return ProjectDigest(
        project_id=ProjectId.model_validate(project_id),
        previous_revision=previous_revision,
        architecture=(
            _fact("arch-host", f"The host owns canonical state ({marker}).", plan_source),
            _fact("arch-roles", "Planner, Implementer, and Reviewer are disposable roles."),
        ),
        module_boundaries=(
            _fact(
                "mod-domain",
                "lockstep.domain holds immutable protocol artifacts.",
                _source(DigestSourceKind.ARCHITECTURE_DOCUMENT, "README.md"),
            ),
        ),
        technology_stack=(_fact("tech-python", "Python 3.12 with Pydantic v2."),),
        standard_commands=(_fact("cmd-check", "./scripts/check-venv runs every gate."),),
        test_strategy=(_fact("test-first", "Tests are frozen before production code."),),
        git_conventions=(
            _fact(
                "git-conventional",
                "Commits use conventional-commit prefixes.",
                _source(DigestSourceKind.PROJECT_METADATA, ".git/config"),
            ),
        ),
        invariants=(
            _fact(
                "inv-authority",
                "Summarization does not increase authority.",
                _source(DigestSourceKind.PLANNER_AUTHORIZED_UPDATE, "phase-12.1"),
            ),
        ),
        architectural_constraints=(
            _fact("con-runtime", "The runtime directory lies outside the project root."),
        ),
    )


def _fail_replace(monkeypatch: pytest.MonkeyPatch, *, after: int = 0) -> None:
    """Simulate a crash at the (after+1)-th atomic publication."""
    real = project_digest_store._replace_atomically
    calls = {"count": 0}

    def maybe_fail(source: Path, target: Path) -> None:
        calls["count"] += 1
        if calls["count"] > after:
            raise OSError("simulated crash before publication")
        real(source, target)

    monkeypatch.setattr(project_digest_store, "_replace_atomically", maybe_fail)


def _no_temp_files(runtime_dir: Path) -> bool:
    return not [p for p in _digest_dir(runtime_dir).rglob("*") if p.name.endswith(".tmp")]


# ---------------------------------------------------------------------------
# Public surface
# ---------------------------------------------------------------------------


def test_public_surfaces_export_expected_names() -> None:
    assert set(project_digest.__all__) == {
        "PROJECT_DIGEST_MAX_BYTES",
        "DigestFact",
        "DigestSource",
        "DigestSourceKind",
        "ProjectDigest",
        "ProjectDigestError",
        "canonical_project_digest_bytes",
        "project_digest_identity",
    }
    assert set(project_digest_store.__all__) == {
        "ProjectDigestStoreError",
        "freeze_project_digest",
        "load_project_digest",
        "load_project_digest_revision",
    }


def test_size_ceiling_is_64_kib() -> None:
    assert PROJECT_DIGEST_MAX_BYTES == 64 * 1024


# ---------------------------------------------------------------------------
# A -- Structured round-trip (AC-01, AC-02, AC-03)
# ---------------------------------------------------------------------------


def test_A_every_stable_category_round_trips_through_persistence(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    digest = _full_digest()

    for section in _SECTIONS:
        assert getattr(digest, section), section

    identity = freeze_project_digest(project_root, runtime_dir, digest)
    loaded = load_project_digest(project_root, runtime_dir)

    assert loaded == digest
    assert identity == project_digest_identity(digest)
    assert loaded is not None and loaded.schema_version.root == 1
    assert loaded.project_id.root == "lockstep"


def test_A_model_is_structured_frozen_and_rejects_unknown_fields() -> None:
    digest = _full_digest()
    with pytest.raises(ValidationError):
        digest.architecture = ()  # type: ignore[misc]

    data = digest.model_dump(mode="json")
    data["notes"] = "arbitrary prose"
    with pytest.raises(ValidationError):
        ProjectDigest.model_validate(data)


def test_A_unsupported_schema_version_is_rejected() -> None:
    data = _full_digest().model_dump(mode="json")
    data["schema_version"] = 2
    with pytest.raises(ValidationError):
        ProjectDigest.model_validate(data)


def test_A_duplicate_fact_ids_are_rejected_even_across_sections() -> None:
    with pytest.raises(ValidationError):
        ProjectDigest(
            project_id=ProjectId.model_validate("lockstep"),
            architecture=(_fact("same", "One."),),
            invariants=(_fact("same", "Two."),),
        )


def test_A_blank_statements_are_rejected() -> None:
    with pytest.raises(ValidationError):
        _fact("blank", "   ")


# ---------------------------------------------------------------------------
# B -- Canonical bytes (AC-04)
# ---------------------------------------------------------------------------


def test_B_insertion_order_does_not_change_canonical_bytes_or_identity() -> None:
    first = _full_digest()

    data = first.model_dump(mode="json")
    reordered = {key: data[key] for key in reversed(list(data))}
    for section in _SECTIONS:
        facts = list(reversed(reordered[section]))
        for fact in facts:
            fact["sources"] = list(reversed(fact["sources"]))
            for i, src in enumerate(fact["sources"]):
                fact["sources"][i] = {key: src[key] for key in reversed(list(src))}
        reordered[section] = [{key: f[key] for key in reversed(list(f))} for f in facts]
    second = ProjectDigest.model_validate(reordered)

    assert second == first
    assert canonical_project_digest_bytes(second) == canonical_project_digest_bytes(first)
    assert project_digest_identity(second) == project_digest_identity(first)


def test_B_fact_and_source_order_are_canonicalized() -> None:
    a = _source(DigestSourceKind.TRACKED_CONFIG, "a.toml")
    b = _source(DigestSourceKind.ARCHITECTURE_DOCUMENT, "b.md")
    one = ProjectDigest(
        project_id=ProjectId.model_validate("lockstep"),
        invariants=(_fact("z", "Zed.", a, b), _fact("a", "Ay.")),
    )
    two = ProjectDigest(
        project_id=ProjectId.model_validate("lockstep"),
        invariants=(_fact("a", "Ay."), _fact("z", "Zed.", b, a)),
    )
    assert canonical_project_digest_bytes(one) == canonical_project_digest_bytes(two)


def test_B_identity_is_sha256_of_canonical_json_excluding_storage_newline() -> None:
    digest = _full_digest()
    raw = canonical_project_digest_bytes(digest)

    assert raw.endswith(b"\n") and not raw.endswith(b"\n\n")
    assert project_digest_identity(digest) == hashlib.sha256(raw[:-1]).hexdigest()
    expected = json.dumps(
        digest.model_dump(mode="json"), ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    assert raw == (expected + "\n").encode("utf-8")


def test_B_different_content_has_different_identity() -> None:
    assert project_digest_identity(_full_digest(marker="A")) != project_digest_identity(
        _full_digest(marker="B")
    )


# ---------------------------------------------------------------------------
# C -- Restart reconstruction (AC-08)
# ---------------------------------------------------------------------------


def test_C_restart_reconstructs_from_disk_alone(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    identity = freeze_project_digest(project_root, runtime_dir, _full_digest())
    expected_bytes = canonical_project_digest_bytes(_full_digest())

    # Nothing in memory survives: reload by path only.
    reloaded = load_project_digest(Path(str(project_root)), Path(str(runtime_dir)))

    assert reloaded is not None
    assert canonical_project_digest_bytes(reloaded) == expected_bytes
    assert project_digest_identity(reloaded) == identity
    assert _history_path(runtime_dir, identity).read_bytes() == expected_bytes


def test_C_persisted_artifacts_carry_no_provider_session_state(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    freeze_project_digest(project_root, runtime_dir, _full_digest())

    for path in _digest_dir(runtime_dir).rglob("*.json"):
        text = path.read_text(encoding="utf-8").lower()
        assert "session" not in text
        assert "provider" not in text


def test_C_provider_session_is_not_an_accepted_source_kind() -> None:
    assert {kind.value for kind in DigestSourceKind} == {
        "tracked_config",
        "master_plan",
        "architecture_document",
        "project_metadata",
        "prior_digest_revision",
        "planner_authorized_update",
    }
    with pytest.raises(ValidationError):
        DigestSource.model_validate({"kind": "provider_session", "locator": "sess-123"})


# ---------------------------------------------------------------------------
# D -- Immutable history (AC-05)
# ---------------------------------------------------------------------------


def test_D_new_revision_keeps_previous_history_unchanged(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    a = _full_digest(marker="A")
    id_a = freeze_project_digest(project_root, runtime_dir, a)
    a_bytes = _history_path(runtime_dir, id_a).read_bytes()

    b = _full_digest(marker="B", previous_revision=id_a)
    id_b = freeze_project_digest(project_root, runtime_dir, b)

    assert id_a != id_b
    assert _history_path(runtime_dir, id_a).read_bytes() == a_bytes
    assert _history_path(runtime_dir, id_b).exists()
    assert load_project_digest(project_root, runtime_dir) == b
    assert load_project_digest_revision(project_root, runtime_dir, id_a) == a
    assert load_project_digest_revision(project_root, runtime_dir, id_b) == b


def test_D_revision_must_name_the_current_revision_as_its_parent(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    id_a = freeze_project_digest(project_root, runtime_dir, _full_digest(marker="A"))
    before = _current_path(runtime_dir).read_bytes()

    with pytest.raises(ProjectDigestStoreError):
        freeze_project_digest(project_root, runtime_dir, _full_digest(marker="B"))
    with pytest.raises(ProjectDigestStoreError):
        freeze_project_digest(
            project_root, runtime_dir, _full_digest(marker="B", previous_revision="0" * 64)
        )

    assert _current_path(runtime_dir).read_bytes() == before
    assert load_project_digest(project_root, runtime_dir) == _full_digest(marker="A")
    assert sorted(p.stem for p in (_digest_dir(runtime_dir) / "history").iterdir()) == [id_a]


def test_D_first_revision_must_not_claim_a_parent(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    with pytest.raises(ProjectDigestStoreError):
        freeze_project_digest(project_root, runtime_dir, _full_digest(previous_revision="a" * 64))
    assert not _current_path(runtime_dir).exists()


def test_D_tampered_history_fails_closed(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    identity = freeze_project_digest(project_root, runtime_dir, _full_digest())
    path = _history_path(runtime_dir, identity)
    data = json.loads(path.read_bytes())
    data["technology_stack"][0]["statement"] = "Rewritten in place."
    path.write_text(json.dumps(data, sort_keys=True, separators=(",", ":")) + "\n")

    with pytest.raises(ProjectDigestStoreError):
        load_project_digest(project_root, runtime_dir)
    with pytest.raises(ProjectDigestStoreError):
        load_project_digest_revision(project_root, runtime_dir, identity)


def test_D_unknown_revision_is_absent_and_malformed_revision_is_rejected(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    freeze_project_digest(project_root, runtime_dir, _full_digest())

    assert load_project_digest_revision(project_root, runtime_dir, "f" * 64) is None
    with pytest.raises(ProjectDigestStoreError):
        load_project_digest_revision(project_root, runtime_dir, "../escape")


# ---------------------------------------------------------------------------
# E -- Idempotent identical freeze (AC-06)
# ---------------------------------------------------------------------------


def test_E_freezing_identical_content_twice_is_idempotent(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    first = freeze_project_digest(project_root, runtime_dir, _full_digest())
    current_before = _current_path(runtime_dir).read_bytes()
    mtime_before = _current_path(runtime_dir).stat().st_mtime_ns

    second = freeze_project_digest(project_root, runtime_dir, _full_digest())

    assert second == first
    assert _current_path(runtime_dir).read_bytes() == current_before
    assert _current_path(runtime_dir).stat().st_mtime_ns == mtime_before
    assert [p.stem for p in (_digest_dir(runtime_dir) / "history").iterdir()] == [first]
    assert load_project_digest(project_root, runtime_dir) == _full_digest()


# ---------------------------------------------------------------------------
# F -- Crash / atomicity (AC-07)
# ---------------------------------------------------------------------------


def test_F_crash_before_any_publication_leaves_previous_digest(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    id_a = freeze_project_digest(project_root, runtime_dir, _full_digest(marker="A"))
    before = _current_path(runtime_dir).read_bytes()

    _fail_replace(monkeypatch)
    with pytest.raises(ProjectDigestStoreError):
        freeze_project_digest(
            project_root, runtime_dir, _full_digest(marker="B", previous_revision=id_a)
        )
    monkeypatch.undo()

    assert _current_path(runtime_dir).read_bytes() == before
    assert load_project_digest(project_root, runtime_dir) == _full_digest(marker="A")
    assert _no_temp_files(runtime_dir)


def test_F_crash_between_history_and_current_leaves_previous_digest_then_retry_succeeds(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    id_a = freeze_project_digest(project_root, runtime_dir, _full_digest(marker="A"))
    b = _full_digest(marker="B", previous_revision=id_a)
    id_b = project_digest_identity(b)

    _fail_replace(monkeypatch, after=1)  # history publishes, current does not
    with pytest.raises(ProjectDigestStoreError):
        freeze_project_digest(project_root, runtime_dir, b)
    monkeypatch.undo()

    assert _history_path(runtime_dir, id_b).exists()
    assert load_project_digest(project_root, runtime_dir) == _full_digest(marker="A")
    assert _no_temp_files(runtime_dir)

    assert freeze_project_digest(project_root, runtime_dir, b) == id_b
    assert load_project_digest(project_root, runtime_dir) == b


def test_F_crash_during_first_freeze_leaves_explicit_absence(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)

    _fail_replace(monkeypatch, after=1)
    with pytest.raises(ProjectDigestStoreError):
        freeze_project_digest(project_root, runtime_dir, _full_digest())
    monkeypatch.undo()

    # Orphan history without current.json is not authority.
    assert not _current_path(runtime_dir).exists()
    assert load_project_digest(project_root, runtime_dir) is None


# ---------------------------------------------------------------------------
# G -- Oversize rejection (AC-09)
# ---------------------------------------------------------------------------


def _oversized(previous_revision: str | None = None) -> ProjectDigest:
    return ProjectDigest(
        project_id=ProjectId.model_validate("lockstep"),
        previous_revision=previous_revision,
        invariants=tuple(_fact(f"inv-{i:04d}", "x" * 1000) for i in range(80)),
    )


def test_G_oversized_candidate_is_rejected_without_truncation(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    id_a = freeze_project_digest(project_root, runtime_dir, _full_digest())
    before = _current_path(runtime_dir).read_bytes()
    history_before = sorted((_digest_dir(runtime_dir) / "history").iterdir())

    with pytest.raises(ProjectDigestError) as first:
        freeze_project_digest(project_root, runtime_dir, _oversized(id_a))
    with pytest.raises(ProjectDigestError) as second:
        freeze_project_digest(project_root, runtime_dir, _oversized(id_a))

    assert first.value.reason == second.value.reason
    assert _current_path(runtime_dir).read_bytes() == before
    assert sorted((_digest_dir(runtime_dir) / "history").iterdir()) == history_before
    assert load_project_digest(project_root, runtime_dir) == _full_digest()


def test_G_canonical_serialization_refuses_oversize() -> None:
    with pytest.raises(ProjectDigestError):
        canonical_project_digest_bytes(_oversized())


def test_G_ceiling_is_inclusive_of_exactly_the_limit() -> None:
    base = ProjectDigest(
        project_id=ProjectId.model_validate("lockstep"),
        invariants=(_fact("inv", "x"),),
    )
    room = PROJECT_DIGEST_MAX_BYTES - len(canonical_project_digest_bytes(base))
    at_limit = ProjectDigest(
        project_id=ProjectId.model_validate("lockstep"),
        invariants=(_fact("inv", "x" * (1 + room)),),
    )
    assert len(canonical_project_digest_bytes(at_limit)) == PROJECT_DIGEST_MAX_BYTES

    over = ProjectDigest(
        project_id=ProjectId.model_validate("lockstep"),
        invariants=(_fact("inv", "x" * (2 + room)),),
    )
    with pytest.raises(ProjectDigestError):
        canonical_project_digest_bytes(over)


# ---------------------------------------------------------------------------
# H -- Corrupt canonical state (AC-10)
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "payload",
    [b"", b"{not json", b"\xff\xfe", b'{"schema_version":1}\n', b'{"revision":"zz"}\n'],
)
def test_H_malformed_current_fails_closed(tmp_path: Path, payload: bytes) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    freeze_project_digest(project_root, runtime_dir, _full_digest())
    _current_path(runtime_dir).write_bytes(payload)

    with pytest.raises(ProjectDigestStoreError):
        load_project_digest(project_root, runtime_dir)


def test_H_current_naming_missing_history_fails_closed(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    identity = freeze_project_digest(project_root, runtime_dir, _full_digest())
    _history_path(runtime_dir, identity).unlink()

    with pytest.raises(ProjectDigestStoreError):
        load_project_digest(project_root, runtime_dir)
    with pytest.raises(ProjectDigestStoreError):
        freeze_project_digest(project_root, runtime_dir, _full_digest())


def test_H_non_canonical_history_bytes_fail_closed(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    identity = freeze_project_digest(project_root, runtime_dir, _full_digest())
    path = _history_path(runtime_dir, identity)
    path.write_text(json.dumps(json.loads(path.read_bytes()), indent=2) + "\n")

    with pytest.raises(ProjectDigestStoreError):
        load_project_digest(project_root, runtime_dir)


def test_H_corrupt_state_is_never_repaired_by_load(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    freeze_project_digest(project_root, runtime_dir, _full_digest())
    _current_path(runtime_dir).write_bytes(b"{not json")

    with pytest.raises(ProjectDigestStoreError):
        load_project_digest(project_root, runtime_dir)
    assert _current_path(runtime_dir).read_bytes() == b"{not json"


def test_H_symlinked_managed_paths_are_rejected(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    elsewhere = tmp_path / "elsewhere"
    elsewhere.mkdir()
    (runtime_dir / "project").mkdir()
    _digest_dir(runtime_dir).symlink_to(elsewhere, target_is_directory=True)

    with pytest.raises(ProjectDigestStoreError):
        freeze_project_digest(project_root, runtime_dir, _full_digest())
    with pytest.raises(ProjectDigestStoreError):
        load_project_digest(project_root, runtime_dir)
    assert not any(elsewhere.iterdir())


# ---------------------------------------------------------------------------
# I -- Missing Digest (AC-10)
# ---------------------------------------------------------------------------


def test_I_missing_digest_is_explicit_absence_and_creates_nothing(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)

    assert load_project_digest(project_root, runtime_dir) is None
    assert not _digest_dir(runtime_dir).exists()
    assert not (runtime_dir / "project").exists()


def test_I_freeze_requires_a_frozen_master_plan(tmp_path: Path) -> None:
    project_root, runtime_dir = _roots(tmp_path)
    with pytest.raises(ProjectDigestStoreError):
        freeze_project_digest(project_root, runtime_dir, _full_digest())
    assert not _digest_dir(runtime_dir).exists()


# ---------------------------------------------------------------------------
# J -- Authority separation (AC-12)
# ---------------------------------------------------------------------------


def _with_cursor_and_contract(tmp_path: Path) -> tuple[Path, Path]:
    project_root, runtime_dir = _frozen_project(tmp_path)
    publish_phase_plan(project_root, runtime_dir, _plan().phases[0])
    freeze_subphase_contract(project_root, runtime_dir, _contract())
    initialize_project_cursor(project_root, runtime_dir)
    bind_frozen_contract(project_root, runtime_dir, transaction_run_id=RunId.model_validate("r1"))
    return project_root, runtime_dir


def test_J_persisting_a_digest_changes_no_execution_authority(tmp_path: Path) -> None:
    project_root, runtime_dir = _with_cursor_and_contract(tmp_path)

    def authority_snapshot() -> dict[str, bytes]:
        files = [
            *(project_root / ".lockstep").rglob("*"),
            *(p for p in runtime_dir.rglob("*") if "project-digest" not in p.parts),
        ]
        return {str(p): p.read_bytes() for p in files if p.is_file()}

    before = authority_snapshot()
    plan_before = load_frozen_master_plan(project_root)
    cursor_before = load_project_cursor(project_root, runtime_dir)
    contract_before = load_active_subphase_contract(project_root, runtime_dir)
    assert contract_before is not None
    digest_before = contract_digest(contract_before)

    freeze_project_digest(project_root, runtime_dir, _full_digest())

    assert authority_snapshot() == before
    assert load_frozen_master_plan(project_root) == plan_before
    assert load_project_cursor(project_root, runtime_dir) == cursor_before
    contract_after = load_active_subphase_contract(project_root, runtime_dir)
    assert contract_after == contract_before
    assert contract_after is not None
    assert contract_digest(contract_after) == digest_before
    assert contract_after.allowed_paths == ("src/lockstep/**",)
    assert [c.criterion_id for c in contract_after.acceptance_criteria] == ["AC-1"]


@pytest.mark.parametrize(
    "field",
    [
        "allowed_paths",
        "protected_paths",
        "forbidden_paths",
        "acceptance_criteria",
        "tests",
        "verification_commands",
        "phases",
        "requirements",
        "dependencies",
        "contract",
        "active_contract",
    ],
)
def test_J_digest_cannot_represent_execution_authority(field: str) -> None:
    data = _full_digest().model_dump(mode="json")
    data[field] = ["src/**"]
    with pytest.raises(ValidationError):
        ProjectDigest.model_validate(data)


def test_J_citing_a_master_plan_that_is_not_the_frozen_one_fails_closed(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    stale = _source(DigestSourceKind.MASTER_PLAN, "master-plan", "0" * 64)
    candidate = ProjectDigest(
        project_id=ProjectId.model_validate("lockstep"),
        architecture=(_fact("arch", "Conflicting summary.", stale),),
    )

    with pytest.raises(ProjectDigestStoreError):
        freeze_project_digest(project_root, runtime_dir, candidate)
    assert not _current_path(runtime_dir).exists()


def test_J_digest_for_a_different_project_fails_closed(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    other = ProjectDigest(
        project_id=ProjectId.model_validate("someone-else"),
        architecture=(_fact("arch", "Elsewhere."),),
    )
    with pytest.raises(ProjectDigestStoreError):
        freeze_project_digest(project_root, runtime_dir, other)
    assert not _digest_dir(runtime_dir).exists()


def test_J_persisted_digest_for_a_different_project_fails_closed_on_load(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    freeze_project_digest(project_root, runtime_dir, _full_digest())

    replacement = tmp_path / "other-project"
    replacement.mkdir()
    freeze_master_plan(replacement, _plan("someone-else"))

    with pytest.raises(ProjectDigestStoreError):
        load_project_digest(replacement, runtime_dir)


# ---------------------------------------------------------------------------
# K -- Provenance (AC-11)
# ---------------------------------------------------------------------------


def test_K_every_fact_requires_at_least_one_source() -> None:
    with pytest.raises(ValidationError):
        DigestFact(fact_id="lonely", statement="Unattributed.", sources=())


def test_K_provenance_round_trips_through_persistence(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    digest = _full_digest()
    freeze_project_digest(project_root, runtime_dir, digest)
    loaded = load_project_digest(project_root, runtime_dir)
    assert loaded is not None

    for section in _SECTIONS:
        assert [f.sources for f in getattr(loaded, section)] == [
            f.sources for f in getattr(digest, section)
        ]
    arch = {f.fact_id: f for f in loaded.architecture}
    (plan_source,) = arch["arch-host"].sources
    assert plan_source.kind is DigestSourceKind.MASTER_PLAN
    assert plan_source.digest == master_plan_digest(_plan())


def test_K_revision_sources_require_a_content_digest() -> None:
    with pytest.raises(ValidationError):
        _source(DigestSourceKind.MASTER_PLAN, "master-plan", None)
    with pytest.raises(ValidationError):
        _source(DigestSourceKind.PRIOR_DIGEST_REVISION, "project-digest", None)
    with pytest.raises(ValidationError):
        _source(DigestSourceKind.TRACKED_CONFIG, "pyproject.toml", "not-a-digest")


@pytest.mark.parametrize("locator", ["/etc/passwd", "../sibling/README.md", "a/../../b", "x\ny"])
def test_K_source_locators_are_project_relative(locator: str) -> None:
    with pytest.raises(ValidationError):
        _source(DigestSourceKind.ARCHITECTURE_DOCUMENT, locator)


def test_K_prior_revision_source_must_name_an_accepted_revision(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    id_a = freeze_project_digest(project_root, runtime_dir, _full_digest())

    unknown = _source(DigestSourceKind.PRIOR_DIGEST_REVISION, "project-digest", "e" * 64)
    with pytest.raises(ProjectDigestStoreError):
        freeze_project_digest(
            project_root,
            runtime_dir,
            ProjectDigest(
                project_id=ProjectId.model_validate("lockstep"),
                previous_revision=id_a,
                invariants=(_fact("carried", "Carried forward.", unknown),),
            ),
        )

    known = _source(DigestSourceKind.PRIOR_DIGEST_REVISION, "project-digest", id_a)
    carried = ProjectDigest(
        project_id=ProjectId.model_validate("lockstep"),
        previous_revision=id_a,
        invariants=(_fact("carried", "Carried forward.", known),),
    )
    freeze_project_digest(project_root, runtime_dir, carried)
    assert load_project_digest(project_root, runtime_dir) == carried


# ---------------------------------------------------------------------------
# L -- Canonical destination (AC-03)
# ---------------------------------------------------------------------------


def test_L_all_persistence_is_under_runtime_project_digest(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    project_files_before = {p for p in project_root.rglob("*") if p.is_file()}
    outside_before = {p for p in tmp_path.rglob("*") if runtime_dir not in p.parents}

    id_a = freeze_project_digest(project_root, runtime_dir, _full_digest(marker="A"))
    id_b = freeze_project_digest(
        project_root, runtime_dir, _full_digest(marker="B", previous_revision=id_a)
    )

    created = {p.relative_to(runtime_dir).as_posix() for p in runtime_dir.rglob("*") if p.is_file()}
    assert created == {
        "project/project-digest/current.json",
        f"project/project-digest/history/{id_a}.json",
        f"project/project-digest/history/{id_b}.json",
    }
    assert {p for p in project_root.rglob("*") if p.is_file()} == project_files_before
    assert {p for p in tmp_path.rglob("*") if runtime_dir not in p.parents} == outside_before


def test_L_current_is_a_canonical_pointer_to_history(tmp_path: Path) -> None:
    project_root, runtime_dir = _frozen_project(tmp_path)
    identity = freeze_project_digest(project_root, runtime_dir, _full_digest())

    raw = _current_path(runtime_dir).read_bytes()
    assert raw.endswith(b"\n")
    assert json.loads(raw) == {"revision": identity, "schema_version": 1}


def test_L_runtime_inside_project_root_is_rejected(tmp_path: Path) -> None:
    project_root, _ = _frozen_project(tmp_path)
    nested = project_root / "runtime"
    with pytest.raises(ProjectDigestStoreError):
        freeze_project_digest(project_root, nested, _full_digest())
    with pytest.raises(ProjectDigestStoreError):
        load_project_digest(project_root, nested)
    assert not nested.exists()


# ---------------------------------------------------------------------------
# M / N -- Boundaries and regression guards (AC-13..AC-16)
# ---------------------------------------------------------------------------

_FORBIDDEN_IMPORT_PREFIXES = (
    "lockstep.agents",
    "lockstep.autonomous_run",
    "lockstep.cli",
    "lockstep.handoff",
    "lockstep.metrics",
    "lockstep.process",
    "lockstep.project_orchestrator",
    "lockstep.reporting",
    "lockstep.supervisor",
)


def _imported_modules(module: object) -> set[str]:
    tree = ast.parse(inspect.getsource(module))  # type: ignore[arg-type]
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            names.add(node.module)
    return names


@pytest.mark.parametrize("module", [project_digest, project_digest_store])
def test_MN_digest_modules_do_not_reach_into_orchestration_or_providers(module: object) -> None:
    for name in _imported_modules(module):
        assert not name.startswith(_FORBIDDEN_IMPORT_PREFIXES), name


# Corrected by Planner ruling (12.2): ProjectDigest semantics belong to the common
# context subsystem only. Outside `lockstep/context/` nothing may name them; inside
# it, only this explicit allowlist may (new context modules are not admitted
# automatically). Orchestration, adapters, turn layers, CLI and runtime reach the
# Digest only through the provider-neutral ContextPack API.
_DIGEST_AWARE_MODULES = frozenset(
    {
        "context/project_digest.py",
        "context/project_digest_store.py",
        "context/context_pack.py",
        "context/context_pack_builder.py",
    }
)


def test_MN_no_prompt_or_cli_integration_is_pulled_forward() -> None:
    src = Path(project_digest.__file__).resolve().parents[1]
    for path in src.rglob("*.py"):
        if path.resolve().relative_to(src).as_posix() in _DIGEST_AWARE_MODULES:
            continue
        text = path.read_text(encoding="utf-8")
        assert "project_digest" not in text, path
        assert "ProjectDigest" not in text, path


def test_MN_phase10_transaction_baseline_v1_is_unchanged() -> None:
    baseline = Path(__file__).parent / "baselines" / "transaction_baseline.json"
    assert json.loads(baseline.read_text(encoding="utf-8"))["baseline_version"] == 1
    assert (
        hashlib.sha256(baseline.read_bytes()).hexdigest()
        == "30d05f1e482ef339a922ccbd5f787fba8379c715d19b5b954a7d19d8a3e29532"
    )
