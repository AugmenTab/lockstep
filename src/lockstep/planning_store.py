"""Durable persistence and freeze semantics for Lockstep planning artifacts.

Gives the validated Phase-1/8.1 planning artifacts an explicit durable
lifecycle. A candidate :class:`~lockstep.domain.MasterPlan` becomes the
project's canonical Master Plan only through an explicit
:func:`freeze_master_plan` call, stored beneath the project-owned
``.lockstep/project/`` subtree alongside a deterministic derived Markdown
rendering. A :class:`~lockstep.domain.PhasePlan` is durable but remains
provisional runtime planning state in the external runtime directory
until a :class:`~lockstep.domain.SubphaseContract` is frozen against it,
at which point the Phase outline may no longer change. Exactly one
active Contract may exist at a time, and once frozen it is immutable;
this module implements no API for editing, replacing, or archiving it.

This module performs no Planner invocation, no provider or model
inference, no orchestration transaction, and no Git mutation: it is
persistence and freeze semantics only, built strictly on top of
:mod:`lockstep.domain` and the pure semantic validation in
:mod:`lockstep.planning`. Every managed write goes through a
same-directory temporary file, ``fsync``, ``os.replace``, and a parent
directory ``fsync`` so that a successful write is durable and a failed
write never damages a previously published artifact. Managed paths that
turn out to be symlinks are rejected outright rather than followed.
"""

from __future__ import annotations

import json
import os
import uuid
from pathlib import Path

from pydantic import BaseModel, ValidationError

from lockstep.domain import MasterPlan, PhasePlan, SubphaseContract
from lockstep.planning import (
    PlanningValidationError,
    validate_master_plan,
    validate_subphase_contract,
)

_LOCKSTEP_DIR_NAME = ".lockstep"
_PROJECT_SUBDIR_NAME = "project"
_MASTER_PLAN_JSON_NAME = "master-plan.json"
_MASTER_PLAN_MD_NAME = "master-plan.md"

_PLANNING_SUBDIR_NAME = "planning"
_PHASE_PLAN_JSON_NAME = "phase-plan.json"

_CONTRACTS_SUBDIR_NAME = "contracts"
_ACTIVE_CONTRACT_JSON_NAME = "active.json"


class PlanningStoreError(Exception):
    """A planning artifact could not be durably persisted, frozen, or loaded.

    Carries a short, bounded, deterministic ``reason`` that may name a
    safe canonical artifact name (``master-plan.json``, ``phase-plan.json``,
    ``active contract``) but never a raw file content excerpt, a full JSON
    dump, prompt text, or a credential or environment value. The optional
    ``path`` attribute identifies the artifact path involved, when one is
    relevant.

    Owns filesystem failures, malformed persisted JSON, artifact pair
    integrity mismatches, freeze conflicts, and unsafe storage locations.
    It never wraps :class:`~lockstep.planning.PlanningValidationError`,
    which remains the exact exception 8.1 semantic validation raises.
    """

    def __init__(self, reason: str, *, path: Path | None = None) -> None:
        self.reason = reason
        self.path = path
        super().__init__(f"planning store error: {reason}")


# --- Path resolution and layout -------------------------------------------


def _resolve(path: Path) -> Path:
    return Path(path).resolve()


def _project_planning_dir(project_root: Path) -> Path:
    return project_root / _LOCKSTEP_DIR_NAME / _PROJECT_SUBDIR_NAME


def _master_plan_json_path(project_root: Path) -> Path:
    return _project_planning_dir(project_root) / _MASTER_PLAN_JSON_NAME


def _master_plan_md_path(project_root: Path) -> Path:
    return _project_planning_dir(project_root) / _MASTER_PLAN_MD_NAME


def _runtime_planning_dir(runtime_dir: Path) -> Path:
    return runtime_dir / _PLANNING_SUBDIR_NAME


def _phase_plan_json_path(runtime_dir: Path) -> Path:
    return _runtime_planning_dir(runtime_dir) / _PHASE_PLAN_JSON_NAME


def _runtime_contracts_dir(runtime_dir: Path) -> Path:
    return runtime_dir / _CONTRACTS_SUBDIR_NAME


def _active_contract_json_path(runtime_dir: Path) -> Path:
    return _runtime_contracts_dir(runtime_dir) / _ACTIVE_CONTRACT_JSON_NAME


