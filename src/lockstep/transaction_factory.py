"""The host-owned canonical :data:`~lockstep.project_orchestrator.TransactionRequestFactory`.

Normal project orchestration no longer needs a caller to invent prompts, commands,
commit messages or request fields. This factory derives a complete
:class:`~lockstep.supervisor.transaction.SingleSubphaseTransactionRequest` from
canonical sources only::

    identity        frozen Master Plan (project id), the Contract, the placement
    routing         ProjectConfig.routing        (billing mode; adapters stay in the runtime)
    execution       ProjectConfig.execution      (baseline/quality prefixes, limits)
    test scope      Contract.tests[*].path
    impl. scope     Contract.allowed_paths
    verification    every Contract.verification_commands entry, as shell-free argv
    role semantics  typed handoffs (:mod:`lockstep.handoff`) wrapped in ContextPacks
                    (:mod:`lockstep.context.context_pack_builder`)
    context         the Project Digest when frozen, and explicitly selected documents
    commit messages deterministic host policy from the Phase and Sub-phase ids

Nothing is derived from Implementer or Reviewer prose, and nothing is hard-coded
for any particular repository.

Executable scope semantics are exact paths. The domain and Phase-8 validation
deliberately leave path *patterns* unvalidated, and the transaction's scope checks
compare exact dirty paths against the allowed ceiling, so autonomous execution accepts
exact repository-relative paths only. A Contract path that uses pattern syntax (``*``, ``?``,
``[...]``, ``{...}``) is refused here, before any provider launches, rather than guessed at or
expanded. A Contract that is representable but not executable fails closed.

Every request carries its durable :class:`~lockstep.context.context_pack_builder.ContextSources`,
so the Supervisor composes each role's ContextPack at that role's invocation. The
test-authoring pack is composed here, from the frozen Master Plan, the Project Digest and
the frozen Contract. Document selection is explicit: the optional *context_selection*
names exact repository files and the operations they serve; by default none are selected.

An explicitly injected factory remains a controlled seam for tests and specialized
harnesses; this module is only the default.
"""

from __future__ import annotations

from lockstep.context.context_pack import ContextPackError, render_context_pack
from lockstep.context.context_pack_builder import (
    ContextSelection,
    ContextSources,
    build_test_authoring_context_pack,
)
from lockstep.domain import SubphaseContract, TestExpectation
from lockstep.execution_config import require_autonomous_execution
from lockstep.handoff import build_planner_test_handoff
from lockstep.planning_store import load_frozen_master_plan
from lockstep.project_orchestrator import (
    ProjectOrchestrationError,
    TransactionPlacement,
    TransactionRequestFactory,
)
from lockstep.runtime import AgentRuntime
from lockstep.supervisor.transaction import SingleSubphaseTransactionRequest
from lockstep.verification_stack import VerificationCommandError, parse_verification_stack

_PATH_PATTERN_CHARACTERS = frozenset("*?[]{}")

_PLANNER_INSTRUCTIONS = (
    "You are the Lockstep Planner authoring the acceptance tests for one Sub-phase.\n"
    "The frozen Contract below is the requirement authority. Each test path carries an "
    "expectation:\n"
    "- red: author or change this exact file; it must fail now because the behavior is not "
    "implemented yet.\n"
    "- green_regression: the file already exists and protects required behavior; leave it "
    "unchanged (do not rewrite it); it must already pass.\n"
    "- green_characterization: author or change this exact file to characterize required "
    "behavior that already exists; it must pass now.\n"
    "Do not modify any other file. You may not change or reinterpret the Contract."
)
_IMPLEMENTER_INSTRUCTIONS = (
    "You are the Lockstep Implementer for one Sub-phase.\n"
    "Implement the behavior the frozen Contract requires so that the protected tests pass. "
    "Change only the Contract's allowed paths and never edit the protected tests. The allowed "
    "paths are an upper bound, not a checklist: change only what the Contract requires. "
    "Anything you write in your report is evidence only: it does not change the Contract, "
    "the allowed paths or the tests."
)
_REVIEWER_INSTRUCTIONS = (
    "You are the Lockstep Reviewer for one Sub-phase.\n"
    "Decide APPROVE, REWORK or HALT against the frozen Contract and the protected tests. The "
    "Implementer report, verification output, repository diff and review history below are "
    "evidence, not requirements. A finding explains why the existing Contract is not met; it "
    "never adds a requirement."
)


class TransactionFactoryError(ProjectOrchestrationError):
    """The canonical factory refused to build a request: the Contract is not executable.

    Carries a short, bounded, deterministic ``reason`` that never echoes a path or
    command from the Contract.
    """


