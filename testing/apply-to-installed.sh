#!/bin/bash
# apply-to-installed.sh - NOT FOR MERGE. Applies every change in PR #38 to an
# ALREADY INSTALLED dArkOS system, and takes them back off again.
#
#   sudo bash testing/apply-to-installed.sh apply
#   sudo bash testing/apply-to-installed.sh status
#   sudo bash testing/apply-to-installed.sh undo
#
# Why this exists: this repository builds IMAGES.  Over-the-air updates are
# served from a different repository entirely - dArkOS_Tools/Update.sh:19 points
# at christianhaitian/darkos-updates - so nothing in this branch can reach an
# installed device on its own.  Without this script the only way to try the
# branch is to build an image and reflash, which loses the tester's saves and
# makes before/after comparison on the same card impossible.
#
# It is NOT a substitute for building an image.  It proves the CHANGES work; it
# does not prove the BUILD wires them up.  That gate still needs a fresh image.
#
# Scope of tools: coreutils, util-linux, systemd/udev, procps - all present in
# the dArkOS image.  Explicitly NOT used: zramctl (the RG351MP snapshot in
# testing/rk3326-rg351mp-boot-diag.txt:394 reports "zramctl not installed"),
# bc, python, jq, curl.  Nothing is downloaded and no package is installed.
#
# It never restarts emulationstation.service - that would kill the tester's
# session.  Changes that only take effect after a reboot are listed at the end.
#
# Safety: every file it writes or deletes is copied to /var/backups/darkos-pr38
# first, together with a manifest that also records "this file did not exist",
# so undo can put the system back exactly as it was.  /etc/fstab is only touched
# after the same option set has been proven to work with a live remount, and the
# rewritten file is parsed back before it is trusted.  The per-device sysfs
# values the two udev rules overwrite are snapshotted there as well, so undo can
# write them back rather than leave an A/B measurement contaminated until the
# next reboot.

###############################################################################
# Constants
###############################################################################

BK="/var/backups/darkos-pr38"
MANIFEST="${BK}/manifest"
UNITS_STATE="${BK}/units"
SYSFS_BK="${BK}/sysfs"
FSTAB="/etc/fstab"

# PortMaster's control folder on dArkOS: control.txt:33-34 resolves it here and
# tools/installer.sh:76 takes the same path as the first branch of its fallback
# chain.  It sits on the exfat ROM partition, through the /opt/system/Tools bind
# mount, which is why restoring anything in it cannot rely on cp -a.
CONTROL_FOLDER="/opt/system/Tools/PortMaster"

# Target root mount options for change 4, from setup_partition.sh:23 of this
# branch.  compress=lzo replaces compress=zlib:1, ssd_spread is dropped.
ROOT_COMPRESS="lzo"

###############################################################################
# Small helpers
###############################################################################

have() { command -v "$1" >/dev/null 2>&1; }

say()  { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
info() { printf '   %s\n' "$*"; }
bad()  { printf '   !! %s\n' "$*"; }

# Per-change result table, printed at the end.
R_NAME=()
R_STATE=()
R_NOTE=()
record() { R_NAME+=("$1"); R_STATE+=("$2"); R_NOTE+=("$3"); }

REBOOT_NOTES=()
needs_reboot() { REBOOT_NOTES+=("$1"); }

###############################################################################
# Backup / restore primitives
#
# Everything lives under one directory.  files/ mirrors the absolute path of
# each managed file, so undo needs no name mangling.  manifest records, once per
# path, whether the path existed before this script first touched it:
#
#   saved  /etc/udev/rules.d/60-darkos-readahead.rules
#   absent /etc/systemd/system/emulationstation.service.d/60-darkos-nice.conf
#
# "once per path" is what makes apply idempotent: a second run finds the path
# already in the manifest and leaves the first, pristine, copy alone.
###############################################################################

backup_ready() {
    mkdir -p "${BK}/files" "${BK}/fstab" "${SYSFS_BK}" 2>/dev/null || return 1
    [ -f "${MANIFEST}" ] || : > "${MANIFEST}"
    [ -f "${UNITS_STATE}" ] || : > "${UNITS_STATE}"
    chmod 700 "${BK}" 2>/dev/null
    return 0
}

manifest_has() {
    grep -Fxq "saved $1" "${MANIFEST}" 2>/dev/null && return 0
    grep -Fxq "absent $1" "${MANIFEST}" 2>/dev/null && return 0
    return 1
}

backup_once() {
    path="$1"
    manifest_has "${path}" && return 0
    if [ -e "${path}" ]; then
        mkdir -p "${BK}/files$(dirname "${path}")" 2>/dev/null || return 1
        cp -a "${path}" "${BK}/files${path}" 2>/dev/null || return 1
        printf 'saved %s\n' "${path}" >> "${MANIFEST}"
    else
        printf 'absent %s\n' "${path}" >> "${MANIFEST}"
    fi
    return 0
}

# backup_blk_attr ATTR - snapshot every block device's current queue/ATTR value.
#
# Deleting a udev rule does not put back what the rule already wrote: the values
# survive in sysfs until the next boot, so an "after undo" measurement taken in
# the same session would still be measuring the change.  Same device selection
# as blk_attr_report, so what is snapshotted is what status reports on.
#
# Written once, like the manifest: a second apply must not overwrite the
# pristine values with the ones this script has since applied.
backup_blk_attr() {
    attr="$1"
    out="${SYSFS_BK}/${attr}"
    if [ -f "${out}" ]; then
        info "sysfs snapshot already taken: ${out}"
        return 0
    fi
    mkdir -p "${SYSFS_BK}" 2>/dev/null || { bad "cannot create ${SYSFS_BK}"; return 1; }
    tmp="${out}.$$"
    : > "${tmp}" 2>/dev/null || { bad "cannot write ${tmp}"; return 1; }
    for p in /sys/block/*/queue/"${attr}"; do
        [ -r "${p}" ] || continue
        dev="${p#/sys/block/}"; dev="${dev%%/*}"
        case "${dev}" in loop*|ram*|zram*) continue ;; esac
        v="$(cat "${p}" 2>/dev/null)"
        # scheduler reads back as the whole menu - "noop [deadline] cfq" - and
        # only the bracketed one is a value the kernel accepts on the way in.
        case "${v}" in
            *"["*"]"*) v="$(printf '%s' "${v}" | sed -n 's/.*\[\([^]]*\)\].*/\1/p')" ;;
        esac
        [ -n "${v}" ] || continue
        printf '%s %s\n' "${dev}" "${v}" >> "${tmp}"
    done
    mv -f "${tmp}" "${out}" 2>/dev/null || { rm -f "${tmp}"; bad "cannot save ${out}"; return 1; }
    info "sysfs snapshot -> ${out}: $(tr '\n' ' ' < "${out}" 2>/dev/null)"
    return 0
}

# install_file SRC DST [MODE]
install_file() {
    src="$1"; dst="$2"; mode="${3:-644}"
    if [ ! -f "${src}" ]; then bad "missing source: ${src}"; return 1; fi
    backup_once "${dst}" || { bad "could not back up ${dst}"; return 1; }
    mkdir -p "$(dirname "${dst}")" 2>/dev/null
    if cmp -s "${src}" "${dst}"; then
        chmod "${mode}" "${dst}" 2>/dev/null
        info "unchanged ${dst}"
        return 0
    fi
    cp -f "${src}" "${dst}" || { bad "copy failed: ${dst}"; return 1; }
    chmod "${mode}" "${dst}" 2>/dev/null
    info "installed ${dst}"
    return 0
}

# Record how a unit looked before we first touched it, so undo can put it back.
remember_unit() {
    u="$1"
    grep -Fq "|${u}|" "${UNITS_STATE}" 2>/dev/null && return 0
    en="$(systemctl is-enabled "${u}" 2>/dev/null)"
    ac="$(systemctl is-active "${u}" 2>/dev/null)"
    printf '|%s|%s|%s|\n' "${u}" "${en:-none}" "${ac:-inactive}" >> "${UNITS_STATE}"
}

###############################################################################
# Platform detection
#
# /proc/device-tree/compatible, exactly as dArkOS' own shipped runtime scripts
# do it - global/checknswitchforusbdac.sh:7 matches *rk3326*, dArkOS_Tools/
# Wifi.sh:327 matches *rk3566* - so the same expression is already known to
# work on BOTH platforms on real hardware, not just on one of them.  The
# RG351MP snapshot in testing/rk3326-rg351mp-boot-diag.txt:11 shows it
# resolving to RK3326 on a device.  The user is never asked.
###############################################################################

SOC="unknown"
detect_platform() {
    compat=""
    [ -r /proc/device-tree/compatible ] &&
        compat="$(tr -d '\000' < /proc/device-tree/compatible 2>/dev/null)"
    case "${compat}" in
        *rk3326*) SOC="rk3326" ;;
        *rk3566*) SOC="rk3566" ;;
        *)        SOC="unknown" ;;
    esac
}

