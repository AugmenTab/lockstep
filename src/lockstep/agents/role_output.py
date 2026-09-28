"""Provider-specific structured-output adaptation for execution roles (Phase 9.4).

Wraps an already-qualified Implementer or Reviewer role adapter in a
thin :class:`~lockstep.agents.invocation.AgentAdapter` that narrows its
command to strict, schema-constrained final output *without* changing
that role's tool/sandbox authority:

    qualified role adapter
        -> build_command(request)            (frozen base authority)
        -> provider-specific structured-output transform
        -> unchanged tool/sandbox authority + schema-constrained output argv

Provider dispatch is deliberately isolated to this module: it is
permitted to reason about which concrete provider a role adapter is.
Every other layer (in particular :mod:`lockstep.agent_turn`) depends
only on the neutral :class:`~lockstep.agents.invocation.AgentAdapter`
interface this module returns. Supports the Implementer and Reviewer
roles only; the frozen Planner structured-output contract
(:mod:`lockstep.agents.structured_output`) is untouched and not reused
here, and Reviewer's separately frozen Codex schema contract
(:mod:`lockstep.agents.codex_review`) is untouched as well. This module
knows nothing about escalation, Planner-decision, or Supervisor/planning
protocol types — its only job is preserving role authority while adding
structured final-output enforcement.
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
from lockstep.agents.invocation import AgentAdapter, AgentCommand, AgentInvocationRequest
from lockstep.agents.openai_schema import to_openai_strict_json_schema
from lockstep.domain import AgentRole

_SCHEMA_NAME_RE = re.compile(r"^[a-z][a-z0-9-]*$")
_MAX_SCHEMA_NAME_LENGTH = 64

_SUPPORTED_ROLES: frozenset[AgentRole] = frozenset({AgentRole.IMPLEMENTER, AgentRole.REVIEWER})

_CODEX_AGENT_TURN_SCHEMA_SUBDIR: tuple[str, ...] = ("providers", "codex", "agent-turn")


class RoleOutputAdapterError(Exception):
    """Structured role-output preparation rejected an adapter, role, or command shape.

    Carries a short sanitized ``reason``. Never carries the request
    prompt, provider stdout/stderr, environment values, or the caller's
    schema in full.
    """

    def __init__(self, *, reason: str) -> None:
        self.reason = reason
        super().__init__(f"role output adapter error: {reason}")


def _validate_schema_name(schema_name: str) -> str:
    if not isinstance(schema_name, str):
        raise RoleOutputAdapterError(reason="schema_name must be a string")
    if not (1 <= len(schema_name) <= _MAX_SCHEMA_NAME_LENGTH):
        raise RoleOutputAdapterError(reason="schema_name has an invalid length")
    if _SCHEMA_NAME_RE.fullmatch(schema_name) is None:
        raise RoleOutputAdapterError(reason="schema_name has an invalid format")
    return schema_name


def _single_optional_flag_index(argv: list[str], *, flag: str) -> int | None:
    occurrences = [index for index, token in enumerate(argv) if token == flag]
    if len(occurrences) > 1:
        raise RoleOutputAdapterError(
            reason=f"expected at most one {flag} token in the base role command"
        )
    if not occurrences:
        return None
    index = occurrences[0]
    if index + 1 >= len(argv):
        raise RoleOutputAdapterError(reason=f"{flag} token is missing its value")
    return index


def _reduce_claude_argv(argv: tuple[str, ...], *, schema_json: str) -> tuple[str, ...]:
    argv_list = list(argv)

    index = _single_optional_flag_index(argv_list, flag="--json-schema")
    if index is None:
        argv_list.extend(("--json-schema", schema_json))
    else:
        argv_list[index + 1] = schema_json

    return tuple(argv_list)


def _reduce_codex_argv(argv: tuple[str, ...], *, schema_path: Path) -> tuple[str, ...]:
    argv_list = list(argv)

    if not argv_list or argv_list[-1] != "-":
        raise RoleOutputAdapterError(
            reason="base role command does not end with the expected stdin marker"
        )

    trailing = len(argv_list) - 1
    index = _single_optional_flag_index(argv_list[:trailing], flag="--output-schema")
    if index is None:
        argv_list[trailing:trailing] = ["--output-schema", str(schema_path)]
    else:
        argv_list[index + 1] = str(schema_path)

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


def _materialize_codex_agent_turn_schema(
    runtime_dir: Path,
    schema_name: str,
    schema: Mapping[str, object],
) -> Path:
    """Materialize a role-output structured-output schema under *runtime_dir*.

    Derives the strict OpenAI schema from *schema* via
    :func:`~lockstep.agents.openai_schema.to_openai_strict_json_schema`
    exactly once, serializes it deterministically, and atomically
    publishes it at
    ``<runtime_dir>/providers/codex/agent-turn/<schema_name>.schema.json``.
    This path is distinct from, and never shared with, the frozen
    Planner materializer in :mod:`lockstep.agents.structured_output` or
    the frozen Reviewer materializer in
    :mod:`lockstep.agents.codex_review`.
    """
    provider_dir = runtime_dir.resolve()
    for segment in _CODEX_AGENT_TURN_SCHEMA_SUBDIR:
        provider_dir = provider_dir / segment
    schema_path = provider_dir / f"{schema_name}.schema.json"

    strict_schema = to_openai_strict_json_schema(schema)
    payload = _serialize_strict_schema_bytes(strict_schema)

    _atomically_publish(schema_path, payload)

    return schema_path.resolve()


@dataclass(frozen=True, slots=True)
class _StructuredRoleAdapter:
    """Authority-preserving, schema-constrained wrapper around a base role adapter."""

    base_adapter: AgentAdapter
    transform: Callable[[AgentCommand], AgentCommand]

    @property
    def name(self) -> str:
        return self.base_adapter.name

    def build_command(self, request: AgentInvocationRequest) -> AgentCommand:
        base_command = self.base_adapter.build_command(request)
        return self.transform(base_command)


def _prepare_claude(
    adapter: ClaudeAdapter,
    *,
    schema: Mapping[str, object],
) -> AgentAdapter:
    if not adapter.status.supports_json_schema:
        raise RoleOutputAdapterError(
            reason="configured Claude role adapter does not support structured output"
        )

    schema_json = json.dumps(
        dict(schema), ensure_ascii=False, separators=(",", ":"), sort_keys=True
    )

    def _transform(command: AgentCommand) -> AgentCommand:
        return replace(command, argv=_reduce_claude_argv(command.argv, schema_json=schema_json))

    return _StructuredRoleAdapter(base_adapter=adapter, transform=_transform)


def _prepare_codex(
    adapter: CodexAdapter,
    *,
    schema: Mapping[str, object],
    runtime_dir: Path,
    schema_name: str,
) -> AgentAdapter:
    if not adapter.status.supports_exec_output_schema:
        raise RoleOutputAdapterError(
            reason="configured Codex role adapter does not support structured output"
        )

    schema_path = _materialize_codex_agent_turn_schema(runtime_dir, schema_name, schema)

    def _transform(command: AgentCommand) -> AgentCommand:
        return replace(command, argv=_reduce_codex_argv(command.argv, schema_path=schema_path))

    return _StructuredRoleAdapter(base_adapter=adapter, transform=_transform)


def prepare_structured_role_adapter(
    adapter: AgentAdapter,
    *,
    role: AgentRole,
    runtime_dir: Path,
    schema: dict[str, object],
    schema_name: str,
) -> AgentAdapter:
    """Wrap a qualified Implementer/Reviewer *adapter* for strict structured output.

    Supports only a base adapter bound to
    :attr:`~lockstep.domain.AgentRole.IMPLEMENTER` or
    :attr:`~lockstep.domain.AgentRole.REVIEWER` that is a real production
    :class:`~lockstep.agents.claude.ClaudeAdapter` or
    :class:`~lockstep.agents.codex.CodexAdapter` whose own ``role``
    matches *role* exactly; any other role, adapter type, or role
    mismatch raises :class:`RoleOutputAdapterError` before any command is
    built or any filesystem access occurs. The returned adapter's
    ``build_command`` begins by calling the base adapter's
    ``build_command`` — preserving every frozen tool/sandbox/model/
    effort/session/environment/stdin contract for that role exactly —
    then adds the provider's structured-output argument. Reviewer's base
    command may already carry a provider structured-output flag from its
    own frozen contract; that value is replaced in place rather than
    duplicated. Codex additionally materializes a durable strict-schema
    artifact under *runtime_dir* at preparation time; Claude embeds
    *schema* inline and creates no schema file.
    """
    if role not in _SUPPORTED_ROLES:
        raise RoleOutputAdapterError(
            reason="structured role output is supported for the Implementer and Reviewer roles only"
        )

    validated_schema_name = _validate_schema_name(schema_name)

    if isinstance(adapter, ClaudeAdapter):
        if adapter.role is not role:
            raise RoleOutputAdapterError(reason="adapter role does not match the requested role")
        return _prepare_claude(adapter, schema=schema)

    if isinstance(adapter, CodexAdapter):
        if adapter.role is not role:
            raise RoleOutputAdapterError(reason="adapter role does not match the requested role")
        return _prepare_codex(
            adapter,
            schema=schema,
            runtime_dir=runtime_dir,
            schema_name=validated_schema_name,
        )

    raise RoleOutputAdapterError(reason="unsupported agent adapter type")


__all__ = [
    "RoleOutputAdapterError",
    "prepare_structured_role_adapter",
]
