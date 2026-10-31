# Architecture

```text
 Linux (linux-create/; or a Mac)           Linux host
 ───────────────────────────────           ──────────
 vphone-cli: IPSWs -> patched firmware,    run-vphone.sh <vm-dir>
 restore, CFW (vphoned)                      │
   │                                         ▼
   └─ VM bundle ──── copy ──────────▶ qemu-system-aarch64 -M vresearch101 (TCG, apple-gxf CPU)
      Disk.img, nvram.bin, ROMs,            ├─ 8 AP vCPUs: OpenAVB (or AVPBooter) → iBoot → SPTM/TXM → XNU → iOS
      SEPStorage, config.plist              ├─ SEP core (own address space, own GICv3): OpenSEP (or AVPSEPBooter) → sepOS
                                            ├─ vpiop mailbox (AP ⇄ SEP), VSTR SEP storage
                                            ├─ GICv3 + GICv2m MSI frame, PL011, RTC, cfg, bdif, AES
                                            ├─ PCIe: Apple virtio-blk (root), xHCI (kbd + hub → touchscreen),
                                            │        vhost-vsock (vphoned, port 1339), virtio-net
                                            └─ apple-gfx-mmio ──C API──▶ libreims_vgpu.a (static)
                                                                          ├─ ParavirtualizedGraphics protocol
                                                                          ├─ per-task GPU processes
                                                                          └─ metal2vulkan: AIR → SPIR-V, Metal → Vulkan
                                                                               └─ host Vulkan driver (NVIDIA)
```

The guest is iOS built for `vphone600ap` on the `vresearch101` virtual platform: the board that
Virtualization.framework presents to Apple's PCC research VMs. vphone-linux replaces
Virtualization.framework with QEMU and replaces Apple's ParavirtualizedGraphics host side with
reims-vgpu. Everything the guest runs is unchanged from what vphone-cli prepared.

## QEMU: the `vresearch101` machine

