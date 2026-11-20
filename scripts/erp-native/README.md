# Native-Windows Frappe/ERPNext spike (failure-handling item 9.6)

Runs the pinned Frappe v16.60.0 / ERPNext v16.60.0 on Windows-native Python 3.14 **without changing any upstream
file**. Evidence: `docs/TEST_RESULTS.md`, section "M5 — Native Windows spike". Status: **spike** — not a deployment;
no service, no listener beyond 127.0.0.1, nothing public.

| File | Role |
|---|---|
| `site-packages/sitecustomize.py` | import-time shims: missing `signal` constants, `os.register_at_fork`, `faulthandler.register`, `os.nice`; DLL directory for `mysqlclient` |
| `site-packages/resource.py` | `resource.getrusage(RUSAGE_SELF).ru_maxrss` from psutil (prepared reports' peak memory) |
| `frappe_win.py` | launcher: `restore_database` without a bash pipeline, Jinja template paths, `frappe.commands.popen` without `preexec_fn`; then runs `frappe.utils.bench_helper` exactly like `bench` |
| `serve_win.py` | web process: `frappe.app.application` under waitress (gunicorn is Unix-only) |
| `worker_win.py` | background worker: `FrappeWorkerNoFork` with RQ's `TimerDeathPenalty` (no fork, no SIGALRM) |
| `run-frappe.ps1` | runs a Frappe CLI command below normal priority with `PYTHONUTF8=1`, the MariaDB client and bash on PATH |
| `import_probe.py`, `worker_test.py` | the import survey and the worker check used as evidence |

Environment used (under `C:\srv\portfolio\erp\native-spike`, not in this repository): uv 0.13.9, CPython 3.14.10,
venv with `pip install -e` of the pinned sources, `mysqlclient` built with MSVC against the MariaDB client headers
and `libmariadb` import library; MariaDB 11.8.10 zip with its own data directory created with
`lower_case_table_names=2`; Redis 8.10.3 (redis-windows MSYS2 build); `PYTHONUTF8=1`.

Known gaps: desk asset build on Windows (esbuild globbing with backslash paths; Studio's Vite build hangs) — build
assets on Linux or use Frappe's prebuilt assets; scheduler and socket.io processes, Windows services, backups
(Frappe's backup code uses shell pipelines), monitoring and browser E2E are not done.
