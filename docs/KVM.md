# KVM on an Apple Silicon host (Omarchy-M / Asahi)

Status: **usable**. On an M1 Pro (Omarchy-M, 16 KiB pages, 16 GB RAM), the VM boots to the home
screen with the GPU, and apps, Safari and its JIT run. The boot ROM, LLB, iBoot, SPTM, TXM, XNU and
sepOS run natively under KVM instead of TCG. vphoned answers about 60 s after QEMU starts. A soak
of 16 boots, each followed by 6 Safari launches, came through clean (2026-11-25).

This follows ChefKiss Inferno's KVM backend (git.chefkiss.dev/AppleHax/Inferno, "Initial KVM
support"), adapted to vresearch101. Known issues are under [Build and run](#known-issues).

## What it needs

- An Apple Silicon Mac running **Omarchy-M** with its `linux-aurora` kernel. Only an M1 Pro has been
  tested; M2 should work in principle.
- **16 GB of RAM or more.** The guest takes 6 GB (`MEM=6G`), and the GPU stack needs about 4 GB
  more.
- The patched kernel **`linux-aurora-kvm`** (below). It installs next to `linux-aurora` as its own
  boot entry, and `linux-aurora` stays the default.
- **QEMU, reims-vgpu and metal2vulkan from this repository**, built by `./build.sh`.
- **AC power** for anything you measure. On battery the Mac runs about 40% slower.

## Install the kernel

The patch (`kvm/linux-aurora-kvm/0001-kvm-arm64-userspace-exits-for-apple-guests.patch`) applies to
the same `linux-aurora` commit Omarchy-M ships, pinned in `kvm/linux-aurora-kvm/PKGBUILD`. It adds:

- the KVM exits GXF/PAC emulation needs (table below);
- a shared area in `kvm_run` (`struct kvm_arm_apple_fast`), through which the kernel handles the
  hottest traps itself: world switches, PAC keys, SPRR reads, leaf page-table stores, TTBR0
  switches and the JIT's SPRR toggles.

Build and install it:

```sh
sudo pacman -S --needed bc dtc rustup clang llvm lld clang18 llvm18 lld18 xmlto
cd kvm/linux-aurora-kvm
makepkg -s                                         # about an hour on an M1 Pro
sudo pacman -U linux-aurora-kvm-7*.pkg.tar.*       # the -headers package is optional
```

`pacman -U` adds a **linux-aurora-kvm** entry to `/boot/efi/limine.conf` through
limine-entry-tool. The default entry does not change. Omarchy's Limine menu is hidden by default
(`timeout: 1`, `quiet: yes`). To pick the new entry at boot, set `timeout: 5` and `quiet: no`
there; keep a copy of the file first.

Reboot, choose **linux-aurora-kvm**, then check:

```sh
uname -r                    # 7.2.11-16-1-kvm-ARCH
ls -l /dev/kvm              # your user needs read/write access (group kvm, or a uaccess ACL)
```

`kvm/kvm-exits-test.c` runs a bare vCPU through each new exit. It needs the patched UAPI headers: run
`make headers_install INSTALL_HDR_PATH=<dir>` in the patched kernel tree, then
`cc -O2 -I <dir>/include -o kvm-exits-test kvm/kvm-exits-test.c && ./kvm-exits-test`.

**Going back:** reboot and pick `linux-aurora`, which is still the default. To remove the kernel,
run `sudo pacman -R linux-aurora-kvm`.

**Keep the kernel and QEMU in step.** The kernel's fast paths share a layout with QEMU
(`struct kvm_arm_apple_fast`), versioned by `KVM_CAP_ARM_APPLE_FAST`. QEMU refuses to start on a
kernel with another version:

```
KVM: the host kernel's fast-path layout is version 0, this QEMU needs 2: rebuild linux-aurora-kvm ...
```

After pulling a change to the patch, rebuild and reinstall the kernel, then reboot. `makepkg -ef`
rebuilds from the existing tree in minutes. `VR_NO_FAST=1` starts QEMU anyway with every trap
handled in QEMU, but that mode is much slower and is meant for debugging only.

## Prepare the host

These settings take effect at every boot.

