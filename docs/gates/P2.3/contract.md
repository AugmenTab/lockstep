# P2.3 Contract — SDLC Profile policy

- Contract ID: `C-P2.3@v1`
- Status: **FROZEN** (2026-10-18)
- Basis: `v2` at `3479f9a` (P2.1 and P2.2 `VERIFIED — awaiting human acceptance`; DG-05 recorded).
- Authority: `.local/plans/phase-02.md` §7 (P2.3) and §3; **DG-05 ACCEPTED with clarifications**
  (`docs/gates/P2.3/dg-05-decision-request.md`, Human decision, 2026-10-18), D-5.1a–D-5.6 and
  clarifications 1, 2 and 4. Clarification 3 and D-5.7–D-5.11 are C-P2.4.
- Traces: FR-WRK-05 (version and bind the effective Profile: id, version, digest, sources,
  overrides, approvals, before an effectful Work Unit; a policy changed after freeze cannot mutate
  the running basis); Bible §3.5, §31, §31.2, §32, §32.2; PRD §5.2.
- Writer: the single writing agent (manual).

## 1. Objective

A pure, declarative Profile policy in `Lockstep.Kernel.Profile`, a strict Profile document format,
a durable Profile registry, and a repository default Profile. The Kernel validates Profile
definitions, resolves the effective Profile for a Work Order from monotonic layers, refuses any
weakening it cannot prove is a strengthening, validates human exceptions and bindings, reports
binding staleness after a source change, and evaluates gates. The Bug Fix, Greenfield and
Brownfield templates are **not** built (Phase 3+); this is their common foundation.

Persistence of a binding with its Work Order is C-P2.5 (Work Orders become durable there). Here
the binding is a pure, digest-carrying value with complete, reproducible provenance.

Layering note: Henforcer forbids Foundation from importing the Kernel, so the document decoder,
which produces the Kernel's `RawProfile`, is `Lockstep.Application.ProfileDocument`.

## 2. Decisions inside this Contract

