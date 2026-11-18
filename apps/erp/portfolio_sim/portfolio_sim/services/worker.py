"""Live simulation worker: the scheduler calls `tick` every minute (hooks.scheduler_events).

A tick does nothing unless the simulation is set up, switched to live and not paused. It advances the
simulation to the current time with a bounded number of events (so a scheduler job stays short; a backlog is
caught up over several ticks) and never waits for the engine lock: if a backfill or another tick holds it,
the tick simply ends.
"""

from __future__ import annotations

import frappe
from frappe.utils import now_datetime

MAX_EVENTS_PER_TICK = 120


def tick() -> dict | None:
	st = frappe.get_single("Distribution Sim Settings")
	if not st.seed or not st.live or st.paused:
		return None
	from frappe.utils.synchronization import LockTimeoutError

	from .simulator import advance

	try:
		return advance(now_datetime(), max_events=MAX_EVENTS_PER_TICK, lock_timeout=0)
	except LockTimeoutError:
		return {"skipped": "engine busy"}
