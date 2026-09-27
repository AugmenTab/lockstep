"""Configuration-driven Lockstep agent runtime composition.

Assembles a project's tracked routing policy, this machine's explicitly
diagnosed provider state, the adapters resolved from those two inputs,
and the exact ``HOME``/``PATH`` environment projection supplied to
inference into one bound :class:`AgentRuntime`, then lets the existing
provider-neutral single-Sub-phase Supervisor consume it without any
provider-specific transaction logic. This module composes the public
APIs of :mod:`lockstep.config`, :mod:`lockstep.agents`,
:mod:`lockstep.process`, and :mod:`lockstep.supervisor`; it constructs
no concrete provider adapter, launches no provider process directly,
and performs no model inference during preparation.
"""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from pathlib import Path
from types import MappingProxyType

from lockstep.agents import (
    AgentProviderDiagnostics,
    ProviderRuntimeOverrides,
    ResolvedAgentAdapters,
    diagnose_agent_providers,
    resolve_agent_adapters,
)
from lockstep.config import ProjectConfig, load_project_config
from lockstep.process import build_process_environment
from lockstep.supervisor import (
    SingleSubphaseTransactionRequest,
    SingleSubphaseTransactionResult,
    run_single_subphase_transaction,
)

_TRANSACTION_ENV_NAMES: tuple[str, ...] = ("HOME", "PATH")


class AgentRuntimeError(Exception):
    """A failure owned solely by the runtime composition layer.

    Carries a short sanitized ``reason``. Never carries ``HOME``,
    ``PATH``, other environment values, full filesystem paths,
    credentials, prompt text, or provider output.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"agent runtime error: {reason}")


def _paths_overlap(first: Path, second: Path) -> bool:
    return first == second or first.is_relative_to(second) or second.is_relative_to(first)


@dataclass(frozen=True, slots=True)
class AgentRuntime:
    """A bound, reusable Lockstep agent runtime for one project/run pair.

    Carries the exact objects produced by the production configuration,
    diagnostics, and resolution layers alongside the exact ``HOME``/
    ``PATH`` mapping the Supervisor transaction receives as its parent
    environment. Immutable and slotted; ``transaction_parent_env`` is
    excluded from :func:`repr` and is not mutable by the caller, nor
    does mutating the mapping originally supplied to
    :func:`prepare_agent_runtime` affect it afterward.
    """

    project_root: Path
    runtime_dir: Path

    config: ProjectConfig
    diagnostics: AgentProviderDiagnostics
    adapters: ResolvedAgentAdapters

    transaction_parent_env: Mapping[str, str] = field(repr=False)

    def __post_init__(self) -> None:
        object.__setattr__(self, "project_root", Path(self.project_root).resolve())
        object.__setattr__(self, "runtime_dir", Path(self.runtime_dir).resolve())
        object.__setattr__(
            self,
            "transaction_parent_env",
            MappingProxyType(dict(self.transaction_parent_env)),
        )


def prepare_agent_runtime(
    project_root: Path,
    runtime_dir: Path,
    *,
    operator_parent_env: Mapping[str, str],
    provider_overrides: ProviderRuntimeOverrides | None = None,
) -> AgentRuntime:
    """Compose one project's tracked config into a prepared runtime.

    In order: resolves *project_root*/*runtime_dir*, loads the tracked
    project configuration via
    :func:`~lockstep.config.load_project_config`, rejects a
    *runtime_dir* that equals or is nested beneath *project_root*,
    projects *operator_parent_env* down to exactly ``HOME``/``PATH``
    through :func:`~lockstep.process.build_process_environment`,
    diagnoses the configured routing policy's selected providers via
    :func:`~lockstep.agents.diagnose_agent_providers`, and resolves the
    three role adapters via
    :func:`~lockstep.agents.resolve_agent_adapters`. Reads no ambient
    environment or filesystem-home state; *operator_parent_env* is the
    sole environment input. Performs zero model turns.
    """
    resolved_project_root = Path(project_root).resolve()
    resolved_runtime_dir = Path(runtime_dir).resolve()

    config = load_project_config(resolved_project_root)

    if resolved_runtime_dir == resolved_project_root or resolved_runtime_dir.is_relative_to(
        resolved_project_root
    ):
        raise AgentRuntimeError(reason="runtime directory must be outside project root")

    projected_source = {
        name: operator_parent_env[name]
        for name in _TRANSACTION_ENV_NAMES
        if name in operator_parent_env
    }
    transaction_parent_env = build_process_environment(
        projected_source,
        inherit_names=(),
        required_names=_TRANSACTION_ENV_NAMES,
    )

    overrides = provider_overrides if provider_overrides is not None else ProviderRuntimeOverrides()

    diagnostics = diagnose_agent_providers(
        config.routing,
        parent_env=operator_parent_env,
        overrides=overrides,
    )

    adapters = resolve_agent_adapters(
        config.routing,
        diagnostics.statuses,
        resolved_runtime_dir,
        claude_config_dir=diagnostics.claude_config_dir,
        codex_home=diagnostics.codex_home,
    )

    return AgentRuntime(
        project_root=resolved_project_root,
        runtime_dir=resolved_runtime_dir,
        config=config,
        diagnostics=diagnostics,
        adapters=adapters,
        transaction_parent_env=transaction_parent_env,
    )


def run_single_subphase_with_runtime(
    request: SingleSubphaseTransactionRequest,
    runtime: AgentRuntime,
) -> SingleSubphaseTransactionResult:
    """Validate *request* against *runtime* and delegate to the Supervisor.

    Requires *request*'s source path, runtime directory, and billing
    mode to match the prepared *runtime* exactly, and requires
    *runtime*'s runtime directory and *request*'s worktree path to be
    disjoint, before making exactly one call to
    :func:`~lockstep.supervisor.run_single_subphase_transaction` with
    *runtime*'s resolved adapters and projected parent environment. Does
    not reload configuration, rediagnose providers, or re-resolve
    adapters; a prepared runtime is reusable across calls. Returns the
    Supervisor's result unchanged.
    """
    if request.source_path != runtime.project_root:
        raise AgentRuntimeError(reason="transaction source does not match prepared project root")

    if request.runtime_dir != runtime.runtime_dir:
        raise AgentRuntimeError(
            reason="transaction runtime directory does not match prepared runtime directory"
        )

    if _paths_overlap(request.worktree_path, runtime.runtime_dir):
        raise AgentRuntimeError(reason="runtime directory overlaps transaction worktree")

    routing = runtime.config.routing
    if not (
        request.billing_mode
        == routing.planner.billing_mode
        == routing.implementer.billing_mode
        == routing.reviewer.billing_mode
    ):
        raise AgentRuntimeError(
            reason="transaction billing mode does not match prepared routing policy"
        )

    return run_single_subphase_transaction(
        request,
        parent_env=runtime.transaction_parent_env,
        planner_adapter=runtime.adapters.planner,
        implementer_adapter=runtime.adapters.implementer,
        reviewer_adapter=runtime.adapters.reviewer,
    )
