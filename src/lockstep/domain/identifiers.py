"""Scalar identifier and numeric primitives for the Lockstep protocol.

These value objects are the smallest canonical domain vocabulary used
throughout later artifact models and event history. Their serialized
representations are part of Lockstep's long-term protocol surface.
"""

from typing import Annotated

from pydantic import ConfigDict, Field, RootModel, StringConstraints

_IDENTIFIER_PATTERN = r"^[A-Za-z0-9][A-Za-z0-9._-]*$"
_PHASE_ID_PATTERN = r"^[0-9]{2,}$"

_IdentifierStr = Annotated[str, StringConstraints(pattern=_IDENTIFIER_PATTERN)]
_PhaseIdStr = Annotated[str, StringConstraints(pattern=_PHASE_ID_PATTERN)]
_PositiveInt = Annotated[int, Field(strict=True, ge=1)]


class ProjectId(RootModel[_IdentifierStr]):
    model_config = ConfigDict(frozen=True)


class RunId(RootModel[_IdentifierStr]):
    model_config = ConfigDict(frozen=True)


class PhaseId(RootModel[_PhaseIdStr]):
    model_config = ConfigDict(frozen=True)


class SubphaseId(RootModel[_PhaseIdStr]):
    model_config = ConfigDict(frozen=True)


class AttemptNumber(RootModel[_PositiveInt]):
    model_config = ConfigDict(frozen=True)


class SchemaVersion(RootModel[_PositiveInt]):
    model_config = ConfigDict(frozen=True)
