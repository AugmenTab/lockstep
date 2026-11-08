# Technology-stack compliance — completion packet

- Handoff `phase-04_update9` (owner-approved post-Phase-4 remediation), 2026-11-07/08.
- Branch `remediation/stack-compliance` from `main` `e1c0770`. Nothing pushed; `main` untouched.
- Audit: `docs/reviews/stack-compliance-audit-2026-11-07.md` (findings, classes, dispositions).
- Status: **ready for final qualification** — every Required finding is corrected or recorded as an acceptable
  exception with its reason, and every check this environment supports passed, including the Docker-dependent
  Phase 4 checks (§8, §8a). Not run: a live provider smoke (§8b).

## 1. Audit findings by subsystem (summary; details in the audit)

| Subsystem | Required | Recommended | Acceptable exception | Deferred |
|---|---|---|---|---|
| Persistence (Orville) | O1–O8 corrected | O9 corrected | X1–X4, X6, X7 | O10 typed identifiers |
| JSON (Fleece) | J1, J2, J3 corrected | J6 corrected | J5 (role context documents) | — |
| Web (Orb/Beeline/Brigid) | W2 control shell corrected; W2 application shell excepted | W6 corrected | W7, W8 (verified), W10 | W1, W3–W5, W9 (routing, request handling, client JS) |

## 2. Orville corrections

- `Lockstep.Persistence.Fields`: shared building blocks — `uuidField` (a `uuid` column carried as canonical text),
  `digestField` (typed `bytea`), `setNow`/`increment`/`setExpression`, `forUpdate`/`forUpdateOf`/`forUpdateSkipLocked`,
  typed joins over qualified fields (`joinedOn`, `selectJoined`), `selectValue`, `countOf`, `insertIgnoringConflict`
  (ON CONFLICT built from the table definition with `mkInsertExpr`), `insertComputed` (server-computed values in a
  `VALUES` insert).
- All 17 data modules: one `O.TableDefinition` per table with an explicit marshaller; Orville's entity operations,
  `where_`/`orderBy`/`groupBy`/`limit`, synthetic fields and Orville's `count`/`max`/`min` aggregates. Public functions
  unchanged; the Application layer did not change.
- Preserved explicitly: server clocks (`now()`, `clock_timestamp()`, expiries as `now() + make_interval`), optimistic
  concurrency as one conditional `UPDATE ... RETURNING`, row locks, `SKIP LOCKED`, the job claim as one statement,
  the C-P1.6 outcome digest computed in the finishing update, ON CONFLICT targets.
- What remains as SQL: audit X2–X7 (table locks, `SET` statements, the `pg_locks` probe, the scheduler's advisory
  lock, migrations, two SQL tokens Orville has no constructor for).

## 3. Fleece corrections

- Web: `Lockstep.Web.Json` — one schema per JSON response body; markup safety as a pass over the encoded text;
  characters above U+FFFF now a surrogate pair (J1: the old escaper wrote invalid JSON).
- Engine: `Lockstep.Application.EngineRecords` — one schema per transaction record kind, used to write and read;
  EngineEvidence's private decoders removed; acceptance decodes the latest summary and review instead of substring
  search. Candidate and discovery through the role-answer schemas (`Roles.encodeCandidate`, `encodeDiscovery`).
- Built-in Profile documents through the Profile document schema (`ProfileDocument.encodeProfileDocument`).
- `Lockstep.Foundation.Fleece`: shared helpers (nullable as `Maybe`, encode/decode text).

## 4. Other stack corrections

- The control pane's shell rendered with Brigid (`Web.Components.Shell`), its links from the static route
  (`Static.assetURL`).
- Static assets and the service 404 now carry the security headers (`respondWith`).

## 5. Acceptable exceptions (reasons in the audit)

- Migrations as checksummed SQL DDL through libpq's simple-query protocol (X1, X6).
- `LOCK TABLE`, `SET TRANSACTION`/`SET lock_timeout`, the `pg_locks` probe, the scheduler advisory lock (X2–X4).
- `bytea` type name and targeted `DO NOTHING` tokens (X7).
- Role context documents in `Foundation.Json`: they embed stored records verbatim (J5).
- The application shell stays hand-written: the frozen C-P3.4 test pins a single-quoted `htmx-config` attribute that
  Brigid cannot write (W2). `Fragment.attr` escaping is required: Brigid writes attribute values as given (W8).
- `-freduction-depth=400` in `Web.Components.Shell` for Brigid's `noscript` content check (W10).

## 6. Launchpad patterns used (Launchpad 11886bf, BSD-3-Clause, `LICENSE-LAUNCHPAD`)

- `Database/Entity.hs`, `Database/Schema/*`: one table definition per table, explicit marshallers, typed `where_`,
  `updateFields*`, field definitions beside the domain (`Util/Orville/Fleece.hs` for custom field types).
- `Data/User/UserSettings.hs`, `Data/Theme.hs`, `Util/Fleece/*`: one canonical `FC.Schema` per payload, explicit
  names, `FC.validate` for converted representations (`nullableOf`).
- `Routes/AGENTS.md`, `Components/*`: typed route builders for links (`Static.assetURL`), Brigid documents.
- No Launchpad code was copied; the patterns were followed.

## 7. Commits and changed modules

