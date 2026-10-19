# P2.1 Contract — Stable identities and exclusive repository ownership

- Contract ID: `C-P2.1@v1`
- Status: **FROZEN** (2026-10-18)
- Basis: `v2` at `55803c4` plus the DG-03 decision record. Gate A ACCEPTED on report r2
  (`33c8d26a…`, tested commit `6c2851d`); Phase 2 authorized by `.local/plans/phase-02.md`.
- Authority: `.local/plans/phase-02.md` §5 (P2.1) and §3 (test-first, frozen Contract); the
  owner's **DG-03 decision** of 2026-10-18 (`dg-03-decision-request.md`, "Human decision").
- Traces: FR-WRK-01 (typed identities; Ticket-originated Work Unit with `plan_ref = Nothing`),
  FR-WRK-02 (one active owning Engineer per canonical repository; fail closed on ambiguous
  alias/worktree/remote); Plan v0.2 P2.1 ("Work Unit with no plan ref valid; same repo via
  alias/worktree rejected"); Bible §3.2, §37 (pure decision core), §38; ARCHITECTURE §2.
- Writer: the single writing agent (manual; no v2 Supervisor).

## 1. Objective

Typed stable identities for Repository, Engineer, Ticket, Work Order, Work Unit, Contract and
Attempt; a **pure Kernel** that decides repository registration and Work Unit identity admission
from validated observations; a **Git observation boundary** that canonicalizes repositories in
the observing process's filesystem view; durable Engineers, repository ownership and identity
decisions in PostgreSQL; and CLI commands to add an Engineer, register a repository and list
ownership. No Git mutation, no network, no model or provider invocation.

## 2. Decisions inside this Contract

| # | Decision |
|---|---|
| I1 | **Identities.** `RepositoryId`, `EngineerId`, `TicketId`, `WorkOrderId`, `WorkUnitId`, `ContractId`, `AttemptId` are distinct newtypes over an abstract `Uuid` (canonical lowercase `8-4-4-4-12` hex; anything else is refused by `parseUuid`). They are generated at the boundary (`Lockstep.Application.Identity`: 16 CSPRNG bytes, RFC 4122 version 4 / variant bits) and enter the Kernel as values (DG-03 D-3.1a). A `RepositoryId` is never derived from a path, remote or commit. |
| I2 | **Kernel purity.** `Lockstep.Kernel.*` imports only the prelude, `text`, `containers`, `bytestring`, `time` and other Kernel modules. Enforced by Henforcer `treeDependencies` (Kernel may not import any other `Lockstep.*` layer, nor `System`, `Network`, `Control.Concurrent`, `Control.Exception`, `Control.Monad.IO`, `Data.IORef`, `Debug`, `Foreign`, `GHC.IO`, `Orville`, `Orb`, `Beeline`, `Brigid`, `Crypto`, `UnliftIO`), by a static check that no Kernel source contains the token `IO` or `unsafe`, and by negative fixtures (§5). New layer rows: Effects may not import Web, Persistence or Application; Foundation, Kernel and Effects may not import each other except Effects → Kernel. |
| I3 | **Observation (D-3.2a amended, D-3.7).** `Lockstep.Effects.Git.observeRepository` runs read-only `git` subprocesses in the calling process's filesystem view, with a fixed argument list, a 10 s timeout per call, `LC_ALL=C`, `GIT_TERMINAL_PROMPT=0`, `GIT_OPTIONAL_LOCKS=0`, and the repository-selecting variables (`GIT_DIR`, `GIT_WORK_TREE`, `GIT_COMMON_DIR`, `GIT_INDEX_FILE`, `GIT_OBJECT_DIRECTORY`, `GIT_ALTERNATE_OBJECT_DIRECTORIES`, `GIT_NAMESPACE`) removed; the operator's own Git configuration (including `insteadOf` and `GIT_CONFIG_*`) is kept. Order of checks, each a distinct typed refusal: path missing → `path-not-found`; not a directory → `not-a-directory`; not in a Git repository → `not-a-git-repository`; bare → `bare-repository`; inside a `.git` directory, or the path's physical identity (device, inode) differs from the top level's → `not-top-level`; `--git-dir` physically differs from `--git-common-dir` → `linked-worktree`; has a superproject → `submodule`; `<top>/.git` is not a real directory physically equal to the common directory → `unsupported-git-layout`; shallow → `shallow-repository`; `git` missing → `git-unavailable`; timeout → `git-timed-out`; any other Git failure → `git-failed`. The observation carries the canonical common directory (`realpath`), its **physical identity** (device, inode) and the authoritative remote (I4). Paths are **never case-folded**: on a case-insensitive filesystem two spellings of one directory share a physical identity; on a case-sensitive one they are distinct directories. Phase 2 has one filesystem view per installation (the `lockstep` process doing the registration); the installed container mounts no host repositories, so a host path is `path-not-found` there. |
| I4 | **Authoritative remote (D-3.4).** The remote that names the repository's own upstream identity: the remote named by `--authoritative-remote R` (missing → `authoritative-remote-unknown`); else none when there are no remotes; else the only remote; else **refused** `authoritative-remote-ambiguous` (the operator must name one: explicit human resolution). Every fetch and push URL of that remote, after Git's own rewriting (`git remote get-url --all` and `--push --all`), must parse (else `remote-url-unsupported`) and resolve (else `remote-unresolvable`) to one identity (else `authoritative-remote-inconsistent`). **Other remotes (upstream, template) are recorded by name only and never used for identity.** |
| I5 | **Remote normalization (pure).** `ssh://`, `git+ssh://`, `ssh+git://`, `git://`, `http://`, `https://` and scp-style `[user@]host:path` are one network form: userinfo and port dropped, host lowercased with a trailing `.` removed, path stripped of leading/trailing `/`, one trailing `.git` and repeated `/`; an empty path or a `.`/`..` segment is unsupported. The path is compared **exactly**, except for hosts that route paths case-insensitively (`github.com`, `gitlab.com`, `bitbucket.org`), where it is lowercased. Identity text: `host/path`. `file:///p`, `file://localhost/p` and plain paths are local: resolved relative to the top level, then identified by the physical identity of their Git common directory. Transport helpers (`x::y`), other schemes and `file://otherhost/` are unsupported. SSH host aliases from `~/.ssh/config` are **not** resolved (a known limit, §9). |
| I6 | **Registration decision (pure; D-3.3d, D-3.5a).** `decideRegistration owned request` compares the candidate with every actively owned repository in `RepositoryId` order, and for each in this order: same physical identity or same canonical common directory → `repository-already-owned`; same authoritative network/local identity → `authoritative-remote-owned`; the candidate's authoritative remote is the owned repository's common directory → `remote-is-owned-repository`; the owned repository's authoritative remote is the candidate's common directory → `owned-repository-pushes-here`. Then: the Engineer already owns a repository → `engineer-already-owns-repository`; the new `RepositoryId` is in use → `repository-id-in-use`. Otherwise accepted. **Root commits and shared ancestry are not inputs**: forks, remote-less clones and template-derived projects are eligible. A repeated registration of the same repository is refused, even by its owner. The result does not depend on the order of `owned`. |
| I7 | **Work Unit identity (FR-WRK-01).** `admitWorkUnit ownerships request` accepts a `WorkUnitRequest { WorkUnitId, RepositoryId, TicketId, WorkOrderId, Maybe PlanRef }` when the repository has an active owner and returns it with that `EngineerId`; otherwise `work-unit-repository-not-owned`. `planRef = Nothing` is valid; a plan reference is optional ancestry, never required identity. State transitions are P2.2. |
| I8 | **Migration `0006`** (ADR-0002 backup gate applies). `lockstep_engineers(id uuid PRIMARY KEY, name text NOT NULL UNIQUE CHECK (name ~ '^[a-z][a-z0-9-]{0,39}$'), created_at timestamptz NOT NULL DEFAULT now())`. `lockstep_repositories(id uuid PRIMARY KEY, owner_engineer_id uuid NOT NULL REFERENCES lockstep_engineers (id), common_dir text NOT NULL, physical_id text NOT NULL, authoritative_remote text, authoritative_identity text, other_remotes text NOT NULL, observation_digest bytea NOT NULL CHECK (octet_length(observation_digest) = 32), registered_at timestamptz NOT NULL DEFAULT now(), released_at timestamptz CHECK (released_at IS NULL), CHECK ((authoritative_remote IS NULL) = (authoritative_identity IS NULL)))` with partial unique indexes `WHERE released_at IS NULL` on `owner_engineer_id`, `physical_id`, `common_dir` and `authoritative_identity`. (`released_at` is always NULL in Phase 2; it reserves release/relocation without implementing it, D-3.6.) `lockstep_identity_decisions(id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY, operation text NOT NULL CHECK (operation IN ('engineer-add', 'repository-register')), engineer_name text NOT NULL, requested_path text, requested_remote text, outcome text NOT NULL CHECK (outcome IN ('accepted', 'refused')), refusal_code text, engineer_id uuid, repository_id uuid, observation text, decided_at timestamptz NOT NULL DEFAULT now(), CHECK ((outcome = 'refused') = (refusal_code IS NOT NULL)))`. |
| I9 | **Admission.** `addEngineer` and `registerRepository` require readiness `Ready`. Registration observes first (outside any transaction), then in **one transaction** takes `LOCK TABLE lockstep_repositories IN EXCLUSIVE MODE`, resolves the Engineer by name (none → `unknown-engineer`), reads every active repository, decides (I6) and inserts the repository row **and** its decision row together. Every attempt that reaches the database, accepted or refused (including observation refusals), leaves exactly one `lockstep_identity_decisions` row. The database constraints are a second line: the Kernel decision runs first. |
| I10 | **CLI.** `lockstep engineer add NAME` → stdout `engineer <uuid> <name>`, exit 0; invalid name → 65 `engineer-name-invalid`; taken → 65 `engineer-name-taken`. `lockstep repository register --engineer NAME [--authoritative-remote R] PATH` (options in any order, `--opt=V` forms, duplicates refused) → stdout `repository <uuid> owner <name> authoritative <R>=<identity>\|none common-dir <path>`, exit 0. A refusal prints `refused <code> decision <n>` on stdout and `lockstep: refused (<code>): <message>` on stderr, exit 65. `lockstep repository list` → one such `repository …` line per active repository, by registration time then id. Not configured 66; not ready 69; usage 64. |
| I11 | **Dependencies.** `process` (a GHC boot package, BSD-3, already in the build through the test suites) is added to the library for `Lockstep.Effects.Git`. Nothing else. |

## 3. Allowed paths

`src/Lockstep/{Kernel,Effects,Application,Persistence,Foundation}/**`, `app/lockstep/Main.hs`,
`test/unit/**` and `test/integration/**` (new files, plus the runner lines in §8),
`test/fixtures/boundary/{control-kernel,violation-kernel-io,violation-kernel-persistence}/**`,
`scripts/lib/check-kernel-boundary` (new), and in `scripts/lib/check-step` one added line in the
build step and the `LOCKSTEP_TEST_CASE_DIR` default in the integration step,
`henforcer.toml` (treeDependencies rows only; `check-henforcer-configs` keeps the test config
equal otherwise), `package.yaml`, `lockstep.cabal`, `README.md`, `docs/OPERATOR_GUIDE.md`,
`docs/architecture/ARCHITECTURE.md` (status notes only), `docs/gates/P2.1/**`.
Not allowed without a stop: any frozen P1 test, fixture or helper (`Support/*`); `.hlint.yaml`;
`check-forbidden-facilities`; `stack.yaml*`; `Dockerfile`; Web routes (no UI in P2.1).

## 4. Production API the tests bind to

```haskell
-- Lockstep.Kernel.Identity
data Uuid; parseUuid :: Text -> Either IdentityError Uuid; uuidText :: Uuid -> Text
uuidFromBytes :: ByteString -> Either IdentityError Uuid      -- exactly 16 bytes
uuidFromWords :: Word64 -> Word64 -> Uuid                      -- total, big-endian
data IdentityError = UuidMalformed | UuidWrongLength
newtype RepositoryId = RepositoryId Uuid; newtype EngineerId = EngineerId Uuid
newtype TicketId = TicketId Uuid; newtype WorkOrderId = WorkOrderId Uuid
newtype WorkUnitId = WorkUnitId Uuid; newtype ContractId = ContractId Uuid
newtype AttemptId = AttemptId Uuid                            -- all Eq, Ord, Show

-- Lockstep.Kernel.Repository
data PhysicalId = PhysicalId { physicalDevice :: Integer, physicalInode :: Integer }
data RemoteLocator = NetworkLocator Text Text | LocalLocator Text
parseRemoteUrl :: Text -> Maybe RemoteLocator
data RemoteIdentity = NetworkIdentity Text Text | LocalIdentity PhysicalId Text  -- Text: display path
remoteIdentityText :: RemoteIdentity -> Text
sameRemote :: RemoteIdentity -> RemoteIdentity -> Bool          -- LocalIdentity: by PhysicalId only
data RemoteConfig = RemoteConfig { remoteName :: Text, remoteFetchUrls :: [Text], remotePushUrls :: [Text] }
selectAuthoritative :: Maybe Text -> [RemoteConfig] -> Either RegistrationRefusal (Maybe (Text, NonEmpty RemoteLocator))
settleAuthoritative :: Text -> NonEmpty RemoteIdentity -> Either RegistrationRefusal AuthoritativeRemote
data AuthoritativeRemote = AuthoritativeRemote { authoritativeName :: Text, authoritativeIdentity :: RemoteIdentity }
data RepositoryObservation = RepositoryObservation
  { observedCommonDir :: Text, observedPhysical :: PhysicalId
  , observedAuthoritative :: Maybe AuthoritativeRemote, observedOtherRemotes :: [Text] }
renderObservation :: RepositoryObservation -> Text                -- canonical, for the digest
data Ownership = Ownership { ownershipRepository :: RepositoryId, ownershipEngineer :: EngineerId }
data OwnedRepository = OwnedRepository { ownedOwnership :: Ownership, ownedObservation :: RepositoryObservation }
data RegistrationRequest = RegistrationRequest { requestRepository :: RepositoryId, requestEngineer :: EngineerId, requestObservation :: RepositoryObservation }
data RegistrationRefusal
  = PathNotFound | NotADirectory | NotAGitRepository | BareRepository | NotTopLevel
  | LinkedWorktree | Submodule | UnsupportedGitLayout | ShallowRepository
  | GitUnavailable | GitTimedOut | GitFailed Text
  | AuthoritativeRemoteAmbiguous [Text] | AuthoritativeRemoteUnknown Text
  | AuthoritativeRemoteInconsistent Text | RemoteUrlUnsupported Text | RemoteUnresolvable Text
  | RepositoryAlreadyOwned Ownership | AuthoritativeRemoteOwned Ownership
  | RemoteIsOwnedRepository Ownership | OwnedRepositoryPushesHere Ownership
  | EngineerAlreadyOwnsRepository RepositoryId | RepositoryIdInUse
refusalCode :: RegistrationRefusal -> Text; renderRefusal :: RegistrationRefusal -> Text
decideRegistration :: [OwnedRepository] -> RegistrationRequest -> Either RegistrationRefusal OwnedRepository

-- Lockstep.Kernel.WorkUnit
data PlanRef; mkPlanRef :: Text -> Maybe PlanRef               -- 1–200 chars, no control chars
data WorkUnitRequest = WorkUnitRequest { wuId :: WorkUnitId, wuRepository :: RepositoryId, wuTicket :: TicketId, wuWorkOrder :: WorkOrderId, wuPlanRef :: Maybe PlanRef }
data AdmittedWorkUnit = AdmittedWorkUnit { admittedRequest :: WorkUnitRequest, admittedEngineer :: EngineerId }
data WorkUnitRefusal = WorkUnitRepositoryNotOwned RepositoryId
admitWorkUnit :: [Ownership] -> WorkUnitRequest -> Either WorkUnitRefusal AdmittedWorkUnit

-- Lockstep.Foundation.Cli (additions)
Command: ... | EngineerAdd String | RepositoryRegister RegisterArgs | RepositoryList
data RegisterArgs = RegisterArgs { registerEngineer :: String, registerRemote :: Maybe String, registerPath :: String }
```

`Lockstep.Effects.Git`, `Lockstep.Persistence.Repositories`, `Lockstep.Application.Identity` and
`Lockstep.Application.Repositories` are exercised through the binary by the integration suite;
their Haskell signatures are not bound by tests.

## 5. Tests (frozen before implementation; §8)

Unit (`lockstep-unit`, pure, no network, no Git):

| Area | Cases |
|---|---|
| Identity | canonical lowercase UUIDs parse and round-trip; uppercase, missing hyphens, wrong group lengths, non-hex, empty → refused; `uuidFromBytes` of 16 bytes renders 36 chars and parses back; 15/17 bytes → `UuidWrongLength` |
| Remote parsing | scp, `ssh://` with user and port, `git+ssh://`, `git://`, `https://` with userinfo, trailing `/`, `.git`, mixed-case host → one `github.com/owner/repo`; GitHub/GitLab/Bitbucket paths lowercased; another host's path case kept (`git.example.com/Team/Repo` ≠ `…/team/repo`); different owner or name → different; `file:///p`, `file://localhost/p`, `/abs`, `../rel`, `./rel` → local; `ext::sh -c x`, `foo::bar`, `file://host/p`, `svn://h/p`, empty, `host:` (empty path), a `..` segment → unsupported |
| Authoritative selection | no remotes → none; one remote → it; two without a choice → `AuthoritativeRemoteAmbiguous` with sorted names; a chosen existing remote → it; a chosen missing remote → `AuthoritativeRemoteUnknown`; an unparseable URL → `RemoteUrlUnsupported`; fetch and push URLs in different forms of one identity → settled; fetch and push to different repositories → `AuthoritativeRemoteInconsistent`; two local spellings with one physical identity → settled |
| Registration (adversarial) | duplicate physical identity → `RepositoryAlreadyOwned` (same and other Engineer); same canonical path with a new physical identity → `RepositoryAlreadyOwned`; **case-sensitive paths** `/r/Proj` and `/r/proj` with different physical identities → accepted; **symlink/case alias** (different display path, same physical identity) → `RepositoryAlreadyOwned`; **duplicate clone** (other directory, same authoritative network identity) → `AuthoritativeRemoteOwned`; clone whose authoritative remote is the owned common directory → `RemoteIsOwnedRepository`; owned repository pushing into the candidate → `OwnedRepositoryPushesHere`; two clones of one local bare repository → `AuthoritativeRemoteOwned`; **fork** (own authoritative remote; upstream equal to the owned repository's authoritative remote, recorded as another remote) → accepted; **shared ancestry** (no remote, other directory) → accepted; template-derived project → accepted; Engineer already owning → `EngineerAlreadyOwnsRepository`; repository identity conflicts reported before the Engineer conflict; reused `RepositoryId` → `RepositoryIdInUse`; every permutation of the owned list gives the same result |
| Work Unit | Ticket-originated with `planRef = Nothing` → admitted with the owning Engineer; with a plan reference → admitted, reference kept; unowned repository → `WorkUnitRepositoryNotOwned`; `mkPlanRef` empty/control/201 chars → `Nothing` |
| Refusal codes | every constructor has the kebab-case code named in I3–I6 |
| CLI | `engineer add NAME`; `repository register --engineer E PATH`, `=` forms, option after the path, `--authoritative-remote`; missing `--engineer` → `MissingOption`; missing path → `MissingArgument "PATH"`; two paths → `UnexpectedArgument`; duplicate option → `DuplicateOption`; `repository list`; `repository list x` → `UnexpectedArgument`; `engineer`/`repository` alone → `MissingSubcommand`; earlier commands unchanged |

Integration (`lockstep-integration`, real PostgreSQL 17.11, real `git`, the real binary; each
Git fixture in a fresh temporary directory, with `HOME` and Git configuration under the test's
control):

| Case | Asserts |
|---|---|
| Engineers | `engineer add alice` → `engineer <uuid> alice`; again → 65 `engineer-name-taken`; `Alice` → 65 `engineer-name-invalid`; one row each; one decision row per attempt |
| Register and list | `orig` (remote `git@github.com:Owner/Repo.git`) by alice → accepted, `authoritative origin=github.com/owner/repo`; `repository list` shows it with the same id after a new process |
| Duplicate and aliases | same path by alice and by bob; a symlink; `orig/` and `orig/sub/..` spellings → each `repository-already-owned`, nothing inserted, one decision row each |
| Linked worktree, subdirectory | `git worktree add` path → `linked-worktree`; `orig/sub` → `not-top-level`; a path inside `.git` → `not-top-level` |
| Duplicate clones | a clone whose `origin` is the local path of `orig` → `remote-is-owned-repository`; a clone with `origin` `https://github.com/owner/repo` → `authoritative-remote-owned`; a clone with `origin gh:Owner/Repo` and `url.https://github.com/.insteadOf gh:` in its `HOME` config → `authoritative-remote-owned` |
| Forks and shared ancestry | a fork (`origin git@github.com:bob/repo-fork.git`, `upstream git@github.com:Owner/Repo.git`) without a choice → `authoritative-remote-ambiguous`; with `--authoritative-remote origin` by bob → accepted; a clone of `orig` with every remote removed (shares all commits) by carol → accepted; a template-derived project (`template` remote = owned upstream, `origin` its own) with `--authoritative-remote origin` by dave → accepted |
| Ambiguous / unsupported remotes | push URL differing from the fetch URL → `authoritative-remote-inconsistent`; `--authoritative-remote nope` → `authoritative-remote-unknown`; `ext::sh -c x` → `remote-url-unsupported`; a local remote path that does not exist → `remote-unresolvable` |
| Unsupported shapes | bare repository → `bare-repository`; `--depth 1` clone → `shallow-repository`; a submodule → `submodule`; a plain directory → `not-a-git-repository`; a missing path → `path-not-found`; a file → `not-a-directory` |
| Cardinality | an Engineer who owns a repository registering an unrelated one → `engineer-already-owns-repository`; unknown Engineer → `unknown-engineer` |
| Case sensitivity | in the system temporary directory **and** in `LOCKSTEP_TEST_CASE_DIR` (required; scripts/check points it at a bind-mounted host directory): the test detects the filesystem's case behaviour and reports it; case-insensitive → registering `ORIG` after `orig` → `repository-already-owned`; case-sensitive → `Proj` and `proj` both accepted (distinct ids) and `ORIG` → `path-not-found` |
| Concurrency | 5 rounds: a path and a symlink to one new repository registered at once by two Engineers → exactly one accepted, one `repository-already-owned`, one repository row |
| Durable decisions | every attempt above has exactly one decision row with the printed code; no repository row without an `accepted` decision |
| Backup gate | a database at schema 5 with data → `db migrate` without a flag → 75; `--no-backup` → applies `0006` |

Negative fixtures (build step, `scripts/lib/check-kernel-boundary`): a Kernel module importing
`System.Process` and one importing `Lockstep.Persistence.Commands` are rejected by Henforcer with
`HEN-` and the module name; a pure Kernel control module compiles; the purity scan finds `IO` in
a fixture and none in `src/Lockstep/Kernel`.

## 6. Verification

Pre-freeze: candidate tests compile against type-only stubs under `--pedantic` and the new
Henforcer rows; format and lint clean; **the integration suite is run** against the stub binary
and every failure is the missing feature, not a helper (memory rule). Acceptance: `scripts/check
--integration` (both case branches on this Mac); a fresh clone and a Linux clone with
`LOCKSTEP_TEST_CASE_DIR` set (in the Linux clone both branches are case-sensitive, and the report
says so); frozen digests P1.1–P2.1; runner diffs additive; `scripts/licenses` with `process` as
the only change; an operator run against the operator database with a backup before `0006`.

## 7. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test; frozen tests never edited. Stop on a
behaviour that makes a frozen expectation impossible, a path outside §3, a dependency beyond I11,
or a design question that §2 and DG-03 do not settle. Rollback: revert the P2.1 commits; `0006` on
the operator database is handled by restoring the pre-migration backup (ADR-0002).

## 8. Freeze record

Frozen 2026-10-18 by the writing agent (manual; no v2 Supervisor). Frozen files never change in
P2.1 without the protected-test amendment protocol.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/IdentityTest.hs` | `ae127658b02539b34e10151a9882b778fef52b82c708c7ef21545219eeb881f5` |
| `test/unit/Lockstep/Kernel/RemoteTest.hs` | `916fdb2e82d7d1241b92bdd28b846fb8167156fa074f4a20f587b96f61279e8c` |
| `test/unit/Lockstep/Kernel/RepositoryTest.hs` | `1f3c9e80de53cd334d485545164cf67d2650c4e414e1fc8826f58f86fafa8a59` |
| `test/unit/Lockstep/Kernel/WorkUnitTest.hs` | `6ff8f9904f3e1f12377147584f5b2960169d63004b84bf6ef1251f3ee8afe2e1` |
| `test/unit/Lockstep/Foundation/CliRepositoryTest.hs` | `428d7c4db68b7b87e3129bfcecf7373dbe8c09fb5b94c68b06d70582a8cc8723` |
| `test/integration/Lockstep/RepositoryOwnershipTest.hs` | `b6a0d3351c6c08849f434016bb96cec2e4ad5348fc0ef735bcf59b6a6b66d02b` |
| `test/unit/Main.hs` (runner, additive) | `a90122abcb06ec64b2f35d5a102b15576b91817556a60a69ee227710a257d854` |
| `test/integration/Main.hs` (runner, additive) | `c6e339230e7c1d943f08403400c7f87a2c6d1c3387b44f50fa6bbec065fdb3a0` |
| `test/fixtures/boundary/control-kernel/Lockstep/Kernel/KernelControl.hs` | `120a03238d679b0cc296134a755aedd21ebf047ae567483d9783e72b9ad2b83c` |
| `test/fixtures/boundary/violation-kernel-io/Lockstep/Kernel/IoViolation.hs` | `5acef9833bb9f06e2bd50ab0c9cf65a87d840035f8f287e98ffba367b37a36f2` |
| `test/fixtures/boundary/violation-kernel-persistence/Lockstep/Kernel/PersistenceViolation.hs` | `7c083783b75449b5a83dfc58310cd59aff0684a173a42e88a6979d4717bf2509` |
| `scripts/lib/check-kernel-boundary` | `948496fbd8f38f1221b19a7a31d186c58c9fb23c330231c27878d3ab2d7c6d4a` |

Runner changes (additive only): `test/unit/Main.hs` gains `IdentityTest`, `RemoteTest`,
`RepositoryTest`, `WorkUnitTest`, `CliRepositoryTest` (10 added lines, 0 removed);
`test/integration/Main.hs` gains `RepositoryOwnershipTest` (2 added lines, 0 removed). Frozen
helpers `Support/{Process,Postgres}.hs` reused unchanged; no new polling helper.

Pre-freeze verification (§6), against type-only stubs (scratch, not committed: the three Kernel
modules with total placeholder bodies, the `Cli` constructors, `Main` handlers exiting 70):

- Build: library, executable and both suites compile under `--pedantic` with the new Henforcer
  rows. Format clean (except the scratch stubs). Lint: no hints; all static checks pass.
  `check-kernel-boundary` passes: both violations rejected with `HEN-`, control compiled, scan
  clean.
- Unit baseline (`evidence/prefreeze-unit-baseline.log`): 58 of 330 fail, **all** in the five new
  groups; the 259 earlier tests pass. The 13 new tests that pass against the stubs are refusal
  checks (an all-refusing stub satisfies them trivially), each paired with a positive case.
- Integration baseline, **run** against the stub binary
  (`evidence/prefreeze-integration-baseline.log`): 6 of 73 fail, all new; 5 at the first
  `engineer add` (exit 64, unknown command) and the backup-gate case because `0006` does not
  exist. The 67 earlier tests pass with no change.
- The Git fixture steps that the baseline cannot reach were replayed by hand in the dev container
  under `/tmp` and under the bind-mounted `LOCKSTEP_TEST_CASE_DIR`. Every command succeeded:
  shallow clone, submodule, linked worktree, `insteadOf`, push URL, `ext::` remote. `/tmp` was
  case-sensitive and the bind mount case-insensitive. In the case-insensitive directory Git
  reports `ORIG/.git`, not the on-disk spelling, which confirms that the physical identity check
  (I3) is required.
- Frozen P1 tests that touch the migration list were checked against `0006`: every such check is
  a substring (`applied migrations: N`) or uses `L.length migrations`.

## 9. Known limits (stated, not hidden)

1. SSH host aliases (`Host gh-work` in `~/.ssh/config`) are not resolved: `gh-work:Owner/Repo` and
   `github.com:Owner/Repo` are different identities. A competing registration through an alias is
   **not** detected. Carried forward to P5.1 (persistent Engineer registry).
2. Hosts other than GitHub, GitLab and Bitbucket compare paths exactly; a case-insensitive
   self-hosted server reached with two spellings is not detected.
3. Observation and admission are separate steps: a repository changed between them (moved,
   remote edited) is admitted on the earlier observation. Effectful admission in later phases
   re-observes and refuses on drift (D-3.6).
4. Physical identity is (device, inode). A device number that changes across reboots or remounts
   makes the physical check miss; the canonical-path check still applies.
