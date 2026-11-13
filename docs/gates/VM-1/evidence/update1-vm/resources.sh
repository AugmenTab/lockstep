echo "cpus=$(nproc) mem-kib=$(awk '/MemTotal/ {print $2}' /proc/meminfo)"
df -h /work | tail -n 1
docker system df
