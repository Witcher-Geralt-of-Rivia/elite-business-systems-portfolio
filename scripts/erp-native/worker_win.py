"""Native-Windows background worker for the spike: Frappe's own FrappeWorkerNoFork (no fork(): jobs run in this
process) with RQ's thread-based TimerDeathPenalty instead of the SIGALRM-based default (no SIGALRM on Windows).
Usage (from the bench's sites directory): python worker_win.py [queues] [--burst]
"""
import sys

import frappe_win  # noqa: F401  (runtime adaptations)
from rq.timeouts import TimerDeathPenalty

from frappe.utils.background_jobs import FrappeWorkerNoFork, get_queue_list, get_redis_conn


class WindowsWorker(FrappeWorkerNoFork):
	death_penalty_class = TimerDeathPenalty


def main():
	args = [a for a in sys.argv[1:] if not a.startswith("--")]
	queues = get_queue_list([q.strip() for q in args[0].split(",")] if args else None, build_queue_name=True)
	worker = WindowsWorker(queues, connection=get_redis_conn())
	worker.work(logging_level="INFO", burst="--burst" in sys.argv, with_scheduler=False)


if __name__ == "__main__":
	main()
