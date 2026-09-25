"""Provider-neutral agent interface and provider-specific adapters.

Eventually houses the abstraction that Lockstep uses to invoke any coding
agent (Claude, Codex, or a deterministic fake) alongside the concrete
adapters that satisfy it. The package must remain the sole location where
provider-specific behavior lives; the rest of Lockstep depends on the
neutral interface only.
"""

from lockstep.agents.codex import (
    CodexAdapter,
    CodexAdapterError,
    CodexCliStatus,
    CodexPreflightError,
    probe_codex_cli,
    require_codex_subscription_ready,
)
from lockstep.agents.invocation import (
    AgentAdapter,
    AgentCommand,
    AgentInvocationRequest,
    AgentInvocationResult,
    invoke_agent,
)
from lockstep.agents.openai_schema import (
    OpenAIStrictSchemaError,
    to_openai_strict_json_schema,
)

__all__ = [
    "AgentAdapter",
    "AgentCommand",
    "AgentInvocationRequest",
    "AgentInvocationResult",
    "CodexAdapter",
    "CodexAdapterError",
    "CodexCliStatus",
    "CodexPreflightError",
    "OpenAIStrictSchemaError",
    "invoke_agent",
    "probe_codex_cli",
    "require_codex_subscription_ready",
    "to_openai_strict_json_schema",
]
