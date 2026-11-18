"""Small helpers through which every ERPNext document field is written.

`new_doc("Sales Order", {...})` and `fill("Purchase Receipt", doc, {...})` take the DocType as a literal so
`scripts/verification/check_erp_upstream.py` can statically verify every field name (including child-table
rows, resolved through the parent's Table field) against the pinned ERPNext/Frappe DocType definitions.
"""

from __future__ import annotations

import frappe


def new_doc(doctype: str, values: dict):
	return frappe.get_doc({"doctype": doctype, **values})


def fill(doctype: str, doc, values: dict):
	if doc.doctype != doctype:
		raise TypeError(f"expected a {doctype}, got {doc.doctype}")
	doc.update(values)
	return doc


def append_row(doctype: str, doc, table: str, row: dict):
	"""Append a child row to `table` of a `doctype` document (verified like `fill`)."""
	if doc.doctype != doctype:
		raise TypeError(f"expected a {doctype}, got {doc.doctype}")
	return doc.append(table, row)


def account(name: str, abbr: str) -> str:
	return f"{name} - {abbr}"


def submit(doc):
	"""Insert (if new) and submit with the document's own validation; never bypasses permissions checks
	beyond running as the simulation's system user."""
	if doc.is_new():
		doc.insert()
	doc.submit()
	return doc
