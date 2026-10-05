"""Phase 12.4: the canonical, Planner-constrained Implementer economy policy.

    The Planner decides what must exist.
    The Implementer uses the least machinery necessary to make it exist.

The policy is stable Implementer role policy. It is part of the canonical Implementer
instructions (``transaction_factory._IMPLEMENTER_INSTRUCTIONS``), so it leads the 12.3
stable prefix of every canonical initial and rework Implementer prompt, exactly once,
with identical bytes across attempts and Sub-phases. It is provider-neutral and adds no
model call, configuration surface, ContextSourceKind or durable state. It has no
authority over the Contract: the frozen Contract, then Planner-authorized correction /
retry authority, then this policy. Planner, Reviewer and JIT Planner prompts do not
receive it.

Legacy injected seams keep exactly the instructions the caller supplied: the host does
not force the canonical role policy into a caller-chosen ``implementer_prompt``.

Baseline classification: every test in this module is RED at entry (a777a4e has no
``_IMPLEMENTER_ECONOMY_POLICY`` / ``_IMPLEMENTER_ECONOMY_ORDER``).
"""

from __future__ import annotations

import dataclasses
from pathlib import Path

import pytest
from test_canonical_project_run import (
    _EXPANSION_FINDING,
    _Canon,
    _contract,
    _implementation,
    _make_canonical,
    _placement,
    _review,
)
from test_context_layout import (
    _contract_for,
    _implementer,
    _rework,
    stable_sources,  # noqa: F401  (pytest fixture)
)
from test_context_layout_integration import (
    _implementer_layout,
    _prepare,
    _prompts,
    _run,
)
from test_supervisor_resume_execution import _budget

import lockstep.context.context_pack as context_pack
import lockstep.phase_gate as phase_gate
import lockstep.planning_workflow as planning_workflow
import lockstep.test_authoring as test_authoring
import lockstep.transaction_factory as transaction_factory
from lockstep.agents.routing import AgentProvider, AgentRoleRoute, AgentRoutingPolicy
from lockstep.config import ProjectConfig
from lockstep.context.context_pack import (
    CONTEXT_PACK_HEADER,
    STABLE_CONTEXT_HEADER,
    ContextSourceKind,
    compose_context_prompt,
    render_context_pack,
)
from lockstep.context.context_pack_builder import (
    ContextSources,
    build_implementer_context_pack,
    build_rework_context_pack,
)
from lockstep.domain import BillingMode
from lockstep.jit_replan import _REPLAN_INSTRUCTIONS
from lockstep.project_orchestrator import (
    ProjectRunDisposition,
    TransactionPlacement,
    run_project_phase,
)
from lockstep.supervisor.transaction import SingleSubphaseTransactionRequest
from lockstep.transaction_factory import (
    _IMPLEMENTER_ECONOMY_ORDER,
    _IMPLEMENTER_ECONOMY_POLICY,
    _IMPLEMENTER_INSTRUCTIONS,
    _PLANNER_INSTRUCTIONS,
    _REVIEWER_INSTRUCTIONS,
    canonical_transaction_request_factory,
)

_POLICY = _IMPLEMENTER_ECONOMY_POLICY
_HEADING = _POLICY.strip().splitlines()[0]
_SIDS = ("01", "02", "03")

_PROVIDER_WORDS = ("claude", "codex", "opus", "sonnet", "haiku", "anthropic", "openai", "gpt")


def _lower(text: str) -> str:
    return " ".join(text.lower().split())


def _policy_offset(prompt: str) -> int:
    assert prompt.count(_POLICY) == 1
    assert prompt.count(_HEADING) == 1
    return prompt.index(_POLICY)


@pytest.fixture(scope="module")
def three_subphases(tmp_path_factory: pytest.TempPathFactory) -> _Canon:
    project = _make_canonical(tmp_path_factory.mktemp("economy-three"), sids=_SIDS)
    _prepare(project)
    _run(project)
    return project


# ===========================================================================
# A / AC-12.4-01 -- one canonical policy, part of the Implementer instructions
# ===========================================================================


