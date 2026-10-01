"""Host-owned identity of one concrete Lockstep agent invocation.

An :class:`InvocationIdentity` says *where an invocation belongs*
(run, Phase, Sub-phase, attempt, role, stage) and *which* concrete
invocation it is (``invocation_id``). It grants no authority: scope,
Git, retry, Contract, and escalation authority remain owned by their
existing artifacts and validators. Only deterministic host
infrastructure issues identities, through :meth:`InvocationIdentity.issue`;
agent output never supplies one.
"""

from __future__ import annotations

import uuid
from typing import Self

from pydantic import BaseModel, ConfigDict, model_validator

from lockstep.domain.enums import AgentRole, InvocationStage
from lockstep.domain.identifiers import (
    AttemptNumber,
    InvocationId,
    PhaseId,
    RunId,
    SubphaseId,
)

_ROLE_BY_STAGE: dict[InvocationStage, AgentRole] = {
    InvocationStage.TEST_AUTHORING: AgentRole.PLANNER,
    InvocationStage.IMPLEMENTATION: AgentRole.IMPLEMENTER,
    InvocationStage.REVIEW: AgentRole.REVIEWER,
    InvocationStage.ESCALATION_DECISION: AgentRole.PLANNER,
}


def _new_invocation_id() -> InvocationId:
    return InvocationId.model_validate(f"inv-{uuid.uuid4().hex}")


class InvocationIdentity(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")

    run_id: RunId
    phase_id: PhaseId
    subphase_id: SubphaseId
    attempt: AttemptNumber
    role: AgentRole
    stage: InvocationStage
    invocation_id: InvocationId

    @model_validator(mode="after")
    def _require_role_matches_stage(self) -> Self:
        if _ROLE_BY_STAGE[self.stage] is not self.role:
            raise ValueError(f"role {self.role.value} cannot own stage {self.stage.value}")
        return self

    @classmethod
    def issue(
        cls,
        *,
        run_id: RunId,
        phase_id: PhaseId,
        subphase_id: SubphaseId,
        attempt: AttemptNumber,
        role: AgentRole,
        stage: InvocationStage,
    ) -> InvocationIdentity:
        """Issue a fresh identity with a host-generated ``invocation_id``."""
        return cls(
            run_id=run_id,
            phase_id=phase_id,
            subphase_id=subphase_id,
            attempt=attempt,
            role=role,
            stage=stage,
            invocation_id=_new_invocation_id(),
        )
