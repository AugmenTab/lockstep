# P1.1 Contract — Minimal Launchpad-derived application

- Contract ID: `C-P1.1@v1`
- Status: **FROZEN** at the test-freeze commit named in §8 (manual; no v2 Supervisor)
- Writer: one manual agent session (single production-code writer)
- Basis: branch `v2` at `a97bd0ce3aaf1f0947561aab7a6238321885dbfa` (Gate P0 ACCEPTED);
  Launchpad `11886bf73c2e3ac69a6839af28b97ba79bbee5fb`, tree `2d3f3d7c…`, verified
  equal to `.local/launchpad-main.zip` by AC-P0-05 (`evidence/AC-P0-05-provenance.md`)
- Input (not authority): Gate P0 report §5 proposed Contract; Phase 1 handoff
  `.local/plans/phase-01.md` §P1.1
- Traces: FR-APP-01, FR-APP-02 (initial slice), NFR-07, NFR-11; ARCHITECTURE §1–§5

## 1. Objective

Bring the smallest useful Launchpad-derived Haskell application into `v2`: one
`lockstep` package, one `lockstep` executable with a `serve` subcommand, a
Brigid-rendered **liveness** page and `GET /api/health_check` → 204, bound to
`127.0.0.1` by default, reproducibly built and tested in the dev container.

## 2. Decisions taken inside this Contract

