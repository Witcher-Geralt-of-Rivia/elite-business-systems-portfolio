# Copyright (c) 2026, Elite Business Systems Portfolio contributors
# License: GNU General Public License v3. See license.txt

from frappe.model.document import Document


class DistributionSimEvent(Document):
	"""One executed simulation event (idempotency ledger). Rows are written by the simulator only."""

	pass
