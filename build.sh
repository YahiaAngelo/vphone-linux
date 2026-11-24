#!/bin/bash
# Build everything: reims-vgpu (with metal2vulkan), then QEMU linked against it.
# Run it again after pulling changes; it only rebuilds what changed.
set -euo pipefail
cd "$(dirname "$0")"
# Use the system clang/lld, not the copies in a swiftly Swift toolchain on PATH.
PATH=$(printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '/swiftly/bin$' -e '/swiftly/toolchains/' | paste -sd:)

git submodule update --init qemu reims-vgpu metal2vulkan   # not --recursive
git -C qemu submodule update --init util/mlib

VPHONE_DEBUG_BUILD=${VPHONE_DEBUG_BUILD:-0}

qemu_release_args() {
  [ "$VPHONE_DEBUG_BUILD" = 0 ] || return 0
  local cc=${CC:-cc}
  local cflags="-O3 -march=native -DNDEBUG -DG_DISABLE_ASSERT"
  local flag
  for flag in -fno-zero-call-used-regs -fzero-call-used-regs=skip; do
    if printf 'int x;\n' | "$cc" -x c "$flag" -c - -o /dev/null 2>/dev/null; then
      cflags+=" $flag"
      break
    fi
  done
  if printf 'int x;\n' | "$cc" -x c -ftrivial-auto-var-init=uninitialized -c - -o /dev/null 2>/dev/null; then
    cflags+=" -ftrivial-auto-var-init=uninitialized"
  fi
  local opts=(--disable-debug-info --enable-lto --disable-stack-protector)
  if [ "$(uname -m)" = x86_64 ] && [ -r /proc/cpuinfo ]; then
    local cpu_flags
    cpu_flags=$(grep -m1 '^flags' /proc/cpuinfo || true)
    if [[ " $cpu_flags " == *" avx512f "* ]] &&
       [[ " $cpu_flags " == *" avx512bw "* ]] &&
       [[ " $cpu_flags " == *" avx512cd "* ]] &&
       [[ " $cpu_flags " == *" avx512dq "* ]] &&
       [[ " $cpu_flags " == *" avx512vl "* ]]; then
      opts+=(--x86-version=4)
    fi
  fi
  opts+=("--extra-cflags=$cflags")
  printf '%s\0' "${opts[@]}"
}

echo "== reims-vgpu (the first build takes a while)"
if [ "$VPHONE_DEBUG_BUILD" = 0 ] && [[ " ${RUSTFLAGS:-} " != *"target-cpu="* ]]; then
  RUSTFLAGS="${RUSTFLAGS:+${RUSTFLAGS} }-C target-cpu=native" make -C reims-vgpu
else
  make -C reims-vgpu
fi

echo "== QEMU"
if [ ! -f qemu/build/build.ninja ]; then
  mkdir -p qemu/build
  qemu_extra=()
  while IFS= read -r -d '' opt; do
    qemu_extra+=("$opt")
  done < <(qemu_release_args)
  (cd qemu/build &&
    PKG_CONFIG_PATH="$PWD/../../reims-vgpu/target/dist-vulkan/lib/pkgconfig" ../configure \
      --target-list=aarch64-softmmu --enable-pvg --enable-lzfse --enable-slirp \
      --enable-libssh --enable-zstd --enable-nettle --enable-gnutls --enable-gtk --enable-sdl \
      --disable-werror --disable-qom-cast-debug "${qemu_extra[@]}")
fi
# QEMU links reims-vgpu statically and ninja may miss a new archive: always relink.
rm -f qemu/build/qemu-system-aarch64
ninja -C qemu/build qemu-system-aarch64

echo "== done: qemu/build/qemu-system-aarch64"
echo "   (vphone-cli's firmware tools for creating a VM: linux-create/build.sh)"
