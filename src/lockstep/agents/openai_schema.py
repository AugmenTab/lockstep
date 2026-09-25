"""OpenAI strict-schema provider-boundary normalization.

Transforms a canonical provider-agnostic JSON Schema into one that
satisfies OpenAI Structured Outputs' stricter presence and closure
requirements. The transform is deterministic, never mutates its input,
returns a deep independent copy, and knows only about JSON Schema —
not about :mod:`lockstep.domain`, :class:`~lockstep.agents.CodexAdapter`,
or any orchestration surface. Applied at the provider transport
boundary only.

Rules applied (Sub-phase 5.5):

* Every object schema receives ``additionalProperties: false`` when
  missing; explicit ``additionalProperties: true`` or a schema-valued
  ``additionalProperties`` fails closed with :class:`OpenAIStrictSchemaError`.
* Every object schema with a ``properties`` mapping has ``required``
  rewritten to the full list of property keys in insertion order.
* Optional fields represented by canonical omission from ``required``
  become required-but-nullable; their existing schema (typically an
  ``anyOf`` including ``{"type": "null"}``) governs which values are
  legal. Nullability is never invented.
* A bare ``"default": null`` keyword is stripped; the nullable schema
  is authoritative. Non-``None`` defaults are preserved verbatim.
* ``$defs``, ``definitions``, ``items``, ``anyOf``, and ``properties``
  are recursively normalized.
* A single-entry ``allOf`` is deterministically flattened; multi-entry
  ``allOf`` fails closed.
* A local ``$ref`` (``#/...``) with sibling schema keys is resolved
  against the root document and merged so no sibling semantics are
  silently discarded. A plain local ``$ref`` may remain a reference.
  Any non-local ``$ref`` fails closed with no network access.
"""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any

_JsonSchema = dict[str, Any]


class OpenAIStrictSchemaError(Exception):
    """Provider-boundary normalization rejected the observed JSON Schema.

    Carries the short semantic ``reason`` and the ``path`` at which the
    violation was observed. Never carries the source schema in full,
    model output, prompt text, or any credential material.
    """

    def __init__(self, *, reason: str, path: tuple[str, ...] = ()) -> None:
        self.reason = reason
        self.path = tuple(path)
        location = "/" if not self.path else "/" + "/".join(self.path)
        super().__init__(f"OpenAI strict schema error at {location}: {reason}")


def to_openai_strict_json_schema(
    schema: Mapping[str, object],
) -> dict[str, object]:
    """Return an OpenAI-strict deep-copied normalization of *schema*.

    *schema* is not mutated. The returned value is a plain ``dict``
    independent of *schema* down to every nested container.
    """
    if not isinstance(schema, Mapping):
        raise OpenAIStrictSchemaError(
            reason="top-level schema must be a mapping",
        )
    root: _JsonSchema = _deep_copy_schema(schema)
    _normalize(root, root, ())
    return root


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------


def _deep_copy_schema(node: object) -> Any:
    if isinstance(node, Mapping):
        return {key: _deep_copy_schema(value) for key, value in node.items()}
    if isinstance(node, list):
        return [_deep_copy_schema(item) for item in node]
    if isinstance(node, tuple):
        return [_deep_copy_schema(item) for item in node]
    return node


def _resolve_local_ref(
    root: _JsonSchema,
    ref: str,
    path: tuple[str, ...],
) -> _JsonSchema:
    if not ref.startswith("#/"):
        raise OpenAIStrictSchemaError(
            reason="only local $ref beginning with '#/' can be resolved",
            path=path,
        )
    current: Any = root
    for raw_segment in ref[2:].split("/"):
        segment = raw_segment.replace("~1", "/").replace("~0", "~")
        if isinstance(current, Mapping) and segment in current:
            current = current[segment]
        else:
            raise OpenAIStrictSchemaError(
                reason=f"local $ref target not found: {ref}",
                path=path,
            )
    if not isinstance(current, dict):
        raise OpenAIStrictSchemaError(
            reason=f"local $ref target is not a schema object: {ref}",
            path=path,
        )
    return current


def _normalize(
    node: _JsonSchema,
    root: _JsonSchema,
    path: tuple[str, ...],
) -> None:
    if "$ref" in node:
        ref_value = node["$ref"]
        sibling_keys = [key for key in node if key != "$ref"]
        if sibling_keys:
            if not isinstance(ref_value, str) or not ref_value.startswith("#/"):
                raise OpenAIStrictSchemaError(
                    reason="$ref with sibling keys must be a local reference",
                    path=path,
                )
            target = _deep_copy_schema(_resolve_local_ref(root, ref_value, path))
            del node["$ref"]
            for key, value in target.items():
                if key not in node:
                    node[key] = value
        else:
            if not isinstance(ref_value, str) or not ref_value.startswith("#/"):
                raise OpenAIStrictSchemaError(
                    reason="only local $ref beginning with '#/' is supported",
                    path=path,
                )
            return

    if "allOf" in node:
        all_of = node["allOf"]
        if not isinstance(all_of, list):
            raise OpenAIStrictSchemaError(
                reason="allOf must be a list of schemas",
                path=path,
            )
        if len(all_of) == 0:
            raise OpenAIStrictSchemaError(
                reason="allOf must contain at least one schema",
                path=path,
            )
        if len(all_of) != 1:
            raise OpenAIStrictSchemaError(
                reason="allOf with more than one entry is not supported",
                path=path,
            )
        single = all_of[0]
        if not isinstance(single, dict):
            raise OpenAIStrictSchemaError(
                reason="allOf entry must be a schema object",
                path=path,
            )
        del node["allOf"]
        for key, value in single.items():
            if key not in node:
                node[key] = value

    if "default" in node and node["default"] is None:
        del node["default"]

    if "anyOf" in node and isinstance(node["anyOf"], list):
        for index, variant in enumerate(node["anyOf"]):
            if isinstance(variant, dict):
                _normalize(variant, root, (*path, "anyOf", str(index)))

    if "items" in node and isinstance(node["items"], dict):
        _normalize(node["items"], root, (*path, "items"))

    if "$defs" in node and isinstance(node["$defs"], dict):
        for name, defn in node["$defs"].items():
            if isinstance(defn, dict):
                _normalize(defn, root, (*path, "$defs", name))

    if "definitions" in node and isinstance(node["definitions"], dict):
        for name, defn in node["definitions"].items():
            if isinstance(defn, dict):
                _normalize(defn, root, (*path, "definitions", name))

    if node.get("type") == "object":
        if "additionalProperties" in node:
            allowance = node["additionalProperties"]
            if allowance is True:
                raise OpenAIStrictSchemaError(
                    reason="additionalProperties: true is not permitted",
                    path=path,
                )
            if allowance is not False:
                raise OpenAIStrictSchemaError(
                    reason="schema-valued additionalProperties is not permitted",
                    path=path,
                )
        else:
            node["additionalProperties"] = False

        properties = node.get("properties")
        if isinstance(properties, dict):
            for prop_name, prop_schema in properties.items():
                if isinstance(prop_schema, dict):
                    _normalize(
                        prop_schema,
                        root,
                        (*path, "properties", prop_name),
                    )
            node["required"] = list(properties.keys())
