# Amendments — C-P6.10b

| # | Contract text | Amended to | Why |
|---|---|---|---|
| AM-P6.10b-1 (§4) | "`scripts/lib/check-host-boundary`, run by `scripts/lib/check-step capsule`." | Run by `scripts/lib/check-step lint` (step 2 of `scripts/check`, "lint and static checks", `--network none`). | `scripts/check` never runs the `capsule` step (it is the Phase 5 manual step for the capsule test suite), so the frozen check would not be part of the full check. The check file is unchanged (digest as frozen). |
