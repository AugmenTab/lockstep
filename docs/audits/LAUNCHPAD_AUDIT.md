# Launchpad Source Acquisition and License Audit (P0.2)

- Audit ID: LS-V2-AUD-LAUNCHPAD
- Revision: 0.1 — DRAFT, 2026-10-16
- Traces: FR-APP-01, NFR-11; DG-01a
- Method: static inspection of the supplied archive plus read-only queries of
  public upstream license metadata. **No build was run** (see §7).

## 1. Source identity

| Property | Value | How established |
|---|---|---|
| Archive | `.local/launchpad-main.zip` (461,842 bytes, 256 entries) | `ls -la`, `unzip -l` |
| Archive SHA-256 | `696147a423d0075980d35347e45f50160223ac3d07aaf4279c5e12969481efca` | `shasum -a 256` |
| Upstream commit | `11886bf73c2e3ac69a6839af28b97ba79bbee5fb` | GitHub archive comment: `unzip -z .local/launchpad-main.zip` |
| Upstream repository | `AugmenTab/launchpad` (`package.yaml` `github:` field) | Source metadata |
| Visibility | Private. The public GitHub API returns `Not Found`. | `curl https://api.github.com/repos/AugmenTab/launchpad` |
| Provenance statement | The human operator stated it is "a private GitHub template repo" and copied it into `.local/` on 2026-10-16 | Operator answer, this session |
| Archive file dates | Latest entry 2026-09-12 | `unzip -l` |

**Not independently verified:** that commit `11886bf` is the current head of the
private repo's `main`, and that the archive bytes match that commit. Doing so
requires authenticated access to the private repo. A clone at that SHA would
settle it in P1.1.

## 2. Ownership and license

| Item | Finding |
|---|---|
| Declared license | `BSD-3-Clause` (`package.yaml` `license:`, generated `launchpad.cabal`) |
| Declared copyright | `2023 Tyler Baum`; author/maintainer Tyler Baum |
| `LICENSE` file | **Absent.** No LICENSE/COPYING/NOTICE file exists anywhere in the archive. |
| Per-module headers | None. `henforcer.toml` sets `moduleHeaderCopyrightMustExistNonEmpty = false` and `moduleHeaderLicenseMustExistNonEmpty = false`. |
| Same owner as Lockstep? | The GitHub owner `AugmenTab` is also the owner of `AugmenTab/lockstep`, `AugmenTab/brigid` and `AugmenTab/ogma`. **INFERRED** that the copyright holder is the Lockstep owner. The human must confirm. |

Consequence: the only evidence of Launchpad's license is a metadata field.
BSD-3-Clause redistribution requires reproducing the copyright notice, the
conditions and the disclaimer, and the archive contains none of that text. If
the human is the sole copyright holder, they can license it to Lockstep under any
terms. That is a **human declaration**, and no evidence in the source can stand
in for it. See ADR-0001.

## 3. Bundled third-party assets (redistributed if copied)

| Asset | Version | License (evidence) | v2 disposition (proposed) |
|---|---|---|---|
| Pico CSS, 20 files `app/static/css/pico*.min.css` | 2.0.6 | MIT (header: "Copyright 2019-2024 - Licensed under MIT") | **Remove** (Bible §3.6.1: custom CSS replaces Pico) |
| htmx `app/static/js/htmx.min.js` | 2.0.10 (embedded `version:"2.0.10"`) | 0BSD (upstream `bigskysoftware/htmx` LICENSE: "Zero-Clause BSD"); minified file has no header | **Retain** (accepted stack). Record version and license in NOTICE. |
| _hyperscript `app/static/js/_hyperscript.min.js` | 0.9.13 | 0BSD (upstream LICENSE) | **Proposed remove.** Not in the accepted stack (Bible §36: "HTMX, minimal local JS"). Used by Modal, Static, Page404, Head, Signup/Get, Account/Security/Get, APIToken/Put. Human decision. |
| Font Awesome Free icons (`app/static/svg/*.svg`, inline SVG in `Components/Icon.hs`) | 6.7.2 (svg files), 7.1.0 (inline) | Font Awesome Free License (icons: CC BY 4.0). Attribution comment is embedded in each SVG. | Retain only icons actually used and keep the attribution comments. Add a NOTICE entry. |
| `app/static/js/scripts.js`, `app/static/css/custom.css` | — | Launchpad (BSD-3 per metadata) | Rewrite during P1.1/P1.6 against Lockstep tokens |

## 4. Haskell dependencies (pinned upstream, `stack.yaml` extra-deps)

Licenses were read at the **pinned commit** where the repo-level metadata was
unclear.

