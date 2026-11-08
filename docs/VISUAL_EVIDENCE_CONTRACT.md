# Lockstep v2 — Visual Evidence Contract (design contract)

- Document: LS-V2-VISUAL-EVIDENCE
- Status: **ACCEPTED** as a design contract at Gate P0 (2026-10-16). It is approved as a
  contract only. It authorizes no UI acceptance.
- Revision: 0.1, 2026-10-16
- Traces: FR-APP-09, NFR-12, NFR-14; Bible §3.6.6, §13.1, §28.2; Plan §1.4, §15
- Implemented by: P1.6 (primitive), P3.15 (Work Unit acceptance matrix), P4.8
  (Scribe visuals)
- Wireframe: `docs/gates/wireframes/gate-evidence-wireframe.html` (an
  illustration only)

## 1. Purpose and non-authority

For every mandatory gate the human must be able to answer three questions, both
visually and through linked raw evidence: **what was intended to be proven, how
it was checked, and what was actually established.**

The visual projection is **read-only** and **reproducible from durable
evidence**. It is not a gate authority. It cannot change policy, authorize work
or record acceptance except through the explicit human decision operation in §7.
Diagrams, wireframes, screenshots and demos support review. They never substitute
for evidence (NFR-14).

## 2. Versioned acceptance criterion identifiers

- Format: `AC-<SCOPE>-<NN>@v<REV>`. Examples: `AC-P0-04@v1`, `AC-A1-02@v1`,
  `AC-WU-<workUnitId>-03@v2`.
- `SCOPE` is a gate (`P0`, `A1`, `B1`, `C1`, …) or a Work Unit Contract.
- `REV` increments whenever the criterion statement, method, expected
  observation **or `required` flag** changes. Evidence binds to the exact
  `@vREV`. A changed criterion never inherits old evidence. Changing `required`
  from `true` to `false` also needs a human deviation record (§4 rule 6). A
  failing row can never be dropped silently.
- Each criterion lists `source_refs`: PRD FR/NFR IDs, Contract ID/digest, or
  plan entry. A criterion without a source ref is invalid.

## 3. Gate row schema (`lockstep.gate-row/v1`)

| Field | Required | Content |
|---|---|---|
| `criterion_id` | yes | `AC-…@vN` |
| `statement` | yes | What must be true, in one sentence |
| `source_refs` | yes | e.g. `["FR-APP-05", "Contract c-17@sha256:…"]` |
| `required` | yes | `true` if the gate cannot be accepted without it |
| `method.kind` | yes | One or more of `automated_test` · `scenario` · `static_check` · `inspection` · `human_review` (a list when combined) |
| `method.command` / `method.scenario_id` | when automated | Exact argv or `SCN-…` |
| `expected_observation` | yes | Concrete and checkable ("exit 0; 0 sentinel entries") |
| `actual_observation` | if executed | What was observed. Empty only when `NOT_RUN`/`BLOCKED`. |
| `disposition` | yes | §4 |
| `evidence[]` | for PASSED and FAILED; for INCONCLUSIVE when any exists | `{locator, sha256, kind, produced_at, producer}` |
| `tested_revision` | if executed | `{repo, commit, dirty: false}`. Dirty trees cannot yield PASSED. |
| `policy_identity` | yes | Effective Profile `{id, version, digest}`, or `"manual — no v2 Supervisor"` before P2 |
| `environment` | if executed | OS, toolchain versions, DB version, adapter kind (`scripted`/`live`) |
| `executed_at`, `executed_by` | if executed | Actor and role (human, Supervisor, manual agent) |
| `limitations` | optional | Known gaps, sampling, flakiness |
| `blocker` | if BLOCKED | What blocks it and who can unblock |

## 4. Dispositions

| Disposition | Meaning | Required content | Counts toward acceptance? |
|---|---|---|---|
| `PASSED` | Method executed against the stated revision; actual matched expected | actual observation, ≥ 1 evidence item whose digest verifies, clean tested revision | yes |
| `FAILED` | Executed; actual contradicts expected | actual observation + evidence | blocks |
| `INCONCLUSIVE` | Executed, but the result neither confirms nor refutes (flaky, partial, unverifiable citation, digest mismatch) | actual observation + why | blocks |
| `BLOCKED` | Cannot execute because a prerequisite or decision is missing | `blocker` | blocks |
| `NOT_RUN` | Not executed (not built, skipped, out of budget, not yet reached) | reason | blocks |

Rules:

1. **Default is NOT_RUN.** A row without a recorded execution is `NOT_RUN`.
   Blank cells are forbidden.
2. **No coercion.** No code path maps `INCONCLUSIVE`, `BLOCKED` or `NOT_RUN` to
   `PASSED`. A `PASSED` claim missing any required content is rendered and stored
   as `INCONCLUSIVE` with the reason "incomplete evidence".
