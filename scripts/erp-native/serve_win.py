"""Native-Windows web process for the spike: Frappe's WSGI application under waitress (gunicorn is Unix-only).
Run from the bench's sites directory. Loopback only."""
import sys
import frappe_win  # noqa: F401  (runtime adaptations)
from waitress import serve
from frappe.app import application

serve(application, listen=sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:8840", threads=8, ident="erp-spike")
