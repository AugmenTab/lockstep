"""11.7-R3: Contract ``allowed_paths`` is an authority CEILING for the Implementer, not an obligation.

Gate Attempt 3 froze a Contract with

    tests:         tests/test_names.py (RED)
    allowed_paths: greeter/names.py, tests/test_names.py

The Implementer correctly changed only ``greeter/names.py``. The host required
``dirty_paths == allowed_paths`` and aborted ``implementation_scope``. R3 pins:

    dirty ⊆ allowed                        (not dirty == allowed)
    dirty ∩ frozen Planner tests = ∅       (independent of ``allowed``)
    allowed ∩ Contract test paths = ∅      (rejected pre-freeze, via the R1 correction route)

``ImplementationReport.changed_files`` stays an unverified evidence claim: it is recorded
verbatim and never read back to derive scope (so there is no equality to preserve there).

Baseline classification at entry: scenarios A, D, E (both), G, H, F (Contract overlap) and
the Planner-guidance test are RED against current production. B, C, I and the abort-reload
audit are accepted behavior and stay green.
"""

from __future__ import annotations

from pathlib import Path

import pytest
from test_contract_test_targets import _spy_orchestrator
from test_project_orchestrator import (
    _contract_payload,
    _contract_response,
    _make_project,
    _tests_response,
)
from test_supervisor_resume_execution import (
    _TEST_FILE_RED as _RESUME_TEST_RED,
)
from test_supervisor_resume_execution import (
    _budget,
    _halt_with_checkpoint,
    _implementer_blocked_response,
    _implementer_completed_response,
    _log_paths_for,
    _planner_authoring_response,
    _planner_decision_response,
    _prepare_scenario,
    _reviewer_turn_blocked_response,
    _reviewer_turn_completed_response,
)
from test_supervisor_resume_execution import (
    _IMPL_CORRECT as _RESUME_IMPL,
)
from test_supervisor_transaction import (
    _IMPL_CORRECT,
    _TEST_FILE_RED,
    _build_request,
    _init_source_repo,
    _log_subjects,
    _parent_env,
    _reviewer_script,
    _script_write_impl,
    _script_write_impl_and_test,
    _script_write_test,
    _ScriptAdapter,
)

import lockstep.planning_workflow as planning_workflow
from lockstep.contract_test_targets import contract_target_findings
from lockstep.domain import ExecutionEventKind, FailureCause, SubphaseContract
from lockstep.escalation import EscalationAuthority, EscalationCategory
from lockstep.escalation_decision import PlannerDecisionKind
from lockstep.git import inspect_repository
from lockstep.persistence import ExecutionEvent, load_verified_state, read_events
from lockstep.resume import ResumeDisposition, inspect_resume
from lockstep.state import WorkflowState
from lockstep.supervisor import SupervisorTransactionError, run_single_subphase_transaction
from lockstep.supervisor.transaction import (
    ResumeExecutionDisposition,
    resume_single_subphase_transaction,
    run_single_subphase_transaction_with_retry_checkpoint,
)

_TWO_PATHS = ("feature.py", "extra.py")
_TAMPERED_TEST = "def test_answer() -> None:\n    assert True\n"


def _run(tmp_path: Path, implementer_script: str, *, implementation_paths: tuple[str, ...]):  # type: ignore[no-untyped-def]
    source = _init_source_repo(tmp_path)
    request = _build_request(tmp_path, source, implementation_paths=implementation_paths)
    planner = _ScriptAdapter("planner", _script_write_test(_TEST_FILE_RED))
    implementer = _ScriptAdapter("implementer", implementer_script)
    reviewer = _ScriptAdapter("reviewer", _reviewer_script("approve", "approved"))

    def go():  # type: ignore[no-untyped-def]
        return run_single_subphase_transaction(
            request,
            parent_env=_parent_env(tmp_path),
            planner_adapter=planner,
            implementer_adapter=implementer,
            reviewer_adapter=reviewer,
        )

    return request, implementer, go


