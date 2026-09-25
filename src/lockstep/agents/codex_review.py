"""Codex Reviewer schema materialization.

Turns the canonical Lockstep Reviewer artifact contract
(:class:`~lockstep.domain.ReviewDecision`) into the exact on-disk
provider artifact that a Reviewer :class:`~lockstep.agents.CodexAdapter`
consumes via ``--output-schema``. The transformation flow is:

    ReviewDecision.model_json_schema()
            ↓
    to_openai_strict_json_schema(...)
            ↓
    deterministic compact UTF-8 JSON
            ↓
    <runtime_dir>/providers/codex/review-decision.schema.json

The helper is Reviewer-specific and receives no worktree path. It never
mutates the canonical schema, never invokes Codex, and never touches
the network. The :class:`~lockstep.agents.CodexAdapter` itself remains
side-effect free; orchestration composes the two explicitly.
"""

from __future__ import annotations

import contextlib
import json
import os
import tempfile
import uuid
from pathlib import Path

from lockstep.agents.openai_schema import to_openai_strict_json_schema
from lockstep.domain import ReviewDecision

_SCHEMA_FILENAME = "review-decision.schema.json"


def materialize_codex_review_schema(runtime_dir: Path) -> Path:
    """Materialize the Reviewer strict-schema artifact under *runtime_dir*.

    Derives the strict OpenAI schema from
    :meth:`ReviewDecision.model_json_schema` via
    :func:`~lockstep.agents.to_openai_strict_json_schema`, serializes it
    deterministically as compact UTF-8 JSON followed by exactly one
    trailing ``\\n``, and atomically publishes it at
    ``<runtime_dir>/providers/codex/review-decision.schema.json``.

    The canonical schema is never mutated. An existing final file at
    the target path is atomically replaced. On any failure during
    publication, no partially written final file is exposed and no
    orphan temporary file is left beneath ``providers/codex/``. Returns
    the absolute resolved path to the completed schema file.
    """
    provider_dir = runtime_dir.resolve() / "providers" / "codex"
    schema_path = provider_dir / _SCHEMA_FILENAME

    canonical = ReviewDecision.model_json_schema()
    strict_schema = to_openai_strict_json_schema(canonical)
    payload = _serialize_strict_schema_bytes(strict_schema)

    _atomically_publish(schema_path, payload)

    return schema_path.resolve()


def _serialize_strict_schema_bytes(strict_schema: dict[str, object]) -> bytes:
    """Return deterministic compact UTF-8 bytes with one trailing newline."""
    text = json.dumps(strict_schema, ensure_ascii=False, separators=(",", ":"))
    return (text + "\n").encode("utf-8")


def _replace_atomically(source: Path, target: Path) -> None:
    """Rename *source* onto *target* via :func:`os.replace`."""
    os.replace(source, target)


def _atomically_publish(target: Path, payload: bytes) -> None:
    """Atomically publish *payload* at *target* with strict cleanup.

    Creates a same-directory temporary file, writes *payload*, flushes
    and fsyncs it, then atomically renames it onto *target* via
    :func:`_replace_atomically`. Any failure removes the temporary file
    and re-raises. On success, best-effort fsyncs the parent directory.
    """
    parent = target.parent
    parent.mkdir(parents=True, exist_ok=True)

    tmp_fd, tmp_name = tempfile.mkstemp(
        prefix=f".{target.name}.{uuid.uuid4().hex}.",
        suffix=".tmp",
        dir=str(parent),
    )
    tmp_path = Path(tmp_name)
    try:
        with os.fdopen(tmp_fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        _replace_atomically(tmp_path, target)
    except BaseException:
        try:
            tmp_path.unlink()
        except FileNotFoundError:
            pass
        except OSError:
            pass
        raise

    with contextlib.suppress(OSError):
        _fsync_directory(parent)


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
