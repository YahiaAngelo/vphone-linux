# vphone-linux

Run [vphone-cli](https://github.com/Lakr233/vphone-cli)'s virtual iPhone on a **Linux x86_64 host**, or on Windows 11 under WSL2 ([docs/WSL.md](docs/WSL.md)).

<p align="center">
  <img src="docs/screenshots/lock-screen.png" width="200" alt="Lock screen">
  <img src="docs/screenshots/home-screen.png" width="200" alt="Home screen with widgets">
  <img src="docs/screenshots/maps.png" width="200" alt="Maps">
  <img src="docs/screenshots/calendar.png" width="200" alt="Calendar">
</p>
<p align="center"><i>iOS 27.0.1 (iPhone 16 Pro, at 2x) running on a Linux PC (Fedora, NVIDIA GPU) in vphone-linux, created with <code>setup/create-vm.sh</code>.</i></p>

vphone-cli runs iOS on an Apple Silicon Mac with Apple's Virtualization.framework, on the
`vresearch101` virtual platform that Apple's Private Cloud Compute (PCC) research VMs use. vphone-linux
boots the **same VM bundle** on Linux, with no Apple code at run time, and can also **create it on
Linux with no Mac at all** (see [docs/CREATE-ON-LINUX.md](docs/CREATE-ON-LINUX.md)):

- **QEMU** (a fork of [ChefKissInc/QEMUAppleSilicon](https://github.com/ChefKissInc/QEMUAppleSilicon)) gains a
  `-M vresearch101` machine and an `apple-gxf` CPU (GXF/SPRR for SPTM and TXM). It runs the guest
  under TCG with 8 vCPUs and models the SEP coprocessor, the GIC wiring, a USB touchscreen, vsock and
  the paravirtual GPU's MMIO device.
- **[reims-vgpu](https://github.com/steelbrain/reims-vgpu)** implements Apple's ParavirtualizedGraphics
  protocol on the host. It is statically linked into QEMU.
- **[metal2vulkan](https://github.com/steelbrain/metal2vulkan)** translates the guest's Metal work to
  Vulkan.

This repository is the glue: the launcher (`run-vphone.sh`), the test and profiling tools (`tools/`),
the Linux build of vphone-cli's firmware tooling (`linux-create/`) and the documentation. The three forks are git submodules (see [Repository layout](#repository-layout)).

Development updates: [@YahiaDev on X](https://x.com/YahiaDev).

## Status

So far tested on one PC: Fedora 44, Intel i7-14700K, 62 GB RAM, NVIDIA RTX 4080 SUPER (driver
615.71.09).

Linux distributions `setup/setup.sh` supports, and how far each was tested:

| Distribution | Tested |
|---|---|
| Fedora 43/44 | end to end (the home screen) on the PC above; setup + vphone-cli build in a clean Fedora 44 container |
| Arch Linux, Omarchy | setup, the whole build, and a VM created through the CFW install (Omarchy 4.0.4 in a VM); `tools/omarchy-window.sh` floats the iPhone window under Hyprland |
| Debian 13, Ubuntu 25.04+ | setup + vphone-cli build in clean Debian 13 and Ubuntu 26.04 containers |
| Windows 11 (WSL2, Ubuntu) | the iPhone boots, rendered on lavapipe ([docs/WSL.md](docs/WSL.md)) |

Every list of packages is checked against Fedora 43/44, Debian 13, Ubuntu 25.10/26.04 and Arch by
CI. Ubuntu 24.04 is too old (no libimobiledevice-glue or libtatsu).

Tested guest pairings on Linux:

| Device | iOS | cloudOS | State |
|---|---|---|---|
| iPhone17,3 (iPhone 16 Pro) | 26.6.2 (23G90) | 26.4 (23E5207q) | end-to-end: the home screen, created with no Mac |
| iPhone17,3 (iPhone 16 Pro) | 27.0.1 (24A446) | 26.4 (23E5207q) | end-to-end with `setup/create-vm.sh`: the home screen at 2x, Auto-Lock Never |
| iPhone19,4 (iPhone Duo) | 27.1 (24A94425) | 26.4 (23E5207q) | the home screen: display, wallpaper, touch (keep it at 3x); needs this repo's QEMU (native X1 and CSSC) |

**Works**

- A full boot: AVPBooter, iBoot, SPTM/TXM, XNU, sepOS on the emulated SEP, the encrypted Data volume,
  the user's lock screen. In test boots, vphoned answered 1-2 minutes after start and the device
  unlocked after 3-5 minutes.
- Home screen, wallpaper, widgets, Control Center and built-in apps (Settings, Calendar, Maps, Photos,
  Weather and others), drawn by the guest's Metal through reims-vgpu and metal2vulkan on the host GPU.
- Touch: QEMU's `usb-touchscreen`, which iOS accepts as the built-in main-screen digitizer. Taps,
  scrolling and drags work from the window (`WINDOW=1`) and over QMP (`tools/qmp.py`).
- Home: a swipe up from the bottom edge, or a middle click. QEMU turns these into Cmd+H, iOS's Home
  shortcut (the guest does not start its own home gesture from this touchscreen).
- vphoned, vphone-cli's guest daemon, over vsock (port 1339): health, `screen.unlock`, `apps.launch`,
  services, file upload, self-update (`tools/vphoned.sh`, `tools/vphoned-update.sh`).
- Your own apps: an iOS app built on Linux with [xtool](https://github.com/xtool-org/xtool) installs
  and runs with `tools/install-ipa.py`, no Apple ID or signing needed
  ([docs/APP-DEVELOPMENT.md](docs/APP-DEVELOPMENT.md): build, run, logs, the edit–build–run loop).

**Creating the VM on Linux, with no Mac**

- Done end to end on the test PC (2026-10-24), from an empty bundle: vphone-cli 2.12.1's
  `fw prepare` and `fw patch` built for Linux, a full restore through OpenAVB's DFU mode over USB/IP,
  vphone-cli's custom firmware installed through an SSH ramdisk, then a boot to the home screen
  (vphoned answered after 49 s, unlocked after 89 s; the first boot's data migration took about 20
  minutes more).
- The boot ROMs are **OpenAVB** and **OpenSEP**, the open-source ROMs vphone-cli ships, in place of
  Apple's `AVPBooter`/`AVPSEPBooter`. Everything else comes from Apple's published IPSWs and
  vphone-cli's release zip.

**Known limits**

- **Speed.** The guest's arm64e code runs under TCG (there is no hardware virtualization of arm64 on
  x86). A cold app launch took about 19-20 s and a warm one 4-8 s in an earlier measurement
  (2026-10-19); later TCG work made indirect-branch lookups and TLB refills much cheaper.
  Scrolling Settings now runs at about 60-68 frames/s on average, with occasional 50-110 ms stalls
  (guest CPU work at emulated speed).
- Creating the VM needs root for several steps, about 45 GB free disk, and about an hour plus the
  downloads ([docs/CREATE-ON-LINUX.md](docs/CREATE-ON-LINUX.md)).
- Only the NVIDIA host GPU has been tested. reims-vgpu documents what AMD GPUs need (`/dev/udmabuf`).
- vphoned's `GET /v1/files/content` stops after 64 KiB on the default vhost-vsock datapath; use
  `tools/guest-read.py`, or the `virtio-vsock-uds-pci` device (QEMU branch `vsock-uds`, not merged).
- reims-vgpu runs in **census mode** by default: a Metal feature it cannot model costs an inexact frame
  instead of killing the VM (see [docs/PERFORMANCE.md](docs/PERFORMANCE.md)).
- Untested: networking, audio, multiple VMs at once.
- Never boot two VMs on one `Disk.img`: the drives are opened with `file.locking=off`, and a second
  VM corrupts the APFS image.

## Quick start

You need a Linux x86_64 PC with a Vulkan GPU (NVIDIA tested), 16 GB RAM or more, about 100 GB free
disk, and sudo. No Mac. **Two steps**:

```sh
git clone https://github.com/YahiaAngelo/vphone-linux.git && cd vphone-linux
./setup/setup.sh                    # deps + sources + all binaries (re-runnable)
./setup/create-vm.sh                # pick a device and an iOS version; it creates the VM
```

`create-vm.sh` menus down to a tested device/iOS pairing, runs the whole create flow
(`fw prepare` + `fw patch`, the DFU restore, the SSH-ramdisk CFW install, the snapshot flip),
keeps one state file per VM so a re-run resumes after a failed step, and starts QEMU exactly once
at the end (never killed by the scripts). Non-interactive:

```sh
./setup/create-vm.sh --device "iPhone17,3" --ios 26.6.2 --scale 1
./setup/create-vm.sh --list         # every device and its tested pairings
```

The pairings tested here: iPhone17,3 + iOS 26.6.2 and + iOS 27.0.1 (end to end with these scripts:
the home screen), and iPhone19,4 (the iPhone Duo) + iOS 27.1 (the home screen; keep it at 3x). Other
pairings are macOS-tested and offered as "under test" with a confirmation. Already have a VM made
with vphone-cli on a Mac? [docs/CREATE-ON-MAC.md](docs/CREATE-ON-MAC.md) shows how to bring it over
instead. The step-by-step manual path, with the packages and every command, is
[docs/SETUP.md](docs/SETUP.md).

## Documentation

| Document | Contents |
|---|---|
| [setup/](setup/README.md) | The two-step setup in this repo: build everything, then pick a device and an iOS version and create the VM |
| [docs/SETUP.md](docs/SETUP.md) | The manual step-by-step: what you need, dependencies, building, creating the VM, first boot, your own apps |
| [docs/CREATE-ON-LINUX.md](docs/CREATE-ON-LINUX.md) | The create flow in detail: firmware, restore over USB/IP, custom firmware, first boot |
| [docs/APP-DEVELOPMENT.md](docs/APP-DEVELOPMENT.md) | Developing iOS apps on Linux with xtool: build, run in the VM, read the log, iterate |
| [docs/CREATE-ON-MAC.md](docs/CREATE-ON-MAC.md) | Optional: creating the VM with vphone-cli on a Mac and copying it over |
| [docs/WSL.md](docs/WSL.md) | Running on Windows 11 under WSL2: what differs (lavapipe, the kernel tree for APFS) and the one-time setup |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Known problems and fixes |
| [docs/ADVANCED.md](docs/ADVANCED.md) | Building by hand, display scale, services, GPU clocks |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How the machine model, SEP, GIC, USB touch, vsock and the GPU path fit together |
| [docs/PERFORMANCE.md](docs/PERFORMANCE.md) | The TCG performance work, every tuning switch, and how to profile |
| [docs/TOOLS.md](docs/TOOLS.md) | Each script in `tools/` |
| [docs/LICENSING.md](docs/LICENSING.md) | Licenses of the parts |
| [CONTRIBUTING.md](CONTRIBUTING.md) | How to contribute |

## Repository layout

```text
vphone-linux/
├── build.sh               builds the submodules and QEMU
├── run-vphone.sh          the launcher: a vphone-cli VM bundle -> QEMU command line
├── tools/                 test, input, vphoned and profiling scripts (docs/TOOLS.md)
├── linux-create/          vphone-cli's firmware tooling built for Linux (fw, restore, cfw)
├── patches/               small patches for vphone-cli (Mac side)
├── docs/
├── qemu/                  submodule: qemu-vphone, branch vphone
├── reims-vgpu/            submodule: reims-vgpu fork, branch vphone
├── metal2vulkan/          submodule: metal2vulkan fork, branch vphone
├── vms/                   your VM bundles (ignored by git)
└── runs/                  test-run output (ignored by git)
```

The submodules are [qemu-vphone](https://github.com/YahiaAngelo/qemu-vphone),
[reims-vgpu](https://github.com/YahiaAngelo/reims-vgpu) and
[metal2vulkan](https://github.com/YahiaAngelo/metal2vulkan), each on its `vphone` branch.
reims-vgpu's `Cargo.toml` takes metal2vulkan from `../metal2vulkan`, so the submodules must stay side by
side as above. vphone-cli is not a submodule: on a Mac it
runs from its own releases, and `linux-create/sync-sources.sh` builds its firmware tooling from a
vphone-cli 2.14.2 checkout without changing its files.

## Credits

- [QEMU](https://www.qemu.org/) and [ChefKissInc/QEMUAppleSilicon](https://github.com/ChefKissInc/QEMUAppleSilicon)
  (Apple Silicon machines, GXF/SPRR, the A13-era CPU work this builds on).
- [reims-vgpu](https://github.com/steelbrain/reims-vgpu), [metal2vulkan](https://github.com/steelbrain/metal2vulkan)
  and [qemu-reims-vgpu](https://github.com/steelbrain/qemu-reims-vgpu) (the C `apple-gfx` device ported here)
  by steelbrain (Anees Iqbal).
- [vphone-cli](https://github.com/Lakr233/vphone-cli) by Lakr233 and contributors (VM creation, firmware
  patches, the CFW and vphoned), and the [super-tart-vphone-writeup](https://github.com/wh1te4ever/super-tart-vphone-writeup)
  it acknowledges.
- The Asahi Linux project's documentation of Apple's GXF.

## Legal

This project contains **no Apple software**. It does not ship firmware, IPSWs, ROMs,
kernelcaches or VM images, and the emulator uses no code from Virtualization.framework. You create
your own VM from firmware Apple publishes, on Linux or with vphone-cli on your own Mac. On Linux,
vphone-cli's tooling downloads the IPSWs you name from Apple's servers, and the VM boots on the
open-source OpenAVB/OpenSEP ROMs from vphone-cli's release.

Apple's software licenses restrict where and how its operating systems may run. Running an iOS or
PCC guest outside Virtualization.framework on a Mac may not be permitted by those terms. vphone-cli
describes its purpose as security research, reverse engineering and debugging; this project has the
same purpose. You are responsible for complying with the licenses of the software you run.

"Apple", "iPhone", "iOS" and "Metal" are trademarks of Apple Inc. This project is not affiliated with or
endorsed by Apple, ChefKiss, or the authors of the upstream projects.

The glue in this repository is MIT-licensed ([LICENSE](LICENSE)). The submodules have their own
licenses: see [docs/LICENSING.md](docs/LICENSING.md).