# ===========================================================================
# A-E: the scope predicate on the initial (legacy) Implementer path
# ===========================================================================


def test_a_proper_subset_of_allowed_paths_passes_scope(tmp_path: Path) -> None:
    request, _, go = _run(
        tmp_path, _script_write_impl(_IMPL_CORRECT), implementation_paths=_TWO_PATHS
    )

    result = go()

    assert result.final_state.workflow_state == WorkflowState.SUBPHASE_COMPLETE
    # Only what actually changed is committed; the unchanged allowed path is not invented.
    assert result.implementation_commit.committed_paths == ("feature.py",)
    assert inspect_repository(request.worktree_path).is_clean


def test_b_exact_allowed_set_passes_scope(tmp_path: Path) -> None:
    script = (
        "import pathlib\n"
        f"pathlib.Path('feature.py').write_text({_IMPL_CORRECT!r})\n"
        "pathlib.Path('extra.py').write_text('extra = True\\n')\n"
    )
    _, _, go = _run(tmp_path, script, implementation_paths=_TWO_PATHS)

    result = go()

    assert set(result.implementation_commit.committed_paths) == set(_TWO_PATHS)


def test_c_unauthorized_extra_path_still_fails_scope(tmp_path: Path) -> None:
    script = (
        "import pathlib\n"
        f"pathlib.Path('feature.py').write_text({_IMPL_CORRECT!r})\n"
        "pathlib.Path('secret.py').write_text('x = 1\\n')\n"
    )
    request, _, go = _run(tmp_path, script, implementation_paths=_TWO_PATHS)

    with pytest.raises(SupervisorTransactionError) as exc_info:
        go()

    assert exc_info.value.stage == "implementation_scope"
    assert _log_subjects(request.worktree_path)[0] == request.test_commit_message
    aborts = [
        e
        for e in read_events(request.runtime_dir / "events.jsonl")
        if isinstance(e, ExecutionEvent) and e.kind is ExecutionEventKind.TRANSACTION_ABORTED
    ]
    assert [e.cause for e in aborts] == [FailureCause.SCOPE_VIOLATION]


def test_d_no_changes_does_not_fail_at_the_scope_layer(tmp_path: Path) -> None:
    request, _, go = _run(tmp_path, "pass", implementation_paths=("feature.py",))

    with pytest.raises(SupervisorTransactionError) as exc_info:
        go()

    # ∅ ⊆ allowed. The no-op is rejected later (the RED test still fails verification).
    assert exc_info.value.stage != "implementation_scope"
    assert _log_subjects(request.worktree_path)[0] == request.test_commit_message


def test_e_frozen_test_modification_is_rejected_even_if_listed_as_allowed(tmp_path: Path) -> None:
    # A manually constructed request that wrongly lists the frozen test as implementation
    # authority must still not let the Implementer modify it.
    request, _, go = _run(
        tmp_path,
        _script_write_impl_and_test(_IMPL_CORRECT, _TAMPERED_TEST),
        implementation_paths=("feature.py", "tests/test_feature.py"),
    )

    with pytest.raises(SupervisorTransactionError) as exc_info:
        go()

    assert exc_info.value.stage == "implementation_scope"
    assert _log_subjects(request.worktree_path)[0] == request.test_commit_message
    aborts = [
        e
        for e in read_events(request.runtime_dir / "events.jsonl")
        if isinstance(e, ExecutionEvent) and e.kind is ExecutionEventKind.TRANSACTION_ABORTED
    ]
    assert [e.cause for e in aborts] == [FailureCause.AUTHORITY_VIOLATION]


# ===========================================================================
# Abort-state reconstruction audit (read-only characterization)
# ===========================================================================


