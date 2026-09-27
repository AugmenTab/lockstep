"""Deterministic, provider-neutral role routing policy.

Describes, for each supported execution role, which provider serves it
and which model, reasoning/effort setting, and billing policy that role
uses. This module is pure configuration: it does not launch providers,
probe provider CLIs, construct adapters, read project configuration
files, or depend on the transaction-orchestration layer. Provider
assignment is deliberately unopinionated — every provider/role
combination constructed here is equally legal; no route infers,
defaults, or derives its provider, model, effort, or billing mode from
another role's route or from ambient configuration.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import StrEnum

from lockstep.domain import BillingMode


class AgentProvider(StrEnum):
    CLAUDE = "claude"
    CODEX = "codex"


class AgentRoutingPolicyError(Exception):
    """Role routing policy rejected an input.

    Carries a short sanitized ``reason``. Never carries credentials,
    environment values, provider auth output, or prompt text — no such
    data exists at this layer.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"agent routing policy error: {reason}")


def _require_nonblank(*, field: str, value: str) -> str:
    if not isinstance(value, str):
        raise AgentRoutingPolicyError(f"{field} must be a string")
    if not value.strip():
        raise AgentRoutingPolicyError(f"{field} must not be blank")
    if "\x00" in value:
        raise AgentRoutingPolicyError(f"{field} must not contain NUL")
    return value


@dataclass(frozen=True, slots=True)
class AgentRoleRoute:
    """One role's explicit provider/model/effort/billing policy.

    Every field is required and explicit at construction; ``model`` and
    ``effort`` are validated but never canonicalized, aliased, or
    substituted with a provider default.
    """

    provider: AgentProvider
    model: str
    effort: str
    billing_mode: BillingMode

    def __post_init__(self) -> None:
        object.__setattr__(self, "model", _require_nonblank(field="model", value=self.model))
        object.__setattr__(self, "effort", _require_nonblank(field="effort", value=self.effort))


@dataclass(frozen=True, slots=True)
class AgentRoutingPolicy:
    """Exactly one route for each currently supported execution role.

    Structurally guarantees planner, implementer, and reviewer routes
    are all present; construction accepts no fewer and no more fields,
    so a role can be neither missing nor smuggled in.
    """

    planner: AgentRoleRoute
    implementer: AgentRoleRoute
    reviewer: AgentRoleRoute
