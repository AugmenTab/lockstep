"""Codex CLI subscription/capability preflight and provider adapter.

Answers deterministic yes/no questions about a configured Codex
executable — is it usable, does it expose the exec options Lockstep's
adapter needs, is its stored authentication explicitly ChatGPT-backed,
and are stored API-key credentials absent — without executing any
model turn. Also detects, by presence only, a global Codex instruction
file that would add hidden semantics outside Lockstep's ContextPack, and
constructs deterministic Codex ``exec`` invocations for the
subscription-backed Planner, Implementer, and Reviewer roles via
:class:`CodexAdapter`. All external commands are executed through
:mod:`lockstep.process`; ambient OpenAI/Codex API credentials are
structurally excluded from every probe and every adapter command.
"""

from __future__ import annotations

import json
import os
import re
from collections.abc import Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType

from lockstep.agents.invocation import (
    AdapterOutput,
    AgentCommand,
    AgentInvocationRequest,
)
from lockstep.domain import AgentRole, BillingMode, ProviderTelemetry, reported_count
from lockstep.process import (
    ProcessResult,
    build_process_environment,
    run_process,
)

_REQUIRED_EXEC_CAPABILITIES: tuple[str, ...] = (
    "--ephemeral",
    "--ignore-user-config",
    "--sandbox",
    "--color",
)

_ADDITIONAL_HELP_TOKENS: tuple[str, ...] = (
    "--ignore-rules",
    "--output-schema",
)

# The generic per-run config override mechanism (``-c, --config <key=value>``).
# Diagnosis qualifies that the mechanism exists; it cannot prove that any
# individual key is understood by the installed Codex.
_CONFIG_OVERRIDE_TOKENS: tuple[str, ...] = ("-c", "--config")

# Codex's global instruction files under the effective CODEX_HOME. Project
# AGENTS discovery is disabled per run, but these are not covered by that
# override, so their presence fails closed.
_GLOBAL_INSTRUCTION_FILE_NAMES: tuple[str, ...] = ("AGENTS.md", "AGENTS.override.md")

# Per-run overrides that disable Codex-native project semantics: project
# AGENTS.md discovery and native skill instruction injection. Project
# instructions and skills reach Codex only through the ContextPack prompt.
_SEMANTIC_SUPPRESSION_CONFIG: tuple[str, ...] = (
    "project_doc_max_bytes=0",
    "skills.include_instructions=false",
)

_AUTH_CHECK_KEY = "auth.credentials"
_SUPPORTED_DOCTOR_SCHEMA_VERSION = 1

_DETAIL_STORED_AUTH_MODE = "stored auth mode"
_DETAIL_STORED_CHATGPT_TOKENS = "stored ChatGPT tokens"
_DETAIL_STORED_API_KEY = "stored API key"

_REQUIRED_STORED_AUTH_MODE = "chatgpt"
_REQUIRED_AUTH_CHECK_STATUS = "ok"

_FLAG_TOKEN_PATTERN: dict[str, re.Pattern[str]] = {
    flag: re.compile(rf"(?<![A-Za-z0-9_\-]){re.escape(flag)}(?![A-Za-z0-9_\-])")
    for flag in (*_REQUIRED_EXEC_CAPABILITIES, *_ADDITIONAL_HELP_TOKENS, *_CONFIG_OVERRIDE_TOKENS)
}

_SUPPORTED_ADAPTER_ROLES: frozenset[AgentRole] = frozenset(
    {AgentRole.PLANNER, AgentRole.IMPLEMENTER, AgentRole.REVIEWER}
)
_ROLE_SANDBOX: Mapping[AgentRole, str] = MappingProxyType(
    {
        AgentRole.PLANNER: "workspace-write",
        AgentRole.IMPLEMENTER: "workspace-write",
        AgentRole.REVIEWER: "read-only",
    }
)

_EMPTY_EXPLICIT_ENV: Mapping[str, str] = MappingProxyType({})


