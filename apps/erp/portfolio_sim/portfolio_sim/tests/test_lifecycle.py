"""ERPNext integration tests for the distribution simulation.

STATUS: WRITTEN, NOT YET EXECUTED. They need a running Frappe v16.60.0 / ERPNext v16.60.0 site, which does not
exist yet: the only supported route on the Windows host is WSL1, and enabling it needs an owner-approved reboot
(see docs/runbooks/ERP_WSL1_POC.md). Until they have run and passed on a real site, nothing in this app is claimed
to work against ERPNext; the pure engine is covered by apps/erp/tests (executed) and the API references by
scripts/verification/check_erp_upstream.py (executed).

Run (on a dedicated test site, never on a site with real history):
	bench --site <test-site> set-config allow_tests true
	bench --site <test-site> run-tests --app portfolio_sim --module portfolio_sim.tests.test_lifecycle
"""

from __future__ import annotations

import json
from datetime import date, datetime

import frappe
from frappe.tests import IntegrationTestCase
from frappe.utils import flt

from portfolio_sim.services import integrity, simulator
from portfolio_sim.services.setup import setup

SEED = 20261119
START = date(2025, 8, 1)


class TestDistributionLifecycle(IntegrationTestCase):
	"""One shared simulated company: set up once, then advance in small steps and check the ERP after each."""

	@classmethod
	def setUpClass(cls):
		super().setUpClass()
		setup(SEED, START)

	def _advance(self, until: str) -> dict:
		return simulator.advance(datetime.fromisoformat(until), respect_pause=False)

	def _ok(self, result: dict):
		self.assertEqual(result["failing"], [], json.dumps(result["results"], indent=1))

	def test_01_setup_created_master_data(self):
		self.assertTrue(frappe.db.exists("Company", "Sable Ridge Electronics Supply Co."))
		self.assertEqual(frappe.db.count("Item", {"item_code": ["like", "SRE-%"]}), 96)
		self.assertEqual(frappe.db.count("Customer", {"customer_group": ["!=", ""]}), 150)
		self.assertEqual(frappe.db.count("Warehouse", {"company": "Sable Ridge Electronics Supply Co.", "is_group": 0}) >= 4, True)
		self.assertEqual(frappe.db.get_single_value("Stock Settings", "allow_negative_stock"), 0)
		self.assertEqual(frappe.db.get_single_value("Selling Settings", "dn_required"), "Yes")

	def test_02_opening_day(self):
		self._advance("2025-08-01 08:00:00")
		self._ok(integrity.run())
		# Opening stock valued at cost, and the temporary opening account cleared to equity.
		temp = frappe.db.sql("""select sum(debit) - sum(credit) from `tabGL Entry` where account = 'Temporary Opening - SRE'
			and is_cancelled = 0""")[0][0]
		self.assertAlmostEqual(flt(temp), 0.0, places=2)

	def test_03_first_two_weeks_full_document_chains(self):
		self._advance("2025-08-15 23:59:59")
		result = integrity.run()
		self._ok(result)
		counts = result["counts"]
		for dt in ("Sales Order", "Delivery Note", "Sales Invoice", "Purchase Order", "Purchase Receipt", "Purchase Invoice"):
			self.assertGreater(counts[dt], 0, dt)
		# Sales order lines are priced from the Standard Selling list with the customer's discount.
		row = frappe.db.sql("""select soi.price_list_rate, soi.discount_percentage, soi.rate from `tabSales Order Item` soi
			join `tabSales Order` so on so.name = soi.parent where so.docstatus = 1 limit 1""", as_dict=True)[0]
		self.assertAlmostEqual(flt(row.rate), flt(row.price_list_rate) * (1 - flt(row.discount_percentage) / 100), places=2)

	def test_04_returns_payments_reconciliation_and_counts(self):
		self._advance("2025-10-31 23:59:59")
		result = integrity.run()
		self._ok(result)
		self.assertGreater(frappe.db.count("Sales Invoice", {"docstatus": 1, "is_return": 1}), 0)
		self.assertGreater(frappe.db.count("Payment Entry", {"docstatus": 1, "payment_type": "Receive"}), 0)
		self.assertGreater(frappe.db.count("Payment Entry", {"docstatus": 1, "payment_type": "Pay"}), 0)
		self.assertGreater(frappe.db.count("Stock Reconciliation", {"docstatus": 1, "purpose": "Stock Reconciliation"}), 0)

	def test_05_replay_matches_plan(self):
		r = simulator.replay_check()
		self.assertEqual((r["missing_count"], r["unexpected_count"], r["mismatch_count"]), (0, 0, 0), r)
		self.assertTrue(r["state_matches"])

	def test_06_rerun_does_not_duplicate(self):
		before = frappe.db.count("Distribution Sim Event")
		gl_before = frappe.db.count("GL Entry")
		self._advance("2025-10-31 23:59:59")  # already processed
		self.assertEqual(frappe.db.count("Distribution Sim Event"), before)
		self.assertEqual(frappe.db.count("GL Entry"), gl_before)

	def test_07_recovery_after_interrupted_event(self):
		"""An event that fails mid-way leaves no partial documents; the next run executes it exactly once."""
		from portfolio_sim.services import executor as ex

		original = ex.Executor.run
		calls = {"n": 0}

		def flaky(self, ev):
			calls["n"] += 1
			result = original(self, ev)
			if calls["n"] == 3:
				raise RuntimeError("simulated crash after documents were created, before commit")
			return result

		ex.Executor.run = flaky
		try:
			with self.assertRaises(RuntimeError):
				self._advance("2025-11-14 23:59:59")
		finally:
			ex.Executor.run = original
		self._advance("2025-11-14 23:59:59")
		self._ok(integrity.run())
		r = simulator.replay_check()
		self.assertEqual((r["missing_count"], r["unexpected_count"]), (0, 0), r)
