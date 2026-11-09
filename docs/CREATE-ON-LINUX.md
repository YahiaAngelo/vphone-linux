# Create the VM on Linux

> **The automated path.** `setup/create-vm.sh` runs everything this document describes — the menus
> (`--device` / `--ios` skip them), the state file per VM so a re-run resumes, and the first boot.
> This document is the same flow with every command visible, for when a step needs attention by
> hand.

The whole VM is made on Linux, with no Mac and no file from one: vphone-cli's firmware tooling built
for Linux (`linux-create/`) downloads and patches the firmware, restores it over USB/IP, and installs
the custom firmware (CFW) through an SSH ramdisk. The boot ROMs are **OpenAVB** and **OpenSEP**, the
open-source replacements for Apple's `AVPBooter` and `AVPSEPBooter` that vphone-cli ships.

> **Status (2026-10-24):** done end to end on the test host. A blank bundle was restored through
> OpenAVB's DFU mode, given the CFW, and booted to the home screen: vphoned answered 49 s after start,
> the lock screen unlocked at 89 s, and the first boot's data migration took about 20 minutes more.
> Every input is made by a script in `tools/` or downloaded from its source; nothing comes from a
> Mac. Several steps need root, so the route is still a series of commands rather than one.

**Before you start:** do [SETUP.md](SETUP.md) steps 1-3 (dependencies and builds). This page is
step 4 of that guide.

