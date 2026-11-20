"""Native-Windows scheduler process: Frappe's own scheduler loop (frappe.utils.scheduler.start_scheduler), which
enqueues due Scheduled Job Types for every site every tick.

Frappe allows one scheduler per bench through a file lock (config/scheduler_process). Frappe's workers also try to
start a scheduler thread when none holds the lock (self-healing). start_scheduler() returns immediately when another
process holds the lock; on Linux the supervisor restarts it, and here the loop below retries every 60 s instead of
exiting (a clean exit would leave the Windows service stopped). Usage (from the sites directory):
python scheduler_win.py
"""
import sys
import time

import frappe_win  # noqa: F401  (runtime adaptations)

import frappe
from frappe.utils.scheduler import start_scheduler


def main() -> int:
	frappe.init("", sites_path=".")
	time.sleep(0.5)
	while True:
		start_scheduler()  # blocks for as long as this process holds the scheduler lock
		print("scheduler_win: another process holds the scheduler lock; retrying in 60 s", flush=True)
		time.sleep(60)


if __name__ == "__main__":
	try:
		sys.exit(main())
	except KeyboardInterrupt:
		sys.exit(0)
