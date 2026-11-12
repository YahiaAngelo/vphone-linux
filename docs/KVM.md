# KVM on an Apple Silicon host (Omarchy-M / Asahi)

Status: **boots to launchd**. Under KVM the boot ROM, LLB, iBoot, SPTM, TXM, XNU (all six AP cores)
and sepOS run natively; XNU mounts the data volume and launchd runs its boot tasks.

On an Apple Silicon Mac running Linux (tested on an M1 Pro, Omarchy-M, 16 KiB pages), the
guest's AP cores can run natively under KVM instead of TCG. This follows ChefKiss Inferno's KVM
backend (git.chefkiss.dev/AppleHax/Inferno, "Initial KVM support"), adapted to vresearch101.

## What it needs

1. **A patched host kernel**, `linux-aurora-kvm` (built from `vphone-kvm-tools/linux-aurora-kvm`):
   linux-aurora plus five KVM capabilities that send work to QEMU instead of the guest:

   | Capability | What exits to QEMU |
   |---|---|
   | `KVM_CAP_ARM_HVC_TO_USER` (253) | every `hvc`, with its immediate (GXF/PAC emulation, PSCI) |
   | `KVM_CAP_ARM_IMPDEF_SYSREG_TO_USER` (254) | Apple's own system registers (Op0 3, CRn 11/15) |
   | `KVM_CAP_ARM_FAULT_TO_USER` (255) | fetches from outside guest RAM, stores to write-protected pages |
   | `KVM_CAP_ARM_TIMER_TO_USER` (256) | timer outputs with an in-kernel GIC (Inferno; unused here) |
   | `KVM_CAP_ARM_GIC_SYSREG_TO_USER` (257) | the GICv3 CPU interface (`ICC_*`), with no in-kernel GIC (vphone) |

   plus `KVM_ARM_SET_WRITE_PROTECT`. 253-256 and the ioctl match Inferno's ABI exactly; 257 is
   vphone's. It installs next to linux-aurora; pick it in the Limine menu at boot.
   `vphone-kvm-tools/kvm-exits-test` checks each exit on a bare vCPU.

2. **QEMU from this branch** (`qemu`, branch `vphone-kvm`), run with `ACCEL=kvm`:

   ```sh
   ACCEL=kvm SMP=6 CID=0 ./run-vphone.sh vms/<name> -snapshot
   ```

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

Asahi's Vulkan driver imports no host pointer (`VK_EXT_external_memory_host`), only dma-bufs.
metal2vulkan (branch `vphone-kvm`) then makes no-copy buffers over dma-bufs of the guest's pages,
which reims-vgpu creates with `/dev/udmabuf`. For that, `run-vphone.sh` puts guest RAM in a
sealed memfd on 16 KiB-page hosts (udmabuf takes only memfds), and udmabuf's limits must cover
a framebuffer (stock: 1024 pieces, 64 MiB):

    echo 65536 | sudo tee /sys/module/udmabuf/parameters/list_limit
    echo 2048  | sudo tee /sys/module/udmabuf/parameters/size_limit_mb

reims-vgpu (branch `vphone-kvm`) needs `+lse,+rcpc` for aarch64 Linux (`.cargo/config.toml`).
With these the boot draws the Apple logo and progress bar.

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

- Framebuffer fetch on Borealis: metal2vulkan refuses pipelines that read their colour
  attachments (no rasterization-order access, no pixel interlock), so the SpringBoard migrator
  hangs at ~87% of the progress bar.
- Why the M1 lets a guest `hvc` through untrapped (worked around above).
- A guest reboot: the hand-over to GXF/PAC emulation and the image patching are one-way.
- Clean-up: the debug switches, and upstreaming the kernel's CLIDR/TID behaviour notes.
