# Performance

The guest's arm64e code runs under QEMU's TCG, so speed comes down to three things:

- how fast translated code runs and finds its next block;
- how much work the guest asks for;
- how quickly the host GPU answers the guest's frames.

This page lists what was measured, what changed, every switch, and how to profile.

All numbers are from one host (i7-14700K, RTX 4080 SUPER, Fedora 44) with an iOS 26.6.2 guest on
8 vCPUs, measured during development. Other VMs and agents were often running on the host at the same
time, so treat them as indications, not benchmarks.

## Where the time goes

- **Indirect-branch lookups.** arm64e calls and returns are indirect branches (`BLRAA`, `RETAB`, ...).
  Every one of them ends a translated block in a lookup of the next one. Before the work below, these
  lookups took about a third of vCPU time (about 27 million per second during app launches).
  `VPHONE_LOOKUP_STATS=1` splits them by cause. In an app workload: returns 38.5%, direct branches to
  another page 34.8%, `BRAA`/`BR` 21%, `BLRAA` and similar 5%.
- **Softmmu TLB refills and page walks.** These took 15-25% of vCPU time. XNU issues ranged and
  broadcast TLB invalidations constantly (about 6-7 thousand TLB flushes per second at context
  switches), and QEMU turned most range flushes into full flushes.
- **Translation** took about 5-10%. It is quiet at idle. With QEMU's default 1 GiB code cache, normal
  use filled the cache and flushed it every few minutes (hence `TB_SIZE=2048`).
- **Guest work.** With iOS's default services, all 8 vCPUs were about 80% busy at rest. A split taken
  while paging the home screen: QEMU itself 60%, the guest kernel 15%, guest user code 24% (mostly
  SpringBoard and backboardd).
- **Serial app launches.** An app launch keeps only 2-3 of the 8 vCPUs busy: it is a serial chain
  running at TCG's single-thread speed.

## What was changed

### TCG (qemu-vphone, branch `vphone`)

Most changes have a switch, so each can be turned off for an A/B comparison.

