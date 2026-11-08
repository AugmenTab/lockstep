# Earlier A1 runs (history; superseded by `../a1/`)

| Run | Commit | Result | Why superseded |
|---|---|---|---|
| run1-20261018T175731Z | `1fa38e1` | 13/14 checks; A1-14 FAILED | A1-14's leak counter had a shell bug (`grep -c … \|\| echo 0` produced `0\n0`). The recorded values were all zero. Fixed in `60235ed` together with the review fixes. |
| run2-20261018T181126Z | `60235ed` | 16/17; A1-12b FAILED | **Real defect**: Brigid 0.4's `A.value` does not escape, so a workspace name with `"` broke out of the form's `value` attribute. Fixed in `31d1626`. The check also expected named entities and was corrected. |
| run3-20261018T182158Z | `31d1626` | 17/17 PASSED | The secret scan before committing found that the exchange's `Set-Cookie` line was logged before the script knew the session value, so raw session cookies were in runs 1–3. Fixed in the next commit (generic cookie/token redaction; A1-14 now fails on any raw value). |

**Redaction after the run (recorded here):** in each `a1.log` above, the raw `lockstep_session=…` values were replaced with `<SESSION-REDACTED-AFTER-RUN>` before committing, so those files no longer match their run's `SHA256SUMS` (`a1.log` lines only; every other file still verifies). All operator sessions in the three A1 databases were revoked on 2026-10-18 (10 sessions). The databases (`lockstep_a1_20261018t175731z`, `…181126z`, `…182158z`) are loopback-only and kept for inspection.
