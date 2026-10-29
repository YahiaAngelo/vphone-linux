#!/bin/bash
# Build everything: reims-vgpu (with metal2vulkan), then QEMU linked against it.
# Run it again after pulling changes; it only rebuilds what changed.
set -euo pipefail
cd "$(dirname "$0")"
# Use the system clang/lld, not the copies in a swiftly Swift toolchain on PATH.
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '/swiftly/bin$' -e '/swiftly/toolchains/' | paste -sd:)

git submodule update --init qemu reims-vgpu metal2vulkan   # not --recursive
git -C qemu submodule update --init util/mlib

echo "== reims-vgpu (the first build takes a while)"
make -C reims-vgpu

echo "== QEMU"
if [ ! -f qemu/build/build.ninja ]; then
  mkdir -p qemu/build
  (cd qemu/build &&
    PKG_CONFIG_PATH="$PWD/../../reims-vgpu/target/dist-vulkan/lib/pkgconfig" ../configure \
      --target-list=aarch64-softmmu --enable-pvg --enable-lzfse --enable-slirp \
      --enable-libssh --enable-zstd --enable-nettle --enable-gnutls --enable-gtk --enable-sdl \
      --disable-werror --disable-qom-cast-debug)
fi
# QEMU links reims-vgpu statically and ninja may miss a new archive: always relink.
rm -f qemu/build/qemu-system-aarch64
ninja -C qemu/build qemu-system-aarch64

echo "== done: qemu/build/qemu-system-aarch64"
echo "   (vphone-cli's firmware tools for creating a VM: linux-create/build.sh)"
