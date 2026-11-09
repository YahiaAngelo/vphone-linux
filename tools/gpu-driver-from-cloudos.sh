#!/bin/bash
# Get the paravirtual GPU driver for `fw prepare --gpu-driver-bundle` from a stock cloudOS restore.
#
#   tools/gpu-driver-from-cloudos.sh <cloudOS.ipsw> <out-dir>
#     -> <out-dir>/AppleParavirtGPUMetalIOGPUFamily.bundle
#
# The driver ships in the cloudOS IPSW's AEA-encrypted cryptex, and Apple's key server no longer
# hands out the key for the cloudOS build vphone-cli pairs with (26.4 23E5207q). vphone-cli on a Mac
# restores the stock cloudOS into a temporary VM and reads the driver from its System volume; this
# does the same on Linux: a temporary bundle (tools/new-vm.sh, OpenAVB/OpenSEP), the IPSW unzipped as
# its restore tree, a restore over USB/IP, then 7-Zip reads the driver from Disk.img (no root, no
# mount). Where 7-Zip cannot open the disk (7-Zip 26.04), tools/apfs-copy-out.sh reads it
# read-only through linux-apfs-rw instead (root). The temporary VM is deleted afterwards (KEEP=1
# keeps it).
#
# Needs, as for any Linux restore: the 32 KiB usbmuxd and the USB/IP attacher running as root
# (sudo tools/usbmuxd-32k.sh; sudo tools/usbip-autoattach.sh), 7-Zip (7z), and about 5 GB free.
# Takes about 20-30 minutes.
set -euo pipefail
cd "$(dirname "$0")/.."
IPSW=$(realpath "${1:?usage: gpu-driver-from-cloudos.sh <cloudOS.ipsw> <out-dir>}")
OUT=${2:?usage: gpu-driver-from-cloudos.sh <cloudOS.ipsw> <out-dir>}
VC=${VC:-$PWD/linux-create/vphone-cli}
NAME=gpu-recovery-$$
VM=vms/$NAME
RUN=runs/$NAME
BUNDLE=Volume1/System/Library/Extensions/AppleParavirtGPUMetalIOGPUFamily.bundle

