# Amendments to frozen checks for C-P4.L.R2 — for the owner's authorization

- Status: **APPROVED and applied** (authorization record below). Before approval the frozen files were unchanged
  and the amended versions were drafts in `.local/amend/`. Prepared 2026-10-29 by the writing agent (Implementer, manual) under
  `.local/plans/phase-04_update4.md` §3 and §6.
- Neither amendment weakens what the check proves: A-P4.L.R1-1 replaces an expectation that contradicts H1 with a
  stricter one; A-P4.L-1 moves the check's offline set-up from environment variables to the explicit offline-test mode
  that H3 makes the only way, and every one of its 84 checks stays as it was.

## A-P4.L.R1-1 — `scripts/lib/check-live-proxy` (C-P4.L.R1)

- Original: sha256 `0a7cbb01c71aecab05a2021c3bdbc9babafeb565736f5de6d2d1878f0b67f96d` (frozen `8d0790c`).
- Proposed: sha256 `ed6f8134a8c5a45dfa6f2af235af3720bf5153b6f2dee9f57d607226b27a523f`.
- Why the original contradicts the invariant: after the run's refusals (a duplicated model, duplicated tools, a
  regional-inference field, a service tier, no effort, an over-deep body) the check sends a valid request on the same
  run and expects `200` — the proxy admitting provider execution after the run's terminal stop. H1 requires that
  request to be refused and to reach nothing. The check's other 19 expectations are unchanged.
- Diff:

  ```diff
  @@ -146,7 +146,9 @@
   expect "a body nested too deep is refused: body-refused" test "$(line_of deep)" = "403 body-refused"
   expect "none of them reached the upstream" test "$(bodies)" = "$before"
   probe valid
  -expect "the proxy still answers afterwards" test "$(line_of valid)" = "200 -"
  +# A-P4.L.R1-1 (C-P4.L.R2 H1): a refusal ends the run's admission; the proxy answers, admits nothing.
  +expect "after the run's first refusal a valid request is refused: run-stopped" test "$(line_of valid)" = "403 run-stopped"
  +expect "and it does not reach the upstream" test "$(bodies)" = "$before"
   expect "the run's first refusal is its stop: body-refused" test "$(summary_stop "$run1")" = body-refused
  ```

- Trials:
  - original vs the new proxy: 19 of 20, the one failure exactly this line (`.local/amend/original-proxy-vs-new.txt`);
  - amended vs the old proxy (`d13ac33`): **RED**, exactly the two amended lines (the request admitted and sent;
    `.local/amend/amended-proxy-vs-old.txt`);
  - amended vs the new proxy: **GREEN**, 21 of 21 (`.local/evidence/live-proxy-20261029t200243z/results.txt`).

## A-P4.L-1 — `scripts/lib/check-live-runner` (C-P4.L)

- Original: sha256 `93f97461cf5f77bde5ebb7341e0b25ca2bc8b3566704339a5045b260b12e7943` (frozen `a6b69e2`).
- Proposed: sha256 `cb31fdd4863eba88e8a431b7eafafb2ab954000f2a2689e2fd6e645c20ef5cee`.
- Why the original contradicts the rule: it puts the helper in test mode with `LOCKSTEP_RUNNER_TEST_UPSTREAM`,
  `…_UPSTREAM_CA` and `…_EGRESS_NETWORK` inherited from the environment, with the key at `DIR/provider/credential` —
  the production key's path. That is exactly the combination H3 requires to be refused ("a test override cannot be
  enabled merely by setting an inherited environment variable on an otherwise production-configured helper"). The
  amendment sets up the explicit offline-test mode instead: the same stand-in upstream, CA and internal network, now
  in `DIR/provider/offline-test`, and the synthetic key at `DIR/provider/offline-credential`. The credential cases
  (unreadable by others, malformed, missing) move with the key. No expectation changes.
