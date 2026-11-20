"""Credential-free, read-only visitor access for the public portfolio (inactive until the owner approves public HTTPS).

* `setup_visitor()` (CLI: `portfolio-sim visitor-setup`) creates the role "Portfolio Visitor" with READ (and report /
  print) permission only - through Custom DocPerm, Frappe's supported permission customisation - on the business
  documents and masters of the simulated distributor, and the user `visitor@sableridge.example` with that role only,
  a random password nobody knows, and enough simultaneous sessions for concurrent visitors.
* `enter()` (GET/POST /api/method/portfolio_sim.visitor.enter) logs the caller in as that user and redirects to the
  Desk. It works only while the site config flag `portfolio_visitor_enabled` is set (off by default) and is rate
  limited per IP address.
* `block_visitor_writes` is attached to every DocType's insert/validate/submit/cancel/delete/rename events
  (hooks.doc_events["*"]): even if a permission were granted by mistake, the server refuses any write made in the
  visitor's session, except the bookkeeping Frappe itself records for every session (allow list below).
No administrator or production credential is involved or exposed.
"""

from __future__ import annotations

import secrets

import frappe
from frappe import _
from frappe.rate_limiter import rate_limit

VISITOR_USER = "visitor@sableridge.example"
VISITOR_ROLE = "Portfolio Visitor"
FLAG = "portfolio_visitor_enabled"

# What the showcase lets visitors look at (read, report, print; never write/create/submit/cancel/delete/export).
READ_DOCTYPES = [
	"Company", "Fiscal Year", "Currency", "Account", "Cost Center", "Mode of Payment", "Payment Terms Template",
	"Item", "Item Group", "Item Price", "Price List", "UOM", "Brand", "Warehouse", "Bin",
	"Customer", "Customer Group", "Territory", "Supplier", "Supplier Group", "Sales Person", "Employee", "Department",
	"Sales Taxes and Charges Template", "Purchase Taxes and Charges Template",
	"Sales Order", "Delivery Note", "Sales Invoice", "Purchase Order", "Purchase Receipt", "Purchase Invoice",
	"Payment Entry", "Journal Entry", "Stock Entry", "Stock Reconciliation", "Payment Reconciliation",
	"GL Entry", "Stock Ledger Entry", "Payment Ledger Entry",
	"Distribution Sim Event", "Distribution Sim Settings",
]

# Records Frappe writes for any logged-in session (not business data).
ALLOWED_SYSTEM_WRITES = {
	"Activity Log", "Access Log", "Route History", "View Log", "Session Default Settings", "Error Log",
	"Notification Settings", "DefaultValue",
}


def is_visitor() -> bool:
	return getattr(frappe.session, "user", None) == VISITOR_USER


def block_visitor_writes(doc, method=None):
	if is_visitor() and doc.doctype not in ALLOWED_SYSTEM_WRITES:
		frappe.throw(_("The portfolio visitor account is read-only."), frappe.PermissionError)


@frappe.whitelist(allow_guest=True, methods=["GET", "POST"])
@rate_limit(limit=30, seconds=60, ip_based=True)
def enter():
	"""Start a read-only visitor session (no credentials) and go to the Desk."""
	if not frappe.conf.get(FLAG):
		frappe.throw(_("Visitor access is not enabled on this site."), frappe.PermissionError)
	if not frappe.db.get_value("User", VISITOR_USER, "enabled"):
		frappe.throw(_("Visitor access is not set up."), frappe.PermissionError)
	frappe.local.login_manager.login_as(VISITOR_USER)
	frappe.local.response["type"] = "redirect"
	frappe.local.response["location"] = "/desk"


def setup_visitor() -> dict:
	"""Idempotent: role, read-only permissions, visitor user. Run once per site (CLI `portfolio-sim visitor-setup`)."""
	from frappe.permissions import add_permission, update_permission_property

	if not frappe.db.exists("Role", VISITOR_ROLE):
		frappe.get_doc({"doctype": "Role", "role_name": VISITOR_ROLE, "desk_access": 1}).insert(ignore_permissions=True)
	granted = []
	for dt in READ_DOCTYPES:
		if not frappe.db.exists("DocType", dt):
			continue
		if not frappe.db.exists("Custom DocPerm", {"parent": dt, "role": VISITOR_ROLE, "permlevel": 0}):
			add_permission(dt, VISITOR_ROLE, 0, "read")
		for ptype, value in (("read", 1), ("report", 1), ("print", 1), ("write", 0), ("create", 0), ("submit", 0),
				("cancel", 0), ("delete", 0), ("amend", 0), ("export", 0), ("import", 0), ("share", 0), ("email", 0)):
			try:
				update_permission_property(dt, VISITOR_ROLE, 0, ptype, value, validate=False)
			except Exception:
				pass  # property not applicable to this DocType (e.g. submit on a non-submittable one)
		granted.append(dt)

	if not frappe.db.exists("User", VISITOR_USER):
		user = frappe.get_doc({
			"doctype": "User", "email": VISITOR_USER, "first_name": "Portfolio", "last_name": "Visitor",
			"user_type": "System User", "send_welcome_email": 0, "enabled": 1,
			"new_password": secrets.token_urlsafe(32),  # never stored anywhere else: login only through enter()
		})
		user.insert(ignore_permissions=True)
	user = frappe.get_doc("User", VISITOR_USER)
	user.flags.ignore_password_policy = True
	user.set("roles", [])
	user.append("roles", {"role": VISITOR_ROLE})
	user.simultaneous_sessions = 500
	user.logout_all_sessions = 0
	user.save(ignore_permissions=True)
	frappe.db.commit()
	frappe.clear_cache()
	return {"role": VISITOR_ROLE, "user": VISITOR_USER, "read_doctypes": len(granted), "enabled_flag": bool(frappe.conf.get(FLAG))}
