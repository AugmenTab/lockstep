# Third-party components in Lockstep v2

- Generated from `scripts/licenses` (evidence: `docs/gates/P1.2/evidence/licenses.txt`)
- Scope: the `lockstep` library and executable (test suites excluded), built in the
  dev container (Debian 12, GHC 9.10.3, Stackage lts-24.12)
- Lockstep v2 is private and not distributed. This file records notices; it does
  not make a distribution decision (ADR-0001 C2).

## Launchpad

Portions of Lockstep are derived from Launchpad `11886bf`, BSD-3-Clause,
Copyright (c) 2023 Tyler Baum. Full text: `LICENSE-LAUNCHPAD`.

## Shipped browser assets

None from third parties yet. `static/lockstep.css` is Lockstep's own.

## PostgreSQL server (separate process, not linked)

`postgres:17.11-bookworm` (PostgreSQL License) runs in its own container via `scripts/db`.

## Native libraries linked dynamically by the `lockstep` executable

All are Debian 12 system libraries, loaded dynamically. The LGPL entries are in the
category ADR-0003 records (dynamic system libraries); they must be reviewed again
before any distribution decision, together with GMP.

| Library | Debian package | License | Note |
|---|---|---|---|
| glibc (`libc`, `libm`, loader) | libc6 2.36-9+deb12u14 | LGPL-2.1-or-later | system C library |
| `libgcc_s` | libgcc-s1 12.2.0-14+deb12u1 | GPL-3.0 with GCC Runtime Library Exception | compiler runtime |
| `libstdc++` | libstdc++6 12.2.0-14+deb12u1 | GPL-3.0 with GCC Runtime Library Exception | via libphonenumber |
| GMP | libgmp10 2:6.2.1+dfsg1-1.1 | LGPL-3.0-or-later / GPL-2.0-or-later | GHC `ghc-bignum` backend (ARCHITECTURE §5.2) |
| libpq | libpq5 15.19-0+deb12u1 | PostgreSQL License | PostgreSQL client (P1.2) |
| OpenSSL | libssl3 3.0.22-1~deb12u1 | Apache-2.0 | via libpq |
| MIT Kerberos (`krb5`, `k5crypto`, `gssapi_krb5`, `krb5support`, `com_err`) | libkrb5-3 / libk5crypto3 / libgssapi-krb5-2 / libkrb5support0 1.20.1-2+deb12u5; libcom-err2 1.47.0-2+b2 | MIT | via libpq |
| OpenLDAP `libldap` | libldap-2.5-0 2.5.13+dfsg-5 | OpenLDAP Public License 2.8 | via libpq |
| Cyrus SASL | libsasl2-2 2.1.28+dfsg-10 | BSD-4-Clause-like (CMU) | via libldap |
| GnuTLS | libgnutls30 3.7.9-2+deb12u7 | LGPL-2.1-or-later | via libldap |
| Nettle / Hogweed | libnettle8 / libhogweed6 3.8.1-2 | LGPL-3.0-or-later / GPL-2.0-or-later | via GnuTLS |
| libidn2 | libidn2-0 2.3.3-1+b1 | LGPL-3.0-or-later / GPL-2.0-or-later | via GnuTLS |
| libunistring | libunistring2 1.0-2 | LGPL-3.0-or-later / GPL-2.0-or-later | via libidn2 |
| libtasn1 | libtasn1-6 4.19.0-2+deb12u1 | LGPL-2.1-or-later | via GnuTLS |
| p11-kit | libp11-kit0 0.24.1-2 | BSD-3-Clause | via GnuTLS |
| keyutils | libkeyutils1 1.6.3-2 | LGPL-2.1-or-later | via Kerberos |
| libffi | libffi8 3.4.4-1 | MIT | via p11-kit |
| libphonenumber | libphonenumber8 8.12.57+ds-3 | Apache-2.0 | required by Brigid |
| Protocol Buffers | libprotobuf32 3.21.12-3+deb12u1 | BSD-3-Clause | via libphonenumber |
| Abseil | libabsl20220623 20220623.1-1+deb12u2 | Apache-2.0 | via libphonenumber |
| ICU | libicu72 72.1-3+deb12u1 | Unicode License (ICU) | via libphonenumber |
| zlib | zlib1g 1:1.2.13.dfsg-1 | Zlib |  |

