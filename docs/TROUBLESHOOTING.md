# Troubleshooting

Problems seen while developing vphone-linux, and their fixes. Setup steps are in [SETUP.md](SETUP.md).

**The VM runs old GPU code after a reims-vgpu change.** QEMU links `libreims_vgpu.a` statically. Run
`ninja -C qemu/build qemu-system-aarch64` after every `make -C reims-vgpu`.

**"task N not created", "Trying to restart GPU" loops.** reims-vgpu's per-process GPU tasks map guest
RAM in whole guest pages, so the RAM must be a shared file mapping aligned to 2 MiB. With `GFX=1` the
launcher sets this up (`memory-backend-file,mem-path=/dev/shm,share=on,align=2M`). Check that
`/dev/shm` has room for `MEM`. Keep `GFX_ISOLATION=on` (the default): local GPU tasks cannot serve
iOS's 256 GiB user tasks.

**A GPU task process uses llvmpipe.** Each GPU task process must use the same Vulkan device as QEMU.
The launcher sets `VK_DRIVER_FILES` to NVIDIA's ICD. On other GPUs, set `VK_DRIVER_FILES` to your
ICD's JSON.

**vphoned returns empty replies.** vphoned drops a half-closed connection before it answers.
`tools/vphoned.sh` keeps its write side open (`STDIN,ignoreeof`). Do the same in your own clients.

**Uploads to the guest stall after 256 KiB.** With `VSOCK=vhost`, Linux caps a vsock socket's send
credit at its own buffer size (256 KiB by default). iOS sends a credit update only when its 512 KiB
window is nearly full, so it never does. Set `SO_VM_SOCKETS_BUFFER_SIZE` (and `_MAX_SIZE`) to at least
512 KiB on the host socket: `tools/vphoned.sh`, `tools/vphoned-update.sh` and `tools/guest-get.py` set
4 MiB.

**Downloading a file over 64 KiB fails** (`GET /v1/files/content` closes after the first chunk on
vhost-vsock). Use `tools/guest-read.py` (base64 over the `files.read` RPC). The alternative is the
`virtio-vsock-uds-pci` device from QEMU branch `vsock-uds` with `VSOCK=uds`.

**vphoned never answers on vsock.** In earlier builds the iOS virtio driver's rings overlapped when
QEMU's vhost-vsock queues were smaller than 256 entries. qemu-vphone now uses 256-entry queues. If you see
it again, `tools/vsock-rings.py SOCK` prints the ring layout. A vsock CID is released only some time
after its VM exits, so give a new VM a new `CID` when you restart quickly.

**Touches are ignored.** If backboardd logs `ignoring digitizer event ... builtIn: NO`, the
touchscreen is not marked built-in. Keep `VPHONE_XHCI_NONREMOVABLE` at its default `0x1fe`.

