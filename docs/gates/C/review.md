# Gate C — independent read-only review and proposed dispositions

- Reviewer: a separate **read-only** reviewer agent of the same model family as the writer. It was
  told to read files and use read-only git only, with no edit, build, Docker or network use.
  **This is not a human review.**
- Scope: `git diff 8e71039..0c8d9ee -- src app scripts static lockstep` (Phase 3 production code),
  against C-P3.1–C-P3.10; mostly P3.5–P3.10. It did not read Brigid's source (outside the
  repository) and ran no tests.
- Date: 2026-10-27. Result: **no HIGH findings**; 2 MEDIUM, 5 LOW, 3 INFO.
- Dispositions are **proposed** by the writing agent (Implementer). Nothing has been changed; the
  tested commit stays `0c8d9ee`. Items marked **owner** need the owner's decision.

## Findings and proposed dispositions

| # | Sev. | Finding (reviewer's words, condensed) | Proposed disposition |
|---|---|---|---|
| 1 | MEDIUM | `applyDecision` (`Application/Decisions.hs:179-215`): key lookup, operation and receipt insert are three steps. Two concurrent requests with one key: one applies, the other is refused stale; if the refused receipt is inserted first, the applier gets back "refused" (no digest check on the lost-race path, line 210), the only durable receipt contradicts what happened, and the closed decision's page 404s (`decidedReceipt` only reads `applied`). Same root as the limitation recorded in C-P3.8 §3a. | **Fix before acceptance** (owner to confirm): claim the key first: a transaction-scoped advisory lock on the key spanning check, operation and insert is not possible because the ledger operations own their transactions; instead insert a `pending` receipt row first (migration 16 widening `outcome`), then update it once with the result. That breaks the "rows never update" rule of M4, so it needs the owner's choice between (a) pending-then-final with a one-time update allowed, or (b) a session-level advisory lock held across the three steps. Also compare digests on the lost-race path. No double effect is possible today (revision/generation checks), only a wrong receipt. |
| 2 | MEDIUM | `connectProject` (`Application/Projects.hs:159-204`) checks the revision before side effects: two concurrent connects at one revision both make a folder, an Engineer and a repository registration, then one is refused `stale-revision`, leaving an orphan Engineer owning a repository (C-P3.5 J2 says a stale revision "changes nothing"). Also on `Left` after the folder was made. | **Fix before acceptance** (owner to confirm): serialise per project before any side effect with a session-level advisory lock keyed on the project id, re-reading the revision under it. Needs a frozen-test addition (a concurrent-connect case). |
| 3 | LOW | `scripts/control-helper:897-906`: `folder_refusal` runs in a subshell, then again only to set `folder_real`, with that second run's refusal discarded; a symlink re-targeted between the two runs could be added as `ro`. | Fix with 2 (single in-shell check setting `folder_real` and `refusal`). Requires a local race on the owner's own home folder. |
| 4 | LOW | `scripts/service:105-130`: `folder_args` follows symlinks with `[ -d ]` and never re-checks that a listed folder is still a real directory inside `$HOME` before mounting. | Fix with 3: skip `[ -L ]` entries and compare `pwd -P`. |
| 5 | LOW | `expected` is an unbounded `Int` stored as `Int32` (`App.hs:404`, `Decisions.hs:194`, `DecisionReceipts.hs:83`): `-1` or `2^31` → refused, then the receipt insert fails (503, no receipt) or wraps. | Fix: reject outside 0..2³¹−1 as a form error before `applyDecision`. |
| 6 | LOW | A closed decision's page shows the latest *browser* receipt for the subject, even from an earlier halt cycle when the latest one was settled elsewhere (`App.hs:507-512`). | Fix: show the receipt only if newer than the subject's last ledger event; else "decided elsewhere". |
| 7 | LOW | `decideTask` is not under the task lock as C-P3.6 K2 says, and `lockTasks` locks the whole table, not one project's tasks; a concurrent title edit and decision can collide on the Ticket's event revision, surfacing as 503 instead of `stale-revision` (nothing half-applied). | **Owner**: either amend the K2 wording to match (decisions go through C-P2.2 `decideTicket`, revision-checked), or run the decision inside the edit lock and map the conflict to `stale-revision`. Proposed: the latter. |
| 8 | INFO | `Fragment.attr` relies on Brigid escaping `"` in `customAttribute`; no test echoes a `"` into an attribute value. | Add a test with a title containing `" autofocus onfocus=alert(1) x="` (a new frozen case, owner-visible). |
| 9 | INFO | A reused creation key returns the earlier task/project even when the new request names another project; `CreateTaskRoute pid` can answer with another project's task. | Return `key-conflict` when the project differs (matches C-P1.5's key rule better; small contract amendment). |
| 10 | INFO | `none` is the "nothing chosen" sentinel for `expected` in the checks form; a profile registered with id `none` would be confused with it. | Reserve the id `none` (refuse it in `profile add`), or use an impossible sentinel. |

## Checked and found clean (reviewer's list, condensed)

Route guard (every data-carrying or acting `/app` route needs the session header, exact Host and
Origin on POST; OPTIONS 405; no CORS); principals (browser decisions always Human; no request field
names a principal); SQL parameterised everywhere; host folder choice limited to offered paths with
path syntax rejected; the schedule preview read-only (first statement `SET TRANSACTION … READ ONLY`,
no lock/claim/row); `chooseChecks` one transaction under the profile lock with stale, losses and
refusal rows as contracted; `createTask`/`editTask` revision-guarded twice under the lock; Activity
and status words honest (PASSED only for PASSED, ATTESTED not verified, unknowns never success, an
unreadable projection never empty); decision kinds checked (`fits`), Give up re-checks the
generation, Try again needs the acknowledgment, text rules before any receipt; sign-in tokens only in
URL fragments, cleaned from the address bar.