## Haskell packages (transitive closure, statically linked unless noted)

261 packages. Licenses are as declared by each package (`stack ls dependencies --license`).

| Package | Version | License | Note |
|---|---|---|---|
| Cabal | 3.12.1.0 | BSD-3 |  |
| Cabal-syntax | 3.12.1.0 | BSD-3 |  |
| HUnit | 1.6.2.0 | BSD3 |  |
| OneTuple | 0.4.2 | BSD3 |  |
| QuickCheck | 2.15.0.1 | BSD3 |  |
| StateVar | 1.2.2 | BSD3 |  |
| adjunctions | 4.4.3 | BSD2 |  |
| aeson | 2.2.3.0 | BSD3 |  |
| aeson-pretty | 0.8.10 | BSD3 |  |
| alex | 3.5.4.0 | BSD3 |  |
| ansi-terminal | 1.1.3 | BSD3 |  |
| ansi-terminal-types | 1.1.3 | BSD3 |  |
| appar | 0.1.8 | BSD3 |  |
| array | 0.5.8.0 | BSD-3 |  |
| asn1-encoding | 0.9.6 | BSD3 |  |
| asn1-parse | 0.9.5 | BSD3 |  |
| asn1-types | 0.3.4 | BSD3 |  |
| assoc | 1.1.1 | BSD3 |  |
| async | 2.2.5 | BSD3 |  |
| attoparsec | 0.14.4 | BSD3 |  |
| attoparsec-aeson | 2.2.2.0 | BSD3 |  |
| attoparsec-iso8601 | 1.1.1.0 | BSD3 |  |
| auto-update | 0.2.6 | MIT |  |
| barbies | 2.1.1.0 | BSD3 |  |
| base | 4.20.2.0 | BSD-3 |  |
| base-compat | 0.14.1 | MIT |  |
| base-compat-batteries | 0.14.1 | MIT |  |
| base-orphans | 0.9.3 | MIT |  |
| base16-bytestring | 1.0.2.0 | BSD3 |  |
| base64-bytestring | 1.2.1.0 | BSD3 |  |
| basement | 0.0.16 | BSD3 |  |
| beeline-http-client | 0.9.0.1 | MIT |  |
| beeline-params | 0.1.0.1 | MIT |  |
| beeline-routing | 0.3.0.2 | MIT |  |
| bifunctors | 5.6.2 | BSD3 |  |
| binary | 0.8.9.3 | BSD-3 |  |
| bitvec | 1.1.5.0 | BSD3 |  |
| blaze-builder | 0.4.4.1 | BSD3 |  |
| boring | 0.2.2 | BSD3 |  |
| brigid | 0.4.0.0 | BSD3 |  |
| bsb-http-chunked | 0.0.0.4 | BSD3 |  |
| byteorder | 1.0.4 | BSD3 |  |
| bytestring | 0.12.2.0 | BSD-3 |  |
| c2hs | 0.28.8 | GPL-2 | build tool (FFI generator for libphonenumber); **not linked** (0 symbols) |
| cabal-doctest | 1.0.11 | BSD3 |  |
| call-stack | 0.4.0 | MIT |  |
| case-insensitive | 1.2.1.0 | BSD3 |  |
| cborg | 0.2.10.0 | BSD3 |  |
| cereal | 0.5.8.3 | BSD3 |  |
| character-ps | 0.1 | BSD3 |  |
| clock | 0.8.4 | BSD3 |  |
| cmdargs | 0.10.22 | BSD3 |  |
| colour | 2.3.6 | MIT |  |
| comonad | 5.0.9 | BSD3 |  |
| concurrent-output | 1.10.21 | BSD2 |  |
| conduit | 1.3.6.1 | MIT |  |
| conduit-extra | 1.3.8 | MIT |  |
| constraints | 0.14.2 | BSD2 |  |
| containers | 0.7 | BSD-3 |  |
| contravariant | 1.5.5 | BSD3 |  |
| cookie | 0.5.1 | MIT |  |
| cryptohash-md5 | 0.11.101.0 | BSD3 |  |
| cryptohash-sha1 | 0.11.101.0 | BSD3 |  |
| crypton | 1.0.4 | BSD3 |  |
| crypton-connection | 0.4.5 | BSD3 |  |
| crypton-socks | 0.6.2 | BSD3 |  |
| crypton-x509 | 1.7.7 | BSD3 |  |
| crypton-x509-store | 1.6.11 | BSD3 |  |
| crypton-x509-system | 1.6.7 | BSD3 |  |
| crypton-x509-validation | 1.6.14 | BSD3 |  |
| data-default | 0.8.0.1 | BSD3 |  |
| data-default-class | 0.2.0.0 | BSD3 |  |
| data-fix | 0.3.4 | BSD3 |  |
| deepseq | 1.5.0.0 | BSD-3 |  |
| directory | 1.3.8.5 | BSD-3 |  |
| distributive | 0.6.2.1 | BSD3 |  |
| dlist | 1.0 | BSD3 |  |
| easy-file | 0.2.5 | BSD3 |  |
| either | 5.0.3 | BSD3 |  |
| entropy | 0.4.1.11 | BSD3 |  |
| erf | 2.0.0.0 | BSD3 |  |
| exceptions | 0.10.9 | BSD-3 |  |
| extra | 1.8 | BSD3 |  |
| fast-logger | 3.2.6 | BSD3 |  |
| file-embed | 0.0.16.0 | BSD2 |  |
| filepath | 1.5.4.0 | BSD-3 |  |
| filepattern | 0.1.3 | BSD3 |  |
| first-class-families | 0.8.1.0 | MIT |  |
| flipstone-prelude | 0.3.3.1 | MIT |  |
| foldable1-classes-compat | 0.1.2 | BSD3 |  |
| free | 5.2 | BSD3 |  |
| generically | 0.1.1 | BSD3 |  |
| generics-sop | 0.5.1.4 | BSD3 |  |
| ghc | 9.10.3 | BSD-3 |  |
| ghc-bignum | 1.3 | BSD-3 |  |
| ghc-boot | 9.10.3 | BSD-3 |  |
| ghc-boot-th | 9.10.3 | BSD-3 |  |
| ghc-heap | 9.10.3 | BSD-3 |  |
| ghc-internal | 9.1003.0 | BSD-3 |  |
| ghc-platform | 0.1.0.0 | BSD-3 |  |
| ghc-prim | 0.12.0 | BSD-3 |  |
| ghci | 9.10.3 | BSD-3 |  |
| half | 0.3.3 | BSD3 |  |
| happy | 2.1.7 | BSD2 |  |
| happy-lib | 2.1.7 | BSD2 |  |
| hashable | 1.5.0.0 | BSD3 |  |
| haskell-lexer | 1.2.1 | MIT |  |
| haskell-src-exts | 1.23.1 | BSD3 |  |
| haskell-src-meta | 0.8.15 | BSD3 |  |
| hedgehog | 1.5 | BSD3 |  |
| henforcer | 1.0.0.0 | BSD3 | GHC plugin, compile time only; **not linked** |
| hourglass | 0.2.12 | BSD3 |  |
| hpc | 0.7.0.2 | BSD-3 |  |
| html-email-validate | 0.2.0.0 | BSD3 |  |
| http-client | 0.7.19 | MIT |  |
| http-client-tls | 0.3.6.4 | MIT |  |
| http-conduit | 2.3.9.1 | BSD3 |  |
| http-date | 0.0.11 | BSD3 |  |
| http-media | 0.8.1.1 | MIT |  |
| http-semantics | 0.3.0 | BSD3 |  |
| http-types | 0.12.4 | BSD3 |  |
| http2 | 5.3.10 | BSD3 |  |
| indexed-profunctors | 0.1.1.1 | BSD3 |  |
| indexed-traversable | 0.1.4 | BSD2 |  |
| indexed-traversable-instances | 0.1.2 | BSD2 |  |
| insert-ordered-containers | 0.2.7 | BSD3 |  |
| integer-conversion | 0.1.1 | BSD3 |  |
| integer-gmp | 1.1 | BSD-3 |  |
| integer-logarithms | 1.0.4 | MIT |  |
| integer-types | 0.1.4.1 | Apache-2.0 |  |
| invariant | 0.6.4 | BSD2 |  |
| iproute | 1.7.15 | BSD3 |  |
| iso3166-country-codes | 0.20140203.8 | LGPL | **LGPL-3.0, statically linked** (via Brigid). Accepted while private: ADR-0003. |
| json-fleece-aeson | 0.5.0.0 | MIT |  |
| json-fleece-core | 0.10.0.0 | MIT |  |
| kan-extensions | 5.2.7 | BSD3 |  |
| language-c | 0.10.0 | BSD3 |  |
| lens | 5.3.5 | BSD2 |  |
| libphonenumber | 0.1.3.0 | MIT |  |
| lifted-async | 0.10.2.7 | BSD3 |  |
| lifted-base | 0.2.3.12 | BSD3 |  |
| lockstep | 0.2.0.0 | AllRightsReserved | this package; no license chosen (ADR-0001 C2) |
| megaparsec | 9.7.0 | BSD2 |  |
| memory | 0.18.0 | BSD3 |  |
| mime-types | 0.1.2.0 | MIT |  |
| mmorph | 1.2.1 | BSD3 |  |
| monad-control | 1.0.3.1 | BSD3 |  |
| mono-traversable | 1.0.21.0 | MIT |  |
| mtl | 2.3.1 | BSD-3 |  |
| network | 3.2.8.0 | BSD3 |  |
| network-byte-order | 0.1.7 | BSD3 |  |
| network-control | 0.1.7 | BSD3 |  |
| network-info | 0.2.1 | BSD3 |  |
| network-uri | 2.6.4.2 | BSD3 |  |
| non-empty-text | 0.2.1 | MIT |  |
| ogma | 0.1.0.1 | BSD3 |  |
| old-locale | 1.0.0.7 | BSD3 |  |
| old-time | 1.1.0.4 | BSD3 |  |
| openapi3 | 3.2.4 | BSD3 |  |
| optics-core | 0.4.1.1 | BSD3 |  |
| optics-extra | 0.4.2.1 | BSD3 |  |
| optics-th | 0.4.1 | BSD3 |  |
| optparse-applicative | 0.18.1.0 | BSD3 |  |
| orb | 0.7.0.0 | MIT |  |
| orville-postgresql | 1.1.1.0.0 | MIT |  |
| os-string | 2.0.7 | BSD-3 |  |
| parallel | 3.2.2.0 | BSD3 |  |
| parsec | 3.1.18.0 | BSD-2 |  |
| parser-combinators | 1.3.0 | BSD3 |  |
| pem | 0.2.4 | BSD3 |  |
| pollock | 0.1.0.3 | MIT |  |
| postgresql-libpq | 0.11.0.0 | BSD3 |  |
| postgresql-libpq-configure | 0.11 | BSD3 |  |
| pretty | 1.1.3.6 | BSD-3 |  |
| pretty-show | 1.10 | MIT |  |
| prettyprinter | 1.7.1 | BSD2 |  |
| prettyprinter-ansi-terminal | 1.1.3 | BSD2 |  |
| primitive | 0.9.1.0 | BSD3 |  |
| process | 1.6.26.1 | BSD-3 |  |
| profunctors | 5.6.3 | BSD3 |  |
| psqueues | 0.2.8.2 | BSD3 |  |
| quaalude | 0.0.0.1 | Apache-2.0 |  |
| quote-quot | 0.2.1.0 | BSD3 |  |
| random | 1.2.1.3 | BSD3 |  |
| recv | 0.1.1 | BSD3 |  |
| reflection | 2.1.9 | BSD3 |  |
| resource-pool | 0.4.0.0 | BSD3 |  |
| resourcet | 1.3.0 | BSD3 |  |
| rts | 1.0.2 | BSD-3 |  |
| safe | 0.3.21 | BSD3 |  |
| safe-exceptions | 0.1.7.4 | MIT |  |
| scientific | 0.3.8.0 | BSD3 |  |
| selective | 0.7.0.1 | MIT |  |
| semaphore-compat | 1.0.0 | BSD-3 |  |
| semialign | 1.3.1 | BSD3 |  |
| semigroupoids | 6.0.1 | BSD2 |  |
| semigroups | 0.20 | BSD3 |  |
| serialise | 0.2.6.1 | BSD3 |  |
| shrubbery | 0.2.3.2 | MIT |  |
| simple-sendfile | 0.2.32 | BSD3 |  |
| sop-core | 0.5.0.2 | BSD3 |  |
| split | 0.2.5 | BSD3 |  |
| splitmix | 0.1.3.1 | BSD3 |  |
| stm | 2.5.3.1 | BSD-3 |  |
| streaming-commons | 0.2.3.0 | MIT |  |
| strict | 0.5.1 | BSD3 |  |
| string-interpolate | 0.3.4.0 | BSD3 |  |
| syb | 0.7.2.4 | BSD3 |  |
| system-cxx-std-lib | 1.0 | BSD-3 |  |
| tagged | 0.8.9 | BSD3 |  |
| tasty | 1.5.3 | MIT |  |
| template-haskell | 2.22.0.0 | BSD-3 |  |
| terminal-size | 0.3.4 | BSD3 |  |
| text | 2.1.3 | BSD-2 |  |
| text-builder-linear | 0.1.3 | BSD3 |  |
| text-conversions | 0.3.1.1 | ISC |  |
| text-iso8601 | 0.1.1 | BSD3 |  |
| text-short | 0.1.6 | BSD3 |  |
| th-abstraction | 0.7.1.0 | ISC |  |
| th-compat | 0.1.6 | BSD3 |  |
| th-expand-syns | 0.4.12.0 | BSD3 |  |
| th-lift | 0.8.6 | BSD3 |  |
| th-orphans | 0.13.16 | BSD3 |  |
| th-reify-many | 0.1.10 | BSD3 |  |
| these | 1.2.1 | BSD3 |  |
| time | 1.12.2 | BSD-2 |  |
| time-compat | 1.9.8 | BSD3 |  |
| time-manager | 0.2.3 | MIT |  |
| tls | 2.1.8 | BSD3 |  |
| tomland | 1.3.3.3 | MPL-2.0 | Henforcer plugin dependency; **not linked** (0 symbols) |
| transformers | 0.6.1.1 | BSD-3 |  |
| transformers-base | 0.4.6 | BSD3 |  |
| transformers-compat | 0.7.2 | BSD3 |  |
| type-errors | 0.2.0.2 | BSD3 |  |
| typed-process | 0.2.13.0 | MIT |  |
| unicode-data | 0.6.0 | Apache-2.0 |  |
| unicode-transforms | 0.4.0.1 | BSD3 |  |
| unix | 2.8.7.0 | BSD-3 |  |
| unix-compat | 0.7.4.1 | BSD3 |  |
| unix-time | 0.4.17 | BSD3 |  |
| unliftio | 0.2.25.1 | MIT |  |
| unliftio-core | 0.2.1.0 | MIT |  |
| unordered-containers | 0.2.20 | BSD3 |  |
| utf8-string | 1.0.2 | BSD3 |  |
| uuid | 1.3.16 | BSD3 |  |
| uuid-types | 1.0.6 | BSD3 |  |
| validation | 1.1.3 | BSD3 |  |
| validation-selective | 0.2.0.0 | MPL-2.0 | Henforcer plugin dependency; **not linked** (0 symbols) |
| vault | 0.3.1.5 | BSD3 |  |
| vector | 0.13.2.0 | BSD3 |  |
| vector-algorithms | 0.9.1.0 | BSD3 |  |
| vector-stream | 0.1.0.1 | BSD3 |  |
| void | 0.7.3 | BSD3 |  |
| wai | 3.2.4 | MIT |  |
| wai-extra | 3.1.18 | MIT |  |
| wai-logger | 2.5.0 | BSD3 |  |
| warp | 3.4.9 | MIT |  |
| witherable | 0.5 | BSD3 |  |
| wl-pprint-annotated | 0.1.0.1 | BSD3 |  |
| word8 | 0.1.3 | BSD3 |  |
| zlib | 0.7.1.1 | BSD3 |  |
