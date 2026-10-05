"""Trial classification, deterministic aggregation, pairing and quality-gated ranking.

Classification keeps failure attribution typed and ordered (first match wins):

    HARNESS_FAILURE          the eval layer itself failed: fixture, runtime binding, run,
                             observation or a grader raised
    ENVIRONMENT_FAILURE      the run did not end as expected and the journal records
                             ``environment_failure``
    PROVIDER_FAILURE         ... records ``provider_process_failure`` / ``usage_exhaustion``
    GRADER_FAILURE           a hard grader observed a violation (FAIL)
    TASK_FAILURE             the run ended in a different disposition than the case expects
    UNAVAILABLE_MEASUREMENT  a hard grader could not observe what it needs
    PASS                     every hard grader passed and the run ended as expected

Provider and environment causes reuse the accepted :class:`~lockstep.domain.FailureCause`
values from the journal, and only explain a run that did not end as expected (a provider
failure the transaction recovered from is not the trial's outcome).

Aggregation never re-derives a metric: an arm's ``metrics`` is the accepted Phase-10
:func:`~lockstep.metrics.aggregate_metrics` over the Sub-phase metrics of its trials. The
eval-layer counts (hard passes, blocked runs, ...) are counts over trials. Every aggregate
sorts its inputs first, so it does not depend on trial order, and raw trials are kept.
No inferential statistics are computed.

Ranking applies the quality gate before any comparative measure: an arm whose trials did
not all pass their hard graders never ranks ahead of one whose trials all did, whatever
the measure.
"""

from __future__ import annotations

from collections import Counter
from collections.abc import Callable, Iterable, Sequence
from enum import StrEnum

from pydantic import BaseModel, ConfigDict

from lockstep.domain import FailureCause, RunId
from lockstep.evaluation.cases import EvalSuite, EvalTrialIdentity
from lockstep.evaluation.graders import GradeOutcome, GradeResult
from lockstep.metrics import Ratio, SubphaseMetrics, TransactionMetrics, UsageAggregate
from lockstep.metrics import aggregate_metrics as _aggregate_metrics
from lockstep.project_orchestrator import ProjectRunDisposition

_PROVIDER_CAUSES = (FailureCause.PROVIDER_PROCESS_FAILURE, FailureCause.USAGE_EXHAUSTION)


class EvalTrialOutcome(StrEnum):
    """The eval-layer classification of one trial (see the module docstring)."""

    PASS = "pass"
    TASK_FAILURE = "task_failure"
    GRADER_FAILURE = "grader_failure"
    HARNESS_FAILURE = "harness_failure"
    PROVIDER_FAILURE = "provider_failure"
    ENVIRONMENT_FAILURE = FailureCause.ENVIRONMENT_FAILURE.value
    UNAVAILABLE_MEASUREMENT = "unavailable_measurement"


