"""Planner-authored specification of Sub-phase 10.3 provider/process usage attribution.

Pins the contract that each concrete agent invocation carries a provider-neutral
``InvocationUsage`` record, correlated to the 10.1 ``InvocationIdentity`` through
the existing ``INVOCATION_RETURNED`` execution event, built from three authority
sources and nothing else:

* HOST: provider (adapter name), configured model/effort, wall-clock start/end,
  monotonic elapsed time, and the process exit/termination classification.
* PROVIDER: reported model, session id and token/cache counts, parsed only by the
  concrete adapter (``ClaudeAdapter`` / ``CodexAdapter``) from the provider's
  structured output mode, below the provider-neutral boundary.
* DETERMINISTIC DERIVATION: ``input_tokens`` / ``uncached_input_tokens`` only when
  exactly derivable from reported quantities.

Unavailable telemetry is ``None`` (never ``0``); quota stays ``QuotaStatus.UNKNOWN``
because neither CLI reports it; no monetary field exists anywhere. Usage is
observational and confers no authority.

Public surface under test:

* ``lockstep.domain.InvocationUsage`` / ``ProviderTelemetry`` / ``ProcessTermination``.
* ``lockstep.process.run_process(..., monotonic=, wall_clock=)`` and the
  ``started_at`` / ``completed_at`` / ``elapsed_seconds`` fields on
  ``ProcessResult`` / ``ProcessTimeoutError``.
* ``adapter.normalize_output(process) -> AdapterOutput(content, telemetry)`` on both
  production adapters (and on the structured Planner wrapper).
* ``AgentInvocationResult.usage`` and ``ExecutionEvent.usage`` (``INVOCATION_RETURNED``
  only), plus ``record_invocation_returned(..., usage=)``.

Envelope fixtures are the exact shapes witnessed live from claude 2.1.286 and
codex-cli 0.157.0 (unused fields trimmed).

Baseline classification (pre-implementation): every test in this module is RED
(collection ``ImportError``: ``InvocationUsage`` not in ``lockstep.domain``). The
Phase 5/6 adapter suites whose argv pins moved to the structured modes are RED
until implementation; the 10.1/10.2 identity/event suites are the GREEN_REGRESSION
guard (AC-10.3-18).
"""

from __future__ import annotations

import json
import os
import stat
import sys
import textwrap
from datetime import UTC, datetime
from pathlib import Path

import pytest
from pydantic import ValidationError
from test_claude_adapter import _healthy_status as _claude_status
from test_codex_adapter import _healthy_status as _codex_status

from lockstep.agents import (
    AgentInvocationRequest,
    ClaudeAdapter,
    CodexAdapter,
    invoke_agent,
    prepare_structured_planner_adapter,
    record_invocation_returned,
)
from lockstep.domain import (
    AgentRole,
    AttemptNumber,
    BillingMode,
    ExecutionEventKind,
    ExecutionOutcome,
    InvocationIdentity,
    InvocationStage,
    InvocationUsage,
    MasterPlan,
    PhaseId,
    ProcessTermination,
    ProjectId,
    ProviderTelemetry,
    QuotaStatus,
    RunId,
    SubphaseId,
)
from lockstep.persistence import (
    ExecutionEvent,
    RunCreatedEvent,
    append_event,
    read_events,
    replay_events,
)
from lockstep.process import ProcessResult, ProcessTimeoutError, run_process

# ---------------------------------------------------------------------------
# Fixtures: witnessed provider output shapes
# ---------------------------------------------------------------------------

_CLAUDE_ENVELOPE: dict[str, object] = {
    "type": "result",
    "subtype": "success",
    "is_error": False,
    "stop_reason": "end_turn",
    "session_id": "c6c5c4b1-c517-464a-ba8c-1984004434c9",
    "total_cost_usd": 0.018853,
    "usage": {
        "input_tokens": 10,
        "cache_creation_input_tokens": 8703,
        "cache_read_input_tokens": 12420,
        "output_tokens": 39,
        "output_tokens_details": {"thinking_tokens": 32},
    },
    "modelUsage": {
        "claude-haiku-4-5-20251001": {
            "inputTokens": 10,
            "outputTokens": 39,
            "cacheReadInputTokens": 12420,
            "cacheCreationInputTokens": 8703,
            "costUSD": 0.018853,
            "costBasis": "list",
        }
    },
    "result": "ok",
}

