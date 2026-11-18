"""App install hook: nothing is generated on install. Company, master data and history are created explicitly
with `bench --site <site> portfolio-sim setup` and `... backfill` so an operator controls when (and how long)
the heavy work runs."""

import frappe


def after_install():
	settings = frappe.get_single("Distribution Sim Settings")
	settings.live = 0
	settings.paused = 0
	settings.save()
