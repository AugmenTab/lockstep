"""Provider-neutral agent interface and provider-specific adapters.

Eventually houses the abstraction that Lockstep uses to invoke any coding
agent (Claude, Codex, or a deterministic fake) alongside the concrete
adapters that satisfy it. The package must remain the sole location where
provider-specific behavior lives; the rest of Lockstep depends on the
neutral interface only.
"""

from lockstep.agents.claude import (
    ClaudeAdapter,
    ClaudeAdapterError,
    ClaudeCliStatus,
    ClaudePreflightError,
    probe_claude_cli,
    require_claude_subscription_ready,
)
from lockstep.agents.codex import (
    CodexAdapter,
    CodexAdapterError,
    CodexCliStatus,
    CodexPreflightError,
    probe_codex_cli,
    require_codex_subscription_ready,
)
from lockstep.agents.codex_review import materialize_codex_review_schema
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
from lockstep.agents.resolution import (
    AgentAdapterResolutionError,
    AgentProviderStatuses,
    ResolvedAgentAdapters,
    resolve_agent_adapters,
)
from lockstep.agents.routing import (
    AgentProvider,
    AgentRoleRoute,
    AgentRoutingPolicy,
    AgentRoutingPolicyError,
)

__all__ = [
    "AgentAdapter",
    "AgentAdapterResolutionError",
    "AgentCommand",
    "AgentInvocationRequest",
    "AgentInvocationResult",
    "AgentProvider",
    "AgentProviderStatuses",
    "AgentRoleRoute",
    "AgentRoutingPolicy",
    "AgentRoutingPolicyError",
    "ClaudeAdapter",
    "ClaudeAdapterError",
    "ClaudeCliStatus",
    "ClaudePreflightError",
    "CodexAdapter",
    "CodexAdapterError",
    "CodexCliStatus",
    "CodexPreflightError",
    "OpenAIStrictSchemaError",
    "ResolvedAgentAdapters",
    "invoke_agent",
    "materialize_codex_review_schema",
    "probe_claude_cli",
    "probe_codex_cli",
    "require_claude_subscription_ready",
    "require_codex_subscription_ready",
    "resolve_agent_adapters",
    "to_openai_strict_json_schema",
]