| # | Decision |
|---|---|
| F1 | **Fixed vocabularies** (D-5.1a; no expression language). Stages `before-execution`, `before-acceptance`, `before-completion`. Artifact kinds: produced before execution — `requirements-basis`, `reproduction`, `impact-assessment`, `threat-model`, `architecture-assessment`, `classification-rationale`, `human-approval`; produced only during or after execution — `frozen-tests`, `verification-record`, `review-record`, `regression-evidence`, `integration-record`, `documentation`. Verifiers `digest-check`, `deterministic-command`, `independent-review`, `human-inspection`. Approval `none` < `supervisor` < `human`. Path classes `docs`, `source`, `tests`, `build`, `dependencies`, `configuration`. Work Order kinds are the C-P2.2 kinds (`engineering`, `investigate`, `pr-rework`, `integrate`, `plan`, `publish-report`, `skill-install`). Profile ids, gate ids and class tags: `^[a-z][a-z0-9-]{0,63}$`. |
| F2 | **Gate.** id, stage, required artifacts (non-empty set), applicability (kinds, classes, path classes; each `*` or a non-empty set), verifiers (non-empty set), approval, exception path (bool). Missing or ambiguous evidence always blocks; there is no other disposition. `evaluateGate`: not applicable; excepted by a bound receipt; otherwise each required artifact, in name order: none → `MissingArtifact`; evidence with two different digests → `AmbiguousEvidence`; its verifiers not a superset of the gate's → `Unverified` (the missing ones); its approval below the gate's → `NeedsApproval`; all present → `GateSatisfied`. Work Unit-scoped receipts are validated (`admitWorkUnitException`) but are consumed by Work Unit gate evaluation only from Phase 3. |
| F3 | **Clarification 1.** A `before-execution` gate may require only artifacts produced before execution; otherwise the definition is refused (`gate-unsatisfiable-before-execution`). Only `before-execution` gates are execution prerequisites (what the scheduler may check, C-P2.4). `before-acceptance` gates become the Work Unit's frozen post-verification gates (C-P2.2 `frozenGates`); `before-completion` gates guard later completion. |
| F4 | **Universal invariants** (D-5.2): `single-implementer`, `scope-and-authorization`, `durable-attempts`, `protected-frozen-tests`, `deterministic-verification`, `independent-review`, `bounded-retries`, `legitimate-commits`, `human-completion`. Every effective Profile contains all nine; no definition can remove one. A definition that lists any invariant under `invariant_exceptions`, or defines a gate whose id starts with `invariant-`, is refused (`weakens-universal-invariant`). |
| F5 | **Precedence** (D-5.3a). Layers, in order: (1) the built-in installation baseline `lockstep-baseline` version 1 (no gates; non-behavioural path permitted); (2) the repository default; (3) the specializations the repository default declares whose selector matches the Work Order kind or one of its class tags (one level; a specialization profile that itself declares specializations is `invalid-profile`; one that is not registered is `profile-unavailable`; the latest registered version is used); (4) the human-approved overrides. Within one level, two sources that define one gate differently, or disagree on the non-behavioural permission, are a conflict (`profile-conflict`), whatever their order. Across levels, a later definition of an existing gate must be at least as strong on every axis (clarification 2): applicability is a superset per dimension; artifacts and verifiers are supersets; approval is at least as high; an exception path is never added. A weaker axis is `weakens-gate` (first weaker axis in the order applicability, artifacts, verifiers, approval, exception-path); a different stage cannot be proved stronger and is `unprovable-strengthening`. A gate is never removed. The non-behavioural permission (`true`, `false` or absent = inherit) may go from permitted to forbidden only (`weakens-profile` otherwise). |
| F6 | **Work facts and trusted origin** (D-5.6). Facts are the Work Order kind, class tags, declared path classes and behaviour. Only a `Human` principal may set them in Phase 2 (`untrusted-classification` otherwise, including `Agent`); there is no path from ticket text or model output to a class. Applicability: a kind set must contain the kind; a class set must meet the class tags; a path-class set must meet the declared path classes, and **an empty declaration applies every path-class gate** (unknown scope fails closed). |
| F7 | **Non-behavioural classification** (clarification 4, Bible §31.2). Non-behavioural facts carry a basis (rationale and human approver, non-empty, no control characters) and declared path classes that are non-empty and only `docs`; otherwise `non-behavioural-refused`. The effective Profile must permit the path (`non-behavioural-refused`). Only then is `protected-frozen-tests` not required (`requiresFrozenTests` False). An observed change outside `docs` for such a binding is `non-behavioural-violated`. |
| F8 | **Exceptions** (D-5.4). A receipt is created only by a `Human` principal (`exception-not-human`), with a target (one Work Order or one Work Unit), a gate, a rationale and an approver (non-empty, no control characters, else `invalid-record`), a time and the effective Profile digest it was granted against. At binding: a Work Order target must be the bound order (`exception-out-of-scope`), the digest must be the effective digest (`exception-profile-mismatch`), the gate must exist (`exception-unknown-gate`), apply to the facts (`exception-not-applicable`) and declare an exception path (`exception-not-permitted`); one receipt per gate (`invalid-record`). A Work Unit receipt is validated the same way against an admitted Work Unit of the bound order. There is no time-based expiry; a receipt never carries over to other work. |
| F9 | **Binding** (D-5.5). `bindProfile` by `Human` or `Supervisor` only (`binding-not-authorized`) records the Work Order, the effective Profile (sources with id, version and digest per layer, overrides with approvers, gates, invariants, facts, its digest), the exception receipts and the approver. The effective digest is the hash of its canonical rendering and the binding digest the hash of the binding's; `verifyProvenance` recomputes every source digest from the definitions and both digests. |
| F10 | **Mid-flight change** (D-5.5). `bindingFreshness` compares the bound repository default and specialization sources with the current ones: any difference is `ProfileChanged ids` unless a human confirmation (`mkProfileConfirmation`, `Human` only, else `binding-not-authorized`; an empty approver is `invalid-record`) for this binding digest names exactly the current sources, in any order. A frozen Work Unit Contract is a value built from the binding at freeze and is never rewritten; staleness only affects work not yet executing (C-P2.4). |
| F11 | **Canonical rendering and digests.** The Kernel renders definitions, effective Profiles and bindings to canonical text (§3) and takes the hash function as a value (`Hasher`), so the Kernel stays pure. The application supplies SHA-256 of the UTF-8 rendering, as 64 lowercase hex characters. Equivalent documents (key order, whitespace, list order) have the same digest. |
| F12 | **Profile documents.** JSON with exactly the keys of §4; an unknown key, a wrong type or invalid JSON is `profile-document-invalid`. |
| F13 | **Registry.** Migration 0007: `lockstep_profiles` (id, version, digest, document; primary key id+version; a trigger refuses every UPDATE and DELETE), `lockstep_repository_profiles` (append-only default assignments; the latest per repository is current; a trigger refuses UPDATE and DELETE), `lockstep_profile_decisions` (one row per `profile add` or `repository set-profile` attempt that reaches the database). Adding the same id and version again with the same digest is `unchanged`; with another digest `profile-version-exists`; a version other than the next one is `profile-version-not-next`. A stored document whose recomputed digest differs from the stored digest is an integrity failure (exit 70) and is never used. |
| F14 | **CLI** (refusal: stdout `refused <code>` plus ` decision <n>` when recorded, stderr `lockstep: refused (<code>): <reason>`, exit 65): `profile add FILE` (`-` reads standard input) → `profile <id> version <n> digest <hex> added|unchanged`; `profile list` → one `profile <id> version <n> digest <hex>` line per stored version, by id then version; `profile show ID [--version N]` → the canonical rendering then `digest <hex>` (the latest version by default; unknown → `profile-unknown`); `repository set-profile --engineer NAME PROFILE` → `repository <uuid> default-profile <id>` (`unknown-engineer`, `engineer-has-no-repository`, `profile-unknown`); `profile resolve --engineer NAME --kind K [--class C]… [--path-class P]… [--non-behavioural RATIONALE]` → the canonical effective rendering then `digest <hex>` (a dry run by the human operator: approver `operator`; `repository-default-profile-unset`; unknown names `invalid-facts`; Kernel refusals by their codes). |

