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
    managed_claude_instructions_path,
    probe_claude_cli,
    require_claude_instruction_isolation,
    require_claude_subscription_ready,
)
from lockstep.agents.codex import (
    CodexAdapter,
    CodexAdapterError,
    CodexCliStatus,
    CodexPreflightError,
    diagnose_codex_cli,
    probe_codex_cli,
    require_codex_instruction_isolation,
    require_codex_subscription_ready,
)
from lockstep.agents.codex_review import materialize_codex_review_schema
from lockstep.agents.diagnostics import (
    AgentProviderDiagnostics,
    ProviderDiagnosticsError,
    ProviderRuntimeOverrides,
    diagnose_agent_providers,
)
from lockstep.agents.invocation import (
    AdapterOutput,
    AgentAdapter,
    AgentCommand,
    AgentInvocationRequest,
    AgentInvocationResult,
    UsageReportingAdapter,
    invoke_agent,
    record_invocation_returned,
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
from lockstep.agents.role_output import (
    RoleOutputAdapterError,
    prepare_structured_role_adapter,
)
from lockstep.agents.routing import (
    AgentProvider,
    AgentRoleRoute,
    AgentRoutingPolicy,
    AgentRoutingPolicyError,
)
from lockstep.agents.structured_output import (
    StructuredOutputAdapterError,
    prepare_structured_planner_adapter,
)

__all__ = [
    "AdapterOutput",
    "AgentAdapter",
    "AgentAdapterResolutionError",
    "AgentCommand",
    "AgentInvocationRequest",
    "AgentInvocationResult",
    "AgentProvider",
    "AgentProviderDiagnostics",
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
    "ProviderDiagnosticsError",
    "ProviderRuntimeOverrides",
    "ResolvedAgentAdapters",
    "RoleOutputAdapterError",
    "StructuredOutputAdapterError",
    "UsageReportingAdapter",
    "diagnose_agent_providers",
    "diagnose_codex_cli",
    "invoke_agent",
    "managed_claude_instructions_path",
    "materialize_codex_review_schema",
    "prepare_structured_planner_adapter",
    "prepare_structured_role_adapter",
    "probe_claude_cli",
    "probe_codex_cli",
    "record_invocation_returned",
    "require_claude_instruction_isolation",
    "require_claude_subscription_ready",
    "require_codex_instruction_isolation",
    "require_codex_subscription_ready",
    "resolve_agent_adapters",
    "to_openai_strict_json_schema",
]
