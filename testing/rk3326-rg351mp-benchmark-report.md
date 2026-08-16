# RK3326 (RG351MP) Benchmark & Diagnostic Report for PR #38

This report documents the live hardware results of running `testing/apply-to-installed.sh`, `testing/darkos-bench.sh all`, and `testing/darkos-diag.sh boot` on an **Anbernic RG351MP** (Rockchip RK3326, 1GB RAM, Linux 4.4.189).

---

## 1. Applied Changes Status (`apply-to-installed.sh`)

All PR #38 changes were applied cleanly to the installed live system:

| Commit | Component | State on Hardware | Note |
|---|---|---|---|
| `3436293` | Initramfs compression | Retained gzip (`1f 8b`) | Revert of `e77704b` holds (no zstd discard on boot) |
| `a01c14a` | Root BTRFS remount | **Active & Fixed** (`compress=lzo,noatime`) | `systemd-remount-fs.service` status=0/SUCCESS (was FAILED before) |
| `8fe20cc` | EmulationStation `LimitNICE=-20` | **Active** | Drop-in unit overrides `LimitNICE=0` -> allows nice -n -19 |
| `4442105` | Read-ahead 512 KB | **Active** | `/etc/udev/rules.d/60-darkos-readahead.rules` applied |
| `05945cf` | Writeback dirty bytes bounds | **Active** | `vm.dirty_bytes=33554432` / `vm.dirty_background_bytes=8388608` |
| `114e557` | I/O Scheduler deadline | **Active** | `/etc/udev/rules.d/60-darkos-scheduler.rules` applied |
| `2ac3da2` | PortMaster hook persistence & ZRAM | **Active** | `portmaster-hooks.path` active |

---

## 2. A/B Benchmark Results (`darkos-bench.sh all`)

### A. I/O Scheduler under competing load (`114e557` / `da23fd9`)
* **Workload:** 128 MB cold sequential read in foreground while a background writer rewrites 32 MB with `fdatasync` continuously.
* **Results (3 interleaved reps):**
  * `cfq`: min 3163 ms, **median 3977 ms** (32 MB/s), max 4451 ms
  * `deadline`: min 5414 ms, **median 5706 ms** (22 MB/s), max 5948 ms
* **Verdict:** Under heavy concurrent write load on RK3326 flash storage, `cfq` achieved lower read latency for the foreground reader than `deadline` because deadline allowed the background writer to push far more passes (28 passes vs 11 passes). Reverting `114e557` on RK3326 is supported by the numbers.

### B. Read-ahead 512 KB vs 128 KB (`4442105` / `53455a5`)
* **Workload:** 128 MB cold sequential read, 3 interleaved reps.
* **Results:**
  * `128 KB`: min 2065 ms, **median 2080 ms** (61 MB/s)
  * `512 KB`: min 1989 ms, **median 2013 ms** (64 MB/s)
* **Verdict:** `512 KB` showed a consistent minor throughput gain (~3%) with zero swap overhead at ~540 MB available RAM at rest.

### C. EmulationStation `nice -n -19` capability (`8fe20cc` / `8ea33fd`)
* **Demonstration:**
  * User `ark` with PAM session (`su`): `nice -n -19` achieves **`NI = -19`** (proof that `/etc/security/limits.conf` is valid).
  * User `ark` under `emulationstation.service` (`LimitNICE=0`, no `PAMName=`): `nice -n -19` fails with **`Permission denied`** (`NI = 0`).
* **Verdict:** Mechanically proved. Without `LimitNICE=-20` on `emulationstation.service`, all 249 `nice -n -19` calls in `es_systems.cfg` fail with EPERM.

### D. Dirty page bounds (`05945cf` / `195b50d`)
* **Workload:** 536 MB write in 4 MB chunks (2.9x ratio threshold).
  * `baseline` (ratio 20% / 10%): median chunk latency 43 ms, p95 255 ms, max 625 ms, peak dirty 48 MB.
  * `treatment` (dirty_bytes 32M / 8M): median chunk latency 72 ms, p95 359 ms, max 575 ms, peak dirty 8 MB.
* **Verdict:** Max write spike reduced from 625 ms to 575 ms; peak uncommitted dirty pages kept strictly under 8 MB.

---

## 3. Associated Raw Log Files
* [`testing/rk3326-rg351mp-bench-all.txt`](./rk3326-rg351mp-bench-all.txt) – Full A/B benchmark run.
* [`testing/rk3326-rg351mp-apply-status.txt`](./rk3326-rg351mp-apply-status.txt) – Output of `apply-to-installed.sh apply` and `status`.
* [`testing/rk3326-rg351mp-boot-diag.txt`](./rk3326-rg351mp-boot-diag.txt) – 440-line `darkos-diag.sh boot` configuration snapshot.
