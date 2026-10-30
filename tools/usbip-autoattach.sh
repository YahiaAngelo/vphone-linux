#!/bin/bash
# Run as root while restoring a VM over USB/IP (tools/vusb-usbip.py):
#
#   sudo tools/usbip-autoattach.sh
#
# A restore moves the guest through several boot stages (DFU, iBoot, the restore OS), and each
# presents a new USB device. The exporter unplugs the old one and offers the new one; this
# attaches whatever 127.0.0.1 offers whenever nothing from it is attached. Ctrl-C to stop.
# It only ever talks to the local exporter. It also lets the user open the device in DFU and
# recovery mode (a udev rule in /run, gone at reboot).
set -u
HOST=127.0.0.1
[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
modprobe vhci-hcd
# vphone-cli's libirecovery opens the DFU/recovery device itself, as the user, through libusb.
# Without a rule the attached device is root-only, libirecovery skips it, and recovery-probe
# times out ("did not enter dfu/recovery mode in time"). Distros that ship libirecovery's own
# rule give it to a group (plugdev, storage...) the user is often not in, and Arch has none at
# all. This one lives in /run, so it is gone after a reboot, like the usbmuxd mask. MODE:= (final):
# systemd's 50-udev-default.rules, read after it, would set USB devices back to 0664.
RULE=/run/udev/rules.d/39-vphone-dfu.rules
mkdir -p "${RULE%/*}"
cat > "$RULE" <<'RULES'
# vphone-linux (tools/usbip-autoattach.sh): Apple DFU, WTF and recovery mode devices for libirecovery.
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="05ac", ATTR{idProduct}=="122[27]|128[0-3]", MODE:="0666"
RULES
udevadm control --reload 2>/dev/null || true
# A device attached before the rule existed gets it now.
udevadm trigger --action=add --subsystem-match=usb --attr-match=idVendor=05ac 2>/dev/null || true
echo "attaching devices offered by $HOST (Ctrl-C to stop)"
while true; do
  # usbip port often cannot name the remote host ("unknown host"), so any import counts.
  if ! usbip port 2>/dev/null | grep -q "Port in Use"; then
    busid=$(usbip list -r "$HOST" 2>/dev/null | sed -nE 's/^ *([0-9]+-[0-9.]+): .*/\1/p' | head -1)
    if [ -n "$busid" ]; then
      if usbip attach -r "$HOST" -b "$busid" 2>/dev/null; then
        echo "$(date +%T) attached $(usbip list -r "$HOST" 2>/dev/null | grep -m1 "$busid:" | sed 's/^ *//')"
      fi
    fi
  fi
  sleep 0.5
done