@dataclass(frozen=True, slots=True)
class CodexCliStatus:
    """Diagnostic and capability evidence gathered by the Codex preflight.

    Captures only high-level structural signals: the executable path
    used, its self-reported version string, the doctor schema version,
    doctor overall status, doctor process return code, the
    ``auth.credentials`` check status, the three stored-credential
    detail values, the exec-flag capability booleans, and whether a
    global Codex instruction file is present under the effective
    ``CODEX_HOME``. Deliberately excludes raw doctor stdout/stderr,
    environment values, auth tokens, API-key values, instruction file
    paths or contents, and any ``HOME`` contents.
    """

    executable: str
    version: str

    doctor_schema_version: int
    doctor_overall_status: str
    doctor_returncode: int

    auth_check_status: str
    stored_auth_mode: str | None
    stored_chatgpt_tokens: bool | None
    stored_api_key: bool | None

    supports_exec_ephemeral: bool
    supports_exec_ignore_user_config: bool
    supports_exec_sandbox: bool
    supports_exec_color: bool

    supports_exec_ignore_rules: bool = False
    supports_exec_output_schema: bool = False

    global_instructions_present: bool = False


class CodexPreflightError(Exception):
    """A stage of the Codex preflight rejected the observed evidence.

    Carries the failing ``stage`` (``version``, ``capabilities``,
    ``doctor``, ``auth``, or ``policy``) and a short sanitized
    ``reason``. Never carries raw doctor stdout/stderr, environment
    values, auth tokens, API-key values, or instruction file paths or
    contents.
    """

    def __init__(self, *, stage: str, reason: str) -> None:
        self.stage = stage
        self.reason = reason
        super().__init__(f"Codex preflight failed during {stage}: {reason}")


def _build_probe_env(
    parent_env: Mapping[str, str],
    codex_home: Path | None,
) -> dict[str, str]:
    if codex_home is None:
        explicit: Mapping[str, str] = _EMPTY_EXPLICIT_ENV
    else:
        explicit = MappingProxyType({"CODEX_HOME": str(codex_home.resolve())})
    return build_process_environment(
        parent_env,
        inherit_names=(),
        explicit_env=explicit,
        required_names=("HOME", "PATH"),
    )


def _run_codex(
    *,
    codex_executable: str,
    argv_tail: tuple[str, ...],
    probe_env: Mapping[str, str],
    cwd: Path,
    timeout_seconds: float,
    max_output_bytes: int,
) -> ProcessResult:
    return run_process(
        (codex_executable, *argv_tail),
        cwd=cwd,
        env=probe_env,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
    )


def _flag_supported(help_text: str, flag: str) -> bool:
    return _FLAG_TOKEN_PATTERN[flag].search(help_text) is not None


def _global_instructions_present(probe_env: Mapping[str, str], codex_home: Path | None) -> bool:
    # The effective home is the explicit override, else $HOME/.codex; an
    # ambient CODEX_HOME is never forwarded, so it is never consulted.
    # Presence only: nothing is opened or read.
    home = codex_home.resolve() if codex_home is not None else Path(probe_env["HOME"]) / ".codex"
    return any(os.path.lexists(home / name) for name in _GLOBAL_INSTRUCTION_FILE_NAMES)


def _parse_optional_bool(value: object) -> bool | None:
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        lowered = value.strip().lower()
        if lowered == "true":
            return True
        if lowered == "false":
            return False
    return None


def _iter_auth_details(details: object) -> Iterator[tuple[str, object]]:
    if isinstance(details, list):
        for item in details:
            if isinstance(item, dict):
                name = item.get("name")
                if isinstance(name, str):
                    yield name, item.get("value")
    elif isinstance(details, dict):
        for name, value in details.items():
            if isinstance(name, str):
                yield name, value


@dataclass(frozen=True, slots=True)
class _DoctorEvidence:
    schema_version: int
    overall_status: str
    auth_check_status: str
    stored_auth_mode: str | None
    stored_chatgpt_tokens: bool | None
    stored_api_key: bool | None


