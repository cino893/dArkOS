#!/bin/bash
# darkos-bench.sh - NOT FOR MERGE.  A/B measurement for the changes in PR #38
# that are currently arguments rather than numbers.
#
#   sudo bash testing/darkos-bench.sh writeback   05945cf  dirty_bytes vs dirty_ratio
#   sudo bash testing/darkos-bench.sh scheduler   114e557  deadline vs cfq, under load
#   sudo bash testing/darkos-bench.sh readahead   4442105  512 KB vs 128 KB
#   sudo bash testing/darkos-bench.sh nice        8fe20cc  can nice -n -19 work at all
#   sudo bash testing/darkos-bench.sh all         all four, one report
#   bash testing/darkos-bench.sh                  this help
#
# WHY IT EXISTS
#
#   05945cf sets vm.dirty_bytes=32M / vm.dirty_background_bytes=8M.  The only
#   measurement taken so far wrote 64 MB and reported 1408 ms against 1449 ms.
#   That run cannot have decided anything: with the vm.dirty_ratio=20 the kernel
#   ships, the throttling threshold on a 1 GB unit is around 180 MB, so 64 MB
#   never reached it and both arms measured the same unthrottled write.  The
#   change is about the WORST-CASE STALL, not about throughput, so this mode
#   writes well past the threshold and reports the latency of every chunk -
#   min / median / p95 / max - and times the closing sync on its own.
#
#   114e557 replaces CFQ with deadline on RK3326.  Nothing has been measured at
#   all.  What CFQ costs, it costs through slice_idle, which only bites when
#   more than one process wants the device; a lone sequential read cannot show
#   it.  So this mode reads a large file with a writer running against it for
#   the whole read, and reports the foreground read time under each scheduler.
#
#   readahead (4442105) has already been measured once - 100 MB, 128 KB
#   1858 ms against 512 KB 1689 ms - and is included so a second unit can
#   confirm or contradict it, and so all three arms come out of one run.
#
#   nice (8fe20cc) is not a benchmark: it is a demonstration, on the running
#   system, of whether "nice -n -19" can succeed for the ark user at all.
#
# WHAT IT WRITES, AND WHERE
#
#   It picks a scratch directory itself and says which one and why.  The root
#   filesystem on this branch is btrfs with compress=lzo, so writing /dev/zero
#   there would measure the LZO compressor rather than the card; the selection
#   prefers a filesystem with no compression (/roms is exfat) and, whatever it
#   ends up on, writes data that cannot be compressed.  /dev/urandom is far too
#   slow on this SoC to be the source for hundreds of megabytes, so exactly one
#   small buffer is taken from it, in RAM, and re-used - LZO's window is 128 KB
#   at most, well under the buffer size, so repeating it does not make it
#   compressible.  Total bytes are printed before anything is written, and
#   every size is overridable.
#
# WHAT IT CHANGES, AND PUTS BACK
#
#   vm.dirty_* sysctls, the I/O scheduler and read_ahead_kb of one block
#   device.  All are read before anything is touched, restored by a single trap
#   on EXIT INT TERM, and also written into a standalone restore script whose
#   path is printed, for the one case a trap cannot cover: SIGKILL.
#
# TOOLS
#
#   coreutils, util-linux, procps and bash builtins only, all of them already
#   used by testing/darkos-diag.sh on this hardware: dd, date, df, sort, awk,
#   sed, grep, cat, cut, tr, tail, wc, sync, sleep, nice, id, su, ps, kill,
#   readlink, mkdir, rmdir, rm, chmod, uname.  systemctl is used in the nice
#   mode and guarded with a command -v test rather than assumed.
#
#   Explicitly NOT used: bc, python, zramctl, iostat, hdparm, fio, ioping,
#   setpriv, findmnt, lsblk - none of the first six are installed, zramctl is
#   confirmed absent in testing/rk3326-rg351mp-boot-diag.txt:394, and the last
#   three have workarounds here that need nothing.  All arithmetic is integer
#   shell arithmetic; awk is used only to pick fields.  Nothing is downloaded
#   and no package is installed.
#
#   Kernel 4.4 (RK3326) is the target.  It runs on 5.10 (RK3566) too, but the
#   scheduler mode will report that cfq does not exist there, which is correct:
#   114e557 does not apply to that platform.

export LC_ALL=C

###############################################################################
# Small helpers - same shapes as testing/darkos-diag.sh
###############################################################################

have() { command -v "$1" >/dev/null 2>&1; }

SECN=0
hdr() {
    SECN=$((SECN + 1))
    printf '\n===============================================================\n'
    printf '%s. %s\n' "${SECN}" "$1"
    printf -- '---------------------------------------------------------------\n'
}

sub()  { printf '\n-- %s\n' "$1"; }
say()  { printf '%s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
bad()  { printf '   !! %s\n' "$*"; }

note() {
    printf '\n  WHAT THIS DECIDES:\n'
    while [ "$#" -gt 0 ]; do printf '    %s\n' "$1"; shift; done
}

# Read one line into RDV without forking.  Returns 1 if the file is unusable.
RDV=''
rd() {
    RDV=''
    [ -e "$1" ] || return 1
    { read -r RDV < "$1"; } 2>/dev/null || return 1
    [ -n "${RDV}" ]
}

# Percentage by which A exceeds B, integer, guarded against B = 0.
pct_over() {
    if [ "$2" -le 0 ]; then printf '0'; return; fi
    printf '%s' "$((((($1 - $2)) * 100) / $2))"
}

###############################################################################
# Timing
#
# There is no bc and no python here, and awk floating point is not needed: every
# number below is an integer count of milliseconds.  Three primitives are tried
# in order and the one chosen is printed, together with the evidence it works -
# a resolution probe and a one second sleep - because "date +%s%N" is a coreutils
# extension and a busybox date would return the literal string "%N".
#
#   EPOCHREALTIME  bash 5 builtin, microseconds, no fork per reading.
#   date +%s%N     coreutils, nanoseconds, one fork per reading.
#   /proc/uptime   always present, centiseconds, i.e. 10 ms granularity.
#
# EPOCHREALTIME and date read the wall clock, which systemd-timesyncd can step;
# /proc/uptime is monotonic.  A step during a 200 ms chunk is unlikely but is
# the reason a single outlier is never reported on its own below.
###############################################################################

TIMER_MODE=''
TIMER_NAME=''
MS=0

init_timer() {
    local t n
    t="${EPOCHREALTIME:-}"
    case "${t}" in
        [0-9]*.[0-9]*) TIMER_MODE='e'; TIMER_NAME='EPOCHREALTIME (bash builtin, us)'; return 0 ;;
    esac
    n="$(date +%s%N 2>/dev/null)"
    case "${n}" in
        ''|*[!0-9]*) ;;
        *) if [ "${#n}" -ge 18 ]; then
               TIMER_MODE='n'; TIMER_NAME='date +%s%N (coreutils, ns)'; return 0
           fi ;;
    esac
    if [ -r /proc/uptime ]; then
        TIMER_MODE='u'; TIMER_NAME='/proc/uptime (monotonic, 10 ms)'; return 0
    fi
    TIMER_MODE='s'; TIMER_NAME='date +%s (1 s - too coarse, results are indicative only)'
}

now_ms() {
    local t f
    case "${TIMER_MODE}" in
        e)  t="${EPOCHREALTIME}"; f="${t#*.}"; MS=$(( ${t%.*} * 1000 + 10#${f} / 1000 )) ;;
        n)  t="$(date +%s%N 2>/dev/null)"; MS=$(( t / 1000000 )) ;;
        u)  read -r t _ < /proc/uptime; f="${t#*.}"; MS=$(( ${t%.*} * 1000 + 10#${f} * 10 )) ;;
        *)  MS=$(( $(date +%s 2>/dev/null) * 1000 )) ;;
    esac
}

# Prints the evidence for the primitive rather than asserting it.
timer_selftest() {
    local a b i d res=''
    sub "timing primitive"
    info "chosen        : ${TIMER_NAME}"
    info "EPOCHREALTIME : ${EPOCHREALTIME:-(not set - bash older than 5.0)}"
    info "date +%s%N    : $(date +%s%N 2>/dev/null || printf '(failed)')"
    info "/proc/uptime  : $(cut -d' ' -f1 /proc/uptime 2>/dev/null || printf '(missing)')"
    i=0
    while [ "${i}" -lt 6 ]; do
        now_ms; res="${res} ${MS}"
        i=$((i + 1))
    done
    info "6 back-to-back readings (ms):${res}"
    now_ms; a="${MS}"
    sleep 1
    now_ms; b="${MS}"
    d=$((b - a))
    info "sleep 1 measured as ${d} ms"
    if [ "${d}" -ge 800 ] && [ "${d}" -le 1500 ]; then
        info "-> this is a millisecond clock and it runs at the right rate"
    else
        bad "sleep 1 did not come out anywhere near 1000 ms.  Either the clock is"
        bad "not what this script thinks it is, or the machine is heavily loaded."
        bad "Every duration below is suspect until that is explained."
    fi
}

###############################################################################
# Integer statistics
#
# stats_ms "12 400 33 ..." fills ST_N / ST_MIN / ST_MED / ST_P95 / ST_MAX /
# ST_SUM.  Sorting is done by sort -n, indexing by shell arithmetic; the
# percentile is the nearest-rank one, which needs no floating point at all.
###############################################################################

ST_N=0; ST_MIN=0; ST_MED=0; ST_P95=0; ST_MAX=0; ST_SUM=0; ST_DROPPED=0

