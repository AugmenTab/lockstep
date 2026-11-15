# Contract — P6.9 Human-controlled improvement proposals

- Contract ID: `C-P6.9@v1`
- Status: FROZEN (§5)
- Authority: `.local/plans/phase-06.md` §14 (P6.9); `.local/plans/phase-06_update1.md` §7.
- Basis: `phase-6` after C-P6.8 qualified (`0a86e86`, the record of the R-P6.8 full check).
- Writer: the single writing agent (Implementer). The Implementer does not accept this subphase.

## 1. What this adds

Lessons from the work become **proposals**. Each is typed, evidence-backed and versioned, and it changes nothing by
itself: only the owner decides on it. An approval is a recorded decision, never an installation. The Skills Library
is Phase 10, so this stays bounded: proposals are recorded and decided; adopting an approved one is a separate,
later change made by the owner.

| # | Decision |
|---|---|
| P1 | **A proposal** (pure `Lockstep.Kernel.Proposal.validateProposal`) has these parts: a scope (`engineering-practice`, `profile-rule`, `test-adequacy`, `review-instructions`, `skill`); the target it would change (a name); the target's current version and the version it proposes; a title, the expected benefit and the risks; the evidence; whether it is private; and who proposed it (a person, or a fix). It is refused when: a text is empty or too long (`text-invalid`), the versions are the same (`no-change`), or it has no evidence (`no-evidence`). |
| P2 | **Evidence is canonical, and repeated opinions are not independent.** Evidence is links to Lockstep's own records, as C-P6.8 names them (a fix, a record of a fix, a commit), never free text. Repeated links count once, and the number of distinct links is the proposal's support. A proposal's identity is the digest of its canonical text (scope, target, versions, title, benefit, risks, sorted distinct evidence, privacy). Proposing the same again, by any key or proposer, gives the same proposal back, never a second one. An idempotency key replays only the proposal it recorded; the same key with other content is refused `key-conflict`. |
| P3 | **No self-privilege.** A proposal from a fix may not have a `profile-rule` scope whose target is the Profile that fix's own Work Order is bound to (`self-privilege`). A Work Unit cannot ask for its own rules to change. The bound Profiles are read from the fix's stored Work Order binding, never from what the proposal claims; a fix that does not exist is refused `unknown-fix`. |
| P4 | **Private scope.** A private proposal can only be a person's; one from a fix is refused (`private-scope`). Private proposals are left out of every list except the owner's own list of private proposals. |
| P5 | **Only the owner decides.** A decision (approve or reject) comes only from a person through the application or the command line. Anything else is refused `not-authorized`: an agent, the Supervisor, a Planner, a fix. The decision names the current version the person looked at. It is refused `stale-target` when that version is not the proposal's current version. For a `profile-rule` proposal, it is also refused when it is not the catalog's latest version of that Profile. A proposal is decided once (`already-decided`). |
| P6 | **Nothing is installed.** An approval records the decision and nothing else: no Profile, Profile choice, plan, skill, instruction or rule changes, and no Work Order's binding changes. No summary (C-P6.8), and no agent output, ever creates, approves or applies a proposal. |

## 2. Typing

- Kernel: `Lockstep.Kernel.Proposal` (`Scope`, `scopeCode`, `parseScope`, `Proposer`, `ProposalInput`,
  `Proposal`, `proposalInput`, `proposalSupport`, `ProposalProblem`, `problemCode`, `validateProposal`,
  `proposalText`, `evidenceKey`, `evidenceFromKey`, `Decision`, `decisionCode`, `decideProposal`).
- Persistence: migration 31 adds `lockstep_improvement_proposals` and `lockstep_improvement_decisions` (both
  immutable), and `Lockstep.Persistence.Proposals`.
- Application: `Lockstep.Application.Proposals` (`proposeImprovement`, `decideImprovement`, `listProposals`).
- CLI: `lockstep proposal propose --scope SCOPE --target NAME --current VERSION --proposed VERSION --title TEXT
  --benefit TEXT --risks TEXT --evidence KEY... [--private]` (evidence keys `fix:ID`, `record:ID:N`,
  `commit:SHA`, `invalidation:ID`, `request:ID`; an unknown scope is `scope-unknown`, a key that is not one is
  `evidence-invalid`), `lockstep proposal list [--private]`, `lockstep proposal approve ID --current VERSION`,
  `lockstep proposal reject ID --current VERSION`. Refusals print `refused CODE` and exit 65.
- Bound: nothing in P6.9 creates a fix's proposal from role output (P6). The `fix` proposer is for the
  application's callers that record a lesson on a fix's behalf; wiring one to a person's action is later work.

## 3. Mandatory tests (handoff §14) → cases

| Handoff test | Where |
|---|---|
| Duplicate proposals are idempotent | unit (the digest ignores order and repeats of evidence); integration `duplicates` |
| Forged approval refused | unit (`decideProposal`: not a person); integration `forged` |
| Stale target revision refused | unit; integration `stale` (also a `profile-rule` whose Profile has a newer version) |
| Proposal cannot mutate effective policy | integration `noMutation` (Profiles, choices, bindings and plans unchanged after an approval) |
| Personal/private scope is protected | unit (`private-scope` from a fix); integration `privateScope` (not listed except to the owner) |
| No auto-install from Scribe output | integration `noAutoInstall` (making summaries creates no proposal; a fix's proposal is only proposed) |
| (§14) No self-privilege | unit; integration `selfPrivilege` |

## 4. Verification files

`test/unit/Lockstep/Kernel/ProposalTest.hs`, `test/integration/Lockstep/ProposalTest.hs`, the runners.

## 5. Freeze record

- Frozen files (SHA-256):
  - `test/unit/Lockstep/Kernel/ProposalTest.hs`
    `77c0c18b6e4b01febf9df258293cd2bbedb31f610c270fa2cf5e9a9dbb49cece`
  - `test/integration/Lockstep/ProposalTest.hs`
    `f3c389c145bc5a83fe793eb3560de5538c8b26bc7a2dcef096d8da4a091bd975`
- RED against the stubs (`Kernel.Proposal` with the contract's types and no rules; `Application.Proposals`
  recording nothing; no migration 31): unit 12 of 13 fail, integration 7 of 7 fail. The unit case "the same
  proposal is the same text…" passes against the stub vacuously (both sides are the same refusal); it is
  meaningful only once `validateProposal` accepts the input, which "a complete proposal is valid" requires.
- Disclosure (the P6.6 practice): before the freeze the tests were tried against a draft implementation
  (unit 13/13, integration 7/7). Three fixture faults were corrected then, none in an assertion: a redundant
  import, a `Show` instance the test assumed, and idempotency keys shorter than the 16 characters keys need.
  The stubs were then restored and the baseline above taken.
- Logs: `.local/evals/phase-06/p69-trial-*.log`, `.local/evals/phase-06/p69-freeze-red-*.log`.

## 6. Allowed paths

New: §2/§4 files, `docs/gates/P6.9/**`. Changed: `Persistence/Migrations.hs` (append 31),
`Foundation/Cli.hs`, `app/lockstep/Main.hs`, the runners, `docs/OPERATOR_GUIDE.md`.

## 7. Budget, stop, rollback

At most 3 attempts per failing frozen test. Model-free. Rollback: the branch; migration 31 is additive.
