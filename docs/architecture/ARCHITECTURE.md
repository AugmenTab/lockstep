# Lockstep v2 — Initial Architecture, Boundaries and Conventions (P0.4)

- Status: **PROPOSED** design contract for human approval (Gate P0)
- Revision: 0.1, 2026-10-16
- Traces: FR-APP-02/09, FR-EXE-01/12, NFR-07/13/14; Bible §36–38; ADR-0001
- Scope: the minimum structure needed to specify P1.1 safely. Everything here is
  design. **No Haskell source exists on branch `v2` yet.**

## 1. Shape: one package, one executable

Keep it simple. There is one Stack project and one Cabal package, `lockstep`,
derived from Launchpad `11886bf`. It builds one executable, `lockstep`, with
subcommands (`lockstep serve`, `lockstep <operator-command> …`). The CLI and HTTP
handlers therefore call the same application operations (FR-APP-04, Bible §3.4.1).
Internal sublibraries or extra packages are added only when an import-boundary
rule cannot be enforced otherwise.

```text
lockstep/                     (branch v2)
├─ package.yaml / stack.yaml / stack.yaml.lock
├─ app/lockstep/Main.hs        COMPOSITION ROOT: loads config, builds interpreters
│                              (incl. Provider.Live from operator config), runs subcommand
├─ app/lockstep-smoke/         separate exe, built only with --flag lockstep:smoke
├─ src/Lockstep/
│  ├─ Kernel/                  PURE decision core (P2)
│  ├─ Evidence/Model.hs        PURE gate/criterion row model (P1.6)
│  ├─ Application/             typed operator commands, Supervisor, dispatcher
│  ├─ Persistence/             Orville schema, migrations, claims/outbox
│  ├─ Effects/                 interpreters: Process, Git, Provider (Scripted|Live), Clock
│  ├─ Web/                     Launchpad-derived Orb/Beeline/Brigid routes + components
│  └─ Foundation/              LEAF: Launchpad-derived app-context types, config types/parsing, logging
├─ static/                     lockstep.css (custom tokens), htmx.min.js, icons
├─ test/unit/                  pure + property tests (no DB, no Git, no network)
├─ test/integration/           real PostgreSQL / Git / process tests
├─ test/fixtures/              scripted role-adapter scenarios, golden traces
├─ scripts/check               the repository-native verification command
└─ docs/                       governance, adr, architecture, gates
```

Module names start at `Lockstep.` rather than `Launchpad.`. ADR-0001 records
the provenance; the BSD-3 LICENSE text for the derived files arrives with them
in P1.1.

## 2. Dependency direction (enforced, not advisory)

```text
app/lockstep/Main.hs (composition root: the only place that wires concrete interpreters)
   │
   ▼
Web ──► Application ──► Kernel ◄── Persistence
  │          │  └──────► Effects ──► Kernel
  │          └─────────► Persistence
  └──► Evidence.Model ◄── Application
Foundation (leaf) ◄── (Web, Application, Persistence, Effects)
```

