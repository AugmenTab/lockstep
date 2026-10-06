"""Durable, tracked, project-owned ContextSelection (Phase 12.8).

The host's explicit choice of optional ContextPack documents lives in exactly one tracked
project file::

    <project_root>/.lockstep/project/context-selection.json

It is stable project configuration, not execution state, so it belongs to the project root
beside the frozen Master Plan rather than under the runtime directory. It persists exactly
what :class:`~lockstep.context.context_pack_builder.SelectedContextDocument` models -- a
repository-relative path, a source kind and the operations served -- and nothing else: no
document text, no cached prompt, no provider, no Phase/run/attempt identity.
Per-call ContextSelection policy flags are deliberately not persisted; only the documents are.

The file is strict (unknown fields, unsafe paths, duplicate documents or operations, and
unknown kinds or operations fail closed) and versioned. Its canonical rendering sorts the
documents by path and each document's operations by their declared order and emits compact
sorted-key JSON with one trailing newline; its identity is the SHA-256 of that rendering, so
whitespace or ordering in a hand-edited file never changes it.

An absent file means the empty selection. Lockstep never creates, edits or deletes the file
(that is a project configuration act, not something an autonomous run does) and never
creates or modifies a selected document. Selection stays explicit: nothing here discovers an
instruction file from the working directory. The selected documents' bytes are still read
freshly, and versioned by their own SHA-256, by the ContextPack builder.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
from typing import Annotated, Final, Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError

from lockstep.context.context_pack import ContextOperation, ContextSourceKind
from lockstep.context.context_pack_builder import (
    CONTEXT_DOCUMENTS_MAX_COUNT,
    ContextSelection,
    SelectedContextDocument,
)
from lockstep.contract_test_targets import target_path_violation, traverses_symlink

CONTEXT_SELECTION_SCHEMA_VERSION: Final = 1

_LOCKSTEP_DIR_NAME = ".lockstep"
_PROJECT_DIR_NAME = "project"
_SELECTION_NAME = "context-selection.json"
_OPERATION_ORDER: tuple[ContextOperation, ...] = tuple(ContextOperation)


class ContextSelectionStoreError(Exception):
    """The tracked ContextSelection is unsafe, malformed, or cannot be represented.

    Carries a short, bounded, deterministic ``reason`` that never contains file contents.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"context selection store error: {reason}")


class _StoredDocument(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid", strict=True)

    path: Annotated[str, Field(min_length=1)]
    kind: Literal[
        ContextSourceKind.PROJECT_INSTRUCTIONS,
        ContextSourceKind.PROJECT_DOCUMENTATION,
        ContextSourceKind.SKILL,
    ]
    operations: Annotated[tuple[ContextOperation, ...], Field(min_length=1)]


class _StoredSelection(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid", strict=True)

    schema_version: Annotated[int, Field(strict=True, ge=1, le=1)]  # bool is not 1
    documents: Annotated[tuple[_StoredDocument, ...], Field(max_length=CONTEXT_DOCUMENTS_MAX_COUNT)]


def context_selection_path(project_root: Path) -> Path:
    """The one canonical, tracked location of the project's ContextSelection."""
    return Path(project_root) / _LOCKSTEP_DIR_NAME / _PROJECT_DIR_NAME / _SELECTION_NAME


def _canonical_document(document: SelectedContextDocument) -> SelectedContextDocument:
    return document.model_copy(
        update={"operations": tuple(sorted(document.operations, key=_OPERATION_ORDER.index))}
    )


def parse_context_selection(raw: bytes) -> ContextSelection:
    """Validate the bytes of a stored selection and return it in canonical order."""
    try:
        text = raw.decode("utf-8")
        stored = _StoredSelection.model_validate_json(text, strict=True)
    except (UnicodeDecodeError, ValidationError) as exc:
        raise ContextSelectionStoreError("the context selection is malformed") from exc

    documents: list[SelectedContextDocument] = []
    for position, entry in enumerate(stored.documents):
        violation = target_path_violation(entry.path)
        if violation is not None:
            raise ContextSelectionStoreError(f"selected document {position} {violation}")
        if len(set(entry.operations)) != len(entry.operations):
            raise ContextSelectionStoreError(f"selected document {position} repeats an operation")
        documents.append(
            _canonical_document(
                SelectedContextDocument(
                    path=entry.path, kind=entry.kind, operations=entry.operations
                )
            )
        )
    documents.sort(key=lambda document: document.path)
    try:
        return ContextSelection(documents=tuple(documents))
    except ValidationError as exc:
        raise ContextSelectionStoreError("a document is selected more than once") from exc


def render_context_selection(selection: ContextSelection) -> bytes:
    """The canonical bytes of *selection*: the exact form a tracked file is identified by."""
    if selection != ContextSelection(documents=selection.documents):
        raise ContextSelectionStoreError("only the selected documents are persisted")
    documents = sorted(
        (_canonical_document(document) for document in selection.documents),
        key=lambda document: document.path,
    )
    value = {
        "schema_version": CONTEXT_SELECTION_SCHEMA_VERSION,
        "documents": [document.model_dump(mode="json") for document in documents],
    }
    text = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return (text + "\n").encode("utf-8")


def context_selection_identity(selection: ContextSelection) -> str:
    """The SHA-256 of *selection*'s canonical rendering."""
    return hashlib.sha256(render_context_selection(selection)).hexdigest()


def _read_tracked(project_root: Path) -> bytes | None:
    root = Path(project_root).resolve()
    path = context_selection_path(root)
    for guarded in (path.parent.parent, path.parent, path):
        if guarded.is_symlink():
            raise ContextSelectionStoreError("the context selection must not be a symlink")
    if not path.exists():
        return None
    if not path.is_file():
        raise ContextSelectionStoreError("the context selection is not a regular file")
    try:
        return path.read_bytes()
    except OSError as exc:
        raise ContextSelectionStoreError("the context selection cannot be read") from exc


def _require_safe_documents(project_root: Path, selection: ContextSelection) -> None:
    root = Path(project_root).resolve()
    for position, document in enumerate(selection.documents):
        if traverses_symlink(root, document.path):
            raise ContextSelectionStoreError(f"selected document {position} traverses a symlink")
        target = root / document.path
        if target.exists() and not target.is_file():
            raise ContextSelectionStoreError(f"selected document {position} is not a regular file")


def _load(project_root: Path) -> tuple[ContextSelection, str] | None:
    raw = _read_tracked(project_root)
    if raw is None:
        return None
    selection = parse_context_selection(raw)
    _require_safe_documents(project_root, selection)
    return selection, context_selection_identity(selection)


def load_context_selection(project_root: Path) -> ContextSelection:
    """The project's durable selection, read freshly; an absent file is the empty selection.

    The one host-owned loader the canonical production request paths share. Read-only.
    """
    loaded = _load(project_root)
    return ContextSelection() if loaded is None else loaded[0]


def load_context_selection_identity(project_root: Path) -> str | None:
    """The identity of the tracked selection, or ``None`` when no file is tracked.

    An explicitly empty file has the identity of the canonical empty rendering; only an
    absent file is ``None``.
    """
    loaded = _load(project_root)
    return None if loaded is None else loaded[1]


__all__ = [
    "CONTEXT_SELECTION_SCHEMA_VERSION",
    "ContextSelectionStoreError",
    "context_selection_identity",
    "context_selection_path",
    "load_context_selection",
    "load_context_selection_identity",
    "parse_context_selection",
    "render_context_selection",
]
