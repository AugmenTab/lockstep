"""Pre-freeze Planner test-candidate correction (dogfood runtime-4 regression).

Runtime 4 reached a genuine model-output failure: the Planner authored RED tests that
statically referenced a module the Sub-phase had not implemented yet, so the configured
Planner quality command (a typecheck) rejected every candidate before baseline ran, and
the transaction ended ``execution_failed / test_quality`` with no way to correct it.

Pinned here, against real Git, real production adapters and fake provider executables
(no Claude, Docker, npm or Black):

    candidate N rejected at test_quality or baseline
        -> deterministic rejection evidence recorded (candidate-addressed, write-once)
        -> exact Contract test paths restored to the pristine pre-Planner worktree
        -> fresh Planner invocation: original prompt + labeled deterministic findings
    candidate accepted -> tests frozen -> Implementer

All within transaction AttemptNumber 1; no retry checkpoint. Scope violations, Git
authority changes and Planner process failures are never corrected, and the legacy
entrypoints keep exactly one candidate.
"""

from __future__ import annotations

import dataclasses
import json
import stat
import sys
import textwrap
from pathlib import Path

import pytest
from test_supervisor_retry_checkpoint import (
    _agent_runtime,
    _build_request,
    _claude_adapter,
    _git,
    _implementer_completed_response,
    _init_source_repo,
    _parent_env,
    _reviewer_turn_completed_response,
    _write_fake_claude_executable,
)

import lockstep.transaction_factory as transaction_factory
from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    ExecutionEventKind,
    ExecutionOutcome,
    FailureCause,
    PhaseId,
    RunId,
    StopReason,
    SubphaseContract,
    SubphaseId,
)
from lockstep.evidence_store import (
    baseline_evidence_path,
    load_planner_candidate_rejection,
    planner_candidate_rejection_path,
)
from lockstep.persistence import (
    ExecutionEvent,
    StateTransitionedEvent,
    read_events,
    read_state,
)
from lockstep.planner_test_candidates import (
    CORRECTION_INSTRUCTIONS,
    PLANNER_QUALITY_INVARIANT,
    CandidateRejectionStage,
    PlannerCandidateRejection,
)
from lockstep.retry import RetryBudget
from lockstep.retry_checkpoint import retry_checkpoint_path
from lockstep.state import WorkflowState
from lockstep.supervisor.transaction import (
    SingleSubphaseTransactionRequest,
    SingleSubphaseTransactionResult,
    SupervisorTransactionError,
    run_single_subphase_transaction,
    run_single_subphase_transaction_with_blockers,
    run_single_subphase_transaction_with_retry_checkpoint,
)

_TEST = "tests/test_feature.py"
_CHAR = "tests/test_current.py"

# Candidate 1 (runtime-4 shape): a static reference to the future module.
_STATIC_RED = (
    "import pathlib\n"
    "import sys\n"
    "\n"
    "sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))\n"
    "\n"
    "from feature import answer\n"
    "\n"
    "\n"
    "def test_answer() -> None:\n"
    "    assert answer() == 42\n"
)
# Candidate 2: the same requirement, resolved at test execution time.
_DYNAMIC_RED = (
    "import importlib\n"
    "import pathlib\n"
    "import sys\n"
    "\n"
    "sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent.parent))\n"
    "\n"
    "\n"
    "def test_answer() -> None:\n"
    "    feature = importlib.import_module('feature')\n"
    "    assert feature.answer() == 42\n"
)
_PASSING = "def test_passes() -> None:\n    assert True\n"
_IMPL = "def answer() -> int:\n    return 42\n"

# A deterministic stand-in for a typechecker: a static import of a module that does not
# exist in the worktree is a compile-time error, exactly the runtime-4 diagnostic class.
_QUALITY_CHECKER = textwrap.dedent(
    """\
    import pathlib
    import sys

    failed = False
    for name in sys.argv[1:]:
        for number, line in enumerate(pathlib.Path(name).read_text().splitlines(), 1):
            words = line.split()
            if line.startswith("from ") and len(words) > 1:
                if not pathlib.Path(words[1] + ".py").exists():
                    print(f"{name}:{number}: Cannot find module '{words[1]}'", file=sys.stderr)
                    failed = True
    sys.exit(2 if failed else 0)
    """
)


