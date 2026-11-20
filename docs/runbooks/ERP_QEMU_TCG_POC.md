# Runbook: ERPNext in a QEMU-TCG Linux guest on the Windows VPS (no WSL, no Hyper-V, no reboot)

**Status:** in progress (owner directive 2026-11-19). Evidence and measurements: [TEST_RESULTS.md](../TEST_RESULTS.md),
section "M5 — ERPNext under QEMU-TCG".

## Design

| Item | Choice | Why |
|---|---|---|
| Emulator | QEMU 11.1.0 for Windows (qemu.weilnetz.de `qemu-w64-setup-20260811.exe`), **extracted** with 7-Zip into `C:\srv\portfolio\erp\qemu-poc\qemu` — never installed, no registry or PATH change | Official Windows build; SHA-512 verified against the published file (the Authenticode certificate expired in 2023 and the file has no timestamp, so the hash is the integrity check) |
| Acceleration | `-accel tcg` only (software CPU emulation). WHPX/Hyper-V are never used | Owner constraint; the host has no VT-x exposed (no nested virtualization) |
| Machine | `-machine pc,smm=off`, `-cpu max`, 1 vCPU, 1.5 GB RAM, `tb-size=256` | With SMM enabled (q35 **or** pc) SeaBIOS loops in System Management Mode under TCG and the kernel never starts (measured twice) |
| Guest | Debian 13 "trixie" genericcloud qcow2 (SHA-512 verified) as a read-only backing file; `vm\erp.qcow2` is a dynamically allocated overlay (40 GB virtual) | Headless, ~350 MB download; MariaDB 11.8 is the distribution version (same major as CI) |
| Provisioning | cloud-init NoCloud seed served once over loopback (`-smbios ... ds=nocloud;s=http://10.0.2.2:<seed port>/`), then cloud-init disabled | No ISO tooling needed on Windows |
| Network | QEMU user-mode networking; host forwards bound to **127.0.0.1** only: SSH and the ERPNext web port; QMP control on loopback | No public listener, no Caddy route, no firewall change |
| Process | Started by the on-demand scheduled task `Portfolio - ERP QEMU guest` (SYSTEM, below-normal priority, no time limit, no trigger) | A child of an interactive/agent shell dies with it; a process started through WMI `Win32_Process.Create` exited when its WMI provider host was recycled (~27 min) — both measured |
| Watchdog | `scripts/erp-qemu/erp-vm-watch.ps1`: every 30 s host CPU, available memory, commit, QEMU CPU/memory, disk growth and the production endpoints' latency; shuts the guest down on memory pressure, pauses it on sustained latency degradation | Stop conditions of the directive |

## Commands

```powershell
$vm = 'scripts\erp-qemu\erp-vm.ps1'
& $vm -Action init                    # key pair, overlay disk, cloud-init seed (once)
& $vm -Action start -MemoryMB 1536    # boot (first boot applies cloud-init)
& $vm -Action status                  # pid, CPU seconds, memory, disk, port reachability
& $vm -Action ssh -Command 'uptime'   # run a command in the guest
& $vm -Action stop                    # clean ACPI shutdown (QMP system_powerdown)
& $vm -Action kill                    # hard stop (QMP quit / terminate)
& $vm -Action cleanup [-All]          # remove task, disk, logs [and QEMU, downloads]: nothing else to undo
scripts\erp-qemu\erp-vm-watch.ps1 -Calibrate   # latency baseline with the guest stopped or paused
scripts\erp-qemu\erp-vm-watch.ps1              # watchdog while the guest runs
```

Guest scripts (copied to `~/poc` in the guest): `provision-base.sh` (packages, MariaDB, Python 3.14 via uv, Node 24,
yarn, bench), `platform-checks.sh` (Stage C), `install-erpnext.sh` (Stage D), `run-integration.sh` (Stage E).

## Stages and gates

**Stage A — feasibility (passed, memory is the binding constraint).** Host: Xeon Gold 6230R, 3 logical CPUs (no
VT-x exposed), 12 GB RAM, 48 GB free on C:. Production services use ~1.3 GB together; the pressure comes from
interactive desktop applications (editor, browser, chat clients: 8–14 GB private). Available memory varied between
0.6 and 6.2 GB during the day, commit between 72 % and 96 % of a 30.6 GB limit; host CPU averaged ~50–60 %.
Decision: 1 vCPU, 1.5 GB guest RAM (QEMU private ≈ 1.9–2.0 GB incl. translation cache), watchdog limits
available ≥ 1,024 MB and commit ≤ 92 %.

**Stage B — environment (passed after two fixes).** Removable directory, scheduled-task launch, loopback-only
forwards. Fixes: SMM off (boot hang) and Task Scheduler launch (process lifetime).

**Stage C — Linux platform (passed).** Boot to SSH 157–328 s (systemd: 2 min 35 s; first boot with cloud-init
longer). Clean ACPI shutdown and restart with state intact (provisioned runtimes, MariaDB). Fork, subprocess,
flock/fcntl locks, Unix sockets, Redis 8.0.2, background worker with SIGTERM, MariaDB 11.8.6, fsync all work.
Performance: 69 forks/s, 46 subprocess spawns/s, Redis ~1,500 req/s; CPU-bound Python **13–23× slower than the
same code natively on the host** (`bench-cpu.py`: loop 1.81 s vs 0.14 s, json 1.63 s vs 0.07 s, sort 3.66 s vs
0.18 s). `-cpu max` beats `-cpu Nehalem` (no AVX) by ~1.8× on the interpreter loop, so `max` is kept.

**Stage D — ERPNext install (passed).** `bench init` 809 s; `get-app erpnext` + `portfolio_sim` ~40 min (mostly
yarn); `new-site` with ERPNext 5,540 s. Fixes: yarn `network-timeout` (ESOCKETTIMEDOUT), MariaDB admin account for
`127.0.0.1` (error 1130 with `skip-name-resolve`), recovery of a partial bench or site, web without the stat reloader,
and `guest/systemd-units.sh`: one unit per process (Redis cache, Redis queue, gunicorn web, worker, scheduler) with
`Restart=always` instead of `bench start`, whose supervisor stops every process when one exits.

**Stage E — integration tests.** Run 1 was invalidated by infrastructure (see TEST_RESULTS: worker exit after a long
operator pause → the dev supervisor stopped Redis). Run 2 on a fresh site: see TEST_RESULTS.

**Stage F — throughput: failed.** ~0.05 events/s against the 0.35 events/s requirement; the guest is purely
CPU-bound (no I/O wait) and already gets most of one host core. Production latency was not affected while QEMU ran
at below-normal priority.

## Conclusion

QEMU-TCG runs real ERPNext on this VPS without WSL or a reboot, but software CPU emulation makes it about 75× slower
than a native Linux runner end to end: **not practical for permanent operation**. Stage G (production readiness) was
therefore not built on QEMU.

Failure-handling item 9.6 (native Windows) was investigated with a spike: the same pinned Frappe/ERPNext run on
Windows-native Python with ten narrowly scoped runtime adaptations (no upstream file changed,
`scripts/erp-native/`) and pass the same 7 integration tests with results identical to CI, at 1.3–1.4 events/s.
That route needs an owner decision before any further build-out (see `state/checkpoint.json`).

## Stop / remove

```powershell
scripts\erp-qemu\erp-vm.ps1 -Action stop        # clean guest shutdown
scripts\erp-qemu\erp-vm.ps1 -Action cleanup -All # removes the task and C:\srv\portfolio\erp\qemu-poc entirely
```