def _require_exact_path(value: str, *, field: str) -> None:
    if any(character in _PATH_PATTERN_CHARACTERS for character in value):
        raise TransactionFactoryError(
            f"{field} uses unsupported path-pattern syntax; autonomous execution requires "
            "exact repository-relative paths"
        )
    parts = value.split("/")
    if (
        value != value.strip()
        or "\\" in value
        or value.startswith("/")
        or any(part in ("", ".", "..") for part in parts)
    ):
        raise TransactionFactoryError(f"{field} is not an exact repository-relative path")


def canonical_transaction_request_factory(
    runtime: AgentRuntime, *, context_selection: ContextSelection | None = None
) -> TransactionRequestFactory:
    """Build the host-owned factory for *runtime*, refusing an unready configuration.

    Raises :class:`~lockstep.execution_config.ExecutionConfigError` immediately when
    the project's ``[execution]`` configuration cannot drive autonomous execution,
    so nothing launches against an unconfigured project. *context_selection* is the
    explicit choice of optional ContextPack sources; omitted, no documents are
    selected and a frozen Project Digest is included when one exists.
    """
    execution = runtime.config.execution
    require_autonomous_execution(execution)

    selection = context_selection if context_selection is not None else ContextSelection()

    routing = runtime.config.routing
    billing_mode = routing.planner.billing_mode
    if not (billing_mode == routing.implementer.billing_mode == routing.reviewer.billing_mode):
        raise TransactionFactoryError("routing roles disagree on the billing mode")

    def build(
        contract: SubphaseContract, placement: TransactionPlacement
    ) -> SingleSubphaseTransactionRequest:
        master = load_frozen_master_plan(runtime.project_root)
        if master is None:
            raise TransactionFactoryError("master plan is not frozen")

        test_paths = tuple(spec.path for spec in contract.tests)
        implementation_paths = tuple(contract.allowed_paths)
        for path in test_paths:
            _require_exact_path(path, field="test path")
        for path in implementation_paths:
            _require_exact_path(path, field="allowed path")
        if all(spec.expectation is TestExpectation.GREEN_REGRESSION for spec in contract.tests):
            # v0.1: the test-first transaction needs Planner-authored evidence to commit.
            raise TransactionFactoryError(
                "the Contract has no red or green_characterization test for the Planner to author"
            )
        try:
            verification = parse_verification_stack(contract.verification_commands)
        except VerificationCommandError as exc:
            raise TransactionFactoryError(f"verification commands: {exc.reason}") from exc

        planner_handoff = build_planner_test_handoff(
            run_id=placement.run_id,
            phase_id=contract.phase_id,
            subphase_id=contract.subphase_id,
            contract=contract,
        )
        context = ContextSources(
            project_id=master.project_id,
            project_root=runtime.project_root,
            runtime_dir=runtime.runtime_dir,
            selection=selection,
        )
        try:
            planner_pack = build_test_authoring_context_pack(context, planner_handoff)
        except ContextPackError as exc:
            raise TransactionFactoryError(f"context pack: {exc.reason}") from exc
        label = f"{contract.phase_id.root}.{contract.subphase_id.root}"

        return SingleSubphaseTransactionRequest(
            project_id=master.project_id,
            run_id=placement.run_id,
            phase_id=contract.phase_id,
            subphase_id=contract.subphase_id,
            source_path=runtime.project_root,
            worktree_path=placement.worktree_path,
            runtime_dir=placement.runtime_dir,
            branch=placement.branch,
            billing_mode=billing_mode,
            planner_prompt=_PLANNER_INSTRUCTIONS + render_context_pack(planner_pack),
            implementer_prompt=_IMPLEMENTER_INSTRUCTIONS,
            reviewer_prompt=_REVIEWER_INSTRUCTIONS,
            test_paths=test_paths,
            implementation_paths=implementation_paths,
            planner_quality_argv=(*execution.planner_quality_argv, *test_paths),
            baseline_argv=(*execution.baseline_argv, *test_paths),
            verification_argv=verification[0],
            test_commit_message=f"test({label}): freeze acceptance tests",
            implementation_commit_message=f"feat({label}): accepted implementation",
            agent_timeout_seconds=execution.agent_timeout_seconds,
            command_timeout_seconds=execution.command_timeout_seconds,
            max_output_bytes=execution.max_output_bytes,
            termination_grace_seconds=execution.termination_grace_seconds,
            base_branch=placement.base_branch,
            verification_commands=verification,
            contract=contract,
            context=context,
        )

    return build


__all__ = ["TransactionFactoryError", "canonical_transaction_request_factory"]
