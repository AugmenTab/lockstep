"""Selected-provider diagnostic boundary.

Answers one deterministic question: are the provider CLIs selected by a
project's :class:`~lockstep.agents.routing.AgentRoutingPolicy`
discoverable and subscription-ready on this machine? Consumes only the
routing policy, an explicit operator parent environment, and optional
untracked machine overrides; resolves each uniquely selected provider's
executable, guards against the transient Claude npx-cache install
failure observed during Phase 6 qualification, and runs the frozen
production preflight/subscription-readiness checks for
:mod:`lockstep.agents.claude` and :mod:`lockstep.agents.codex`. Performs
no adapter resolution, no model inference, and no project-configuration
or Supervisor access; the resulting
:class:`~lockstep.agents.resolution.AgentProviderStatuses` is the sole
bridge into Sub-phase 7.2 adapter resolution.
"""

from __future__ import annotations

import os
import shutil
import tempfile
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path

from lockstep.agents.claude import (
    ClaudeCliStatus,
    claude_inherited_environment,
    probe_claude_cli,
    require_claude_subscription_ready,
)
from lockstep.agents.codex import (
    CodexCliStatus,
    probe_codex_cli,
    require_codex_subscription_ready,
)
from lockstep.agents.resolution import AgentProviderStatuses
from lockstep.agents.routing import AgentProvider, AgentRoutingPolicy

_NPX_CACHE_SEGMENT: tuple[str, str] = (".npm", "_npx")


