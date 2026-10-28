# A-P4.3-1 — amendment request: import order in the frozen unit runner

- Prepared by: the writing agent (Implementer), 2026-10-28. **Not applied** (the frozen bytes are in the tree;
  digest checked after the trial). Needs the owner's (Planner's) authorization; the writing agent does not
  amend a frozen file on its own.
- File: `test/unit/Main.hs`, frozen in C-P4.3 §4 at
  `ee38476e022283dbd2a60338cf8726b9504688450fdbd49488174e771dda8fcd`.
- Defect: the runner line added for C-P4.3 (`import Lockstep.Kernel.ConversationTest …`) was placed after
  `EffectViewTest` instead of in alphabetical order, and the runner was not run through fourmolu before the
  freeze. The format step of `scripts/check` (step 1) therefore fails on `0fcb2b9`, and nothing after it runs.
  The pre-freeze format check was run before that line was added; the miss is in the writing agent's freeze
  procedure, not in any test's meaning.
- Change (exactly fourmolu's own output; one import line moved, nothing else):

```diff
@@ -30,11 +30,11 @@ import Lockstep.Foundation.OperatorTokenTest qualified as OperatorTokenTest
 import Lockstep.Foundation.SessionProtocolTest qualified as SessionProtocolTest
 import Lockstep.Foundation.SystemConfigTest qualified as SystemConfigTest
 import Lockstep.Kernel.ActivityTest qualified as ActivityTest
+import Lockstep.Kernel.ConversationTest qualified as ConversationTest
 import Lockstep.Kernel.DecisionTest qualified as DecisionTest
 import Lockstep.Kernel.DeliveryTest qualified as DeliveryTest
 import Lockstep.Kernel.EffectTest qualified as EffectTest
 import Lockstep.Kernel.EffectViewTest qualified as EffectViewTest
-import Lockstep.Kernel.ConversationTest qualified as ConversationTest
 import Lockstep.Kernel.EventCodecTest qualified as EventCodecTest
 import Lockstep.Kernel.ExecutionTest qualified as KernelExecutionTest
 import Lockstep.Kernel.IdentityTest qualified as IdentityTest
```

- Digest before: `ee38476e022283dbd2a60338cf8726b9504688450fdbd49488174e771dda8fcd`.
  Digest after: `7e9892b31c2ac908f2fe1fc8e3b0f40628bdb9b3ebf5dcd100606fe114bb6b1e`.
- Effect on tests: none. Import order does not change which groups run or in what order (the list in `main`
  is unchanged).
- Trial: the full `scripts/check --integration` was run with the change applied temporarily
  (`p43-trial-with-a-p4.3-1.log`), then the frozen bytes were restored and digest-checked. Result: see the
  trial record below.

## Trial record

- Without the change, `scripts/check --integration` on `0fcb2b9` (clean tree): step 1 format FAILED on exactly
  this hunk; steps 2–6 NOT_RUN (`check-integration-0fcb2b9.log`).
- With the change applied temporarily to `0fcb2b9` (tree DIRTY only by this file): format, lint, build (Kernel
  boundary and purity scan, 25 files), unit **818 of 818**, no-live-model guard, integration **454 of 454**
  and backup/restore all PASSED (`trial-with-a-p4.3-1.log`). The 454 are the 446 of `bd4512b` and the 8
  C-P4.3 cases.
- Restored with `git restore`; the file's digest is again
  `ee38476e022283dbd2a60338cf8726b9504688450fdbd49488174e771dda8fcd`.

## Decision

*(for the owner)*
