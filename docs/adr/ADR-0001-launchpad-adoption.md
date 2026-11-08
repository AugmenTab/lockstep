# ADR-0001 — Adopt Launchpad as the Lockstep v2 application foundation (DG-01a)

- Status: **ACCEPTED** (2026-10-16), subject to the C4 checks at P1.1.
- Gate: DG-01a (source revision, reuse and license rights)
- Affects: FR-APP-01, FR-APP-02, NFR-07, NFR-11
- Evidence: `audits/LAUNCHPAD_AUDIT.md` rev 0.1

## Question

May Lockstep v2 copy, modify and redistribute source from Launchpad commit
`11886bf73c2e3ac69a6839af28b97ba79bbee5fb`, and under what notice obligations?

## Alternatives

1. **Adopt Launchpad `11886bf`** (selected framework per Bible §36), retaining the
   foundation and removing the items in Audit §5b.
2. Build the same stack from scratch without Launchpad source. This contradicts
   the accepted Bible direction and loses audited wiring.
3. Substitute another framework. Not permitted without a Bible/PRD amendment
   (Plan §16 risk register).

## Proposed choice

Alternative 1, with the following conditions:

- **C1 (human declaration, required).** The human owner confirms that they hold
  the copyright in Launchpad (declared "2023 Tyler Baum") or otherwise have the
  right to license it to Lockstep. They also state the license under which
  Launchpad-derived code enters Lockstep. Proposed: BSD-3-Clause, matching
  `package.yaml`, with the full license text added as a file.
- **C2 (human decision).** The distribution intent for Lockstep v2 (private,
  personal-only, or public open source) and Lockstep's own license. The Python
  repo's license applies to the Python history only. Nothing in Phase 0 sets the
  v2 license.
- **C3 (human decision).** Remove `_hyperscript` (not in the accepted stack) and
  the pandoc-based docs generator (GPL-2.0).
- **C4 (P1.1 acceptance checks, not human).** A clean container build of the
  derived package. A transitive license inventory (`stack ls dependencies
  --license`) with no copyleft dependency in the shipped server executable. A
  `NOTICE`/`THIRD_PARTY_LICENSES` file covering htmx (0BSD), Font Awesome Free
  icons (CC BY 4.0) and the MIT/BSD Haskell dependencies.

## Retained / removed Launchpad primitives

Retained (to be adapted in P1.1–P1.3): the `Types` app monad and context, the
`REPL` startup modes, `Routes` Beeline/Shrubbery/Orb dispatch, the Orb handler and
permission-action pattern, `Config` loading, Orville pool and schema
registration, `Database.Entity` (soft-delete to be reviewed), Brigid
`Components` (restyled), `Validation`, the `Util.Fleece`/`Util.Orville`
utilities, the API health route, and the cookie + token-digest primitives.

Removed: Pico and Theme, Rollbar, Signup/Admin/Account multi-user routes,
Mobile routes, nginx, `launchpad-tools GenerateDocs`/pandoc, Ogma i18n config,
`scripts/rebrand`, and the template's agent instruction files.

## Risks

- License text absent from source (Audit §2). Mitigated by C1 and the LICENSE file.
- The archive is not verified against the private repo (Audit §1). Mitigated by
  cloning `11886bf` in P1.1 and comparing trees.
- `allow-newer: true` weakens reproducibility. Mitigated by the P0.4 dependency policy.
- Auto-migration conflicts with FR-APP-03. Resolved at DG-02 before P1.2.

## Approval

| Field | Value |
|---|---|
| Approver | Human owner (operator), Phase 0 session |
| Decision | ACCEPT alternative 1 (adopt Launchpad `11886bf`) |
| C1 confirmation | Owner is the sole copyright holder; Launchpad-derived code enters Lockstep under **BSD-3-Clause**, and the LICENSE text arrives with the first derived code (P1.1) |
| C2 distribution intent / v2 license | **Undecided; private for now.** No Lockstep v2 license is chosen; nothing is pushed or published until a later explicit decision |
| C3 hyperscript & pandoc removal | **Remove both** |
| Effective date | 2026-10-16 |
| Record of approval | Operator answers in the Phase 0 session; restated in the Gate P0 packet for explicit confirmation |