3. **Re-verification.** The projector re-hashes evidence on render. A digest
   mismatch shows `INCONCLUSIVE (evidence changed)`. A missing or unreachable
   locator shows `INCONCLUSIVE (evidence unavailable)`.
4. **Staleness.** If `tested_revision` differs from the gate's declared revision,
   a recorded `PASSED` is rendered and counted as `INCONCLUSIVE (stale
   revision)`. It never shows a PASSED label or color. A stale `FAILED` stays
   `FAILED`.
5. **Aggregate.** The machine summary of a gate is the worst *effective*
   disposition (after rules 2–4) among required rows, ordered
   `FAILED > BLOCKED > INCONCLUSIVE > NOT_RUN > PASSED`. A gate with **no**
   required rows aggregates to `NOT_RUN`, never a vacuous `PASSED`. The summary
   is **not** acceptance.
6. **Deviations** are separate human-approved records: they cite the row, the
   reason and the approver. The row keeps its real disposition. There is no
   `WAIVED` disposition.
7. Semantic-challenge findings (`CONFIRMED`/`DISPROVED`/`NEEDS_HUMAN`/
   `INCONCLUSIVE`) are shown in a separate section, never merged with
   deterministic test rows (Bible §13.1).

## 5. Raw evidence location and provenance

- Every evidence item has a **locator** and a **SHA-256**. Locator forms:
  `repo:<path>@<commit>`, `local:.local/evidence/<gate>/<file>`,
  `db:<table>/<id>` (from P1.2), or `git:<object-id>`.
- Small text evidence (≤ 1 MiB) may be committed under
  `docs/gates/<GATE>/evidence/`. Larger or sensitive evidence stays in
  `.local/evidence/` and only its digest is committed.
- Evidence is append-only. Re-running produces new evidence with a new timestamp.
  Old evidence is never overwritten.
- Provenance records **who or what produced it** (`human`, `manual-agent`,
  `supervisor`, `ci`), with the producing command or scenario, and the adapter
  kind (`scripted`/`live`).

## 6. Tested revision and policy identity

Every gate report header shows: repository, branch, tested commit, clean/dirty,
schema revision (from P1.2), policy identity (Profile ID, version and digest, or
"manual — no v2 Supervisor" before P2), and the document revisions it is judged
against (Bible/PRD/Plan digests from SOURCE_REGISTER).

## 7. Human inspection and decision

- From any row, one action reaches the full command, the untruncated output (or
  its locator) and the diff. Nothing material is paraphrased away (Bible §13.1).
- The gate decision (`ACCEPTED` / `REJECTED` / `DEFERRED`) is recorded **only by
  the human**. The record binds `{gate, report revision, report SHA-256,
  decided_by, decided_at, notes}`. A decision against a stale report revision is
  refused with a "refresh" message (Bible §13.3).
- No agent, CI job or green aggregate sets a gate decision.

## 8. Accessibility (NFR-12)

- Status is always given as **text** (`PASSED`, `NOT_RUN`, …). Color and icon are
  redundant cues, never the only one.
- Contrast meets WCAG 2.2 AA in both light and dark themes. Green is reserved for
  `PASSED`. `NOT_RUN` is neutral gray with a dashed outline, so it can never be
  mistaken for success.
- The matrix is a semantic `<table>` with `<th scope>` headers. Drill-down uses
  `<details>`/buttons reachable by keyboard. There are no drag-only controls. A
  visible focus ring is required.
- Live updates (HTMX polling or SSE) must not move focus or overwrite form input.
  `prefers-reduced-motion` is honored.
- Every diagram has a text equivalent.

## 9. Diagram, screenshot and demonstration provenance

| Artifact | Mandatory label | Provenance fields |
|---|---|---|
| Diagram / wireframe | `ILLUSTRATION — NOT EVIDENCE` | Source file, generator, revision, date, what it illustrates |
| Screenshot | `SCREENSHOT — shows rendering, not correctness` | URL/route, app commit, data source (`canonical DB` / `sample data`), captured_at |
| Interactive demo | `DEMO — sample data, read-only` | Declared dataset; must not write canonical state |
| Before/after comparison | `COMPARISON` | Both revisions |

An artifact without its label and provenance is excluded from the gate report.

## 10. Implementation notes for P1.6

- `Lockstep.Evidence.Model` (pure) implements §3–§4: smart constructors make an
  unsupported `PASSED` unrepresentable. Its tests include generated rows, and they
  assert that no non-PASSED input renders with the PASSED class or label
  (cross-cutting test "visual evidence falsely shows incomplete/unknown gate as
  passed", Plan §14).
- Brigid components follow the wireframe's structure; styling uses Lockstep CSS
  tokens. No Pico.
