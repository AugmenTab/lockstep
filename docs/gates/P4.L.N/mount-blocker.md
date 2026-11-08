# C-P4.L.N — the config-directory ownership conflict (decision needed)

- Found 2026-11-01 by the writing agent (Implementer, manual) while implementing N1. Implementation paused here.

## The conflict

Three established constraints cannot all hold at once for the mounted config directory:

1. **The isolation (C-P4.L.R3):** the tools (all repository code) run as the **operator's own uid**, deliberately,
   so files the tools write in the tree are owned by the operator. The CLI runs as a separate uid (2000000000) with
   `CAP_DAC_OVERRIDE`.
2. **Native login (C-P4.L.N N1):** the owner runs `claude auth login` on the host, so the config directory and its
   credential files are owned by the **operator's uid** and must persist and be refreshable across runs.
3. **N1 / Planner clarification 1:** the tools must **not** be able to read the credential, and **Lockstep must not
   copy, inspect, or write inside** the config directory ("No secret copying or inspection by Lockstep").

But the tools run as the operator's uid (1), and the credential files are owned by the operator's uid (2) — so, by
file ownership, **the tools can already read them** inside the container. Nothing hides an operator-owned file from a
process running as the operator. The CLI reading them is fine (it has `CAP_DAC_OVERRIDE`); the tools reading them is
the violation.

Every way to hide them breaks one of the three:

| Option | Hides from tools? | Breaks |
|---|---|---|
| A. `agent-entry` re-owns the dir to the CLI uid at container start (chmod 700) | yes | needs `CAP_CHOWN` added to the role container (a change to the qualified R3 capability set), and it **writes** to the dir (metadata) — against N1 "never writes inside it"; on a **Linux** host the bind-mount ownership change is visible on the host (the operator needs root to use the dir afterward). On macOS/OrbStack the host dir is unaffected. |
| B. `agent-entry` copies the dir into the CLI's private home at start | yes | **copying the credential** — against Planner clarification 1 ("No secret copying"); a refreshed token does not persist across runs. |
| C. The tools run as a uid distinct from the operator's | yes | tree files the tools write are then **not owned by the operator** — against the R3 intent that the host user owns repository changes. |

## What I will not do without a decision

Pick one silently. Each relaxes a constraint the owner or Planner set, and all touch the credential boundary or the
qualified isolation.

## The options, with my read

- **Option A, scoped to the attended smoke host (macOS/OrbStack):** on this Mac the host dir is unaffected by the
  container-side chown, refresh persists, and the only cost is adding `CAP_CHOWN` to the role container and amending
  N1's "never writes inside it" to "never reads or copies the credential; may set the directory's ownership so only
  the CLI can read it". The Linux-host side effect is documented as a residual (the smoke is not on Linux). This is
  the smallest change that keeps the credential out of the tools' reach while leaving the owner's login untouched in
  content. **My recommendation, if the owner accepts a narrowly added capability and the reworded N1.**
- **Option C** is the structurally cleanest (no touching the dir, refresh persists as the CLI's uid) but reverses an
  R3 decision about who owns tree writes; that is a larger reopening than this increment's scope.
- **Option B** is ruled out by clarification 1.

## Decision requested

Which option (A as scoped, C, or another the owner prefers), and — for A — approval to add `CAP_CHOWN` to the role
container and to reword N1 accordingly. Until then the native helper path is not implemented; the frozen check
(`aaefedb`) stands RED on the native path, and the filter, contract and supersession are in place.
