"""Durable, host-owned persistence for the Project Digest (Phase 12.1).

The Project Digest lives in exactly one canonical place, the project-state
area of the runtime directory::

    <runtime_dir>/project/project-digest/
        current.json              pointer to the accepted revision
        history/<identity>.json   immutable canonical revisions

A revision file holds the exact canonical bytes of a
:class:`~lockstep.context.project_digest.ProjectDigest` and is named by its
content identity; it is written once and never overwritten. ``current.json``
is a small canonical pointer naming one revision. A freeze publishes the
history file first and the pointer last, each through a same-directory
temporary file, ``fsync``, ``os.replace``, and a parent-directory ``fsync``,
so after any crash a reader sees either the previous accepted Digest or the
new one -- never partial JSON and never a pointer to a missing revision. A
history file without a pointer naming it is not authority: it is either an
earlier revision or the leftover of an interrupted freeze, which re-running
the same freeze completes.

Only this module writes canonical Digest state; an agent may propose a
Digest, but it becomes canonical only through :func:`freeze_project_digest`.
Freezing is an explicit operation and nothing here runs automatically.

The Digest is bound to the frozen Master Plan (:mod:`lockstep.planning_store`)
by project identity, and every fact source that cites a Master Plan revision
must cite the frozen one; disagreement fails closed. This module reads the
Master Plan and never writes it, the project cursor, a Contract, or any
transaction journal, so persisting a Digest changes no execution authority.
Writers are assumed single-process; no cross-process lock is taken.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import uuid
from pathlib import Path
from typing import Annotated

from pydantic import BaseModel, ConfigDict, StringConstraints, ValidationError

from lockstep.context.project_digest import (
    DigestSourceKind,
    ProjectDigest,
    ProjectDigestError,
    canonical_project_digest_bytes,
    project_digest_identity,
)
from lockstep.domain import SchemaVersion
from lockstep.planning_store import load_frozen_master_plan
from lockstep.project_cursor import master_plan_digest

_PROJECT_SUBDIR_NAME = "project"
_DIGEST_SUBDIR_NAME = "project-digest"
_CURRENT_JSON_NAME = "current.json"
_HISTORY_SUBDIR_NAME = "history"
_IDENTITY_PATTERN = re.compile(r"^[0-9a-f]{64}$")

_CURRENT_SCHEMA_VERSION: SchemaVersion = SchemaVersion.model_validate(1)


class ProjectDigestStoreError(Exception):
    """The Project Digest could not be durably persisted, loaded, or accepted.

    Carries a short, bounded, deterministic ``reason`` that never contains
    file contents or raw JSON. The optional ``path`` identifies the artifact
    path involved. Owns filesystem failures, malformed or non-canonical
    persisted state, unsafe storage locations, missing prerequisites, stale
    revisions, and conflicts with the frozen Master Plan.
    """

    def __init__(self, reason: str, *, path: Path | None = None) -> None:
        self.reason = reason
        self.path = path
        super().__init__(f"project digest store error: {reason}")


class _CurrentPointer(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    schema_version: SchemaVersion
    revision: Annotated[str, StringConstraints(pattern=r"^[0-9a-f]{64}$")]


# --- Location ---------------------------------------------------------------------


def _project_dir(runtime_dir: Path) -> Path:
    return runtime_dir / _PROJECT_SUBDIR_NAME


def _digest_dir(runtime_dir: Path) -> Path:
    return _project_dir(runtime_dir) / _DIGEST_SUBDIR_NAME


def _current_path(runtime_dir: Path) -> Path:
    return _digest_dir(runtime_dir) / _CURRENT_JSON_NAME


def _history_dir(runtime_dir: Path) -> Path:
    return _digest_dir(runtime_dir) / _HISTORY_SUBDIR_NAME


def _history_path(runtime_dir: Path, identity: str) -> Path:
    return _history_dir(runtime_dir) / f"{identity}.json"


def _require_identity(value: str) -> None:
    if not _IDENTITY_PATTERN.match(value):
        raise ProjectDigestStoreError("project digest revision is malformed")


def _checked_runtime_dir(project_root: Path, runtime_dir: Path) -> Path:
    resolved_project = Path(project_root).resolve()
    resolved_runtime = Path(runtime_dir).resolve()
    if resolved_runtime == resolved_project or resolved_runtime.is_relative_to(resolved_project):
        raise ProjectDigestStoreError("runtime directory must be outside project root")
    for path, name in (
        (_project_dir(resolved_runtime), "project directory"),
        (_digest_dir(resolved_runtime), "project digest directory"),
        (_current_path(resolved_runtime), _CURRENT_JSON_NAME),
        (_history_dir(resolved_runtime), "project digest history directory"),
    ):
        if path.is_symlink():
            raise ProjectDigestStoreError(f"{name} must not be a symlink", path=path)
    return resolved_runtime


# --- Atomic publication -----------------------------------------------------------


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _replace_atomically(source: Path, target: Path) -> None:
    os.replace(source, target)


def _atomic_write_bytes(path: Path, payload: bytes, *, artifact_name: str) -> None:
    parent = path.parent
    try:
        parent.mkdir(parents=True, exist_ok=True)
    except OSError as exc:
        raise ProjectDigestStoreError(
            f"cannot create directory for {artifact_name}", path=parent
        ) from exc

    temp_path = parent / f".{path.name}.{uuid.uuid4().hex}.tmp"
    try:
        try:
            fd = os.open(temp_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
        except OSError as exc:
            raise ProjectDigestStoreError(
                f"cannot create temporary file for {artifact_name}", path=temp_path
            ) from exc
        try:
            with os.fdopen(fd, "wb") as handle:
                handle.write(payload)
                handle.flush()
                os.fsync(handle.fileno())
        except OSError as exc:
            raise ProjectDigestStoreError(
                f"cannot write temporary file for {artifact_name}", path=temp_path
            ) from exc
        try:
            _replace_atomically(temp_path, path)
        except OSError as exc:
            raise ProjectDigestStoreError(f"cannot publish {artifact_name}", path=path) from exc
        try:
            _fsync_directory(parent)
        except OSError as exc:
            raise ProjectDigestStoreError(
                f"cannot fsync directory for {artifact_name}", path=parent
            ) from exc
    except BaseException:
        with contextlib.suppress(OSError):
            temp_path.unlink()
        raise


def _pointer_bytes(identity: str) -> bytes:
    pointer = _CurrentPointer(schema_version=_CURRENT_SCHEMA_VERSION, revision=identity)
    text = json.dumps(
        pointer.model_dump(mode="json"), ensure_ascii=False, sort_keys=True, separators=(",", ":")
    )
    return (text + "\n").encode("utf-8")


# --- Reading ----------------------------------------------------------------------


def _read_bytes(path: Path, *, artifact_name: str) -> bytes:
    try:
        return path.read_bytes()
    except OSError as exc:
        raise ProjectDigestStoreError(f"cannot read {artifact_name}", path=path) from exc


def _read_pointer(path: Path) -> str:
    raw = _read_bytes(path, artifact_name=_CURRENT_JSON_NAME)
    try:
        pointer = _CurrentPointer.model_validate(json.loads(raw.decode("utf-8")))
    except (UnicodeDecodeError, json.JSONDecodeError, ValidationError) as exc:
        raise ProjectDigestStoreError(
            "current.json is not a valid project digest pointer", path=path
        ) from exc
    if pointer.schema_version.root != _CURRENT_SCHEMA_VERSION.root:
        raise ProjectDigestStoreError("current.json has an unsupported schema_version", path=path)
    if _pointer_bytes(pointer.revision) != raw:
        raise ProjectDigestStoreError("current.json is not canonical", path=path)
    return pointer.revision


def _verified_revision(path: Path, identity: str) -> ProjectDigest:
    raw = _read_bytes(path, artifact_name="project digest revision")
    try:
        digest = ProjectDigest.model_validate(json.loads(raw.decode("utf-8")))
        canonical = canonical_project_digest_bytes(digest)
    except (UnicodeDecodeError, json.JSONDecodeError, ValidationError, ProjectDigestError) as exc:
        raise ProjectDigestStoreError(
            "project digest revision is not a valid project digest", path=path
        ) from exc
    if canonical != raw:
        raise ProjectDigestStoreError("project digest revision is not canonical", path=path)
    if project_digest_identity(digest) != identity:
        raise ProjectDigestStoreError(
            "project digest revision does not match its identity", path=path
        )
    return digest


def _require_consistent_with_master_plan(project_root: Path, digest: ProjectDigest) -> None:
    plan = load_frozen_master_plan(project_root)
    if plan is None:
        raise ProjectDigestStoreError("project digest requires a frozen master plan")
    if digest.project_id != plan.project_id:
        raise ProjectDigestStoreError("project digest names a different project")
    frozen = master_plan_digest(plan)
    for fact in digest.facts():
        for source in fact.sources:
            if source.kind is DigestSourceKind.MASTER_PLAN and source.digest != frozen:
                raise ProjectDigestStoreError(
                    f"fact {fact.fact_id} cites a master plan that is not the frozen master plan"
                )


def _load_current(project_root: Path, runtime_dir: Path) -> tuple[str, ProjectDigest] | None:
    current = _current_path(runtime_dir)
    if not current.exists():
        return None
    identity = _read_pointer(current)
    path = _history_path(runtime_dir, identity)
    if not path.exists():
        raise ProjectDigestStoreError(
            "current.json names a project digest revision that does not exist", path=path
        )
    digest = _verified_revision(path, identity)
    _require_consistent_with_master_plan(project_root, digest)
    return identity, digest


# --- Public API -------------------------------------------------------------------


def load_project_digest(project_root: Path, runtime_dir: Path) -> ProjectDigest | None:
    """Reconstruct the accepted Project Digest, or ``None`` if none was ever frozen.

    Read-only and never repairs. Fails closed unless ``current.json`` is a
    canonical pointer to an existing history revision whose bytes are
    canonical, whose identity matches its name, and which agrees with the
    frozen Master Plan. Depends only on persisted artifacts, never on a
    provider conversation.
    """
    resolved_runtime = _checked_runtime_dir(project_root, runtime_dir)
    loaded = _load_current(project_root, resolved_runtime)
    return None if loaded is None else loaded[1]


def load_project_digest_revision(
    project_root: Path, runtime_dir: Path, identity: str
) -> ProjectDigest | None:
    """Load one historical revision by identity, or ``None`` if it was never persisted.

    Read-only. The revision must be canonical and hash to exactly *identity*.
    A revision present in history is not thereby current; use
    :func:`load_project_digest` for the accepted Digest.
    """
    _require_identity(identity)
    resolved_runtime = _checked_runtime_dir(project_root, runtime_dir)
    path = _history_path(resolved_runtime, identity)
    if not path.exists():
        return None
    return _verified_revision(path, identity)


def freeze_project_digest(project_root: Path, runtime_dir: Path, digest: ProjectDigest) -> str:
    """Accept *digest* as the project's current Project Digest and return its identity.

    Canonically serializes *digest* first, so an oversized candidate raises
    :class:`~lockstep.context.project_digest.ProjectDigestError` with zero side
    effects. Then requires a frozen Master Plan for the same project, Master
    Plan sources that cite the frozen revision, prior-revision sources that
    name persisted history, and ``previous_revision`` equal to the current
    revision (``None`` for the first). Freezing the current revision again is
    an idempotent no-op. Publishes the immutable history file, then the
    ``current.json`` pointer.
    """
    payload = canonical_project_digest_bytes(digest)
    identity = project_digest_identity(digest)

    resolved_runtime = _checked_runtime_dir(project_root, runtime_dir)
    _require_consistent_with_master_plan(project_root, digest)

    current = _load_current(project_root, resolved_runtime)
    current_identity = None if current is None else current[0]
    if identity == current_identity:
        return identity
    if digest.previous_revision != current_identity:
        raise ProjectDigestStoreError(
            "project digest does not supersede the current revision"
            if current_identity is not None
            else "first project digest revision must not name a previous revision"
        )

    for fact in digest.facts():
        for source in fact.sources:
            if source.kind is DigestSourceKind.PRIOR_DIGEST_REVISION:
                assert source.digest is not None
                path = _history_path(resolved_runtime, source.digest)
                if not path.exists():
                    raise ProjectDigestStoreError(
                        f"fact {fact.fact_id} cites a project digest revision that does not exist"
                    )
                _verified_revision(path, source.digest)

    target = _history_path(resolved_runtime, identity)
    if target.exists():
        if _read_bytes(target, artifact_name="project digest revision") != payload:
            raise ProjectDigestStoreError(
                "history already holds different bytes for this revision", path=target
            )
    else:
        _atomic_write_bytes(target, payload, artifact_name="project digest revision")

    _atomic_write_bytes(
        _current_path(resolved_runtime), _pointer_bytes(identity), artifact_name=_CURRENT_JSON_NAME
    )
    return identity


__all__ = [
    "ProjectDigestStoreError",
    "freeze_project_digest",
    "load_project_digest",
    "load_project_digest_revision",
]