# ---------------------------------------------------------------------------
# A Planner executable that records each prompt and the worktree it started from
# ---------------------------------------------------------------------------


def _write_recording_planner(bin_dir: Path, responses: list[dict[str, object]]) -> Path:
    bin_dir.mkdir(parents=True, exist_ok=True)
    (bin_dir / "responses.json").write_text(json.dumps(responses), encoding="utf-8")
    executable = bin_dir / "claude-planner"
    executable.write_text(
        textwrap.dedent(
            f"""\
            #!{sys.executable}
            import json
            import subprocess
            import sys
            from pathlib import Path

            base = Path(__file__).resolve().parent
            responses = json.loads((base / "responses.json").read_text(encoding="utf-8"))
            count_path = base / "count.txt"
            index = int(count_path.read_text()) if count_path.exists() else 0
            count_path.write_text(str(index + 1))
            response = responses[index] if index < len(responses) else responses[-1]

            prompt = sys.stdin.read()
            status = subprocess.run(
                ["git", "status", "--porcelain", "--untracked-files=all"],
                capture_output=True, text=True, check=True,
            ).stdout
            head = subprocess.run(
                ["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True
            ).stdout.strip()
            (base / f"prompt-{{index + 1}}.txt").write_text(prompt, encoding="utf-8")
            with (base / "invocations.jsonl").open("a", encoding="utf-8") as fh:
                fh.write(json.dumps({{"status": status, "head": head}}) + "\\n")

            for rel_path, content in response.get("files", {{}}).items():
                target = Path(rel_path)
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(content)
            for argv in response.get("git", []):
                subprocess.run(["git", *argv], check=True, capture_output=True)

            sys.stdout.write(response.get("stdout", ""))
            raise SystemExit(int(response.get("returncode", 0)))
            """
        ),
        encoding="utf-8",
    )
    executable.chmod(executable.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _authored(files: dict[str, str], **extra: object) -> dict[str, object]:
    return {"stdout": "", "returncode": 0, "files": files, **extra}


@dataclasses.dataclass(frozen=True)
class _Run:
    request: SingleSubphaseTransactionRequest
    root: Path
    source_head: str
    planner_bin: Path
    implementer_bin: Path
    runtime: object

    # --- driving ---------------------------------------------------------------

    def checkpointed(self, max_attempts: int = 3) -> object:
        return run_single_subphase_transaction_with_retry_checkpoint(
            self.request,
            agent_turn_runtime=self.runtime,  # type: ignore[arg-type]
            retry_budget=RetryBudget(max_attempts=AttemptNumber.model_validate(max_attempts)),
        )

    def fails(self, max_attempts: int = 3) -> SupervisorTransactionError:
        with pytest.raises(SupervisorTransactionError) as exc_info:
            self.checkpointed(max_attempts)
        return exc_info.value

    # --- observing ---------------------------------------------------------------

    def planner_calls(self) -> list[dict[str, str]]:
        log = self.planner_bin / "invocations.jsonl"
        if not log.exists():
            return []
        return [json.loads(line) for line in log.read_text().splitlines() if line]

    def prompt(self, candidate: int) -> str:
        return (self.planner_bin / f"prompt-{candidate}.txt").read_text(encoding="utf-8")

    def implementer_calls(self) -> int:
        log = self.implementer_bin / "claude-implementer-invocations.jsonl"
        return len(log.read_text().splitlines()) if log.exists() else 0

    def journal(self) -> list[object]:
        return list(read_events(self.request.runtime_dir / "events.jsonl"))

    def of(self, kind: ExecutionEventKind) -> list[ExecutionEvent]:
        return [e for e in self.journal() if isinstance(e, ExecutionEvent) and e.kind is kind]

    def transitions(self) -> list[tuple[WorkflowState, WorkflowState]]:
        return [
            (e.source, e.target) for e in self.journal() if isinstance(e, StateTransitionedEvent)
        ]

    def state(self) -> WorkflowState:
        snapshot = read_state(self.request.runtime_dir / "state.json")
        assert snapshot is not None
        return snapshot.workflow_state

    def rejection(self, candidate: int) -> PlannerCandidateRejection | None:
        return load_planner_candidate_rejection(
            self.request.runtime_dir,
            run_id=self.request.run_id,
            phase_id=self.request.phase_id,
            subphase_id=self.request.subphase_id,
            attempt=AttemptNumber.model_validate(1),
            candidate=candidate,
        )

    def worktree(self) -> Path:
        return self.request.worktree_path

    def test_commits(self) -> list[str]:
        return _git(
            self.worktree(), "log", "--format=%H", f"{self.source_head}..HEAD"
        ).stdout.split()


def _contract(*specs: tuple[str, str]) -> SubphaseContract:
    return SubphaseContract.model_validate(
        {
            "schema_version": 1,
            "phase_id": "09",
            "subphase_id": "10",
            "title": "Answer",
            "objective": "Provide the answer.",
            "acceptance_criteria": [{"criterion_id": "AC-1", "description": "It answers."}],
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


def _prepare(
    tmp_path: Path,
    planner: list[dict[str, object]],
    *,
    specs: tuple[tuple[str, str], ...] = ((_TEST, "red"),),
    baseline_prefix: tuple[str, ...] | None = None,
) -> _Run:
    source = _init_source_repo(tmp_path)
    source_head = _git(source, "rev-parse", "HEAD").stdout.strip()
    checker = tmp_path / "quality_checker.py"
    checker.write_text(_QUALITY_CHECKER, encoding="utf-8")
    test_paths = tuple(path for path, _ in specs)
    pytest_prefix = (sys.executable, "-m", "pytest", "-q", "-p", "no:cacheprovider")
    request = dataclasses.replace(
        _build_request(tmp_path, source),
        test_paths=test_paths,
        planner_quality_argv=(sys.executable, str(checker), *test_paths),
        baseline_argv=(*(baseline_prefix or pytest_prefix), *test_paths),
        verification_argv=(*pytest_prefix, *test_paths),
        contract=_contract(*specs),
    )

    planner_bin = tmp_path / "planner-bin"
    _write_recording_planner(planner_bin, planner)
    implementer_bin = tmp_path / "implementer-bin"
    _write_fake_claude_executable(
        implementer_bin,
        name="claude-implementer",
        responses=[_implementer_completed_response({"feature.py": _IMPL})],
    )
    reviewer_bin = tmp_path / "reviewer-bin"
    _write_fake_claude_executable(
        reviewer_bin, name="claude-reviewer", responses=[_reviewer_turn_completed_response()]
    )
    runtime = _agent_runtime(
        tmp_path,
        runtime_dir=request.runtime_dir,
        planner_adapter=_claude_adapter(
            AgentRole.PLANNER, executable=str(planner_bin / "claude-planner")
        ),
        implementer_adapter=_claude_adapter(
            AgentRole.IMPLEMENTER, executable=str(implementer_bin / "claude-implementer")
        ),
        reviewer_adapter=_claude_adapter(
            AgentRole.REVIEWER, executable=str(reviewer_bin / "claude-reviewer")
        ),
        parent_env=_parent_env(tmp_path),
    )
    return _Run(request, tmp_path, source_head, planner_bin, implementer_bin, runtime)


def _attempts(run: _Run) -> set[int]:
    return {
        e.attempt.root
        for e in run.journal()
        if isinstance(e, ExecutionEvent) and e.attempt is not None
    }


def _sequence_of_first(run: _Run, predicate: object) -> int:
    for event in run.journal():
        if predicate(event):  # type: ignore[operator]
            return event.sequence  # type: ignore[attr-defined]
    raise AssertionError("event not found")


def _no_checkpoint(run: _Run) -> bool:
    return not retry_checkpoint_path(run.request.runtime_dir).exists()


_PRE_AUTHORING = [
    (WorkflowState.READY, WorkflowState.PHASE_PLANNING),
    (WorkflowState.PHASE_PLANNING, WorkflowState.SUBPHASE_PLANNING),
    (WorkflowState.SUBPHASE_PLANNING, WorkflowState.TEST_AUTHORING),
]


# ===========================================================================
# Runtime-4 regression: a quality-rejected candidate is corrected
# ===========================================================================


def test_runtime4_quality_rejected_candidate_is_corrected_before_freeze(tmp_path: Path) -> None:
    run = _prepare(tmp_path, [_authored({_TEST: _STATIC_RED}), _authored({_TEST: _DYNAMIC_RED})])

    result = run.checkpointed()

    # 9. Tests froze only after candidate 2 was accepted; the transaction completed.
    assert isinstance(result, SingleSubphaseTransactionResult)
    calls = run.planner_calls()
    assert len(calls) == 2

    # 1/5. Candidate 1 wrote only its authorized test path; candidate 2 started from the
    # exact pristine pre-Planner worktree (same HEAD, nothing dirty).
    assert [call["status"] for call in calls] == ["", ""]
    assert [call["head"] for call in calls] == [run.source_head, run.source_head]

    # 2/3. Candidate 1's deterministic quality rejection is durable evidence.
    rejection = run.rejection(1)
    assert rejection is not None
    assert rejection.stage is CandidateRejectionStage.TEST_QUALITY
    assert rejection.candidate == 1
    assert rejection.attempt.root == 1
    assert rejection.test_paths == (_TEST,)
    assert rejection.findings == ("planner_quality_failed exit=2",)
    assert rejection.quality is not None
    assert rejection.quality.argv == run.request.planner_quality_argv
    assert rejection.quality.exit_code == 2
    assert "Cannot find module 'feature'" in rejection.quality.stderr
    assert rejection.baseline is None
    assert run.rejection(2) is None

    # 6. Candidate 2 was told the deterministic finding.
    assert "Cannot find module 'feature'" in run.prompt(2)

    # 7/8. Candidate 2 passed quality and its RED expectation was checked normally.
    (baseline,) = run.of(ExecutionEventKind.BASELINE_VERIFIED)
    assert baseline.outcome is ExecutionOutcome.SUCCESS
    record = json.loads(
        baseline_evidence_path(run.request.runtime_dir, AttemptNumber.model_validate(1)).read_text(
            encoding="utf-8"
        )
    )
    assert [(s["path"], s["expectation"], s["satisfied"]) for s in record["specs"]] == [
        (_TEST, "red", True)
    ]

    # Quality rejection stays in TEST_AUTHORING: the FSM path is the ordinary one.
    assert run.transitions()[:6] == [
        *_PRE_AUTHORING,
        (WorkflowState.TEST_AUTHORING, WorkflowState.TEST_BASELINE_VERIFY),
        (WorkflowState.TEST_BASELINE_VERIFY, WorkflowState.TEST_COMMIT),
        (WorkflowState.TEST_COMMIT, WorkflowState.IMPLEMENTING),
    ]

    # 9. Only candidate 2 is committed and frozen.
    assert result.test_commit.committed_paths == (_TEST,)
    frozen = _git(run.worktree(), "show", f"{result.test_commit.commit_sha}:{_TEST}").stdout
    assert frozen == _DYNAMIC_RED
    assert len(run.of(ExecutionEventKind.TESTS_FROZEN)) == 1

    # 10. The Implementer was not invoked before the freeze.
    frozen_at = _sequence_of_first(
        run,
        lambda e: isinstance(e, ExecutionEvent) and e.kind is ExecutionEventKind.TESTS_FROZEN,
    )
    implementer_at = _sequence_of_first(
        run,
        lambda e: (
            isinstance(e, ExecutionEvent)
            and e.kind is ExecutionEventKind.INVOCATION_STARTED
            and e.role is AgentRole.IMPLEMENTER
        ),
    )
    assert frozen_at < implementer_at
    assert run.implementer_calls() == 1

    # 11. Transaction AttemptNumber 1 throughout; two distinct Planner invocations.
    assert _attempts(run) == {1}
    planner_started = [
        e for e in run.of(ExecutionEventKind.INVOCATION_STARTED) if e.role is AgentRole.PLANNER
    ]
    assert len({e.invocation_id for e in planner_started}) == 2
    assert _no_checkpoint(run)

    # The journal stays strictly monotonic.
    sequences = [e.sequence for e in run.journal()]  # type: ignore[attr-defined]
    assert sequences == list(range(1, len(sequences) + 1))


# ===========================================================================
# Baseline-mismatch correction
# ===========================================================================


def test_baseline_rejected_candidate_is_corrected_through_the_controlled_edge(
    tmp_path: Path,
) -> None:
    # Candidate 1 passes quality but its RED test passes at baseline.
    run = _prepare(tmp_path, [_authored({_TEST: _PASSING}), _authored({_TEST: _DYNAMIC_RED})])

    result = run.checkpointed()

    assert isinstance(result, SingleSubphaseTransactionResult)
    assert len(run.planner_calls()) == 2
    assert run.planner_calls()[1]["status"] == ""

    rejection = run.rejection(1)
    assert rejection is not None
    assert rejection.stage is CandidateRejectionStage.BASELINE
    assert rejection.quality is None
    assert rejection.baseline is not None
    assert rejection.findings == (f"red_unexpectedly_passed path={_TEST} expected=red exit=0",)
    (entry,) = rejection.baseline.specs
    assert (entry.path, entry.satisfied, entry.exit_code) == (_TEST, False, 0)

    # Candidate 2 received the deterministic baseline finding.
    assert "red_unexpectedly_passed" in run.prompt(2)

    # The canonical baseline artifact is the accepted candidate's, not the rejected one's.
    record = json.loads(
        baseline_evidence_path(run.request.runtime_dir, AttemptNumber.model_validate(1)).read_text(
            encoding="utf-8"
        )
    )
    assert record["specs"][0]["satisfied"] is True

    assert run.transitions()[:8] == [
        *_PRE_AUTHORING,
        (WorkflowState.TEST_AUTHORING, WorkflowState.TEST_BASELINE_VERIFY),
        (WorkflowState.TEST_BASELINE_VERIFY, WorkflowState.TEST_AUTHORING),
        (WorkflowState.TEST_AUTHORING, WorkflowState.TEST_BASELINE_VERIFY),
        (WorkflowState.TEST_BASELINE_VERIFY, WorkflowState.TEST_COMMIT),
        (WorkflowState.TEST_COMMIT, WorkflowState.IMPLEMENTING),
    ]
    outcomes = [e.outcome for e in run.of(ExecutionEventKind.BASELINE_VERIFIED)]
    assert outcomes == [ExecutionOutcome.FAILURE, ExecutionOutcome.SUCCESS]

    # Only candidate 2 is committed and frozen.
    assert len(run.test_commits()) == 2  # test commit + implementation commit
    frozen = _git(run.worktree(), "show", f"{result.test_commit.commit_sha}:{_TEST}").stdout
    assert frozen == _DYNAMIC_RED
    assert _attempts(run) == {1}
    assert _no_checkpoint(run)


def test_a_failing_characterization_candidate_is_corrected_alongside_a_red_one(
    tmp_path: Path,
) -> None:
    specs = ((_TEST, "red"), (_CHAR, "green_characterization"))
    bad = {_TEST: _DYNAMIC_RED, _CHAR: "def test_c() -> None:\n    assert False\n"}
    good = {_TEST: _DYNAMIC_RED, _CHAR: _PASSING}
    run = _prepare(tmp_path, [_authored(bad), _authored(good)], specs=specs)

    result = run.checkpointed()

    assert isinstance(result, SingleSubphaseTransactionResult)
    rejection = run.rejection(1)
    assert rejection is not None and rejection.test_paths == (_TEST, _CHAR)
    assert rejection.findings == (
        f"green_characterization_failed path={_CHAR} expected=green_characterization exit=1",
    )
    assert run.planner_calls()[1]["status"] == ""
    assert sorted(result.test_commit.committed_paths) == sorted([_TEST, _CHAR])


def test_every_rejected_candidate_keeps_its_own_durable_evidence(tmp_path: Path) -> None:
    run = _prepare(
        tmp_path,
        [
            _authored({_TEST: _STATIC_RED}),
            _authored({_TEST: _PASSING}),
            _authored({_TEST: _DYNAMIC_RED}),
        ],
    )

    assert isinstance(run.checkpointed(max_attempts=3), SingleSubphaseTransactionResult)

    first, second = run.rejection(1), run.rejection(2)
    assert first is not None and first.stage is CandidateRejectionStage.TEST_QUALITY
    assert second is not None and second.stage is CandidateRejectionStage.BASELINE
    assert run.rejection(3) is None
    one = AttemptNumber.model_validate(1)
    assert planner_candidate_rejection_path(run.request.runtime_dir, one, 1) != (
        planner_candidate_rejection_path(run.request.runtime_dir, one, 2)
    )
    # The third prompt carries both prior rejections, oldest first.
    third = run.prompt(3)
    assert third.index("planner_quality_failed") < third.index("red_unexpectedly_passed")
    # Evidence never includes the rejected test source.
    for candidate in (1, 2):
        path = planner_candidate_rejection_path(run.request.runtime_dir, one, candidate)
        assert "def test_" not in path.read_text(encoding="utf-8")
    assert "def test_passes" not in third and "from feature import answer" not in third


# ===========================================================================
# Correction prompt: original prompt + labeled, authority-free correction section
# ===========================================================================


def test_correction_prompt_is_the_original_prompt_plus_a_labeled_correction(
    tmp_path: Path,
) -> None:
    run = _prepare(tmp_path, [_authored({_TEST: _STATIC_RED}), _authored({_TEST: _DYNAMIC_RED})])
    run.checkpointed()

    first, second = run.prompt(1), run.prompt(2)

    assert first == run.request.planner_prompt
    assert second.startswith(first)
    correction = second[len(first) :]
    titles = (
        "REJECTED TEST CANDIDATE",
        "DETERMINISTIC VALIDATION FINDINGS",
        "CORRECTION INSTRUCTIONS",
    )
    positions = [correction.index(title) for title in titles]
    assert positions == sorted(positions)
    assert CORRECTION_INSTRUCTIONS in correction
    text = CORRECTION_INSTRUCTIONS.lower()
    assert "evidence only" in text
    assert "amend no contract" in text
    assert "complete replacement candidate" in text
    assert "resolves every deterministic finding" in text
    assert "git index" in text and "outside the authorized test paths" in text
    assert "attempt" not in text


# ===========================================================================
# Planner-facing quality invariant
# ===========================================================================


@pytest.mark.parametrize(
    "instructions",
    [
        pytest.param(transaction_factory._PLANNER_INSTRUCTIONS, id="canonical-factory"),
        pytest.param(CORRECTION_INSTRUCTIONS, id="correction"),
    ],
)
def test_planner_instructions_state_the_quality_invariant(instructions: str) -> None:
    text = instructions.lower()

    assert "quality gate precedes baseline classification" in text
    assert "baseline test execution" in text
    assert "not during the compilation, typechecking or linting" in text
    assert "does not exist yet" in text
    assert "mere absence makes the quality stage fail" in text


def test_the_quality_invariant_is_generic() -> None:
    text = PLANNER_QUALITY_INVARIANT.lower()

    for specific in ("typescript", "import(", "black", "npm", "docker", "codegen", "tsc"):
        assert specific not in text


def test_the_bridge_instructions_carry_the_same_invariant() -> None:
    import lockstep.test_authoring as test_authoring

    assert PLANNER_QUALITY_INVARIANT in test_authoring._AUTHORING_INSTRUCTIONS


# ===========================================================================
# Hard failures: correction never weakens authority
# ===========================================================================


@pytest.mark.parametrize(
    "files",
    [
        pytest.param({_TEST: _STATIC_RED, "extra.py": "x = 1\n"}, id="extra-path"),
        pytest.param({_TEST: _STATIC_RED, "README.md": "tampered\n"}, id="unauthorized-path"),
    ],
)
def test_scope_violation_still_terminates_immediately(
    tmp_path: Path, files: dict[str, str]
) -> None:
    run = _prepare(tmp_path, [_authored(files), _authored({_TEST: _DYNAMIC_RED})])

    error = run.fails()

    assert error.stage == "test_scope"
    assert len(run.planner_calls()) == 1
    assert run.rejection(1) is None
    assert run.implementer_calls() == 0
    (abort,) = run.of(ExecutionEventKind.TRANSACTION_ABORTED)
    assert abort.cause is FailureCause.SCOPE_VIOLATION
    # Nothing was cleaned up.
    assert (run.worktree() / _TEST).exists()


def test_planner_changing_head_is_not_corrected(tmp_path: Path) -> None:
    moved = _authored(
        {_TEST: _STATIC_RED, "README.md": "moved\n"},
        git=[["commit", "-q", "-m", "planner commit", "--", "README.md"]],
    )
    run = _prepare(tmp_path, [moved, _authored({_TEST: _DYNAMIC_RED})])

    error = run.fails()

    assert error.stage == "test_authority"
    assert len(run.planner_calls()) == 1
    (abort,) = run.of(ExecutionEventKind.TRANSACTION_ABORTED)
    assert abort.cause is FailureCause.AUTHORITY_VIOLATION
    assert abort.stop_reason is StopReason.PROTECTED_ARTIFACT_CHANGED
    assert (run.worktree() / _TEST).read_text() == _STATIC_RED
    assert run.implementer_calls() == 0


def test_planner_staging_files_is_not_corrected(tmp_path: Path) -> None:
    staged = _authored({_TEST: _STATIC_RED}, git=[["add", "--", _TEST]])
    run = _prepare(tmp_path, [staged, _authored({_TEST: _DYNAMIC_RED})])

    error = run.fails()

    assert error.stage == "test_authority"
    assert len(run.planner_calls()) == 1
    staged_now = _git(run.worktree(), "diff", "--cached", "--name-only").stdout.split()
    assert staged_now == [_TEST]  # never silently repaired
    assert run.implementer_calls() == 0


def test_planner_process_failure_keeps_existing_behavior(tmp_path: Path) -> None:
    failed = {"stdout": "", "returncode": 1, "files": {_TEST: _DYNAMIC_RED}}
    run = _prepare(tmp_path, [failed, _authored({_TEST: _DYNAMIC_RED})])

    error = run.fails()

    assert error.stage == "planner"
    assert len(run.planner_calls()) == 1
    assert run.state() is WorkflowState.HALTED
    assert run.rejection(1) is None


def test_baseline_infrastructure_failure_is_not_corrected(tmp_path: Path) -> None:
    run = _prepare(
        tmp_path,
        [_authored({_TEST: _DYNAMIC_RED}), _authored({_TEST: _DYNAMIC_RED})],
        baseline_prefix=(str(tmp_path / "no-such-test-runner"),),
    )

    error = run.fails()

    assert error.stage == "baseline"
    assert len(run.planner_calls()) == 1
    assert run.implementer_calls() == 0


def test_a_failing_pre_existing_green_regression_is_not_corrected(tmp_path: Path) -> None:
    reg = "tests/test_existing.py"
    run = _prepare(
        tmp_path,
        [_authored({_TEST: _DYNAMIC_RED})] * 2,
        specs=((_TEST, "red"), (reg, "green_regression")),
    )
    # The pre-existing regression file fails; the Planner may not change it.
    source = run.request.source_path
    (source / "tests").mkdir()
    (source / reg).write_text("def test_r() -> None:\n    assert False\n")
    _git(source, "add", reg)
    _git(source, "commit", "-m", "existing regression")

    error = run.fails()

    assert error.stage == "baseline"
    assert len(run.planner_calls()) == 1


@pytest.mark.parametrize(
    ("bad", "stage"),
    [
        pytest.param({_TEST: _STATIC_RED}, "test_quality", id="quality"),
        pytest.param({_TEST: _PASSING}, "baseline", id="baseline"),
    ],
)
def test_exhausted_candidate_budget_never_invokes_the_implementer(
    tmp_path: Path, bad: dict[str, str], stage: str
) -> None:
    run = _prepare(tmp_path, [_authored(bad), _authored(bad), _authored({_TEST: _DYNAMIC_RED})])

    error = run.fails(max_attempts=2)

    assert error.stage == stage
    assert len(run.planner_calls()) == 2
    assert run.implementer_calls() == 0
    assert run.of(ExecutionEventKind.TESTS_FROZEN) == []
    assert run.test_commits() == []
    assert _no_checkpoint(run)
    assert _attempts(run) == {1}
    # Every candidate's rejection is durable; the final one stays in the worktree.
    for candidate in (1, 2):
        rejection = run.rejection(candidate)
        assert rejection is not None and rejection.stage.value == stage
    assert (run.worktree() / _TEST).read_text() == bad[_TEST]
    expected_state = (
        WorkflowState.TEST_AUTHORING
        if stage == "test_quality"
        else WorkflowState.TEST_BASELINE_VERIFY
    )
    assert run.state() is expected_state


def test_a_one_attempt_budget_allows_exactly_one_candidate(tmp_path: Path) -> None:
    run = _prepare(tmp_path, [_authored({_TEST: _STATIC_RED}), _authored({_TEST: _DYNAMIC_RED})])

    error = run.fails(max_attempts=1)

    assert error.stage == "test_quality"
    assert len(run.planner_calls()) == 1


# ===========================================================================
# Legacy entrypoints keep exactly one candidate
# ===========================================================================


def test_legacy_entrypoint_never_requests_a_second_candidate(tmp_path: Path) -> None:
    run = _prepare(tmp_path, [_authored({_TEST: _STATIC_RED}), _authored({_TEST: _DYNAMIC_RED})])
    adapters = run.runtime.adapters  # type: ignore[attr-defined]

    with pytest.raises(SupervisorTransactionError) as exc_info:
        run_single_subphase_transaction(
            run.request,
            parent_env=_parent_env(tmp_path),
            planner_adapter=adapters.planner,
            implementer_adapter=adapters.implementer,
            reviewer_adapter=adapters.reviewer,
        )

    assert exc_info.value.stage == "test_quality"
    assert len(run.planner_calls()) == 1


def test_blocker_entrypoint_never_requests_a_second_candidate(tmp_path: Path) -> None:
    run = _prepare(tmp_path, [_authored({_TEST: _PASSING}), _authored({_TEST: _DYNAMIC_RED})])

    with pytest.raises(SupervisorTransactionError) as exc_info:
        run_single_subphase_transaction_with_blockers(
            run.request,
            agent_turn_runtime=run.runtime,  # type: ignore[arg-type]
        )

    assert exc_info.value.stage == "baseline"
    assert len(run.planner_calls()) == 1
    assert run.state() is WorkflowState.TEST_BASELINE_VERIFY


# ===========================================================================
# Evidence model
# ===========================================================================


def test_a_rejection_record_must_carry_evidence_matching_its_stage() -> None:
    common = {
        "run_id": RunId.model_validate("20260928-010"),
        "phase_id": PhaseId.model_validate("09"),
        "subphase_id": SubphaseId.model_validate("10"),
        "attempt": AttemptNumber.model_validate(1),
        "candidate": 1,
        "test_paths": (_TEST,),
        "findings": ("planner_quality_failed exit=2",),
        "max_output_bytes": 16,
    }
    with pytest.raises(ValueError):
        PlannerCandidateRejection(stage=CandidateRejectionStage.TEST_QUALITY, **common)
    with pytest.raises(ValueError):
        PlannerCandidateRejection(stage=CandidateRejectionStage.BASELINE, **common)
    with pytest.raises(ValueError):
        PlannerCandidateRejection(
            stage=CandidateRejectionStage.TEST_QUALITY,
            quality={"argv": ("q",), "exit_code": 2, "stderr": "x" * 17},
            **common,
        )
    with pytest.raises(ValueError):
        PlannerCandidateRejection(
            stage=CandidateRejectionStage.TEST_QUALITY,
            quality={"argv": ("q",), "exit_code": 2},
            **{**common, "candidate": 0},
        )
