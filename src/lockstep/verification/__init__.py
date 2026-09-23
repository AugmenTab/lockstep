"""Deterministic verification orchestration and evidence.

Eventually owns the machinery that runs a Sub-phase's verification
gates, collects their evidence, and produces the VerificationReport
consumed by the review pipeline. Verifier execution is deterministic
and its results are the sole basis for downstream review decisions.
"""