###############################################################################
# Reload primitives
###############################################################################

RELOAD_SYSTEMD=0
RELOAD_UDEV=0
RELOAD_SYSCTL=0

do_reloads() {
    if [ "${RELOAD_SYSTEMD}" -eq 1 ]; then
        step "systemctl daemon-reload"
        systemctl daemon-reload 2>/dev/null || bad "daemon-reload failed"
    fi
    if [ "${RELOAD_UDEV}" -eq 1 ]; then
        step "udev: reload rules and re-trigger block devices"
        if have udevadm; then
            udevadm control --reload-rules 2>/dev/null || bad "udevadm control failed"
            # Narrow on purpose: only block devices carry queue/*, and a bare
            # "udevadm trigger" would replay every event on the system.
            udevadm trigger --subsystem-match=block --action=change 2>/dev/null ||
                bad "udevadm trigger failed"
            udevadm settle --timeout=10 2>/dev/null
        else
            bad "udevadm not found - rules will apply at the next boot"
        fi
    fi
    if [ "${RELOAD_SYSCTL}" -eq 1 ]; then
        step "sysctl --system"
        if have sysctl; then
            sysctl --system >/dev/null 2>&1 ||
                sysctl -p /etc/sysctl.d/60-darkos-writeback.conf >/dev/null 2>&1 ||
                bad "sysctl reload failed"
        else
            bad "sysctl not found - the writeback caps apply at the next boot"
        fi
    fi
}

###############################################################################
# fstab helpers (change 4)
###############################################################################

# Read the option field of the root entry of a fstab-format file.
fstab_root_opts() {
    awk '
        /^[[:space:]]*#/ { next }
        NF >= 4 && $2 == "/" { print $4; found = 1; exit }
        END { if (!found) exit 1 }
    ' "$1" 2>/dev/null
}

# Rewrite an option list: any compress=/compress-force= becomes compress=lzo,
# ssd_spread is dropped, everything else is left alone and the order kept.
darkos_root_opts() {
    printf '%s' "$1" | awk -v algo="${ROOT_COMPRESS}" '
        BEGIN { RS = ","; ORS = "" }
        {
            o = $0
            gsub(/[[:space:]]/, "", o)
            if (o == "" || o == "ssd_spread") next
            if (o ~ /^compress(-force)?=/) { o = "compress=" algo; seen = 1 }
            out = (out == "" ? o : out "," o)
        }
        END {
            if (!seen) out = (out == "" ? "compress=" algo : out ",compress=" algo)
            print out
        }'
}

# Rewrite the option field of the root entry, on stdout.
fstab_with_opts() {
    awk -v opts="$2" '
        /^[[:space:]]*#/ { print; next }
        NF >= 4 && $2 == "/" {
            f5 = ($5 == "" ? "0" : $5); f6 = ($6 == "" ? "0" : $6)
            printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, $3, opts, f5, f6
            next
        }
        { print }
    ' "$1"
}

###############################################################################
# Source files this script needs
###############################################################################

SELF_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
REPO="$(cd "${SELF_DIR}/.." 2>/dev/null && pwd)"

