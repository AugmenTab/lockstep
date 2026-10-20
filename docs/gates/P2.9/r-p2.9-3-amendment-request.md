# R-P2.9-3 — frozen-criterion amendment request (C-P2.9 AC-B1-03, AC-B1-04)

- Prepared by: the writing agent (Implementer), 2026-10-20.
- Status: **APPROVED as written** by the human owner (`.local/plans/phase-02_update3.md`).
  Applied as C-P2.9 §6.2.
- Evidence: B1 run 2, `docs/gates/B/evidence/b1-run2/`, at `de3ebc5`. 17 of 20 checks passed.

## 1. What needs your authorization

AC-B1-03 says a fresh database "migrates to **revision 11** and reports `readiness ready 11`".
AC-B1-04 says the installed service answers "readiness `ready 11`".

You authorized migration 0012 as part of the remediation (C-P2.9-R1 M8). The schema's
current revision is therefore **12**. Run 2 shows `readiness ready 12`, `revision 12`, and
`pending 0`. The two checks fail only because the criteria name the old revision.

Proposed diff. Nothing else changes:

```diff
-| AC-B1-03@v1 | A fresh database migrates to revision 11 and reports `readiness ready 11`. | yes |
+| AC-B1-03@v1 | A fresh database migrates to revision 12 (migration 0012, C-P2.9-R1 M8) and reports `readiness ready 12`. | yes |
-| AC-B1-04@v1 | The installed service answers health 204 and readiness `ready 11` on `127.0.0.1:8200`. | yes |
+| AC-B1-04@v1 | The installed service answers health 204 and readiness `ready 12` on `127.0.0.1:8200`. | yes |
```

In `scripts/b1`, the two expected strings follow:

```diff
-check AC-B1-03 "a fresh database migrates to revision 11 and reports ready 11" "$(printf '%s' "$LAST_OUT" | grep -q '^readiness ready 11$'; echo $?)"
+check AC-B1-03 "a fresh database migrates to revision 12 and reports ready 12" "$(printf '%s' "$LAST_OUT" | grep -q '^readiness ready 12$'; echo $?)"
-check AC-B1-04 "the installed service answers health 204 and readiness 'ready 11' on 127.0.0.1:$port" "$([ "$health" = 204 ] && [ "$HTTP_STATUS" = 200 ] && [ "$HTTP_BODY" = "ready 11" ]; echo $?)"
+check AC-B1-04 "the installed service answers health 204 and readiness 'ready 12' on 127.0.0.1:$port" "$([ "$health" = 204 ] && [ "$HTTP_STATUS" = 200 ] && [ "$HTTP_BODY" = "ready 12" ]; echo $?)"
```

## 2. Already fixed, without changing the criterion (for your information)

AC-B1-15 also failed in run 2, even though its outcome was exactly right:

```
exit 65: refused claim-held | exit 0: executed 61851620-… applied applied
```

The PostgreSQL destination shows **one** application. The cause is a script defect in the
check expression that R-P2.9-1 approved. It used `case … esac` inside `$( … )`, which this
Mac's bash 3.2.57 rejects as a syntax error ("near unexpected token `;;'"), so the check
evaluated as failed.

I rewrote the same four-outcome condition as an `||` chain. It accepts exactly the same four
outcomes and still requires exactly one execution and one application. `bash -n scripts/b1` is
clean with bash 3.2. The criterion text is unchanged.

The C-P2.9 freeze rule allows a script defect to be fixed when no criterion is weakened. I
record it here so the change to the approved diff is visible.

## Decision requested

Approve R-P2.9-3 as written. If approved, I will:
1. apply it;
2. run B1 from a clean checkout (run 3), keeping runs 1 and 2 as history;
3. record the second independent review, which is running now;
4. write the Gate B report and the decision packet.