def _require_external_runtime(project_root: Path, runtime_dir: Path) -> None:
    resolved_project = _resolve(project_root)
    resolved_runtime = _resolve(runtime_dir)

    if resolved_runtime == resolved_project:
        raise PlanningStoreError("runtime directory must be outside project root")

    try:
        resolved_runtime.relative_to(resolved_project)
    except ValueError:
        return
    raise PlanningStoreError("runtime directory must be outside project root")


def _reject_symlink(path: Path, artifact_name: str) -> None:
    if path.is_symlink():
        raise PlanningStoreError(f"{artifact_name} must not be a symlink", path=path)


def _check_master_plan_symlinks(project_root: Path) -> None:
    _reject_symlink(project_root / _LOCKSTEP_DIR_NAME, ".lockstep directory")
    _reject_symlink(_project_planning_dir(project_root), ".lockstep/project directory")
    _reject_symlink(_master_plan_json_path(project_root), _MASTER_PLAN_JSON_NAME)
    _reject_symlink(_master_plan_md_path(project_root), _MASTER_PLAN_MD_NAME)


def _check_phase_plan_symlinks(runtime_dir: Path) -> None:
    _reject_symlink(_runtime_planning_dir(runtime_dir), "planning directory")
    _reject_symlink(_phase_plan_json_path(runtime_dir), _PHASE_PLAN_JSON_NAME)


def _check_active_contract_symlinks(runtime_dir: Path) -> None:
    _reject_symlink(_runtime_contracts_dir(runtime_dir), "contracts directory")
    _reject_symlink(_active_contract_json_path(runtime_dir), "active contract")


# --- Canonical serialization and atomic publication ------------------------


def _canonical_json_bytes(model: BaseModel) -> bytes:
    text = json.dumps(model.model_dump(mode="json"), ensure_ascii=False, separators=(",", ":"))
    return (text + "\n").encode("utf-8")


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _atomic_write_bytes(path: Path, payload: bytes, *, artifact_name: str) -> None:
    parent = path.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise PlanningStoreError(
            f"cannot create directory for {artifact_name}", path=parent
        ) from exc

    temp_path = parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    try:
        try:
            fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except OSError as exc:
            raise PlanningStoreError(
                f"cannot create temporary file for {artifact_name}", path=temp_path
            ) from exc

        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as exc:
            raise PlanningStoreError(
                f"cannot write temporary file for {artifact_name}", path=temp_path
            ) from exc

        try:
            os.replace(temp_path, path)
        except OSError as exc:
            raise PlanningStoreError(f"cannot publish {artifact_name}", path=path) from exc

        try:
            _fsync_directory(parent)
        except OSError as exc:
            raise PlanningStoreError(
                f"cannot fsync directory for {artifact_name}", path=parent
            ) from exc
    except BaseException:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass
        raise


def _read_utf8(path: Path, *, artifact_name: str) -> str:
    try:
        raw = path.read_bytes()
    except OSError as exc:
        raise PlanningStoreError(f"cannot read {artifact_name}", path=path) from exc
    try:
        return raw.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise PlanningStoreError(f"{artifact_name} is not valid UTF-8", path=path) from exc


def _hydrate_json_model[ModelT: BaseModel](
    text: str, model_cls: type[ModelT], *, artifact_name: str, path: Path
) -> ModelT:
    try:
        raw = json.loads(text)
    except json.JSONDecodeError as exc:
        raise PlanningStoreError(f"{artifact_name} is malformed JSON", path=path) from exc
    try:
        return model_cls.model_validate(raw)
    except ValidationError as exc:
        raise PlanningStoreError(
            f"{artifact_name} does not match the expected schema", path=path
        ) from exc


# --- Deterministic Master Plan Markdown -------------------------------------


def _format_dependency_list(ids: tuple[str, ...]) -> str:
    return ", ".join(ids) if ids else "(none)"


