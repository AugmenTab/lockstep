"""Planner Test Authoring Bridge (Sub-phase 8.7).

Bridges a frozen active :class:`~lockstep.domain.SubphaseContract` into
actual Planner-authored executable test files inside an isolated,
caller-supplied Git worktree:

    frozen Master Plan
        +
    published current PhasePlan
        +
    frozen active SubphaseContract
        +
    explicit isolated clean Git worktree
        ↓
    configured normal writable Planner adapter (``runtime.adapters.planner``)
        ↓
    Planner authors exactly the Contract's TestSpecification.path files
        ↓
    deterministic Git/filesystem scope verification
        ↓
    test-file integrity hashes
        ↓
    PlannerTestAuthoringResult

The Planner may write the Contract's exact test files and nothing
else: no production code, no planning artifacts, no Git history, no
Git index. Every fact about what actually changed is established
through the public, read-only :func:`lockstep.git.inspect_repository`
surface; this module performs no Git mutation and launches no raw Git
subprocess. It does not run the authored tests, does not classify
RED/GREEN outcomes, does not commit, and never invokes the Implementer
or Reviewer roles.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path

from lockstep.agents import (
    AgentInvocationRequest,
    AgentInvocationResult,
    invoke_agent,
)
from lockstep.contract_test_targets import target_path_violation, traverses_symlink
from lockstep.domain import (
    AgentRole,
    PhaseId,
    PhasePlan,
    SubphaseContract,
    SubphaseId,
    SubphaseOutline,
)
from lockstep.git import inspect_repository
from lockstep.planning_store import (
    load_active_subphase_contract,
    load_frozen_master_plan,
    load_phase_plan,
)
from lockstep.runtime import AgentRuntime

_CONTRACT_LABEL = "Frozen active Contract:"
_PHASE_PLAN_LABEL = "Current Phase plan:"
_TARGET_OUTLINE_LABEL = "Target subphase outline:"
_TARGET_PHASE_LABEL = "Target phase_id:"
_TARGET_SUBPHASE_LABEL = "Target subphase_id:"
_WRITABLE_PATHS_LABEL = "Writable test paths (JSON array):"

_AUTHORING_INSTRUCTIONS = (
    "You are in executable-test-authoring mode.\n"
    "The active SubphaseContract above is frozen and authoritative.\n"
    "Author executable tests that implement exactly its TestSpecification "
    "entries.\n"
    "You may inspect the repository read-only to understand existing "
    "architecture, fixtures, test conventions, and public behavior.\n"
    "Modify exactly the writable test paths listed above and no others.\n"
    "Do not modify production code.\n"
    "Do not modify configuration.\n"
    "Do not modify planning artifacts.\n"
    "Do not alter the Contract.\n"
    "Do not stage, commit, reset, checkout, rebase, merge, or otherwise "
    "mutate Git history or the Git index.\n"
    "Do not implement the production behavior the tests describe.\n"
    "Do not weaken existing tests.\n"
    "Do not change the requested baseline expectation.\n"
    "A test with expectation red is intended to fail against the current "
    "pre-implementation repository because required new behavior is "
    "absent.\n"
    "A test with expectation green_regression protects existing required "
    "behavior and is intended to pass now.\n"
    "A test with expectation green_characterization records required "
    "existing behavior and is intended to pass now.\n"
    "You author the test accordingly; you do not execute or claim its "
    "baseline classification yourself.\n"
    "Make each authored test clearly traceable to the acceptance-criterion "
    "ids listed for its TestSpecification.\n"
    "When complete, leave the authored test files in the working tree.\n"
)


class TestAuthoringError(Exception):
    """An authoring/control failure owned by this layer.

    Carries a short, bounded, deterministic ``reason``. Never carries
    the Planner prompt, file contents, stdout, stderr, environment
    values, or a full Git diff. Lower-layer typed failures (Git
    inspection errors, :class:`~lockstep.planning_store.PlanningStoreError`,
    and agent/process errors) propagate unwrapped and are never
    represented by this exception.
    """

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"test authoring error: {reason}")


@dataclass(frozen=True, slots=True)
class AuthoredTestFile:
    """One Planner-authored test file's canonical path and content hash."""

    path: str
    sha256: str


@dataclass(frozen=True, slots=True)
class PlannerTestAuthoringResult:
    """Immutable record of one successful Planner test-authoring turn.

    ``files`` preserves the frozen Contract's ``tests`` order. Neither
    field appears in :func:`repr`... only ``invocation`` is excluded;
    ``files`` carries no prompt, stdout, or file content, so it is safe
    to display.
    """

    files: tuple[AuthoredTestFile, ...]
    invocation: AgentInvocationResult = field(repr=False)


