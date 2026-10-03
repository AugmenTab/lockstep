"""Expectation-aware test authoring scope and baseline verification (11.7-R2).

The Contract's ``TestSpecification.expectation`` is the authority for what each test file
must do before implementation begins::

    RED                      the Planner creates/changes the file; it must FAIL at baseline
    GREEN_REGRESSION         the file already exists and is left unchanged; it must PASS
    GREEN_CHARACTERIZATION   the Planner creates/changes the file; it must PASS

Two deterministic judgements follow, both defined here and nowhere else:

    :func:`authoring_scope_violation`   which paths the Planner may have changed
    :func:`run_baseline_expectations`   one command per specification (configured prefix plus
                                        the exact path, no shell), each judged against its own
                                        expectation, so one specification's intended failure can
                                        never hide another's unexpected one

The baseline remains ONE logical transaction stage: the caller emits a single
``BASELINE_VERIFIED`` event for the whole set. The recorded evidence is descriptive; the
Contract stays authoritative for what was expected.
"""

from __future__ import annotations

from collections.abc import Callable, Mapping, Sequence
from enum import StrEnum
from pathlib import Path
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field, model_validator

from lockstep.contract_test_targets import target_path_violation, traverses_symlink
from lockstep.domain import (
    AttemptNumber,
    FailureCause,
    PhaseId,
    RunId,
    SubphaseContract,
    SubphaseId,
    TestExpectation,
)
from lockstep.process import (
    ProcessConfigurationError,
    ProcessLaunchError,
    ProcessResult,
    ProcessTimeoutError,
    run_process,
)
from lockstep.verification_stack import _bound

Spec = tuple[str, TestExpectation]

_CURRENT_SCHEMA_VERSION = 1


class AuthoringScopeSubreason(StrEnum):
    """Why a Planner test-authoring result is out of scope (typed, bounded)."""

    UNEXPECTED_PATH = "unexpected_path"
    REQUIRED_RED_TARGET_UNCHANGED = "required_red_target_unchanged"
    REQUIRED_CHARACTERIZATION_TARGET_UNCHANGED = "required_characterization_target_unchanged"
    GREEN_REGRESSION_MODIFIED = "green_regression_modified"
    INVALID_TEST_TARGET = "invalid_test_target"
    DELETED_TEST_TARGET = "deleted_test_target"
    NON_REGULAR_TEST_TARGET = "non_regular_test_target"
    SYMLINK_VIOLATION = "symlink_violation"


S = AuthoringScopeSubreason


class BaselineSubreason(StrEnum):
    """Why the baseline stage rejected the authored evidence (typed, bounded)."""

    RED_UNEXPECTEDLY_PASSED = "red_unexpectedly_passed"
    GREEN_REGRESSION_FAILED = "green_regression_failed"
    GREEN_CHARACTERIZATION_FAILED = "green_characterization_failed"
    BASELINE_COMMAND_TIMEOUT = "baseline_command_timeout"
    BASELINE_ENVIRONMENT_FAILURE = "baseline_environment_failure"


_EXPECTATION_FAILURE: Mapping[TestExpectation, BaselineSubreason] = {
    TestExpectation.RED: BaselineSubreason.RED_UNEXPECTEDLY_PASSED,
    TestExpectation.GREEN_REGRESSION: BaselineSubreason.GREEN_REGRESSION_FAILED,
    TestExpectation.GREEN_CHARACTERIZATION: BaselineSubreason.GREEN_CHARACTERIZATION_FAILED,
}


def expectation_specs(
    test_paths: Sequence[str], contract: SubphaseContract | None
) -> tuple[Spec, ...]:
    """The ``(path, expectation)`` pairs for *test_paths*, in order.

    A path the Contract does not classify (a legacy request without a Contract) is RED, the
    only meaning such a request ever had.
    """
    expectations = {spec.path: spec.expectation for spec in contract.tests} if contract else {}
    return tuple((path, expectations.get(path, TestExpectation.RED)) for path in test_paths)