def _parse_doctor_stdout(stdout: str) -> _DoctorEvidence:
    try:
        parsed = json.loads(stdout)
    except json.JSONDecodeError as exc:
        raise CodexPreflightError(
            stage="doctor",
            reason=f"doctor stdout is not valid JSON ({exc.msg})",
        ) from None
    if not isinstance(parsed, dict):
        raise CodexPreflightError(
            stage="doctor",
            reason="doctor stdout is not a JSON object",
        )
    schema_version = parsed.get("schemaVersion")
    if isinstance(schema_version, bool) or not isinstance(schema_version, int):
        raise CodexPreflightError(
            stage="doctor",
            reason="doctor 'schemaVersion' is missing or not an integer",
        )
    if schema_version != _SUPPORTED_DOCTOR_SCHEMA_VERSION:
        raise CodexPreflightError(
            stage="doctor",
            reason=f"unsupported doctor schemaVersion {schema_version}",
        )
    checks = parsed.get("checks")
    if not isinstance(checks, dict):
        raise CodexPreflightError(
            stage="doctor",
            reason="doctor 'checks' is missing or not an object",
        )
    auth_check = checks.get(_AUTH_CHECK_KEY)
    if not isinstance(auth_check, dict):
        raise CodexPreflightError(
            stage="doctor",
            reason=f"doctor 'checks.{_AUTH_CHECK_KEY}' is missing or not an object",
        )
    auth_status = auth_check.get("status")
    if not isinstance(auth_status, str):
        raise CodexPreflightError(
            stage="doctor",
            reason=f"doctor '{_AUTH_CHECK_KEY}.status' is missing or not a string",
        )

    stored_mode: str | None = None
    stored_chatgpt: bool | None = None
    stored_api: bool | None = None
    for name, value in _iter_auth_details(auth_check.get("details")):
        if name == _DETAIL_STORED_AUTH_MODE:
            stored_mode = value if isinstance(value, str) else None
        elif name == _DETAIL_STORED_CHATGPT_TOKENS:
            stored_chatgpt = _parse_optional_bool(value)
        elif name == _DETAIL_STORED_API_KEY:
            stored_api = _parse_optional_bool(value)

    overall_raw = parsed.get("overallStatus")
    overall_status = overall_raw if isinstance(overall_raw, str) else ""

    return _DoctorEvidence(
        schema_version=schema_version,
        overall_status=overall_status,
        auth_check_status=auth_status,
        stored_auth_mode=stored_mode,
        stored_chatgpt_tokens=stored_chatgpt,
        stored_api_key=stored_api,
    )


def probe_codex_cli(
    *,
    codex_executable: str,
    parent_env: Mapping[str, str],
    cwd: Path,
    codex_home: Path | None = None,
    timeout_seconds: float = 15.0,
    max_output_bytes: int = 1_048_576,
) -> CodexCliStatus:
    """Execute the three non-inference Codex probes and return evidence.

    Runs ``codex --version``, ``codex exec --help``, and
    ``codex doctor --json`` under a probe environment that inherits only
    ``HOME`` and ``PATH`` from *parent_env* and, when supplied,
    substitutes an explicit ``CODEX_HOME`` from *codex_home*. No
    ambient OpenAI/Codex API credential variables are inherited. Also
    records, by presence only, whether a global ``AGENTS.md`` or
    ``AGENTS.override.md`` exists under the effective ``CODEX_HOME``.
    The returned :class:`CodexCliStatus` is diagnostic evidence only;
    subscription readiness is decided by
    :func:`require_codex_subscription_ready` and semantic isolation by
    :func:`require_codex_instruction_isolation`.
    """
    status, _help_text = _probe_codex_evidence(
        codex_executable=codex_executable,
        parent_env=parent_env,
        cwd=cwd,
        codex_home=codex_home,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
    )
    return status


def diagnose_codex_cli(
    *,
    codex_executable: str,
    parent_env: Mapping[str, str],
    cwd: Path,
    codex_home: Path | None = None,
    timeout_seconds: float = 15.0,
    max_output_bytes: int = 1_048_576,
) -> CodexCliStatus:
    """Return canonical-execution-ready Codex evidence or raise.

    Runs the same probes as :func:`probe_codex_cli`, then requires that
    ``codex exec --help`` advertises the generic per-run config override
    mechanism (``-c`` / ``--config``) that every :class:`CodexAdapter`
    command depends on, then applies
    :func:`require_codex_subscription_ready` and
    :func:`require_codex_instruction_isolation`. The help check
    qualifies the mechanism only; it does not establish that any
    individual config key is understood by the installed Codex.
    """
    status, help_text = _probe_codex_evidence(
        codex_executable=codex_executable,
        parent_env=parent_env,
        cwd=cwd,
        codex_home=codex_home,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
    )
    if not all(_flag_supported(help_text, token) for token in _CONFIG_OVERRIDE_TOKENS):
        raise CodexPreflightError(
            stage="capabilities",
            reason="codex exec is missing required option(s): -c/--config",
        )
    return require_codex_instruction_isolation(require_codex_subscription_ready(status))


