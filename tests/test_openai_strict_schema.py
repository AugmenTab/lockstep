"""Planner tests for OpenAI strict-schema normalization (Sub-phase 5.5).

These tests pin the provider-boundary transform:

    canonical provider-agnostic JSON Schema
            ↓
    to_openai_strict_json_schema
            ↓
    schema suitable for Codex --output-schema

The canonical Lockstep artifact contract remains unchanged; only the
provider adapter accommodates OpenAI Structured Outputs' stricter
requirements. The transform must never mutate its input and must never
alter canonical domain semantics.
"""

from __future__ import annotations

import copy
from collections.abc import Mapping
from typing import Any

import pytest

from lockstep.agents import (
    OpenAIStrictSchemaError,
    to_openai_strict_json_schema,
)
from lockstep.domain import ReviewDecision

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _iter_object_schemas(node: object) -> list[dict[str, Any]]:
    """Return every dict whose ``type`` is ``"object"`` reachable in *node*."""
    found: list[dict[str, Any]] = []

    def _walk(current: object) -> None:
        if isinstance(current, dict):
            if current.get("type") == "object":
                found.append(current)
            for value in current.values():
                _walk(value)
        elif isinstance(current, list):
            for item in current:
                _walk(item)

    _walk(node)
    return found


def _find_first(node: object, predicate: Any) -> dict[str, Any] | None:
    """Return the first dict satisfying *predicate*, or ``None``."""
    if isinstance(node, dict):
        if predicate(node):
            return node
        for value in node.values():
            found = _find_first(value, predicate)
            if found is not None:
                return found
    elif isinstance(node, list):
        for item in node:
            found = _find_first(item, predicate)
            if found is not None:
                return found
    return None


# ---------------------------------------------------------------------------
# Section 21 — input immutability and deep independence
# ---------------------------------------------------------------------------


def test_input_schema_is_not_mutated_and_result_is_deeply_independent() -> None:
    source: dict[str, Any] = {
        "type": "object",
        "properties": {
            "outer": {
                "type": "object",
                "properties": {
                    "opt": {
                        "anyOf": [{"type": "string"}, {"type": "null"}],
                        "default": None,
                    },
                },
                "required": [],
            },
            "list_field": {
                "type": "array",
                "items": {
                    "type": "object",
                    "properties": {"x": {"type": "integer"}},
                    "required": [],
                },
            },
        },
        "required": [],
        "$defs": {
            "Nested": {
                "type": "object",
                "properties": {"y": {"type": "string"}},
                "required": [],
            },
        },
    }
    original = copy.deepcopy(source)

    result = to_openai_strict_json_schema(source)

    assert source == original, "source schema must not be mutated"
    assert result is not source
    assert result["properties"] is not source["properties"]
    assert result["properties"]["outer"] is not source["properties"]["outer"]
    assert result["$defs"]["Nested"] is not source["$defs"]["Nested"]

    result["properties"]["outer"]["additionalProperties"] = "MUTATED"
    assert source["properties"]["outer"].get("additionalProperties") != "MUTATED"
    assert source == original


# ---------------------------------------------------------------------------
# Section 22 — root object strictness
# ---------------------------------------------------------------------------


def test_root_required_contains_every_property_in_order_and_closes_object() -> None:
    source: dict[str, Any] = {
        "type": "object",
        "properties": {
            "a": {"type": "string"},
            "b": {"type": "integer"},
            "c": {"type": "boolean"},
        },
        "required": ["a"],
    }

    result = to_openai_strict_json_schema(source)

    assert result["required"] == ["a", "b", "c"]
    assert result["additionalProperties"] is False


# ---------------------------------------------------------------------------
# Section 23 — nullable field omitted from canonical required
# ---------------------------------------------------------------------------


def test_nullable_field_becomes_required_but_retains_null_alternative() -> None:
    source: dict[str, Any] = {
        "type": "object",
        "properties": {
            "keep": {"type": "string"},
            "maybe": {
                "anyOf": [{"type": "string"}, {"type": "null"}],
                "default": None,
            },
        },
        "required": ["keep"],
    }

    result = to_openai_strict_json_schema(source)

    assert result["required"] == ["keep", "maybe"]
    maybe = result["properties"]["maybe"]
    assert "default" not in maybe
    assert isinstance(maybe.get("anyOf"), list)
    variant_types = [variant.get("type") for variant in maybe["anyOf"] if isinstance(variant, dict)]
    assert "string" in variant_types
    assert "null" in variant_types
    assert maybe.get("type") != "string"


# ---------------------------------------------------------------------------
# Section 24 — non-None defaults preserved
# ---------------------------------------------------------------------------