Something not working? The Linux-creation entries in [TROUBLESHOOTING.md](TROUBLESHOOTING.md#creating-the-vm-on-linux)
cover what went wrong on the test PC.

The steps:

1. [Make an empty VM bundle](#1-make-an-empty-vm-bundle)
2. [Download and patch the firmware](#2-download-and-patch-the-firmware)
3. [Restore over USB/IP](#3-restore-over-usbip)
4. [Boot the SSH ramdisk](#4-boot-the-ssh-ramdisk)
5. [Install the CFW](#5-install-the-cfw)
6. [Finish and first boot](#6-finish-and-first-boot)

Everything below uses `vms/` as the library and `myphone` as the VM. `VC` is the Linux vphone-cli:

```sh
VC=$PWD/linux-create/vphone-cli
```

## 1. Make an empty VM bundle

```sh
tools/new-vm.sh vms/myphone          # a random ECID; or: tools/new-vm.sh vms/myphone <ECID in hex>
```

It writes what vphone-cli's `vm new` would, with the ROMs from [SETUP.md](SETUP.md#3-build) step 3:

| File | Contents |
|---|---|
| `OpenAVB.bin`, `OpenSEP.bin` | Copies of the ROMs. |
| `config.plist` | vphone-cli's machine configuration: `vresearch101`, 8 CPUs, 8 GiB (`CPUS=`, `MEM_GIB=`), the 1290x2796 screen, `romImages` naming the two ROMs (`run-vphone.sh` boots those), NAT with a random MAC, and a `machineIdentifier` holding the ECID (Virtualization.framework's format: a binary plist `{ECID: …}`). |
| `ecid`, `udid-prediction.txt` | The ECID, for `run-vphone.sh` and for `restore` (so it needs no `--ecid`). |
| `Disk.img` | Empty, sparse, 64 GiB. |
| `nvram.bin` | Zeros, 32 MiB + 16 KiB. |
| `SEPStorage` | Zeros, 512 KiB. |

The name must not start with a dot (vphone-cli refuses it). Apple's signing server accepted a
random ECID from this script in testing (`restore --get-shsh`).

With an empty `nvram.bin`, OpenAVB finds no firmware to boot and drops into DFU mode
(`OpenBootROM: virtual firmware source not found`), which is where a restore starts.

Use fresh zeroed `SEPStorage` for each new restore. A VM whose SEP storage had been through many
restores panicked in the SEP key store at its first boot (`SEP Panic: :sks`).

## 2. Download and patch the firmware

The VM is made from two of Apple's firmware files (IPSWs), the pair vphone-cli recommends and that
was tested end to end:

| File | Size | Download |
|---|---|---|
| iPhone 16 (iPhone17,3) iOS **26.6.2 (23G90)** | 11.3 GB | [iPhone17,3_26.6.2_23G90_Restore.ipsw](https://updates.cdn-apple.com/2026SummerFCS/29d685ce-f70d-45a0-9823-b1cd115f3927/iPhone17,3_26.6.2_23G90_Restore.ipsw) |
| cloudOS **26.4 beta (23E5207q)** | 1.2 GB | [cloudOS 26.4 23E5207q](https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64) (the link has no file name; save it as below) |

Both come straight from Apple's update servers; vphone-cli lists the same links (`$VC fw urls
--device iPhone17,3`, and its firmware catalog for the cloudOS). The cloudOS 26.4 beta is the newest
cloudOS that still has the `vphone600ap` firmware the VM needs, so later cloudOS versions don't
work. Other iOS versions may work with it but were not tested here (`$VC fw catalog`).

**2.1 Download them** into an `ipsws/` folder in this checkout (git ignores it). `-C -` resumes a
broken download; the iPhone file took about an hour on the test PC:

```sh
mkdir -p ipsws
curl -L -C - -o ipsws/iPhone17,3_26.6.2_23G90_Restore.ipsw \
  'https://updates.cdn-apple.com/2026SummerFCS/29d685ce-f70d-45a0-9823-b1cd115f3927/iPhone17,3_26.6.2_23G90_Restore.ipsw'
curl -L -C - -o ipsws/cloudOS-26.4-23E5207q.ipsw \
  'https://updates.cdn-apple.com/private-cloud-compute/c0ecdb4b310cf5239ab2b248dd3098eec297dc5aa3bbe6ada27273262b0b8b64'
ls -l ipsws/      # 11254382122 and 1199454323 bytes
```

If you already have them elsewhere (another disk is fine), use those paths below instead.

**2.2 Start the USB helpers.** Both the GPU driver below and the restore in step 3 need them; leave
them running through step 5.

In **your main shell** (it starts the daemon in the background and returns):

```sh
sudo tools/usbmuxd-32k.sh          # stops and runtime-masks the system usbmuxd, runs the 32 KiB one
```

In **a second terminal** (it keeps running until Ctrl-C), from the same `vphone-linux` directory:

```sh
sudo tools/usbip-autoattach.sh     # attaches the VM's USB device at each stage (DFU, iBEC, RestoreOS)
```

Keep working in your main shell: the `VC` variable above and the `vms/myphone` paths are set up
there. Running the attacher in the main shell would block it, and a new shell would not have `VC`
(set it again there if you do switch).

**2.3 Get the GPU driver.** It ships in the cloudOS IPSW's AEA-encrypted cryptex, and Apple's key
server no longer gives out the key for 23E5207q, so take it from a stock cloudOS restore instead, as
vphone-cli does on a Mac:

```sh
tools/gpu-driver-from-cloudos.sh ipsws/cloudOS-26.4-23E5207q.ipsw drivers/
# -> drivers/AppleParavirtGPUMetalIOGPUFamily.bundle
```

This restores the stock cloudOS into a temporary VM (about 20 minutes), reads the driver from its
System volume with 7-Zip (no root, no mount), and deletes the VM. It needs about 5 GB free while it
runs. On the test PC it gave the same driver as vphone-cli on a Mac (SHA-1 `b5d95b38…`). You need it
once; keep `drivers/` for later VMs.

**2.4 Merge and patch the firmware** into the VM from step 1:

```sh
$VC fw prepare -l vms myphone \
  -i ipsws/iPhone17,3_26.6.2_23G90_Restore.ipsw -c ipsws/cloudOS-26.4-23E5207q.ipsw \
  --gpu-driver-bundle drivers/AppleParavirtGPUMetalIOGPUFamily.bundle
$VC fw patch -l vms myphone
```

`fw prepare` merges both IPSWs into a restore tree inside the VM (`vms/myphone/*_Restore`, about
12 GB); `fw patch` patches its boot chain. After that the IPSWs are only needed to make another VM,
so you can move or delete them. (`-i` and `-c` also take the URLs directly; vphone-cli then
downloads into `~/.vphone/ipsws`. Step 2.3 needs the cloudOS file on disk, so the explicit download
is simpler.)

- **Run `fw patch` every time after `fw prepare`.** `fw prepare` writes stock firmware; on the test
  host a re-prepared tree went unpatched and nothing booted past iBoot. `restore` later prints
  "recorded N boot-chain patches", but that number comes from the patch plan, not from the files.
  To check a tree: `FirmwareOriginals/` exists in the bundle, and the research kernel differs from the
  IPSW's (patched, it is about 43 MB instead of 14 MB).
- Don't set `VPHONE_NO_LZFSE`: OpenAVB only accepts an LZFSE-compressed iBSS, which `fw patch`
  writes by default.

## 3. Restore over USB/IP

The restore runs vphone-cli's idevicerestore against the guest, which QEMU presents as a USB device:

```text
guest (OpenAVB DFU → iBSS/iBEC → RestoreOS)
  └─ QEMU vusb / vusb-pci ── chardev ──▶ tools/vusb-usbip.py (USB/IP server, 127.0.0.1:3240)
       └─ usbip attach (vhci_hcd) ──▶ usbmuxd (32 KiB) ──▶ vphone-cli restore
```

1. Keep the two USB helpers from step 2.2 running.

2. Start the VM in DFU (add `GFX=1 WINDOW=1` to watch it in a window):

   ```sh
   tools/dfu-up.sh vms/myphone runs/myphone-dfu
   $VC recovery-probe                 # [+] iPhone99,11 in DFU, ECID 0x...
   ```

3. Restore (this **erases** `Disk.img`; about 25 minutes on the test host):

   ```sh
   VPHONE_RESTORE_TIMEOUT_SCALE=10 $VC restore -l vms myphone -v
   ```

   Keep at least 25 GB free on the disk holding `vms/` while it runs: on the test PC a restore
   failed at 12% (`format_media`) with 17 GB free and passed with 27 GB.

   A good run logs `Describing iBSS to OpenAVB`, ends with `Status: Restore Finished`, and leaves a
   firmware store in `nvram.bin` (`HUFA` at 0x4000, iLLB, `auto-boot=true`).
   `VPHONE_RESTORE_TIMEOUT_SCALE` stretches idevicerestore's device waits for emulation.

4. Stop the VM (the next step starts it again in a different mode):

   ```sh
   tools/dfu-stop.sh vms/myphone
   ```

On the test host one restore attempt failed early (the NVRAM recorded
`restore-outcome=initial_engine_failure_no_return`) and the next one, unchanged, passed. If a
restore hangs at "Waiting for device to enter restore mode", stop it, zero `nvram.bin` again and
retry.

## 4. Boot the SSH ramdisk

Linux cannot write the guest's System volume: it is sealed, and linux-apfs-rw refuses read-write
mounts of sealed volumes. So the guest's own kernel mounts its volumes from an SSH ramdisk (dropbear,
`root`/`alpine`), and the CFW install reaches them over sshfs.

**Build the SSH ramdisk image** once per firmware, while the restore tree is still in full mode
(right after step 3):

```sh
tools/ssh-ramdisk-stage.sh                              # -> runs/sshramdisk/ssh-root
bash tools/ssh-ramdisk-rebuild-signed.sh vms myphone    # -> runs/sshramdisk/out/094-39914-031.dmg (asks for sudo once)
```

The default keeps SSHRD's stock bootstrap and does not require an Apple SDK or signer.
For ECID-bound SSH, explicitly choose a trusted prebuilt artifact:

```sh
export VPHONE_SSHRD_BOOTSTRAP=/path/to/bootstrap
```

Alternatively, opt into a source build before automated creation or manual staging:

```sh
export VPHONE_SSHRD_BOOTSTRAP_BUILD=1
export DARWIN_SDK_BUNDLE="$HOME/.swiftpm/swift-sdks/darwin.artifactbundle"
```

Source builds require clang, ld64.lld, rcodesign, and xtool's Darwin SDK extracted
from Xcode. `setup.sh` does not install that SDK. Set `SDKROOT`, `LD64_LLD`, or
`RCODESIGN` when those tools live elsewhere. Do not select both modes.
Staging checks its arm64 iOS architecture, ad-hoc signing identifier, executable page
hashes, and signed USB/watchdog/platform/network entitlements before copying it.
Only use a bootstrap built from source you trust; ad-hoc signing does not identify its publisher.
Build one explicitly with `tools/sshramdisk-bootstrap/build.sh /path/to/bootstrap`.
No Apple SDK or signer is needed when staging a valid prebuilt bootstrap. Explicit
requests fail if validation or building fails. They never fall back to the stock bootstrap.

- `ssh-ramdisk-stage.sh` downloads the SSH tools (dropbear, bash, coreutils, sftp-server for iOS)
  from SSHRD_Script's [sshtars](https://github.com/verygenericname/sshtars) at a pinned commit,
  checks their SHA-256, and unpacks them. This repository doesn't redistribute them. Downloaded
  tools retain their signatures. When requested, `restored_external` is replaced by the signed
  ECID-aware bootstrap. It reads the guest's exact nonzero eight-byte `/chosen/unique-chip-id`
  and advertises its canonical ECID instead of SSHRD's shared build-date serial. Missing or
  malformed identity stops initialization. Automated creation then binds `VPHONE_ECID` to the
  selected VM. An explicit `VPHONE_ECID` during creation requires an ECID-aware bootstrap and
  must match the VM. Direct connector requests remain strict, including when no device matches.
  The trust cache built in the next step admits the exact staged code hashes.
- For an existing staging tree, run `tools/ssh-ramdisk-stage.sh --bootstrap-only` before rebuilding
  the image and trust cache. Automated creation performs this upgrade on every CFW attempt
  when an ECID-aware bootstrap is requested. Without an opt-in, an existing staging tree is kept.
- `ssh-ramdisk-rebuild-signed.sh` saves the tree's stock restore ramdisk to `runs/sshramdisk/` the
  first time, mounts a copy of its APFS volume (root, linux-apfs-rw), adds the tools, and repacks it.
- The tested ramdisk also carried a PRNG seeder (`prng_seedctl`), which exited without effect; the
  script leaves it out.

**Switch the restore tree to the SSH ramdisk:**

```sh
tools/restore-tree-mode.sh vms myphone ssh      # `full` undoes it
```

This swaps in the SSH ramdisk, builds a trust cache that admits its tools, forces TXM's selector-24
check to pass (`fw patch --restore-txm-precheck`), makes the patched research kernel the restore
kernel, and updates the manifest. Keep the tree in `full` mode for a full restore.

**Boot it.** With `auto-boot=false`, OpenAVB loads the restored iLLB and iBoot stops at its recovery
prompt (`05ac:1281`); `restore --boot-ramdisk` boots the ramdisk from there:

```sh
python3 tools/nvram-autoboot.py vms/myphone/nvram.bin --auto-boot false
tools/dfu-up.sh vms/myphone runs/myphone-sshrd
VPHONE_RESTORE_TIMEOUT_SCALE=10 VPHONE_RESTORE_BOOT_ARGS_EXTRA="serial=3" \
  $VC restore -l vms myphone --boot-ramdisk -v
```

After a few minutes the log ends like this, and **stays there**:

```text
Sending RestoreKernelCache (43374642 bytes)...
Waiting for device to enter restore mode...
normal_idevice_new: can't connect to lockdownd on device with UDID SSHRD_Script Sep 22 2022 18:56:50
```

That means the ramdisk is up: `SSHRD_Script` is the SSH ramdisk answering, and the lockdownd lines
only say it is not a normal iOS system, so the command never finishes on its own. **Press Ctrl-C to
stop it**; the ramdisk keeps running. Then, in the same shell:

```sh
tools/ssh-ramdisk.sh 'id'                                  # uid=0(root)
tools/ssh-ramdisk.sh '/bin/bash /usr/bin/mount_filesystems; /sbin/mount'
```

`mount_filesystems` mounts by role. On the test VM: System `disk1s1` at `/mnt1`, Data at `/mnt2`,
Preboot `disk1s5` at `/mnt6`, and xART `disk1s3` at `/mnt7` (it holds the gigalocker, a 6 MB
`<uuid>.gl`). Check with `/sbin/mount` and `ls`: the device numbers differ between restores.

## 5. Install the CFW

With the ramdisk up and its volumes mounted:

```sh
sudo $VC cfw install -l vms myphone --work-parent "${VPHONE_CFW_WORK_PARENT:-/var/tmp}" --keep-artifacts
```

- The installer mounts the guest's System, xART and Preboot on the host with sshfs, through
  `tools/sshfs-remote-sftp.sh` (the ramdisk's dropbear has no SFTP subsystem, so the wrapper runs
  `/usr/libexec/sftp-server` as a command). The guest paths default to `/mnt1`, `/mnt7` and `/mnt6`;
  if `mount_filesystems` put them elsewhere, pass
  `sudo VPHONE_GUEST_SYSTEM=… VPHONE_GUEST_XART=… VPHONE_GUEST_PREBOOT=… $VC cfw install …`.
- It decrypts the OS and App cryptexes in process, mounts them read-only with linux-apfs-rw, and
  copies them into System. That took about 16 minutes on the test host. The App cryptex is many
  small files, and the host disk barely grows for minutes at a time while it copies; it is not stuck.
- It needs rcodesign (found on `PATH`, in `~/.cargo/bin` of the user who ran sudo, or at
  `$VPHONE_RCODESIGN`) and the APFS driver from SETUP step 3 (`modprobe apfs`, else
  `$VPHONE_APFS_KO`, else `.build/linux-apfs-rw/apfs.ko`). It also needs about 8 GB of working space
  on the filesystem selected for `--work-parent`. Set `VPHONE_CFW_WORK_PARENT` to select a
  different path; it defaults to `/var/tmp`. The `cfw` command retains ownership and permission
  checks on the selected directory.
- It renames the xART gigalocker to `AA.gl`, installs vphoned and the launchd hook, and ends with
  `[+] Linux guest install complete` and a new `PatchReceipt.plist`.
- Without `--keep-artifacts` the restore tree is deleted at the end (12 GB back; a new restore then
  needs `fw prepare` again).

If an install fails halfway, look for leftover root sshfs mounts (`findmnt -l | grep vphone-cfw`)
and unmount them with `fusermount3 -u` before retrying.

## 6. Finish and first boot

1. Unmount the guest volumes from the ramdisk so nothing is lost, then stop the VM:

   ```sh
   tools/ssh-ramdisk.sh 'sync; /sbin/umount /mnt2; /sbin/umount /mnt6; /sbin/umount /mnt1; sync'
   tools/dfu-stop.sh vms/myphone
   ```

   xART at `/mnt7` stays busy; `sync` is enough for it.
2. Make the kernel boot the installed system, not the restore's snapshot, and turn auto-boot back on
   (the VM must be stopped):

   ```sh
   $VC fw snapshot-flip -l vms myphone
   python3 tools/nvram-autoboot.py vms/myphone/nvram.bin --auto-boot true
   ```

   Without the snapshot flip, launchd panics with `Library not loaded: /usr/lib/libSystem.B.dylib`.
3. If you kept the restore tree: `tools/restore-tree-mode.sh vms myphone full`.
4. Give the system usbmuxd back: `sudo kill $(cat /run/usbmuxd-32k.pid)`, then
   `sudo systemctl unmask --runtime usbmuxd.service`.
5. Keep a pristine copy (`cp -a --reflink=always vms/myphone vms/myphone.pristine`), then boot as in
   [SETUP.md](SETUP.md#5-start-it) (`GFX=1 WINDOW=1 ./run-vphone.sh vms/myphone`).

**The first boot** shows the Apple logo with a progress bar while iOS migrates its data. Under
emulation this took about 20 minutes on the test host; vphoned answers well before it ends (it
reports `setup_pending: true`). When the progress bar is gone, skip Setup Assistant and unlock:

```sh
tools/vphoned.sh POST /v1/rpc '{"method":"setup.skip","params":{"force":true},"id":1}'
tools/vphoned.sh POST /v1/rpc '{"method":"screen.unlock","params":{},"id":1}'
```

Then, on a new VM:

- **Set Auto-Lock to Never**: `python3 tools/auto-lock-never.py vms/myphone 3` (or Settings ›
  Display & Brightness › Auto-Lock). A new VM locks and turns the screen off after 60 s, and iOS
  then drops every touch (backboardd logs `ignoring touch event ((backlight dim/off))`): it looks
  as if touch is broken. `screen.unlock` wakes it. The tool sets it through ManagedConfiguration,
  as Settings does; profiled ignores that call from a vphoned without ManagedConfiguration's write
  entitlements (the release's has none, so `display.auto_lock.set` changed nothing), and `cfw
  install` now merges them in. On a VM installed before that, the tool re-signs the VM's vphoned
  and installs it in the guest first. The setting is kept across reboots.
- **Lower the display scale** (optional): a new VM draws at iOS's default 3x (1290x2796). With the
  VM running, `tools/set-scale.sh vms/myphone 1`, then start it again and run
  `python3 tools/guest-1x-logo.py 3` ([SETUP.md step 7](SETUP.md#7-make-it-faster-optional)). On the
  test host the Linux-made VM then booted at 1x to the home screen (vphoned at 68 s, unlocked at
  153 s).