def test_a_the_canonical_implementer_instructions_carry_the_policy_exactly_once() -> None:
    assert _POLICY.strip()
    assert _IMPLEMENTER_INSTRUCTIONS.count(_POLICY) == 1
    assert _IMPLEMENTER_INSTRUCTIONS.count(_HEADING) == 1
    # The accepted role statement still leads; the policy is the stable role policy after it.
    assert _IMPLEMENTER_INSTRUCTIONS.startswith(
        "You are the Lockstep Implementer for one Sub-phase."
    )
    assert _IMPLEMENTER_INSTRUCTIONS.endswith(_POLICY)


def test_a_the_accepted_implementer_role_semantics_are_kept() -> None:
    text = _lower(_IMPLEMENTER_INSTRUCTIONS)
    assert "change only the contract's allowed paths" in text
    assert "never edit the protected tests" in text
    assert "evidence only" in text


def test_a_the_canonical_factory_request_carries_the_policy_once(tmp_path: Path) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    request = canonical_transaction_request_factory(project.runtime)(
        _contract(), _placement(project)
    )

    assert request.implementer_prompt == _IMPLEMENTER_INSTRUCTIONS
    assert request.implementer_prompt.count(_POLICY) == 1


# ===========================================================================
# L / AC-12.4-05..08 -- the ordered preference hierarchy is a structured sequence
# ===========================================================================


def test_l_the_policy_order_is_the_accepted_eight_step_hierarchy() -> None:
    assert isinstance(_IMPLEMENTER_ECONOMY_ORDER, tuple)
    expected = (
        ("contract", "acceptance criteria", "mandatory"),
        ("contemplated change", "requires"),
        ("reuse", "repository"),
        ("standard library",),
        ("native platform",),
        ("dependencies", "already"),
        ("simplest direct implementation", "contract"),
        ("new abstraction", "dependency", "module", "service", "machinery", "only when"),
    )
    assert len(_IMPLEMENTER_ECONOMY_ORDER) == len(expected)
    for rule, words in zip(_IMPLEMENTER_ECONOMY_ORDER, expected, strict=True):
        assert all(word in _lower(rule) for word in words), rule


def test_l_the_policy_renders_every_step_numbered_and_in_order() -> None:
    offsets = []
    for number, rule in enumerate(_IMPLEMENTER_ECONOMY_ORDER, start=1):
        line = f"{number}. {rule}"
        assert _POLICY.count(line) == 1, line
        offsets.append(_POLICY.index(line))
    assert offsets == sorted(offsets)
    assert "later preference never overrides an earlier" in _lower(_POLICY)


# ===========================================================================
# AC-12.4-02 / 03 -- authority precedence: the Contract wins
# ===========================================================================


def test_the_policy_states_its_authority_precedence() -> None:
    text = _lower(_POLICY)
    assert "least machinery necessary" in text
    assert "precedence: the frozen contract, then" in text
    contract = text.index("precedence: the frozen contract")
    retry = text.index("retry", contract)
    policy = text.index("then this policy", contract)
    assert contract < retry < policy
    assert "the contract wins" in text
    assert "never what the work is" in text


# ===========================================================================
# I / AC-12.4-09 -- scope, tests, criteria, paths and requirements are untouchable
# ===========================================================================


@pytest.mark.parametrize(
    "forbidden",
    [
        "drop or reinterpret a requirement",
        "weaken or remove a test",
        "change the acceptance criteria",
        "shrink or expand the frozen scope",
        "change the allowed paths",
        "skip required error handling, validation, durability or documentation",
        "substitute approximate behavior for exact behavior",
        "bypass architecture or authority rules",
    ],
)
def test_i_the_policy_never_permits_weakening(forbidden: str) -> None:
    text = _lower(_POLICY)
    assert "this policy never permits you to" in text
    sentence = text[text.index("this policy never permits you to") :].split(". ")[0]
    assert forbidden in sentence


# ===========================================================================
# J / AC-12.4-10 -- avoiding contemplated changes is not refusing authorized work
# ===========================================================================


