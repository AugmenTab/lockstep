for t in 192.168.5.2:18765 host.lima.internal:18765 192.168.1.197:18765 192.168.5.2:18766 192.168.1.197:18766; do
  h=${t%:*}; p=${t#*:}
  if timeout 4 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null; then echo "tcp $t open"; else echo "tcp $t closed"; fi
done
getent hosts archive.ubuntu.com > /dev/null && echo dns-ok
curl -s -m 20 -o /dev/null -w "https=%{http_code}\n" https://registry-1.docker.io/v2/
docker pull -q busybox:1.36 > /dev/null 2>&1 && docker run --rm busybox:1.36 echo docker-run-ok
cd /tmp && sudo apt-get update -qq > /dev/null 2>&1 && apt-get download -qq hello > /dev/null 2>&1 && ls hello_*.deb > /dev/null 2>&1 && echo apt-download-ok
rm -f /tmp/hello_*.deb
