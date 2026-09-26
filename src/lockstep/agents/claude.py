"""Claude Code CLI subscription and capability preflight.

Answers deterministic yes/no questions about a configured Claude Code
executable — is it a supported version, does its help surface advertise
the flags Lockstep's future adapter will require, and does its stored
authentication describe an active claude.ai first-party paid
subscription — without executing any model turn. All external commands
are executed through :mod:`lockstep.process`; ambient Anthropic and
cloud-provider credential variables are structurally excluded from
every probe by the allowlist-based environment builder.
"""

from __future__ import annotations

import json
import re
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType

from lockstep.process import (
    ProcessResult,
    build_process_environment,
    run_process,
)

_MIN_VERSION: tuple[int, int, int] = (2, 1, 259)
_VERSION_TOKEN_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")

_ACCEPTED_SUBSCRIPTION_TYPES: frozenset[str] = frozenset({"pro", "max", "team", "enterprise"})
_REQUIRED_AUTH_METHOD = "claude.ai"
_REQUIRED_API_PROVIDER = "firstParty"

_CAPABILITY_FLAG_NAMES: tuple[str, ...] = (
    "-p",
    "--print",
    "--model",
    "--effort",
    "--output-format",
    "--json-schema",
    "--permission-mode",
    "--permission-prompts",
    "--no-session-persistence",
    "--restricted",
    "--bare",
    "--tools",
    "--disallowedTools",
    "--disallowed-tools",
)

_FLAG_TOKEN_PATTERN: dict[str, re.Pattern[str]] = {
    flag: re.compile(rf"(?<![A-Za-z0-9_\-]){re.escape(flag)}(?![A-Za-z0-9_\-])")
    for flag in _CAPABILITY_FLAG_NAMES
}

_EMPTY_EXPLICIT_ENV: Mapping[str, str] = MappingProxyType({})


@dataclass(frozen=True, slots=True)
class ClaudeCliStatus:
    """Bounded evidence gathered by the Claude Code preflight.

    Captures the executable path used, its normalized semantic version,
    the four fields Lockstep reads from ``claude auth status``
    (``loggedIn``, ``authMethod``, ``apiProvider``, ``subscriptionType``),
    and one boolean per Phase-6 CLI flag observed in the installed help
    surface. Deliberately excludes email, organization identifiers,
    credential paths, and any auth-token material.
    """

    executable: str
    version: str

    logged_in: bool
    auth_method: str | None
    api_provider: str | None
    subscription_type: str | None

    supports_print: bool
    supports_model: bool
    supports_effort: bool
    supports_output_format: bool
    supports_json_schema: bool
    supports_permission_mode: bool
    supports_permission_prompts: bool
    supports_no_session_persistence: bool
    supports_restricted: bool
    supports_bare: bool
    supports_tools: bool
    supports_disallowed_tools: bool


class ClaudePreflightError(Exception):
    """A stage of the Claude Code preflight rejected the observed evidence.

    Carries the failing ``stage`` (``version``, ``capabilities``,
    ``auth``, ``subscription``, or ``environment``) and a short
    sanitized ``reason``. Never carries raw auth JSON, environment
    values, credential material, or user-identity fields.
    """

    def __init__(self, *, stage: str, reason: str) -> None:
        self.stage = stage
        self.reason = reason
        super().__init__(f"Claude preflight failed during {stage}: {reason}")


def _build_probe_env(
    parent_env: Mapping[str, str],
    claude_config_dir: Path | None,
) -> dict[str, str]:
    if claude_config_dir is None:
        explicit: Mapping[str, str] = _EMPTY_EXPLICIT_ENV
    else:
        explicit = MappingProxyType({"CLAUDE_CONFIG_DIR": str(claude_config_dir.resolve())})
    return build_process_environment(
        parent_env,
        inherit_names=(),
        explicit_env=explicit,
        required_names=("HOME", "PATH"),
    )