def _probe_codex_evidence(
    *,
    codex_executable: str,
    parent_env: Mapping[str, str],
    cwd: Path,
    codex_home: Path | None,
    timeout_seconds: float,
    max_output_bytes: int,
) -> tuple[CodexCliStatus, str]:
    resolved_cwd = cwd.resolve()
    probe_env = _build_probe_env(parent_env, codex_home)

    version_result = _run_codex(
        codex_executable=codex_executable,
        argv_tail=("--version",),
        probe_env=probe_env,
        cwd=resolved_cwd,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
    )
    if version_result.returncode != 0:
        raise CodexPreflightError(
            stage="version",
            reason=(f"codex --version exited with status {version_result.returncode}"),
        )
    version = version_result.stdout.strip()
    if not version:
        raise CodexPreflightError(
            stage="version",
            reason="codex --version produced empty stdout",
        )

    help_result = _run_codex(
        codex_executable=codex_executable,
        argv_tail=("exec", "--help"),
        probe_env=probe_env,
        cwd=resolved_cwd,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
    )
    if help_result.returncode != 0:
        raise CodexPreflightError(
            stage="capabilities",
            reason=(f"codex exec --help exited with status {help_result.returncode}"),
        )
    help_text = help_result.stdout + "\n" + help_result.stderr

    doctor_result = _run_codex(
        codex_executable=codex_executable,
        argv_tail=("doctor", "--json"),
        probe_env=probe_env,
        cwd=resolved_cwd,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
    )
    evidence = _parse_doctor_stdout(doctor_result.stdout)

    status = CodexCliStatus(
        executable=codex_executable,
        version=version,
        doctor_schema_version=evidence.schema_version,
        doctor_overall_status=evidence.overall_status,
        doctor_returncode=doctor_result.returncode,
        auth_check_status=evidence.auth_check_status,
        stored_auth_mode=evidence.stored_auth_mode,
        stored_chatgpt_tokens=evidence.stored_chatgpt_tokens,
        stored_api_key=evidence.stored_api_key,
        supports_exec_ephemeral=_flag_supported(help_text, "--ephemeral"),
        supports_exec_ignore_user_config=_flag_supported(help_text, "--ignore-user-config"),
        supports_exec_sandbox=_flag_supported(help_text, "--sandbox"),
        supports_exec_color=_flag_supported(help_text, "--color"),
        supports_exec_ignore_rules=_flag_supported(help_text, "--ignore-rules"),
        supports_exec_output_schema=_flag_supported(help_text, "--output-schema"),
        global_instructions_present=_global_instructions_present(probe_env, codex_home),
    )
    return status, help_text


def require_codex_subscription_ready(status: CodexCliStatus) -> CodexCliStatus:
    """Return *status* unchanged when it satisfies subscription policy.

    Requires all four future-adapter exec capabilities to be present
    and requires the ``auth.credentials`` check to report ``ok`` with
    an exact ``chatgpt`` stored auth mode, stored ChatGPT tokens
    present, and no stored API-key credential. Raises
    :class:`CodexPreflightError` with stage ``capabilities`` or
    ``auth`` when any predicate is not satisfied.
    """
    missing = [
        flag
        for flag, supported in (
            ("--ephemeral", status.supports_exec_ephemeral),
            ("--ignore-user-config", status.supports_exec_ignore_user_config),
            ("--sandbox", status.supports_exec_sandbox),
            ("--color", status.supports_exec_color),
        )
        if not supported
    ]
    if missing:
        raise CodexPreflightError(
            stage="capabilities",
            reason=("codex exec is missing required option(s): " + ", ".join(missing)),
        )
    if status.auth_check_status != _REQUIRED_AUTH_CHECK_STATUS:
        raise CodexPreflightError(
            stage="auth",
            reason=(
                f"codex doctor '{_AUTH_CHECK_KEY}.status' is "
                f"{status.auth_check_status!r}, expected "
                f"{_REQUIRED_AUTH_CHECK_STATUS!r}"
            ),
        )
    if status.stored_auth_mode != _REQUIRED_STORED_AUTH_MODE:
        raise CodexPreflightError(
            stage="auth",
            reason=(
                f"stored auth mode {status.stored_auth_mode!r} is not "
                f"{_REQUIRED_STORED_AUTH_MODE!r}"
            ),
        )
    if status.stored_chatgpt_tokens is not True:
        raise CodexPreflightError(
            stage="auth",
            reason="stored ChatGPT tokens are not present",
        )
    if status.stored_api_key is not False:
        raise CodexPreflightError(
            stage="auth",
            reason=("a stored API-key credential is present; SUBSCRIPTION_ONLY requires none"),
        )
    return status


