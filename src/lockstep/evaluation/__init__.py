"""Role / policy evaluation: structured cases, explicit arms, deterministic graders.

Answers one question with structured evidence: did a policy variant improve the desired
behavior without violating correctness, authority or scope? A case (:mod:`.cases`) is a
deterministic fixture, the task, observable expectations and finite bounds; an arm names
the one agent-facing input that differs (:mod:`.baseline` holds the authentic pre-policy
Implementer instructions). The harness (:mod:`.harness`) runs each expanded trial in an
isolated fixture repository through the ordinary canonical project runner and the
existing runtime/provider selection, graders (:mod:`.graders`) read durable evidence, and
:mod:`.results` classifies, pairs and aggregates trials deterministically.

Everything here is evaluation evidence, never project authority: it amends no Contract,
authorizes no retry or remediation, and no production module consumes it. There is no
production policy toggle and no public CLI.
"""
