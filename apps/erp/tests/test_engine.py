"""Unit tests for the pure-Python distribution engine (no Frappe needed).

Run: python -m unittest discover -s apps/erp/tests -v      (Python 3.12+; Frappe v16 itself needs 3.14)
"""

from __future__ import annotations

import json
import re
import sys
import unittest
from collections import Counter, defaultdict
from datetime import date, timedelta
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "portfolio_sim"))

from portfolio_sim.engine import calendar as cal  # noqa: E402
from portfolio_sim.engine.planner import Planner, events_hash, initial_state, plan_range, state_dumps, state_loads  # noqa: E402
from portfolio_sim.engine.rng import Rng, derive_seed  # noqa: E402
from portfolio_sim.engine.scenario import build_scenario, curated_values, load_catalog  # noqa: E402

SEED = 20261119
START = date(2025, 8, 1)
END = date(2026, 1, 31)  # six months: covers month ends, holidays, December seasonality

# Account names of ERPNext v16's "Standard" chart (verified against the pinned source by
# scripts/verification/check_erp_upstream.py); expenses must post to these.
STANDARD_EXPENSE_ACCOUNTS = {"Office Rent", "Salary", "Utility Expenses", "Telephone Expenses", "Freight and Forwarding Charges",
	"Marketing Expenses", "Travel Expenses", "Office Maintenance Expenses", "Bank Charges"}


class _Plan:
	"""Plan once per test run (six months), shared by the planner tests."""

	cache: dict = {}

	@classmethod
	def get(cls):
		if not cls.cache:
			cat = load_catalog()
			s = build_scenario(cat, SEED, cal.on_or_after(START))
			st0 = initial_state(s)
			events, st = plan_range(Planner(s), st0, s.start, END)
			cls.cache = {"catalog": cat, "scenario": s, "state0": st0, "events": events, "state": st}
		return cls.cache


class TestRng(unittest.TestCase):
	def test_same_seed_same_stream(self):
		a, b = Rng(42), Rng(42)
		self.assertEqual([a.next_u64() for _ in range(50)], [b.next_u64() for _ in range(50)])

	def test_stream_is_pinned(self):
		# Guards against accidental changes to the generator, which would silently change the history that a
		# deployed ERP was generated from (the replay check would then report every event as a mismatch).
		self.assertEqual(derive_seed(SEED, "scenario"), 5821736844590429757)
		r = Rng(derive_seed(SEED, "day", "2025-08-04"))
		self.assertEqual([r.randint(0, 999) for _ in range(5)], [365, 303, 2, 243, 42])

	def test_first_month_plan_is_pinned(self):
		# Changing the planner or catalogue changes this hash on purpose: update it together with a note in
		# docs/ERP_DATA_ENGINE.md, and never on a site whose history was generated with the old plan.
		s = build_scenario(load_catalog(), SEED, cal.on_or_after(START))
		events, _ = plan_range(Planner(s), initial_state(s), s.start, date(2025, 8, 31))
		self.assertEqual(len(events), 1116)
		self.assertEqual(events_hash(events), "b16d74671b6bda6bc12e5c0e237defbf38f1c9f471e1f31d8b560c05eaf53082")

	def test_ranges_and_means(self):
		r = Rng(7)
		xs = [r.random() for _ in range(20000)]
		self.assertTrue(all(0 <= x < 1 for x in xs))
		self.assertAlmostEqual(sum(xs) / len(xs), 0.5, delta=0.01)
		ints = [r.randint(3, 5) for _ in range(3000)]
		self.assertEqual(set(ints), {3, 4, 5})
		pois = [r.poisson(14.0) for _ in range(5000)]
		self.assertAlmostEqual(sum(pois) / len(pois), 14.0, delta=0.3)
		self.assertEqual(r.poisson(0), 0)

	def test_weighted_respects_weights(self):
		r = Rng(9)
		c = Counter(r.weighted(["a", "b"], [1, 3]) for _ in range(8000))
		self.assertAlmostEqual(c["b"] / 8000, 0.75, delta=0.02)
		with self.assertRaises(ValueError):
			r.weighted(["a"], [0])


