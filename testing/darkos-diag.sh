#!/bin/bash
# darkos-diag.sh - READ-ONLY diagnostics for dArkOS, in two modes.
#
#   bash darkos-diag.sh boot            configuration snapshot, run once after a reboot
#   bash darkos-diag.sh game [s] [pid]  under-load measurement, run over SSH while playing
#   bash darkos-diag.sh                 this help
#
# This script changes NOTHING. It does not mount, remount, tune, kill or delete
# anything, it writes no file outside two scratch files in /tmp, and it starts no
# load of its own. In particular it deliberately does NOT run "mount -o remount /"
# to test question 1 - that command is a write - it reads /proc/mounts and findmnt
# instead. It is safe on a single device you cannot afford to brick.
#
# Only tools known to exist in the dArkOS image are used: findmnt, lsblk, od,
# dmesg, ps, awk, sed, grep, free, vmstat, swapon, zramctl, systemd-analyze,
# systemctl, btrfs, cat/cut/tr, date, sleep, uname. No iostat, sar, pidstat, perf,
# iotop, htop, hdparm, bc or python - none of those are installed. Floating point
# is done in awk.
#
# Works on kernel 4.4 (RK3326: RG351*, R36S, RGB10, RK2020) and kernel 5.10
# (RK3566: RG353*, RG503, RGB30, RK2023). Platform-specific sysfs paths are
# detected, never assumed; a missing file is always reported, never fatal.
#
# Root is not required. Where it helps (dmesg on kernels with dmesg_restrict,
# btrfs filesystem df, /proc/PID/io of another user) the script says so and
# carries on.

###############################################################################
# Helpers
###############################################################################

have() { command -v "$1" >/dev/null 2>&1; }

SECN=0
hdr() {
    SECN=$((SECN + 1))
    printf '\n===============================================================\n'
    printf '%s. %s\n' "$SECN" "$1"
    printf -- '---------------------------------------------------------------\n'
}

sub() { printf '\n-- %s\n' "$1"; }

# Interpretation block. The heading differs per mode because the question does:
# boot decides whether a proposal is right, game says what is limiting the frame rate.
interp() {
    if [ "$MODE" = game ]; then
        printf '\n  HOW TO READ IT:\n'
    else
        printf '\n  EXPECTED / WHAT IT DECIDES:\n'
    fi
    while [ "$#" -gt 0 ]; do printf '    %s\n' "$1"; shift; done
}

# Print a file if it is readable, otherwise say so and carry on.
show_file() {
    if [ -r "$1" ]; then
        printf '%s: ' "$1"
        cat "$1" 2>/dev/null || printf '(read failed)\n'
    else
        printf '%s: (missing or not readable)\n' "$1"
    fi
}

first_dir() { for d in "$@"; do [ -d "$d" ] && { printf '%s' "$d"; return; }; done; }

# Read one line into RDV without forking. Returns 1 if the file is unusable.
RDV=''
rd() { RDV=''; [ -e "$1" ] || return 1; { read -r RDV < "$1"; } 2>/dev/null || return 1; [ -n "$RDV" ]; }

# min/avg/max of a sample list. $1 label, $2 divisor (0 = auto-scale
# millidegrees), $3 unit, $4 samples.
stat_line() {
    [ -n "$4" ] || { printf '  %-24s (no samples - path absent on this platform)\n' "$1"; return; }
    printf '%s\n' $4 | awk -v l="$1" -v d="$2" -v u="$3" '
        { v = $1 + 0; if (d > 0) v = v / d; else if (v > 1000) v = v / 1000
          n++; s += v; if (n == 1 || v < mn) mn = v; if (n == 1 || v > mx) mx = v }
        END { if (n) printf "  %-24s min %8.1f  avg %8.1f  max %8.1f %s (n=%d)\n", l, mn, s/n, mx, u, n }'
}

# "pid cputicks comm" per process. A process name may contain spaces and
# parentheses, so fields cannot be counted from the start of the line: sub(/.*\) /)
# strips past the last ") ", and \)[^)]*$ finds the last ")" (a plain /\).*/ would
# match the leftmost one and truncate such a name).
proc_snapshot() {
    awk 'FNR == 1 { split(FILENAME, a, "/"); s = $0; sub(/.*\) /, "", s); split(s, f, " ")
                    c = $0; sub(/^[0-9]+ \(/, "", c); sub(/\)[^)]*$/, "", c)
                    print a[3], f[12] + f[13], c }' /proc/[0-9]*/stat 2>/dev/null
}

# Emulator and launcher names: the entries in Emulationstation/es_systems.cfg*
# plus the standalone binaries installed by the build_*.sh scripts.
EMU_RE='retroarch|retrorun|drastic|ppsspp|dolphin|flycast|duckstation|mupen64|yabasanshiro|scummvm|amiberry|hypseus|singe|daphne|openbor|gzdoom|lzdoom|mednafen|pcsx|solarus|ecwolf|xroar|openmsx|bigpemu|pico8|fake08|easyrpg|applewin|linapple|ti99sim|piemu|mvem|gametank|box86|box64|kodi-gbm|mame|vice|minivmac|freej2me|emulationstatio'

# USER_HZ is 100 on every Linux ARM port regardless of CONFIG_HZ; /proc/PID/stat
# is expressed in it, so getconf (not present in the image) is not needed.
HZ=100

###############################################################################
# Help (no argument)
###############################################################################
usage() {
    cat <<'EOF'
dArkOS read-only diagnostics - one script, two modes. It changes nothing.

  bash darkos-diag.sh boot
      CONFIGURATION SNAPSHOT. Run it ONCE, within ~20 seconds of a reboot, with
      NO game started. It reads the state the image booted into and decides the
      open questions of PR #38: is the remount of / failing, what is /boot/uInitrd
      really, what clock does the machine idle at, which I/O scheduler and
      read-ahead are in force, does the nice limit exist, where does boot time go,
      what is compiled into this kernel, is zram up.
      Timing matters: the @reboot cron job runs perfnorm and switches the governor,
      so a late run answers question 3 wrongly.

  bash darkos-diag.sh game [seconds] [pid]
      UNDER-LOAD MEASUREMENT. Start a game, LEAVE IT RUNNING, then run this over
      SSH. It samples for a while (default 10 s, pass a number to change it) and
      reports min/avg/max, because one reading cannot tell throttling from health.
      It answers a different question: while the game runs, is the machine giving
      everything it has, and if not, what is holding it back - clocks, heat,
      priority, memory, the SD card, or another process.
      If the game binary is not recognised, pass its PID after the seconds:
      bash darkos-diag.sh game 10 1234

  Both modes are read-only. Nothing is mounted, tuned, written outside /tmp, or
  killed. No root needed; a few sections say more when run with sudo.

  Save the output:
      bash darkos-diag.sh boot > /tmp/darkos-boot.txt 2>&1
      bash darkos-diag.sh game 30 > /tmp/darkos-game.txt 2>&1

  In one line: "boot" tells you what the image is configured to do, "game" tells
  you what the hardware is actually doing while you play. Send both.
EOF
}

