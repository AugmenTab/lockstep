"""Durable serialization and storage of Lockstep run state.

Eventually owns the on-disk representation of canonical run state and
the event history that supports resumption and audit. All file-format
choices, repository abstractions, and storage interfaces belong here so
that the domain layer never encodes storage concerns directly.
"""
