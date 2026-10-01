"""Vendor-neutral boundary between Lockstep orchestration and agent CLIs.

Defines the immutable request/command/result types and the
:func:`invoke_agent` composition function that routes an
:class:`AgentInvocationRequest` through a trusted
:class:`AgentAdapter`, the frozen environment policy, and the
deterministic process runner. This module contains no provider-specific
behavior: it neither reads ambient process state nor interprets
adapter output.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from types import MappingProxyType
from typing import Protocol, runtime_checkable

from lockstep.domain import (
    AgentRole,
    BillingMode,
    ExecutionEventKind,
    ExecutionOutcome,
    InvocationIdentity,
)
from lockstep.persistence import record_execution_event
from lockstep.process import (
    ProcessResult,
    build_process_environment,
    run_process,
)

_EMPTY_EXPLICIT_ENV: Mapping[str, str] = MappingProxyType({})


@dataclass(frozen=True, slots=True)
class AgentInvocationRequest:
    """Orchestrator-owned agent invocation request.

    Carries the role, billing mode, prompt, working directory, execution
    budget, and optional host-issued :class:`InvocationIdentity` that the
    orchestrator hands to a trusted adapter.
    The ``cwd`` is normalized with non-strict :meth:`Path.resolve` at
    construction so downstream components see a stable absolute path.
    ``prompt`` is excluded from :func:`repr` to keep planner prompts out
    of logs and error text.
    """

    role: AgentRole
    billing_mode: BillingMode
    prompt: str = field(repr=False)
    cwd: Path
    timeout_seconds: float
    max_output_bytes: int = 1_048_576
    termination_grace_seconds: float = 0.25
    identity: InvocationIdentity | None = None

    def __post_init__(self) -> None:
        object.__setattr__(self, "cwd", Path(self.cwd).resolve())
        if self.identity is not None and self.identity.role is not self.role:
            raise ValueError("invocation identity role does not match request role")


@dataclass(frozen=True, slots=True)
class AgentCommand:
    """Adapter-owned vendor-specific command and environment intent.

    Carries the ``argv`` to launch and the environment capabilities the
    adapter needs — additional names to inherit from the parent
    mapping, explicit key/value pairs, and names that must be present
    in the final child environment. Execution constraints (cwd,
    timeout, output budget, termination grace) are deliberately absent
    so the orchestrator retains sole authority over them.
    """

    argv: tuple[str, ...]
    inherit_names: tuple[str, ...] = ()
    explicit_env: Mapping[str, str] = field(
        default_factory=lambda: _EMPTY_EXPLICIT_ENV,
        repr=False,
    )
    required_names: tuple[str, ...] = ()
    stdin_text: str | None = field(default=None, repr=False)

    def __post_init__(self) -> None:
        object.__setattr__(
            self,
            "explicit_env",
            MappingProxyType(dict(self.explicit_env)),
        )


@runtime_checkable
class AgentAdapter(Protocol):
    """Structural protocol every concrete agent adapter must satisfy."""

    @property
    def name(self) -> str: ...

    def build_command(
        self,
        request: AgentInvocationRequest,
    ) -> AgentCommand: ...


@dataclass(frozen=True, slots=True)
class AgentInvocationResult:
    """Immutable record of a completed agent invocation."""

    adapter_name: str
    role: AgentRole
    billing_mode: BillingMode
    process: ProcessResult
    identity: InvocationIdentity | None = None


def record_invocation_returned(
    runtime_dir: Path | None,
    identity: InvocationIdentity | None,
    *,
    outcome: ExecutionOutcome,
    returncode: int | None = None,
) -> None:
    """Record the classified return of one identified invocation (no-op without both)."""
    if runtime_dir is None or identity is None:
        return
    record_execution_event(
        runtime_dir,
        kind=ExecutionEventKind.INVOCATION_RETURNED,
        outcome=outcome,
        identity=identity,
        returncode=returncode,
    )


def invoke_agent(
    adapter: AgentAdapter,
    request: AgentInvocationRequest,
    *,
    parent_env: Mapping[str, str],
    runtime_dir: Path | None = None,
    record_return: bool = True,
) -> AgentInvocationResult:
    """Compose adapter, environment policy, and process runner.

    Asks the adapter to construct an :class:`AgentCommand` for
    *request*, builds the child environment through
    :func:`lockstep.process.build_process_environment`, launches the
    command through :func:`lockstep.process.run_process` under the
    orchestrator-owned execution constraints, and returns the outcome
    as an :class:`AgentInvocationResult`. No ambient process state is
    consulted; *parent_env* is the sole environment input.

    When *request* carries a host-issued identity and *runtime_dir* holds
    an event journal, records ``INVOCATION_STARTED`` immediately before
    the process launches (after the command and environment were built,
    so a start is never claimed for a launch that could not happen) and
    ``INVOCATION_RETURNED`` once it returns -- unless *record_return* is
    ``False``, in which case the caller classifies the outcome (for
    example a structured ``BLOCKED`` report) and records the return
    itself through :func:`record_invocation_returned`; an abnormal
    process failure is always recorded here, since the caller never
    receives a result. The records are
    observational and confer no authority; a failure to append the start
    record propagates before any process is launched.
    """
    command = adapter.build_command(request)

    child_env = build_process_environment(
        parent_env,
        inherit_names=command.inherit_names,
        explicit_env=command.explicit_env,
        required_names=command.required_names,
    )

    identity = request.identity if runtime_dir is not None else None
    if identity is not None:
        assert runtime_dir is not None
        record_execution_event(
            runtime_dir, kind=ExecutionEventKind.INVOCATION_STARTED, identity=identity
        )

    try:
        process = run_process(
            command.argv,
            cwd=request.cwd,
            env=child_env,
            timeout_seconds=request.timeout_seconds,
            max_output_bytes=request.max_output_bytes,
            termination_grace_seconds=request.termination_grace_seconds,
            stdin_text=command.stdin_text,
        )
    except BaseException:
        record_invocation_returned(runtime_dir, identity, outcome=ExecutionOutcome.FAILURE)
        raise

    if identity is not None and record_return:
        record_invocation_returned(
            runtime_dir,
            identity,
            outcome=(
                ExecutionOutcome.SUCCESS if process.returncode == 0 else ExecutionOutcome.FAILURE
            ),
            returncode=process.returncode,
        )

    return AgentInvocationResult(
        adapter_name=adapter.name,
        role=request.role,
        billing_mode=request.billing_mode,
        process=process,
        identity=request.identity,
    )