MODE="${1:-}"
case "$MODE" in
    boot|game) ;;
    ''|-h|--help|help) usage; exit 0 ;;
    *) printf 'Unknown mode: %s\n\n' "$MODE"; usage; exit 2 ;;
esac

DUR="${2:-10}"
case "$DUR" in ''|*[!0-9]*) DUR=10 ;; esac
[ "$DUR" -lt 3 ] && DUR=3
PID_ARG="$3"

SNAP="/tmp/darkos-diag-cpu.$$"
VMS="/tmp/darkos-diag-vmstat.$$"
trap 'rm -f "$SNAP" "$VMS" 2>/dev/null' EXIT INT TERM

###############################################################################
# Platform detection - shared, and the only place sysfs paths are guessed
###############################################################################
detect_platform() {
    COMPAT=''
    [ -r /proc/device-tree/compatible ] && COMPAT="$(tr -d '\000' < /proc/device-tree/compatible 2>/dev/null)"
    case "$COMPAT" in
        *rk3326*) SOC='RK3326'; GPUID='ff400000' ;;
        *rk3566*) SOC='RK3566'; GPUID='fde60000' ;;
        *)        SOC='unknown'; GPUID='' ;;
    esac
    # Same nodes perfmax writes (scripts/perfmax): CPU policy, GPU devfreq, DMC devfreq.
    GPU_DEV=''
    [ -n "$GPUID" ] && GPU_DEV="$(first_dir "/sys/devices/platform/${GPUID}.gpu/devfreq/${GPUID}.gpu")"
    [ -n "$GPU_DEV" ] || GPU_DEV="$(first_dir /sys/devices/platform/*.gpu/devfreq/*.gpu /sys/class/devfreq/*.gpu)"
    DMC_DEV="$(first_dir /sys/devices/platform/dmc/devfreq/dmc /sys/class/devfreq/dmc)"

    # cpufreq: policy* on both kernels, cpu*/cpufreq as a fallback if absent.
    POLS=()
    for p in /sys/devices/system/cpu/cpufreq/policy*; do
        [ -d "$p" ] && POLS+=("$p")
    done
    if [ "${#POLS[@]}" -eq 0 ]; then
        for p in /sys/devices/system/cpu/cpu*/cpufreq; do
            [ -d "$p" ] && POLS+=("$p")
        done
    fi

    # devfreq: sample every node the kernel exposes rather than only the two we know.
    DEVFS=()
    for d in /sys/class/devfreq/*; do
        [ -e "$d/cur_freq" ] && DEVFS+=("$d")
    done
    # The class directory should list everything, but add the two perfmax targets
    # explicitly in case a driver registers one without a class symlink.
    for d in "$GPU_DEV" "$DMC_DEV"; do
        [ -n "$d" ] && [ -e "$d/cur_freq" ] || continue
        SEEN=0
        for e in "${DEVFS[@]}"; do [ "${e##*/}" = "${d##*/}" ] && SEEN=1; done
        [ "$SEEN" -eq 0 ] && DEVFS+=("$d")
    done

    ZONES=()
    for z in /sys/class/thermal/thermal_zone*; do
        [ -e "$z/temp" ] && ZONES+=("$z")
    done

    COOLS=()
    for c in /sys/class/thermal/cooling_device*; do
        [ -e "$c/cur_state" ] && COOLS+=("$c")
    done

    DISKS=()
    for b in /sys/block/mmcblk* /sys/block/sd*; do
        [ -e "$b/stat" ] && DISKS+=("$b")
    done

    NCPU="$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)"
    [ -n "$NCPU" ] || NCPU=1
    ROOTDEV="$(awk '$2 == "/" { print $1; exit }' /proc/mounts 2>/dev/null | sed 's@^/dev/@@')"
}

find_game_pid() {
    GAME_PID=''
    if [ -n "$PID_ARG" ] && [ -d "/proc/$PID_ARG" ]; then
        GAME_PID="$PID_ARG"
        return
    fi
    # Busiest match wins: during play that is the emulator, not its wrapper shell
    # and not emulationstation sitting idle behind it.
    GAME_PID="$(proc_snapshot | awk -v re="$EMU_RE" '
        tolower($3) ~ re && tolower($3) !~ /emulationstatio/ && $2+0 > b { b = $2+0; p = $1 }
        END { if (p) print p }')"
}

