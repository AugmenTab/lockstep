# C-P3.5 host probe — path-preserving mounts on this Mac's Docker (manual)

- Date: 2026-10-26. Docker runtime: OrbStack (Docker Engine 29.4), image `lockstep-dev:p1`.
- Why: every automated C-P3.5 test runs the service in the test container's own filesystem view
  and replaces `docker` with a stub that records arguments. This probe checks, with the real
  runtime, the two facts J5 relies on: a folder mounted at its own path is seen by Git in the
  container exactly as on the host, and a folder made through a read-write mount by the host
  user's id belongs to the host user.
- Scope: a throwaway folder `.local/p35-probe` inside the checkout. Nothing of the operator's
  installation, home folder, service, pane or database was touched.

| Step | Command (abridged) | Result |
|---|---|---|
| 1 | `git init -q -b main .local/p35-probe/site` on the host | made |
| 2 | `docker run --rm --user 501:20 --volume P:P:ro … git -C P rev-parse --path-format=absolute --show-toplevel --git-common-dir --is-bare-repository` | `P`, `P/.git`, `false`: the same paths as on the host, no ownership refusal |
| 3 | the same as the container's default user (root) | `P`: also accepted on this runtime |
| 4 | `docker run --rm --user 501:20 --volume .local/p35-probe:…:rw … git init -q -b main …/made-in-container` | made |
| 5 | `ls -ln .local/p35-probe` on the host | `made-in-container` and `site` both owned by `501 20` |

Not run here: the full service registration through `scripts/service` with a real folder list
(the qualification instance's install and database are not set up for P3.5); the owner's
`./lockstep` with the real default browser (owner-only, as before).
