"""Every ERPNext/Frappe API this app relies on, in one place.

The executor and setup routine resolve functions through `FUNCTIONS` (never by scattered dotted strings),
and `scripts/verification/check_erp_upstream.py` verifies each entry against the pinned v16.60.0 sources:
module file exists, function is defined at module level, and its leading parameters match. Document
field names are verified separately from every `new_doc(...)` / `fill(...)` call in the services.
"""

# name -> (module, function, leading parameter names as defined upstream)
FUNCTIONS: dict[str, tuple[str, str, tuple[str, ...]]] = {
	"setup_complete": ("erpnext.setup.setup_wizard.setup_wizard", "setup_complete", ("args",)),
	"make_purchase_receipt": ("erpnext.buying.doctype.purchase_order.purchase_order", "make_purchase_receipt",
		("source_name", "target_doc", "args")),
	"make_purchase_invoice_from_receipt": ("erpnext.stock.doctype.purchase_receipt.purchase_receipt", "make_purchase_invoice",
		("source_name", "target_doc", "args")),
	"make_purchase_return": ("erpnext.stock.doctype.purchase_receipt.purchase_receipt", "make_purchase_return",
		("source_name", "target_doc")),
	"make_debit_note": ("erpnext.accounts.doctype.purchase_invoice.purchase_invoice", "make_debit_note",
		("source_name", "target_doc")),
	"make_delivery_note": ("erpnext.selling.doctype.sales_order.sales_order", "make_delivery_note",
		("source_name", "target_doc", "kwargs")),
	"make_sales_invoice_from_delivery": ("erpnext.stock.doctype.delivery_note.delivery_note", "make_sales_invoice",
		("source_name", "target_doc", "args")),
	"make_sales_return_from_delivery": ("erpnext.stock.doctype.delivery_note.delivery_note", "make_sales_return",
		("source_name", "target_doc")),
	"make_credit_note": ("erpnext.accounts.doctype.sales_invoice.sales_invoice", "make_sales_return",
		("source_name", "target_doc")),
	"get_payment_entry": ("erpnext.accounts.doctype.payment_entry.payment_entry", "get_payment_entry",
		("dt", "dn", "party_amount", "bank_account", "bank_amount", "party_type", "payment_type", "reference_date")),
	"get_stock_balance": ("erpnext.stock.utils", "get_stock_balance",
		("item_code", "warehouse", "posting_date", "posting_time", "with_valuation_rate")),
	"get_root_of": ("frappe.utils.nestedset", "get_root_of", ("doctype",)),
	"filelock": ("frappe.utils.synchronization", "filelock", ("lock_name",)),
}

# DocType -> controller methods called on documents of that type ("Document" = frappe.model.document.Document).
METHODS: dict[str, tuple[str, ...]] = {
	"Payment Reconciliation": ("get_unreconciled_entries", "allocate_entries", "reconcile"),
	"Document": ("insert", "submit", "save", "update", "set", "get", "append", "as_dict", "add_comment", "is_new"),
}

# Child-row fields set generically (by attribute) when trimming mapped documents to planned quantities.
ROW_FIELDS: dict[str, tuple[str, ...]] = {
	"Purchase Receipt Item": ("item_code", "qty", "received_qty", "rejected_qty"),
	"Purchase Invoice Item": ("item_code", "qty"),
	"Delivery Note Item": ("item_code", "qty"),
	"Sales Invoice Item": ("item_code", "qty"),
}

# Columns read by the integrity SQL (services/integrity.py), verified against the DocType definitions.
SQL_COLUMNS: dict[str, tuple[str, ...]] = {
	"GL Entry": ("account", "company", "debit", "credit", "is_cancelled", "voucher_type", "voucher_no", "posting_date"),
	"Payment Ledger Entry": ("against_voucher_type", "against_voucher_no", "amount", "delinked", "company", "posting_date", "account"),
	"Stock Ledger Entry": ("item_code", "warehouse", "actual_qty", "qty_after_transaction", "stock_value_difference",
		"is_cancelled", "company", "posting_date", "posting_datetime"),
	"Bin": ("item_code", "warehouse", "actual_qty"),
	"Account": ("account_type", "company"),
	"Warehouse": ("company",),
	"Sales Invoice": ("company", "outstanding_amount", "posting_date", "is_return", "net_total", "total_taxes_and_charges",
		"taxes_and_charges", "customer"),
	"Purchase Invoice": ("company", "outstanding_amount", "posting_date", "is_return"),
	"Sales Order": ("company", "transaction_date"),
	"Sales Order Item": ("qty", "delivered_qty"),
	"Purchase Order": ("company", "transaction_date"),
	"Purchase Order Item": ("qty", "received_qty"),
	"Delivery Note": ("company", "posting_date", "is_return"),
	"Delivery Note Item": ("against_sales_order", "qty", "returned_qty"),
	"Sales Invoice Item": ("delivery_note",),
	"Purchase Receipt": ("company", "posting_date", "is_return"),
	"Purchase Receipt Item": ("purchase_order", "qty", "returned_qty"),
	"Purchase Invoice Item": ("purchase_receipt",),
	"Payment Entry": ("company", "posting_date"),
	"Payment Entry Reference": ("reference_doctype", "reference_name"),
	"Journal Entry": ("company", "is_system_generated"),
	"Stock Entry": ("company",),
	"Stock Reconciliation": ("company",),
}

# Accounts of ERPNext's "Standard" chart (created as "<name> - <abbr>").
STANDARD_ACCOUNTS: tuple[str, ...] = (
	"Debtors", "Creditors", "Bank Accounts", "Stock In Hand", "Cost of Goods Sold", "Sales", "Duties and Taxes",
	"Capital Stock", "Opening Balance Equity", "Temporary Opening", "Stock Adjustment", "Office Rent", "Salary",
	"Utility Expenses", "Telephone Expenses", "Freight and Forwarding Charges", "Marketing Expenses",
	"Travel Expenses", "Office Maintenance Expenses", "Bank Charges", "Stock Received But Not Billed",
)

# Records installed by ERPNext's setup fixtures for a United States company.
FIXTURE_UOMS: tuple[str, ...] = ("Nos", "Box")
FIXTURE_MODES_OF_PAYMENT: tuple[str, ...] = ("Check", "Wire Transfer")
FIXTURE_PRICE_LISTS: tuple[str, ...] = ("Standard Buying", "Standard Selling")

# Single DocTypes whose fields the setup routine writes (verified like document fields).
SETTINGS: dict[str, tuple[str, ...]] = {
	"Stock Settings": ("allow_negative_stock", "valuation_method", "auto_indent", "auto_insert_price_list_rate_if_missing"),
	"Selling Settings": ("so_required", "dn_required", "selling_price_list"),
	"Buying Settings": ("po_required", "pr_required", "buying_price_list"),
	"Accounts Settings": ("unlink_payment_on_cancellation_of_invoice",),
	"Company": ("reconciliation_takes_effect_on", "default_bank_account", "enable_perpetual_inventory", "round_off_account"),
}


def resolve(name: str):
	"""Import and return the upstream function registered under `name` (Frappe runtime only)."""
	import importlib

	module, func, _ = FUNCTIONS[name]
	return getattr(importlib.import_module(module), func)
