#!/usr/bin/env bash
# Build vphone-cli's firmware tooling for Linux in one step: fetch the pinned
# vphone-cli tag, sync its sources, install Swift if needed, and build.
#
#   linux-create/build.sh            # -> Release product used by linux-create/vphone-cli
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

src=${VPHONE_CLI:-$here/../cpu-tree/vphone-cli-$VPHONE_CLI_VERSION}
ensure_vphone_cli_source "$src"

ensure_swift
swift_check_libs
# Arch's makepkg builds the AUR lzfse with LTO by default: its liblzfse.a then has no machine
# code the Swift linker can use (undefined symbol: lzfse_encode_buffer).
if [ -e /usr/lib/liblzfse.a ] && objdump -h /usr/lib/liblzfse.a 2>/dev/null | grep '\.gnu\.lto_' >/dev/null; then
  die "/usr/lib/liblzfse.a was built with LTO, which Swift cannot link.
      Rebuild it: ./setup/setup.sh deps   (or see docs/SETUP.md, the Arch section)"
fi

cd "$here"
# ArchiveKit links Shims/libarchive/lib/libarchive.so (Package.swift): point it at this distro's
# libarchive.so.13 (Fedora /usr/lib64, Debian/Ubuntu /usr/lib/x86_64-linux-gnu, Arch /usr/lib).
la=$(pkg-config --variable=libdir libarchive 2>/dev/null)/libarchive.so.13
[ -e "$la" ] || die "libarchive.so.13 not found (install libarchive-devel / libarchive-dev / libarchive)"
mkdir -p Shims/libarchive/lib
ln -sfn "$la" Shims/libarchive/lib/libarchive.so
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
build_args=("$@")
configuration=release
has_configuration=0
for ((i = 0; i < ${#build_args[@]}; i++)); do
  case ${build_args[i]} in
    --configuration|-c)
      ((i + 1 < ${#build_args[@]})) || die "missing value for ${build_args[i]}"
      configuration=${build_args[i + 1]}
      has_configuration=1
      i=$((i + 1))
      ;;
    --configuration=*|-c=*)
      configuration=${build_args[i]#*=}
      has_configuration=1
      ;;
  esac
done
case $configuration in
  debug) configuration_name=Debug ;;
  release) configuration_name=Release ;;
  *) die "configuration must be debug or release: $configuration" ;;
esac
if [ "$has_configuration" = 0 ]; then
  build_args+=(--configuration release)
fi
swift build --build-system swiftbuild --scratch-path .build/out "${ld_flags[@]}" "${build_args[@]}"
log "Built: $here/.build/out/out/Products/$configuration_name-linux-$(uname -m)/vphone-cli  (or run linux-create/vphone-cli)"
