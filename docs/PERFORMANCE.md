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
| **Return-address stack**: each call pushes its return address and the block that call site last returned to on a 32-entry ring per vCPU; a `RET`/`RETAA`/`RETAB` whose target is the top entry jumps straight to that block, without the jump cache lookup, when the block is still valid (a per-vCPU stamp that every jump-cache generation, epoch, ASID switch and flush changes; not invalidated; same flags). Any other return takes the lookup. Checked by `tests/tcg/vphone-ras/` in the QEMU fork | `VPHONE_RAS` (default on, `0` off; `VPHONE_RAS_STATS=1` logs hit rates) | iOS 27 Duo, boot to unlock: 98.6% of returns hit. Under guestbench, QEMU's share of vCPU time 44.4% → 35.0% (`helper_vphone_lookup_fast` 9.6% → 5.4%, qht 2.5% → 0.5%); guestbench 4-9% faster at equal guest load; app switches and unlock (155-160 vs 159-166 s) no slower |
| **Cross-page link refill**: when a checked cross-page link misses because an address-space switch emptied the destination's code TLB entry, the slow way refills that entry from the jump cache, so the link hits again next time | `VPHONE_XPAGE_REFILL` (default on) | Cross-page slow ways 6.5% → 1.3% of lookups (guestbench), 10.3% → 2.3% (app switching) |
| **Indirect-branch cache**: each `BR`/`BLR`/`BRAA`/`BLRAA` (and zero-modifier forms) site keeps the block it last went to and jumps there when the target's code TLB entry still maps to that block's host address, the block is valid and its keys match; a valid slot is replaced only on every 8th miss to another target. Not used on cores with BTI. Checked by `tests/tcg/vphone-ibc/` | `VPHONE_IBC` (default on), `VPHONE_IBC_REPLACE` | 83-88% hit rate. With the refill: host cycles −2.7% ±1.2 at equal guest load (branchy phase −13%), lookup functions 11.3% → 6.1% of vCPU time |
| **DC ZVA in generated code**: the iOS kernel zero-fills every new page with `DC ZVA` (about 4.4M/s); it now writes the zeros through the normal store fast path instead of two C helpers, with the same fault address. Checked by `tests/tcg/vphone-zva/` | `VPHONE_INLINE_ZVA` (default on) | Host cycles −3.7% ±0.8, mmap phase −14% |
| **Acquire/release fences on x86 hosts**: upstream puts a fence before every release store and after every acquire load, which still lets `STLR;LDAR` reorder (a 2-vCPU litmus test saw forbidden outcomes in 1-6% of runs). Now one fence after each release store: about 20× fewer fences and no forbidden outcome. Checked by `tests/tcg/vphone-fence/` | `VPHONE_FENCE` (default 1, `0` upstream) | Correctness fix; speed within noise (−0.9% ±1.1) |
| **Larger minimum TLB size**: `CPU_TLB_DYN_MIN_BITS` raised from 6 to 10 (compile time). The softmmu TLBs no longer shrink to 64 entries under iOS's constant flushes. 12 made boot 13% slower | | QEMU's share of vCPU time 44.6% → 43.0% |
| **2 GiB code cache** (x86-64's maximum). iOS's boot alone generates about 5 GB of translated code. With 1 GiB the cache filled every ~3.5 minutes of use (14 full flushes in 49 minutes), and each flush retranslates everything the guest runs next | `TB_SIZE` (launcher, MiB, default 2048) | |
| **Neon float32 on the host's SIMD**: `FADD`/`FSUB`/`FMUL`/`FMLA`/`FMLS` (vector and by element) compute all lanes with SSE/FMA when the result is exactly softfloat's (inexact already raised, round to nearest, inputs zero or normal, results finite and not tiny); any other vector takes the per-lane path. Checked against softfloat by `tests/fp/vphone-f32-fast.c` in the QEMU fork | `VPHONE_FAST_F32` (default on, `0` off) | iOS 27 (iPhone Duo), app switching: floating point 11.1% → 5.7% of QEMU's time |
| **Native A64 floating point and Neon** (ported from Inferno `2eed395`): FP and Neon float instructions are emitted as host SSE/AVX/FMA instructions in the generated code, with the host's MXCSR following FPCR (rounding, flags folded into FPSR). Each op falls back to the helper where x86 and Arm can differ (NaN results, minimum-normal results, unordered min/max, out-of-range conversions), and the whole path is off while FPCR.FZ/AH/FIZ/NEP are set. Checked against the helper path by `tests/fp/vphone-native-fp` in the QEMU fork (644 forms × 22 FPCR settings, results and FPSR) | `VPHONE_NATIVE_FP` (default on, `0` off) | iOS 27 app switching: FP helpers 7.6% → 0.6% of QEMU's time; a mixed FP/Neon guest loop 5.7× faster |
| **No TLB flush on unchanged SPRR writes**: iOS 27 writes the Apple SPRR permission registers thousands of times a second, mostly with the value already held, and each write flushed every TLB of the vCPU (about 30% of all TLB flushes). Only a change of permissions needs the flush | | iPhone Duo guest benchmark (`tools/guestbench`, fresh boots): 6.62 s → 5.85 s |
| **Tile functions over extended-range attachments** (metal2vulkan): a tile function may now read and write a `BGR10_XR`, `BGRA10_XR` or `RGB10A8_2P_XR10` attachment, which its staging decodes to the `half` values Metal's tile memory holds and encodes back. iOS 27's lock-screen poster renderer (`MercuryPosterExt`) downsamples its wallpaper this way; its refused pipeline made it retry about 20 times a second | | `MercuryPosterExt` from about 92% of a guest CPU to none; an idle iPhone Duo guest from about 3 busy CPUs to about 1.1 |
| **Jump cache generations per address space and per bucket**: every TLB flush used to mark the whole jump cache stale, so each entry had to be checked against the TLB again, and an ASID switch (about 550 a second per vCPU) is such a flush. Now an ASID switch only changes the address space: entries filled under an ASID are current again when it returns, unless a TLB invalidation came in between. A page flush starts a new generation of the page's bucket (one store) instead of marking its entries, so range flushes up to 512 pages no longer reset the cache | `VPHONE_JC_RANGE_PAGES` (default now 512) | Stale rechecks 52% → 37% of slow lookups. iPhone Duo guest benchmark: 5.87 s → 4.76 s (−19%); boot to unlock about 205 s → 182 s |
| **Broadcast TLB flushes as a barrier**: XNU broadcasts TLB invalidations (`TLBI ...IS`) thousands of times a second, and QEMU synchronized each one with an exclusive section, which stops every vCPU (43-74 ms of every second under load, invisible to CPU profiles). Now each vCPU flushes its own TLB from its work queue and the source waits for them; only when one is late (1 ms) or another exclusive section is pending does it fall back on the exclusive section. The old barrier mode gave up instead of falling back, and on iOS 27 that let vCPUs run with stale TLB entries (a boot that never drew its UI) | `QEMU_TLB_UNSYNCED` (launcher default 2; 0 = an exclusive section per flush), `VPHONE_TLB_BARRIER_US` | iPhone Duo guest benchmark: 5.38 s → 4.81 s; boot to unlock 189-197 s → 171-187 s |
| The barrier waits only for vCPUs that are running guest code: a halted or stopped vCPU runs its queued flush before it runs guest code again, so waking it and waiting for it only cost time (at rest, 7% of backboardd's time was this wait) | | Barrier wait at rest 3.6% → 0.95% of QEMU's time; guest benchmark unchanged at low load, up to 15% faster with a busy guest |
| **Invalidating code no longer empties every jump cache**: ARM64 translations are position-independent, so when the guest reused memory that held code, QEMU emptied every vCPU's whole jump cache (131,072 entries each) to drop the stale translation: 8.3% of QEMU's time while switching apps. Now each vCPU starts a new jump cache epoch at its next lookup, and an older entry is used again only after its translation has been checked to be still valid | `VPHONE_JC_LAZY_INVAL` (default on; 0 = empty the caches) | iPhone Duo app switching, 3 fresh boots each: first Calendar launch 22.6 / 42.9 / timed out s → 12.7 / 19.6 / 17.4 s; time over the switches 258-374 s → 238 s |

Tried, and left off by default:

- **WFE that waits** (Inferno `a5620ce`, ported on the fork's `vphone-wfe` branch): WFE halts the vCPU until
  SEV, an interrupt, the event stream or a store to the monitored address. On this 28-thread host with 8
  vCPUs it saved nothing: idle QEMU CPU 731 s vs 684 s per 120 s with it off, 60% more context switches.
  The guest's busy vCPUs are background work, not lock spinning. Its statistics (`VPHONE_WFE_STATS=1`,
  fork branch `vphone-wfe2`) say why: an iOS 27 guest runs ~14,000 WFEs a second, 40% return at once,
  and the rest wait about 11 us on average. XNU's timer event stream fires every few microseconds,
  and even without it (`VPHONE_WFE_EVSTREAM=0`) the store that releases the lock comes within
  microseconds. A vCPU thread's sleep and wakeup cost about as much as that spin. It may help on a
  host with fewer cores than vCPUs.

- **`QEMU_TLB_UNSYNCED`** (relaxed broadcast TLB flushes). Six app-switch sweeps per mode gave the same
  latencies within noise. Settings scrolling: 31.4 vs 30.5 frames/s. The synced flush is not the
  bottleneck.
- **Pinning to P-cores** (`VPHONE_CPUS`): no measurable change in an A/B. It stays on, because a TCG
  thread on an E-core is slower.
- **Pinning each thread** (`tools/pin-threads.sh`: one vCPU per physical P-core, GPU threads on the
  siblings, the rest on E-cores): no difference on the Settings scroll. It is kept for experiments.

All four rows above together: host cycles −6.8% ±0.8 and host instructions −11.0% ±0.7 for the
same guestbench work (`VPHONE_MARK` metric, vCPU threads pinned, 27 runs per arm, equal guest load);
guestbench 3.73 s vs 4.00 s. Boot to unlock unchanged (151-158 s); app switching not yet remeasured.
Pinning the vCPU threads (`tools/pin-threads.sh`) alone brought guestbench from 4.4-4.9 s to 4.0-4.2 s;
the launcher does not pin yet.

Next candidates, from the profiles: CAS and LSE atomics inline (now C helpers, about 2.5% of vCPU
time); an ASID-tagged softmmu TLB, so a context switch costs no full flush.

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

### GPU stack vphone-next4 (release check, 2026-11-09)

The release's GPU stack (reims-vgpu `310da07`, metal2vulkan `8279756`) against v0.4's (reims-vgpu
`960bf4b`, metal2vulkan `f359ce2`), both linked into the same QEMU (`108e142`). Guest: iPhone 16
(iPhone17,3), iOS 26.6.2, as `create-vm.sh` makes it (1x, 430x932), 8 vCPUs, RTX 4080 SUPER, the
disk image on a USB SSD. Each boot measured boot to unlock, then home-screen paging (12 swipes) and a
Settings scroll (12 swipes), with reims-vgpu's frame statistics (`REIMS_VGPU_STATS=1`). Warm runs
reuse the first boot's shader and pipeline caches.

| | New stack | v0.4 stack |
|---|---|---|
| Boot to unlock, cold caches | 65 s | 63 s |
| Boot to unlock, warm (3 boots) | 62, 62, 86 s | 155, 121, 72 s |
| Settings scroll, warm (frames/s, average) | 51, 71, 58 | 13, 35, 60 |
| Home-screen paging, warm (frames/s, average) | 30, 24, 38 | 8 (then a 24 s stall), no frames, 26 |
| Either, cold caches (frames/s) | about 20 | about 20 |

On its good boot the v0.4 stack scrolls and pages as fast as the new one. The new stack's gain here
is consistency: every boot unlocked in about a minute and drew every swipe, where two of three v0.4
boots unlocked late and stalled on the home screen. With cold caches both are held to about
20 frames/s by first-use shader compiles. Single boots vary a lot (other work on the host, iOS's
background activity), so treat these as indications.

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
| `GFX_PPI` | unset | Optional explicit physical display density (`apple-gfx-mmio.pixels-per-inch`), an integer from 1 to 65535. The launcher does not read this value from `config.plist`. Set it only when QEMU supports the property, which [qemu-vphone#3](https://github.com/YahiaAngelo/qemu-vphone/pull/3) adds. The QEMU version pinned on `development` does not have it, and QEMU refuses to start when it is set. When unset or empty, QEMU keeps its default physical size. When set, the first `GFX_MODES` mode must describe the native physical panel |
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
| `VPHONE_JC_RANGE_PAGES` | 512 | Range flushes of this many pages or more start a new jump cache epoch instead of a new generation per page bucket | `accel/tcg/cputlb.c` |
| `VPHONE_JC_LAZY_INVAL` | on | Invalidating a position-independent translation makes each vCPU start a new jump cache epoch at its next lookup; `0` empties every vCPU's jump cache instead (QEMU's) | `accel/tcg/tb-maint.c`, `tb-jmp-cache.h` |
| `QEMU_TLB_UNSYNCED` | 2 (launcher) | How a broadcast TLB flush synchronizes: 0 an exclusive section per flush (QEMU's), 2 a barrier that falls back on one when a vCPU is late, 1 unsynchronized (not safe) |
| `QEMU_TLB_UNSYNCED` | 0 | Broadcast TLB flush mode: 0 synced (upstream), 1 fully async, 2 barrier (flush, then wait up to 1 ms for the others). Relaxed modes are experimental | `accel/tcg/cputlb.c` |
| `VPHONE_XPAGE_LINKS` | off | Checked cross-page links | `target/arm/tcg/translate-a64.c` |
| `VPHONE_RET_PREFETCH` | off | Return-address prefetch at calls: `2` inline, `1` through a helper, `0` off (the launcher sets 2) | `target/arm/tcg/translate-a64.c` |
| `VPHONE_RAS` | on | Return-address stack checked at `RET`/`RETAA`/`RETAB`; `0` = the jump cache lookup for every return. `VPHONE_RAS_STATS=1` (with `-d guest_errors`) logs hits and miss causes | `target/arm/tcg/translate-a64.c`, `accel/tcg/tb-jmp-cache.h` |
| `VPHONE_XPAGE_REFILL` | on | Cross-page link slow way refills the code TLB entry; `0` = old slow way | `accel/tcg/cpu-exec.c`, `accel/tcg/cputlb.c`, `target/arm/tcg/translate-a64.c` |
| `VPHONE_IBC` | on | Per-site indirect-branch cache; `0` = jump cache lookup. `VPHONE_IBC_REPLACE` sets how many other-target misses replace a valid slot (default 8) | `target/arm/tcg/translate-a64.c`, `accel/tcg/cpu-exec.c` |
| `VPHONE_INLINE_ZVA` | on | `DC ZVA` in generated code; `0` = helpers | `target/arm/tcg/translate-a64.c` |
| `VPHONE_FENCE` | 1 | Acquire/release on a TSO host: one fence per release store; `0` = upstream mapping | `target/arm/tcg/translate-a64.c` |
| `VPHONE_FAST_CNT` | off | Counter reads without the BQL or a TB exit (no measured effect on iOS) | `target/arm/helper.c`, `target/arm/tcg/translate-a64.c` |
| `VPHONE_MARK` | off | Diagnostic: `hint #0x7e` phase markers log host instructions/cycles/CPU time per guest phase; `VPHONE_INSN_STATS`, `VPHONE_SYSREG_STATS` count instruction classes and system registers | `target/arm/tcg/translate-a64.c` |
| `VPHONE_NATIVE_FP` | on | A64 FP/Neon as host SSE/AVX instructions; `0` = helpers (and softfloat's hardfloat) as before | `target/arm/tcg/host-fpcr.h`, `translate-a64.c` |
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