| Commit | What |
|---|---|
| `92405c1` | audit |
| `7745e3c` | Orville: Fields, Ledger, Repositories, Conversation |
| `1d1f40b` | Orville: the other 13 data modules; lockstep-compliance suite; `check-source-paths` accepts its path |
| `e35dcdd` | Web: Fleece response bodies, the control shell in Brigid, headers on static/404 |
| `d695ae8` | Engine records, candidate, discovery, built-in Profiles through Fleece; JSON compliance tests |
| `5b5d47c` | audit dispositions |
| (this commit) | this packet |

Changed: `src/Lockstep/Persistence/*` (17 modules + `Fields`), `Application/{Engine,EngineCandidate,EngineEvidence,
EngineRecords,Execution,ProfileDocument,ProjectChecks}`, `Effects/Roles`, `Foundation/Fleece`,
`Web/{Json,SecureResponse,App,Control,Application,Static,Components/Shell}`, `package.yaml`, `lockstep.cabal`,
`scripts/lib/check-source-paths`, `test/compliance/**`. Unchanged: every frozen test, fixture and runner, the
migrations, `scripts/control-helper`, the schema.

## 8. Tests and qualification

Added: `lockstep-compliance` suite (`stack test lockstep:lockstep-compliance`, needs `LOCKSTEP_TEST_PG_*`;
runner `.local/run-compliance.sh`), **21/21**:
- Persistence on real PostgreSQL, the server as oracle: uuid text in/out and refusal; bytea hex round trip;
  ON CONFLICT; server-clock expiry (`expires_at - created_at = 12 hours`); optimistic concurrency; the job outcome
  digest equals SHA-256 of the C-P1.6 E3 canonical text.
- JSON: every record schema, the frozen Contract, the candidate, the built-in Profiles and the argv byte-identical to
  the replaced hand-built output (the old expressions as the oracle); the discovery's answer-schema key order; web
  bodies' shape, markup safety, surrogate pairs and round trip.

Qualification on this Mac (Docker, `scripts/check --integration`, tested revision `d695ae8`; the working tree was
dirty only by the audit document): format, lint and static checks, build, unit **870/870**, no-live-model guard,
integration **571/571**, backup/restore — all PASSED (`.local/stack-check-final.log`). Earlier runs during the work:
`.local/stack-check-orville.log` (job claim defect found and fixed), `.local/stack-check-fleece.log` (application
shell exception found).

### 8a. Further checks (all run on this Mac with Docker, 2026-11-08)

| Check | Result | Phase 4 baseline | Log |
|---|---|---|---|
| Linux clean clone at `5b5d47c` (case-sensitive): format, lint, build, unit, integration | PASSED; unit **870/870**, integration **571/571**; kernel boundary and purity scan clean | 870/571 | `.local/stack-linux-clone.log` |
| `check-runner` (host, real Docker) | 0 failures (44 PASS) | 0 failures | `.local/stack-check-runner.log` |
| `check-runner-paths` | 0 failures (7/7) | 7/7 | `.local/stack-check-runner-paths.log` |
| `lockstep-stress` (96 MiB heap) | PASS | PASS | `.local/stack-stress.log` |
| `check-live-native` | **23/23** | 23/23 | `.local/evidence/live-native-20261108t074752z/` |
| `check-live-isolation` | **26/26** | 26/26 | `.local/evidence/live-isolation-20261108t074815z/` |
| `check-live-impersonation` | **43/43** | 43/43 | `.local/evidence/live-impersonation-20261108t074853z/` |
| `check-live-runner` | **84/84** | 84/84 | `.local/evidence/live-20261108t074920z/` |
| `check-live-boundary` | **83/83** | 83/83 | `.local/evidence/live-boundary-20261108t075113z/` |
| `check-live-concurrency` | **17/17** | 17/17 | `.local/evidence/live-concurrency-20261108t075212z/` |
| `check-live-proxy` | **21/21** | 21/21 | `.local/evidence/live-proxy-20261108t075241z/` |

The live checks are offline (synthetic credentials, local stand-ins; no provider contacted).

### 8b. Not run

- **A live provider smoke** on this code. The calculator smoke (`b812f88`) is evidence for the accepted Phase 4
  revision, not for this modified code. The handoff does not require one; it is the remaining attended evidence if
  the owner wants it before merging.
- A full re-run after the docs-only commits that follow `d695ae8` (no code changed; the Linux clone ran at `5b5d47c`).

## 9. Behavioural differences (all deliberate)

- JSON responses: astral characters are a valid surrogate pair (was invalid JSON); control characters as `\n`, `\t`
  etc. instead of `\u000a`; a result's `fields` object in key order.
- A new discovery record writes `reproduction` before `allowed_paths`.
- The control pane's shell is Brigid markup (same elements, attributes and scripts; `<meta charset="utf-8"/>` form).
- Static assets and 404 responses carry the security headers.
- Acceptance compares the verification summary's and review's commit exactly (was a substring test).

## 10. Unresolved decisions (deferred, not blocking)

- Routing and request handling of `/app`, `/operator` and the control pane onto Beeline routes and Orb handlers
  (W1, W3–W5, W9): an HTTP-layer rewrite in front of ~60 frozen integration tests and the browser drivers.
- Typed identifiers (O10).
- Whether the application shell's frozen test may be amended so it can be rendered with Brigid (Planner/owner).
