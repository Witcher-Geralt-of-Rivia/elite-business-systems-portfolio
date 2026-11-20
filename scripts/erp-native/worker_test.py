"""Enqueue three jobs (ok / raises / exceeds its 3 s timeout) on the native site, or report their final states.
python worker_test.py enqueue | python worker_test.py check"""
import json
import sys

import frappe_win  # noqa: F401
import frappe

IDS = "worker_test_ids.json"
frappe.init("native.local", sites_path=".")
frappe.connect()
if sys.argv[1] == "enqueue":
	jobs = [
		frappe.enqueue("frappe.client.get_count", queue="default", doctype="Sales Invoice"),
		frappe.enqueue("frappe.throw", queue="default", msg="expected failure"),
		frappe.enqueue("frappe.utils.background_jobs.test_job", queue="default", timeout=3, s=20),
	]
	json.dump([j.id for j in jobs], open(IDS, "w"))
	print("enqueued", [j.id for j in jobs])
else:
	from rq.job import Job

	from frappe.utils.background_jobs import get_redis_conn

	for jid in json.load(open(IDS)):
		j = Job.fetch(jid, connection=get_redis_conn())
		exc = (j.latest_result().exc_string or "").strip().splitlines()[-1:] if j.latest_result() else ""
		print(j.func_name, j.get_status(), "result:", j.return_value(), exc)
frappe.destroy()
