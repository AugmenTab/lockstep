"""Phase 11.4: the complete Contract verification stack, run without a shell.

Each ``SubphaseContract.verification_commands`` string is split with
``shlex`` into argv and executed directly, in order, stopping at the first
failure. The whole stack is one verification *stage*: it yields exactly one
domain ``VerificationReport`` (the semantic result) plus one bounded
``VerificationEvidenceRecord`` sidecar (ordered per-command process evidence).
Neither carries Contract authority.

Baseline classification: every test in this module is RED at entry
(``lockstep.verification_stack`` does not exist).
"""

from __future__ import annotations

import os
import shlex
import sys
from pathlib import Path

import pytest
from pydantic import ValidationError

from lockstep.domain import AttemptNumber, PhaseId, RunId, SubphaseId, VerificationReport
from lockstep.verification_stack import (
    CommandEvidence,
    VerificationCommandError,
    VerificationEvidenceRecord,
    parse_verification_command,
    parse_verification_stack,
    run_verification_stack,
)

_RUN = RunId.model_validate("run-01-01")
_PHASE = PhaseId.model_validate("01")
_SUBPHASE = SubphaseId.model_validate("01")
_ATTEMPT = AttemptNumber.model_validate(1)


def _run(
    commands: tuple[tuple[str, ...], ...],
    cwd: Path,
    *,
    max_output_bytes: int = 65536,
) -> tuple[VerificationReport, VerificationEvidenceRecord]:
    result = run_verification_stack(
        commands,
        run_id=_RUN,
        phase_id=_PHASE,
        subphase_id=_SUBPHASE,
        attempt=_ATTEMPT,
        cwd=cwd,
        env=dict(os.environ),
        timeout_seconds=30.0,
        max_output_bytes=max_output_bytes,
        termination_grace_seconds=0.25,
    )
    return result.report, result.evidence


def _py(code: str, *args: str) -> tuple[str, ...]:
    return (sys.executable, "-c", code, *args)


# --- parsing ----------------------------------------------------------------------------


def test_a_verification_string_becomes_direct_argv() -> None:
    assert parse_verification_command("pytest -q tests/a.py") == ("pytest", "-q", "tests/a.py")


def test_quoting_is_honored_without_a_shell() -> None:
    assert parse_verification_command('python -m pytest "tests/a b.py"') == (
        "python",
        "-m",
        "pytest",
        "tests/a b.py",
    )


@pytest.mark.parametrize(
    "text",
    [
        "",
        "   ",
        "pytest && ruff check",
        "pytest || true",
        "pytest ; rm -rf build",
        "pytest | tee out.txt",
        "pytest > out.txt",
        "pytest < in.txt",
        "pytest &",
        "echo $(whoami)",
        "echo `whoami`",
        "pytest 'unterminated",
    ],
)
def test_shell_syntax_and_malformed_commands_are_rejected(text: str) -> None:
    with pytest.raises(VerificationCommandError):
        parse_verification_command(text)


def test_a_stack_keeps_contract_order_and_one_bad_command_rejects_the_whole_stack() -> None:
    assert parse_verification_stack(("a one", "b two")) == (("a", "one"), ("b", "two"))
    with pytest.raises(VerificationCommandError):
        parse_verification_stack(("a one", "b && c"))


# --- execution ----------------------------------------------------------------------------


def test_every_command_runs_in_order_and_yields_one_report_and_one_record(tmp_path: Path) -> None:
    order = tmp_path / "order.txt"
    append = "import sys, pathlib; pathlib.Path(sys.argv[1]).open('a').write(sys.argv[2])"
    commands = tuple(_py(append, str(order), tag) for tag in ("1", "2", "3"))

    report, evidence = _run(commands, tmp_path)

    assert order.read_text() == "123"
    assert report.passed is True
    assert report.failures == ()
    assert report.commands == tuple(shlex.join(argv) for argv in commands)
    assert (report.phase_id, report.subphase_id, report.attempt) == (_PHASE, _SUBPHASE, _ATTEMPT)
    assert [entry.argv for entry in evidence.commands] == [tuple(c) for c in commands]
    assert [entry.exit_code for entry in evidence.commands] == [0, 0, 0]
    assert evidence.run_id == _RUN and evidence.attempt == _ATTEMPT


def test_the_first_failure_stops_later_commands_and_is_recorded(tmp_path: Path) -> None:
    marker = tmp_path / "third-ran.txt"
    commands = (
        _py("print('first')"),
        _py("import sys; print('second'); sys.stderr.write('boom'); raise SystemExit(3)"),
        _py("import pathlib, sys; pathlib.Path(sys.argv[1]).write_text('x')", str(marker)),
    )

    report, evidence = _run(commands, tmp_path)

    assert not marker.exists()
    assert report.passed is False
    assert len(report.failures) == 1
    assert "3" in report.failures[0].observation
    assert report.commands == tuple(shlex.join(argv) for argv in commands[:2])
    assert [entry.exit_code for entry in evidence.commands] == [0, 3]
    assert evidence.commands[1].stdout.strip() == "second"
    assert evidence.commands[1].stderr == "boom"


def test_arguments_are_passed_literally_so_no_shell_semantics_exist(tmp_path: Path) -> None:
    report, evidence = _run((_py("import sys; print(sys.argv[1])", "a && b $HOME"),), tmp_path)

    assert report.passed is True
    assert evidence.commands[0].stdout.strip() == "a && b $HOME"


def test_captured_output_is_bounded_and_flagged(tmp_path: Path) -> None:
    _, evidence = _run((_py("print('x' * 10000)"),), tmp_path, max_output_bytes=64)

    entry = evidence.commands[0]
    assert len(entry.stdout.encode("utf-8")) <= 64
    assert entry.stdout_truncated is True
    assert evidence.max_output_bytes == 64


def test_the_evidence_record_refuses_unbounded_output() -> None:
    with pytest.raises(ValidationError):
        VerificationEvidenceRecord(
            run_id=_RUN,
            phase_id=_PHASE,
            subphase_id=_SUBPHASE,
            attempt=_ATTEMPT,
            max_output_bytes=8,
            commands=(
                CommandEvidence(
                    argv=("x",),
                    exit_code=0,
                    stdout="y" * 9,
                    stderr="",
                    stdout_truncated=False,
                    stderr_truncated=False,
                ),
            ),
        )


def test_the_evidence_record_is_not_a_second_verification_report() -> None:
    assert VerificationEvidenceRecord is not VerificationReport
    assert not issubclass(VerificationEvidenceRecord, VerificationReport)
    assert "passed" not in VerificationEvidenceRecord.model_fields
