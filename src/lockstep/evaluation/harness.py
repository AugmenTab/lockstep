"""Run evaluation trials through the ordinary canonical machinery, one isolated fixture each.

There is no evaluation execution engine. A trial is::

    fixture        a fresh Git repository under the caller's workspace, materialized from
                   the case: its files, the tracked ``lockstep.toml`` (the requested routing,
                   the case's execution policy) and the frozen Master Plan, in one commit
    runtime        the requested provider selection binds an AgentRuntime for that project
                   (production: :func:`prepared_runtime_binder`, i.e. prepare_agent_runtime)
    run            run_project_phase with the canonical transaction request factory, wrapped
                   at its documented injection seam so the arm sets the one policy surface
    observe        the cursor, transaction journals, evidence store, Git and the accepted
                   Phase-10 metrics, read after the run
    grade          deterministic graders over that evidence
    classify       typed attribution (:func:`~lockstep.evaluation.results.classify_trial`)

Layout under the caller-supplied *workspace* (the harness never chooses a root; for
persistent local evidence use an ignored ``.local/evals/...`` tree of the Lockstep
checkout)::

    <case_id>/<arm_id>/repeat-<n>/source/    the trial's own fixture repository
    <case_id>/<arm_id>/repeat-<n>/runtime/   its Lockstep runtime directory

A trial never reuses a directory, so no arm or repetition can inherit another's state.
The arm's instructions reach only the isolated requests of its own trial; production
configuration, routing and the canonical instructions are never modified. Results are
returned, not persisted; the caller may serialize them as evaluation evidence.
"""

from __future__ import annotations

import dataclasses
import hashlib
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path

from lockstep.agents import ProviderRuntimeOverrides
from lockstep.agents.routing import AgentRoutingPolicy
from lockstep.config import LOCKSTEP_CONFIG_FILENAME, ProjectConfig, render_project_config
from lockstep.domain import (
    AttemptNumber,
    ExecutionEventKind,
    RunId,
    SubphaseContract,
)
from lockstep.evaluation.cases import (
    EvalArm,
    EvalSuite,
    EvalTrial,
    EvalTrialIdentity,
    PolicySurface,
    expand_trials,
)
from lockstep.evaluation.graders import (
    EvalObservation,
    GradeOutcome,
    GradeResult,
    TransactionObservation,
    grade,
    implementer_blocked,
)
from lockstep.evaluation.results import (
    EvalSuiteResult,
    EvalTrialOutcome,
    EvalTrialResult,
    aggregate_suite,
    classify_trial,
)
from lockstep.git import inspect_repository, measure_repository_change
from lockstep.git.evidence import changes_since, is_ancestor
from lockstep.git.repository import _run_git_text
from lockstep.metrics import SubphaseMetrics, project_run_metrics
from lockstep.persistence import ExecutionEvent, read_events
from lockstep.planning_store import freeze_master_plan
from lockstep.project_cursor_store import load_project_cursor
from lockstep.project_orchestrator import (
    ProjectRunDisposition,
    TransactionPlacement,
    TransactionRequestFactory,
    run_project_phase,
    transaction_runtime_dir,
    transaction_worktree_path,
)
from lockstep.retry import RetryBudget
from lockstep.runtime import AgentRuntime, prepare_agent_runtime
from lockstep.supervisor.transaction import SingleSubphaseTransactionRequest
from lockstep.transaction_factory import canonical_transaction_request_factory

_JOURNAL_NAME = "events.jsonl"
_FIXTURE_AUTHOR = ("Lockstep Evaluation", "lockstep-eval@example.invalid")


class EvalHarnessError(Exception):
    """The caller asked for something the harness refuses before any trial starts."""

    def __init__(self, reason: str) -> None:
        self.reason = reason
        super().__init__(f"evaluation harness error: {reason}")


@dataclass(frozen=True, slots=True)
class EvalTrialPlacement:
    """Where one trial lives: its own directory, fixture repository and runtime directory."""

    trial: EvalTrial
    trial_root: Path
    project_root: Path
    runtime_dir: Path


RuntimeBinder = Callable[[EvalTrialPlacement], AgentRuntime]