def _paths_overlap(first: Path, second: Path) -> bool:
    return first == second or first.is_relative_to(second) or second.is_relative_to(first)


def _require_clean_baseline(
    *,
    staged_paths: tuple[str, ...],
    unstaged_paths: tuple[str, ...],
    untracked_paths: tuple[str, ...],
    dirty_paths: tuple[str, ...],
) -> None:
    if staged_paths != () or unstaged_paths != () or untracked_paths != () or dirty_paths != ():
        raise TestAuthoringError(reason="worktree is not clean")


def _validate_test_specification_path(path: str) -> None:
    # The structural definition is shared with the pre-freeze Contract check (11.7-R1).
    if target_path_violation(path) is not None:
        raise TestAuthoringError(reason=f"unsafe test specification path: {path!r}")


def _require_no_symlink_components(worktree_path: Path, path: str) -> None:
    if traverses_symlink(worktree_path, path):
        raise TestAuthoringError(
            reason=f"unsafe test specification path traverses a symlink: {path!r}"
        )


def _require_present(worktree_path: Path, path: str) -> None:
    target = worktree_path / path
    if not target.exists() and not target.is_symlink():
        raise TestAuthoringError(reason=f"required test path was deleted: {path!r}")


def _require_regular_file(worktree_path: Path, path: str) -> None:
    target = worktree_path / path
    if target.is_symlink():
        raise TestAuthoringError(reason=f"required test path became a symlink: {path!r}")
    if not target.is_file():
        raise TestAuthoringError(reason=f"required test path is not a regular file: {path!r}")


def _find_outline(phase_plan: PhasePlan, subphase_id: SubphaseId) -> SubphaseOutline | None:
    for outline in phase_plan.subphases:
        if outline.subphase_id == subphase_id:
            return outline
    return None


def _canonical_json(model: SubphaseContract | PhasePlan | SubphaseOutline) -> str:
    return json.dumps(model.model_dump(mode="json"), ensure_ascii=False, separators=(",", ":"))


def _build_authoring_prompt(
    *,
    contract: SubphaseContract,
    phase_plan: PhasePlan,
    target_outline: SubphaseOutline,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    test_paths: tuple[str, ...],
) -> str:
    writable_paths_json = json.dumps(list(test_paths), ensure_ascii=False, separators=(",", ":"))
    return (
        f"{_CONTRACT_LABEL}\n"
        f"{_canonical_json(contract)}\n"
        "\n"
        f"{_PHASE_PLAN_LABEL}\n"
        f"{_canonical_json(phase_plan)}\n"
        "\n"
        f"{_TARGET_OUTLINE_LABEL}\n"
        f"{_canonical_json(target_outline)}\n"
        "\n"
        f"{_TARGET_PHASE_LABEL}\n"
        f"{phase_id.root}\n"
        "\n"
        f"{_TARGET_SUBPHASE_LABEL}\n"
        f"{subphase_id.root}\n"
        "\n"
        f"{_WRITABLE_PATHS_LABEL}\n"
        f"{writable_paths_json}\n"
        "\n"
        f"{_AUTHORING_INSTRUCTIONS}"
    )