- **udmabuf limits.** On Asahi the GPU stack shares guest RAM with the GPU as dma-bufs, and the stock
  limits (1024 pieces, 64 MiB) are too small for a framebuffer:

  ```sh
  sudo tee /etc/tmpfiles.d/udmabuf.conf <<'CONF'
  w /sys/module/udmabuf/parameters/list_limit - - - - 65536
  w /sys/module/udmabuf/parameters/size_limit_mb - - - - 2048
  CONF
  sudo systemd-tmpfiles --create /etc/tmpfiles.d/udmabuf.conf
  ```

  `/dev/udmabuf` must be readable and writable by your user.

- **Honeykrisp's device heap.** Mesa's Asahi driver counts imported memory against a heap of half
  the RAM, and QEMU imports the guest's RAM, so the VM runs out of "device memory" while RAM is free.
  Raise the heap for QEMU only, in `~/.drirc`:

  ```xml
  <driconf>
    <device>
      <application name="qemu (vphone)" executable="qemu-system-aarch64">
        <option name="heap_memory_percent" value="1" />
      </application>
    </device>
  </driconf>
  ```

  (The value is a multiple of RAM in this Mesa build: `1` means all of it.)

## Build and run

`./build.sh` builds reims-vgpu, metal2vulkan and QEMU. On an aarch64 Linux host QEMU's configure
enables KVM by itself (`--enable-kvm` makes it explicit). Then run:

```sh
ACCEL=kvm SMP=6 MEM=6G GFX=1 WINDOW=1 VSOCK=vhost CID=3 ./run-vphone.sh vms/<name>
```

- `SMP=6` uses six of the M1 Pro's eight cores and leaves two for QEMU's own threads and the GPU.
- `run-vphone.sh` puts guest RAM in a sealed memfd on 16 KiB-page hosts, because udmabuf takes only
  memfds.
- Add `-snapshot` to leave the disk untouched. Alternatively, put a `Disk.qcow2` overlay in the VM
  directory: `run-vphone.sh` then writes there and opens `Disk.img` read-only.

Switches for comparisons and bug reports (all default off):

| Switch | Turns off |
|---|---|
| `VR_NO_KERNEL_TTBR0=1` | TTBR0_EL1 switches in the kernel |
| `VR_NO_KERNEL_PERM=1` | the JIT's EL0 SPRR toggles in the kernel |
| `VR_NO_KERNEL_PT=1` | leaf page-table stores in the kernel |
| `VR_NO_FAST=1` | the whole shared-area fast path (debugging only: much slower, and it logs stale-table warnings) |

### Known issues

- **Layered icons after Home.** After you leave an app, Safari's compass needle and the front gear
  of Settings can lose their fill until iOS redraws them, which takes up to about a minute. It needs
  four or more vCPUs running in parallel and follows GPU completion latency. The cause is not found.
- **vphoned stops answering** on about one boot in 15–20 (seen before 2026-11-15). Input goes
  through vphoned, so the screen looks frozen. vphoned's event loop never runs again after startup,
  while the guest's vsock driver keeps working. Quit QEMU and boot again. The 2026-11-25 soak did
  not hit it in 16 boots.
- **No guest reboot.** The hand-over to GXF/PAC emulation and the image patching are one-way, so
  quit QEMU and start it again.
- **Asahi's Vulkan driver** has no `VK_EXT_external_memory_host`, so metal2vulkan imports guest
  pages as dma-bufs. This needs the host settings above.

## Kernel exits

The patch adds five KVM capabilities that send work to QEMU instead of the guest:

| Capability | What exits to QEMU |
|---|---|
| `KVM_CAP_ARM_HVC_TO_USER` (253) | every `hvc`, with its immediate (GXF/PAC emulation, PSCI) |
| `KVM_CAP_ARM_IMPDEF_SYSREG_TO_USER` (254) | Apple's own system registers (Op0 3, CRn 11/15) |
| `KVM_CAP_ARM_FAULT_TO_USER` (255) | fetches from outside guest RAM, stores to write-protected pages |
| `KVM_CAP_ARM_TIMER_TO_USER` (256) | timer outputs with an in-kernel GIC (Inferno; unused here) |
| `KVM_CAP_ARM_GIC_SYSREG_TO_USER` (257) | the GICv3 CPU interface (`ICC_*`), with no in-kernel GIC (vphone) |

It also adds `KVM_ARM_SET_WRITE_PROTECT`. Capabilities 253–256 and the ioctl match Inferno's ABI
exactly; 257 is vphone's.

## How it works