## 3. Canonical renderings (normative; lines end with `\n`)

Sets are sorted by their names and joined with `,`; `*` is any value; quoted text escapes `\` and
`"` with a backslash. Timestamps are ISO 8601 UTC (`iso8601Show`).

```
lockstep-profile 1
id <id>
version <n>
allows-non-behavioural <true|false|inherit>
gate <id> stage=<s> artifacts=<set> kinds=<set|*> classes=<set|*> path-classes=<set|*> verifiers=<set> approval=<a> exception-path=<true|false>   (one per gate, by id)
specialize kind=<k> profile=<id>                                                                                                      (kind selectors first, by kind name)
specialize class=<c> profile=<id>                                                                                                     (then class selectors, by tag)
```

```
lockstep-effective-profile 1
source baseline <id> <version> <digest>
source repository-default <id> <version> <digest>
source specialization <id> <version> <digest>                                (by id)
override <i> approver="<a>" rationale="<r>" allows-non-behavioural=<true|false|inherit>   (i from 1, in the given order)
override-gate <i> <gate fields as above, from "<id> stage=">
invariants <the nine names in §2 F4 order, comma-joined>
allows-non-behavioural <true|false>
gate <gate fields>                                                           (by id)
facts kind=<k> classes=<set|-> path-classes=<set|-> behaviour=<behaviour-changing|non-behavioural>
non-behavioural-basis rationale="<r>" approver="<a>"                         (only when non-behavioural)
```

