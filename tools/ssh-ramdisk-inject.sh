#!/bin/bash
# Inject the SSHRD tools into the extracted cloudOS restore-ramdisk APFS container.
#
# The restore ramdisk (094-39914-031.dmg) is an uncompressed rdsk IM4P whose payload
# is one unsealed APFS volume named "ramdisk".  Its launchd config already runs
# /usr/local/bin/restored_external, and ssh.tar.gz overwrites that path with the
# SSHRD daemon, so no launchd changes are needed.
#
# Run as root:
#   sudo tools/ssh-ramdisk-inject.sh
#
# Then repack (unprivileged):
#   tools/ssh-ramdisk-repack.sh
#
# If a run fails halfway, re-extract the stock payload before retrying:
#   tail -c +28 runs/sshramdisk/stock-094-39914-031.dmg \
#     > runs/sshramdisk/base/apfs.img
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASE=${1:-$ROOT/runs/sshramdisk/base/apfs.img}
STAGE=${2:-$ROOT/runs/sshramdisk/ssh-root}
MNT=${3:-/mnt/vphone-sshramdisk}
MOD=$ROOT/.build/linux-apfs-rw/apfs.ko

[ "$(id -u)" = 0 ] || { echo "run as root: sudo $0" >&2; exit 1; }
[ -f "$BASE" ] || { echo "missing base APFS image: $BASE" >&2; exit 1; }
[ -d "$STAGE" ] || { echo "missing SSH staging dir: $STAGE" >&2; exit 1; }
# The APFS driver: already loaded, installed (modprobe), $VPHONE_APFS_KO, or the build in this
# checkout (docs/SETUP.md step 3), in that order, as cfw install does.
if ! grep -qw apfs /proc/filesystems; then
    modprobe apfs 2>/dev/null || {
        MOD=${VPHONE_APFS_KO:-$MOD}
        [ -f "$MOD" ] || { echo "the APFS driver is not loaded and $MOD is missing: build it (docs/SETUP.md step 3)" >&2; exit 1; }
        insmod "$MOD"
    }
fi

mkdir -p "$MNT"
LOOP=$(losetup -f --show "$BASE")
cleanup() {
    set +e
    mountpoint -q "$MNT" && umount "$MNT"
    losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

# linux-apfs-rw accepts "readwrite"; fall back to the kernel spelling if needed.
if ! mount -t apfs -o readwrite,vol=0 "$LOOP" "$MNT" 2>/dev/null; then
    mount -t apfs -o rw,vol=0 "$LOOP" "$MNT"
fi

echo "=== mounted $LOOP at $MNT"
df -h "$MNT" || true

# Drop the tools/firmware we never keep.  Do it before extraction: the volume
# has ~40 MiB free and the staging tree is ~35 MiB.
DROP=(
    usr/bin/img4tool
    usr/bin/img4
    usr/sbin/dietappleh13camerad
    usr/sbin/dietappleh16camerad
    usr/local/bin/wget
    usr/local/bin/procexp
    # Other devices' firmware and accessory updaters: the restore uses them, the SSH ramdisk
    # does not, and the iOS 18 ramdisk (168 MB, 25 MB free) has no room for the tools without.
    usr/standalone/firmware
    usr/lib/updaters
)
for p in "${DROP[@]}"; do
    rm -rf "${MNT:?}/$p"
done
df -h "$MNT" || true

# Unlink existing regular files and symlinks first, but never directories:
# on APFS `rm` of a non-empty directory fails with EINVAL (the old `-U`
# unlink-first mode is what broke the first run).  Unlinking individual files
# still preserves the other links of a hardlinked base file instead of
# truncating the shared inode, which a plain overwrite would do.
tar -C "$STAGE" -cf - . | tar -C "$MNT" -tf - | while IFS= read -r p; do
    if [ -L "$MNT/$p" ] || { [ -e "$MNT/$p" ] && [ ! -d "$MNT/$p" ]; }; then
        rm -f "$MNT/$p"
    fi
done

# --no-overwrite-dir leaves the metadata of the ramdisk's existing directories
# alone; --touch avoids restoring mtimes the APFS writer does not support;
# --no-same-owner avoids chown failures (chown -h below fixes ownership).
tar -C "$STAGE" -cf - . | tar -C "$MNT" --no-overwrite-dir --touch --no-same-owner -xf -

# The new files come from the staging dir; make them root-owned without
# dereferencing the ramdisk's absolute symlinks (-h is lchown, not chown).
chown -Rh 0:0 "$MNT" 2>/dev/null || true

# In case the staging tree carried any of them, drop them again.
for p in "${DROP[@]}"; do
    rm -rf "${MNT:?}/$p"
done

sync
echo "=== after injection"
df -h "$MNT" || true

umount "$MNT"
losetup -d "$LOOP"
trap - EXIT
echo "injected SSHRD tools into $BASE"
