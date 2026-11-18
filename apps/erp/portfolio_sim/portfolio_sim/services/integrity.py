"""Read-only integrity checks for the simulated ERP data (Frappe runtime). Every check must return 0.

Columns used here are listed in `upstream_refs.SQL_COLUMNS` and verified against the pinned DocType definitions.
Payment Ledger Entry amounts are normalised by ERPNext (receivable: debit - credit; payable: credit - debit), so
an invoice's outstanding amount equals the sum of its non-delinked ledger amounts for both customers and suppliers
(erpnext/accounts/utils.py `get_payment_ledger_entries`).
"""

from __future__ import annotations

import json
import time
from collections import defaultdict

import frappe
from frappe.utils import flt, getdate

from ..engine.planner import state_loads

CHECKS: dict[str, str] = {
	# General ledger
	"gl_voucher_unbalanced": """select count(*) from (select voucher_type, voucher_no from `tabGL Entry`
		where is_cancelled = 0 and company = %(company)s group by voucher_type, voucher_no
		having abs(sum(debit) - sum(credit)) > 0.005) x""",
	"gl_total_unbalanced": """select count(*) from (select sum(debit) - sum(credit) d from `tabGL Entry`
		where is_cancelled = 0 and company = %(company)s) x where abs(d) > 0.01""",
	"gl_after_processed_point": """select count(*) from `tabGL Entry` where is_cancelled = 0 and company = %(company)s
		and posting_date > %(processed_date)s""",
	"gl_on_weekend": """select count(*) from `tabGL Entry` where is_cancelled = 0 and company = %(company)s
		and dayofweek(posting_date) in (1, 7)""",
	"bank_balance_negative_days": """select count(*) from (select posting_date, sum(sum(debit) - sum(credit))
		over (order by posting_date) bal from `tabGL Entry` where is_cancelled = 0 and company = %(company)s
		and account = %(bank)s group by posting_date) x where bal < -0.005""",
	# Receivables / payables
	"sales_invoice_outstanding_vs_ledger": """select count(*) from `tabSales Invoice` si left join (
		select against_voucher_no, sum(amount) amt from `tabPayment Ledger Entry` where delinked = 0
		and company = %(company)s and against_voucher_type = 'Sales Invoice' group by against_voucher_no) p
		on p.against_voucher_no = si.name where si.docstatus = 1 and si.company = %(company)s
		and abs(si.outstanding_amount - ifnull(p.amt, 0)) > 0.01""",
	"purchase_invoice_outstanding_vs_ledger": """select count(*) from `tabPurchase Invoice` pi left join (
		select against_voucher_no, sum(amount) amt from `tabPayment Ledger Entry` where delinked = 0
		and company = %(company)s and against_voucher_type = 'Purchase Invoice' group by against_voucher_no) p
		on p.against_voucher_no = pi.name where pi.docstatus = 1 and pi.company = %(company)s
		and abs(pi.outstanding_amount - ifnull(p.amt, 0)) > 0.01""",
	"receivable_gl_vs_ledger": """select count(*) from (select
		(select ifnull(sum(debit) - sum(credit), 0) from `tabGL Entry` where is_cancelled = 0 and company = %(company)s
			and account = %(debtors)s) gl,
		(select ifnull(sum(amount), 0) from `tabPayment Ledger Entry` where delinked = 0 and company = %(company)s
			and account = %(debtors)s) ple) x where abs(gl - ple) > 0.01""",
	"payable_gl_vs_ledger": """select count(*) from (select
		(select ifnull(sum(credit) - sum(debit), 0) from `tabGL Entry` where is_cancelled = 0 and company = %(company)s
			and account = %(creditors)s) gl,
		(select ifnull(sum(amount), 0) from `tabPayment Ledger Entry` where delinked = 0 and company = %(company)s
			and account = %(creditors)s) ple) x where abs(gl - ple) > 0.01""",
	"sales_tax_mismatch": """select count(*) from `tabSales Invoice` where docstatus = 1 and company = %(company)s
		and ifnull(taxes_and_charges, '') != '' and abs(total_taxes_and_charges - round(net_total * %(tax_rate)s / 100, 2)) > 0.02""",
	"untaxed_invoice_for_taxable_customer": """select count(*) from `tabSales Invoice` where docstatus = 1 and company = %(company)s
		and is_return = 0 and customer in %(taxable_customers)s and ifnull(taxes_and_charges, '') = ''""",
	# Inventory
	"bin_vs_stock_ledger": """select count(*) from `tabBin` b join `tabWarehouse` w on w.name = b.warehouse and w.company = %(company)s
		left join (select item_code, warehouse, sum(actual_qty) q from `tabStock Ledger Entry` where is_cancelled = 0
		group by item_code, warehouse) s on s.item_code = b.item_code and s.warehouse = b.warehouse
		where abs(b.actual_qty - ifnull(s.q, 0)) > 0.0001""",
	"negative_stock": """select count(*) from `tabStock Ledger Entry` where is_cancelled = 0 and company = %(company)s
		and qty_after_transaction < -0.0001""",
	"stock_value_vs_gl": """select count(*) from (select
		(select ifnull(sum(stock_value_difference), 0) from `tabStock Ledger Entry` where is_cancelled = 0 and company = %(company)s) sle,
		(select ifnull(sum(g.debit) - sum(g.credit), 0) from `tabGL Entry` g join `tabAccount` a on a.name = g.account
			where g.is_cancelled = 0 and g.company = %(company)s and a.account_type = 'Stock') gl) x where abs(sle - gl) > 1.0""",
	# Document relationships
	"sales_order_overdelivered": """select count(*) from `tabSales Order Item` i join `tabSales Order` o on o.name = i.parent
		where o.docstatus = 1 and o.company = %(company)s and i.delivered_qty > i.qty + 0.0001""",
	"purchase_order_overreceived": """select count(*) from `tabPurchase Order Item` i join `tabPurchase Order` o on o.name = i.parent
		where o.docstatus = 1 and o.company = %(company)s and i.received_qty > i.qty + 0.0001""",
	"delivery_without_sales_order": """select count(*) from `tabDelivery Note Item` i join `tabDelivery Note` d on d.name = i.parent
		where d.docstatus = 1 and d.company = %(company)s and d.is_return = 0 and ifnull(i.against_sales_order, '') = ''""",
	"invoice_without_delivery": """select count(*) from `tabSales Invoice Item` i join `tabSales Invoice` s on s.name = i.parent
		where s.docstatus = 1 and s.company = %(company)s and s.is_return = 0 and ifnull(i.delivery_note, '') = ''""",
	"receipt_without_purchase_order": """select count(*) from `tabPurchase Receipt Item` i join `tabPurchase Receipt` r on r.name = i.parent
		where r.docstatus = 1 and r.company = %(company)s and r.is_return = 0 and ifnull(i.purchase_order, '') = ''""",
	"bill_without_receipt": """select count(*) from `tabPurchase Invoice Item` i join `tabPurchase Invoice` p on p.name = i.parent
		where p.docstatus = 1 and p.company = %(company)s and p.is_return = 0 and ifnull(i.purchase_receipt, '') = ''""",
	"returns_exceed_delivery": """select count(*) from `tabDelivery Note Item` i join `tabDelivery Note` d on d.name = i.parent
		where d.docstatus = 1 and d.company = %(company)s and d.is_return = 0 and i.returned_qty > i.qty + 0.0001""",
	"returns_exceed_receipt": """select count(*) from `tabPurchase Receipt Item` i join `tabPurchase Receipt` r on r.name = i.parent
		where r.docstatus = 1 and r.company = %(company)s and r.is_return = 0 and i.returned_qty > i.qty + 0.0001""",
	# Chronology
	"delivery_before_order": """select count(*) from `tabDelivery Note Item` i join `tabDelivery Note` d on d.name = i.parent
		join `tabSales Order` o on o.name = i.against_sales_order where d.docstatus = 1 and d.company = %(company)s
		and d.posting_date < o.transaction_date""",
	"receipt_before_order": """select count(*) from `tabPurchase Receipt Item` i join `tabPurchase Receipt` r on r.name = i.parent
		join `tabPurchase Order` o on o.name = i.purchase_order where r.docstatus = 1 and r.company = %(company)s
		and r.posting_date < o.transaction_date""",
	"invoice_before_delivery": """select count(*) from `tabSales Invoice Item` i join `tabSales Invoice` s on s.name = i.parent
		join `tabDelivery Note` d on d.name = i.delivery_note where s.docstatus = 1 and s.company = %(company)s
		and s.posting_date < d.posting_date""",
	"bill_before_receipt": """select count(*) from `tabPurchase Invoice Item` i join `tabPurchase Invoice` p on p.name = i.parent
		join `tabPurchase Receipt` r on r.name = i.purchase_receipt where p.docstatus = 1 and p.company = %(company)s
		and p.posting_date < r.posting_date""",
	"payment_before_invoice": """select count(*) from `tabPayment Entry Reference` r join `tabPayment Entry` e on e.name = r.parent
		left join `tabSales Invoice` s on r.reference_doctype = 'Sales Invoice' and s.name = r.reference_name
		left join `tabPurchase Invoice` p on r.reference_doctype = 'Purchase Invoice' and p.name = r.reference_name
		where e.docstatus = 1 and e.company = %(company)s and e.posting_date < coalesce(s.posting_date, p.posting_date, e.posting_date)""",
	# Simulation ledger
	"ledger_reference_duplicated": """select count(*) from (select reference_doctype, reference_name from `tabDistribution Sim Event`
		where ifnull(reference_name, '') != '' group by reference_doctype, reference_name having count(*) > 1) x""",
	"cancelled_simulated_documents": """select count(*) from `tabGL Entry` where is_cancelled = 1 and company = %(company)s""",
}

