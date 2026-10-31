#!/bin/bash
# Boot a vphone-cli VM bundle (copied from a Mac) on Linux with QEMU's
# vresearch101 machine.
#
#   run-vphone.sh <vm-dir> [extra qemu args...]
#
# <vm-dir> holds the bundle's Disk.img, nvram.bin and the two ROMs
# (AVPBooter.vresearch1.bin, AVPSEPBooter.vresearch1.bin), plus a file
# "ecid" with the machine's ECID in hex (from its machineIdentifier).
#
# Env: QEMU, SMP (AP cores, default 8), MEM (default 8G), GFX=1 to attach the
#      reims-vgpu paravirtual GPU, WINDOW=1 for its own window (with a button bar;
#      TOOLBAR=0 for none), LOG (-D file),
#      DFLAGS (-d flags), TRACE (-trace pattern), GDB=<port> to wait for gdb,
#      CID (vsock context ID, default 3; unique per running VM; 0 = no vsock),
#      VSOCK (uds | vhost: vsock datapath, see below), VSOCK_DIR (uds sockets).
#
# vphoned listens on vsock port 1339 in the guest (vphone-cli's control
# channel); from the host: tools/vphoned.sh (either datapath), or with VSOCK=vhost
# socat - VSOCK-CONNECT:$CID:1339
set -euo pipefail

VM=${1:?usage: run-vphone.sh <vm-dir> [qemu args...]}
shift
QEMU=${QEMU:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/qemu/build/qemu-system-aarch64}   # this checkout's
SMP=${SMP:-8}
MEM=${MEM:-8G}

ecid=$(tr -d ' \n' < "$VM/ecid")

# The ROM files a machine boots: config.plist's romImages (OpenAVB/OpenSEP for
# machines made by vphone-cli 2.10+) or Apple's Virtualization.framework names.
rom_name=$(python3 -c "import plistlib,sys;print((plistlib.load(open(sys.argv[1],'rb')).get('romImages') or {}).get('avpBooter',''))" "$VM/config.plist" 2>/dev/null)
seprom_name=$(python3 -c "import plistlib,sys;print((plistlib.load(open(sys.argv[1],'rb')).get('romImages') or {}).get('avpSEPBooter',''))" "$VM/config.plist" 2>/dev/null)
[ -n "$rom_name" ] || rom_name=AVPBooter.vresearch1.bin
[ -n "$seprom_name" ] || seprom_name=AVPSEPBooter.vresearch1.bin
machine="vresearch101,ecid=$ecid,sep-rom=$VM/$seprom_name"
# the serial number Virtualization.framework reported for this machine, if known
[ -f "$VM/serial" ] && machine+=",serial=$(tr -d ' \n' < "$VM/serial")"
# TB_SIZE: the TCG code cache in MiB (default 2048, x86-64's limit). An iOS guest keeps ~1.3M
# translated blocks live at ~18x expansion: the default 1 GiB filled every ~3.5 minutes (14 full
# flushes in 49 minutes), and every flush retranslates everything the guest runs next.
args=(
  -accel "tcg,tb-size=${TB_SIZE:-2048}"
  -smp "$SMP,maxcpus=$((SMP + 1))" -m "$MEM"
  -bios "$VM/$rom_name"
  # nvram.bin is Virtualization.framework aux storage: a 16 KiB header, then
  # the firmware store (HUFA) AVPBooter reads through the backdoor device
  -drive "file=$VM/nvram.bin,if=pflash,format=raw,offset=16384,file.locking=off"
  -drive "file=$VM/Disk.img,if=pflash,format=raw,file.locking=off"
  # The firmware backdoor reads this disk during boot; XNU also expects the
  # root APFS disk to be present as an Apple VirtIO PCI storage device.
  -drive "file=$VM/Disk.img,if=none,id=root-pci,format=raw,file.locking=off"
  # Virtualization.framework also exposes the auxiliary storage as an "aux"
  # virtio-blk device; the RestoreOS builds its IONVRAM service from it. Like the pflash, it
  # starts past the 16 KiB aux-storage header: without the offset the restore writes the
  # firmware store at byte 0 and AVPBooter, which reads it at 16 KiB, falls back to DFU.
  -drive "file=$VM/nvram.bin,if=none,id=aux-pci,format=raw,offset=16384,file.locking=off"
  -serial mon:stdio
)
# The SEP coprocessor's persistent storage (Virtualization.framework's
# _VZSEPCoprocessorConfiguration storageURL); sepOS's SEPD reads it at boot
if [ -f "$VM/SEPStorage" ]; then
  args+=(-drive "file=$VM/SEPStorage,if=none,id=sep-storage,format=raw,file.locking=off")
fi

