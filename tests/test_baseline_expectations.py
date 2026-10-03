"""11.7-R2: expectation-aware Planner authoring scope and per-specification baseline.

Gate Attempt 2 showed a Contract with one RED and one GREEN_REGRESSION target. The
Planner correctly changed only the RED file and the host aborted ``test_scope`` because it
required *every* Contract test path to be dirty. Investigating exposed a larger defect:
the baseline stage ran one aggregate command over all Contract paths and read its single
exit code as "RED confirmed", so an unexpectedly failing GREEN file was hidden by an
intended RED failure.

R2 pins the accepted PRD semantics:

    RED                      Planner creates/changes it; it must FAIL at baseline
    GREEN_REGRESSION         already exists, Planner leaves it unchanged; must PASS
    GREEN_CHARACTERIZATION   Planner creates/changes it; must PASS

    baseline                 one logical stage, each specification judged independently
    protection               every Contract test path, changed or not
    Phase-10 baseline v1     unchanged (still exactly one BASELINE_VERIFIED event)

Baseline classification: every test in this module that exercises the new semantics is RED
at entry. The reproductions are:

    test_attempt2_shape_red_changed_regression_unchanged_passes_authoring_scope
    test_a_failing_characterization_is_not_masked_by_an_intended_red_failure

Everything runs the real production code against fake agent scripts and real git.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest
import test_project_orchestrator as orchestrator_support
import test_test_authoring_failure_precedence as bridge_support
from test_project_orchestrator import _contract_response, _make_project, _tests_response
from test_supervisor_transaction import (
    _git,
    _init_source_repo,
    _log_subjects,
    _parent_env,
    _reviewer_script,
    _ScriptAdapter,
)

import lockstep.planning_workflow as planning_workflow
import lockstep.project_orchestrator as project_orchestrator
import lockstep.test_authoring as test_authoring
import lockstep.transaction_factory as transaction_factory
from lockstep.contract_test_targets import contract_target_findings
from lockstep.domain import (
    BillingMode,
    ExecutionEventKind,
    ExecutionOutcome,
    FailureCause,
    PhaseId,
    ProjectId,
    RunId,
    StopReason,
    SubphaseContract,
    SubphaseId,
)
from lockstep.metrics import project_runtime_metrics
from lockstep.persistence import ExecutionEvent, read_events
from lockstep.supervisor import (
    SingleSubphaseTransactionRequest,
    SupervisorTransactionError,
    run_single_subphase_transaction,
)

_BASELINE = Path(__file__).parent / "baselines" / "transaction_baseline.json"
_PYTEST = (sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider")

_RED = "tests/test_new_behavior.py"
_REG = "tests/test_existing_regression.py"
_CHAR = "tests/test_current_behavior.py"

_FAILS = "def test_fails() -> None:\n    assert False\n"
_PASSES = "def test_passes() -> None:\n    assert True\n"


# ===========================================================================
# Fixtures
# ===========================================================================


def _contract(*specs: tuple[str, str]) -> SubphaseContract:
    return SubphaseContract.model_validate(
        {
            "schema_version": 1,
            "phase_id": "04",
            "subphase_id": "01",
            "title": "Expectation-aware baseline",
            "objective": "Judge every specification by its own expectation.",
            "acceptance_criteria": [{"criterion_id": "AC-1", "description": "It holds."}],
            "tests": [
                {"path": path, "expectation": expectation, "acceptance_criteria": ["AC-1"]}
                for path, expectation in specs
            ],
            "allowed_paths": ["feature.py"],
            "protected_paths": [],
            "forbidden_paths": [],
            "verification_commands": ["pytest"],
        }
    )


_MIXED = ((_RED, "red"), (_REG, "green_regression"), (_CHAR, "green_characterization"))


def _source(tmp_path: Path, *, regression_body: str = _PASSES) -> Path:
    source = _init_source_repo(tmp_path)
    (source / "tests").mkdir()
    (source / _REG).write_text(regression_body, encoding="utf-8")
    _git(source, "add", _REG)
    _git(source, "commit", "-m", "existing regression evidence")
    return source


def _write_script(files: dict[str, str]) -> str:
    lines = ["import pathlib"]
    for path, content in files.items():
        lines += [
            f"target = pathlib.Path({path!r})",
            "target.parent.mkdir(parents=True, exist_ok=True)",
            f"target.write_text({content!r})",
        ]
    return "\n".join(lines) + "\n"


def _request(
    tmp_path: Path,
    source: Path,
    contract: SubphaseContract,
    *,
    baseline_prefix: tuple[str, ...] = _PYTEST,
    command_timeout_seconds: float = 60.0,
) -> SingleSubphaseTransactionRequest:
    test_paths = tuple(spec.path for spec in contract.tests)
    return SingleSubphaseTransactionRequest(
        project_id=ProjectId.model_validate("lockstep"),
        run_id=RunId.model_validate("20260930-001"),
        phase_id=PhaseId.model_validate("04"),
        subphase_id=SubphaseId.model_validate("01"),
        source_path=source,
        worktree_path=tmp_path / "run-worktree",
        runtime_dir=tmp_path / "runtime",
        branch="lockstep/run/run-04-01-baseline",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        planner_prompt="author the acceptance evidence",
        implementer_prompt="implement",
        reviewer_prompt="review",
        test_paths=test_paths,
        implementation_paths=("feature.py",),
        planner_quality_argv=(sys.executable, "-m", "py_compile", *test_paths),
        baseline_argv=(*baseline_prefix, *test_paths),
        verification_argv=(*_PYTEST, *test_paths),
        test_commit_message="test(04.01): freeze acceptance tests",
        implementation_commit_message="feat(04.01): accepted implementation",
        agent_timeout_seconds=60.0,
        command_timeout_seconds=command_timeout_seconds,
        contract=contract,
    )


class _Run:
    def __init__(
        self,
        tmp_path: Path,
        *,
        specs: tuple[tuple[str, str], ...] = _MIXED,
        planner_files: dict[str, str],
        regression_body: str = _PASSES,
        implementer_script: str = "import sys\nsys.exit(1)\n",
        baseline_prefix: tuple[str, ...] = _PYTEST,
        command_timeout_seconds: float = 60.0,
    ) -> None:
        self.source = _source(tmp_path, regression_body=regression_body)
        self.request = _request(
            tmp_path,
            self.source,
            _contract(*specs),
            baseline_prefix=baseline_prefix,
            command_timeout_seconds=command_timeout_seconds,
        )
        self.planner = _ScriptAdapter("planner", _write_script(planner_files))
        self.implementer = _ScriptAdapter("implementer", implementer_script)
        self.reviewer = _ScriptAdapter("reviewer", _reviewer_script("approve", "approved"))
        self.tmp_path = tmp_path

    def go(self) -> SupervisorTransactionError:
        with pytest.raises(SupervisorTransactionError) as exc_info:
            run_single_subphase_transaction(
                self.request,
                parent_env=_parent_env(self.tmp_path),
                planner_adapter=self.planner,
                implementer_adapter=self.implementer,
                reviewer_adapter=self.reviewer,
            )
        return exc_info.value

    def events(self) -> list[ExecutionEvent]:
        return [
            e
            for e in read_events(self.request.runtime_dir / "events.jsonl")
            if isinstance(e, ExecutionEvent)
        ]

    def of(self, kind: ExecutionEventKind) -> list[ExecutionEvent]:
        return [e for e in self.events() if e.kind is kind]

    def evidence(self) -> dict[str, object]:
        path = self.request.runtime_dir / "artifacts" / "attempt-1" / "baseline-evidence.json"
        return json.loads(path.read_text(encoding="utf-8"))

    def committed_paths(self) -> list[str]:
        shown = _git(self.request.worktree_path, "show", "--name-only", "--format=", "HEAD")
        return sorted(shown.stdout.split())


_GOOD_FILES = {_RED: _FAILS, _CHAR: _PASSES}


def _abort(run: _Run) -> ExecutionEvent:
    (abort,) = run.of(ExecutionEventKind.TRANSACTION_ABORTED)
    return abort


# ===========================================================================
# A: the Attempt-2 authoring shape (reproduction 1)
# ===========================================================================


def test_attempt2_shape_red_changed_regression_unchanged_passes_authoring_scope(
    tmp_path: Path,
) -> None:
    run = _Run(
        tmp_path,
        specs=((_RED, "red"), (_REG, "green_regression")),
        planner_files={_RED: _FAILS},
    )

    error = run.go()

    # The implementer was launched, so authoring scope, baseline and the test commit passed.
    assert error.stage == "implementer"
    assert len(run.implementer.invocations) == 1
    assert run.committed_paths() == [_RED]
    assert len(run.of(ExecutionEventKind.TESTS_FROZEN)) == 1


# ===========================================================================
# B / C / E / M: authoring scope failures are deterministic and typed
# ===========================================================================


@pytest.mark.parametrize(
    ("files", "subreason"),
    [
        pytest.param(
            {_RED: _FAILS, _CHAR: _PASSES, _REG: _PASSES + "# edited\n"},
            "green_regression_modified",
            id="B-regression-modified",
        ),
        pytest.param({_CHAR: _PASSES}, "required_red_target_unchanged", id="C-red-unchanged"),
        pytest.param(
            {_RED: _FAILS}, "required_characterization_target_unchanged", id="E-char-unchanged"
        ),
        pytest.param(
            {_RED: _FAILS, _CHAR: _PASSES, "extra.py": "x = 1\n"},
            "unexpected_path",
            id="M-extra-file",
        ),
    ],
)
def test_authoring_scope_violations_stop_before_baseline_with_a_typed_subreason(
    tmp_path: Path, files: dict[str, str], subreason: str
) -> None:
    run = _Run(tmp_path, planner_files=files)

    error = run.go()

    assert error.stage == "test_scope"
    abort = _abort(run)
    assert abort.cause is FailureCause.SCOPE_VIOLATION
    assert abort.stop_reason is StopReason.OUT_OF_SCOPE_CHANGE
    assert abort.detail is not None and subreason in abort.detail
    assert run.of(ExecutionEventKind.BASELINE_VERIFIED) == []
    assert run.implementer.invocations == []


# ===========================================================================
# D / I: a correct mixed baseline is accepted as exactly one logical stage
# ===========================================================================


def test_mixed_correct_baseline_is_one_logical_stage_and_commits_only_authored_files(
    tmp_path: Path,
) -> None:
    run = _Run(tmp_path, planner_files=_GOOD_FILES)

    error = run.go()

    assert error.stage == "implementer"
    (baseline,) = run.of(ExecutionEventKind.BASELINE_VERIFIED)
    assert baseline.outcome is ExecutionOutcome.SUCCESS
    assert baseline.cause is None
    assert len(run.of(ExecutionEventKind.TESTS_FROZEN)) == 1
    # The unchanged GREEN_REGRESSION file is never part of the test commit.
    assert run.committed_paths() == sorted([_RED, _CHAR])
    assert _log_subjects(run.request.worktree_path)[0] == run.request.test_commit_message

    # Evidence reconstructs path, expectation, exit status and verdict per specification.
    specs = run.evidence()["specs"]
    assert [(s["path"], s["expectation"], s["satisfied"]) for s in specs] == [
        (_RED, "red", True),
        (_REG, "green_regression", True),
        (_CHAR, "green_characterization", True),
    ]
    assert [s["exit_code"] != 0 for s in specs] == [True, False, False]
    assert all(s["argv"][-1] == s["path"] for s in specs)


def test_mixed_baseline_does_not_multiply_the_phase10_baseline_stage(tmp_path: Path) -> None:
    run = _Run(tmp_path, planner_files=_GOOD_FILES)
    run.go()

    totals = project_runtime_metrics(run.request.runtime_dir, repository_change=None).totals

    assert totals.baseline_verification_runs == 1
    assert json.loads(_BASELINE.read_text(encoding="utf-8"))["baseline_version"] == 1


# ===========================================================================
# F / G / H: every expectation is proven independently
# ===========================================================================


def _baseline_failure(run: _Run, subreason: str, path: str) -> None:
    error = run.go()
    assert error.stage == "baseline"
    (baseline,) = run.of(ExecutionEventKind.BASELINE_VERIFIED)
    assert baseline.outcome is ExecutionOutcome.FAILURE
    assert baseline.detail is not None
    assert subreason in baseline.detail and path in baseline.detail
    assert run.of(ExecutionEventKind.TESTS_FROZEN) == []
    assert run.implementer.invocations == []


def test_f_red_that_unexpectedly_passes_is_rejected(tmp_path: Path) -> None:
    run = _Run(tmp_path, planner_files={_RED: _PASSES, _CHAR: _PASSES})

    _baseline_failure(run, "red_unexpectedly_passed", _RED)

    baseline = run.of(ExecutionEventKind.BASELINE_VERIFIED)[0]
    assert baseline.cause is FailureCause.TEST_DEFECT


def test_g_failing_green_regression_is_rejected_even_when_red_fails_as_intended(
    tmp_path: Path,
) -> None:
    run = _Run(
        tmp_path,
        specs=((_RED, "red"), (_REG, "green_regression")),
        planner_files={_RED: _FAILS},
        regression_body=_FAILS,
    )

    _baseline_failure(run, "green_regression_failed", _REG)


def test_h_failing_characterization_is_rejected(tmp_path: Path) -> None:
    run = _Run(tmp_path, planner_files={_RED: _FAILS, _CHAR: _FAILS})

    _baseline_failure(run, "green_characterization_failed", _CHAR)


def test_a_failing_characterization_is_not_masked_by_an_intended_red_failure(
    tmp_path: Path,
) -> None:
    """Reproduction 2: aggregate non-zero used to read as ``red_confirmed``."""
    run = _Run(
        tmp_path,
        specs=((_RED, "red"), (_CHAR, "green_characterization")),
        planner_files={_RED: _FAILS, _CHAR: _FAILS},
    )

    run.go()

    assert [e.detail for e in run.of(ExecutionEventKind.BASELINE_VERIFIED)] != ["red_confirmed"]
    assert run.of(ExecutionEventKind.TESTS_FROZEN) == []
    assert run.implementer.invocations == []


def test_baseline_failure_evidence_is_durable_and_names_the_violation(tmp_path: Path) -> None:
    run = _Run(tmp_path, planner_files={_RED: _FAILS, _CHAR: _FAILS})
    run.go()

    specs = run.evidence()["specs"]

    assert specs[-1]["path"] == _CHAR
    assert specs[-1]["expectation"] == "green_characterization"
    assert specs[-1]["satisfied"] is False
    assert specs[-1]["exit_code"] != 0
    assert specs[-1]["termination"] == "exited"


def test_baseline_command_timeout_is_distinguished(tmp_path: Path) -> None:
    run = _Run(
        tmp_path,
        planner_files=_GOOD_FILES,
        baseline_prefix=(sys.executable, "-c", "import time; time.sleep(60)"),
        command_timeout_seconds=1.0,
    )

    error = run.go()

    assert error.stage == "baseline"
    (baseline,) = run.of(ExecutionEventKind.BASELINE_VERIFIED)
    assert baseline.outcome is ExecutionOutcome.FAILURE
    assert baseline.detail is not None and "baseline_command_timeout" in baseline.detail
    assert run.implementer.invocations == []


def test_baseline_environment_failure_is_distinguished(tmp_path: Path) -> None:
    run = _Run(
        tmp_path,
        planner_files=_GOOD_FILES,
        baseline_prefix=(str(tmp_path / "no-such-test-runner"),),
    )

    error = run.go()

    assert error.stage == "baseline"
    (baseline,) = run.of(ExecutionEventKind.BASELINE_VERIFIED)
    assert baseline.cause is FailureCause.ENVIRONMENT_FAILURE
    assert baseline.detail is not None and "baseline_environment_failure" in baseline.detail


# ===========================================================================
# L: every Contract test path stays protected, changed or not
# ===========================================================================


def test_l_unchanged_green_regression_is_frozen_acceptance_authority(tmp_path: Path) -> None:
    tamper = f"import pathlib\npathlib.Path({_REG!r}).write_text('tampered\\n')\n"
    run = _Run(tmp_path, planner_files=_GOOD_FILES, implementer_script=tamper)

    error = run.go()

    assert error.stage == "implementation_scope"
    abort = _abort(run)
    assert abort.cause is FailureCause.AUTHORITY_VIOLATION
    assert abort.stop_reason is StopReason.PROTECTED_ARTIFACT_CHANGED


# ===========================================================================
# J / K: semantic Contract validation before the freeze
# ===========================================================================


def test_j_a_missing_green_regression_target_is_a_finding(tmp_path: Path) -> None:
    contract = _contract((_RED, "red"), (_REG, "green_regression"))

    findings = contract_target_findings(contract, (tmp_path,))

    assert len(findings) == 1
    assert "tests[1].path" in findings[0] and _REG in findings[0]
    assert "green_regression" in findings[0] and "exist" in findings[0]


def test_an_existing_green_regression_target_is_valid(tmp_path: Path) -> None:
    (tmp_path / "tests").mkdir()
    (tmp_path / _REG).write_text(_PASSES)

    assert (
        contract_target_findings(_contract((_RED, "red"), (_REG, "green_regression")), (tmp_path,))
        == ()
    )


def test_future_red_and_characterization_targets_are_not_required_to_exist(
    tmp_path: Path,
) -> None:
    contract = _contract((_RED, "red"), (_CHAR, "green_characterization"))

    assert contract_target_findings(contract, (tmp_path,)) == ()


def test_green_regression_must_exist_in_the_state_the_transaction_starts_from(
    tmp_path: Path,
) -> None:
    source = tmp_path / "source"
    previous = tmp_path / "previous"
    (previous / "tests").mkdir(parents=True)
    source.mkdir()
    contract = _contract((_RED, "red"), (_REG, "green_regression"))

    # Created by an earlier accepted Sub-phase: present in the later state only.
    (previous / _REG).write_text(_PASSES)
    assert contract_target_findings(contract, (source, previous)) == ()

    # Present in the source checkout but absent from the state the branch is rooted at.
    (previous / _REG).unlink()
    (source / "tests").mkdir()
    (source / _REG).write_text(_PASSES)
    assert contract_target_findings(contract, (source, previous)) != ()


def test_k_an_all_green_regression_contract_is_a_finding(tmp_path: Path) -> None:
    (tmp_path / "tests").mkdir()
    (tmp_path / _REG).write_text(_PASSES)

    findings = contract_target_findings(_contract((_REG, "green_regression")), (tmp_path,))

    assert len(findings) == 1
    assert "green_regression" in findings[0]
    assert "red" in findings[0] and "green_characterization" in findings[0]


def test_a_regression_plus_characterization_contract_is_valid(tmp_path: Path) -> None:
    (tmp_path / "tests").mkdir()
    (tmp_path / _REG).write_text(_PASSES)
    contract = _contract((_REG, "green_regression"), (_CHAR, "green_characterization"))

    assert contract_target_findings(contract, (tmp_path,)) == ()


def _green_response(tests: list[dict[str, object]]) -> dict[str, object]:
    payload = orchestrator_support._contract_payload("01")
    payload["tests"] = tests
    return {"stdout": json.dumps(payload), "returncode": 0}


def _spy(monkeypatch: pytest.MonkeyPatch):  # type: ignore[no-untyped-def]
    created: list[object] = []
    frozen: list[SubphaseContract] = []
    real_create = project_orchestrator.create_subphase_contract_candidate
    real_freeze = project_orchestrator.freeze_subphase_contract

    def create(runtime, **kwargs):  # type: ignore[no-untyped-def]
        created.append(kwargs.get("correction"))
        return real_create(runtime, **kwargs)

    def freeze(project_root, runtime_dir, contract):  # type: ignore[no-untyped-def]
        frozen.append(contract)
        return real_freeze(project_root, runtime_dir, contract)

    monkeypatch.setattr(project_orchestrator, "create_subphase_contract_candidate", create)
    monkeypatch.setattr(project_orchestrator, "freeze_subphase_contract", freeze)
    return created, frozen


@pytest.mark.parametrize("shape", ["missing-regression", "all-regression"])
def test_semantic_findings_use_the_one_bounded_contract_correction(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch, shape: str
) -> None:
    regression = {
        "path": "tests/test_regression_01.py",
        "expectation": "green_regression",
        "acceptance_criteria": ["AC-1"],
    }
    red = {
        "path": "tests/test_feature_01.py",
        "expectation": "red",
        "acceptance_criteria": ["AC-1"],
    }
    bad_tests = [red, regression] if shape == "missing-regression" else [regression]
    project = _make_project(
        tmp_path,
        sids=("01",),
        planner=[_green_response(bad_tests), _contract_response("01"), _tests_response("01")],
    )
    if shape == "all-regression":
        (project.project_root / "tests").mkdir()
        (project.project_root / "tests" / "test_regression_01.py").write_text(_PASSES)
    created, frozen = _spy(monkeypatch)

    assert project.step() is None

    assert project.launches("planner") == 2
    assert len(created) == 2 and created[0] is None and created[1] is not None
    assert [c.tests[0].path for c in frozen] == ["tests/test_feature_01.py"]


def test_two_semantically_invalid_candidates_stop_safely(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    bad = _green_response(
        [
            {
                "path": "tests/test_missing_01.py",
                "expectation": "green_regression",
                "acceptance_criteria": ["AC-1"],
            }
        ]
    )
    project = _make_project(tmp_path, sids=("01",), planner=[bad, bad, _contract_response("01")])
    created, frozen = _spy(monkeypatch)

    result = project.step()

    assert result is not None
    assert result.disposition is project_orchestrator.ProjectRunDisposition.EXECUTION_FAILED
    assert project.launches("planner") == 2 and len(created) == 2 and frozen == []


# ===========================================================================
# Planner-facing semantics
# ===========================================================================


def test_contract_planner_instructions_state_the_expectation_semantics() -> None:
    text = planning_workflow._SUBPHASE_CONTRACT_INSTRUCTIONS.lower()

    assert "green_regression" in text and "already exist" in text
    assert "green_characterization" in text
    assert "at least one" in text


@pytest.mark.parametrize(
    "instructions",
    [
        pytest.param(transaction_factory._PLANNER_INSTRUCTIONS, id="factory"),
        pytest.param(test_authoring._AUTHORING_INSTRUCTIONS, id="bridge"),
    ],
)
def test_planner_authoring_instructions_distinguish_the_three_expectations(
    instructions: str,
) -> None:
    text = instructions.lower()

    assert "green_regression" in text and "unchanged" in text
    assert "green_characterization" in text
    assert "red" in text


# ===========================================================================
# The (non-transaction) 8.7 bridge applies the same expectation semantics
# ===========================================================================


def _bridge_tests() -> list[dict[str, object]]:
    return [
        {"path": _RED, "expectation": "red", "acceptance_criteria": ["AC-1"]},
        {"path": _REG, "expectation": "green_regression", "acceptance_criteria": ["AC-1"]},
    ]


def test_bridge_accepts_an_unchanged_existing_green_regression_file(tmp_path: Path) -> None:
    runtime, worktree = bridge_support._setup(
        tmp_path,
        contract_payload=bridge_support._contract_payload(tests=_bridge_tests()),
        planner_actions=bridge_support._default_write_actions((_RED,)),
        extra_worktree_files={_REG: _PASSES},
    )

    result = bridge_support._author(runtime, worktree)

    assert [f.path for f in result.files] == [_RED, _REG]  # type: ignore[attr-defined]


def test_bridge_rejects_a_modified_green_regression_file(tmp_path: Path) -> None:
    runtime, worktree = bridge_support._setup(
        tmp_path,
        contract_payload=bridge_support._contract_payload(tests=_bridge_tests()),
        planner_actions=bridge_support._default_write_actions((_RED, _REG)),
        extra_worktree_files={_REG: _PASSES},
    )

    with pytest.raises(test_authoring.TestAuthoringError):
        bridge_support._author(runtime, worktree)
