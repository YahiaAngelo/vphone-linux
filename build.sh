#!/bin/bash
# Build everything: reims-vgpu (with metal2vulkan), then QEMU linked against it.
# Run it again after pulling changes; it only rebuilds what changed.
set -euo pipefail
cd "$(dirname "$0")"
# Use the system clang/lld, not the copies in a swiftly Swift toolchain on PATH.
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '/swiftly/bin$' -e '/swiftly/toolchains/' | paste -sd:)

git submodule update --init qemu reims-vgpu metal2vulkan   # not --recursive
git -C qemu submodule update --init util/mlib

VPHONE_NATIVE_OPT=${VPHONE_NATIVE_OPT:-0}
VPHONE_LTO=${VPHONE_LTO:-0}
VPHONE_NDEBUG=${VPHONE_NDEBUG:-0}

qemu_flags_stamp() {
  local native=0 lto=0 ndebug=0
  if [ "$VPHONE_NATIVE_OPT" = 1 ]; then native=1; fi
  if [ "$VPHONE_LTO" = 1 ]; then lto=1; fi
  if [ "$VPHONE_NDEBUG" = 1 ]; then ndebug=1; fi
  printf 'native=%s lto=%s ndebug=%s\n' "$native" "$lto" "$ndebug"
}

qemu_opt_args() {
  local opts=()
  local cflags=""
  if [ "$VPHONE_LTO" = 1 ]; then
    opts+=(--enable-lto)
  fi
  if [ "$VPHONE_NATIVE_OPT" = 1 ]; then
    cflags="${cflags:+${cflags} }-O3 -march=native"
  fi
  if [ "$VPHONE_NDEBUG" = 1 ]; then
    cflags="${cflags:+${cflags} }-DNDEBUG -DG_DISABLE_ASSERT"
  fi
  if [ -n "$cflags" ]; then
    opts+=("--extra-cflags=$cflags")
  fi
  if [ ${#opts[@]} -gt 0 ]; then
    printf '%s\0' "${opts[@]}"
  fi
}

echo "== reims-vgpu (the first build takes a while)"
if [ "$VPHONE_NATIVE_OPT" = 1 ] && [[ " ${RUSTFLAGS:-} " != *"target-cpu="* ]]; then
  RUSTFLAGS="${RUSTFLAGS:+${RUSTFLAGS} }-C target-cpu=native" make -C reims-vgpu
else
  make -C reims-vgpu
fi

echo "== QEMU"
want_stamp=$(qemu_flags_stamp)
have_stamp=""
if [ -f qemu/build/.vphone-build-flags ]; then
  have_stamp=$(cat qemu/build/.vphone-build-flags)
fi
if [ ! -f qemu/build/build.ninja ] || [ "$have_stamp" != "$want_stamp" ]; then
  if [ -f qemu/build/build.ninja ]; then
    echo "   reconfiguring QEMU (build flags changed: ${have_stamp:-<none>} -> $want_stamp)"
  fi
  mkdir -p qemu/build
  qemu_extra=()
  while IFS= read -r -d '' opt; do
    qemu_extra+=("$opt")
  done < <(qemu_opt_args)
  rm -f qemu/build/.vphone-build-flags
  (cd qemu/build &&
    PKG_CONFIG_PATH="$PWD/../../reims-vgpu/target/dist-vulkan/lib/pkgconfig" ../configure \
      --target-list=aarch64-softmmu --enable-pvg --enable-lzfse --enable-slirp \
      --enable-libssh --enable-zstd --enable-nettle --enable-gnutls --enable-gtk --enable-sdl \
      --disable-werror --disable-qom-cast-debug "${qemu_extra[@]}")
  printf '%s\n' "$want_stamp" > qemu/build/.vphone-build-flags
fi
# QEMU links reims-vgpu statically and ninja may miss a new archive: always relink.
rm -f qemu/build/qemu-system-aarch64
ninja -C qemu/build qemu-system-aarch64

echo "== done: qemu/build/qemu-system-aarch64"
echo "   (vphone-cli's firmware tools for creating a VM: linux-create/build.sh)"