_CODEX_JSONL = "\n".join(
    json.dumps(event)
    for event in (
        {"type": "thread.started", "thread_id": "01a0f849-d103-7271-a5b9-2165ee8755a7"},
        {"type": "turn.started"},
        {"type": "item.completed", "item": {"id": "item_0", "type": "agent_message", "text": "ok"}},
        {
            "type": "turn.completed",
            "usage": {
                "input_tokens": 14537,
                "cached_input_tokens": 12160,
                "cache_write_input_tokens": 0,
                "output_tokens": 5,
                "reasoning_output_tokens": 0,
            },
        },
    )
)


def _envelope(**overrides: object) -> str:
    return json.dumps({**_CLAUDE_ENVELOPE, **overrides})


def _process(stdout: str, *, returncode: int = 0, truncated: bool = False) -> ProcessResult:
    return ProcessResult(
        argv=("fake",),
        cwd=Path("."),
        returncode=returncode,
        stdout=stdout,
        stderr="",
        stdout_truncated=truncated,
        stderr_truncated=False,
    )


def _claude(role: AgentRole = AgentRole.IMPLEMENTER, **kwargs: str) -> ClaudeAdapter:
    return ClaudeAdapter(
        role=role,
        status=kwargs.pop("status", _claude_status()),  # type: ignore[arg-type]
        model=kwargs.pop("model", "claude-haiku-4-5-20251001"),
        effort=kwargs.pop("effort", "low"),
    )


def _codex(role: AgentRole = AgentRole.IMPLEMENTER, **kwargs: object) -> CodexAdapter:
    return CodexAdapter(
        role=role,
        status=kwargs.pop("status", _codex_status()),  # type: ignore[arg-type]
        model=kwargs.pop("model", "gpt-5"),  # type: ignore[arg-type]
        reasoning_effort=kwargs.pop("reasoning_effort", "medium"),  # type: ignore[arg-type]
        review_output_schema_path=kwargs.pop("review_output_schema_path", None),  # type: ignore[arg-type]
    )


# ---------------------------------------------------------------------------
# AC-10.3-08: unknown is distinguishable from zero
# ---------------------------------------------------------------------------


def test_provider_telemetry_defaults_every_field_to_unavailable() -> None:
    telemetry = ProviderTelemetry()
    for name in ProviderTelemetry.model_fields:
        assert getattr(telemetry, name) is None, name


def test_zero_is_distinct_from_unavailable_and_survives_round_trip() -> None:
    zero = ProviderTelemetry(output_tokens=0, cache_read_tokens=0)
    unknown = ProviderTelemetry()

    assert zero.output_tokens == 0
    assert zero.output_tokens is not None
    assert unknown.output_tokens is None
    assert zero != unknown

    restored = ProviderTelemetry.model_validate_json(zero.model_dump_json())
    assert restored.output_tokens == 0
    assert restored.input_tokens is None
    assert restored == zero


@pytest.mark.parametrize("bad", [-1, True, 1.5, "3"])
def test_token_counts_reject_negative_bool_float_and_string(bad: object) -> None:
    with pytest.raises(ValidationError):
        ProviderTelemetry.model_validate({"output_tokens": bad})


def test_unknown_telemetry_fields_are_rejected() -> None:
    with pytest.raises(ValidationError):
        ProviderTelemetry.model_validate({"output_tokens": 1, "mystery": 2})
    with pytest.raises(ValidationError):
        InvocationUsage.model_validate({"provider": "claude", "termination": "exited", "x": 1})


def test_usage_quota_defaults_to_canonical_unknown() -> None:
    usage = InvocationUsage(provider="claude", termination=ProcessTermination.EXITED)
    assert usage.quota_status is QuotaStatus.UNKNOWN
    assert InvocationUsage.model_fields["quota_status"].annotation is QuotaStatus


# ---------------------------------------------------------------------------
# AC-10.3-17: no invented dollar economics
# ---------------------------------------------------------------------------


def test_no_monetary_field_exists_in_the_usage_contract() -> None:
    names = [*InvocationUsage.model_fields, *ProviderTelemetry.model_fields]
    for name in names:
        lowered = name.lower()
        assert "cost" not in lowered, name
        assert "usd" not in lowered, name
        assert "price" not in lowered, name
        assert "dollar" not in lowered, name


def test_claude_list_price_cost_is_discarded_not_recorded() -> None:
    output = _claude().normalize_output(_process(_envelope()))
    dumped = output.telemetry.model_dump_json()
    assert "0.018853" not in dumped
    assert "cost" not in dumped.lower()
    assert "list" not in dumped


# ---------------------------------------------------------------------------
# AC-10.3-05 / 06: host process timing and termination
# ---------------------------------------------------------------------------