def test_scope_abort_cannot_relaunch_the_implementer_from_stale_state(tmp_path: Path) -> None:
    script = (
        "import pathlib\n"
        f"pathlib.Path('feature.py').write_text({_IMPL_CORRECT!r})\n"
        "pathlib.Path('secret.py').write_text('x = 1\\n')\n"
    )
    request, implementer, go = _run(tmp_path, script, implementation_paths=_TWO_PATHS)
    with pytest.raises(SupervisorTransactionError):
        go()
    launches = len(implementer.invocations)

    # The journal replays to IMPLEMENTING, but that confers no authority to continue:
    reloaded = load_verified_state(request.runtime_dir / "state.json", request.runtime_dir / "events.jsonl")
    assert reloaded is not None and reloaded.workflow_state == WorkflowState.IMPLEMENTING
    # ... no retry checkpoint or claim exists, so nothing is resumable ...
    assert inspect_resume(request.runtime_dir).disposition is ResumeDisposition.NO_CHECKPOINT
    # ... and a fresh start over the same runtime is refused before any agent launches.
    with pytest.raises(SupervisorTransactionError) as exc_info:
        go()
    assert exc_info.value.stage == "runtime"
    assert len(implementer.invocations) == launches


# ===========================================================================
# Blocker-aware initial path, resume, and reviewer-resume share the semantics
# ===========================================================================


def test_turn_path_initial_proper_subset_passes_scope(tmp_path: Path) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        implementation_paths=_TWO_PATHS,
        implementer_responses=[_implementer_completed_response({"feature.py": _RESUME_IMPL})],
    )

    run_single_subphase_transaction_with_retry_checkpoint(
        scenario.request, agent_turn_runtime=scenario.runtime, retry_budget=_budget(3)
    )

    assert _log_paths_for(scenario.request.worktree_path, "feat(feature): implement answer") == (
        "feature.py",
    )


def _blocked_then(final: dict[str, object], **kwargs):  # type: ignore[no-untyped-def]
    return _prepare_scenario(
        kwargs.pop("root"),
        planner_responses=[
            _planner_authoring_response(_RESUME_TEST_RED),
            _planner_decision_response(kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE),
        ],
        implementer_responses=[
            _implementer_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            final,
        ],
        reviewer_responses=[_reviewer_turn_completed_response(attempt=2, verdict="approve")],
        **kwargs,
    )


