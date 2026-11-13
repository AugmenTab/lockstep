if timeout 4 bash -c "exec 3<>/dev/tcp/192.168.5.2/18765" 2>/dev/null; then echo control-open; else echo control-closed; fi