class TestCalendar(unittest.TestCase):
	def test_holidays(self):
		h25, h26 = cal.holidays(2025), cal.holidays(2026)
		self.assertIn(date(2025, 11, 27), h25)  # Thanksgiving
		self.assertIn(date(2025, 11, 28), h25)  # day after
		self.assertIn(date(2025, 9, 1), h25)  # Labor Day
		self.assertIn(date(2026, 5, 25), h26)  # Memorial Day
		self.assertIn(date(2026, 7, 3), h26)  # July 4th on a Saturday, observed Friday
		self.assertIn(date(2025, 12, 25), h25)

	def test_business_days(self):
		self.assertFalse(cal.is_business_day(date(2025, 8, 2)))  # Saturday
		self.assertTrue(cal.is_business_day(date(2025, 8, 4)))
		self.assertEqual(cal.next_business_day(date(2025, 11, 26)), date(2025, 12, 1))
		self.assertEqual(cal.month_day(2025, 8, 31), date(2025, 8, 29))  # last business day
		self.assertEqual(cal.month_day(2025, 11, 1), date(2025, 11, 3))  # first business day
		self.assertTrue(cal.is_last_business_day_of_month(date(2025, 10, 31)))


class TestCatalog(unittest.TestCase):
	def setUp(self):
		self.cat = load_catalog()

	def test_about_500_curated_values(self):
		n = len(curated_values(self.cat))
		self.assertGreaterEqual(n, 450, n)
		self.assertLessEqual(n, 650, n)

	def test_items_and_suppliers(self):
		items = [row for rows in self.cat["items"].values() for row in rows]
		self.assertEqual(len(items), 96)
		self.assertEqual(len({r[0] for r in items}), 96, "item names unique")
		covered = {g for s in self.cat["suppliers"] for g in s["groups"]}
		self.assertEqual(covered, {g["prefix"] for g in self.cat["item_groups"]})
		self.assertTrue(all(r[2] > 0 and r[3] > 0 for r in items))

	def test_no_placeholders_or_real_contact_data(self):
		text = json.dumps({k: v for k, v in self.cat.items() if k != "_about"})
		for bad in (r"\b(Test|Demo|Sample|Dummy) (Customer|Company|Item|Supplier|Product)\b", r"_Test", r"Customer \d",
				r"Item \d", r"lorem", r"@", r"https?://"):
			self.assertIsNone(re.search(bad, text, re.I), bad)

	def test_independent_of_crm_and_pos_scenarios(self):
		text = json.dumps({k: v for k, v in self.cat.items() if k != "_about"})
		for other in ("Meridian", "Harbor", "Pine Market", "Keystone Logistics", "Atomic", "NexoPOS"):
			self.assertNotIn(other, text)

	def test_references_resolve(self):
		terms = {t["name"] for t in self.cat["payment_terms"]}
		self.assertTrue(all(s["terms"] in terms for s in self.cat["suppliers"]))
		self.assertTrue(all(t in terms for seg in self.cat["customer_segments"] for t in seg["terms"]))
		self.assertTrue({e["account"] for e in self.cat["expenses"]} <= STANDARD_EXPENSE_ACCOUNTS)
		self.assertAlmostEqual(sum(s["share"] for s in self.cat["customer_segments"]), 1.0, places=6)
		self.assertEqual(set(self.cat["supplier_cities"]), {s["name"] for s in self.cat["suppliers"]})