def test_non_none_defaults_are_preserved_verbatim() -> None:
    source: dict[str, Any] = {
        "type": "object",
        "properties": {
            "count": {"type": "integer", "default": 1},
            "tags": {"type": "array", "items": {"type": "string"}, "default": []},
            "label": {"type": "string", "default": "value"},
        },
        "required": [],
    }

    result = to_openai_strict_json_schema(source)

    assert result["properties"]["count"]["default"] == 1
    assert result["properties"]["tags"]["default"] == []
    assert result["properties"]["label"]["default"] == "value"


# ---------------------------------------------------------------------------
# Section 25 — nested $defs receive object normalization
# ---------------------------------------------------------------------------


def test_nested_defs_object_becomes_strict() -> None:
    source: dict[str, Any] = {
        "type": "object",
        "properties": {"ref_field": {"$ref": "#/$defs/Nested"}},
        "required": ["ref_field"],
        "$defs": {
            "Nested": {
                "type": "object",
                "properties": {
                    "optional_a": {"type": "string"},
                    "optional_b": {"type": "integer"},
                },
                "required": [],
            },
        },
    }

    result = to_openai_strict_json_schema(source)

    nested = result["$defs"]["Nested"]
    assert nested["required"] == ["optional_a", "optional_b"]
    assert nested["additionalProperties"] is False


def test_legacy_definitions_are_also_normalized() -> None:
    source: dict[str, Any] = {
        "type": "object",
        "properties": {"holder": {"$ref": "#/definitions/Legacy"}},
        "required": ["holder"],
        "definitions": {
            "Legacy": {
                "type": "object",
                "properties": {"m": {"type": "string"}, "n": {"type": "integer"}},
                "required": [],
            },
        },
    }

    result = to_openai_strict_json_schema(source)

    legacy = result["definitions"]["Legacy"]
    assert legacy["required"] == ["m", "n"]
    assert legacy["additionalProperties"] is False
    assert "definitions" in result
    assert "$defs" not in result


# ---------------------------------------------------------------------------
# Section 26 — arrays recurse into item objects
# ---------------------------------------------------------------------------


def test_object_schema_under_array_items_is_normalized() -> None:
    source: dict[str, Any] = {
        "type": "array",
        "items": {
            "type": "object",
            "properties": {"x": {"type": "integer"}, "y": {"type": "string"}},
            "required": ["x"],
        },
    }

    result = to_openai_strict_json_schema(source)

    item = result["items"]
    assert item["required"] == ["x", "y"]
    assert item["additionalProperties"] is False


# ---------------------------------------------------------------------------
# Section 27 — anyOf variants recurse (without collapsing null alternatives)
# ---------------------------------------------------------------------------


def test_anyof_variants_recursively_normalize_and_preserve_null_variant() -> None:
    source: dict[str, Any] = {
        "anyOf": [
            {
                "type": "object",
                "properties": {"inner": {"type": "string"}},
                "required": [],
            },
            {"type": "null"},
        ],
    }

    result = to_openai_strict_json_schema(source)

    assert isinstance(result["anyOf"], list)
    assert len(result["anyOf"]) == 2
    object_variant = result["anyOf"][0]
    null_variant = result["anyOf"][1]
    assert object_variant["required"] == ["inner"]
    assert object_variant["additionalProperties"] is False
    assert null_variant == {"type": "null"}


# ---------------------------------------------------------------------------
# Section 28 — explicit arbitrary properties rejected
# ---------------------------------------------------------------------------


def test_additional_properties_true_is_rejected() -> None:
    source: dict[str, Any] = {
        "type": "object",
        "properties": {"a": {"type": "string"}},
        "required": ["a"],
        "additionalProperties": True,
    }

    with pytest.raises(OpenAIStrictSchemaError) as exc_info:
        to_openai_strict_json_schema(source)

    error = exc_info.value
    assert "additionalProperties" in str(error) or "additional" in str(error).lower()


def test_schema_valued_additional_properties_is_rejected() -> None:
    source: dict[str, Any] = {
        "type": "object",
        "properties": {"a": {"type": "string"}},
        "required": ["a"],
        "additionalProperties": {"type": "string"},
    }

    with pytest.raises(OpenAIStrictSchemaError):
        to_openai_strict_json_schema(source)


# ---------------------------------------------------------------------------
# Section 29 — single allOf flattened
# ---------------------------------------------------------------------------


def test_single_entry_allof_is_flattened_and_normalized() -> None:
    source: dict[str, Any] = {
        "description": "wrapper",
        "allOf": [
            {
                "type": "object",
                "properties": {"p": {"type": "string"}, "q": {"type": "integer"}},
                "required": ["p"],
            },
        ],
    }

    result = to_openai_strict_json_schema(source)

    assert "allOf" not in result
    assert result.get("description") == "wrapper"
    assert result["type"] == "object"
    assert result["required"] == ["p", "q"]
    assert result["additionalProperties"] is False


