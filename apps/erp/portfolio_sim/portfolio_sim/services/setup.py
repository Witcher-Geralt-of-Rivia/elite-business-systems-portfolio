"""Company and master-data setup for Sable Ridge Electronics Supply Co. (Frappe runtime).

1. ERPNext's own programmatic setup (`erpnext.setup.setup_wizard.setup_wizard.setup_complete`): fixtures,
   company with the Standard chart of accounts, fiscal year, price lists, bank account. (Frappe's desk
   `setup_complete` is not used: it also sends a telemetry persona event.)
2. Settings that make document flow strict (SO->DN->SI, PO->PR->PI), no negative stock, no automatic
   material requests (the planner purchases), no price-list rewriting by transactions.
3. Master data from `build_scenario()`: warehouses, item groups, items, prices, payment terms, suppliers,
   customer groups, territories, departments, designations, employees, sales persons, customers, tax template.
4. The simulation settings record with the planner's initial state.

Every step is idempotent (existing records are kept), so re-running setup is safe.
"""

from __future__ import annotations

from datetime import date

import frappe

from ..engine import calendar as cal
from ..engine.planner import initial_state, state_dumps
from ..engine.scenario import Scenario, build_scenario, load_catalog
from ..upstream_refs import resolve
from .docs import account, append_row, fill, new_doc


def get_scenario(seed: int, start: date) -> Scenario:
	return build_scenario(load_catalog(), seed, start)


def _exists(doctype: str, name_or_filters) -> bool:
	return bool(frappe.db.exists(doctype, name_or_filters))