def test_run_process_measures_elapsed_with_the_monotonic_clock(tmp_path: Path) -> None:
    monotonic_ticks = iter([100.0, 100.75])
    wall_ticks = iter(
        [
            datetime(2026, 1, 1, 0, 0, 0, tzinfo=UTC),
            datetime(2026, 1, 1, 0, 0, 5, tzinfo=UTC),  # deliberately != monotonic delta
        ]
    )

    result = run_process(
        [sys.executable, "-c", "pass"],
        cwd=tmp_path,
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
        timeout_seconds=10,
        monotonic=lambda: next(monotonic_ticks),
        wall_clock=lambda: next(wall_ticks),
    )

    assert result.elapsed_seconds == pytest.approx(0.75)
    assert result.started_at == datetime(2026, 1, 1, 0, 0, 0, tzinfo=UTC)
    assert result.completed_at == datetime(2026, 1, 1, 0, 0, 5, tzinfo=UTC)


def test_run_process_nonzero_exit_still_carries_timing(tmp_path: Path) -> None:
    result = run_process(
        [sys.executable, "-c", "raise SystemExit(3)"],
        cwd=tmp_path,
        env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
        timeout_seconds=10,
    )
    assert result.returncode == 3
    assert result.elapsed_seconds is not None and result.elapsed_seconds >= 0
    assert result.started_at is not None and result.completed_at is not None
    assert result.started_at <= result.completed_at


def test_timeout_error_carries_elapsed_time(tmp_path: Path) -> None:
    ticks = iter([10.0, 10.4])
    with pytest.raises(ProcessTimeoutError) as excinfo:
        run_process(
            [sys.executable, "-c", "import time; time.sleep(30)"],
            cwd=tmp_path,
            env={"PATH": os.environ.get("PATH", "/usr/bin:/bin")},
            timeout_seconds=0.2,
            termination_grace_seconds=0.1,
            monotonic=lambda: next(ticks),
        )
    assert excinfo.value.elapsed_seconds == pytest.approx(0.4)
    assert excinfo.value.started_at is not None
    assert excinfo.value.completed_at is not None


# ---------------------------------------------------------------------------
# AC-10.3-09: Claude envelope normalization (below the common layer)
# ---------------------------------------------------------------------------


def test_claude_success_envelope_yields_content_and_normalized_telemetry() -> None:
    output = _claude().normalize_output(_process(_envelope()))

    assert output.content == "ok"
    telemetry = output.telemetry
    assert telemetry.uncached_input_tokens == 10
    assert telemetry.cache_write_tokens == 8703
    assert telemetry.cache_read_tokens == 12420
    assert telemetry.output_tokens == 39
    assert telemetry.input_tokens == 10 + 8703 + 12420
    assert telemetry.reported_model == "claude-haiku-4-5-20251001"
    assert telemetry.provider_session_id == "c6c5c4b1-c517-464a-ba8c-1984004434c9"


def test_claude_schema_envelope_content_is_the_result_string() -> None:
    envelope = _envelope(result='{"answer":"ok"}', structured_output={"answer": "ok"})
    output = _claude(AgentRole.REVIEWER).normalize_output(_process(envelope))
    assert json.loads(output.content) == {"answer": "ok"}


def test_claude_missing_usage_is_all_unavailable_not_zero() -> None:
    envelope = {k: v for k, v in _CLAUDE_ENVELOPE.items() if k not in ("usage", "modelUsage")}
    output = _claude().normalize_output(_process(json.dumps(envelope)))

    assert output.content == "ok"
    assert output.telemetry.output_tokens is None
    assert output.telemetry.input_tokens is None
    assert output.telemetry.cache_read_tokens is None
    assert output.telemetry.reported_model is None
    assert output.telemetry.provider_session_id == _CLAUDE_ENVELOPE["session_id"]


def test_claude_partial_usage_keeps_zero_and_leaves_the_rest_unavailable() -> None:
    output = _claude().normalize_output(_process(_envelope(usage={"output_tokens": 0})))

    assert output.telemetry.output_tokens == 0
    assert output.telemetry.uncached_input_tokens is None
    assert output.telemetry.cache_read_tokens is None
    assert output.telemetry.cache_write_tokens is None
    assert output.telemetry.input_tokens is None  # not derivable from a partial breakdown


def test_claude_multiple_models_leave_reported_model_unavailable() -> None:
    models = {
        "claude-haiku-4-5-20251001": {"inputTokens": 1},
        "claude-sonnet-5-5": {"inputTokens": 2},
    }
    output = _claude().normalize_output(_process(_envelope(modelUsage=models)))
    assert output.telemetry.reported_model is None


