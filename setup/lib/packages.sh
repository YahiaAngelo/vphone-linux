# shellcheck shell=bash disable=SC2034
# The system packages setup.sh installs, one list per package family. Kept apart from setup.sh
# so CI can check every name still resolves (.github/workflows/validate.yml installs nothing:
# `dnf install --assumeno`, `apt-get install --simulate`, `pacman -Sp` in each distro's
# container). One unknown name makes dnf/apt install nothing at all, so a renamed or dropped
# package must fail there before it fails on a user's PC.

# Fedora (and RHEL-likes): the tested reference. The last line is what swiftly lists for the
# Swift toolchain on Fedora.
FEDORA_PKGS=(git gcc gcc-c++ clang lld binutils make cmake ninja-build meson
  python3 python3-pillow rsync glib2-devel pixman-devel lzfse-devel libslirp-devel
  libssh-devel libzstd-devel nettle-devel gnutls-devel gtk3-devel
  sdl2-compat-devel bzip2-devel libX11-devel libXScrnSaver-devel wayland-devel libxkbcommon-devel
  vulkan-loader vulkan-loader-devel vulkan-tools
  socat gdb perf unzip curl zstd
  usbip fuse-sshfs fuse3 7zip kernel-devel
  libusb1-devel libplist-devel libimobiledevice-glue-devel openssl-devel libcurl-devel
  libimobiledevice-devel libusbmuxd-devel libtatsu-devel libarchive-devel
  zip libedit-devel sqlite-devel libuuid-devel python3-devel libstdc++-static)

# Debian 13+, Ubuntu 25.04+, Mint... setup.sh adds usbip where the distro packages it (Debian), or
# linux-tools-generic where it ships it instead (Ubuntu), and linux-headers-generic (or WSL's
# kernel-build tools). Older releases (Ubuntu 24.04) have no libimobiledevice-glue or libtatsu
# and a libimobiledevice older than the 1.4 vphone-cli's restore code links: setup.sh stops there. binutils-gold, zip,
# gnupg2, libpython3-dev, libxml2-dev, libncurses-dev and libz3-dev are what swiftly lists for
# the Swift toolchain; bc, flex, bison and libelf-dev build linux-apfs-rw on WSL's kernel tree.
DEBIAN_PKGS=(git gcc g++ clang lld binutils make cmake ninja-build meson
  python3 python3-pil python3-setuptools pkg-config rsync unzip curl zstd
  libglib2.0-dev libpixman-1-dev liblzfse-dev libslirp-dev libssh-dev
  libzstd-dev nettle-dev libgnutls28-dev libgtk-3-dev libsdl2-dev
  libbz2-dev libx11-dev libxss-dev libxkbcommon-dev libwayland-dev wayland-protocols
  libvulkan-dev mesa-vulkan-drivers vulkan-tools
  socat gdb hwdata
  sshfs fuse3 7zip bc flex bison libelf-dev
  binutils-gold zip gnupg2 libpython3-dev libxml2-dev libncurses-dev libz3-dev libedit-dev libsqlite3-dev
  libusb-1.0-0-dev libplist-dev libimobiledevice-glue-dev libssl-dev libcurl4-openssl-dev
  libimobiledevice-dev libusbmuxd-dev libtatsu-dev libarchive-dev)

# Arch Linux and derivatives (Omarchy, EndeavourOS, CachyOS, Manjaro...):
#  - lzfse is AUR-only: setup.sh builds it (without LTO, arch_install_lzfse).
#  - libxml2-legacy gives the Swift toolchain its libxml2.so.2; base-devel is for makepkg.
#  - flex, bison, dtc, libdecor, libdrm and the X11 extension libraries are reims-vgpu's
#    (reims-vgpu/scripts/install-ctl.sh); its SDL3 window needs the X11/Wayland ones.
#  - The running kernel's headers are added by setup.sh (arch_kernel_headers).
ARCH_PKGS=(git base-devel gcc clang lld binutils make cmake
  ninja meson pkgconf python python-pillow python-setuptools rsync
  glib2 pixman libslirp libssh zstd nettle gnutls gtk3 sdl2-compat bzip2 zlib
  libx11 libxss libxkbcommon wayland vulkan-icd-loader vulkan-headers vulkan-tools
  libxext libxrandr libxcursor libxi libxfixes libxtst libdecor libdrm flex bison dtc
  socat gdb perf usbip sshfs fuse3 7zip zip unzip curl gnupg
  libusb libplist libimobiledevice-glue libimobiledevice libusbmuxd libtatsu
  libarchive openssl libxml2-legacy libedit sqlite)
