# Screenshots — provenance and inspection (C-P1.6 E10)

**SCREENSHOT — shows rendering, not correctness.** These images support review; they are not
evidence that the projection is correct (NFR-14). Correctness is established by the frozen tests
(`evidence/check-fresh-clone.log`) and by the HTML captured with each image.

| File | Route | App commit | Data source | Theme | Captured at (UTC) | SHA-256 |
|---|---|---|---|---|---|---|
| `center-operator-light.png` | `/operator/center` | `2ac0059` (binary built from it) | canonical operator DB `lockstep` (schema 5) | light | 2026-10-18 17:39 | `f4fc9418…` |
| `center-operator-dark.png` | same | same | same | dark (`--force-dark-mode`) | same | `916b4f2d…` |
| `center-negative-light.png` | same | same | scratch DB `lockstep_p16_negative` (dropped afterwards); job 1's row edited, job 2's digest cleared | light | same | `6411410…` |
| `center-negative-dark.png` | same | same | same | dark | same | `b23eb54a…` |
| `center-operator.html`, `center-negative.html` | same | same | the HTML served at the same moment | — | same | `64be1e84…`, `1b7a68b1…` |

Producer: manual agent session, headless Chromium 155 in the dev container, through a local
proxy that adds the session cookie (`../operator-run.sh`). Full digests: `../SHA256SUMS`.

## Inspection by the writing agent (2026-10-18)

- Status table: every row pairs the status label, its count and its meaning in one row; no
  floating badges or separate legend (handoff §P1.6 comprehension fix). Counts are right-aligned
  and readable.
- Dispositions are text first. Green appears only on the single job whose outcome digest still
  matches (`AC-JOB-5`, operator DB). `NOT_RUN (in progress)` is gray with a dashed outline.
  `FAILED` is red; `INCONCLUSIVE (…)` is amber with its reason.
- Operator DB: jobs 1, 3 and 4 succeeded before migration `0005` added outcome digests, so they
  show `INCONCLUSIVE (incomplete evidence)` rather than PASSED. That is the intended truthful
  result, not a defect. The aggregate is `FAILED` (job 2's deterministic failure) and is labelled
  "not acceptance".
- Negative case: the edited job shows `INCONCLUSIVE (evidence changed)` with its actual
  `succeeded, 1/2 steps`; the job with a cleared digest shows `INCONCLUSIVE (incomplete evidence)`.
  Nothing misleading is green.
- Dark theme: same structure; all text readable on the dark surfaces.
- Not inspected here: keyboard focus order (links are standard anchors with the stylesheet's
  visible `:focus-visible` ring) and screen-reader output. A human browser check is part of A1 (P1.7).