class TestScenario(unittest.TestCase):
	def setUp(self):
		self.cat = load_catalog()

	def test_deterministic(self):
		a = build_scenario(self.cat, SEED, START).to_master_data()
		b = build_scenario(self.cat, SEED, START).to_master_data()
		c = build_scenario(self.cat, SEED + 1, START).to_master_data()
		self.assertEqual(json.dumps(a, sort_keys=True), json.dumps(b, sort_keys=True))
		self.assertNotEqual(json.dumps(a, sort_keys=True), json.dumps(c, sort_keys=True))

	def test_master_data_rules(self):
		s = build_scenario(self.cat, SEED, START)
		self.assertEqual(len(s.customers), 150)
		self.assertEqual(len({c.name for c in s.customers}), 150)
		self.assertEqual(len({e.full_name for e in s.employees}), len(s.employees))
		for it in s.items:
			self.assertGreater(it.list_price, it.cost, it.code)
			self.assertRegex(it.code, r"^SRE-[A-Z]{3}-\d{3}$")
		for c in s.customers:
			self.assertEqual(c.warehouse, s.warehouse_for_territory(c.territory))
			if c.taxable:
				self.assertEqual(c.state, "Ohio")
				self.assertFalse(s.segments[c.segment]["exempt"])
			self.assertLess(c.since, s.start.isoformat())
			self.assertIn(c.account_manager, {e.full_name for e in s.employees if e.sales_person})
		self.assertEqual(sum(e.sales_person for e in s.employees), 6)


