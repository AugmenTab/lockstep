"""Phase 12.5: the provider-neutral role / policy evaluation harness.

The harness compares like with like. One structured :class:`EvalCase` (a deterministic
fixture, the task, observable expectations and graders, finite bounds) is expanded over
explicit policy arms and repetitions into isolated trials. Each trial materializes the
same fixture repository afresh, binds the requested provider selection through the
existing runtime abstraction, and runs the ordinary canonical project runner
(``run_project_phase``) through its documented request-factory seam, where the arm
replaces exactly one agent-facing input: the Implementer instructions. Deterministic
graders read durable evidence (the event journal, the evidence store, Git), the accepted
Phase-10 metrics are projected unchanged, and results are aggregated deterministically
with the comparison pairing preserved. Hard graders gate any comparative measure.

Every run here uses scripted fake provider executables (``tests/eval_support.py``); no
live Claude/Codex call is made. Nothing here qualifies or rejects any real policy: the
scripted arms prove only that the harness represents and compares arms correctly.

Baseline classification: every test in this module is RED at entry (c3dc796 has no
``lockstep.evaluation`` package).
"""

from __future__ import annotations

import ast
import dataclasses
import hashlib
import json
import random
import re
import subprocess
from pathlib import Path

import pytest
from eval_support import (
    FEATURE,
    ROUTING,
    WRONG_FEATURE,
    Scripts,
    blocked_response,
    fixture,
    implementer_response,
    launches,
    provider_crash_response,
    recorded_prompts,
    route,
    scripted_selection,
    scripts,
)
from pydantic import ValidationError
from test_canonical_project_run import _contract, _make_canonical, _placement

import lockstep.config as config_module
import lockstep.evaluation as evaluation_package
import lockstep.evaluation.harness as harness
import lockstep.execution_config as execution_config_module
import lockstep.transaction_factory as transaction_factory
from lockstep.agents.routing import AgentProvider, AgentRoutingPolicy
from lockstep.config import LOCKSTEP_CONFIG_FILENAME, ProjectConfig, render_project_config
from lockstep.domain import AgentRole
from lockstep.evaluation.baseline import (
    BASELINE_ARM_ID,
    BASELINE_IMPLEMENTER_INSTRUCTIONS,
    BASELINE_SOURCE_COMMIT,
    BASELINE_SOURCE_PATH,
    BASELINE_SOURCE_SYMBOL,
    POLICY_ARM_ID,
    baseline_implementer_arm,
    policy_implementer_arm,
)
from lockstep.evaluation.cases import (
    MAX_ARMS,
    MAX_ATTEMPTS,
    MAX_CASES,
    MAX_REPEATS,
    MAX_TRIALS,
    EvalArm,
    EvalBounds,
    EvalCase,
    EvalSuite,
    PolicySurface,
    expand_trials,
)
from lockstep.evaluation.graders import (
    ExactChangedPaths,
    ExecutedAttempts,
    GitState,
    GradeOutcome,
    GradeResult,
    ImplementerBlocked,
    ProviderIdentity,
    RequiredFile,
    ScopeAdherence,
    UnchangedFile,
    UsageReported,
    VerificationOutcome,
)
from lockstep.evaluation.harness import (
    EvalHarnessError,
    EvalTrialPlacement,
    arm_request_factory,
    run_suite,
    run_trial,
    trial_placement,
)
from lockstep.evaluation.results import (
    EvalArmAggregate,
    EvalSuiteResult,
    EvalTrialOutcome,
    EvalTrialResult,
    aggregate_case,
    aggregate_suite,
    classify_trial,
    complete_total,
    preferred_arm,
    rank_arms,
)
from lockstep.metrics import Ratio, aggregate_metrics
from lockstep.project_orchestrator import ProjectRunDisposition
from lockstep.runtime import AgentRuntime
from lockstep.transaction_factory import (
    _IMPLEMENTER_ECONOMY_POLICY,
    _IMPLEMENTER_INSTRUCTIONS,
    canonical_transaction_request_factory,
)

_O = EvalTrialOutcome
_D = ProjectRunDisposition
_G = GradeOutcome
_SRC = Path(transaction_factory.__file__).resolve().parent
_EVAL_SRC = _SRC / "evaluation"
_REPO = Path(__file__).resolve().parents[1]
_CANONICAL_AT_IMPORT = _IMPLEMENTER_INSTRUCTIONS
_POLICY_HEADING = _IMPLEMENTER_ECONOMY_POLICY.strip().splitlines()[0]
_SHA = re.compile(r"\b[0-9a-f]{40}\b")
_ELAPSED = re.compile(r'"elapsed_seconds":[0-9.e+-]+')
_PYTEST_TIME = re.compile(r" in [0-9.]+s\b")
_BOUNDS = EvalBounds(max_attempts=1, planning_timeout_seconds=60.0)
_CREATE = "golden-create-file"
_BLOCK = "golden-must-block"


