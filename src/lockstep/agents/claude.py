"""Claude Code CLI subscription/capability preflight and provider adapter.

Answers deterministic yes/no questions about a configured Claude Code
executable — is it a supported version, does its help surface advertise
the flags Lockstep's adapter requires, and does its stored
authentication describe an active claude.ai first-party paid
subscription — without executing any model turn. Also detects, by
presence only, a platform-managed CLAUDE.md that would add hidden
semantics outside Lockstep's ContextPack, and constructs
deterministic Claude Code print-mode invocations for the
subscription-backed Planner, Implementer, and Reviewer roles via
:class:`ClaudeAdapter`. All external commands are executed through
:mod:`lockstep.process`; ambient Anthropic and cloud-provider
credential variables are structurally excluded from every probe and
every adapter command by the allowlist-based environment builder.
"""

from __future__ import annotations

import json
import os
import re
import sys
from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from types import MappingProxyType

from lockstep.agents.invocation import (
    AdapterOutput,
    AgentCommand,
    AgentInvocationRequest,
)
from lockstep.domain import (
    AgentRole,
    BillingMode,
    ProviderTelemetry,
    ReviewDecision,
    reported_count,
)
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
    "--safe-mode",
    "--bare",
    "--tools",
    "--disallowedTools",
    "--disallowed-tools",
    "--allowedTools",
    "--allowed-tools",
)

_FLAG_TOKEN_PATTERN: dict[str, re.Pattern[str]] = {
    flag: re.compile(rf"(?<![A-Za-z0-9_\-]){re.escape(flag)}(?![A-Za-z0-9_\-])")
    for flag in _CAPABILITY_FLAG_NAMES
}

_EMPTY_EXPLICIT_ENV: Mapping[str, str] = MappingProxyType({})

# Defense in depth around --safe-mode / --restricted: pin the built-in
# AGENTS.md plugin to CLAUDE.md-only so an operator's user settings cannot
# change native instruction discovery underneath Lockstep. Compact, sorted
# JSON so the argv is byte-deterministic.
_AGENTS_PLUGIN_SETTINGS = json.dumps(
    {
        "pluginConfigs": {
            "cc-plugin-agents-md@builtin": {"options": {"instructionFiles": "claude-md"}}
        }
    },
    separators=(",", ":"),
    sort_keys=True,
)

_MANAGED_INSTRUCTIONS_PATHS: Mapping[str, Path] = MappingProxyType(
    {
        "darwin": Path("/Library/Application Support/ClaudeCode/CLAUDE.md"),
        "win32": Path("C:\\Program Files\\ClaudeCode\\CLAUDE.md"),
    }
)
_LINUX_MANAGED_INSTRUCTIONS_PATH = Path("/etc/claude-code/CLAUDE.md")

# The one Claude provider environment policy, shared by the preflight probes
# and every ClaudeAdapter command. HOME and PATH are required; USER is
# inherited only when the operator environment supplies it (macOS
# keychain-backed subscription login is looked up by user name). No other
# ambient variable reaches a Claude process.
_CLAUDE_REQUIRED_ENV_NAMES: tuple[str, ...] = ("HOME", "PATH")
_CLAUDE_INHERITED_ENV_NAMES: tuple[str, ...] = ("USER",)

_SUPPORTED_ADAPTER_ROLES: frozenset[AgentRole] = frozenset(
    {AgentRole.PLANNER, AgentRole.IMPLEMENTER, AgentRole.REVIEWER}
)
_ROLE_TOOLS: Mapping[AgentRole, str] = MappingProxyType(
    {
        AgentRole.PLANNER: "Read,Write,Edit,Glob,Grep",
        AgentRole.IMPLEMENTER: "Read,Write,Edit,Glob,Grep",
        AgentRole.REVIEWER: "Read,Glob,Grep",
    }
)
_DISALLOWED_TOOLS = "mcp__*"


