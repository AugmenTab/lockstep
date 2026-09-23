"""Deterministic Lockstep workflow state and transition rules.

Eventually defines the finite set of run states, the legal transitions
between them, and the invariants that any transition must preserve.
State progression is deterministic and validated here rather than being
distributed across callers.
"""
