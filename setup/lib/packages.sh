# The Arch Linux packages setup.sh installs (Arch, Omarchy, EndeavourOS, CachyOS, Manjaro...).
# Kept apart from setup.sh so CI can check every name still resolves: an Arch container runs
# `pacman -Sp` on ARCH_PKGS (.github/workflows/validate.yml), so a renamed or dropped package
# fails there before it fails on a user's PC.
#  - lzfse is AUR-only: setup.sh builds it (without LTO, arch_install_lzfse).
#  - libxml2-legacy gives the Swift toolchain its libxml2.so.2; base-devel is for makepkg.
#  - flex, bison, dtc, libdecor, libdrm and the X11 extension libraries are reims-vgpu's
#    (reims-vgpu/scripts/install-ctl.sh); its SDL3 window needs the X11/Wayland ones.
#  - The running kernel's headers are added by setup.sh (arch_kernel_headers).
# shellcheck shell=bash disable=SC2034
ARCH_PKGS=(git base-devel gcc clang lld binutils make cmake
  ninja meson pkgconf python python-pillow python-setuptools rsync
  glib2 pixman libslirp libssh zstd nettle gnutls gtk3 sdl2-compat bzip2 zlib
  libx11 libxss libxkbcommon wayland vulkan-icd-loader vulkan-headers vulkan-tools
  libxext libxrandr libxcursor libxi libxfixes libxtst libdecor libdrm flex bison dtc
  socat gdb perf usbip sshfs fuse3 7zip zip unzip curl gnupg
  libusb libplist libimobiledevice-glue libimobiledevice libusbmuxd libtatsu
  libarchive openssl libxml2-legacy libedit sqlite)
