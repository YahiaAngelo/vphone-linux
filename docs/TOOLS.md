# Tools

Scripts in `tools/`. Most of them change to the repository root first, so you can run them from
anywhere. They need Python 3 (some need `python3-pillow`), `socat` and, for profiling, `perf`.

Common arguments:

- **`SOCK`**: a QMP Unix socket. Start the VM with `-qmp unix:$PWD/runs/qmp.sock,server,nowait`
  (`tools/boot-test.sh` does this for you, at `runs/RUN/qmp.sock`). QMP serves one client at a time.
- **`CID`**: the VM's vsock CID (`run-vphone.sh`'s `CID`, default 3). vphoned listens on port 1339.
- **`RUN`**: a run name. Output goes to `runs/RUN/` (`serial.log`, `stderr.log`, `qemu.log`,
  `qmp.sock`).
- **Coordinates** are guest pixels on the 1290x2796 grid, whatever `GFX_RES` is. QMP's absolute
  pointer is scaled to the display.

## Setup

| Script | Usage | What it does |
|---|---|---|
| `check-host.sh` | `tools/check-host.sh` | Checks this PC against the requirements in SETUP.md (CPU, RAM, `/dev/shm`, Vulkan GPU, `/dev/vhost-vsock`, `vm.max_map_count`, Rust, meson). Changes nothing. |
| `omarchy-window.sh` | `tools/omarchy-window.sh [--remove]` | Omarchy/Hyprland: adds a window rule (`~/.config/hypr/vphone-linux.lua`) so the iPhone window floats centred at its own shape instead of being tiled. `--remove` takes it out. |
| `import-vm.sh` | `tools/import-vm.sh SOURCE NAME` | Copies a vphone-cli VM (a local path or `user@mac:path` over ssh) into `vms/NAME`, sparse, writes its `ecid` file and keeps a `vms/NAME.pristine` copy. |

