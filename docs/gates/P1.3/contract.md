# P1.3 Contract — Local operator trust and request security

- Contract ID: `C-P1.3@v1`
- Status: **FROZEN** (2026-10-17). Written for the human owner's decisions of 2026-10-17
  (`decision-request.md`, "Human decisions"): **D-1a, D-2d, D-3a**; places that depend on them
  are marked **[D-n]**. The D-2d browser check required before the freeze passed
  (`evidence/referrer-origin-probe.log`).
- Basis: `v2` at `eda7d5e`. P1.1 and P1.2 ACCEPTED by the human owner at `b3a3723`
  (`docs/gates/P1.2/r1-acceptance-packet.md`).
- Authority: the human owner's P1.3 design decision (recovery plan §7.4) over recovery plan
  §4; execution rules in `.local/plans/phase-01-recovery-handoff.md` §3 and
  `.local/plans/phase-01.md` §P1.3; the owner's continuation of 2026-10-17 ("Resume at P1.3
  under the existing full-phase handoff and recorded human-approved authentication design").
- Traces: FR-APP-05, NFR-04, Bible v2.1 §38.1, Plan v0.2 P1.3 ("Unauthorized POST refused;
  browser cannot reveal CLI secrets").
- Writer: the single writing agent (manual; no v2 Supervisor).

## 1. Objective

An explicit local operator session: the OS user who can run `lockstep` with the 0600
`LOCKSTEP_CONFIG` issues a single-use sign-in link; the browser exchanges it for a
server-side session; every mutating request is checked for Host, Origin, session and CSRF;
the raw token and the database password never leak beyond the bounded places.

## 2. Decisions inside this Contract

| # | Decision |
|---|---|
| E1 | **Trust anchor.** Whoever can run `lockstep` as the OS user owning the 0600 `LOCKSTEP_CONFIG`. No passphrase (§7.4). |
| E2 | **Issue.** `lockstep operator sign-in [--port N]` (default 8000; same port parser as `serve`). Requires `LOCKSTEP_CONFIG` (else exit 66) and readiness `Ready` (else exit 69, readiness code on stderr). Generates 32 bytes with crypton's `getRandomBytes`; the token text is unpadded base64url (43 characters). Stores only the SHA-256 digest with `expires_at = now() + 5 minutes` (database clock). Prints exactly one line to stdout: `http://127.0.0.1:<N>/operator/sign-in?token=<token>` (port 80: `http://127.0.0.1/…` [D-1]). The token is never read from argv (there is no token option), never logged, and its type's `Show` is `<redacted>`. |
| E3 | **Confirm page.** `GET /operator/sign-in?token=T` validates only the token's *shape* (43 base64url characters), touches no database row, and renders a confirmation form with `T` in one hidden field. Response headers: `Cache-Control: no-store`, `Referrer-Policy: origin` **[D-2d]** (browsers then send the exact `Origin` on the form POST and only the bare origin `http://127.0.0.1:<port>/` as `Referer`, never the path or token; measured in `evidence/referrer-origin-probe.log`), `Content-Security-Policy: default-src 'none'; style-src 'self'; form-action 'self'; base-uri 'none'; frame-ancestors 'none'`. The page loads only `/static/lockstep.css` (same origin; its Referer is the bare origin) and has no outbound link. A missing or malformed token → 400 refusal page that does not echo the input, with `Referrer-Policy: no-referrer`. |
| E4 | **Exchange.** `POST /operator/sign-in` (form field `token`) runs **one PostgreSQL transaction**: `UPDATE lockstep_operator_sign_in_tokens SET consumed_at = now() WHERE digest = $1 AND consumed_at IS NULL AND expires_at > now() RETURNING digest`; on one row, `INSERT` a session (32 CSPRNG bytes, digest stored, `expires_at = now() + 12 hours`, absolute). Zero rows → 403 refusal page ("invalid, already used or expired; run `lockstep operator sign-in` again"), no echo, nothing created. A missing or malformed `token` field (including a body that is not valid form data or UTF-8) → 400, nothing consulted. Form bodies (sign-in and sign-out) over 16 KiB → 413; the server drains such a body up to 1 MiB before answering so the client sees the response. Success → `303`, `Location: /operator` **[D-3]**, `Set-Cookie: lockstep_session=<token>; Path=/; HttpOnly; SameSite=Strict; Max-Age=43200`, `Cache-Control: no-store`, `Referrer-Policy: no-referrer`. `Secure` is **not** set: plain HTTP on loopback (recorded per §4 of the plan). |
| E5 | **Session.** Valid iff the cookie decodes to 32 bytes, its digest exists, `revoked_at IS NULL` and `expires_at > now()`. A malformed `Cookie` header or value counts as no session (401), never 500. |
| E6 | **CSRF.** `csrf = base64url(HMAC-SHA256(key = raw session token bytes, message = "lockstep-csrf-v1"))`, computed per request, nothing stored. Hidden field `csrf` on every form of a protected page; compared with `Data.ByteArray.constEq`. |
| E7 | **Request guard, in this order** [D-1, D-2]: (1) unknown method or unrouted path → 404, nothing runs; (2) Host: a present `Host` must equal `127.0.0.1:<port>`, else 403; a missing `Host` → 403 on `/operator/*` and on every non-GET/HEAD request, tolerated only on the public GET/HEAD routes; `localhost` is never accepted; (3) every non-GET/HEAD request, `POST /operator/sign-in` included: `Origin` must equal `http://127.0.0.1:<port>`, else 403; there is **no exception** (`null`, missing, foreign, other port all refused; `Sec-Fetch-Site` is not consulted) **[D-2d]**; port 80: the exact forms are `Host: 127.0.0.1` and `Origin: http://127.0.0.1` **[D-1a]**; (4) protected route without a valid session → 401 (HTML page saying to run `lockstep operator sign-in`); (5) protected POST with a missing/invalid `csrf` → 403, session unchanged. |
| E8 | **Routes.** Public: `GET /`, `GET /api/health_check`, `GET /api/readiness`, `/static/*` (unchanged), `GET`/`POST /operator/sign-in`. Protected: `GET /operator` (session expiry + sign-out form), `POST /operator/sign-out` (revokes the current session, clears the cookie with `Max-Age=0`, `303 → /`). Every `/operator*` response carries `Cache-Control: no-store`; every one carries `Referrer-Policy: no-referrer` except the 200 confirm page of `GET /operator/sign-in`, which carries `Referrer-Policy: origin` (E3) **[D-2d]**. |
| E9 | **CLI revoke.** `lockstep operator sign-out-all` sets `revoked_at = now()` on every session that is unrevoked and unexpired and prints `revoked sessions: N` (N = those sessions). Same config/readiness rules and exit codes as E2. |
| E10 | **Migration `0002`** (append-only; ADR-0002 backup gate applies to any database already at revision 1): `lockstep_operator_sign_in_tokens(digest bytea PRIMARY KEY CHECK (octet_length(digest) = 32), created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL, consumed_at timestamptz)` and `lockstep_operator_sessions(digest bytea PRIMARY KEY CHECK (octet_length(digest) = 32), created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL, revoked_at timestamptz)`. |
| E11 | **Logging.** No request logging is added; nothing logs a request target or query string. Warp's `setOnException` is replaced so that it logs only a fixed exception class (Warp's default can print a malformed request line). The existing `EXCEPTION app:` log line cannot contain a token: handlers hold tokens only as redacted types and SQL errors carry digests. |
| E12 | **Layering.** Token generation, digests and CSRF live in `Lockstep.Foundation.OperatorToken` (pure + CSPRNG, no Lockstep imports); storage in `Lockstep.Persistence.OperatorSessions`; operations in `Lockstep.Application.OperatorTrust` (used by both CLI and Web); HTTP in `Lockstep.Web.Operator` and `Lockstep.Web.RequestGuard`. No Henforcer config change. |
| E13 | **Dependencies.** Library adds direct dependencies `memory` (constant-time compare, base64url) and `cookie` (`Cookie` parsing), both already in the lib+exe closure (P1.2 license inventory). `base64-bytestring`, named in the decision request, is not needed (`memory` encodes base64url). No new package. `scripts/licenses` is re-run and must show no new linked package. |