REQUIRED="
scripts/zram-swap.sh
scripts/zram-swap.service
scripts/portmaster-hooks.sh
scripts/portmaster-hooks.service
scripts/portmaster-hooks.path
scripts/60-darkos-scheduler.rules
scripts/60-darkos-readahead.rules
scripts/60-darkos-writeback.conf
portmaster/mod_dArkOS.txt
"

check_sources() {
    missing=""
    if [ -z "${REPO}" ] || [ ! -d "${REPO}" ]; then
        bad "cannot resolve the repository root from $0"
        return 1
    fi
    for f in ${REQUIRED}; do
        [ -f "${REPO}/${f}" ] || missing="${missing} ${f}"
    done
    if [ -n "${missing}" ]; then
        bad "repository root looks wrong: ${REPO}"
        bad "missing:${missing}"
        bad "run this from inside a checkout of the PR branch, as testing/$(basename "$0")"
        return 1
    fi
    return 0
}

###############################################################################
# apply
###############################################################################

apply_1_portmaster() {
    step "1/7  PortMaster hook kept across updates + zram swap at boot (2ac3da2)"
    ok=0
    mkdir -p /usr/local/share/dArkOS/portmaster /usr/local/bin 2>/dev/null
    for t in "${REPO}"/portmaster/*.txt; do
        [ -f "${t}" ] || continue
        install_file "${t}" "/usr/local/share/dArkOS/portmaster/$(basename "${t}")" 644 || ok=1
    done
    # 755, not the 777 the build scripts use: these run as root out of a
    # systemd unit, and world-writable would make that a local root hole.
    install_file "${REPO}/scripts/portmaster-hooks.sh" /usr/local/bin/portmaster-hooks.sh 755 || ok=1
    install_file "${REPO}/scripts/zram-swap.sh"        /usr/local/bin/zram-swap.sh        755 || ok=1
    install_file "${REPO}/scripts/portmaster-hooks.service" /etc/systemd/system/portmaster-hooks.service || ok=1
    install_file "${REPO}/scripts/portmaster-hooks.path"    /etc/systemd/system/portmaster-hooks.path    || ok=1
    install_file "${REPO}/scripts/zram-swap.service"        /etc/systemd/system/zram-swap.service        || ok=1

    # The hook units copy every staged .txt into the PortMaster control folder,
    # so those targets have to be recorded BEFORE the units are started or undo
    # would leave this branch's mod_dArkOS.txt behind and the system would not
    # be back exactly as it was.  Same test the hook itself uses
    # (portmaster-hooks.sh:17): no control.txt means no control folder, the hook
    # copies nothing, and there is nothing to record - recording it anyway would
    # put "absent" entries in the manifest for files this script never creates.
    hooks_safe=1
    if [ -f "${CONTROL_FOLDER}/control.txt" ]; then
        for t in "${REPO}"/portmaster/*.txt; do
            [ -f "${t}" ] || continue
            backup_once "${CONTROL_FOLDER}/$(basename "${t}")" ||
                { bad "could not back up ${CONTROL_FOLDER}/$(basename "${t}")"; ok=1; hooks_safe=0; }
        done
        info "control folder recorded: ${CONTROL_FOLDER}"
    else
        info "no ${CONTROL_FOLDER}/control.txt - PortMaster is not installed here,"
        info "so the hook units will copy nothing and nothing needs recording."
    fi

    for u in zram-swap.service portmaster-hooks.service portmaster-hooks.path; do
        remember_unit "${u}"
    done
    RELOAD_SYSTEMD=1
    systemctl daemon-reload 2>/dev/null

    systemctl enable zram-swap.service >/dev/null 2>&1 || { bad "enable zram-swap.service failed"; ok=1; }
    # Starting this is safe: it only adds swap, it never touches EmulationStation.
    systemctl start zram-swap.service >/dev/null 2>&1

    # The hook units write into the control folder, so they are only let loose
    # once that folder's contents are safely recorded - otherwise undo would
    # have nothing to put back.
    if [ "${hooks_safe}" -eq 1 ]; then
        for u in portmaster-hooks.service portmaster-hooks.path; do
            systemctl enable "${u}" >/dev/null 2>&1 || { bad "enable ${u} failed"; ok=1; }
        done
        systemctl start portmaster-hooks.path    >/dev/null 2>&1 || info "portmaster-hooks.path did not start"
        systemctl start portmaster-hooks.service >/dev/null 2>&1 || info "portmaster-hooks.service did not run (PortMaster may not be installed yet)"
    else
        bad "hook units left disabled and stopped: ${CONTROL_FOLDER} could not be"
        bad "backed up, so undo would not be able to put it back."
    fi

    if [ "${ok}" -eq 0 ]; then
        record "1 portmaster hook" PASS "files installed, units enabled and started"
    else
        record "1 portmaster hook" FAIL "see messages above"
    fi

    # The zram-swap start above reported success no matter what happened.  The
    # unit is Type=oneshot and zram-swap.sh gives up with exit 0 on every one of
    # its failure paths - no zram device, disksize still 0 after both compressor
    # attempts, no device node in time - and a failing swapon only skips the
    # sysctl block.  systemd sees success in all of those cases.  The RG351MP
    # snapshot in testing/rk3326-rg351mp-boot-diag.txt:388-405 is exactly that:
    # unit enabled, disksize 0, SwapTotal 0 kB.  So ask the kernel instead.
    step "     verifying that swap actually exists"
    zdsz="$(cat /sys/block/zram0/disksize 2>/dev/null)"
    zswap="$(awk 'NR > 1 && $1 ~ /zram/ && $3 + 0 > 0 { print $1 "=" $3 "kB pri=" $5 }' /proc/swaps 2>/dev/null)"
    ztot="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo 2>/dev/null)"
    if [ -n "${zswap}" ] && [ -n "${zdsz}" ] && [ "${zdsz}" != "0" ]; then
        info "/proc/swaps               : ${zswap}"
        info "/sys/block/zram0/disksize : ${zdsz}"
        info "/proc/meminfo SwapTotal   : ${ztot:-?} kB"
        record "1 zram swap" PASS "${zswap} disksize=${zdsz}"
    else
        bad "ZRAM SWAP DID NOT COME UP.  THIS HALF OF CHANGE 1 IS NOT IN EFFECT."
        bad "  /sys/block/zram0/disksize : ${zdsz:-(no such file)}"
        bad "  /proc/swaps zram entry    : ${zswap:-(none)}"
        bad "  /proc/meminfo SwapTotal   : ${ztot:-?} kB"
        bad "  zram-swap.service         : $(systemctl is-active zram-swap.service 2>/dev/null) / $(systemctl is-enabled zram-swap.service 2>/dev/null)"
        bad "  /sys/block/zram0/comp_algorithm: $(cat /sys/block/zram0/comp_algorithm 2>/dev/null)"
        bad "systemctl start returned success anyway: the unit is Type=oneshot and"
        bad "zram-swap.sh exits 0 on every give-up path it has."
        bad "DO NOT report change 1 as measured - there is nothing swapping.  Send"
        bad "the values above plus: journalctl -b -u zram-swap.service"
        bad "The PortMaster hook half of change 1 is unaffected and still in force -"
        bad "see its own row in the summary."
        record "1 zram swap" FAIL "no swap: disksize=${zdsz:-none} SwapTotal=${ztot:-?}kB"
    fi
}

apply_2_scheduler() {
    step "2/7  I/O scheduler deadline via udev, RK3326 only (da23fd9)"
    if [ "${SOC}" != "rk3326" ]; then
        info "platform is ${SOC} - skipped on purpose."
        info "RK3566 already gets bfq from 10-standard.rules, and a 60- file"
        info "sorts later and would override it (udev(7): rules files are sorted"
        info "lexicographically regardless of the directory they live in)."
        record "2 scheduler" SKIP "not RK3326 (detected: ${SOC})"
        return
    fi
    backup_blk_attr scheduler
    if install_file "${REPO}/scripts/60-darkos-scheduler.rules" /etc/udev/rules.d/60-darkos-scheduler.rules; then
        RELOAD_UDEV=1
        record "2 scheduler" PASS "rule installed"
    else
        record "2 scheduler" FAIL "install failed"
    fi
}

apply_3_welcome() {
    step "3/7  welcome-message.service no longer delays EmulationStation (45c43ae)"
    frag="$(systemctl show -p FragmentPath --value welcome-message.service 2>/dev/null)"
    if [ -z "${frag}" ] || [ ! -f "${frag}" ]; then
        info "welcome-message.service has no unit file on this system."
        record "3 welcome-message" SKIP "unit not present"
        return
    fi
    info "unit file: ${frag}"
    # NOT a drop-in.  systemd.unit(5), EXAMPLES: "Dependencies (After=, etc.)
    # cannot be reset to an empty list, so dependencies can only be added in
    # drop-ins.  If you want to remove dependencies, you have to override the
    # entire unit."  An override file is impossible too - dArkOS installs this
    # unit into /etc/systemd/system (finishing_touches.sh:396), the highest
    # priority directory there is.  So the installed file itself is edited, and
    # it is edited by removing one token from IT, not by overwriting it with
    # this branch's copy: the device may be running a different dArkOS build.
    tmp="${frag}.darkos-pr38.$$"
    awk '
        /^[[:space:]]*Before[[:space:]]*=/ {
            line = $0
            sub(/^[[:space:]]*Before[[:space:]]*=[[:space:]]*/, "", line)
            n = split(line, t, /[[:space:]]+/)
            out = ""
            for (i = 1; i <= n; i++)
                if (t[i] != "" && t[i] != "emulationstation.service")
                    out = (out == "" ? t[i] : out " " t[i])
            if (out == "") next
            print "Before=" out
            next
        }
        { print }
    ' "${frag}" > "${tmp}" 2>/dev/null
    if [ ! -s "${tmp}" ]; then
        rm -f "${tmp}"
        bad "rewrite produced an empty file - nothing changed"
        record "3 welcome-message" FAIL "rewrite failed"
        return
    fi
    if cmp -s "${frag}" "${tmp}"; then
        rm -f "${tmp}"
        info "no Before=emulationstation.service in this unit - nothing to do."
        # Still record it, so undo does not have to special-case it.
        backup_once "${frag}"
        record "3 welcome-message" PASS "already absent"
        return
    fi
    backup_once "${frag}" || { rm -f "${tmp}"; record "3 welcome-message" FAIL "backup failed"; return; }
    chmod --reference="${frag}" "${tmp}" 2>/dev/null || chmod 644 "${tmp}"
    if mv -f "${tmp}" "${frag}"; then
        info "removed Before=emulationstation.service"
        RELOAD_SYSTEMD=1
        needs_reboot "3 welcome-message: the ordering only matters during boot"
        record "3 welcome-message" PASS "ordering removed"
    else
        rm -f "${tmp}"
        record "3 welcome-message" FAIL "could not replace the unit file"
    fi
}