def require_codex_instruction_isolation(status: CodexCliStatus) -> CodexCliStatus:
    """Return *status* unchanged when no global Codex instruction file is present.

    A global ``AGENTS.md`` / ``AGENTS.override.md`` under the effective
    ``CODEX_HOME`` would reach the model as instructions that are not
    Lockstep-selected project semantics and are not suppressed by the
    per-run project-doc override. Raises :class:`CodexPreflightError`
    with stage ``policy``; the reason names neither path nor contents.
    """
    if status.global_instructions_present:
        raise CodexPreflightError(
            stage="policy",
            reason=(
                "a global Codex instruction file is present; canonical Lockstep "
                "execution requires provider-neutral project semantics"
            ),
        )
    return status


class CodexAdapterError(Exception):
    """Codex adapter rejected its role/billing/model/schema configuration.

    Carries a short sanitized ``reason``. Never carries the request
    prompt, the child stdin payload, environment values, stored Codex
    auth contents, or raw process output.
    """

    def __init__(self, *, reason: str) -> None:
        self.reason = reason
        super().__init__(f"Codex adapter error: {reason}")


def _require_nonblank_config(*, field: str, value: str) -> str:
    if not isinstance(value, str):
        raise CodexAdapterError(reason=f"{field} must be a string")
    if not value.strip():
        raise CodexAdapterError(reason=f"{field} must not be blank")
    if "\x00" in value:
        raise CodexAdapterError(reason=f"{field} must not contain NUL")
    return value


def _parse_jsonl_events(stdout: str) -> list[dict[str, object]]:
    events: list[dict[str, object]] = []
    for line in stdout.splitlines():
        try:
            parsed = json.loads(line)
        except (ValueError, RecursionError):
            continue  # tail-bounded capture may cut the stream head mid-line
        if isinstance(parsed, dict):
            events.append(parsed)
    return events


def _parse_exec_jsonl(stdout: str) -> AdapterOutput:
    """Read ``codex exec --json`` JSONL events.

    The final message is the text of the last ``agent_message`` item. Telemetry
    is read from the last ``turn.completed`` ``usage`` and the ``thread.started``
    thread id; the CLI does not report the model, so it stays unavailable.
    Codex's ``input_tokens`` already includes its cached subset, so it is the
    total input and ``uncached_input_tokens`` is derived as the exact
    difference -- only when both are reported and the cached count does not
    exceed the total. Output that is not Codex JSONL passes through unchanged
    with all telemetry unavailable; this function never raises.
    """
    events = _parse_jsonl_events(stdout)
    if not events or not any(isinstance(e.get("type"), str) for e in events):
        return AdapterOutput(content=stdout)

    content = ""
    session_id: str | None = None
    usage: dict[str, object] = {}
    for event in events:
        kind = event.get("type")
        if kind == "thread.started":
            thread_id = event.get("thread_id")
            session_id = thread_id if isinstance(thread_id, str) and thread_id else session_id
        elif kind == "item.completed":
            item = event.get("item")
            if isinstance(item, dict) and item.get("type") == "agent_message":
                text = item.get("text")
                if isinstance(text, str):
                    content = text
        elif kind == "turn.completed":
            reported = event.get("usage")
            if isinstance(reported, dict):
                usage = reported

    total_input = reported_count(usage.get("input_tokens"))
    cached = reported_count(usage.get("cached_input_tokens"))
    uncached = (
        total_input - cached
        if total_input is not None and cached is not None and cached <= total_input
        else None
    )
    return AdapterOutput(
        content=content,
        telemetry=ProviderTelemetry(
            provider_session_id=session_id,
            input_tokens=total_input,
            uncached_input_tokens=uncached,
            cache_read_tokens=cached,
            cache_write_tokens=reported_count(usage.get("cache_write_input_tokens")),
            output_tokens=reported_count(usage.get("output_tokens")),
        ),
    )