- **No in-kernel GIC.** vresearch101 has two GICv3s at the same address: the AP's and the SEP's
  private one. One in-kernel vGIC can't model that, so both stay QEMU's GICv3 models
  (`kernel-irqchip=off`); the guest's `ICC_*` accesses exit to them (257), interrupts reach the
  vCPUs through KVM's IRQ/FIQ lines, and the timers through `device_irq_level`.
- **GXF/SPRR and Apple PAC** are emulated by `target/arm/apple-virt.c` (from Inferno): shadow
  page tables with the SPRR permissions of the current world, write-protected guest page tables,
  and per-EL PAC keys. It was adapted to the M1-style SPRR layout vresearch101's SPTM uses
  (`C1_5` EL0 table, `C1_6` EL1 table, `C3_0` EL0 mask).
- **Image rewriting.** SPTM, TXM and XNU run natively, so their `genter`/`gexit`, exception
  returns, lower-EL exception entries and SPRR/MMU register accesses are rewritten to `hvc`
  (`hw/arm/apple-silicon/virt_patches.c`, from Inferno). iBoot loads all three and jumps to SPTM,
  whose first act is to program SPRR/GXF; that write traps, and `vr_kvm_patch_images()` in
  `hw/vmapple/vresearch101.c` finds the three images in guest RAM and rewrites them once.