@dataclass(frozen=True, slots=True)
class ClaudeCliStatus:
    """Bounded evidence gathered by the Claude Code preflight.

    Captures the executable path used, its normalized semantic version,
    the four fields Lockstep reads from ``claude auth status``
    (``loggedIn``, ``authMethod``, ``apiProvider``, ``subscriptionType``),
    and one boolean per Phase-6 CLI flag observed in the installed help
    surface, plus whether a platform-managed CLAUDE.md is present.
    ``supports_bare`` is diagnostic only: ``--bare`` is
    incompatible with claude.ai subscription OAuth and is never used by
    :class:`ClaudeAdapter`. Deliberately excludes email, organization
    identifiers, credential paths, managed instruction paths or contents,
    and any auth-token material.
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

    supports_safe_mode: bool = False
    supports_allowed_tools: bool = False

    managed_instructions_present: bool = False


class ClaudePreflightError(Exception):
    """A stage of the Claude Code preflight rejected the observed evidence.

    Carries the failing ``stage`` (``version``, ``capabilities``,
    ``auth``, ``subscription``, ``environment``, or ``policy``) and a short
    sanitized ``reason``. Never carries raw auth JSON, environment
    values, credential material, or user-identity fields.
    """

    def __init__(self, *, stage: str, reason: str) -> None:
        self.stage = stage
        self.reason = reason
        super().__init__(f"Claude preflight failed during {stage}: {reason}")


def managed_claude_instructions_path(platform: str = sys.platform) -> Path:
    """Return the platform-managed Claude Code CLAUDE.md location for *platform*.

    macOS uses ``/Library/Application Support/ClaudeCode``, Windows
    ``C:\\Program Files\\ClaudeCode``, and every other platform (Linux, WSL)
    ``/etc/claude-code``. The file is only ever checked for presence.
    """
    return _MANAGED_INSTRUCTIONS_PATHS.get(platform, _LINUX_MANAGED_INSTRUCTIONS_PATH)


def claude_inherited_environment(parent_env: Mapping[str, str]) -> Mapping[str, str]:
    """Return the optional variables a Claude process inherits from *parent_env*.

    Exactly ``USER`` when *parent_env* supplies it, and nothing otherwise; a
    missing ``USER`` is never invented. The result is what
    :class:`ClaudeAdapter` binds as ``inherited_env`` so inference commands
    reproduce the environment under which the preflight probes ran.
    """
    selected = {
        name: parent_env[name] for name in _CLAUDE_INHERITED_ENV_NAMES if name in parent_env
    }
    return MappingProxyType(build_process_environment(selected, inherit_names=()))


def _claude_explicit_env(
    inherited_env: Mapping[str, str],
    claude_config_dir: Path | None,
) -> Mapping[str, str]:
    if not inherited_env and claude_config_dir is None:
        return _EMPTY_EXPLICIT_ENV
    explicit = dict(inherited_env)
    if claude_config_dir is not None:
        explicit["CLAUDE_CONFIG_DIR"] = str(claude_config_dir.resolve())
    return MappingProxyType(explicit)


def _build_probe_env(
    parent_env: Mapping[str, str],
    claude_config_dir: Path | None,
) -> dict[str, str]:
    required_source = {
        name: parent_env[name] for name in _CLAUDE_REQUIRED_ENV_NAMES if name in parent_env
    }
    return build_process_environment(
        required_source,
        inherit_names=(),
        explicit_env=_claude_explicit_env(
            claude_inherited_environment(parent_env), claude_config_dir
        ),
        required_names=_CLAUDE_REQUIRED_ENV_NAMES,
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
    managed_instructions_path: Path | None = None,
) -> ClaudeCliStatus:
    """Execute the three non-inference Claude Code probes and return evidence.

    Runs ``claude --version``, ``claude --help``, and
    ``claude auth status`` under the Claude provider environment: ``HOME``
    and ``PATH`` (required) and ``USER`` (when present) from *parent_env*
    and, when supplied, an explicit ``CLAUDE_CONFIG_DIR`` resolved from
    *claude_config_dir*. No other ambient variable, and in particular no
    Anthropic or cloud-provider credential variable, is inherited. Also
    records, by presence only, whether a managed CLAUDE.md exists at
    *managed_instructions_path* (by default
    :func:`managed_claude_instructions_path`). The returned
    :class:`ClaudeCliStatus` is diagnostic evidence only; subscription
    readiness is decided by :func:`require_claude_subscription_ready` and
    semantic isolation by :func:`require_claude_instruction_isolation`.
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

    managed_path = (
        managed_claude_instructions_path()
        if managed_instructions_path is None
        else managed_instructions_path
    )

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
        supports_safe_mode=_flag_supported(help_text, "--safe-mode"),
        supports_allowed_tools=(
            _flag_supported(help_text, "--allowedTools")
            or _flag_supported(help_text, "--allowed-tools")
        ),
        # Presence only: the managed file is never opened or read.
        managed_instructions_present=os.path.lexists(managed_path),
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


def require_claude_instruction_isolation(status: ClaudeCliStatus) -> ClaudeCliStatus:
    """Return *status* unchanged when no managed CLAUDE.md is present.

    A managed CLAUDE.md is organization prompt content that Lockstep cannot
    prove ``--safe-mode`` suppresses, so it would reach the model as hidden
    Claude-only semantics. Raises :class:`ClaudePreflightError` with stage
    ``policy``; the reason names neither path nor contents. Managed
    settings (execution constraints) are unaffected.
    """
    if status.managed_instructions_present:
        raise ClaudePreflightError(
            stage="policy",
            reason=(
                "a managed Claude instruction file is present; canonical Lockstep "
                "execution requires provider-neutral project semantics"
            ),
        )
    return status


