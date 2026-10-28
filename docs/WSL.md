# Running vphone-linux on Windows (WSL2)

vphone-linux runs inside WSL2 on Windows 11 with the same two steps as on a Linux PC
(`./setup/setup.sh`, then `./setup/create-vm.sh`). The scripts detect WSL and adapt. This page lists
what is different and what to set up once.

## What differs from a Linux PC

| | Linux PC | WSL2 |
|---|---|---|
| GPU path | the host GPU's Vulkan driver (NVIDIA tested) | **lavapipe** (Mesa's CPU Vulkan driver); see below |
| Window (`WINDOW=1`) | X11/Wayland | WSLg (built into WSL on Windows 11) |
| linux-apfs-rw | built against `linux-headers-$(uname -r)` | built against Microsoft's WSL kernel source, fetched and built once by `tools/wsl-kernel-tree.sh` (~10 min, ~6 GB) |
| `usbip` | distro package | Ubuntu's `linux-tools-*` copy, linked to `/usr/local/bin/usbip` by `setup.sh` |
| USB/IP, vhost-vsock, vhci-hcd | kernel modules | the same modules ship with the WSL kernel |
| USB access during a restore | libirecovery's `uaccess` rule (needs a logind seat) | `setup/data/70-vphone-apple-usb.rules`, installed by `setup.sh` (WSL has no seat) |
| CPU placement | `run-vphone.sh` pins QEMU to the P-cores (`/sys/devices/cpu_core`) | not possible: Windows schedules WSL's vCPUs |

**Why lavapipe.** WSL2 has no native Vulkan driver for the host GPU. The only GPU-backed option is
Mesa's `dzn` (Vulkan on Direct3D 12), which cannot import guest RAM by pointer
(`VK_EXT_external_memory_host`), and WSL has no `/dev/udmabuf` for the dma-buf fallback. reims-vgpu
needs one of the two for every guest surface. lavapipe supports the pointer import, so it works,
but it draws on the CPU: expect lower frame rates than on a GPU, and fewer cores left for the
guest. `run-vphone.sh` picks lavapipe on WSL and keeps it to 4 threads (`LP_NUM_THREADS`). Set
`VK_DRIVER_FILES` yourself to try another ICD.

## One-time setup

1. **WSL itself** (PowerShell): `wsl --update`, and use WSL 2 with systemd (the default for new
   Ubuntu installs; otherwise add `[boot]` / `systemd=true` to `/etc/wsl.conf`).
2. **Memory and cores.** WSL gets half of the PC's RAM by default. The guest needs `MEM` (8 GB) in
   `/dev/shm` plus room for QEMU and lavapipe: give WSL 16 GB or more in
   `%UserProfile%\.wslconfig`:

   ```ini
   [wsl2]
   memory=24GB
   processors=24
   ```

   Then `wsl --shutdown` and reopen.
3. **Device access.** `./setup/setup.sh deps` installs, on WSL, the vhost-vsock rules from
   docs/SETUP.md and a udev rule that opens the guest's DFU/recovery/restore USB device to your
   user. A one-off `chmod 666 /dev/vhost-vsock` does not last: the next udev event on the device
   resets it and QEMU fails with `vhost-vsock: failed to open vhost device: Permission denied`.

4. **Keep everything on the Linux filesystem** (`~`), not under `/mnt/c`. Windows drives are
   mounted over 9P, which is far too slow for `Disk.img` and the build trees.

## IPSWs you already have on a Windows drive

`create-vm.sh` reuses files in `~/.cache/vphone`, by the catalog's file names. Copy them there
rather than downloading again:

```sh
mkdir -p ~/.cache/vphone
cp "/mnt/h/vphone-linux/ipsws/iPhone17,3_26.6.2_23G90_Restore.ipsw" \
   /mnt/h/vphone-linux/firmware/cloudOS-26.4-23E5207q.ipsw ~/.cache/vphone/
```

A drive that was attached after WSL started (or a USB/network drive) may not be under `/mnt`
yet: `sudo mkdir -p /mnt/h && sudo mount -t drvfs H: /mnt/h`.

## Then

```sh
./tools/check-host.sh       # WSL-aware: lavapipe, WSLg, usbip
./setup/setup.sh
./setup/create-vm.sh --device "iPhone17,3" --ios 26.6.2 --scale 1
```

Scale 1 is the better choice on WSL: lavapipe's cost grows with the pixel count.

## Known problems on WSL

- **First boot: `userspace panic: datamigrator plugin SpringBoard.migrator hang`.** iOS's
  watchdog gives up on the first-boot data migration when the guest runs too slowly (WSL cannot
  keep QEMU on the P-cores). The guest stops in the panic and does not reboot: stop its QEMU and
  re-run `create-vm.sh`, which resumes at the first boot. Keep lavapipe small (`LP_NUM_THREADS`);
  `SMP=6` leaves Windows more room.
- **A restore or SSH-ramdisk boot waits forever for the next USB stage** (`waiting for the next
  stage's device` in the exporter log). Also seen on Linux (docs/CREATE-ON-LINUX.md §3): stop the
  VM with `tools/dfu-stop.sh`, and for a restore zero `nvram.bin` and `SEPStorage` again, then
  re-run `create-vm.sh`.

Status: setup, the restore, the CFW install and the first boot's start (Metal on lavapipe in a
WSLg window, vphoned answering) were run on WSL2 (Windows 11, Ubuntu 26.04, i7-14700K). The
first boot's migration has not yet completed on WSL.
