"""Drives the planner and the executor (Frappe runtime): history backfill, live advance, replay check.

Exactly-once execution:
* the planner's state and the planned day's pending events are persisted in `Distribution Sim Settings`
  when a day is planned (one commit);
* each event's documents, its `Distribution Sim Event` ledger row (primary key = event key) and the shortened
  pending list are committed together in one transaction; any error rolls all of them back;
* an event whose key is already in the ledger is never executed again (crash between commit and the pending
  update cannot duplicate it), so stopping the process at any moment and running again resumes exactly.

Only one engine runs at a time (`filelock`), whether started by the CLI backfill or the scheduler tick.
"""

from __future__ import annotations

import hashlib
import json
import time as _time
import traceback
from datetime import datetime, time, timedelta

import frappe
from frappe.utils import get_datetime, getdate, now_datetime

from ..engine.planner import Planner, initial_state, plan_range, state_dumps, state_loads
from ..upstream_refs import resolve
from .executor import Executor
from .setup import get_scenario

LOCK = "portfolio_sim_engine"
MAX_ATTEMPTS = 5  # per event, for transient lock conflicts (deadlock, lock-wait timeout)


def _settings():
	return frappe.get_single("Distribution Sim Settings")


def _scenario(st):
	if not st.seed:
		frappe.throw("Simulation not set up: run `bench --site <site> portfolio-sim setup` first")
	return get_scenario(int(st.seed), getdate(st.scenario_start))


def _record(ev: dict, result: dict) -> None:
	frappe.get_doc({"doctype": "Distribution Sim Event", "event_key": ev["key"], "kind": ev["kind"],
		"business_date": ev["date"], "business_time": ev["time"], "outcome": result["outcome"],
		"reference_doctype": result["reference_doctype"], "reference_name": result["reference_name"],
		"second_doctype": result["second_doctype"], "second_name": result["second_name"],
		"details": json.dumps(result["details"], default=str, sort_keys=True)}).insert(ignore_permissions=True)


def advance(until: datetime, max_events: int | None = None, respect_pause: bool = True, lock_timeout: int = 30) -> dict:
	"""Plan and execute events up to `until` (inclusive). Returns a summary."""
	with resolve("filelock")(LOCK, timeout=lock_timeout):
		st = _settings()
		if respect_pause and st.paused:
			return {"paused": True, "executed": 0}
		scenario = _scenario(st)
		planner = Planner(scenario)
		executor = Executor(scenario)
		state = state_loads(st.state_json) if st.state_json else initial_state(scenario)
		pending = json.loads(st.pending_events or "[]")
		executed = skipped = 0
		while True:
			if not pending:
				day = scenario.start if not st.planned_day else getdate(st.planned_day) + timedelta(days=1)
				if datetime.combine(day, time(0)) > until:
					break
				events, state = planner.plan_day(state, day)
				pending = [e.to_dict() for e in events]
				text = state_dumps(state)
				frappe.db.set_single_value("Distribution Sim Settings", {"planned_day": day, "state_json": text,
					"state_hash": hashlib.sha256(text.encode()).hexdigest()[:16], "pending_events": json.dumps(pending),
					**({} if pending else {"processed_until": datetime.combine(day, time(23, 59, 59))})})
				frappe.db.commit()
				st.planned_day = day
				continue
			ev = pending[0]
			at = get_datetime(f"{ev['date']} {ev['time']}")
			if at > until or (max_events is not None and executed >= max_events):
				break
			attempt = 0
			while True:
				attempt += 1
				try:
					if frappe.db.exists("Distribution Sim Event", ev["key"]):
						done = 0  # executed in an earlier run whose pending-list update was lost
					else:
						_record(ev, executor.run(ev))
						done = 1
					pending.pop(0)
					frappe.db.set_single_value("Distribution Sim Settings", {"pending_events": json.dumps(pending),
						"processed_until": at, "events_executed": int(st.events_executed or 0) + executed + done,
						"last_run_at": now_datetime(), "last_error": None})
					frappe.db.commit()
					executed += done
					skipped += 1 - done
					break
				except Exception as e:
					frappe.db.rollback()
					# A deadlock or lock-wait timeout against concurrent ERPNext work (e.g. the hourly stock
					# revaluation job) is transient: the whole event was rolled back, so it is retried from scratch,
					# as Frappe retries background jobs (frappe.utils.background_jobs.execute_job).
					if attempt < MAX_ATTEMPTS and (frappe.db.is_deadlocked(e) or frappe.db.is_timedout(e)):
						_time.sleep(attempt * 2)
						continue
					frappe.db.set_single_value("Distribution Sim Settings", {"last_error": f"{ev['key']}: {traceback.format_exc(limit=3)}"[:2000],
						"last_run_at": now_datetime()})
					frappe.db.commit()
					raise
		return {"executed": executed, "skipped_already_done": skipped, "planned_day": str(st.planned_day),
			"pending_today": len(pending)}