`../build.sh` builds the submodules and QEMU (see [SETUP.md](SETUP.md#3-build)).

## Running VMs for tests

| Tool | Usage | What it does |
|---|---|---|
| `boot-test.sh` | `VMDIR=vms/test tools/boot-test.sh RUN CID [qemu args]` | Boots `VMDIR/vm` with the GPU and a window (`WINDOW=0` for headless) and a QMP socket in `runs/RUN/`. Waits for vphoned, then retries `screen.unlock` until the guest unlocks. Prints `vphoned up t=...` and `unlocked t=...`, or `fatal`. First stops any VM a previous `boot-test.sh` started, and refuses to boot a `Disk.img` that another QEMU holds. Environment (`SMP`, `QEMU`, `VPHONE_*`, ...) passes through. Use a copy of your VM. |
| `stuck.sh` | `tools/stuck.sh VM_DIR SECONDS [qemu args]` | Boots with a gdb stub, waits, then prints every CPU's pc/sp/lr/cpsr, CPU 0's ELR/ESR/FAR and TTBRs, and the code around them. For boots that hang. |
| `firstfault.py` | `tools/firstfault.py VM_DIR [--after TEXT] [--n N] [--secs S] [--ctx L]` | Boots with `-d int,unimp` streamed through a FIFO and prints the exception log around the first N aborts or undefined instructions after a trigger line (default `Guarded Execution Enter`). Avoids multi-GB logs. |

## vphoned (guest daemon over vsock)

| Tool | Usage | What it does |
|---|---|---|
| `install-ipa.py` | `tools/install-ipa.py APP.ipa [--launch BUNDLE_ID] [--cid CID]` | Uploads an .ipa to the guest over vsock, installs it with `apps.install` (vphoned signs it in the guest) and optionally launches it. Works with an unsigned `xtool dev build --ipa`. |
| `app-logs.py` | `tools/app-logs.py PROCESS [--subsystem S] [--seconds N] [--cid CID] [--json]` | Prints an app's log lines from the running guest (vphoned `logs.syslog`), one per line; `--subsystem` keeps only the app's own `os.Logger` lines. See [APP-DEVELOPMENT.md](APP-DEVELOPMENT.md). |
| `vphoned.sh` | `tools/vphoned.sh [-c CID] METHOD PATH [JSON]` | One HTTP request to vphoned, e.g. `GET /v1/health`, or `POST /v1/rpc '{"method":"screen.unlock","params":{},"id":1}'`. Uses AF_VSOCK with a 4 MiB socket buffer, or the `uds` socket when `$VSOCK_DIR/$CID.sock` exists. Keeps its write side open, as vphoned requires. `VPHONED_TIMEOUT` (default 300 s). |
| `vphoned-update.sh` | `tools/vphoned-update.sh [-c CID] BINARY` | Replaces the guest's vphoned through its self-update: uploads to `/var/root/Library/Caches/vphoned.next`, then `agent.apply_update` with the SHA-256. The binary must be signed the way vphone-cli's `StageBundle.sh` signs it. Changes the VM's disk. |
| `guest-get.py` | `tools/guest-get.py CID GUEST_PATH LOCAL_PATH` | Downloads a file with `GET /v1/files/content`, streaming. On vhost-vsock this stops after 64 KiB; it works on a `VSOCK=uds` VM. |
| `guest-read.py` | `tools/guest-read.py CID GUEST_PATH LOCAL_PATH [SIZE]` | Downloads a file with the `files.read` RPC (base64 in JSON). Works on vhost-vsock. Default limit 512 MiB. |

## Input and screen (QMP)

| Tool | Usage | What it does |
|---|---|---|
| `qmp.py` | `tools/qmp.py SOCK shot OUT.png` · `tap X Y` · `swipe X0 Y0 X1 Y1 [MS [STEPS]]` · `home` · `key QCODE...` | Screenshot, tap, swipe (default 300 ms, 20 steps), Home (a middle click, which the touchscreen turns into Cmd+H) and key presses. |
| `screen-changed.py` | `tools/screen-changed.py SOCK save PATH` · `tools/screen-changed.py SOCK BEFORE.ppm` | Saves a PPM screendump, or exits 0 if the screen now differs clearly from `BEFORE`, else 1. Needs Pillow. |
| `set-scale.sh` | `tools/set-scale.sh VM-DIR 1\|2\|3` | Changes the screen scale in one step, with the VM running: sets it in the guest's device tree (`guest-dt-scale.py`), clears iOS's cached scale through vphoned, shuts the guest down, patches LLB (`display-scale.py`) and writes `gfx-res` from the VM's 3x size. iOS 27 does not go below 2x. |
| `auto-lock-never.py` | `tools/auto-lock-never.py VM-DIR [CID]` | Sets the running guest's Auto-Lock to Never through ManagedConfiguration (`script.eval`), as Settings does. Where profiled ignores it (a vphoned without ManagedConfiguration's write entitlements, installed before `cfw install` added them), re-signs the VM's `.vphoned.signed` with them, installs it with `vphoned-update.sh` and tries again. The setting survives reboots. |
| `guest-dt-scale.py` | `tools/guest-dt-scale.py CID [SCALE]` | Shows or sets the screen scale in a running guest's own device tree (`/product` `artwork-scale-factor`, which iOS 27 reads too), through vphoned; keeps the original in the guest and in `runs/guest-dt-scale/`. Takes effect from the next boot. See [ADVANCED.md](ADVANCED.md#display-scale). |
| `display-scale.py` | `tools/display-scale.py NVRAM [SCALE]` | Shows or sets iOS's screen scale by patching LLB in `nvram.bin` (`0` restores). Use it with a matching `gfx-res`. See [ADVANCED.md](ADVANCED.md#display-scale). Run it on a stopped VM, and keep a backup. |
| `guest-1x-logo.py` | `tools/guest-1x-logo.py CID` | At 1x, gives the guest 1x copies of its boot Apple logo (halved from its own @2x images in ProgressUI.framework), which iOS otherwise lacks, leaving the boot screen black. Remounts `/` writable through a one-shot launchd job first. Takes effect from the next boot. |

## Latency and frame-rate benchmarks

| Tool | Usage | What it does |
|---|---|---|
| `tap-latency.py` | `tools/tap-latency.py SOCK NAME X Y [NAME X Y ...]` | From the home screen, taps each icon and reports the seconds to the first screen change and to a settled screen, then goes Home. QMP only (no vphoned). Example apps on the default home screen: `Calendar 497 1015 Settings 1089 1953 Maps 200 1953 Photos 794 1015`. |
| `switch-latency.sh` | `tools/switch-latency.sh RUN CID BUNDLE_ID [URL]` | Asks vphoned to `apps.launch` a bundle and reports the time to the first screen change and when vphoned answered. Pass a URL (e.g. `calshow://`) to skip vphoned's slow running-apps listing. Screenshots go to `runs/RUN/sw-BUNDLE/`. |
| `scroll-bench.sh` | `tools/scroll-bench.sh RUN CID [boot-test args]` | Boots with `REIMS_VGPU_STATS=1`, waits, then runs `scroll-measure.sh`. |
| `scroll-measure.sh` | `tools/scroll-measure.sh RUN CID` | On a running VM (booted with `REIMS_VGPU_STATS=1` and `-name vphone,debug-threads=on`): opens Settings, warms it, scrolls for about 15 s, and prints frames/s per second, the average, the worst gap and the vCPU load. |
| `swipe-film.py` | `tools/swipe-film.py SOCK OUTDIR X0 Y0 X1 Y1 [SECONDS]` | Swipes and takes a PPM screendump every ~35-50 ms. Saves downscaled PNG frames and prints how much each differs from the previous and the last. Pair it with `VPHONE_TOUCH_TRACE=1`. |
| `perf-apps.sh` | `tools/perf-apps.sh RUN CID [boot-test args]` | Boots, records `perf` on QEMU for 40 s while opening four apps (Home after each), shuts down, and prints the DSO and symbol breakdown of vCPU threads. Output in `$PERF_OUT` (default `$TMPDIR/perf-apps`). |

## Profiling helpers

| Tool | Usage | What it does |
|---|---|---|
| `thread-cpu.py` | `tools/thread-cpu.py PID SECONDS [INTERVAL]` | Per-thread CPU (% of a core) every interval: total, each vCPU (`CPU n/TCG`), the busiest other threads. Needs `-name ...,debug-threads=on` for named vCPU threads. |
| `cpu-sample.py` | `tools/cpu-sample.py SOCK SECONDS [INTERVAL]` | Samples each AP vCPU's PC and exception level over QMP (`info registers -a`). Prints `I` (idle), `K<pc>` (kernel) or `U<pc>` (user) per CPU. Set `IDLE_PC` to this boot's idle-loop PC (the default is from one test boot; the kernel slides every boot). Biased: TCG updates the PC only at helper calls. |
| `dsc-symbolize.py` | `tools/dsc-symbolize.py SAMPLES CACHE_BASE [TOP]` | Attributes user-mode PCs (the `U<pc>` tokens of `cpu-sample.py`'s format) to shared-cache images and functions, using the guest's dyld shared cache copied to `dsc/`. `CACHE_BASE` is the cache's load address in this boot (`sharedCache.base` of a crash report). |
| `pin-threads.sh` | `tools/pin-threads.sh PID [show]` | Pins a running QEMU's threads: each vCPU thread (`CPU n/TCG`) alone on its own physical P-core, the GPU threads (`reims-vgpu.*`, `metal2vulkan*`) and QEMU's main thread on those cores' hyper-thread siblings, everything else on the E-cores. `show` prints the placement without applying it. The defaults are for an i7-14700K; override them with `VCPU_CORES` (space-separated, default `0 2 4 6 8 10 12 14`), `GPU_CPUS` (default `1,3,5,7,9,11,13,15`) and `OTHER_CPUS` (default `16-27`). Needs `-name ...,debug-threads=on`. Measured no difference on the Settings scroll; provided for experiments. |
| `jit-stats.py` | `tools/jit-stats.py SOCK SECONDS` | QEMU's JIT counters (`info jit`: code size, TBs, flushes, invalidations, partial TLB flushes) and their rates over an interval. |
| `perf-tlb-share.sh` | `tools/perf-tlb-share.sh PERF.DATA [TOP]` | Share of samples in softmmu TLB fill/page walk, TLB flush and memory slow-path symbols, plus the top symbols. Sums both PMUs of a hybrid CPU. |
| `validate-run.sh` | `tools/validate-run.sh RUN CID BUNDLE_ID` | Boots under the Khronos Vulkan validation layer (errors only, to `runs/RUN/validation.log`, with backtraces through `M2V_VALIDATION_BACKTRACE`), launches an app, and reports validation errors and NVIDIA Xid faults (`journalctl -k`). |

## vsock diagnostics

| Tool | Usage | What it does |
|---|---|---|
| `vsock-rings.py` | `tools/vsock-rings.py SOCK` | The vhost-vsock device's virtqueue layout (QEMU's view) and each ring's avail/used index from guest memory. Diagnoses a vsock that times out on every port (overlapping rings). |
| `vsock-boot-check.sh` | `tools/vsock-boot-check.sh N CID0` | N headless boots (`VMDIR` as for `boot-test.sh`). For each, whether vphoned answers, plus the ring layout. Uses CIDs `CID0`, `CID0+1`, ... |

## Firmware and recovery-mode USB (research)

| Tool | Usage | What it does |
|---|---|---|
| `im4p_payload.py` | `tools/im4p_payload.py IN.im4p OUT.bin` | Extracts an IM4P payload and LZFSE-decompresses it (needs `liblzfse`). For looking at firmware you extracted yourself. |
| `vusb-host.py` | `tools/vusb-host.py SOCK STEP...` | Talks to QEMU's `vresearch-vusb` device (the guest's USB device side in recovery/DFU mode) over its chardev, as the USB host would. Steps: `reset`, `setup:<8 hex bytes>`, `xfer:<ep>[:hex]`, `abort:<ep>`, `wait:<s>`. Experimental. |
| `vusb-usbip.py` | `tools/vusb-usbip.py SOCK` | Exports that device as a USB/IP server on 127.0.0.1:3240 (`usbip list -r 127.0.0.1`). Used by the Linux restore: DFU/recovery transfers are split into 512 bytes, the RestoreOS and SSH-ramdisk stages (05ac:12a8, 12ac) forward each URB whole with its zero-length packet. Experimental. |