def _render_master_plan_markdown(plan: MasterPlan) -> str:
    lines: list[str] = [
        f"# {plan.title}",
        "",
        f"Project: {plan.project_id.root}",
        "",
        plan.objective,
    ]

    for phase in plan.phases:
        lines.append("")
        lines.append(f"## Phase {phase.phase_id.root}: {phase.title}")
        lines.append("")
        lines.append(phase.objective)
        lines.append("")
        lines.append(
            f"Depends on: {_format_dependency_list(tuple(dep.root for dep in phase.depends_on))}"
        )

        if phase.subphases:
            lines.append("")
            lines.append("### Sub-phases")
            for subphase in phase.subphases:
                lines.append("")
                lines.append(f"- {subphase.subphase_id.root}: {subphase.title}")
                lines.append(f"  {subphase.objective}")
                sub_deps = _format_dependency_list(tuple(dep.root for dep in subphase.depends_on))
                lines.append(f"  Depends on: {sub_deps}")

        if phase.integration_acceptance_criteria:
            lines.append("")
            lines.append("### Integration Acceptance Criteria")
            for criterion in phase.integration_acceptance_criteria:
                lines.append("")
                lines.append(f"- {criterion.criterion_id}: {criterion.description}")

    return "\n".join(lines) + "\n"


# --- Master Plan freeze / load ----------------------------------------------


def _load_master_plan_pair(json_path: Path, md_path: Path) -> MasterPlan:
    json_text = _read_utf8(json_path, artifact_name=_MASTER_PLAN_JSON_NAME)
    plan = _hydrate_json_model(
        json_text, MasterPlan, artifact_name=_MASTER_PLAN_JSON_NAME, path=json_path
    )
    validate_master_plan(plan)

    md_text = _read_utf8(md_path, artifact_name=_MASTER_PLAN_MD_NAME)
    expected_md = _render_master_plan_markdown(plan)
    if md_text != expected_md:
        raise PlanningStoreError("master-plan.md does not match master-plan.json", path=md_path)

    return plan


def freeze_master_plan(project_root: Path, plan: MasterPlan) -> None:
    """Freeze *plan* as the project's canonical Master Plan.

    Requires :func:`~lockstep.planning.validate_master_plan` to succeed
    on *plan* before any filesystem access; an invalid candidate produces
    zero side effects and the exact
    :class:`~lockstep.planning.PlanningValidationError` propagates.

    If no canonical ``master-plan.json`` exists yet, publishes a
    deterministic ``master-plan.md`` rendering followed by the canonical
    ``master-plan.json`` (the commit marker for a completed freeze); a
    stale orphan Markdown file with no canonical JSON is replaced rather
    than treated as already frozen. If a canonical pair already exists,
    an equal *plan* is an idempotent no-op and a different *plan* raises
    :class:`PlanningStoreError`; the Master Plan is never overwritten,
    merged, or amended.
    """
    validate_master_plan(plan)

    resolved_root = _resolve(project_root)
    _check_master_plan_symlinks(resolved_root)

    json_path = _master_plan_json_path(resolved_root)
    md_path = _master_plan_md_path(resolved_root)

    if json_path.exists():
        if not md_path.exists():
            raise PlanningStoreError("master-plan.md is missing", path=md_path)
        existing = _load_master_plan_pair(json_path, md_path)
        if existing == plan:
            return
        raise PlanningStoreError("master plan is already frozen")

    rendered_md = _render_master_plan_markdown(plan)
    _atomic_write_bytes(md_path, rendered_md.encode("utf-8"), artifact_name=_MASTER_PLAN_MD_NAME)
    _atomic_write_bytes(
        json_path, _canonical_json_bytes(plan), artifact_name=_MASTER_PLAN_JSON_NAME
    )


def load_frozen_master_plan(project_root: Path) -> MasterPlan | None:
    """Load the project's canonical Master Plan, or ``None`` if unfrozen.

    Read-only: never mutates, repairs, or regenerates artifacts. Requires
    ``master-plan.json`` and ``master-plan.md`` to either both be absent
    (returns ``None``) or both be present, hydrate, semantically validate,
    and agree with each other; any other combination raises
    :class:`PlanningStoreError`.
    """
    resolved_root = _resolve(project_root)
    _check_master_plan_symlinks(resolved_root)

    json_path = _master_plan_json_path(resolved_root)
    md_path = _master_plan_md_path(resolved_root)

    json_exists = json_path.exists()
    md_exists = md_path.exists()

    if not json_exists and not md_exists:
        return None
    if not json_exists:
        raise PlanningStoreError("master-plan.json is missing", path=json_path)
    if not md_exists:
        raise PlanningStoreError("master-plan.md is missing", path=md_path)

    return _load_master_plan_pair(json_path, md_path)


# --- Effective-plan construction (shared by Phase plan and Contract) -------


def _find_frozen_phase(frozen_plan: MasterPlan, phase_id: str) -> PhasePlan | None:
    for phase in frozen_plan.phases:
        if phase.phase_id.root == phase_id:
            return phase
    return None


