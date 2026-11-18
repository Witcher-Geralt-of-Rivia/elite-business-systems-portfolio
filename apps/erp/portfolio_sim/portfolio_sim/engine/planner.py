"""Business-event planner for Sable Ridge Electronics Supply Co. (pure Python, deterministic).

The planner runs the whole business on a projected model (stock per warehouse, open purchase and
sales orders, payables, receivables, credits) and emits dated events with stable keys. It never reads
the ERP: the same seed, scenario start and state always produce the same events, so

* history can be generated in any number of runs (state is persisted after each day),
* a replay check can recompute the plan and compare it with the ERP's event ledger,
* the executor (Frappe side) only turns events into ERPNext documents.

Monetary amounts are computed by ERPNext (prices, discounts, taxes, valuation); events carry
quantities, rates for purchases, dates and references to earlier events by key.
"""

from __future__ import annotations

import copy
import hashlib
import json
import math
from dataclasses import asdict, dataclass
from datetime import date, timedelta

from . import calendar as cal
from .rng import Rng, derive_seed
from .scenario import Scenario

SELLING_WAREHOUSES = ("DC", "CLE", "CIN")
EMA_ALPHA = 0.05

# Time of day per kind: the order in which a day's events are executed.
TIMES = {
	"opening_capital": "07:00:00", "opening_stock": "07:05:00", "opening_clearing": "07:10:00",
	"purchase_receipt": "08:00:00", "purchase_return": "08:30:00", "stock_transfer": "09:00:00",
	"delivery_note": "09:30:00", "sales_invoice": "09:35:00", "purchase_invoice": "11:00:00",
	"customer_advance": "12:30:00", "customer_payment": "13:00:00", "sales_return": "14:00:00",
	"supplier_payment": "15:00:00", "reconcile": "16:00:00", "month_end_settlement": "16:30:00",
	"expense": "16:45:00", "purchase_order": "17:00:00", "stock_count": "17:30:00",
}


@dataclass
class Event:
	key: str
	kind: str
	date: str
	time: str
	payload: dict

	def to_dict(self) -> dict:
		return asdict(self)


def _d(s: str) -> date:
	return date.fromisoformat(s)


def initial_state(scenario: Scenario) -> dict:
	"""Projected state before the first day: demand estimates and opening stock levels."""
	ema = estimate_demand(scenario)
	stock: dict[str, dict[str, int]] = {w["key"]: {} for w in scenario.warehouses}
	policy = scenario.catalog["policy"]
	for it in scenario.items:
		total = sum(ema[w].get(it.code, 0.0) for w in SELLING_WAREHOUSES)
		for w in SELLING_WAREHOUSES:
			if w == "DC":
				q = total * policy["opening_stock_days"] - sum(ema[b].get(it.code, 0.0) for b in ("CLE", "CIN")) * policy["branch_cover_days"]
			else:
				q = ema[w].get(it.code, 0.0) * policy["branch_cover_days"]
			stock[w][it.code] = int(math.ceil(max(q, 0) / it.pack) * it.pack)
	return {
		"version": 1,
		"day": None,
		"stock": stock,
		"ema": {w: {k: round(v, 6) for k, v in ema[w].items()} for w in SELLING_WAREHOUSES},
		"open_pos": {},
		"open_sos": {},
		"pending": [],
		"pending_seq": 0,
		"invoices": {},
		"payables": {},
		"credits": {},
		"supplier_credits": {},
		"counters": {"bill": 0, "check": 0, "po_no": 0},
	}


def estimate_demand(scenario: Scenario, days: int = 60) -> dict[str, dict[str, float]]:
	"""Average daily units per (warehouse, item) from a warm-up of the demand model (separate stream)."""
	rng = Rng(derive_seed(scenario.seed, "warm-up"))
	totals: dict[str, dict[str, float]] = {w: {} for w in SELLING_WAREHOUSES}
	d = scenario.start
	for _ in range(days):
		for so in _draw_orders(scenario, rng, d, scale=1.0):
			for code, qty in so["lines"]:
				totals[so["warehouse"]][code] = totals[so["warehouse"]].get(code, 0.0) + qty
	return {w: {k: v / days for k, v in totals[w].items()} for w in SELLING_WAREHOUSES}