###############################################################################
# SECTION: platform (both modes)
###############################################################################
sec_platform() {
    hdr 'What machine is this'
    printf 'date        : %s\n' "$(date 2>/dev/null)"
    printf 'kernel      : %s\n' "$(uname -srm 2>/dev/null)"
    if [ -r /proc/device-tree/model ]; then
        printf 'model       : %s\n' "$(tr -d '\000' < /proc/device-tree/model 2>/dev/null)"
    else
        printf 'model       : (no /proc/device-tree/model)\n'
    fi
    [ -r /etc/os-release ] && grep -E '^(PRETTY_NAME|VERSION_CODENAME)=' /etc/os-release 2>/dev/null
    printf 'soc / cpus  : %s / %s\n' "$SOC" "$NCPU"
    printf 'uptime      : %s s since boot\n' "$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
    printf 'root device : %s\n' "${ROOTDEV:-unknown}"

    sub 'sysfs nodes perfmax writes to (detected, not assumed)'
    printf '  cpufreq policies : %s\n' "${POLS[*]:-NOT FOUND}"
    printf '  gpu devfreq      : %s\n' "${GPU_DEV:-NOT FOUND}"
    printf '  dmc devfreq      : %s\n' "${DMC_DEV:-NOT FOUND}"
    printf '  all devfreq      : %s\n' "${DEVFS[*]:-none}"
    printf '  thermal zones    : %s\n' "${#ZONES[@]}"
    printf '  block devices    : %s\n' "${DISKS[*]:-none}"

    if [ "$MODE" = game ]; then
        sub 'the process being measured'
        if [ -n "$GAME_PID" ] && [ -d "/proc/$GAME_PID" ]; then
            rd "/proc/$GAME_PID/comm"
            printf 'game process: pid %s (%s)\n' "$GAME_PID" "$RDV"
            printf 'cmdline     : %s\n' "$( { tr '\000' ' ' < "/proc/$GAME_PID/cmdline"; } 2>/dev/null | cut -c1-150 )"
        else
            printf 'game process: NONE FOUND - either no game is running, or its binary is not in\n'
            printf '              the name list; pass its PID as the third argument:\n'
            printf '              bash darkos-diag.sh game 10 <pid>\n'
            printf '              Every system-wide metric below is still collected and still valid.\n'
        fi
        printf 'emulationstation: '
        ps -eo pid=,ni=,comm= 2>/dev/null | awk 'tolower($3) ~ /emulationstatio/ { print "pid " $1 ", nice " $2; f = 1 } END { if (!f) print "not running" }'
    fi

    interp \
        'Kernel 4.4.x  -> RK3326 (RG351*, R36S, RGB10, RK2020). Proposals 1, 3, 4' \
        '                 apply to this device.' \
        'Kernel 5.10.x -> RK3566 (RG353*, RG503, RGB30, RK2023). Only proposals' \
        '                 2, 5, 6, 7 apply.' \
        'NOT FOUND next to a devfreq node means perfmax cannot have set it on this' \
        'unit at all, whatever the script says.'
}

###############################################################################
# SAMPLING WINDOW (game only). Everything time-based is collected here once.
###############################################################################
sample_window() {
    hdr "Sampling for ${DUR} s - LEAVE THE GAME RUNNING, do not touch the device"
    printf 'Start time: %s\n' "$(date 2>/dev/null)"
    printf 'The numbers in the sections below come from this window. If you alt-tabbed\n'
    printf 'out of the game, quit it, or the device went to sleep during these %s s, the\n' "$DUR"
    printf 'results are worthless - rerun.\n\n'

    # Governors as they were when the window opened, to compare with the end.
    POL_GOV0=(); POL_MAXF=(); POL_S=(); POL_BELOW=()
    i=0
    for p in "${POLS[@]}"; do
        rd "$p/scaling_governor"; POL_GOV0[$i]="$RDV"
        POL_MAXF[$i]=0; rd "$p/scaling_max_freq" && POL_MAXF[$i]="$RDV"
        POL_S[$i]=''; POL_BELOW[$i]=0
        i=$((i + 1))
    done
    DEV_GOV0=(); DEV_S=()
    i=0
    for d in "${DEVFS[@]}"; do
        rd "$d/governor"; DEV_GOV0[$i]="$RDV"; DEV_S[$i]=''
        i=$((i + 1))
    done
    TZ_S=(); COOL_S=()

    D_START=()
    i=0
    for b in "${DISKS[@]}"; do rd "$b/stat"; D_START[$i]="$RDV"; i=$((i + 1)); done
    IO_START=''
    [ -n "$GAME_PID" ] && IO_START="$(grep -E '^(rchar|read_bytes|write_bytes)' "/proc/$GAME_PID/io" 2>/dev/null)"

    proc_snapshot > "$SNAP" 2>/dev/null
    have vmstat && vmstat 1 "$DUR" > "$VMS" 2>/dev/null &

    N=0
    while [ "$N" -lt "$DUR" ]; do
        i=0
        for p in "${POLS[@]}"; do
            if rd "$p/scaling_cur_freq"; then
                POL_S[$i]="${POL_S[$i]} $RDV"
                case "$RDV${POL_MAXF[$i]}" in
                    *[!0-9]*) ;;
                    *) [ "$RDV" -lt "${POL_MAXF[$i]}" ] && POL_BELOW[$i]=$((${POL_BELOW[$i]} + 1)) ;;
                esac
            fi
            i=$((i + 1))
        done
        i=0
        for d in "${DEVFS[@]}"; do rd "$d/cur_freq" && DEV_S[$i]="${DEV_S[$i]} $RDV"; i=$((i + 1)); done
        i=0
        for z in "${ZONES[@]}"; do rd "$z/temp" && TZ_S[$i]="${TZ_S[$i]} $RDV"; i=$((i + 1)); done
        i=0
        for c in "${COOLS[@]}"; do rd "$c/cur_state" && COOL_S[$i]="${COOL_S[$i]} $RDV"; i=$((i + 1)); done
        N=$((N + 1))
        [ "$N" -lt "$DUR" ] && sleep 1
    done
    wait 2>/dev/null
    printf 'done, %s samples.\n' "$N"
}

