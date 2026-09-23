"""Canonical Lockstep data types and protocol models.

Eventually contains the pure domain vocabulary — MasterPlan, PhasePlan,
SubphaseContract, ImplementationReport, VerificationReport,
ReviewDecision, and their identifiers. This package must stay
independent of Typer, Claude, Codex, Git command implementation, and
any UI-specific behavior so that it can be safely imported by every
other layer.
"""