@dataclass(frozen=True, slots=True)
class EvalRuntimeSelection:
    """The provider/runtime choice of an experiment: explicit input, never a global.

    ``routing`` is written into every fixture's tracked configuration; ``bind_runtime``
    composes an :class:`~lockstep.runtime.AgentRuntime` for a trial's project from it. The
    harness refuses a runtime whose routing differs from ``routing``.
    """

    routing: AgentRoutingPolicy
    bind_runtime: RuntimeBinder


def prepared_runtime_binder(
    *,
    operator_parent_env: Mapping[str, str],
    provider_overrides: ProviderRuntimeOverrides | None = None,
) -> RuntimeBinder:
    """Bind real configured providers through the production runtime preparation.

    Diagnoses and resolves providers from the fixture's tracked ``lockstep.toml`` exactly
    as production does. Using it calls real providers; qualification uses scripted ones.
    """
    environment = dict(operator_parent_env)

    def bind(placement: EvalTrialPlacement) -> AgentRuntime:
        return prepare_agent_runtime(
            placement.project_root,
            placement.runtime_dir,
            operator_parent_env=environment,
            provider_overrides=provider_overrides,
        )

    return bind


def trial_placement(trial: EvalTrial, workspace: Path) -> EvalTrialPlacement:
    """The deterministic location of *trial* under *workspace*."""
    identity = trial.identity
    root = (
        Path(workspace).resolve()
        / identity.case_id
        / identity.arm_id
        / f"repeat-{identity.repeat_index}"
    )
    return EvalTrialPlacement(
        trial=trial,
        trial_root=root,
        project_root=root / "source",
        runtime_dir=root / "runtime",
    )


def arm_request_factory(base: TransactionRequestFactory, arm: EvalArm) -> TransactionRequestFactory:
    """Wrap *base* so every request carries the arm's value of its one policy surface."""
    match arm.surface:
        case PolicySurface.IMPLEMENTER_INSTRUCTIONS:
            instructions = arm.instructions

    def build(
        contract: SubphaseContract, placement: TransactionPlacement
    ) -> SingleSubphaseTransactionRequest:
        return dataclasses.replace(base(contract, placement), implementer_prompt=instructions)

    return build


# ---------------------------------------------------------------------------
# Trial stages
# ---------------------------------------------------------------------------


def _harness_failure(
    identity: EvalTrialIdentity,
    stage: str,
    cause: BaseException,
    *,
    fixture_commit: str | None = None,
    fixture_tree: str | None = None,
) -> EvalTrialResult:
    reason = cause.reason if isinstance(cause, EvalHarnessError) else type(cause).__name__
    return EvalTrialResult(
        identity=identity,
        outcome=EvalTrialOutcome.HARNESS_FAILURE,
        failure_detail=f"{stage}: {reason}",
        fixture_commit=fixture_commit,
        fixture_tree=fixture_tree,
    )


def _git(root: Path, *args: str) -> str:
    return _run_git_text(root, list(args)).stdout.strip()


def _materialize_fixture(placement: EvalTrialPlacement, routing: AgentRoutingPolicy) -> str:
    """Create the trial's fixture repository; return its single commit."""
    if placement.trial_root.exists():
        raise EvalHarnessError("trial directory already exists")
    case = placement.trial.case
    source = placement.project_root
    source.mkdir(parents=True)
    placement.runtime_dir.mkdir()
    _git(source, "init", "--quiet")
    _git(source, "symbolic-ref", "HEAD", "refs/heads/main")
    _git(source, "config", "user.name", _FIXTURE_AUTHOR[0])
    _git(source, "config", "user.email", _FIXTURE_AUTHOR[1])
    _git(source, "config", "commit.gpgsign", "false")
    for path, content in case.fixture.files.items():
        target = source / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(content.encode("utf-8"))
    config = ProjectConfig(schema_version=1, routing=routing, execution=case.fixture.execution)
    (source / LOCKSTEP_CONFIG_FILENAME).write_bytes(render_project_config(config).encode("utf-8"))
    freeze_master_plan(source, case.fixture.master_plan)
    _git(source, "add", "--all")
    _git(source, "commit", "--quiet", "--no-verify", "-m", f"evaluation fixture {case.case_id}")
    return _git(source, "rev-parse", "HEAD")