stats_ms() {
    local v i
    local -a a=()
    ST_N=0; ST_MIN=0; ST_MED=0; ST_P95=0; ST_MAX=0; ST_SUM=0; ST_DROPPED=0
    [ -n "$1" ] || return 1
    # $1 is deliberately unquoted: it is a whitespace separated list of integers.
    while read -r v; do
        # A negative delta can only mean the wall clock stepped mid-measurement.
        # Those samples are dropped, and counted, so the drop is visible.
        case "${v}" in ''|*[!0-9]*) ST_DROPPED=$((ST_DROPPED + 1)); continue ;; esac
        a+=("${v}")
        ST_SUM=$((ST_SUM + v))
    done < <(printf '%s\n' $1 | sort -n)
    ST_N="${#a[@]}"
    [ "${ST_N}" -gt 0 ] || return 1
    ST_MIN="${a[0]}"
    ST_MAX="${a[$((ST_N - 1))]}"
    i=$((ST_N / 2));         [ "${i}" -ge "${ST_N}" ] && i=$((ST_N - 1)); ST_MED="${a[${i}]}"
    i=$(((ST_N * 95) / 100)); [ "${i}" -ge "${ST_N}" ] && i=$((ST_N - 1)); ST_P95="${a[${i}]}"
    return 0
}

print_stats() {
    printf '   %-22s n=%-4s min %6s  med %6s  p95 %6s  max %6s  total %7s ms\n' \
        "$1" "${ST_N}" "${ST_MIN}" "${ST_MED}" "${ST_P95}" "${ST_MAX}" "${ST_SUM}"
    [ "${ST_DROPPED}" -gt 0 ] &&
        bad "${ST_DROPPED} sample(s) discarded as negative - the clock stepped during the run"
    return 0
}

# One decimal place, without floating point: tenths(a, b) prints a/b as "2.9".
tenths() {
    local t
    if [ "$2" -le 0 ]; then printf '?'; return; fi
    t=$((($1 * 10) / $2))
    printf '%s.%s' "$((t / 10))" "$((t % 10))"
}

###############################################################################
# Saved state and cleanup
#
# Everything this script can change is read before it changes anything, and put
# back by one trap.  Each restore is unconditional and ignores errors, so a run
# that died halfway through setting an arm still restores the rest.
###############################################################################

SAVED_D_RATIO=''; SAVED_D_BG_RATIO=''; SAVED_D_BYTES=''; SAVED_D_BG_BYTES=''
SAVED_SCHED=''; SAVED_RA=''
QUEUE=''            # /sys/block/<dev>/queue of the device under test
RESTOREF="/tmp/darkos-bench-restore.$$"
BGDIR=''            # scratch directory actually used
SEED=''; WBFILE=''; RDFILE=''; BGFILE=''; BGCNT=''; BGPIDF=''
BG_PID=''; BG_FLAG=''
CLEANED=0

save_vm_state() {
    rd /proc/sys/vm/dirty_ratio            && SAVED_D_RATIO="${RDV}"
    rd /proc/sys/vm/dirty_background_ratio && SAVED_D_BG_RATIO="${RDV}"
    rd /proc/sys/vm/dirty_bytes            && SAVED_D_BYTES="${RDV}"
    rd /proc/sys/vm/dirty_background_bytes && SAVED_D_BG_BYTES="${RDV}"
}

# The scheduler file reads back as the whole menu - "noop [deadline] cfq" - and
# only the bracketed word is a value the kernel accepts on the way in.
sched_current() {
    local v
    v="$(cat "${QUEUE}/scheduler" 2>/dev/null)"
    case "${v}" in
        *"["*"]"*) printf '%s' "${v}" | sed -n 's/.*\[\([^]]*\)\].*/\1/p' ;;
        *)         printf '%s' "${v}" ;;
    esac
}

save_dev_state() {
    [ -n "${QUEUE}" ] || return 1
    SAVED_SCHED="$(sched_current)"
    rd "${QUEUE}/read_ahead_kb" && SAVED_RA="${RDV}"
    return 0
}

write_restore_file() {
    {
        printf '#!/bin/bash\n'
        printf '# Written by darkos-bench.sh, pid %s.  Run this ONLY if that script was\n' "$$"
        printf '# killed with SIGKILL and so could not restore these itself.  A normal exit,\n'
        printf '# an error exit and Ctrl-C all restore them and delete this file.\n'
        if [ -n "${SAVED_D_BYTES}" ] && [ "${SAVED_D_BYTES}" != "0" ]; then
            printf 'echo %s > /proc/sys/vm/dirty_bytes\n' "${SAVED_D_BYTES}"
            printf 'echo %s > /proc/sys/vm/dirty_background_bytes\n' "${SAVED_D_BG_BYTES:-8388608}"
        else
            printf 'echo %s > /proc/sys/vm/dirty_ratio\n' "${SAVED_D_RATIO:-20}"
            printf 'echo %s > /proc/sys/vm/dirty_background_ratio\n' "${SAVED_D_BG_RATIO:-10}"
        fi
        [ -n "${QUEUE}" ] && [ -n "${SAVED_SCHED}" ] &&
            printf 'echo %s > %s/scheduler\n' "${SAVED_SCHED}" "${QUEUE}"
        [ -n "${QUEUE}" ] && [ -n "${SAVED_RA}" ] &&
            printf 'echo %s > %s/read_ahead_kb\n' "${SAVED_RA}" "${QUEUE}"
        # Removing the flag file is also how the background writer is told to
        # stop: it tests for that file once per pass and exits when it is gone.
        [ -n "${BGDIR}" ] && printf 'rm -f %s/* 2>/dev/null; rmdir %s 2>/dev/null\n' "${BGDIR}" "${BGDIR}"
        printf 'rm -f %s\n' "${RESTOREF}"
    } > "${RESTOREF}" 2>/dev/null
    chmod 700 "${RESTOREF}" 2>/dev/null
}

restore_vm() {
    [ -n "${SAVED_D_RATIO}${SAVED_D_BYTES}" ] || return 0
    if [ -n "${SAVED_D_BYTES}" ] && [ "${SAVED_D_BYTES}" != "0" ]; then
        printf '%s\n' "${SAVED_D_BYTES}" > /proc/sys/vm/dirty_bytes 2>/dev/null
        printf '%s\n' "${SAVED_D_BG_BYTES:-8388608}" > /proc/sys/vm/dirty_background_bytes 2>/dev/null
    else
        printf '%s\n' "${SAVED_D_RATIO:-20}" > /proc/sys/vm/dirty_ratio 2>/dev/null
        printf '%s\n' "${SAVED_D_BG_RATIO:-10}" > /proc/sys/vm/dirty_background_ratio 2>/dev/null
    fi
}

restore_dev() {
    [ -n "${QUEUE}" ] || return 0
    [ -n "${SAVED_SCHED}" ] && printf '%s\n' "${SAVED_SCHED}" > "${QUEUE}/scheduler" 2>/dev/null
    [ -n "${SAVED_RA}" ] && printf '%s\n' "${SAVED_RA}" > "${QUEUE}/read_ahead_kb" 2>/dev/null
    return 0
}

# The background writer is a subshell running dd in a loop.  Killing the
# subshell does not kill the dd it is currently waiting on - that dd is
# reparented, keeps writing and keeps the scratch file busy - so it is stopped
# three ways: the flag file it tests every iteration is removed, the subshell is
# killed, and the pid it recorded for its own dd is killed after checking that
# the pid really is that dd and not a recycled one.
stop_bg() {
    local p
    [ -n "${BG_FLAG}" ] && rm -f "${BG_FLAG}" 2>/dev/null
    if [ -n "${BG_PID}" ]; then
        kill "${BG_PID}" 2>/dev/null
        wait "${BG_PID}" 2>/dev/null
    fi
    if [ -n "${BGPIDF}" ] && [ -r "${BGPIDF}" ]; then
        read -r p < "${BGPIDF}" 2>/dev/null
        case "${p}" in
            ''|*[!0-9]*) ;;
            *) if grep -qsaF -- "${BGFILE}" "/proc/${p}/cmdline" 2>/dev/null; then
                   kill "${p}" 2>/dev/null; sleep 1; kill -9 "${p}" 2>/dev/null
               fi ;;
        esac
    fi
    BG_PID=''
    return 0
}

cleanup() {
    [ "${CLEANED}" = "1" ] && return 0
    CLEANED=1
    stop_bg
    restore_dev
    restore_vm
    for f in "${SEED}" "${WBFILE}" "${RDFILE}" "${BGFILE}" "${BGCNT}" "${BGPIDF}" "${BG_FLAG}"; do
        [ -n "${f}" ] && rm -f "${f}" 2>/dev/null
    done
    # By name as well as by variable: a run that died before a mode set its
    # variable would otherwise leave the file behind.  Named explicitly rather
    # than with a wildcard - this is a directory built from a path the caller
    # supplied, and rm -rf on one of those is how test scripts eat filesystems.
    if [ -n "${BGDIR}" ]; then
        for f in wb.dat read.dat bg.dat bg.run bg.count bg.pid; do
            rm -f "${BGDIR}/${f}" 2>/dev/null
        done
        rmdir "${BGDIR}" 2>/dev/null
    fi
    rm -f "${RESTOREF}" 2>/dev/null
    return 0
}

trap 'cleanup' EXIT
trap 'printf "\n\ninterrupted - restoring\n"; cleanup; exit 130' INT TERM

###############################################################################
# Target selection
#
# Where the scratch file goes decides whether the measurement means anything.
#
#  - btrfs with compress=lzo (this branch mounts / that way) compresses on the
#    way to the card, so a file of zeroes would measure the compressor.  The
#    data written below is incompressible, which removes that, but the
#    compressor still runs and costs CPU, so a filesystem without compression is
#    preferred where one exists.
#  - fuse filesystems put a userspace daemon between write() and the card, and
#    the dirty pages that the writeback limits act on then belong to the
#    daemon's reads and writes of the block device rather than to this script.
#    Avoided when there is any alternative, reported when there is not.
#  - tmpfs is excluded outright: it never reaches the card and its pages are not
#    accounted for dirty throttling at all.
#
# Preference order among what is left: most free space wins, which on these
# units is /roms - the exfat partition where the ROMs, saves and states that
# actually stall live.
###############################################################################

