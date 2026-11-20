#!/usr/bin/env bash
# Stage D: Frappe v16.60.0 + ERPNext v16.60.0 + portfolio_sim in the QEMU-TCG guest, then an isolated test site.
# Same steps as .github/workflows/erp-integration.yml (run 44425817273). Prerequisite: provision-base.sh.
# The portfolio_sim sources are expected in ~/src/portfolio_sim (copied from the repository by the host).
# Guest-local MariaDB admin credentials are generated here and kept only in ~/.erp-db-admin (mode 600).
set -euo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
REF="${REF:-v16.60.0}"; BENCH="$HOME/frappe-bench"; SITE="${SITE:-test_site}"
PY="$(uv python find 3.14)"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
step() { local t0=$(date +%s); log "BEGIN $1"; shift; "$@"; log "END ($(( $(date +%s) - t0 )) s)"; }

if [[ ! -f ~/.erp-db-admin ]]; then
  (umask 077; head -c 24 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | head -c 24 > ~/.erp-db-admin)
fi
DBPW="$(cat ~/.erp-db-admin)"
# bench connects over TCP to 127.0.0.1; with skip-name-resolve that does not match accounts for 'localhost'
# (measured: error 1130), so the admin account exists for both. MariaDB listens on the guest loopback only.
for h in localhost 127.0.0.1; do
  sudo mariadb -e "CREATE USER IF NOT EXISTS 'benchadmin'@'$h' IDENTIFIED BY '$DBPW'; GRANT ALL ON *.* TO 'benchadmin'@'$h' WITH GRANT OPTION;"
done

init_bench() {
  cd "$HOME"
  bench init --skip-assets --frappe-branch "$REF" --python "$PY" frappe-bench
  cd "$BENCH"
  # No asset watcher; no code reloader on the web process: under emulation werkzeug's stat reloader alone used as
  # much CPU as the test runner (measured: 23 CPU-minutes each in the first hour).
  sed -i 's/^watch:/# watch:/; s/^web: bench serve  *--port \([0-9]*\)$/web: bench serve --port \1 --noreload/' Procfile
  git -C apps/frappe describe --tags
}
get_apps() {
  cd "$BENCH"
  bench get-app --skip-assets --branch "$REF" erpnext https://github.com/frappe/erpnext
  git -C apps/erpnext describe --tags
  rm -rf /tmp/portfolio_sim && cp -r "$HOME/src/portfolio_sim" /tmp/portfolio_sim
  git -C /tmp/portfolio_sim init -q && git -C /tmp/portfolio_sim add -A
  git -C /tmp/portfolio_sim -c user.name=poc -c user.email=poc@example.org commit -qm "portfolio_sim (QEMU PoC)"
  bench get-app --skip-assets /tmp/portfolio_sim
  bench pip install unittest-xml-reporting
  cat sites/apps.txt
}
new_site() {
  cd "$BENCH"
  bench new-site "$SITE" --db-root-username benchadmin --db-root-password "$DBPW" --admin-password admin \
    --mariadb-user-host-login-scope='%' --install-app erpnext
  bench --site "$SITE" install-app portfolio_sim
  bench --site "$SITE" set-config allow_tests true
  bench --site "$SITE" list-apps
}

# Under software emulation yarn's default 30 s network timeout is too short (measured: ESOCKETTIMEDOUT on
# ace-builds during the first bench init); fewer parallel downloads keep the single emulated vCPU responsive.
yarn config set network-timeout 600000 >/dev/null
yarn config set network-concurrency 4 >/dev/null
# A bench init that failed part-way (e.g. in yarn install) leaves apps/frappe without node_modules: start over.
if [[ -d "$BENCH" && ! -f "$BENCH/apps/frappe/node_modules/.yarn-integrity" ]]; then log "removing incomplete bench"; rm -rf "$BENCH"; fi
[[ -d "$BENCH/apps/frappe" ]] || step "bench init $REF" init_bench
[[ -d "$BENCH/apps/portfolio_sim" ]] || step "get-app erpnext $REF + portfolio_sim" get_apps
# A site whose creation failed part-way (no portfolio_sim installed) is removed with its database first.
if [[ -d "$BENCH/sites/$SITE" ]] && ! (cd "$BENCH" && bench --site "$SITE" list-apps 2>/dev/null | grep -q portfolio_sim); then
  db=$(jq -r .db_name "$BENCH/sites/$SITE/site_config.json" 2>/dev/null || true)
  log "removing incomplete site $SITE (db ${db:-none})"
  [[ -n "$db" && "$db" != null ]] && sudo mariadb -e "DROP DATABASE IF EXISTS \`$db\`; DROP USER IF EXISTS '$db'@'%', '$db'@'localhost';"
  rm -rf "$BENCH/sites/$SITE"
fi
if [[ ! -d "$BENCH/sites/$SITE" ]]; then
  # new-site needs the bench Redis instances (cache, queue).
  pgrep -f "redis-server.*$BENCH" >/dev/null || (cd "$BENCH" && nohup bench start > "$BENCH/bench_start.log" 2>&1 &)
  ports=$(jq -r '.redis_cache, .redis_queue' "$BENCH/sites/common_site_config.json" | sed 's/.*://')
  for p in $ports; do
    for i in $(seq 180); do redis-cli -p "$p" ping >/dev/null 2>&1 && break; sleep 1; done
    redis-cli -p "$p" ping >/dev/null || { log "redis on $p did not start"; tail -50 "$BENCH/bench_start.log"; exit 1; }
  done
  step "new-site $SITE (erpnext, portfolio_sim)" new_site
fi
log "installed: $(cd "$BENCH" && bench version 2>/dev/null | tr '\n' ' ')"
du -sh "$BENCH" /var/lib/mysql 2>/dev/null || sudo du -sh /var/lib/mysql