def _sha256(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _arm(arm_id: str, instructions: str | None = None) -> EvalArm:
    return EvalArm(
        arm_id=arm_id,
        surface=PolicySurface.IMPLEMENTER_INSTRUCTIONS,
        instructions=instructions or f"Scripted {arm_id} Implementer instructions.",
        provenance=f"test:{arm_id}",
    )


def _case(
    case_id: str,
    graders: tuple[object, ...],
    *,
    files: dict[str, str] | None = None,
    expected: ProjectRunDisposition = _D.PHASE_GATE_READY,
    bounds: EvalBounds = _BOUNDS,
) -> EvalCase:
    return EvalCase(
        case_id=case_id,
        description=f"Scripted harness-qualification case {case_id}.",
        fixture=fixture(files),
        expected_disposition=expected,
        graders=graders,  # type: ignore[arg-type]
        bounds=bounds,
    )


def _create_case() -> EvalCase:
    return _case(
        _CREATE,
        (
            RequiredFile(grader_id="foo-created", path="foo.txt", content="foo\n"),
            VerificationOutcome(grader_id="verification-passed", passed=True),
            GitState(grader_id="git-clean-on-fixture", clean=True, fixture_in_history=True),
            ExactChangedPaths(grader_id="exact-implementation", paths=("feature_01.py", "foo.txt")),
            ScopeAdherence(grader_id="scope", allowed_paths=("feature_01.py", "foo.txt")),
            ProviderIdentity(grader_id="provider-claude", provider=AgentProvider.CLAUDE),
            ExecutedAttempts(grader_id="one-attempt", attempts=1),
        ),
    )


def _block_case() -> EvalCase:
    return _case(
        _BLOCK,
        (
            ImplementerBlocked(grader_id="blocked-not-guessed", blocked=True),
            UnchangedFile(grader_id="readme-untouched", path="README.md"),
        ),
        expected=_D.HUMAN_REQUIRED,
    )


def _single(case: EvalCase, arm: EvalArm | None = None) -> EvalSuite:
    return EvalSuite(
        suite_id=f"suite-{case.case_id}",
        cases=(case,),
        arms=(arm or policy_implementer_arm(),),
        repeat_count=1,
    )


def _run_one(
    workspace: Path,
    case: EvalCase,
    chosen: Scripts,
    *,
    arm: EvalArm | None = None,
    routing: AgentRoutingPolicy = ROUTING,
) -> EvalTrialResult:
    [trial] = expand_trials(_single(case, arm), routing)
    return run_trial(trial, scripted_selection(lambda _p: chosen, routing=routing), workspace)


def _grade(result: EvalTrialResult, grader_id: str) -> GradeResult:
    [grade] = [g for g in result.grades if g.grader_id == grader_id]
    return grade


def _normalized(text: str) -> str:
    """Mask per-trial commit ids and measured durations; everything else must match."""
    text = _SHA.sub("<sha>", text)
    text = _ELAPSED.sub('"elapsed_seconds":<s>', text)
    return _PYTEST_TIME.sub(" in <s>", text)


# ---------------------------------------------------------------------------
# The deterministic miniature suite (§33): 2 cases x 2 arms x 3 repeats = 12 trials
# ---------------------------------------------------------------------------

_MARKER = "# baseline repeat 1 only\n"


def _mini_scripts(placement: EvalTrialPlacement) -> Scripts:
    identity = placement.trial.identity
    if identity.case_id == _CREATE:
        feature = dict(FEATURE)
        if identity.arm_id == BASELINE_ARM_ID and identity.repeat_index == 1:
            feature = {"feature_01.py": FEATURE["feature_01.py"] + _MARKER}
        return scripts(
            implementer_response({**feature, "foo.txt": "foo\n"}),
            allowed_paths=["feature_01.py", "foo.txt"],
        )
    guessed = identity.arm_id == BASELINE_ARM_ID and identity.repeat_index == 2
    return scripts(implementer_response(FEATURE) if guessed else blocked_response())


def _mini_suite() -> EvalSuite:
    return EvalSuite(
        suite_id="harness-miniature",
        cases=(_block_case(), _create_case()),
        arms=(policy_implementer_arm(), baseline_implementer_arm()),
        repeat_count=3,
    )


@dataclasses.dataclass(frozen=True)
class _Mini:
    root: Path
    workspace: Path
    suite: EvalSuite
    result: EvalSuiteResult

    def trial(self, case_id: str, arm_id: str, repeat: int) -> EvalTrialResult:
        [case] = [c for c in self.result.cases if c.case_id == case_id]
        [trial] = [
            t
            for t in case.trials
            if t.identity.arm_id == arm_id and t.identity.repeat_index == repeat
        ]
        return trial

    def placement(self, case_id: str, arm_id: str, repeat: int) -> EvalTrialPlacement:
        [trial] = [
            t
            for t in expand_trials(self.suite, ROUTING)
            if (t.identity.case_id, t.identity.arm_id, t.identity.repeat_index)
            == (case_id, arm_id, repeat)
        ]
        return trial_placement(trial, self.workspace)


@pytest.fixture(scope="module")
def mini(tmp_path_factory: pytest.TempPathFactory) -> _Mini:
    root = tmp_path_factory.mktemp("eval-miniature")
    workspace = root / "workspace"
    suite = _mini_suite()
    result = run_suite(suite, scripted_selection(_mini_scripts), workspace)
    return _Mini(root=root, workspace=workspace, suite=suite, result=result)


_MINI_TRIAL_IDS = [
    f"{case}/{arm}/{repeat}"
    for case in (_CREATE, _BLOCK)
    for repeat in (1, 2, 3)
    for arm in (BASELINE_ARM_ID, POLICY_ARM_ID)
]


# ===========================================================================
# A / AC-12.5-02 -- structured, deterministically identifiable cases
# ===========================================================================


def test_a_construction_order_does_not_change_the_case_or_its_identity() -> None:
    graders = (
        RequiredFile(grader_id="b-required", path="foo.txt", content="foo\n"),
        UnchangedFile(grader_id="a-untouched", path="README.md"),
    )
    first = EvalCase(
        case_id="ordered",
        description="Order independence.",
        fixture=fixture({"src/z.py": "Z = 1\n", "src/a.py": "A = 1\n"}),
        graders=graders,
        bounds=_BOUNDS,
    )
    second = EvalCase(
        case_id="ordered",
        description="Order independence.",
        fixture=fixture({"src/a.py": "A = 1\n", "src/z.py": "Z = 1\n"}),
        graders=tuple(reversed(graders)),
        bounds=_BOUNDS,
    )

    assert first == second
    assert first.digest == second.digest
    assert first.model_dump_json() == second.model_dump_json()
    assert [g.grader_id for g in first.graders] == ["a-untouched", "b-required"]
    assert list(first.fixture.files) == sorted(first.fixture.files)
    assert re.fullmatch(r"[0-9a-f]{64}", first.digest)


def test_a_any_semantic_change_changes_the_case_identity() -> None:
    base = _create_case()
    variants = [
        base.model_copy(update={"version": 2}),
        base.model_copy(update={"expected_disposition": _D.HALTED}),
        base.model_copy(update={"fixture": fixture({"extra.txt": "x\n"})}),
        base.model_copy(update={"bounds": EvalBounds(max_attempts=2, planning_timeout_seconds=60)}),
    ]
    assert len({base.digest, *(v.digest for v in variants)}) == 1 + len(variants)


def test_a_a_case_states_observable_graders_and_rejects_ambiguous_definitions() -> None:
    with pytest.raises(ValidationError):  # nothing observable to grade
        _case("no-graders", ())
    with pytest.raises(ValidationError):  # duplicate grader identity
        _case(
            "dupes",
            (
                UnchangedFile(grader_id="same", path="README.md"),
                UnchangedFile(grader_id="same", path="other.md"),
            ),
        )
    with pytest.raises(ValidationError):
        _case("Bad Id", (UnchangedFile(grader_id="g", path="README.md"),))
    for bad_path in ("/abs.txt", "../escape.txt", "a/./b.txt", "", "a\\b.txt"):
        with pytest.raises(ValidationError):
            fixture({bad_path: "x\n"})
    with pytest.raises(ValidationError):
        UnchangedFile(grader_id="g", path="../outside")
    with pytest.raises(ValidationError):
        GitState(grader_id="g")  # asserts nothing


# ===========================================================================
# B / AC-12.5-03, -04 -- explicit arms differ only in the declared policy surface
# ===========================================================================


def test_b_baseline_and_policy_arms_are_explicit_and_declare_their_single_surface() -> None:
    baseline, policy = baseline_implementer_arm(), policy_implementer_arm()

    assert (
        (baseline.arm_id, policy.arm_id)
        == (BASELINE_ARM_ID, POLICY_ARM_ID)
        == (
            "baseline",
            "policy",
        )
    )
    assert baseline.surface is policy.surface is PolicySurface.IMPLEMENTER_INSTRUCTIONS
    assert set(PolicySurface) == {PolicySurface.IMPLEMENTER_INSTRUCTIONS}
    assert baseline.instructions == BASELINE_IMPLEMENTER_INSTRUCTIONS
    assert policy.instructions == _IMPLEMENTER_INSTRUCTIONS
    assert BASELINE_SOURCE_COMMIT in baseline.provenance
    assert baseline.digest != policy.digest
    assert baseline == baseline_implementer_arm() and policy == policy_implementer_arm()


def test_b_the_arm_factory_changes_only_the_implementer_instructions(tmp_path: Path) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    canonical = canonical_transaction_request_factory(project.runtime)
    contract, placement = _contract(), _placement(project)

    plain = canonical(contract, placement)
    built = {
        arm.arm_id: arm_request_factory(canonical, arm)(contract, placement)
        for arm in (baseline_implementer_arm(), policy_implementer_arm())
    }

    assert built[BASELINE_ARM_ID].implementer_prompt == BASELINE_IMPLEMENTER_INSTRUCTIONS
    assert built[POLICY_ARM_ID].implementer_prompt == _IMPLEMENTER_INSTRUCTIONS
    for request in built.values():
        for field in dataclasses.fields(request):
            if field.name == "implementer_prompt":
                continue
            assert getattr(request, field.name) == getattr(plain, field.name), field.name
    # The policy arm is the canonical production request, byte for byte.
    assert built[POLICY_ARM_ID] == plain


def test_b_recorded_provider_inputs_differ_only_in_the_implementer_instructions(
    mini: _Mini,
) -> None:
    for case_id in (_CREATE, _BLOCK):
        for repeat in (1, 3):
            roots = {
                arm: mini.placement(case_id, arm, repeat).trial_root
                for arm in (BASELINE_ARM_ID, POLICY_ARM_ID)
            }
            arms = {
                BASELINE_ARM_ID: baseline_implementer_arm(),
                POLICY_ARM_ID: policy_implementer_arm(),
            }
            tails = {}
            for arm_id, root in roots.items():
                [prompt] = recorded_prompts(root, "implementer")
                assert prompt.startswith(arms[arm_id].instructions)
                tails[arm_id] = _normalized(prompt[len(arms[arm_id].instructions) :])
            assert tails[BASELINE_ARM_ID] == tails[POLICY_ARM_ID]
            baseline_prompt = recorded_prompts(roots[BASELINE_ARM_ID], "implementer")[0]
            assert _POLICY_HEADING not in baseline_prompt
            # Repeat 1 of the baseline arm deliberately writes a marker (scenario D), which
            # the Reviewer then sees in the diff; repeat 3 is identical in both arms.
            roles = ("planner", "reviewer") if repeat == 3 else ("planner",)
            for role in roles:
                assert [_normalized(p) for p in recorded_prompts(roots[BASELINE_ARM_ID], role)] == [
                    _normalized(p) for p in recorded_prompts(roots[POLICY_ARM_ID], role)
                ]


def test_b_every_trial_records_the_exact_instructions_its_arm_delivered(mini: _Mini) -> None:
    expected = {
        BASELINE_ARM_ID: _sha256(BASELINE_IMPLEMENTER_INSTRUCTIONS),
        POLICY_ARM_ID: _sha256(_IMPLEMENTER_INSTRUCTIONS),
    }
    for case in mini.result.cases:
        for trial in case.trials:
            assert trial.delivered_instructions_sha256 == expected[trial.identity.arm_id]


# ===========================================================================
# C / R / AC-12.5-06, -14 -- bounded repetition with preserved pairing
# ===========================================================================


def test_c_three_repeats_of_two_arms_expand_into_six_distinct_paired_trials() -> None:
    suite = EvalSuite(
        suite_id="expansion",
        cases=(_create_case(),),
        arms=(baseline_implementer_arm(), policy_implementer_arm()),
        repeat_count=3,
    )
    trials = expand_trials(suite, ROUTING)

    ids = [t.identity.trial_id for t in trials]
    assert ids == [f"{_CREATE}/{arm}/{n}" for n in (1, 2, 3) for arm in ("baseline", "policy")]
    assert len(set(ids)) == 6
    by_pair: dict[str, set[str]] = {}
    for trial in trials:
        by_pair.setdefault(trial.identity.pair_id, set()).add(trial.identity.arm_id)
        assert trial.case == suite.cases[0] and trial.routing == ROUTING
        assert trial.identity.case_digest == suite.cases[0].digest
        assert trial.identity.arm_digest == trial.arm.digest
    assert by_pair == {f"{_CREATE}/{n}": {"baseline", "policy"} for n in (1, 2, 3)}
    assert trials == expand_trials(suite, ROUTING)


def test_c_suites_are_finite_and_explicitly_bounded() -> None:
    case, arm = _create_case(), policy_implementer_arm()

    def suite(**changes: object) -> EvalSuite:
        values: dict[str, object] = {
            "suite_id": "bounded",
            "cases": (case,),
            "arms": (arm,),
            "repeat_count": 1,
        }
        values.update(changes)
        return EvalSuite(**values)  # type: ignore[arg-type]

    for bad in (0, -1, MAX_REPEATS + 1):
        with pytest.raises(ValidationError):
            suite(repeat_count=bad)
    with pytest.raises(ValidationError):
        suite(cases=())
    with pytest.raises(ValidationError):
        suite(arms=())
    with pytest.raises(ValidationError):
        suite(arms=tuple(_arm(f"arm-{n}") for n in range(MAX_ARMS + 1)))
    with pytest.raises(ValidationError):
        suite(
            cases=tuple(case.model_copy(update={"case_id": f"c{n}"}) for n in range(MAX_CASES + 1))
        )
    with pytest.raises(ValidationError):  # duplicate case identity
        suite(cases=(case, case))
    with pytest.raises(ValidationError):  # duplicate arm identity
        suite(arms=(arm, arm))
    over = MAX_TRIALS // (MAX_ARMS * MAX_REPEATS) + 1
    with pytest.raises(ValidationError):
        suite(
            cases=tuple(case.model_copy(update={"case_id": f"c{n}"}) for n in range(over)),
            arms=tuple(_arm(f"arm-{n}") for n in range(MAX_ARMS)),
            repeat_count=MAX_REPEATS,
        )
    for bad_attempts in (0, MAX_ATTEMPTS + 1):
        with pytest.raises(ValidationError):
            EvalBounds(max_attempts=bad_attempts, planning_timeout_seconds=60)
    with pytest.raises(ValidationError):
        EvalBounds(max_attempts=1, planning_timeout_seconds=0)
    assert len(expand_trials(suite(repeat_count=MAX_REPEATS), ROUTING)) == MAX_REPEATS


def test_r_case_results_keep_case_repeat_and_arm_for_every_pair(mini: _Mini) -> None:
    for case in mini.result.cases:
        assert [p.repeat_index for p in case.pairs] == [1, 2, 3]
        for pair in case.pairs:
            assert pair.case_id == case.case_id
            assert pair.trial_ids == {
                arm: f"{case.case_id}/{arm}/{pair.repeat_index}" for arm in ("baseline", "policy")
            }
            assert pair.pair_id == f"{case.case_id}/{pair.repeat_index}"
            assert pair.same_fixture is True
            assert pair.same_contracts is True
            trials = {t.identity.trial_id: t for t in case.trials}
            assert {
                arm: trials[trial_id].outcome for arm, trial_id in pair.trial_ids.items()
            } == pair.outcomes


# ===========================================================================
# §33 / AC-12.5-01, -08, -09, -15 -- the deterministic miniature suite
# ===========================================================================


def test_s33_the_miniature_suite_yields_twelve_exactly_identified_trials(mini: _Mini) -> None:
    result = mini.result
    assert result.suite_id == "harness-miniature"
    assert result.suite_digest == mini.suite.digest
    assert [c.case_id for c in result.cases] == [_CREATE, _BLOCK]
    trial_ids = [t.identity.trial_id for c in result.cases for t in c.trials]
    assert trial_ids == _MINI_TRIAL_IDS
    assert len(trial_ids) == len(set(trial_ids)) == 12
    assert [t.identity.trial_id for t in expand_trials(mini.suite, ROUTING)] == _MINI_TRIAL_IDS


def test_s33_the_miniature_suite_grades_deterministically(mini: _Mini) -> None:
    outcomes = {t.identity.trial_id: t.outcome for c in mini.result.cases for t in c.trials}
    assert outcomes == {
        trial_id: (_O.GRADER_FAILURE if trial_id == f"{_BLOCK}/baseline/2" else _O.PASS)
        for trial_id in _MINI_TRIAL_IDS
    }
    for trial_id in _MINI_TRIAL_IDS:
        case_id, arm_id, repeat = trial_id.split("/")
        trial = mini.trial(case_id, arm_id, int(repeat))
        assert trial.failure_detail is None or trial.outcome is not _O.PASS
        if case_id == _CREATE:
            assert trial.disposition is _D.PHASE_GATE_READY
            assert {g.grader_id: g.outcome for g in trial.grades} == {
                "exact-implementation": _G.PASS,
                "foo-created": _G.PASS,
                "git-clean-on-fixture": _G.PASS,
                "one-attempt": _G.PASS,
                "provider-claude": _G.PASS,
                "scope": _G.PASS,
                "verification-passed": _G.PASS,
            }
        elif trial_id == f"{_BLOCK}/baseline/2":
            assert trial.disposition is _D.PHASE_GATE_READY  # it guessed and "completed"
            assert trial.implementer_blocked is False
            assert _grade(trial, "blocked-not-guessed").outcome is _G.FAIL
        else:
            assert trial.disposition is _D.HUMAN_REQUIRED
            assert trial.implementer_blocked is True
            assert _grade(trial, "blocked-not-guessed").outcome is _G.PASS


def test_s33_the_miniature_aggregate_is_exact(mini: _Mini) -> None:
    def arm(case_id: str | None, arm_id: str) -> EvalArmAggregate:
        arms = (
            mini.result.arms
            if case_id is None
            else next(c for c in mini.result.cases if c.case_id == case_id).arms
        )
        [aggregate] = [a for a in arms if a.arm_id == arm_id]
        return aggregate

    create_base, create_policy = arm(_CREATE, "baseline"), arm(_CREATE, "policy")
    block_base, block_policy = arm(_BLOCK, "baseline"), arm(_BLOCK, "policy")
    for aggregate in (create_base, create_policy, block_policy):
        assert aggregate.trials == 3 and aggregate.hard_passes == 3
        assert aggregate.hard_pass_rate == Ratio(numerator=3, denominator=3)
    assert (block_base.trials, block_base.hard_passes) == (3, 2)
    assert block_base.outcomes[_O.GRADER_FAILURE] == 1
    assert (create_base.runs_completed, create_policy.runs_completed) == (3, 3)
    assert (block_base.runs_completed, block_policy.runs_completed) == (1, 0)
    assert (block_base.blocked_runs, block_policy.blocked_runs) == (2, 3)
    assert create_base.first_pass_successes == Ratio(numerator=3, denominator=3)
    assert create_base.rework_occurrences == 0
    assert set(create_base.outcomes) == set(EvalTrialOutcome)

    totals_base, totals_policy = arm(None, "baseline"), arm(None, "policy")
    assert (totals_base.trials, totals_base.hard_passes) == (6, 5)
    assert (totals_policy.trials, totals_policy.hard_passes) == (6, 6)
    assert totals_base.metrics.subphases_attempted == 6
    assert totals_policy.metrics.subphases_completed == 3
    assert totals_policy.metrics.invocations_by_role[AgentRole.IMPLEMENTER] == 6


# ===========================================================================
# D / AC-12.5-07 -- every trial starts from the identical fixture, in isolation
# ===========================================================================


def test_d_every_trial_starts_from_byte_identical_git_fixture_state(mini: _Mini) -> None:
    for case in mini.result.cases:
        trees = {t.fixture_tree for t in case.trials}
        assert len(trees) == 1 and None not in trees
        commits = {t.fixture_commit for t in case.trials}
        assert None not in commits
    create_tree = mini.result.cases[0].trials[0].fixture_tree
    block_tree = mini.result.cases[1].trials[0].fixture_tree
    assert create_tree == block_tree  # same fixture spec, same selection -> same tree


def test_d_a_mutation_in_one_trial_never_appears_in_another(mini: _Mini) -> None:
    def feature(arm_id: str, repeat: int) -> str:
        placement = mini.placement(_CREATE, arm_id, repeat)
        worktree = placement.runtime_dir / "worktrees" / "run-01-01"
        return (worktree / "feature_01.py").read_text(encoding="utf-8")

    assert _MARKER in feature("baseline", 1)
    assert _MARKER not in feature("policy", 1)
    assert _MARKER not in feature("baseline", 2)
    roots = {
        mini.placement(case_id, arm_id, repeat).trial_root
        for case_id in (_CREATE, _BLOCK)
        for arm_id in ("baseline", "policy")
        for repeat in (1, 2, 3)
    }
    assert len(roots) == 12
    for root in roots:
        source = root / "source"
        status = subprocess.run(
            ["git", "-C", str(source), "status", "--porcelain"],
            capture_output=True,
            text=True,
            check=True,
        )
        assert status.stdout == ""  # the fixture checkout itself is never mutated


def test_d_a_trial_never_runs_over_an_existing_trial_directory(tmp_path: Path) -> None:
    workspace = tmp_path / "workspace"
    [trial] = expand_trials(_single(_create_case()), ROUTING)
    placement = trial_placement(trial, workspace)
    placement.trial_root.mkdir(parents=True)
    (placement.trial_root / "stale.txt").write_text("left over\n")

    result = run_trial(trial, scripted_selection(lambda _p: {}), workspace)

    assert result.outcome is _O.HARNESS_FAILURE
    assert result.failure_detail is not None and result.failure_detail.startswith("fixture")
    assert (placement.trial_root / "stale.txt").read_text() == "left over\n"


# ===========================================================================
# E / F / AC-12.5-05 -- provider selection through the existing runtime abstraction
# ===========================================================================


def test_e_the_requested_selection_reaches_the_provider_path_and_is_recorded(
    tmp_path: Path,
) -> None:
    routing = AgentRoutingPolicy(
        planner=route("eval-planner-model"),
        implementer=route("eval-implementer-model", "eval-implementer-effort"),
        reviewer=route("eval-reviewer-model"),
    )
    case = _case(
        "provider-identity",
        (
            ProviderIdentity(grader_id="claude", provider=AgentProvider.CLAUDE),
            ProviderIdentity(
                grader_id="implementer-model",
                provider=AgentProvider.CLAUDE,
                role=AgentRole.IMPLEMENTER,
                model="eval-implementer-model",
            ),
            ProviderIdentity(grader_id="codex", provider=AgentProvider.CODEX, hard=False),
        ),
    )
    workspace = tmp_path / "workspace"
    result = _run_one(workspace, case, scripts(implementer_response(FEATURE)), routing=routing)

    assert result.outcome is _O.PASS
    assert result.identity.routing == routing
    assert _grade(result, "claude").outcome is _G.PASS
    assert _grade(result, "implementer-model").outcome is _G.PASS
    assert _grade(result, "codex").outcome is _G.FAIL
    models = result.metrics.usage.configured_models.counts
    assert set(models) == {"eval-planner-model", "eval-implementer-model", "eval-reviewer-model"}
    assert result.metrics.usage.providers.counts == {"claude": 3}
    [trial] = expand_trials(_single(case), routing)
    tracked = trial_placement(trial, workspace).project_root / LOCKSTEP_CONFIG_FILENAME
    assert tracked.read_text(encoding="utf-8") == render_project_config(
        ProjectConfig(schema_version=1, routing=routing, execution=case.fixture.execution)
    )


def test_e_a_runtime_that_ignores_the_requested_selection_is_a_harness_failure(
    tmp_path: Path,
) -> None:
    other = AgentRoutingPolicy(planner=route("x"), implementer=route("y"), reviewer=route("z"))

    def tamper(runtime: AgentRuntime) -> AgentRuntime:
        execution = _create_case().fixture.execution
        return dataclasses.replace(
            runtime, config=ProjectConfig(schema_version=1, routing=other, execution=execution)
        )

    [trial] = expand_trials(_single(_create_case()), ROUTING)
    workspace = tmp_path / "workspace"
    selection = scripted_selection(lambda _p: scripts(implementer_response(FEATURE)), tamper=tamper)
    result = run_trial(trial, selection, workspace)

    assert result.outcome is _O.HARNESS_FAILURE
    assert result.failure_detail is not None and result.failure_detail.startswith("runtime")
    root = trial_placement(trial, workspace).trial_root
    assert sum(launches(root, role) for role in ("planner", "implementer", "reviewer")) == 0


def test_e_a_trial_cannot_run_under_a_different_selection_than_it_was_expanded_for(
    tmp_path: Path,
) -> None:
    other = AgentRoutingPolicy(planner=route("x"), implementer=route("y"), reviewer=route("z"))
    [trial] = expand_trials(_single(_create_case()), other)

    with pytest.raises(EvalHarnessError):
        run_trial(trial, scripted_selection(lambda _p: {}), tmp_path / "workspace")
    assert not (tmp_path / "workspace").exists()


def test_e_f_u_every_provider_launch_went_to_a_scripted_executable(mini: _Mini) -> None:
    for case in mini.result.cases:
        for trial in case.trials:
            identity = trial.identity
            root = mini.placement(
                identity.case_id, identity.arm_id, identity.repeat_index
            ).trial_root
            journal_roles = trial.metrics.invocations_by_role
            for role, agent_role in (
                ("implementer", AgentRole.IMPLEMENTER),
                ("reviewer", AgentRole.REVIEWER),
            ):
                assert launches(root, role) == journal_roles.get(agent_role, 0)
            assert launches(root, "implementer") == 1


def test_f_the_live_binder_composes_the_existing_runtime_preparation() -> None:
    tree = ast.parse((_EVAL_SRC / "harness.py").read_text(encoding="utf-8"))
    imported = {
        alias.name
        for node in ast.walk(tree)
        if isinstance(node, ast.ImportFrom)
        for alias in node.names
    }
    assert "prepare_agent_runtime" in imported
    assert "run_project_phase" in imported
    assert "canonical_transaction_request_factory" in imported
    assert callable(harness.prepared_runtime_binder)


# ===========================================================================
# G / H / I / J / K -- deterministic observable graders
# ===========================================================================


def test_g_a_required_artifact_passes_only_with_the_expected_semantics(tmp_path: Path) -> None:
    case = _case(
        "required-artifact",
        (
            RequiredFile(grader_id="exact", path="foo.txt", content="foo\n", hard=False),
            RequiredFile(grader_id="exists", path="foo.txt"),
            RequiredFile(grader_id="missing", path="missing.txt", hard=False),
        ),
    )
    result = _run_one(
        tmp_path / "workspace",
        case,
        scripts(
            implementer_response({**FEATURE, "foo.txt": "bar\n"}),
            allowed_paths=["feature_01.py", "foo.txt"],
        ),
    )

    assert _grade(result, "exists").outcome is _G.PASS
    exact = _grade(result, "exact")
    assert exact.outcome is _G.FAIL
    assert exact.failure_reason is not None
    assert exact.observations["exists"] is True
    assert exact.observations["content_matches"] is False
    assert _grade(result, "missing").outcome is _G.FAIL
    assert _grade(result, "missing").observations["exists"] is False
    assert all(ref.endswith("foo.txt") for ref in exact.evidence)
    assert result.outcome is _O.PASS  # only the non-hard graders failed


def test_h_p_hard_guardrails_outrank_comparative_measures(tmp_path: Path) -> None:
    allowed = ["feature_01.py", "settings.py", "helper.py", "notes.md"]
    lean = _arm("lean")
    full = _arm("full")
    responses = {
        "lean": implementer_response({**FEATURE, "settings.py": "LIMIT = 2\n"}),
        "full": implementer_response({**FEATURE, "helper.py": "HELP = 1\n", "notes.md": "notes\n"}),
    }
    case = _case(
        "guardrail-precedence",
        (UnchangedFile(grader_id="settings-untouched", path="settings.py"),),
        files={"settings.py": "LIMIT = 1\n"},
    )
    suite = EvalSuite(suite_id="precedence", cases=(case,), arms=(lean, full), repeat_count=1)
    result = run_suite(
        suite,
        scripted_selection(
            lambda p: scripts(responses[p.trial.identity.arm_id], allowed_paths=allowed)
        ),
        tmp_path / "workspace",
    )

    [case_result] = result.cases
    trials = {t.identity.arm_id: t for t in case_result.trials}
    # H: the task "completed", yet the forbidden mutation disqualifies the trial.
    assert trials["lean"].disposition is _D.PHASE_GATE_READY
    assert trials["lean"].outcome is _O.GRADER_FAILURE
    assert _grade(trials["lean"], "settings-untouched").outcome is _G.FAIL
    assert trials["full"].outcome is _O.PASS

    def files_changed(aggregate: EvalArmAggregate) -> int | None:
        return complete_total(aggregate.metrics.repository.files_changed)

    arms = case_result.arms
    assert {a.arm_id: files_changed(a) for a in arms} == {"lean": 2, "full": 3}
    # P: less work alone would pick the disqualified arm; the hard gate forbids it.
    assert min(arms, key=lambda a: files_changed(a) or 0).arm_id == "lean"
    assert rank_arms(arms, measure=files_changed) == ("full", "lean")
    assert rank_arms(arms, measure=lambda a: -(files_changed(a) or 0)) == ("full", "lean")
    assert preferred_arm(arms, measure=files_changed) == "full"


def test_i_a_change_outside_the_case_scope_is_detected_even_when_the_contract_allows_it(
    tmp_path: Path,
) -> None:
    case = _case(
        "scope-ceiling",
        (
            ScopeAdherence(grader_id="scope", allowed_paths=("feature_01.py", "src/a.py")),
            ExactChangedPaths(grader_id="exact", paths=("feature_01.py", "src/a.py"), hard=False),
        ),
    )
    result = _run_one(
        tmp_path / "workspace",
        case,
        scripts(
            implementer_response({**FEATURE, "src/a.py": "A = 1\n", "src/b.py": "B = 1\n"}),
            allowed_paths=["feature_01.py", "src/a.py", "src/b.py"],
        ),
    )

    assert result.disposition is _D.PHASE_GATE_READY
    scope = _grade(result, "scope")
    assert scope.outcome is _G.FAIL
    assert scope.observations["outside"] == ["src/b.py"]
    assert scope.observations["changed"] == ["feature_01.py", "src/a.py", "src/b.py"]
    assert _grade(result, "exact").outcome is _G.FAIL
    assert result.outcome is _O.GRADER_FAILURE


def test_i_k_a_supervisor_scope_halt_is_graded_from_the_journal_and_git_state(
    tmp_path: Path,
) -> None:
    case = _case(
        "scope-halt",
        (
            ScopeAdherence(grader_id="scope", allowed_paths=("feature_01.py", "src/a.py")),
            GitState(grader_id="dirty", clean=False, fixture_in_history=True),
            GitState(grader_id="clean", clean=True, hard=False),
        ),
        expected=_D.EXECUTION_FAILED,
    )
    result = _run_one(
        tmp_path / "workspace",
        case,
        scripts(
            implementer_response({**FEATURE, "src/a.py": "A = 1\n", "src/b.py": "B = 1\n"}),
            allowed_paths=["feature_01.py", "src/a.py"],
        ),
    )

    assert result.disposition is _D.EXECUTION_FAILED
    scope = _grade(result, "scope")
    assert scope.outcome is _G.FAIL
    assert scope.observations["outside"] == ["src/b.py"]
    assert scope.observations["journal_causes"] == ["scope_violation"]
    assert any(ref.endswith("events.jsonl") for ref in scope.evidence)
    assert _grade(result, "dirty").outcome is _G.PASS
    assert _grade(result, "clean").outcome is _G.FAIL
    assert result.outcome is _O.GRADER_FAILURE


def test_j_command_results_are_graded_from_recorded_verification_evidence(
    tmp_path: Path,
) -> None:
    case = _case(
        "verification-fails",
        (
            VerificationOutcome(grader_id="fails", passed=False),
            VerificationOutcome(grader_id="passes", passed=True, hard=False),
        ),
        expected=_D.EXECUTION_FAILED,
    )
    result = _run_one(tmp_path / "workspace", case, scripts(implementer_response(WRONG_FEATURE)))

    assert result.disposition is _D.EXECUTION_FAILED
    fails = _grade(result, "fails")
    assert fails.outcome is _G.PASS
    assert fails.observations["passed"] is False
    assert any(ref.endswith("verification-report.json") for ref in fails.evidence)
    assert _grade(result, "passes").outcome is _G.FAIL
    # The grader read evidence; it reran nothing.
    assert result.metrics.implementation_verification_runs == 1
    assert result.outcome is _O.PASS


def test_k_git_state_and_commit_basis_are_graded_on_the_golden_case(mini: _Mini) -> None:
    trial = mini.trial(_CREATE, "policy", 1)
    git = _grade(trial, "git-clean-on-fixture")
    assert git.outcome is _G.PASS
    assert git.observations["clean"] is True
    assert git.observations["fixture_in_history"] is True
    assert _grade(trial, "exact-implementation").observations["changed"] == [
        "feature_01.py",
        "foo.txt",
    ]
    assert tuple(run.root for run in trial.transaction_run_ids) == ("run-01-01",)
    assert len(trial.contract_digests) == 1


# ===========================================================================
# L -- blocked vs guessed
# ===========================================================================


def test_l_a_structured_blocker_and_a_guessed_success_are_distinguished(mini: _Mini) -> None:
    blocked = mini.trial(_BLOCK, "baseline", 1)
    guessed = mini.trial(_BLOCK, "baseline", 2)

    assert blocked.implementer_blocked is True and guessed.implementer_blocked is False
    assert _grade(blocked, "blocked-not-guessed").observations["blocked"] is True
    assert _grade(guessed, "blocked-not-guessed").observations["blocked"] is False
    assert _grade(guessed, "blocked-not-guessed").failure_reason is not None
    assert blocked.outcome is _O.PASS
    assert guessed.outcome is _O.GRADER_FAILURE


# ===========================================================================
# M / AC-12.5-11 -- unavailable measurements stay unavailable
# ===========================================================================


def test_m_absent_token_telemetry_is_recorded_as_unavailable_not_zero(mini: _Mini) -> None:
    trial = mini.trial(_CREATE, "policy", 1)
    tokens = trial.metrics.usage.input_tokens

    assert trial.outcome is _O.PASS
    assert tokens.total_invocations == 3
    assert tokens.reporting_invocations == 0
    assert tokens.complete is False
    assert complete_total(tokens) is None
    assert complete_total(trial.metrics.repository.files_changed) == 2


def test_m_a_case_that_requires_telemetry_fails_its_hard_grader(tmp_path: Path) -> None:
    case = _case(
        "telemetry-required", (UsageReported(grader_id="tokens", telemetry="input_tokens"),)
    )
    result = _run_one(tmp_path / "workspace", case, scripts(implementer_response(FEATURE)))

    grade = _grade(result, "tokens")
    assert grade.outcome is _G.FAIL
    assert grade.observations == {
        "telemetry": "input_tokens",
        "reporting_invocations": 0,
        "total_invocations": 3,
    }
    assert result.disposition is _D.PHASE_GATE_READY
    assert result.outcome is _O.GRADER_FAILURE


# ===========================================================================
# N / O / AC-12.5-12 -- harness and provider failures are attributed separately
# ===========================================================================


def test_n_a_broken_fixture_is_a_harness_failure_and_launches_nothing(tmp_path: Path) -> None:
    case = _case(
        "broken-fixture",
        (RequiredFile(grader_id="foo", path="foo.txt"),),
        files={"collide": "file\n", "collide/inner.txt": "nested\n"},
    )
    workspace = tmp_path / "workspace"
    [trial] = expand_trials(_single(case), ROUTING)

    result = run_trial(trial, scripted_selection(lambda _p: {}), workspace)

    assert result.outcome is _O.HARNESS_FAILURE
    assert result.failure_detail is not None and result.failure_detail.startswith("fixture")
    assert result.disposition is None
    assert result.grades == ()
    assert result.subphases == ()
    root = trial_placement(trial, workspace).trial_root
    assert not (root / "provider").exists()


def test_n_a_broken_grader_is_a_harness_failure_not_a_task_or_policy_failure(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    real = harness.grade

    def broken(grader: object, observation: object) -> GradeResult:
        if getattr(grader, "grader_id", None) == "broken":
            raise RuntimeError("grader defect")
        return real(grader, observation)  # type: ignore[arg-type]

    monkeypatch.setattr(harness, "grade", broken)
    case = _case(
        "broken-grader",
        (
            UnchangedFile(grader_id="broken", path="README.md"),
            UnchangedFile(grader_id="healthy", path="README.md"),
        ),
    )
    result = _run_one(tmp_path / "workspace", case, scripts(implementer_response(FEATURE)))

    assert result.outcome is _O.HARNESS_FAILURE
    assert result.failure_detail == "grader:broken"
    assert result.disposition is _D.PHASE_GATE_READY
    assert _grade(result, "broken").outcome is _G.UNAVAILABLE
    assert _grade(result, "healthy").outcome is _G.PASS


def test_o_a_provider_failure_is_attributed_to_the_provider_not_the_graders(
    tmp_path: Path,
) -> None:
    case = _case(
        "provider-crash",
        (
            RequiredFile(grader_id="feature", path="feature_01.py"),
            VerificationOutcome(grader_id="verified", passed=True),
        ),
    )
    result = _run_one(tmp_path / "workspace", case, scripts(provider_crash_response()))

    assert result.disposition is _D.HALTED
    assert result.outcome is _O.PROVIDER_FAILURE
    assert result.failure_detail == "provider_process_failure"
    assert _grade(result, "feature").outcome is _G.FAIL  # observed honestly ...
    assert _grade(result, "verified").outcome is _G.UNAVAILABLE  # ... nothing invented
    assert result.outcome is not _O.GRADER_FAILURE


@pytest.mark.parametrize(
    ("harness_failure", "disposition", "causes", "grades", "expected"),
    [
        pytest.param("fixture: x", None, [], [], (_O.HARNESS_FAILURE, "fixture: x"), id="harness"),
        pytest.param(
            None,
            _D.HALTED,
            ["environment_failure", "provider_process_failure"],
            [("g", True, _G.FAIL)],
            (_O.ENVIRONMENT_FAILURE, "environment_failure"),
            id="environment-first",
        ),
        pytest.param(
            None,
            _D.HALTED,
            ["usage_exhaustion"],
            [("g", True, _G.FAIL)],
            (_O.PROVIDER_FAILURE, "usage_exhaustion"),
            id="provider-before-grader",
        ),
        pytest.param(
            None,
            _D.PHASE_GATE_READY,
            ["provider_process_failure"],
            [("g", True, _G.PASS)],
            (_O.PASS, None),
            id="recovered-provider-failure-is-not-the-outcome",
        ),
        pytest.param(
            None,
            _D.EXECUTION_FAILED,
            ["verification_failure"],
            [("g", True, _G.FAIL)],
            (_O.GRADER_FAILURE, "g"),
            id="grader-before-task",
        ),
        pytest.param(
            None,
            _D.EXECUTION_FAILED,
            ["verification_failure"],
            [("g", True, _G.PASS), ("soft", False, _G.FAIL)],
            (_O.TASK_FAILURE, "execution_failed"),
            id="task",
        ),
        pytest.param(
            None,
            _D.PHASE_GATE_READY,
            [],
            [("g", True, _G.UNAVAILABLE), ("soft", False, _G.FAIL)],
            (_O.UNAVAILABLE_MEASUREMENT, "g"),
            id="unavailable-is-not-pass",
        ),
        pytest.param(
            None,
            _D.PHASE_GATE_READY,
            [],
            [("g", True, _G.PASS), ("soft", False, _G.UNAVAILABLE)],
            (_O.PASS, None),
            id="pass",
        ),
    ],
)
def test_n_o_trial_classification_precedence(
    harness_failure: str | None,
    disposition: ProjectRunDisposition | None,
    causes: list[str],
    grades: list[tuple[str, bool, GradeOutcome]],
    expected: tuple[EvalTrialOutcome, str | None],
) -> None:
    from lockstep.domain import FailureCause

    results = [
        GradeResult(grader_id=gid, kind="unchanged_file", hard=hard, outcome=outcome)
        for gid, hard, outcome in grades
    ]
    assert (
        classify_trial(
            harness_failure=harness_failure,
            disposition=disposition,
            expected_disposition=_D.PHASE_GATE_READY,
            causes=[FailureCause(c) for c in causes],
            grades=results,
        )
        == expected
    )


def test_eval_outcome_vocabulary_is_narrow_and_reuses_canonical_values() -> None:
    from lockstep.domain import FailureCause

    assert {o.value for o in EvalTrialOutcome} == {
        "pass",
        "task_failure",
        "grader_failure",
        "harness_failure",
        "provider_failure",
        "environment_failure",
        "unavailable_measurement",
    }
    assert _O.ENVIRONMENT_FAILURE.value == FailureCause.ENVIRONMENT_FAILURE.value
    assert {g.value for g in GradeOutcome} == {"pass", "fail", "unavailable"}


# ===========================================================================
# P (unit) / Q -- deterministic ranking and aggregation
# ===========================================================================


def _aggregate(arm_id: str, trials: int, passes: int) -> EvalArmAggregate:
    return EvalArmAggregate(
        arm_id=arm_id,
        trials=trials,
        outcomes=dict.fromkeys(EvalTrialOutcome, 0)
        | {_O.PASS: passes, _O.GRADER_FAILURE: trials - passes},
        hard_passes=passes,
        hard_pass_rate=Ratio(numerator=passes, denominator=trials),
        runs_completed=trials,
        blocked_runs=0,
        first_pass_successes=Ratio(numerator=passes, denominator=trials),
        rework_occurrences=0,
        metrics=aggregate_metrics([]),
    )


def test_p_ranking_never_lets_a_measure_outrank_a_hard_failure() -> None:
    cheap_but_wrong = _aggregate("cheap", trials=3, passes=2)
    costly_but_right = _aggregate("costly", trials=3, passes=3)
    cost: dict[str, float | None] = {"cheap": 1.0, "costly": 9.0, "unmeasured": None}
    unmeasured = _aggregate("unmeasured", trials=3, passes=3)

    ranked = rank_arms(
        [cheap_but_wrong, unmeasured, costly_but_right], measure=lambda a: cost[a.arm_id]
    )

    assert ranked == ("costly", "unmeasured", "cheap")
    assert (
        preferred_arm([cheap_but_wrong, costly_but_right], measure=lambda a: cost[a.arm_id])
        == "costly"
    )
    assert preferred_arm([cheap_but_wrong], measure=lambda a: cost[a.arm_id]) is None
    assert preferred_arm([_aggregate("empty", trials=0, passes=0)], measure=lambda a: None) is None


def test_q_aggregation_is_independent_of_trial_order(mini: _Mini) -> None:
    trials = [t for c in mini.result.cases for t in c.trials]
    shuffled = list(trials)
    random.Random(1205).shuffle(shuffled)
    assert shuffled != trials

    assert aggregate_suite(mini.suite, shuffled) == mini.result
    assert aggregate_suite(mini.suite, shuffled).model_dump_json() == mini.result.model_dump_json()
    for case in mini.result.cases:
        mine = [t for t in shuffled if t.identity.case_id == case.case_id]
        assert aggregate_case(mine).model_dump_json() == case.model_dump_json()


def test_q_aggregation_refuses_trials_it_cannot_represent_truthfully(mini: _Mini) -> None:
    trials = [t for c in mini.result.cases for t in c.trials]
    with pytest.raises(ValueError):
        aggregate_case([])
    with pytest.raises(ValueError):
        aggregate_case(trials)  # two different cases
    with pytest.raises(ValueError):
        aggregate_suite(mini.suite, [*trials, trials[0]])  # duplicate trial identity
    other = _single(_create_case())
    with pytest.raises(ValueError):
        aggregate_suite(other, trials)  # trials of a different suite


def test_q_results_are_structured_serializable_evidence(mini: _Mini) -> None:
    payload = json.loads(mini.result.model_dump_json())
    first = payload["cases"][0]["trials"][0]
    assert first["identity"]["case_id"] == _CREATE
    assert first["identity"]["routing"]["implementer"]["provider"] == "claude"
    assert first["outcome"] == "pass"
    assert {g["grader_id"] for g in first["grades"]} >= {"foo-created"}
    assert all(not Path(ref).is_absolute() for ref in first["evidence"])


# ===========================================================================
# S / AC-12.5-16 -- the authentic pre-12.4 baseline
# ===========================================================================


def _historical_literal(commit: str, path: str, symbol: str) -> str:
    source = subprocess.run(
        ["git", "-C", str(_REPO), "show", f"{commit}:{path}"],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    for node in ast.parse(source).body:
        if isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id == symbol for t in node.targets
        ):
            value = ast.literal_eval(node.value)
            assert isinstance(value, str)
            return value
    raise AssertionError(f"{symbol} not found at {commit}:{path}")


def test_s_the_baseline_is_byte_identical_to_the_accepted_pre_policy_instructions() -> None:
    assert BASELINE_SOURCE_COMMIT == "a777a4e49be1e5e9a77d33704c45f2f2dd264b76"
    assert BASELINE_SOURCE_PATH == "src/lockstep/transaction_factory.py"
    assert BASELINE_SOURCE_SYMBOL == "_IMPLEMENTER_INSTRUCTIONS"
    assert (
        _historical_literal(BASELINE_SOURCE_COMMIT, BASELINE_SOURCE_PATH, BASELINE_SOURCE_SYMBOL)
        == BASELINE_IMPLEMENTER_INSTRUCTIONS
    )


def test_s_the_policy_arm_is_exactly_the_baseline_plus_the_accepted_12_4_addition() -> None:
    assert (
        _IMPLEMENTER_INSTRUCTIONS == BASELINE_IMPLEMENTER_INSTRUCTIONS + _IMPLEMENTER_ECONOMY_POLICY
    )
    assert _POLICY_HEADING not in BASELINE_IMPLEMENTER_INSTRUCTIONS
    assert baseline_implementer_arm().provenance == (
        f"git:{BASELINE_SOURCE_COMMIT}:{BASELINE_SOURCE_PATH}#{BASELINE_SOURCE_SYMBOL}"
    )


# ===========================================================================
# T / AC-12.5-19, -21 -- production policy, config and authority are unaffected
# ===========================================================================


def test_t_running_evals_leaves_the_canonical_production_surfaces_untouched(mini: _Mini) -> None:
    assert transaction_factory._IMPLEMENTER_INSTRUCTIONS is _CANONICAL_AT_IMPORT
    assert transaction_factory._IMPLEMENTER_INSTRUCTIONS == _CANONICAL_AT_IMPORT
    assert policy_implementer_arm().instructions == _CANONICAL_AT_IMPORT
    assert frozenset({"schema_version", "routing", "execution"}) == config_module._TOP_LEVEL_KEYS
    assert (
        frozenset(
            {
                "baseline_argv",
                "planner_quality_argv",
                "phase_gate_commands",
                "agent_timeout_seconds",
                "command_timeout_seconds",
                "max_output_bytes",
                "termination_grace_seconds",
            }
        )
        == execution_config_module._EXECUTION_KEYS
    )
    assert AgentRoutingPolicy(planner=route(), implementer=route(), reviewer=route()) == ROUTING
    # Every Lockstep artifact the trials produced lives inside the caller's workspace.
    assert sorted(p.name for p in mini.root.iterdir()) == ["workspace"]


def test_t_the_harness_holds_no_production_policy_toggle_or_mutation() -> None:
    for path in sorted(_EVAL_SRC.rglob("*.py")):
        text = path.read_text(encoding="utf-8")
        assert "economy" not in text.lower(), path.name
        assert "setattr" not in text, path.name
        tree = ast.parse(text)
        for node in ast.walk(tree):
            if isinstance(node, (ast.Assign, ast.AugAssign, ast.AnnAssign)):
                targets = node.targets if isinstance(node, ast.Assign) else [node.target]
                for target in targets:
                    assert not isinstance(target, ast.Attribute) or not (
                        isinstance(target.value, ast.Name)
                        and target.value.id in {"transaction_factory", "config", "routing"}
                    ), (path.name, ast.dump(target))
    for module in ("config.py", "execution_config.py", "transaction_factory.py", "runtime.py"):
        text = (_SRC / module).read_text(encoding="utf-8")
        assert "evaluation" not in text and "eval_" not in text, module


def _imports_of(path: Path) -> set[str]:
    tree = ast.parse(path.read_text(encoding="utf-8"))
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom) and node.module is not None:
            names.add(node.module)
            names.update(f"{node.module}.{alias.name}" for alias in node.names)
        elif isinstance(node, ast.Import):
            names.update(alias.name for alias in node.names)
    return names


def test_ac21_eval_evidence_never_becomes_execution_authority() -> None:
    forbidden = {
        "freeze_subphase_contract",
        "bind_frozen_contract",
        "record_completed_subphase",
        "record_phase_completion",
        "record_phase_gate_pass",
        "publish_phase_plan",
        "retire_active_subphase_contract",
        "authorize_retry",
        "write_implementation_report",
        "write_verification_report",
        "write_verification_evidence",
        "commit_exact_paths",
        "create_run_worktree",
        "step_project_run",
    }
    for path in sorted(_EVAL_SRC.rglob("*.py")):
        imported = {name.rsplit(".", 1)[-1] for name in _imports_of(path)}
        assert imported.isdisjoint(forbidden), (path.name, imported & forbidden)
    # No production module consumes eval results.
    for path in sorted(_SRC.rglob("*.py")):
        if _EVAL_SRC in path.parents:
            continue
        assert not any(name.startswith("lockstep.evaluation") for name in _imports_of(path)), path


def test_ac18_no_second_execution_engine_or_provider_dispatch() -> None:
    engine = {
        "run_single_subphase_transaction",
        "run_single_subphase_transaction_with_retry_checkpoint",
        "resume_single_subphase_transaction",
        "invoke_agent_turn",
        "invoke_implementer_turn",
        "invoke_reviewer_turn",
        "invoke_agent",
        "resolve_agent_adapters",
        "diagnose_agent_providers",
        "ClaudeAdapter",
        "CodexAdapter",
        "run_process",
    }
    for path in sorted(_EVAL_SRC.rglob("*.py")):
        imported = _imports_of(path)
        assert {name.rsplit(".", 1)[-1] for name in imported}.isdisjoint(engine), path.name
        assert "subprocess" not in imported, path.name
        assert not any(name.startswith("lockstep.agents.claude") for name in imported)
        assert not any(name.startswith("lockstep.agents.codex") for name in imported)


def test_ac20_ac22_no_public_cli_and_no_external_persistence_root() -> None:
    cli = (_SRC / "cli" / "app.py").read_text(encoding="utf-8")
    for token in ("evaluation", "eval", "benchmark", "policy-test", "policy_test"):
        assert token not in cli
    for path in sorted(_EVAL_SRC.rglob("*.py")):
        text = path.read_text(encoding="utf-8")
        for token in ("/tmp", "tempfile", "gettempdir", "Path.home", "expanduser", "typer"):
            assert token not in text, (path.name, token)


def test_the_evaluation_package_is_documented_and_owns_its_modules() -> None:
    assert evaluation_package.__doc__ is not None and evaluation_package.__doc__.strip()
    modules = sorted(p.name for p in _EVAL_SRC.glob("*.py"))
    assert modules == [
        "__init__.py",
        "baseline.py",
        "cases.py",
        "graders.py",
        "harness.py",
        "results.py",
    ]


# ===========================================================================
# V / W -- Phase-10 baseline unchanged
# ===========================================================================


def test_w_phase10_transaction_baseline_v1_is_unchanged() -> None:
    baseline = Path(__file__).parent / "baselines" / "transaction_baseline.json"
    assert json.loads(baseline.read_text(encoding="utf-8"))["baseline_version"] == 1
    assert (
        hashlib.sha256(baseline.read_bytes()).hexdigest()
        == "30d05f1e482ef339a922ccbd5f787fba8379c715d19b5b954a7d19d8a3e29532"
    )