def _require_phase_facts_unchanged(frozen_phase: PhasePlan, candidate: PhasePlan) -> None:
    if candidate.schema_version != frozen_phase.schema_version:
        raise PlanningValidationError(
            f"phase {candidate.phase_id.root}: schema_version must match the frozen master plan"
        )
    if candidate.title != frozen_phase.title:
        raise PlanningValidationError(
            f"phase {candidate.phase_id.root}: title must match the frozen master plan"
        )
    if candidate.objective != frozen_phase.objective:
        raise PlanningValidationError(
            f"phase {candidate.phase_id.root}: objective must match the frozen master plan"
        )
    if candidate.depends_on != frozen_phase.depends_on:
        raise PlanningValidationError(
            f"phase {candidate.phase_id.root}: depends_on must match the frozen master plan"
        )
    if candidate.integration_acceptance_criteria != frozen_phase.integration_acceptance_criteria:
        raise PlanningValidationError(
            f"phase {candidate.phase_id.root}: integration_acceptance_criteria must match "
            "the frozen master plan"
        )


def _build_effective_master_plan(frozen_plan: MasterPlan, phase_plan: PhasePlan) -> MasterPlan:
    frozen_phase = _find_frozen_phase(frozen_plan, phase_plan.phase_id.root)
    if frozen_phase is None:
        raise PlanningValidationError(f"unknown phase: {phase_plan.phase_id.root}")

    _require_phase_facts_unchanged(frozen_phase, phase_plan)

    updated_phases = tuple(
        phase_plan if phase.phase_id.root == phase_plan.phase_id.root else phase
        for phase in frozen_plan.phases
    )
    return frozen_plan.model_copy(update={"phases": updated_phases})


# --- Phase plan publication / load ------------------------------------------


def publish_phase_plan(project_root: Path, runtime_dir: Path, phase_plan: PhasePlan) -> None:
    """Publish *phase_plan* as the current durable, provisional runtime Phase plan.

    Requires a frozen Master Plan and that *phase_plan* revises only the
    ``subphases`` of one of its Phases; the effective Master Plan formed
    by substituting the revised Phase must pass
    :func:`~lockstep.planning.validate_master_plan`. Refuses to write
    while an active Sub-phase Contract exists, even for byte-identical
    content, since the Contract was frozen against the current outline.
    Otherwise a valid Phase plan atomically replaces any existing one.
    """
    _require_external_runtime(project_root, runtime_dir)
    resolved_runtime = _resolve(runtime_dir)

    frozen_plan = load_frozen_master_plan(project_root)
    if frozen_plan is None:
        raise PlanningStoreError("cannot publish a phase plan without a frozen master plan")

    effective_plan = _build_effective_master_plan(frozen_plan, phase_plan)
    validate_master_plan(effective_plan)

    _check_active_contract_symlinks(resolved_runtime)
    if _active_contract_json_path(resolved_runtime).exists():
        raise PlanningStoreError("phase plan cannot change while a subphase contract is active")

    _check_phase_plan_symlinks(resolved_runtime)
    _atomic_write_bytes(
        _phase_plan_json_path(resolved_runtime),
        _canonical_json_bytes(phase_plan),
        artifact_name=_PHASE_PLAN_JSON_NAME,
    )


def load_phase_plan(project_root: Path, runtime_dir: Path) -> PhasePlan | None:
    """Load the current durable runtime Phase plan, or ``None`` if unpublished.

    Requires a frozen Master Plan. Read-only: never repairs. Re-validates
    the loaded Phase plan against the frozen Master Plan using the same
    effective-plan logic as :func:`publish_phase_plan`, so drift beneath
    the artifact fails closed rather than being silently trusted.
    """
    _require_external_runtime(project_root, runtime_dir)
    resolved_runtime = _resolve(runtime_dir)

    frozen_plan = load_frozen_master_plan(project_root)
    if frozen_plan is None:
        raise PlanningStoreError("cannot load a phase plan without a frozen master plan")

    _check_phase_plan_symlinks(resolved_runtime)
    phase_plan_path = _phase_plan_json_path(resolved_runtime)
    if not phase_plan_path.exists():
        return None

    text = _read_utf8(phase_plan_path, artifact_name=_PHASE_PLAN_JSON_NAME)
    phase_plan = _hydrate_json_model(
        text, PhasePlan, artifact_name=_PHASE_PLAN_JSON_NAME, path=phase_plan_path
    )

    effective_plan = _build_effective_master_plan(frozen_plan, phase_plan)
    validate_master_plan(effective_plan)

    return phase_plan


