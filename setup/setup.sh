#!/usr/bin/env bash
# vphone-setup, step 1: turn a bare Linux machine into a working vphone-linux
# build (dependencies, sources, release bundle, all binaries).
#
#   ./setup.sh [<phase>] [-y] [--src DIR] [--workdir DIR]
#
# Phases: deps, sources, build, release, all (default). Re-runnable; each
# phase skips work that is already done.
#
#   ./setup.sh                       # everything, asking before sudo apt/dnf
#   ./setup.sh -y                    # everything, no prompts
#
# This script never runs a VM or QEMU; it only builds binaries.
set -Eeuo pipefail
# shellcheck disable=SC1091  # this checkout's own lib/common.sh, resolved at run time
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck disable=SC1091
source "$VSETUP_ROOT/lib/swift.sh"
# shellcheck disable=SC1091
source "$VSETUP_ROOT/lib/packages.sh"

VSETUP_ASSUME_YES=${VSETUP_ASSUME_YES:-0}
VSETUP_PHASE=all
while [ $# -gt 0 ]; do
  case $1 in
    -y|--yes)        VSETUP_ASSUME_YES=1 ;;
    --src)           VSETUP_SRC=$2; shift ;;
    --workdir)       mkdir -p "$2"; VSETUP_SRC=$2/src; VSETUP_RELEASE=$2/vphone-release; shift ;;
    deps|sources|build|release|all) VSETUP_PHASE=$1 ;;
    *) die "unknown option: $1" ;;
  esac; shift
done

do_phase() { [ "$VSETUP_PHASE" = "$1" ] || [ "$VSETUP_PHASE" = all ]; }

# ---------------------------------------------------------------- 1. deps ---
# The headers package for the running kernel (linux, linux-lts, linux-zen, a
# custom kernel's own -headers package...), for linux-apfs-rw.
arch_kernel_headers() {
  local base; base=/usr/lib/modules/$(uname -r)/pkgbase
  if [ -r "$base" ]; then echo "$(cat "$base")-headers"; else echo linux-headers; fi
}
# lzfse (QEMU's --enable-lzfse, and the Swift build) is only in the AUR, and it
# ships just a static liblzfse.a. Arch's makepkg.conf turns on LTO, which fills
# that archive with GCC's intermediate code instead of machine code: GCC links
# it, but the Swift toolchain's linker (lld/gold) cannot, so vphone-cli fails
# with undefined lzfse_encode_buffer. Build it here with LTO off (an AUR helper
# would use the LTO default), and rebuild an installed copy that has LTO in it.
lzfse_has_lto() { objdump -h /usr/lib/liblzfse.a 2>/dev/null | grep '\.gnu\.lto_' >/dev/null; }
arch_install_lzfse() {
  if pacman -Q lzfse >/dev/null 2>&1 && ! lzfse_has_lto; then return 0; fi
  if pacman -Q lzfse >/dev/null 2>&1; then
    log " Rebuilding lzfse without LTO (the installed liblzfse.a has GCC LTO code)"
  else
    log " Building lzfse from the AUR, without LTO"
  fi
  local d; d=$(mktemp -d)
  git clone --depth 1 https://aur.archlinux.org/lzfse.git "$d/lzfse"
  printf "\n# vphone-linux: plain machine code in liblzfse.a, for the Swift toolchain's linker\noptions+=('!lto')\n" \
    >> "$d/lzfse/PKGBUILD"
  ( cd "$d/lzfse" && makepkg -sif --noconfirm )
  rm -rf "$d"
  ! lzfse_has_lto || die "liblzfse.a still has LTO code; rebuild the lzfse package with options=('!lto')"
}

