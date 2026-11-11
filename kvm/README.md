# KVM on an Apple Silicon Linux host: kernel side

See [docs/KVM.md](../docs/KVM.md) for what this is for and how the QEMU side works.

- `linux-aurora-kvm/`: Omarchy-M's `linux-aurora` 7.2.11 (same pinned commit) plus
  `0001-kvm-arm64-userspace-exits-for-apple-guests.patch`, which sends to userspace what GXF/PAC
  emulation needs: `KVM_CAP_ARM_HVC_TO_USER` (253), `KVM_CAP_ARM_IMPDEF_SYSREG_TO_USER` (254),
  `KVM_CAP_ARM_FAULT_TO_USER` (255), `KVM_CAP_ARM_TIMER_TO_USER` (256), `KVM_ARM_SET_WRITE_PROTECT`
  (all as in ChefKiss Inferno's KVM backend) and `KVM_CAP_ARM_GIC_SYSREG_TO_USER` (257, vphone's:
  the GICv3 CPU interface goes to QEMU's GIC models). It installs next to `linux-aurora` as its own
  Limine entry; `linux-aurora` stays the default.
- `kvm-exits-test.c`: runs a bare vCPU through each new exit.
- `apply-kernel-edits.py`: makes the patch from a linux-aurora tree (re-run it on a newer one).

## Build and install

    sudo pacman -S --needed bc dtc rustup clang llvm lld clang18 llvm18 lld18 xmlto
    cd linux-aurora-kvm && makepkg -s               # about an hour on an M1 Pro
    sudo pacman -U linux-aurora-kvm-7*.pkg.tar.xz    # the headers package is optional

After changing the patch, `makepkg -ef` rebuilds from the existing tree in minutes.

Reboot into the linux-aurora-kvm entry, then check the new exits (the test needs the patched UAPI
headers: `make headers_install INSTALL_HDR_PATH=<dir>` in the patched kernel tree):

    cc -O2 -Wall -I <dir>/include -o kvm-exits-test kvm-exits-test.c && ./kvm-exits-test
