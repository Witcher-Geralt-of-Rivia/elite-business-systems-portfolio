"""Turns planned events into ERPNext documents (Frappe runtime).

Every document is created the way a user would create it: from ERPNext's own mappers
(`make_purchase_receipt`, `make_delivery_note`, `make_sales_invoice`, `make_sales_return`, `make_debit_note`,
`get_payment_entry`) or as a new document, then `insert()` and `submit()` with ERPNext's validation, taxes,
valuation and ledger posting. Nothing is written to ledgers directly. Back-dated history uses ERPNext's own
`set_posting_time` mechanism; events are executed in chronological order, so no later postings exist when a
document is submitted.

`run(event)` returns what to record in the ledger; the simulator writes that ledger row in the same database
transaction as the documents (idempotency).
"""

from __future__ import annotations

from datetime import timedelta

import frappe
from frappe.utils import flt, getdate

from ..engine.scenario import Scenario
from ..upstream_refs import resolve
from .docs import account, append_row, fill, new_doc, submit


class Divergence(Exception):
	"""The ERP's state differs from the planner's projection (stops the simulation for investigation)."""


class Executor:
	def __init__(self, scenario: Scenario):
		self.s = scenario
		c = scenario.company
		self.abbr = c["abbr"]
		self.company = c["name"]
		self.wh = {w["key"]: account(w["name"], self.abbr) for w in scenario.warehouses}
		self.bank = account(c["bank_account"], self.abbr)
		self.debtors = account("Debtors", self.abbr)
		self.creditors = account("Creditors", self.abbr)
		self.tax_account = account(c["tax_account"], self.abbr)
		self.tax_template = f"{scenario.catalog['tax']['template']} - {self.abbr}"
		self.cost_center = frappe.get_cached_value("Company", self.company, "cost_center")

	# ------------------------------------------------------------------ helpers
	def run(self, ev: dict) -> dict:
		handler = getattr(self, f"_{ev['kind']}")
		return handler(ev["payload"], getdate(ev["date"]), ev["time"])

	def ref(self, key: str, second: bool = False) -> str:
		row = frappe.db.get_value("Distribution Sim Event", key,
			["reference_name", "second_name", "outcome"], as_dict=True)
		if not row:
			raise Divergence(f"event {key} has not been executed")
		return row.second_name if second else row.reference_name

	@staticmethod
	def _done(doc, second=None, **details) -> dict:
		return {"outcome": "Done", "reference_doctype": doc.doctype, "reference_name": doc.name,
			"second_doctype": second.doctype if second else None, "second_name": second.name if second else None,
			"details": details}

	@staticmethod
	def _nothing(**details) -> dict:
		return {"outcome": "Nothing Due", "reference_doctype": None, "reference_name": None,
			"second_doctype": None, "second_name": None, "details": details}

	def _keep_rows(self, doc, table: str, wanted: dict, sign: int = 1) -> None:
		"""Keep only rows for wanted item codes and set their quantities (sign -1 for returns)."""
		kept = []
		remaining = dict(wanted)
		for row in doc.get(table):
			q = remaining.get(row.item_code, 0)
			if q <= 0:
				continue
			take = min(q, abs(flt(row.qty)))
			row.qty = sign * take
			if hasattr(row, "received_qty") and row.doctype == "Purchase Receipt Item":
				row.received_qty = sign * take
				row.rejected_qty = 0
			remaining[row.item_code] = q - take
			kept.append(row)
		missing = {k: v for k, v in remaining.items() if v > 0}
		if missing:
			raise Divergence(f"{doc.doctype}: quantities not available from the source document: {missing}")
		doc.set(table, kept)

	# ------------------------------------------------------------------ opening
	def _opening_capital(self, p: dict, d, t) -> dict:
		je = new_doc("Journal Entry", {"voucher_type": "Journal Entry", "company": self.company, "posting_date": d,
			"user_remark": "Owners' capital contribution at the start of the simulated period", "accounts": [
				{"account": self.bank, "debit_in_account_currency": p["amount"], "cost_center": self.cost_center},
				{"account": account("Capital Stock", self.abbr), "credit_in_account_currency": p["amount"], "cost_center": self.cost_center}]})
		return self._done(submit(je), amount=p["amount"])

	def _opening_stock(self, p: dict, d, t) -> dict:
		items = [{"item_code": code, "warehouse": self.wh[p["warehouse"]], "qty": qty, "valuation_rate": self.s.item(code).cost}
			for code, qty in p["lines"].items()]
		sr = new_doc("Stock Reconciliation", {"company": self.company, "purpose": "Opening Stock", "posting_date": d,
			"posting_time": t, "set_posting_time": 1, "expense_account": account("Temporary Opening", self.abbr),
			"cost_center": self.cost_center, "items": items})
		return self._done(submit(sr), lines=len(items))

	def _opening_clearing(self, p: dict, d, t) -> dict:
		temp = account("Temporary Opening", self.abbr)
		balance = flt(frappe.db.sql("""select sum(credit) - sum(debit) from `tabGL Entry`
			where account = %s and company = %s and is_cancelled = 0""", (temp, self.company))[0][0])
		if abs(balance) < 0.005:
			return self._nothing(reason="temporary opening already cleared")
		je = new_doc("Journal Entry", {"voucher_type": "Opening Entry", "company": self.company, "posting_date": d,
			"is_opening": "Yes", "user_remark": "Opening stock value transferred to opening balance equity", "accounts": [
				{"account": temp, "debit_in_account_currency": balance, "cost_center": self.cost_center},
				{"account": account("Opening Balance Equity", self.abbr), "credit_in_account_currency": balance, "cost_center": self.cost_center}]})
		return self._done(submit(je), amount=balance)

	# ------------------------------------------------------------------ purchasing
	def _purchase_order(self, p: dict, d, t) -> dict:
		po = new_doc("Purchase Order", {"supplier": p["supplier"], "company": self.company, "transaction_date": d,
			"schedule_date": p["schedule_date"], "set_warehouse": self.wh[p["warehouse"]], "buying_price_list": "Standard Buying",
			"items": [{"item_code": code, "qty": qty, "rate": rate, "schedule_date": p["schedule_date"],
				"warehouse": self.wh[p["warehouse"]]} for code, qty, rate in p["lines"]]})
		submit(po)
		po.add_comment("Comment", p.get("remarks") or "")
		return self._done(po, lines=len(p["lines"]))

	def _purchase_receipt(self, p: dict, d, t) -> dict:
		pr = resolve("make_purchase_receipt")(self.ref(p["po"]))
		self._keep_rows(pr, "items", p["lines"])
		fill("Purchase Receipt", pr, {"posting_date": d, "posting_time": t, "set_posting_time": 1})
		return self._done(submit(pr), lines=p["lines"])

	def _terms_days(self, terms: str) -> int:
		return next(x["days"] for x in self.s.catalog["payment_terms"] if x["name"] == terms)

	def _purchase_invoice(self, p: dict, d, t) -> dict:
		pi = resolve("make_purchase_invoice_from_receipt")(self.ref(p["pr"]))
		# Mappers compute the due date from today's date; back-dated documents need it from their posting date
		# (CI: "Due Date cannot be after ...").
		due = d + timedelta(days=self._terms_days(self.s.supplier(pi.supplier)["terms"]))
		fill("Purchase Invoice", pi, {"posting_date": d, "posting_time": t, "set_posting_time": 1, "bill_no": p["bill_no"],
			"bill_date": p["bill_date"], "due_date": due, "payment_schedule": []})
		return self._done(submit(pi), bill_no=p["bill_no"])

	def _purchase_return(self, p: dict, d, t) -> dict:
		ret = resolve("make_purchase_return")(self.ref(p["pr"]))
		self._keep_rows(ret, "items", p["lines"], sign=-1)
		fill("Purchase Receipt", ret, {"posting_date": d, "posting_time": t, "set_posting_time": 1})
		submit(ret)
		debit = resolve("make_debit_note")(self.ref(p["pi"]))
		self._keep_rows(debit, "items", p["lines"], sign=-1)
		fill("Purchase Invoice", debit, {"posting_date": d, "posting_time": t, "set_posting_time": 1, "due_date": d,
			"payment_schedule": [],
			"update_outstanding_for_self": 1 if p["standalone"] else 0, "remarks": p["reason"]})
		return self._done(ret, submit(debit), reason=p["reason"], standalone=p["standalone"])

	def _supplier_payment(self, p: dict, d, t) -> dict:
		pi = self.ref(p["pi"])
		if flt(frappe.db.get_value("Purchase Invoice", pi, "outstanding_amount")) <= 0:
			return self._nothing(invoice=pi)
		pe = resolve("get_payment_entry")("Purchase Invoice", pi)
		fill("Payment Entry", pe, {"posting_date": d, "reference_no": p["reference_no"], "reference_date": d,
			"mode_of_payment": "Wire Transfer"})
		return self._done(submit(pe), invoice=pi)

	# ------------------------------------------------------------------ selling
	def _sales_order(self, p: dict, d, t) -> dict:
		cu = self.s.customer(p["customer"])
		wh = self.wh[p["warehouse"]]
		so = submit(new_doc("Sales Order", {"customer": cu.name, "company": self.company, "transaction_date": d,
			"delivery_date": p["delivery_date"], "set_warehouse": wh, "po_no": p["po_no"], "po_date": d,
			"selling_price_list": "Standard Selling",
			"taxes_and_charges": self.tax_template if cu.taxable else "",
			"taxes": [{"charge_type": "On Net Total", "account_head": self.tax_account, "rate": self.s.catalog["tax"]["rate"],
				"description": self.s.catalog["tax"]["description"]}] if cu.taxable else [],
			"items": [{"item_code": code, "qty": qty, "delivery_date": p["delivery_date"], "warehouse": wh,
				"discount_percentage": cu.discount} for code, qty in p["lines"]]}))
		if p.get("remarks"):
			so.add_comment("Comment", p["remarks"])
		return self._done(so, lines=len(p["lines"]))

	def _delivery_note(self, p: dict, d, t) -> dict:
		dn = resolve("make_delivery_note")(self.ref(p["so"]))
		self._keep_rows(dn, "items", p["lines"])
		fill("Delivery Note", dn, {"posting_date": d, "posting_time": t, "set_posting_time": 1})
		return self._done(submit(dn), lines=p["lines"])

	def _sales_invoice(self, p: dict, d, t) -> dict:
		si = resolve("make_sales_invoice_from_delivery")(self.ref(p["dn"]))
		due = d + timedelta(days=self.s.customer(si.customer).terms_days)
		fill("Sales Invoice", si, {"posting_date": d, "posting_time": t, "set_posting_time": 1, "due_date": due,
			"payment_schedule": []})
		return self._done(submit(si))

	def _pay_invoices(self, customer: str, invoices: list[str], d, reference_no: str, mode_of_payment: str,
			fraction: float = 1.0) -> dict:
		due = []
		for name in invoices:
			out = flt(frappe.db.get_value("Sales Invoice", name, "outstanding_amount"))
			if out > 0:
				due.append((name, round(out * fraction, 2) if fraction < 1 else out))
		if not due:
			return self._nothing(invoices=invoices)
		total = round(sum(a for _, a in due), 2)
		pe = resolve("get_payment_entry")("Sales Invoice", due[0][0], party_amount=due[0][1])
		for name, amount in due[1:]:
			append_row("Payment Entry", pe, "references", {"reference_doctype": "Sales Invoice", "reference_name": name,
				"allocated_amount": amount})
		fill("Payment Entry", pe, {"posting_date": d, "reference_no": reference_no, "reference_date": d,
			"mode_of_payment": mode_of_payment, "paid_amount": total, "received_amount": total})
		return self._done(submit(pe), invoices=[n for n, _ in due], amount=total)

	def _customer_payment(self, p: dict, d, t) -> dict:
		names = [self.ref(k) for k in p["invoices"]]
		return self._pay_invoices(p["customer"], names, d, p["reference_no"], "Check", 0.5 if p["mode"] == "half" else 1.0)

	def _customer_advance(self, p: dict, d, t) -> dict:
		pe = new_doc("Payment Entry", {"payment_type": "Receive", "company": self.company, "party_type": "Customer",
			"party": p["customer"], "posting_date": d, "paid_from": self.debtors, "paid_to": self.bank,
			"paid_amount": p["amount"], "received_amount": p["amount"], "source_exchange_rate": 1, "target_exchange_rate": 1,
			"reference_no": p["reference_no"], "reference_date": d, "mode_of_payment": "Wire Transfer"})
		return self._done(submit(pe), amount=p["amount"])

	def _month_end_settlement(self, p: dict, d, t) -> dict:
		names = frappe.get_all("Sales Invoice", filters={"customer": p["customer"], "company": self.company, "docstatus": 1,
			"outstanding_amount": [">", 0], "posting_date": ["<=", d]}, order_by="posting_date asc, name asc", pluck="name")
		return self._pay_invoices(p["customer"], names, d, p["reference_no"], "Wire Transfer")

	def _sales_return(self, p: dict, d, t) -> dict:
		ret = resolve("make_sales_return_from_delivery")(self.ref(p["dn"]))
		self._keep_rows(ret, "items", p["lines"], sign=-1)
		for row in ret.items:
			fill("Delivery Note Item", row, {"warehouse": self.wh[p["return_warehouse"]]})
		fill("Delivery Note", ret, {"posting_date": d, "posting_time": t, "set_posting_time": 1, "set_warehouse": self.wh[p["return_warehouse"]]})
		submit(ret)
		cn = resolve("make_credit_note")(self.ref(p["si"]))
		self._keep_rows(cn, "items", p["lines"], sign=-1)
		fill("Sales Invoice", cn, {"posting_date": d, "posting_time": t, "set_posting_time": 1, "due_date": d, "update_stock": 0,
			"payment_schedule": [], "update_outstanding_for_self": 1 if p["standalone"] else 0, "remarks": p["reason"]})
		return self._done(ret, submit(cn), reason=p["reason"], standalone=p["standalone"])

	def _reconcile(self, p: dict, d, t) -> dict:
		pr = frappe.get_doc("Payment Reconciliation")
		fill("Payment Reconciliation", pr, {"company": self.company, "party_type": p["party_type"], "party": p["party"],
			"receivable_payable_account": self.debtors if p["party_type"] == "Customer" else self.creditors,
			"to_invoice_date": d, "to_payment_date": d})
		pr.get_unreconciled_entries()
		if not pr.payments or not pr.invoices:
			return self._nothing(party=p["party"], payments=len(pr.payments), invoices=len(pr.invoices))
		pr.allocate_entries(frappe._dict({"payments": [x.as_dict() for x in pr.payments],
			"invoices": [x.as_dict() for x in pr.invoices]}))
		allocations = len(pr.allocation)
		pr.reconcile()
		return {"outcome": "Done", "reference_doctype": None, "reference_name": None, "second_doctype": None,
			"second_name": None, "details": {"party": p["party"], "allocations": allocations}}

	# ------------------------------------------------------------------ stock and expenses
	def _stock_transfer(self, p: dict, d, t) -> dict:
		se = new_doc("Stock Entry", {"stock_entry_type": "Material Transfer", "purpose": "Material Transfer", "company": self.company,
			"posting_date": d, "posting_time": t, "set_posting_time": 1, "remarks": p["purpose"],
			"items": [{"item_code": code, "qty": qty, "s_warehouse": self.wh[p["from"]], "t_warehouse": self.wh[p["to"]]}
				for code, qty in sorted(p["lines"].items())]})
		return self._done(submit(se), lines=len(p["lines"]))

	def _stock_count(self, p: dict, d, t) -> dict:
		wh = self.wh[p["warehouse"]]
		items = []
		for code, counted in p["lines"].items():
			qty, rate = resolve("get_stock_balance")(code, wh, d, t, with_valuation_rate=True)[:2]
			if "before" in p and flt(qty) != p["before"][code]:
				raise Divergence(f"{code} in {wh}: ERP has {qty}, the plan expects {p['before'][code]} before the count")
			items.append({"item_code": code, "warehouse": wh, "qty": counted, "valuation_rate": rate})
		sr = new_doc("Stock Reconciliation", {"company": self.company, "purpose": "Stock Reconciliation", "posting_date": d,
			"posting_time": t, "set_posting_time": 1, "expense_account": account("Stock Adjustment", self.abbr),
			"cost_center": self.cost_center, "items": items})
		return self._done(submit(sr), lines=len(items))

	def _expense(self, p: dict, d, t) -> dict:
		je = new_doc("Journal Entry", {"voucher_type": "Bank Entry", "company": self.company, "posting_date": d,
			"cheque_no": f"{p['name'][:20]} {d.isoformat()}", "cheque_date": d, "user_remark": p["name"], "accounts": [
				{"account": account(p["account"], self.abbr), "debit_in_account_currency": p["amount"], "cost_center": self.cost_center},
				{"account": self.bank, "credit_in_account_currency": p["amount"], "cost_center": self.cost_center}]})
		return self._done(submit(je), amount=p["amount"])
