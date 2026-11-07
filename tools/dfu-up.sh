#!/bin/bash
# Start a VM bundle in DFU for a Linux restore: QEMU with the virtual USB device controller,
# and tools/vusb-usbip.py exporting it over USB/IP on 127.0.0.1.
#
#   tools/dfu-up.sh <vm-dir> <run-dir>
#
# The VM's Disk.img must hold no bootable system (a fresh, empty one), so AVPBooter stays in DFU.
# Then, as root in other terminals: tools/usbmuxd-32k.sh and tools/usbip-autoattach.sh, and run
# `vphone-cli restore`. Logs go to <run-dir> (serial.log, stderr.log, qemu.log, usbip.log).
# Only the QEMU and exporter that a previous dfu-up.sh started for <run-dir> are stopped first.
#
# Env: QEMU (default: qemu/build),
#      GFX=1 WINDOW=1 (open the display window to watch), SMP (8), VUSB_DEBUG=1 (log every URB), VUSB_URB_TIMEOUT (seconds, default 300).
set -euo pipefail
VM=$(realpath "${1:?usage: dfu-up.sh <vm-dir> <run-dir>}")
mkdir -p "${2:?usage: dfu-up.sh <vm-dir> <run-dir>}"
R=$(realpath "$2")
cd "$(dirname "$0")/.."
SOCK=$R/vusb.sock
EXPORTER=$PWD/tools/vusb-usbip.py
EXPORTER_PID_FILE=$R/usbip-exporter.pid
# A PID can be reused. The recorded start time and both exact arguments must
# still identify this run's exporter before timeout is asked to stop it.
stop_previous_exporter() {
  local pid started extra current
  [ -f "$EXPORTER_PID_FILE" ] || return 0
  read -r pid started extra < "$EXPORTER_PID_FILE" || return 0
  [[ $pid =~ ^[0-9]+$ && $started =~ ^[0-9]+$ && -z $extra ]] || {
    echo "invalid exporter identity: $EXPORTER_PID_FILE" >&2; return 1;
  }
  [ -r "/proc/$pid/stat" ] || return 0
  current=$(sed 's/^.*) //' "/proc/$pid/stat" | awk '{print $20}')
  [ "$current" = "$started" ] || return 0
  tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Fx -- "$EXPORTER" >/dev/null || return 0
  tr '\0' '\n' < "/proc/$pid/cmdline" | grep -Fx -- "$SOCK" >/dev/null || return 0
  kill "$pid"
}
# Never two guests on one disk (the drives are opened without locking). Checked first, before
# anything is stopped: a VM from another run on this disk is refused; this run's own is restarted.
want=$(stat -L -c %d:%i "$VM/Disk.img")
for p in $(pgrep -x qemu-system-aar || true); do
  cmd=$(tr '\0' ' ' </proc/$p/cmdline 2>/dev/null) || continue
  # By inode: a VM started with a relative or symlinked path to this disk still counts.
  hit=
  for f in $(tr '\0' '\n' </proc/$p/cmdline | grep -oE 'file=[^,]*Disk\.img' | cut -d= -f2); do
    [ "$(cd "$(readlink /proc/$p/cwd 2>/dev/null || echo /)" && stat -L -c %d:%i "$f" 2>/dev/null)" = "$want" ] && hit=1
  done
  [ -n "$hit" ] || continue
  case $cmd in *"$SOCK"*) continue ;; esac
  echo "a VM is already running $VM (QEMU pid $p); stop it first: tools/dfu-stop.sh $VM" >&2; exit 2
done
# An exporter belonging to another run is never stopped to free the USB/IP port.
stop_previous_exporter
for p in $(pgrep -x qemu-system-aar || true); do
  tr '\0' ' ' </proc/$p/cmdline | grep -q -- "$SOCK" && kill "$p"
done
sleep 2
rm -f "$SOCK"
(QEMU=${QEMU:-$PWD/qemu/build/qemu-system-aarch64} CID=0 SMP=${SMP:-8} \
  GFX=${GFX:-0} WINDOW=${WINDOW:-0} \
  DFLAGS=guest_errors LOG=$R/qemu.log timeout 14400 \
  ./run-vphone.sh "$VM" -chardev socket,id=vusb,path=$SOCK,server=on,wait=off \
  -global vresearch-vusb.chardev=vusb > "$R/serial.log" 2> "$R/stderr.log" &)
for _ in $(seq 1 30); do [ -S "$SOCK" ] && break; sleep 1; done
[ -S "$SOCK" ] || { echo "QEMU did not start; see $R/stderr.log" >&2; exit 1; }
sleep 20   # AVPBooter reaches DFU
VUSB_DEBUG=${VUSB_EXPORTER_DEBUG:-} VUSB_URB_TIMEOUT=${VUSB_URB_TIMEOUT:-300} timeout 14400 \
  python3 -u "$EXPORTER" "$SOCK" > "$R/usbip.log" 2>&1 &
exporter_pid=$!
exporter_started=$(sed 's/^.*) //' "/proc/$exporter_pid/stat" | awk '{print $20}')
printf '%s %s\n' "$exporter_pid" "$exporter_started" > "$EXPORTER_PID_FILE"
echo "DFU VM up; exporter log $R/usbip.log. Attach with: sudo tools/usbip-autoattach.sh"
