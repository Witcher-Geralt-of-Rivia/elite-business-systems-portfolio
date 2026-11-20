#!/usr/bin/env bash
# One systemd unit per ERPNext process in the guest (replaces `bench start`/honcho, which stops EVERY process when
# any one exits - measured: a worker's clean exit after a long guest pause took Redis down under running tests).
# Each unit restarts on its own. Web = gunicorn (as in production benches), loopback port 8000 (forwarded to the
# host's loopback only). Usage: systemd-units.sh install | status
set -euo pipefail
BENCH=/home/erp/frappe-bench; U=/etc/systemd/system
unit() { # name description exec [extra]
  sudo tee "$U/erpnext-$1.service" >/dev/null <<EOF
[Unit]
Description=ERPNext $2 (QEMU PoC)
After=network-online.target mariadb.service ${4:-}
Wants=network-online.target
PartOf=erpnext.target

[Service]
User=erp
WorkingDirectory=$BENCH/${5:-}
Environment=PATH=/home/erp/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=$3
Restart=always
RestartSec=10
TimeoutStopSec=60

[Install]
WantedBy=erpnext.target
EOF
}
case "${1:-}" in
  install)
    sudo tee "$U/erpnext.target" >/dev/null <<'EOF'
[Unit]
Description=ERPNext (all processes, QEMU PoC)
Wants=erpnext-redis-cache.service erpnext-redis-queue.service erpnext-web.service erpnext-worker.service erpnext-schedule.service

[Install]
WantedBy=multi-user.target
EOF
    unit redis-cache "Redis cache" "/usr/bin/redis-server $BENCH/config/redis_cache.conf" "" "config"
    unit redis-queue "Redis queue" "/usr/bin/redis-server $BENCH/config/redis_queue.conf" "" "config"
    unit web "web (gunicorn)" "$BENCH/env/bin/gunicorn --chdir $BENCH/sites --bind 127.0.0.1:8000 --workers 2 --threads 2 --timeout 300 --graceful-timeout 30 --max-requests 2000 --max-requests-jitter 200 frappe.app:application --preload" "erpnext-redis-cache.service erpnext-redis-queue.service" "sites"
    unit worker "background worker" "/home/erp/.local/bin/bench worker" "erpnext-redis-queue.service"
    unit schedule "scheduler" "/home/erp/.local/bin/bench schedule" "erpnext-redis-queue.service"
    sudo systemctl disable --now erpnext-bench.service 2>/dev/null || true
    sudo systemctl daemon-reload
    sudo systemctl enable erpnext.target erpnext-redis-cache erpnext-redis-queue erpnext-web erpnext-worker erpnext-schedule
    sudo systemctl start erpnext.target
    ;;
  status)
    systemctl --no-pager --plain list-units 'erpnext*' ;;
  *) echo "usage: $0 install | status"; exit 2 ;;
esac