# ---------------------------------------------------------------------------
# Section 30 — multi-entry allOf fails closed
# ---------------------------------------------------------------------------


def test_multi_entry_allof_is_rejected() -> None:
    source: dict[str, Any] = {
        "allOf": [
            {"type": "object", "properties": {"a": {"type": "string"}}, "required": []},
            {"type": "object", "properties": {"b": {"type": "integer"}}, "required": []},
        ],
    }

    with pytest.raises(OpenAIStrictSchemaError):
        to_openai_strict_json_schema(source)


# ---------------------------------------------------------------------------
# Section 31 — local $ref with siblings resolves without dropping siblings
# ---------------------------------------------------------------------------


def test_local_ref_with_siblings_preserves_sibling_and_normalizes_target() -> None:
    source: dict[str, Any] = {
        "type": "object",
        "properties": {
            "field": {
                "$ref": "#/$defs/Target",
                "description": "sibling-description-sentinel",
            },
        },
        "required": ["field"],
        "$defs": {
            "Target": {
                "type": "object",
                "properties": {"m": {"type": "string"}, "n": {"type": "integer"}},
                "required": ["m"],
            },
        },
    }

    result = to_openai_strict_json_schema(source)

    field = result["properties"]["field"]
    assert field.get("description") == "sibling-description-sentinel"
    # Sibling must not have been silently discarded; the referenced object
    # semantics must remain reachable (either merged in place or via a
    # normalized reference target).
    if "$ref" in field:
        target_name = field["$ref"].rsplit("/", 1)[-1]
        target = result["$defs"][target_name]
    else:
        target = field
    assert target.get("type") == "object"
    assert target["required"] == ["m", "n"]
    assert target["additionalProperties"] is False


# ---------------------------------------------------------------------------
# Section 32 — nonlocal or unresolvable $ref fails closed without I/O
# ---------------------------------------------------------------------------


def test_nonlocal_ref_with_siblings_is_rejected() -> None:
    source: dict[str, Any] = {
        "type": "object",
        "properties": {
            "field": {
                "$ref": "https://example.com/schema",
                "description": "should-not-fetch",
            },
        },
        "required": ["field"],
    }

    with pytest.raises(OpenAIStrictSchemaError):
        to_openai_strict_json_schema(source)


# ---------------------------------------------------------------------------
# Section 33 — actual ReviewDecision schema
# ---------------------------------------------------------------------------


def test_actual_review_decision_schema_becomes_strict_recursively() -> None:
    canonical = ReviewDecision.model_json_schema()
    canonical_snapshot = copy.deepcopy(canonical)

    strict = to_openai_strict_json_schema(canonical)

    assert canonical == canonical_snapshot, "canonical schema must not be mutated"

    root_props = strict.get("properties")
    assert isinstance(root_props, dict)
    assert set(strict["required"]) == set(root_props.keys())
    assert strict["required"] == list(root_props.keys())
    assert strict["additionalProperties"] is False

    review_finding = strict["$defs"]["ReviewFinding"]
    assert review_finding.get("type") == "object"
    finding_props = review_finding["properties"]
    assert set(review_finding["required"]) == set(finding_props.keys())
    assert review_finding["required"] == list(finding_props.keys())
    assert review_finding["additionalProperties"] is False

    for object_schema in _iter_object_schemas(strict):
        assert object_schema["additionalProperties"] is False
        if "properties" in object_schema:
            props = object_schema["properties"]
            assert isinstance(props, dict)
            assert object_schema["required"] == list(props.keys())


# ---------------------------------------------------------------------------
# Section 34 — nullable ReviewFinding fields still accept null
# ---------------------------------------------------------------------------


def test_actual_strict_schema_retains_nullable_semantics_for_review_finding() -> None:
    canonical = ReviewDecision.model_json_schema()
    strict = to_openai_strict_json_schema(canonical)

    review_finding = strict["$defs"]["ReviewFinding"]
    props = review_finding["properties"]

    for candidate in ("acceptance_criterion_id", "file_path"):
        node = props.get(candidate)
        assert isinstance(node, dict), f"{candidate} must remain present"
        assert "default" not in node
        variants = node.get("anyOf")
        assert isinstance(variants, list)
        variant_types = {variant.get("type") for variant in variants if isinstance(variant, dict)}
        assert "null" in variant_types
        assert "string" in variant_types


# ---------------------------------------------------------------------------
# Section 35 — canonical validator still accepts strict-shaped output
# ---------------------------------------------------------------------------


