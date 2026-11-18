"""Static checks of the Frappe app against the pinned ERPNext/Frappe v16.60.0 sources (no runtime needed).

Requires the pinned upstream clones in upstream/erpnext-v16.60.0 and upstream/frappe-v16.60.0 (git-ignored;
see apps/erp/README.md). Skipped when they are absent.
"""

from __future__ import annotations

import ast
import importlib.util
import py_compile
import sys
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
CHECKER = REPO / "scripts" / "verification" / "check_erp_upstream.py"
ERPNEXT = REPO / "upstream" / "erpnext-v16.60.0"
FRAPPE = REPO / "upstream" / "frappe-v16.60.0"
APP = REPO / "apps" / "erp" / "portfolio_sim"


def _load_checker():
	spec = importlib.util.spec_from_file_location("check_erp_upstream", CHECKER)
	mod = importlib.util.module_from_spec(spec)
	sys.modules["check_erp_upstream"] = mod
	spec.loader.exec_module(mod)
	return mod


class TestCompiles(unittest.TestCase):
	def test_every_app_module_compiles(self):
		files = sorted(APP.rglob("*.py"))
		self.assertGreater(len(files), 15)
		for f in files:
			py_compile.compile(str(f), doraise=True)

	def test_engine_has_no_frappe_dependency(self):
		for f in (APP / "portfolio_sim" / "engine").glob("*.py"):
			tree = ast.parse(f.read_text(encoding="utf-8"))
			for node in ast.walk(tree):
				if isinstance(node, ast.Import | ast.ImportFrom):
					names = [a.name for a in node.names] if isinstance(node, ast.Import) else [node.module or ""]
					self.assertFalse(any(n.split(".")[0] in ("frappe", "erpnext") for n in names), f"{f.name} imports Frappe")


@unittest.skipUnless(ERPNEXT.exists() and FRAPPE.exists(), "pinned upstream sources not present")
class TestUpstreamReferences(unittest.TestCase):
	@classmethod
	def setUpClass(cls):
		cls.mod = _load_checker()
		cls.checker = cls.mod.Checker(ERPNEXT, FRAPPE)

	def test_app_matches_pinned_sources(self):
		c = self.mod.Checker(ERPNEXT, FRAPPE)
		for step in (c.versions, c.functions, c.methods, c.services, c.manifests, c.app):
			step()
		self.assertEqual(c.problems, [])
		self.assertGreater(c.checked, 600)

	def _problems_for(self, source: str, doctype_call: str = "fill") -> list[str]:
		c = self.mod.Checker(ERPNEXT, FRAPPE)
		call = ast.parse(source).body[0].value
		if doctype_call == "new_doc":
			c.dict_fields(call.args[0].value, call.args[1], "selftest")
		else:
			c.dict_fields(call.args[0].value, call.args[2], "selftest")
		return c.problems

	def test_detects_unknown_field(self):
		problems = self._problems_for('new_doc("Sales Order", {"customer": "x", "not_a_field": 1})', "new_doc")
		self.assertEqual(len(problems), 1)
		self.assertIn("not_a_field", problems[0])

	def test_detects_unknown_child_field(self):
		problems = self._problems_for('new_doc("Sales Order", {"items": [{"item_code": "A", "qtty": 1}]})', "new_doc")
		self.assertEqual(len(problems), 1)
		self.assertIn("Sales Order Item", problems[0])

	def test_detects_invalid_select_option(self):
		problems = self._problems_for('fill("Stock Settings", doc, {"valuation_method": "Average Cost"})')
		self.assertEqual(len(problems), 1)
		self.assertIn("valuation_method", problems[0])

	def test_detects_wrong_function_signature(self):
		c = self.mod.Checker(ERPNEXT, FRAPPE)
		c.refs["FUNCTIONS"] = {"bad": ("erpnext.selling.doctype.sales_order.sales_order", "make_delivery_note", ("source", "target_doc")),
			"missing": ("erpnext.selling.doctype.sales_order.sales_order", "make_teleport", ("source_name",))}
		c.functions()
		self.assertEqual(len(c.problems), 2)

	def test_detects_unknown_account(self):
		c = self.mod.Checker(ERPNEXT, FRAPPE)
		c.refs["STANDARD_ACCOUNTS"] = ("Debtors", "Imaginary Account")
		c.refs["FIXTURE_UOMS"] = ("Nos",)
		c.manifests()
		self.assertTrue(any("Imaginary Account" in p for p in c.problems))


if __name__ == "__main__":
	unittest.main()
