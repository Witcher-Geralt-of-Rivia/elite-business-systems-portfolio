"""Native-Windows web process: Frappe's WSGI application (frappe.app.application) under waitress, because gunicorn is
Unix-only. Run from the bench's sites directory. Listens on loopback only; the private proxy (Caddy on 127.0.0.1)
serves /assets and /files and forwards everything else here with X-Forwarded-For/-Proto.

Usage: python serve_win.py [listen, default 127.0.0.1:8851] [threads, default 6]
"""
import sys

import frappe_win  # noqa: F401  (runtime adaptations)
from waitress import serve

from frappe.app import application

if __name__ == "__main__":
	listen = sys.argv[1] if len(sys.argv) > 1 else "127.0.0.1:8851"
	if not listen.startswith(("127.0.0.1:", "localhost:", "[::1]:")):
		sys.exit(f"serve_win: refusing to listen on a non-loopback address: {listen}")
	serve(
		application,
		listen=listen,
		threads=int(sys.argv[2]) if len(sys.argv) > 2 else 6,
		ident="erp",
		# Only the loopback proxy may set the client address and scheme (login rate limits, secure cookies).
		trusted_proxy="127.0.0.1",
		trusted_proxy_count=1,
		trusted_proxy_headers={"x-forwarded-for", "x-forwarded-proto"},
		clear_untrusted_proxy_headers=True,
		channel_timeout=300,
		max_request_body_size=64 * 1024 * 1024,
	)
