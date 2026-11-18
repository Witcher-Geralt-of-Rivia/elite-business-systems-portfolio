"""Static verification of the ERP app (apps/erp/portfolio_sim) against the pinned ERPNext/Frappe sources.

No Frappe runtime is needed: the upstream trees are parsed (Python AST and DocType JSON). Verified:

1. pinned versions: erpnext and frappe `__version__` == 16.60.0;
2. every function in `upstream_refs.FUNCTIONS`: module file exists, function defined at module level, and its
   parameters start with the expected names in order;
3. every method in `upstream_refs.METHODS` exists on the DocType controller (or Frappe's Document/BaseDocument);
4. every DocType field written or read by the app's services: `new_doc(DT, {...})`, `fill(DT, doc, {...})`,
   `append_row(DT, doc, table, {...})`, `frappe.get_doc({"doctype": DT, ...})`, `frappe.get_all(DT, filters=, fields=,
   pluck=)`, `frappe.db.get_value/set_value/set_single_value/count(DT, ...)`, `frappe.get_single(DT)`; child-table rows
   are resolved through the parent's Table field; Select values given as literals must be valid options;
5. `ROW_FIELDS` and `SQL_COLUMNS` columns exist on their DocTypes;
6. Standard chart accounts, fixture UOMs, modes of payment and price lists exist upstream;
7. the app's own DocTypes and hooks are consistent (field_order, module, hook targets).

Usage: python scripts/verification/check_erp_upstream.py [--erpnext DIR] [--frappe DIR] [--json]
Exit code 0 when everything matches, 1 otherwise.
"""

from __future__ import annotations

import argparse
import ast
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
APP = REPO / "apps" / "erp" / "portfolio_sim"
PKG = APP / "portfolio_sim"
STANDARD_FIELDS = {"name", "owner", "creation", "modified", "modified_by", "docstatus", "idx", "parent", "parenttype",
	"parentfield", "doctype"}
NO_VALUE_TYPES = {"Section Break", "Column Break", "Tab Break", "HTML", "Button", "Fold", "Heading"}
PINNED = "16.60.0"