def test_j_the_policy_distinguishes_unnecessary_additions_from_refusing_authorized_work() -> None:
    text = _lower(_POLICY)
    assert "do not make a contemplated change unless the authorized work requires it" in text
    assert "never lets you refuse, drop or defer authorized work" in text
    assert "if the contract requires a new module, abstraction or dependency, build it" in text


@pytest.mark.parametrize(
    "permission",
    [
        "you may omit",
        "you may skip",
        "you may drop",
        "you may refuse",
        "you may decline",
        "optional",
    ],
)
def test_h_the_policy_grants_no_permission_to_omit_a_requirement(permission: str) -> None:
    assert permission not in _lower(_POLICY)


# ===========================================================================
# K / AC-12.4-11 -- diff size is not the objective
# ===========================================================================


def test_k_diff_size_is_not_the_objective() -> None:
    text = _lower(_POLICY)
    assert "diff size is not the objective; contract satisfaction is" in text
    assert "a larger change can be correct and a smaller one can be wrong" in text
    for metric in ("minimize lines", "minimize files", "fewest lines", "patch bytes"):
        assert metric not in text


# ===========================================================================
# §18-21 -- dependencies, abstractions, retries, tool use
# ===========================================================================


def test_dependencies_and_abstractions_are_introduced_only_when_required() -> None:
    text = _lower(_POLICY)
    assert "never add a dependency speculatively" in text
    assert "speculative generality" in text
    assert "opportunistic refactors" in text and "unrelated cleanup" in text
    assert "an abstraction is appropriate when" in text
    assert "materially prevents duplication" in text
    # "Prefer the standard library" is not absolute.
    assert "existing project library, use it" in text


def test_rework_must_perform_the_authorized_repair() -> None:
    text = _lower(_POLICY)
    assert "on a retry or rework, perform the authorized repair" in text
    assert "smallest correct repair" in text
    assert "too expensive" in text and "close enough" in text


def test_tool_economy_never_skips_required_verification() -> None:
    text = _lower(_POLICY)
    assert "redundant verification commands" in text
    assert "never skip necessary investigation or required verification" in text
    assert "the host runs its own verification regardless" in text


# ===========================================================================
# B / C / O / AC-12.4-12/13 -- stable-prefix placement, attempt identity, no duplicate
# ===========================================================================


def test_b_the_policy_is_inside_the_stable_prefix_before_the_boundary(
    stable_sources: ContextSources,  # noqa: F811
) -> None:
    layout = compose_context_prompt(
        _IMPLEMENTER_INSTRUCTIONS, build_implementer_context_pack(stable_sources, _implementer())
    )

    assert layout.stable_prefix.count(_POLICY) == 1
    assert _POLICY not in layout.volatile_suffix and _HEADING not in layout.volatile_suffix
    assert layout.text.index(_POLICY) < layout.text.index(STABLE_CONTEXT_HEADER)
    assert layout.text.index(_POLICY) < layout.text.index(CONTEXT_PACK_HEADER)


def test_c_o_initial_and_rework_carry_identical_policy_bytes_once(
    stable_sources: ContextSources,  # noqa: F811
) -> None:
    initial = compose_context_prompt(
        _IMPLEMENTER_INSTRUCTIONS, build_implementer_context_pack(stable_sources, _implementer())
    )
    reworks = [
        compose_context_prompt(
            _IMPLEMENTER_INSTRUCTIONS,
            build_rework_context_pack(stable_sources, _rework(attempt)),
            trailer="\n\nescalation resume tail",
        )
        for attempt in (2, 3)
    ]

    offset = _policy_offset(initial.text)
    for rework in reworks:
        assert _policy_offset(rework.text) == offset
        assert rework.stable_prefix == initial.stable_prefix
        assert _POLICY not in rework.volatile_suffix


# ===========================================================================
# H -- a Contract demanding new machinery is rendered unchanged after the policy
# ===========================================================================