TDIR=''; TDEV=''; TFSTYPE=''; TOPTS=''; TFUSE=no; TCOMP=no

# Longest mountpoint prefix of a path, from /proc/mounts.  findmnt would do it in
# one line but this needs no tool at all, and it sees exactly what the kernel
# sees.  Later lines win ties, which is what an over-mount means.
# Prints: DEVICE MOUNTPOINT FSTYPE OPTIONS
mount_of() {
    local path="$1" best='' bestlen=0 dev fs opts mp len
    path="$(readlink -f "${path}" 2>/dev/null)"
    [ -n "${path}" ] || return 1
    while read -r dev mp fs opts _; do
        [ -n "${mp}" ] || continue
        if [ "${mp}" = "/" ]; then
            len=1
        else
            case "${path}" in
                "${mp}"|"${mp}"/*) ;;
                *) continue ;;
            esac
            len="${#mp}"
        fi
        if [ "${len}" -ge "${bestlen}" ]; then
            bestlen="${len}"; best="${dev} ${mp} ${fs} ${opts}"
        fi
    done < /proc/mounts
    [ -n "${best}" ] || return 1
    printf '%s' "${best}"
}

fstype_of() {
    local m
    m="$(mount_of "$1")" || return 1
    m="${m#* }"; m="${m#* }"
    printf '%s' "${m%% *}"
}

avail_mb() { df -P -k "$1" 2>/dev/null | awk 'NR == 2 { print int($4 / 1024) }'; }

# Everything sysfs knows about the queue lives on the whole device, never on the
# partition, so /dev/mmcblk0p3 has to become /sys/block/mmcblk0.  /sys/class/block
# holds both, which /sys/block does not, so the partition is found there first and
# its parent is the directory its symlink resolves into.
queue_for_dev() {
    local dev="$1" b parent
    dev="$(readlink -f "${dev}" 2>/dev/null)"
    case "${dev}" in
        /dev/*) ;;
        *) return 1 ;;
    esac
    b="${dev##*/}"
    [ -n "${b}" ] || return 1
    if [ -d "/sys/class/block/${b}/queue" ]; then
        printf '/sys/class/block/%s/queue' "${b}"
        return 0
    fi
    if [ -e "/sys/class/block/${b}" ]; then
        parent="$(readlink -f "/sys/class/block/${b}" 2>/dev/null)"
        parent="${parent%/*}"
        parent="${parent##*/}"
        if [ -n "${parent}" ] && [ -d "/sys/class/block/${parent}/queue" ]; then
            printf '/sys/class/block/%s/queue' "${parent}"
            return 0
        fi
    fi
    return 1
}

