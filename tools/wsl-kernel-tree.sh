#!/bin/bash
# WSL2 has no linux-headers package for its Microsoft kernel, and the kernel is built with
# CONFIG_MODVERSIONS: an out-of-tree module (linux-apfs-rw) loads only when its symbol CRCs
# match. This fetches microsoft/WSL2-Linux-Kernel at the running kernel's tag, configures it
# with the running config (/proc/config.gz) and builds it once, which leaves a tree with a
# Module.symvers that `make -C <tree> M=...` can build modules against. Prints the tree's path.
#
#   tools/wsl-kernel-tree.sh [DIR]      (default: .build/wsl-kernel-<release>)
#
# Re-runnable: a finished tree (it has Module.symvers) is reused. The first build takes
# 5-15 minutes and about 6 GB of disk.
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
REL=$(uname -r)                                  # 6.6.87.2-microsoft-standard-WSL2
VER=${REL%%-*}                                   # 6.6.87.2
DIR=${1:-$ROOT/.build/wsl-kernel-$REL}
TAG=${WSL_KERNEL_TAG:-linux-msft-wsl-$VER}
# GCC 15 defaults to C23, which a 6.6 kernel does not build with (bool/false keywords in the
# x86 realmode code). GCC 13 builds it; build modules against this tree with the same CC.
KCC=${WSL_KERNEL_CC:-gcc-13}
command -v "$KCC" >/dev/null || { echo "$KCC is needed (sudo apt install $KCC cpio dwarves)" >&2; exit 1; }
command -v pahole >/dev/null || { echo "pahole is needed for the kernel's BTF (sudo apt install dwarves)" >&2; exit 1; }

case $REL in *microsoft*|*WSL*) ;; *) echo "not a WSL kernel: $REL" >&2; exit 1 ;; esac

if [ -f "$DIR/Module.symvers" ] && [ "$(cat "$DIR/include/config/kernel.release" 2>/dev/null)" = "$REL" ]; then
  echo "$DIR"; exit 0
fi

if [ ! -f "$DIR/Makefile" ]; then
  echo "fetching microsoft/WSL2-Linux-Kernel $TAG" >&2
  mkdir -p "$(dirname "$DIR")"
  git clone --depth 1 --branch "$TAG" https://github.com/microsoft/WSL2-Linux-Kernel.git "$DIR" >&2
fi

zcat /proc/config.gz > "$DIR/.config"
# Keep the config exactly as the running kernel's: options such as DEBUG_INFO_BTF_MODULES
# change struct module and with it module_layout's CRC, and the kernel then refuses the module.
# The release string must be exactly the running kernel's (vermagic): no "+" for a git tree.
touch "$DIR/.scmversion"
make -C "$DIR" CC="$KCC" HOSTCC="$KCC" olddefconfig LOCALVERSION= >&2
echo "building the WSL kernel once for Module.symvers ($(nproc) jobs)" >&2
# resolve_btfids' bundled libbpf trips -Werror on newer glibc headers (strchr returns const)
make -C "$DIR" CC="$KCC" HOSTCC="$KCC" HOSTCFLAGS="-Wno-error=discarded-qualifiers" \
  -j"$(nproc)" LOCALVERSION= vmlinux modules >&2
# The check that matters: module_layout's CRC must be the running kernel's (from any shipped module).
ref=$(find "/lib/modules/$REL/kernel" -name '*.ko*' -print -quit 2>/dev/null)
if [ -n "$ref" ]; then
  want=$(/sbin/modprobe --dump-modversions "$ref" 2>/dev/null | awk '$2=="module_layout"{print $1}')
  have=$(awk '$2=="module_layout"{print $1}' "$DIR/Module.symvers")
  [ -z "$want" ] || [ "$((want))" = "$((have))" ] || {
    echo "module_layout CRC $have != running kernel's $want: modules built here will not load" >&2; exit 1; }
fi
[ "$(cat "$DIR/include/config/kernel.release")" = "$REL" ] || {
  echo "built release $(cat "$DIR/include/config/kernel.release") != running $REL" >&2; exit 1; }
echo "$DIR"
