"""Provider-specific structured-output adaptation for the configured Planner.

Wraps an already-constructed, role-bound Planner
:class:`~lockstep.agents.claude.ClaudeAdapter` or
:class:`~lockstep.agents.codex.CodexAdapter` in a thin
:class:`~lockstep.agents.invocation.AgentAdapter` that narrows its command
to schema-constrained, read-only structured output:

    configured Planner adapter
        -> build_command(request)            (frozen base authority)
        -> provider-specific structured-output transform
        -> read-only authority + schema-constrained output argv

Provider dispatch is deliberately isolated to this module: it is the one
place in Lockstep permitted to reason about which concrete provider a
Planner adapter is. Every other layer (in particular
:mod:`lockstep.planning_transport`) depends only on the neutral
:class:`~lockstep.agents.invocation.AgentAdapter` interface this module
returns. Supports the Planner role only; Reviewer's frozen structured-output
contract (:mod:`lockstep.agents.codex_review`) is untouched and not
generalized here.
"""

from __future__ import annotations

import contextlib
import json
import os
import re
import tempfile
import uuid
from collections.abc import Callable, Mapping
from dataclasses import dataclass, replace
from pathlib import Path

from lockstep.agents.claude import ClaudeAdapter
from lockstep.agents.codex import CodexAdapter
from lockstep.agents.invocation import (
    AdapterOutput,
    AgentAdapter,
    AgentCommand,
    AgentInvocationRequest,
)
from lockstep.agents.openai_schema import to_openai_strict_json_schema
from lockstep.domain import AgentRole
from lockstep.process import ProcessResult

_SCHEMA_NAME_RE = re.compile(r"^[a-z][a-z0-9-]*$")
_MAX_SCHEMA_NAME_LENGTH = 64

_CLAUDE_PLANNER_TOOLS = "Read,Write,Edit,Glob,Grep"
_CLAUDE_READ_ONLY_TOOLS = "Read,Glob,Grep"

_CODEX_PLANNER_SANDBOX = "workspace-write"
_CODEX_READ_ONLY_SANDBOX = "read-only"

_CODEX_PLANNING_SCHEMA_SUBDIR: tuple[str, ...] = ("providers", "codex", "planning")


class StructuredOutputAdapterError(Exception):
    """Structured-output preparation rejected an adapter, role, or command shape.

    Carries a short sanitized ``reason``. Never carries the request
    prompt, provider stdout/stderr, environment values, or the caller's
    canonical schema in full.
    """

    def __init__(self, *, reason: str) -> None:
        self.reason = reason
        super().__init__(f"structured output adapter error: {reason}")


def _validate_schema_name(schema_name: str) -> str:
    if not isinstance(schema_name, str):
        raise StructuredOutputAdapterError(reason="schema_name must be a string")
    if not (1 <= len(schema_name) <= _MAX_SCHEMA_NAME_LENGTH):
        raise StructuredOutputAdapterError(reason="schema_name has an invalid length")
    if _SCHEMA_NAME_RE.fullmatch(schema_name) is None:
        raise StructuredOutputAdapterError(reason="schema_name has an invalid format")
    return schema_name


def _require_single_flag_value(argv: list[str], *, flag: str) -> int:
    occurrences = [index for index, token in enumerate(argv) if token == flag]
    if len(occurrences) != 1:
        raise StructuredOutputAdapterError(
            reason=f"expected exactly one {flag} token in the base Planner command"
        )
    index = occurrences[0]
    if index + 1 >= len(argv):
        raise StructuredOutputAdapterError(reason=f"{flag} token is missing its value")
    return index


def _reduce_claude_argv(argv: tuple[str, ...], *, schema_json: str) -> tuple[str, ...]:
    argv_list = list(argv)

    tools_index = _require_single_flag_value(argv_list, flag="--tools")
    if argv_list[tools_index + 1] != _CLAUDE_PLANNER_TOOLS:
        raise StructuredOutputAdapterError(
            reason="base Planner command --tools value does not match the expected authority"
        )

    allowed_index = _require_single_flag_value(argv_list, flag="--allowedTools")
    if argv_list[allowed_index + 1] != _CLAUDE_PLANNER_TOOLS:
        raise StructuredOutputAdapterError(
            reason=(
                "base Planner command --allowedTools value does not match "
                "the expected writable authority"
            )
        )

    argv_list[tools_index + 1] = _CLAUDE_READ_ONLY_TOOLS
    argv_list[allowed_index + 1] = _CLAUDE_READ_ONLY_TOOLS
    argv_list.extend(("--json-schema", schema_json))
    return tuple(argv_list)


def _reduce_codex_argv(argv: tuple[str, ...], *, schema_path: Path) -> tuple[str, ...]:
    argv_list = list(argv)

    if not argv_list or argv_list[-1] != "-":
        raise StructuredOutputAdapterError(
            reason="base Planner command does not end with the expected stdin marker"
        )

    sandbox_index = _require_single_flag_value(argv_list, flag="--sandbox")
    if sandbox_index + 1 >= len(argv_list) - 1:
        raise StructuredOutputAdapterError(reason="--sandbox token is missing its value")
    if argv_list[sandbox_index + 1] != _CODEX_PLANNER_SANDBOX:
        raise StructuredOutputAdapterError(
            reason="base Planner command --sandbox value does not match the expected authority"
        )

    argv_list[sandbox_index + 1] = _CODEX_READ_ONLY_SANDBOX
    insertion_index = len(argv_list) - 1
    argv_list[insertion_index:insertion_index] = ["--output-schema", str(schema_path)]
    return tuple(argv_list)


def _serialize_strict_schema_bytes(strict_schema: Mapping[str, object]) -> bytes:
    text = json.dumps(dict(strict_schema), ensure_ascii=False, separators=(",", ":"))
    return (text + "\n").encode("utf-8")