| Change | Switch | Measured effect |
|---|---|---|
| Keep the jump cache across TLB flushes, and make it larger (from the upstream base) | | |
| **16 KiB target pages** and a **page-count range-flush check** | `VPHONE_TARGET_PAGE_BITS=14`, `VPHONE_TLB_RANGE_PAGES=1` | TLB fill/walk share of boot CPU 18% → 9.6%. Fills to unlock 1.3 → 0.59 billion. Range flushes escalated to full flushes 70M → 1.8M. Boot to vphoned 15-25 s faster, warm app switches 10-20% faster |
| Jump cache indexed by instruction within a page (A64's 4-byte alignment had left 16 of 64 slots per page usable) | | Conflict misses 13.5% → 4.9%, hash-table lookups 13.8% → 5.1% |
| Jump cache entries hold the TB's keys and code pointer: one cache line per hit | | Lookup group 36% → 33% |
| Lookup statistics (diagnostic) | `VPHONE_LOOKUP_STATS` | |
| **Checked cross-page links**: a direct `B`/`BL` to another page chains directly while the destination still maps to the same host address in the vCPU's softmmu TLB | `VPHONE_XPAGE_LINKS` | Lookups −34%. Guest code 29.6% → 34.8% of vCPU time |
| TB lookup state passed by pointer (a 16-byte copy stalled store forwarding) | | `helper_lookup_tb_ptr` 5.7% → 3.1% |
| A flushed page's jump cache entries are marked stale (an older generation), not emptied | | `qht_lookup_custom` 3.9% → 2.4% |
| USB HID: no unchanged reports at the guest's 24 ms idle rate | | About 1/5 vCPU less at rest (backboardd and the HID driver) |
| Range flushes past 4 pages bump the jump cache generation instead of marking each page | `VPHONE_JC_RANGE_PAGES` (default 4) | Marking loop 4.1% → 1.2% of vCPU time |
| `apple-gxf` no longer advertises BTI (no Apple core has it) | | Guarded-page checks (about 1.3%) gone |
| **Jump cache lookup at `BR`/`BLR`/`RET`** without the generic lookup helper: `1` inline in the generated code, `2` the same check in `helper_vphone_lookup_fast` with the TB's flags as constants (smaller code: 322 instead of 346 host bytes per TB) | `VPHONE_INLINE_LOOKUP` (default 2) | Guest code 42% → 50% of vCPU time; `tb_lookup_ptr` 10.2% → 3.4%; `helper_lookup_tb_ptr` 4.3% → 1.0% |
| **Return-address prefetch**: at each call, the generated code loads the return address's jump cache entry, so the return's lookup does not stall on a cache miss (38% of that lookup's time had been this miss). `2` inline, `1` through a helper, `0` off | `VPHONE_RET_PREFETCH` (launcher default 2) | QEMU's share of vCPU time while paging the home screen 47.8% → 44.6% |
| **Larger minimum TLB size**: `CPU_TLB_DYN_MIN_BITS` raised from 6 to 10 (compile time). The softmmu TLBs no longer shrink to 64 entries under iOS's constant flushes. 12 made boot 13% slower | | QEMU's share of vCPU time 44.6% → 43.0% |
| **2 GiB code cache** (x86-64's maximum). iOS's boot alone generates about 5 GB of translated code. With 1 GiB the cache filled every ~3.5 minutes of use (14 full flushes in 49 minutes), and each flush retranslates everything the guest runs next | `TB_SIZE` (launcher, MiB, default 2048) | |
| **Neon float32 on the host's SIMD**: `FADD`/`FSUB`/`FMUL`/`FMLA`/`FMLS` (vector and by element) compute all lanes with SSE/FMA when the result is exactly softfloat's (inexact already raised, round to nearest, inputs zero or normal, results finite and not tiny); any other vector takes the per-lane path. Checked against softfloat by `tests/fp/vphone-f32-fast.c` in the QEMU fork | `VPHONE_FAST_F32` (default on, `0` off) | iOS 27 (iPhone Duo), app switching: floating point 11.1% → 5.7% of QEMU's time |

Tried, and left off by default:

- **`QEMU_TLB_UNSYNCED`** (relaxed broadcast TLB flushes). Six app-switch sweeps per mode gave the same
  latencies within noise. Settings scrolling: 31.4 vs 30.5 frames/s. The synced flush is not the
  bottleneck.
- **Pinning to P-cores** (`VPHONE_CPUS`): no measurable change in an A/B. It stays on, because a TCG
  thread on an E-core is slower.
- **Pinning each thread** (`tools/pin-threads.sh`: one vCPU per physical P-core, GPU threads on the
  siblings, the rest on E-cores): no difference on the Settings scroll. It is kept for experiments.

Next candidates, from the profiles: a per-vCPU return-address stack checked at `RET`; indirect `BRAA`/`BR`
jumps; an ASID-tagged softmmu TLB, so a context switch costs no full flush.

### Guest settings

See [ADVANCED.md](ADVANCED.md#background-services):

- **Disabling background services** cut idle guest CPU from 92-104 to 32 CPU-seconds per 20 s.
  Before that, SpringBoard was starved: 0 frames during swipes, and widget renderers killed by
  FrontBoard's watchdog.
- **Display scale** ([ADVANCED.md](ADVANCED.md#display-scale)): 2x needs 2.25x fewer pixels than 3x,
  and 1x about 9x fewer. In Settings scrolling the frame rate barely changed (36.6 → 37.9 frames/s
  average, 56 → 66 peak), but vCPU load fell from 50-60% to 40%.
- **A 1x width that is a multiple of 32** (`448x932`, not `430x932`; `ALIGN32=1 tools/set-scale.sh`), at the cost of the device's own layout: iOS picks it by the exact point size (see [ADVANCED.md](ADVANCED.md#display-scale)). NVIDIA's linear images need
  128-byte rows. At 430 pixels (1720-byte rows) iOS's full-screen surfaces were shadow-copied in and
  out, about 10 screens per frame; at 448 they are aliased. Copies fell from about 246 million to
  1.3 million texels per 30 s at idle.
- **Reduce Motion** and **Reduce Transparency**.

### Host GPU

- **Lock the GPU and memory clocks** ([ADVANCED.md](ADVANCED.md#host-gpu-clocks)), again after every
  host reboot. The bursty load otherwise keeps the GPU at idle clocks (210 MHz). Guest GPU work went
  from 420 µs to 140 µs (median), and the window's draw from about 3 ms (2960 µs) to 388 µs.
- The metal2vulkan fork keeps 256 released pipeline variants instead of 16 (`M2V_KEPT_PIPELINES`).
  With 16, paging between two home-screen pages created 231 `VkPipeline`s and 244 shader modules in
  26 s.

Open on the GPU side:

- **Icon churn.** SpringBoard deletes and recreates about 300 GPU resources per home-page swipe. Each
  delete waits behind the task queue's encodes (p90 3.4 ms).
- **Shadowed textures.** IOSurfaces whose rows are not a multiple of 128 bytes are still shadow-copied
  in and out on each use. At 1x with a 448-pixel width, the full-screen surfaces no longer are.
- **Shader compiles.** iOS's Metal binary archives have no AIR slice for the paravirtual GPU, so
  shaders are compiled on first use in each boot: 12-113 ms each. They are cached within a boot.

### Current state

Settings scrolling now runs at about 60-68 frames/s on average (about 37 before the TCG work above),
with occasional 50-110 ms stalls: guest CPU work at emulated speed.

Where vCPU time goes while scrolling Settings (per guest process, from the recipe in
[Per-process profiles](#per-process-profiles)): the Settings app about 35%, backboardd about 23%,
SpringBoard about 6%, MTLCompilerService about 4%. In every process roughly half of the time is QEMU
overhead (lookups, TLB refills, helpers) rather than translated guest code.

### Earlier end-to-end measurements

Taken before the latest TCG changes:

- Boot: vphoned up after 66-107 s, unlocked after 186-282 s.
- App switch, from vphoned's `apps.launch` with a URL to the first screen change: Calendar 13.6 s cold
  and 4.8 s warm; Maps 7.1 s cold and 1.7 s warm.
- App open from a tap: about 19-20 s cold (Calendar, Photos), 4-8 s warm.

Not yet measured on the pinned commits: boot and app-launch times (`tools/perf-apps.sh`,
`tools/tap-latency.py`).

## Launcher switches

Environment variables read by `run-vphone.sh`:

| Variable | Default | What it does |
|---|---|---|
| `QEMU` | `./qemu/build/qemu-system-aarch64` | QEMU binary |
| `SMP` | `8` | AP vCPUs. The launcher passes `maxcpus=SMP+1` for the SEP core |
| `MEM` | `8G` | Guest RAM |
| `TB_SIZE` | `2048` | TCG code cache in MiB (`-accel tcg,tb-size=`). 2048 is x86-64's maximum; QEMU's default 1 GiB flushed every few minutes |
| `GFX` | `0` | `1` attaches the paravirtual GPU (`apple-gfx-mmio` on reims-vgpu) |
| `WINDOW` | `0` | `1` opens reims-vgpu's window (sets `REIMS_VGPU_WINDOW`) |
| `GFX_RES` | the VM's `gfx-res` file, else `1290x2796` | Framebuffer size (`apple-gfx-mmio.resolution`). At 1x `430x932` (`448x932` with the width a multiple of 32: fewer GPU copies, generic layout) |
| `GFX_MODES` | `$GFX_RES@60` | Display modes offered to the guest (machine `gfx-modes`, `/`-separated) |
| `GFX_ISOLATION` | `on` | `apple-gfx-mmio.process-isolation`: per-task GPU processes. Keep it on |
| `REIMS_VGPU_WINDOW_TITLE` | `vphone-linux` | Title of reims-vgpu's window |
| `VK_DRIVER_FILES` | NVIDIA's ICD if present | Vulkan ICD for QEMU and every GPU task process |
| `REIMS_VGPU_CENSUS_DIR` | `runs/census` | Census mode (see below). Empty restores fatal degradations |
| `VPHONE_TARGET_PAGE_BITS` | `14` | QEMU's target page size, 12..16. 14 = 16 KiB, iOS's granule |
| `VPHONE_TLB_RANGE_PAGES` | `1` | Range flushes compare page count with TLB entry count. `0` = upstream |
| `VPHONE_XPAGE_LINKS` | `1` | Checked cross-page direct-branch links |
| `VPHONE_RET_PREFETCH` | `2` | Return-address jump cache prefetch at calls: `2` inline, `1` through a helper, `0` off |
| `VPHONE_XHCI_NONREMOVABLE` | `0x1fe` | Bit n marks xHCI root port n non-removable. Needed for touch |
| `VPHONE_CPUS` | `/sys/devices/cpu_core/cpus` (P-cores), if present | `taskset` CPU list for QEMU. Empty = no pinning |
| `CID` | `3` | vsock guest CID, unique per running VM. `0` = no vsock |
| `VSOCK` | `vhost` | `vhost` (kernel vhost-vsock), `uds` (`virtio-vsock-uds-pci`, branch `vsock-uds`), `auto` |
| `VSOCK_DIR` | `/tmp/vphone-vsock` | Directory of the `uds` sockets (`$CID.sock`) |
| `LOG` | | QEMU log file (`-D`) |
| `DFLAGS` | | QEMU log items (`-d`), e.g. `guest_errors,unimp` |
| `TRACE` | | QEMU trace pattern (`-trace`) |
| `GDB` | | Port: start halted and wait for gdb |

## QEMU switches (fork, environment)

Each switch is read once per process. "Code default" is what QEMU does when the variable is unset;
the launcher overrides some of them (above).

| Variable | Code default | What it does | Source |
|---|---|---|---|
| `VPHONE_TARGET_PAGE_BITS` | 12 | Target page size of `vresearch101` (12..16). Fixed before machine options are parsed, hence an env var | `hw/vmapple/vresearch101.c` |
| `VPHONE_TLB_RANGE_PAGES` | off | Page-count range-flush check | `accel/tcg/cputlb.c` |
| `VPHONE_JC_RANGE_PAGES` | 4 | Range flushes longer than this many pages bump the jump cache generation instead of clearing per page | `accel/tcg/cputlb.c` |
| `QEMU_TLB_UNSYNCED` | 0 | Broadcast TLB flush mode: 0 synced (upstream), 1 fully async, 2 barrier (flush, then wait up to 1 ms for the others). Relaxed modes are experimental | `accel/tcg/cputlb.c` |
| `VPHONE_XPAGE_LINKS` | off | Checked cross-page links | `target/arm/tcg/translate-a64.c` |
| `VPHONE_RET_PREFETCH` | off | Return-address prefetch at calls: `2` inline, `1` through a helper, `0` off (the launcher sets 2) | `target/arm/tcg/translate-a64.c` |
| `VPHONE_FAST_F32` | on | Neon float32 add/sub/mul/fused multiply-add on the host's SIMD; `0` = softfloat lane by lane | `target/arm/tcg/vec-f32-fast.h` |
| `VPHONE_INLINE_LOOKUP` | **2** | Jump cache lookup at `BR`/`BLR`/`RET`: `0` off (generic lookup), `1` inline check in generated code, `2` the same check in `helper_vphone_lookup_fast` with the TB's flags as constants (smaller code) | `target/arm/tcg/translate-a64.c` |
| `VPHONE_LOOKUP_STATS` | off | Diagnostic: counts why A64 code ends in a TB lookup | `target/arm/tcg/translate-a64.c` |
| `VPHONE_ASID_TRACE` | unset | Diagnostic: file that receives one line per TTBR0 ASID change on each vCPU (`CLOCK_MONOTONIC` ns, cpu, asid, ttbr0), to attribute host `perf` samples to guest processes ([Per-process profiles](#per-process-profiles)) | `target/arm/helper.c` |
| `VPHONE_EXCL_STATS` | off | Diagnostic: exclusive sections per second and their wall time (temporary) | `cpu-common.c` |
| `VPHONE_XHCI_NONREMOVABLE` | 0 | Non-removable root ports (bit mask) | `hw/usb/hcd-xhci.c` |
| `VPHONE_TOUCH_HOME` | on | Bottom-edge swipe or middle click sends Cmd+H. `0` disables | `hw/usb/dev-hid.c` |
| `VPHONE_TOUCH_TRACE` | off | Diagnostic: each touch report with a `CLOCK_BOOTTIME` stamp on stderr (temporary) | `hw/usb/dev-hid.c` |
| `VPHONE_VSOCK_DEBUG` | off | Branch `vsock-uds` only: `1` logs vsock control packets, `2` also data packets | `hw/virtio/virtio-vsock-uds.c` |

Compile-time change: `CPU_TLB_DYN_MIN_BITS` is 10 instead of QEMU's 6, so a vCPU's softmmu TLB never
shrinks below 1024 entries.

QEMU device and machine properties: `-M vresearch101,ecid=,serial=,sep-rom=,gfx-device=,gfx-modes=,memory-backend=`;
`apple-gfx-mmio.resolution`, `apple-gfx-mmio.process-isolation`; `virtio-vsock-uds-pci.credit-request`
(default on); `usb-hub.nonremovable` (bit mask).

## reims-vgpu switches

| Variable | Default | What it does |
|---|---|---|
| `REIMS_VGPU_LOG` | unset (silent) | Log to stderr: a level (`off`, `error`, `warn`, `info`, `debug`, `trace`), optionally followed by `,target=level` pairs |
| `REIMS_VGPU_STATS` | off | Every second, per display: guest frames/s and longest gap, window frames/s, window GPU time (`reims-vgpu stats: ...` on stderr) |
| `REIMS_VGPU_TRACE` | unset | File for a timeline of the device's work (`<ns> <thread> <kind> <values>`): command-buffer commit (`cbdone`), submit start and end, GPU start and end |
| `REIMS_VGPU_TRACE_DEGRADE` | off | With `REIMS_VGPU_TRACE`: write every occurrence of every degradation to the trace |
| `REIMS_VGPU_WORK_COUNTS` | off | vphone diagnostic: each second, the metal2vulkan work counters that changed, per device (`reims-vgpu work ...`) |
| `REIMS_VGPU_CENSUS_DIR` | unset (launcher: `runs/census`) | Census mode: degradations on reims-vgpu's fatal list are recorded in `<dir>/census-<pid>.json` and relayed instead of killing the process. The run is then not faithful to Metal |
| `REIMS_VGPU_STRICT` | off | `1`: die at any difference from Metal's answer instead of relaying it |
| `REIMS_VGPU_EXACT` | unset | Comma-separated device policies to make exact (`sampling`, `ycbcr_filter`, `float_maths`, `texel_conversion`, `half_rounding`, `nan_and_min_max`, ..., or `all`). Costs speed |
| `REIMS_VGPU_DUMP_IR` | unset | Directory: write refused shader IR there |
| `REIMS_VGPU_WINDOW` | on, when QEMU has `-display none` (the launcher sets `0` unless `WINDOW=1`) | Read by QEMU's `apple-gfx`: open reims-vgpu's window |
| `REIMS_VGPU_WINDOW_TITLE` | `Reims vGPU` (launcher: `vphone-linux`) | Window title (vphone addition) |
| `REIMS_VGPU_WINDOW_BORDERLESS` | off | Borderless window that fills its screen |
| `REIMS_VGPU_WINDOW_SCREENS` | display i on screen i | Comma-separated host screen indices |
| `REIMS_VGPU_WINDOW_REFRESH` | screen's highest | Refresh rate (Hz) of the modes offered to the guest |

reims-vgpu's own documentation (`reims-vgpu/docs/`) describes its other variables, which are used by
its tests and by `reims-ctl`.

## metal2vulkan switches

| Variable | Default | What it does |
|---|---|---|
| `M2V_KEPT_PIPELINES` | 256 (vphone; upstream 16) | Released pipeline variant instances kept for reuse |
| `M2V_VALIDATION_BACKTRACE` | unset | File: a backtrace for each Vulkan validation message from the runtime's debug messenger (used by `tools/validate-run.sh`) |

The other `M2V_*` variables in metal2vulkan are for its test harness.

## Profiling

### perf on QEMU

Profile one VM, attaching to the QEMU process itself (not to a `timeout` wrapper), during a fixed
workload. Name the threads so that vCPU threads can be separated:

```sh
GFX=1 ./run-vphone.sh vms/myphone -name vphone,debug-threads=on -qmp unix:$PWD/runs/qmp.sock,server,nowait
perf record -F 999 -g -p $(pgrep -x qemu-system-aar) -o qemu.perf -- sleep 40
perf report -i qemu.perf --no-children --comms "CPU 0/TCG,CPU 1/TCG,..." --sort symbol
```

`tools/perf-apps.sh RUN CID` does this end to end: it boots, records 40 s while opening Calendar,
Settings, Maps and Photos, then prints the top DSOs (translated guest code is its own DSO, which gives the guest-code share) and the top symbols.
`tools/perf-tlb-share.sh perf.data` sums the TLB fill/walk, flush and memory-slowpath shares. It adds up
both PMUs of a hybrid CPU.

### Guest code: perfmap and the shared cache

To attribute samples inside translated code to guest addresses, boot with QEMU's `-perfmap`. QEMU
writes `/tmp/perf-<pid>.map` (gigabytes: delete it afterwards), and `perf report -n --sort sym` then
shows `guest-0x...` symbols. Guest **user** PCs can then be named with `tools/dsc-symbolize.py`:

1. Copy the guest's dyld shared cache into `dsc/` (for example with `tools/guest-read.py`, or
   `tools/guest-get.py` on a `VSOCK=uds` VM). `dsc/` holds Apple binaries: it is in `.gitignore`;
   never publish it. Not yet documented: the guest path of the cache on iOS 26.
2. Find the cache's load address in this boot: make a process crash with a report (for example
   `processes.kill {"pid": ..., "signal": "QUIT", "force": true}` on weatherd) and read
   `sharedCache.base` from `logs.crashes`.
3. Write the samples one per line as `<time> U<hex pc> ...` (the format `tools/cpu-sample.py`
   prints) and run `tools/dsc-symbolize.py SAMPLES CACHE_BASE [TOP]`.

`tools/cpu-sample.py SOCK SECONDS` samples each vCPU's PC and exception level over QMP. It is quick,
but biased: TCG updates the PC only at helper calls. Prefer perfmap for real profiles.

### Per-process profiles

`VPHONE_ASID_TRACE` logs which guest address space (TTBR0 ASID) each vCPU runs, with
`CLOCK_MONOTONIC` timestamps, so host `perf` samples can be attributed to guest processes:

1. Boot with `-perfmap` and the trace, with named threads:

   ```sh
   VPHONE_ASID_TRACE=runs/asid.log GFX=1 ./run-vphone.sh vms/myphone \
     -perfmap -name vphone,debug-threads=on -qmp unix:$PWD/runs/qmp.sock,server,nowait
   ```

2. Record with the same clock during the workload:
   `perf record -k mono -F 999 -p $(pgrep -x qemu-system-aar) -o qemu.perf -- sleep 30`.
3. Dump the samples: `perf script -i qemu.perf -F tid,comm,time,ip,sym --ns`.
4. Tag each `CPU n/TCG` sample with the last ASID that vCPU switched to before the sample's time in
   the trace.
5. Symbolize the user PCs (the `guest-0x...` symbols of perfmap) with `tools/dsc-symbolize.py`, as
   above.

`/tmp/perf-<pid>.map` can grow to several GB over a long run: delete it afterwards.

### Timeline and frame tools

- `REIMS_VGPU_STATS=1`: per-second frame rate and longest gap, guest and window.
  `tools/scroll-bench.sh` and `tools/scroll-measure.sh` use it on a fixed Settings scroll.
- `REIMS_VGPU_TRACE=<file>`: commit, submit and GPU start/end per command buffer. Use it to see whether
  frames wait for the GPU.
- `REIMS_VGPU_WORK_COUNTS=1`: what metal2vulkan did each second (pipelines made, imports, copies).
- `VPHONE_EXCL_STATS=1`: how often all vCPUs are stopped for an exclusive section (about 9-14 thousand
  per second even at idle, from broadcast TLB invalidations).
- `VPHONE_TOUCH_TRACE=1` together with `tools/swipe-film.py`: input-to-photon timing of a swipe.
- `tools/thread-cpu.py PID SECONDS`: CPU per thread (vCPUs and the busiest others).
- `tools/jit-stats.py SOCK SECONDS`: rates of QEMU's JIT counters (translations, flushes).
- `tools/tap-latency.py` and `tools/switch-latency.sh`: time from a tap or an `apps.launch` to the first
  screen change and to a settled screen.

Measurement tips:

- Screenshots taken during timing must be PPM: QMP `screendump` runs under QEMU's global lock, and PNG
  compression there throttles every vCPU.
- Wait a few minutes after boot before measuring. Post-boot work (indexing, first-launch daemons) runs
  for minutes.
- Use one VM at a time, and note the host load.