apply_4_rootfs() {
    step "4/7  root mount options: compress=${ROOT_COMPRESS}, drop ssd_spread (34b5670)"
    if [ "${SOC}" != "rk3326" ]; then
        info "platform is ${SOC} - skipped.  The commit only changes"
        info "setup_partition.sh; RK3566 keeps compress=zstd:1, which its 5.10"
        info "kernel parses correctly."
        record "4 root mount options" SKIP "not RK3326 (detected: ${SOC})"
        return
    fi
    if ! have findmnt; then
        record "4 root mount options" SKIP "findmnt not available"
        return
    fi
    fstype="$(findmnt -no FSTYPE / 2>/dev/null)"
    if [ "${fstype}" != "btrfs" ]; then
        info "/ is ${fstype:-unknown}, not btrfs - nothing to do."
        record "4 root mount options" SKIP "/ is not btrfs"
        return
    fi
    if [ ! -f "${FSTAB}" ]; then
        record "4 root mount options" FAIL "${FSTAB} does not exist"
        return
    fi
    cur="$(fstab_root_opts "${FSTAB}")"
    if [ -z "${cur}" ]; then
        bad "no root entry found in ${FSTAB} - refusing to guess"
        record "4 root mount options" FAIL "no root entry in fstab"
        return
    fi
    new="$(darkos_root_opts "${cur}")"
    info "fstab now : ${cur}"
    info "fstab want: ${new}"

    # PROVE IT FIRST.  A bad option set here is a device that does not boot, so
    # the kernel gets to reject it while the system is still running and /etc is
    # still untouched.  Only a remount that actually succeeds earns an edit.
    step "     proving the option set with a live remount"
    if ! mount -o "remount,${new}" / 2>&1; then
        bad "mount -o remount,${new} / FAILED - ${FSTAB} left untouched."
        bad "report this: the option set is wrong for this kernel."
        record "4 root mount options" FAIL "live remount refused, fstab untouched"
        return
    fi
    info "remount succeeded: $(findmnt -no OPTIONS / 2>/dev/null)"

    if [ "${cur}" = "${new}" ]; then
        info "${FSTAB} already asks for exactly this - no edit needed."
        backup_once "${FSTAB}"
        record "4 root mount options" PASS "already in fstab; live mount refreshed"
        return
    fi

    ts="$(date +%Y%m%d-%H%M%S 2>/dev/null)"
    [ -n "${ts}" ] || ts="$$"
    cp -a "${FSTAB}" "${BK}/fstab/fstab.${ts}" 2>/dev/null ||
        { bad "could not write the timestamped fstab backup"; record "4 root mount options" FAIL "backup failed"; return; }
    info "timestamped backup: ${BK}/fstab/fstab.${ts}"
    backup_once "${FSTAB}" || { record "4 root mount options" FAIL "manifest backup failed"; return; }

    tmp="${FSTAB}.darkos-pr38.$$"
    fstab_with_opts "${FSTAB}" "${new}" > "${tmp}" 2>/dev/null
    if [ ! -s "${tmp}" ]; then
        rm -f "${tmp}"
        bad "rewrite produced an empty ${FSTAB} - nothing changed"
        record "4 root mount options" FAIL "rewrite failed"
        return
    fi
    # Parse the candidate before it becomes /etc/fstab, if this findmnt can.
    probe="$(findmnt --fstab --tab-file "${tmp}" -no OPTIONS / 2>/dev/null)"
    if [ -n "${probe}" ] && [ "${probe}" != "${new}" ]; then
        rm -f "${tmp}"
        bad "candidate fstab parses as '${probe}', expected '${new}' - nothing changed"
        record "4 root mount options" FAIL "candidate did not parse as expected"
        return
    fi
    chmod --reference="${FSTAB}" "${tmp}" 2>/dev/null || chmod 644 "${tmp}"
    mv -f "${tmp}" "${FSTAB}" || {
        rm -f "${tmp}"
        record "4 root mount options" FAIL "could not replace ${FSTAB}"
        return
    }
    # And read it back from its real location, whatever the probe could do.
    after="$(findmnt --fstab -no OPTIONS / 2>/dev/null)"
    if [ -z "${after}" ] || [ "${after}" != "${new}" ]; then
        bad "${FSTAB} does not read back as expected (got '${after}') - restoring"
        cp -a "${BK}/fstab/fstab.${ts}" "${FSTAB}" 2>/dev/null
        record "4 root mount options" FAIL "reread mismatch, fstab restored"
        return
    fi
    info "${FSTAB} reread ok: ${after}"
    record "4 root mount options" PASS "remounted live and written to fstab"
}