Recovery mode: boot a scratch copy of the VM whose `Disk.img` is blank (`truncate -s 1G Disk.img`) with
`CID=0 ./run-vphone.sh DIR -chardev socket,id=vusb,path=$PWD/vusb.sock,server=on,wait=off -global vresearch-vusb.chardev=vusb`.
LLB then enters recovery mode and presents the USB device.

## Creating the VM on Linux

Used by [CREATE-ON-LINUX.md](CREATE-ON-LINUX.md). The ones marked "root" need sudo.

| Tool | Usage | What it does |
|---|---|---|
| `gpu-driver-from-cloudos.sh` | `tools/gpu-driver-from-cloudos.sh CLOUDOS.ipsw OUT-DIR` | Gets the GPU driver for `fw prepare --gpu-driver-bundle`: restores the stock cloudOS into a temporary VM over USB/IP, reads `AppleParavirtGPUMetalIOGPUFamily.bundle` from its System volume with 7-Zip, deletes the VM. |
| `new-vm.sh` | `tools/new-vm.sh VM-DIR [ECID]` | Makes an empty VM bundle for a Linux restore: `config.plist` (OpenAVB/OpenSEP, a machine identifier with a random or given ECID), `ecid`, `udid-prediction.txt`, the ROMs and empty sparse disk, NVRAM and SEP storage. |
| `dfu-up.sh` | `tools/dfu-up.sh VM-DIR RUN-DIR` | Starts the VM with QEMU (`qemu/build`, or `QEMU=`) and `vusb-usbip.py`: in DFU when `nvram.bin` holds no firmware, at iBoot's recovery prompt when it does and `auto-boot=false`. Stops any older exporter first. `GFX=1 WINDOW=1` opens the display window. Logs to `RUN-DIR`; refuses a disk another QEMU holds. |
| `dfu-stop.sh` | `tools/dfu-stop.sh VM-DIR` | Stops the VM that runs this VM directory's disk and its USB/IP exporter, between the creation steps. |
| `restore-tree-mode.sh` | `tools/restore-tree-mode.sh LIB VM ssh\|full` | Switches the restore tree between a full restore and the SSH ramdisk: ramdisk, trust cache, TXM pre-check patch, research restore kernel, and manifest digests over the retyped images. `full` puts the saved files back. No root. |
| `nvram-autoboot.py` | `tools/nvram-autoboot.py NVRAM [--auto-boot true\|false] [--dry-run]` | Edits the guest's NVRAM banks in `nvram.bin` (stopped VM): sets `auto-boot` and drops the restore's `boot-args`. `false` makes iBoot stop at recovery for the SSH ramdisk; `true` boots the installed system. |
| `build-usbmuxd-32k.sh` | `tools/build-usbmuxd-32k.sh` | Builds stock usbmuxd with a 32 KiB USB MTU into `.build/usbmuxd-32k/` (no autotools needed). |
| `usbmuxd-32k.sh` | `sudo tools/usbmuxd-32k.sh` | Root. Stops and runtime-masks the system usbmuxd and runs the 32 KiB one (pidfile `/run/usbmuxd-32k.pid`). |
| `usbip-autoattach.sh` | `sudo tools/usbip-autoattach.sh` | Root. Attaches whatever the local exporter offers whenever nothing is attached, so each restore stage is picked up. Also installs a runtime udev rule so the user can open the device in DFU/recovery mode. Ctrl-C to stop. |
| `dfu-diagnose.sh` | `tools/dfu-diagnose.sh [RUN-DIR]` | Read-only. When `recovery-probe` finds nothing: checks QEMU, the exporter, the attach loop, the attached Apple device and whether this user can open it. |
| `ssh-ramdisk-stage.sh` | `tools/ssh-ramdisk-stage.sh [OUT]` | Downloads SSHRD_Script's `ssh.tar.gz` (pinned commit, SHA-256 checked) and unpacks it as the SSH ramdisk's staging tree, `runs/sshramdisk/ssh-root`, minus the files the ramdisk does not need. No root. |
| `ssh-ramdisk-inject.sh` | `sudo tools/ssh-ramdisk-inject.sh` | Root. Adds the SSH tools (dropbear and friends) to the extracted cloudOS restore ramdisk. |
| `ssh-ramdisk-repack.sh` | `tools/ssh-ramdisk-repack.sh [STOCK.dmg] [PAYLOAD] [OUT.dmg]` | Puts the modified APFS payload back into the stock `rdsk` IM4P wrapper. |
| `ssh-ramdisk-rebuild-signed.sh` | `tools/ssh-ramdisk-rebuild-signed.sh LIB VM` | Builds the SSH ramdisk: the VM's stock restore ramdisk with the staging tree injected (`ssh-ramdisk-inject.sh`, root, once) and repacked (`ssh-ramdisk-repack.sh`), into `runs/sshramdisk/out/`. |
| `ssh-ramdisk-trustcache.py` | `tools/ssh-ramdisk-trustcache.py STOCK.rtsc SSH-TREE OUT.rtsc` | Builds the ramdisk's trust cache: the stock entries plus the cdhash of every Mach-O in the SSH tree, sorted. |
| `ssh-ramdisk.sh` | `tools/ssh-ramdisk.sh 'CMD'` | Runs a command on the booted SSH ramdisk as root, through usbmuxd. |
| `usbmux-connect.py` | `tools/usbmux-connect.py proxy PORT` | A small iproxy: connects stdin/stdout to a device port through usbmuxd (the ssh ProxyCommand). |
| `sshfs-remote-sftp.sh` | sshfs `-o ssh_command=tools/sshfs-remote-sftp.sh` | Runs `/usr/libexec/sftp-server` as a command, because the ramdisk's dropbear has no SFTP subsystem. `cfw install` uses it. |
