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
pkg_feeds() {
  local distro; distro=${1%%:*}
  log " Installing splash-screen packages for $distro"
  case $distro in
    fedora)
      sudo dnf install -y git gcc gcc-c++ clang lld binutils make cmake ninja-build meson \
        python3 python3-pillow glib2-devel pixman-devel lzfse-devel libslirp-devel \
        libssh-devel libzstd-devel nettle-devel gnutls-devel gtk3-devel \
        sdl2-compat-devel bzip2-devel libX11-devel wayland-devel libxkbcommon-devel \
        vulkan-loader vulkan-loader-devel vulkan-tools \
        socat gdb perf \
        usbip fuse-sshfs fuse3 7zip kernel-devel \
        libusb1-devel libplist-devel libimobiledevice-glue-devel openssl-devel libcurl-devel \
        libimobiledevice-devel libusbmuxd-devel libtatsu-devel libarchive-devel ;;
    ubuntu|debian|linuxmint)
      sudo apt-get update
      sudo apt-get install -y git gcc g++ clang lld binutils make cmake ninja-build meson \
        python3 python3-pil python3-setuptools pkg-config \
        libglib2.0-dev libpixman-1-dev liblzfse-dev libslirp-dev libssh-dev \
        libzstd-dev nettle-dev libgnutls28-dev libgtk-3-dev libsdl2-dev \
        libbz2-dev libx11-dev libxkbcommon-dev libwayland-dev wayland-protocols \
        libvulkan-dev mesa-vulkan-drivers vulkan-tools \
        socat gdb linux-tools-generic hwdata \
        sshfs fuse3 p7zip-full unzip curl zstd bc flex bison libelf-dev \
        binutils-gold zip gnupg2 libpython3-dev libxml2-dev libncurses-dev libz3-dev \
        libusb-1.0-0-dev libplist-dev libimobiledevice-glue-dev libssl-dev libcurl4-openssl-dev \
        libimobiledevice-dev libusbmuxd-dev libtatsu-dev libarchive-dev
      # Ubuntu ships usbip in linux-tools-<ver>; /usr/bin/usbip only runs it for the
      # running kernel, which is never installed on WSL or a custom kernel.
      usbip version >/dev/null 2>&1 || {
        local u; u=$(ls -d /usr/lib/linux-tools/*/usbip 2>/dev/null | sort -V | tail -1)
        [ -n "$u" ] && sudo ln -sf "$u" /usr/local/bin/usbip
      }
      # WSL: tools/wsl-kernel-tree.sh builds Microsoft's kernel source instead of headers
      if is_wsl; then sudo apt-get install -y gcc-13 cpio dwarves; else sudo apt-get install -y linux-headers-generic; fi ;;
    arch|cachyos|manjaro)
      sudo pacman -S --needed --noconfirm git gcc clang lld binutils make cmake ninja meson \
        python python-pillow glib2 pixman lzfse libslirp libssh zstd nettle gnutls gtk3 \
        sdl2 bzip2 libx11 libxkbcommon wayland vulkan-icd-loader vulkan-tools \
        socat gdb perf usbip sshfs fuse3 p7zip linux-headers \
        libusb libplist openssl curl libimobiledevice libusbmuxd libtatsu libarchive ;;
    *) die "unsupported distro: $1 — install the packages from docs/SETUP.md §2/§5.1 manually." ;;
  esac
}

do_phase deps && {
  if [ "$(id -u)" = 0 ]; then
    pkg_feeds "$(detect_distro)"
  else
    confirm "Install the system packages with sudo? (chooser: $(detect_distro))" &&
      pkg_feeds "$(detect_distro)"
  fi

  # rustup (reims-vgpu) — its own pins come from rust-toolchain.toml
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
  # swiftly (Swift for the vphone-cli Linux build)
  if ! have swift; then
    log " Installing swiftly + Swift 6.4.1"
    # The tarball is per architecture (swiftly.tar.gz is a 404); unpacked in a scratch dir
    sw_tmp=$(mktemp -d)
    curl -fL --retry 3 -o "$sw_tmp/swiftly.tar.gz" \
      "https://download.swift.org/swiftly/linux/swiftly-$(uname -m).tar.gz"
    tar -C "$sw_tmp" -zxf "$sw_tmp/swiftly.tar.gz"
    "$sw_tmp/swiftly" init --quiet-shell-followup --assume-yes --skip-install
    rm -rf "$sw_tmp"
    # shellcheck disable=SC1091  # swiftly's env file, outside this checkout
    if [ -r "$HOME/.local/share/swiftly/env.sh" ]; then
      . "$HOME/.local/share/swiftly/env.sh"
    else
      # shellcheck disable=SC1091
      . "$HOME/.swiftly/env.sh"
    fi
    hash -r
    ( cd "$HOME" && swiftly install --use --assume-yes 6.4.1 )   # not here: it writes .swift-version to $PWD
    hash -r
  fi
  # sysctl for reims-vgpu's guest-memory mappings
  if [ "$(cat /proc/sys/vm/max_map_count)" -lt 1048576 ]; then
    warn "vm.max_map_count is $(cat /proc/sys/vm/max_map_count); add"
    warn "  'vm.max_map_count = 1048576' to /etc/sysctl.d/vphone.conf  (sudo)"
  fi
  # vhost-vsock is the default control channel
  if ! [ -e /dev/vhost-vsock ] && [ "$(id -u)" = 0 ]; then
    modprobe vhost_vsock || true
  fi
  [ -e /dev/vhost-vsock ] || warn "/dev/vhost-vsock missing: boot with VSOCK=uds, or load vhost_vsock"
  # docs/SETUP.md's vhost-vsock access, applied on WSL: without the udev rule a one-off chmod
  # is lost at the next udev event on the device and QEMU fails with "Permission denied".
  if is_wsl && [ ! -e /etc/udev/rules.d/90-vhost-vsock.rules ]; then
    echo vhost_vsock | sudo tee /etc/modules-load.d/vhost-vsock.conf >/dev/null
    echo 'KERNEL=="vhost-vsock", MODE="0666"' | sudo tee /etc/udev/rules.d/90-vhost-vsock.rules >/dev/null
    sudo udevadm control --reload && sudo udevadm trigger --sysname-match=vhost-vsock --action=change ||
      warn "could not apply the vhost-vsock udev rule"
  fi
  # WSL: no logind seat, so libirecovery's uaccess rule never opens the guest's DFU/recovery/
  # restore USB device to the user and recovery-probe times out. Open Apple's 05ac:12xx instead.
  if is_wsl && [ ! -e /etc/udev/rules.d/70-vphone-apple-usb.rules ]; then
    sudo install -m 644 "$VSETUP_ROOT/data/70-vphone-apple-usb.rules" /etc/udev/rules.d/ &&
      sudo udevadm control --reload || warn "could not install the Apple USB udev rule"
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
  # ArchiveKit links Shims/libarchive/lib/libarchive.so: point it at this distro's libarchive
  # (Fedora: /usr/lib64, Debian/Ubuntu: /usr/lib/x86_64-linux-gnu).
  local la; la=$(pkg-config --variable=libdir libarchive)/libarchive.so.13
  [ -e "$la" ] || die "libarchive.so.13 not found (install libarchive-dev / libarchive-devel)"
  mkdir -p "$VSETUP_SRC/linux-create/Shims/libarchive/lib"
  ln -sfn "$la" "$VSETUP_SRC/linux-create/Shims/libarchive/lib/libarchive.so"
  ( cd "$VSETUP_SRC/linux-create"
    VPHONE_CLI="$src" ./sync-sources.sh
    swift build --build-system swiftbuild --scratch-path .build/out )
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

do_phase build && for step in reims qemu creator usbmuxd apfs; do
  "build_$step"
done

# ------------------------------------------------------------- 4. release ---
do_phase release && {
  rel="$VSETUP_RELEASE/app"
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

# ---- GPU driver: needs a temporary stock cloudOS restore; interactive. ----
if [ "$VSETUP_PHASE" = all ] || [ "$VSETUP_PHASE" = release ]; then
  [ -d "$VSETUP_RELEASE/AppleParavirtGPUMetalIOGPUFamily.bundle" ] || {
    log "The paravirt GPU driver bundle is not extracted yet."
    log "Run tools/gpu-driver-from-cloudos.sh (restores a stock cloudOS into a scratch"
    log "bundle once, then extracts it). Headless and safe; ~1 h. Or skip it: a VM works"
    log "headless without it, but no graphics. Run:  sudo $VSETUP_SRC/tools/gpu-driver-from-cloudos.sh"
  }
fi

log "Setup complete: binaries under $VSETUP_SRC, ROMs under $VSETUP_RELEASE."
log "Next: ./create-vm.sh to pick the device and the iOS version and build the VM."