```
lockstep-profile-binding 1
work-order <uuid>
effective-digest <digest>
approver "<a>"
exception gate=<g> target=<work-order|work-unit>:<uuid> approver="<a>" rationale="<r>" granted-at=<iso> profile-digest=<digest>   (by gate)
```

## 4. Profile document (JSON)

```json
{
  "id": "team-default",
  "version": 1,
  "allows_non_behavioural": true,
  "invariant_exceptions": [],
  "gates": [
    { "id": "impact", "stage": "before-execution", "artifacts": ["impact-assessment"],
      "kinds": ["engineering"], "classes": ["bug-fix"], "path_classes": ["source"],
      "verifiers": ["human-inspection"], "approval": "human", "exception_path": false }
  ],
  "specializations": [ { "when_kind": "engineering", "profile": "eng" }, { "when_class": "security", "profile": "sec" } ]
}
```

Required: `id`, `version`, `gates`. Optional: `allows_non_behavioural` (absent = inherit),
`invariant_exceptions` (absent = empty), `specializations` (absent = empty); in a gate, `kinds`,
`classes`, `path_classes` (absent = any) and `exception_path` (absent = false). A specialization
has exactly one of `when_kind`, `when_class`, never naming its own profile; selectors are unique.

## 5. Allowed paths

`src/Lockstep/Kernel/Profile.hs` (new), `src/Lockstep/Kernel/WorkOrder.hs` (new exports
`workOrderKindName`, `parseWorkOrderKind` only), `src/Lockstep/Application/ProfileDocument.hs`
(new), `src/Lockstep/Foundation/Cli.hs`, `src/Lockstep/Application/Profiles.hs` (new),
`src/Lockstep/Persistence/Profiles.hs` (new), `src/Lockstep/Persistence/Migrations.hs` (append
migration 0007), `app/lockstep/Main.hs`, `scripts/service` (`cli` passes standard input with
`--interactive` when it is not a terminal), `test/unit/**`, `test/integration/**` (new files and
runner lines), `README.md`, `docs/OPERATOR_GUIDE.md`, `docs/architecture/ARCHITECTURE.md`,
`docs/gates/P2.3/**`. Earlier modules otherwise unchanged; frozen tests unchanged.

## 6. Production API the tests bind to