def test_h_a_contract_requiring_new_machinery_is_rendered_unchanged(
    stable_sources: ContextSources,  # noqa: F811
) -> None:
    objective = (
        "Create the new module pkg/registry.py with a new Registry abstraction backed by the "
        "fixturedep dependency."
    )
    pack = build_implementer_context_pack(
        stable_sources, _implementer(contract=_contract_for(objective=objective))
    )
    layout = compose_context_prompt(_IMPLEMENTER_INSTRUCTIONS, pack)

    assert layout.text == _IMPLEMENTER_INSTRUCTIONS + render_context_pack(pack)
    assert render_context_pack(pack) == compose_context_prompt("", pack).text
    assert layout.volatile_suffix.count(objective) == 1
    assert layout.text.index(_POLICY) < layout.text.index(objective)


# ===========================================================================
# E / F / G / AC-12.4-14 -- Planner, Reviewer and JIT instructions are untouched
# ===========================================================================


@pytest.mark.parametrize(
    "instructions",
    [
        pytest.param(_PLANNER_INSTRUCTIONS, id="planner-test-authoring"),
        pytest.param(_REVIEWER_INSTRUCTIONS, id="reviewer"),
        pytest.param(_REPLAN_INSTRUCTIONS, id="jit-planner"),
        pytest.param(test_authoring._AUTHORING_INSTRUCTIONS, id="authoring-bridge"),
        pytest.param(planning_workflow._SUBPHASE_CONTRACT_INSTRUCTIONS, id="contract-planner"),
        pytest.param(phase_gate._REVIEW_INSTRUCTIONS, id="phase-gate"),
    ],
)
def test_efg_other_role_instructions_do_not_carry_the_policy(instructions: str) -> None:
    assert _HEADING not in instructions
    for rule in _IMPLEMENTER_ECONOMY_ORDER:
        assert rule not in instructions
    assert "least machinery" not in instructions.lower()


def test_f_the_reviewer_gains_no_economy_rejection_authority() -> None:
    text = _lower(_REVIEWER_INSTRUCTIONS)
    assert "against the frozen contract and the protected tests" in text
    assert "it never adds a requirement" in text
    for phrase in ("simpler", "smaller", "too many lines", "economy", "machinery"):
        assert phrase not in text


# ===========================================================================
# M / AC-12.4-15 -- provider-neutral
# ===========================================================================


def test_m_the_policy_names_no_provider_or_model() -> None:
    text = _POLICY.lower()
    for word in _PROVIDER_WORDS:
        assert word not in text, word


@pytest.mark.parametrize("provider", list(AgentProvider))
def test_m_provider_selection_does_not_change_the_implementer_instructions(
    tmp_path: Path, provider: AgentProvider
) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    route = AgentRoleRoute(
        provider=provider,
        model="unused-model",
        effort="unused-effort",
        billing_mode=BillingMode.SUBSCRIPTION_ONLY,
    )
    config = ProjectConfig(
        schema_version=1,
        routing=AgentRoutingPolicy(planner=route, implementer=route, reviewer=route),
        execution=project.runtime.config.execution,
    )
    runtime = dataclasses.replace(project.runtime, config=config)

    request = canonical_transaction_request_factory(runtime)(_contract(), _placement(project))

    assert request.implementer_prompt == _IMPLEMENTER_INSTRUCTIONS


# ===========================================================================
# AC-12.4-16..18 -- no new model call, durable store, ContextSourceKind or config surface
# ===========================================================================


def test_no_context_source_kind_config_or_cli_surface_is_added() -> None:
    assert not any("economy" in kind.value for kind in ContextSourceKind)
    assert "economy" not in " ".join(context_pack.__all__).lower()
    assert transaction_factory.__all__ == [
        "TransactionFactoryError",
        "canonical_transaction_request_factory",
    ]
    src = Path(transaction_factory.__file__).resolve().parent
    holders = sorted(
        path.relative_to(src).as_posix()
        for path in src.rglob("*.py")
        if "economy" in path.read_text(encoding="utf-8").lower()
    )
    assert holders == ["transaction_factory.py"]


# ===========================================================================
# Integration: the real provider stdin of a canonical three-Sub-phase run
# ===========================================================================


