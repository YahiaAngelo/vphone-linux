#!/bin/bash
# Explain why `vphone-cli recovery-probe` found no DFU/recovery device: prints what it finds at
# each link of the chain (QEMU, the USB/IP exporter, the attach, the USB device, its permissions).
#
#   tools/dfu-diagnose.sh [<run-dir>]      # run-dir: the one given to tools/dfu-up.sh, for its logs
#
# Read-only; run as the same user as vphone-cli. Called by the setup scripts when the probe fails.
set -uo pipefail
R=${1:-}
say() { printf '  %s\n' "$*" >&2; }
echo "DFU diagnosis:" >&2

if pgrep -x qemu-system-aar >/dev/null; then say "QEMU: running"
else say "QEMU: NOT running${R:+ (see $R/stderr.log, $R/qemu.log)}"; fi

if pgrep -f 'python3 -u tools/vusb-usbip\.py' >/dev/null; then say "USB/IP exporter: running"
else say "USB/IP exporter: NOT running${R:+ (see $R/usbip.log)}"; fi

if pgrep -f 'usbip-autoattach\.sh' >/dev/null; then say "attach loop: running"
else say "attach loop: NOT running (sudo tools/usbip-autoattach.sh)"; fi
[ -d /sys/bus/platform/drivers/vhci_hcd ] || say "vhci_hcd: not loaded (sudo modprobe vhci-hcd)"

found=0
for d in /sys/bus/usb/devices/*; do
  [ "$(cat "$d/idVendor" 2>/dev/null)" = 05ac ] || continue
  pid=$(cat "$d/idProduct"); found=1
  node=$(printf '/dev/bus/usb/%03d/%03d' "$(cat "$d/busnum")" "$(cat "$d/devnum")")
  case $pid in
    1227|1222) mode="DFU" ;; 128[0-3]) mode="recovery" ;; *) mode="other mode" ;;
  esac
  if [ -r "$node" ] && [ -w "$node" ]; then
    say "USB device 05ac:$pid ($mode) at $node: attached, and this user can open it"
  else
    say "USB device 05ac:$pid ($mode) at $node: attached, but this user CANNOT open it ($(stat -c '%U:%G %a' "$node" 2>/dev/null))"
    say "  -> libirecovery skips it. Restart the attach loop from this checkout (it installs a udev rule):"
    say "     sudo pkill -f usbip-autoattach.sh; sudo tools/usbip-autoattach.sh"
  fi
done
if [ "$found" = 0 ]; then
  say "USB device: no Apple (05ac) device attached"
  if command -v usbip >/dev/null; then
    offered=$(usbip list -r 127.0.0.1 2>/dev/null | grep -cE '^ *[0-9]+-[0-9.]+:' || true)
    say "  the exporter offers $offered device(s) on 127.0.0.1 (none: the guest never reached DFU${R:+, see $R/serial.log})"
  else
    say "  'usbip' is not installed"
  fi
fi
[ -r /tmp/vphone-usbip-autoattach.log ] && say "attach log: /tmp/vphone-usbip-autoattach.log"
exit 0
