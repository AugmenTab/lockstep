# Gate A — browser-form regression: report, Planner decision, amendment request

- Prepared by: the writing agent (Implementer), 2026-10-18.
- State: `v2` at `ba3dbde`, clean. Gate A report r1 (`docs/gates/A/gate-report.md`,
  sha256 `efee1118…`) is superseded as evidence of the failed human demonstration; it stays in
  place unchanged. Nothing has been changed in code. The demonstration service is stopped.

## 1. Failure (owner's human-operated A1 demonstration, step 4)

Submitting the rename form on `/operator` in the owner's browser (service `de8afa3`,
`127.0.0.1:8010`) returned the request guard's Origin refusal:

> Request refused. This request did not come from a page of this service.

**Root cause.**
- Every operator page except the sign-in confirm page sent `Referrer-Policy: no-referrer`
  (C-P1.3 E8; kept by D-2d).
- Browsers serialize the `Origin` of a form POST from such a page as `null`
  (`docs/gates/P1.3/evidence/origin-probe.log`).
- The guard requires the exact Origin, with no exception.

So no form on the operator pages could be submitted from a real browser: rename, queue job and
sign-out. Every automated check sent POSTs with curl or http-client and an explicit `Origin`. The
UI-form claims in the P1.4–P1.6 records and r1's AC-A1-07 were therefore verified only with
browser-shaped requests.

## 2. Planner decision (verbatim, 2026-10-18)

> ## Planner decision — Gate A browser-form regression
>
> Review the Project Bible, current Phase 1 authority, and the failed human A1 demonstration report before proceeding.
>
> **Decision: Approve Option A.**
>
> Amend D-2d / C-P1.3 E8 to use `Referrer-Policy: origin` on operator HTML pages containing forms or initiating state-changing browser requests.
>
> Retain the strict exact-Origin guard. Do not introduce an `Origin: null` exception.
>
> The existing `Referrer-Policy: origin` treatment of the sign-in confirmation page remains unchanged.
>
> ### Authorized recovery
>
> 1. Create a narrowly scoped remediation Contract covering the header correction, browser integration coverage, qualification updates, and evidence corrections. Preserve previously frozen tests unless a separately authorized amendment is unavoidable.
> 2. Audit all operator pages and interactions that can initiate a mutating browser request. Ensure the policy consistently supports legitimate same-origin submissions without leaking sensitive URL components.
> 3. Add real-browser regression coverage using headless Chromium. Submit the actual served rename, queue-job, and sign-out forms. Verify responses, durable state changes, and relevant security headers. Do not substitute curl or manually constructed HTTP requests for these tests. Include negative Origin/CSRF checks so the correction cannot silently weaken the guard.
> 4. Correct the overstated browser-interaction claims in the P1.4–P1.6 records and Gate A report. Preserve r1 as superseded evidence of the failed human demonstration; issue r2 against a newly tested commit.
> 5. Correct the A1 demonstration procedure: browser Back navigation may generate a fresh idempotency key. Demonstrate replay using an explicitly reused key and identical command payload.
> 6. Run the complete qualification suite from the required clean environments, including the actual browser regression tests, and produce a new Gate A evidence packet.
> 7. Return control for a new human-operated demonstration and Gate A decision. Do not record human acceptance yourself.
>
> Continue as the Implementer under the existing role boundaries. Do not assume Planner or human approval authority. Do not begin Phase 2.
>
> Keep the consolidated Phase 1 retrospective updated with the original failure, root cause, remediation, and verification results.

## 3. Audit (recovery step 2)

| Page | Forms / state-changing requests | Policy under Option A |
|---|---|---|
| `GET /operator/sign-in?token=…` (confirm) | sign-in form | `origin` (unchanged, D-2d) |
| `GET /operator` | rename form, Sign out form | **`origin`** (was `no-referrer`) |
| `GET /operator/jobs/new` | queue form | **`origin`** (was `no-referrer`) |
| `GET /operator/receipts/<id>` | none (links only) | `no-referrer` (unchanged) |
| `GET /operator/center` | none (links only) | `no-referrer` (unchanged) |
| Refusal pages (400/401/403/404/409/413/503) | none | `no-referrer` (unchanged) |
| 303 redirects (sign-in, rename, queue, sign-out) | none | `no-referrer` (unchanged) |
| `GET /`, `/api/*`, `/static/*` | none | no policy header (unchanged) |

Under `origin`, the two pages send the exact `Origin` on their POSTs and only the bare origin as
`Referer` (measured for D-2d). Their URLs carry no secrets in any case (`/operator`,
`/operator/jobs/new`). The token appears only in the confirm page's URL, which already uses
`origin`.

## 4. Amendment requested (recovery step 1: "separately authorized … unavoidable")

**Exactly one frozen assertion conflicts with Option A:**
`test/integration/Lockstep/OperatorTrustTest.hs:114` (C-P1.3 §8, sha256 `bd708e56…`) requires the
signed-in `/operator` page to send `Referrer-Policy: no-referrer`. The page must carry the rename
and Sign out forms, because the frozen P1.3 and P1.4 tests require them there, so the conflict
cannot be designed around with headers. The other four `no-referrer` assertions
(`OperatorRoutesTest` lines 34, 38, 108, 117) are on refusal pages and stay valid.

**Proposed amendment R-P1.3-1:** exactly `proposed-test-amendment.diff`
(sha256 `33114dc0…`; one line: `Just "no-referrer"` → `Just "origin"` for the `/operator`
page). Then re-freeze with a new digest recorded in C-P1.3 §9.

**Alternative that avoids the amendment (not recommended):** keep the `/operator` header as
`no-referrer` and add `<meta name="referrer" content="origin">` to the page. Browsers apply the
meta policy to the document, so forms would work. But the HTTP header would then contradict the
effective policy, and the frozen assertion would pass while describing something untrue.

## 5. What happens after authorization

These steps are within the Planner decision; none starts until R-P1.3-1 (or the alternative) is
authorized:

1. Remediation Contract C-P1.7-R1.
2. Headers per §3.
3. Headless-Chromium form tests:
   - a real browser signs in, then submits the served rename, queue and sign-out forms;
   - durable state and headers are verified;
   - negative cases: a cross-origin page on another port submitting to the service, and a
     tampered CSRF field, are both refused and store nothing.
   This requires Chromium in the dev image (a named `Dockerfile` change).
4. Record corrections in P1.4–P1.6.
5. Corrected demonstration procedure.
6. Full qualification from clean environments; A1 extended with the browser tests.
7. Gate A report r2 at the new tested commit.
8. Hand back for a new human demonstration.

## 6. Answer needed

For example: "R-P1.3-1 approved." Or choose the meta-tag alternative.
