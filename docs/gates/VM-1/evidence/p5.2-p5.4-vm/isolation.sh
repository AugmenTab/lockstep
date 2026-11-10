echo "hostname=$(hostname)"
echo "mounts=[$(findmnt -rn -t virtiofs,9p,fuse.sshfs,nfs,cifs -o TARGET | tr '\n' ' ')]"
ls /Users >/dev/null 2>&1 && echo users-dir=present || echo users-dir=absent
echo "ssh-agent=[${SSH_AUTH_SOCK:-}]"
echo "docker-name=$(docker info --format '{{.Name}}' 2>&1)"
echo "docker-os=$(docker info --format '{{.OperatingSystem}}' 2>&1)"
for target in host.lima.internal:18765 192.168.5.2:18765 192.168.5.2:2375 192.168.5.2:5432 192.168.5.2:8000 192.168.5.2:22; do
  host=${target%:*}
  port=${target#*:}
  if timeout 4 bash -c "exec 3<>/dev/tcp/$host/$port" 2>/dev/null; then echo "tcp $target open"; else echo "tcp $target closed"; fi
done
echo "listening=[$(ss -Hltn | awk '{print $4}' | tr '\n' ' ')]"
echo isolation-done
