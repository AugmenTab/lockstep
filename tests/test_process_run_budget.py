"""Phase 11.6: the unattended-run wall-clock budget as one shared guard at the process seam.

Every provider and command launch in Lockstep funnels through ``run_process``. The run budget
therefore lives there, once: before a launch it computes the remaining unattended time, refuses
the launch when none is left, and caps the stage timeout to what is left -- so a long
per-stage timeout can never carry a launch past the deadline, and a stop caused by the budget is
distinguishable from an ordinary timeout. ``ExecutionConfig`` is never rewritten.

Baseline classification: every test here is RED at entry (``lockstep.process.budget`` and
``RunBudgetTimeoutError`` do not exist) except the signature pin, which is GREEN_REGRESSION.
"""

from __future__ import annotations

import inspect
import sys
import time
from datetime import timedelta
from pathlib import Path

import pytest
from autonomous_run_support import FakeClock

from lockstep.process import ProcessTimeoutError, run_process
from lockstep.process.budget import RunTimeBudget, active_run_time_budget, run_time_budget
from lockstep.process.runner import RunBudgetTimeoutError

_SLEEP = (sys.executable, "-c", "import time; time.sleep(30)")


def _budget(clock: FakeClock, seconds: float) -> RunTimeBudget:
    return RunTimeBudget(deadline=clock() + timedelta(seconds=seconds), clock=clock)


def _run(argv: tuple[str, ...], tmp_path: Path, *, timeout: float) -> object:
    return run_process(argv, cwd=tmp_path, env={}, timeout_seconds=timeout)


def test_the_process_runner_signature_is_unchanged() -> None:
    assert list(inspect.signature(run_process).parameters) == [
        "argv",
        "cwd",
        "env",
        "timeout_seconds",
        "max_output_bytes",
        "termination_grace_seconds",
        "stdin_text",
        "monotonic",
        "wall_clock",
    ]


def test_remaining_time_comes_from_the_deadline_and_the_injected_clock() -> None:
    clock = FakeClock()
    budget = _budget(clock, 100)

    assert budget.remaining_seconds() == 100
    clock.advance(30)
    assert budget.remaining_seconds() == 70
    clock.advance(500)
    assert budget.remaining_seconds() == -430
    assert budget.exhausted is False  # the clock alone never marks a stop


def test_no_budget_is_active_unless_a_run_installed_one_and_the_context_restores_it() -> None:
    clock = FakeClock()
    outer, inner = _budget(clock, 100), _budget(clock, 10)
    assert active_run_time_budget() is None

    with run_time_budget(outer):
        assert active_run_time_budget() is outer
        with run_time_budget(inner):
            assert active_run_time_budget() is inner
        assert active_run_time_budget() is outer

    assert active_run_time_budget() is None


def test_the_context_is_restored_when_the_run_raises() -> None:
    with pytest.raises(RuntimeError), run_time_budget(_budget(FakeClock(), 5)):
        raise RuntimeError

    assert active_run_time_budget() is None


def test_an_expired_budget_refuses_the_launch_and_launches_nothing(tmp_path: Path) -> None:
    clock = FakeClock()
    budget = _budget(clock, 10)
    clock.advance(10)  # exactly at the deadline: nothing remains
    marker = tmp_path / "launched"
    argv = (sys.executable, "-c", f"open({str(marker)!r}, 'w').write('x')")

    with run_time_budget(budget), pytest.raises(RunBudgetTimeoutError) as refused:
        _run(argv, tmp_path, timeout=60)

    assert not marker.exists()
    assert isinstance(refused.value, ProcessTimeoutError)  # existing timeout handling still applies
    assert budget.exhausted is True


def test_remaining_time_caps_a_longer_stage_timeout_and_stops_the_operation(
    tmp_path: Path,
) -> None:
    clock = FakeClock()
    budget = _budget(clock, 1.0)
    started = time.monotonic()

    with run_time_budget(budget), pytest.raises(RunBudgetTimeoutError) as stopped:
        _run(_SLEEP, tmp_path, timeout=600)

    assert time.monotonic() - started < 20
    assert stopped.value.timeout_seconds == pytest.approx(1.0)
    assert budget.exhausted is True


def test_a_stricter_ordinary_timeout_is_not_attributed_to_the_run_budget(tmp_path: Path) -> None:
    clock = FakeClock()
    budget = _budget(clock, 1000)

    with run_time_budget(budget), pytest.raises(ProcessTimeoutError) as stopped:
        _run(_SLEEP, tmp_path, timeout=0.5)

    assert type(stopped.value) is ProcessTimeoutError
    assert stopped.value.timeout_seconds == 0.5
    assert budget.exhausted is False


def test_a_launch_that_finishes_inside_the_budget_is_unaffected(tmp_path: Path) -> None:
    clock = FakeClock()
    budget = _budget(clock, 1000)

    with run_time_budget(budget):
        result = run_process(
            (sys.executable, "-c", "print('ok')"), cwd=tmp_path, env={}, timeout_seconds=60
        )

    assert result.returncode == 0 and result.stdout.strip() == "ok"
    assert budget.exhausted is False


def test_without_a_budget_the_runner_behaves_exactly_as_before(tmp_path: Path) -> None:
    with pytest.raises(ProcessTimeoutError) as stopped:
        _run(_SLEEP, tmp_path, timeout=0.5)

    assert type(stopped.value) is ProcessTimeoutError