def required_changed_paths(specs: Sequence[Spec]) -> tuple[str, ...]:
    """The paths the Planner must create or change: every RED and GREEN_CHARACTERIZATION."""
    return tuple(
        path for path, expectation in specs if expectation is not TestExpectation.GREEN_REGRESSION
    )


def authoring_scope_violation(
    specs: Sequence[Spec], dirty_paths: Sequence[str], root: Path
) -> AuthoringScopeSubreason | None:
    """The first reason the Planner's dirty paths do not match the expectations, or ``None``.

    Required: ``dirty == RED + GREEN_CHARACTERIZATION``. A GREEN_REGRESSION path must be
    unchanged. Pure of Planner output beyond the filesystem and Git facts it is given.
    """
    if any(target_path_violation(path) is not None for path, _ in specs):
        return S.INVALID_TEST_TARGET

    dirty = set(dirty_paths)
    if dirty - {path for path, _ in specs}:
        return S.UNEXPECTED_PATH

    for path, _ in specs:
        if path not in dirty:
            continue
        if traverses_symlink(root, path):
            return S.SYMLINK_VIOLATION
        target = root / path
        if not target.exists():
            return S.DELETED_TEST_TARGET
        if not target.is_file():
            return S.NON_REGULAR_TEST_TARGET

    if any(
        path in dirty
        for path, expectation in specs
        if expectation is TestExpectation.GREEN_REGRESSION
    ):
        return S.GREEN_REGRESSION_MODIFIED
    for path, expectation in specs:
        if path in dirty:
            continue
        if expectation is TestExpectation.RED:
            return S.REQUIRED_RED_TARGET_UNCHANGED
        if expectation is TestExpectation.GREEN_CHARACTERIZATION:
            return S.REQUIRED_CHARACTERIZATION_TARGET_UNCHANGED
    return None


class _EvidenceModel(BaseModel):
    model_config = ConfigDict(frozen=True, extra="forbid")


class BaselineSpecEvidence(_EvidenceModel):
    """What one specification's baseline command did and whether it met its expectation."""

    path: str
    expectation: TestExpectation
    argv: Annotated[tuple[str, ...], Field(min_length=1)]
    termination: str
    exit_code: int | None
    stdout: str = ""
    stderr: str = ""
    stdout_truncated: bool = False
    stderr_truncated: bool = False
    elapsed_seconds: float | None = None
    satisfied: bool
    finding: str | None = None


class BaselineEvidenceRecord(_EvidenceModel):
    """Ordered, bounded evidence of one baseline stage; states no verdict of its own."""

    schema_version: int = _CURRENT_SCHEMA_VERSION
    run_id: RunId
    phase_id: PhaseId
    subphase_id: SubphaseId
    attempt: AttemptNumber
    max_output_bytes: Annotated[int, Field(ge=1)]
    specs: tuple[BaselineSpecEvidence, ...]

    @model_validator(mode="after")
    def _enforce_output_bound(self) -> BaselineEvidenceRecord:
        for entry in self.specs:
            for text in (entry.stdout, entry.stderr):
                if len(text.encode("utf-8")) > self.max_output_bytes:
                    raise ValueError("captured output exceeds the recorded bound")
        return self


class BaselineOutcome(_EvidenceModel):
    """The stage result: its evidence, and the first violation if any."""

    record: BaselineEvidenceRecord
    subreason: BaselineSubreason | None = None
    cause: FailureCause | None = None
    detail: str | None = None

    @property
    def satisfied(self) -> bool:
        return self.subreason is None


