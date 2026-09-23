"""Generic safe subprocess execution.

Eventually provides the single, provider-neutral mechanism by which
Lockstep launches external processes — capturing output, enforcing
timeouts, and normalizing errors. Higher-level integrations (agents,
Git, verification) route their process calls through this package
rather than invoking subprocess machinery directly.
"""
