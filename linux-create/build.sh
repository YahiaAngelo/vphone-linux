#!/usr/bin/env bash
# Build vphone-cli's firmware tooling for Linux in one step: fetch the pinned
# vphone-cli tag, sync its sources, install Swift if needed, and build.
#
#   linux-create/build.sh            # -> linux-create/vphone-cli (wrapper) works
#
# Needs no swiftly env/PATH setup: the pinned toolchain (.swift-version) is
# installed with swiftly if missing and called by its full path.
# VPHONE_CLI=DIR uses an existing vphone-cli checkout instead.
set -Eeuo pipefail
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "$here/../setup/lib/common.sh"
# shellcheck disable=SC1091
source "$here/../setup/lib/swift.sh"

[ "$(id -u)" != 0 ] || die "run this as your user, not root (the build tree would become root-owned)"

src=${VPHONE_CLI:-$here/../cpu-tree/vphone-cli-$VPHONE_CLI_PUBLIC}
if [ ! -d "$src/.git" ] && [ -z "${VPHONE_CLI:-}" ]; then
  log "Cloning vphone-cli $VPHONE_CLI_PUBLIC into $src"
  mkdir -p "$(dirname "$src")"
  git clone --depth 1 --branch "$VPHONE_CLI_PUBLIC" "$VPHONE_CLI_REPO" "$src"
fi
[ -d "$src" ] || die "no vphone-cli checkout at $src"

ensure_swift
swift_check_libs
# Arch's makepkg builds the AUR lzfse with LTO by default: its liblzfse.a then has no machine
# code the Swift linker can use (undefined symbol: lzfse_encode_buffer).
if [ -e /usr/lib/liblzfse.a ] && objdump -h /usr/lib/liblzfse.a 2>/dev/null | grep '\.gnu\.lto_' >/dev/null; then
  die "/usr/lib/liblzfse.a was built with LTO, which Swift cannot link.
      Rebuild it: ./setup/setup.sh deps   (or see docs/SETUP.md, the Arch section)"
fi

cd "$here"
VPHONE_CLI=$src ./sync-sources.sh
log "Building with Swift $VPHONE_SWIFT_VERSION ($(swift_bin))"
# On Arch, link with the toolchain's lld: Swift's default on Linux is gold, which Arch's
# binutils crashes in (internal error in format_file_lineno) instead of reporting a link
# error. -z nostart-stop-gc: with the build's --gc-sections, lld otherwise drops the Swift
# metadata sections the runtime finds only through __start_/__stop_ symbols, and vphone-cli
# segfaults at startup (swift_getWitnessTable). Other distros keep the tested default;
# VPHONE_SWIFT_LLD=1 or 0 overrides.
ld_flags=()
lld=${VPHONE_SWIFT_LLD:-$([ "$(distro_family)" = arch ] && echo 1 || echo 0)}
[ "$lld" = 1 ] && ld_flags=(-Xswiftc -use-ld=lld -Xlinker -z -Xlinker nostart-stop-gc)
swift build --build-system swiftbuild --scratch-path .build/out "${ld_flags[@]}" "$@"
log "Built: $here/.build/out/out/Products/Debug-linux-$(uname -m)/vphone-cli  (or run linux-create/vphone-cli)"
