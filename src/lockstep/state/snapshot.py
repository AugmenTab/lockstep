"""Immutable checkpoint model for the current Lockstep run state.

`RunStateSnapshot` is the frozen, schema-versioned cache/checkpoint that
represents the workflow state derived from replaying the authoritative
event journal up to a given sequence number. The snapshot is convenient
but never authoritative: the journal is the source of truth and any
snapshot that disagrees with journal replay is treated as corrupt. The
coarse `RunStatus` is intentionally not persisted here; it remains
derived from `workflow_state` via `run_status_for` so there is exactly
one source of workflow truth in the system.
"""

from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, field_validator

from lockstep.domain import ProjectId, RunId, SchemaVersion
from lockstep.state.machine import WorkflowState

_CURRENT_SCHEMA_VERSION: SchemaVersion = SchemaVersion.model_validate(1)

_PositiveStrictInt = Annotated[int, Field(strict=True, ge=1)]


class RunStateSnapshot(BaseModel):
    """Immutable derived checkpoint of the current workflow state of a run."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    schema_version: SchemaVersion = _CURRENT_SCHEMA_VERSION
    run_id: RunId
    project_id: ProjectId
    workflow_state: WorkflowState
    last_sequence: _PositiveStrictInt

    @field_validator("schema_version")
    @classmethod
    def _reject_unsupported_schema_version(cls, value: SchemaVersion) -> SchemaVersion:
        if value.root != _CURRENT_SCHEMA_VERSION.root:
            raise ValueError(
                f"unsupported schema_version {value.root}; "
                f"snapshots currently understand only schema_version "
                f"{_CURRENT_SCHEMA_VERSION.root}"
            )
        return value
