cd /work/repo
f() { local x; for x in "$@"; do printf '<%s>' "$x"; done; echo; }
f "a b" c | tr '<' '[' > out.txt && cat out.txt
( cd /tmp && pwd ) ; { echo grouped; } 2>&1 | sed 's/grouped/grouped-ok/'
python3 -c 'print("py-ok")'
sudo apt-get install -y --no-install-recommends tree >/dev/null 2>&1 && tree --version | head -n 1
