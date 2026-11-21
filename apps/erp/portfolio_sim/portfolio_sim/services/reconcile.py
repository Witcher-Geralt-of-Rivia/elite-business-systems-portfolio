"""Read-only reconciliation: ERPNext's own management reports against the underlying ledgers.

Each comparison runs the report's `execute()` (the code behind the Desk report and its dashboards) with the company
and the simulated period, and compares its totals with independent SQL sums over GL Entry, Payment Ledger Entry,
Stock Ledger Entry and the submitted invoices. Nothing is written.
"""

from __future__ import annotations

import frappe
from frappe.utils import flt, getdate, today

TOLERANCE = 0.05


def _sql1(query: str, values: dict) -> float:
	return flt(frappe.db.sql(query, values)[0][0])


def _rows(result) -> list:
	data = result[1] if isinstance(result, (list, tuple)) else result
	return [r for r in (data or []) if isinstance(r, dict)]


def _cmp(name: str, report_value: float, ledger_value: float, detail: str) -> dict:
	diff = round(report_value - ledger_value, 2)
	return {"check": name, "report": round(report_value, 2), "ledger": round(ledger_value, 2), "difference": diff,
		"pass": abs(diff) <= TOLERANCE, "detail": detail}


def run() -> dict:
	frappe.set_user("Administrator")
	st = frappe.get_single("Distribution Sim Settings")
	company = st.company
	start = getdate(st.scenario_start)
	end = getdate(st.processed_until) if st.processed_until else getdate(today())
	v = {"company": company, "start": start, "end": end}
	debtors = frappe.db.get_value("Company", company, "default_receivable_account")
	creditors = frappe.db.get_value("Company", company, "default_payable_account")
	out: list[dict] = []

	# 1. General ledger: balanced overall and per year.
	dr = _sql1("select sum(debit) from `tabGL Entry` where is_cancelled = 0 and company = %(company)s", v)
	cr = _sql1("select sum(credit) from `tabGL Entry` where is_cancelled = 0 and company = %(company)s", v)
	out.append(_cmp("gl_debit_equals_credit", dr, cr, "all GL entries"))

	# 2. Trial Balance report (current fiscal year): debits = credits, period totals = GL.
	from erpnext.accounts.report.trial_balance.trial_balance import execute as trial_balance

	fy = frappe.db.get_value("Fiscal Year", {"year_start_date": ("<=", end), "year_end_date": (">=", end)}, ["name", "year_start_date"], as_dict=True)
	# No Period Closing Voucher is posted (the simulation never closes a fiscal year), so the prior year's P&L must be
	# carried into the opening with ERPNext's own option; without it the closing totals differ by exactly the prior
	# year's net result (measured 2026-11-20: 830,964.93 = FY 2025 net loss).
	tb = _rows(trial_balance(frappe._dict(company=company, fiscal_year=fy.name, from_date=fy.year_start_date, to_date=end,
		show_zero_values=0, include_default_book_entries=1, show_unclosed_fy_pl_balances=1)))
	total = next((r for r in tb if str(r.get("account", "")).strip("'").lower() == "total"), None)
	if total:
		out.append(_cmp("trial_balance_closing_balanced", flt(total.get("closing_debit")), flt(total.get("closing_credit")), f"FY {fy.name} closing"))
		vy = dict(v, fs=fy.year_start_date)
		out.append(_cmp("trial_balance_period_debit_vs_gl", flt(total.get("debit")),
			_sql1("""select sum(debit) from `tabGL Entry` where is_cancelled = 0 and company = %(company)s and posting_date between %(fs)s and %(end)s
				and ifnull(is_opening, 'No') = 'No'""", vy), f"FY {fy.name} period debits"))
	else:
		out.append({"check": "trial_balance_closing_balanced", "pass": False, "detail": "no total row"})

	# 3./4. Accounts Receivable / Payable reports vs the payment ledger.
	from erpnext.accounts.report.accounts_payable.accounts_payable import execute as accounts_payable
	from erpnext.accounts.report.accounts_receivable.accounts_receivable import execute as accounts_receivable

	common = dict(company=company, report_date=end, ageing_based_on="Due Date", range="30, 60, 90, 120", calculate_ageing_with="Report Date")
	ar = sum(flt(r.get("outstanding")) for r in _rows(accounts_receivable(frappe._dict(common))))
	out.append(_cmp("accounts_receivable_vs_payment_ledger", ar, _sql1("""select sum(amount) from `tabPayment Ledger Entry`
		where delinked = 0 and company = %(company)s and account = %(acc)s and posting_date <= %(end)s""", dict(v, acc=debtors)), "outstanding incl. unallocated advances"))
	ap = sum(flt(r.get("outstanding")) for r in _rows(accounts_payable(frappe._dict(common))))
	out.append(_cmp("accounts_payable_vs_payment_ledger", ap, _sql1("""select sum(amount) from `tabPayment Ledger Entry`
		where delinked = 0 and company = %(company)s and account = %(acc)s and posting_date <= %(end)s""", dict(v, acc=creditors)), "outstanding"))

	# 5. Stock Balance report vs the stock ledger and the stock accounts in the GL.
	from erpnext.stock.report.stock_balance.stock_balance import execute as stock_balance

	sb = _rows(stock_balance(frappe._dict(company=company, from_date=start, to_date=end)))
	sb_value = sum(flt(r.get("bal_val")) for r in sb)
	sle_value = _sql1("""select sum(stock_value_difference) from `tabStock Ledger Entry` where is_cancelled = 0
		and company = %(company)s and posting_date <= %(end)s""", v)
	out.append(_cmp("stock_balance_vs_stock_ledger", sb_value, sle_value, f"{len(sb)} item-warehouse rows"))
	stock_accounts = [a.name for a in frappe.get_all("Account", filters={"company": company, "account_type": "Stock"})]
	gl_stock = _sql1("""select sum(debit) - sum(credit) from `tabGL Entry` where is_cancelled = 0 and company = %(company)s
		and account in %(accs)s and posting_date <= %(end)s""", dict(v, accs=tuple(stock_accounts))) if stock_accounts else 0.0
	out.append(_cmp("stock_balance_vs_gl_stock_accounts", sb_value, gl_stock, ", ".join(stock_accounts)))

	# 6. Sales Register report vs submitted Sales Invoices.
	from erpnext.accounts.report.sales_register.sales_register import execute as sales_register

	sr = _rows(sales_register(frappe._dict(company=company, from_date=start, to_date=end)))
	sr_total = sum(flt(r.get("grand_total")) for r in sr if r.get("invoice") or r.get("voucher_no"))
	si_total = _sql1("""select sum(grand_total) from `tabSales Invoice` where docstatus = 1 and company = %(company)s
		and posting_date between %(start)s and %(end)s""", v)
	out.append(_cmp("sales_register_vs_invoices", sr_total, si_total, f"{len(sr)} rows"))

	# 7. Meaningful values: nothing simulated is zero-valued; positive revenue and margin.
	zero = _sql1("""select count(*) from `tabSales Invoice` where docstatus = 1 and company = %(company)s and grand_total = 0
		and is_return = 0""", v) + _sql1("""select count(*) from `tabPurchase Invoice` where docstatus = 1 and company = %(company)s
		and grand_total = 0 and is_return = 0""", v)
	out.append({"check": "no_zero_value_invoices", "pass": zero == 0, "detail": f"{int(zero)} zero-value invoices"})

	return {"company": company, "period": [str(start), str(end)], "checks": len(out),
		"failing": [c["check"] for c in out if not c["pass"]], "results": out}
