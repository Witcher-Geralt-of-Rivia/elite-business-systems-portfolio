#!/usr/bin/env bash
# Stage E: the portfolio_sim ERPNext integration tests inside the QEMU-TCG guest - the same commands and guards as
# .github/workflows/erp-integration.yml (run 44425817273): exactly 7 lifecycle tests, none failed/errored/skipped;
# then status, the integrity checks and the replay verifier on the simulated history, plus ledger/GL evidence.
# Bench processes (redis, web, workers, scheduler) must be running (bench start). Output: ~/poc/evidence/.
set -uo pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
BENCH="$HOME/frappe-bench"; SITE="${SITE:-test_site}"; EV="$HOME/poc/evidence"; mkdir -p "$EV"
cd "$BENCH"
log() { printf '%s %s\n' "$(date -u +%FT%TZ)" "$*"; }
rc=0

log "BEGIN run-tests portfolio_sim.tests.test_lifecycle"
start=$(date +%s)
bench --site "$SITE" run-tests --app portfolio_sim --module portfolio_sim.tests.test_lifecycle \
  --skip-before-tests --junit-xml-output "$EV/junit.xml" 2>&1 | tee "$EV/run-tests.log"
log "END run-tests ($(( $(date +%s) - start )) s)"
"$(uv python find 3.14)" - "$EV/junit.xml" <<'PY' || rc=1
import sys, xml.etree.ElementTree as ET
root = ET.parse(sys.argv[1]).getroot()
suites = [root] if root.tag == "testsuite" else list(root.iter("testsuite"))
n = sum(int(s.get("tests", 0)) for s in suites)
bad = sum(int(s.get("failures", 0)) + int(s.get("errors", 0)) + int(s.get("skipped", 0)) for s in suites)
print("junit:", n, "tests; failures/errors/skipped:", bad)
for c in root.iter("testcase"): print(f"  {c.get('name')}: {float(c.get('time', 0)):.1f}s")
sys.exit(0 if n == 7 and bad == 0 else 1)
PY

log "status / integrity / replay"
bench --site "$SITE" portfolio-sim status | tee "$EV/status.json"
bench --site "$SITE" portfolio-sim integrity > "$EV/integrity.json"; i=$?; tail -c 600 "$EV/integrity.json"; echo; log "integrity exit $i"
bench --site "$SITE" portfolio-sim replay-check > "$EV/replay.json"; r=$?; tail -c 400 "$EV/replay.json"; echo; log "replay exit $r"
[[ $i == 0 && $r == 0 ]] || rc=1
bench --site "$SITE" mariadb -e "select kind, outcome, count(*) n from \`tabDistribution Sim Event\` group by kind, outcome order by kind" | tee "$EV/ledger_by_kind.tsv"
bench --site "$SITE" mariadb -e "select voucher_type, count(distinct voucher_no) vouchers, round(sum(debit),2) debit, round(sum(credit),2) credit from \`tabGL Entry\` where is_cancelled = 0 group by voucher_type" | tee "$EV/gl_by_voucher_type.tsv"
"$(uv python find 3.14)" - "$EV/status.json" <<'PY' || rc=1
import json, sys
text = open(sys.argv[1]).read(); s = json.loads(text[text.index("{"):])
print("events executed:", s["events_executed"], "ledger rows:", s["ledger_rows"], "planned day:", s["planned_day"])
sys.exit(0 if s["seed"] and s["ledger_rows"] >= 1000 and s["events_executed"] == s["ledger_rows"] else 1)
PY
log "RESULT $([[ $rc == 0 ]] && echo PASS || echo FAIL)"
exit $rc