def run_baseline_expectations(
    specs: Sequence[Spec],
    *,
    prefix_argv: Sequence[str],
    run_id: RunId,
    phase_id: PhaseId,
    subphase_id: SubphaseId,
    attempt: AttemptNumber,
    cwd: Path,
    env: Mapping[str, str],
    timeout_seconds: float,
    max_output_bytes: int,
    termination_grace_seconds: float = 0.25,
    runner: Callable[..., ProcessResult] = run_process,
) -> BaselineOutcome:
    """Run ``prefix_argv + [path]`` per specification, stopping at the first violation."""
    entries: list[BaselineSpecEvidence] = []
    subreason: BaselineSubreason | None = None
    cause: FailureCause | None = None
    detail: str | None = None

    for path, expectation in specs:
        argv = (*prefix_argv, path)
        try:
            result = runner(
                argv,
                cwd=cwd,
                env=env,
                timeout_seconds=timeout_seconds,
                max_output_bytes=max_output_bytes,
                termination_grace_seconds=termination_grace_seconds,
            )
        except ProcessTimeoutError as exc:
            stdout, stdout_truncated = _bound(exc.stdout, max_output_bytes, exc.stdout_truncated)
            stderr, stderr_truncated = _bound(exc.stderr, max_output_bytes, exc.stderr_truncated)
            subreason = BaselineSubreason.BASELINE_COMMAND_TIMEOUT
            cause = FailureCause.ENVIRONMENT_FAILURE
            entries.append(
                BaselineSpecEvidence(
                    path=path,
                    expectation=expectation,
                    argv=argv,
                    termination="timed_out",
                    exit_code=None,
                    stdout=stdout,
                    stderr=stderr,
                    stdout_truncated=stdout_truncated,
                    stderr_truncated=stderr_truncated,
                    elapsed_seconds=exc.elapsed_seconds,
                    satisfied=False,
                    finding=subreason.value,
                )
            )
            detail = f"{subreason.value} path={path} expected={expectation.value} exit=none"
            break
        except (ProcessLaunchError, ProcessConfigurationError):
            subreason = BaselineSubreason.BASELINE_ENVIRONMENT_FAILURE
            cause = FailureCause.ENVIRONMENT_FAILURE
            entries.append(
                BaselineSpecEvidence(
                    path=path,
                    expectation=expectation,
                    argv=argv,
                    termination="launch_failed",
                    exit_code=None,
                    satisfied=False,
                    finding=subreason.value,
                )
            )
            detail = f"{subreason.value} path={path} expected={expectation.value} exit=none"
            break

        stdout, stdout_truncated = _bound(result.stdout, max_output_bytes, result.stdout_truncated)
        stderr, stderr_truncated = _bound(result.stderr, max_output_bytes, result.stderr_truncated)
        passed = result.returncode == 0
        satisfied = (not passed) if expectation is TestExpectation.RED else passed
        finding = None if satisfied else _EXPECTATION_FAILURE[expectation].value
        entries.append(
            BaselineSpecEvidence(
                path=path,
                expectation=expectation,
                argv=argv,
                termination="exited",
                exit_code=result.returncode,
                stdout=stdout,
                stderr=stderr,
                stdout_truncated=stdout_truncated,
                stderr_truncated=stderr_truncated,
                elapsed_seconds=result.elapsed_seconds,
                satisfied=satisfied,
                finding=finding,
            )
        )
        if not satisfied:
            subreason = _EXPECTATION_FAILURE[expectation]
            cause = FailureCause.TEST_DEFECT
            detail = (
                f"{subreason.value} path={path} expected={expectation.value} "
                f"exit={result.returncode}"
            )
            break

    record = BaselineEvidenceRecord(
        run_id=run_id,
        phase_id=phase_id,
        subphase_id=subphase_id,
        attempt=attempt,
        max_output_bytes=max_output_bytes,
        specs=tuple(entries),
    )
    return BaselineOutcome(record=record, subreason=subreason, cause=cause, detail=detail)


__all__ = [
    "AuthoringScopeSubreason",
    "BaselineEvidenceRecord",
    "BaselineOutcome",
    "BaselineSpecEvidence",
    "BaselineSubreason",
    "authoring_scope_violation",
    "expectation_specs",
    "required_changed_paths",
    "run_baseline_expectations",
]
