# R-P2.5-1 — protected-test amendment request (C-P2.5)

- Prepared by: the writing agent (Implementer), 2026-10-19. Status: `APPROVED` by the human owner, 2026-10-19 ("R-P2.5-1 APPROVED … Authorize the exact two-literal amendment in `evidence/r-p2.5-1.diff`, replacing `unsafe-retry-budget` with `retry-budget-forbidden` in the frozen `EffectTest`."); recorded in C-P2.5 §10.1. A frozen test
  may be changed only with the human owner's approval. The protocol is the one used for
  R-P1.3-1, R-P1.5-1 and R-P2.3-1.
- Contract: `C-P2.5@v1`, frozen at `5f2d1e2`; implementation `d8fa98b`.
- File: `test/unit/Lockstep/Kernel/EffectTest.hs`, frozen SHA-256
  `da22e6abf955ae6d25ef9a92fc8e5cacba887e6bf635b058cb9d2a4a40992f28`.

## Conflict between two frozen artifacts

- C-P2.5 (frozen by me at `5f2d1e2`) names the class-D budget refusal `unsafe-retry-budget`.
  The frozen `EffectTest` asserts that exact string twice.
- C-P2.1's frozen Kernel purity scan (`scripts/lib/check-kernel-boundary`, digest `948496fb…`)
  runs `grep -E '\bIO\b|unsafe'` over `src/Lockstep/Kernel`. It therefore refuses the literal
  `"unsafe-retry-budget"` in `Lockstep.Kernel.Effect`, even though it is a string and not unsafe
  code. The check fails at the build step, at line 383 (`evidence/check-integration-unamended.log`).

I can't make the Kernel return that string without the literal appearing in Kernel source.
Building it from fragments would get past the scan's letter while defeating its purpose, and I
won't do that. The defect is my naming: I didn't run the frozen scan against the code
vocabulary before freezing C-P2.5.

Apart from this, P2.5 is green on the unamended tree:

- unit: 522/522 (`evidence/first-implementation-unit-run.log`);
- integration: 93/93, including all 14 new ledger cases (`evidence/integration-unamended.log`).

## Proposed amendment (two string literals; no other change)

Rename the refusal code to `retry-budget-forbidden`. The exact diff is in
`evidence/r-p2.5-1.diff`: 2 lines changed, both string literals.

```diff
-        refusedWith "unsafe-retry-budget" (mkEffectSpec "invoke" TermsUnqueryable 1)
+        refusedWith "retry-budget-forbidden" (mkEffectSpec "invoke" TermsUnqueryable 1)
…
-              , "unsafe-retry-budget"
+              , "retry-budget-forbidden"
```

Unchanged:

- the cases, the inputs and every other expectation;
- the constructor name `UnsafeRetryBudget` (capitalized, so the scan does not match it);
- the test title.

With approval, these would change too:

- the matching string in `Lockstep.Kernel.Effect`;
- the code name in C-P2.5 E1 and §7.

Alternative, **not recommended**: change the C-P2.1 scan to skip string literals. That weakens a
frozen safety check, and would be an amendment of its own.

## Trial

I applied the diff and the matching implementation string in the working tree and ran
`scripts/check --integration`. All 6 steps passed: 522 unit, 93 integration, purity scan clean
over 13 Kernel files (`evidence/check-integration-with-proposed-amendment.log`). I then restored
both files with `git checkout`. The frozen file's SHA-256 afterwards is `da22e6ab…`, unchanged.

## Decision requested

Approve R-P2.5-1 as written, or choose another code name or the alternative. If you approve, I
will:

1. apply the diff byte for byte and change the implementation string;
2. record the re-freeze digest in C-P2.5 §10.1;
3. re-run `scripts/check --integration` and a Linux clone, then write the P2.5 record;
4. continue to P2.6.
