"""Native-Windows background worker: Frappe's own FrappeWorkerNoFork (no fork(): jobs run in this process) with
RQ's thread-based TimerDeathPenalty instead of the SIGALRM-based default (no SIGALRM on Windows).

Usage (from the bench's sites directory): python worker_win.py [queues] [--burst]

Service contract (install-erp-services.ps1): the Windows service wrapper restarts the worker only when it exits
with a non-zero code. FrappeWorkerNoFork deliberately leaves its work loop after RQ_MAX_JOBS jobs and after a job
timeout (to discard partial state); on Linux the process supervisor restarts it. Here an end of the work loop that
nobody requested exits with code 3, so the service restarts the worker. A stop requested by the service (Ctrl+C:
warm shutdown, the running job finishes; a second Ctrl+C: immediate exit, the open DB transaction rolls back)
exits 0.
"""
import sys

import frappe_win  # noqa: F401  (runtime adaptations)
from rq.timeouts import TimerDeathPenalty

import frappe
from frappe.utils.background_jobs import FrappeWorkerNoFork, get_queue_list, get_redis_conn

RESTART_EXIT_CODE = 3


class WindowsWorker(FrappeWorkerNoFork):
	death_penalty_class = TimerDeathPenalty

	@property
	def dequeue_timeout(self) -> int:
		# rq waits for jobs with a blocking Redis read of worker_ttl - 15 = 405 s. On Windows a console Ctrl+C (the
		# service stop) is only handled when that read returns, so a stop took minutes (measured: 107 s and more).
		# A short wait keeps an idle worker responsive to a stop; heartbeats and job timeouts are unchanged.
		return 10

	def request_force_stop(self, signum, frame):
		# rq.Worker's cold shutdown kills a forked "horse" process; without fork there is none: just leave.
		self.log.warning("Worker %s: cold shutdown requested; exiting", self.name)
		raise SystemExit(0)


def main() -> int:
	args = [a for a in sys.argv[1:] if not a.startswith("--")]
	burst = "--burst" in sys.argv
	frappe.init("", sites_path=".")
	queues = get_queue_list([q.strip() for q in args[0].split(",")] if args else None, build_queue_name=True)
	worker = WindowsWorker(queues, connection=get_redis_conn())
	worker.work(
		logging_level="INFO",
		burst=burst,
		date_format="%Y-%m-%d %H:%M:%S",
		log_format="%(asctime)s,%(msecs)03d %(message)s",
		with_scheduler=False,
	)
	# rq's request_stop() (SIGINT/SIGTERM handler) records the shutdown request date.
	if burst or getattr(worker, "_shutdown_requested_date", None):
		return 0
	print("worker_win: work loop ended without a stop request (job limit or job timeout); exit 3 -> restart", flush=True)
	return RESTART_EXIT_CODE


if __name__ == "__main__":
	sys.exit(main())