command -v 7z >/dev/null || { echo "7z (7-Zip) is needed" >&2; exit 1; }
[ -x "$VC" ] || { echo "build vphone-cli first (linux-create/)" >&2; exit 1; }
if [ "${VPHONE_CREATOR_USB_READY:-0}" = 1 ]; then
  case ${USBMUXD_SOCKET_ADDRESS:-} in
    UNIX:/*) ;;
    *) echo "VPHONE_CREATOR_USB_READY requires USBMUXD_SOCKET_ADDRESS=UNIX:/absolute/path" >&2; exit 1 ;;
  esac
  [ -S "${USBMUXD_SOCKET_ADDRESS#UNIX:}" ] || {
    echo "private usbmuxd socket missing: ${USBMUXD_SOCKET_ADDRESS#UNIX:}" >&2; exit 1;
  }
else
  pgrep -f 'usbmuxd-32k/usbmuxd' >/dev/null || { echo "start the 32 KiB usbmuxd first: sudo tools/usbmuxd-32k.sh" >&2; exit 1; }
  pgrep -f 'usbip-autoattach.sh' >/dev/null || { echo "start the USB/IP attacher first: sudo tools/usbip-autoattach.sh" >&2; exit 1; }
fi
[ -e "$OUT/AppleParavirtGPUMetalIOGPUFamily.bundle" ] && { echo "$OUT/AppleParavirtGPUMetalIOGPUFamily.bundle exists" >&2; exit 1; }

stop_vm() {
  for p in $(pgrep -x qemu-system-aar || true); do
    tr '\0' ' ' </proc/$p/cmdline 2>/dev/null | grep -q -- "$PWD/$RUN/" && kill "$p"
  done
  for p in $(pgrep -x python3 || true); do
    tr '\0' ' ' </proc/$p/cmdline 2>/dev/null | grep -q -- "$PWD/$RUN/vusb.sock" && kill "$p"
  done
  return 0
}
created_vm=0
cleanup() {
  [ "$created_vm" = 1 ] || return 0
  stop_vm
  if [ "${KEEP:-0}" != 1 ]; then rm -rf "$VM"; fi
}
trap cleanup EXIT

echo "=== temporary VM $VM"
tools/new-vm.sh "$VM" >/dev/null
created_vm=1
# Lock the actual disk inode. The descriptor remains open across the restore's children.
exec {GPU_DISK_LOCK}<>"$VM/Disk.img"
flock -n "$GPU_DISK_LOCK" || { echo "temporary VM disk is already locked: $VM/Disk.img" >&2; exit 1; }
echo "=== unzipping $(basename "$IPSW") as its restore tree"
unzip -q "$IPSW" -d "$VM/iPhonePCC_Restore"
# The temporary VM reports iPhone99,11, which cloudOS releases after the 26.4 beta leave out of
# SupportedProductTypes; idevicerestore refuses a manifest that does not list the device.
python3 - "$VM/iPhonePCC_Restore/BuildManifest.plist" <<'PY'
import plistlib, sys
p = sys.argv[1]
m = plistlib.load(open(p, "rb"))
types = m.get("SupportedProductTypes", [])
if "iPhone99,11" not in types:
    m["SupportedProductTypes"] = types + ["iPhone99,11"]
    plistlib.dump(m, open(p, "wb"), fmt=plistlib.FMT_XML)
PY

echo "=== DFU"
tools/dfu-up.sh "$VM" "$RUN" >/dev/null
for _ in $(seq 1 60); do "$VC" recovery-probe >/dev/null 2>&1 && break; sleep 3; done
"$VC" recovery-probe || { tools/dfu-diagnose.sh "$RUN"; exit 1; }

echo "=== restoring the stock cloudOS (log: $RUN/restore.log)"
# restore-wait.sh: the tool can wait forever for the device to come back after a finished
# restore (issue #19).
VPHONE_RESTORE_TIMEOUT_SCALE=${VPHONE_RESTORE_TIMEOUT_SCALE:-10} \
  tools/restore-wait.sh "$RUN/restore.log" "$VC" restore -l vms "$NAME" -v \
  || { tail -20 "$RUN/restore.log" >&2; echo "restore failed; log: $RUN/restore.log" >&2; exit 1; }
grep -q -i 'restore finished' "$RUN/restore.log" || { echo "restore did not finish; log: $RUN/restore.log" >&2; exit 1; }
stop_vm
sleep 3

echo "=== reading the driver from the System volume"
TMP=$(mktemp -d "$PWD/.build/gpu-driver.XXXXXX")
if 7z x "$VM/Disk.img" -o"$TMP" "$BUNDLE" -r -y >/dev/null 2>&1 &&
   [ -f "$TMP/$BUNDLE/AppleParavirtGPUMetalIOGPUFamily" ]; then
  FOUND=$TMP/$BUNDLE
else
  # 7-Zip 26.04 (Arch's 7zip) cannot open these containers ("Cannot open the file as [APFS]
  # archive"): read the System volume (volume 0) through linux-apfs-rw instead, as root.
  echo "    7-Zip could not read the disk; mounting it read-only through linux-apfs-rw (sudo)"
  rm -rf "$TMP" && mkdir -p "$TMP"
  tools/apfs-copy-out.sh "$VM/Disk.img" 0 "${BUNDLE#Volume1/}" "$TMP"
  FOUND=$TMP/$(basename "$BUNDLE")
fi
[ -f "$FOUND/AppleParavirtGPUMetalIOGPUFamily" ] || { echo "driver not found in the restored disk" >&2; exit 1; }
mkdir -p "$OUT"
mv "$FOUND" "$OUT/"
rm -rf "$TMP"
echo "=== $OUT/AppleParavirtGPUMetalIOGPUFamily.bundle"
sha1sum "$OUT/AppleParavirtGPUMetalIOGPUFamily.bundle/AppleParavirtGPUMetalIOGPUFamily"
