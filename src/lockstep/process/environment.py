"""Secret-safe environment policy for Lockstep child processes.

Constructs the exact ``env`` mapping a caller may hand to
:func:`lockstep.process.run_process`. The policy is an explicit
allowlist: only a small, exact-name baseline is inherited from the
supplied parent mapping; every other capability requires deliberate
opt-in through ``inherit_names`` or ``explicit_env``. The function is
pure — it never reads ``os.environ`` or any process-global state.
"""

from __future__ import annotations

from collections.abc import Mapping, Sequence

_SAFE_BASELINE_NAMES: tuple[str, ...] = (
    "HOME",
    "PATH",
    "TMPDIR",
    "USER",
    "LOGNAME",
    "SHELL",
    "LANG",
    "LC_ALL",
    "LC_ADDRESS",
    "LC_COLLATE",
    "LC_CTYPE",
    "LC_IDENTIFICATION",
    "LC_MEASUREMENT",
    "LC_MESSAGES",
    "LC_MONETARY",
    "LC_NAME",
    "LC_NUMERIC",
    "LC_PAPER",
    "LC_TELEPHONE",
    "LC_TIME",
    "XDG_CONFIG_HOME",
    "XDG_CACHE_HOME",
    "XDG_DATA_HOME",
    "XDG_STATE_HOME",
    "XDG_RUNTIME_DIR",
)


class EnvironmentPolicyError(Exception):
    """Environment policy rejected an input.

    Carries a human-readable ``reason`` and, when applicable, the
    offending ``variable_name``. Never carries the offending value or
    any source mapping.
    """

    def __init__(self, reason: str, *, variable_name: str | None = None) -> None:
        self.reason = reason
        self.variable_name = variable_name
        if variable_name is None:
            message = f"environment policy error: {reason}"
        else:
            message = f"environment policy error for {variable_name}: {reason}"
        super().__init__(message)


def _validate_policy_name(name: object, *, source: str) -> str:
    if not isinstance(name, str):
        raise EnvironmentPolicyError(
            f"{source} entry must be str, got {type(name).__name__}",
        )
    if name == "":
        raise EnvironmentPolicyError(f"{source} entry must not be empty")
    if "\x00" in name:
        raise EnvironmentPolicyError(
            "variable name contains NUL",
            variable_name=name.replace("\x00", "?"),
        )
    if "=" in name:
        raise EnvironmentPolicyError(
            "variable name contains '='",
            variable_name=name,
        )
    return name


def _validate_selected_value(name: str, value: object) -> str:
    if not isinstance(value, str):
        raise EnvironmentPolicyError(
            f"value must be str, got {type(value).__name__}",
            variable_name=name,
        )
    if "\x00" in value:
        raise EnvironmentPolicyError(
            "value contains NUL",
            variable_name=name,
        )
    return value


def _validate_unique_sequence(
    names: Sequence[str],
    *,
    source: str,
) -> tuple[str, ...]:
    validated: list[str] = []
    seen: set[str] = set()
    for entry in names:
        validated_name = _validate_policy_name(entry, source=source)
        if validated_name in seen:
            raise EnvironmentPolicyError(
                "duplicate inherited variable name"
                if source == "inherit_names"
                else f"duplicate {source} entry",
                variable_name=validated_name,
            )
        seen.add(validated_name)
        validated.append(validated_name)
    return tuple(validated)


def build_process_environment(
    parent_env: Mapping[str, str],
    *,
    inherit_names: Sequence[str] = (),
    explicit_env: Mapping[str, str] | None = None,
    required_names: Sequence[str] = (),
) -> dict[str, str]:
    """Return a new child environment built by explicit policy.

    The returned mapping combines a fixed safe baseline inherited from
    ``parent_env`` (only when each baseline name is present), any names
    listed in ``inherit_names`` (again only when present), and every
    entry of ``explicit_env`` (which takes precedence over inherited
    values). ``required_names`` is checked against the final mapping
    and raises :class:`EnvironmentPolicyError` if any name is absent.
    Ambient parent variables outside these selections are not inspected
    and not surfaced.
    """
    validated_inherit = _validate_unique_sequence(inherit_names, source="inherit_names")
    validated_required = _validate_unique_sequence(required_names, source="required_names")

    child: dict[str, str] = {}

    for name in _SAFE_BASELINE_NAMES:
        if name in parent_env:
            child[name] = _validate_selected_value(name, parent_env[name])

    for name in validated_inherit:
        if name in parent_env:
            child[name] = _validate_selected_value(name, parent_env[name])

    if explicit_env is not None:
        for raw_key, raw_value in explicit_env.items():
            key = _validate_policy_name(raw_key, source="explicit_env")
            child[key] = _validate_selected_value(key, raw_value)

    for name in validated_required:
        if name not in child:
            raise EnvironmentPolicyError(
                f"required variable {name} is missing",
                variable_name=name,
            )

    return dict(sorted(child.items()))