@dataclass(frozen=True, slots=True)
class CodexAdapter:
    """Subscription-backed Codex ``exec`` command builder.

    A :class:`CodexAdapter` is role-bound: it constructs deterministic
    Codex ``exec`` invocations for exactly one of the Planner,
    Implementer, or Reviewer roles under
    :attr:`BillingMode.SUBSCRIPTION_ONLY`. Construction requires
    subscription-ready capability evidence via
    :func:`require_codex_subscription_ready` plus the additional
    ``--ignore-rules`` capability and, for Reviewer, the
    ``--output-schema`` capability, and rejects a status reporting a
    global Codex instruction file. Every command disables Codex-native
    project AGENTS discovery and native skill instruction injection
    through per-run config overrides. The prompt is transported through
    :attr:`AgentCommand.stdin_text`; it never appears in argv or in
    the explicit environment. ``build_command`` performs no process,
    filesystem, or network work.
    """

    role: AgentRole
    status: CodexCliStatus
    model: str
    reasoning_effort: str
    codex_home: Path | None = None
    review_output_schema_path: Path | None = None

    @property
    def name(self) -> str:
        return "codex"

    @property
    def configured_model(self) -> str:
        return self.model

    @property
    def configured_effort(self) -> str:
        return self.reasoning_effort

    def normalize_output(self, process: ProcessResult) -> AdapterOutput:
        """Reduce ``exec --json`` JSONL events to the final message plus telemetry."""
        return _parse_exec_jsonl(process.stdout)

    def __post_init__(self) -> None:
        if self.role not in _SUPPORTED_ADAPTER_ROLES:
            raise CodexAdapterError(
                reason=f"unsupported role {self.role.value!r}",
            )

        _require_nonblank_config(field="model", value=self.model)
        _require_nonblank_config(field="reasoning_effort", value=self.reasoning_effort)

        if self.role is AgentRole.REVIEWER:
            if self.review_output_schema_path is None:
                raise CodexAdapterError(
                    reason="Reviewer requires a review_output_schema_path",
                )
            resolved_schema = Path(self.review_output_schema_path).resolve()
            object.__setattr__(self, "review_output_schema_path", resolved_schema)
        elif self.review_output_schema_path is not None:
            raise CodexAdapterError(
                reason=(
                    "review_output_schema_path is only valid for Reviewer; "
                    f"got role {self.role.value!r}"
                ),
            )

        if self.codex_home is not None:
            resolved_home = Path(self.codex_home).resolve()
            object.__setattr__(self, "codex_home", resolved_home)

        require_codex_subscription_ready(self.status)
        require_codex_instruction_isolation(self.status)

        if not self.status.supports_exec_ignore_rules:
            raise CodexPreflightError(
                stage="capabilities",
                reason="codex exec is missing required option(s): --ignore-rules",
            )
        if self.role is AgentRole.REVIEWER and not self.status.supports_exec_output_schema:
            raise CodexPreflightError(
                stage="capabilities",
                reason="codex exec is missing required option(s): --output-schema",
            )

    def build_command(self, request: AgentInvocationRequest) -> AgentCommand:
        """Construct the deterministic Codex ``exec`` command for *request*.

        Validates that *request*'s role matches this adapter and that
        the billing mode is :attr:`BillingMode.SUBSCRIPTION_ONLY`, then
        assembles the fixed argv described by the Sub-phase 5.3 contract
        with the prompt bound only to :attr:`AgentCommand.stdin_text`
        and ``CODEX_HOME`` bound only to :attr:`AgentCommand.explicit_env`
        when configured.
        """
        if request.role is not self.role:
            raise CodexAdapterError(
                reason="request role does not match configured Codex adapter role",
            )
        if request.billing_mode is not BillingMode.SUBSCRIPTION_ONLY:
            raise CodexAdapterError(
                reason=(
                    "Codex adapter supports SUBSCRIPTION_ONLY billing only; "
                    f"got {request.billing_mode.value!r}"
                ),
            )

        sandbox = _ROLE_SANDBOX[self.role]
        reasoning_config = f"model_reasoning_effort={json.dumps(self.reasoning_effort)}"

        argv: list[str] = [
            self.status.executable,
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--json",
            "--color",
            "never",
            "--sandbox",
            sandbox,
            "--model",
            self.model,
            "-c",
            reasoning_config,
        ]
        for override in _SEMANTIC_SUPPRESSION_CONFIG:
            argv.extend(("-c", override))
        if self.role is AgentRole.REVIEWER:
            assert self.review_output_schema_path is not None
            argv.extend(("--output-schema", str(self.review_output_schema_path)))
        argv.append("-")

        explicit_env: Mapping[str, str]
        if self.codex_home is None:
            explicit_env = _EMPTY_EXPLICIT_ENV
        else:
            explicit_env = MappingProxyType({"CODEX_HOME": str(self.codex_home)})

        return AgentCommand(
            argv=tuple(argv),
            inherit_names=(),
            explicit_env=explicit_env,
            required_names=("HOME", "PATH"),
            stdin_text=request.prompt,
        )
