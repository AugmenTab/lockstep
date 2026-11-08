# Contract — P3.8 Human decisions in the browser

- Contract ID: `C-P3.8@v1`
- Status: **FROZEN** (2026-10-26; §4)
- Authority: Phase 3 handoff P3.8 ("a real Decisions view … exact subject, requested decision,
  current state, evidence, available legal choices and consequences"; "authenticated typed
  operations with immutable durable receipts and stale-revision protection"; "an agent assertion
  must not impersonate human authorization"; "no nonfunctional approval buttons … future
  capabilities labeled unavailable"); PRD v0.3 FR-UX-08; Plan v0.3 §4 P3.8; C-P2.5 (the ledger
  operations, unchanged), C-P2.6/C-P2.9 (effect outcomes and human resolution, unchanged),
  C-P1.5 (idempotency keys); C-P3.4 (the frozen rule that the Decisions *section* shows links
  only and says what arrives in a later update).
- Writer: the single writing agent (Implementer, manual).
- Scope: the two kinds of decision that only a person can make today **and** that the ledger
  can already apply: a piece of work that was **stopped** (a halted Work Order: put it back in line,
  or cancel it), and a step whose **outcome nobody knows** (an effect intent in the C-P2.8 UNKNOWN
  status: it happened, it did not happen, try it again, or give up on it). Everything else a
  person may one day decide (signing work off, approving a running agent's work, confirming changed
  checks, carrying a step into a new attempt) is either not reachable yet or stays in the command
  line, and the page says so. No ledger, Kernel or scheduler rule changes.

## 1. What P3.8 delivers

