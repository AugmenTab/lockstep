"""Strict, portable Lockstep project configuration.

Parses the project's tracked ``lockstep.toml`` into a frozen
:class:`ProjectConfig` describing exactly which provider/model/effort/
billing policy each execution role uses. This module is deliberately
narrow: it performs a strict deterministic parse of a fixed schema into
:class:`~lockstep.agents.routing.AgentRoutingPolicy`, and nothing more.
It never probes a provider executable, never inspects authentication
state, and never reads machine-specific paths, so a checked-out
repository's configuration remains fully portable between machines.
"""

from __future__ import annotations

import tomllib
from dataclasses import dataclass
from pathlib import Path

from lockstep.agents.routing import (
    AgentProvider,
    AgentRoleRoute,
    AgentRoutingPolicy,
    AgentRoutingPolicyError,
)
from lockstep.domain import BillingMode

LOCKSTEP_CONFIG_FILENAME = "lockstep.toml"

_SCHEMA_VERSION = 1
_TOP_LEVEL_KEYS: frozenset[str] = frozenset({"schema_version", "routing"})
_ROLE_NAMES: tuple[str, ...] = ("planner", "implementer", "reviewer")
_ROUTE_KEYS: frozenset[str] = frozenset({"provider", "model", "effort", "billing_mode"})

_TOML_SINGLE_CHAR_ESCAPES: dict[str, str] = {
    "\\": "\\\\",
    '"': '\\"',
    "\b": "\\b",
    "\t": "\\t",
    "\n": "\\n",
    "\f": "\\f",
    "\r": "\\r",
}