Source: `qemu/hw/vmapple/vresearch101.c` ([qemu-vphone](https://github.com/YahiaAngelo/qemu-vphone), branch `vphone`).

- **The board.** The device tree of `vresearch101ap`/`vphone600ap` (`arm-io,vmapple1`) puts every
  device QEMU's `vmapple` machine has at the same address. vresearch101 reuses vmapple's cfg, bdif,
  aes and virtio-blk devices and adds the devices below. The memory map and SPI numbers are at the top
  of the file. Unlike `vmapple`, the machine needs no HVF: it runs under TCG.
- **Machine options:** `ecid` (from the bundle's `config.plist`), `serial`, `sep-rom` (the SEP boot
  ROM), `gfx-device` (`apple-gfx-mmio` or none), `gfx-modes` (display modes such as `1290x2796@60`,
  `/`-separated) and `memory-backend`.
- **Boot.** `-bios` loads AVPBooter. `nvram.bin` is a pflash drive at offset 16 KiB: AVPBooter reads
  its firmware store (LLB, iBoot) from it. AVPBooter and iBoot read the root disk through the bdif
  "backdoor" device, which can now also write (iBoot saves NVRAM to the aux device). XNU then wants the
  same `Disk.img` as an Apple virtio-blk PCI device in the root role (`create_root_virtio_blk`), so the
  launcher attaches the image twice with `file.locking=off`. The cfg device reports board ID `0x90`.
- **CPU: `apple-gxf`.** This CPU model comes from ChefKissInc/QEMUAppleSilicon. It implements Apple's GXF guarded levels
  (GENTER/GEXIT) and SPRR permissions, which SPTM and TXM rely on. vphone-linux changes:
  - An M1-style SPRR layout and `apple_gxf_define_m1_override_cpregs()` (`hw/arm/apple-silicon/a13_gxf.c`).
    It overrides only `VBAR_EL1`. The A13 set also aliased `ELR/SPSR/ESR/FAR_EL1` to their GL copies,
    which made SPTM's FIQ return path loop forever.
  - The SPRR permission index comes from the leaf descriptor's own AP/UXN/PXN bits; table-level XN only
    removes execute (`target/arm/ptw.c`).
  - GENTER writes `ESR_GL`, and GEXIT follows `ASPSR` (`target/arm/tcg/helper-a64.c`).
  - No BTI (`target/arm/cpu64.c`): no Apple core implements it, and the guarded-page checks had cost
    about 1.3% of vCPU time.
  - A 24 MHz timebase (`cntfrq`) on every core, as the device tree says. sepOS asserts it.
- **Interrupts.** One GICv3 for the AP cores. Its FIQ outputs are connected because XNU routes the
  timer PPIs to group 0 (FIQ). Without them the guest never gets timer ticks. A GICv2m frame at
  `0x1fff0000` (the device tree's MSI frame) serves PCI MSIs; `MSI_TYPER` bit 31 is set for
  AppleVirtualPlatform's check (`hw/intc/arm_gicv2m.c`).

## The SEP coprocessor

Source: `create_sep()`, `create_sep_gic()` and `create_vpiop()` in `vresearch101.c`;
`hw/vmapple/vpiop.c`; `hw/vmapple/sep-storage.c`.

- **A second core with a private address space.** The SEP is an extra `apple-gxf` CPU outside the SMP
  list, so the launcher passes `maxcpus=SMP+1`. Its address space comes from AVPSEPBooter's page
  tables. It has its own ROM (`0x2000000`, the bundle's `AVPSEPBooter.vresearch1.bin`), SRAM
  (`0x4000000`) and a 32 MiB TZ0 region at `0x6000000` where sepOS is loaded. The rest of the system
  address space is shared with the AP.
- **Its own GICv3.** sepOS programs a GIC at the same physical addresses as the AP's. A one-CPU GICv3
  that is mapped only in the SEP's address space serves it (the new `first-cpu-index` property,
  `hw/intc/arm_gicv3_common.c`). The SEP core's MPIDR affinity is 0 so that SPIs reach it.
- **The vpiop mailbox** (`iop-sep,vpiop`, `0x30250000`): one register bank per side, 16-byte messages.
  INTID `0x34` on the AP carries both "inbox not empty" and "outbox empty", with an edge for each new
  event, as XNU's AppleVPIOP expects. The register layout is in `vpiop.c`'s header comment.
- **SEP storage (VSTR)**: sepOS's SEPD reaches the bundle's `SEPStorage` file through a register
  window at SEP physical `0x30020000` and a request buffer (VSTD) at `0x8000000`. The requests are
  virtio-blk chains (`sep-storage.c`).
- **A TRNG:** the cfg page's `rnd` word returns fresh random bits on every read. A constant value
  stalled sepOS's TRNG and led to SKS/ACM timeouts.

## USB: keyboard and touchscreen

Source: `vresearch101.c` (`create_pcie`), `hw/usb/dev-hid.c`, `hw/usb/dev-hub.c`, `hw/usb/hcd-xhci.c`.

- An xHCI controller with `usb-kbd` on root port 1 and a `usb-hub` on root port 2. The hub has a
  non-removable downstream port 2.1, which holds `usb-touchscreen`.
- **`usb-touchscreen`** uses the report descriptor and identity of Virtualization.framework's USB touch
  screen (05ac:8108 "Virtual USB Touch Screen"): four fingers, each with a transducer index, In Range,
  Touch, X and Y. QEMU's absolute pointer (the window, QMP `input-send-event`) drives finger 0.
- **Built-in.** backboardd only takes touches from the main-screen digitizer, which must be built in.
  iOS marks the touchscreen built-in when its xHCI root port reports Device Removable = non-removable
  (PORTSC bit 30). `VPHONE_XHCI_NONREMOVABLE` sets that bit per port; the launcher sets `0x1fe`.
- **The hub fix.** QEMU's hub raised `C_PORT_ENABLE` when a reset enabled a port. iOS took that as a
  port error and re-enumerated the touchscreen about once a second, forever.
- **Home.** iOS does not start its home gesture from this touchscreen. Instead, a drag that starts in
  the bottom 1% and rises at least 12% of the screen, or a middle click, sends Cmd+H on the USB
  keyboard (`VPHONE_TOUCH_HOME=0` turns this off).
- **Idle reports.** iOS sets the keyboard's HID idle rate to 24 ms. QEMU now records SET_IDLE but sends
  no unchanged reports: they had cost about a fifth of a vCPU at rest.
- `usb-vmapple-tablet` (05ac:8106) is an earlier experiment. iOS binds it as a mouse, not as a
  digitizer.

## vsock and vphoned

Virtualization.framework's `VZVirtioSocketDevice` is virtio-vsock. vphone-cli's guest daemon,
**vphoned**, listens on vsock port 1339 and speaks HTTP (`GET /v1/health`, `POST /v1/rpc`, file
transfer). See vphone-cli's `Research/vphoned_http_api.md`.

- **Default datapath: `vhost-vsock-pci`** (the kernel's vhost-vsock). The host side is plain
  `AF_VSOCK` (`socat - VSOCK-CONNECT:3:1339`). QEMU's vhost-vsock queues are 256 entries
  (`include/hw/virtio/vhost-vsock-common.h`). The iOS virtio driver assumes page-aligned rings, so
  with smaller tables the avail and used rings sometimes overlapped and every connection timed out.
- Host-to-guest streams need a host socket buffer of at least 512 KiB (`SO_VM_SOCKETS_BUFFER_SIZE`).
  Linux caps the send credit at that buffer, while iOS only sends a credit update when its 512 KiB
  window is nearly full.
- **Optional `virtio-vsock-uds-pci`** (QEMU branch `vsock-uds`, not merged into
  `vphone`): the vsock datapath runs inside QEMU, and the host side is a Unix socket
  (`$VSOCK_DIR/$CID.sock`, Firecracker-style `CONNECT <port>\n` / `OK <n>\n`). It never caps
  credit, and it asks the guest for credit updates. `VSOCK=uds` or `VSOCK=auto` selects it. The
  branch is based on an older `vphone` commit and needs a rebase.

## GPU: apple-gfx-mmio, reims-vgpu, metal2vulkan

**QEMU side** (`qemu/hw/display/apple-gfx.c`, `apple-gfx-mmio.c`, `apple-gfx.h`). This is the C
`apple-gfx` device from steelbrain's qemu-reims-vgpu, ported to the QEMU 10.2 APIs of
ChefKissInc/QEMUAppleSilicon and built on Linux. It replaces the macOS-only Objective-C device that
used ParavirtualizedGraphics.framework. Porting notes are not published.

- Two MMIO windows: the GPU at `0x30200000` (SPI `0x11`) and the IOSurface mapper at `0x30210000` (SPI
  `0x10`).
- Properties: `resolution` (the framebuffer size), `display-modes` (from the machine's `gfx-modes`) and
  `process-isolation` (default on, keep it on).
- Guest RAM must be a shared file mapping (`memory-backend-file,mem-path=/dev/shm,share=on,align=2M`).
  reims-vgpu's per-task processes map guest RAM themselves, in whole 16 KiB guest pages.
- `REIMS_VGPU_WINDOW=1` opens reims-vgpu's own window (SDL3), which also feeds input back into QEMU.

**reims-vgpu** (`reims-vgpu/`, [YahiaAngelo/reims-vgpu](https://github.com/YahiaAngelo/reims-vgpu), branch `vphone`) implements the host side of Apple's
ParavirtualizedGraphics protocol: the command FIFO, resources, IOSurfaces, displays and per-task GPU
processes. On Linux it runs the guest's Metal on its Vulkan platform. What the `vphone` branch adds:

- The guest's page size is taken per device, for arm64 guests (16 KiB pages) on an x86_64 host with
  4 KiB pages.
- ASTC textures on GPUs without ASTC (NVIDIA): blocks are decoded on the CPU, with deferred decode
  for GPU copies (`gpu/astc.rs`, `gpu/encode_blit.rs`).
- Robustness for iOS apps: a draw or dispatch the runtime refuses is skipped with a warning; a refused
  pipeline answers Metal's NSError; an unknown IOSurface texture answers nil; transfer buffers live 3 s
  past their release.
- `REIMS_VGPU_DUMP_IR`, `REIMS_VGPU_WORK_COUNTS`, `REIMS_VGPU_WINDOW_TITLE` (the launcher sets
  `vphone-linux`).
- `Cargo.toml` `[patch]`: metal2vulkan from `../metal2vulkan`.

**metal2vulkan** (`metal2vulkan/`, [YahiaAngelo/metal2vulkan](https://github.com/YahiaAngelo/metal2vulkan), branch `vphone`) compiles AIR (Metal's IR) to SPIR-V and maps the
Metal API onto Vulkan. What the `vphone` branch adds:

- iOS's runtime-compiled metallibs, which have no extended header (`metal2vulkan-air/src/container/mtlb.rs`).
- 4-byte bind offsets: iOS apps bind constant buffers at offsets that are not 16-byte aligned, which
  had broken the wallpaper's matrices (`lower/access/mod.rs`).
- `RGB8_444_2P` (4:4:4 two-plane YCbCr) render targets over iOS's private `'_RB4'` IOSurfaces, which
  the compositor and widget renderers use, including framebuffer fetch from them (`ycbcr.rs`,
  `shadow.rs`, `lower/fragment/fetch.rs`).
- Fallbacks for bicubic sampling states that were never measured.
- 256 kept pipeline variants instead of 16 (`M2V_KEPT_PIPELINES`). SpringBoard releases and recreates
  hundreds of pipelines as home-screen pages come and go.
- The golden-hash test tables, re-blessed for these changes (`SEMANTICS_VERSION` 1760).

## The launcher

`run-vphone.sh <vm-dir> [qemu args]` turns a bundle into a QEMU command line. It:

- reads `ecid`, `serial` and `gfx-res`;
- attaches the ROMs, `nvram.bin`, `Disk.img` (twice) and `SEPStorage`;
- with `GFX=1`, adds the GPU, the shared RAM backend and its environment;
- sets the TCG code cache size (`TB_SIZE`) and the TCG and USB switches;
- adds vsock;
- pins QEMU to the performance cores of a hybrid CPU.

Every switch is listed in [PERFORMANCE.md](PERFORMANCE.md#launcher-switches).

## Creating the VM on Linux

The steps are in [CREATE-ON-LINUX.md](CREATE-ON-LINUX.md). The parts:

**vphone-cli on Linux** (`linux-create/`). A Swift package that builds vphone-cli 2.14.2's firmware
tooling (`fw prepare`, `fw patch`, `restore`, `cfw install`, `sign`) on Linux. `sync-sources.sh` links
vphone-cli's own source files and adds Linux stand-ins for Apple modules (`Shims/`: Darwin, CryptoKit,
Compression, MachO, ...), whole-file replacements (`overlay/`) and one-line sed edits (`edits/`).
Fixes it needed on Linux include a `funopen` replacement for glibc, URLSession workarounds for Swift
6.4.1's Linux Foundation (an invalidated session aborts when freed; per-task delegates are ignored),
and emulation-length device waits for idevicerestore (`VPHONE_RESTORE_TIMEOUT_SCALE`).

**Boot ROMs.** OpenAVB and OpenSEP (from vphone-cli's release) replace Apple's ROMs, so no file from
a Mac is needed. OpenAVB loads iLLB from the firmware store in `nvram.bin`, or drops into DFU mode
when there is none; before it accepts a DFU iBSS, vphone-cli's restore uploads the image's identity
to it (`openavb.c`), and it only decodes an LZFSE iBSS.

**USB for the restore.** `hw/vmapple/vusb.c` (`vresearch-vusb`) models the bdif USB slot (`0x30100000`)
that OpenAVB, AVPBooter and iBoot use in DFU and recovery mode. Each request is a descriptor chain in
guest RAM; on completion the device sets register `0x10` (which AVPBooter and iBoot poll) and also
writes the first descriptor back (`flags = 0x8000`, and the received length), which is what OpenAVB
polls; `hw/vmapple/vusb-pci.c` is the RestoreOS's virtio
USB device controller. Both go to a chardev. `tools/vusb-usbip.py` turns
that into a USB/IP server on 127.0.0.1, the host attaches it with `usbip` (vhci_hcd), and usbmuxd and
vphone-cli's idevicerestore see an ordinary USB iPhone: 05ac:1227 (DFU), then 05ac:12a8/12ac (the
RestoreOS and the SSH ramdisk). Each stage re-enumerates, so `tools/usbip-autoattach.sh` re-attaches.

The RestoreOS's `AppleUSBDeviceMux` is not like usbmuxd's host side: it reads into 32 KiB buffers,
expects exactly one mux packet per USB transfer and drops shorter transfers without reassembling them.
So the host needs a usbmuxd built with a 32 KiB MTU (stock: 48 KiB), and the exporter forwards each
bulk OUT URB whole, together with the zero-length packet that ends it. DFU and recovery keep their
512-byte split.

**Auxiliary storage.** The RestoreOS writes the firmware store and NVRAM through a virtio-blk drive in
the aux role. That drive starts 16 KiB into `nvram.bin` (`offset=16384`), after Virtualization.framework's
header, where AVPBooter reads the store.

**CFW without `mount_apfs`.** The guest's System volume is sealed, and linux-apfs-rw refuses read-write
mounts of sealed volumes. So `cfw install` boots an SSH ramdisk built from the cloudOS restore ramdisk
(SSH tools added to the ramdisk and its trust cache, TXM's selector-24 check forced to pass, the
research kernel as the restore kernel), lets the guest's kernel mount its own volumes read-write, and mounts them on the host
with sshfs. Bundle signatures use rcodesign, AEA decryption is in process, and the cryptex images are
mounted read-only with linux-apfs-rw. idevicerestore retypes each restore image as it sends it
(`krnl` → `rkrn`, `trxm` → `rtrx`, ...), and iBoot checks the image against the manifest digest of
those retyped bytes, so `tools/restore-tree-mode.sh` hashes them that way. After the install,
`fw snapshot-flip` renames the restore's root snapshot so the kernel roots the live System volume.