def test_a_b_d_every_canonical_implementer_input_carries_the_policy_once_in_the_prefix(
    three_subphases: _Canon,
) -> None:
    project = three_subphases
    recorded = _prompts(project, "implementer", "implementation")
    layouts = [_implementer_layout(project, sid) for sid in _SIDS]
    assert len(recorded) == len(_SIDS)

    offsets = {_policy_offset(prompt) for prompt in recorded}
    assert offsets == {_IMPLEMENTER_INSTRUCTIONS.index(_POLICY)}
    prefix = layouts[0].stable_prefix
    assert all(layout.stable_prefix == prefix for layout in layouts)
    assert prefix.count(_POLICY) == 1
    for prompt, layout in zip(recorded, layouts, strict=True):
        assert prompt.startswith(layout.text)
        assert prompt.index(_POLICY) < prompt.index(STABLE_CONTEXT_HEADER)
        assert _HEADING not in prompt[len(prefix) :]


@pytest.mark.parametrize(
    ("role", "operation"),
    [
        pytest.param("planner", "test_authoring", id="E-planner"),
        pytest.param("reviewer", "review", id="F-reviewer"),
        pytest.param("planner", "jit_replan", id="G-jit"),
    ],
)
def test_efg_other_canonical_role_inputs_do_not_carry_the_policy(
    three_subphases: _Canon, role: str, operation: str
) -> None:
    recorded = _prompts(three_subphases, role, operation)
    assert recorded
    for prompt in recorded:
        assert _HEADING not in prompt
        assert "least machinery" not in prompt.lower()


def test_c_o_a_canonical_rework_carries_identical_policy_bytes_once(tmp_path: Path) -> None:
    finding = {
        "summary": _EXPANSION_FINDING,
        "evidence": "requested by the reviewer",
        "file_path": None,
        "acceptance_criterion_id": None,
    }
    project = _make_canonical(
        tmp_path,
        sids=("01",),
        implementer=[
            _implementation("01", "attempt one summary"),
            _implementation("01", "attempt two summary"),
        ],
        reviewer=[
            _review("01", attempt=1, verdict="rework", findings=[finding]),
            _review("01", attempt=2, verdict="approve"),
        ],
    )
    _prepare(project)
    _run(project)

    first, second = project.prompt("implementer", 0), project.prompt("implementer", 1)
    assert _policy_offset(first) == _policy_offset(second)
    prefix = _implementer_layout(project, "01").stable_prefix
    assert first.startswith(prefix) and second.startswith(prefix)
    assert _HEADING not in second[len(prefix) :]
    assert _EXPANSION_FINDING in second[len(prefix) :]


# ===========================================================================
# N -- legacy injected seams keep exactly the caller's instructions
# ===========================================================================


def _run_injected(project: _Canon, **changes: object) -> SingleSubphaseTransactionRequest:
    canonical = canonical_transaction_request_factory(project.runtime)
    seen: list[SingleSubphaseTransactionRequest] = []

    def injected(
        contract: object, placement: TransactionPlacement
    ) -> SingleSubphaseTransactionRequest:
        request = dataclasses.replace(canonical(contract, placement), **changes)  # type: ignore[arg-type]
        seen.append(request)
        return request

    result = run_project_phase(
        project.runtime,
        retry_budget=_budget(3),
        planning_timeout_seconds=60.0,
        request_factory=injected,
    )
    assert result.disposition is ProjectRunDisposition.PHASE_GATE_READY
    [request] = seen
    return request


def test_n_an_injected_caller_prompt_is_not_given_the_canonical_policy(tmp_path: Path) -> None:
    project = _make_canonical(tmp_path, sids=("01",))
    caller = "Caller-chosen Implementer instructions."

    _run_injected(project, implementer_prompt=caller, context=None)

    prompt = project.prompt("implementer", 0)
    assert prompt.startswith(caller)
    assert _HEADING not in prompt


def test_n_an_injected_context_free_request_keeps_its_canonical_instructions_once(
    tmp_path: Path,
) -> None:
    project = _make_canonical(tmp_path, sids=("01",))

    request = _run_injected(project, context=None)

    prompt = project.prompt("implementer", 0)
    assert request.implementer_prompt == _IMPLEMENTER_INSTRUCTIONS
    assert prompt.startswith(_IMPLEMENTER_INSTRUCTIONS)
    assert CONTEXT_PACK_HEADER not in prompt
    _policy_offset(prompt)