## 3. Allowed paths

`src/Lockstep/{Foundation,Persistence,Application,Web}/**`, `app/lockstep/Main.hs`,
`test/unit/**` and `test/integration/**` (**new files only**, plus the runner additions in §8),
`package.yaml`, `lockstep.cabal`, `README.md`, `docs/gates/P1.3/**`.

Not allowed without a stop: any frozen P1.1/P1.2 test, fixture or script; `henforcer.toml`,
`henforcer-tests.toml`; `.hlint.yaml`; `scripts/lib/check-forbidden-facilities`;
`stack.yaml`/`stack.yaml.lock` (no new package is expected); `Dockerfile`.

Out of scope: typed commands/receipts (P1.4), dispatcher (P1.5), command center (P1.6),
remote operation, any non-loopback bind.

## 4. Production API the tests bind to (to be confirmed by the stub compile)

```haskell
-- Lockstep.Foundation.OperatorToken
data RawToken                      -- 32 bytes; Show = "<redacted>"
generateToken :: IO RawToken       -- crypton getRandomBytes
encodeToken :: RawToken -> Text    -- unpadded base64url, 43 chars
decodeToken :: Text -> Maybe RawToken
tokenDigest :: RawToken -> ByteString            -- SHA-256, 32 bytes
csrfFor :: RawToken -> Text                      -- E6
csrfMatches :: RawToken -> Text -> Bool          -- constant time

-- Lockstep.Foundation.Cli (additions)
Command: ... | OperatorSignIn Port | OperatorSignOutAll

-- Lockstep.Application.OperatorTrust
data SignInRefusal = SignInTokenRefused | SignInNotReady NotReadyReason
issueSignIn :: DatabaseRuntime -> IO (Either NotReadyReason RawToken)
exchangeSignIn :: DatabaseRuntime -> RawToken -> IO (Either SignInRefusal RawToken)  -- new session token
data Session = Session { sessionExpiresAt :: UTCTime }
lookupSession :: DatabaseRuntime -> RawToken -> IO (Maybe Session)
revokeSession :: DatabaseRuntime -> RawToken -> IO (Either NotReadyReason ())
revokeAllSessions :: DatabaseRuntime -> IO (Either NotReadyReason Int)
signInUrl :: Port -> RawToken -> Text

-- Lockstep.Web.RequestGuard (pure)
data GuardRefusal = HostRefused | OriginRefused
data RouteClass = PublicRead | OperatorRoute    -- [D-2d]: sign-in needs no class of its own
guardRequest :: Port -> RouteClass -> Wai.Request -> Either GuardRefusal ()
```

