# C-P4.L.N supersedes the P4.L.S subscription mode — a frozen-test decision for the Planner

- Prepared 2026-10-31 by the writing agent (Implementer, manual). Not yet acted on.

## The situation

P4.L.S (`3764f93`, qualified `bfd2367`/`8976c42`) added a `billing subscription` mode in which **the egress proxy
holds the owner's subscription token and injects it** on each request (`Authorization: Bearer`). Its frozen check
`scripts/lib/check-live-subscription` and the frozen stand-in `scripts/lib/live-standin-headers` verify exactly that
injection.

The owner then directed (update7) that Lockstep must **never** substitute or relay the subscription token — the
unmodified CLI holds its own. C-P4.L.N implements that: the proxy's subscription injection is removed and replaced by a
passthrough filter that cannot read the token. Under C-P4.L.N, `billing subscription` means **native** (the CLI
authenticates itself), not injection.

So `check-live-subscription` and `live-standin-headers` now test a behaviour that C-P4.L.N removes. They cannot stay
frozen as-is through this increment.

## The decision needed (frozen tests; the Planner's)

1. **Retire** `scripts/lib/check-live-subscription` and `scripts/lib/live-standin-headers` (frozen `3764f93`), since
   the token-injection mode they verify is being removed; **and**
2. **replace** them with `scripts/lib/check-live-native` and its stand-in (this contract §3), which verify the native
   path (preflight gate, the passthrough filter, the credential mounted only to the CLI's identity).

The subscription-injection code in `scripts/runner/provider/egress-proxy` and `scripts/control-helper` (added in
`97d24f2`) is removed in the same increment. The API-key mode and all other frozen live checks are unchanged.

Nothing is deleted until this is approved. If instead the Planner wants the injection mode kept (dormant) and its
check retained, say so and I will keep both and gate native mode separately.

## What is ready now (pending the decision)

- The contract `docs/gates/P4.L.N/contract.md`, corrected for the Planner's three clarifications.
- The passthrough filter, built in `scripts/runner/provider/egress-proxy` (uncommitted in the working tree) and
  proven offline: an allowed host tunnels end-to-end TLS, a disallowed host is refused at `CONNECT`, and the filter's
  own log never contains the request or response body (it cannot read the token). Evidence:
  `.local/p4ln/filter-trial.sh` output.
- The test tool `scripts/lib/live-connect-probe` (uncommitted).

## The freeze plan, once decided

RED → implementation → GREEN, as the Planner directed: freeze `check-live-native` (+ stand-in) and the retirement;
remove the injection mode; the helper's native mode (preflight `claude auth status` against the mounted config dir;
the config dir mounted to the CLI identity only; the filter instead of the proxy; usage from `result.json`);
offline-qualify what is offline-qualifiable (the filter, the preflight-refuse gate, the credential mount isolation);
Mac + Linux; one review. **Offline cannot prove a real authenticated run** (the CLI gates on a real login, which is
the attended smoke) — stated as a limitation, consistent with the Planner's note that the mocked preflight is offline
behaviour only.
