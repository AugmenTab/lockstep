#!/bin/bash
# Phase 5 update 2 §2: what the capsule can actually reach at the Mac's LAN address. Read-only: TCP
# connects, HTTP GETs of public status pages, the MariaDB greeting; no login, no session.
lan=192.168.1.197
for p in 4444 5000 7000 7900 8300 8310 8320 8780 8781 9300 5984 6984 62417; do
  if timeout 3 bash -c "exec 3<>/dev/tcp/$lan/$p" 2>/dev/null; then echo "tcp $p reachable"; else echo "tcp $p closed"; fi
done
code() { curl -sk -o /dev/null -m 5 -w '%{http_code}' "$1"; }
echo "http 8300 / -> $(code http://$lan:8300/)"
echo "http 8300 /interface/login/login.php -> $(code http://$lan:8300/interface/login/login.php)"
echo "http 8310 / -> $(code http://$lan:8310/)"
curl -s -m 5 http://$lan:8310/ | grep -o -m 1 'name="pma_username"' | sed 's/^/http 8310 login form: /'
echo "http 5984 / -> $(code http://$lan:5984/)"
echo "http 5984 /_all_dbs (no credentials) -> $(code http://$lan:5984/_all_dbs)"
echo "http 4444 /status (no credentials) -> $(code http://$lan:4444/status)"
curl -s -m 5 http://$lan:4444/status | grep -o -m 1 '"ready": *[a-z]*' | sed 's/^/selenium /'
echo "http 7900 / -> $(code http://$lan:7900/)"
echo "http 8780 / -> $(code http://$lan:8780/)"
echo "http 8781 / -> $(code http://$lan:8781/)"
echo "https 9300 / -> $(code https://$lan:9300/)"
echo "https 6984 / -> $(code https://$lan:6984/)"
echo "http 7000 / -> $(code http://$lan:7000/)"
echo "http 5000 / -> $(code http://$lan:5000/)"
# MariaDB: the server's greeting only (protocol version byte and version string), then close.
timeout 3 bash -c "exec 3<>/dev/tcp/$lan/8320; head -c 40 <&3" 2>/dev/null | tr -c '[:print:]' '.' | sed 's/^/mariadb greeting: /'
echo
# UDP: an mDNS service-enumeration query and a NetBIOS name-status query, unicast to the Mac.
python3 - "$lan" <<'EOF'
import socket, sys
lan = sys.argv[1]
def ask(port, payload, name):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM); s.settimeout(3)
    try:
        s.sendto(payload, (lan, port)); data, _ = s.recvfrom(4096)
        print("udp %d %s: answered (%d bytes)" % (port, name, len(data)))
    except Exception as e:
        print("udp %d %s: no answer (%s)" % (port, name, type(e).__name__))
q = b"\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00" + b"".join(bytes([len(l)]) + l.encode() for l in ["_services", "_dns-sd", "_udp", "local"]) + b"\x00\x00\x0c\x00\x01"
ask(5353, q, "mdns")
nb = b"\x12\x34\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x20" + b"CKAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA" + b"\x00\x00\x21\x00\x01"
ask(137, nb, "netbios")
EOF
