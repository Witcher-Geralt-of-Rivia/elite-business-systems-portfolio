"""Scenario construction from the curated catalogue (pure Python).

`build_scenario(catalog, seed)` turns ~500 curated values into the concrete master data of
Sable Ridge Electronics Supply Co.: items with SKUs, costs, list prices and pack sizes; suppliers;
customers with segment, location, terms and payment behaviour; staff. The Frappe setup routine and
the planner both use this function, so master data and simulated activity always agree.
"""

from __future__ import annotations

import json
import math
from dataclasses import asdict, dataclass, field
from datetime import date, timedelta
from pathlib import Path

from .rng import Rng, derive_seed

CATALOG_PATH = Path(__file__).resolve().parent.parent / "data" / "catalog.json"

# Keys whose string values are structural (identifiers, field names, account/UOM names that must match
# ERPNext fixtures), not curated business vocabulary.
_STRUCTURAL_KEYS = {"_about", "abbr", "currency", "country", "chart_of_accounts", "timezone", "key", "role", "prefix",
	"uom", "group", "terms", "account", "taxable_state", "state", "territory", "genders"}


def load_catalog(path: Path | str = CATALOG_PATH) -> dict:
	with open(path, encoding="utf-8") as f:
		return json.load(f)


def curated_values(catalog: dict) -> list[str]:
	"""All curated business strings (names, descriptions, vocabulary), without structural values."""
	out: list[str] = []

	def walk(value, key=None):
		if key in _STRUCTURAL_KEYS:
			return
		if isinstance(value, dict):
			for k, v in value.items():
				walk(v, k)
		elif isinstance(value, list):
			for v in value:
				walk(v, key)
		elif isinstance(value, str):
			out.append(value)

	walk(catalog)
	# Territory names appear as values in several places; count each distinct curated string once.
	seen, unique = set(), []
	for s in out:
		if s not in seen:
			seen.add(s)
			unique.append(s)
	return unique


@dataclass
class Item:
	code: str
	name: str
	group_prefix: str
	group_name: str
	uom: str
	cost: float
	list_price: float
	weight: float
	supplier: str
	pack: int
	description: str = ""


@dataclass
class Customer:
	name: str
	segment: str
	city: str
	state: str
	territory: str
	warehouse: str
	terms: str
	terms_days: int
	discount: float
	orders_per_month: float
	on_time: float
	late_days: float
	installments: float
	batch_payer: bool
	advance_payer: bool
	advance_amount: int
	taxable: bool
	account_manager: str
	since: str
	contact_name: str = ""
	contact_title: str = ""


@dataclass
class Employee:
	first_name: str
	last_name: str
	gender: str
	department: str
	designation: str
	date_of_birth: str
	date_of_joining: str
	sales_person: bool = False
	territories: list[str] = field(default_factory=list)

	@property
	def full_name(self) -> str:
		return f"{self.first_name} {self.last_name}"


@dataclass
class Scenario:
	seed: int
	start: date
	company: dict
	warehouses: list[dict]
	items: list[Item]
	suppliers: list[dict]
	customers: list[Customer]
	employees: list[Employee]
	segments: dict[str, dict]
	catalog: dict

	def item(self, code: str) -> Item:
		return self._items[code]

	def customer(self, name: str) -> Customer:
		return self._customers[name]

	def supplier(self, name: str) -> dict:
		return self._suppliers[name]

	def __post_init__(self):
		self._items = {i.code: i for i in self.items}
		self._customers = {c.name: c for c in self.customers}
		self._suppliers = {s["name"]: s for s in self.suppliers}

	def warehouse_for_territory(self, territory: str) -> str:
		for w in self.warehouses:
			if territory in w["territories"]:
				return w["key"]
		return "DC"

	def to_master_data(self) -> dict:
		"""JSON-serialisable master data (used by the Frappe setup routine and for hashing)."""
		return {
			"items": [asdict(i) for i in self.items],
			"customers": [asdict(c) for c in self.customers],
			"employees": [asdict(e) for e in self.employees],
			"suppliers": self.suppliers,
		}


def _pack_size(cost: float) -> int:
	if cost < 10:
		return 10
	if cost < 50:
		return 5
	if cost < 150:
		return 2
	return 1