1. **What needs you.** The Decisions section lists every open decision, each a link: what it is
   about (the task's title), what is being asked, and since when it waits. It keeps the C-P3.4 rule
   for the section: links only, no form or button, and it names what arrives later.
2. **One page per decision** (`/app/decisions/<id>`): the subject in plain words; the current state
   and why (the stored halt reason, or the stored outcome reason and every observation); the legal
   choices only, each with what it will do; *Technical details* with the exact ids, revision or
   generation, and the raw ledger lines.
3. **Exact, typed, human decisions.** Each choice is one existing C-P2.5/C-P2.9 operation with
   principal **Human**, the expected revision (stopped work) or generation (unknown outcome) shown
   on the page, and a fresh idempotency key. A stale page is refused and changes nothing.
4. **Durable receipts.** Every decision request that reaches an operation leaves one immutable
   receipt (key, payload digest, subject, choice, outcome, refusal code, actor, time). Sending the
   same request again returns the first receipt and applies nothing; the same key with different
   content is refused.

## 2. Decisions

| # | Decision |
|---|---|
| M1 | **Open decisions** (`Lockstep.Application.Decisions.listDecisions`, from the C-P2.8 projection read in one snapshot): `StoppedWork` for each Work Order in `halted` (order id, revision, reason, ticket title); `UnknownOutcome` for each effect in status UNKNOWN (operation id, generation, effect name, reason, observations, its order and ticket title). Ordered by kind (unknown outcomes first: they block their work), then id. Nothing else is listed as a decision. |
| M2 | **Requests** (pure, `Lockstep.Kernel.Decision`): `PutBackInLine wo rev`, `CancelWork wo rev`, `ItHappened op gen evidence`, `ItDidNotHappen op gen evidence`, `TryAgain op gen acknowledged`, `GiveUp op gen reason acknowledged`. `decisionPayload` is the canonical text `lockstep-decision-v1` + subject + choice + expected + text + acknowledgment, one per line (text escaped); its SHA-256 is the receipt's payload digest. `decisionSubject`, `decisionChoiceName` (`put-back`, `cancel`, `happened`, `did-not-happen`, `try-again`, `give-up`). Evidence and reasons: 1–500 characters after trimming, no control characters (`text-empty`, `text-too-long`, `text-control`). |
| M3 | **Applying** (`applyDecision runtime key request`): (1) the request's own rules (M2) → refusal, no receipt; (2) a receipt with this key: same digest → that receipt, marked replayed; other digest → `key-conflict`; (3) the operation, principal Human: `decideWorkOrder … WoRequeue / WoCancel` with the expected revision; `resolveOutcome … AttestApplied / AttestNotApplied / RetryAcknowledgingDuplication` with the expected generation; for *give up*, the intent's current generation must equal the expected one (else `stale-revision`), then `abandonIntentAcknowledged`; (4) one receipt row with outcome `applied` or `refused` and the operation's refusal code. A receipt insert that loses a race to the same key returns the stored receipt. The receipt's actor is `application-session`; no request field can name a principal. |
| M4 | **Migration 15** `lockstep_decision_receipts`: `id`, `idempotency_key` unique (the C-P1.5 key rule), `payload_digest` (64 hex), `subject` uuid, `choice` (M2 names), `expected` ≥ 0, `outcome` (`applied`, `refused`), `refusal_code` (present exactly when refused), `actor`, `recorded_at`; UPDATE, DELETE and TRUNCATE refused by trigger. |
| M5 | **Words.** Choices: *Put it back in line*, *Cancel this work*, *It happened*, *It did not happen*, *Try it again*, *Give up on it*, each with its consequence sentence. Refusals in plain words: `stale-revision`/`stale-claim`/`not-unknown`/`already-settled`/`illegal-transition`/`already-terminal` → "This changed since the page was shown. Nothing was changed; here is how it stands now."; `duplication-risk-not-acknowledged` → tick the box; `idempotency-key-expired`; `key-conflict`; `text-empty`, `text-too-long`, `text-control`; anything else general. No Work Order, Ticket, intent, generation, Supervisor or scheduler word outside *Technical details*. |
| M6 | **Pages.** `/app/decisions` (section fragment, links only, "… arrive in a later update of Lockstep."); `/app/decisions/<uuid>` (fragment `/app/fragments/decision/<uuid>`: the decision page while it is open, the **Done** page of its latest applied receipt once it is closed, 404 for anything else); the form posts to `/app/api/decisions/<uuid>` (session header, Origin, up to 16 KiB) with hidden `key` and `expected`, `choice`, optional `text` and `acknowledge=yes`, and answers `200` with the decision page (still open) or a **Done** page that says what was recorded and links back to Decisions, with `X-Lockstep-Path`. Home's "What needs your attention" links to Decisions when anything is open. |
| M7 | **Not here.** Ticket signoff (needs integration evidence that Phase 3 cannot produce), confirming changed checks (no durable confirmation exists in Phase 2), carrying a step into a new attempt (`lockstep effects carry` stays the way), approving agent work (Phase 4). The Decisions section names these as arriving later; no button exists for them. |

## 3. Verification (to be frozen before implementation)

| File | Kind | Covers |
|---|---|---|
| `test/unit/Lockstep/Kernel/DecisionTest.hs` | unit | payload text and digest stability; every field changes the payload; subject and choice names; text rules; refusal words for every M5 code, with no internal words |
| `test/integration/Lockstep/DecisionsTest.hs` | integration: real PostgreSQL, in-process | listing a halted order and an UNKNOWN effect with their expected values; put back in line (a Human event, receipt); replay returns the first receipt and appends nothing; same key with other content is `key-conflict`; stale revision and stale generation refused with a receipt, nothing changed; cancel; it happened (attested resolution), try again without acknowledgment refused; give up; the list empties; receipts are immutable |
| `test/integration/Lockstep/DecisionsPageTest.hs` | integration: real service | the section lists links only and says "later update"; a decision page's subject, state, choices, consequences and hidden fields; session and Origin required; applying answers Done; a replay answers with the same receipt; stale words; escaping; no internal words outside *Technical details*; 404s and the 16 KiB limit |
| `test/integration/Lockstep/DecisionsBrowserTest.hs` | integration: headless Chromium (`test/browser/app_driver.py`, frozen), real service | Home → Decisions → the stopped work → Put it back in line (keyboard) → Done → back to Decisions: it is gone |

## 3a. Verification record (after implementation)

| Check | Result | Evidence |
|---|---|---|
| Frozen files (P3.8 and earlier) | digests unchanged | §4, earlier contracts' §4 |
| `scripts/check --integration` | format, lint, build, unit, no-live-model guard PASSED; integration 373 of 375 PASSED, the 2 failures being the known C-P3.4 `HandoverTest.hs` defect | `check-integration.log` |
| C-P3.8 groups | unit 7 of 7; in-process 9 of 9 (a Human event per applied decision; a replay appends nothing; stale revision and generation refused with receipts; receipts immutable); pages 6 of 6; the real-browser journey (Home → Decisions → stopped work → Put it back in line by keyboard → Done → no longer open) PASSED | `check-integration.log` |
| Linux clean clone of `3e614d6` | format, lint, build, unit PASSED; integration 373 of 375. The kept tail shows every C-P3.8 case passing (the real-browser journey included); the 2 failures are outside it and match the known `HandoverTest.hs` cases in count | `linux-clone.log` |

The first implementation run passed; the only fix before it was a compile error (a local name
shadowing another).

Implementation notes (decisions within the design, recorded here):

- The receipt is written after the operation's own transaction (C-P2.5 operations own their
  transactions). A crash between them leaves an applied decision without a receipt; a replay of
  that request is then refused by the revision or generation check (no double effect) and gets a
  `refused` receipt. Recorded here as a known limitation.
