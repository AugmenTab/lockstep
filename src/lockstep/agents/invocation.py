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
from dataclasses import dataclass, field, replace
from pathlib import Path
from types import MappingProxyType
from typing import Protocol, runtime_checkable

from lockstep.domain import (
    AgentRole,
    BillingMode,
    ExecutionEventKind,
    ExecutionOutcome,
    FailureCause,
    InvocationIdentity,
    InvocationUsage,
    ProcessTermination,
    ProviderTelemetry,
)
from lockstep.failure import cause_for_invocation_failure
from lockstep.persistence import record_execution_event
from lockstep.process import (
    ProcessLaunchError,
    ProcessResult,
    ProcessTimeoutError,
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
class AdapterOutput:
    """A provider adapter's reading of one process's raw output.

    ``content`` is what orchestrators consume in place of the raw stdout (the
    provider's structured wrapper removed); ``telemetry`` is whatever the
    provider reported, with everything it did not report left unavailable.
    """

    content: str
    telemetry: ProviderTelemetry = field(default_factory=ProviderTelemetry)


@runtime_checkable
class UsageReportingAdapter(Protocol):
    """Optional adapter capability: host routing identity plus output normalization.

    Provider-specific response shapes are parsed only behind
    :meth:`normalize_output`; the orchestration layer sees just
    :class:`AdapterOutput`. An adapter without this capability still gets
    host-known attribution, with all provider telemetry unavailable.
    """

    @property
    def configured_model(self) -> str: ...

    @property
    def configured_effort(self) -> str: ...

    def normalize_output(self, process: ProcessResult) -> AdapterOutput: ...


@dataclass(frozen=True, slots=True)
class AgentInvocationResult:
    """Immutable record of a completed agent invocation."""

    adapter_name: str
    role: AgentRole
    billing_mode: BillingMode
    process: ProcessResult
    identity: InvocationIdentity | None = None
    usage: InvocationUsage | None = None


def record_invocation_returned(
    runtime_dir: Path | None,
    identity: InvocationIdentity | None,
    *,
    outcome: ExecutionOutcome,
    returncode: int | None = None,
    usage: InvocationUsage | None = None,
    cause: FailureCause | None = None,
) -> None:
    """Record the classified return of one identified invocation (no-op without both).

    A failed invocation is attributed from its host-observed process evidence
    unless the caller already knows a more specific *cause* (for example
    malformed output on a process that exited cleanly).
    """
    if runtime_dir is None or identity is None:
        return
    if cause is None and outcome is ExecutionOutcome.FAILURE and usage is not None:
        cause = cause_for_invocation_failure(usage)
    record_execution_event(
        runtime_dir,
        kind=ExecutionEventKind.INVOCATION_RETURNED,
        outcome=outcome,
        identity=identity,
        returncode=returncode,
        usage=usage,
        cause=cause,
    )


def _build_usage(
    adapter: AgentAdapter,
    *,
    process: ProcessResult | ProcessTimeoutError,
    termination: ProcessTermination,
    exit_code: int | None,
    telemetry: ProviderTelemetry,
) -> InvocationUsage:
    configured_model: str | None = None
    configured_effort: str | None = None
    if isinstance(adapter, UsageReportingAdapter):
        configured_model = adapter.configured_model
        configured_effort = adapter.configured_effort
    return InvocationUsage(
        provider=adapter.name,
        configured_model=configured_model,
        configured_effort=configured_effort,
        started_at=process.started_at,
        completed_at=process.completed_at,
        elapsed_seconds=process.elapsed_seconds,
        termination=termination,
        exit_code=exit_code,
        reported=telemetry,
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

    The returned result carries an :class:`InvocationUsage` -- host-observed
    timing and exit status, the adapter's configured model/effort, and
    whatever telemetry a :class:`UsageReportingAdapter` could read -- and, when
    the adapter can normalize output, ``process.stdout`` is the adapter's
    ``content`` rather than the provider's raw structured output. The same
    usage rides the recorded ``INVOCATION_RETURNED`` event; a timeout records
    its host timing with no exit status and no provider telemetry.
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
    except ProcessTimeoutError as exc:
        record_invocation_returned(
            runtime_dir,
            identity,
            outcome=ExecutionOutcome.FAILURE,
            usage=_build_usage(
                adapter,
                process=exc,
                termination=ProcessTermination.TIMED_OUT,
                exit_code=None,
                telemetry=ProviderTelemetry(),
            ),
        )
        raise
    except ProcessLaunchError:
        record_invocation_returned(
            runtime_dir,
            identity,
            outcome=ExecutionOutcome.FAILURE,
            cause=cause_for_invocation_failure(None, launch_failed=True),
        )
        raise
    except BaseException:
        record_invocation_returned(runtime_dir, identity, outcome=ExecutionOutcome.FAILURE)
        raise

    telemetry = ProviderTelemetry()
    if isinstance(adapter, UsageReportingAdapter):
        normalized = adapter.normalize_output(process)
        process = replace(process, stdout=normalized.content)
        telemetry = normalized.telemetry
    usage = _build_usage(
        adapter,
        process=process,
        termination=ProcessTermination.EXITED,
        exit_code=process.returncode,
        telemetry=telemetry,
    )

    if identity is not None and record_return:
        record_invocation_returned(
            runtime_dir,
            identity,
            outcome=(
                ExecutionOutcome.SUCCESS if process.returncode == 0 else ExecutionOutcome.FAILURE
            ),
            returncode=process.returncode,
            usage=usage,
        )

    return AgentInvocationResult(
        adapter_name=adapter.name,
        role=request.role,
        billing_mode=request.billing_mode,
        process=process,
        identity=request.identity,
        usage=usage,
    )