pkg_feeds() {
  local family; family=$(distro_family)
  log " Installing system packages for $family ($(detect_distro))"
  case $family in
    fedora)
      sudo dnf install -y "${FEDORA_PKGS[@]}" ;;
    debian)
      sudo apt-get update
      local extra=() missing=() p
      for p in "${DEBIAN_PKGS[@]}"; do [ -n "$(apt-cache madison "$p" 2>/dev/null)" ] || missing+=("$p"); done
      [ ${#missing[@]} = 0 ] || die "this release has no ${missing[*]}: vphone-cli's restore code links
     libimobiledevice 1.4, libimobiledevice-glue and libtatsu. Use Debian 13+ or Ubuntu 25.04+."
      # Debian packages usbip; Ubuntu ships it in linux-tools (linked below).
      if [ -n "$(apt-cache madison usbip 2>/dev/null)" ]; then extra+=(usbip); else extra+=(linux-tools-generic); fi
      # WSL: tools/wsl-kernel-tree.sh builds Microsoft's kernel source instead of headers.
      if is_wsl; then extra+=(gcc-13 cpio dwarves); else extra+=(linux-headers-generic); fi
      sudo apt-get install -y "${DEBIAN_PKGS[@]}" "${extra[@]}"
      # Ubuntu's /usr/bin/usbip only runs linux-tools for the running kernel, which is never
      # installed on WSL or a custom kernel: link the newest one instead.
      usbip version >/dev/null 2>&1 || {
        local u; u=$(find /usr/lib/linux-tools -name usbip -path '*/usbip' 2>/dev/null | sort -V | tail -1)
        if [ -n "$u" ]; then sudo ln -sf "$u" /usr/local/bin/usbip; fi
      } ;;
    arch)
      # No -y here: syncing the database without upgrading is a partial upgrade, which Arch
      # does not support. A stale database fails the download instead (404 on a mirror):
      # the system is updated by its owner, not as a side effect of this script.
      sudo pacman -S --needed --noconfirm "${ARCH_PKGS[@]}" "$(arch_kernel_headers)" ||
        die "pacman could not install the packages. If it failed to retrieve files (404), the
     package database is out of date: update the system first ($(is_omarchy && echo 'omarchy update, or ')sudo pacman -Syu),
     reboot if the kernel was updated (linux-apfs-rw builds against the running kernel), then re-run."
      arch_install_lzfse ;;
    *) die "unsupported distro: $(detect_distro) — install the packages from docs/SETUP.md §2 manually." ;;
  esac
}