apply_5_nice() {
    step "5/7  LimitNICE=-20 for EmulationStation (8ea33fd)"
    frag="$(systemctl show -p FragmentPath --value emulationstation.service 2>/dev/null)"
    if [ -z "${frag}" ] || [ ! -f "${frag}" ]; then
        info "emulationstation.service has no unit file on this system."
        record "5 LimitNICE" SKIP "unit not present"
        return
    fi
    info "unit file: ${frag} (left untouched)"
    # A drop-in is correct here and NOT correct for change 3: LimitNICE= is a
    # plain scalar, not a dependency list, and systemd.unit(5) states drop-ins
    # take precedence over unit files wherever those live - including /etc.
    d="/etc/systemd/system/emulationstation.service.d"
    mkdir -p "${d}" 2>/dev/null
    f="${d}/60-darkos-nice.conf"
    backup_once "${f}" || { record "5 LimitNICE" FAIL "backup failed"; return; }
    printf '[Service]\nLimitNICE=-20\n' > "${f}" || {
        record "5 LimitNICE" FAIL "could not write the drop-in"; return; }
    chmod 644 "${f}" 2>/dev/null
    info "drop-in written: ${f}"
    RELOAD_SYSTEMD=1
    needs_reboot "5 LimitNICE: EmulationStation must be restarted; this script will NOT do it"
    record "5 LimitNICE" PASS "drop-in written (effective after ES restarts)"
}

apply_6_readahead() {
    step "6/7  read_ahead_kb 512 via udev, both platforms (53455a5)"
    backup_blk_attr read_ahead_kb
    if install_file "${REPO}/scripts/60-darkos-readahead.rules" /etc/udev/rules.d/60-darkos-readahead.rules; then
        RELOAD_UDEV=1
        record "6 read-ahead" PASS "rule installed"
    else
        record "6 read-ahead" FAIL "install failed"
    fi
}

apply_7_writeback() {
    step "7/7  vm.dirty_bytes / vm.dirty_background_bytes (195b50d)"
    if install_file "${REPO}/scripts/60-darkos-writeback.conf" /etc/sysctl.d/60-darkos-writeback.conf; then
        RELOAD_SYSCTL=1
        record "7 writeback caps" PASS "sysctl drop-in installed"
    else
        record "7 writeback caps" FAIL "install failed"
    fi
}

