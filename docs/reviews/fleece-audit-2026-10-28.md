# JSON and Fleece audit — 2026-10-28

- Asked by the owner. Read-only survey of `src/`, `app/`, `test/`, `static/` and the unbuilt Phase 4 drafts.
- **Deferred by the owner**: Phase 4 continues in the existing style; this and the Orville finding (all
  persistence modules run hand-written SQL strings instead of Orville's typed API) are fixed together after the
  post-Phase-4 dogfooding. Nothing here has been changed.

## Verdict

Decoding is sound: every JSON document the server reads goes through a strict Fleece schema that refuses
unknown keys (`lockstep.json` in `Foundation/SystemConfig.hs`; Profile documents in
`Application/ProfileDocument.hs`, from the CLI and from stored rows). Aeson is never used directly; no JSON is
hand-parsed in production. **Encoding never uses Fleece**: there is no `FA.encode` anywhere.

## Findings — production

| # | Severity | Where | What |
|---|---|---|---|
| J1 | HIGH | `Web/SecureResponse.hs:60-75` `jsonString` | Hand-written JSON string escaper behind every JSON response. Characters above U+FFFF are written as `\u` + 5 hex digits (no surrogate pair; `justifyRight` pads but never truncates): U+1F600 becomes `ὠ0`, read by a parser as U+1F60 then `0`. Emoji and other non-BMP characters in folder paths, helper result text, details and reasons are silently corrupted. Structure is not breakable (`"`, `\`, controls, `<>&` handled). Verified by reading the code. |
| J2 | MEDIUM | `Web/SecureResponse.hs:51-53` `errorJson` (~40 call sites), `Web/Control.hs:199–316` (result, folder list, session, id, url bodies), `Web/App.hs:233` | Every JSON response body is assembled from strings instead of Fleece encoder schemas. |
| J3 | LOW | `Application/Execution.hs:75-103`, `Application/ProjectChecks.hs:74-76` | Built-in Profile documents written as JSON text, checked only by decoding at runtime (constants). |
| J4 | — | `Kernel/EventCodec.hs`, `Kernel/Profile.hs` rendering, `Kernel/Conversation.hs` payload texts, the control and runner line protocols | Not JSON: documented canonical digest or protocol texts. Not findings. |

Design choice for the fix: `jsonString` escapes `<`, `>`, `&` so no response can be read as markup; with Fleece
encoding that moves to a pass over the encoded bytes, or is dropped because responses are `application/json`
with `nosniff`.

## Findings — tests

- The test suites do not depend on json-fleece, so ~31 sites take values out of JSON responses by substring and
  offset (e.g. `take 43 . drop 11` after `"session":"`), fragile to key order and spacing. MEDIUM, test-only.
- `test/integration/Lockstep/Support/Postgres.hs:157-173` `writeConfigFile` puts the password into
  `lockstep.json` without escaping (a `"` or `\` would make it invalid). MEDIUM, test-only.
- No unit test covers `jsonString` outside the Basic Multilingual Plane.

## Findings — Phase 4 drafts

- `.local/p45-draft/src/Lockstep/Foundation/Json.hs`: a second hand-written JSON encoder (RFC-correct escaping)
  for role context documents. Kept only if the existing style requires it (owner's decision: no mix in Phase 4).
- Role answers (`result.json`) are decoded through ~13 strict Fleece schemas: consistent with the existing
  decoding style.
