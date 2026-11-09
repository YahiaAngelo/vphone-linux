#!/bin/bash
# Switch a VM's restore tree between a full restore and the SSH ramdisk.
#
#   tools/restore-tree-mode.sh <library> <vm> ssh     # for `restore --boot-ramdisk`
#   tools/restore-tree-mode.sh <library> <vm> full    # back to a normal full restore
#
# A full restore needs the stock ramdisk (its restored_external is the restore daemon) and the
# release restore kernel. The SSH ramdisk needs the SSH ramdisk image, a trust cache that admits
# its tools, TXM's selector-24 pre-check forced to PASS, and the research kernel as the restore
# kernel (its AMFI lets the ad-hoc SSH tools run). Every manifest entry this changes gets the
# file's SHA-384 as its digest.
#
# `ssh` keeps the full-restore files as *.full-restore next to them, once; `full` puts them back.
# No root needed. The SSH ramdisk image itself is built once per firmware with
# tools/ssh-ramdisk-rebuild-signed.sh (root, for the APFS mount) into runs/sshramdisk/out/.
#
# Env: VC (vphone-cli), SSHRD (the SSH ramdisk image), SSHROOT (its staging tree),
#      STOCK_RTSC (the stock restore trust cache).
set -euo pipefail
cd "$(dirname "$0")/.."
LIB=${1:?usage: restore-tree-mode.sh <library> <vm> ssh|full}
VM=${2:?usage: restore-tree-mode.sh <library> <vm> ssh|full}
MODE=${3:?usage: restore-tree-mode.sh <library> <vm> ssh|full}
VC=${VC:-$PWD/linux-create/vphone-cli}
SSHRD=${SSHRD:-$PWD/runs/sshramdisk/out/094-39914-031.dmg}
SSHROOT=${SSHROOT:-$PWD/runs/sshramdisk/ssh-root}
STOCK_RTSC=${STOCK_RTSC:-$PWD/runs/sshramdisk/stock-094-39914-031.dmg.trustcache}

shopt -s nullglob
trees=("$LIB/$VM"/*_Restore)
[ ${#trees[@]} -eq 1 ] || { echo "expected one *_Restore tree in $LIB/$VM" >&2; exit 1; }
T=${trees[0]}
M=$T/BuildManifest.plist

# path of a manifest component (first identity that has it)
component_path() {
    python3 - "$M" "$1" <<'PY'
import plistlib, sys
m = plistlib.load(open(sys.argv[1], "rb"))
for bi in m["BuildIdentities"]:
    c = bi["Manifest"].get(sys.argv[2])
    if c and c.get("Info", {}).get("Path"):
        print(c["Info"]["Path"]); break
PY
}

RD=$(component_path RestoreRamDisk)
TC=$(component_path RestoreTrustCache)
TXM=$(component_path Ap,RestoreTrustedExecutionMonitor)
SAVED=("$M" "$T/$RD" "$T/$TC" "$T/$TXM")

case $MODE in
ssh)
    for f in "$SSHRD" "$STOCK_RTSC" "$SSHROOT/usr/local/bin/dropbear"; do
        [ -e "$f" ] || { echo "missing $f: build the SSH ramdisk first (tools/ssh-ramdisk-stage.sh, then tools/ssh-ramdisk-rebuild-signed.sh $LIB $VM)" >&2; exit 1; }
    done
    for f in "${SAVED[@]}"; do
        [ -e "$f.full-restore" ] || cp --reflink=auto -p "$f" "$f.full-restore"
    done
    echo "=== SSH ramdisk -> $RD"
    cp "$SSHRD" "$T/$RD"
    echo "=== trust cache -> $TC"
    python3 tools/ssh-ramdisk-trustcache.py "$STOCK_RTSC" "$SSHROOT" "$T/$TC"
    echo "=== TXM selector-24 pre-check -> PASS"
    # Always patch the full-restore TXM, so running this twice is safe.
    cp "$T/$TXM.full-restore" "$T/$TXM"
    # Its own manifest refresh can fail ("file doesn't exist"); the digests are set below.
    if ! "$VC" fw patch -l "$LIB" "$VM" --restore-txm-precheck; then
        cmp -s "$T/$TXM" "$T/$TXM.full-restore" && { echo "TXM was not patched" >&2; exit 1; }
        echo "(fw patch's manifest refresh failed after patching TXM; continuing)"
    fi
    KERNEL=$(component_path KernelCache)
    echo "=== restore kernel -> $KERNEL (research)"
    python3 - "$M" "$T" "$KERNEL" <<'PY'
import hashlib, os, plistlib, sys
path, tree, kernel = sys.argv[1:4]
m = plistlib.load(open(path, "rb"))
# idevicerestore retypes these IM4Ps when it sends them (img4.c's component tag table), and
# the image is checked against a digest of the retyped bytes: krnl -> rkrn, trxm -> rtrx, ...
TAGS = {"RestoreKernelCache": b"rkrn", "RestoreRamDisk": b"rdsk",
        "RestoreTrustCache": b"rtsc", "Ap,RestoreTrustedExecutionMonitor": b"rtrx"}
def sha(p, key):
    data = open(os.path.join(tree, p), "rb").read()
    i = data.find(b"\x16\x04IM4P", 0, 32)
    if i < 0 or data[i + 6:i + 8] != b"\x16\x04":
        sys.exit(f"{p}: not an IM4P")
    data = data[:i + 8] + TAGS[key] + data[i + 12:]
    return hashlib.sha384(data).digest()
for bi in m["BuildIdentities"]:
    man = bi["Manifest"]
    if "RestoreKernelCache" in man:
        man["RestoreKernelCache"]["Info"]["Path"] = kernel
    for key in ("RestoreKernelCache", "RestoreRamDisk", "RestoreTrustCache",
                "Ap,RestoreTrustedExecutionMonitor"):
        c = man.get(key)
        if c and c.get("Info", {}).get("Path") and "Digest" in c:
            c["Digest"] = sha(c["Info"]["Path"], key)
            print(f"  {key}: {c['Info']['Path']}")
plistlib.dump(m, open(path, "wb"), fmt=plistlib.FMT_XML)
PY
    ;;
full)
    for f in "${SAVED[@]}"; do
        [ -e "$f.full-restore" ] || { echo "no $f.full-restore: tree is already in full mode?" >&2; exit 1; }
    done
    for f in "${SAVED[@]}"; do mv "$f.full-restore" "$f"; done
    ;;
*)
    echo "mode must be ssh or full" >&2; exit 1 ;;
esac
echo "=== $T is in $MODE mode"