```haskell
-- Lockstep.Kernel.WorkOrder (new exports)
workOrderKindName :: WorkOrderKind -> Text; parseWorkOrderKind :: Text -> Maybe WorkOrderKind

-- Lockstep.Kernel.Profile
data ContentDigest; mkContentDigest :: Text -> Maybe ContentDigest; contentDigestText :: ContentDigest -> Text
newtype Hasher = Hasher (Text -> ContentDigest)
data ProfileId; mkProfileId :: Text -> Maybe ProfileId; profileIdText
data GateId;    mkGateId    :: Text -> Maybe GateId;    gateIdText
data ClassTag;  mkClassTag  :: Text -> Maybe ClassTag;  classTagText
data UniversalInvariant = SingleImplementer | ScopeAndAuthorization | DurableAttempts | ProtectedFrozenTests
  | DeterministicVerification | IndependentReview | BoundedRetries | LegitimateCommits | HumanCompletion
data GateStage = BeforeExecution | BeforeAcceptance | BeforeCompletion
data ArtifactKind = RequirementsBasis | Reproduction | ImpactAssessment | ThreatModel | ArchitectureAssessment
  | ClassificationRationale | HumanApprovalRecord | FrozenTests | VerificationRecord | ReviewRecord
  | RegressionEvidence | IntegrationRecord | Documentation
data VerifierKind = VerifyDigest | VerifyCommand | VerifyIndependentReview | VerifyHumanInspection
data Approval = ApprovalNone | ApprovalSupervisor | ApprovalHuman            -- Ord
data PathClass = PathDocs | PathSource | PathTests | PathBuild | PathDependencies | PathConfiguration
producibleBeforeExecution :: ArtifactKind -> Bool
parsePathClass :: Text -> Maybe PathClass
data RawGate = RawGate { rawGateId, rawGateStage :: Text, rawGateArtifacts :: [Text], rawGateKinds, rawGateClasses,
  rawGatePathClasses :: Maybe [Text], rawGateVerifiers :: [Text], rawGateApproval :: Text, rawGateExceptionPath :: Bool }
data RawSpecialization = RawSpecialization { rawWhenKind, rawWhenClass :: Maybe Text, rawSpecializationProfile :: Text }
data RawProfile = RawProfile { rawProfileId :: Text, rawProfileVersion :: Integer, rawAllowsNonBehavioural :: Maybe Bool,
  rawInvariantExceptions :: [Text], rawGates :: [RawGate], rawSpecializations :: [RawSpecialization] }
data Gate; gateId :: Gate -> GateId; gateStage :: Gate -> GateStage; gateApproval :: Gate -> Approval; gateExceptionPath :: Gate -> Bool
data ProfileDefinition; mkProfileDefinition :: RawProfile -> Either ProfileRefusal ProfileDefinition
definitionId :: ProfileDefinition -> ProfileId; definitionVersion :: ProfileDefinition -> Int; definitionGates :: ProfileDefinition -> [Gate]
installationBaseline :: ProfileDefinition
renderProfileDefinition :: ProfileDefinition -> Text
data ProfileRef = ProfileRef { refId :: ProfileId, refVersion :: Int, refDigest :: ContentDigest }   -- Eq, Ord
profileRef :: Hasher -> ProfileDefinition -> ProfileRef
data Override; mkOverride :: Principal -> Text -> Text -> Maybe Bool -> [RawGate] -> Either ProfileRefusal Override
data NonBehaviouralBasis; mkNonBehaviouralBasis :: Text -> Text -> Maybe NonBehaviouralBasis
data Behaviour = BehaviourChanging | NonBehavioural NonBehaviouralBasis
data WorkFacts; mkWorkFacts :: Principal -> WorkOrderKind -> [ClassTag] -> [PathClass] -> Behaviour -> Either ProfileRefusal WorkFacts
gateApplies :: WorkFacts -> Gate -> Bool
data ResolutionInput = ResolutionInput { resolutionDefault :: ProfileDefinition, resolutionCatalog :: [ProfileDefinition],
  resolutionOverrides :: [Override], resolutionFacts :: WorkFacts }
data LayerLevel = LayerBaseline | LayerRepositoryDefault | LayerSpecialization | LayerOverride
data EffectiveProfile; resolveProfile :: Hasher -> ResolutionInput -> Either ProfileRefusal EffectiveProfile
effectiveSources :: EffectiveProfile -> [(LayerLevel, ProfileRef)]; effectiveGates :: EffectiveProfile -> [Gate]
effectiveInvariants :: EffectiveProfile -> [UniversalInvariant]; effectiveAllowsNonBehavioural :: EffectiveProfile -> Bool
effectiveDigest :: EffectiveProfile -> ContentDigest; renderEffectiveProfile :: EffectiveProfile -> Text
data ExceptionTarget = ForWorkOrder WorkOrderId | ForWorkUnit WorkUnitId
data ExceptionReceipt
mkExceptionReceipt :: Principal -> ExceptionTarget -> GateId -> Text -> Text -> UTCTime -> ContentDigest -> Either ProfileRefusal ExceptionReceipt
data ProfileBinding
bindProfile :: Hasher -> Principal -> WorkOrderId -> Text -> EffectiveProfile -> [ExceptionReceipt] -> Either ProfileRefusal ProfileBinding
bindingWorkOrder :: ProfileBinding -> WorkOrderId; bindingProfile :: ProfileBinding -> EffectiveProfile
bindingExceptions :: ProfileBinding -> [ExceptionReceipt]; bindingDigest :: ProfileBinding -> ContentDigest
renderBinding :: ProfileBinding -> Text
verifyProvenance :: Hasher -> [ProfileDefinition] -> ProfileBinding -> Bool
admitWorkUnitException :: ProfileBinding -> AdmittedWorkUnit -> ExceptionReceipt -> Either ProfileRefusal ExceptionReceipt
data ProfileConfirmation; mkProfileConfirmation :: Principal -> ProfileBinding -> [ProfileRef] -> Text -> Either ProfileRefusal ProfileConfirmation
data Freshness = Fresh | ProfileChanged [ProfileId]
bindingFreshness :: ProfileBinding -> [ProfileConfirmation] -> ProfileRef -> [ProfileRef] -> Freshness
data GateEvidence = GateEvidence { evidenceArtifact :: ArtifactKind, evidenceDigest :: ContentDigest,
  evidenceVerifiedBy :: [VerifierKind], evidenceApproval :: Approval }
data GateBlock = MissingArtifact ArtifactKind | AmbiguousEvidence ArtifactKind | Unverified ArtifactKind [VerifierKind] | NeedsApproval ArtifactKind Approval
data GateStatus = GateNotApplicable | GateSatisfied | GateExcepted ExceptionReceipt | GateBlocked GateBlock
evaluateGate :: ProfileBinding -> [GateEvidence] -> Gate -> GateStatus
executionPrerequisites :: ProfileBinding -> [Gate]          -- applicable before-execution gates, by id
acceptanceGateIds :: ProfileBinding -> [Text]               -- applicable before-acceptance gate ids, by id
requiresFrozenTests :: ProfileBinding -> Bool
checkObservedPaths :: ProfileBinding -> [PathClass] -> Either ProfileRefusal ()
data ProfileRefusal = InvalidProfile Text | WeakensUniversalInvariant Text | GateUnsatisfiableBeforeExecution GateId
  | WeakensGate GateId Text | UnprovableStrengthening GateId Text | ProfileConflict Text | WeakensNonBehaviouralPolicy
  | ProfileUnavailable ProfileId | UntrustedClassification Principal | NonBehaviouralRefused Text
  | NonBehaviouralViolated [PathClass] | ExceptionNotHuman | ExceptionUnknownGate GateId | ExceptionNotApplicable GateId
  | ExceptionNotPermitted GateId | ExceptionOutOfScope | ExceptionProfileMismatch | BindingNotAuthorized Principal
  | InvalidRecord Text | InvalidFacts Text
profileRefusalCode :: ProfileRefusal -> Text   -- the codes of §2, plus invalid-record and invalid-facts

-- Lockstep.Application.ProfileDocument
decodeProfileDocument :: LBS.ByteString -> Either Text RawProfile

-- Lockstep.Application.Profiles
sha256Hasher :: Hasher

-- Lockstep.Foundation.Cli: new Command constructors
ProfileAdd String | ProfileList | ProfileShow String (Maybe Integer) | RepositorySetProfile String String
ProfileResolve ResolveArgs   -- ResolveArgs { resolveEngineer :: String, resolveKind :: String, resolveClasses :: [String],
                             --   resolvePathClasses :: [String], resolveNonBehavioural :: Maybe String }
```