def build_scenario(catalog: dict, seed: int, start: date) -> Scenario:
	rng = Rng(derive_seed(seed, "scenario"))
	groups = {g["prefix"]: g for g in catalog["item_groups"]}
	supplier_for = {}
	for s in catalog["suppliers"]:
		for prefix in s["groups"]:
			supplier_for[prefix] = s["name"]

	items: list[Item] = []
	for prefix, rows in catalog["items"].items():
		g = groups[prefix]
		for i, (name, uom, cost, weight) in enumerate(rows, start=1):
			margin = rng.uniform(*g["margin"])
			list_price = math.floor(cost * (1 + margin)) + 0.99 if cost * (1 + margin) >= 5 else round(cost * (1 + margin), 2)
			features = rng.sample(catalog["item_features"], 2)
			items.append(Item(code=f"SRE-{prefix}-{i:03d}", name=name, group_prefix=prefix, group_name=g["name"], uom=uom,
				cost=float(cost), list_price=float(list_price), weight=float(weight), supplier=supplier_for[prefix],
				pack=_pack_size(cost), description=f"{name}. {features[0]}; {features[1].lower()}."))

	# Staff (deterministic names; account managers cover territories).
	firsts, lasts = list(catalog["people"]["first_names"]), list(catalog["people"]["last_names"])
	rng.shuffle(firsts)
	rng.shuffle(lasts)
	employees: list[Employee] = []
	territories = list(catalog["territory_weights"].keys())
	manager_territories = [["Ohio North"], ["Ohio North"], ["Ohio Central", "Out of State"], ["Ohio Central"],
		["Ohio South"], ["Ohio South", "Out of State"]]
	n = 0
	for role in catalog["staff"]:
		for k in range(role["count"]):
			first, last = firsts[n % len(firsts)], lasts[(n * 7) % len(lasts)]
			n += 1
			born = date(1962, 1, 1) + timedelta(days=rng.randint(0, 365 * 38))
			joined = start - timedelta(days=rng.randint(120, 365 * 12))
			employees.append(Employee(first_name=first, last_name=last, gender=rng.choice(catalog["people"]["genders"]),
				department=role["department"], designation=role["designation"], date_of_birth=born.isoformat(),
				date_of_joining=joined.isoformat(), sales_person=bool(role.get("sales_person")),
				territories=manager_territories[k % len(manager_territories)] if role.get("sales_person") else []))
	managers = [e for e in employees if e.sales_person]

	# Customers.
	segments = {s["name"]: s for s in catalog["customer_segments"]}
	total = catalog["customer_count"]
	counts = {s["name"]: max(1, round(total * s["share"])) for s in catalog["customer_segments"]}
	stems = list(catalog["customer_stems"])
	rng.shuffle(stems)
	used: set[str] = set()
	customers: list[Customer] = []
	tw = catalog["territory_weights"]
	cities_by_territory: dict[str, list[dict]] = {}
	for c in catalog["cities"]:
		cities_by_territory.setdefault(c["territory"], []).append(c)
	stem_i = 0
	for seg_name, count in counts.items():
		seg = segments[seg_name]
		for _ in range(count):
			for _attempt in range(50):
				name = f"{stems[stem_i % len(stems)]} {rng.choice(seg['kinds'])}"
				stem_i += 1
				if name not in used:
					break
			used.add(name)
			territory = rng.weighted(territories, [tw[t] for t in territories])
			city = rng.choice(cities_by_territory[territory])
			terms = rng.choice(seg["terms"])
			terms_days = next(t["days"] for t in catalog["payment_terms"] if t["name"] == terms)
			lo, hi = seg["orders_per_month"]
			rate = rng.uniform(lo, hi)
			taxable = (city["state"] == catalog["tax"]["taxable_state"]) and not seg["exempt"]
			advance = rng.chance(seg["advance_payer"])
			covering = [m for m in managers if territory in m.territories] or managers
			customers.append(Customer(
				name=name, segment=seg_name, city=city["name"], state=city["state"], territory=territory,
				warehouse="DC", terms=terms, terms_days=terms_days, discount=float(rng.randint(*seg["discount"])),
				orders_per_month=round(rate, 3), on_time=min(0.97, max(0.2, seg["on_time"] + rng.normal(0, 0.08))),
				late_days=max(2.0, seg["late_days"] * rng.uniform(0.6, 1.5)), installments=seg["installments"],
				batch_payer=rng.chance(seg["batch_payer"]), advance_payer=advance,
				advance_amount=int(round(rate * seg["qty_scale"] * 900, -2)) if advance else 0, taxable=taxable,
				account_manager=rng.choice(covering).full_name,
				since=(start - timedelta(days=rng.randint(60, 365 * 9))).isoformat(),
				contact_name=f"{rng.choice(catalog['people']['first_names'])} {rng.choice(catalog['people']['last_names'])}",
				contact_title=rng.choice(catalog["contact_titles"])))
	scenario = Scenario(seed=seed, start=start, company=catalog["company"], warehouses=catalog["warehouses"], items=items,
		suppliers=catalog["suppliers"], customers=customers, employees=employees, segments=segments, catalog=catalog)
	for c in scenario.customers:
		c.warehouse = scenario.warehouse_for_territory(c.territory)
	return scenario