def _growth(scenario: Scenario, d: date) -> float:
	years = (d - scenario.start).days / 365.25
	return (1 + scenario.catalog["demand"]["growth_per_year"]) ** years


def _draw_orders(scenario: Scenario, rng: Rng, d: date, scale: float | None = None) -> list[dict]:
	"""New sales orders for business day d (customer, warehouse, lines)."""
	demand = scenario.catalog["demand"]
	if scale is None:
		scale = demand["seasonality"][d.month - 1] * demand["weekday"][d.weekday()] * _growth(scenario, d)
	n = rng.poisson(demand["orders_per_business_day"] * scale)
	customers = scenario.customers
	weights = [c.orders_per_month for c in customers]
	groups = scenario.catalog["item_groups"]
	gseason = demand.get("group_seasonality", {})
	by_group: dict[str, list] = {}
	for it in scenario.items:
		by_group.setdefault(it.group_prefix, []).append(it)
	orders = []
	for _ in range(n):
		c = rng.weighted(customers, weights)
		seg = scenario.segments[c.segment]
		k = rng.randint(*seg["lines"])
		gw = [g["affinity"].get(c.segment, 1) * gseason.get(g["prefix"], [1.0] * 12)[d.month - 1] for g in groups]
		chosen: dict[str, int] = {}
		for _line in range(k * 3):
			if len(chosen) >= k:
				break
			g = rng.weighted(groups, gw)
			pool = by_group[g["prefix"]]
			it = rng.weighted(pool, [i.weight for i in pool])
			if it.code in chosen:
				continue
			base = seg["qty_scale"] * (4.0 if it.cost < 20 else 2.0 if it.cost < 80 else 1.0 if it.cost < 150 else 0.5)
			qty = max(1, round(rng.lognormal(math.log(max(base, 0.6)), 0.55)))
			if it.cost >= 150:
				qty = min(qty, 3)
			chosen[it.code] = qty
		if chosen:
			orders.append({"customer": c.name, "warehouse": c.warehouse, "lines": sorted(chosen.items())})
	return orders


