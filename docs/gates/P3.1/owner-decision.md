# DR-P3.1 — Owner decision (2026-10-25)

- Decided by: the human owner, 2026-10-25, in answer to the Implementer's request for explicit
  approval of the Planner's disposition (`.local/plans/phase-03_update1.md`).
- Recorded verbatim below by the writing agent (Implementer). The agent decided nothing here.
- Supersedes the open choices in `design-request.md` §8.

Mapping to the request's decision letters (for traceability; the owner's text below governs):

| Decision | Disposition |
|---|---|
| S | (a), amended: T1–T7 for the bootstrap control pane only; T8 deferred to P3.4 |
| L | (a): cookie pages and frozen tests preserved; retirement planned at P3.4 by separately authorized amendments |
| B | (a), amended: pane without Docker socket, narrow helper as the invoking OS user, private authenticated channel, versioned allowlist, replay protection, serialized execution, bounded timeouts, durable results |
| R | recommended: one-time terminal build with progress; no rebuild on later launches |
| P | recommended, amended: explicit consent; detect the user's actual shell |
| A | recommended: auto-start only already-compatible services |
| N | recommended: new root `lockstep`; frozen scripts preserved |
| H | alternative: minimal first-party JavaScript in P3.1; pinned HTMX later |

---

# DR-P3.1 — Approved Design Decisions

The human owner has approved the P3.1 bootstrap architecture, incorporating the Planner's amendments.

This decision supersedes the unresolved choices in `docs/gates/P3.1/design-request.md`.

## 1. Browser authentication

Use the proposed one-time sign-in token and per-origin, header-based session authentication.

- Generate a cryptographically secure, single-use sign-in token.
- Deliver it through a URL fragment and remove it from browser history after exchange.
- Store only credential digests on the server.
- Use an origin-scoped browser session credential, not a cookie.
- Require the session header on protected requests.
- Preserve strict Host, Origin, CSP, and cross-origin protections.
- Enforce session expiration, revocation, and replay resistance.
- Test XSS, CSRF, cross-origin requests, and credential exposure.

Implement this authentication mechanism for the bootstrap control pane in P3.1.

**Do not migrate the main application to it yet.** That belongs to P3.4.

## 2. Existing authentication

Preserve the existing Phase 1/2 cookie-based operator pages and frozen tests temporarily.

Do not use their authentication mechanism for new bootstrap management operations.

Plan their retirement during P3.4 through separately authorized frozen-test amendments.

## 3. Bootstrap architecture

Implement:

- A containerized local control pane without Docker socket access.
- A narrowly privileged host-side helper running as the invoking OS user.
- A private, authenticated communication channel between them.
- A fixed, versioned allowlist of permitted lifecycle operations.
- Request validation, replay protection, serialized execution, bounded timeouts, and durable operation results.

The control pane must not have unrestricted application database credentials, arbitrary host filesystem access, or a general-purpose command-execution interface.

The helper is a narrowly scoped exception to the previous no-new-daemon preference. It is not a general privileged service.

## 4. First launch

If the bootstrap application has not been built, perform the required one-time build and display understandable progress in the terminal.

Open the browser automatically when the control pane is ready.

Subsequent launches must not rebuild unnecessarily.

## 5. PATH installation

Offer to make `lockstep` available as a normal command.

Require explicit permission before modifying shell configuration. Detect the user's actual shell and provide clear instructions when automatic PATH configuration is unsuitable.

## 6. Automatic startup

When the already-installed application and database schema are compatible, start the necessary services automatically.

Do not automatically install, upgrade, migrate, or restore data. Those operations require an explicit user decision through the control pane.

## 7. Launcher

Create a new `lockstep` launcher at the repository root.

Preserve the existing frozen scripts. Continue supporting advanced CLI operations.

The normal `lockstep` invocation opens the control pane. `lockstep stop` shuts down its managed local processes safely.

## 8. Frontend

Use minimal first-party JavaScript for P3.1.

Do not introduce HTMX merely to implement bootstrap authentication and lifecycle controls. Integrate pinned HTMX when the main application UI requires it.

## 9. Implementation authorization

Proceed with C-P3.1, test freezing, implementation, and qualification.

Preserve the existing operator installation and database during testing.

Do not request another design decision unless a concrete safety, authority, or frozen-artifact conflict arises.

**Priority: deliver a secure, working local control pane without expanding P3.1 into later Phase 3 functionality.**