| Package(s) | Pinned commit | License | Evidence |
|---|---|---|---|
| beeline-http-client / -params / -routing | `04bd46a1` | MIT | `beeline-routing/package.yaml` at pin |
| brigid | `331dcc01` | BSD-3-Clause (© 2023 Tyler Baum) | `package.yaml` at pin |
| bounded-text | `f5866f78` | MIT | GitHub license API |
| json-fleece-aeson / -core / -markdown | `5ac84750` | MIT | GitHub license API |
| flipstone-prelude | `4ae274c7` | MIT | GitHub license API |
| henforcer (GHC plugin, build-time) | `71c6c304` | MIT | GitHub license API |
| libphonenumber (typeable) | `5e03e45e` | MIT | GitHub license API |
| ogma | `55ed9161` | BSD-3-Clause | GitHub license API |
| optparse-repl | `24e05519` | MIT | GitHub license API |
| orb | `611084e6` | MIT (© 2025 Flipstone Technology Partners) | `package.yaml` + LICENSE at pin |
| orville-postgresql | `2f493550` | MIT (© 2023 Flipstone Technology Partners) | `package.yaml` + LICENSE at pin |
| rollbar | `5e4785c8` | MIT | GitHub license API |
| shrubbery | `1847db5c` | MIT | GitHub license API |
| **pandoc** (used only by `launchpad-tools`) | Stackage lts-24.12 | **GPL-2.0** (upstream `jgm/pandoc`) | GitHub license API |

Hackage/Stackage packages from resolver `lts-24.12` (warp, wai, crypton,
password, http-client, …) were **not** license-inventoried: there is no local
toolchain to run `stack ls dependencies --license`. Disposition: **NOT_RUN**. This
becomes a P1.1 acceptance check (see §8).

**License risk:** `launchpad-tools` links pandoc (GPL-2.0-or-later). Distributing
that executable would carry GPL obligations. The `launchpad` server executable
and library do not depend on pandoc. Proposed: v2 does not carry
`Commands/GenerateDocs` or the pandoc dependency.

## 5. Functionality inventory relevant to Lockstep

Size: 112 Haskell modules, 8,796 lines (`src/`, `app/`).

### 5a. Verified present and reusable (by inspection, not execution)

| Capability | Location | Notes |
|---|---|---|
| App monad + context (`ReaderT AppContext IO`) | `Launchpad.Types` | Carries config, AppEnv, Orville state, request, HTTP manager, logger |
| Startup lifecycle | `Launchpad.REPL` (`startLaunchpad`, `Normal`/`Maintenance`/`Operation` modes) | `Operation` mode runs an app action without HTTP, which is useful for a CLI sharing operations (FR-APP-04) |
| Typed routing + dispatch | `Launchpad.Routes` (Beeline + Shrubbery union + `Orb.dispatch`) | URL construction from the same routes |
| Orb handler pattern with explicit permission actions | `Routes/**`, `Handler/PermissionActions.hs` | Every route declares a permission action |
| Health endpoint | `Routes/API/HealthCheck.hs` (`/api/health_check` → 204) | **Does not check the DB.** Always 204. |
| Config loading (`CONFIG_PATH`, Fleece JSON) | `Launchpad.Config` | Fails loudly on a missing or invalid config |
| Orville connection pool + schema registration | `Launchpad.Database.Schema` | |
| Entity metadata (timestamps, soft delete) | `Launchpad.Database.Entity` | Soft-delete semantics need review against immutable evidence |
| Brigid components | `Launchpad.Components.*` (Body, Head, Html, Form, Fields, Button, Select, MultiSelect, Modal, Toast, Tabs, Nav, Breadcrumbs, Icon, Time, Page404) | Pico-class coupling in `Components/Classes.hs` |
| Session cookie + token-digest storage | `Data/Authentication/*`, `Handler/Authentication.hs` | HTTP-only, SameSite=Strict, Secure outside Development; digests stored, not raw tokens |
| Fleece/Orville utilities | `Util/Fleece*`, `Util/Orville*`, `Data/Enum/Auxiliary.hs`, `Data/Timespan.hs` | |
| Validation framework | `Launchpad.Validation` | |
| Swagger UI for API routes | `Orb.SwaggerUIRoute` in `Launchpad.Routes` | Optional |

### 5b. Present but not suited to Lockstep (proposed removal)

| Capability | Why |
|---|---|
| Pico CSS, Theme (`Data/Theme.hs`, color schemes) | Bible §3.6.1 |
| Rollbar (`Services/Rollbar*`), wired into config **and** the exception path in `REPL.app` | Sends errors to an external service, which is an unauthorized external effect under Bible §3.4.3. The config makes the `rollbar` block **required**. |
| Signup, Admin/Users, Account (Profile/Settings/Security/APIToken) | Multi-user SaaS account model. Lockstep is one local operator (Bible §15). P1.3 replaces this with operator trust/session. |
| Mobile routes | Empty union |
| `launchpad-tools GenerateDocs` (pandoc) | GPL dependency (§4); not needed |
| nginx config, `compose.yml` nginx service | Static serving is unnecessary for a local single-host service |
| Ogma / `supported_languages` | i18n business config with no Lockstep requirement |
| `.claude/skills/*`, `AGENTS.md`, `CLAUDE.md`, subtree `AGENTS.md`/`CLAUDE.md` | Agent instruction files. Under Bible §32.2 externally supplied instructions are untrusted until reviewed. Treat them as reference only and do not copy them in unreviewed. |
| `scripts/rebrand` | GNU-sed-only (`sed -i -e`, `\L`) and needs `git ls-files`. One-shot template tool. |

