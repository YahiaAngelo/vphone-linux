# Licensing

vphone-linux is several projects with different licenses. This page summarizes them. It is not legal
advice; each project's own license files are authoritative.

| Part | Where | License |
|---|---|---|
| Glue: `run-vphone.sh`, `build.sh`, `tools/`, `docs/`, `patches/`, `linux-create/`, and `kvm/` except the kernel files below | this repository | **MIT** ([`LICENSE`](../LICENSE)) |
| QEMU fork | `qemu/` submodule: [qemu-vphone](https://github.com/YahiaAngelo/qemu-vphone), a fork of [ChefKissInc/QEMUAppleSilicon](https://github.com/ChefKissInc/QEMUAppleSilicon) | **GPL-3.0** overall. The upstream project's own code: **AGPL-3.0**. QEMU's code keeps its original licenses, mostly GPL-2.0-or-later. The files vphone-linux added (`hw/vmapple/vresearch101.c`, `vpiop.c`, `sep-storage.c`, ...) carry `SPDX-License-Identifier: GPL-2.0-or-later` headers. See `qemu/LICENSE` and `qemu/COPYING*`. |
| KVM backend in the QEMU fork | `qemu/target/arm/apple-virt.c`, `qemu/hw/arm/apple-silicon/virt_patches.c` (from ChefKiss Inferno's KVM backend, with vphone changes); `qemu/accel/accel-private.c` | `apple-virt.c` and `virt_patches.c`: **AGPL-3.0-or-later** (their headers). `accel-private.c`: **GPL-2.0-or-later**, QEMU's terms (its header) |
| Linux kernel patch | `kvm/linux-aurora-kvm/0001-kvm-arm64-userspace-exits-for-apple-guests.patch`, and the kernel code `kvm/apply-kernel-edits.py` inserts | **GPL-2.0**, Linux's license, as a change to Linux |
| Kernel package files | `kvm/linux-aurora-kvm/` (`PKGBUILD`, `config`, `configure.sh`, `bindgen-kernel.py`, `validate-config.py`, `rust-toolchain.toml`) | Adapted from Omarchy-M's `linux-aurora` package, which builds on asahi-alarm's `linux-asahi` (see `PKGBUILD`); they keep those packages' terms. `config` is a Linux kernel configuration |
| KVM test and measurement tools | `kvm/` (everything else: `kvm-exits-test.c`, `hvc-stress*`, `fetchtest/`, the scripts) | **MIT**, like the glue. They use Linux's UAPI headers, which carry the syscall exception (`Linux-syscall-note`) |
| reims-vgpu fork | `reims-vgpu/` submodule ([YahiaAngelo/reims-vgpu](https://github.com/YahiaAngelo/reims-vgpu)) | **GPL-2.0-or-later OR LGPL-3.0-or-later** (`reims-vgpu/LICENSE`, `LICENSES/`) |
| metal2vulkan fork | `metal2vulkan/` submodule ([YahiaAngelo/metal2vulkan](https://github.com/YahiaAngelo/metal2vulkan)) | **GPL-2.0-or-later OR LGPL-3.0-or-later** (`metal2vulkan/LICENSE`) |
| vphone-cli | not included: used on the Mac, or linked from a checkout by `linux-create/sync-sources.sh` | MIT |
| `linux-create/` | this repository (Linux build files, shims, overlays and edits for vphone-cli) | **MIT**; its overlays are modified vphone-cli files, also MIT |
| OpenAVB, OpenSEP | not included: unzipped from vphone-cli's release by the user | See each one's `LICENSE` (OpenAVB includes APSL-2.0 parts) |

## Notes

- **The kernel is built and distributed separately.** `linux-aurora-kvm` is an ordinary GPL-2.0
  Linux kernel package. QEMU talks to it only through KVM's ioctls and the `kvm_run` area, the
  userspace interface that the syscall exception covers. The kernel's license therefore does not
  extend to QEMU, and QEMU's does not extend to the kernel. Anyone who distributes a built package
  (for example as a release asset) must also offer its source: the pinned `linux-aurora` commit plus
  this patch.
- **The QEMU binary combines all three.** QEMU links `libreims_vgpu.a` (which contains metal2vulkan)
  statically. reims-vgpu and metal2vulkan may be used under GPL-2.0-or-later, and therefore under
  GPLv3, so they can be combined with qemu-vphone's GPL-3.0/AGPL-3.0 code. vphone-linux distributes
  source only; anyone distributing binaries takes on the GPL-3.0/AGPL-3.0 source obligations of the
  combination.
- **Branding.** Per the upstream project's branding notice (`ui/icons/CKBrandingNotice.md` in
  ChefKissInc/QEMUAppleSilicon), qemu-vphone removed the upstream project's name and boot-splash
  artwork (commit "qemu-vphone: remove the upstream project's name and artwork"). qemu-vphone is not
  endorsed by the upstream project.
- **No Apple code is included.** Some QEMU device models and comments describe register layouts and
  protocols learned by observing Apple's firmware and Virtualization.framework, for interoperability:
  the vpiop mailbox, VSTR SEP storage, and the USB touchscreen's HID report descriptor. The
  repositories contain no Apple binaries, firmware, or code.
- **Nothing Apple is committed, either.** iOS/IPSW firmware, cloudOS images, the OpenAVB/OpenSEP ROMs,
  the paravirt GPU driver bundle and `guest-resources` are downloaded from Apple's CDN or unzipped from
  a vphone-cli release **at run time, into the user's own machine only**, and stay out of every
  repository: `setup.sh` stages them under `~/vphone-setup-work/` / `~/.cache/vphone/`, and the CI's
  `no-apple-content` job fails any commit that tracks them (or any blob over 16 MiB). If you fork this
  project, do not re-host Apple's firmware or vphone-cli's release assets: link to them and let the
  user fetch from the source, the way this setup does.

## Why MIT for the glue

- The glue is separate programs that start QEMU as a process and talk to it over QMP or vsock. They do
  not link to GPL code, so a permissive license is possible.
- `patches/vphone-cli-cfw-freespace.patch` modifies vphone-cli, which is MIT. Keeping the same
  license makes upstreaming it simple.
- MIT matches vphone-cli, the project users already know.
