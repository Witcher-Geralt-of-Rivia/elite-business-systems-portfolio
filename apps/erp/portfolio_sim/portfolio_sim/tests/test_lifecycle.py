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
from collections import Counter
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

	def _planned(self, until: str) -> Counter:
		"""Event kinds the deterministic plan contains up to `until` (pure engine, same seed and start)."""
		from portfolio_sim.engine import calendar as cal
		from portfolio_sim.engine.planner import Planner, initial_state, plan_range
		from portfolio_sim.services.setup import get_scenario

		s = get_scenario(SEED, cal.on_or_after(START))
		events, _ = plan_range(Planner(s), initial_state(s), s.start, date.fromisoformat(until[:10]))
		return Counter(e.kind for e in events if f"{e.date} {e.time}" <= until)

	def _done(self, kind: str) -> int:
		return frappe.db.count("Distribution Sim Event", {"kind": kind, "outcome": "Done"})

	def _assert_documents_match_plan(self, until: str):
		"""Exact correspondence between the plan and ERPNext's submitted documents for the window."""
		p = self._planned(until)
		company = "Sable Ridge Electronics Supply Co."

		def docs(doctype, **filters):
			return frappe.db.count(doctype, {"docstatus": 1, "company": company, **filters})

		self.assertEqual(frappe.db.count("Distribution Sim Event"), sum(p.values()), "ledger rows = planned events")
		expect = {
			("Sales Order", ()): p["sales_order"],
			("Delivery Note", (("is_return", 0),)): p["delivery_note"],
			("Delivery Note", (("is_return", 1),)): p["sales_return"],
			("Sales Invoice", (("is_return", 0),)): p["sales_invoice"],
			("Sales Invoice", (("is_return", 1),)): p["sales_return"],
			("Purchase Order", ()): p["purchase_order"],
			("Purchase Receipt", (("is_return", 0),)): p["purchase_receipt"],
			("Purchase Receipt", (("is_return", 1),)): p["purchase_return"],
			("Purchase Invoice", (("is_return", 0),)): p["purchase_invoice"],
			("Purchase Invoice", (("is_return", 1),)): p["purchase_return"],
			("Stock Entry", ()): p["stock_transfer"],
			("Stock Reconciliation", ()): p["opening_stock"] + p["stock_count"],
			("Journal Entry", (("is_system_generated", 0),)): p["expense"] + p["opening_capital"] + self._done("opening_clearing"),
			("Payment Entry", (("payment_type", "Receive"),)): sum(self._done(k) for k in ("customer_payment", "customer_advance",
				"month_end_settlement")),
			("Payment Entry", (("payment_type", "Pay"),)): self._done("supplier_payment"),
		}
		for (doctype, filters), n in expect.items():
			self.assertEqual(docs(doctype, **dict(filters)), n, f"{doctype} {dict(filters)}")
		return p

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
		self._ok(integrity.run())
		p = self._assert_documents_match_plan("2025-08-15 23:59:59")
		# (The first supplier receipt is planned for 2025-08-18: opening stock covers the first weeks.)
		for kind in ("sales_order", "delivery_note", "sales_invoice", "purchase_order", "stock_transfer", "customer_payment"):
			self.assertGreater(p[kind], 0, kind)
		# Every sales order line is priced from ERPNext's Standard Selling Item Price, less the customer's discount
		# (run 44417258442 passed a weaker version of this check with every rate at 0).
		rows = frappe.db.sql("""select soi.item_code, soi.price_list_rate, soi.discount_percentage, soi.rate, ip.price_list_rate list_price
			from `tabSales Order Item` soi join `tabSales Order` so on so.name = soi.parent
			join `tabItem Price` ip on ip.item_code = soi.item_code and ip.price_list = 'Standard Selling'
			where so.docstatus = 1""", as_dict=True)
		self.assertGreater(len(rows), 100)
		for row in rows:
			self.assertGreater(flt(row.rate), 0, row)
			self.assertAlmostEqual(flt(row.price_list_rate), flt(row.list_price), places=2)
			self.assertAlmostEqual(flt(row.rate), flt(row.list_price) * (1 - flt(row.discount_percentage) / 100), places=2)

	def test_04_returns_payments_reconciliation_and_counts(self):
		# Five weeks: August month end (cycle count, advance settlement), Net 15/30 payments, the first supplier
		# payment runs, returns and Friday reconciliations.
		self._advance("2025-09-05 23:59:59")
		self._ok(integrity.run())
		p = self._assert_documents_match_plan("2025-09-05 23:59:59")
		for kind in ("purchase_receipt", "purchase_invoice", "sales_return", "stock_count", "month_end_settlement", "customer_advance"):
			self.assertGreater(p[kind], 0, kind)
		self.assertGreater(frappe.db.count("Sales Invoice", {"docstatus": 1, "is_return": 1}), 0)
		self.assertGreater(frappe.db.count("Stock Reconciliation", {"docstatus": 1, "purpose": "Stock Reconciliation"}), 0)
		# Customer payments really pay invoices ("Nothing Due" only when credits or advances already settled them).
		self.assertGreaterEqual(self._done("customer_payment"), 0.9 * p["customer_payment"],
			(self._done("customer_payment"), p["customer_payment"]))
		self.assertGreater(frappe.db.sql("""select count(*) from `tabGL Entry` where voucher_type = 'Sales Invoice'
			and is_cancelled = 0""")[0][0], 0)
		# Partial deliveries: some sales orders were delivered in more than one Delivery Note.
		multi = frappe.db.sql("""select count(*) from (select dni.against_sales_order from `tabDelivery Note Item` dni
			join `tabDelivery Note` dn on dn.name = dni.parent where dn.docstatus = 1 and dn.is_return = 0
			group by dni.against_sales_order having count(distinct dn.name) > 1) x""")[0][0]
		self.assertGreater(multi, 0, "orders with partial deliveries")
		# Reconciliation allocated advances/credits against invoices at least once.
		allocated = [json.loads(r.details or "{}").get("allocations", 0) for r in frappe.get_all("Distribution Sim Event",
			filters={"kind": "reconcile", "outcome": "Done"}, fields=["details"])]
		self.assertGreater(sum(allocated), 0, "reconciliation allocations")

	def test_05_replay_matches_plan(self):
		r = simulator.replay_check()
		self.assertEqual((r["missing_count"], r["unexpected_count"], r["mismatch_count"]), (0, 0, 0), r)
		self.assertTrue(r["state_matches"])

	def test_06_rerun_does_not_duplicate(self):
		before = frappe.db.count("Distribution Sim Event")
		gl_before = frappe.db.count("GL Entry")
		self._advance("2025-09-05 23:59:59")  # already processed
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
				self._advance("2025-09-12 23:59:59")
		finally:
			ex.Executor.run = original
		self._advance("2025-09-12 23:59:59")
		self._ok(integrity.run())
		p = self._assert_documents_match_plan("2025-09-12 23:59:59")  # no partial or duplicate documents
		self.assertGreater(p["supplier_payment"], 0)  # first supplier payment run is planned for 2025-09-11
		self.assertGreater(frappe.db.count("Payment Entry", {"docstatus": 1, "payment_type": "Pay"}), 0)
		r = simulator.replay_check()
		self.assertEqual((r["missing_count"], r["unexpected_count"]), (0, 0), r)