def _run_claude(
    *,
    claude_executable: str,
    argv_tail: tuple[str, ...],
    probe_env: Mapping[str, str],
    cwd: Path,
    timeout_seconds: float,
    max_output_bytes: int,
) -> ProcessResult:
    return run_process(
        (claude_executable, *argv_tail),
        cwd=cwd,
        env=probe_env,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
    )


def _parse_version(stdout: str) -> tuple[str, tuple[int, int, int]]:
    stripped = stdout.strip()
    if not stripped:
        raise ClaudePreflightError(
            stage="version",
            reason="claude --version produced empty stdout",
        )
    first_line = stripped.splitlines()[0].strip()
    for token in first_line.split():
        match = _VERSION_TOKEN_RE.match(token)
        if match is not None:
            return (
                token,
                (int(match.group(1)), int(match.group(2)), int(match.group(3))),
            )
    raise ClaudePreflightError(
        stage="version",
        reason="claude --version output did not contain a recognized semantic version",
    )


def _flag_supported(help_text: str, flag: str) -> bool:
    return _FLAG_TOKEN_PATTERN[flag].search(help_text) is not None


def _parse_auth_status(
    stdout: str,
) -> tuple[bool, str | None, str | None, str | None]:
    try:
        parsed = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise ClaudePreflightError(
            stage="auth",
            reason=f"claude auth status stdout is not valid JSON ({exc.msg})",
        ) from None
    if not isinstance(parsed, dict):
        raise ClaudePreflightError(
            stage="auth",
            reason="claude auth status stdout is not a JSON object",
        )

    if "loggedIn" not in parsed:
        raise ClaudePreflightError(
            stage="auth",
            reason="'loggedIn' field is missing",
        )
    logged_in_raw = parsed["loggedIn"]
    if not isinstance(logged_in_raw, bool):
        raise ClaudePreflightError(
            stage="auth",
            reason="'loggedIn' field is not a boolean",
        )

    fields: dict[str, str | None] = {}
    for name in ("authMethod", "apiProvider", "subscriptionType"):
        if name not in parsed:
            raise ClaudePreflightError(
                stage="auth",
                reason=f"'{name}' field is missing",
            )
        raw = parsed[name]
        if raw is None:
            fields[name] = None
        elif isinstance(raw, str):
            fields[name] = raw
        else:
            raise ClaudePreflightError(
                stage="auth",
                reason=f"'{name}' field is not a string or null",
            )

    return (
        logged_in_raw,
        fields["authMethod"],
        fields["apiProvider"],
        fields["subscriptionType"],
    )