### 5c. Absent, or incompatible with PRD requirements (must be built in v2)

| Requirement | Launchpad state | Plan item |
|---|---|---|
| FR-APP-05: bind loopback by default | `Warp.defaultSettings` with only `setPort`; Warp's default host preference is all IPv4 interfaces (**INFERRED** from Warp's documented default; verify at P1.1) | P1.1/P1.3 |
| FR-APP-05: CSRF/origin checks on mutations | **Absent.** No CSRF or Origin logic in `src/` or `app/`; only SameSite=Strict cookies. | P1.3 |
| Configurable port | Hard-coded `port = 8000` (`Types.hs:113`) | P1.1 |
| FR-APP-03: ordered migrations, backup/restore | **Incompatible as-is.** `autoMigrateSchema` at every startup; no versioned migration history or down/forward-recovery procedure. | DG-02 / P1.2 |
| Health/readiness with DB | Health returns 204 unconditionally | P1.2 |
| FR-APP-04: durable command receipt, idempotency | Absent | P1.4 |
| Background dispatcher independent of HTTP | Absent | P1.5 |
| Real test suite | `test/Main.hs` prints "Test suite not yet implemented" | P1.1 onward |
| CI workflow | Absent (README lists it as future work) | P1.7 |
| Pure decision kernel | Not applicable (Launchpad has no domain kernel) | P2 |

## 6. Build prerequisites and source layout

Layout: `src/` (library, `Launchpad.*`, `Services.*`, `Util.*`, `Data.*`),
`app/launchpad-api` (server exe), `app/launchpad-tools` (CLI exe), `app/static`,
`test/`, `config/`, `scripts/`, `docs/`, `nginx/`.

| Prerequisite | Value (source) |
|---|---|
| Compiler | GHC 9.10.3 via ghcup (`Dockerfile` `BOOTSTRAP_HASKELL_GHC_VERSION`) |
| Build tool | Stack, `system-ghc: true`, `install-ghc: false` (`stack.yaml`) |
| Snapshot | `lts-24.12`, plus pinned git extra-deps (§4). `stack.yaml.lock` present (226 lines). |
| Reproducibility hazard | `allow-newer: true` in `stack.yaml` disables version bounds. Proposed v2 policy: disallow it (P0.4 dependency policy). |
| Warnings | `-Weverything -Werror` (with exclusions), `-fplugin Henforcer` |
| Format/lint | fourmolu 0.18.0.0, hlint 3.10 (installed in Dockerfile) |
| System libs | libpq-dev/libpq5, libgmp, libffi, libnuma, libtinfo, zlib, libphonenumber-dev, libprotobuf-dev, pkg-config |
| Database | PostgreSQL 15.8 (`compose.yml` image `postgres:15.8-alpine`) |
| Dev orchestration | Docker Compose; `scripts/bootstrap` creates external network `launchpad_dev`, volume `launchpad_stack_root`, `.env` |
| Config | `CONFIG_PATH` JSON; `compose.yml` references `config/2025-07-05.json`, **which is not in the archive** (only `config/sample-config.json`) |
| Credential exposure | `scripts/bootstrap` and `compose.yml` mount the operator's `~/.ssh` private key read-only into the build container "to pull private dependencies". Every pinned dependency in §4 is public, so v2 should not mount SSH keys (Bible §24). |

Host toolchain on this machine (2026-10-16): `ghc`, `cabal`, `stack`, `psql` are
**not installed**; `docker` is at `/usr/local/bin/docker`. A container build was
not attempted in P0 (no scaffolding change was made, so the handoff does not
require one).

## 7. What this audit did not do

| Check | Disposition | Reason / follow-up |
|---|---|---|
| Clean build of `11886bf` | NOT_RUN | No host toolchain; P1.1 acceptance requires a clean container build |
| Transitive Hackage license inventory | NOT_RUN | Needs `stack ls dependencies --license`; P1.1 |
| Verify archive == private repo commit | NOT_RUN | Needs authenticated clone |
| Security review of auth code | NOT_RUN | P1.3 owns operator trust; the current code was read, not tested |
| Launchpad tests | NOT_RUN | There are none (stub) |

## 8. Recommendation for DG-01a (for human decision)

**Recommendation: ADOPT Launchpad `11886bf` as the v2 foundation, subject to
three human confirmations and P1.1 build/license checks.** The detailed record is
in `adr/ADR-0001-launchpad-adoption.md`.