- *Give up* checks the step's current generation itself before `abandonIntentAcknowledged`, which
  has no generation argument; a race between the two is refused by the ledger as `already-settled`.
- Home's "What needs your attention" gains "N decision(s) need you: Decisions"; its last sentence
  now says "Anything only you can decide is under Decisions." (it said decisions would arrive in a
  later update).

## 4. Freeze record

Frozen 2026-10-26 by the writing agent (manual), before the decision operations and pages were
implemented.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/DecisionTest.hs` | `f644abe93cd8c3e68b6d1f42a4c67ca3f829a1b68b6e3cef50e167b21353e5f2` |
| `test/integration/Lockstep/Support/Decisions.hs` (fixtures) | `7941e1127ee214134779415f80b70f08b7e78dfaf5395f88dbbca812072792ac` |
| `test/integration/Lockstep/DecisionsTest.hs` | `fc71b30569f91b5363431dce4f44a61b0fc20a95e05c11cbec38b1ef6eb630c1` |
| `test/integration/Lockstep/DecisionsPageTest.hs` | `71d8038e11d2c911b40220419d2b99ae77ab01ec1299c7bd3924d74c6526b30f` |
| `test/integration/Lockstep/DecisionsBrowserTest.hs` | `c4e35e5c8f218fd0503c3798a8ccfd547532ca1cc61c6677458c0ec0fd90ecd4` |
| `test/unit/Main.hs` (runner, additive) | `800c819a9e45f8b42c40a48175ab527fb2d90f1ee6b2f104cc3d24bcebecbc35` |
| `test/integration/Main.hs` (runner, additive) | `86211d73e43f8963750171cb5152df0398e6fdbb280e8c8b13c0a1574a9aec3a` |

Earlier frozen tests are untouched; the runners only gain lines.

Pre-freeze verification:

- The pure request module (`Lockstep.Kernel.Decision`), the receipt storage
  (`Lockstep.Persistence.DecisionReceipts`) and migration 15 were written before the freeze. The
  unit group passed 7 of 7 at its first run (`prefreeze-unit.log`) and was not run against a stub
  first (the P3.6/P3.7 reason: a failing unit step hides the integration baseline).
- `scripts/check --integration` against a stubbed `Lockstep.Application.Decisions` and the
  unchanged pages (`prefreeze-integration-baseline.log`): format, lint, build, unit and guard
  pass; 18 of 375 integration cases fail, which are the 2 known `HandoverTest.hs` cases and all
  16 new ones. Each new failure was read for its reason: the stub (an empty list,
  `not-implemented`), the placeholder Decisions section, 404 for the new page and route, and no
  link in the browser. The fixtures ran: work stopped by a person, and a step with no answer, both
  made through the real ledger before the assertions; the browser reached the Decisions section.
- Found and fixed before the freeze: `-Wpartial-fields` refused the first shape of
  `OpenDecision` (now two constructors, each carrying its own record); a fixture name clashed with
  a record field (renamed `stepWithUnknownOutcome`); 3 hlint hints in the tests.
- Contract text changed before the freeze: M6 now says a closed decision's page shows what was
  decided (its latest applied receipt) rather than 404, so a reload after deciding still works.