###############################################################################
# SHARED SECTION: clock domains (both modes)
###############################################################################
sec_clocks() {
    if [ "$MODE" = game ]; then
        hdr 'Clock domains - did perfmax actually take effect?'
    else
        hdr 'Q3 - what clock does the CPU run at after boot? (touches proposals 2, 3)'
        printf 'NOTE: only meaningful if run shortly after boot and BEFORE any game,\n'
        printf '      because the @reboot cron job runs perfnorm and switches to ondemand.\n'
        printf 'seconds since boot: %s\n' "$(cut -d' ' -f1 /proc/uptime 2>/dev/null)"
    fi

    if [ "${#POLS[@]}" -eq 0 ]; then
        printf '\n  no cpufreq interface exposed by this kernel\n'
    fi
    i=0
    for p in "${POLS[@]}"; do
        sub "$p"
        show_file "$p/scaling_governor"
        show_file "$p/scaling_cur_freq"
        show_file "$p/scaling_min_freq"
        show_file "$p/scaling_max_freq"
        [ "$MODE" = boot ] && show_file "$p/scaling_available_frequencies"
        if [ "$MODE" = game ]; then
            printf 'governor when the window opened: %s\n' "${POL_GOV0[$i]:-n/a}"
            stat_line "${p##*/}" 1000 MHz "${POL_S[$i]}"
            printf '  samples below scaling_max_freq (%s kHz): %s of %s\n' \
                "${POL_MAXF[$i]}" "${POL_BELOW[$i]}" "$N"
        fi
        i=$((i + 1))
    done

    sub 'GPU and memory controller (devfreq) - also set by perfmax/perfnorm'
    if [ "${#DEVFS[@]}" -eq 0 ]; then
        printf '  no devfreq nodes on this platform\n'
    fi
    i=0
    for d in "${DEVFS[@]}"; do
        LBL="${d##*/}"
        # /sys/class/devfreq/dmc and /sys/devices/platform/dmc/devfreq/dmc are the
        # same node reached by different paths, so compare the node name, not the path.
        case "${d##*/}" in
            "${GPU_DEV##*/}") [ -n "$GPU_DEV" ] && LBL="$LBL (gpu)" ;;
            "${DMC_DEV##*/}") [ -n "$DMC_DEV" ] && LBL="$LBL (dmc)" ;;
        esac
        rd "$d/governor"; G="$RDV"
        rd "$d/cur_freq"; F="$RDV"
        printf '  %-28s governor %-18s cur_freq %s\n' "$LBL" "${G:-?}" "${F:-?}"
        if [ "$MODE" = game ]; then
            printf '    governor when the window opened: %s\n' "${DEV_GOV0[$i]:-n/a}"
            stat_line "$LBL" 1000000 MHz "${DEV_S[$i]}"
        fi
        i=$((i + 1))
    done

    if [ "$MODE" = game ]; then
        interp \
            'perfmax writes three governors (scripts/perfmax): the CPU policy, the GPU devfreq' \
            'node and the DMC memory controller. With the default %GOVERNOR% = performance all' \
            'three must read "performance"; any of them on ondemand/simple_ondemand/dmc_ondemand' \
            'during a game is the largest single loss possible here, and it means perfmax either' \
            'did not run or wrote to a node this unit does not have (see section 1).' \
            '' \
            'Healthy CPU line: min = avg = max = scaling_max_freq, and "samples below" = 0.' \
            'A min below max with "samples below" non-zero WHILE the governor is performance is' \
            'throttling, not idling - that governor never lowers the clock by itself, so the' \
            'cause is thermal or a regulator cap: read the thermal section next.' \
            'DMC pinned low while the CPU is at max is a memory-bandwidth ceiling, and from' \
            'inside the emulator it looks exactly like a slow CPU.' \
            'A governor that changed between the start and the end of the window means something' \
            'ran perfnorm mid-game - usually the game exited and you measured the menu.'
    else
        interp \
            'RGB10 / RK2020 boot with CONFIG_CPU_FREQ_DEFAULT_GOV_USERSPACE, which pins' \
            'whatever frequency the bootloader left and scales nothing. The RG351* units' \
            'boot on performance instead.' \
            '' \
            'If scaling_cur_freq sits at the BOTTOM of scaling_available_frequencies' \
            'right after boot, then the whole boot and all ES navigation up to the first' \
            'game run at minimum clock, and that dwarfs the 1.5 s saved by proposal 2.' \
            'If it sits at the TOP, there is no problem here and the topic is closed.' \
            'Run this again ~30 s later: the governor should have become ondemand, because' \
            'the root crontab runs "perfnorm quiet" at every boot.' \
            'What the clock does DURING a game is a different question - use the game mode.'
    fi
}

###############################################################################
# SHARED SECTION: process priority / nice (both modes)
###############################################################################
sec_nice() {
    if [ "$MODE" = game ]; then
        hdr 'Process priority - does "nice -n -19" survive in the field?'
    else
        hdr 'Q5 - can "nice -n -19" work at all? (decides proposal 5)'
        printf 'NOTE: this mode only shows whether the LIMIT exists. Whether the emulator\n'
        printf '      really ends up at NI = -19 can only be seen with a game running -\n'
        printf '      that is what "bash darkos-diag.sh game" is for.\n'
    fi

    if [ "$MODE" = game ] && [ -n "$GAME_PID" ] && [ -d "/proc/$GAME_PID" ]; then
        sub 'the game process'
        ps -o pid,ppid,ni,pri,stat,comm -p "$GAME_PID" 2>/dev/null || printf '  (ps failed)\n'
        printf '  RLIMIT_NICE : %s\n' "$(grep -i 'nice priority' "/proc/$GAME_PID/limits" 2>/dev/null | tr -s ' ' | cut -c1-64)"
        printf '  %s\n' "$(grep -i '^Threads:' "/proc/$GAME_PID/status" 2>/dev/null | tr -s ' \t' ' ')"
    fi

    sub 'emulator / ES processes and their nice level'
    ps -eo pid,ni,pri,comm 2>/dev/null | awk -v re="$EMU_RE" 'NR==1 || tolower($4) ~ re'

    EMUPIDS="$(ps -eo pid=,comm= 2>/dev/null | awk -v re="$EMU_RE" 'tolower($2) ~ re {print $1}')"
    if [ -n "$EMUPIDS" ]; then
        sub 'RLIMIT_NICE of those processes'
        for pid in $EMUPIDS; do
            if [ -r "/proc/$pid/limits" ]; then
                printf 'pid %-7s %-20s %s\n' "$pid" \
                    "$(cat /proc/$pid/comm 2>/dev/null)" \
                    "$(grep -i 'nice priority' /proc/$pid/limits 2>/dev/null | tr -s ' ')"
            else
                printf 'pid %-7s (limits not readable - owned by another user)\n' "$pid"
            fi
        done
    else
        printf '\n  No emulator or ES process found.\n'
    fi

    sub 'everything currently running at a negative nice level'
    ps -eo pid,ni,comm 2>/dev/null | awk 'NR == 1 || $2+0 < 0'

    sub 'where the limit is supposed to come from'
    if have systemctl; then
        systemctl show emulationstation.service -p User -p PAMName -p LimitNICE -p LimitNICESoft 2>/dev/null \
            || printf '(systemctl show failed)\n'
    else
        printf '(systemctl not available)\n'
    fi
    if [ -r /etc/security/limits.conf ]; then
        printf 'limits.conf nice entries: '
        grep -E '^[^#]*nice' /etc/security/limits.conf 2>/dev/null || printf '(none)\n'
    else
        printf '/etc/security/limits.conf: (missing or not readable)\n'
    fi

    if [ "$MODE" = game ]; then
        interp \
            'This verifies the LimitNICE change under load rather than in theory.' \
            'NI = -19 and "Max nice priority" soft/hard = 40 means it works.' \
            'NI = 0 with that limit at 0 means every "nice -n -19" in es_systems.cfg is failing' \
            'with EPERM and the game runs at the same priority as the background daemons -' \
            'exactly what the change fixes.' \
            'NI = 0 with the limit at 40 means the limit is granted and the launcher is not' \
            'applying it, which is a different bug worth reporting on its own.' \
            'Threads says what the priority is worth: a single-threaded emulator on four cores' \
            'rarely cares, a four-thread one cares a lot.' \
            'Does it HELP is still a separate question - compare the RetroArch FPS counter on a' \
            'borderline core (flycast, mupen64plus_next) with Wi-Fi on, so background daemons' \
            'actually compete. If NI changes but FPS does not, this is a correctness fix, not a' \
            'performance fix, and it should be described as one.'
    else
        interp \
            'emulationstation.service runs with User=ark and no PAMName=, so pam_limits never' \
            'runs for it and the "ark - nice -20" line in limits.conf does NOT apply to anything' \
            'ES launches. LimitNICE= on the unit is the only mechanism that can work.' \
            '' \
            'BEFORE proposal 5: LimitNICE empty/0 and the ES process shows a nice priority limit' \
            '  of 0. That CONFIRMS the diagnosis - all the "nice -n -19" calls in es_systems.cfg' \
            '  fail silently with EPERM.' \
            'AFTER proposal 5:  LimitNICE=40 (systemd reports the rlimit form, not "-19").' \
            'If ES already shows a limit of 40 without the change, proposal 5 is wrong - revert it.'
    fi
}