class Planner:
	def __init__(self, scenario: Scenario):
		self.s = scenario
		self.policy = scenario.catalog["policy"]
		self.supplier_items: dict[str, list] = {}
		for it in scenario.items:
			self.supplier_items.setdefault(it.supplier, []).append(it)

	# ------------------------------------------------------------------ public API
	def plan_day(self, state: dict, d: date) -> tuple[list[Event], dict]:
		"""Events of day d and the state after it. `state` is not modified."""
		st = copy.deepcopy(state)
		if st["day"] is not None and _d(st["day"]) >= d:
			raise ValueError(f"day {d} already planned (state is at {st['day']})")
		self._events: list[tuple[str, int, Event]] = []
		self._counters: dict[str, int] = {}
		self._d = d
		self.st = st
		if cal.is_business_day(d):
			rng = Rng(derive_seed(self.s.seed, "day", d.isoformat()))
			self._business_day(rng)
		st["day"] = d.isoformat()
		events = [e for _, _, e in sorted(self._events, key=lambda t: (t[0], t[1]))]
		return events, st

	# ------------------------------------------------------------------ helpers
	def _emit(self, kind: str, payload: dict, time: str | None = None) -> str:
		n = self._counters.get(kind, 0) + 1
		self._counters[kind] = n
		key = f"{self._d.isoformat()}:{kind}:{n:03d}"
		t = time or TIMES[kind]
		self._events.append((t, len(self._events), Event(key, kind, self._d.isoformat(), t, payload)))
		return key

	def _schedule(self, when: date, kind: str, payload: dict) -> None:
		self.st["pending_seq"] += 1
		self.st["pending"].append([when.isoformat(), TIMES.get(kind, "12:00:00"), kind, self.st["pending_seq"], payload])
		self.st["pending"].sort(key=lambda p: (p[0], p[1], p[3]))

	def _due(self, kind: str) -> list[dict]:
		today = self._d.isoformat()
		out, keep = [], []
		for p in self.st["pending"]:
			(out if p[0] <= today and p[2] == kind else keep).append(p)
		self.st["pending"] = keep
		return [p[4] for p in out]

	def _stock(self, wh: str, code: str) -> int:
		return self.st["stock"][wh].get(code, 0)

	def _add_stock(self, wh: str, code: str, qty: int) -> None:
		self.st["stock"][wh][code] = self._stock(wh, code) + qty
		if self.st["stock"][wh][code] < 0:
			raise AssertionError(f"negative projected stock {wh} {code} on {self._d}")

	def _backorder(self, wh: str, code: str) -> int:
		return sum(max(0, l[0] - l[1]) for so in self.st["open_sos"].values() if so["warehouse"] == wh
			for c, l in so["lines"].items() if c == code)

	def _on_order(self, code: str) -> int:
		return sum(max(0, l[0] - l[1]) for po in self.st["open_pos"].values() for c, l in po["lines"].items() if c == code)

	# ------------------------------------------------------------------ the business day
	def _business_day(self, rng: Rng) -> None:
		d = self._d
		if d == self.s.start:
			self._opening()
		self._receipts(rng)
		self._supplier_invoices(rng)
		self._purchase_returns()
		self._transfers()
		self._deliveries(rng)
		ordered = self._sales_orders(rng)
		self._customer_payments()
		self._sales_returns()
		self._advances_and_settlement()
		self._supplier_payments()
		self._reconciliations()
		self._expenses(rng)
		self._purchasing(rng)
		self._cycle_count(rng)
		self._update_ema(ordered)
		self._prune()

	def _opening(self) -> None:
		self._emit("opening_capital", {"amount": self.s.company["opening_capital"]})
		# One Stock Reconciliation per warehouse: ERPNext queues reconciliations with more than 100 rows as a
		# background job instead of submitting them (stock_reconciliation.py `submit`), found in CI.
		for w in SELLING_WAREHOUSES:
			lines = {c: q for c, q in sorted(self.st["stock"][w].items()) if q > 0}
			if lines:
				self._emit("opening_stock", {"warehouse": w, "lines": lines, "valuation": "cost"})
		self._emit("opening_clearing", {})

	def _receipts(self, rng: Rng) -> None:
		today = self._d.isoformat()
		for po_key in sorted(self.st["open_pos"]):
			po = self.st["open_pos"][po_key]
			due = [a for a in po["arrivals"] if a[0] <= today]
			if not due:
				continue
			po["arrivals"] = [a for a in po["arrivals"] if a[0] > today]
			lines: dict[str, int] = {}
			for _, arr in due:
				for c, q in arr.items():
					lines[c] = lines.get(c, 0) + q
			lines = {c: q for c, q in sorted(lines.items()) if q > 0}
			if not lines:
				continue
			pr_key = self._emit("purchase_receipt", {"po": po_key, "lines": lines})
			defects: dict[str, int] = {}
			for c, q in lines.items():
				self._add_stock(po["warehouse"], c, q)
				po["lines"][c][1] += q
				if q >= 5 and rng.chance(self.policy["purchase_defect_rate"] * 3):
					defects[c] = max(1, round(q * rng.uniform(0.02, 0.08)))
			self.st["counters"]["bill"] += 1
			sup = self.s.supplier(po["supplier"])
			delay = rng.randint(*self.policy["supplier_invoice_delay"])
			self._schedule(cal.next_business_day(self._d, delay), "purchase_invoice", {
				"pr": pr_key, "supplier": po["supplier"], "bill_no": f"INV-{''.join(w[0] for w in sup['name'].split())}-{self.st['counters']['bill']:05d}",
				"defects": defects})
			if not po["arrivals"]:
				del self.st["open_pos"][po_key]

	def _supplier_invoices(self, rng: Rng) -> None:
		for p in self._due("purchase_invoice"):
			pi_key = self._emit("purchase_invoice", {"pr": p["pr"], "bill_no": p["bill_no"], "bill_date": self._d.isoformat()})
			terms = self.s.supplier(p["supplier"])["terms"]
			days = next(t["days"] for t in self.s.catalog["payment_terms"] if t["name"] == terms)
			self.st["payables"][pi_key] = {"supplier": p["supplier"], "due": (self._d + timedelta(days=days)).isoformat(),
				"paid_on": None, "pr": p["pr"]}
			if p["defects"]:
				self._schedule(cal.next_business_day(self._d, rng.randint(1, 3)), "purchase_return", {
					"pr": p["pr"], "pi": pi_key, "lines": p["defects"],
					"reason": rng.choice(self.s.catalog["purchase_return_reasons"])})

	def _purchase_returns(self) -> None:
		for p in self._due("purchase_return"):
			lines = {c: min(q, self._stock("DC", c)) for c, q in p["lines"].items()}
			lines = {c: q for c, q in lines.items() if q > 0}
			if not lines:
				continue
			pay = self.st["payables"].get(p["pi"])
			standalone = bool(pay and pay["paid_on"] and pay["paid_on"] <= self._d.isoformat())
			self._emit("purchase_return", {"pr": p["pr"], "pi": p["pi"], "lines": lines, "reason": p["reason"],
				"standalone": standalone})
			for c, q in lines.items():
				self._add_stock("DC", c, -q)
			if standalone:
				sup = pay["supplier"]
				self.st["supplier_credits"][sup] = self.st["supplier_credits"].get(sup, 0) + 1

	def _transfers(self) -> None:
		d = self._d
		if d.weekday() == self.policy["transfer_weekday"]:
			for b in ("CLE", "CIN"):
				lines = {}
				for it in self.s.items:
					target = self.st["ema"][b].get(it.code, 0.0) * self.policy["branch_cover_days"]
					need = target + self._backorder(b, it.code) - self._stock(b, it.code)
					avail = self._stock("DC", it.code) - self._backorder("DC", it.code)
					q = int(min(math.ceil(need), avail))
					if q >= 1:
						lines[it.code] = q
						self._add_stock("DC", it.code, -q)
						self._add_stock(b, it.code, q)
				if lines:
					self._emit("stock_transfer", {"from": "DC", "to": b, "lines": lines, "purpose": "branch replenishment"})
		if d.weekday() == self.policy["returns_restock_weekday"]:
			lines = {c: q for c, q in sorted(self.st["stock"]["RTN"].items()) if q > 0}
			if lines:
				self._emit("stock_transfer", {"from": "RTN", "to": "DC", "lines": lines, "purpose": "returns inspected and restocked"})
				for c, q in lines.items():
					self._add_stock("RTN", c, -q)
					self._add_stock("DC", c, q)

	def _deliveries(self, rng: Rng) -> None:
		today = self._d.isoformat()
		minute = 0
		for so_key in sorted(self.st["open_sos"]):
			so = self.st["open_sos"][so_key]
			if so["from"] > today:
				continue
			lines = {}
			for c in sorted(so["lines"]):
				qty, delivered = so["lines"][c]
				q = min(qty - delivered, self._stock(so["warehouse"], c))
				if q > 0:
					lines[c] = q
			if not lines:
				continue
			t = f"{9 + (30 + minute) // 60:02d}:{(30 + minute) % 60:02d}:00"
			minute = min(minute + 2, 150)
			dn_key = self._emit("delivery_note", {"so": so_key, "lines": lines}, time=t)
			for c, q in lines.items():
				self._add_stock(so["warehouse"], c, -q)
				so["lines"][c][1] += q
			t2 = t[:6] + "30"
			si_key = self._emit("sales_invoice", {"dn": dn_key}, time=t2)
			self._after_invoice(rng, so["customer"], dn_key, si_key, lines)
			if all(l[1] >= l[0] for l in so["lines"].values()):
				del self.st["open_sos"][so_key]

	def _after_invoice(self, rng: Rng, customer: str, dn_key: str, si_key: str, lines: dict) -> None:
		c = self.s.customer(customer)
		d = self._d
		inv = {"customer": customer, "paid_on": None, "lines": dict(lines), "returned": {}}
		if not c.advance_payer:
			due = d + timedelta(days=c.terms_days)
			if rng.chance(c.on_time):
				pay = due - timedelta(days=rng.randint(0, 5))
			else:
				pay = due + timedelta(days=max(1, round(rng.exponential(c.late_days))))
			pay = cal.on_or_after(max(pay, cal.next_business_day(d)))
			if c.batch_payer:
				while pay.weekday() != 2 or not cal.is_business_day(pay):
					pay += timedelta(days=1)
				self._schedule(pay, "payment_intent", {"customer": customer, "si": si_key, "mode": "full", "batch": True})
			elif c.terms_days >= 30 and rng.chance(c.installments):
				first = cal.on_or_after(max(pay - timedelta(days=14), cal.next_business_day(d)))
				if first < pay:
					self._schedule(first, "payment_intent", {"customer": customer, "si": si_key, "mode": "half", "batch": False})
				self._schedule(pay, "payment_intent", {"customer": customer, "si": si_key, "mode": "full", "batch": False})
			else:
				self._schedule(pay, "payment_intent", {"customer": customer, "si": si_key, "mode": "full", "batch": False})
			inv["paid_on"] = pay.isoformat()
		self.st["invoices"][si_key] = inv
		rate = self.s.segments[c.segment]["return_rate"]
		for code, q in sorted(lines.items()):
			if rng.chance(rate * 0.8):
				when = cal.next_business_day(d, rng.randint(3, 20))
				rq = max(1, round(q * rng.uniform(0.1, 0.6)))
				self._schedule(when, "sales_return", {"dn": dn_key, "si": si_key, "customer": customer, "lines": {code: rq},
					"reason": rng.choice(self.s.catalog["return_reasons"])})
				break  # at most one returned line per invoice

	def _sales_orders(self, rng: Rng) -> dict:
		ordered: dict[str, dict[str, int]] = {w: {} for w in SELLING_WAREHOUSES}
		orders = _draw_orders(self.s, rng, self._d)
		times = sorted(rng.randint(9 * 60 + 40, 16 * 60 + 30) for _ in orders)
		deliver_from = cal.next_business_day(self._d).isoformat()
		for o, minute in zip(orders, times, strict=True):
			self.st["counters"]["po_no"] += 1
			c = self.s.customer(o["customer"])
			remarks = rng.choice(self.s.catalog["shipping_instructions"]) if rng.chance(0.35) else ""
			key = self._emit("sales_order", {"customer": o["customer"], "warehouse": o["warehouse"],
				"delivery_date": deliver_from, "lines": [[code, q] for code, q in o["lines"]],
				"po_no": f"PO-{c.name.split()[0][:4].upper()}-{self.st['counters']['po_no']:05d}", "remarks": remarks},
				time=f"{minute // 60:02d}:{minute % 60:02d}:00")
			self.st["open_sos"][key] = {"customer": o["customer"], "warehouse": o["warehouse"], "from": deliver_from,
				"lines": {code: [q, 0] for code, q in o["lines"]}}
			for code, q in o["lines"]:
				ordered[o["warehouse"]][code] = ordered[o["warehouse"]].get(code, 0) + q
		return ordered

	def _customer_payments(self) -> None:
		intents = self._due("payment_intent")
		batches: dict[str, list[str]] = {}
		for p in intents:
			inv = self.st["invoices"].get(p["si"])
			if inv is None or inv.get("settled"):
				continue  # fully credited before payment
			if p["batch"]:
				batches.setdefault(p["customer"], []).append(p["si"])
			else:
				self._emit_payment(p["customer"], [p["si"]], p["mode"])
		for customer in sorted(batches):
			self._emit_payment(customer, sorted(batches[customer]), "full")

	def _emit_payment(self, customer: str, invoices: list[str], mode: str) -> None:
		self.st["counters"]["check"] += 1
		self._emit("customer_payment", {"customer": customer, "invoices": invoices, "mode": mode,
			"reference_no": f"CHK-{self.st['counters']['check']:06d}"})

	def _prune(self) -> None:
		"""Bound the state: forget invoices older than 45 days that are paid or settled (returns are planned
		at most 20 business days after an invoice; unpaid invoices are kept for their scheduled payments)."""
		cutoff = (self._d - timedelta(days=45)).isoformat()
		today = self._d.isoformat()
		for k in [k for k, v in self.st["invoices"].items()
				if k[:10] < cutoff and (v.get("settled") or v["paid_on"] is None or v["paid_on"] <= today)]:
			del self.st["invoices"][k]

	def _sales_returns(self) -> None:
		for p in self._due("sales_return"):
			inv = self.st["invoices"].get(p["si"])
			if inv is None:
				continue
			c = self.s.customer(p["customer"])
			lines = {}
			for code, q in p["lines"].items():
				left = inv["lines"].get(code, 0) - inv["returned"].get(code, 0)
				if min(q, left) > 0:
					lines[code] = min(q, left)
			if not lines:
				continue
			paid = inv["paid_on"] is not None and inv["paid_on"] <= self._d.isoformat()
			standalone = c.advance_payer or paid
			self._emit("sales_return", {"dn": p["dn"], "si": p["si"], "customer": p["customer"], "lines": lines,
				"reason": p["reason"], "standalone": standalone, "return_warehouse": "RTN"})
			for code, q in lines.items():
				inv["returned"][code] = inv["returned"].get(code, 0) + q
				self._add_stock("RTN", code, q)
			if standalone:
				self.st["credits"][p["customer"]] = self.st["credits"].get(p["customer"], 0) + 1
			elif all(inv["returned"].get(k, 0) >= v for k, v in inv["lines"].items()):
				inv["settled"] = True  # credit note covers the whole invoice; scheduled payments are dropped
				self.st["pending"] = [x for x in self.st["pending"] if not (x[2] == "payment_intent" and x[4]["si"] == p["si"])]

	def _advances_and_settlement(self) -> None:
		d = self._d
		first = cal.month_day(d.year, d.month, 1) == d
		last = cal.is_last_business_day_of_month(d)
		for c in self.s.customers:
			if not c.advance_payer:
				continue
			if first:
				self.st["counters"]["check"] += 1
				self._emit("customer_advance", {"customer": c.name, "amount": c.advance_amount,
					"reference_no": f"WIRE-{self.st['counters']['check']:06d}"})
			if last:
				self._emit("reconcile", {"party_type": "Customer", "party": c.name}, time="16:15:00")
				self.st["counters"]["check"] += 1
				self._emit("month_end_settlement", {"customer": c.name, "reference_no": f"WIRE-{self.st['counters']['check']:06d}"})
				self.st["credits"].pop(c.name, None)

	def _supplier_payments(self) -> None:
		d = self._d
		if d.weekday() != self.policy["supplier_payment_weekday"]:
			return
		horizon = (d + timedelta(days=7)).isoformat()
		for pi_key in sorted(self.st["payables"]):
			p = self.st["payables"][pi_key]
			if p["paid_on"] is None and p["due"] <= horizon:
				self.st["counters"]["check"] += 1
				self._emit("supplier_payment", {"pi": pi_key, "reference_no": f"ACH-{self.st['counters']['check']:06d}"})
				p["paid_on"] = d.isoformat()
		cutoff = (d - timedelta(days=60)).isoformat()
		for pi_key in [k for k, p in self.st["payables"].items() if p["paid_on"] and p["paid_on"] < cutoff]:
			del self.st["payables"][pi_key]

	def _reconciliations(self) -> None:
		d = self._d
		if d.weekday() != 4:
			return
		today = d.isoformat()
		month_end = cal.is_last_business_day_of_month(d)
		for customer in sorted(self.st["credits"]):
			if self.s.customer(customer).advance_payer:
				continue  # reconciled weekly and at month end below
			open_inv = [k for k, v in self.st["invoices"].items() if v["customer"] == customer and not v.get("settled")
				and (v["paid_on"] is None or v["paid_on"] > today)]
			if open_inv:
				self._emit("reconcile", {"party_type": "Customer", "party": customer})
				del self.st["credits"][customer]
		for supplier in sorted(self.st["supplier_credits"]):
			if any(p["supplier"] == supplier and p["paid_on"] is None for p in self.st["payables"].values()):
				self._emit("reconcile", {"party_type": "Supplier", "party": supplier})
				del self.st["supplier_credits"][supplier]
		for c in self.s.customers:
			if month_end:
				break  # the month-end reconciliation covers advance payers today
			if c.advance_payer and any(v["customer"] == c.name and not v.get("settled") for v in self.st["invoices"].values()):
				self._emit("reconcile", {"party_type": "Customer", "party": c.name})

	def _expenses(self, rng: Rng) -> None:
		d = self._d
		for e in self.s.catalog["expenses"]:
			if cal.month_day(d.year, d.month, e["day"]) != d:
				continue
			amount = e["monthly"] * (1 + e["jitter"] * rng.normal(0, 1))
			if e["account"] == "Salary":
				amount *= 1.03 ** ((d - self.s.start).days / 365.25)
			self._emit("expense", {"name": e["name"], "account": e["account"], "amount": round(max(amount, 1.0), 2)})

	def _purchasing(self, rng: Rng) -> None:
		d = self._d
		years = (d - self.s.start).days / 365.25
		for sup in self.s.suppliers:
			if d.weekday() != sup["review_weekday"]:
				continue
			lead_avg = sum(sup["lead_days"]) / 2
			lines = []
			for it in self.supplier_items[sup["name"]]:
				daily = sum(self.st["ema"][w].get(it.code, 0.0) for w in SELLING_WAREHOUSES)
				if daily <= 0:
					continue
				position = sum(self._stock(w, it.code) for w in SELLING_WAREHOUSES) + self._on_order(it.code) \
					- sum(self._backorder(w, it.code) for w in SELLING_WAREHOUSES)
				rop = daily * (lead_avg + 5 + self.policy["dc_safety_days"])
				if position >= rop:
					continue
				target = daily * (lead_avg + 5 + self.policy["dc_cover_days"])
				qty = int(math.ceil((target - position) / it.pack) * it.pack)
				if qty <= 0:
					continue
				rate = round(it.cost * (1 + self.policy["purchase_price_inflation_per_year"]) ** years * rng.uniform(0.98, 1.02), 2)
				lines.append([it.code, qty, rate])
			if not lines:
				continue
			lead = rng.randint(*sup["lead_days"])
			arrive = cal.next_business_day(d, lead)
			arrivals: list[list] = []
			if rng.chance(1 - sup["fill_rate"]) or rng.chance(0.12):
				first: dict[str, int] = {}
				rest: dict[str, int] = {}
				for code, q, _ in lines:
					got = q if rng.chance(sup["fill_rate"]) else int(q * rng.uniform(0.4, 0.9))
					first[code] = got
					if q - got > 0:
						rest[code] = q - got
				arrivals.append([arrive.isoformat(), first])
				if rest:
					arrivals.append([cal.next_business_day(arrive, rng.randint(3, 8)).isoformat(), rest])
			else:
				arrivals.append([arrive.isoformat(), {code: q for code, q, _ in lines}])
			key = self._emit("purchase_order", {"supplier": sup["name"], "warehouse": "DC", "schedule_date": arrive.isoformat(),
				"lines": lines, "remarks": rng.choice(self.s.catalog["purchase_notes"])})
			self.st["open_pos"][key] = {"supplier": sup["name"], "warehouse": "DC", "arrivals": arrivals,
				"lines": {code: [q, 0] for code, q, _ in lines}}

	def _cycle_count(self, rng: Rng) -> None:
		if not cal.is_last_business_day_of_month(self._d):
			return
		candidates = [it for it in self.s.items if self._stock("DC", it.code) - self._backorder("DC", it.code) >= 20]
		lines, before = {}, {}
		for it in rng.sample(candidates, 6):
			on_hand = self._stock("DC", it.code)
			if rng.chance(0.7):
				shrink = max(1, round(on_hand * self.policy["shrinkage_rate"] * rng.uniform(0.5, 2.5)))
				lines[it.code] = on_hand - shrink
				before[it.code] = on_hand
		if lines:
			lines = dict(sorted(lines.items()))
			# `before` lets the executor confirm the ERP's stock equals the projection before posting the count.
			self._emit("stock_count", {"warehouse": "DC", "lines": lines, "before": dict(sorted(before.items()))})
			for code, counted in lines.items():
				self._add_stock("DC", code, counted - self._stock("DC", code))

	def _update_ema(self, ordered: dict) -> None:
		for w in SELLING_WAREHOUSES:
			ema = self.st["ema"][w]
			for it in self.s.items:
				v = ema.get(it.code, 0.0) * (1 - EMA_ALPHA) + EMA_ALPHA * ordered[w].get(it.code, 0)
				ema[it.code] = round(v, 6)


def plan_range(planner: Planner, state: dict, start: date, end: date) -> tuple[list[Event], dict]:
	events: list[Event] = []
	d = start
	while d <= end:
		day_events, state = planner.plan_day(state, d)
		events.extend(day_events)
		d += timedelta(days=1)
	return events, state


def events_hash(events: list[Event]) -> str:
	h = hashlib.sha256()
	for e in events:
		h.update(json.dumps(e.to_dict(), sort_keys=True, separators=(",", ":")).encode())
	return h.hexdigest()


def state_dumps(state: dict) -> str:
	return json.dumps(state, sort_keys=True, separators=(",", ":"))


def state_loads(text: str) -> dict:
	return json.loads(text)