# Submitted transaction documents that every simulated event accounts for (system-generated reconciliation
# journals excluded).
TRACKED = ("Sales Order", "Delivery Note", "Sales Invoice", "Purchase Order", "Purchase Receipt", "Purchase Invoice",
	"Payment Entry", "Stock Entry", "Stock Reconciliation", "Journal Entry")


def run(only: list[str] | None = None) -> dict:
	st = frappe.get_single("Distribution Sim Settings")
	if not st.seed or not st.scenario_start:
		# Checks on an empty, un-initialised site would all be 0 and prove nothing.
		frappe.throw("Simulation not set up: run `bench --site <site> portfolio-sim setup` first")
	from .setup import get_scenario

	s = get_scenario(int(st.seed), getdate(st.scenario_start))
	abbr = s.company["abbr"]
	params = {"company": s.company["name"], "bank": f"{s.company['bank_account']} - {abbr}", "debtors": f"Debtors - {abbr}",
		"creditors": f"Creditors - {abbr}", "tax_rate": s.catalog["tax"]["rate"],
		"processed_date": getdate(st.processed_until) if st.processed_until else s.start,
		"taxable_customers": tuple(c.name for c in s.customers if c.taxable) or ("",)}
	results, seconds = {}, {}
	for name, sql in CHECKS.items():
		if only and name not in only:
			continue
		t = time.time()
		results[name] = int(frappe.db.sql(sql, params)[0][0] or 0)
		seconds[name] = round(time.time() - t, 2)
	if not only or "documents_without_ledger" in only:
		results["documents_without_ledger"] = _untracked(params["company"])
	if not only or "ledger_reference_not_submitted" in only:
		results["ledger_reference_not_submitted"] = _ledger_references()
	if not only or "erp_stock_vs_plan" in only:
		results["erp_stock_vs_plan"] = _stock_vs_plan(st, s)
	failing = {k: v for k, v in results.items() if v}
	return {"checks": len(results), "failing": failing or [], "results": results, "seconds": seconds,
		"counts": _counts(params["company"])}