def test_review_decision_can_validate_strict_shaped_payload() -> None:
    payload: dict[str, Any] = {
        "schema_version": 1,
        "phase_id": "05",
        "subphase_id": "05",
        "attempt": 1,
        "verdict": "approve",
        "summary": "strict-shaped payload",
        "findings": [
            {
                "summary": "a note",
                "evidence": "some evidence",
                "file_path": None,
                "acceptance_criterion_id": None,
            },
        ],
    }

    decision = ReviewDecision.model_validate(payload)

    assert decision.verdict.value == "approve"
    assert decision.summary == "strict-shaped payload"
    assert len(decision.findings) == 1
    finding = decision.findings[0]
    assert finding.file_path is None
    assert finding.acceptance_criterion_id is None


# ---------------------------------------------------------------------------
# Section 36 — determinism
# ---------------------------------------------------------------------------


def test_normalization_is_deterministic_across_equal_inputs() -> None:
    def _build() -> dict[str, Any]:
        return {
            "type": "object",
            "properties": {
                "alpha": {"type": "string"},
                "beta": {"type": "integer"},
                "gamma": {
                    "anyOf": [{"type": "string"}, {"type": "null"}],
                    "default": None,
                },
            },
            "required": ["alpha"],
            "$defs": {
                "Sub": {
                    "type": "object",
                    "properties": {"one": {"type": "string"}, "two": {"type": "integer"}},
                    "required": [],
                },
            },
        }

    a = to_openai_strict_json_schema(_build())
    b = to_openai_strict_json_schema(_build())

    assert a == b
    assert a["required"] == b["required"]
    assert a["$defs"]["Sub"]["required"] == b["$defs"]["Sub"]["required"]
    assert a["required"] == ["alpha", "beta", "gamma"]
    assert a["$defs"]["Sub"]["required"] == ["one", "two"]


# ---------------------------------------------------------------------------
# Section 37 — public API surface
# ---------------------------------------------------------------------------


def test_public_api_exports_new_symbols_from_lockstep_agents() -> None:
    import lockstep.agents as agents

    assert hasattr(agents, "OpenAIStrictSchemaError")
    assert hasattr(agents, "to_openai_strict_json_schema")
    assert agents.OpenAIStrictSchemaError is OpenAIStrictSchemaError
    assert agents.to_openai_strict_json_schema is to_openai_strict_json_schema


def test_existing_public_api_surface_preserved() -> None:
    from lockstep.agents import (
        AgentAdapter,
        AgentCommand,
        AgentInvocationRequest,
        AgentInvocationResult,
        CodexAdapter,
        CodexAdapterError,
        CodexCliStatus,
        CodexPreflightError,
        invoke_agent,
        probe_codex_cli,
        require_codex_subscription_ready,
    )

    for symbol in (
        AgentAdapter,
        AgentCommand,
        AgentInvocationRequest,
        AgentInvocationResult,
        CodexAdapter,
        CodexAdapterError,
        CodexCliStatus,
        CodexPreflightError,
        invoke_agent,
        probe_codex_cli,
        require_codex_subscription_ready,
    ):
        assert symbol is not None


# ---------------------------------------------------------------------------
# Section 41 — error boundedness (no unrelated schema data leaks)
# ---------------------------------------------------------------------------


def test_error_does_not_leak_unrelated_schema_sentinel() -> None:
    source: dict[str, Any] = {
        "type": "object",
        "properties": {
            "safe": {
                "type": "string",
                "description": "UNRELATED_SENTINEL_DO_NOT_LEAK",
            },
            "open": {
                "type": "object",
                "properties": {"x": {"type": "string"}},
                "required": [],
                "additionalProperties": True,
            },
        },
        "required": ["safe", "open"],
    }

    with pytest.raises(OpenAIStrictSchemaError) as exc_info:
        to_openai_strict_json_schema(source)

    rendered = str(exc_info.value)
    assert "UNRELATED_SENTINEL_DO_NOT_LEAK" not in rendered


def test_error_exposes_bounded_path_and_reason_fields() -> None:
    source: dict[str, Any] = {
        "type": "object",
        "properties": {"x": {"type": "string"}},
        "required": ["x"],
        "additionalProperties": True,
    }

    with pytest.raises(OpenAIStrictSchemaError) as exc_info:
        to_openai_strict_json_schema(source)

    error = exc_info.value
    assert isinstance(error.reason, str)
    assert error.reason.strip() != ""
    assert isinstance(error.path, tuple)


# ---------------------------------------------------------------------------
# Return type — result is a mutable dict independent of input
# ---------------------------------------------------------------------------


def test_result_is_plain_mutable_dict_even_from_mapping_input() -> None:
    from types import MappingProxyType

    source_dict: dict[str, Any] = {
        "type": "object",
        "properties": {"a": {"type": "string"}},
        "required": ["a"],
    }
    proxy: Mapping[str, object] = MappingProxyType(source_dict)

    result = to_openai_strict_json_schema(proxy)

    assert isinstance(result, dict)
    result["extra"] = "mutation-should-not-affect-source"
    assert "extra" not in source_dict