def test_claude_error_envelope_on_failed_exit_preserves_consumption() -> None:
    envelope = _envelope(is_error=True, subtype="error_during_execution", result="boom")
    output = _claude().normalize_output(_process(envelope, returncode=1))

    assert output.telemetry.output_tokens == 39
    assert output.telemetry.cache_read_tokens == 12420


@pytest.mark.parametrize(
    "stdout",
    [
        "plain text answer",
        '{"verdict": "approve"}',  # a bare artifact, not a result envelope
        '{"type": "result", "result": ',  # truncated envelope
        "",
        "[1, 2, 3]",
    ],
)
def test_claude_non_envelope_stdout_passes_through_unchanged(stdout: str) -> None:
    output = _claude().normalize_output(_process(stdout))
    assert output.content == stdout
    assert output.telemetry == ProviderTelemetry()


# ---------------------------------------------------------------------------
# AC-10.3-10: Codex JSONL normalization
# ---------------------------------------------------------------------------


def test_codex_jsonl_yields_content_and_normalized_telemetry() -> None:
    output = _codex().normalize_output(_process(_CODEX_JSONL))

    assert output.content == "ok"
    telemetry = output.telemetry
    assert telemetry.input_tokens == 14537
    assert telemetry.cache_read_tokens == 12160
    assert telemetry.cache_write_tokens == 0
    assert telemetry.uncached_input_tokens == 14537 - 12160
    assert telemetry.output_tokens == 5
    assert telemetry.provider_session_id == "01a0f849-d103-7271-a5b9-2165ee8755a7"
    assert telemetry.reported_model is None  # the CLI does not expose it


def test_codex_final_message_is_the_last_agent_message() -> None:
    lines = [
        {"type": "item.completed", "item": {"type": "agent_message", "text": "working on it"}},
        {"type": "item.completed", "item": {"type": "command_execution", "text": "ls"}},
        {"type": "item.completed", "item": {"type": "agent_message", "text": '{"a": 1}'}},
    ]
    output = _codex().normalize_output(_process("\n".join(json.dumps(x) for x in lines)))
    assert output.content == '{"a": 1}'
    assert output.telemetry == ProviderTelemetry()


def test_codex_unexposed_cache_fields_stay_unavailable() -> None:
    usage = {"input_tokens": 100, "output_tokens": 7}
    lines = [
        {"type": "item.completed", "item": {"type": "agent_message", "text": "x"}},
        {"type": "turn.completed", "usage": usage},
    ]
    output = _codex().normalize_output(_process("\n".join(json.dumps(x) for x in lines)))

    assert output.telemetry.input_tokens == 100
    assert output.telemetry.output_tokens == 7
    assert output.telemetry.cache_read_tokens is None
    assert output.telemetry.cache_write_tokens is None
    assert output.telemetry.uncached_input_tokens is None  # cannot derive without cached


def test_codex_inconsistent_cached_count_is_not_derived() -> None:
    usage = {"input_tokens": 10, "cached_input_tokens": 99, "output_tokens": 1}
    lines = [{"type": "turn.completed", "usage": usage}]
    output = _codex().normalize_output(_process("\n".join(json.dumps(x) for x in lines)))

    assert output.telemetry.cache_read_tokens == 99
    assert output.telemetry.uncached_input_tokens is None


def test_codex_reported_zero_is_preserved() -> None:
    usage = {"input_tokens": 4, "cached_input_tokens": 0, "output_tokens": 0}
    lines = [{"type": "turn.completed", "usage": usage}]
    output = _codex().normalize_output(_process("\n".join(json.dumps(x) for x in lines)))

    assert output.telemetry.output_tokens == 0
    assert output.telemetry.cache_read_tokens == 0
    assert output.telemetry.uncached_input_tokens == 4


def test_codex_tolerates_a_tail_truncated_first_line() -> None:
    truncated = _CODEX_JSONL.splitlines()
    truncated[0] = truncated[0][10:]  # tail-bounded capture can cut the stream head
    output = _codex().normalize_output(_process("\n".join(truncated)))
    assert output.content == "ok"
    assert output.telemetry.output_tokens == 5
    assert output.telemetry.provider_session_id is None


@pytest.mark.parametrize("stdout", ["plain text answer", '{"verdict": "approve"}', ""])
def test_codex_non_jsonl_stdout_passes_through_unchanged(stdout: str) -> None:
    output = _codex().normalize_output(_process(stdout))
    assert output.content == stdout
    assert output.telemetry == ProviderTelemetry()


