#!/bin/bash
# Compressed in-RAM swap, so the heavier ports and emulators get room to breathe
# instead of being OOM killed, without touching the SD card.
#
# dolphin.sh and ppsspp.sh already do this on demand and skip when zramctl
# reports a device, so they find an equivalent zram0 already up and lose nothing
# by skipping.  1G is their size, which is why it is the size used here.

zram_device="/dev/zram0"
zram_sysfs="/sys/block/zram0"
sysctl_state="/run/zram-swap.sysctl"

zram_start() {
  modprobe zram num_devices=1 2>/dev/null
  [ -d "${zram_sysfs}" ] || exit 0
  grep -q "^${zram_device}[[:space:]]" /proc/swaps && exit 0

  # comp_algorithm lists the algorithms this kernel offers and brackets the one it
  # has selected.  dolphin.sh and ppsspp.sh both ask for lz4, so ask for the same
  # thing wherever it is on offer.
  kernel_algorithm=""
  if grep -qw lz4 "${zram_sysfs}/comp_algorithm"; then
    kernel_algorithm="$(sed -n 's/.*\[\([^]]*\)\].*/\1/p' "${zram_sysfs}/comp_algorithm")"
    echo lz4 > "${zram_sysfs}/comp_algorithm" 2>/dev/null
  fi

  # The compressor is only instantiated once disksize is written, so a name that
  # comp_algorithm accepted can still be refused at this point, leaving disksize at
  # 0.  Reading it back is the check that the choice took; put the kernel's own
  # selection back and retry rather than end up swapless.
  echo 1G > "${zram_sysfs}/disksize" 2>/dev/null
  if [ "$(cat "${zram_sysfs}/disksize")" = "0" ] && [ -n "${kernel_algorithm}" ]; then
    echo "${kernel_algorithm}" > "${zram_sysfs}/comp_algorithm" 2>/dev/null
    echo 1G > "${zram_sysfs}/disksize" 2>/dev/null
  fi
  [ "$(cat "${zram_sysfs}/disksize")" = "0" ] && exit 0

  # The device node is created by udev, so it can lag the module load slightly.
  # Kept short because this unit is ordered before EmulationStation: swapless is a
  # better outcome than a boot that visibly stalls.
  attempt=0
  while [ ! -b "${zram_device}" ] && [ "${attempt}" -lt 20 ]; do
    attempt=$((attempt + 1))
    sleep 0.1
  done
  [ -b "${zram_device}" ] || exit 0

  mkswap "${zram_device}" > /dev/null
  if swapon -p 100 "${zram_device}"; then
    # Only meaningful now that swap exists: reach for it early rather than late,
    # and do not read ahead into a device that decompresses a page at a time.
    { sysctl -n vm.swappiness; sysctl -n vm.page-cluster; } > "${sysctl_state}"
    sysctl -q -w vm.swappiness=100 vm.page-cluster=0
  fi
}

zram_stop() {
  swapoff "${zram_device}" 2>/dev/null

  if [ -s "${sysctl_state}" ]; then
    { read -r swappiness; read -r page_cluster; } < "${sysctl_state}"
    sysctl -q -w vm.swappiness="${swappiness}" vm.page-cluster="${page_cluster}"
    rm -f "${sysctl_state}"
  fi

  # reset is refused with EBUSY while the device is still held, which is exactly
  # what a swapoff cut short by TimeoutStopSec leaves behind.  systemd swaps off
  # again in its final shutdown phase, so give up quietly instead.
  if [ -d "${zram_sysfs}" ]; then
    echo 1 > "${zram_sysfs}/reset" 2>/dev/null
  fi
}

case "$1" in
  start) zram_start ;;
  stop)  zram_stop ;;
  *)     echo "usage: $0 {start|stop}" >&2; exit 1 ;;
esac
