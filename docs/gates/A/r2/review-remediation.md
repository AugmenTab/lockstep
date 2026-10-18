# Independent read-only review of the browser-form remediation (`de8afa3..6c2851d`)

- Reviewer: a separate **read-only** reviewer agent (same model family as the writer; read files
  and read-only git only). **Not a human review.** 2026-10-18.
- Scope: `git diff de8afa3 6c2851d -- src test scripts Dockerfile docs/OPERATOR_GUIDE.md`
  against C-P1.7-R1 and the Planner decision.
- Result: **no HIGH findings**; 1 MEDIUM, 4 LOW, 3 INFO. **No code change followed**, so the
  tested commit stays `6c2851d`.

| # | Sev. | Finding | Disposition |
|---|---|---|---|
| 1 | MEDIUM | `scripts/a1` does not fully meet R5: only the rename (plus sign-in/out) goes through Chromium. The stale check (A1-08) still uses curl, and the form-duplicate check was dropped. | **Partly a contract conflict; recorded.** (a) A duplicate through the real form is impossible by design: R6 says Back loads a fresh key, which R5's wording contradicts. Replay is shown with an explicitly reused key (A1-07), as the Planner directed. (b) An automated browser stale check needs the browser paused while the revision changes, which requires extending the frozen driver (C-P1.7-R1 §8). The server-side stale refusal is covered at HTTP level (A1-08). The browser reaches the same handler with a valid Origin and CSRF (A1-06, AC-A1-23). **Added instead:** a real-browser stale check to the owner's demonstration (report r2 §4 step 5b: two tabs). Recorded as a limitation in r2 §3. |
| 2 | LOW | The driver ignores a load timeout. | **Recorded.** The reviewer confirmed it fails safe: missing POST keys fail every expectation. Not changed (frozen). |
| 3 | LOW | Sent headers are paired to redirect hops by position; R3 names `responseReceivedExtraInfo`, but the driver uses `responseReceived`/`redirectResponse`. | **Recorded.** It fails safe: a mismatch yields empty Origin/Referer and the expectations fail. The R3 deviation is noted in the remediation record. |
| 4 | LOW | The cross-origin case does not assert that the cookie was sent. | **Recorded.** The 403 comes from the guard, which runs before the session check; a session refusal would be a 401. |
| 5 | LOW | Chromium and Python are now also present in the image the service runs in. | **Evidence added:** `docs/gates/P1.7/r1-evidence/ldd-installed-binary.txt`. The installed binary links no Chromium, Python, NSS, X11 or GTK library. The Chromium version (155.0.8059.79) is in the A1 log. A slim runtime image is a follow-up. |
| 6 | INFO | `origin` is wider than `same-origin` (it sends the bare origin cross-origin). | **No change**: Option A was approved as `origin`; the value is only `http://127.0.0.1:P`. |
| 7 | INFO | `confirmResponse` uses a literal instead of `formPagePolicy`; operator-guide wording about Back; A1-13 still installs Chromium at run time. | **Recorded.** On Back: with `no-store`, Back re-fetches the form with a **fresh key and the current revision**, so resubmitting applies as a new command (it is not stale). The guide's wording ("counts as a new command") is accurate. The literal and A1-13 are cosmetic or redundant. |
| 8 | INFO | Possible secrets in output. | **No issue**: the browser sign-in token is redacted in the log, consumed, and caught by A1-14's raw-secret scan; the driver never emits cookies or CSRF values. |

Checked and found sound by the reviewer: exactly the two form pages changed to `origin`, no
form page left on `no-referrer`, no form-less page given `origin`, the secret-bearing URL
unchanged; the guard unchanged (empty diffs of `RequestGuard.hs`/`Application.hs`); the frozen
amendment byte-identical and the four R1-frozen files at their digests; the driver genuinely lets
the browser build every request and fails the test on errors, missing keys and timeouts; the
database assertions prove that only the legitimate submissions changed state.
