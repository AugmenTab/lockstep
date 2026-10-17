# P1.3 — decision request: two conflicts between the approved design and real behaviour

- Prepared by: the writing agent (Implementer), 2026-10-17. **Nothing here is decided.**
- Basis: `v2` at `eda7d5e` (P1.1 and P1.2 ACCEPTED by the human owner at `b3a3723`).
- Design under review: recovery plan `.local/plans/phase-01-recovery.md` §4 as amended
  by §7.4; handoff `.local/plans/phase-01-recovery-handoff.md` §3.
- Rule that applies: handoff §3, Contract precondition 3: "Any conflict between this design
  and real behaviour (Wai, Warp, Orville, browser) is a narrow amendment for the human. Do
  not adapt it silently."
- State: no P1.3 test or production code exists. The draft Contract is `contract.md`
  (status DRAFT, not frozen). It is written with the recommended options below and can be
  frozen as soon as these are decided.

## D-1 — `Host` on every request vs. the frozen P1.1/P1.2 unit tests

**Design text:** "`Host` must be exactly `127.0.0.1:<port>` on every request." "`Origin` must
be exactly `http://127.0.0.1:<port>` on every non-GET/HEAD request; a missing Origin is refused."

**Conflict (Wai):** the frozen unit tests send in-process WAI requests built from
`Wai.defaultRequest`, which has **no `Host` header** and no `Origin`:

| Frozen test (digest in C-P1.1 §8 / C-P1.2 §8) | Request | Frozen expectation | Under the design as written |
|---|---|---|---|
| `test/unit/Lockstep/Web/ApplicationTest.hs` (19 GET cases) | `GET /`, `GET /api/health_check`, `GET /static/…`, removed routes | 200 / 204 / 404 | refused (missing Host) |
| same file, "POST /api/health_check is not a route" | `POST`, no Host, no Origin | 404 | refused (missing Host and Origin) |
| `test/unit/Lockstep/Web/ReadinessRouteTest.hs` (2 cases) | `GET /api/readiness`, `GET /api/health_check` | 503 / 204 | refused (missing Host) |

Browsers always send `Host` on HTTP/1.1, so a missing `Host` never comes from a browser and
cannot carry a DNS-rebinding attack. A *present* wrong `Host` (the rebinding case) is refused
under every option below.

| Option | Effect |
|---|---|
| **D-1a (recommended)** | A present `Host` must be exact on every routed request. A **missing** `Host` is refused on every `/operator/*` route and on every non-GET/HEAD request, and tolerated only on the public GET/HEAD routes (`/`, `/api/health_check`, `/api/readiness`, `/static/*`), which carry no secrets. Route recognition comes first: an unrouted path answers 404 and runs nothing, whatever its Host/Origin. All frozen tests stay valid unchanged. |
| D-1b | Missing `Host` tolerated on every route; present `Host` must be exact. Weaker for non-browser local clients. |
| D-1c | Design as written (missing `Host` refused everywhere). Needs a Planner/human-authorized amendment of the 2 frozen test files above (add `Host`). |
| D-1d | Design as written, but enforced only as WAI middleware in `Main`; `application`/`applicationWith` stay unguarded, so the frozen tests keep testing an unguarded app that is not what `serve` runs. Not recommended. |

Also part of D-1 (small, same rule): with `--port 80`, browsers send `Host: 127.0.0.1` and
`Origin: http://127.0.0.1` (the default port is omitted, RFC 9110 §4.2.1/§7.2). Recommended:
treat those as the exact forms for port 80 only.

## D-2 — sign-in POST: `Referrer-Policy: no-referrer` makes browsers send `Origin: null`

**Design text:** `GET /operator/sign-in` has `Referrer-Policy: no-referrer`; the confirm form
POSTs back; every non-GET/HEAD request needs the exact `Origin`.

**Conflict (browser), measured:** the Fetch standard serializes the request `Origin` of a
non-CORS POST as `null` when the request's referrer policy is `no-referrer`. A throwaway
probe (`evidence/origin-probe.log`, script alongside) served a page with each policy and
submitted a same-origin form:

| Page policy | Chromium 155 | Firefox ESR 153.5 |
|---|---|---|
| `no-referrer` (design) | `Origin: null`, `Sec-Fetch-Site: same-origin`, no Referer | same |
| `same-origin` | correct Origin, but `Referer: …/?token=SECRET` | same |
| `strict-origin-when-cross-origin` (browser default) | correct Origin, but `Referer: …/?token=SECRET` | same |

So, as written, the strict Origin check refuses every real browser sign-in; and any policy that
yields a real Origin leaks the token into the POST's `Referer` (outside the bounded exposure
list (a)–(c)). The probe submitted the form from a script; a user's click uses the same
Fetch rule.

| Option | Effect |
|---|---|
| **D-2a (recommended)** | Keep `no-referrer`. On **`POST /operator/sign-in` only**, accept `Origin: null` if and only if `Sec-Fetch-Site: same-origin` (a header pages cannot set) and `Host` is exact. Everywhere else the exact-Origin rule stands, `null` included. The token remains required, single-use, 5 min. Tested: `null` without `Sec-Fetch-Site`, with `cross-site`/`same-site`/`none`, and `null` on sign-out are all refused. Browsers without Fetch Metadata (Safari < 16.4, Firefox < 90) cannot sign in. |
| D-2b | Change the sign-in GET to `Referrer-Policy: same-origin`. Real Origin, but the raw token goes to our own server in the `Referer` of the POST and of the redirected GET; the exposure list would gain those two headers. |
| D-2c | Accept `Origin: null` on the sign-in POST unconditionally. Simplest; only the token protects sign-in against login CSRF. |

## D-3 (minor) — where the sign-in POST redirects

Recovery plan §4 says `303 → /`; handoff §3 says only "303 and `no-store`". `/` is the public
status page and shows no session state (its frozen tests stay as they are).

- **D-3a (recommended):** `303 → /operator`, the protected page that shows the session
  expiry and the sign-out form (needed anyway for `POST /operator/sign-out` with CSRF).
- D-3b: `303 → /` as in plan §4, with `/` unchanged; the operator then opens `/operator`.

## Information only (no decision needed unless you object)

- No new package enters the build closure. The library adds **direct** dependencies on
  `memory` (constant-time compare), `base64-bytestring` (base64url) and `cookie` (parsing
  `Cookie`), all already linked transitively and listed in the P1.2 license inventory
  (`docs/gates/P1.2/evidence/licenses.txt`). `scripts/licenses` will be re-run.
- No Henforcer config change, no forbidden-facility exclusion change. Runner additions are
  named in the draft Contract §8.

## Answer needed

One line is enough, e.g. "D-1a, D-2a, D-3a". Any other option, or a change to a default, is
equally fine. I will then freeze C-P1.3 with those choices recorded as amendments in your
words, and continue under the Phase 1 handoff.