###############################################################################
# SHARED SECTION: memory, zram, swap (both modes)
###############################################################################
sec_memory() {
    if [ "$MODE" = game ]; then
        hdr 'Memory pressure and zram under load'
    else
        hdr 'Q8 - zram, swap and memory at rest'
    fi

    sub 'memory'
    have free && free -m 2>/dev/null
    grep -E '^(MemTotal|MemAvailable|SwapTotal|SwapFree|Dirty|Writeback):' /proc/meminfo 2>/dev/null

    sub 'zram devices'
    if have zramctl; then
        zramctl 2>/dev/null || printf '(zramctl failed)\n'
    else
        printf '(zramctl not installed)\n'
    fi
    show_file /sys/block/zram0/comp_algorithm
    show_file /sys/block/zram0/disksize
    rd /sys/block/zram0/mm_stat && printf 'zram0 mm_stat (orig compr used ...): %s\n' "$RDV"

    sub 'active swap'
    if have swapon; then
        swapon --show 2>/dev/null || swapon -s 2>/dev/null || printf '(swapon failed)\n'
    fi
    show_file /proc/swaps

    sub 'zram-swap.service'
    if have systemctl; then
        printf 'is-active: %s\n' "$(systemctl is-active zram-swap.service 2>/dev/null)"
        systemctl --no-pager --full status zram-swap.service 2>/dev/null | head -12
    else
        printf '(systemctl not available)\n'
    fi

    sub 'vm tunables currently in force (verifies proposal 7 / the zram sysctls)'
    show_file /proc/sys/vm/dirty_bytes
    show_file /proc/sys/vm/dirty_background_bytes
    show_file /proc/sys/vm/dirty_ratio
    show_file /proc/sys/vm/dirty_background_ratio
    show_file /proc/sys/vm/swappiness
    show_file /proc/sys/vm/page-cluster

    if [ "$MODE" = game ]; then
        sub "vmstat over the sampling window (si/so = swap in/out, wa = waiting on I/O)"
        if [ -s "$VMS" ]; then tail -n 8 "$VMS"; else printf '  (vmstat not available)\n'; fi

        sub 'kernel log: OOM, allocation failures, thermal events'
        if have dmesg; then
            DM="$(dmesg 2>&1)"
            case "$DM" in
                *'Operation not permitted'*|*'Permission denied'*|*'read kernel buffer failed'*)
                    printf '  dmesg refused (dmesg_restrict). Rerun the script with sudo for this section\n'
                    printf '  only; everything else works unprivileged.\n' ;;
                *) OOM="$(printf '%s\n' "$DM" | grep -iE 'out of memory|oom-killer|oom_reaper|page allocation failure|thermal|throttl' | tail -n 10)"
                   printf '%s\n' "${OOM:-  (nothing matched - good)}" ;;
            esac
        else
            printf '  (dmesg not available)\n'
        fi

        interp \
            'MemAvailable is the number that matters, not "free". Under roughly 80 MB on a 1 GB' \
            'RK3326 the kernel reclaims page cache continuously, which is felt as a stutter every' \
            'time the game touches an uncached asset.' \
            'si/so at 0 means zram is idle and costs nothing; sustained non-zero so means the game' \
            'is being swapped while it plays, and each page costs a compress plus a decompress on' \
            'the very CPU running the emulator - zram buys survival, not smoothness.' \
            'zramctl DATA versus COMPR is the real ratio; under about 2x with lzo the swap returns' \
            'less RAM than it costs in CPU.' \
            'High wa with si/so at 0 is I/O wait, not memory - see the I/O section.' \
            'Any "page allocation failure" line explains a hitch on its own.'
    else
        sub 'swap traffic over 3 seconds while idle (si/so columns)'
        if have vmstat; then
            vmstat 1 3 2>/dev/null || printf '(vmstat failed)\n'
        else
            printf '(vmstat not installed)\n'
        fi

        interp \
            'zramctl should list zram0 with a size around 1G and an algorithm the kernel' \
            'actually supports. On 4.4 RK3326 CRYPTO_LZ4 is not set, so a request for lz4' \
            'silently falls back - seeing lzo here is expected, not a failure. Empty output' \
            'means the zram swap service never came up at all.' \
            '' \
            'si/so staying at 0 while idle is healthy; non-zero at idle means the image is' \
            'already short of RAM before a game even starts.' \
            '' \
            'dirty_bytes 0 and dirty_ratio 20 = proposal 7 is NOT in this image yet.' \
            'dirty_bytes 33554432 and dirty_background_bytes 8388608 = it is.' \
            'swappiness 100 + page-cluster 0 = the zram service applied its sysctls.'
    fi
}