def _bind(placement: EvalTrialPlacement, selection: EvalRuntimeSelection) -> AgentRuntime:
    runtime = selection.bind_runtime(placement)
    if runtime.config.routing != selection.routing:
        raise EvalHarnessError("the bound runtime does not carry the requested routing")
    if (runtime.project_root, runtime.runtime_dir) != (
        placement.project_root.resolve(),
        placement.runtime_dir.resolve(),
    ):
        raise EvalHarnessError("the bound runtime is not placed in the trial")
    return runtime


def _transaction(
    runtime_dir: Path, run_id: RunId, *, completed: bool
) -> tuple[TransactionObservation, SubphaseMetrics | None]:
    directory = transaction_runtime_dir(runtime_dir, run_id)
    journal = directory / _JOURNAL_NAME
    worktree = transaction_worktree_path(runtime_dir, run_id)
    events = read_events(journal) if journal.exists() else []
    execution = tuple(e for e in events if isinstance(e, ExecutionEvent))
    frozen = [e.detail for e in execution if e.kind is ExecutionEventKind.TESTS_FROZEN]
    tests_frozen_sha = frozen[-1] if frozen else None
    metrics = None
    if any(e.kind is ExecutionEventKind.INVOCATION_STARTED for e in execution):
        change = None
        if completed and tests_frozen_sha is not None and worktree.exists():
            head = inspect_repository(worktree).head_sha
            change = measure_repository_change(worktree, tests_frozen_sha, head)
        [metrics] = project_run_metrics(events, repository_change=change).subphases
    observation = TransactionObservation(
        run_id=run_id,
        runtime_dir=directory,
        worktree=worktree,
        journal=journal,
        events=execution,
        tests_frozen_sha=tests_frozen_sha,
        completed=completed,
    )
    return observation, metrics


def _observe(
    placement: EvalTrialPlacement,
    workspace: Path,
    fixture_commit: str,
    disposition: ProjectRunDisposition | None,
) -> tuple[EvalObservation, tuple[str, ...]]:
    cursor = load_project_cursor(placement.project_root, placement.runtime_dir)
    bound: list[tuple[RunId, str, bool]] = []
    if cursor is not None:
        bound.extend((c.run_id, c.contract_digest, True) for c in cursor.completed_subphases)
        if cursor.active_contract is not None:
            active = cursor.active_contract
            bound.append((active.transaction_run_id, active.contract_digest, False))
    runtime_dir = placement.runtime_dir.resolve()
    transactions: list[TransactionObservation] = []
    subphases: list[SubphaseMetrics] = []
    for run_id, _digest, completed in bound:
        transaction, metrics = _transaction(runtime_dir, run_id, completed=completed)
        transactions.append(transaction)
        if metrics is not None:
            subphases.append(metrics)

    existing = [t.worktree for t in transactions if t.worktree.exists()]
    repository = existing[-1] if existing else placement.project_root.resolve()
    snapshot = inspect_repository(repository)
    implemented = [
        t for t in transactions if t.tests_frozen_sha is not None and t.worktree.exists()
    ]
    changes: tuple[str, ...] | None = None
    if implemented:
        paths: set[str] = set()
        for t in implemented:
            assert t.tests_frozen_sha is not None
            paths.update(
                c.path for c in changes_since(t.worktree, t.tests_frozen_sha, max_patch_bytes=1)
            )
        changes = tuple(sorted(paths))
    observation = EvalObservation(
        evidence_root=workspace,
        fixture_commit=fixture_commit,
        disposition=disposition,
        repository=repository,
        snapshot=snapshot,
        fixture_in_history=is_ancestor(repository, fixture_commit, snapshot.head_sha),
        implementation_changes=changes,
        transactions=tuple(transactions),
        subphases=tuple(subphases),
    )
    return observation, tuple(digest for _run, digest, _completed in bound)


def _crashed(grader_id: str, kind: str, hard: bool, exc: BaseException) -> GradeResult:
    return GradeResult(
        grader_id=grader_id,
        kind=kind,
        hard=hard,
        outcome=GradeOutcome.UNAVAILABLE,
        failure_reason=f"the grader raised {type(exc).__name__}",
    )


