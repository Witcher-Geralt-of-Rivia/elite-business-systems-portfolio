"""Health endpoint for the hosted installation: GET /api/method/portfolio_sim.health.status

Checks the components a request cannot see on its own: the database, both Redis instances, the background workers
(RQ heartbeats), the scheduler (last enqueue of the simulation's per-minute job) and the live simulation (last tick,
lag behind the clock). Returns HTTP 200 when everything required is healthy, otherwise 503.

Guest-accessible on purpose (monitoring has no session) and therefore limited to states, counts and ages: no
hostnames, ports, versions, document data or error texts.
"""

from __future__ import annotations

import json
import time
from datetime import datetime, timedelta
from datetime import time as dtime

import frappe
from frappe.utils import get_datetime, getdate, now_datetime

TICK_JOB = "portfolio_sim.services.worker.tick"
SCHEDULER_MAX_AGE_S = 300  # the tick job is due every minute
WORKER_HEARTBEAT_MAX_AGE_S = 900
SIM_MAX_OVERDUE_S = 1800  # live mode: a tick runs every minute with up to 120 events


def _age(value) -> int | None:
	if not value:
		return None
	return int((now_datetime() - get_datetime(value)).total_seconds())


def _probe(fn):
	start = time.monotonic()
	try:
		fn()
		return {"ok": True, "ms": round((time.monotonic() - start) * 1000, 1)}
	except Exception:
		return {"ok": False}


@frappe.whitelist(allow_guest=True, methods=["GET"])
def status() -> dict:
	from frappe.utils.background_jobs import get_redis_conn

	out: dict = {
		"db": _probe(lambda: frappe.db.sql("select 1")),
		"redis_cache": _probe(lambda: frappe.cache.ping()),
		"redis_queue": _probe(lambda: get_redis_conn().ping()),
	}

	try:
		from rq import Worker

		now = time.time()
		workers = Worker.all(connection=get_redis_conn())
		fresh = [w for w in workers if w.last_heartbeat and now - w.last_heartbeat.timestamp() < WORKER_HEARTBEAT_MAX_AGE_S]
		queues = sorted({q.name.rsplit(":", 1)[-1] for w in fresh for q in w.queues})
		out["workers"] = {"ok": bool(fresh), "count": len(fresh), "queues": queues}
	except Exception:
		out["workers"] = {"ok": False}

	try:
		from frappe.utils.scheduler import is_scheduler_disabled

		last = frappe.db.get_value("Scheduled Job Type", {"method": TICK_JOB}, "last_execution")
		age = _age(last)
		# A negative age is a clock problem (e.g. a site time-zone change leaves last_execution in the future, and
		# Frappe then treats every job as not due): unhealthy, not "fresh". Found 2026-11-20.
		out["scheduler"] = {
			"ok": not is_scheduler_disabled(verbose=False) and age is not None and -60 <= age < SCHEDULER_MAX_AGE_S,
			"enabled": not is_scheduler_disabled(verbose=False),
			"last_enqueue_age_s": age,
		}
	except Exception:
		out["scheduler"] = {"ok": False}

	try:
		st = frappe.get_single("Distribution Sim Settings")
		live = bool(st.seed and st.live and not st.paused)
		# The processed point is the time of the last executed event, so it trails the clock overnight and over
		# weekends by design. What matters is whether the NEXT due event is overdue.
		pending = json.loads(st.pending_events or "[]")
		if pending:
			next_due = get_datetime(f"{pending[0]['date']} {pending[0]['time']}")
		elif st.planned_day:
			next_due = datetime.combine(getdate(st.planned_day) + timedelta(days=1), dtime(0))
		else:
			next_due = None
		now = now_datetime()
		overdue = int((now - next_due).total_seconds()) if next_due and next_due <= now else 0
		sim = {
			"set_up": bool(st.seed),
			"live": bool(st.live),
			"paused": bool(st.paused),
			"last_tick_age_s": _age(st.last_run_at),
			"overdue_s": overdue,
			"events_executed": int(st.events_executed or 0),
			"error": bool(st.last_error),
		}
		sim["ok"] = (not live) or (overdue < SIM_MAX_OVERDUE_S and not st.last_error)
		out["simulation"] = sim
	except Exception:
		out["simulation"] = {"ok": False}

	required = ("db", "redis_cache", "redis_queue", "workers", "scheduler", "simulation")
	out["ok"] = all(out[k].get("ok") for k in required)
	if not out["ok"]:
		frappe.local.response["http_status_code"] = 503
	return out


@frappe.whitelist(methods=["POST"])
def realtime_probe() -> str:
	"""End-to-end realtime check for logged-in users (browser tests): a background job on the short queue publishes
	a message to the caller, so the path web -> Redis queue -> worker -> Redis pub/sub -> Socket.IO -> browser is
	exercised. Nothing is written to the database."""
	frappe.enqueue("portfolio_sim.health._realtime_probe_job", queue="short", user=frappe.session.user)
	return "queued"


def _realtime_probe_job(user: str) -> None:
	frappe.publish_realtime("msgprint", "realtime probe: delivered by a background worker", user=user)
