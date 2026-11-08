# Stack patterns: how Launchpad and Artificer use the stack, and what Lockstep must do

Status: reference, 2026-11-08. Source study of Launchpad (`.local/launchpad-src`, commit 11886bf) and Artificer
(`.local/artificer-src`), with every library API below checked in ghci against Lockstep's pinned versions
(`stack.yaml`: Orville 2f493550, json-fleece 5ac84750, Orb 611084e6 (orb-0.7.0.0), Shrubbery 1847db5c, Beeline 04bd46a1,
Brigid 331dcc01 (brigid-0.4.0.0)). Launchpad and Lockstep pin the same commits; Artificer pins older ones.

The short version: in both applications **one typed definition is the single source of truth for each concern, and
the type checker connects them.** An ID type defines its database column, its URL parameter and its JSON form. A path
definition both recognises requests and builds links. A Fleece schema both encodes and decodes, and documents the API.
A handler's response list is checked against the responses its permission action can produce. Lockstep currently
re-implements most of these by hand (§10).

## 1. Code conventions

- **Layer ownership** (Launchpad `docs/agent/architecture.md`): domain meaning in `Data`, persistence in `Database`,
  endpoints in `Routes`, cross-route request policy in `Handler`, reusable HTML in `Components`, form validation in
  `Validation`, startup in `Types`/`REPL`/`Config`.
- **One module per concept, with a facade.** `Artificer/Data/Entry.hs` re-exports `Data/Entry/{Entry, EntryId,
  EntryData, ...}` (`module Export`); `Artificer/Database.hs` re-exports `Entity`, `Queries` and every
  `Schema/*` table so routes import `DB` once.
- **Each domain type carries its own representations**, defined once next to the type
  (`Artificer/Data/Visibility.hs`):
  - `visibilityToText` is the single canonical text form (explicit, never `Show`);
  - `visibilityFromText = EnumAux.parseEnumText visibilityToText` — the parser is derived from the renderer;
  - `visibilitySchema = FC.boundedEnum visibilityToText` (JSON);
  - `visibilityField = O.convertField (O.tryConvertSqlType toText fromText) (O.boundedTextField "visibility" 7)`
    (column);
  - `visibilityValidator = V.boundedEnum visibilityToText` (form input);
  - `renderVisibility` is the separate human label.
- **Validated text is a newtype with a smart constructor**, never bare `Text`: `Username` wraps
  `BT.BoundedText 6 32` from the `bounded-text` library (`Launchpad/Data/User/Username.hs`); `FoundryId` hides its
  constructor and exposes `foundryIdFromText :: Text -> Either String FoundryId` plus schema, field and validator.
- **Naming** (`docs/agent/conventions.md`): `fooField`, `fooTable`, `fooMarshaller`, `fooSchema`, `fooValidator`,
  `fooParam`; `internalFooIdField` is a table's own key column, `fooIdField` the foreign-key column other tables use.
- Literals through `Data.String.Interpolate.i`; `Flipstone.Prelude`; qualified imports; explicit export lists;
  boilerplate accepted over metaprogramming.

## 2. Entity: typed keys through a type family

