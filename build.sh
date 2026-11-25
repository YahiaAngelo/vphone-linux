#!/bin/bash
# Build everything: reims-vgpu (with metal2vulkan), then QEMU linked against it.
# Run it again after pulling changes; it only rebuilds what changed.
set -euo pipefail
cd "$(dirname "$0")"
# shellcheck source=setup/lib/common.sh
source ./setup/lib/common.sh
# Use the system clang/lld, not the copies in a swiftly Swift toolchain on PATH.
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '/swiftly/bin$' -e '/swiftly/toolchains/' | paste -sd:)

git submodule update --init qemu reims-vgpu metal2vulkan   # not --recursive
git -C qemu submodule update --init util/mlib

echo "== reims-vgpu (the first build takes a while)"
if [ "$VPHONE_NATIVE_OPT" = 1 ] && [[ " ${RUSTFLAGS:-} " != *"target-cpu="* ]]; then
  RUSTFLAGS="${RUSTFLAGS:+${RUSTFLAGS} }-C target-cpu=native" make -C reims-vgpu
else
  make -C reims-vgpu
fi

echo "== QEMU"
reims_header="$PWD/reims-vgpu/target/dist-vulkan/include/reims_vgpu.h"
qemu_build="qemu/build"
want_stamp=$(qemu_flags_stamp "$reims_header")
have_stamp=""
if [ -f "$qemu_build/.vphone-build-flags" ]; then
  have_stamp=$(cat "$qemu_build/.vphone-build-flags")
fi
if [ ! -f "$qemu_build/build.ninja" ] || [ "$have_stamp" != "$want_stamp" ]; then
  if [ -d "$qemu_build" ]; then
    if [ "$have_stamp" != "$want_stamp" ] && { [ -f "$qemu_build/build.ninja" ] || [ -f "$qemu_build/config.status" ]; }; then
      echo "   removing $qemu_build for clean QEMU configure (build stamp changed: ${have_stamp:-<none>} -> $want_stamp)"
    fi
    rm -rf "$qemu_build"
  fi
  mkdir -p "$qemu_build"
  qemu_extra=()
  while IFS= read -r -d '' opt; do
    qemu_extra+=("$opt")
  done < <(qemu_opt_args)
  (cd "$qemu_build" &&
    PKG_CONFIG_PATH="$PWD/../../reims-vgpu/target/dist-vulkan/lib/pkgconfig" ../configure \
      --target-list=aarch64-softmmu --enable-pvg --enable-lzfse --enable-slirp \
      --enable-libssh --enable-zstd --enable-nettle --enable-gnutls --enable-gtk --enable-sdl \
      --disable-werror --disable-qom-cast-debug "${qemu_extra[@]}")
  printf '%s\n' "$want_stamp" > "$qemu_build/.vphone-build-flags"
fi
# QEMU links reims-vgpu statically and ninja may miss a new archive: always relink.
rm -f "$qemu_build/qemu-system-aarch64"
ninja -C "$qemu_build" qemu-system-aarch64

echo "== done: $qemu_build/qemu-system-aarch64"
echo "   (vphone-cli's firmware tools for creating a VM: linux-create/build.sh)"
