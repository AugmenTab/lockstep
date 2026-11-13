echo "hostname=$(hostname)"
echo "mounts=[$(findmnt -rn -t virtiofs,9p,fuse.sshfs,nfs,cifs -o TARGET | tr "\n" " ")]"
ls /Users >/dev/null 2>&1 && echo users-dir=present || echo users-dir=absent
echo "ssh-agent=[${SSH_AUTH_SOCK:-}]"
echo "docker-name=$(docker info --format '{{.Name}}' 2>&1)"
for target in host.lima.internal:18765 192.168.5.2:18765 host.lima.internal:18766 192.168.5.2:18766 192.168.5.2:2375 192.168.5.2:5432 192.168.5.2:8000 192.168.5.2:22 192.168.5.2:5000 192.168.5.2:7000 192.168.5.2:5984 192.168.5.2:4444  10.10.1.203:18765 10.10.1.203:18766 10.10.1.203:5000 10.10.1.203:7000 10.10.1.203:4444 10.10.1.203:5984 10.10.1.203:6984 10.10.1.203:7900 10.10.1.203:8300 10.10.1.203:8310 10.10.1.203:8320 10.10.1.203:8780 10.10.1.203:8781 10.10.1.203:9300 10.10.1.203:50966 10.10.1.203:22 10.10.1.203:5432 10.10.1.203:8000; do
  h=${target%:*}; p=${target#*:}
  if timeout 4 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null; then echo "tcp $target open"; else echo "tcp $target closed"; fi
done
getent hosts archive.ubuntu.com >/dev/null && echo dns-ok
curl -s -m 20 -o /dev/null -w "https=%{http_code}\n" https://registry-1.docker.io/v2/
echo isolation-done