`Artificer/Database/Entity.hs` (Launchpad's is the same):

```haskell
type role Entity nominal
data Entity entity = Entity
  { entityKey :: EntityKey entity, entityInsertedAt, entityUpdatedAt :: UTCTime
  , entityDisabledAt :: Maybe UTCTime, entityDisabledBy :: Maybe UserId, entity :: entity }

type family EntityKey idType
type Table entity = O.TableDefinition (O.HasKey (EntityKey entity)) entity (Entity entity)
```

How the pieces prevent cross-contamination:

1. **Each ID is its own newtype** (`newtype EntryId = EntryId Int32`), so `EntryId` and `PackId` are different
   types even though both are integers.
2. **The type family ties each domain type to exactly one key type**: `type instance Entity.EntityKey Entry = EntryId`
   lives beside `data Entry` (`Data/Entry/Entry.hs:37`). `Entity.Table Entry` therefore has key `HasKey EntryId`, and
   `O.findEntity entryTable` accepts only an `EntryId`. Passing a `PackId` is a type error.
3. **The write type and read type differ**: you insert an `Entry` and read back `Entity Entry`. The key and the
   timestamps are `O.marshallReadOnlyField`, so application code cannot write them; the database assigns them
   (`entityMarshaller`, lines 91–101).
4. **`type role Entity nominal`** stops `coerce` from turning `Entity Entry` into `Entity Pack`, which would otherwise
   be possible because the representations are the same.
5. **Foreign-key columns are derived from the referenced table, not written again.**
   `packIdField = Entity.addForeignKeyConstraintTo packTable` has type `FieldDefinition NotNull PackId` and carries
   the constraint. `Entry`'s marshaller uses `O.marshallField entryPackId packIdField`, so the column type, the
   Haskell type and the constraint all come from one place. A second relationship to the same table uses
   `O.prefixField "parent" packFolderIdField` (`Schema/PackFolder.hs:67-69`).
6. **The key's column comes from one shared field**: `internalEntryIdField = O.coerceField Entity.entityIdField`.

`mkEntityTable name idField marshaller` builds the table, wraps the marshaller and attaches the `updated_at` trigger.
`softDeleteEntities`/`restoreEntities`/`notDisabledCondition` are the only way rows are disabled; every query decides
explicitly whether disabled rows take part (for example `Handler/Authentication.hs:179-184`).

**Owner-approved adaptation for Lockstep:** keys are UUIDv4, not `Int32`. `mkEntityTable` and the foreign-key helpers
take the key field as a parameter instead of assuming `integerField "id"`, and the `Coercible Int32 key` constraint
becomes `Coercible UUID key`. The type-family, role and read-only mechanics stay exactly as they are.

## 3. UUIDs: the library, not a hand-written type

Checked in ghci (`.local/ghci/stack-study-3.ghci`):

- `uuid-types-1.0.6` and `uuid-1.3.16` are already in the snapshot. `Data.UUID.Types` gives `fromText :: Text ->
  Maybe UUID`, `toText`, `fromWords64`, `fromByteString`, plus `Eq`/`Ord`/`Show`; `Data.UUID.V4.nextRandom :: IO UUID`.
- Orville has `O.uuidField :: String -> FieldDefinition NotNull UUID` (native `uuid` column).
- Fleece and Beeline ship no UUID schema or parameter. Both are one-line compositions of library calls:
  - JSON: `FC.validateNamed "Uuid" UUID.toText parseCanonical FC.text`;
  - path: `R.convertParam (Just "uuid") parseCanonical UUID.toText (R.textParam name)`.
- **`fromText` accepts uppercase**: "3F2504E0-…" parses. Lockstep's frozen tests require non-canonical input to be
  refused, so `parseCanonical t` is "`fromText t`, then require `toText u == t`". That is a check layered on the
  library, not a parser of our own.
- An ID type then looks like Launchpad's `UserId` plus the Artificer pattern: `newtype ProjectId = ProjectId UUID`
  with `projectIdParam` (Beeline), `projectIdSchema` (Fleece) and the key field (Orville), each defined once in the ID
  module.

## 4. Fleece: one schema, both directions

- **One `FC.Schema t a`, polymorphic in the interpreter `t`.** The same definition is the Aeson encoder, the decoder
  (`FA.decode schema bytes`, used for configuration in `Launchpad/Config.hs:137`) and Orb's OpenAPI description.
- **Records**: `FC.object $ FC.constructor User #+ FC.required "name" field schema #+ FC.optional ...`. Field names are
  explicit wire names, and field order is the encoding order.
- **Validated and converted values**:
  - `FC.validate`/`FC.validateNamed to from base`, where `from` returns `Either String a`, so a decode fails with a
    message instead of producing a bad value;
  - `FC.transform` for total conversions (e.g. `nubOrd` in `supportedLanguagesSchema`);
  - `FC.coerceSchema` for newtypes;
  - `FC.boundedEnum toText` for enums.
- **Shared helpers** live in `Util/Fleece/*`:
  - `associationListSchema` turns a list into a `Map` and rejects duplicate keys;
  - `boundedTextSchema`;
  - `sumTagSchema`, which checks a constant tag field;
  - orphan schemas for library types (`bcp_47Schema`).
- **JSON in a column**: `Util/Orville/Fleece.fleeceField schema "col"` makes a `jsonb` column whose conversion is the
  schema (`UserSettings`, `EntryData`). The stored shape is the API shape, so changing it is a data migration.
- **Sum types are Shrubbery unions.**
  - `TaggedUnion` for anything we decode (`Data/Entry/EntryData/EntryData.hs`):
    - `type EntryData = TaggedUnion '["item" @= ItemData, "journal_entry" @= JournalEntryData, ...]`;
    - the schema is `FC.taggedUnionNamed name "type" (FC.taggedUnionMember @"item" itemObj #@ ...)`;
    - the type-level tag *is* the JSON discriminator value, so encoder, decoder and type cannot drift apart;
    - members are `FC.Object` schemas (no separate wrapper object).
    - In ghci, `taggedUnionMember` requires `KnownSymbol tag` and `TagType tag tags ~ a`: a tag naming the wrong
      type does not compile.
  - Values are built with `Shrubbery.unifyTaggedUnion @"journal_entry" value` and taken apart exhaustively with
    `dissectTaggedUnion . taggedBranchBuild . taggedBranch @"item" f . ... $ taggedBranchEnd`. Leaving a branch out is
    a compile error.
  - Open, extensible unions combine member lists with `Shrubbery.Append` and system-prefixed tags
    (`"100dos.ranged_weapon"`, `Data/Entry/EntryData/Item.hs:27-51`).
  - Plain `Union` + `FC.unionNamed`/`FC.unionMember` is untagged: decoding tries members in order. Artificer uses it
    **only for output it never decodes** and says so in a comment (`Data/Foundry/Document/Item.hs:41-46`). Rule: if
    it is read back, it is a `TaggedUnion`.

## 5. Routing: Shrubbery + Beeline + Orb

- **The route tree is a Shrubbery `Union` of route types.**
  - Each endpoint is its own type: `newtype GetUpdateUser = GetUpdateUser { getUpdateUserId :: UserId }`.
  - Each feature has a `Routes` union and a router: `R.routeList $ Orb.get path /: Orb.put path2 /: R.emptyRoutes`.
  - Subtrees are mounted with `R.make id /> R.Subrouter featureRouter id`.
  - `Orb.dispatch` dispatches over the union (`Launchpad/Routes.hs`, `Routes/App.hs`, `Routes/App/Admin.hs`).
- **A path is a value, defined once, polymorphic in the router**:

  ```haskell
  updateUser :: R.Router r => (UserId -> a) -> (a -> UserId) -> R.Builder r a a
  updateUser con acc = R.make con /- appRootPath /- "admin" /- "users" /+ R.Param userIdParam acc
  ```

  - With Orb's `ServerRouter` (the `RouteRecognizer` instance) it recognises requests and parses the typed parameter.
  - With Beeline's `RouteGenerator` it renders the URL.
  - Shared prefixes are values too (`Common.appRootPath`).
  - Paths without parameters take the route constructor directly (`Common.login :: route -> R.Builder r route route`).
- **Links are typed by HTTP method.**
  - `B.get :: route -> R.Builder R.RouteGenerator route route -> B.RelativeURL B.Get` (and `B.put`, `B.post`,
    `B.delete`, `B.patch`).
  - Launchpad exposes `getUpdateUserLink :: UserId -> RelativeURL Get` and `putUpdateUserLink`.
  - Artificer generalises this to one function per path, `entriesURL :: (Entries -> Builder RouteGenerator ... ->
    RelativeURL op) -> PackId -> RelativeURL op`, called as `entriesURL B.put packId`
    (`Routes/App/Packs/Entries/Shared.hs:39-46`).
  - Static assets are typed URLs the same way (`Components/Static.hs`).
  - `B.mkURL` lifts a relative URL into a redirect target (`Common.page404`, `R.redirectHeader $ B.mkURL loginLink`).
  - The application contains no internal URL string literals.
- **A handler declares its whole contract in types** (`Routes/App/Admin/Users/Update/Put.hs`):
  - `instance Orb.HasHandler PutUpdateUser` with associated types `HandlerRequestBody`, `HandlerResponses`,
    `HandlerPermissionAction` and `HandlerMonad`;
  - `HandlerResponses` is a type-level list
    (`[Response200 (ChildHTML Table NoElement), Response303 NoContent, ..., Response422 FormErrors]`);
  - `Orb.handlerResponseBodies` must give a body or schema for each entry in that list
    (`addResponseBody200 textHtml renderLazyHTML`, `addResponseSchema422 formErrorsSchema`);
  - the handler returns `Shrubbery.TaggedUnion` of that list through `Orb.return200 ...`, so it cannot return a status
    it did not declare.
- **Request bodies** (checked in ghci, `Orb.RequestBody`):
  - `FormDataRequestBody (Form -> Either err body)`, which requires the 400 and 422 responses;
  - `SchemaRequestBody (forall t. Fleece t => Schema t body)` for JSON (requires 422; malformed JSON never reaches the
    handler);
  - `RawRequestBody`;
  - `EmptyRequestBody`.

  Headers and queries use Beeline parameter schemas: `BP.makeParams AuthHeader ?+ BP.required authorization
  (BP.textParam "Authorization")`.
- **Permission actions run before the handler and hand it a value.**
  - `Orb.PermissionAction` has associated `PermissionActionResult`, `PermissionActionError` and
    `PermissionActionMonad`.
  - The result (an `Entity User`) is the handler's second argument.
  - `Orb.PermissionError` carries `PermissionErrorConstraints err tags`, for example
    `(HasResponseCodeWithType tags "303" NoContent, HasResponseCodeWithType tags "403" UnauthorizedMessage)`. A route
    that uses an admin permission does not compile unless its response list declares those responses
    (`Handler/Authentication.hs:136-154`).
  - Artificer makes **the route type its own permission action** (`mkPermissionAction = Orb.reqRoute`;
    `checkPermissionAction = permittedForPackOwnerOrAdmin View . postEntryPackId`). The check reads the typed `PackId`
    from the path, loads the pack, its package and the user in one transaction, and passes the handler an
    `AuthenticatedPack` record (`Routes/App/Packs/Permission.hs`). Handlers never look up the same rows again.
- **OpenAPI** comes from the same definitions: `Orb.provideOpenApi "docs" (R.make id /> R.Subrouter API.routes id)`
  plus `Orb.swaggerUIRoutes`.

## 6. Front end: Brigid + HTMX, server-rendered

- **Pages and fragments are typed Brigid values.** `E.ChildHTML parent grandparent` records where a fragment may
  appear, and an Orb response type can say so: `Response201 (E.ChildHTML E.Main E.Body)` is a fragment that belongs
  in `<main>`.
- **HTMX attributes take typed URLs**:
  - `A.htmx :: RelativeURL method -> Attribute tag` writes `hx-get`/`hx-put`/... from the method in the type;
  - `A.hxTarget (HTML.mkQuerySelector entriesId)` and `A.id entriesId` use the same `B.Id`, so an element and every
    request targeting it share one definition (`Routes/App/Packs/Entries/Render.hs:37-52`);
  - triggers, swaps and events are typed too (`HTML.mkTrigger`, `HTML.swapOuterHTML`, `HTML.HtmxAfterRequest`).
- **Form field names are typed**:
  - `B.Name` (and `B.Id`) are `NonEmptyText` newtypes, declared once (`Routes/App/Packs/Shared.hs`);
  - the same `B.Name` is used for `A.name` on the input and for `V.required name validator` when parsing the
    submission, so the form and its parser cannot disagree on a field name.
- **Components are records of typed inputs**:
  - `Button name method tag` takes `buttonLink :: B.RelativeURL method` and `buttonTarget :: Maybe B.Id`;
  - `Select` takes `selectOptionToValue`, the type's canonical text function;
  - the page shell is `Html { htmlTitle, htmlExtraScripts :: [Safe.ExternalScript (RelativeURL Get)], ... }`
    (`Components/Html.hs`, `Body.hs`, `Form/Button.hs`).

  Components render state they are given; they never query or authorise.
- **The server owns the state.**
  - Each interaction is an ordinary typed route that returns a Brigid fragment.
  - JavaScript is limited to small hooks such as `closeModal`, `handleButtonDisable` and `sort-cards.js`.
  - Launchpad's rule: no client-side routing for behaviour the routes already represent.

## 7. Validation

`Launchpad/Validation.hs`:

- `Validator input a` is an `Applicative` that **accumulates** errors.
  - `required`/`optional`/`nullable`/`optionalNullable` take a `B.Name`.
  - `chain` composes steps (`V.text \`V.chain\` V.eitherValidator foundryIdFromText`).
- Domain validators live with their types (`usernameValidator`, `visibilityValidator`).
- A failed form returns `Response422 FormErrors`, serialised with `formErrorsSchema`.

## 8. Application monad and database access

- `newtype Launchpad a = Launchpad (ReaderT AppContext IO a)` derives `O.MonadOrville`/`MonadOrvilleControl` and
  implements `O.HasOrvilleState`, `Orb.HasRequest`/`HasRespond`/`HasLogger`. Handlers call Orville directly, and
  `O.withTransaction` sets transaction scope (`Types.hs`).
- **Batched reads use `Orville.PostgreSQL.Plan`**: `findAllWhere`, `findOne`, `planList`, `chain`, `focusParam`
  (`Artificer/Database/Queries.hs`), with no N+1 queries.
- **Grouped counts use typed synthetic fields**: `O.syntheticField Expr.count1AggregateFunction "entry_count"` with
  `selectMarshalledColumns` and `groupBy`.
- **Database functions and triggers are Orville schema objects**, attached to the table definition with
  `O.addTableTriggers`: `O.mkFunction`, `O.mkTriggerFunction` and `O.mkTriggerDefinition`
  (`Artificer/Database/{Functions,Triggers}.hs`).
- Both apps register their schema (`SchemaTable`, `SchemaFunction`) and migrate it with Orville's `AutoMigration`.

## 9. Constraints specific to Lockstep

- **Migrations stay explicit and checksummed SQL** (ADR-0002, FR-APP-03: ordered, forward-only, recorded). Auto-migration
  is out. The table definitions are still the typed description of the schema, and Orville's
  `generateMigrationPlan` against a migrated database is a library-provided drift check: an empty plan means the
  definitions and the migrations agree.
- **Soft deletion**: Lockstep has no user table yet. The owner's direction is to adopt the Entity model now and add
  `disabled_by` when users exist.
- **Append-only ledger tables** with refuse-change triggers (events, records, observations, decisions) are not entities
  that get updated or disabled. Their triggers can become `O.mkFunction`/`O.mkTriggerDefinition` values as in
  Artificer.
- **The Kernel must stay pure.** `uuid-types` is pure, so the Kernel can use `Data.UUID.Types.UUID`. `Data.UUID.V4`
  (IO) belongs at the Application boundary.
- **Frozen tests** call `parseUuid`, `uuidText` and the Kernel ID newtypes. Their behaviour (canonical lowercase only)
  is kept as a check on top of `Data.UUID`.

## 10. Where Lockstep departs today (summary; a full inventory follows as its own document)

- **UUIDs and IDs**:
  - `Kernel/Identity.hs` hand-writes a `Uuid` (two `Word64`s, a hex parser and printer);
  - `Application/Identity.hs:19-35` sets the v4 bits by hand where `Data.UUID.V4.nextRandom` exists;
  - persistence and the application pass IDs as `Text` (`Persistence/Fields.uuidField` carries `uuid` as text);
  - there is no `EntityKey`, no `Entity` and no typed foreign-key fields.
- **Routing**:
  - only health, readiness and liveness are Orb routes (`Web/Routes.hs`);
  - `/app` is matched by hand over `pathInfo` segments with `Text` IDs and a `validId` guard (`Web/App.hs:150-179`),
    and `/operator` and the control pane likewise;
  - there are no typed path parameters, links, permission actions, declared response unions or OpenAPI.
- **Front end**:
  - `/app` is a client-rendered shell driven by `static/app.js` (256 lines) and `static/control.js` (662 lines);
  - fragments and HTMX targets are not typed routes;
  - the app shell is hand-written markup.
- **Validation**: there is no `Validation`/`Form` module. ADR-0001 retained Launchpad's `Validation`,
  `Database.Entity`, permission actions and Orb dispatch, but none of them is in `src/` now.
- **Libraries dropped**:
  - `bounded-text`, which Launchpad uses for validated text;
  - `json-fleece-markdown`.
- **JSON**: role context documents still go through the hand-built `Foundation.Json` (audit J5).

The next document lists each departure with its replacement and order of work, starting with `Data.UUID` + typed IDs +
the UUID-keyed `Entity`, which unblock typed path parameters and Orb routing.