## 5. Tests (frozen before implementation; §8)

Unit (`lockstep-unit`, no network, in-process WAI):

| Area | Cases |
|---|---|
| Token | 32 random bytes → 43-char base64url, round trip; two tokens differ; malformed text (wrong length, `+`/`/`/`=`, non-ASCII, empty) → `Nothing`; digest is SHA-256 of the raw bytes (known vector); `show` is `<redacted>` |
| CSRF | deterministic per session; differs between sessions; matches a known HMAC-SHA256 vector; wrong, empty or other-session value → `False` |
| Guard [D-1, D-2] | exact Host → ok; `localhost:P`, other port, other host, `127.0.0.1` without port (P ≠ 80) → `HostRefused`; missing Host → ok on `PublicRead` GET, refused on `OperatorRoute` and on POST; POST: exact Origin ok; missing, foreign, other port, `null` → `OriginRefused`; `OperatorRoute` POST (sign-in's class): exact Origin ok, `null` → refused with and without `Sec-Fetch-Site: same-origin` [D-2d]; port 80 forms |
| CLI | `operator sign-in` → port 8000; `--port N` / `--port=N`; `operator sign-out-all`; `operator` alone → `MissingSubcommand`; `operator frob` → `UnknownCommand`; `--token X` → `UnknownOption`; extra arguments refused; P1.1/P1.2 commands unchanged |
| App (no database) | `GET /operator` → 401; `POST /operator/sign-out` with exact Host/Origin, no session → 401; foreign Host on `GET /` → 403; missing Origin on `POST /operator/sign-out` → 403; malformed `Cookie` → 401, not 500; `GET /operator/sign-in?token=<valid shape>` → 200 with `no-store`, `Referrer-Policy: origin` [D-2d], the CSP, the token exactly once (in a hidden input), no `src`/`href` that is absolute or protocol-relative; malformed token → 400 without echo, with `no-referrer`; `POST /operator/sign-in` without a database → 503 refusal without echo; P1.1/P1.2 routes unchanged |

Integration (`lockstep-integration`, real PostgreSQL 17.11 + the real binary over HTTP):

| Case | Asserts |
|---|---|
| Issue | `operator sign-in --port P` exits 0, prints one URL for `127.0.0.1:P`; the table holds `sha256(token)` and never the raw token or its text; expiry ≈ 5 min |
| Not ready | `operator sign-in` against an unmigrated DB → exit 69; unset config → exit 66 |
| Happy path | GET confirm → POST (exact Origin) → 303 to `/operator` [D-3] with the cookie attributes of E4 and `no-store`; `GET /operator` with the cookie → 200 shows the expiry and a sign-out form; sign-out with CSRF → 303, cookie cleared; then `GET /operator` → 401 |
| Browser-shaped sign-in [D-2d] | the GET confirm page carries `Referrer-Policy: origin`; POST with exact `Origin`, `Referer: http://127.0.0.1:P/` and `Sec-Fetch-Site: same-origin` → 303; POST with `Origin: null` + `Sec-Fetch-Site: same-origin` → 403 and the token is **not** consumed (a later exact-Origin POST with it → 303) |
| Token refusals | reused token → 403; expired (row set to the past) → 403; unknown well-formed token → 403; none creates a session |
| Parallel | two concurrent POSTs with one token → exactly one 303 and one session row |
| Session refusals | expired session (row set to the past) → 401; after `operator sign-out-all` (prints the count of unrevoked, unexpired sessions; a second run prints 0) → 401; a sign-out with a missing or wrong `csrf` → 403 and the session still works |
| Origin/Host over HTTP | foreign `Host`, `Host: localhost:P`, foreign `Origin`, missing `Origin` on sign-out → 403 |
| Malformed | garbage cookie, over-long cookie, non-UTF-8 form body, missing form field (400), 200 kB form body → 4xx, never 500; the token still works afterwards |
| Bounded exposure | the raw token appears only in the CLI stdout line, the GET request URL and once in the GET body; it is absent from: server stdout/stderr, every other response body and header (POST 303, `Location`, `/`, `/operator`, refusal pages for used/expired tokens), CLI stderr |
| DB password | absent from every output, page and CLI stream of this suite |
| Backup gate (CLI) | a database at revision 1 (migration 0001 only) with `db migrate` and no flag → exit 75, nothing applied; with `--no-backup` → applies `0002` |

## 6. Verification

Pre-freeze: candidate tests compile against type-only stubs of §4 under the package flags
(`-Weverything -Werror`) and the **post-change** Henforcer configs (unchanged files:
`henforcer.toml`, `henforcer-tests.toml`); fourmolu and hlint clean; baseline log shows only
missing-module/export failures against the current code.

Acceptance: `scripts/check --integration` from a fresh clone and the canonical Linux-clone
procedure; frozen-digest verification for P1.1, P1.2 (§8/§9.1) and P1.3; runner diffs
additive only; `scripts/licenses`; one manual operator run (real `serve` + CLI sign-in,
browser-shaped requests with `curl`) recorded with redaction checks. A real-browser run is
part of P1.7's A1, not of P1.3.

## 7. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test; frozen tests never edited. Stop
on: a Wai/Warp/Orville/browser behaviour that makes a frozen expectation impossible; any path
outside §3; a new linked package or license exception; any design question §2 does not
settle. Rollback: revert the P1.3 commits; migration `0002` on an operator database is
handled by `scripts/db restore` of the pre-migration backup (ADR-0002).

## 8. Freeze record

Frozen 2026-10-17 by the writing agent (manual; no v2 Supervisor), after the owner's D-1a,
D-2d, D-3a and the passing D-2d browser probe. Frozen test files never change in P1.3.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Foundation/OperatorTokenTest.hs` | `d892988ff765d3951aa5a8259fb3c44180454766ba45242761f3917ecd81807e` |
| `test/unit/Lockstep/Foundation/CliOperatorTest.hs` | `bb0e6f1b896bd1a6a4d1930f880af3c50471484e90ac599eb88ad080e5e9c8ab` |
| `test/unit/Lockstep/Web/RequestGuardTest.hs` | `cfd2ac9011f57a7fc6a1f44e05d756c4b5f4ef6f31be848ecfe72912859b6b7f` |
| `test/unit/Lockstep/Web/OperatorRoutesTest.hs` | `8cf3385ea8646bbc3d7d7bbd8a938da6872ccba1964acae5de3fbfefc5ee9c30` |
| `test/integration/Lockstep/OperatorTrustTest.hs` | `bd708e562e36e1a5efb77192ca92210cc161320a57ae2969924224272179cb06` |
| `test/integration/Lockstep/Support/Http.hs` (new helper) | `aac479f47a4cd9969d0b93623e809f076f1738500dc0bf7334619c4f1b8aa8a8` |
| `test/unit/Main.hs` (runner, additive) | `faa4222b234919f542d4763a822cf35ef8787d600be1fef2990456f57529eba1` |
| `test/integration/Main.hs` (runner, additive) | `c4c2a940398262804009b412e13310e04f598e1143f4a0e1bedc08f067ea99f0` |

Runner changes (named in advance, additive only, per C-P1.2 §9.2 A3): `test/unit/Main.hs` gains
`OperatorTokenTest`, `RequestGuardTest`, `CliOperatorTest`, `OperatorRoutesTest`;
`test/integration/Main.hs` gains `OperatorTrustTest` (8 + 2 added lines, 0 removed). New
helper `test/integration/Lockstep/Support/Http.hs`; the frozen `Support/Process.hs` and
`Support/Postgres.hs` are reused unchanged. No Henforcer config change; no forbidden-facility
exclusion change.

Pre-freeze verification (§6):
- Type-only stubs of §4 (scratch, not committed: `Foundation.OperatorToken`, `Web.RequestGuard`,
  the two `Command` constructors) — both suites compile under `--pedantic`
  (`-Weverything -Werror`) and the unchanged Henforcer configs; boundary fixtures still
  rejected: `evidence/prefreeze-stub-build.log`.
- fourmolu: 0 files changed; lint step (hlint, partial-function fixture, forbidden facilities,
  source paths, Henforcer config consistency): clean.
- Baseline against the current code (scratch clone of `4d799cc` plus only the test files):
  failures are only the missing modules `Lockstep.Foundation.OperatorToken`,
  `Lockstep.Web.RequestGuard` and the missing constructors `OperatorSignIn`,
  `OperatorSignOutAll`: `evidence/prefreeze-baseline.log`.
- Expectations checked against real behaviour before the freeze: in-process WAI requests
  without `Host` (D-1a), browser `Origin`/`Referer` (D-2d probe), the row lock that serializes
  two exchanges of one token, and that `sign-out-all` counts only live sessions (E9).