class TestPlanner(unittest.TestCase):
	@classmethod
	def setUpClass(cls):
		p = _Plan.get()
		cls.s, cls.events, cls.state = p["scenario"], p["events"], p["state"]
		cls.by_key = {e.key: e for e in cls.events}
		cls.pos = {e.key: i for i, e in enumerate(cls.events)}

	def test_deterministic(self):
		events, _ = plan_range(Planner(self.s), initial_state(self.s), self.s.start, date(2025, 10, 31))
		again, _ = plan_range(Planner(self.s), initial_state(self.s), self.s.start, date(2025, 10, 31))
		self.assertEqual(events_hash(events), events_hash(again))
		self.assertEqual(events_hash(events), events_hash([e for e in self.events if e.date <= "2025-10-31"]))

	def test_resume_after_interruption_matches_uninterrupted_run(self):
		planner = Planner(self.s)
		state = initial_state(self.s)
		events = []
		d = self.s.start
		while d <= date(2025, 10, 31):
			day, state = planner.plan_day(state, d)
			events.extend(day)
			state = state_loads(state_dumps(state))  # persisted and reloaded after every day
			if d.day % 9 == 0:
				planner = Planner(self.s)  # a fresh process
			d += timedelta(days=1)
		self.assertEqual(events_hash(events), events_hash([e for e in self.events if e.date <= "2025-10-31"]))

	def test_replanning_a_day_is_refused(self):
		_, st = Planner(self.s).plan_day(initial_state(self.s), self.s.start)
		with self.assertRaises(ValueError):
			Planner(self.s).plan_day(st, self.s.start)

	def test_keys_unique_and_ordered(self):
		keys = [e.key for e in self.events]
		self.assertEqual(len(keys), len(set(keys)))
		self.assertEqual([(e.date, e.time) for e in self.events], sorted((e.date, e.time) for e in self.events))
		for e in self.events:
			self.assertTrue(e.key.startswith(e.date + ":" + e.kind + ":"), e.key)

	def test_only_business_days_and_opening_once(self):
		for e in self.events:
			self.assertTrue(cal.is_business_day(date.fromisoformat(e.date)), e.key)
		opening = [e for e in self.events if e.kind.startswith("opening_")]
		self.assertEqual([e.kind for e in opening], ["opening_capital", "opening_stock", "opening_clearing"])
		self.assertTrue(all(e.date == self.s.start.isoformat() for e in opening))

	def _ref(self, e, field):
		ref = e.payload[field]
		self.assertIn(ref, self.by_key, f"{e.key} -> {field} {ref}")
		self.assertLess(self.pos[ref], self.pos[e.key], f"{e.key} refers to a later event {ref}")
		return self.by_key[ref]

	def test_references_point_to_earlier_events_of_the_right_kind(self):
		expect = {"purchase_receipt": {"po": "purchase_order"}, "purchase_invoice": {"pr": "purchase_receipt"},
			"purchase_return": {"pr": "purchase_receipt", "pi": "purchase_invoice"}, "supplier_payment": {"pi": "purchase_invoice"},
			"delivery_note": {"so": "sales_order"}, "sales_invoice": {"dn": "delivery_note"},
			"sales_return": {"dn": "delivery_note", "si": "sales_invoice"}}
		for e in self.events:
			for field, kind in expect.get(e.kind, {}).items():
				self.assertEqual(self._ref(e, field).kind, kind)
			if e.kind == "customer_payment":
				for si in e.payload["invoices"]:
					self.assertEqual(self.by_key[si].kind, "sales_invoice")
					self.assertLess(self.pos[si], self.pos[e.key])
					self.assertGreater(e.date, self.by_key[si].date, "payment on a later day than the invoice")

	def test_document_chains_are_consistent(self):
		for e in self.events:
			if e.kind == "sales_invoice":
				dn = self._ref(e, "dn")
				self.assertEqual(dn.date, e.date)
			if e.kind == "purchase_invoice":
				self.assertGreater(e.date, self._ref(e, "pr").date)
			if e.kind == "sales_return":
				dn = self._ref(e, "dn")
				self.assertGreaterEqual((date.fromisoformat(e.date) - date.fromisoformat(dn.date)).days, 3)
				si = self._ref(e, "si")
				self.assertEqual(self.by_key[si.payload["dn"]].key, dn.key)
				self.assertEqual(self.by_key[dn.payload["so"]].payload["customer"], e.payload["customer"])

	def test_quantities_never_exceed_orders(self):
		ordered = {e.key: dict(e.payload["lines"]) if e.kind == "sales_order" else {c: q for c, q, _ in e.payload["lines"]}
			for e in self.events if e.kind in ("sales_order", "purchase_order")}
		delivered, received, returned = defaultdict(int), defaultdict(int), defaultdict(int)
		dn_lines = {}
		for e in self.events:
			if e.kind == "delivery_note":
				dn_lines[e.key] = e.payload["lines"]
				for c, q in e.payload["lines"].items():
					delivered[(e.payload["so"], c)] += q
					self.assertLessEqual(delivered[(e.payload["so"], c)], ordered[e.payload["so"]][c])
			if e.kind == "purchase_receipt":
				for c, q in e.payload["lines"].items():
					received[(e.payload["po"], c)] += q
					self.assertLessEqual(received[(e.payload["po"], c)], ordered[e.payload["po"]][c])
			if e.kind == "sales_return":
				for c, q in e.payload["lines"].items():
					returned[(e.payload["dn"], c)] += q
					self.assertLessEqual(returned[(e.payload["dn"], c)], dn_lines[e.payload["dn"]][c])
		# Purchase orders still open at the horizon are the only ones not fully received.
		open_pos = set(self.state["open_pos"])
		for po, lines in ((k, v) for k, v in ordered.items() if self.by_key[k].kind == "purchase_order"):
			if po not in open_pos:
				for c, q in lines.items():
					self.assertEqual(received[(po, c)], q, f"{po} {c}")

	def test_stock_replay_never_negative_and_matches_state(self):
		stock = defaultdict(int)
		for e in self.events:
			p = e.payload
			if e.kind == "opening_stock":
				for w, lines in p["warehouses"].items():
					for c, q in lines.items():
						stock[(w, c)] += q
			elif e.kind == "purchase_receipt":
				for c, q in p["lines"].items():
					stock[("DC", c)] += q
			elif e.kind == "purchase_return":
				for c, q in p["lines"].items():
					stock[("DC", c)] -= q
			elif e.kind == "delivery_note":
				w = self.by_key[p["so"]].payload["warehouse"]
				for c, q in p["lines"].items():
					stock[(w, c)] -= q
			elif e.kind == "sales_return":
				for c, q in p["lines"].items():
					stock[("RTN", c)] += q
			elif e.kind == "stock_transfer":
				for c, q in p["lines"].items():
					stock[(p["from"], c)] -= q
					stock[(p["to"], c)] += q
			elif e.kind == "stock_count":
				for c, q in p["lines"].items():
					stock[(p["warehouse"], c)] = q
			negative = {k: v for k, v in stock.items() if v < 0}
			self.assertFalse(negative, f"after {e.key}: {negative}")
		for w, lines in self.state["stock"].items():
			for c, q in lines.items():
				self.assertEqual(stock[(w, c)], q, f"{w} {c}")

	def test_plausible_volumes(self):
		days = cal.business_days(self.s.start, END)
		so = [e for e in self.events if e.kind == "sales_order"]
		per_day = len(so) / len(days)
		self.assertTrue(10 <= per_day <= 20, per_day)
		by_month = Counter(e.date[:7] for e in so)
		dec = by_month["2025-12"] / len([d for d in days if d.month == 12])
		oct_ = by_month["2025-10"] / len([d for d in days if d.month == 10 and d.year == 2025])
		self.assertLess(dec, oct_, "December is quieter than October")
		# First delivery covers the whole order for most orders (backorders are the exception).
		first_dn = {}
		for e in self.events:
			if e.kind == "delivery_note" and e.payload["so"] not in first_dn:
				first_dn[e.payload["so"]] = e.payload["lines"]
		complete = sum(1 for k, lines in first_dn.items() if lines == dict(self.by_key[k].payload["lines"]))
		self.assertGreater(complete / len(first_dn), 0.75, complete / len(first_dn))
		invoices = sum(1 for e in self.events if e.kind == "sales_invoice")
		returns = sum(1 for e in self.events if e.kind == "sales_return")
		self.assertTrue(0.02 <= returns / invoices <= 0.10, returns / invoices)

	def test_invoices_get_paid(self):
		"""Every invoice of a non-advance customer has a full payment, a payment still scheduled at the
		horizon (late payers), or was fully credited."""
		paid_full = set()
		half = set()
		for e in self.events:
			if e.kind == "customer_payment":
				for si in e.payload["invoices"]:
					if e.payload["mode"] == "half":
						self.assertNotIn(si, paid_full, "half payment after the final payment")
						half.add(si)
					else:
						paid_full.add(si)
		scheduled = {p[4]["si"] for p in self.state["pending"] if p[2] == "payment_intent" and p[4]["mode"] == "full"}
		settled = {k for k, v in self.state["invoices"].items() if v.get("settled")}
		unpaid = 0
		for e in self.events:
			if e.kind == "sales_invoice":
				customer = self.by_key[self.by_key[e.payload["dn"]].payload["so"]].payload["customer"]
				if not self.s.customer(customer).advance_payer and e.key not in paid_full:
					self.assertTrue(e.key in scheduled or e.key in settled, e.key)
					self.assertFalse(e.key in scheduled and e.key in settled)
					unpaid += 1
		# Receivables at the horizon are a plausible share of recent invoicing, not an accumulating backlog.
		invoices = sum(1 for e in self.events if e.kind == "sales_invoice")
		self.assertLess(unpaid / invoices, 0.25, unpaid / invoices)

	def test_supplier_side(self):
		for e in self.events:
			if e.kind == "purchase_order":
				for code, qty, rate in e.payload["lines"]:
					it = self.s.item(code)
					self.assertEqual(qty % it.pack, 0)
					self.assertTrue(it.cost * 0.95 <= rate <= it.cost * 1.10, (code, rate))
					self.assertEqual(it.supplier, e.payload["supplier"])
			if e.kind == "supplier_payment":
				pi = self.by_key[e.payload["pi"]]
				self.assertGreaterEqual(e.date, pi.date)
			if e.kind == "expense":
				self.assertGreater(e.payload["amount"], 0)
				self.assertIn(e.payload["account"], STANDARD_EXPENSE_ACCOUNTS)

	def test_month_end_and_weekly_routines(self):
		counts = [e for e in self.events if e.kind == "stock_count"]
		self.assertTrue(all(cal.is_last_business_day_of_month(date.fromisoformat(e.date)) for e in counts))
		transfers = [e for e in self.events if e.kind == "stock_transfer"]
		self.assertTrue(all(date.fromisoformat(e.date).weekday() in (1, 4) for e in transfers))
		payroll = [e for e in self.events if e.kind == "expense" and e.payload["account"] == "Salary"]
		self.assertEqual(len(payroll), 2 * 6)


if __name__ == "__main__":
	unittest.main()