class ProjectConfigError(Exception):
    """Project configuration rejected an input.

    Carries a short sanitized ``reason`` that may name a structural
    location (a top-level key, a routing role, a route field) but never
    echoes a raw configured value, raw TOML source, or a credential or
    environment value.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"project config error: {reason}")


@dataclass(frozen=True, slots=True)
class ProjectConfig:
    """The fully parsed, portable Lockstep project configuration."""

    schema_version: int
    routing: AgentRoutingPolicy


def _require_mapping(value: object, *, location: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ProjectConfigError(f"{location} must be a table")
    return value


def _require_string(value: object, *, location: str) -> str:
    if not isinstance(value, str):
        raise ProjectConfigError(f"{location} must be a string")
    return value


def _parse_schema_version(raw: object) -> int:
    if isinstance(raw, bool) or not isinstance(raw, int):
        raise ProjectConfigError("schema_version must be an integer")
    if raw != _SCHEMA_VERSION:
        raise ProjectConfigError(f"schema_version must be exactly {_SCHEMA_VERSION}")
    return raw


def _parse_provider(raw: object, *, role: str) -> AgentProvider:
    value = _require_string(raw, location=f"routing.{role}.provider")
    try:
        return AgentProvider(value)
    except ValueError as exc:
        raise ProjectConfigError(f"routing.{role}.provider is unsupported") from exc


def _parse_billing_mode(raw: object, *, role: str) -> BillingMode:
    value = _require_string(raw, location=f"routing.{role}.billing_mode")
    try:
        return BillingMode(value)
    except ValueError as exc:
        raise ProjectConfigError(f"routing.{role}.billing_mode is unsupported") from exc


def _parse_route(raw: object, *, role: str) -> AgentRoleRoute:
    table = _require_mapping(raw, location=f"routing.{role}")

    extra = set(table) - _ROUTE_KEYS
    if extra:
        raise ProjectConfigError(f"routing.{role} has unknown field: {min(extra)}")

    missing = _ROUTE_KEYS - set(table)
    if missing:
        raise ProjectConfigError(f"routing.{role} is missing field: {min(missing)}")

    provider = _parse_provider(table["provider"], role=role)
    billing_mode = _parse_billing_mode(table["billing_mode"], role=role)
    model = _require_string(table["model"], location=f"routing.{role}.model")
    effort = _require_string(table["effort"], location=f"routing.{role}.effort")

    try:
        return AgentRoleRoute(
            provider=provider,
            model=model,
            effort=effort,
            billing_mode=billing_mode,
        )
    except AgentRoutingPolicyError as exc:
        raise ProjectConfigError(f"routing.{role} has an invalid model or effort value") from exc


def parse_project_config(text: str) -> ProjectConfig:
    """Parse *text* as a strict schema-v1 ``lockstep.toml`` document.

    Pure: performs no filesystem, environment, or process access. All
    four fields of every role route must be present and explicit; no
    role inherits another role's configuration and no field is
    canonicalized, aliased, or interpolated.
    """
    try:
        raw = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        raise ProjectConfigError("invalid TOML syntax") from exc

    extra_top = set(raw) - _TOP_LEVEL_KEYS
    if extra_top:
        raise ProjectConfigError(f"unknown top-level key: {min(extra_top)}")

    missing_top = _TOP_LEVEL_KEYS - set(raw)
    if missing_top:
        raise ProjectConfigError(f"missing top-level key: {min(missing_top)}")

    schema_version = _parse_schema_version(raw["schema_version"])

    routing_table = _require_mapping(raw["routing"], location="routing")

    extra_roles = set(routing_table) - set(_ROLE_NAMES)
    if extra_roles:
        raise ProjectConfigError(f"routing has unknown role: {min(extra_roles)}")

    missing_roles = set(_ROLE_NAMES) - set(routing_table)
    if missing_roles:
        raise ProjectConfigError(f"routing is missing role: {min(missing_roles)}")

    routing = AgentRoutingPolicy(
        planner=_parse_route(routing_table["planner"], role="planner"),
        implementer=_parse_route(routing_table["implementer"], role="implementer"),
        reviewer=_parse_route(routing_table["reviewer"], role="reviewer"),
    )

    return ProjectConfig(schema_version=schema_version, routing=routing)


def load_project_config(project_root: Path) -> ProjectConfig:
    """Load and parse ``<project_root>/lockstep.toml`` exactly.

    Performs no upward search, no cwd fallback, and no HOME or
    environment-variable lookup. Rejects a config path that does not
    exist, is not a regular file, or is a symlink (even one that
    resolves to a regular file), so a tracked unattended-run
    configuration cannot silently redirect Lockstep into reading an
    arbitrary host file.
    """
    config_path = Path(project_root).resolve() / LOCKSTEP_CONFIG_FILENAME

    if config_path.is_symlink():
        raise ProjectConfigError("config file must not be a symlink")
    if not config_path.exists():
        raise ProjectConfigError("config file does not exist")
    if not config_path.is_file():
        raise ProjectConfigError("config path is not a regular file")

    try:
        raw_bytes = config_path.read_bytes()
    except OSError as exc:
        raise ProjectConfigError("config file could not be read") from exc

    try:
        text = raw_bytes.decode("utf-8", errors="strict")
    except UnicodeDecodeError as exc:
        raise ProjectConfigError("config file is not valid UTF-8") from exc

    return parse_project_config(text)


def _quote_toml_string(value: str) -> str:
    parts: list[str] = []
    for character in value:
        escape = _TOML_SINGLE_CHAR_ESCAPES.get(character)
        if escape is not None:
            parts.append(escape)
        elif ord(character) < 0x20 or ord(character) == 0x7F:
            parts.append(f"\\u{ord(character):04X}")
        else:
            parts.append(character)
    return '"' + "".join(parts) + '"'


def render_project_config(config: ProjectConfig) -> str:
    """Render *config* as canonical, deterministic schema-v1 TOML.

    Pure: performs no filesystem, environment, or process access.
    Fields are emitted in a fixed section and field order using each
    enum's ``.value`` string, and the output always ends with exactly
    one trailing newline. ``parse_project_config(render_project_config(c))
    == c`` for every legal :class:`ProjectConfig`.
    """
    if config.schema_version != _SCHEMA_VERSION:
        raise ProjectConfigError(f"schema_version must be exactly {_SCHEMA_VERSION} to render")

    lines = [f"schema_version = {config.schema_version}"]

    for role, route in (
        ("planner", config.routing.planner),
        ("implementer", config.routing.implementer),
        ("reviewer", config.routing.reviewer),
    ):
        lines.append("")
        lines.append(f"[routing.{role}]")
        lines.append(f"provider = {_quote_toml_string(route.provider.value)}")
        lines.append(f"model = {_quote_toml_string(route.model)}")
        lines.append(f"effort = {_quote_toml_string(route.effort)}")
        lines.append(f"billing_mode = {_quote_toml_string(route.billing_mode.value)}")

    return "\n".join(lines) + "\n"