do_apply() {
    say "Applying PR #38 to the running system."
    say "repository : ${REPO}"
    say "platform   : ${SOC}"
    say "backups    : ${BK}"
    backup_ready || { bad "cannot create ${BK}"; return 1; }
    apply_1_portmaster
    apply_2_scheduler
    apply_3_welcome
    apply_4_rootfs
    apply_5_nice
    apply_6_readahead
    apply_7_writeback
    do_reloads
    return 0
}

###############################################################################
# undo
###############################################################################

# cp -a is right for /etc and wrong for the PortMaster control folder: that one
# is on the exfat ROM partition, where ownership and mode are properties of the
# mount (uid=1000,gid=1000,umask=000) and chown/chmod are refused, so cp -a can
# fail AFTER the data has already been written.  Content is the only thing that
# can differ there, so fall back to a plain copy and let cmp say whether it
# worked instead of trusting an exit status.
restore_path() {
    cp -a "$1" "$2" 2>/dev/null && return 0
    cp -f "$1" "$2" 2>/dev/null
    cmp -s "$1" "$2"
}

# restore_blk_attr ATTR - write the snapshotted per-device values back.
#   0 = everything recorded was written back
#   1 = something could not be written back (caller keeps the reboot note)
#   2 = nothing was recorded, or no recorded device is still here
restore_blk_attr() {
    attr="$1"
    f="${SYSFS_BK}/${attr}"
    [ -s "${f}" ] || return 2
    miss=0
    did=0
    while read -r dev val; do
        [ -n "${dev}" ] && [ -n "${val}" ] || continue
        t="/sys/block/${dev}/queue/${attr}"
        if [ ! -e "${t}" ]; then
            info "${dev}: gone, skipped"
            continue
        fi
        if printf '%s\n' "${val}" > "${t}" 2>/dev/null; then
            info "${dev} ${attr} <- ${val}   (reads back: $(cat "${t}" 2>/dev/null))"
            did=1
        else
            bad "could not write '${val}' to ${t}"
            miss=1
        fi
    done < "${f}"
    [ "${did}" -eq 1 ] || return 2
    return "${miss}"
}

do_undo() {
    say "Undoing PR #38 on the running system."
    say "backups    : ${BK}"
    if [ ! -f "${MANIFEST}" ]; then
        bad "no manifest at ${MANIFEST} - nothing was ever applied from here."
        record "undo" SKIP "no backup directory"
        return 0
    fi

    # Units first: a disable after the unit file is gone leaves dangling
    # symlinks in the .wants directories.
    step "restoring unit enablement"
    if [ -f "${UNITS_STATE}" ]; then
        while IFS='|' read -r _lead u en ac _tail; do
            [ -n "${u}" ] || continue
            if [ "${ac}" != "active" ]; then
                systemctl stop "${u}" >/dev/null 2>&1 && info "stopped ${u}"
            fi
            if [ "${en}" != "enabled" ] && [ "${en}" != "enabled-runtime" ]; then
                systemctl disable "${u}" >/dev/null 2>&1 && info "disabled ${u}"
            fi
        done < "${UNITS_STATE}"
    else
        info "no unit state file at ${UNITS_STATE} - nothing to stop or disable."
    fi

    step "restoring files"
    fail=0
    touched_udev=0
    touched_sysctl=0
    touched_fstab=0
    while read -r state path; do
        [ -n "${path}" ] || continue
        case "${path}" in
            /etc/udev/rules.d/*)   touched_udev=1 ;;
            /etc/sysctl.d/*)       touched_sysctl=1 ;;
            "${FSTAB}")            touched_fstab=1 ;;
        esac
        if [ "${state}" = "saved" ]; then
            if [ -e "${BK}/files${path}" ]; then
                if restore_path "${BK}/files${path}" "${path}"; then
                    info "restored ${path}"
                else
                    bad "could not restore ${path}"; fail=1
                fi
            else
                bad "backup copy missing for ${path}"; fail=1
            fi
        elif [ "${state}" = "absent" ]; then
            if [ -e "${path}" ]; then
                rm -f "${path}" 2>/dev/null && info "removed ${path}" || { bad "could not remove ${path}"; fail=1; }
            else
                info "already gone ${path}"
            fi
        fi
    done < "${MANIFEST}"

    rmdir /etc/systemd/system/emulationstation.service.d 2>/dev/null
    rmdir /usr/local/share/dArkOS/portmaster /usr/local/share/dArkOS 2>/dev/null

    [ "${touched_udev}" -eq 1 ]   && RELOAD_UDEV=1
    [ "${touched_sysctl}" -eq 1 ] && RELOAD_SYSCTL=1
    # Unconditional: a restored unit file may live outside /etc/systemd/system
    # (welcome-message.service is found through FragmentPath, not assumed), and
    # a daemon-reload with nothing to reload costs nothing.
    RELOAD_SYSTEMD=1
    do_reloads

    if [ "${touched_sysctl}" -eq 1 ]; then
        # Deleting the file does not undo the values already in the kernel, and
        # dirty_bytes and dirty_ratio are mutually exclusive - writing one zeroes
        # the other - so the ratios have to be put back explicitly.
        step "restoring the kernel writeback defaults"
        sysctl -q -w vm.dirty_ratio=20 vm.dirty_background_ratio=10 2>/dev/null ||
            bad "could not restore vm.dirty_ratio / vm.dirty_background_ratio"
    fi

    if [ "${touched_fstab}" -eq 1 ]; then
        needs_reboot "4 root mount options: ${FSTAB} is restored, but / stays mounted with the applied options until reboot"
    fi

    # Removing the rules does not put back what they already wrote, and the
    # likely test cycle - status, apply, reboot, measure, undo, measure - needs
    # the second measurement to be a baseline, not the applied values with the
    # rule file deleted.  So write the snapshot back; the reboot note stays only
    # as the fallback for whatever could not be written.
    rb_partial=0
    rb_snapshot=0
    if [ -s "${SYSFS_BK}/scheduler" ] || [ -s "${SYSFS_BK}/read_ahead_kb" ]; then
        rb_snapshot=1
        step "restoring the block device values the udev rules changed"
        for a in scheduler read_ahead_kb; do
            restore_blk_attr "${a}"
            [ $? -eq 1 ] && rb_partial=1
        done
    fi
    if [ "${rb_partial}" -eq 1 ]; then
        needs_reboot "2/6 udev: some block device values could not be written back - those clear at the next reboot"
    elif [ "${touched_udev}" -eq 1 ] && [ "${rb_snapshot}" -eq 0 ]; then
        needs_reboot "2/6 udev: no pre-apply snapshot in ${SYSFS_BK} to restore from - the applied scheduler and read-ahead values stay until reboot"
    fi

    step "backup directory left in place at ${BK} - delete it by hand when done"
    if [ "${fail}" -eq 0 ]; then
        record "undo" PASS "everything restored from ${BK}"
    else
        record "undo" FAIL "some paths could not be restored - see above"
    fi
    return 0
}

###############################################################################
# status - read from the live system only
###############################################################################

blk_attr_report() {
    # $1 = attribute name under queue/, $2 = wanted value or pattern
    hits=""
    for d in /sys/block/*/queue/"$1"; do
        [ -r "${d}" ] || continue
        dev="${d#/sys/block/}"; dev="${dev%%/*}"
        case "${dev}" in loop*|ram*|zram*) continue ;; esac
        hits="${hits}${dev}=$(cat "${d}" 2>/dev/null) "
    done
    printf '%s' "${hits}"
}

