# Gate A — independent read-only review and dispositions

- Reviewer: a separate **read-only** reviewer agent (same model family as the writer; no edit,
  write, build, Docker or network use; read files and read-only git only). **Not a human review.**
- Scope: `git diff b3a3723..95ca7c2 -- src app scripts static test package.yaml` against the
  P1.3–P1.7 Contracts, VISUAL_EVIDENCE_CONTRACT and TESTING_STRATEGY §8; frozen-test digests.
- Date: 2026-10-18. Result: **no HIGH findings**; 4 MEDIUM, 9 LOW, 4 INFO.
- Dispositions by the writing agent (Implementer); fixes in `60235ed` and `31d1626`. Items marked
  **owner** need the human owner's decision; the agent did not decide them.

| # | Sev. | Finding (summary) | Disposition |
|---|---|---|---|
| 1 | MEDIUM | The host-only session cookie (`Path=/`, no `Secure`) is sent to **every service on 127.0.0.1, any port**; browsers scope cookies by host, not port, and other ports are same-site. A local process that receives it gets full operator authority (it can forge Host/Origin and derive the CSRF value). | **Owner.** A real fix needs host isolation (a distinct loopback name) or a narrower `Path`, which conflict with D-1a and C-P1.3 E4 (`Path=/`). Recorded as a known limitation in the Gate A report. Options are listed there. |
| 2 | MEDIUM | Protected pages lacked `frame-ancestors`/`X-Frame-Options`, so a page on another 127.0.0.1 port could frame them and clickjack forms. | **Fixed** (`60235ed`): every operator page sends `Content-Security-Policy: frame-ancestors 'none'` and `X-Frame-Options: DENY` (the confirm page keeps its full E3 CSP, which includes `frame-ancestors 'none'`). Checked by A1-06b. No frozen test covers it (noted). |
| 3 | MEDIUM | "No non-loopback listener" under host networking was unmeasured on the Mac. | **Fixed**: A1-04b records `lsof` on the Mac and probes the LAN address. Measured: only `127.0.0.1:<port>` (OrbStack), LAN refused. The runtime is OrbStack, not Docker Desktop: the wording was corrected. |
| 4 | MEDIUM | Shim resolution was checked after the unit tests and outside stack's environment (which prepends its own directories); TESTING_STRATEGY §8.2 orders it before the tests. | **Fixed**: `check-step` asserts, before the unit and integration tests, that each CLI resolves to its shim inside `stack exec`. **Residual deviation (owner may confirm):** PATH is the shim directory plus the dev image's PATH (system and toolchain directories), not a hand-built "toolchain only" list. |
| 5 | LOW | A1-14 `token_leaks` arithmetic bug (false failure); password extraction could silently match nothing. | **Fixed**: run 1's A1-14 failed for this reason; it is kept as history. Password extraction is now asserted. |
| 6 | LOW | A1's "zero live-model calls" could only pass. | **Fixed**: A1-14 now also asserts, inside the service container, that `claude` resolves to the shim and a canary call is logged (exit 97). |
| 7 | LOW | A rename could commit without a receipt if the insert returned no row (unreachable today). | **Fixed**: that case now aborts the transaction. |
| 8 | LOW | Dispatcher outcomes and errors were hidden or mislabelled; `forkIO` hid thread death; no attempt limit. | **Fixed** except the attempt limit (recorded as a limitation; jobs are no-ops). |
| 9 | LOW | The outcome digest's error branch is never compared between SQL and Haskell. | **Recorded** (limitation); a test needs a new Contract. |
| 10 | LOW | Job evidence limits: PASSED from `state` only; rule 4 cannot fire for job rows; the digest covers the displayed row only. | **Recorded** in the Gate A limitations. |
| 11 | LOW | Import-check regex missed PackageImports/SOURCE/safe; the self-test accepted any failure. | **Fixed**: wider regex (tested with a PackageImports case); each self-test case checks its failure message. |
| 12 | LOW | A page on another port can plant a second `lockstep_session` cookie and force 401s (DoS only). | **Recorded** with finding 1 (owner). |
| 13 | LOW | Sign-out ignored a revoke failure; DB errors in session lookup show 401; generic refusal messages. | **Fixed** the sign-out case (now 503). The rest is recorded. |
| 14 | INFO | No test for HTML escaping. | **Real defect found by acting on this finding.** A1 run 2's escaping check (A1-12b) showed Brigid 0.4's `A.value` writes its text unescaped, so a workspace name containing `"` broke out of the rename form's `value` attribute (HTML/script injection into the operator page by whoever can set the name). Text nodes were already escaped. **Fixed** in `31d1626`: every `value` attribute is written through Brigid's escaping custom-attribute path, with ampersands encoded. A1 run 3 checks it. The upstream Brigid behaviour is recorded as a dependency issue. No frozen test (noted). |
| 15 | INFO | R-P1.5-1's `jobState` maps unknown states to `failed`. | **No change**: harmless under the CHECK constraint; the owner approved the exact diff. |
| 16 | INFO | `sed` assumes compact JSON config; sentinel directories accumulate; A1-13 downloads Chromium at run time and passes the session on the `docker run` line; `LOCKSTEP_SERVICE_SENTINEL_DIR` must be relative. | **Recorded** (limitations). |
| 17 | INFO | No dispatcher runs if the DB becomes ready after `serve` starts. | **Recorded**; documented in the operator guide. |

Checked and found sound by the reviewer (summary): frozen tests intact (19/19 at their contract
digests; only R-P1.5-1 after a freeze, byte for byte); no idempotency or stale-revision defect;
every mutating route guarded (exact Host and Origin; session and CSRF on protected POSTs);
CSPRNG tokens stored only as digests, constant-time comparisons, HMAC CSRF; atomic token
exchange; dispatcher updates conditional on owner and state, released on SIGTERM; only an
effective PASSED renders green; step 5 fails rather than skips; no partial functions.