# ---------------------------------------------------------------------------
# AC-10.3-11: provider asymmetry; AC-10.3-13: quota vocabulary
# ---------------------------------------------------------------------------


def test_providers_expose_different_subsets_without_schema_failure() -> None:
    claude = _claude().normalize_output(_process(_envelope())).telemetry
    codex = _codex().normalize_output(_process(_CODEX_JSONL)).telemetry

    assert claude.reported_model is not None and codex.reported_model is None
    assert claude.cache_write_tokens == 8703
    for telemetry in (claude, codex):
        assert ProviderTelemetry.model_validate_json(telemetry.model_dump_json()) == telemetry


# ---------------------------------------------------------------------------
# Integration harness: fake provider executables through invoke_agent
# ---------------------------------------------------------------------------


def _fake_cli(root: Path, name: str, *, stdout: str, exit_code: int = 0, sleep: float = 0) -> Path:
    directory = root / f"fake-{name}"
    directory.mkdir(parents=True, exist_ok=True)
    executable = directory / name
    (directory / "stdout.txt").write_text(stdout, encoding="utf-8")
    executable.write_text(
        textwrap.dedent(
            f"""\
            #!{sys.executable}
            import sys, time
            from pathlib import Path
            sys.stdin.buffer.read()
            time.sleep({sleep!r})
            sys.stdout.write((Path(__file__).resolve().parent / "stdout.txt").read_text())
            raise SystemExit({exit_code})
            """
        ),
        encoding="utf-8",
    )
    executable.chmod(executable.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
    return executable


def _parent_env() -> dict[str, str]:
    return {
        "HOME": os.environ.get("HOME", "/tmp"),
        "PATH": os.environ.get("PATH", "/usr/bin:/bin"),
    }


def _identity(
    *, attempt: int = 1, role: AgentRole = AgentRole.IMPLEMENTER, run: str = "run-1"
) -> InvocationIdentity:
    return InvocationIdentity.issue(
        run_id=RunId.model_validate(run),
        phase_id=PhaseId.model_validate("10"),
        subphase_id=SubphaseId.model_validate("03"),
        attempt=AttemptNumber.model_validate(attempt),
        role=role,
        stage=InvocationStage.IMPLEMENTATION
        if role is AgentRole.IMPLEMENTER
        else InvocationStage.REVIEW,
    )


def _request(
    cwd: Path,
    *,
    role: AgentRole = AgentRole.IMPLEMENTER,
    identity: InvocationIdentity | None = None,
    timeout: float = 10,
) -> AgentInvocationRequest:
    return AgentInvocationRequest(
        role=role,
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
        prompt="prompt",
        cwd=cwd,
        timeout_seconds=timeout,
        termination_grace_seconds=0.1,
        identity=identity,
    )


def _runtime_with_journal(root: Path, *, run: str = "run-1") -> Path:
    runtime_dir = root / "runtime"
    runtime_dir.mkdir()
    append_event(
        runtime_dir / "events.jsonl",
        RunCreatedEvent(
            run_id=RunId.model_validate(run),
            sequence=1,
            occurred_at=datetime.now(UTC),
            project_id=ProjectId.model_validate("lockstep"),
        ),
    )
    return runtime_dir


def _returned(runtime_dir: Path) -> list[ExecutionEvent]:
    return [
        e
        for e in read_events(runtime_dir / "events.jsonl")
        if isinstance(e, ExecutionEvent) and e.kind is ExecutionEventKind.INVOCATION_RETURNED
    ]


# ---------------------------------------------------------------------------
# AC-10.3-02/03/04/05/06/09: one Claude invocation end to end
# ---------------------------------------------------------------------------


def test_claude_invocation_result_carries_content_and_usage(tmp_path: Path) -> None:
    executable = _fake_cli(tmp_path, "claude", stdout=_envelope())
    adapter = _claude(status=_claude_status(executable=str(executable)), effort="high")

    result = invoke_agent(adapter, _request(tmp_path), parent_env=_parent_env())

    assert result.process.stdout == "ok"  # orchestrators never see the envelope
    usage = result.usage
    assert usage is not None
    assert usage.provider == "claude"
    assert usage.configured_model == "claude-haiku-4-5-20251001"
    assert usage.configured_effort == "high"
    assert usage.termination is ProcessTermination.EXITED
    assert usage.exit_code == 0
    assert usage.elapsed_seconds is not None and usage.elapsed_seconds >= 0
    assert usage.started_at is not None and usage.completed_at is not None
    assert usage.started_at <= usage.completed_at
    assert usage.quota_status is QuotaStatus.UNKNOWN
    assert usage.reported.output_tokens == 39
    assert usage.reported.reported_model == "claude-haiku-4-5-20251001"


def test_conflicting_reported_model_is_preserved_beside_the_configured_one(
    tmp_path: Path,
) -> None:
    executable = _fake_cli(tmp_path, "claude", stdout=_envelope())
    adapter = _claude(status=_claude_status(executable=str(executable)), model="claude-opus-9")

    result = invoke_agent(adapter, _request(tmp_path), parent_env=_parent_env())

    assert result.usage is not None
    assert result.usage.configured_model == "claude-opus-9"  # host routing is never rewritten
    assert result.usage.reported.reported_model == "claude-haiku-4-5-20251001"


def test_codex_invocation_result_carries_content_and_usage(tmp_path: Path) -> None:
    executable = _fake_cli(tmp_path, "codex", stdout=_CODEX_JSONL)
    adapter = _codex(
        status=_codex_status(executable=str(executable)),
        model="gpt-5.5",
        reasoning_effort="xhigh",
    )

    result = invoke_agent(adapter, _request(tmp_path), parent_env=_parent_env())

    assert result.process.stdout == "ok"
    usage = result.usage
    assert usage is not None
    assert usage.provider == "codex"
    assert usage.configured_model == "gpt-5.5"
    assert usage.configured_effort == "xhigh"
    assert usage.reported.input_tokens == 14537
    assert usage.reported.uncached_input_tokens == 2377
    assert usage.reported.reported_model is None
    assert usage.quota_status is QuotaStatus.UNKNOWN


def test_adapter_without_usage_support_still_attributes_host_known_facts(tmp_path: Path) -> None:
    class _BareAdapter:
        name = "bare"

        def build_command(self, request: AgentInvocationRequest):  # type: ignore[no-untyped-def]
            from lockstep.agents import AgentCommand

            return AgentCommand(
                argv=(sys.executable, "-c", "print('hi')"), required_names=("PATH",)
            )

    result = invoke_agent(_BareAdapter(), _request(tmp_path), parent_env=_parent_env())

    assert result.process.stdout.strip() == "hi"
    assert result.usage is not None
    assert result.usage.provider == "bare"
    assert result.usage.configured_model is None
    assert result.usage.configured_effort is None
    assert result.usage.exit_code == 0
    assert result.usage.reported == ProviderTelemetry()


def test_structured_planner_wrapper_still_normalizes_and_attributes(tmp_path: Path) -> None:
    executable = _fake_cli(tmp_path, "claude", stdout=_envelope(result='{"x": 1}'))
    base = _claude(AgentRole.PLANNER, status=_claude_status(executable=str(executable)))
    structured = prepare_structured_planner_adapter(
        base,
        canonical_schema=MasterPlan.model_json_schema(),
        runtime_dir=tmp_path / "rt",
        schema_name="master-plan",
    )

    result = invoke_agent(
        structured, _request(tmp_path, role=AgentRole.PLANNER), parent_env=_parent_env()
    )

    assert result.process.stdout == '{"x": 1}'
    assert result.usage is not None
    assert result.usage.provider == "claude"
    assert result.usage.configured_model == "claude-haiku-4-5-20251001"
    assert result.usage.reported.output_tokens == 39


# ---------------------------------------------------------------------------
# AC-10.3-01 / 16: correlation to the canonical identity through the journal
# ---------------------------------------------------------------------------


@pytest.mark.parametrize("attempt", [1, 2])
def test_usage_rides_the_returned_event_keyed_by_the_canonical_invocation_id(
    tmp_path: Path, attempt: int
) -> None:
    executable = _fake_cli(tmp_path, "claude", stdout=_envelope())
    adapter = _claude(status=_claude_status(executable=str(executable)))
    runtime_dir = _runtime_with_journal(tmp_path)
    identity = _identity(attempt=attempt)

    result = invoke_agent(
        adapter,
        _request(tmp_path, identity=identity),
        parent_env=_parent_env(),
        runtime_dir=runtime_dir,
    )

    returned = _returned(runtime_dir)
    assert len(returned) == 1  # attributable exactly once
    event = returned[0]
    assert event.invocation_id == identity.invocation_id
    assert event.attempt == AttemptNumber.model_validate(attempt)
    assert event.outcome is ExecutionOutcome.SUCCESS
    assert event.usage == result.usage
    assert event.usage is not None
    assert event.usage.reported.output_tokens == 39
    assert "invocation_id" not in InvocationUsage.model_fields  # no second identity


def test_usage_survives_reload_without_mutation_or_duplication(tmp_path: Path) -> None:
    executable = _fake_cli(tmp_path, "codex", stdout=_CODEX_JSONL)
    adapter = _codex(status=_codex_status(executable=str(executable)))
    runtime_dir = _runtime_with_journal(tmp_path)
    identity = _identity()

    invoke_agent(
        adapter,
        _request(tmp_path, identity=identity),
        parent_env=_parent_env(),
        runtime_dir=runtime_dir,
    )

    first = _returned(runtime_dir)
    second = _returned(runtime_dir)
    assert first == second
    assert len(first) == 1
    assert first[0].usage is not None
    assert first[0].usage.reported.cache_read_tokens == 12160
    assert first[0].usage.reported.reported_model is None  # unavailable stays unavailable


def test_caller_recorded_return_carries_the_same_usage_once(tmp_path: Path) -> None:
    executable = _fake_cli(tmp_path, "claude", stdout=_envelope())
    adapter = _claude(status=_claude_status(executable=str(executable)))
    runtime_dir = _runtime_with_journal(tmp_path)
    identity = _identity()

    result = invoke_agent(
        adapter,
        _request(tmp_path, identity=identity),
        parent_env=_parent_env(),
        runtime_dir=runtime_dir,
        record_return=False,
    )
    assert _returned(runtime_dir) == []

    record_invocation_returned(
        runtime_dir,
        identity,
        outcome=ExecutionOutcome.BLOCKED,
        returncode=result.process.returncode,
        usage=result.usage,
    )

    returned = _returned(runtime_dir)
    assert len(returned) == 1
    assert returned[0].outcome is ExecutionOutcome.BLOCKED
    assert returned[0].usage == result.usage


def test_no_usage_event_is_written_without_an_identity_or_journal(tmp_path: Path) -> None:
    executable = _fake_cli(tmp_path, "claude", stdout=_envelope())
    adapter = _claude(status=_claude_status(executable=str(executable)))
    runtime_dir = _runtime_with_journal(tmp_path)

    result = invoke_agent(
        adapter, _request(tmp_path), parent_env=_parent_env(), runtime_dir=runtime_dir
    )

    assert result.usage is not None  # still returned to the caller
    assert _returned(runtime_dir) == []


# ---------------------------------------------------------------------------
# AC-10.3-14 / 06: failed invocations remain attributable
# ---------------------------------------------------------------------------


def test_nonzero_exit_keeps_exit_status_and_observed_provider_usage(tmp_path: Path) -> None:
    envelope = _envelope(is_error=True, subtype="error_during_execution", result="boom")
    executable = _fake_cli(tmp_path, "claude", stdout=envelope, exit_code=1)
    adapter = _claude(status=_claude_status(executable=str(executable)))
    runtime_dir = _runtime_with_journal(tmp_path)
    identity = _identity()

    result = invoke_agent(
        adapter,
        _request(tmp_path, identity=identity),
        parent_env=_parent_env(),
        runtime_dir=runtime_dir,
    )

    assert result.process.returncode == 1
    (event,) = _returned(runtime_dir)
    assert event.outcome is ExecutionOutcome.FAILURE
    assert event.returncode == 1
    assert event.usage is not None
    assert event.usage.exit_code == 1
    assert event.usage.termination is ProcessTermination.EXITED
    assert event.usage.reported.output_tokens == 39  # consumption before failure is retained
    assert event.usage.reported.cache_read_tokens == 12420


def test_malformed_provider_output_is_attributed_with_unavailable_telemetry(
    tmp_path: Path,
) -> None:
    executable = _fake_cli(tmp_path, "claude", stdout="not an envelope at all")
    adapter = _claude(status=_claude_status(executable=str(executable)))
    runtime_dir = _runtime_with_journal(tmp_path)
    identity = _identity()

    invoke_agent(
        adapter,
        _request(tmp_path, identity=identity),
        parent_env=_parent_env(),
        runtime_dir=runtime_dir,
    )

    (event,) = _returned(runtime_dir)
    assert event.usage is not None
    assert event.usage.provider == "claude"
    assert event.usage.exit_code == 0
    assert event.usage.reported == ProviderTelemetry()  # unknown, not zero


def test_timeout_records_failure_with_timing_and_no_invented_exit_status(tmp_path: Path) -> None:
    executable = _fake_cli(tmp_path, "claude", stdout=_envelope(), sleep=30)
    adapter = _claude(status=_claude_status(executable=str(executable)))
    runtime_dir = _runtime_with_journal(tmp_path)
    identity = _identity()

    with pytest.raises(ProcessTimeoutError):
        invoke_agent(
            adapter,
            _request(tmp_path, identity=identity, timeout=0.3),
            parent_env=_parent_env(),
            runtime_dir=runtime_dir,
        )

    (event,) = _returned(runtime_dir)
    assert event.outcome is ExecutionOutcome.FAILURE
    assert event.usage is not None
    assert event.usage.provider == "claude"
    assert event.usage.termination is ProcessTermination.TIMED_OUT
    assert event.usage.exit_code is None
    assert event.usage.elapsed_seconds is not None and event.usage.elapsed_seconds >= 0.3
    assert event.usage.reported == ProviderTelemetry()


# ---------------------------------------------------------------------------
# AC-10.3-15: usage is observational
# ---------------------------------------------------------------------------


def test_forged_usage_cannot_change_replayed_workflow_state(tmp_path: Path) -> None:
    runtime_dir = _runtime_with_journal(tmp_path)
    journal = runtime_dir / "events.jsonl"
    before = replay_events(read_events(journal))
    identity = _identity()

    forged = InvocationUsage(
        provider="claude",
        termination=ProcessTermination.EXITED,
        exit_code=0,
        reported=ProviderTelemetry(output_tokens=10**12, input_tokens=0),
    )
    append_event(
        journal,
        ExecutionEvent(
            run_id=identity.run_id,
            sequence=2,
            occurred_at=datetime.now(UTC),
            kind=ExecutionEventKind.INVOCATION_RETURNED,
            outcome=ExecutionOutcome.SUCCESS,
            phase_id=identity.phase_id,
            subphase_id=identity.subphase_id,
            attempt=identity.attempt,
            role=identity.role,
            stage=identity.stage,
            invocation_id=identity.invocation_id,
            usage=forged,
        ),
    )

    after = replay_events(read_events(journal))
    assert after.workflow_state == before.workflow_state
    assert after.run_id == before.run_id
    assert after.last_sequence == before.last_sequence + 1


def test_usage_is_only_valid_on_invocation_returned_events() -> None:
    identity = _identity()
    with pytest.raises(ValidationError):
        ExecutionEvent(
            run_id=identity.run_id,
            sequence=2,
            occurred_at=datetime.now(UTC),
            kind=ExecutionEventKind.INVOCATION_STARTED,
            phase_id=identity.phase_id,
            subphase_id=identity.subphase_id,
            attempt=identity.attempt,
            role=identity.role,
            stage=identity.stage,
            invocation_id=identity.invocation_id,
            usage=InvocationUsage(provider="claude", termination=ProcessTermination.EXITED),
        )
    with pytest.raises(ValidationError):
        ExecutionEvent(
            run_id=identity.run_id,
            sequence=2,
            occurred_at=datetime.now(UTC),
            kind=ExecutionEventKind.RETRY_AUTHORIZED,
            usage=InvocationUsage(provider="claude", termination=ProcessTermination.EXITED),
        )


# ---------------------------------------------------------------------------
# AC-10.3-09 / 12 / 17: provider-neutral boundary and billing safety (structural)
# ---------------------------------------------------------------------------

_SRC = Path(__file__).resolve().parent.parent / "src" / "lockstep"
_PROVIDER_PARSER_FILES = {
    _SRC / "agents" / "claude.py",
    _SRC / "agents" / "codex.py",
}
_PROVIDER_SHAPE_TOKENS = (
    "modelUsage",
    '"cache_read_input_tokens"',
    '"cache_creation_input_tokens"',
    '"cached_input_tokens"',  # quoted: the normalized "uncached_input_tokens" is not a provider key
    "turn.completed",
    "thread.started",
    "agent_message",
)


def test_provider_response_shapes_are_parsed_only_inside_the_provider_adapters() -> None:
    offenders: list[str] = []
    for path in sorted(_SRC.rglob("*.py")):
        if path in _PROVIDER_PARSER_FILES:
            continue
        text = path.read_text(encoding="utf-8")
        offenders.extend(
            f"{path.name}: {token}" for token in _PROVIDER_SHAPE_TOKENS if token in text
        )
    assert offenders == []


def test_no_dollar_cost_is_read_or_computed_anywhere_in_production() -> None:
    offenders: list[str] = []
    for path in sorted(_SRC.rglob("*.py")):
        text = path.read_text(encoding="utf-8")
        offenders.extend(
            f"{path.name}: {token}"
            for token in ("total_cost_usd", "costUSD", "costBasis", "cost_usd")
            if token in text
        )
    assert offenders == []
