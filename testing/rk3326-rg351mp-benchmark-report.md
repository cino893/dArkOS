# RG351MP (RK3326) hardware run for PR #38

Anbernic RG351MP, Rockchip RK3326, 1 GB RAM, Linux 4.4.189. This file only
summarises the raw logs beside it, and where it disagrees with one of them, the
raw log is right.

---

## 1. `apply-to-installed.sh` did NOT run

```
=== APPLY OUTPUT ===
   !! repository root looks wrong: /
   !! missing: scripts/zram-swap.sh ... portmaster/mod_dArkOS.txt
   !! run this from inside a checkout of the PR branch, as testing/apply-to-installed.sh
```

It was invoked from somewhere that is not a checkout of the branch, so it
refused before touching anything - which is the behaviour it is supposed to
have. `status` confirms it: *"No backup directory at /var/backups/darkos-pr38:
nothing has been applied from this script."*

**Nothing in this section is evidence about the branch.** Whether these changes
land correctly on a running system is still untested.

What `status` actually found, and where it came from:

| # | change | state | why |
|---|---|---|---|
| 1 | PortMaster hook + zram | PARTIAL | files 3/3, `zram-swap` enabled, but `portmaster-hooks.service` disabled. Swap **is** up: `/dev/zram0=458452kB`, `disksize=469458944` - that is `MemTotal/2`, not the `1G` this branch asks for, so it comes from the image |
| 2 | I/O scheduler | PARTIAL | `rule=no`, live `[deadline]` - set by hand earlier, not by any rule |
| 3 | welcome-message ordering | APPLIED | `Before=(empty)` |
| 4 | root mount options | APPLIED | live `rw,noatime,compress=lzo`, `systemd-remount-fs: active`. fstab reads `defaults,noatime,compress=lzo,noatime` - a hand edit, not this branch |
| 5 | `LimitNICE` | **ABSENT** | `LimitNICE=0, drop-in=no` |
| 6 | read-ahead | PARTIAL | `rule=no`, live `512` - set by hand earlier |
| 7 | writeback caps | APPLIED | `file=yes`, `dirty_bytes=33554432` |

The unit is still running an image built from the **first** revision of this PR:
`zram-swap.service` carries `Description=ZRAM Compressed Swap for PortMaster &
Gaming Performance`, a string that exists nowhere else in this branch's history.

---

## 2. `darkos-bench.sh all` - this is the evidence

The benchmark sets up both arms itself and does not care what state the system
is in, so these results stand on their own.

### 2.1 I/O scheduler, `114e557` - DISPROVED, and reverted

128 MB cold sequential read in the foreground, one writer rewriting 32 MB with
`fdatasync` for the whole of every read, three interleaved reps per scheduler:

| rep | cfq | deadline |
|---|---|---|
| 1 | 4451 ms (11 writer passes) | 5948 ms (28) |
| 2 | 3977 ms (15) | 5706 ms (28) |
| 3 | 3163 ms (10) | 5414 ms (26) |
| **median** | **3977 ms (32 MB/s)** | **5706 ms (22 MB/s)** |

cfq wins every rep with no overlap; deadline is **30% slower** for the
foreground reader. The writer pass counts say why - under deadline the writer
got roughly twice the device. CFQ's per-process fairness was protecting the
reader, which is the opposite of the premise the commit rested on.

### 2.2 Writeback caps, `05945cf` - INCONCLUSIVE plus a measured cost, and reverted

536 MB in 4 MB chunks, 2.9x the ratio threshold, baseline arm first so any card
slowdown counts against the treatment:

| arm | med | p95 | max | sync | peak dirty | total |
|---|---|---|---|---|---|---|
| ratios (20/10) | 43 ms | 255 ms | 625 ms | 231 ms | 48 MB | 11748 ms |
| dirty_bytes (32M/8M) | 72 ms | 359 ms | 575 ms | 350 ms | 8 MB | 20558 ms |

The baseline arm peaked at **48 MB** of dirty pages against a threshold of about
**179 MB** - writeback kept up on its own and the throttling point this change
exists to move was never reached. The benchmark's own verdict is therefore
INCONCLUSIVE, and it is right to be.

Meanwhile the cap costs: 46 MB/s down to 26 MB/s, and median, p95 and the
closing sync all get worse. The only number that improves is the single worst
chunk, 625 ms against 575 ms, which is one sample either side.

What was *not* measured is the axis the commit was argued on: a third process -
the emulator - stalling while a large write is in flight. That is the
measurement to bring if this should come back.

### 2.3 Read-ahead, `4442105` - not confirmed

128 MB cold sequential read, no competing I/O, three interleaved reps:

| rep | 128 KB | 512 KB |
|---|---|---|
| 1 | 2174 ms | 2013 ms |
| 2 | 2080 ms | 1989 ms |
| 3 | 2065 ms | **2114 ms** |
| median | 2080 ms | 2013 ms |

3% apart, and the third rep goes the other way. The benchmark calls this within
noise, and it does not reproduce the 9% reported earlier from a less careful
method on this same model. The change is kept because nothing measured argues
against it, but it is not a proven win.

### 2.4 `LimitNICE`, `8fe20cc` - DEMONSTRATED

| probe | result |
|---|---|
| `emulationstation.service` | `User=ark`, `PAMName=` empty, `LimitNICE=0` |
| live ES process (pid 510), `/proc/510/limits` | `Max nice priority 0 0` |
| `nice -n -19` as ark **through su**, so pam_limits runs | achieved **-19** |
| same, with the rlimit ES really has (`ulimit -e 0`) | `Permission denied`, achieved **0** |
| running ES processes | `NI 0` |

The `ark - nice -20` line in limits.conf is correct and works whenever something
applies it. `emulationstation.service` has no `PAMName=`, so nothing does - and
that is the process tree every emulator and port is launched from. All 249
`nice -n -19` calls fail there. `LimitNICE=-20` on the unit is the fix.

---

## 3. What this run settles, and what it does not

Settled: `114e557` is wrong on this hardware and is gone. `05945cf` is
unsupported and costly here and is gone. `8fe20cc` is proved. `4442105` is
unproven but harmless.

Not settled, and unchanged by this run:

* **No image built from this branch has been booted.** Everything above came
  either from the benchmark setting up its own arms, or from a system whose
  state came from an older image and from hand edits.
* `apply-to-installed.sh` has still never completed a run.
* The zram half of `2ac3da2` - the swap on this unit is the image's, not this
  branch's.
* **RK3566 entirely.** Different kernel, different schedulers, 2-4 GB of RAM and
  therefore a completely different writeback threshold. None of it transfers.

---

## 4. Raw logs

* [`rk3326-rg351mp-bench-all.txt`](./rk3326-rg351mp-bench-all.txt) - full A/B benchmark run
* [`rk3326-rg351mp-apply-status.txt`](./rk3326-rg351mp-apply-status.txt) - `apply-to-installed.sh apply` and `status`
* [`rk3326-rg351mp-boot-diag.txt`](./rk3326-rg351mp-boot-diag.txt) - `darkos-diag.sh boot` snapshot
