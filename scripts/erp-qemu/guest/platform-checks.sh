#!/usr/bin/env bash
# Stage C: Linux platform checks inside the QEMU-TCG guest, before ERPNext. Each check prints PASS/FAIL and a
# measurement; exit status is the number of failures. Needs: Python 3.14 (uv), redis-server binary, MariaDB.
set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
PY="$(uv python find 3.14 2>/dev/null || echo python3)"
fail=0
check() { local name="$1"; shift; local t0=$(date +%s.%N); local out; out="$("$@" 2>&1)"; local rc=$?
  local dt=$(awk -v a="$t0" -v b="$(date +%s.%N)" 'BEGIN{print b-a}'); printf '%-4s %-28s %6.2fs  %s\n' "$([[ $rc == 0 ]] && echo PASS || echo FAIL)" "$name" "$dt" "$(echo "$out" | tail -1)"
  [[ $rc == 0 ]] || fail=$((fail + 1)); }

check "kernel/arch"        bash -c 'uname -srm; nproc; grep -m1 "model name" /proc/cpuinfo'
check "network (https)"    bash -c 'curl -fsS -o /dev/null -w "%{http_code} %{time_total}s" https://pypi.org/simple/frappe-bench/'
check "python 3.14"        "$PY" -c 'import sys; assert sys.version_info[:2] == (3, 14), sys.version; print(sys.version.split()[0])'
check "fork x200"          "$PY" -c '
import os, time
t = time.time()
for _ in range(200):
    pid = os.fork()
    if pid == 0: os._exit(7)
    assert os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]) == 7
print(f"{200 / (time.time() - t):.0f} forks/s")'
check "subprocess x50"     "$PY" -c '
import subprocess, time
t = time.time()
for _ in range(50): subprocess.run(["true"], check=True)
print(f"{50 / (time.time() - t):.0f} spawns/s")'
check "fcntl/flock locks"  "$PY" -c '
import fcntl, os, tempfile
p = tempfile.mktemp(); a = open(p, "w"); b = open(p, "w")
fcntl.flock(a, fcntl.LOCK_EX)
try: fcntl.flock(b, fcntl.LOCK_EX | fcntl.LOCK_NB); raise SystemExit("second lock granted")
except BlockingIOError: pass
fcntl.flock(a, fcntl.LOCK_UN); fcntl.flock(b, fcntl.LOCK_EX | fcntl.LOCK_NB)
fcntl.lockf(b, fcntl.LOCK_UN); os.unlink(p); print("exclusive lock enforced")'
check "unix sockets"       "$PY" -c '
import os, socket, tempfile, threading
p = tempfile.mktemp(); s = socket.socket(socket.AF_UNIX); s.bind(p); s.listen()
def serve():
    c, _ = s.accept(); c.sendall(c.recv(64).upper()); c.close()
threading.Thread(target=serve).start()
c = socket.socket(socket.AF_UNIX); c.connect(p); c.sendall(b"ping"); r = c.recv(64); os.unlink(p)
assert r == b"PING", r; print("echo ok")'
check "multiprocessing"    "$PY" -c '
import multiprocessing as mp, time
t = time.time()
with mp.get_context("fork").Pool(2) as p: r = p.starmap(pow, zip(range(1000), [2] * 1000))
assert r[999] == 998001; print(f"pool map {time.time() - t:.2f}s")'
check "redis server"       bash -c '
d=$(mktemp -d); redis-server --port 16379 --bind 127.0.0.1 --save "" --appendonly no --dir "$d" --daemonize yes >/dev/null
for i in $(seq 50); do redis-cli -p 16379 ping 2>/dev/null | grep -q PONG && break; sleep 0.2; done
redis-cli -p 16379 set k v >/dev/null; v=$(redis-cli -p 16379 get k); ops=$(redis-benchmark -p 16379 -q -n 5000 -t set,get 2>/dev/null | tr "\r" "\n" | grep -E "^(SET|GET)" | tr "\n" " ")
redis-cli -p 16379 shutdown nosave >/dev/null 2>&1; rm -rf "$d"; [[ $v == v ]] && echo "get/set ok; $ops"'
check "background worker"  "$PY" -c '
import os, signal, time, subprocess, sys, tempfile
f = tempfile.mktemp()
w = subprocess.Popen([sys.executable, "-c", f"import time\nwhile True:\n open({f!r},\"a\").write(\"x\"); time.sleep(0.2)"])
time.sleep(2); n1 = os.path.getsize(f); time.sleep(1); n2 = os.path.getsize(f)
w.send_signal(signal.SIGTERM); w.wait(5); os.unlink(f)
assert n2 > n1 > 0, (n1, n2); print(f"worker ticked {n2}x, SIGTERM rc={w.returncode}")'
check "mariadb"            bash -c 'sudo mariadb -N -e "select version(), @@character_set_server, @@innodb_buffer_pool_size/1048576"'
check "fsync x100"         "$PY" -c '
import os, time, tempfile
fd, p = tempfile.mkstemp(); t = time.time()
for _ in range(100): os.write(fd, b"x" * 4096); os.fsync(fd)
os.close(fd); os.unlink(p); print(f"{100 / (time.time() - t):.0f} fsync/s")'
check "cpu (python loop)"  "$PY" -c '
import time
t = time.time(); s = 0
for i in range(3_000_000): s += i * i
print(f"3M iterations in {time.time() - t:.2f}s")'
check "memory"             bash -c 'free -m | awk "/Mem:/{print \"total \" \$2 \" MB, available \" \$7 \" MB\"}"'
check "disk"               bash -c 'df -h / | awk "NR==2{print \$2\" size, \"\$3\" used, \"\$4\" free\"}"'
check "boot time"          bash -c 'systemd-analyze 2>/dev/null | head -1'
echo "failures: $fail"
exit $fail