class ClaudeAdapterError(Exception):
    """Claude adapter rejected its role/billing/model configuration.

    Carries a short sanitized ``reason``. Never carries the request
    prompt, the child stdin payload, environment values, stored Claude
    auth contents, or raw process output.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"Claude adapter error: {reason}")


def _require_nonblank_config(*, field: str, value: str) -> str:
    if not isinstance(value, str):
        raise ClaudeAdapterError(f"{field} must be a string")
    if not value.strip():
        raise ClaudeAdapterError(f"{field} must not be blank")
    if "\x00" in value:
        raise ClaudeAdapterError(f"{field} must not contain NUL")
    return value


def _require_adapter_capabilities(status: ClaudeCliStatus, role: AgentRole) -> None:
    required: list[tuple[str, bool]] = [
        ("-p/--print", status.supports_print),
        ("--model", status.supports_model),
        ("--effort", status.supports_effort),
        ("--output-format", status.supports_output_format),
        ("--permission-prompts", status.supports_permission_prompts),
        ("--no-session-persistence", status.supports_no_session_persistence),
        ("--restricted", status.supports_restricted),
        ("--safe-mode", status.supports_safe_mode),
        ("--tools", status.supports_tools),
        ("--allowedTools", status.supports_allowed_tools),
        ("--disallowedTools", status.supports_disallowed_tools),
    ]
    if role is AgentRole.REVIEWER:
        required.append(("--json-schema", status.supports_json_schema))
    missing = [flag for flag, supported in required if not supported]
    if missing:
        raise ClaudePreflightError(
            stage="capabilities",
            reason="claude is missing required option(s): " + ", ".join(missing),
        )


def _canonical_review_schema_json() -> str:
    return json.dumps(
        ReviewDecision.model_json_schema(),
        ensure_ascii=False,
        separators=(",", ":"),
        sort_keys=True,
    )


def _optional_str(value: object) -> str | None:
    return value if isinstance(value, str) and value else None


def _parse_result_envelope(stdout: str) -> AdapterOutput:
    """Read a ``claude -p --output-format json`` result envelope.

    The envelope's ``result`` string is the content orchestrators consume (for
    ``--json-schema`` runs it is the canonical artifact JSON). Telemetry is read
    only from fields Claude reports: ``usage`` token counts, the single model
    key of ``modelUsage`` and ``session_id``. ``input_tokens`` is derived only
    as the exact sum of Claude's three disjoint input categories, and only when
    all three are reported. The envelope's monetary fields are list-price
    figures, not what a subscription is billed, and are deliberately never
    read. Anything that is not a result envelope passes through unchanged with
    all telemetry unavailable; this function never raises.
    """
    passthrough = AdapterOutput(content=stdout)
    try:
        envelope = json.loads(stdout)
    except (ValueError, RecursionError):
        return passthrough
    if not isinstance(envelope, dict) or envelope.get("type") != "result":
        return passthrough

    result = envelope.get("result")
    content = result if isinstance(result, str) else stdout

    usage = envelope.get("usage")
    counts = usage if isinstance(usage, dict) else {}
    uncached = reported_count(counts.get("input_tokens"))
    cache_read = reported_count(counts.get("cache_read_input_tokens"))
    cache_write = reported_count(counts.get("cache_creation_input_tokens"))
    total_input = (
        uncached + cache_read + cache_write
        if uncached is not None and cache_read is not None and cache_write is not None
        else None
    )

    model_usage = envelope.get("modelUsage")
    reported_model = (
        _optional_str(next(iter(model_usage)))
        if isinstance(model_usage, dict) and len(model_usage) == 1
        else None
    )

    return AdapterOutput(
        content=content,
        telemetry=ProviderTelemetry(
            reported_model=reported_model,
            provider_session_id=_optional_str(envelope.get("session_id")),
            input_tokens=total_input,
            uncached_input_tokens=uncached,
            cache_read_tokens=cache_read,
            cache_write_tokens=cache_write,
            output_tokens=reported_count(counts.get("output_tokens")),
        ),
    )


@dataclass(frozen=True, slots=True)
class ClaudeAdapter:
    """Subscription-backed Claude Code print-mode command builder.

    A :class:`ClaudeAdapter` is role-bound: it constructs deterministic
    ``claude -p`` invocations for exactly one of the Planner,
    Implementer, or Reviewer roles under
    :attr:`BillingMode.SUBSCRIPTION_ONLY`. Construction requires
    subscription readiness via :func:`require_claude_subscription_ready`
    plus the adapter's CLI capability surface (``--safe-mode`` and
    ``--allowedTools`` included; ``--bare`` never), and rejects a status
    reporting a managed CLAUDE.md. Every command pins
    the configured model and effort, runs in safe, restricted,
    non-persistent print mode, with the built-in AGENTS.md plugin pinned to
    CLAUDE.md-only by an explicit ``--settings`` payload, permission prompts
    disabled and JSON
    result-envelope output, exposes an explicit role-specific tool list, and
    denies MCP tools. :meth:`normalize_output` unwraps that envelope so
    orchestrators see only the content (and usage is attributed from it). The
    Reviewer additionally receives the canonical :class:`ReviewDecision` JSON
    Schema inline so its envelope ``result`` is the raw canonical artifact.
    The prompt is transported only through :attr:`AgentCommand.stdin_text`.
    ``inherited_env`` is the Claude provider environment's optional part
    (``USER`` only, as produced by :func:`claude_inherited_environment`),
    bound at resolution so every command reproduces the preflight's
    environment over a ``HOME``/``PATH`` parent; it is excluded from
    :func:`repr`. Construction and ``build_command`` perform no process,
    filesystem, or network work.
    """

    role: AgentRole
    status: ClaudeCliStatus
    model: str
    effort: str
    claude_config_dir: Path | None = None
    inherited_env: Mapping[str, str] = field(default=_EMPTY_EXPLICIT_ENV, repr=False, hash=False)

    @property
    def name(self) -> str:
        return "claude"

    @property
    def configured_model(self) -> str:
        return self.model

    @property
    def configured_effort(self) -> str:
        return self.effort

    def normalize_output(self, process: ProcessResult) -> AdapterOutput:
        """Unwrap the print-mode JSON result envelope into content plus telemetry."""
        return _parse_result_envelope(process.stdout)

    def __post_init__(self) -> None:
        if self.role not in _SUPPORTED_ADAPTER_ROLES:
            raise ClaudeAdapterError(f"unsupported role {self.role.value!r}")

        _require_nonblank_config(field="model", value=self.model)
        _require_nonblank_config(field="effort", value=self.effort)

        if self.claude_config_dir is not None:
            resolved = Path(self.claude_config_dir).resolve()
            object.__setattr__(self, "claude_config_dir", resolved)

        unapproved = sorted(set(self.inherited_env) - set(_CLAUDE_INHERITED_ENV_NAMES))
        if unapproved:
            raise ClaudeAdapterError(
                "inherited_env may bind only "
                + ", ".join(_CLAUDE_INHERITED_ENV_NAMES)
                + "; got "
                + ", ".join(unapproved)
            )
        object.__setattr__(self, "inherited_env", MappingProxyType(dict(self.inherited_env)))

        require_claude_subscription_ready(self.status)
        require_claude_instruction_isolation(self.status)
        _require_adapter_capabilities(self.status, self.role)

    def build_command(self, request: AgentInvocationRequest) -> AgentCommand:
        """Construct the deterministic Claude Code command for *request*.

        Validates that *request*'s role matches this adapter and that
        the billing mode is :attr:`BillingMode.SUBSCRIPTION_ONLY`, then
        assembles the fixed Sub-phase 6.3 argv with the prompt bound
        only to :attr:`AgentCommand.stdin_text`, and ``USER`` (from
        ``inherited_env``) and ``CLAUDE_CONFIG_DIR`` bound only to
        :attr:`AgentCommand.explicit_env` when configured.
        """
        if request.role is not self.role:
            raise ClaudeAdapterError(
                "request role does not match configured Claude adapter role",
            )
        if request.billing_mode is not BillingMode.SUBSCRIPTION_ONLY:
            raise ClaudeAdapterError(
                "Claude adapter supports SUBSCRIPTION_ONLY billing only; "
                f"got {request.billing_mode.value!r}",
            )

        tools = _ROLE_TOOLS[self.role]
        argv: list[str] = [
            self.status.executable,
            "-p",
            "--safe-mode",
            "--restricted",
            "--settings",
            _AGENTS_PLUGIN_SETTINGS,
            "--no-session-persistence",
            "--permission-prompts",
            "none",
            "--model",
            self.model,
            "--effort",
            self.effort,
            "--output-format",
            "json",
            "--tools",
            tools,
            "--allowedTools",
            tools,
            "--disallowedTools",
            _DISALLOWED_TOOLS,
        ]
        if self.role is AgentRole.REVIEWER:
            argv.extend(("--json-schema", _canonical_review_schema_json()))

        return AgentCommand(
            argv=tuple(argv),
            inherit_names=(),
            explicit_env=_claude_explicit_env(self.inherited_env, self.claude_config_dir),
            required_names=_CLAUDE_REQUIRED_ENV_NAMES,
            stdin_text=request.prompt,
        )