class Checker:
	def __init__(self, erpnext: Path, frappe: Path):
		self.roots = {"erpnext": erpnext, "frappe": frappe}
		self.problems: list[str] = []
		self.checked = 0
		self.doctypes: dict[str, dict] = {}
		self._index_doctypes()
		ns: dict = {}
		exec(compile((PKG / "upstream_refs.py").read_text(encoding="utf-8"), "upstream_refs.py", "exec"), ns)
		self.refs = ns

	def fail(self, msg: str) -> None:
		self.problems.append(msg)

	def ok(self) -> None:
		self.checked += 1

	# ------------------------------------------------------------------ indexes
	def _index_doctypes(self) -> None:
		trees = [self.roots["erpnext"] / "erpnext", self.roots["frappe"] / "frappe", PKG]
		for tree in trees:
			for path in tree.rglob("doctype/*/*.json"):
				if path.stem != path.parent.name:
					continue
				try:
					d = json.loads(path.read_text(encoding="utf-8"))
				except (ValueError, UnicodeDecodeError):
					continue
				if d.get("doctype") != "DocType" or "name" not in d:
					continue
				fields = {f["fieldname"]: f for f in d.get("fields", []) if "fieldname" in f}
				self.doctypes[d["name"]] = {"fields": fields, "path": path, "issingle": d.get("issingle"), "json": d}

	def _module_file(self, module: str) -> Path | None:
		top = module.split(".")[0]
		root = self.roots.get(top)
		base = root if root else APP
		parts = module.split(".")
		p = base.joinpath(*parts).with_suffix(".py")
		if p.exists():
			return p
		p = base.joinpath(*parts, "__init__.py")
		return p if p.exists() else None

	@staticmethod
	def _params(fn: ast.FunctionDef) -> list[str]:
		a = fn.args
		return [x.arg for x in a.posonlyargs + a.args + a.kwonlyargs]

	# ------------------------------------------------------------------ checks
	def versions(self) -> None:
		for name, root in self.roots.items():
			text = (root / name / "__init__.py").read_text(encoding="utf-8")
			m = re.search(r'__version__\s*=\s*"([^"]+)"', text)
			if not m or m.group(1) != PINNED:
				self.fail(f"{name}: version {m.group(1) if m else '?'} is not the pinned {PINNED}")
			else:
				self.ok()

	def functions(self) -> None:
		for key, (module, func, params) in self.refs["FUNCTIONS"].items():
			path = self._module_file(module)
			if not path:
				self.fail(f"FUNCTIONS[{key}]: module {module} not found")
				continue
			tree = ast.parse(path.read_text(encoding="utf-8"))
			fn = next((n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == func), None)
			if not fn:
				self.fail(f"FUNCTIONS[{key}]: {module}.{func} is not defined at module level")
				continue
			actual = self._params(fn)
			if actual[: len(params)] != list(params):
				self.fail(f"FUNCTIONS[{key}]: {module}.{func} parameters {actual} do not start with {list(params)}")
				continue
			self.ok()

	def _class_methods(self, path: Path) -> set[str]:
		tree = ast.parse(path.read_text(encoding="utf-8"))
		return {f.name for c in ast.walk(tree) if isinstance(c, ast.ClassDef) for f in c.body
			if isinstance(f, ast.FunctionDef | ast.AsyncFunctionDef)}

	def methods(self) -> None:
		fr = self.roots["frappe"] / "frappe" / "model"
		base = self._class_methods(fr / "document.py") | self._class_methods(fr / "base_document.py")
		for doctype, names in self.refs["METHODS"].items():
			if doctype == "Document":
				have = base
			else:
				dt = self.doctypes.get(doctype)
				if not dt:
					self.fail(f"METHODS: DocType {doctype} not found")
					continue
				have = self._class_methods(dt["path"].with_suffix(".py")) | base
			for n in names:
				if n in have:
					self.ok()
				else:
					self.fail(f"METHODS: {doctype}.{n} not found")

	def field(self, doctype: str, fieldname: str, where: str, value_node: ast.AST | None = None) -> dict | None:
		dt = self.doctypes.get(doctype)
		if not dt:
			self.fail(f"{where}: DocType {doctype!r} not found")
			return None
		if fieldname in STANDARD_FIELDS:
			self.ok()
			return None
		f = dt["fields"].get(fieldname)
		if not f or f.get("fieldtype") in NO_VALUE_TYPES:
			self.fail(f"{where}: {doctype} has no field {fieldname!r}")
			return None
		self.ok()
		if f.get("fieldtype") == "Select" and isinstance(value_node, ast.Constant) and isinstance(value_node.value, str):
			options = [o for o in (f.get("options") or "").split("\n")]
			if value_node.value and value_node.value not in options:
				self.fail(f"{where}: {doctype}.{fieldname} = {value_node.value!r} is not one of {options}")
			else:
				self.ok()
		return f

	def dict_fields(self, doctype: str, node: ast.AST, where: str) -> None:
		if isinstance(node, ast.ListComp):
			node = node.elt
		if not isinstance(node, ast.Dict):
			return
		for k, v in zip(node.keys, node.values, strict=True):
			if k is None or not (isinstance(k, ast.Constant) and isinstance(k.value, str)):
				continue
			if k.value == "doctype":
				continue
			f = self.field(doctype, k.value, where, v)
			if f and f.get("fieldtype") in ("Table", "Table MultiSelect"):
				child = f.get("options")
				items = v.body if isinstance(v, ast.IfExp) else v
				if isinstance(items, ast.List):
					for elt in items.elts:
						self.dict_fields(child, elt, where)
				elif isinstance(items, ast.ListComp):
					self.dict_fields(child, items, where)

	@staticmethod
	def _const(node) -> str | None:
		return node.value if isinstance(node, ast.Constant) and isinstance(node.value, str) else None

	def _fields_arg(self, doctype: str, node, where: str) -> None:
		if isinstance(node, ast.Constant) and isinstance(node.value, str):
			self.field(doctype, node.value.split(" as ")[0].strip(), where)
		elif isinstance(node, ast.List):
			for e in node.elts:
				self._fields_arg(doctype, e, where)

	def services(self) -> None:
		files = sorted((PKG / "services").glob("*.py")) + [PKG / "install.py", PKG / "commands.py"]
		for path in files:
			tree = ast.parse(path.read_text(encoding="utf-8"))
			rel = path.relative_to(REPO).as_posix()
			for node in ast.walk(tree):
				if not isinstance(node, ast.Call):
					continue
				where = f"{rel}:{node.lineno}"
				fn = node.func
				name = fn.id if isinstance(fn, ast.Name) else fn.attr if isinstance(fn, ast.Attribute) else None
				owner = ast.unparse(fn.value) if isinstance(fn, ast.Attribute) else ""
				args = node.args
				kw = {k.arg: k.value for k in node.keywords if k.arg}
				dt = self._const(args[0]) if args else None
				if name == "new_doc" and dt and len(args) > 1:
					self.dict_fields(dt, args[1], where)
				elif name == "fill" and dt and len(args) > 2:
					self.dict_fields(dt, args[2], where)
				elif name == "append_row" and dt and len(args) > 3:
					table = self._const(args[2])
					f = self.field(dt, table, where) if table else None
					if f:
						self.dict_fields(f["options"], args[3], where)
				elif name == "get_doc" and args and isinstance(args[0], ast.Dict):
					d = dict(zip([self._const(k) for k in args[0].keys], args[0].values, strict=True))
					dt2 = self._const(d.get("doctype")) if "doctype" in d else None
					if dt2:
						self.dict_fields(dt2, args[0], where)
				elif name in ("get_doc", "get_single", "get_cached_doc") and dt:
					if dt in self.doctypes:
						self.ok()
					else:
						self.fail(f"{where}: DocType {dt!r} not found")
				elif name in ("get_all", "get_list") and dt:
					if isinstance(kw.get("filters"), ast.Dict):
						for k in kw["filters"].keys:
							if self._const(k):
								self.field(dt, self._const(k), where)
					if "fields" in kw:
						self._fields_arg(dt, kw["fields"], where)
					if "pluck" in kw and self._const(kw["pluck"]):
						self.field(dt, self._const(kw["pluck"]), where)
				elif owner.endswith("db") and name in ("get_value", "get_cached_value") and dt:
					if len(args) > 1 and isinstance(args[1], ast.Dict):
						for k in args[1].keys:
							if self._const(k):
								self.field(dt, self._const(k), where)
					if len(args) > 2:
						self._fields_arg(dt, args[2], where)
				elif name == "get_cached_value" and dt and len(args) > 2:
					self._fields_arg(dt, args[2], where)
				elif owner.endswith("db") and name == "set_value" and dt and len(args) > 2:
					self._fields_arg(dt, args[2], where)
				elif owner.endswith("db") and name == "set_single_value" and dt and len(args) > 1:
					if isinstance(args[1], ast.Dict):
						self.dict_fields(dt, args[1], where)
					else:
						self._fields_arg(dt, args[1], where)
				elif owner.endswith("db") and name == "count" and dt:
					if len(args) > 1 and isinstance(args[1], ast.Dict):
						for k in args[1].keys:
							if self._const(k):
								self.field(dt, self._const(k), where)
					elif dt not in self.doctypes:
						self.fail(f"{where}: DocType {dt!r} not found")

	def manifests(self) -> None:
		for section in ("ROW_FIELDS", "SQL_COLUMNS"):
			for dt, cols in self.refs[section].items():
				for c in cols:
					self.field(dt, c, section)
		for dt, cols in self.refs["SETTINGS"].items():
			for c in cols:
				self.field(dt, c, "SETTINGS")
		chart = (self.roots["erpnext"] / "erpnext/accounts/doctype/account/chart_of_accounts/verified/standard_chart_of_accounts.py").read_text(encoding="utf-8")
		names = set(re.findall(r'_\("([^"]+)"\)', chart))
		for a in self.refs["STANDARD_ACCOUNTS"]:
			(self.ok() if a in names else self.fail(f"STANDARD_ACCOUNTS: {a!r} not in the Standard chart"))
		uoms = {u["uom_name"] for u in json.loads((self.roots["erpnext"] / "erpnext/setup/setup_wizard/data/uom_data.json").read_text(encoding="utf-8"))}
		for u in self.refs["FIXTURE_UOMS"]:
			(self.ok() if u in uoms else self.fail(f"FIXTURE_UOMS: {u!r} not installed by ERPNext"))
		fixtures = (self.roots["erpnext"] / "erpnext/setup/setup_wizard/operations/install_fixtures.py").read_text(encoding="utf-8")
		for m in self.refs["FIXTURE_MODES_OF_PAYMENT"]:
			(self.ok() if re.search(rf'"{re.escape(m)}"', fixtures) else self.fail(f"FIXTURE_MODES_OF_PAYMENT: {m!r} not in fixtures"))
		for pl in self.refs["FIXTURE_PRICE_LISTS"]:
			(self.ok() if f'"price_list_name": _("{pl}")' in fixtures else self.fail(f"FIXTURE_PRICE_LISTS: {pl!r} not in fixtures"))
		catalog = json.loads((PKG / "data" / "catalog.json").read_text(encoding="utf-8"))
		for e in catalog["expenses"]:
			(self.ok() if e["account"] in self.refs["STANDARD_ACCOUNTS"] else self.fail(f"catalog expense account {e['account']!r} not registered"))
		for rows in catalog["items"].values():
			for r in rows:
				(self.ok() if r[1] in self.refs["FIXTURE_UOMS"] else self.fail(f"catalog UOM {r[1]!r} not registered"))

	def app(self) -> None:
		modules = (PKG / "modules.txt").read_text(encoding="utf-8").split()
		module_names = [" ".join(modules)] if modules else []
		for name in ("Distribution Sim Event", "Distribution Sim Settings"):
			d = self.doctypes.get(name)
			if not d:
				self.fail(f"app DocType {name} missing")
				continue
			j = d["json"]
			if j["module"] not in module_names:
				self.fail(f"{name}: module {j['module']!r} not in modules.txt {module_names}")
			if set(j["field_order"]) != set(d["fields"]):
				self.fail(f"{name}: field_order and fields differ")
			if not (d["path"].with_suffix(".py")).exists():
				self.fail(f"{name}: controller missing")
			self.ok()
		hooks = ast.parse((PKG / "hooks.py").read_text(encoding="utf-8"))
		targets = [n.value for n in ast.walk(hooks) if isinstance(n, ast.Constant) and isinstance(n.value, str)
			and n.value.startswith("portfolio_sim.")]
		for t in targets:
			module, func = t.rsplit(".", 1)
			p = self._module_file(module)
			if p and any(isinstance(n, ast.FunctionDef) and n.name == func for n in ast.parse(p.read_text(encoding="utf-8")).body):
				self.ok()
			else:
				self.fail(f"hooks: {t} not found")


def main() -> int:
	ap = argparse.ArgumentParser()
	ap.add_argument("--erpnext", default=str(REPO / "upstream" / "erpnext-v16.60.0"))
	ap.add_argument("--frappe", default=str(REPO / "upstream" / "frappe-v16.60.0"))
	ap.add_argument("--json", action="store_true")
	a = ap.parse_args()
	c = Checker(Path(a.erpnext), Path(a.frappe))
	for step in (c.versions, c.functions, c.methods, c.services, c.manifests, c.app):
		step()
	result = {"pinned": PINNED, "doctypes_indexed": len(c.doctypes), "checks_passed": c.checked, "problems": c.problems}
	if a.json:
		print(json.dumps(result, indent=2))
	else:
		print(f"pinned {PINNED}: {len(c.doctypes)} DocTypes indexed, {c.checked} checks passed, {len(c.problems)} problems")
		for p in c.problems:
			print("  -", p)
	return 1 if c.problems else 0


if __name__ == "__main__":
	sys.exit(main())
