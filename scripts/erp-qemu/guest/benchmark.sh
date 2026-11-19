#!/usr/bin/env bash
# Stage F: simulation throughput on a dedicated site (not the test site).
#   benchmark.sh setup                  create site $SITE with ERPNext + portfolio_sim and run portfolio-sim setup
#   benchmark.sh run <until> [max]      backfill up to <until> (ISO date/time), report events/s from the ledger counts
#   benchmark.sh verify                 integrity + replay-check on $SITE
# Throughput = (events_executed after - before) / wall seconds of the backfill command, including bench start-up.
set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
BENCH="$HOME/frappe-bench"; SITE="${SITE:-erp_poc}"; EV="$HOME/poc/evidence"; mkdir -p "$EV"
PY="$(uv python find 3.14)"
cd "$BENCH"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
executed() { bench --site "$SITE" portfolio-sim status 2>/dev/null | "$PY" -c 'import json,sys; t=sys.stdin.read(); print(json.loads(t[t.index("{"):])["events_executed"])'; }

case "${1:-}" in
  setup)
    t0=$(date +%s)
    [[ -d "sites/$SITE" ]] || bench new-site "$SITE" --db-root-username benchadmin --db-root-password "$(cat ~/.erp-db-admin)" \
      --admin-password "${ADMIN_PASSWORD:-admin}" --mariadb-user-host-login-scope='%' --install-app erpnext
    bench --site "$SITE" list-apps | grep -q portfolio_sim || bench --site "$SITE" install-app portfolio_sim
    bench --site "$SITE" portfolio-sim setup | tail -20
    log "setup done in $(( $(date +%s) - t0 )) s"
    ;;
  run)
    until="$2"; max="${3:-}"
    before=$(executed); t0=$(date +%s.%N)
    bench --site "$SITE" portfolio-sim backfill --until "$until" ${max:+--max-events "$max"} > "$EV/backfill-$(date +%s).json" 2>&1; rc=$?
    t1=$(date +%s.%N); after=$(executed)
    "$PY" -c "n=$after-$before; s=$t1-$t0; print(f'backfill until=$until rc=$rc events={n} seconds={s:.0f} events_per_s={n/s:.3f}')" | tee -a "$EV/throughput.log"
    ;;
  verify)
    bench --site "$SITE" portfolio-sim integrity > "$EV/integrity-$SITE.json"; i=$?
    bench --site "$SITE" portfolio-sim replay-check > "$EV/replay-$SITE.json"; r=$?
    bench --site "$SITE" portfolio-sim status | tail -n +1 > "$EV/status-$SITE.json"
    "$PY" - "$EV/integrity-$SITE.json" "$EV/replay-$SITE.json" <<'PY'
import json, sys
def load(p):
    t = open(p).read(); return json.loads(t[t.index("{"):])
i, r = load(sys.argv[1]), load(sys.argv[2])
print("integrity: checks", i["checks"], "failing", i["failing"], "seconds", i.get("seconds"), "counts", i.get("counts"))
print("replay:", {k: r[k] for k in ("missing_count", "unexpected_count", "mismatch_count", "state_matches") if k in r})
PY
    log "verify integrity_exit=$i replay_exit=$r"; [[ $i == 0 && $r == 0 ]]
    ;;
  *) echo "usage: $0 setup | run <until> [max] | verify"; exit 2 ;;
esac