candidate_line() {
    local mp="$1" m dev fs opts comp fuse av
    m="$(mount_of "${mp}")" || return 1
    dev="${m%% *}"; m="${m#* }"
    mp="${m%% *}";  m="${m#* }"
    fs="${m%% *}";  opts="${m#* }"
    case "${fs}" in
        tmpfs|ramfs|devtmpfs|proc|sysfs|cgroup*|overlay|squashfs|nfs*|cifs) return 1 ;;
    esac
    case "${dev}" in /dev/*) ;; *) return 1 ;; esac
    case "${fs}" in fuse|fuseblk|fuse.*) fuse=yes ;; *) fuse=no ;; esac
    case ",${opts}," in *,compress=*|*,compress-force=*) comp=yes ;; *) comp=no ;; esac
    case ",${opts}," in *,ro,*) return 1 ;; esac
    av="$(avail_mb "$1")"
    case "${av}" in ''|*[!0-9]*) return 1 ;; esac
    printf '%s %s %s %s %s %s' "$1" "${dev}" "${fs}" "${fuse}" "${comp}" "${av}"
}

pick_target() {
    local want="$1" line best='' bestscore=-1 score mp dev fs fuse comp av
    sub "scratch filesystem"
    if [ -n "${want}" ] && { [ ! -d "${want}" ] || [ ! -w "${want}" ]; }; then
        bad "--dir ${want} is not a writable directory - falling back to the list below"
        want=''
    fi
    printf '   %-14s %-16s %-9s %-5s %-9s %s\n' MOUNT DEVICE FSTYPE FUSE COMPRESS 'AVAIL MB'
    for mp in "${want}" /roms /home /var/tmp / /tmp; do
        [ -n "${mp}" ] || continue
        [ -d "${mp}" ] || continue
        [ -w "${mp}" ] || continue
        line="$(candidate_line "${mp}")" || continue
        set -- ${line}
        mp="$1"; dev="$2"; fs="$3"; fuse="$4"; comp="$5"; av="$6"
        # One candidate per block device: /var/tmp and / are the same card, the
        # same queue and the same scheduler, so listing both says nothing.
        case " ${SEEN_MPS} " in *" ${dev} "*) continue ;; esac
        SEEN_MPS="${SEEN_MPS} ${dev}"
        printf '   %-14s %-16s %-9s %-5s %-9s %s\n' "${mp}" "${dev}" "${fs}" "${fuse}" "${comp}" "${av}"
        # Free space decides between equals; fuse and compression are penalties
        # heavy enough that a smaller clean filesystem still wins.
        score="${av}"
        [ "${fuse}" = yes ] && score=$((score - 100000))
        [ "${comp}" = yes ] && score=$((score - 50000))
        [ -n "${want}" ] && [ "${mp}" = "${want}" ] && score=$((score + 1000000))
        if [ "${score}" -gt "${bestscore}" ]; then
            bestscore="${score}"
            best="${line}"
        fi
    done
    if [ -z "${best}" ]; then
        bad "no writable block-backed filesystem found - cannot benchmark anything"
        return 1
    fi
    set -- ${best}
    TDIR="$1"; TDEV="$2"; TFSTYPE="$3"; TFUSE="$4"; TCOMP="$5"; TAVAIL="$6"
    return 0
}
SEEN_MPS=''
TAVAIL=0

###############################################################################
# Data source
#
# /dev/urandom on RK3326 delivers single-digit MB/s, so streaming 500 MB from it
# would measure the random pool and nothing else.  One buffer is taken from it
# once, into RAM, and every write below is that buffer repeated.  Repetition
# does not make it compressible: btrfs compresses in 128 KB units, LZO's window
# is smaller still, and neither can see across the buffer boundary.  The time
# the buffer took is printed, which is also the evidence for why it is not the
# source directly.
###############################################################################

SEED_MB=8
seed_dir() {
    local d
    for d in /dev/shm /run /tmp; do
        [ -d "${d}" ] && [ -w "${d}" ] || continue
        case "$(fstype_of "${d}")" in
            tmpfs|ramfs) printf '%s' "${d}"; return 0 ;;
        esac
    done
    for d in /run /tmp; do
        [ -d "${d}" ] && [ -w "${d}" ] && { printf '%s' "${d}"; return 0; }
    done
    return 1
}

make_seed() {
    local d t0 t1
    d="$(seed_dir)" || { bad "no writable directory for the source buffer"; return 1; }
    SEED="${d}/darkos-bench-seed.$$"
    sub "incompressible source buffer"
    info "location : ${SEED}"
    now_ms; t0="${MS}"
    dd if=/dev/urandom of="${SEED}" bs=1048576 count="${SEED_MB}" 2>/dev/null
    now_ms; t1="${MS}"
    if [ ! -s "${SEED}" ]; then
        bad "could not fill the source buffer from /dev/urandom"
        return 1
    fi
    info "${SEED_MB} MB from /dev/urandom took $((t1 - t0)) ms"
    if [ "$((t1 - t0))" -gt 0 ]; then
        info "-> that is about $(((SEED_MB * 1000) / (t1 - t0))) MB/s: streaming it"
        info "   directly would have measured the random pool, not the card"
    fi
    return 0
}

###############################################################################
# Common primitives
###############################################################################

DROP_OK=unknown
drop_caches() {
    sync 2>/dev/null
    if [ -w /proc/sys/vm/drop_caches ]; then
        if printf '3\n' > /proc/sys/vm/drop_caches 2>/dev/null; then
            DROP_OK=yes; return 0
        fi
    fi
    DROP_OK=no
    return 1
}

# Write SIZE_MB into $1 by repeating the seed buffer.  Not timed; this is setup.
make_datafile() {
    local out="$1" mb="$2" done_mb=0 step rc=0 sz
    rm -f "${out}" 2>/dev/null
    step="${SEED_MB}"
    while [ "${done_mb}" -lt "${mb}" ]; do
        [ $((mb - done_mb)) -lt "${step}" ] && step=$((mb - done_mb))
        dd if="${SEED}" bs=1048576 count="${step}" >> "${out}" 2>/dev/null || rc=1
        [ "${rc}" = 0 ] || break
        done_mb=$((done_mb + step))
    done
    sync 2>/dev/null
    [ "${rc}" = 0 ] || return 1
    # A short file would quietly turn into a faster read and a wrong MB/s, so
    # the size is checked rather than inferred from dd's exit status.
    sz="$(wc -c < "${out}" 2>/dev/null)"
    case "${sz}" in ''|*[!0-9]*) return 1 ;; esac
    if [ "$((sz / 1048576))" -lt "${mb}" ]; then
        bad "${out} came out at $((sz / 1048576)) MB instead of ${mb} MB"
        return 1
    fi
    return 0
}

# Cold sequential read of $1, $2 MB.  Returns the time in TIMED_MS.
TIMED_MS=0
timed_read() {
    local f="$1" mb="$2" t0 t1
    drop_caches
    now_ms; t0="${MS}"
    dd if="${f}" of=/dev/null bs=1048576 count="${mb}" 2>/dev/null
    now_ms; t1="${MS}"
    TIMED_MS=$((t1 - t0))
}

# The floor under every per-chunk number below: one dd of the same size that
# never touches the card.  Whatever is left after subtracting this is I/O.
fork_floor() {
    local mb="$1" i=0 t0 t1 s=''
    while [ "${i}" -lt 5 ]; do
        now_ms; t0="${MS}"
        dd if="${SEED}" of=/dev/null bs=1048576 count="${mb}" 2>/dev/null
        now_ms; t1="${MS}"
        s="${s} $((t1 - t0))"
        i=$((i + 1))
    done
    stats_ms "${s}"
    printf '%s' "${ST_MED}"
}

start_bg() {
    local mb="$1"
    BG_FLAG="${BGDIR}/bg.run"
    BGCNT="${BGDIR}/bg.count"
    BGPIDF="${BGDIR}/bg.pid"
    BGFILE="${BGDIR}/bg.dat"
    : > "${BGCNT}" 2>/dev/null
    : > "${BG_FLAG}" 2>/dev/null || return 1
    (
        while [ -e "${BG_FLAG}" ]; do
            dd if="${SEED}" of="${BGFILE}" bs=1048576 count="${mb}" conv=notrunc,fdatasync \
               2>/dev/null &
            printf '%s\n' "$!" > "${BGPIDF}" 2>/dev/null
            wait $! 2>/dev/null
            printf 'x\n' >> "${BGCNT}" 2>/dev/null
        done
    ) &
    BG_PID="$!"
    return 0
}

bg_iters() {
    local n
    n="$(wc -l < "${BGCNT}" 2>/dev/null)"
    case "${n}" in ''|*[!0-9]*) printf '0' ;; *) printf '%s' "${n}" ;; esac
}

###############################################################################
# State the run found
###############################################################################

report_found_state() {
    local f
    sub "state this system was in before the run"
    info "MemTotal              : $(awk '/^MemTotal:/ { print $2 " kB" }' /proc/meminfo 2>/dev/null)"
    info "vm.dirty_ratio        : ${SAVED_D_RATIO:-?}"
    info "vm.dirty_background_ratio : ${SAVED_D_BG_RATIO:-?}"
    info "vm.dirty_bytes        : ${SAVED_D_BYTES:-?}"
    info "vm.dirty_background_bytes : ${SAVED_D_BG_BYTES:-?}"
    for f in /etc/sysctl.d/60-darkos-writeback.conf \
             /etc/udev/rules.d/60-darkos-scheduler.rules \
             /etc/udev/rules.d/60-darkos-readahead.rules; do
        if [ -f "${f}" ]; then info "${f}: present"; else info "${f}: absent"; fi
    done
    info "/ mount options       : $(mount_of / 2>/dev/null)"
    # Not in the nice mode: that one is advertised as read-only, and dropping
    # the page cache is a system-wide side effect even though it is harmless.
    if [ "${MODE}" != nice ]; then
        if drop_caches; then
            info "page cache            : /proc/sys/vm/drop_caches accepted a 3 - every read"
            info "                        arm below starts cold, and each one drops it again"
        else
            bad "/proc/sys/vm/drop_caches could not be written.  Every read arm after"
            bad "the first will be reading out of page cache and the read comparisons"
            bad "below are worthless.  Do not quote them."
        fi
    fi
    if [ -n "${QUEUE}" ]; then
        info "device under test     : ${TDEV} -> ${QUEUE}"
        info "scheduler found       : ${SAVED_SCHED:-?}   (menu: $(cat "${QUEUE}/scheduler" 2>/dev/null))"
        info "read_ahead_kb found   : ${SAVED_RA:-?}"
        info "rotational            : $(cat "${QUEUE}/rotational" 2>/dev/null)"
        info "nr_requests           : $(cat "${QUEUE}/nr_requests" 2>/dev/null)"
    fi
    printf '\n'
    info "Each arm below sets its own values, so it does not matter whether"
    info "apply-to-installed.sh has been run; the values above are only recorded"
    info "so the report says which state it started from, and restored at the end."
}

###############################################################################
# writeback - 05945cf
###############################################################################

WB_RAN=no
WB_BASE_MAX=0; WB_BASE_P95=0; WB_BASE_MED=0; WB_BASE_SYNC=0; WB_BASE_PEAK=0; WB_BASE_TOT=0
WB_TRT_MAX=0;  WB_TRT_P95=0;  WB_TRT_MED=0;  WB_TRT_SYNC=0;  WB_TRT_PEAK=0;  WB_TRT_TOT=0
WB_THRESH_MB=0; WB_TOTAL_MB=0; WB_FLOOR=0
WB_MEMMB=0; WB_RATIO=0; WB_BGRATIO=0; WB_RATIO_SRC=''; WB_CAPPED=no

# Sizing lives on its own because the announcement of how much this will write
# to the card has to come BEFORE anything is written, and the writeback mode is
# the only one whose size is computed rather than given.  Idempotent: the second
# call finds WB_TOTAL_MB already set and leaves it alone.
wb_compute_size() {
    local memkb
    [ "${WB_THRESH_MB}" -gt 0 ] && return 0
    memkb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null)"
    case "${memkb}" in ''|*[!0-9]*) return 1 ;; esac
    WB_MEMMB=$((memkb / 1024))

    # The threshold the kernel actually uses is a percentage of DIRTYABLE memory
    # (free plus reclaimable page cache), not of MemTotal, so MemTotal * ratio is
    # an upper bound on it.  Sizing off the upper bound is the safe direction: it
    # guarantees the run crosses the real threshold rather than stopping short,
    # which is precisely how the 64 MB attempt in the PR went wrong.
    if [ -n "${SAVED_D_RATIO}" ] && [ "${SAVED_D_RATIO}" != "0" ]; then
        WB_RATIO="${SAVED_D_RATIO}"; WB_BGRATIO="${SAVED_D_BG_RATIO:-10}"
        WB_RATIO_SRC="read from this kernel"
    else
        WB_RATIO=20; WB_BGRATIO=10
        WB_RATIO_SRC="kernel default - this system is in dirty_bytes mode, so the ratio it would fall back to cannot be read"
    fi
    WB_THRESH_MB=$(((WB_MEMMB * WB_RATIO) / 100))
    [ "${WB_THRESH_MB}" -lt 1 ] && WB_THRESH_MB=1

    if [ "${WB_TOTAL_MB}" -le 0 ]; then
        WB_TOTAL_MB=$((WB_THRESH_MB * 3))
        [ "${WB_TOTAL_MB}" -lt 192 ] && WB_TOTAL_MB=192
        # Free space is the only cap.  A fixed one would quietly stop clearing
        # the threshold on a 2-4 GB unit.
        if [ "${WB_TOTAL_MB}" -gt $((TAVAIL - 128)) ]; then
            WB_TOTAL_MB=$((TAVAIL - 128))
            WB_CAPPED=yes
        fi
    fi
    [ "${WB_TOTAL_MB}" -lt 0 ] && WB_TOTAL_MB=0
    WB_TOTAL_MB=$(((WB_TOTAL_MB / CHUNK_MB) * CHUNK_MB))
    [ "${WB_TOTAL_MB}" -lt "${CHUNK_MB}" ] && WB_TOTAL_MB="${CHUNK_MB}"
    return 0
}

vm_show() {
    printf '   in force now: dirty_ratio=%s dirty_background_ratio=%s dirty_bytes=%s dirty_background_bytes=%s\n' \
        "$(cat /proc/sys/vm/dirty_ratio 2>/dev/null)" \
        "$(cat /proc/sys/vm/dirty_background_ratio 2>/dev/null)" \
        "$(cat /proc/sys/vm/dirty_bytes 2>/dev/null)" \
        "$(cat /proc/sys/vm/dirty_background_bytes 2>/dev/null)"
}

# The two pairs are mutually exclusive: writing either member of one pair makes
# the kernel zero the corresponding member of the other.  So each arm is set
# explicitly and then read back, rather than assumed.
vm_arm_ratio() {
    printf '%s\n' "$1" > /proc/sys/vm/dirty_ratio 2>/dev/null
    printf '%s\n' "$2" > /proc/sys/vm/dirty_background_ratio 2>/dev/null
}

vm_arm_bytes() {
    printf '%s\n' "$1" > /proc/sys/vm/dirty_bytes 2>/dev/null
    printf '%s\n' "$2" > /proc/sys/vm/dirty_background_bytes 2>/dev/null
}

# One arm: write WB_TOTAL_MB in CHUNK_MB pieces, timing each piece, then sync.
WB_SAMPLES=''; WB_SYNC=0; WB_PEAK=0
wb_run_arm() {
    local i=0 n t0 t1 s0 s1 rc=0 k v skip nskip
    WB_SAMPLES=''; WB_SYNC=0; WB_PEAK=0
    n=$((WB_TOTAL_MB / CHUNK_MB))
    nskip=$((SEED_MB / CHUNK_MB)); [ "${nskip}" -lt 1 ] && nskip=1
    rm -f "${WBFILE}" 2>/dev/null
    drop_caches
    # Created and checked before exec touches it: a redirection failure on exec
    # is one of the few things that can take the whole shell down with it.
    : > "${WBFILE}" 2>/dev/null || { bad "cannot create ${WBFILE}"; return 1; }
    exec 9>"${WBFILE}" || { bad "cannot open ${WBFILE}"; return 1; }
    while [ "${i}" -lt "${n}" ]; do
        skip=$(((i % nskip) * CHUNK_MB))
        now_ms; t0="${MS}"
        dd if="${SEED}" bs=1048576 skip="${skip}" count="${CHUNK_MB}" >&9 2>/dev/null
        rc="$?"
        now_ms; t1="${MS}"
        WB_SAMPLES="${WB_SAMPLES} $((t1 - t0))"
        if [ "${rc}" != 0 ]; then bad "write failed after $((i * CHUNK_MB)) MB"; break; fi
        # Sampled between chunks, never inside a timed section.
        while read -r k v _; do
            case "${k}" in
                Dirty:) [ "${v}" -gt "${WB_PEAK}" ] && WB_PEAK="${v}"; break ;;
            esac
        done < /proc/meminfo
        i=$((i + 1))
    done
    exec 9>&-
    now_ms; s0="${MS}"
    sync 2>/dev/null
    now_ms; s1="${MS}"
    WB_SYNC=$((s1 - s0))
    rm -f "${WBFILE}" 2>/dev/null
    sync 2>/dev/null
    [ "${rc}" = 0 ]
}

mode_writeback() {
    hdr "writeback: vm.dirty_bytes vs vm.dirty_ratio (commit 05945cf)"

    if ! wb_compute_size; then
        bad "cannot read MemTotal from /proc/meminfo - skipping this mode"
        return 1
    fi

    sub "sizing"
    info "MemTotal                    : ${WB_MEMMB} MB"
    info "vm.dirty_ratio used to size : ${WB_RATIO} % (${WB_RATIO_SRC})"
    info "  -> ratio threshold        : <= ${WB_THRESH_MB} MB dirty before the kernel throttles"
    info "  -> background threshold   : <= $(((WB_MEMMB * WB_BGRATIO) / 100)) MB before it starts flushing"
    info "treatment threshold         : 32 MB (dirty_bytes=33554432, from"
    info "                              scripts/60-darkos-writeback.conf)"
    info "this run writes             : ${WB_TOTAL_MB} MB per arm, in ${CHUNK_MB} MB chunks, 2 arms"
    info "  -> $(tenths "${WB_TOTAL_MB}" "${WB_THRESH_MB}")x the ratio threshold, $((WB_TOTAL_MB * 2)) MB written in total"
    [ "${WB_CAPPED}" = yes ] &&
        bad "capped by free space on ${TDIR} (${TAVAIL} MB) - it wanted $((WB_THRESH_MB * 3)) MB"
    if [ "$((WB_TOTAL_MB * 10 / WB_THRESH_MB))" -lt 15 ]; then
        bad "less than 1.5x the threshold.  On a machine with this much RAM that is"
        bad "a thin margin; if the two arms come out flat, that may be why rather"
        bad "than the change being useless.  --size $((WB_THRESH_MB * 3)) is what it wanted."
    fi
    if [ "${WB_THRESH_MB}" -gt 64 ]; then
        info "the earlier 64 MB attempt was $((64 * 100 / WB_THRESH_MB))% of this threshold, which is why"
        info "it cannot have shown anything on a unit this size"
    else
        info "note: on THIS machine 64 MB is $((64 * 100 / WB_THRESH_MB))% of the threshold and would have"
        info "crossed it.  The objection to the earlier measurement was specific to 1 GB."
    fi

    if [ "${TAVAIL}" -lt $((WB_TOTAL_MB + 128)) ]; then
        bad "${TDIR} has ${TAVAIL} MB free, needs $((WB_TOTAL_MB + 128)) MB - skipping this mode"
        bad "re-run with --dir DIR pointing somewhere with room, or --size MB"
        return 1
    fi

    WB_FLOOR="$(fork_floor "${CHUNK_MB}")"
    info "per-chunk floor (same dd, no card involved): ${WB_FLOOR} ms - subtract this"
    info "from min/median before reading anything into them"

    WBFILE="${BGDIR}/wb.dat"

    sub "arm A - baseline: ratios, as the kernel ships them"
    vm_arm_ratio "${WB_RATIO}" "${WB_BGRATIO}"
    vm_show
    wb_run_arm
    stats_ms "${WB_SAMPLES}"
    print_stats "chunk latency"
    WB_BASE_MED="${ST_MED}"; WB_BASE_P95="${ST_P95}"; WB_BASE_MAX="${ST_MAX}"; WB_BASE_TOT="${ST_SUM}"
    WB_BASE_SYNC="${WB_SYNC}"; WB_BASE_PEAK=$((WB_PEAK / 1024))
    info "closing sync                : ${WB_BASE_SYNC} ms"
    info "peak Dirty seen during it   : ${WB_BASE_PEAK} MB"

    sub "arm B - treatment: dirty_bytes=32M / dirty_background_bytes=8M"
    vm_arm_bytes 33554432 8388608
    vm_show
    wb_run_arm
    stats_ms "${WB_SAMPLES}"
    print_stats "chunk latency"
    WB_TRT_MED="${ST_MED}"; WB_TRT_P95="${ST_P95}"; WB_TRT_MAX="${ST_MAX}"; WB_TRT_TOT="${ST_SUM}"
    WB_TRT_SYNC="${WB_SYNC}"; WB_TRT_PEAK=$((WB_PEAK / 1024))
    info "closing sync                : ${WB_TRT_SYNC} ms"
    info "peak Dirty seen during it   : ${WB_TRT_PEAK} MB"

    restore_vm
    WB_RAN=yes

    sub "side by side"
    printf '   %-12s %10s %10s %10s %10s %10s\n' arm med p95 max sync 'peak MB'
    printf '   %-12s %10s %10s %10s %10s %10s\n' baseline \
        "${WB_BASE_MED}" "${WB_BASE_P95}" "${WB_BASE_MAX}" "${WB_BASE_SYNC}" "${WB_BASE_PEAK}"
    printf '   %-12s %10s %10s %10s %10s %10s\n' treatment \
        "${WB_TRT_MED}" "${WB_TRT_P95}" "${WB_TRT_MAX}" "${WB_TRT_SYNC}" "${WB_TRT_PEAK}"

    note \
      "The claim is about the worst case, so max, p95 and the closing sync are" \
      "the numbers that count.  Total time is expected to be roughly equal:" \
      "the same bytes reach the same card either way." \
      "peak Dirty is the check on the run itself.  If the baseline arm's peak" \
      "never got near ${WB_THRESH_MB} MB the workload never reached the threshold and" \
      "the comparison is void - that is exactly what went wrong with the 64 MB" \
      "measurement quoted in the PR." \
      "Order effect: the baseline arm runs first, so any card slowdown over" \
      "the run counts AGAINST the treatment, never for it."
    return 0
}

###############################################################################
# scheduler - 114e557
###############################################################################

SC_RAN=no; SC_CFQ_MED=0; SC_DL_MED=0; SC_CFQ_LIST=''; SC_DL_LIST=''
SC_BG_TOTAL_MB=0; SC_BG_PASSES=0; SC_NOTE=''

sched_set() {
    local want="$1" got
    printf '%s\n' "${want}" > "${QUEUE}/scheduler" 2>/dev/null
    sleep 1
    got="$(sched_current)"
    [ "${got}" = "${want}" ]
}

mode_scheduler() {
    local rep i0 i1 arm need

    hdr "scheduler: deadline vs cfq with competing I/O (commit 114e557)"

    if [ -z "${QUEUE}" ]; then
        bad "no block device resolved - skipping"
        return 1
    fi
    sub "what this device offers"
    info "queue                : ${QUEUE}"
    info "scheduler menu       : $(cat "${QUEUE}/scheduler" 2>/dev/null)"
    case "$(cat "${QUEUE}/scheduler" 2>/dev/null)" in
        *cfq*) ;;
        *) bad "this kernel has no cfq - nothing to compare against."
           bad "On RK3566/5.10 that is correct and expected: 114e557 is RK3326 only."
           SC_NOTE='cfq not available on this kernel'
           return 1 ;;
    esac

    need=$((RD_MB + BG_MB + 64))
    if [ "${TAVAIL}" -lt "${need}" ]; then
        bad "${TDIR} has ${TAVAIL} MB free, needs ${need} MB - skipping"
        return 1
    fi

    RDFILE="${BGDIR}/read.dat"
    if [ ! -s "${RDFILE}" ]; then
        info "creating the ${RD_MB} MB file to read..."
        make_datafile "${RDFILE}" "${RD_MB}" || { bad "could not create it"; return 1; }
    fi
    BGFILE="${BGDIR}/bg.dat"
    info "creating the ${BG_MB} MB file the background writer rewrites..."
    make_datafile "${BGFILE}" "${BG_MB}" || { bad "could not create it"; return 1; }

    sub "load"
    info "foreground : cold sequential read of ${RD_MB} MB, timed - this is the number"
    info "background : one writer rewriting ${BG_MB} MB over and over, fdatasync each"
    info "             pass, running for the whole of every foreground read"
    info "reps       : ${REPS} per scheduler, arms interleaved so a card that slows"
    info "             down over the run cannot favour either one"

    start_bg "${BG_MB}" || { bad "could not start the background writer"; return 1; }
    sleep 2
    if [ "$(bg_iters)" = "0" ]; then
        sleep 3
    fi

    rep=1
    while [ "${rep}" -le "${REPS}" ]; do
        for arm in cfq deadline; do
            if ! sched_set "${arm}"; then
                bad "could not switch to ${arm} - arm skipped"
                continue
            fi
            i0="$(bg_iters)"
            timed_read "${RDFILE}" "${RD_MB}"
            i1="$(bg_iters)"
            printf '   rep %-2s %-9s read %6s ms   background passes during it: %s\n' \
                "${rep}" "${arm}" "${TIMED_MS}" "$((i1 - i0))"
            if [ "${arm}" = cfq ]; then
                SC_CFQ_LIST="${SC_CFQ_LIST} ${TIMED_MS}"
            else
                SC_DL_LIST="${SC_DL_LIST} ${TIMED_MS}"
            fi
        done
        rep=$((rep + 1))
    done

    SC_BG_PASSES="$(bg_iters)"
    SC_BG_TOTAL_MB=$((SC_BG_PASSES * BG_MB))
    stop_bg
    restore_dev

    sub "result"
    if stats_ms "${SC_CFQ_LIST}"; then
        print_stats "cfq read"
        SC_CFQ_MED="${ST_MED}"
    fi
    if stats_ms "${SC_DL_LIST}"; then
        print_stats "deadline read"
        SC_DL_MED="${ST_MED}"
    fi
    if [ "${SC_DL_MED}" -gt 0 ] && [ "${SC_CFQ_MED}" -gt 0 ]; then
        info "median throughput: cfq $(((RD_MB * 1000) / SC_CFQ_MED)) MB/s, deadline $(((RD_MB * 1000) / SC_DL_MED)) MB/s"
        SC_RAN=yes
    fi
    info "background writer did ${SC_BG_PASSES} passes, ${SC_BG_TOTAL_MB} MB written by it in total"
    if [ "${SC_BG_PASSES}" -lt "$((REPS * 2))" ]; then
        bad "the background writer completed fewer passes than there were reads:"
        bad "the competing load may not have covered every read.  Treat as weak evidence."
        SC_NOTE='background writer completed very few passes'
    fi

    note \
      "CFQ's cost is slice_idle: it holds the device idle for a few milliseconds" \
      "after each request in case that process asks again, which is a win on a" \
      "seeking disk and pure latency on flash.  It only shows up when a second" \
      "process wants the device, which is why the reads above run against a" \
      "writer and not on their own." \
      "deadline faster than cfq by a clear margin supports 114e557." \
      "Equal times mean CFQ costs nothing measurable here and the commit is a" \
      "change without a benefit - defensible on principle, but say so."
    return 0
}

###############################################################################
# readahead - 4442105
###############################################################################

RA_RAN=no; RA_128_MED=0; RA_512_MED=0; RA_128_LIST=''; RA_512_LIST=''

ra_set() {
    printf '%s\n' "$1" > "${QUEUE}/read_ahead_kb" 2>/dev/null
    rd "${QUEUE}/read_ahead_kb" && [ "${RDV}" = "$1" ]
}

mode_readahead() {
    local rep arm

    hdr "read-ahead: 512 KB vs 128 KB, sequential read (commit 4442105)"

    if [ -z "${QUEUE}" ]; then bad "no block device resolved - skipping"; return 1; fi

    if [ "${TAVAIL}" -lt $((RD_MB + 64)) ]; then
        bad "${TDIR} has ${TAVAIL} MB free, needs $((RD_MB + 64)) MB - skipping"
        return 1
    fi
    RDFILE="${BGDIR}/read.dat"
    if [ ! -s "${RDFILE}" ]; then
        info "creating the ${RD_MB} MB file to read..."
        make_datafile "${RDFILE}" "${RD_MB}" || { bad "could not create it"; return 1; }
    fi

    sub "load"
    info "cold sequential read of ${RD_MB} MB, no competing I/O, ${REPS} reps per arm,"
    info "arms interleaved.  read_ahead_kb is set on ${QUEUE}."
    if [ "${TFUSE}" = yes ]; then
        bad "the scratch filesystem is fuse: reads go through the fuse BDI first and"
        bad "this knob only reaches the card indirectly.  The number is still real,"
        bad "but it is not the clean measurement of read-ahead it looks like."
    fi

    rep=1
    while [ "${rep}" -le "${REPS}" ]; do
        for arm in 128 512; do
            if ! ra_set "${arm}"; then
                bad "could not set read_ahead_kb=${arm} - arm skipped"
                continue
            fi
            timed_read "${RDFILE}" "${RD_MB}"
            printf '   rep %-2s %-9s read %6s ms  (%s MB/s)\n' \
                "${rep}" "${arm} KB" "${TIMED_MS}" \
                "$([ "${TIMED_MS}" -gt 0 ] && printf '%s' "$(((RD_MB * 1000) / TIMED_MS))" || printf '?')"
            if [ "${arm}" = 128 ]; then
                RA_128_LIST="${RA_128_LIST} ${TIMED_MS}"
            else
                RA_512_LIST="${RA_512_LIST} ${TIMED_MS}"
            fi
        done
        rep=$((rep + 1))
    done
    restore_dev

    sub "result"
    if stats_ms "${RA_128_LIST}"; then print_stats "128 KB read"; RA_128_MED="${ST_MED}"; fi
    if stats_ms "${RA_512_LIST}"; then print_stats "512 KB read"; RA_512_MED="${ST_MED}"; fi
    [ "${RA_128_MED}" -gt 0 ] && [ "${RA_512_MED}" -gt 0 ] && RA_RAN=yes

    note \
      "The first unit to run this reported 100 MB in 1858 ms at 128 KB and" \
      "1689 ms at 512 KB, a 9% gain.  This is here so a second unit can confirm" \
      "or contradict that, not to re-derive it." \
      "Note the sizes are not comparable across units or cards - only the ratio" \
      "between the two arms on the SAME unit is."
    return 0
}

###############################################################################
# nice - 8fe20cc
#
# Not a benchmark.  The claim under test is that emulationstation.service runs
# with User=ark and no PAMName=, so pam_limits never runs for it, the
# "ark - nice -20" line in limits.conf never applies, and every one of the 249
# "nice -n -19" calls in es_systems.cfg fails with EPERM.
#
# Demonstrated rather than asserted, in four steps:
#
#   1. the unit's own properties, from systemctl show;
#   2. RLIMIT_NICE of the ES process that is actually running, from
#      /proc/PID/limits - this is the ground truth, everything ES starts
#      inherits it;
#   3. a nice -n -19 attempt as ark WITH pam_limits in the way (su runs PAM),
#      which is expected to succeed and so proves limits.conf itself is fine;
#   4. the same attempt as ark with RLIMIT_NICE lowered to what ES actually has
#      - a faithful reproduction of the ES environment without needing setpriv,
#      because a process may always lower its own limit.
#
# The difference between 3 and 4 is the whole argument.  Nothing here writes to
# the system; the only side effect is two processes that live for milliseconds.
###############################################################################

NI_RAN=no; NI_ES_LIMIT=''; NI_PAM_NI=''; NI_ESLIKE_NI=''; NI_GAME_LINES=''

EMU_RE='retroarch|retrorun|drastic|ppsspp|dolphin|flycast|duckstation|mupen64|yabasanshiro|scummvm|amiberry|hypseus|singe|daphne|openbor|gzdoom|lzdoom|mednafen|pcsx|solarus|ecwolf|xroar|openmsx|bigpemu|pico8|fake08|easyrpg|applewin|linapple|ti99sim|piemu|mvem|gametank|box86|box64|kodi-gbm|mame|vice|minivmac|freej2me|emulationstatio'

mode_nice() {
    local espid p out rc

    hdr "nice: can nice -n -19 succeed for ark at all (commit 8fe20cc)"

    sub "1. what the unit asks for"
    if have systemctl; then
        systemctl show emulationstation.service \
            -p User -p PAMName -p LimitNICE -p LimitNICESoft -p FragmentPath 2>/dev/null |
            sed 's/^/   /'
    else
        bad "systemctl not available"
    fi
    info "LimitNICE is reported in rlimit form: 40 means nice -20 is allowed,"
    info "0 or empty means no negative nice at all.  PAMName= empty is the point:"
    info "without it systemd never opens a PAM session, so pam_limits never runs."

    sub "2. what a running emulationstation actually got"
    espid=''
    for p in $(ps -eo pid,comm 2>/dev/null | awk '$2 ~ /emulationstatio/ { print $1 }'); do
        espid="${p}"; break
    done
    if [ -n "${espid}" ] && [ -r "/proc/${espid}/limits" ]; then
        printf '   pid %s /proc/%s/limits:\n' "${espid}" "${espid}"
        grep -i 'nice' "/proc/${espid}/limits" 2>/dev/null | sed 's/^/     /'
        # "Max nice priority   SOFT   HARD" - the kernel prints no units column
        # for this one (fs/proc/base.c), so the soft limit is field 4.
        NI_ES_LIMIT="$(awk '/Max nice priority/ { print $4 }' "/proc/${espid}/limits" 2>/dev/null)"
        case "${NI_ES_LIMIT}" in
            ''|*[!0-9]*) info "could not parse a number out of that line" ;;
            *) info "soft limit ${NI_ES_LIMIT} means the lowest nice ES and its children may"
               info "ask for is $((20 - NI_ES_LIMIT))" ;;
        esac
    else
        bad "emulationstation is not running - start it and re-run for step 2."
        bad "Steps 3 and 4 below do not need it."
    fi

    sub "3. nice -n -19 as ark, through su, so pam_limits DOES run"
    if id ark >/dev/null 2>&1; then
        # The probe has to report ITS OWN nice, not the shell's: nice(1) changes
        # only the process it starts.  cut is that process, and field 19 of
        # /proc/self/stat is the nice value - safe to take by position here
        # because "cut" contains no space or bracket to confuse the parse.
        out="$(su ark -s /bin/bash -c 'nice -n -19 cut -d" " -f19 /proc/self/stat' 2>&1)"
        rc="$?"
        NI_PAM_NI="$(printf '%s' "${out}" | tr -d ' ' | tail -n 1)"
        printf '   result: rc=%s  nice achieved: %s\n' "${rc}" "${NI_PAM_NI:-?}"
        [ -n "${out}" ] && printf '   raw: %s\n' "$(printf '%s' "${out}" | tr '\n' ' ')"
        info "this is NOT the path ES takes.  It is here to show limits.conf is"
        info "correct and does work - when something actually applies it."
    else
        bad "no user 'ark' on this system - steps 3 and 4 skipped"
    fi

    sub "4. the same attempt with the rlimit ES really has"
    if id ark >/dev/null 2>&1; then
        out="$(su ark -s /bin/bash -c 'ulimit -e 0 2>/dev/null; nice -n -19 cut -d" " -f19 /proc/self/stat' 2>&1)"
        rc="$?"
        NI_ESLIKE_NI="$(printf '%s' "${out}" | tr -d ' ' | tail -n 1)"
        printf '   result: rc=%s  nice achieved: %s\n' "${rc}" "${NI_ESLIKE_NI:-?}"
        [ -n "${out}" ] && printf '   raw: %s\n' "$(printf '%s' "${out}" | tr '\n' ' ')"
        info "ulimit -e 0 lowers RLIMIT_NICE to the value step 2 read off the real"
        info "ES process.  A process may always lower its own limit, so this needs"
        info "no setpriv and reproduces the ES environment exactly.  su is used for"
        info "the uid only - the limit it inherits from PAM is thrown away here."
        info "GNU nice prints a diagnostic and runs the command anyway, so the exit"
        info "status is not the evidence - the nice value above is."
        NI_RAN=yes
    else
        bad "skipped with step 3: there is no ark user on this system"
    fi

    sub "5. what is running right now, and at what priority"
    NI_GAME_LINES="$(ps -eo pid,ni,pri,user,comm 2>/dev/null |
        grep -E "${EMU_RE}" 2>/dev/null | grep -v grep)"
    if [ -n "${NI_GAME_LINES}" ]; then
        printf '   %s\n' 'PID NI PRI USER COMMAND'
        printf '%s\n' "${NI_GAME_LINES}" | sed 's/^/   /'
    else
        info "no emulator or emulationstation process found."
        info "For the strongest evidence: start a game, leave it running, and re-run"
        info "this mode over SSH.  ES starts games with nice -n -19 (es_systems.cfg),"
        info "so NI=0 on a running game is the failure, in production, first hand."
    fi

    note \
      "NI = -19 on a running game means the mechanism works and 8fe20cc is" \
      "unnecessary.  NI = 0 on a running game means all 249 of those calls are" \
      "failing and 8fe20cc is the fix." \
      "Step 3 succeeding while step 4 fails is the proof that the limits.conf" \
      "line is fine and it is the missing PAM session, not the line, that breaks it."
    return 0
}

###############################################################################
# Verdict
###############################################################################

print_verdict() {
    local d p

    hdr "VERDICT"

    printf '\nCLAIM 1 - 05945cf, vm.dirty_bytes=32M cuts the worst-case write stall\n'
    if [ "${WB_RAN}" != yes ]; then
        printf '  INCONCLUSIVE - the writeback mode did not run to completion.\n'
        printf '  Nothing above supports or refutes it.\n'
    elif [ "${WB_BASE_PEAK}" -lt $((WB_THRESH_MB / 2)) ]; then
        printf '  INCONCLUSIVE - the baseline arm peaked at %s MB dirty against a\n' "${WB_BASE_PEAK}"
        printf '  threshold of about %s MB, so it never reached the throttling point\n' "${WB_THRESH_MB}"
        printf '  this change is about.  Re-run with a larger --size.\n'
    else
        d=$((WB_BASE_SYNC - WB_TRT_SYNC))
        p="$(pct_over "${WB_BASE_SYNC}" "${WB_TRT_SYNC}")"
        printf '  closing sync : baseline %s ms, treatment %s ms (%s ms, %s%% apart)\n' \
            "${WB_BASE_SYNC}" "${WB_TRT_SYNC}" "${d}" "${p}"
        printf '  worst chunk  : baseline %s ms, treatment %s ms\n' "${WB_BASE_MAX}" "${WB_TRT_MAX}"
        printf '  p95 chunk    : baseline %s ms, treatment %s ms\n' "${WB_BASE_P95}" "${WB_TRT_P95}"
        printf '  total time   : baseline %s ms, treatment %s ms\n' "${WB_BASE_TOT}" "${WB_TRT_TOT}"
        if [ "${d}" -gt 200 ] && [ "${p}" -gt 25 ]; then
            printf '  SUPPORTED on the sync axis: the pile of dirty pages waiting at sync\n'
            printf '  time is smaller, and that wait is what a save-state or a gamelist\n'
            printf '  write makes the user sit through.\n'
        elif [ "${WB_BASE_MAX}" -gt "${WB_TRT_MAX}" ] &&
             [ "$(pct_over "${WB_BASE_MAX}" "${WB_TRT_MAX}")" -gt 25 ]; then
            printf '  SUPPORTED on the worst-chunk axis, not on sync.\n'
        elif [ "${WB_TRT_MAX}" -gt "${WB_BASE_MAX}" ] &&
             [ "$(pct_over "${WB_TRT_MAX}" "${WB_BASE_MAX}")" -gt 25 ]; then
            printf '  NOT SUPPORTED - and worse than that, the treatment arm has the\n'
            printf '  LONGER worst case here.  That is an argument for reverting 05945cf.\n'
        else
            printf '  NOT SUPPORTED - no axis moved by more than 25%%, which is inside what\n'
            printf '  this many chunks can separate from run-to-run variation on an SD\n'
            printf '  card.  On this unit, with this card, the change buys nothing that\n'
            printf '  shows.  Read the four lines above before repeating that anywhere:\n'
            printf '  a difference smaller than 25%% is still visible in them.\n'
        fi
    fi

    printf '\nCLAIM 2 - 114e557, deadline beats CFQ on RK3326 under competing I/O\n'
    if [ "${SC_RAN}" != yes ]; then
        printf '  INCONCLUSIVE - the scheduler mode did not produce two comparable arms.\n'
        [ -n "${SC_NOTE}" ] && printf '  Reason: %s\n' "${SC_NOTE}"
    else
        d=$((SC_CFQ_MED - SC_DL_MED))
        p="$(pct_over "${SC_CFQ_MED}" "${SC_DL_MED}")"
        printf '  foreground read, median of %s: cfq %s ms, deadline %s ms (%s ms, %s%%)\n' \
            "${REPS}" "${SC_CFQ_MED}" "${SC_DL_MED}" "${d}" "${p}"
        printf '  competing writer: %s MB written during the run\n' "${SC_BG_TOTAL_MB}"
        if [ "${p}" -gt 10 ]; then
            printf '  SUPPORTED - deadline is faster by more than 10%% with a writer in the\n'
            printf '  way, which is the situation the commit is about.\n'
        elif [ "${p}" -lt -10 ]; then
            printf '  NOT SUPPORTED - cfq is the faster one here.  Revert 114e557.\n'
        elif [ "${p}" -ge -5 ] && [ "${p}" -le 5 ]; then
            printf '  NOT SUPPORTED - within 5%%, i.e. within noise.  CFQ is not costing\n'
            printf '  this unit anything measurable and the commit is a change without a\n'
            printf '  demonstrated benefit.\n'
        else
            printf '  INCONCLUSIVE - between 5%% and 10%%, which %s reps cannot separate\n' "${REPS}"
            printf '  from run-to-run variation.  Re-run with --reps 7.\n'
        fi
        [ -n "${SC_NOTE}" ] && printf '  Caveat: %s\n' "${SC_NOTE}"
    fi

    printf '\nSUPPORTING - 4442105, read_ahead_kb=512\n'
    if [ "${RA_RAN}" != yes ]; then
        printf '  Not run, or only one arm produced a number.\n'
    else
        p="$(pct_over "${RA_128_MED}" "${RA_512_MED}")"
        printf '  128 KB %s ms, 512 KB %s ms, %s%% apart\n' "${RA_128_MED}" "${RA_512_MED}" "${p}"
        if [ "${p}" -gt 5 ]; then
            printf '  CONFIRMS the earlier 9%% result on a second unit.\n'
        elif [ "${p}" -lt -5 ]; then
            printf '  CONTRADICTS the earlier result: 128 KB is faster on this unit.\n'
        else
            printf '  Neither confirms nor contradicts: within noise on this unit.\n'
        fi
    fi

    printf '\nSUPPORTING - 8fe20cc, LimitNICE=-20\n'
    if [ "${NI_RAN}" != yes ]; then
        printf '  Not run.\n'
    else
        printf '  as ark with PAM (su)          : nice came out as %s\n' "${NI_PAM_NI:-?}"
        printf '  as ark with the ES rlimit     : nice came out as %s\n' "${NI_ESLIKE_NI:-?}"
        printf '  RLIMIT_NICE of the live ES    : %s\n' "${NI_ES_LIMIT:-ES not running}"
        if [ "${NI_PAM_NI}" = "-19" ] && [ -n "${NI_ESLIKE_NI}" ] && [ "${NI_ESLIKE_NI}" != "-19" ]; then
            printf '  DEMONSTRATED: the limits.conf line works when PAM applies it and\n'
            printf '  does nothing when it does not.  Since emulationstation.service has\n'
            printf '  no PAMName=, the second case is the one running in production, and\n'
            printf '  8fe20cc is the fix for it.\n'
        elif [ "${NI_PAM_NI}" = "-19" ] && [ "${NI_ESLIKE_NI}" = "-19" ]; then
            printf '  NOT DEMONSTRATED: the attempt succeeded even with RLIMIT_NICE at 0,\n'
            printf '  which should be impossible for a non-root process.  Check that su\n'
            printf '  really dropped to ark before drawing any conclusion from this run.\n'
        elif [ -n "${NI_PAM_NI}" ] && [ "${NI_PAM_NI}" != "-19" ]; then
            printf '  PARTLY DEMONSTRATED: even WITH pam_limits the attempt failed, so on\n'
            printf '  this system the limits.conf line is not reaching ark at all.  The\n'
            printf '  conclusion for 8fe20cc is unchanged - nice -n -19 cannot work as\n'
            printf '  things stand - but the reason is broader than the missing PAMName=.\n'
        else
            printf '  NOT DEMONSTRATED - read the two numbers above before concluding.\n'
        fi
    fi

    printf '\nNothing above was measured on RK3566.  None of it transfers: different\n'
    printf 'kernel, different schedulers, 2-4 GB of RAM and therefore a completely\n'
    printf 'different ratio threshold.\n'
}

###############################################################################
# Entry point
###############################################################################

usage() {
    cat <<'EOF'
darkos-bench.sh - settle the unmeasured parts of PR #38 with numbers.

  sudo bash testing/darkos-bench.sh writeback
      Does vm.dirty_bytes=32M actually cut the stall?  Writes past the
      ratio-based threshold twice, once under the ratios the kernel ships and
      once under the byte limits this branch installs, and reports the latency
      of every chunk plus the closing sync.  The claim is about the worst case,
      so max, p95 and sync are what it reports; total time is expected to be
      the same either way.

  sudo bash testing/darkos-bench.sh scheduler
      Is deadline faster than CFQ here?  Times a cold sequential read with a
      writer running against it for the whole read, under each scheduler,
      interleaved.  Without the competing writer the question is meaningless:
      CFQ costs what it costs through slice_idle.

  sudo bash testing/darkos-bench.sh readahead
      128 KB against 512 KB, cold sequential read.  Already measured once on
      one unit; this is for a second opinion.

  sudo bash testing/darkos-bench.sh nice
      Read-only.  Shows LimitNICE on the unit, the RLIMIT_NICE a live
      emulationstation actually got, what nice -n -19 does as ark with PAM in
      the way and with the rlimit ES really has, and the NI of any game that is
      running.

  sudo bash testing/darkos-bench.sh all
      All four in one report, with a verdict block at the end.

Options:
  --dir DIR        scratch directory (default: chosen and explained at run time)
  --size MB        bytes per writeback arm (default: 3x the ratio threshold)
  --read-size MB   file size for the read tests (default 128)
  --bg-size MB     file the background writer rewrites (default 32)
  --reps N         repetitions per read arm (default 3)

It writes hundreds of MB to the card and prints the exact total before it does.
Every value it changes - vm.dirty_*, scheduler, read_ahead_kb - is restored by a
trap on EXIT, INT and TERM, and also written to a standalone restore script
whose path is printed, in case the run is SIGKILLed.

Save the output:
  sudo bash testing/darkos-bench.sh all > /tmp/darkos-bench.txt 2>&1

Run "nice" a second time with a game actually running: that is the one number
in the whole report that comes from production rather than from a test rig.
EOF
}

MODE=''
CHUNK_MB=4
RD_MB=128
BG_MB=32
REPS=3
WB_TOTAL_MB=0
WANT_DIR=''

MODE="${1:-}"
case "${MODE}" in
    ''|-h|--help|help) usage; exit 0 ;;
    writeback|scheduler|readahead|nice|all) shift ;;
    *) printf 'Unknown mode: %s\n\n' "${MODE}"; usage; exit 2 ;;
esac

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dir|--size|--read-size|--bg-size|--reps)
            if [ "$#" -lt 2 ]; then
                printf '%s needs a value\n\n' "$1"; usage; exit 2
            fi ;;
        *) printf 'Unknown option: %s\n\n' "$1"; usage; exit 2 ;;
    esac
    case "$1" in
        --dir)       WANT_DIR="$2" ;;
        --size)      WB_TOTAL_MB="$2" ;;
        --read-size) RD_MB="$2" ;;
        --bg-size)   BG_MB="$2" ;;
        --reps)      REPS="$2" ;;
    esac
    shift 2
done

check_num() {
    case "$2" in
        ''|*[!0-9]*) printf 'Not a number: %s %s\n' "$1" "$2"; exit 2 ;;
    esac
}
check_num --size "${WB_TOTAL_MB}"
check_num --read-size "${RD_MB}"
check_num --bg-size "${BG_MB}"
check_num --reps "${REPS}"
[ "${REPS}" -lt 1 ] && REPS=1
[ "${RD_MB}" -lt 16 ] && RD_MB=16
[ "${BG_MB}" -lt "${SEED_MB}" ] && BG_MB="${SEED_MB}"

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    printf 'This must run as root: it writes vm sysctls, the I/O scheduler and\n'
    printf 'read_ahead_kb, drops the page cache between arms, and the nice mode\n'
    printf 'switches user to demonstrate the rlimit.\n'
    printf 'Re-run it yourself:  sudo bash %s %s\n' "$0" "${MODE}"
    exit 1
fi

printf 'dArkOS A/B benchmark - mode: %s\n' "${MODE}"
printf 'kernel %s   %s\n' "$(uname -r 2>/dev/null)" "$(date 2>/dev/null)"

hdr "Setup"
init_timer
timer_selftest
save_vm_state

if [ "${MODE}" = nice ]; then
    report_found_state
    mode_nice
    print_verdict
    printf '\nDone.  Nothing on this system was modified by the nice mode.\n'
    exit 0
fi

pick_target "${WANT_DIR}" || exit 1
QUEUE="$(queue_for_dev "${TDEV}")"
if [ -z "${QUEUE}" ]; then
    bad "cannot map ${TDEV} to a /sys/class/block queue - scheduler and read-ahead"
    bad "modes will be skipped; the writeback mode does not need it."
fi
save_dev_state
write_restore_file

sub "chosen"
info "scratch directory : ${TDIR}"
info "filesystem        : ${TFSTYPE} on ${TDEV}, fuse=${TFUSE}, compression=${TCOMP}"
info "free space        : ${TAVAIL} MB"
info "queue             : ${QUEUE:-(not resolved)}"
if [ "${TCOMP}" = yes ]; then
    bad "this filesystem compresses.  Every byte written below is incompressible"
    bad "by construction, so the compressor cannot cheat the result - but it does"
    bad "still run, and it costs CPU on both arms equally."
fi
if [ "${TFUSE}" = yes ]; then
    bad "this filesystem is fuse.  A userspace daemon sits between write() and the"
    bad "card, so the dirty pages the writeback limits act on are partly its, not"
    bad "this script's.  The comparison is still A/B and still valid, but it is"
    bad "measuring a longer path than the one the commit talks about."
fi
info "restore script    : ${RESTOREF} (deleted on a clean or interrupted exit)"

BGDIR="${TDIR}/darkos-bench-$$"
mkdir -p "${BGDIR}" 2>/dev/null || { bad "cannot create ${BGDIR}"; exit 1; }

make_seed || exit 1
report_found_state

# Announce the wear before doing any of it.
TOTAL_ANNOUNCED=0
sub "how much this will write to the card"
case "${MODE}" in
    writeback|all)
        if wb_compute_size; then
            info "writeback : ${WB_TOTAL_MB} MB per arm x 2 arms = $((WB_TOTAL_MB * 2)) MB, deleted afterwards"
            info "            (sized from MemTotal - the reasoning is printed in that section)"
            TOTAL_ANNOUNCED=$((TOTAL_ANNOUNCED + WB_TOTAL_MB * 2))
        else
            info "writeback : size unknown, /proc/meminfo could not be read"
        fi ;;
esac
case "${MODE}" in
    scheduler|all)
        info "scheduler : ${RD_MB} MB read file + ${BG_MB} MB writer file, created once."
        info "            Then the writer rewrites its ${BG_MB} MB continuously for the"
        info "            length of $((REPS * 2)) reads.  That part is time-bounded, not"
        info "            size-bounded, so it cannot be predicted exactly - expect a few"
        info "            hundred MB; the exact figure is reported at the end of the mode."
        TOTAL_ANNOUNCED=$((TOTAL_ANNOUNCED + RD_MB + BG_MB)) ;;
esac
case "${MODE}" in
    readahead)
        info "readahead : ${RD_MB} MB read file, created once, then read only"
        TOTAL_ANNOUNCED=$((TOTAL_ANNOUNCED + RD_MB)) ;;
    all)
        info "readahead : re-uses the file the scheduler mode created, writes nothing" ;;
esac
info "predictable total : ${TOTAL_ANNOUNCED} MB, plus the background writer above"
info "All of it is deleted at the end.  Ctrl-C now if this is not a card you"
info "want to spend that on."
sleep 3

case "${MODE}" in
    writeback) mode_writeback ;;
    scheduler) mode_scheduler ;;
    readahead) mode_readahead ;;
    all)       mode_writeback; mode_scheduler; mode_readahead; mode_nice ;;
esac

print_verdict

printf '\n===============================================================\n'
printf 'Done.  Restoring what was changed.\n'
cleanup
sub "state after restore - compare this with the state found at the top"
info "vm.dirty_ratio            : $(cat /proc/sys/vm/dirty_ratio 2>/dev/null)"
info "vm.dirty_background_ratio : $(cat /proc/sys/vm/dirty_background_ratio 2>/dev/null)"
info "vm.dirty_bytes            : $(cat /proc/sys/vm/dirty_bytes 2>/dev/null)"
info "vm.dirty_background_bytes : $(cat /proc/sys/vm/dirty_background_bytes 2>/dev/null)"
info "(the two pairs are mutually exclusive: the kernel zeroes one when the"
info " other is written, so exactly one pair should be non-zero here)"
if [ -n "${QUEUE}" ]; then
    info "scheduler                 : $(sched_current)"
    info "read_ahead_kb             : $(cat "${QUEUE}/read_ahead_kb" 2>/dev/null)"
fi
printf '===============================================================\n'
exit 0