def test_h_resumed_proper_subset_passes_scope_like_attempt_one(tmp_path: Path) -> None:
    scenario = _blocked_then(
        _implementer_completed_response({"feature.py": _RESUME_IMPL}),
        root=tmp_path / "scenario",
        implementation_paths=_TWO_PATHS,
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert _log_paths_for(scenario.request.worktree_path, "feat(feature): implement answer") == (
        "feature.py",
    )


def test_i_resumed_unauthorized_extra_path_fails_scope(tmp_path: Path) -> None:
    scenario = _blocked_then(
        _implementer_completed_response({"feature.py": _RESUME_IMPL, "secret.py": "x = 1\n"}),
        root=tmp_path / "scenario",
        implementation_paths=_TWO_PATHS,
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    with pytest.raises(SupervisorTransactionError) as exc_info:
        resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)

    assert exc_info.value.stage == "implementation_scope"


def test_resumed_frozen_test_modification_is_rejected_even_if_listed_as_allowed(
    tmp_path: Path,
) -> None:
    scenario = _blocked_then(
        _implementer_completed_response(
            {"feature.py": _RESUME_IMPL, "tests/test_feature.py": _TAMPERED_TEST}
        ),
        root=tmp_path / "scenario",
        implementation_paths=("feature.py", "tests/test_feature.py"),
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    with pytest.raises(SupervisorTransactionError) as exc_info:
        resume_single_subphase_transaction(scenario.request, agent_turn_runtime=scenario.runtime)

    assert exc_info.value.stage == "implementation_scope"
    assert (
        _log_subjects(scenario.request.worktree_path)[0]
        == "test(feature): freeze answer expectation"
    )


def test_resumed_reviewer_commits_the_proper_subset_that_actually_changed(
    tmp_path: Path,
) -> None:
    scenario = _prepare_scenario(
        tmp_path / "scenario",
        implementation_paths=_TWO_PATHS,
        planner_responses=[
            _planner_authoring_response(_RESUME_TEST_RED),
            _planner_decision_response(
                kind=PlannerDecisionKind.AUTHORIZE_BOUNDED_CHANGE, authorized_paths=()
            ),
        ],
        implementer_responses=[_implementer_completed_response({"feature.py": _RESUME_IMPL})],
        reviewer_responses=[
            _reviewer_turn_blocked_response(
                category=EscalationCategory.ARCHITECTURE_CONFLICT,
                requested_authority=EscalationAuthority.PLANNER,
            ),
            _reviewer_turn_completed_response(attempt=2, verdict="approve"),
        ],
    )
    _halt_with_checkpoint(scenario, retry_budget=_budget(3))

    result = resume_single_subphase_transaction(
        scenario.request, agent_turn_runtime=scenario.runtime
    )

    assert result.disposition == ResumeExecutionDisposition.SETTLED
    assert _log_paths_for(scenario.request.worktree_path, "feat(feature): implement answer") == (
        "feature.py",
    )


# ===========================================================================
# F/G: Contract overlap is rejected pre-freeze, through the R1 correction route
# ===========================================================================


def _overlap_contract(sid: str = "01") -> SubphaseContract:
    payload = _contract_payload(sid)
    payload["allowed_paths"] = [f"feature_{sid}.py", f"tests/test_feature_{sid}.py"]
    return SubphaseContract.model_validate(payload)


def test_f_allowed_path_overlapping_a_test_target_is_a_finding(tmp_path: Path) -> None:
    findings = contract_target_findings(_overlap_contract(), (tmp_path,))

    assert len(findings) == 1
    assert "allowed path overlaps Planner test target" in findings[0]
    assert "tests/test_feature_01.py" in findings[0]


def test_f_separated_authority_has_no_finding(tmp_path: Path) -> None:
    contract = SubphaseContract.model_validate(_contract_payload("01"))

    assert contract_target_findings(contract, (tmp_path,)) == ()


def test_f_every_overlapping_path_is_reported(tmp_path: Path) -> None:
    payload = _contract_payload("01")
    payload["tests"] = [
        {"path": "tests/test_a.py", "expectation": "red", "acceptance_criteria": ["AC-1"]},
        {"path": "tests/test_b.py", "expectation": "red", "acceptance_criteria": ["AC-1"]},
    ]
    payload["allowed_paths"] = ["tests/test_b.py", "feature_01.py", "tests/test_a.py"]

    findings = contract_target_findings(SubphaseContract.model_validate(payload), (tmp_path,))

    assert len(findings) == 2
    assert "tests/test_a.py" in findings[0] and "tests/test_b.py" in findings[1]


def test_contract_planner_instructions_define_allowed_paths_as_a_ceiling() -> None:
    text = planning_workflow._SUBPHASE_CONTRACT_INSTRUCTIONS.lower()

    assert "upper bound" in text
    assert "checklist" in text
    assert "testspecification path" in text


def test_g_overlap_then_separated_freezes_only_candidate_two(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    project = _make_project(
        tmp_path,
        sids=("01",),
        planner=[
            {"stdout": _overlap_contract().model_dump_json(), "returncode": 0},
            _contract_response("01"),
            _tests_response("01"),
        ],
    )
    created, frozen = _spy_orchestrator(monkeypatch)

    assert project.step() is None

    assert project.launches("planner") == 2
    assert len(created) == 2
    assert created[0] is None and created[1] is not None
    assert any("allowed path overlaps" in finding for finding in created[1].findings)
    assert [c.allowed_paths for c in frozen] == [("feature_01.py",)]