**Everything is zoomed in after switching to 1x.** iOS kept the 3x scale it cached at an earlier
boot (MobileGestalt's `ArtworkDeviceScaleFactor`). Use `tools/set-scale.sh vms/myphone 1` with the
VM running: it clears that cache before shutting down. On a VM that is already zoomed, run it again
(it is safe to repeat), then start the VM.

**Touches do nothing on a new VM.** If backboardd logs `ignoring touch event ((backlight dim/off))`,
the screen has auto-locked and turned off (a new VM locks after 60 s), and iOS drops touches while
it is off. Wake it with `screen.unlock`, then set Settings › Display & Brightness › Auto-Lock to Never.

**The guest is sluggish at idle.** Disable background services ([ADVANCED.md](ADVANCED.md#background-services)). Look for crash loops with
the `logs.crashes` RPC, and look for a running ReportCrash.

**Black widgets or wallpaper.** Under heavy CPU starvation, FrontBoard's 10 s scene-create watchdog
kills the widget renderer and the wallpaper extension. Disabling services fixes it.

**NVIDIA Xid errors, a lost device, a frozen display.** Run the failing workload under the Vulkan
validation layer (`tools/validate-run.sh RUN CID BUNDLE_ID`) and report the errors. One such bug, a
transfer buffer freed while a copy into it was in flight, was fixed in the reims-vgpu fork.

**The VM died at an unsupported Metal feature.** By default the launcher runs reims-vgpu in census
mode (`REIMS_VGPU_CENSUS_DIR=runs/census`): a degradation that would kill the VM is recorded in
`census-<pid>.json` instead. `REIMS_VGPU_CENSUS_DIR=` (empty) restores the fatal behaviour.

**A corrupted VM disk.** The drives are opened with `file.locking=off` (the same `Disk.img` is
attached twice), so QEMU does not stop a second VM from opening the same disk. Never run two VMs
on one `Disk.img`. `tools/boot-test.sh` refuses to boot a disk that another QEMU holds. Work on reflink
copies.

**Huge logs, full `/tmp`.** `DFLAGS=int` and `-trace` patterns for the GIC write gigabytes per minute.
Stream them through a FIFO (as `tools/firstfault.py` does), or trace briefly.

**Stopping QEMU from a script.** Don't `pkill -f` a pattern that also matches your own shell's command
line. Find QEMU with `pgrep -x qemu-system-aar` (the kernel truncates the process name), or by its
`-qmp` socket path as `tools/boot-test.sh` does.

**Screenshots slow the guest.** QMP `screendump` runs under QEMU's global lock. PNG compression there
stalls every vCPU, so timing tools use PPM.

**Debugging the boot.** `DFLAGS=guest_errors,unimp LOG=q.log` logs unimplemented device accesses.
`GDB=1234` waits for `gdb -ex 'set architecture aarch64' -ex 'target remote :1234'`. Hardware
breakpoints do not fire on the SEP core (an extra CPU outside the SMP list). `tools/stuck.sh` and
`tools/firstfault.py` help when a boot stalls.

## Creating the VM on Linux

See [CREATE-ON-LINUX.md](CREATE-ON-LINUX.md) for the steps.

**A Linux restore resets the guest during `NORData`, or the mux logs short packets.** The system's
usbmuxd is running instead of the 32 KiB one, or the exporter is splitting transfers. Run
`sudo tools/usbmuxd-32k.sh` (it masks the system unit for this boot only) and use `tools/vusb-usbip.py`
from this repository.

**After a Linux restore, the VM stays in DFU** (every CPU loops in AVPBooter, `Disk.img` is never
read). The RestoreOS wrote the firmware store 16 KiB too early, because the `aux-pci` drive had no
`offset=16384`. Use the current `run-vphone.sh`. A bundle restored without it can be repaired by
shifting `nvram.bin` 16 KiB forward (16 KiB of zeros, then the first 32 MiB).

**OpenAVB never leaves DFU / `vusb-usbip.py` times out on the reset.** OpenAVB waits for QEMU to
mark each USB request done in the request descriptor itself (`flags = 0x8000`), not in a register as
AVPBooter and iBoot do. Use the restore QEMU with the current `hw/vmapple/vusb.c`.

**"The device did not enter dfu/recovery mode in time"** (from `recovery-probe`, the GPU-driver
step or `create-vm.sh`). Run `tools/dfu-diagnose.sh <run-dir>` as your user: it checks QEMU, the
exporter, the attach loop and the attached device. The usual cause on Arch and other distros
without a matching libirecovery udev rule: the DFU device is attached but root-only, so
vphone-cli's libirecovery, running as your user, cannot open it and skips it. The current
`tools/usbip-autoattach.sh` installs a rule for it in `/run/udev/rules.d` (gone at reboot), with
`MODE:=` so systemd's later `50-udev-default.rules` cannot set the device back to 0664 (an earlier
version's plain `MODE=` was undone that way: `ls -l /dev/bus/usb/*/*` showed the Apple device
`crw-rw-r--` root). Restart an attach loop started from an older checkout
(`sudo pkill -f usbip-autoattach.sh`, then `sudo tools/usbip-autoattach.sh`).

**`Error: Unsupported Linux platform` while setup installs Swift.** swiftly recognises only the
exact releases it lists (Fedora 39/41, Ubuntu 22.04/24.04/26.04, Debian 12/13, UBI 9...), so its
own detection refuses Fedora 44 and other newer releases. The current `setup/lib/swift.sh` always
names the platform (Fedora: `fedora41`, Arch and others: `ubi9`). An older checkout downloaded
`swiftly.tar.gz`, which is gone (404): update and run `./setup/setup.sh deps` again.

**`swift build` fails with `libxml2.so.2` or `libncurses.so.6` not found (Arch).** swift.org has no
Arch build; the UBI 9 one needs `libxml2-legacy` and the ncurses links `setup.sh` adds inside the
toolchain. Run `./setup/setup.sh deps`, or see the Arch notes in [SETUP.md](SETUP.md).

**`reims-vgpu: fatal: ... newBufferWithBytesNoCopy ... HostMemory, needs ExtExternalMemoryHost`.**
The Vulkan driver cannot import the guest's memory by pointer (`VK_EXT_external_memory_host`). A
Linux VM's virtio-gpu Venus (tryOmarchy, QEMU/virglrenderer) and WSL's dzn have no such extension:
render on lavapipe instead (`VK_DRIVER_FILES=/usr/share/vulkan/icd.d/lvp_icd.json`; WSL picks it
by itself). `tools/check-host.sh` warns about it.

**`one-time-boot-command=device-recovery` after "rebooting due to critical process crashes:
SpringBoard".** iOS rebooted itself into recovery, and every later boot goes there too. Boot with
`GFX=1` (SpringBoard needs the GPU device), and clear the request:
`tools/nvram-autoboot.py VM/nvram.bin --drop one-time-boot-command --drop device-recovery-boot-reason`.

**"Unable to discover device mode" right after `dfu-up.sh`.** An exporter from an earlier run still
holds 127.0.0.1:3240 for a VM that is gone. The current `dfu-up.sh` stops every old
`vusb-usbip.py` first.

**`ERROR the SSH ramdisk did not answer in 30 min`** (the cfw step). Every 5 minutes the wait
prints what it sees: the Apple USB devices on the host, the devices usbmuxd knows, ssh's last error
and the guest's last serial line. Read them in that order:
- No `05ac:12a8` on the host: the ramdisk has not booted, or the attach loop missed it. Check that
  `sudo tools/usbip-autoattach.sh` is still running (`/tmp/vphone-usbip-autoattach.log` should end
  with `05ac:12a8` attached) and the end of `VM/.runs-sshrd/serial.log`.
- `05ac:12a8` attached but usbmuxd lists nothing: the 32 KiB usbmuxd is not the one running.
  Run `sudo tools/usbmuxd-32k.sh` again and read `/tmp/usbmuxd-32k.log`.
- usbmuxd lists it but ssh fails: the error is in `VM/.runs-sshrd/ssh-wait.log`.
`fw patch's manifest refresh failed after patching TXM; continuing` just before it is expected and
harmless: `restore-tree-mode.sh` sets those digests itself. A re-run stops the QEMU an earlier
attempt left behind.

**The first boot's window disappears and setup keeps waiting for vphoned.** QEMU stopped. The guest's
RAM is a file in `/dev/shm`, a tmpfs that holds half the host's RAM by default: when it fills, QEMU
dies with no message once the guest touches enough memory.
`df -h /dev/shm` must show at least 8 GB free; `run-vphone.sh` now refuses to start otherwise.
Enlarge it with `sudo mount -o remount,size=12G /dev/shm`. Also check
`journalctl -k | grep -i -E 'oom|qemu'` for the out-of-memory killer. The current `create-vm.sh`
stops waiting when QEMU is gone and prints why.

**iBEC panics with "Kernelcache image not valid" or "TXM image load failed" when booting the SSH
ramdisk.** idevicerestore retypes restore images when it sends them (`krnl` → `rkrn`,
`trxm` → `rtrx`), and iBoot checks each against the manifest digest of the retyped bytes. Use
`tools/restore-tree-mode.sh`, which computes them that way.

**The kernel prints nothing and the ramdisk never shows up.** Check that `fw patch` ran on the tree
(CREATE-ON-LINUX.md, step 2).

**`cfw install` on Linux says "sshfs did not mount".** Check that the ramdisk is up
(`tools/ssh-ramdisk.sh id`) and that the guest volumes are mounted where the installer looks
(`/mnt1`, `/mnt7`, `/mnt6` by default; see CREATE-ON-LINUX.md, step 5). A
failed run can leave root sshfs mounts under `/var/tmp/vphone-cfw.*`; unmount them with
`fusermount3 -u` before retrying.