###############################################################################
# SHARED SECTION: block devices and I/O (both modes)
###############################################################################
sec_io() {
    if [ "$MODE" = game ]; then
        hdr 'I/O during play - is the game streaming from the card?'
    else
        hdr 'Q4 - I/O scheduler and read-ahead (decides proposals 1 and 6)'
    fi

    if have lsblk; then
        sub 'block devices'
        lsblk -o NAME,SIZE,TYPE,MOUNTPOINT 2>/dev/null || lsblk 2>/dev/null
    fi

    i=0
    for b in "${DISKS[@]}"; do
        DEV="${b##*/}"
        MARK=''
        case "$ROOTDEV" in "$DEV"*) MARK=' <- holds /' ;; esac
        sub "$b$MARK"
        show_file "$b/queue/scheduler"
        show_file "$b/queue/read_ahead_kb"
        show_file "$b/queue/rotational"
        show_file "$b/queue/nr_requests"
        if [ "$MODE" = game ] && rd "$b/stat" && [ -n "${D_START[$i]}" ]; then
            printf '%s\n%s\n' "${D_START[$i]}" "$RDV" | awk -v d="$N" '
                NR == 1 { r = $1; s = $3; t = $7; next }
                { printf "traffic during the window: read %7d KB in %6d requests, written %7d KB, over %d s\n",
                         ($3 - s) / 2, $1 - r, ($7 - t) / 2, d }'
        fi
        i=$((i + 1))
    done
    [ "${#DISKS[@]}" -eq 0 ] && printf '\n  no mmcblk*/sd* block devices found\n'

    sub 'did the udev rule file make it into the image?'
    show_file /etc/udev/rules.d/10-standard.rules

    if [ "$MODE" = game ]; then
        if [ -n "$GAME_PID" ]; then
            sub "game process I/O (/proc/$GAME_PID/io)"
            IO_END="$(grep -E '^(rchar|read_bytes|write_bytes)' "/proc/$GAME_PID/io" 2>/dev/null)"
            if [ -n "$IO_START" ] && [ -n "$IO_END" ]; then
                printf '%s\n%s\n' "$IO_START" "$IO_END" | awk -F'[: ]+' \
                    '{ if (!($1 in a)) a[$1] = $2; else printf "  %-12s %8d KB during the window\n", $1, ($2 - a[$1]) / 1024 }'
            else
                printf '  not readable - /proc/PID/io needs the owning user or root.\n'
            fi
        fi
        interp \
            'The scheduler and read_ahead_kb lines are the same settings the boot mode judges;' \
            'what is new here is the traffic.' \
            'read_bytes near zero during play means the game sits in page cache, no I/O change' \
            'can speed it up, and the read-ahead and scheduler commits are load-time' \
            'optimisations only - they should be described as such in the PR.' \
            'Steady hundreds of KB per second is real streaming from the card (large PSP, PS1 or' \
            'Dreamcast images, CD audio), and then those commits do matter during play, as does' \
            'MemAvailable in the memory section.' \
            'write_bytes rising while nothing is being saved is usually a log or an autosave,' \
            'which on the exFAT ROM partition is expensive.' \
            'Note that reads served from page cache appear in rchar but not in read_bytes; the' \
            'gap between the two is exactly the part the card never sees.'
    else
        interp \
            'RK3326 (4.4), BEFORE proposal 1: scheduler shows [cfq]. AFTER: [deadline].' \
            'RK3566 (5.10): the repo already ships a bfq rule. If scheduler shows' \
            '  [mq-deadline] or [none] instead of [bfq], the bfq module is not loaded' \
            '  and that existing rule has been silently doing nothing.' \
            '' \
            'read_ahead_kb: 128 is the kernel default and means proposal 6 has not been' \
            'applied to this image yet. 512 means it has.' \
            '' \
            'rotational must be 0, otherwise neither rule matches at all.' \
            'Whether any of this is felt DURING a game is answered by the game mode, not here.'
    fi
}

###############################################################################
# BOOT-ONLY: Q1 root mount
###############################################################################
sec_rootmount() {
    hdr 'Q1 - is the remount of / actually failing? (decides proposal 4)'
    sub 'effective mount options of / (findmnt)'
    if have findmnt; then
        findmnt -no SOURCE,FSTYPE,OPTIONS / 2>/dev/null || printf '(findmnt failed)\n'
    else
        printf '(findmnt not installed)\n'
    fi

    sub 'effective mount options of / (/proc/mounts, no tools involved)'
    awk '$2 == "/" {print}' /proc/mounts 2>/dev/null || printf '(cannot read /proc/mounts)\n'

    sub 'what /etc/fstab asks for'
    if [ -r /etc/fstab ]; then
        grep -vE '^\s*(#|$)' /etc/fstab 2>/dev/null
    else
        printf '(no readable /etc/fstab)\n'
    fi

    sub 'did systemd-remount-fs succeed?'
    if have systemctl; then
        printf 'is-failed: %s\n' "$(systemctl is-failed systemd-remount-fs.service 2>/dev/null)"
        systemctl --no-pager --full status systemd-remount-fs.service 2>/dev/null | head -20
    else
        printf '(systemctl not available)\n'
    fi

    sub 'btrfs complaints in the kernel log'
    if have dmesg; then
        dmesg 2>/dev/null | grep -iE 'btrfs|unrecognized mount option|remount' | tail -20 \
            || printf '(nothing, or dmesg needs root - rerun with sudo)\n'
    else
        printf '(dmesg not available)\n'
    fi

    sub 'btrfs space accounting (only meaningful if / really is btrfs)'
    if have btrfs; then
        btrfs filesystem df / 2>/dev/null || printf '(needs root, or / is not btrfs)\n'
    else
        printf '(btrfs-progs not installed)\n'
    fi

    interp \
        'On RK3326 (4.4), our claim is that "compress=zlib:1" is not parsable by' \
        'btrfs 4.4, so the WHOLE remount is rejected and noatime is lost with it.' \
        '' \
        'PROPOSAL 4 IS CORRECT if the options of / show "relatime" and NO' \
        '  "compress=" token, and/or systemd-remount-fs is failed.' \
        'PROPOSAL 4 IS WRONG - revert it - if the options of / show' \
        '  "noatime" AND "compress=zlib" (any form). Then the parser accepts it' \
        '  and there was never a problem.' \
        'On RK3566 (5.10) compress=zstd:1 is valid syntax; seeing it here is normal.'
}

