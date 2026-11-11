# LAN exposure: inventory, the scoped exception for Brigid, and the residual risk (Phase 5 update 2)

- **Date:** 2026-11-11. **Host:** this Mac, LAN address 192.168.1.197 (it was 10.10.1.203 in update 1: a
  different network). **Source:** `netstat -anv` (every socket, every owner), `docker ps`/`inspect`
  (secret values never printed, only compared with known defaults), and a probe run from inside a capsule.
  Evidence: `evidence/update2-lan/`.
- **D4 (host loopback) stays closed:** `networkOpts.hostLoopback: false`, enforced (update 1). This document
  is only about services bound to the Mac's other addresses, which a guest reaches the way any LAN device does.
- **No general host-LAN isolation is implemented or claimed.** A durable boundary enforced on the host
  (a packet filter between the capsule NAT and the Mac's own addresses) is **deferred work**. It is required
  before unrestricted, unattended or multi-project use of capsules.

## 1. Inventory and classification

"Reachable" was measured from inside the capsule `vmq1` (`evidence/update2-lan/guest-reachability.txt`):
TCP connects, HTTP GETs of public pages, MariaDB's greeting, one mDNS and one NetBIOS query. Nothing logged
in, and nothing created a session.

### TCP listeners

| Port | Bind | Owner | Reachable | Sensitive | Authentication | Decision |
|---|---|---|---|---|---|---|
| 8320 | * | `development-easy` MariaDB 11.8 (OpenEMR dev stack) | yes (greeting) | **a database** | root password is the **public default** | **material: not accepted.** Stopped by the owner (see §2) |
| 8310 | * | same stack, phpMyAdmin 5.2 | yes (login form) | **DB administration** | login, but the DB root default works | **material: not accepted** (stopped) |
| 5984, 6984 | * | same stack, CouchDB 3.5 | yes (`/_all_dbs` → 401) | **DB admin API** | admin password is the **public default** | **material: not accepted** (stopped) |
| 8300, 9300 | * | same stack, OpenEMR (EHR) | yes (login page) | **an EHR application** | admin password is the **public default** | **material: not accepted** (stopped) |
| 4444 | * | same stack, Selenium standalone Chromium | yes (`/status` ready) | **remote control of a browser** inside that stack's network | **none** (WebDriver) | **material: not accepted** (stopped) |
| 7900 | * | same stack, Selenium noVNC | yes | a view of that browser | VNC password (not the default) | not accepted with its stack (stopped) |
| 8780, 8781 | * | polygon-pong web (nginx) and server: the owner's development app | yes (200, 404) | no data | none | accepted for the attended run |
| 5000, 7000 | * | macOS Control Center (AirPlay receiver) | yes (403) | no | AirPlay pairing | accepted |
| dynamic (62417) | * | macOS `rapportd` (Continuity) | yes | no | Apple-ID device pairing | accepted (port changes) |

### UDP sockets

Excluded by construction:
- **Connected UDP sockets** (a foreign address; the browser's QUIC flows, Lima's NTP): the kernel delivers
  only from their one peer.
- **Sockets with no port** (`*.*`).
- **Loopback.**

| Port | Owner | Reachable | Decision |
|---|---|---|---|
| 5353 | `mDNSResponder`, the browser (Bonjour) | **answered** a service query (124 bytes): the Mac's advertised service names, as any LAN device sees them | accepted |
| 137, 138 | `netbiosd` | no answer | accepted |
| 547 | `dhcp6d` (client) | not probed (client) | accepted |
| dynamic | `sharingd` (AirDrop), `replicatord`, `syslogd` | not probed; Apple-authenticated or send-only | accepted (ports change) |
| dynamic, on * and on specific addresses | the browser (WebRTC/QUIC sockets) | not probed; ICE needs per-session credentials | accepted (ports change) |

## 2. Owner decision taken (2026-11-11)

The `development-easy` stack (six containers: MariaDB, phpMyAdmin, CouchDB, OpenEMR, Selenium, OpenLDAP) was
the one material exposure: public default credentials on a database, its admin tool, a database admin API
and an EHR, and an unauthenticated WebDriver. The Implementer could not accept it and did not touch it. Asked,
the owner chose to **stop it**. The Implementer ran `docker stop` on the six containers. Their data is kept,
and `docker start` brings them back. Its ports are **not** in the exception, so if it starts again,
preflight refuses.

## 3. The exception policy (`scripts/capsule/lan-exposure`, read by `scripts/capsule-preflight`)

The previous `--allow-lan PORTS` flags were global, port-only and permanent. They are **removed**. The only
allowance is the owner's file `DIR/capsule/lan-exception` in the helper state that runs the project. A file
that is not a regular file of mode 0600 is ignored, and nothing is accepted.

- **Scoped.** It names the capsule config's `project`, `lockstep-project`, `capsule` and `verify-capsule`.
  All four must match, so another project, or the same file under another identity, is refused
  (`exception-wrong-…`) and accepts nothing.
- **Expiring.** `expires` must be in the future and at most **72 hours** ahead. Past it, the exception is
  refused and the normal refusal returns.
- **Exact listeners.** Each `allow` names a protocol (TCP and UDP are separate), a bind (`*` or `address`), a
  port (a number, or `dynamic` for 49152–65535 only) and the owning process. A listener nothing names is
  refused, including one that starts after the review.
- **Policy, not text.** An unknown or malformed line refuses the whole exception.
- **Narrow.** It changes only `host-network-exposure`. Every other preflight check still fails on its own.
- **Recorded.** Preflight prints a `NOTE lan-exception accepts …` line for every listener it accepts.

The exception for Brigid, as installed for the run: `evidence/update2-lan/brigid-lan-exception.txt`
(project `brigid`, capsules `brigid1`/`brigidv`, expires 2026-11-13T23:00Z).

## 4. Residual risk accepted for the attended experiment

During the run a capsule's code can:
- reach polygon-pong (a development app with no data);
- reach macOS's AirPlay and Continuity endpoints (which require pairing);
- see the Mac's Bonjour service list;
- send to the dynamic UDP sockets above.

None of these holds Lockstep's state or a credential. Preflight is a check at the start, not a packet
filter: a service that starts listening after the preflight is not blocked for that run. The owner attends
the run.