## 7. Tests (frozen before implementation)

Unit (`lockstep-unit`, pure):

| Area | Cases |
|---|---|
| Definitions | a valid document-equivalent definition is accepted; invalid id, version 0, unknown stage/artifact/verifier/approval/kind/path class, empty artifacts or verifiers, an empty applicability set, duplicate gate ids, a specialization naming itself or with both or no selector, duplicate selectors → `invalid-profile`; an `invariant_exceptions` entry → `weakens-universal-invariant`, also for `protected-frozen-tests`; a gate id `invariant-…` → `weakens-universal-invariant`; a `before-execution` gate requiring `verification-record` or `frozen-tests` → `gate-unsatisfiable-before-execution`; the same gate at `before-acceptance` is accepted |
| Rendering and digests | the golden rendering of one definition; permuting gates, sets and specializations gives the same rendering and digest; `profileRef` carries the SHA-256 of the rendering; `installationBaseline` is `lockstep-baseline` version 1 |
| Precedence | a specialization adding a gate and strengthening one (broader applicability, more artifacts, more verifiers, higher approval, exception path removed) is accepted with the stronger gate; each single-axis weakening (narrower kinds, fewer artifacts, fewer verifiers, lower approval, an added exception path) → `weakens-gate` naming the axis, also when another axis is strengthened; a stage change → `unprovable-strengthening`; two matching specializations defining one gate differently → `profile-conflict` in both catalog and declaration orders; two overrides disagreeing on one gate → `profile-conflict` in both orders; an override weaker than the default → `weakens-gate`; a specialization re-permitting the non-behavioural path → `weakens-profile`; a missing specialization → `profile-unavailable`; a nested specialization → `invalid-profile`; a specialization that does not match the facts contributes nothing; the latest catalog version of a specialization is used; every effective Profile has all nine invariants and the baseline as its first source |
| Facts and trust | `Agent`, `Supervisor`, `Scheduler` setting facts → `untrusted-classification`; non-behavioural with no path classes or a non-docs class → `non-behavioural-refused`; with a Profile forbidding it → `non-behavioural-refused`; a docs-only, permitted one resolves and `requiresFrozenTests` is False (True for behaviour-changing); an observed `source` change for it → `non-behavioural-violated`; applicability of kinds, classes and path classes, including the empty declaration applying path-class gates |
| Exceptions | a human receipt for a gate with an exception path binds and `evaluateGate` gives `GateExcepted`; non-human → `exception-not-human`; empty rationale → `invalid-record`; another Work Order → `exception-out-of-scope`; another digest → `exception-profile-mismatch`; an unknown gate → `exception-unknown-gate`; a non-applicable gate → `exception-not-applicable`; a gate without an exception path → `exception-not-permitted`; two receipts for one gate → `invalid-record`; a Work Unit receipt for a unit of the bound order is admitted, for a unit of another order → `exception-out-of-scope` |
| Binding and provenance | binding by Human and Supervisor; Agent and Scheduler → `binding-not-authorized`; `verifyProvenance` holds with the definitions and fails for a changed definition, a missing definition or another hasher; the binding and effective digests are the hashes of their renderings |
| Mid-flight change | a new version of the default or of a bound specialization, or another default, gives `ProfileChanged` with the ids; a human confirmation for the exact current sources restores `Fresh`; a confirmation for other sources or another binding does not; a non-human confirmation → `binding-not-authorized`; a FrozenContract built from the old binding keeps its gates and digest |
| Gates | not applicable; satisfied; missing artifact; two evidences with different digests → ambiguous; missing verifier → unverified; lower approval → needs approval; `executionPrerequisites` lists only applicable `before-execution` gates, `acceptanceGateIds` only applicable `before-acceptance` ones |
| Document (`Lockstep.Application.ProfileDocumentTest`) | the §4 example decodes; absent optional keys take their defaults; an unknown key (top level, gate, specialization), a wrong type and invalid JSON are refused |
| CLI | the five commands, their options (both `=` and two-word forms where an option takes a value), missing arguments, duplicates and unknown options; earlier commands unchanged |

