avail=$(df --output=avail -B1 /work | tail -n 1)
fallocate -l "$avail" /work/fill 2>&1 || dd if=/dev/zero of=/work/fill bs=1M 2>/dev/null
echo data > /work/after-full.txt 2>&1 || echo write-refused-enospc
rm -f /work/fill /work/after-full.txt
echo ok > /work/after-free.txt && echo write-ok-after-free
docker info >/dev/null 2>&1 && echo docker-ok-after-free
sudo fstrim -v /work 2>&1 || sudo fstrim -v / 2>&1