st() { printf '   %-24s %-9s %s\n' "$1" "$2" "$3"; }

do_status() {
    say "PR #38 status on the running system (read from the live system, not from ${BK})."
    say "platform   : ${SOC}"
    say ""

    # 1
    n=0
    [ -f /usr/local/bin/zram-swap.sh ] && n=$((n + 1))
    [ -f /usr/local/bin/portmaster-hooks.sh ] && n=$((n + 1))
    [ -f /usr/local/share/dArkOS/portmaster/mod_dArkOS.txt ] && n=$((n + 1))
    zen="$(systemctl is-enabled zram-swap.service 2>/dev/null)"
    pen="$(systemctl is-enabled portmaster-hooks.path 2>/dev/null)"
    sen="$(systemctl is-enabled portmaster-hooks.service 2>/dev/null)"
    swap="$(awk 'NR > 1 && $1 ~ /zram/ && $3 + 0 > 0 { print $1 "=" $3 "kB" }' /proc/swaps 2>/dev/null)"
    dsz="$(cat /sys/block/zram0/disksize 2>/dev/null)"
    if [ "${n}" -eq 3 ] && [ "${zen}" = "enabled" ] && [ "${pen}" = "enabled" ] && [ "${sen}" = "enabled" ]; then
        # Files and enablement are not enough to call this applied: the snapshot
        # in testing/rk3326-rg351mp-boot-diag.txt:388-405 has zram-swap.service
        # enabled with disksize 0 and SwapTotal 0 kB.
        if [ -n "${swap}" ] && [ -n "${dsz}" ] && [ "${dsz}" != "0" ]; then
            s="APPLIED"
        else
            s="PARTIAL"
        fi
    elif [ "${n}" -eq 0 ] && [ -z "${zen}" ]; then
        s="ABSENT"
    else
        s="PARTIAL"
    fi
    st "1 portmaster+zram" "${s}" "files=${n}/3 zram-swap=${zen:-none} hooks.path=${pen:-none} hooks.service=${sen:-none}"
    st "" "" "swap: ${swap:-NONE}  /sys/block/zram0/disksize=${dsz:-n/a}"

    # 2
    if [ "${SOC}" != "rk3326" ]; then
        st "2 scheduler" "N/A" "RK3326 only; this is ${SOC}"
    else
        r="$([ -f /etc/udev/rules.d/60-darkos-scheduler.rules ] && echo yes || echo no)"
        cur="$(blk_attr_report scheduler)"
        case "${cur}" in
            *"[deadline]"*) s="APPLIED" ;;
            "")             s="UNKNOWN" ;;
            *)              s="ABSENT" ;;
        esac
        [ "${r}" = "no" ] && [ "${s}" = "APPLIED" ] && s="PARTIAL"
        st "2 scheduler" "${s}" "rule=${r} live: ${cur:-none}"
    fi

    # 3
    b="$(systemctl show -p Before --value welcome-message.service 2>/dev/null)"
    lp="$(systemctl show -p LoadState --value welcome-message.service 2>/dev/null)"
    if [ "${lp}" != "loaded" ]; then
        st "3 welcome-message" "N/A" "unit not loaded (LoadState=${lp:-unknown})"
    else
        case " ${b} " in
            *" emulationstation.service "*) s="ABSENT" ;;
            *)                              s="APPLIED" ;;
        esac
        st "3 welcome-message" "${s}" "Before=${b:-(empty)}"
    fi

    # 4
    if [ "${SOC}" != "rk3326" ]; then
        st "4 root mount options" "N/A" "RK3326 only; this is ${SOC}"
    elif ! have findmnt; then
        st "4 root mount options" "UNKNOWN" "findmnt not available"
    else
        live="$(findmnt -no OPTIONS / 2>/dev/null)"
        tab="$(findmnt --fstab -no OPTIONS / 2>/dev/null)"
        lv=0; tv=0
        case ",${live}," in *",compress=${ROOT_COMPRESS},"*|*",compress=${ROOT_COMPRESS}"*) lv=1 ;; esac
        case ",${live}," in *",ssd_spread,"*) lv=0 ;; esac
        case ",${tab},"  in *",compress=${ROOT_COMPRESS},"*|*",compress=${ROOT_COMPRESS}"*) tv=1 ;; esac
        case ",${tab},"  in *",ssd_spread,"*) tv=0 ;; esac
        if [ "${lv}" -eq 1 ] && [ "${tv}" -eq 1 ]; then s="APPLIED"
        elif [ "${lv}" -eq 0 ] && [ "${tv}" -eq 0 ]; then s="ABSENT"
        else s="PARTIAL"; fi
        st "4 root mount options" "${s}" "live: ${live:-?}"
        st "" "" "fstab: ${tab:-?}"
        st "" "" "systemd-remount-fs: $(systemctl is-active systemd-remount-fs.service 2>/dev/null)"
    fi

    # 5
    ln="$(systemctl show -p LimitNICE --value emulationstation.service 2>/dev/null)"
    dp="$([ -f /etc/systemd/system/emulationstation.service.d/60-darkos-nice.conf ] && echo yes || echo no)"
    if [ -z "${ln}" ]; then
        st "5 LimitNICE" "UNKNOWN" "unit not present"
    elif [ "${ln}" = "40" ]; then
        st "5 LimitNICE" "APPLIED" "LimitNICE=40 (rlimit form of nice -20), drop-in=${dp}"
    else
        st "5 LimitNICE" "ABSENT" "LimitNICE=${ln}, drop-in=${dp}"
    fi

    # 6
    r="$([ -f /etc/udev/rules.d/60-darkos-readahead.rules ] && echo yes || echo no)"
    cur="$(blk_attr_report read_ahead_kb)"
    case "${cur}" in
        *=512*) s="APPLIED" ;;
        "")     s="UNKNOWN" ;;
        *)      s="ABSENT" ;;
    esac
    [ "${r}" = "no" ] && [ "${s}" = "APPLIED" ] && s="PARTIAL"
    st "6 read-ahead" "${s}" "rule=${r} live: ${cur:-none}"

    # 7
    db="$(cat /proc/sys/vm/dirty_bytes 2>/dev/null)"
    bg="$(cat /proc/sys/vm/dirty_background_bytes 2>/dev/null)"
    f="$([ -f /etc/sysctl.d/60-darkos-writeback.conf ] && echo yes || echo no)"
    if [ "${db}" = "33554432" ] && [ "${bg}" = "8388608" ]; then s="APPLIED"
    elif [ "${db}" = "0" ] || [ -z "${db}" ]; then s="ABSENT"
    else s="PARTIAL"; fi
    [ "${f}" = "no" ] && [ "${s}" = "APPLIED" ] && s="PARTIAL"
    st "7 writeback caps" "${s}" "file=${f} dirty_bytes=${db:-?} dirty_background_bytes=${bg:-?}"

    say ""
    if [ -f "${MANIFEST}" ]; then
        say "A backup directory exists at ${BK} ($(wc -l < "${MANIFEST}" 2>/dev/null) managed paths)."
        say "It is NOT what the states above are read from - they come from the kernel and systemd."
    else
        say "No backup directory at ${BK}: nothing has been applied from this script."
    fi
    return 0
}