def author_planner_tests(
    runtime: AgentRuntime,
    *,
    worktree_path: Path,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    timeout_seconds: float,
    max_output_bytes: int = 1_048_576,
    termination_grace_seconds: float = 0.25,
) -> PlannerTestAuthoringResult:
    """Ask the configured Planner to author exactly the active Contract's tests.

    Performs, in order: worktree structural checks (not the canonical
    source checkout, no overlap with *runtime*'s runtime directory), a
    Git worktree validity/clean-baseline check via the public
    :func:`lockstep.git.inspect_repository` surface, planning-state
    preflight (frozen Master Plan, published current Phase plan, active
    Contract, explicit phase/subphase identity binding, current-outline
    membership), Contract test-path safety validation, exactly one
    normal writable Planner invocation
    (:func:`~lockstep.agents.invoke_agent` against
    ``runtime.adapters.planner``), and deterministic post-invocation
    Git/filesystem scope verification, in priority order: HEAD/branch
    unchanged, no staged changes, no unexpected/out-of-contract path,
    no unsafe deletion/symlink/non-regular mutation among the Contract
    paths the Planner actually touched, then a non-zero Planner process
    exit, and only then a merely-missing expected path. Returns
    exact-byte SHA-256 hashes for each authored file in Contract order.
    Performs no Git mutation, no
    planning-state mutation, no baseline test execution, and invokes no
    role other than Planner.
    """
    resolved_worktree = Path(worktree_path).resolve()

    if resolved_worktree == runtime.project_root:
        raise TestAuthoringError(reason="worktree path must not be the canonical source checkout")
    if _paths_overlap(resolved_worktree, runtime.runtime_dir):
        raise TestAuthoringError(reason="worktree path must not overlap the runtime directory")

    baseline_snapshot = inspect_repository(resolved_worktree)
    _require_clean_baseline(
        staged_paths=baseline_snapshot.staged_paths,
        unstaged_paths=baseline_snapshot.unstaged_paths,
        untracked_paths=baseline_snapshot.untracked_paths,
        dirty_paths=baseline_snapshot.dirty_paths,
    )

    master_plan = load_frozen_master_plan(runtime.project_root)
    if master_plan is None:
        raise TestAuthoringError(reason="master plan is not frozen")

    phase_plan = load_phase_plan(runtime.project_root, runtime.runtime_dir)
    if phase_plan is None:
        raise TestAuthoringError(reason="current phase plan is not published")

    contract = load_active_subphase_contract(runtime.project_root, runtime.runtime_dir)
    if contract is None:
        raise TestAuthoringError(reason="subphase contract is not active")

    if phase_plan.phase_id != phase_id:
        raise TestAuthoringError(reason="published phase plan does not match requested phase")
    if contract.phase_id != phase_id:
        raise TestAuthoringError(reason="active contract does not match requested phase")
    if contract.subphase_id != subphase_id:
        raise TestAuthoringError(reason="active contract does not match requested subphase")

    target_outline = _find_outline(phase_plan, subphase_id)
    if target_outline is None:
        raise TestAuthoringError(
            reason="requested subphase is not present in the current phase plan"
        )

    test_paths = tuple(test.path for test in contract.tests)
    for path in test_paths:
        _validate_test_specification_path(path)
    for path in test_paths:
        _require_no_symlink_components(resolved_worktree, path)

    prompt = _build_authoring_prompt(
        contract=contract,
        phase_plan=phase_plan,
        target_outline=target_outline,
        phase_id=phase_id,
        subphase_id=subphase_id,
        test_paths=test_paths,
    )

    request = AgentInvocationRequest(
        role=AgentRole.PLANNER,
        billing_mode=runtime.config.routing.planner.billing_mode,
        prompt=prompt,
        cwd=resolved_worktree,
        timeout_seconds=timeout_seconds,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=termination_grace_seconds,
    )

    invocation = invoke_agent(
        runtime.adapters.planner,
        request,
        parent_env=runtime.transaction_parent_env,
    )

    post_snapshot = inspect_repository(resolved_worktree)

    if (
        post_snapshot.head_sha != baseline_snapshot.head_sha
        or post_snapshot.branch != baseline_snapshot.branch
    ):
        raise TestAuthoringError(reason="planner changed git history")

    if post_snapshot.staged_paths != ():
        raise TestAuthoringError(reason="planner modified the git index")

    changed_paths = set(post_snapshot.dirty_paths)
    test_path_set = set(test_paths)

    unexpected_paths = changed_paths - test_path_set
    if unexpected_paths:
        raise TestAuthoringError(
            reason="planner modified paths outside the contract test specification"
        )

    changed_test_paths = test_path_set & changed_paths
    for path in test_paths:
        if path in changed_test_paths:
            _require_present(resolved_worktree, path)
    for path in test_paths:
        if path in changed_test_paths:
            _require_regular_file(resolved_worktree, path)

    if not invocation.process.succeeded:
        raise TestAuthoringError(
            reason=f"planner process exited with status {invocation.process.returncode}"
        )

    missing_paths = test_path_set - changed_paths
    if missing_paths:
        raise TestAuthoringError(reason="required test path was not changed by the planner")

    files = tuple(
        AuthoredTestFile(
            path=path,
            sha256=hashlib.sha256((resolved_worktree / path).read_bytes()).hexdigest(),
        )
        for path in test_paths
    )

    return PlannerTestAuthoringResult(files=files, invocation=invocation)


__all__ = [
    "AuthoredTestFile",
    "PlannerTestAuthoringResult",
    "TestAuthoringError",
    "author_planner_tests",
]
