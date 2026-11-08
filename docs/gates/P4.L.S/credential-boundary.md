# P4.L.S — the subscription credential boundary (disposition for the Planner)

- Prepared 2026-10-31 by the writing agent (Implementer, manual) at the Planner's request ("Subscription credential
  boundary — requires resolution").
- Source: Anthropic, *Claude Code — Legal and compliance*, "Authentication and credential use"
  (`https://code.claude.com/docs/en/legal-and-compliance`, read 2026-10-31).

## 1. What the documentation says (quoted)

- "OAuth authentication is intended exclusively for purchasers of Claude Free, Pro, Max, Ultra, Team, and Enterprise
  subscription plans and is designed to support ordinary use of Claude Code and other native Anthropic applications."
- "Anthropic does not permit third-party developers to offer Claude.ai login into their own applications, or to route
  requests through Free, Pro, Max, or Ultra plan credentials on behalf of their users. Moreover, developers may not
  collect, store, or intermediate Claude.ai credentials or session tokens — sign-in to a Claude account must complete
  through Anthropic's own flow."
- "Nor does it prevent an end user from signing in to the unmodified Claude Code binary with their own Claude
  subscription, including where a platform hosts Claude Code …"
- For running Claude Code inside a product: "The Claude Code binary must not be modified … customers may not remove,
  disable, or restrict any authentication method built into it"; "Each end user must authenticate with their own …
  Claude subscription plan credentials".
- "Advertised usage limits for Pro, Max, and Ultra plans assume ordinary, individual usage of Claude Code and the Agent
  SDK." (The page also notes that from June 15, 2026, `claude -p` usage on subscription plans draws from a separate
  monthly Agent SDK credit.)

## 2. Disposition of the P4.L.S proxy design

**Not to be used for real subscription traffic.** In P4.L.S the proxy reads the owner's subscription token from a file
and puts it on each request in place of the CLI's placeholder: Lockstep *stores* and *intermediates* a Claude.ai
session token. Whatever the owner-only setting, that is the pattern the documentation names. The code stays (it is
what the offline qualification tests), but the subscription mode is offline-only until a decision below is taken; no
real token is ever placed for it. The API-key mode is unaffected (API keys "provisioned … for use by the customer's own
authorized users" are expressly not restricted).

## 3. The narrowest supported alternative

**The unmodified CLI authenticates itself, with the owner's own subscription, and talks to Anthropic directly; Lockstep
never holds, sees or relays the token.**

| | Now (P4.L.S proxy) | Alternative |
|---|---|---|
| Sign-in | owner runs `claude setup-token`; Lockstep's proxy reads the token | the owner signs in through Anthropic's own flow (`claude setup-token` or `/login`) and the result is given only to the CLI process, in its private home or environment, never to a Lockstep component |
| Who holds the token | the proxy (host user), per run | only the CLI process (uid 2000000000, not dumpable, private home): what C-P4.L.R3 already protects |
| Network | CLI → plain HTTP → Lockstep proxy (reads every request) → TLS → Anthropic | CLI → TLS end-to-end → Anthropic, through a **passthrough** egress filter that relays `CONNECT api.anthropic.com:443` only and cannot read the traffic |
| Binary | unmodified | unmodified; no authentication method removed |

How it keeps the CLI/tool isolation: the token lives only in the CLI's process, which no tool process can trace, read
or signal (C-P4.L.R3, measured), and the CLI already keeps the token variable out of its tools' environment (measured,
A-P4.L.S-2). A tool that starts its own `claude` or talks to the network has no credential, so it cannot open a
conversation with any model; the isolation, not the proxy, becomes what enforces one writing agent.

What changes in the egress controls (the price of not reading the traffic):

| Control (today, at the proxy) | With the passthrough |
|---|---|
| One upstream host, no redirect | kept: the filter relays `CONNECT` to `api.anthropic.com:443` only, nothing else; other hosts refused |
| Model, effort, tools, features, fields checked per request | **lost at the wire**; held by the unmodified CLI's own flags (`--model`, `--effort`, `--tools "Read Edit Bash"`, `--strict-mcp-config`, …) and the image's environment; measured in the offline checks, not enforced per request |
| One conversation a run (H2), terminal refusal (H1) | the proxy's rule is lost; replaced by "no credential outside the CLI" (above). A second conversation needs a credential no tool can reach |
| Token reservation before each request, ledger, token limit | **lost**: the request's size is not visible. Replaced by: a wall clock per run (kept), the CLI's own turn limit (`--max-turns`), a run count (kept, the helper's), and **usage recorded after each run** from the CLI's own JSON result (tokens in, out, cache), as the Bible asks ("report measured resource consumption"). The subscription's own usage limits are Anthropic's |
| Credential never in the role's container | changes: it is in the role's container, inside the CLI process alone, protected by the isolation |

Work it needs (one narrow increment, like P4.L.S): a passthrough filter (the proxy container's new mode, or a small
CONNECT relay); the helper's subscription start (the token placed for the CLI, the filter instead of the proxy, the
post-run usage record); the measurement first of which hosts the pinned CLI contacts in subscription mode without
`ANTHROPIC_BASE_URL` (if more than `api.anthropic.com`, each named and justified); frozen checks: tools cannot obtain
the token (memory, environment, files, a second CLI), only the allowed host is reachable, usage recorded. Isolation,
engine, Supervisor unchanged.

What it cannot do that today's design does: refuse a wrong model, tool or field *on the wire*, and stop a run *before*
a request that would pass a token cap. For a pinned, unmodified CLI started with fixed flags, the first is held by the
CLI; the second becomes a per-run wall clock, turn limit and after-the-fact record.

Open point, for the owner: whether an orchestrator that starts the owner's own Claude Code headlessly (`claude -p`) is
"ordinary, individual usage" in the documentation's sense is not something this agent can settle; the page points to
Anthropic sales for such questions. The alternative above removes Lockstep from the credential path, which is what the
documentation forbids it to be in.

## 4. The other path

**An API-key-backed smoke**, as C-P4.L was built: every control above stays as qualified (the proxy reads and checks
each request, reserves before sending, the dollar budget). It needs the owner's separate approval and bills the
owner's Console account; it is not a silent switch.

## 5. Recommendation

For the attended calculator smoke and Gate C-EXEC, the shortest path is the **API-key smoke** (already qualified; only
the owner's approvals remain). The **passthrough alternative** is the supported subscription path for ongoing use (the
Brigid dogfood onward), as its own narrow increment. The choice is the owner's.