###############################################################################
# Summary
###############################################################################

print_summary() {
    [ "${#R_NAME[@]}" -gt 0 ] || return 0
    printf '\n===============================================================\n'
    printf 'SUMMARY\n'
    printf -- '---------------------------------------------------------------\n'
    rc=0
    i=0
    while [ "${i}" -lt "${#R_NAME[@]}" ]; do
        printf '  %-24s %-5s %s\n' "${R_NAME[$i]}" "${R_STATE[$i]}" "${R_NOTE[$i]}"
        [ "${R_STATE[$i]}" = "FAIL" ] && rc=1
        i=$((i + 1))
    done
    if [ "${#REBOOT_NOTES[@]}" -gt 0 ]; then
        printf '\nTAKES EFFECT ONLY AFTER A REBOOT:\n'
        for n in "${REBOOT_NOTES[@]}"; do printf '  - %s\n' "${n}"; done
        printf '\nThis script deliberately does not restart emulationstation.service.\n'
        printf 'Reboot when you are ready:  sudo reboot\n'
    fi
    return "${rc}"
}

###############################################################################
# Entry point
###############################################################################

usage() {
    cat <<'EOF'
apply-to-installed.sh - put PR #38 onto a running dArkOS system, or take it off.

  sudo bash testing/apply-to-installed.sh apply
      Install every change in the PR onto this running system.  Backs up every
      file it touches to /var/backups/darkos-pr38 first, including the fact that
      a file did not exist.  Safe to run twice.

  sudo bash testing/apply-to-installed.sh status
      Report, per change, whether it is currently in force.  Read from the live
      system - mount options, systemd properties, sysfs, /proc - never from the
      backup directory.  Changes nothing.

  sudo bash testing/apply-to-installed.sh undo
      Put everything back from /var/backups/darkos-pr38, disable what apply
      enabled, and write the pre-apply scheduler and read-ahead values back into
      sysfs so a measurement taken after undo is a real baseline.

Run it from inside a checkout of the PR branch, as testing/apply-to-installed.sh
- it finds the files it installs relative to its own location.

It never restarts emulationstation.service.  Changes that need a reboot are
listed at the end of the run.

Order for a test session:
  sudo bash testing/apply-to-installed.sh status   > /tmp/before.txt
  sudo bash testing/apply-to-installed.sh apply
  sudo reboot
  sudo bash testing/apply-to-installed.sh status   > /tmp/after.txt
  bash testing/darkos-diag.sh boot                 > /tmp/diag-after.txt
EOF
}

CMD="${1:-}"
case "${CMD}" in
    ''|-h|--help|help) usage; exit 0 ;;
    apply|undo|status) ;;
    *) printf 'Unknown command: %s\n\n' "${CMD}"; usage; exit 2 ;;
esac

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    printf 'This must run as root: apply and undo write to /etc and /usr/local,\n'
    printf 'and status reads unit properties that are incomplete without it.\n'
    printf 'Re-run it yourself:  sudo bash %s %s\n' "$0" "${CMD}"
    exit 1
fi

detect_platform
if [ "${SOC}" = "unknown" ]; then
    printf 'Cannot tell RK3326 from RK3566: /proc/device-tree/compatible is missing\n'
    printf 'or matches neither.  Refusing to guess - two of the changes are\n'
    printf 'platform specific and the wrong one would be a regression.\n'
    exit 1
fi

case "${CMD}" in
    apply)
        check_sources || exit 1
        do_apply
        ;;
    undo)
        do_undo
        ;;
    status)
        do_status
        exit 0
        ;;
esac

print_summary
exit $?