def setup(seed: int, start: date) -> dict:
	start = cal.on_or_after(start)
	s = get_scenario(seed, start)
	c = s.company
	abbr = c["abbr"]
	created: dict[str, int] = {}

	def count(kind: str):
		created[kind] = created.get(kind, 0) + 1

	# 1. ERPNext setup (fixtures, company, fiscal year of the scenario start, defaults, bank account).
	if not _exists("Company", c["name"]):
		resolve("setup_complete")(frappe._dict({
			"currency": c["currency"], "country": c["country"], "timezone": c["timezone"], "language": "en",
			"company_name": c["name"], "company_abbr": abbr, "chart_of_accounts": c["chart_of_accounts"],
			"fy_start_date": date(start.year, 1, 1).isoformat(), "fy_end_date": date(start.year, 12, 31).isoformat(),
			"bank_account": c["bank_account"], "domain": None,
		}))
		for app in ("frappe", "erpnext"):
			frappe.db.set_value("Installed Application", {"app_name": app}, "is_setup_complete", 1)
		count("company")
	company = c["name"]
	bank = account(c["bank_account"], abbr)

	for year in range(start.year, date.today().year + 2):
		if not frappe.db.get_value("Fiscal Year", {"year_start_date": date(year, 1, 1)}):
			new_doc("Fiscal Year", {"year": str(year), "year_start_date": date(year, 1, 1), "year_end_date": date(year, 12, 31),
				"companies": [{"company": company}]}).insert()
			count("fiscal_year")

	# 2. Settings.
	# ERPNext's setup_complete runs only ERPNext's stages, not Frappe's System Settings: without this the site keeps
	# no time zone and Frappe's now_datetime() falls back to Asia/Kolkata, so the live simulation would run the
	# distributor's business day ~10 hours early (found on the native install, 2026-11-20).
	# (Frappe's own wizard would also set the mandatory language; without it System Settings cannot be saved.)
	system = {"time_zone": c["timezone"], "language": "en", "country": c["country"]}
	if any(frappe.db.get_single_value("System Settings", k) != v for k, v in system.items()):
		frappe.db.set_single_value("System Settings", system)
	fill("Company", frappe.get_doc("Company", company), {"reconciliation_takes_effect_on": "Oldest Of Invoice Or Advance",
		"default_bank_account": bank, "enable_perpetual_inventory": 1}).save()
	fill("Stock Settings", frappe.get_single("Stock Settings"), {"allow_negative_stock": 0, "valuation_method": "FIFO",
		"auto_indent": 0, "auto_insert_price_list_rate_if_missing": 0}).save()
	fill("Selling Settings", frappe.get_single("Selling Settings"), {"so_required": "Yes", "dn_required": "Yes",
		"selling_price_list": "Standard Selling"}).save()
	fill("Buying Settings", frappe.get_single("Buying Settings"), {"po_required": "Yes", "pr_required": "Yes",
		"buying_price_list": "Standard Buying"}).save()

	tax_account = account(c["tax_account"], abbr)
	if not _exists("Account", tax_account):
		new_doc("Account", {"account_name": c["tax_account"], "parent_account": account("Duties and Taxes", abbr),
			"company": company, "account_type": "Tax", "is_group": 0}).insert()
		count("account")
	# "Temporary Opening" (opening stock difference account) and the expense accounts come with the Standard chart.

	for mode in ("Check", "Wire Transfer"):
		mop = frappe.get_doc("Mode of Payment", mode)
		if not any(a.company == company for a in mop.accounts):
			append_row("Mode of Payment", mop, "accounts", {"company": company, "default_account": bank})
			mop.save()

	# 3. Master data.
	root_wh = frappe.db.get_value("Warehouse", {"company": company, "is_group": 1, "parent_warehouse": ["in", ["", None]]})
	for w in s.warehouses:
		if not _exists("Warehouse", account(w["name"], abbr)):
			new_doc("Warehouse", {"warehouse_name": w["name"], "company": company, "parent_warehouse": root_wh, "is_group": 0}).insert()
			count("warehouse")

	dc = account(s.warehouses[0]["name"], abbr)
	root_ig = resolve("get_root_of")("Item Group")
	for g in s.catalog["item_groups"]:
		if not _exists("Item Group", g["name"]):
			ig = new_doc("Item Group", {"item_group_name": g["name"], "parent_item_group": root_ig, "is_group": 0,
				"item_group_defaults": [{"company": company, "default_warehouse": dc}]}).insert()
			# v16's Item Group has no description field; the curated description is kept as a comment.
			ig.add_comment("Comment", s.catalog["group_descriptions"][g["prefix"]])
			count("item_group")

	for t in s.catalog["payment_terms"]:
		if not _exists("Payment Term", t["name"]):
			new_doc("Payment Term", {"payment_term_name": t["name"], "invoice_portion": 100, "due_date_based_on": "Day(s) after invoice date",
				"credit_days": t["days"]}).insert()
		if not _exists("Payment Terms Template", t["name"]):
			new_doc("Payment Terms Template", {"template_name": t["name"], "terms": [{"payment_term": t["name"], "invoice_portion": 100,
				"due_date_based_on": "Day(s) after invoice date", "credit_days": t["days"]}]}).insert()
			count("payment_terms")

	root_sg = resolve("get_root_of")("Supplier Group")
	for g in s.catalog["supplier_groups"]:
		if not _exists("Supplier Group", g):
			new_doc("Supplier Group", {"supplier_group_name": g, "parent_supplier_group": root_sg, "is_group": 0}).insert()
	for sup in s.suppliers:
		if not _exists("Supplier", sup["name"]):
			new_doc("Supplier", {"supplier_name": sup["name"], "supplier_group": sup["group"], "supplier_type": "Company",
				"country": c["country"], "payment_terms": sup["terms"]}).insert()
			city, state = s.catalog["supplier_cities"][sup["name"]].split(", ")
			new_doc("Address", {"address_title": sup["name"], "address_type": "Billing", "address_line1": "Main Office",
				"city": city, "state": state, "country": c["country"], "links": [{"link_doctype": "Supplier", "link_name": sup["name"]}]}).insert()
			count("supplier")

	for it in s.items:
		if not _exists("Item", it.code):
			new_doc("Item", {"item_code": it.code, "item_name": it.name, "item_group": it.group_name, "stock_uom": it.uom,
				"is_stock_item": 1, "include_item_in_manufacturing": 0, "description": it.description, "valuation_rate": it.cost,
				"item_defaults": [{"company": company, "default_warehouse": dc, "default_supplier": it.supplier}]}).insert()
			count("item")
		for price_list, rate in (("Standard Buying", it.cost), ("Standard Selling", it.list_price)):
			if not _exists("Item Price", {"item_code": it.code, "price_list": price_list}):
				new_doc("Item Price", {"item_code": it.code, "price_list": price_list, "price_list_rate": rate, "uom": it.uom}).insert()

	root_cg = resolve("get_root_of")("Customer Group")
	for seg in s.catalog["customer_segments"]:
		if not _exists("Customer Group", seg["name"]):
			new_doc("Customer Group", {"customer_group_name": seg["name"], "parent_customer_group": root_cg, "is_group": 0}).insert()
	root_t = resolve("get_root_of")("Territory")
	for t in s.catalog["territory_weights"]:
		if not _exists("Territory", t):
			new_doc("Territory", {"territory_name": t, "parent_territory": root_t, "is_group": 0}).insert()

	tax_template = f"{s.catalog['tax']['template']} - {abbr}"
	if not _exists("Sales Taxes and Charges Template", tax_template):
		new_doc("Sales Taxes and Charges Template", {"title": s.catalog["tax"]["template"], "company": company, "taxes": [{
			"charge_type": "On Net Total", "account_head": tax_account, "rate": s.catalog["tax"]["rate"],
			"description": s.catalog["tax"]["description"]}]}).insert()
		count("tax_template")

	root_dept = resolve("get_root_of")("Department")
	for dept in sorted({e.department for e in s.employees}):
		if not frappe.db.get_value("Department", {"department_name": dept, "company": company}):
			new_doc("Department", {"department_name": dept, "company": company, "parent_department": root_dept, "is_group": 0}).insert()
	for desig in sorted({e.designation for e in s.employees}):
		if not _exists("Designation", desig):
			new_doc("Designation", {"designation_name": desig}).insert()
	# Gender records come from Frappe's interactive setup wizard, not from ERPNext's programmatic setup
	# (found in CI run 44411918611: "Could not find Gender: Female").
	for g in s.catalog["people"]["genders"]:
		if not _exists("Gender", g):
			new_doc("Gender", {"gender": g}).insert()
	root_sp = resolve("get_root_of")("Sales Person")
	for e in s.employees:
		emp = frappe.db.get_value("Employee", {"first_name": e.first_name, "last_name": e.last_name, "company": company})
		if not emp:
			emp = new_doc("Employee", {"first_name": e.first_name, "last_name": e.last_name, "gender": e.gender,
				"date_of_birth": e.date_of_birth, "date_of_joining": e.date_of_joining, "company": company, "status": "Active",
				"department": frappe.db.get_value("Department", {"department_name": e.department, "company": company}),
				"designation": e.designation}).insert().name
			count("employee")
		if e.sales_person and not _exists("Sales Person", e.full_name):
			new_doc("Sales Person", {"sales_person_name": e.full_name, "employee": emp, "parent_sales_person": root_sp,
				"is_group": 0, "enabled": 1}).insert()

	for cu in s.customers:
		if not _exists("Customer", cu.name):
			new_doc("Customer", {"customer_name": cu.name, "customer_type": "Company", "customer_group": cu.segment,
				"territory": cu.territory, "payment_terms": cu.terms, "default_price_list": "Standard Selling",
				"sales_team": [{"sales_person": cu.account_manager, "allocated_percentage": 100}]}).insert()
			first, last = cu.contact_name.split(" ", 1)
			new_doc("Contact", {"first_name": first, "last_name": last, "designation": cu.contact_title, "is_primary_contact": 1,
				"links": [{"link_doctype": "Customer", "link_name": cu.name}]}).insert()
			new_doc("Address", {"address_title": cu.name, "address_type": "Billing", "address_line1": "Main Office",
				"city": cu.city, "state": cu.state, "country": c["country"], "is_primary_address": 1,
				"links": [{"link_doctype": "Customer", "link_name": cu.name}]}).insert()
			count("customer")

	# 4. Simulation settings with the planner's initial state.
	settings = frappe.get_single("Distribution Sim Settings")
	if not settings.seed:
		state = initial_state(s)
		fill("Distribution Sim Settings", settings, {"seed": seed, "scenario_start": start, "company": company, "live": 0,
			"paused": 0, "planned_day": None, "processed_until": None, "events_executed": 0, "state_json": state_dumps(state),
			"pending_events": "[]"})
		settings.save()
	elif settings.seed != seed or str(settings.scenario_start) != start.isoformat():
		frappe.throw(f"Simulation already initialised with seed {settings.seed} from {settings.scenario_start}")
	frappe.db.commit()
	return created