def probe_claude_cli(
    *,
    claude_executable: str,
    parent_env: Mapping[str, str],
    cwd: Path,
    claude_config_dir: Path | None = None,
    timeout_seconds: float = 15.0,
    max_output_bytes: int = 1_048_576,
) -> ClaudeCliStatus:
    """Execute the three non-inference Claude Code probes and return evidence.

    Runs ``claude --version``, ``claude --help``, and
    ``claude auth status`` under a probe environment that inherits only
    ``HOME`` and ``PATH`` from *parent_env* and, when supplied,
    substitutes an explicit ``CLAUDE_CONFIG_DIR`` resolved from
    *claude_config_dir*. No ambient Anthropic or cloud-provider
    credential variables are inherited. The returned
    :class:`ClaudeCliStatus` is diagnostic evidence only; subscription
    readiness is decided by :func:`require_claude_subscription_ready`.
    """
    resolved_cwd = cwd.resolve()
    probe_env = _build_probe_env(parent_env, claude_config_dir)

    version_result = _run_claude(
        claude_executable=claude_executable,
        argv_tail=("--version",),
        probe_env=probe_env,
        cwd=resolved_cwd,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
    )
    if version_result.returncode != 0:
        raise ClaudePreflightError(
            stage="version",
            reason=f"claude --version exited with status {version_result.returncode}",
        )
    version, version_tuple = _parse_version(version_result.stdout)
    if version_tuple < _MIN_VERSION:
        minimum = ".".join(str(component) for component in _MIN_VERSION)
        raise ClaudePreflightError(
            stage="version",
            reason=f"Claude Code >= {minimum} is required",
        )

    help_result = _run_claude(
        claude_executable=claude_executable,
        argv_tail=("--help",),
        probe_env=probe_env,
        cwd=resolved_cwd,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
    )
    if help_result.returncode != 0:
        raise ClaudePreflightError(
            stage="capabilities",
            reason=f"claude --help exited with status {help_result.returncode}",
        )
    help_text = help_result.stdout + "\n" + help_result.stderr

    auth_result = _run_claude(
        claude_executable=claude_executable,
        argv_tail=("auth", "status"),
        probe_env=probe_env,
        cwd=resolved_cwd,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
    )
    if auth_result.returncode != 0:
        raise ClaudePreflightError(
            stage="auth",
            reason=f"claude auth status exited with status {auth_result.returncode}",
        )
    logged_in, auth_method, api_provider, subscription_type = _parse_auth_status(auth_result.stdout)

    return ClaudeCliStatus(
        executable=claude_executable,
        version=version,
        logged_in=logged_in,
        auth_method=auth_method,
        api_provider=api_provider,
        subscription_type=subscription_type,
        supports_print=(_flag_supported(help_text, "-p") or _flag_supported(help_text, "--print")),
        supports_model=_flag_supported(help_text, "--model"),
        supports_effort=_flag_supported(help_text, "--effort"),
        supports_output_format=_flag_supported(help_text, "--output-format"),
        supports_json_schema=_flag_supported(help_text, "--json-schema"),
        supports_permission_mode=_flag_supported(help_text, "--permission-mode"),
        supports_permission_prompts=_flag_supported(help_text, "--permission-prompts"),
        supports_no_session_persistence=_flag_supported(help_text, "--no-session-persistence"),
        supports_restricted=_flag_supported(help_text, "--restricted"),
        supports_bare=_flag_supported(help_text, "--bare"),
        supports_tools=_flag_supported(help_text, "--tools"),
        supports_disallowed_tools=(
            _flag_supported(help_text, "--disallowedTools")
            or _flag_supported(help_text, "--disallowed-tools")
        ),
    )


def require_claude_subscription_ready(status: ClaudeCliStatus) -> ClaudeCliStatus:
    """Return *status* unchanged when it satisfies subscription policy.

    Requires the CLI to be logged in with ``authMethod`` exactly
    ``claude.ai``, ``apiProvider`` exactly ``firstParty``, and a
    ``subscriptionType`` (case-insensitive) equal to one of ``pro``,
    ``max``, ``team``, or ``enterprise``. Raises
    :class:`ClaudePreflightError` with stage ``auth`` for a
    not-logged-in status and stage ``subscription`` for every other
    policy violation.
    """
    if not status.logged_in:
        raise ClaudePreflightError(
            stage="auth",
            reason="claude CLI is not logged in",
        )
    if status.auth_method != _REQUIRED_AUTH_METHOD:
        raise ClaudePreflightError(
            stage="subscription",
            reason=(f"authMethod {status.auth_method!r} is not {_REQUIRED_AUTH_METHOD!r}"),
        )
    if status.api_provider != _REQUIRED_API_PROVIDER:
        raise ClaudePreflightError(
            stage="subscription",
            reason=(f"apiProvider {status.api_provider!r} is not {_REQUIRED_API_PROVIDER!r}"),
        )
    subscription = status.subscription_type
    if not isinstance(subscription, str):
        raise ClaudePreflightError(
            stage="subscription",
            reason="subscriptionType is missing",
        )
    normalized = subscription.strip().lower()
    if normalized not in _ACCEPTED_SUBSCRIPTION_TYPES:
        raise ClaudePreflightError(
            stage="subscription",
            reason=(
                f"subscriptionType {subscription!r} is not a supported paid Claude subscription"
            ),
        )
    return status
