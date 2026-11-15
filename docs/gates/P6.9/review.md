# Review — C-P6.9 Human-controlled improvement proposals

- Reviewed: `a8e74d7` (implementation) against `docs/gates/P6.9/contract.md` and the frozen tests of `7742f51`.
- Reviewer: an independent read-only agent (no edits, builds or tests), 2026-11-15. The Implementer does not
  accept this subphase.
- Held: canonical text (proposer and key excluded, everything in P2 included), private vs shared digests,
  serialization (`LOCK … IN EXCLUSIVE MODE` plus the unique key, digest and decision keys), migration constraints
  matching the application's checks, immutability triggers, P4 listing, P6 (a decision writes only its row), and
  the simple-Haskell rules.

## Findings and dispositions

| # | Severity | Finding | Disposition (R-P6.9) |
|---|---|---|---|
| R-P6.9-1 | High (P2) | Evidence is parsed but never resolved: `fix:a`, `commit:trust-me` are accepted, so evidence is free text in practice and support can be inflated. | Fix: every link must resolve inside the proposing transaction: `fix:` an existing fix; `record:ID:N` that fix's record N; `invalidation:` an invalidation of that fix; `request:` an existing request. Otherwise refused `evidence-unknown`. **Limited:** `commit:` is checked for form only (a full 40-hex SHA): the frozen C-P6.9 tests' shared fixture cites a well-formed SHA no fix recorded, so requiring a recorded commit needs the owner's authority to amend them. |
| R-P6.9-2 | High (P2) | The same link in another spelling (upper-case UUID; a short SHA) counts twice and changes the digest. | Fix: links are stored in their canonical spelling (lower-case UUID text, the recorded full SHA), so duplicates count once and digest once. |
| R-P6.9-3 | Medium | Stored evidence does not round-trip: an id with a space (`record:a b:3`) is accepted, stored space-separated and read back as nothing, so the proposal can never be decided (`proposal-unreadable`); `mapMaybe` hides partial loss. | Fix: `evidenceFromKey` refuses empty ids and ids with whitespace, control characters or `:`; a decision refuses (`proposal-unreadable`) when the stored keys do not read back to exactly the stored text. |
| R-P6.9-4 | Medium (P5) | A `profile-rule` proposal whose target is not a catalog Profile, or whose `current` is not its latest version, is accepted but can then never be decided (`stale-target` forever). | **Partly fixed:** a proposal for a catalog Profile whose `current` is not its latest version is refused `stale-target` when proposed. **Not fixed:** refusing a target that is not a catalog Profile (`unknown-target`) conflicts with the frozen C-P6.9 case `selfPrivilege`, which expects a fix's proposal for the unregistered `team-checks` to be accepted; such a proposal stays undecidable (fails closed). Owner question below. |
| R-P6.9-5 | Low | `principalOf` duplicates `Conversation.senderPrincipal` (and maps a Planner to Agent, not Supervisor; both refused). Callers choose `Proposer`/`Sender`; the CLI hard-codes a person. | Fix: use `senderPrincipal`. The caller-trust constraint is recorded for the later work that wires a fix's proposals to a person's action. |
| R-P6.9-6 | Low | Validation and the unknown-fix check run before the key lookup, so a key's replay can be refused after a fix's binding changed. | **Not changed:** a replay must show the same content, and the content's identity is the digest of its validated canonical form; when that content no longer validates, refusing is fail-closed and harmless. |
| R-P6.9-7 | Cosmetic | The help column of `schedule run-once` lost a space; the `proposal propose` help names only three of the five evidence kinds; `listProposals` reads decisions one row at a time. | Fix the help text; batch the decision read. |

Open for the owner (frozen-test authority needed, not taken):

- **OQ-P6.9-1.** May the frozen C-P6.9 tests be amended so that (a) their shared fixture cites a commit a fix
  recorded, letting `commit:` evidence require a recorded commit (R-P6.9-1), and (b) `selfPrivilege` registers
  `team-checks`, letting a proposal for a non-catalog Profile be refused `unknown-target` (R-P6.9-4)?
- **OQ-P6.9-2.** May a proposal whose target has since moved on still be *rejected* (P5 now gates both decisions
  on currency)?

## Full check of the implementation

`a8e74d7` (`scripts/check --integration`): all passed: format, lint, build, unit (1075), no-live-model guard,
integration + backup/restore (694). Log: `.local/evals/phase-06/p69-full-check.log`.

## Remediation tests (frozen RED against `a8e74d7`)

- `test/unit/Lockstep/Kernel/ProposalReviewTest.hs`
  `5eee909623795ad1a71f06e15b6d1bc519c72c0e774908cb6c076aa75ba7b8ab`
- `test/integration/Lockstep/ProposalReviewTest.hs`
  `06e8e6940b8ef6fd67a1e154aeb6d5670a0d44194e091d4d79a00a5e271b5494`
- RED against `a8e74d7`: unit 1 of 3 fail (ids holding a space or nothing are keys), integration 3 of 5 fail
  (unresolved evidence accepted; another spelling counted twice; a stale catalog Profile rule accepted). The
  passing cases are regression guards: evidence that resolves stays accepted, every kind reads back, a resolved
  proposal stays decidable, and text of no kind is no key.
- Disclosure (the P6.6 practice): the tests were first tried against a draft remediation (all 12 C-P6.9 and
  R-P6.9 integration cases and all 16 unit cases passed after one implementation correction: ids in upper case
  were refused instead of canonicalized). No test changed after the RED baseline. Logs:
  `.local/evals/phase-06/p69r-*.log`.

## After remediation

- Remediation `ef3c64a`: C-P6.9 and R-P6.9 unit 16/16, integration 12/12.
- Full check of `ef3c64a` (`scripts/check --integration`): all passed: format, lint, build, unit (1078),
  no-live-model guard, integration + backup/restore (699). Log: `.local/evals/phase-06/p69r-full-check.log`.
- C-P6.9 is locally qualified, with the limitations in `amendments.md`; OQ-P6.9-1 and OQ-P6.9-2 are open for the
  owner. Owner acceptance is pending.
