"""Provider-neutral agent interface and provider-specific adapters.

Eventually houses the abstraction that Lockstep uses to invoke any coding
agent (Claude, Codex, or a deterministic fake) alongside the concrete
adapters that satisfy it. The package must remain the sole location where
provider-specific behavior lives; the rest of Lockstep depends on the
neutral interface only.
"""