Integration (`lockstep-integration`, real PostgreSQL and the real binary):

| Case | Asserts |
|---|---|
| Registry | `profile add` of a file → `added` with the SHA-256 of the rendering; the same again → `unchanged`; the same version with other content → `profile-version-exists`; a skipped version → `profile-version-not-next`; an invalid document → `profile-document-invalid`; a weakening document → `weakens-universal-invariant`; `profile list` and `profile show` (latest and `--version`); one decision row per attempt; a direct SQL UPDATE or DELETE of a profile row fails |
| Repository default | `repository set-profile` for an owned repository → recorded; unknown engineer, an engineer without a repository and an unknown profile are refused |
| Resolution | `profile resolve` with no default → `repository-default-profile-unset`; with a default and a matching specialization → the effective rendering lists both sources and the stronger gate, and its digest is the SHA-256 of the printed rendering; a weakening specialization → `weakens-gate`; after a new default version the resolution names the new version; a tampered stored document (changed by SQL with the trigger disabled by the test) → exit 70 and no output rendering |

## 8. Verification

Pre-freeze: the tests compile against type-only stubs; format and lint clean; the unit and
integration baselines fail only in the new groups (and earlier tests pass); every helper is
exercised. Acceptance: `scripts/check --integration` on the clean tree; a Linux clone; frozen
digests P1.1–P2.3; `check-kernel-boundary` covers `Profile`; licenses unchanged.

