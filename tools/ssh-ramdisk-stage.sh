#!/bin/bash
# Make the SSH ramdisk's staging tree (runs/sshramdisk/ssh-root) from SSHRD_Script's tools.
#
#   tools/ssh-ramdisk-stage.sh [out-dir]       (default: runs/sshramdisk/ssh-root)
#   tools/ssh-ramdisk-stage.sh --bootstrap-only [out-dir]  (update an existing tree)
#
# Downloads ssh.tar.gz (dropbear, bash, coreutils, sftp-server, ... for iOS) from
# github.com/verygenericname/sshtars at a pinned commit and checks its SHA-256. This repository does
# not redistribute those binaries. Then:
#   - removes usr/share/misc/magic.mgc and usr/trollstore/ (not needed). It keeps
#     usr/lib/libresolv.9.dylib: sftp-server needs it, and the stock restore ramdisk has none.
# By default the downloaded tools keep their original bootstrap and signatures.
# VPHONE_SSHRD_BOOTSTRAP selects a prebuilt ECID-aware bootstrap. Its arm64 iOS
# signature, code pages, identifier and entitlements are checked before installation.
# VPHONE_SSHRD_BOOTSTRAP_BUILD=1 instead cross-builds it from source, requiring
# clang, xtool's Darwin SDK bundle (DARWIN_SDK_BUNDLE), and rcodesign (RCODESIGN).
# The tools run because
# tools/ssh-ramdisk-trustcache.py adds their code hashes to the ramdisk's trust cache and
# `fw patch --restore-txm-precheck` lets TXM admit them (tools/restore-tree-mode.sh does both).
# This reproduces the staging tree the tested SSH ramdisk was built from, without its optional PRNG
# seeder (usr/libexec/prng_seedctl, which exited without effect there). No root needed.
set -euo pipefail
cd "$(dirname "$0")/.."
BOOTSTRAP_ONLY=0
if [ "${1:-}" = --bootstrap-only ]; then BOOTSTRAP_ONLY=1; shift; fi
OUT=${1:-runs/sshramdisk/ssh-root}
URL=https://github.com/verygenericname/sshtars/raw/9f9551a14a268148d920370635e9c1bce33bf49c/ssh.tar.gz
SHA256=ddfa230acd2789c7e61ddb0d2ec3df9a6c741f2ddcab58fc1a826d278be1d74d
CACHE=runs/sshramdisk/ssh.tar.gz
BOOTSTRAP_MODE=$(tools/sshramdisk-bootstrap/build.sh --mode)

if [ "$BOOTSTRAP_ONLY" = 1 ]; then
  [ -f "$OUT/usr/local/bin/dropbear" ] || { echo "$OUT: missing staged Dropbear" >&2; exit 1; }
  [ "$BOOTSTRAP_MODE" != stock ] || exit 0
else
  [ ! -e "$OUT" ] || { echo "$OUT exists; use --bootstrap-only to update its bootstrap" >&2; exit 1; }
fi
mkdir -p "$(dirname "$OUT")"
WORK=$(mktemp -d "$(dirname "$OUT")/.sshrd-stage.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
if [ "$BOOTSTRAP_MODE" = prebuilt ]; then
  cp -- "$VPHONE_SSHRD_BOOTSTRAP" "$WORK/bootstrap"
elif [ "$BOOTSTRAP_MODE" = source ]; then
  tools/sshramdisk-bootstrap/build.sh "$WORK/bootstrap"
fi
if [ "$BOOTSTRAP_MODE" != stock ]; then
  python3 tools/sshramdisk-bootstrap/check.py "$WORK/bootstrap"
fi
if [ "$BOOTSTRAP_ONLY" = 1 ]; then
  chmod 755 "$WORK/bootstrap"
  mv "$WORK/bootstrap" "$OUT/usr/local/bin/restored_external"
  exit 0
fi
mkdir -p "$(dirname "$CACHE")"
if [ ! -f "$CACHE" ]; then
  echo "=== downloading ssh.tar.gz (SSHRD_Script's sshtars)"
  curl -sSfL -o "$CACHE.part" "$URL"
  mv "$CACHE.part" "$CACHE"
fi
sha256sum "$CACHE" | grep -q "^$SHA256" || { echo "$CACHE: unexpected SHA-256" >&2; exit 1; }

echo "=== unpacking into $OUT"
mkdir "$WORK/tree"
tar -xzf "$CACHE" -C "$WORK/tree"
rm -f "$WORK/tree/usr/share/misc/magic.mgc"
rm -rf "$WORK/tree/usr/trollstore"
if [ "$BOOTSTRAP_MODE" != stock ]; then
  install -m 755 "$WORK/bootstrap" "$WORK/tree/usr/local/bin/restored_external"
fi
mv "$WORK/tree" "$OUT"

echo "=== $OUT: $(find "$OUT" -type f | wc -l) files"
