#!/bin/bash
# Copy a file or folder out of an APFS volume in a VM disk image, read-only, through this
# checkout's linux-apfs-rw module (./setup/setup.sh builds it).
#
#   tools/apfs-copy-out.sh <Disk.img> <volume> <path-in-volume> <dest-dir>
#     volume: the APFS volume index in the container (0 is iOS's System volume)
#
# For when 7-Zip cannot open the container: 7-Zip 26.04 (Arch's 7zip package) fails on iOS
# disks with "Cannot open the file as [APFS] archive". Needs root (insmod, losetup, mount); the
# copy is handed to the calling user. The disk is attached read-only and detached afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."
DISK=${1:?usage: apfs-copy-out.sh <Disk.img> <volume> <path-in-volume> <dest-dir>}
VOL=${2:?usage: apfs-copy-out.sh <Disk.img> <volume> <path-in-volume> <dest-dir>}
SRC=${3:?usage: apfs-copy-out.sh <Disk.img> <volume> <path-in-volume> <dest-dir>}
DEST=${4:?usage: apfs-copy-out.sh <Disk.img> <volume> <path-in-volume> <dest-dir>}
MOD=$PWD/.build/linux-apfs-rw/apfs.ko

if ! grep -q '^apfs ' /proc/modules; then
  [ -f "$MOD" ] || { echo "linux-apfs-rw is not built ($MOD): run ./setup/setup.sh build" >&2; exit 1; }
  sudo insmod "$MOD"
fi
MNT=$(mktemp -d)
LOOP=''
done_() {
  if mountpoint -q "$MNT"; then sudo umount "$MNT"; fi
  if [ -n "$LOOP" ]; then sudo losetup -d "$LOOP"; fi
  rmdir "$MNT"
}
trap done_ EXIT
LOOP=$(sudo losetup -r -f -P --show "$DISK")
# The container is the disk's one GPT partition; udev may take a moment to create its node.
for _ in $(seq 1 50); do [ -b "${LOOP}p1" ] && break; sleep 0.1; done
[ -b "${LOOP}p1" ] || { echo "no partition found on $DISK" >&2; exit 1; }
sudo mount -t apfs -o "ro,vol=$VOL" "${LOOP}p1" "$MNT"
[ -e "$MNT/$SRC" ] || { echo "$SRC not found in volume $VOL of $DISK" >&2; exit 1; }
mkdir -p "$DEST"
sudo cp -a "$MNT/$SRC" "$DEST/"
sudo chown -R "$(id -u):$(id -g)" "$DEST/$(basename "$SRC")"