def run_trial(
    trial: EvalTrial, selection: EvalRuntimeSelection, workspace: Path
) -> EvalTrialResult:
    """Run one trial in isolation and return its structured, classified result.

    Raises :class:`EvalHarnessError` only when the trial was expanded for a different
    provider selection; every failure after that is recorded in the result.
    """
    if trial.routing != selection.routing:
        raise EvalHarnessError("the trial was expanded for a different provider selection")
    workspace = Path(workspace).resolve()
    workspace.mkdir(parents=True, exist_ok=True)
    placement = trial_placement(trial, workspace)
    identity = trial.identity
    case = trial.case

    try:
        fixture_commit = _materialize_fixture(placement, selection.routing)
        fixture_tree = _git(placement.project_root, "rev-parse", "HEAD^{tree}")
    except Exception as exc:
        return _harness_failure(identity, "fixture", exc)
    fixture = {"fixture_commit": fixture_commit, "fixture_tree": fixture_tree}

    try:
        runtime = _bind(placement, selection)
        factory = arm_request_factory(canonical_transaction_request_factory(runtime), trial.arm)
    except Exception as exc:
        return _harness_failure(identity, "runtime", exc, **fixture)

    delivered: set[str] = set()

    def recording_factory(
        contract: SubphaseContract, transaction: TransactionPlacement
    ) -> SingleSubphaseTransactionRequest:
        request = factory(contract, transaction)
        delivered.add(hashlib.sha256(request.implementer_prompt.encode("utf-8")).hexdigest())
        return request

    disposition: ProjectRunDisposition | None = None
    run_failure: str | None = None
    try:
        run = run_project_phase(
            runtime,
            request_factory=recording_factory,
            retry_budget=RetryBudget(
                max_attempts=AttemptNumber.model_validate(case.bounds.max_attempts)
            ),
            planning_timeout_seconds=case.bounds.planning_timeout_seconds,
            jit_replan=case.bounds.jit_replan,
        )
        disposition = run.disposition
    except Exception as exc:
        run_failure = f"run: {type(exc).__name__}"

    try:
        observation, contract_digests = _observe(placement, workspace, fixture_commit, disposition)
    except Exception as exc:
        return _harness_failure(identity, "observe", exc, **fixture)

    grades: list[GradeResult] = []
    grader_failure: str | None = None
    for grader in case.graders:
        try:
            grades.append(grade(grader, observation))
        except Exception as exc:
            grades.append(_crashed(grader.grader_id, grader.kind, grader.hard, exc))
            grader_failure = grader_failure or f"grader:{grader.grader_id}"

    outcome, detail = classify_trial(
        harness_failure=grader_failure,
        run_failure=run_failure,
        disposition=disposition,
        expected_disposition=case.expected_disposition,
        causes=[e.cause for e in observation.events() if e.cause is not None],
        grades=grades,
    )
    return EvalTrialResult(
        identity=identity,
        outcome=outcome,
        failure_detail=detail,
        fixture_commit=fixture_commit,
        fixture_tree=fixture_tree,
        delivered_instructions_sha256=next(iter(delivered)) if len(delivered) == 1 else None,
        disposition=disposition,
        transaction_run_ids=tuple(t.run_id for t in observation.transactions),
        contract_digests=contract_digests,
        implementer_blocked=implementer_blocked(observation.events()),
        grades=tuple(grades),
        subphases=observation.subphases,
        evidence=observation.journals(),
    )


def run_suite(
    suite: EvalSuite, selection: EvalRuntimeSelection, workspace: Path
) -> EvalSuiteResult:
    """Run every trial of *suite* sequentially under *selection*, then aggregate.

    Each trial runs exactly once: no retry-until-pass, no early stop on a lucky result.
    """
    trials = [
        run_trial(trial, selection, workspace) for trial in expand_trials(suite, selection.routing)
    ]
    return aggregate_suite(suite, trials)


__all__ = [
    "EvalHarnessError",
    "EvalRuntimeSelection",
    "EvalTrialPlacement",
    "RuntimeBinder",
    "arm_request_factory",
    "prepared_runtime_binder",
    "run_suite",
    "run_trial",
    "trial_placement",
]
