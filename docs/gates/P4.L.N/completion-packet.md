# Completion packet — native subscription authentication (C-P4.L.N)

- For: the owner and the Planner. Prepared 2026-11-01 by the writing agent (Implementer, manual) under
  `.local/plans/phase-04_update7.md` and the Planner's mount-blocker (Option D) and supersession decisions. The
  Implementer cannot accept Gate C-EXEC or mark anything Done.
- **What this delivers:** Lockstep runs the unmodified Claude Code CLI on the owner's own subscription. The CLI holds
  its own sign-in state in a dedicated Docker named volume; it talks to Anthropic over end-to-end TLS through a
  passthrough filter that cannot read the traffic. Lockstep never collects, parses, stores, substitutes or relays the
  token. No API-key billing, no token-injection proxy.
- **Not authorized here:** no real login, no provider call. Offline qualification only. The real sign-in and the
  calculator smoke are the owner's next, attended steps (§5).

## 1. HEAD, diff

- Candidate: **`05da865`**. Basis `8976c42`. Commits: `aaefedb` (freeze, RED), `130a14c` (implementation +
  retirements), `05da865` (the review's two LOW cleanups: comments and unreachable code only). Mac and the Linux clean
  clone ran at `130a14c`; `05da865` changes no exercised path (comments and dead code), re-verified by the live checks.
- Removed: the P4.L.S token-injection mode in `egress-proxy` and `control-helper`, and the frozen checks it was
  verified by (`check-live-subscription`, `live-standin-headers`) — Planner-approved supersession
  (`docs/gates/P4.L.N/supersedes.md`). API-key offline mode is unchanged.

## 2. What was built

- **The passthrough filter** (`egress-proxy passthrough`): accepts only `CONNECT <allowed-host>:443` from an explicit
  host allowlist, relays the bytes, and refuses any other host, port or method. It terminates no TLS and reads no
  request body (measured: a marker in the tunnelled bytes never reaches its log).
- **The auth volume** (Option D): a Docker named volume owned by the CLI identity (uid 2000000000), set up by the
  helper's `provider-auth-init` and signed into by `provider-auth-login` (the owner, in a temporary container running
  the unmodified CLI's own flow). The ordinary role container gains **no** new capability.
- **The helper's native run path**: a preflight (`claude auth status` against the mounted volume, no network) refuses
  an unauthenticated run cleanly; otherwise it starts the filter and the two-identity role container (C-P4.L.R3) with
  the volume mounted to the CLI only, `HTTPS_PROXY` to the filter, no token in the environment; usage is recorded in
  tokens from the CLI's own JSON output, with no dollar figure.

## 3. Qualification (offline; synthetic credentials and fixtures; no provider contacted)

- `check-live-native` (frozen `aaefedb`, amended A-P4.L.N-1, sha256 `089e1349…`): **23/23** — the filter (allow,
  refuse host, refuse method, no body read); the preflight (synthetic authenticated volume proceeds, unauthenticated
  refused and not retried); the volume owned by the CLI identity and unreadable by the tools; state persists after the
  login container is destroyed and across role-container recreation; the tree stays owned by the operator identity; no
  token in the role environment; usage in tokens, no dollars; a simulated transaction completes through the filter.
- The other frozen live checks against the rebuilt image: `check-live-isolation` **26/26**, `check-live-impersonation`
  **43/43**, `check-live-runner` **84/84**, `check-live-boundary` **83/83**, `check-live-concurrency` **17/17**,
  `check-live-proxy` **21/21**.
- Host, real Docker: `check-runner` 0 failures, `check-runner-paths` **7/7**, `lockstep-stress` PASS
  (`.local/p4ln/host-*.log`, `.local/evidence/runner-*`).
- Mac `scripts/check --integration` at `130a14c`: all six steps PASSED — unit **870/870**, integration **571/571**,
  guard clean (`.local/p4ln-check-mac.log`).
- Linux clean clone at `130a14c`: format, lint, build, unit, integration PASSED — unit **870/870**, integration
  **571/571**, case-sensitive disks (`.local/p4ln-linux.log`).
- Baseline (RED) `.local/p4ln-red-baseline.log`; GREEN evidence `.local/evidence/live-native-*/` and `.local/p4ln/`.
- Independent review `docs/reviews/phase-4-native-auth-review-2026-11-01.md`: token-intermediation prohibition
  **confirmed honored**; 0 HIGH, 0 MEDIUM, 2 LOW (dead code / stale comments), both fixed; re-verified green.

## 4. Limitations (stated plainly)

1. **Offline proves the mechanism, not Anthropic's acceptance.** The checks use a synthetic `.credentials.json` and a
   local stand-in; they do **not** show that a real subscription sign-in through the filter is accepted. That is the
   attended smoke (Planner).
2. **The egress allowlist is `api.anthropic.com` only so far.** Any further sign-in or token-refresh hosts are
   identified and reviewed at the attended setup and added to `provider/egress-hosts`; no wildcard (contract §3, §6).
3. **The filter does not inspect requests** (end-to-end TLS). The per-request model/tool/field checks and the
   one-conversation wire control of C-P4.L.R2 are gone on the native path; what stands in their place is the engine's
   single-code-writer invariant and the credential being unreachable by repository code — **not** the same guarantee
   (contract §7). The filesystem tests show the tools cannot read the volume; they are not proof against every
   in-process, model-directed file operation by the CLI itself.
4. **On a Linux host** a named volume's files written by the CLI identity are owned by uid 2000000000; this does not
   affect the macOS/OrbStack smoke host. Live auth is qualified offline only.

## 5. Operator steps for the attended calculator smoke

1. Build the image from the candidate: `scripts/provider-image`.
2. Configure `~/.local/control/provider/`: `config` (`billing subscription`, model, effort, the token/invocation
   limits — no prices), and `egress-hosts` (one host a line; start with `api.anthropic.com`).
3. Set up and sign in (the owner, once):
   - `scripts/control-helper --state <state> --provider-auth-init`
   - `scripts/control-helper --state <state> --provider-auth-login` → complete Anthropic's own sign-in in the browser.
   - If the sign-in or a role run reports an egress refusal for an Anthropic host, add that exact host to
     `egress-hosts` and note it (this is the "identified at attended setup" step).
4. Start the helper with `--runner`; the log should say `live runs on (… subscription, native …)`.
5. Run one attended calculator bug fix through the normal Lockstep workflow (Planner → frozen tests → one Implementer
   → verification → Reviewer → Supervisor commit → human Done). The Implementer does not perform or coach the fix.
6. Keep the evidence (§9 of the handoff): revision, CLI version, usage in tokens, outcome, tests, review, the
   Supervisor's Git commit, interventions, limitations. No secrets in the evidence.

Gate C-EXEC remains pending until the owner accepts the completed smoke evidence.
