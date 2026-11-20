"""Import every module of frappe, erpnext and portfolio_sim on native Windows; report failures by root cause."""
import collections, importlib, pkgutil, sys, traceback
fails = collections.Counter(); examples = {}; total = 0
for pkg in ("frappe", "erpnext", "portfolio_sim"):
    root = importlib.import_module(pkg)
    for m in pkgutil.walk_packages(root.__path__, pkg + ".", onerror=lambda n: None):
        if ".tests" in m.name or m.name.endswith(".test") or "test_" in m.name.rsplit(".", 1)[-1]:
            continue
        total += 1
        try:
            importlib.import_module(m.name)
        except BaseException as e:
            key = f"{type(e).__name__}: {str(e).splitlines()[0][:90] if str(e) else ''}"
            fails[key] += 1; examples.setdefault(key, m.name)
print(f"modules: {total}, failed: {sum(fails.values())}")
for k, n in fails.most_common(25): print(f"{n:5d}  {k}   e.g. {examples[k]}")