# Persistent host settings (docs/SETUP.md §2), each written only when missing: vhost_vsock
# loaded at boot and usable by the user, and vm.max_map_count high enough for reims-vgpu's
# guest-memory mappings (Arch already ships 1048576).
host_settings() {
  if [ "$(cat /proc/sys/vm/max_map_count)" -lt 1048576 ]; then
    log " Setting vm.max_map_count = 1048576 (/etc/sysctl.d/90-vphone.conf)"
    echo 'vm.max_map_count = 1048576' | sudo tee /etc/sysctl.d/90-vphone.conf >/dev/null
    sudo sysctl -q --system
  fi
  if ! grep -qsx vhost_vsock /etc/modules-load.d/*.conf; then
    log " Loading vhost_vsock at boot (/etc/modules-load.d/vhost-vsock.conf)"
    echo vhost_vsock | sudo tee /etc/modules-load.d/vhost-vsock.conf >/dev/null
  fi
  if [ ! -f /etc/udev/rules.d/90-vhost-vsock.rules ]; then
    echo 'KERNEL=="vhost-vsock", MODE="0666"' | sudo tee /etc/udev/rules.d/90-vhost-vsock.rules >/dev/null
  fi
  [ -e /dev/vhost-vsock ] || sudo modprobe vhost_vsock || true
  if [ -e /dev/vhost-vsock ] && ! [ -w /dev/vhost-vsock ]; then sudo chmod 666 /dev/vhost-vsock; fi
}

do_phase deps && {
  if is_omarchy; then log " Omarchy $(omarchy-version 2>/dev/null || true) detected (Arch packages, Hyprland window rule)"; fi
  if [ "$(id -u)" = 0 ]; then
    [ "$(distro_family)" != arch ] || die "run setup.sh as your user (it uses sudo itself); makepkg and swiftly refuse root"
    pkg_feeds
  else
    confirm "Install the system packages with sudo? ($(detect_distro))" && pkg_feeds
  fi

  # rustup (reims-vgpu) — its own pins come from rust-toolchain.toml
  # shellcheck disable=SC1091  # rustup's env file, outside this checkout
  if ! have cargo && [ -r "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; fi
  if ! have cargo; then
    log " Installing rustup"
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable
    # shellcheck disable=SC1091  # rustup's env file, outside this checkout
    . "$HOME/.cargo/env"
  fi
  if ! have rcodesign; then
    log " Installing rcodesign (apple-codesign)"
    cargo install apple-codesign --locked
  fi
  # Swift for the vphone-cli Linux build: the version in linux-create/.swift-version,
  # installed with swiftly and called by its full path (setup/lib/swift.sh). On Arch it
  # uses swiftly's ubi9 build plus ncurses links inside the toolchain.
  ensure_swift
  if confirm "Set the vhost_vsock and vm.max_map_count host settings with sudo (only those missing)?"; then
    host_settings
  fi
  [ "$(cat /proc/sys/vm/max_map_count)" -ge 1048576 ] ||
    warn "vm.max_map_count is $(cat /proc/sys/vm/max_map_count): set 1048576 (docs/SETUP.md §2)"
  [ -e /dev/vhost-vsock ] || warn "/dev/vhost-vsock missing: boot with VSOCK=uds, or load vhost_vsock"
  # docs/SETUP.md's vhost-vsock access, applied on WSL: without the udev rule a one-off chmod
  # is lost at the next udev event on the device and QEMU fails with "Permission denied".
  if is_wsl && [ ! -e /etc/udev/rules.d/90-vhost-vsock.rules ]; then
    echo vhost_vsock | sudo tee /etc/modules-load.d/vhost-vsock.conf >/dev/null
    echo 'KERNEL=="vhost-vsock", MODE="0666"' | sudo tee /etc/udev/rules.d/90-vhost-vsock.rules >/dev/null
  fi
  # /dev/vhost-vsock can exist before its module loads (a static node, root:kvm 0660): load the
  # module so udev creates the real node with the rule's mode.
  if is_wsl && ! grep -q '^vhost_vsock ' /proc/modules; then
    if ! { sudo udevadm control --reload && sudo modprobe vhost_vsock && sudo udevadm settle; }; then
      warn "could not load vhost_vsock"
    fi
  fi
  # WSL: no logind seat, so libirecovery's uaccess rule never opens the guest's DFU/recovery/
  # restore USB device to the user and recovery-probe times out. Open Apple's 05ac:12xx instead.
  if is_wsl && [ ! -e /etc/udev/rules.d/70-vphone-apple-usb.rules ]; then
    if ! { sudo install -m 644 "$VSETUP_ROOT/data/70-vphone-apple-usb.rules" /etc/udev/rules.d/ &&
           sudo udevadm control --reload; }; then
      warn "could not install the Apple USB udev rule"
    fi
  fi
}

# ------------------------------------------------------------- 2. sources ---
# The setup lives IN the checkout it builds (VSETUP_SRC defaults to it); a
# --src DIR still points the build at a second checkout.
do_phase sources && {
  if [ ! -d "$VSETUP_SRC/.git" ]; then
    log " Cloning vphone-linux ($VPHONE_LINUX_BRANCH) into $VSETUP_SRC"
    mkdir -p "$(dirname "$VSETUP_SRC")"
    git clone --branch "$VPHONE_LINUX_BRANCH" \
      https://github.com/YahiaAngelo/vphone-linux.git "$VSETUP_SRC"
  fi
  log " Fetching submodules (single level — NOT --recursive)"
  git -C "$VSETUP_SRC" submodule update --init
  git -C "$VSETUP_SRC/qemu" submodule update --init util/mlib
}

# --------------------------------------------------------------- 3. build ---
build_reims() {
  # Always: cargo rebuilds only what changed, and a submodule update must reach the library
  # (QEMU is relinked below when the library is newer than it).
  log " Building reims-vgpu (the first build is long: its static lib is ~800 MB)"
  make -C "$VSETUP_SRC/reims-vgpu"
}
build_qemu() {
  local pkgcfg="$VSETUP_SRC/reims-vgpu/target/dist-vulkan/lib/pkgconfig"
  if [ ! -x "$VSETUP_SRC/qemu/build/qemu-system-aarch64" ] ||
     [ "$VSETUP_SRC/reims-vgpu/target/dist-vulkan/lib/libreims_vgpu.a" -nt \
       "$VSETUP_SRC/qemu/build/qemu-system-aarch64" ]; then
    log " Building QEMU (-M vresearch101) against reims-vgpu"
    mkdir -p "$VSETUP_SRC/qemu/build"
    ( export PKG_CONFIG_PATH=$pkgcfg
      cd "$VSETUP_SRC/qemu/build"
      [ -f config.status ] || ../configure --target-list=aarch64-softmmu --enable-pvg \
        --enable-lzfse --enable-slirp --enable-libssh --enable-zstd --enable-nettle \
        --enable-gnutls --enable-gtk --enable-sdl --disable-werror --disable-qom-cast-debug
      ninja qemu-system-aarch64 )
  fi
}
build_creator() {
  log " Building vphone-cli's firmware tooling for Linux (vphone-cli $VPHONE_CLI_PUBLIC)"
  local src="$VSETUP_SRC/cpu-tree/vphone-cli-$VPHONE_CLI_PUBLIC"
  mkdir -p "$(dirname "$src")"
  if [ ! -d "$src/.git" ]; then
    git clone --depth 1 --branch "$VPHONE_CLI_PUBLIC" "$VPHONE_CLI_REPO" "$src"
  fi
  VPHONE_CLI="$src" "$VSETUP_SRC/linux-create/build.sh"
}
build_usbmuxd() { "$VSETUP_SRC/tools/build-usbmuxd-32k.sh"; }
# linux-apfs-rw with the iOS 27 volume features accepted (patches/linux-apfs-rw-ios27.patch):
# fw patch's seal patcher mounts the restore ramdisk with it, and the SSH ramdisk injector too.
# Built for the running kernel; rebuilt when the kernel changed.
APFS_RW_COMMIT=03187127cd2e62cf78321cdb942eb3a7b17981f9
build_apfs() {
  local dir="$VSETUP_SRC/.build/linux-apfs-rw"
  if [ ! -d "$dir/.git" ]; then
    log " Fetching linux-apfs-rw"
    git clone https://github.com/linux-apfs/linux-apfs-rw.git "$dir"
  fi
  if [ "$(git -C "$dir" rev-parse HEAD)" != "$APFS_RW_COMMIT" ] || git -C "$dir" diff --quiet; then
    git -C "$dir" checkout -q -f "$APFS_RW_COMMIT"
    git -C "$dir" apply "$VSETUP_SRC/patches/linux-apfs-rw-ios27.patch"
  fi
  if [ -f "$dir/apfs.ko" ] && [ "$(modinfo -F vermagic "$dir/apfs.ko" | cut -d' ' -f1)" != "$(uname -r)" ]; then
    make -C "$dir" clean
  fi
  log " Building linux-apfs-rw for kernel $(uname -r)"
  if is_wsl && [ ! -e "/lib/modules/$(uname -r)/build" ]; then
    # WSL: no headers package for Microsoft's kernel; build against its source tree
    make -C "$dir" CC="${WSL_KERNEL_CC:-gcc-13}" KERNEL_DIR="$("$VSETUP_SRC/tools/wsl-kernel-tree.sh")"
  else
    make -C "$dir"
  fi
}

# An lzfse built with Arch's default LTO cannot be linked by Swift: rebuild it first
# (needs sudo), so `./setup.sh build` alone is enough after pulling this fix.
if do_phase build && [ "$(distro_family)" = arch ] && lzfse_has_lto; then
  arch_install_lzfse
fi
do_phase build && for step in reims qemu creator usbmuxd apfs; do
  # The C/Rust builds use the system clang/lld, never the Swift toolchain's copies.
  PATH=$(path_without_swiftly) "build_$step"
done

# ------------------------------------------------------------- 4. release ---
do_phase release && {
  rel="$VSETUP_RELEASE/app"
  mkdir -p "$rel"
  log " Setting up the vphone-cli $VPHONE_CLI_PUBLIC release bundle (ROMs + guest resources)"
  zip="$VSETUP_RELEASE/VPhone-$VPHONE_CLI_PUBLIC.zip"
  if [ ! -d "$rel/VPhone.bundle/Contents/Resources/OpenAVB" ]; then
    [ -f "$zip" ] || curl -L --retry 3 -o "$zip" \
      "https://github.com/Lakr233/vphone-cli/releases/download/$VPHONE_CLI_PUBLIC/VPhone-$VPHONE_CLI_PUBLIC.zip"
    [ -d "$rel/VPhone.bundle" ] || unzip -q -n "$zip" -d "$rel"
    # The bundle can land at any nesting depth (2.12: app/VPhone.bundle;
    # 2.13's zip itself starts with an app/ folder: app/app/VPhone.bundle).
    # Find it wherever it is and normalize to $rel/VPhone.bundle.
    bundle=$(find "$rel" -type d -name VPhone.bundle -print -quit)
    if [ -n "$bundle" ] && [ "$bundle" != "$rel/VPhone.bundle" ]; then
      log " Normalizing bundle path: $bundle -> $rel/VPhone.bundle"
      rm -rf "$rel/VPhone.bundle" 2>/dev/null
      mv "$bundle" "$rel/VPhone.bundle"
    fi
  fi
  [ -d "$rel/VPhone.bundle/Contents/Resources/OpenAVB" ] ||
    die "VPhone.bundle not found, or missing ROMs in $rel — check the download and re-run './setup.sh release'"
  r="$rel/VPhone.bundle/Contents/Resources"
  ( cd "$VSETUP_SRC"
    ln -sfn "$r/guest-resources" guest-resources
    mkdir -p OpenAVB OpenSEP
    cp "$r/OpenAVB/OpenAVB.bin" OpenAVB/OpenAVB.bin 2>/dev/null || cp "$r/OpenAVB.bin" OpenAVB/OpenAVB.bin
    cp "$r/OpenSEP/OpenSEP.bin" OpenSEP/OpenSEP.bin 2>/dev/null || cp "$r/OpenSEP.bin" OpenSEP/OpenSEP.bin )
}

# The GPU driver needs a stock cloudOS restore (~20-30 min); create-vm.sh does it in its
# gpu-driver step, once, after downloading the cloudOS IPSW.
# Omarchy / Hyprland: float the iPhone window at its own shape instead of tiling it.
if do_phase deps && [ -f "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/hyprland.lua" ] &&
   [ ! -f "${XDG_CONFIG_HOME:-$HOME/.config}/hypr/vphone-linux.lua" ] &&
   confirm "Hyprland$(is_omarchy && echo ' (Omarchy)') found: add a window rule so the iPhone window floats phone-shaped?"; then
  echo y | "$VSETUP_SRC/tools/omarchy-window.sh" || warn "the window rule was not installed: run tools/omarchy-window.sh"
fi

log "Setup complete: binaries under $VSETUP_SRC, ROMs under $VSETUP_RELEASE."
log "Next: ./create-vm.sh to pick the device and the iOS version and build the VM."