def _replace_atomically(source: Path, target: Path) -> None:
    """Rename *source* onto *target* via :func:`os.replace`."""
    os.replace(source, target)


def _fsync_directory(directory: Path) -> None:
    fd = os.open(directory, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _atomically_publish(target: Path, payload: bytes) -> None:
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


def _materialize_codex_planning_schema(
    runtime_dir: Path,
    schema_name: str,
    canonical_schema: Mapping[str, object],
) -> Path:
    """Materialize a Planner structured-output schema under *runtime_dir*.

    Derives the strict OpenAI schema from *canonical_schema* via
    :func:`~lockstep.agents.openai_schema.to_openai_strict_json_schema`
    exactly once, serializes it deterministically, and atomically
    publishes it at
    ``<runtime_dir>/providers/codex/planning/<schema_name>.schema.json``.
    Every call recomputes the strict schema from *canonical_schema*; a
    stale existing file at the target path is atomically replaced. This
    path is distinct from, and never shared with, the frozen Reviewer
    materializer in :mod:`lockstep.agents.codex_review`.
    """
    provider_dir = runtime_dir.resolve()
    for segment in _CODEX_PLANNING_SCHEMA_SUBDIR:
        provider_dir = provider_dir / segment
    schema_path = provider_dir / f"{schema_name}.schema.json"

    strict_schema = to_openai_strict_json_schema(canonical_schema)
    payload = _serialize_strict_schema_bytes(strict_schema)

    _atomically_publish(schema_path, payload)

    return schema_path.resolve()


@dataclass(frozen=True, slots=True)
class _StructuredPlannerAdapter:
    """Read-only, schema-constrained wrapper around a base Planner adapter."""

    base_adapter: ClaudeAdapter | CodexAdapter
    transform: Callable[[AgentCommand], AgentCommand]

    @property
    def name(self) -> str:
        return self.base_adapter.name

    @property
    def configured_model(self) -> str:
        return self.base_adapter.configured_model

    @property
    def configured_effort(self) -> str:
        return self.base_adapter.configured_effort

    def normalize_output(self, process: ProcessResult) -> AdapterOutput:
        return self.base_adapter.normalize_output(process)

    def build_command(self, request: AgentInvocationRequest) -> AgentCommand:
        base_command = self.base_adapter.build_command(request)
        return self.transform(base_command)


def _prepare_claude(
    adapter: ClaudeAdapter,
    *,
    canonical_schema: Mapping[str, object],
) -> AgentAdapter:
    if not adapter.status.supports_json_schema:
        raise StructuredOutputAdapterError(
            reason="configured Claude Planner does not support structured output"
        )

    schema_json = json.dumps(
        dict(canonical_schema), ensure_ascii=False, separators=(",", ":"), sort_keys=True
    )

    def _transform(command: AgentCommand) -> AgentCommand:
        return replace(command, argv=_reduce_claude_argv(command.argv, schema_json=schema_json))

    return _StructuredPlannerAdapter(base_adapter=adapter, transform=_transform)


def _prepare_codex(
    adapter: CodexAdapter,
    *,
    canonical_schema: Mapping[str, object],
    runtime_dir: Path,
    schema_name: str,
) -> AgentAdapter:
    if not adapter.status.supports_exec_output_schema:
        raise StructuredOutputAdapterError(
            reason="configured Codex Planner does not support structured output"
        )

    schema_path = _materialize_codex_planning_schema(runtime_dir, schema_name, canonical_schema)

    def _transform(command: AgentCommand) -> AgentCommand:
        return replace(command, argv=_reduce_codex_argv(command.argv, schema_path=schema_path))

    return _StructuredPlannerAdapter(base_adapter=adapter, transform=_transform)


def prepare_structured_planner_adapter(
    adapter: AgentAdapter,
    *,
    canonical_schema: Mapping[str, object],
    runtime_dir: Path,
    schema_name: str,
) -> AgentAdapter:
    """Wrap a Planner *adapter* for schema-constrained, read-only structured output.

    Supports only a base adapter bound to :attr:`~lockstep.domain.AgentRole.PLANNER`
    that is a real production :class:`~lockstep.agents.claude.ClaudeAdapter` or
    :class:`~lockstep.agents.codex.CodexAdapter`; any other role or adapter type
    raises :class:`StructuredOutputAdapterError` before any command is built or
    any filesystem access occurs. The returned adapter's ``build_command``
    begins by calling the base adapter's ``build_command`` — preserving every
    frozen model/effort/session/environment/stdin contract — then narrows the
    result to read-only authority and adds the provider's structured-output
    argument. Codex additionally materializes a durable strict-schema artifact
    under *runtime_dir* at preparation time; Claude embeds *canonical_schema*
    inline and creates no schema file.
    """
    validated_schema_name = _validate_schema_name(schema_name)

    if isinstance(adapter, ClaudeAdapter):
        if adapter.role is not AgentRole.PLANNER:
            raise StructuredOutputAdapterError(
                reason="structured output is supported for the Planner role only"
            )
        return _prepare_claude(adapter, canonical_schema=canonical_schema)

    if isinstance(adapter, CodexAdapter):
        if adapter.role is not AgentRole.PLANNER:
            raise StructuredOutputAdapterError(
                reason="structured output is supported for the Planner role only"
            )
        return _prepare_codex(
            adapter,
            canonical_schema=canonical_schema,
            runtime_dir=runtime_dir,
            schema_name=validated_schema_name,
        )

    raise StructuredOutputAdapterError(reason="unsupported agent adapter type")


__all__ = [
    "StructuredOutputAdapterError",
    "prepare_structured_planner_adapter",
]
