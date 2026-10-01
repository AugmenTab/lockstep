"""Provider-neutral record of what one concrete agent invocation measurably consumed.

An :class:`InvocationUsage` is evidence, never inference. Every field has
exactly one authority source:

* HOST -- ``provider``, ``configured_model``, ``configured_effort``,
  ``started_at``, ``completed_at``, ``elapsed_seconds``, ``termination`` and
  ``exit_code``. They come from the host's routing and process runner, never
  from agent output.
* PROVIDER -- everything in :class:`ProviderTelemetry`, parsed by the concrete
  provider adapter from the provider's own structured output.
* DETERMINISTIC DERIVATION -- ``ProviderTelemetry.input_tokens`` and
  ``uncached_input_tokens``, only when exactly derivable from reported counts.

``None`` means unavailable and is never collapsed into ``0``. Quota reuses the
canonical :class:`~lockstep.domain.enums.QuotaStatus` and stays ``UNKNOWN``
unless a provider reports it. No monetary field exists: unknown cost is not
``$0`` and is never estimated. Usage is correlated to an invocation only by
the 10.1 ``invocation_id`` carried by the event that holds it and confers no
authority.
"""

from __future__ import annotations

from datetime import datetime
from typing import Annotated

from pydantic import BaseModel, ConfigDict, Field

from lockstep.domain.enums import ProcessTermination, QuotaStatus

TokenCount = Annotated[int, Field(strict=True, ge=0)]


def reported_count(value: object) -> int | None:
    """Return *value* if it is a provider-reported non-negative integer, else ``None``.

    Booleans, floats, strings and negatives are not counts; they read as
    unavailable rather than being coerced.
    """
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


class ProviderTelemetry(BaseModel):
    """Provider-reported consumption; every field defaults to unavailable (``None``).

    ``input_tokens`` is the total input processed including cache reads and
    writes; ``uncached_input_tokens``, ``cache_read_tokens`` and
    ``cache_write_tokens`` are its components where the provider exposes them.
    """

    model_config = ConfigDict(frozen=True, extra="forbid")

    reported_model: str | None = None
    provider_session_id: str | None = None
    input_tokens: TokenCount | None = None
    uncached_input_tokens: TokenCount | None = None
    cache_read_tokens: TokenCount | None = None
    cache_write_tokens: TokenCount | None = None
    output_tokens: TokenCount | None = None


class InvocationUsage(BaseModel):
    """Host-observed process facts plus provider-reported telemetry for one invocation."""

    model_config = ConfigDict(frozen=True, extra="forbid")

    provider: str
    configured_model: str | None = None
    configured_effort: str | None = None
    started_at: datetime | None = None
    completed_at: datetime | None = None
    elapsed_seconds: Annotated[float, Field(ge=0)] | None = None
    termination: ProcessTermination
    exit_code: int | None = None
    quota_status: QuotaStatus = QuotaStatus.UNKNOWN
    reported: ProviderTelemetry = Field(default_factory=ProviderTelemetry)