class ProviderDiagnosticsError(Exception):
    """Diagnostics rejected an input before any provider was probed.

    Carries a short sanitized ``reason``. Never carries PATH contents,
    other environment values, credentials, or raw provider stdout/stderr.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"provider diagnostics error: {reason}")


@dataclass(frozen=True, slots=True)
class ProviderRuntimeOverrides:
    """Untracked, operator-supplied machine overrides for provider diagnostics.

    Never persisted to project configuration and never validated for a
    provider that the supplied routing policy does not select.
    """

    claude_executable: Path | None = None
    codex_executable: Path | None = None
    claude_config_dir: Path | None = None
    codex_home: Path | None = None


@dataclass(frozen=True, slots=True)
class AgentProviderDiagnostics:
    """Bounded evidence produced by :func:`diagnose_agent_providers`.

    ``statuses`` flows directly into
    :func:`~lockstep.agents.resolution.resolve_agent_adapters`. For a
    provider the routing policy does not select, its executable and
    runtime-directory fields are ``None``. Stores no parent environment,
    PATH value, prompt, credential, raw process output, or temporary
    probe directory; the only environment value carried is the Claude
    provider environment's optional ``USER`` inside ``statuses`` (hidden
    from :func:`repr`), which adapter resolution must reproduce.
    """

    statuses: AgentProviderStatuses
    claude_executable: Path | None = None
    codex_executable: Path | None = None
    claude_config_dir: Path | None = None
    codex_home: Path | None = None


def _selected_providers(policy: AgentRoutingPolicy) -> tuple[AgentProvider, ...]:
    used = {policy.planner.provider, policy.implementer.provider, policy.reviewer.provider}
    return tuple(
        provider for provider in (AgentProvider.CLAUDE, AgentProvider.CODEX) if provider in used
    )


def _is_under_transient_npx_cache(path: Path) -> bool:
    parts = path.parts
    first, second = _NPX_CACHE_SEGMENT
    return any(
        parts[index] == first and parts[index + 1] == second for index in range(len(parts) - 1)
    )


def _require_not_transient_npx_cache(candidate: Path, resolved: Path) -> None:
    if _is_under_transient_npx_cache(candidate) or _is_under_transient_npx_cache(resolved):
        raise ProviderDiagnosticsError("claude executable resolves to a transient npx cache")


def _resolve_selected_executable(
    *,
    override: Path | None,
    cli_name: str,
    field: str,
    parent_env: Mapping[str, str],
) -> tuple[Path, Path]:
    """Resolve one selected provider's executable to (candidate, canonical).

    ``candidate`` is the supplied/discovered path before canonicalization;
    ``resolved`` is its canonical absolute target. Both are returned so
    callers can inspect the pre-resolution form as well.
    """
    if override is not None:
        if not override.is_absolute():
            raise ProviderDiagnosticsError(f"{field} must be an absolute path")
        if not override.exists():
            raise ProviderDiagnosticsError(f"{field} does not exist")
        if not override.is_file():
            raise ProviderDiagnosticsError(f"{field} is not a regular file")
        if not os.access(override, os.X_OK):
            raise ProviderDiagnosticsError(f"{field} is not executable")
        return override, override.resolve()

    path_value = parent_env.get("PATH")
    if not path_value:
        raise ProviderDiagnosticsError("required PATH is unavailable")
    found = shutil.which(cli_name, path=path_value)
    if found is None:
        raise ProviderDiagnosticsError(f"selected provider executable not found: {cli_name}")
    candidate = Path(found)
    return candidate, candidate.resolve()


def _validate_absolute_runtime_dir(path: Path, *, field: str) -> Path:
    if not path.is_absolute():
        raise ProviderDiagnosticsError(f"{field} must be an absolute path")
    return path.resolve()


_DEFAULT_OVERRIDES = ProviderRuntimeOverrides()


def diagnose_agent_providers(
    policy: AgentRoutingPolicy,
    *,
    parent_env: Mapping[str, str],
    overrides: ProviderRuntimeOverrides = _DEFAULT_OVERRIDES,
) -> AgentProviderDiagnostics:
    """Diagnose exactly the providers *policy* selects, once each.

    Derives the unique selected-provider set solely from *policy*'s
    three role routes, resolves and validates every selected provider's
    executable (and, for Claude, rejects a transient npx-cache install),
    then validates any explicit runtime-directory override for a
    selected provider — all before launching any provider process. Only
    then does it run the frozen production preflight and
    subscription-readiness checks, in fixed Claude-then-Codex order,
    inside a fresh temporary directory used as every probe's ``cwd``. An
    override supplied for a provider *policy* does not select is
    ignored entirely. Never reads ambient environment state; every
    value consulted comes from the explicit *parent_env* mapping, which
    is never mutated.
    """
    selected = _selected_providers(policy)

    claude_resolved: Path | None = None
    codex_resolved: Path | None = None

    if AgentProvider.CLAUDE in selected:
        candidate, resolved = _resolve_selected_executable(
            override=overrides.claude_executable,
            cli_name="claude",
            field="claude_executable",
            parent_env=parent_env,
        )
        _require_not_transient_npx_cache(candidate, resolved)
        claude_resolved = resolved

    if AgentProvider.CODEX in selected:
        _candidate, resolved = _resolve_selected_executable(
            override=overrides.codex_executable,
            cli_name="codex",
            field="codex_executable",
            parent_env=parent_env,
        )
        codex_resolved = resolved

    claude_config_dir: Path | None = None
    codex_home: Path | None = None

    if AgentProvider.CLAUDE in selected and overrides.claude_config_dir is not None:
        claude_config_dir = _validate_absolute_runtime_dir(
            overrides.claude_config_dir, field="claude_config_dir"
        )

    if AgentProvider.CODEX in selected and overrides.codex_home is not None:
        codex_home = _validate_absolute_runtime_dir(overrides.codex_home, field="codex_home")

    claude_status: ClaudeCliStatus | None = None
    codex_status: CodexCliStatus | None = None

    with tempfile.TemporaryDirectory(prefix="lockstep-provider-diagnostics-") as raw_probe_dir:
        probe_cwd = Path(raw_probe_dir)

        if claude_resolved is not None:
            claude_status = require_claude_subscription_ready(
                probe_claude_cli(
                    claude_executable=str(claude_resolved),
                    parent_env=parent_env,
                    cwd=probe_cwd,
                    claude_config_dir=claude_config_dir,
                )
            )

        if codex_resolved is not None:
            codex_status = require_codex_subscription_ready(
                probe_codex_cli(
                    codex_executable=str(codex_resolved),
                    parent_env=parent_env,
                    cwd=probe_cwd,
                    codex_home=codex_home,
                )
            )

    return AgentProviderDiagnostics(
        statuses=AgentProviderStatuses(
            claude=claude_status,
            codex=codex_status,
            claude_inherited_env=(
                claude_inherited_environment(parent_env) if claude_status is not None else {}
            ),
        ),
        claude_executable=claude_resolved,
        codex_executable=codex_resolved,
        claude_config_dir=claude_config_dir,
        codex_home=codex_home,
    )
