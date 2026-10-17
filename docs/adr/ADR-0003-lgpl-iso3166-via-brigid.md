# ADR-0003 — LGPL-3.0 `iso3166-country-codes` statically linked via Brigid

- Status: **PROPOSED** — awaiting the human owner. Blocks P1.1 acceptance (AC-P0-08).
- Affects: NFR-11, FR-APP-01; ARCHITECTURE §5.2 (license allowlist); ADR-0001 C2/C4
- Evidence: `docs/gates/P1.1/evidence/licenses.txt` (`scripts/licenses`),
  `THIRD_PARTY_LICENSES.md`, symbol search of the unstripped `lockstep` binary
  (`.local/evidence/P1.1/lockstep-symbols.txt`)

## Finding

The AC-P0-08 transitive inventory of the shipped `lockstep` executable found one
copyleft Haskell library **with object code in the binary**:

| Package | Version | License | How it enters | Linkage |
|---|---|---|---|---|
| `iso3166-country-codes` | 0.20140203.8 | **LGPL-3.0** (`COPYING.LESSER`) | direct dependency of Brigid `331dcc0` (`Brigid.HTML.Types.Phone`) | **static** (2,850 symbols) |

Brigid uses it, together with `libphonenumber`, only for its phone-number
attribute and `tel:` URL types. Lockstep uses neither. Brigid's `main` is the
pinned commit, so no upstream version avoids it today.

Checked and **not** an exception (no object code in the binary, verified by symbol
search): `c2hs` (GPL-2, build-time FFI generator), `tomland` and
`validation-selective` (MPL-2.0, Henforcer plugin dependencies), `henforcer`.

Native libraries, all **dynamic** (recorded, not new exceptions in practice):
GMP (LGPL-3.0/GPL-2.0, already anticipated in ARCHITECTURE §5.2), glibc
(LGPL-2.1), `libstdc++`/`libgcc_s` (GPL-3.0 with the GCC Runtime Library
Exception), and permissive libphonenumber (Apache-2.0), Abseil (Apache-2.0),
protobuf (BSD-3), ICU (Unicode License), zlib. ICU's Unicode License and the GCC
exception are not named in the §5.2 allowlist; they are listed for the same decision.

## Why it matters

LGPL-3.0 obligations attach when the binary is **conveyed** to someone. For a
statically linked library they include letting the recipient relink with a
modified version (for example by supplying object files). v2 is private and not
distributed (ADR-0001 C2), so no obligation is triggered today. ARCHITECTURE §5.2
still requires an ADR for any copyleft component linked into `lockstep`.

## Options

| | Option | Cost | Effect |
|---|---|---|---|
| **A (recommended for now)** | **Accept while private.** Record the exception and the dynamic system libraries; keep them in `THIRD_PARTY_LICENSES.md`; `scripts/licenses` fails if any *other* linked copyleft package appears. Resolve before any distribution decision, together with GMP (ARCHITECTURE §5.2). | None now | P1.1 can be accepted; distribution stays blocked on this ADR's follow-up |
| B | **Remove upstream.** Owner changes Brigid so phone-number support is behind a Cabal flag (off by default) or a separate package; Lockstep then bumps the Brigid pin in its own Work Unit. | One Brigid change + dependency-upgrade Work Unit | Also drops libphonenumber, protobuf, Abseil, ICU and `libstdc++` from the binary and the dev image |
| C | Replace `iso3166-country-codes` inside Brigid with a permissively licensed equivalent | Brigid change | Removes the LGPL item only; C++ libraries remain |
| D | Comply as if distributing (ship relinkable objects) | Ongoing packaging work | Unnecessary while private |

Recommendation: **A now, B before any distribution** (B is also the simplest way to
shrink the native dependency set).

## Approval

| Field | Value |
|---|---|
| Decision | _pending_ |
| Approver | _human owner_ |
| Date | _pending_ |
