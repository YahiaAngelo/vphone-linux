#!/bin/bash
# Build the SSH ramdisk: the stock cloudOS restore ramdisk with the SSH tools from the staging tree
# (tools/ssh-ramdisk-stage.sh) injected. The tools are not re-signed; tools/restore-tree-mode.sh adds
# their code hashes to the trust cache and forces TXM's selector-24 check to pass.
#
# Usage (as your normal user; it asks for sudo once, for the APFS mount):
#   bash tools/ssh-ramdisk-rebuild-signed.sh <library> <vm>
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
LIB=${1:?usage: ssh-ramdisk-rebuild-signed.sh <library> <vm>   (restore tree in full mode)}
VM=${2:?usage: ssh-ramdisk-rebuild-signed.sh <library> <vm>}
shopt -s nullglob; trees=("$LIB/$VM"/*_Restore)
[ ${#trees[@]} -eq 1 ] || { echo "expected one *_Restore tree in $LIB/$VM" >&2; exit 1; }
# The restore ramdisk differs per cloudOS (26.4: 094-39914-031.dmg, 18.7.2: 043-59579-029.dmg):
# take its name from the tree's manifest, and keep one stock copy and one SSH build per name.
RD=$(python3 - "${trees[0]}/BuildManifest.plist" <<'PY'
import plistlib, sys
m = plistlib.load(open(sys.argv[1], "rb"))
for bi in m["BuildIdentities"]:
    c = bi["Manifest"].get("RestoreRamDisk")
    if c and c.get("Info", {}).get("Path"):
        print(c["Info"]["Path"]); break
PY
)
[ -n "$RD" ] || { echo "no RestoreRamDisk in ${trees[0]}/BuildManifest.plist" >&2; exit 1; }
STOCK="$ROOT/runs/sshramdisk/stock-$RD"
BASE="$ROOT/runs/sshramdisk/base/${RD%.dmg}/apfs.img"
STAGE="$ROOT/runs/sshramdisk/ssh-root"
WORK="$ROOT/runs/sshramdisk/base-signed"
PAYLOAD="$WORK/apfs.img"
OUT="$ROOT/runs/sshramdisk/out/$RD"
MNT=/mnt/vphone-sshramdisk

# The stock restore ramdisk and its APFS payload come from the VM's restore tree, once.
if [ ! -f "$STOCK" ]; then
    [ -e "${trees[0]}/$RD.full-restore" ] && { echo "tree is in ssh mode; run restore-tree-mode.sh ... full first" >&2; exit 1; }
    mkdir -p "$(dirname "$STOCK")"
    cp "${trees[0]}/$RD" "$STOCK"
    cp "${trees[0]}/Firmware/$RD.trustcache" "$STOCK.trustcache"
fi
if [ ! -f "$BASE" ]; then
    mkdir -p "$(dirname "$BASE")"
    tail -c +28 "$STOCK" > "$BASE"     # the APFS container starts at byte 27 of the IM4P
fi

for f in "$STOCK" "$BASE" "$STAGE/usr/local/bin/dropbear"; do
    [ -e "$f" ] || { echo "missing $f (staging tree: tools/ssh-ramdisk-stage.sh)" >&2; exit 1; }
done

echo "=== fresh APFS copy (stock base is left untouched)"
rm -rf "$WORK"
mkdir -p "$WORK"
cp "$BASE" "$PAYLOAD"

echo "=== inject the staging tree (needs sudo for losetup/mount)"
sudo "$ROOT/tools/ssh-ramdisk-inject.sh" "$PAYLOAD" "$STAGE" "$MNT"

echo "=== repack into the stock rdsk IM4P wrapper"
"$ROOT/tools/ssh-ramdisk-repack.sh" "$STOCK" "$PAYLOAD" "$OUT"

echo "=== built $OUT; install it with: tools/restore-tree-mode.sh $LIB $VM ssh"
echo "=== done"
sha1sum "$OUT"