- Diff:

  ```diff
  @@ -3,10 +3,12 @@
  -# with a synthetic provider configuration and a synthetic credential, and the
  -# egress proxy's upstream replaced by a local stand-in (scripts/lib/live-standin,
  -# HTTPS with a certificate made here) on an internal network: nothing here can
  -# reach the internet, and no model provider is ever contacted. Runs the real
  +# with a synthetic provider configuration and a synthetic credential, in the
  +# helper's explicit offline-test mode (DIR/provider/offline-test, the key in
  +# DIR/provider/offline-credential; A-P4.L-1, C-P4.L.R2 H3): the egress proxy's
  +# upstream is a local stand-in (scripts/lib/live-standin, HTTPS with a certificate
  +# made here) on an internal network: nothing here can reach the internet, and no
  +# model provider is ever contacted. Runs the real
  @@ -101,8 +103,7 @@
   start_helper() {
  -  LOCKSTEP_RUNNER_TEST_LIMITS=1 LOCKSTEP_RUNNER_TEST_EGRESS_NETWORK=$upnet \
  -    LOCKSTEP_RUNNER_TEST_UPSTREAM=standin:8443 LOCKSTEP_RUNNER_TEST_UPSTREAM_CA=$work/standin.pem \
  +  LOCKSTEP_RUNNER_TEST_LIMITS=1 \
       "$root/scripts/control-helper" --state "$state" --instance "$instance" --runner \
  @@ -254,8 +255,12 @@
   chmod 600 "$state/provider/config"
  -printf '%s\n' "$secret" > "$state/provider/credential"
  -chmod 600 "$state/provider/credential"
  +# A-P4.L-1: the helper's explicit offline-test mode (its upstream, CA and internal network) and its key.
  +printf 'lockstep-offline-test 1\nupstream standin:8443\nca %s\negress-network %s\n' "$work/standin.pem" "$upnet" \
  +  > "$state/provider/offline-test"
  +chmod 600 "$state/provider/offline-test"
  +printf '%s\n' "$secret" > "$state/provider/offline-credential"
  +chmod 600 "$state/provider/offline-credential"
  @@ -396,21 +401,21 @@
  -chmod 644 "$state/provider/credential"
  +chmod 644 "$state/provider/offline-credential"
   …
  -chmod 600 "$state/provider/credential"
  -printf 'not-a-key\n' > "$state/provider/credential"
  +chmod 600 "$state/provider/offline-credential"
  +printf 'not-a-key\n' > "$state/provider/offline-credential"
   …
  -rm -f "$state/provider/credential"
  +rm -f "$state/provider/offline-credential"
   …
  -printf '%s\n' "$secret" > "$state/provider/credential"
  -chmod 600 "$state/provider/credential"
  +printf '%s\n' "$secret" > "$state/provider/offline-credential"
  +chmod 600 "$state/provider/offline-credential"
  ```

  (The full diff: `git diff --no-index scripts/lib/check-live-runner .local/amend/check-live-runner`.)

- Trials:
  - original vs the new helper: the helper refuses its environment overrides, so no live run starts and the check
    fails from its first CLI case and stops at the budget case (`.local/amend/original-runner-vs-new.txt`);
  - amended vs the old helper (`d13ac33`): **RED** — the old helper has no offline mode and no production key in
    that set-up, so every live run is refused before any container starts (nothing contacted;
    `.local/amend/amended-runner-vs-old.txt`);
  - amended vs the new helper: **GREEN**, 84 of 84 (`.local/evidence/live-20261029t200305z/results.txt`).

## Authorization record

| Amendment | Decision | By | Date |
|---|---|---|---|
| A-P4.L.R1-1 | **APPROVED** — "a valid request following a terminal refusal receives `403 run-stopped`, with no additional upstream request" | the owner, in the session | 2026-10-29 |
| A-P4.L-1 | **APPROVED** — "from inherited environment variables to the explicit offline-test configuration file and offline credential path; all 84 existing behavioral expectations must remain unchanged" | the owner, in the session | 2026-10-29 |

Scope of the authorization (the owner's words, abridged): apply only these exact amendments; verify the resulting
digests against these records; retain the RED/GREEN evidence; no other frozen-test change; no installation, real
credential, live call or Gate C-EXEC acceptance. Applied 2026-10-29: `scripts/lib/check-live-proxy` sha256
`ed6f8134a8c5a45dfa6f2af235af3720bf5153b6f2dee9f57d607226b27a523f` and `scripts/lib/check-live-runner` sha256
`cb31fdd4863eba88e8a431b7eafafb2ab954000f2a2689e2fd6e645c20ef5cee` — both equal to the proposed digests above.