# --- Sub-phase Contract freeze / load ---------------------------------------


def freeze_subphase_contract(
    project_root: Path, runtime_dir: Path, contract: SubphaseContract
) -> None:
    """Freeze *contract* as the one active, immutable Sub-phase Contract.

    Requires a frozen Master Plan and a current runtime Phase plan whose
    ``phase_id`` matches *contract*; validates *contract* against the
    effective Master Plan (the frozen Master Plan with its matching Phase
    replaced by the current runtime Phase plan) via
    :func:`~lockstep.planning.validate_subphase_contract`, so the
    Contract is checked against the current outline rather than the
    stale one nested in the frozen Master Plan. An equal already-active
    Contract is an idempotent no-op; a different one raises
    :class:`PlanningStoreError`. This module implements no API to edit,
    overwrite, or archive an active Contract.
    """
    _require_external_runtime(project_root, runtime_dir)
    resolved_runtime = _resolve(runtime_dir)

    frozen_plan = load_frozen_master_plan(project_root)
    if frozen_plan is None:
        raise PlanningStoreError("cannot freeze a contract without a frozen master plan")

    phase_plan = load_phase_plan(project_root, runtime_dir)
    if phase_plan is None:
        raise PlanningStoreError("cannot freeze contract without current phase plan")

    if contract.phase_id.root != phase_plan.phase_id.root:
        raise PlanningValidationError(
            f"contract phase {contract.phase_id.root} does not match "
            f"current phase plan {phase_plan.phase_id.root}"
        )

    effective_plan = _build_effective_master_plan(frozen_plan, phase_plan)
    validate_subphase_contract(effective_plan, contract)

    _check_active_contract_symlinks(resolved_runtime)
    active_path = _active_contract_json_path(resolved_runtime)

    if active_path.exists():
        text = _read_utf8(active_path, artifact_name=_ACTIVE_CONTRACT_JSON_NAME)
        existing = _hydrate_json_model(
            text, SubphaseContract, artifact_name=_ACTIVE_CONTRACT_JSON_NAME, path=active_path
        )
        if existing == contract:
            return
        raise PlanningStoreError("a subphase contract is already active")

    _atomic_write_bytes(
        active_path, _canonical_json_bytes(contract), artifact_name=_ACTIVE_CONTRACT_JSON_NAME
    )


def load_active_subphase_contract(project_root: Path, runtime_dir: Path) -> SubphaseContract | None:
    """Load the active Sub-phase Contract, or ``None`` if none is frozen.

    Read-only: never repairs. Also loads and validates the frozen Master
    Plan and current Phase plan beneath the Contract, and re-validates
    the Contract against the effective Master Plan; a missing or
    no-longer-valid Phase plan, or a Contract that no longer validates,
    fails closed rather than treating the Contract as self-sufficient.
    """
    _require_external_runtime(project_root, runtime_dir)
    resolved_runtime = _resolve(runtime_dir)

    _check_active_contract_symlinks(resolved_runtime)
    active_path = _active_contract_json_path(resolved_runtime)
    if not active_path.exists():
        return None

    frozen_plan = load_frozen_master_plan(project_root)
    if frozen_plan is None:
        raise PlanningStoreError("cannot load active contract without a frozen master plan")

    phase_plan = load_phase_plan(project_root, runtime_dir)
    if phase_plan is None:
        raise PlanningStoreError("cannot load active contract without current phase plan")

    text = _read_utf8(active_path, artifact_name=_ACTIVE_CONTRACT_JSON_NAME)
    contract = _hydrate_json_model(
        text, SubphaseContract, artifact_name=_ACTIVE_CONTRACT_JSON_NAME, path=active_path
    )

    if contract.phase_id.root != phase_plan.phase_id.root:
        raise PlanningValidationError(
            f"contract phase {contract.phase_id.root} does not match "
            f"current phase plan {phase_plan.phase_id.root}"
        )

    effective_plan = _build_effective_master_plan(frozen_plan, phase_plan)
    validate_subphase_contract(effective_plan, contract)

    return contract


__all__ = [
    "PlanningStoreError",
    "freeze_master_plan",
    "freeze_subphase_contract",
    "load_active_subphase_contract",
    "load_frozen_master_plan",
    "load_phase_plan",
    "publish_phase_plan",
]
