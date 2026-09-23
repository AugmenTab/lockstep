"""Repository inspection and Supervisor-controlled Git mutation.

Eventually mediates every Git interaction Lockstep performs, including
worktree management and the mutation boundary that only the Supervisor
role is permitted to cross. Callers depend on this package rather than
shelling out to Git directly.
"""