| # | Decision | Rationale | Reversible? |
|---|---|---|---|
| D1 | Bind host is **not configurable** in P1.1. `BindHost` has one constructor, `Loopback` (`127.0.0.1`). | FR-APP-05 loopback default; "never turn on public bind as a convenience". A public bind is unrepresentable rather than merely defaulted off. | Yes, by a later Contract with its own security tests |
| D2 | Default port **8000** (Launchpad's value), overridable with `--port N` or `--port=N`. Not assumed approved: it is recorded here and shown in the Gate A packet for human review. Not materially open: loopback-only, any free unprivileged port works, one flag overrides it. | No Python-reference precedent; keeping the template value avoids an arbitrary new number | Yes |
| D3 | Argument ambiguity resolved: **no `--port` option** → default 8000; **`--port` with no value** → typed `MissingOptionValue "--port"`; non-numeric → `InvalidPort`; outside 1–65535 → `PortOutOfRange`; repeated `--port` → `DuplicateOption`; any other option (incl. `--host`) → `UnknownOption`. Usage errors exit 64 and do not start a server. | Handoff P1.1 bullet 2 | — |
| D4 | No JSON config file in P1.1. Launchpad's config (`business_config`, `database`, `rollbar`) is not imported; the database config returns with P1.2 under DG-02. Rollbar removal is proven by absence (dependency and source grep) rather than by a config parser that does not exist yet. | Smallest coherent slice; avoids a config file whose only content would be removed blocks | P1.2 adds config |
| D5 | Hand-written total argument parser (no optparse-applicative) so errors are a closed sum type. | Typed refusals; no new dependency | Yes |
| D6 | Static assets are **embedded** in the binary (`file-embed`) and served by the WAI app under `/static/<name>` from an explicit allowlist. No nginx. | NFR-07 single binary; Launchpad served static files through nginx, which is removed | Yes |
| D7 | No `APP_ENV`, HTTP client manager, Orville pool, Ogma, theme, user model or authentication in P1.1. | Unused until P1.2/P1.3; external effects removed | Later Contracts |
| D9 | **Amendment (human-approved).** `allow-newer: false` cannot build Launchpad's pins on GHC 9.10: `integer-types-0.1.4.1` (latest release, no relaxed revision) caps `base <4.20`/`hashable <1.5`, and `libphonenumber-0.1.3.0` caps `base <4.20`. Both are Brigid dependencies, and Brigid's `main` is the pinned commit. `stack.yaml` therefore sets `allow-newer: true` with `allow-newer-deps: [integer-types, libphonenumber]`; all other packages keep their bounds. `scripts/check` refuses any other scope. | Narrowest form of what Launchpad did globally. Evidence: `.local/evidence/P1.1/deps-resolve-2.log`. Human: "They're fine, don't waste time." (2026-10-17) | Yes, when upstream bounds are relaxed |
| D10 | Brigid's transitive dependencies `ogma`, `libphonenumber` (+ C++ `libphonenumber`/`protobuf` system libraries) and `beeline-http-client` are kept as **libraries**. Launchpad's Ogma i18n *configuration* stays removed. | Brigid requires them; not used by Lockstep code | — |
| D8 | Request exceptions are logged to stdout and rethrown (Warp answers 500). Rollbar reporting removed. | Bible §3.4.3: no unauthorized external effect | — |

## 3. Allowed paths

`package.yaml`, `lockstep.cabal` (generated), `stack.yaml`, `stack.yaml.lock`,
`app/lockstep/**`, `src/Lockstep/Foundation/**`, `src/Lockstep/Web/**`,
`static/**`, `test/unit/**`, `test/integration/**`, `test/fixtures/**`,
`scripts/**`, `Dockerfile`, `.dockerignore`, `.gitignore`, `henforcer.toml`,
`.hlint.yaml`, `fourmolu.yaml`, `LICENSE-LAUNCHPAD`, `THIRD_PARTY_LICENSES.md`,
`README.md`, `docs/gates/P1.1/**`, and status lines in `docs/governance/*`.

Out of scope: database (P1.2), operator trust/CSRF (P1.3), commands (P1.4),
dispatcher (P1.5), command-center UI (P1.6), live-model guard (P1.7), any Kernel,
Persistence, Application, Effects or provider module.

## 4a. Production API the tests bind to

```haskell
-- Lockstep.Foundation.Config
data BindHost = Loopback                                   -- Eq, Show
data Port                                                  -- Eq, Show; abstract
mkPort :: Integer -> Maybe Port                            -- 1..65535
portNumber :: Port -> Int
defaultPort :: Port                                        -- 8000
data ServeConfig = ServeConfig { serveHost :: BindHost, servePort :: Port }
defaultServeConfig :: ServeConfig

-- Lockstep.Foundation.Cli
data Command = Serve ServeConfig                            -- Eq, Show
data CliError = NoCommand | UnknownCommand String | UnknownOption String
  | MissingOptionValue String | DuplicateOption String
  | InvalidPort String | PortOutOfRange Integer | UnexpectedArgument String
parseArgs :: [String] -> Either CliError Command

-- Lockstep.Web.Server
serverSettings :: ServeConfig -> Warp.Settings

-- Lockstep.Web.Application
application :: ServeConfig -> (LogStr -> IO ()) -> Wai.Application
```

## 4. Tests (frozen before implementation; §8)

Unit suite `lockstep-unit` (no network, no DB; run with `--network none`):

| Test | Asserts | Class |
|---|---|---|
| `Cli/serve with no options` | `Serve (ServeConfig Loopback 8000)` | positive |
| `Cli/--port N`, `--port=N` | port N | positive |
| `Cli/--port missing value` | `Left (MissingOptionValue "--port")` | negative |
| `Cli/non-numeric, 0, 65536, negative` | `InvalidPort` / `PortOutOfRange` | negative |
| `Cli/duplicate --port`, `--host 0.0.0.0`, unknown subcommand, no subcommand, extra positional | typed refusal for each | refusal |
| `Server/host` | Warp settings host is `127.0.0.1`; port is the configured port | positive |
| `Application/health` | `GET /api/health_check` → 204, empty body; `POST` → 404 | positive / negative |
| `Application/liveness` | `GET /` → 200 `text/html`; says liveness only and database readiness **not checked**; links `/static/lockstep.css`; contains no `pico`, `hyperscript` or `rollbar` | positive |
| `Application/removed routes` | `/app`, `/app/login`, `/app/signup`, `/app/admin/users`, `/app/account/profile`, `/app/logout`, `/api/docs`, `/api/test_authentication`, `/mobile` → 404 | negative |
| `Application/static` | `/static/lockstep.css` → 200 `text/css`; `/static/css/pico.min.css`, `/static/js/_hyperscript.min.js`, `/static/../package.yaml` → 404 | positive / negative |

Integration suite `lockstep-integration` (real `lockstep` process, real TCP):

| Test | Asserts |
|---|---|
| `Process/default port` | `lockstep serve` answers 204 on `127.0.0.1:8000/api/health_check` |
| `Process/configured port` | `--port P` answers 204 and the liveness page on `127.0.0.1:P` |
| `Process/loopback only` | a connection to the container's non-loopback IPv4 address on P is refused. If no such address is supplied, the test **fails** with "precondition missing" (never passes vacuously) |
| `Process/usage error` | `serve --port` exits 64, prints the typed error, and nothing listens |
| `Process/SIGTERM` | the server exits 0 within 5 s |

Static / negative checks in `scripts/check`:

| Check | Expected |
|---|---|
| Forbidden facilities: case-insensitive `pico`, `hyperscript`, `rollbar`, `pandoc`, `nginx`, `supported_languages`, `import ogma`, `.ssh/`, `SSH_KEY` in tracked build/source/config files (docs excluded); `allow-newer` only in `stack.yaml` and scoped exactly to D9's two packages | no match |
| Partial-function hlint rules on `src app test` | no hint |
| Partial-function **negative fixture** `test/fixtures/lint/PartialFunctions.hs` | hlint **reports** each banned function (the check fails if hlint accepts it) |
| Henforcer boundary **negative fixture** `test/fixtures/boundary/…` (a Foundation module importing Web) | compilation **fails** with a Henforcer tree-dependency error; a positive control fixture compiles |

## 5. Acceptance (all mandatory)

1. AC-P0-05 passed **before** any Launchpad file entered `v2` (done; evidence above).
2. AC-P0-08: `stack ls dependencies --license` covers every transitive dependency of
   `lockstep`; GMP and other system-library linkage recorded from `ldd`;
   `THIRD_PARTY_LICENSES.md` and `LICENSE-LAUNCHPAD` (BSD-3) present. Any copyleft
   Haskell dependency, or a linkage beyond ARCHITECTURE §5.2's recorded GMP case,
   stops P1.1 for a human-reviewed ADR.
3. `scripts/check` steps 1–4 exit 0 from a **fresh clone** in the dev container,
   plus `scripts/check --integration`.
4. Forbidden facilities absent (§4 static check); `allow-newer` scoped per D9.
5. Henforcer configured; boundary negative fixture fails, positive control passes.
   The Kernel/Persistence/Effects rows of ARCHITECTURE §2 are **NOT_RUN** (no such
   modules exist).
6. Evidence recorded in `docs/gates/P1.1/evidence/` per VISUAL_EVIDENCE_CONTRACT.

## 6. Verification commands

```sh
scripts/check                  # steps 1–4 (+ static checks) in the dev container
scripts/check --integration    # additionally the process/HTTP suite
scripts/licenses               # stack ls dependencies --license + ldd of lockstep
```

## 7. Budget, stop and rollback

- At most 3 implementation attempts per failing frozen test; no edit to a frozen
  test. A frozen test that is wrong stops work for a human decision.
- Stop on: copyleft or unknown license in the linked closure; a build that needs
  `allow-newer: true` or changes outside §3; Henforcer unable to express the
  Foundation rule (record and ask).
- Rollback: revert the P1.1 commits on `v2`. `main` and the stash are untouched.

## 8. Freeze record

Frozen by the commit that introduces this section (`test(p1.1): …`, manual).
Baseline before freeze (`.local/evidence/P1.1/baseline-tests.log`): the unit
suite fails **only** with "Could not find module" for the four §4a modules; the
integration suite typechecks. Against throwaway type-only stubs (scratch, not
committed) both suites compiled under the package's `-Weverything -Werror` flags
and Henforcer; fourmolu and hlint clean. One candidate defect was corrected
before freeze (`lookup` is not exported by Flipstone.Prelude).

| File | SHA-256 |
|---|---|
| `test/unit/Main.hs` | `096a30edecaa9d7dab184949abaeacee5b7898564013478ee59ab51c4f2c0df8` |
| `test/unit/Lockstep/Foundation/CliTest.hs` | `74896f1673762c264fa5ce8dac9b5efc7607ad18a3142957fe80e0a62987345e` |
| `test/unit/Lockstep/Web/ServerTest.hs` | `2999bcb90d321874fd70ece273b9c6c96b9003bdd8219f92d7bafce001d311a8` |
| `test/unit/Lockstep/Web/ApplicationTest.hs` | `d96005cca8f8932c0ded00d5620e0d67f27c8b1bf60211af4e069a42c510f528` |
| `test/integration/Main.hs` | `df908e4e9b6b81e13b6587bc12ff4bb5e23899e1b34c684154e12ddc87dbb56a` |
| `test/integration/Lockstep/ProcessTest.hs` | `edff519c576a561bd18fce8504aef7712b32ead15ec1dfea02cf406ad483f431` |
| `test/fixtures/lint/PartialFunctions.hs` | `5e3a2d756cd5906015196859d2f703872b912e03f950cfe44a7f55f218224d94` |
| `test/fixtures/boundary/violation/Lockstep/Foundation/BoundaryViolation.hs` | `73c33ee665ec4acd0bbd27453d52313697b19c43a8fb09a95f037a66b6082a7d` |
| `test/fixtures/boundary/control/Lockstep/Web/BoundaryControl.hs` | `f062ff49cf9b67b522c05fbd004adec9669ad3467ce63ffa0a139fc6d713f42b` |

Verify: `shasum -a 256 -c` against this table; `git diff <freeze-commit> -- test/` must be empty at acceptance.