class _Model(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


def classify_trial(
    *,
    harness_failure: str | None,
    disposition: ProjectRunDisposition | None,
    expected_disposition: ProjectRunDisposition,
    causes: Iterable[FailureCause],
    grades: Iterable[GradeResult],
    run_failure: str | None = None,
) -> tuple[EvalTrialOutcome, str | None]:
    """Classify one trial and name what decided it. Pure and deterministic.

    *harness_failure* is an eval-layer defect (a grader raised, ...). *run_failure* says
    the canonical run raised instead of returning a disposition; it is a harness failure
    unless the journal attributes the failed run to the environment or the provider.
    """
    if harness_failure is not None:
        return EvalTrialOutcome.HARNESS_FAILURE, harness_failure
    recorded = list(causes)
    hard = [g for g in grades if g.hard]
    if run_failure is not None or disposition is not expected_disposition:
        if FailureCause.ENVIRONMENT_FAILURE in recorded:
            return EvalTrialOutcome.ENVIRONMENT_FAILURE, FailureCause.ENVIRONMENT_FAILURE.value
        for cause in recorded:
            if cause in _PROVIDER_CAUSES:
                return EvalTrialOutcome.PROVIDER_FAILURE, cause.value
    if run_failure is not None:
        return EvalTrialOutcome.HARNESS_FAILURE, run_failure
    for g in hard:
        if g.outcome is GradeOutcome.FAIL:
            return EvalTrialOutcome.GRADER_FAILURE, g.grader_id
    if disposition is not expected_disposition:
        return EvalTrialOutcome.TASK_FAILURE, disposition.value if disposition else "none"
    for g in hard:
        if g.outcome is GradeOutcome.UNAVAILABLE:
            return EvalTrialOutcome.UNAVAILABLE_MEASUREMENT, g.grader_id
    return EvalTrialOutcome.PASS, None


class EvalTrialResult(_Model):
    """The structured record of one trial. Evidence, never authority.

    ``subphases`` are the accepted Phase-10 metrics of the trial's transactions, unchanged;
    ``metrics`` aggregates them with the accepted formula. ``evidence`` references are
    relative to the evaluation workspace. ``fixture_tree`` is the Git tree of the fixture
    commit (content identity); ``fixture_commit`` names that commit in the trial's own
    repository. ``delivered_instructions_sha256`` is the digest of the Implementer
    instructions the arm put on every transaction request of the trial.
    """

    identity: EvalTrialIdentity
    outcome: EvalTrialOutcome
    failure_detail: str | None = None
    fixture_commit: str | None = None
    fixture_tree: str | None = None
    delivered_instructions_sha256: str | None = None
    disposition: ProjectRunDisposition | None = None
    transaction_run_ids: tuple[RunId, ...] = ()
    contract_digests: tuple[str, ...] = ()
    implementer_blocked: bool = False
    grades: tuple[GradeResult, ...] = ()
    subphases: tuple[SubphaseMetrics, ...] = ()
    evidence: tuple[str, ...] = ()

    @property
    def trial_id(self) -> str:
        return self.identity.trial_id

    @property
    def hard_passed(self) -> bool:
        return self.outcome is EvalTrialOutcome.PASS

    @property
    def metrics(self) -> TransactionMetrics:
        return _aggregate_metrics(self.subphases)

    @property
    def first_pass(self) -> bool | None:
        """Every completed Sub-phase passed on its first attempt; ``None`` if none completed."""
        completed = [s for s in self.subphases if s.completed]
        if not completed:
            return None
        return all(s.first_pass for s in completed)

    @property
    def reworked(self) -> bool:
        return any(s.reworked for s in self.subphases)


def _trial_key(trial: EvalTrialResult) -> tuple[str, int, str]:
    identity = trial.identity
    return identity.case_id, identity.repeat_index, identity.arm_id


class EvalArmAggregate(_Model):
    """Deterministic counts over one arm's trials, plus the accepted metric aggregate."""

    arm_id: str
    trials: int
    outcomes: dict[EvalTrialOutcome, int]
    hard_passes: int
    hard_pass_rate: Ratio
    runs_completed: int
    blocked_runs: int
    first_pass_successes: Ratio
    rework_occurrences: int
    metrics: TransactionMetrics

    @property
    def qualified(self) -> bool:
        """Every trial of the arm passed every hard grader (the quality gate)."""
        return self.trials > 0 and self.hard_passes == self.trials


def _arm_aggregate(arm_id: str, trials: Sequence[EvalTrialResult]) -> EvalArmAggregate:
    ordered = sorted(trials, key=_trial_key)
    counted = Counter(t.outcome for t in ordered)
    passes = counted[EvalTrialOutcome.PASS]
    observable = [t for t in ordered if t.first_pass is not None]
    return EvalArmAggregate(
        arm_id=arm_id,
        trials=len(ordered),
        outcomes={outcome: counted[outcome] for outcome in EvalTrialOutcome},
        hard_passes=passes,
        hard_pass_rate=Ratio(numerator=passes, denominator=len(ordered)),
        runs_completed=sum(
            t.disposition is ProjectRunDisposition.PHASE_GATE_READY for t in ordered
        ),
        blocked_runs=sum(t.implementer_blocked for t in ordered),
        first_pass_successes=Ratio(
            numerator=sum(t.hard_passed and bool(t.first_pass) for t in observable),
            denominator=len(observable),
        ),
        rework_occurrences=sum(t.reworked for t in ordered),
        metrics=_aggregate_metrics(s for t in ordered for s in t.subphases),
    )


def _arm_aggregates(trials: Sequence[EvalTrialResult]) -> tuple[EvalArmAggregate, ...]:
    by_arm: dict[str, list[EvalTrialResult]] = {}
    for trial in trials:
        by_arm.setdefault(trial.identity.arm_id, []).append(trial)
    return tuple(_arm_aggregate(arm_id, by_arm[arm_id]) for arm_id in sorted(by_arm))


class EvalPair(_Model):
    """The trials of every arm that ran the same case and repetition."""

    case_id: str
    repeat_index: int
    trial_ids: dict[str, str]
    outcomes: dict[str, EvalTrialOutcome]
    same_fixture: bool
    same_contracts: bool

    @property
    def pair_id(self) -> str:
        return f"{self.case_id}/{self.repeat_index}"


class EvalCaseResult(_Model):
    case_id: str
    case_digest: str
    trials: tuple[EvalTrialResult, ...]
    arms: tuple[EvalArmAggregate, ...]
    pairs: tuple[EvalPair, ...]


class EvalSuiteResult(_Model):
    suite_id: str
    suite_digest: str
    cases: tuple[EvalCaseResult, ...]
    arms: tuple[EvalArmAggregate, ...]


def _require_unique(trials: Sequence[EvalTrialResult]) -> None:
    ids = [t.trial_id for t in trials]
    if len(set(ids)) != len(ids):
        raise ValueError("trial identities must be unique")


def _pairs(case_id: str, trials: Sequence[EvalTrialResult]) -> tuple[EvalPair, ...]:
    by_repeat: dict[int, list[EvalTrialResult]] = {}
    for trial in trials:
        by_repeat.setdefault(trial.identity.repeat_index, []).append(trial)
    pairs = []
    for repeat in sorted(by_repeat):
        members = sorted(by_repeat[repeat], key=_trial_key)
        trees = {t.fixture_tree for t in members}
        contracts = {t.contract_digests for t in members}
        pairs.append(
            EvalPair(
                case_id=case_id,
                repeat_index=repeat,
                trial_ids={t.identity.arm_id: t.trial_id for t in members},
                outcomes={t.identity.arm_id: t.outcome for t in members},
                same_fixture=len(trees) == 1 and None not in trees,
                same_contracts=len(contracts) == 1 and () not in contracts,
            )
        )
    return tuple(pairs)


def aggregate_case(trials: Iterable[EvalTrialResult]) -> EvalCaseResult:
    """Aggregate the trials of one case. Independent of input order."""
    ordered = sorted(trials, key=_trial_key)
    if not ordered:
        raise ValueError("a case result needs at least one trial")
    if len({(t.identity.case_id, t.identity.case_digest) for t in ordered}) != 1:
        raise ValueError("every trial of a case result must run the same case")
    _require_unique(ordered)
    first = ordered[0].identity
    return EvalCaseResult(
        case_id=first.case_id,
        case_digest=first.case_digest,
        trials=tuple(ordered),
        arms=_arm_aggregates(ordered),
        pairs=_pairs(first.case_id, ordered),
    )


def aggregate_suite(suite: EvalSuite, trials: Iterable[EvalTrialResult]) -> EvalSuiteResult:
    """Aggregate a suite's trials per case and per arm. Independent of input order."""
    ordered = sorted(trials, key=_trial_key)
    _require_unique(ordered)
    cases = {case.case_id: case.digest for case in suite.cases}
    arms = {arm.arm_id: arm.digest for arm in suite.arms}
    for trial in ordered:
        identity = trial.identity
        if (
            cases.get(identity.case_id) != identity.case_digest
            or arms.get(identity.arm_id) != identity.arm_digest
            or identity.repeat_index > suite.repeat_count
        ):
            raise ValueError(f"trial {trial.trial_id} does not belong to suite {suite.suite_id}")
    by_case: dict[str, list[EvalTrialResult]] = {}
    for trial in ordered:
        by_case.setdefault(trial.identity.case_id, []).append(trial)
    return EvalSuiteResult(
        suite_id=suite.suite_id,
        suite_digest=suite.digest,
        cases=tuple(aggregate_case(by_case[case_id]) for case_id in sorted(by_case)),
        arms=_arm_aggregates(ordered),
    )


Measure = Callable[[EvalArmAggregate], float | int | None]


def rank_arms(arms: Iterable[EvalArmAggregate], *, measure: Measure) -> tuple[str, ...]:
    """Order arms: the quality gate first, then *measure* ascending (unmeasured last).

    Arms that passed every hard grader on every trial come first; the rest follow by hard
    pass rate. Only within those groups does the comparative measure (lower is better)
    order arms; ties fall back to the arm id, so the order is deterministic.
    """

    def key(arm: EvalArmAggregate) -> tuple[bool, float, bool, float, str]:
        value = measure(arm)
        return (
            not arm.qualified,
            -(arm.hard_pass_rate.value or 0.0),
            value is None,
            float(value) if value is not None else 0.0,
            arm.arm_id,
        )

    return tuple(arm.arm_id for arm in sorted(arms, key=key))


def preferred_arm(arms: Iterable[EvalArmAggregate], *, measure: Measure) -> str | None:
    """The first-ranked arm, only if it passed the quality gate; otherwise ``None``."""
    candidates = list(arms)
    ranked = rank_arms(candidates, measure=measure)
    if not ranked:
        return None
    first = next(arm for arm in candidates if arm.arm_id == ranked[0])
    return first.arm_id if first.qualified else None


def complete_total(aggregate: UsageAggregate) -> int | None:
    """The total only when every expected item reported it; otherwise unavailable."""
    if aggregate.total_invocations == 0 or not aggregate.complete:
        return None
    return aggregate.known_total


__all__ = [
    "EvalArmAggregate",
    "EvalCaseResult",
    "EvalPair",
    "EvalSuiteResult",
    "EvalTrialOutcome",
    "EvalTrialResult",
    "Measure",
    "aggregate_case",
    "aggregate_suite",
    "classify_trial",
    "complete_total",
    "preferred_arm",
    "rank_arms",
]