def status() -> dict:
	st = _settings()
	return {"seed": st.seed, "scenario_start": str(st.scenario_start), "company": st.company, "live": bool(st.live),
		"paused": bool(st.paused), "planned_day": str(st.planned_day), "processed_until": str(st.processed_until),
		"events_executed": st.events_executed, "pending_today": len(json.loads(st.pending_events or "[]")),
		"ledger_rows": frappe.db.count("Distribution Sim Event"), "state_hash": st.state_hash, "last_error": st.last_error}


AMENDABLE_KINDS = ("capital_contribution",)


def amend(kinds: tuple[str, ...] = AMENDABLE_KINDS, dry_run: bool = False) -> dict:
	"""Execute planned events that a planner rule added to days that were already processed.

	A rule that only ADDS events without drawing random numbers (FUNDING_FROM in engine.planner) leaves every existing
	event unchanged, but its events on days before the processed point were never executed. They are executed here in
	chronological order, exactly once (ledger primary key), with their planned date; only `kinds` are allowed, and only
	events whose day is already fully planned. Afterwards replay-check matches again."""
	if any(k not in AMENDABLE_KINDS for k in kinds):
		frappe.throw(f"only {AMENDABLE_KINDS} can be amended")
	with resolve("filelock")(LOCK, timeout=30):
		st = _settings()
		scenario = _scenario(st)
		events, _ = plan_range(Planner(scenario), initial_state(scenario), scenario.start, getdate(st.planned_day))
		pending = {e["key"] for e in json.loads(st.pending_events or "[]")}
		todo = [e for e in events if e.kind in kinds and e.key not in pending and not frappe.db.exists("Distribution Sim Event", e.key)]
		if dry_run:
			return {"to_execute": [e.key for e in todo]}
		executor = Executor(scenario)
		done = []
		for e in todo:
			ev = e.to_dict()
			_record(ev, executor.run(ev))
			frappe.db.set_single_value("Distribution Sim Settings", {"events_executed": int(_settings().events_executed or 0) + 1,
				"last_run_at": now_datetime()})
			frappe.db.commit()
			done.append(e.key)
		return {"executed": done, "count": len(done)}


def replay_check() -> dict:
	"""Re-plan from the scenario start through the planned day (read-only) and compare with the ledger:
	every planned event up to the processed point must be in the ledger with the same kind and date, nothing else
	may be there, and the persisted planner state must equal the recomputed one."""
	st = _settings()
	_scenario(st)  # refuses an un-initialised simulation (an empty comparison would prove nothing)
	if not st.planned_day:
		return {"days": 0, "planned": 0, "ledger": 0, "missing": [], "missing_count": 0, "unexpected": [], "unexpected_count": 0,
			"mismatch": [], "mismatch_count": 0, "state_matches": True}
	scenario = _scenario(st)
	events, state = plan_range(Planner(scenario), initial_state(scenario), scenario.start, getdate(st.planned_day))
	pending = {e["key"] for e in json.loads(st.pending_events or "[]")}
	planned = {e.key: e for e in events if e.key not in pending}
	ledger = {r.name: r for r in frappe.get_all("Distribution Sim Event", fields=["name", "kind", "business_date"], limit_page_length=0)}
	missing = sorted(k for k in planned if k not in ledger)
	unexpected = sorted(k for k in ledger if k not in planned)
	mismatch = sorted(k for k, e in planned.items() if k in ledger and (ledger[k].kind != e.kind or str(ledger[k].business_date) != e.date))
	return {"days": (getdate(st.planned_day) - scenario.start).days + 1, "planned": len(planned), "ledger": len(ledger),
		"missing": missing[:20], "missing_count": len(missing), "unexpected": unexpected[:20], "unexpected_count": len(unexpected),
		"mismatch": mismatch[:20], "mismatch_count": len(mismatch),
		"state_matches": state_dumps(state) == (st.state_json or "")}