###############################################################################
# BOOT-ONLY: Q2 initrd
###############################################################################
sec_initrd() {
    hdr 'Q2 - what is /boot/uInitrd really? (decides proposal 3)'
    UINITRD=/boot/uInitrd
    sub 'size'
    if [ -e "$UINITRD" ]; then
        ls -l "$UINITRD" 2>/dev/null
    else
        printf '%s does not exist.\n' "$UINITRD"
        printf 'Other candidates found in /boot:\n'
        ls -l /boot 2>/dev/null | grep -iE 'initrd|uinitrd|initramfs' || printf '  (none)\n'
    fi

    sub 'U-Boot image header magic (first 4 bytes, expect 27 05 19 56)'
    if [ -r "$UINITRD" ] && have od; then
        od -An -tx1 -N4 "$UINITRD" 2>/dev/null || printf '(read failed)\n'
    else
        printf '(file missing/unreadable, or od not installed)\n'
    fi

    sub 'payload magic (4 bytes after the 64-byte mkimage header)'
    if [ -r "$UINITRD" ] && have od; then
        od -An -tx1 -j64 -N4 "$UINITRD" 2>/dev/null || printf '(read failed)\n'
    else
        printf '(file missing/unreadable, or od not installed)\n'
    fi

    sub 'what the kernel said about the initramfs'
    if have dmesg; then
        dmesg 2>/dev/null | grep -iE 'initramfs|initrd|rootfs image|Unpacking' | tail -20 \
            || printf '(nothing found, or dmesg needs root - rerun with sudo)\n'
    else
        printf '(dmesg not available)\n'
    fi

    interp \
        'Payload magic decoder:' \
        '  28 b5 2f fd = zstd  -> PROPOSAL 3 IS CORRECT on a 4.4 kernel. The kernel' \
        '                        has no zstd decompressor, so this file is read off' \
        '                        the SD card on every boot and then thrown away.' \
        '  04 22 4d 18 = lz4   -> this is what the fix produces. Good.' \
        '  1f 8b       = gzip  -> PROPOSAL 3 IS WRONG - revert it. The initrd works' \
        '                        and is really used.' \
        '  fd 37 7a 58 = xz,  42 5a 68 = bzip2,  5d 00 00 = lzma' \
        '' \
        'Corroboration: dmesg containing "Initramfs unpacking failed" confirms it;' \
        'dmesg showing a successful unpack refutes it.' \
        'Size matters too: tens of MB means MODULES=most and a slow read every boot.' \
        '' \
        'On RK3566 (5.10) zstd is supported and the initrd is genuinely used -' \
        'seeing zstd there is NOT a bug.'
}

###############################################################################
# BOOT-ONLY: Q6 boot time
###############################################################################
sec_boottime() {
    hdr 'Q6 - how long does boot take and what costs the time? (sizes proposal 2)'
    if have systemd-analyze; then
        sub 'systemd-analyze'
        systemd-analyze 2>&1 | head -5
        sub 'systemd-analyze blame (top 20)'
        systemd-analyze blame 2>/dev/null | head -20 || printf '(blame failed)\n'
        sub 'systemd-analyze critical-chain emulationstation.service'
        systemd-analyze critical-chain emulationstation.service 2>/dev/null \
            || printf '(critical-chain failed - is the unit enabled?)\n'
        sub 'welcome-message.service ordering'
        systemctl show welcome-message.service -p Before -p After -p Type 2>/dev/null
    else
        printf '(systemd-analyze not available)\n'
    fi

    interp \
        'welcome-message.service near the top of "blame" with roughly 1.5 s, and' \
        'appearing in the critical chain of emulationstation.service, CONFIRMS' \
        'proposal 2. After the change it should drop out of the chain entirely and' \
        'ES should start that much earlier.' \
        '' \
        'Also read the total: 1.5 s out of 8 s matters, 1.5 s out of 60 s does not,' \
        'and in the second case the initrd (proposal 3) is the thing worth chasing.' \
        'systemd-analyze only covers the part AFTER the kernel starts - U-Boot time' \
        'has to be taken with a stopwatch, 3x before and 3x after.'
}

###############################################################################
# BOOT-ONLY: Q7 kernel config
###############################################################################
sec_kconfig() {
    hdr 'Q7 - kernel debug options and decompressors compiled into THIS kernel'
    KCONF=''
    for c in "/proc/config.gz" "/boot/config-$(uname -r 2>/dev/null)" /boot/config-*; do
        if [ -r "$c" ]; then KCONF="$c"; break; fi
    done
    if [ -z "$KCONF" ]; then
        printf 'No kernel config found (/proc/config.gz, /boot/config-*).\n'
        printf 'This is expected on dArkOS: the build copies the config into the\n'
        printf 'rootfs /boot, which the FAT boot partition then mounts over.\n'
        printf 'Nothing to report here - use the defconfig in the kernel repo instead.\n'
    else
        printf 'using: %s\n\n' "$KCONF"
        case "$KCONF" in
            *.gz) READER='zcat' ;;
            *) READER='cat' ;;
        esac
        if have "$READER"; then
            "$READER" "$KCONF" 2>/dev/null | grep -E \
                '^#?\s*CONFIG_(RD_ZSTD|RD_LZ4|RD_GZIP|IOSCHED_DEADLINE|IOSCHED_BFQ|DEFAULT_IOSCHED|DEBUG_SPINLOCK|DEBUG_CREDENTIALS|DEBUG_DEVRES|DEBUG_GPIO|REGULATOR_DEBUG|DETECT_HUNG_TASK|BOOTPARAM_SOFTLOCKUP_PANIC|BOOTPARAM_HUNG_TASK_PANIC|FRAME_POINTER|PROFILING|MEMCG|BLK_CGROUP|COMPACTION|ZRAM|CRYPTO_LZ4|CRYPTO_LZO|BTRFS_FS)\b' \
                || printf '(no matching symbols found)\n'
        else
            printf '(%s not available to read %s)\n' "$READER" "$KCONF"
        fi
    fi

    interp \
        'CONFIG_RD_ZSTD absent (or "is not set") on 4.4 is the other half of the' \
        'proof for proposal 3. CONFIG_RD_LZ4=y means the fix will work.' \
        'CONFIG_IOSCHED_DEADLINE=y means proposal 1 will work.' \
        'CRYPTO_LZ4 not set explains a zram device that came up as lzo despite the' \
        'script asking for lz4 - that is a fallback, not a failure.' \
        'On RK3566, a long list of DEBUG_* set to y would mean the (out of scope)' \
        'proposal 9 also applies to that platform.'
}