if [ "${GFX:-0}" = 1 ]; then
  # apple-gfx needs guest RAM as a shared file mapping
  # The bundle's screenConfig (1290x2796, 460 ppi), not the host screen's modes.
  # GFX_RES=860x1864 with LLB patched to 2x (tools/display-scale.py VM/nvram.bin 2), or 430x932
  # at 1x: the same 430x932-point screen with 2.25x / 9x fewer pixels for iOS to draw.
  # A VM folder's gfx-res file (e.g. 448x932 for 1x) sets its default. Keep the width a
  # multiple of 32 at 1x (rows a multiple of 128 bytes): NVIDIA's linear images need 128-byte
  # rows, so a 430-wide screen's surfaces were shadow-copied in and out on every pass (~10
  # screens per frame); at 448 the runtime aliases them instead.
  GFX_RES=${GFX_RES:-$(cat "$VM/gfx-res" 2>/dev/null || echo 1290x2796)}
  machine+=",gfx-device=apple-gfx-mmio,memory-backend=ram0,gfx-modes=${GFX_MODES:-$GFX_RES@60}"
  # A shared file mapping aligned past the guest's 16 KiB pages: reims-vgpu's
  # per-task processes map guest RAM in whole guest pages (memfd has no align)
  args+=(-object "memory-backend-file,id=ram0,size=$MEM,mem-path=/dev/shm,share=on,align=2M"
         -global apple-gfx-mmio.resolution=$GFX_RES
         -global apple-gfx-mmio.process-isolation=${GFX_ISOLATION:-on})
  export REIMS_VGPU_WINDOW=${WINDOW:-0}
  export REIMS_VGPU_WINDOW_TITLE=${REIMS_VGPU_WINDOW_TITLE:-vphone-linux}
  # Every GPU task process must pick the same Vulkan device as QEMU (a task
  # process left to the loader picked llvmpipe). NVIDIA's manifest is nvidia_icd.x86_64.json on
  # Fedora and nvidia_icd.json on Arch/Omarchy and Debian.
  if [ -z "${VK_DRIVER_FILES:-}" ]; then
    for icd in /usr/share/vulkan/icd.d/nvidia_icd.x86_64.json /usr/share/vulkan/icd.d/nvidia_icd.json; do
      [ -f "$icd" ] && { export VK_DRIVER_FILES=$icd; break; }
    done
  fi
  if [ -z "${VK_DRIVER_FILES:-}" ] && grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
    # WSL2 has no native Vulkan driver for the host GPU, only Mesa's dzn (Vulkan on D3D12),
    # which cannot import guest RAM by pointer (VK_EXT_external_memory_host) and has no udmabuf
    # fallback. lavapipe can: it renders on the CPU, slower but complete. Present goes through
    # WSLg's Wayland/X server. Set VK_DRIVER_FILES to try another ICD. (A VM's virtio-gpu Venus
    # lacks the same extension: there too, VK_DRIVER_FILES=.../lvp_icd.json.)
    for icd in /usr/share/vulkan/icd.d/lvp_icd.json /usr/share/vulkan/icd.d/lvp_icd.x86_64.json; do
      [ -f "$icd" ] && { export VK_DRIVER_FILES=$icd; break; }
    done
    # lavapipe's rasterizer threads compete with the vCPUs, and WSL cannot keep QEMU on the
    # performance cores (no /sys/devices/cpu_core): a guest starved of CPU trips iOS's first-boot
    # watchdog ("datamigrator plugin SpringBoard.migrator hang"). Keep lavapipe to a few threads.
    export LP_NUM_THREADS=${LP_NUM_THREADS:-4}
  fi
  # A degradation reims-vgpu would die at (its DIES list) is recorded and relayed instead, so
  # one app's use of an unmodelled Metal corner costs an inexact frame, not the VM. The census
  # (census-<pid>.json) lists every kind met. REIMS_VGPU_CENSUS_DIR= (empty) restores deaths.
  export REIMS_VGPU_CENSUS_DIR=${REIMS_VGPU_CENSUS_DIR-$PWD/runs/census}
  if [ -n "$REIMS_VGPU_CENSUS_DIR" ]; then mkdir -p "$REIMS_VGPU_CENSUS_DIR"; else unset REIMS_VGPU_CENSUS_DIR; fi