`Foundation` imports no other `Lockstep.*` layer. Startup sequencing
(Launchpad's `REPL.startLaunchpad`) moves into the composition root, which may
import every layer. It is the only non-test importer of
`Lockstep.Effects.Provider.Live`.

| Layer | May import | Must NOT import |
|---|---|---|
| `Kernel.*`, `Evidence.Model` | `base`/prelude (incl. `Data.List.NonEmpty`), `text`, `containers`, `bytestring`, `time` (values only) | Orb, Beeline, Brigid, Orville, WAI/Warp, `http-client`, `process`, `directory`, any `IO`-performing module, any other `Lockstep.*` layer |
| `Effects.*` | Kernel, Foundation, process/git/filesystem libs | Web, Persistence |
| `Persistence.*` | Kernel, Foundation, Orville | Web, Effects |
| `Application.*` | Kernel, Evidence.Model, Persistence, Effects, Foundation | Web |
| `Web.*` | Application, Evidence.Model, Foundation, Orb/Beeline/Brigid | Persistence, Effects, Kernel internals (only exported operation types) |

**Enforcement:** Launchpad is *configured* (`package.yaml`, `henforcer.toml`) to
build with the Henforcer GHC plugin. That build has not yet been run here
(Audit §7). P1.1
configures `henforcer.toml` tree-dependency rules for the table above, and adds
a deliberately violating fixture module that must fail to compile (a negative
check). The Kernel row becomes enforceable when the first Kernel module lands
(P2.1). Until then the rule is recorded but **NOT_RUN**.

Kernel signature direction, from Bible §37 (conceptual, not final API):
`decide :: Snapshot -> Observation -> Either Refusal (NonEmpty DomainEvent, [EffectIntent])`.
Time, ids and randomness enter the Kernel as **inputs**. It never reads a clock.

## 3. Launchpad primitives retained / removed

As accepted in ADR-0001. Mapping to v2 locations:

| Launchpad | v2 | When |
|---|---|---|
| `Launchpad.Types`, `Launchpad.REPL`, `Launchpad.Config` | `Lockstep.Foundation.*`: loopback bind, configurable port, no Rollbar, `Operation` mode reused by CLI subcommands | P1.1 |
| `Launchpad.Routes` (Beeline/Shrubbery/Orb dispatch), Orb handler pattern, `Handler/PermissionActions` | `Lockstep.Web.Routes` | P1.1 |
| `Routes/API/HealthCheck` | `Lockstep.Web.Health` (P1.1 static liveness; P1.2 adds DB readiness) | P1.1/P1.2 |
| `Launchpad.Components.*` (Brigid) | `Lockstep.Web.Components.*`, Pico classes removed | P1.1/P1.6 |
| `Database.Entity`, `Database.Schema`, `Util.Orville*` | `Lockstep.Persistence.*`; auto-migration replaced per DG-02 | P1.2 |
| `Data/Authentication/*`, cookie + token-digest | Operator trust/session primitives | P1.3 |
| `Validation`, `Util.Fleece*`, `Data.Enum.Auxiliary` | `Lockstep.Foundation.*` | as needed |
| **Removed:** Pico, Theme, `_hyperscript`, Rollbar, Signup/Admin/Account, Mobile, nginx, `launchpad-tools`/pandoc, Ogma config, `scripts/rebrand`, template agent instruction files, SSH-key container mount, `allow-newer` | — | P1.1 |

## 4. Repository-native build/test command

`scripts/check` is the single verification entry point for humans, CI and future
Contracts:

```text
scripts/check            # format-check, lint, build (-Werror), unit tests, live-inference guard
scripts/check --integration   # additionally: real PostgreSQL/Git/process suites
```

| Step | Command (inside the dev container) | Fails on |
|---|---|---|
| 1 format | `fourmolu --mode check $(git ls-files '*.hs')` | any diff |
| 2 lint | `hlint src app test` | any hint |
| 3 build | `stack build --pedantic --test --no-run-tests` | warning or error (incl. Henforcer) |
| 4 unit | `stack test lockstep:lockstep-unit` | any failure |
| 5 guard | `scripts/check` installs provider-CLI shims on the test `PATH`, asserts they resolve, then requires an empty sentinel log; it also starts the **release** binary with a fault plan and expects refusal (TESTING_STRATEGY §6, §8) | any live-call attempt, a shim that does not resolve, or an accepted fault plan |
| 6 integration (opt flag; mandatory in CI) | `stack test lockstep:lockstep-integration` | any failure |

The container (Launchpad's Dockerfile, reduced) is the canonical build
environment, because the host has no GHC. The Dockerfile mounts no SSH keys.
**Status:** contract only. P1.1 implements `scripts/check` steps 1–4, and
acceptance requires running it from a clean checkout. Steps 5–6 arrive with P1.7
and P1.2.

## 5. Dependency selection and compatibility policy

1. **Pins.** Stackage LTS snapshot (initially `lts-24.12`, GHC 9.10.3, as in
   Launchpad), extra-deps pinned to exact Git commits, `stack.yaml.lock`
   committed. **`allow-newer: false`.**
2. **License allowlist for anything linked into `lockstep`:** MIT, BSD-2/3,
   ISC, 0BSD, Apache-2.0, PostgreSQL, Zlib; for static icons, CC BY 4.0 with
   attribution. Copyleft (GPL/LGPL/AGPL/MPL) needs an ADR. `stack ls dependencies
   --license` output is checked at P1.1 and whenever dependencies change.
   Known toolchain item: GHC's default runtime links **libgmp (LGPL-3.0)**, and
   libpq (PostgreSQL License) is linked dynamically. P1.1 records how GMP is linked
   in the release binary. Before any distribution decision (ADR-0001 C2), choose
   between dynamic GMP plus LGPL notices and a `ghc-bignum` native backend. This
   is not a blocker while v2 stays private.
3. **Notices.** `THIRD_PARTY_LICENSES.md` lists every shipped third-party
   component with its version and license. It is created in P1.1 (ADR-0001 C4).
4. **Kernel minimalism.** The Kernel dependency list in §2 is closed. Adding a
   package to it requires an ADR.
5. **Provider access through narrow adapters.** CLI-backed providers are
   invoked through `Effects.Process` (PRD §6.3). Bible §36 also allows HTTP
   endpoints (e.g. a local Qwen server, Bible §6). Any HTTP model client needs an
   ADR naming its adapter scope, and lives only under `Effects.Provider.*`.
6. **Upgrades** (snapshot, GHC, Orville/Orb pins) are their own Work Units
   with the full check suite. They are never bundled into feature work.
7. **Browser assets** are vendored, pinned and listed in notices. There is no
   Node toolchain at build or runtime (NFR-07).

## 6. Documentation, ADR, gate-evidence and retrospective conventions

| Artifact | Location | Rules |
|---|---|---|
| Governing-source and decision registers | `docs/governance/` | Updated on every gate decision |
| ADRs | `docs/adr/ADR-NNNN-<slug>.md` | Status `PROPOSED` → `ACCEPTED`/`REJECTED`/`SUPERSEDED`; approver + date mandatory for ACCEPTED; never edited after acceptance except to add a `Superseded by` link |
| Architecture / design contracts | `docs/architecture/`, `docs/TESTING_STRATEGY.md`, `docs/VISUAL_EVIDENCE_CONTRACT.md` | Versioned header |
| Gate reports | `docs/gates/<GATE>/gate-report.md` | Schema in VISUAL_EVIDENCE_CONTRACT; human disposition recorded in the report |
| Raw gate evidence | Small text (≤ 1 MiB): `docs/gates/<GATE>/evidence/`. Larger or sensitive: `.local/evidence/<GATE>/`, with SHA-256 in the report | Never edit evidence after capture |
| Wireframes / illustrations | `docs/gates/wireframes/` | Banner "ILLUSTRATION — NOT EVIDENCE" |
| Retrospectives | `.local/retros/retro-<PP>.md` (local, gitignored) | One whole-phase retrospective per phase, written after the phase gate decision. No per-sub-phase retrospectives. |
| Commits | Conventional prefix with sub-phase, e.g. `docs(p0.4): …`, `feat(p1.1): …` | Until the v2 Supervisor exists, commits are **manual** and say so; they are never described as Supervisor-owned |