- **PSCI** (the guest's conduit is `hvc #0`) is answered by QEMU's PSCI code.
- **The SEP** is a KVM vCPU too, with its private RAM mapped into the guest's IPA space on first
  use (`accel/accel-private.c`); its addresses don't overlap the AP's.

## Licensing

`apple-virt.c`, `accel-private.c` and `virt_patches.c` come from ChefKiss Inferno and are
AGPL-3.0; see docs/LICENSING.md.

## Fixes found on the way (all in the `vphone-kvm` QEMU branch unless noted)

- KVM refuses to run a vCPU whose PMU was requested but not set up: the board calls
  `kvm_arm_pmu_init()` for every CPU.
- Kernel patch: with `GIC_SYSREG_TO_USER`, the ID registers' GIC fields are left as userspace set
  them (the in-kernel-GIC fixup cleared them, and QEMU's later register writes failed with EBUSY).
- GXF/PAC emulation takes over the AP cores only at SPTM's first SPRR write: the boot ROM, LLB and
  iBoot change SCTLR, the TTBRs and the PAC keys natively, which it can't track.
- The A64 load/store emulator (`target/arm/emulate/aarch64.c`, used for MMIO accesses KVM can't
  decode) mis-decoded pre/post-indexed loads and stores; LLB's copy of the boot manifest hash out
  of the config page then stopped after one word and every image failed its Image4 check. It is
  rewritten to cover the load/store single and pair classes, SIMD registers and SP as a base.
- RAM holds several copies of SPTM, TXM and the kernelcache (iBoot's load buffers, header-bearing
  copies, and SPTM's running code without a Mach-O header). Every copy is patched, the running
  SPTM is found from the PC of the trap that starts patching, and every code section of every
  executable segment is scanned.
- The VM asks KVM for its largest IPA space, and the GXF shadow pool sits below 64 GiB so the
  guest's TCR_EL1.IPS (40 bits for XNU) can reach it.
- QEMU cleans guest RAM it touches to the point of coherency (`qemu_guest_ram_noncoherent`),
  since Apple's boot code maps DMA buffers non-cacheable and an M1 has no stage-2 forced write-back.

- SPTM/TXM/XNU run from copies iBoot packs into RAM in its own layout (the running SPTM has no
  Mach-O header): after patching a header-bearing copy, every changed 4 KiB page is written to every
  RAM page that still holds its original contents.
- vresearch101's SPTM names the GL1 registers the M1 way (`S3_6_C15_C10_<n>` for its own, EL1 names
  for the kernel's), the reverse of the A13 convention Inferno's emulation assumes: SPTM's and TXM's
  accesses become `M1_*` vregs (`apple_virt_m1_gl_names`), never the kernel's.
- PSCI is QEMU's: `CPU_ON` writes the new vCPU's state back to KVM (`arm-powerctl.c`), PSCI and
  apple-virt's slow HVC path take the BQL, and the board's MPIDRs replace KVM's (the SEP must be
  affinity 0: its boot monitor puts its stack by it).
- CLIDR_EL1 is set to the model's (KVM's, from an M1's CTR_EL0, shows only an L1 instruction
  cache, and the SEP's boot monitor stops on that).

Debugging aids: `VR_STEPTRACE=1` single-steps the kernel world (out of GXF) and logs every
exception it takes plus each SPTM call's result (x1 holds SPTM's panic string on failure);
`VR_GXF_CALLS=1` logs genter/gexit under TCG; `VR_TRACE_NISV=1` logs undecodable MMIO exits;
`VR_TRACE_EXITS=1` logs CPU 0's HVC and system-register exits and SCTLR.M
mismatches; `BDIF_WHO=<disk offset>` prints the guest call stack that reads that offset. gdb works
with `-gdb tcp::1234 -S` (hardware breakpoints; watchpoints don't fire under KVM).

## GPU on Asahi

Asahi's Vulkan driver (Honeykrisp) imports no host pointer (`VK_EXT_external_memory_host`), only
dma-bufs. metal2vulkan therefore makes no-copy buffers over dma-bufs of the guest's pages, which
reims-vgpu creates with `/dev/udmabuf`. This is why the host needs the udmabuf limits and the
`~/.drirc` heap setting in [Prepare the host](#prepare-the-host). Other Honeykrisp differences
handled in metal2vulkan:

- framebuffer fetch and raster order groups without a pixel interlock (`7821c91dd`, `2ed4760b3`);
- varyings read at the pixel centre (`6adfad109`);
- the wallpaper's tile-row streaks (vphone-linux `f83c00c`).

reims-vgpu needs `+lse,+rcpc` on aarch64 Linux, which its `.cargo/config.toml` sets.

## The hangs: `hvc` that doesn't trap (worked around)

Three symptoms had one cause: a spinning `hvc #0x80ae; cmp x14, #0; b.ne .` (GXF_STATUS check
with a stale x14), the kernel's bad-stack or PAC `brk #0xc472` halt with the other CPUs parked
in SPTM, and SPTM `VIOLATION_*` panics. On the M1 under KVM a patched `hvc` occasionally runs
without trapping (KVM's trace shows no exit; memory and the shadow translations hold the patched
instruction). Seen at the lower-EL vector (`hvc 0x1340` at VBAR+0x400) and the GXF_STATUS check,
on both core types, only inside the iOS guest: the reproducers `kvm/hvc-stress.c` and
`kvm/hvc-stress2.c` (a mini-kernel doing what XNU does around those `hvc`s) never skipped one
in over 600M traps. Ruled out: QEMU register write-backs, unpatched copies, shadow-pool reuse,
I-cache staleness, interrupt delivery, ACTLR, KVM's PC/exception injection.

The fix: patched traps are trapped IMPDEF sysreg accesses instead,
`msr/mrs S3_<op1>_C11_C<crm>_<op2>, X<rt>` with the 16-bit hvc immediate packed into
read:1 op1:3 crm:4 op2:3 rt:5 (`apple_virt_trap_insn`). KVM forwards them as
`IMPDEF_SYSREG_TO_USER` exits; `kvm_arm_handle_sysreg` unpacks the immediate, steps the PC and
calls `kvm_arm_handle_hvc`. They always trap: 20 min (GFX=0) and 37 min (GFX=1) boots with the
skip detectors armed caught nothing. `VR_TRAP_HVC=1` goes back to `hvc`.

`VR_CATCH_CORRUPT=1` enables the instrumentation (exit rings with timestamps, invariant checks,
trapped check spin `0x13ff`, skip detector `0x13fc` after the vector's trap, translation
dumps); `VR_VECTOR_ISB=1` puts an `isb` before the vector's trap; `VR_POOL_AGED=<n>` changes
shadow-table reuse.

## Open items

- The layered-icon glitch after Home (see [Known issues](#known-issues)).
- vphoned's rare deaf event loop (see [Known issues](#known-issues)).
- A version check on `struct kvm_arm_apple_fast`, so that a mismatched kernel and QEMU turn the
  fast paths off instead of misreading each other.
- Fewer exits:
  - ASID-tagged shadow tables, to drop the ~110k/s TLB flushes at world switches;
  - GIC CPU-interface exits, still about 38% of QEMU's exit time.
- Why the M1 lets a guest `hvc` through untrapped (worked around above).
- A guest reboot: the hand-over to GXF/PAC emulation and the image patching are one-way.
