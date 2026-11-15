# Amendments — C-P6.9 (from the independent review, R-P6.9)

Text corrections and limitations; the frozen C-P6.9 tests are unchanged.

| # | Contract text | Amended to |
|---|---|---|
| AM-P6.9-1 (P2) | "Evidence is links to Lockstep's own records … never free text." | Each link must resolve when proposed, or the proposal is refused `evidence-unknown`: `fix:ID` an existing fix; `record:ID:N` that fix's record N; `invalidation:ID` an invalidation of that fix; `request:ID` an existing request. Ids are stored in their canonical spelling (lower-case UUID), so the same link counts once and digests once. **Limitation:** `commit:SHA` is checked for form only (a full 40-hex SHA, stored in lower case); requiring a commit a fix recorded needs OQ-P6.9-1. |
| AM-P6.9-2 (P2) | Evidence keys | An id is not empty and holds no space, control character or `:`; a stored proposal whose evidence does not read back exactly is `proposal-unreadable` (never decided on other evidence). |
| AM-P6.9-3 (P5) | "For a `profile-rule` proposal, it is also refused when it is not the catalog's latest version of that Profile." | Also checked when proposed: a rule for a catalog Profile whose `current` is not its latest version is refused `stale-target`. **Limitation:** a rule for a target that is not a catalog Profile is still accepted (frozen case `selfPrivilege`) and can never be decided (fail closed); OQ-P6.9-1. |
| AM-P6.9-4 (§2 CLI) | Evidence kinds in `proposal propose` | The help names all five kinds. |