## 9. Budget, stop, rollback

At most 3 implementation attempts per failing frozen test. Stop on a rule that contradicts DG-05
or a source document, or makes a frozen expectation impossible. Rollback: revert the P2.3 commits;
migration 0007 is forward-only and only adds tables (`docs/adr/ADR-0002`: restore the pre-migration
backup to undo).

## 10. Freeze record

Frozen 2026-10-18 by the writing agent (manual). Frozen files never change in P2.3 without the
protected-test amendment protocol.

| File | SHA-256 |
|---|---|
| `test/unit/Lockstep/Kernel/ProfileTest.hs` | `6964c052e983417d0800a785391f4bcfbfe3f7534a39c95cb4626b2ba734d2fe` |
| `test/unit/Lockstep/Application/ProfileDocumentTest.hs` | `a0d3757879f2addc324d257ac5bca519c96cc7a92f5d9a9ba0227bfb5739f08b` |
| `test/unit/Lockstep/Foundation/CliProfileTest.hs` | `72ac2744b48dd93f8b921d3b626dde4ba43130636a3d4e0302dc9fe90882ad89` |
| `test/integration/Lockstep/ProfileRegistryTest.hs` | `305cc30f9d9d62bde7a0e987086a3fd6ca07991d2fecc269b7c1dfd09d04b139` |
| `test/unit/Main.hs` (runner, additive) | `8c01c6f20c041b5b12533333c1a4528879881e7fc4abe25834132b003ba8b228` |
| `test/integration/Main.hs` (runner, additive) | `36064c2730bdc88547a130b3b417407414e7e239dee1f3cf8a1063e43adc6ce4` |

Runner changes: `test/unit/Main.hs` +6 lines (three imports, three entries), `test/integration/Main.hs`
+2 lines; nothing removed.

Pre-freeze verification (§8), against type-only stubs (scratch; the API of §6 with refusing or
empty bodies; `mkContentDigest` and `sha256Hasher` are real, being leaf utilities):

- Build: library and both suites compile under `--pedantic`; fourmolu clean; hlint clean on the
  new tests after three hints (two eta reductions, one lambda).
- Unit baseline (`evidence/prefreeze-unit-baseline.log`): 74 of 451 fail, **all** in the three new
  groups; the 377 earlier tests pass (the one `FAILED` match in the log is an EvidenceModel test
  name). New tests passing against the stubs: the two digest utilities (real); six document
  refusal cases, which a refuse-everything stub satisfies and which are paired with the failing
  positive decodes; and "earlier commands are unchanged".
- Integration baseline (`evidence/prefreeze-integration-baseline.log`): 6 of 6 fail. Five stop at
  `lockstep profile …` being an unknown command (exit 64); the resolution case first ran its
  Engineer and Git-repository registration helper successfully, and the standard-input case ran the
  binary through its own helper. `sqlFails`, `count` and the digest helpers were checked by reading.
- The Kernel fixtures cannot be built by the stubs, so every expected rendering, refusal and order
  in `ProfileTest` was checked against §2–§3 by reading before the freeze.
