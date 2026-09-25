"""Codex CLI subscription and capability preflight.

Answers deterministic yes/no questions about a configured Codex
executable — is it usable, does it expose the exec options Lockstep's
future adapter needs, is its stored authentication explicitly
ChatGPT-backed, and are stored API-key credentials absent — without
executing any model turn. All external commands are executed through
:mod:`lockstep.process`; ambient OpenAI/Codex API credentials are
structurally excluded from the probe environment.
"""

from __future__ import annotations

import json
import re
from collections.abc import Iterator, Mapping
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType

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

_AUTH_CHECK_KEY = "auth.credentials"
_SUPPORTED_DOCTOR_SCHEMA_VERSION = 1

_DETAIL_STORED_AUTH_MODE = "stored auth mode"
_DETAIL_STORED_CHATGPT_TOKENS = "stored ChatGPT tokens"
_DETAIL_STORED_API_KEY = "stored API key"

_REQUIRED_STORED_AUTH_MODE = "chatgpt"
_REQUIRED_AUTH_CHECK_STATUS = "ok"

_FLAG_TOKEN_PATTERN: dict[str, re.Pattern[str]] = {
    flag: re.compile(rf"(?<![A-Za-z0-9_\-]){re.escape(flag)}(?![A-Za-z0-9_\-])")
    for flag in _REQUIRED_EXEC_CAPABILITIES
}

_EMPTY_EXPLICIT_ENV: Mapping[str, str] = MappingProxyType({})


@dataclass(frozen=True, slots=True)
class CodexCliStatus:
    """Diagnostic and capability evidence gathered by the Codex preflight.

    Captures only high-level structural signals: the executable path
    used, its self-reported version string, the doctor schema version,
    doctor overall status, doctor process return code, the
    ``auth.credentials`` check status, the three stored-credential
    detail values, and the four exec-flag capability booleans.
    Deliberately excludes raw doctor stdout/stderr, environment values,
    auth tokens, API-key values, and any ``HOME`` contents.
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


class CodexPreflightError(Exception):
    """A stage of the Codex preflight rejected the observed evidence.

    Carries the failing ``stage`` (``version``, ``capabilities``,
    ``doctor``, or ``auth``) and a short sanitized ``reason``. Never
    carries raw doctor stdout/stderr, environment values, auth tokens,
    or API-key values.
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
    ambient OpenAI/Codex API credential variables are inherited. The
    returned :class:`CodexCliStatus` is diagnostic evidence only;
    subscription readiness is decided by
    :func:`require_codex_subscription_ready`.
    """
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

    return CodexCliStatus(
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
    )


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
