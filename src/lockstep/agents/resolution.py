"""Deterministic provider adapter resolver.

Converts a frozen :class:`~lockstep.agents.routing.AgentRoutingPolicy`,
already-probed provider statuses, and explicit provider-runtime paths
into exactly three production role-bound adapters: Planner, Implementer,
and Reviewer. Provider-specific construction belongs here; transaction
orchestration consumes the resulting
:class:`~lockstep.agents.invocation.AgentAdapter` instances and remains
provider-neutral. Performs no provider CLI invocation, no
authentication probe, and no model inference. The Codex Reviewer schema
artifact, materialized only when the Reviewer route selects Codex, is
the resolver's sole permitted filesystem side effect.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from types import MappingProxyType

from lockstep.agents.claude import ClaudeAdapter, ClaudeCliStatus
from lockstep.agents.codex import CodexAdapter, CodexCliStatus
from lockstep.agents.codex_review import materialize_codex_review_schema
from lockstep.agents.invocation import AgentAdapter
from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.domain import AgentRole, BillingMode

_SUPPORTED_BILLING_MODES: frozenset[BillingMode] = frozenset({BillingMode.SUBSCRIPTION_ONLY})

_EMPTY_INHERITED_ENV: Mapping[str, str] = MappingProxyType({})

_ROLE_ORDER: tuple[tuple[str, AgentRole], ...] = (
    ("planner", AgentRole.PLANNER),
    ("implementer", AgentRole.IMPLEMENTER),
    ("reviewer", AgentRole.REVIEWER),
)


class AgentAdapterResolutionError(Exception):
    """Resolver rejected a routing policy before constructing adapters.

    Carries a short sanitized ``reason`` naming only non-secret routing
    and configuration facts (role name, provider value, billing-mode
    enum value). Never carries credentials, environment values, prompt
    text, or provider stdout/stderr.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"agent adapter resolution error: {reason}")


@dataclass(frozen=True, slots=True)
class AgentProviderStatuses:
    """Already-probed provider status carried into adapter resolution.

    A provider's status may be absent (``None``) when no route in the
    policy being resolved selects that provider. ``claude_inherited_env``
    is the optional part of the Claude provider environment (``USER``
    only) under which the Claude status was established; resolution binds
    it into every Claude adapter so inference runs under the same
    environment the preflight verified. It is excluded from :func:`repr`.
    This object probes nothing; it is inert evidence supplied by the
    caller.
    """

    claude: ClaudeCliStatus | None = None
    codex: CodexCliStatus | None = None
    claude_inherited_env: Mapping[str, str] = field(
        default=_EMPTY_INHERITED_ENV, repr=False, hash=False
    )

    def __post_init__(self) -> None:
        object.__setattr__(
            self, "claude_inherited_env", MappingProxyType(dict(self.claude_inherited_env))
        )


@dataclass(frozen=True, slots=True)
class ResolvedAgentAdapters:
    """The exactly-three execution-role adapters produced by resolution."""

    planner: AgentAdapter
    implementer: AgentAdapter
    reviewer: AgentAdapter


def _validate_route(
    *,
    field_name: str,
    route: AgentRoleRoute,
    statuses: AgentProviderStatuses,
) -> None:
    if route.provider is AgentProvider.CLAUDE and statuses.claude is None:
        raise AgentAdapterResolutionError(
            f"{field_name} route selects provider {AgentProvider.CLAUDE.value!r} "
            "but no Claude status was supplied"
        )
    if route.provider is AgentProvider.CODEX and statuses.codex is None:
        raise AgentAdapterResolutionError(
            f"{field_name} route selects provider {AgentProvider.CODEX.value!r} "
            "but no Codex status was supplied"
        )
    if route.billing_mode not in _SUPPORTED_BILLING_MODES:
        raise AgentAdapterResolutionError(
            f"{field_name} route (provider {route.provider.value!r}) requests "
            f"unsupported billing mode {route.billing_mode.value!r}"
        )


def _build_adapter(
    *,
    agent_role: AgentRole,
    route: AgentRoleRoute,
    statuses: AgentProviderStatuses,
    claude_config_dir: Path | None,
    codex_home: Path | None,
    review_output_schema_path: Path | None,
) -> AgentAdapter:
    if route.provider is AgentProvider.CLAUDE:
        assert statuses.claude is not None
        return ClaudeAdapter(
            role=agent_role,
            status=statuses.claude,
            model=route.model,
            effort=route.effort,
            claude_config_dir=claude_config_dir,
            inherited_env=statuses.claude_inherited_env,
        )

    assert statuses.codex is not None
    return CodexAdapter(
        role=agent_role,
        status=statuses.codex,
        model=route.model,
        reasoning_effort=route.effort,
        codex_home=codex_home,
        review_output_schema_path=review_output_schema_path,
    )


def resolve_agent_adapters(
    policy: AgentRoutingPolicy,
    statuses: AgentProviderStatuses,
    runtime_dir: Path,
    *,
    claude_config_dir: Path | None = None,
    codex_home: Path | None = None,
) -> ResolvedAgentAdapters:
    """Deterministically resolve *policy* into three production adapters.

    Validates, for all three routes, that the selected provider has a
    supplied status and requests a currently supported billing mode
    before constructing anything or touching the filesystem. Only after
    every resolver-owned check passes does it materialize the Codex
    Reviewer schema artifact (if and only if the Reviewer route selects
    Codex) via
    :func:`~lockstep.agents.codex_review.materialize_codex_review_schema`
    under the resolved *runtime_dir*, then construct the three adapters.
    """
    routes: dict[str, AgentRoleRoute] = {
        "planner": policy.planner,
        "implementer": policy.implementer,
        "reviewer": policy.reviewer,
    }

    for field_name, _ in _ROLE_ORDER:
        _validate_route(field_name=field_name, route=routes[field_name], statuses=statuses)

    review_output_schema_path: Path | None = None
    if policy.reviewer.provider is AgentProvider.CODEX:
        review_output_schema_path = materialize_codex_review_schema(runtime_dir.resolve())

    planner = _build_adapter(
        agent_role=AgentRole.PLANNER,
        route=policy.planner,
        statuses=statuses,
        claude_config_dir=claude_config_dir,
        codex_home=codex_home,
        review_output_schema_path=None,
    )
    implementer = _build_adapter(
        agent_role=AgentRole.IMPLEMENTER,
        route=policy.implementer,
        statuses=statuses,
        claude_config_dir=claude_config_dir,
        codex_home=codex_home,
        review_output_schema_path=None,
    )
    reviewer = _build_adapter(
        agent_role=AgentRole.REVIEWER,
        route=policy.reviewer,
        statuses=statuses,
        claude_config_dir=claude_config_dir,
        codex_home=codex_home,
        review_output_schema_path=review_output_schema_path,
    )

    return ResolvedAgentAdapters(planner=planner, implementer=implementer, reviewer=reviewer)