###############################################################################
# GAME-ONLY: thermal
###############################################################################
sec_thermal() {
    hdr 'Thermal throttling - the usual cause of mid-game frame drops'
    if [ "${#ZONES[@]}" -eq 0 ]; then
        printf '  no thermal zones exposed by this kernel\n'
    else
        i=0
        for z in "${ZONES[@]}"; do
            rd "$z/type"; stat_line "${RDV:-${z##*/}}" 0 'C' "${TZ_S[$i]}"
            i=$((i + 1))
        done
        sub 'trip points of the first zone (millidegrees)'
        for t in "${ZONES[0]}"/trip_point_*_temp; do
            rd "$t" && printf '  %-24s %s\n' "${t##*/}" "$RDV"
        done
    fi

    sub 'cooling devices (non-zero state = the kernel is capping something)'
    if [ "${#COOLS[@]}" -eq 0 ]; then
        printf '  none exposed\n'
    fi
    i=0
    for c in "${COOLS[@]}"; do
        rd "$c/type"; CT="$RDV"
        rd "$c/max_state"; CM="$RDV"
        printf '  %-24s max_state %s\n' "${CT:-${c##*/}}" "${CM:-?}"
        stat_line "  cur_state over window" 1 '' "${COOL_S[$i]}"
        i=$((i + 1))
    done

    interp \
        'Rockchip reports millidegrees; the min/avg/max lines above are already degrees C, so' \
        'compare them against the trip points rather than against a remembered number.' \
        'Healthy: max temperature at least ~10 C under the lowest trip point and every' \
        'cooling device at cur_state 0 for the whole window (min = avg = max = 0).' \
        'Throttling: cur_state max above 0, or the max temperature sitting on a trip point,' \
        'together with a non-zero "samples below scaling_max_freq" in the clock section. Then' \
        'the frame drops are thermal, and no scheduler, nice or I/O change will fix them -' \
        'this is the one result that invalidates every other section.' \
        'cur_state avg between 0 and max means intermittent capping - the stutter is periodic.' \
        'A temperature still climbing at the end means the window was too short: rerun with' \
        '120 after ten minutes of play.'
}

###############################################################################
# GAME-ONLY: CPU consumers
###############################################################################
sec_cpuhogs() {
    hdr 'Who else is eating the CPU?'
    if [ -s "$SNAP" ]; then
        printf '  %% of ONE core, from /proc/PID/stat deltas over %s s (%s cores total)\n\n' "$N" "$NCPU"
        proc_snapshot | awk -v snap="$SNAP" -v hz="$HZ" -v dur="$N" -v game="$GAME_PID" '
            BEGIN { while ((getline line < snap) > 0) { split(line, o, " "); t[o[1]] = o[2] } }
            { d = $2 - (($1 in t) ? t[$1] : 0); if (d > 0) { v[$1] = d; c[$1] = $3 } }
            END { for (k = 0; k < 10; k++) {
                      best = ""; bv = 0
                      for (p in v) if (v[p] > bv) { bv = v[p]; best = p }
                      if (best == "") break
                      printf "  %7.1f %%  pid %-7s %-22s%s\n", bv * 100 / (hz * dur), best, c[best],
                             (best == game ? "  <- the game" : "")
                      delete v[best] } }'
    else
        printf '  Could not write %s - section skipped.\n' "$SNAP"
    fi
    printf '\n  load average: %s\n' "$(cat /proc/loadavg 2>/dev/null)"

    interp \
        'Deltas, not "top -b": top reports its first sample as an average since boot and its' \
        'behaviour differs between procps versions.' \
        'The game should dominate this list; anything else above ~5 % while a game runs is' \
        'competing for a core the emulator needs, and RK3326 has only four.' \
        'Usual suspects worth naming in a bug report: wpa_supplicant, bluetoothd, pulseaudio,' \
        'gptokeyb, oga_controls, buttonmon, batterymon, and emulationstation itself if it did' \
        'not go quiet behind the game.' \
        'kworker/ or ksoftirqd/ near the top means an interrupt storm, almost always Wi-Fi:' \
        'turn Wi-Fi off and rerun, because a gain there is a real finding independent of every' \
        'commit in this PR.' \
        'A game at 95-100 % of one core with the others idle is single-threaded and CPU-bound,' \
        'so only clock speed helps it; a game well under 100 % with cool temperatures and no' \
        'swap traffic is waiting on the GPU or on vsync, and CPU work is not the bottleneck.'
}

###############################################################################
# Main
###############################################################################
printf 'dArkOS read-only diagnostics - mode: %s\n' "$MODE"
detect_platform
[ "$MODE" = game ] && find_game_pid

sec_platform

if [ "$MODE" = boot ]; then
    sec_rootmount
    sec_initrd
    sec_clocks
    sec_io
    sec_nice
    sec_boottime
    sec_kconfig
    sec_memory
else
    sample_window
    sec_clocks
    sec_thermal
    sec_nice
    sec_memory
    sec_io
    sec_cpuhogs
fi

printf '\n===============================================================\n'
printf 'Done. Nothing on this system was modified.\n'
if [ "$MODE" = boot ]; then
    printf 'Next: start a game and run "bash darkos-diag.sh game" over SSH.\n'
else
    printf 'If you have not sent the boot snapshot yet: reboot and run "bash darkos-diag.sh boot".\n'
fi
printf '===============================================================\n'