fi
# 16 KiB target pages (iOS's granule) plus a page-count range-flush check in cputlb.c: together
# they halve the time spent refilling the softmmu TLB (HANDOFF.md, "16 KiB target pages").
# VPHONE_TARGET_PAGE_BITS=12 / VPHONE_TLB_RANGE_PAGES=0 restore QEMU's defaults.
export VPHONE_TARGET_PAGE_BITS=${VPHONE_TARGET_PAGE_BITS:-14}
export VPHONE_TLB_RANGE_PAGES=${VPHONE_TLB_RANGE_PAGES:-1}
# Direct branches to another page chain through a TLB-checked link instead of a TB lookup
# (qemu target/arm/tcg/translate-a64.c gen_goto_tb_checked). VPHONE_XPAGE_LINKS=0 disables.
export VPHONE_XPAGE_LINKS=${VPHONE_XPAGE_LINKS:-1}
# At each call, load the return address's TB jump cache entry ahead of the return's lookup
# (qemu translate-a64.c vphone_gen_prefetch_ret): 2 (default) inline, 1 through a helper, 0 off.
# The return's lookup (helper_vphone_lookup_fast) otherwise stalls on that entry's cache miss
# (38% of its time); inline, QEMU's share of vCPU time fell from 47.8% to 44.6%.
export VPHONE_RET_PREFETCH=${VPHONE_RET_PREFETCH:-2}
# Touch: iOS accepts the USB touchscreen (hub port 2.1) as the built-in main-screen digitizer only
# when its xHCI root port reports the device non-removable (PORTSC Device Removable, hcd-xhci.c).
# Bit n = xHCI port n; 0x1fe = every port. VPHONE_XHCI_NONREMOVABLE=0 restores QEMU's default.
export VPHONE_XHCI_NONREMOVABLE=${VPHONE_XHCI_NONREMOVABLE:-0x1fe}
args+=(-display none)

# Virtualization.framework's VZVirtioSocketDevice is virtio-vsock. Two datapaths:
#  VSOCK=uds   QEMU's own (virtio-vsock-uds-pci). Host side: a Unix socket $VSOCK_DIR/$CID.sock
#              speaking "CONNECT <port>\n" -> "OK <n>\n" (tools/vphoned.sh, vphoned-update.sh).
#              It asks the guest for credit and never caps it, so any host client can stream.
#  VSOCK=vhost the kernel's vhost-vsock; host side AF_VSOCK (socat VSOCK-CONNECT:$CID:1339).
#              Linux caps a socket's send credit at its own buffer (256 KiB by default) and iOS
#              only sends a credit update once its 512 KiB window is nearly full, so a
#              host-to-guest stream stalls after 256 KiB unless the host socket's
#              SO_VM_SOCKETS_BUFFER_SIZE is >= 512 KiB (vphoned-update.sh sets it).
# Default: vhost (63 MB/s uploads vs 26 for uds, and plain AF_VSOCK/socat work). VSOCK=auto
# picks uds when this QEMU has the device (qemu branch vsock-uds).
CID=${CID:-3}
VSOCK=${VSOCK:-vhost}
VSOCK_DIR=${VSOCK_DIR:-/tmp/vphone-vsock}
if [ "$VSOCK" = auto ]; then
  case $("$QEMU" -device help 2>/dev/null || true) in
    *'"virtio-vsock-uds-pci"'*) VSOCK=uds ;;
    *) VSOCK=vhost ;;
  esac
fi
if [ "$CID" != 0 ]; then
  if [ "$VSOCK" = uds ]; then
    mkdir -p "$VSOCK_DIR"
    args+=(-device "virtio-vsock-uds-pci,guest-cid=$CID,uds-path=$VSOCK_DIR/$CID.sock")
  else
    rm -f "$VSOCK_DIR/$CID.sock"  # tools prefer the socket when it exists
    args+=(-device "vhost-vsock-pci,guest-cid=$CID")
  fi
fi

# The window's button bar (Home, Lock, volume, screenshot, and Fold on an iPhone Duo) and, on a
# foldable guest, its rotation: tools/window/vphone-window.py talks to the window over its control
# socket and to vphoned over vsock, and ends with QEMU. TOOLBAR=0 leaves the window bare.
if [ "${GFX:-0}" = 1 ] && [ "${WINDOW:-0}" = 1 ] && [ "${TOOLBAR:-1}" = 1 ] && [ "$CID" != 0 ]; then
  export REIMS_VGPU_WINDOW_CONTROL=${XDG_RUNTIME_DIR:-/tmp}/vphone-window-$CID.sock
  python3 "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tools/window/vphone-window.py" \
    "$REIMS_VGPU_WINDOW_CONTROL" --cid "$CID" &
fi

[ -n "${LOG:-}" ] && args+=(-D "$LOG")
[ -n "${DFLAGS:-}" ] && args+=(-d "$DFLAGS")
[ -n "${TRACE:-}" ] && args+=(-trace "$TRACE")
[ -n "${GDB:-}" ] && args+=(-gdb "tcp::$GDB" -S)

# Hybrid hosts (this i7-14700K: P-cores 0-15, E-cores 16-27): keep QEMU on the performance
# cores, where a vCPU thread runs TCG code far faster than on an efficiency core.
# VPHONE_CPUS= (empty) leaves placement to the scheduler; any taskset list overrides.
if [ -z "${VPHONE_CPUS+x}" ] && [ -r /sys/devices/cpu_core/cpus ]; then
  VPHONE_CPUS=$(cat /sys/devices/cpu_core/cpus)
fi
if [ -n "${VPHONE_CPUS:-}" ]; then
  exec taskset -c "$VPHONE_CPUS" "$QEMU" -M "$machine" "${args[@]}" "$@"
fi
exec "$QEMU" -M "$machine" "${args[@]}" "$@"
