# Superseded A1 runs for report r2

| Run | Commit | Result | Why superseded |
|---|---|---|---|
| run1-20261018T192429Z | `f1b6e1c` | 11 checks failed | `scripts/a1` ran the browser driver with `docker run` but without `-i`, so the driver received an empty step list (JSON decode error, A1-06). A1-06c, A1-07, A1-08 and A1-11 to A1-12b then failed because they expect the browser's rename to have advanced the revision. Product behaviour was not involved: the fresh-clone suite in the same run, which includes the real-browser test, passed (259 unit, 67 integration). Fixed in the next commit (`-i`). |