def _untracked(company: str) -> int:
	referenced = set()
	for r in frappe.get_all("Distribution Sim Event", fields=["reference_doctype", "reference_name", "second_doctype", "second_name"],
			limit_page_length=0):
		referenced.add((r.reference_doctype, r.reference_name))
		referenced.add((r.second_doctype, r.second_name))
	missing = 0
	for dt in TRACKED:
		filters = {"docstatus": 1, "company": company}
		if dt == "Journal Entry":
			filters["is_system_generated"] = 0
		for name in frappe.get_all(dt, filters=filters, pluck="name", limit_page_length=0):
			if (dt, name) not in referenced:
				missing += 1
	return missing


def _ledger_references() -> int:
	"""Every document recorded by a 'Done' event exists and is submitted."""
	by_type: dict[str, set] = defaultdict(set)
	for r in frappe.get_all("Distribution Sim Event", filters={"outcome": "Done"},
			fields=["reference_doctype", "reference_name", "second_doctype", "second_name"], limit_page_length=0):
		for dt, dn in ((r.reference_doctype, r.reference_name), (r.second_doctype, r.second_name)):
			if dt and dn:
				by_type[dt].add(dn)
	bad = 0
	for dt, names in by_type.items():
		ok = set(frappe.get_all(dt, filters={"name": ["in", list(names)], "docstatus": 1}, pluck="name", limit_page_length=0))
		bad += len(names - ok)
	return bad


def _stock_vs_plan(st, s) -> int:
	"""After a fully executed day, the ERP's quantities must equal the planner's projection."""
	if json.loads(st.pending_events or "[]") or not st.state_json:
		return 0  # mid-day: the projection is ahead of the ERP by the pending events
	state = state_loads(st.state_json)
	wh = {w["key"]: f"{w['name']} - {s.company['abbr']}" for w in s.warehouses}
	erp = defaultdict(float)
	for r in frappe.get_all("Bin", fields=["item_code", "warehouse", "actual_qty"], limit_page_length=0):
		erp[(r.warehouse, r.item_code)] = flt(r.actual_qty)
	diffs = 0
	for key, lines in state["stock"].items():
		for code, qty in lines.items():
			if abs(erp[(wh[key], code)] - qty) > 0.0001:
				diffs += 1
	return diffs


def _counts(company: str) -> dict:
	out = {dt: frappe.db.count(dt, {"docstatus": 1, "company": company}) for dt in TRACKED}
	out["ledger_events"] = frappe.db.count("Distribution Sim Event")
	return out
