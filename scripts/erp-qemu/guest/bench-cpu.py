"""CPU micro-benchmark for comparing QEMU-TCG CPU models (interpreter loop, json, regex, sorting, imports)."""
import json, re, subprocess, sys, time

def t(name, fn, n=1):
    s = time.perf_counter()
    for _ in range(n): fn()
    print(f"{name:12s} {time.perf_counter() - s:7.2f}s", flush=True)

doc = {"items": [{"code": f"SKU-{i:05d}", "qty": i % 17, "rate": i * 1.25, "tags": ["a", "b", "c"]} for i in range(2000)]}
t("loop", lambda: sum(i * i for i in range(1_000_000)))
t("json", lambda: json.loads(json.dumps(doc)), 10)
rx = re.compile(r"SKU-(\d+)")
txt = json.dumps(doc)
t("regex", lambda: len(rx.findall(txt)), 10)
t("sort", lambda: sorted(str(i * 7919 % 100003) for i in range(200_000)))
t("import", lambda: subprocess.run([sys.executable, "-c", "import email.mime.text, decimal, asyncio, http.client, xml.dom.minidom, sqlite3"], check=True))
