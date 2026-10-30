#!/usr/bin/env bash
# vphone-setup, step 2: pick a device and iOS version and create the VM.
#
#   ./create-vm.sh                                 # interactive menus
#   ./create-vm.sh --device "iPhone17,3" --ios 26.6.2
#   ./create-vm.sh --list                          # devices + tested pairings
#   ./create-vm.sh --dry-run --device ... --ios ... # print the pipeline, run nothing
#
# The pipeline is vphone-cli's Linux firmware flow (docs/SETUP.md §5) with one
# state file per VM, so a re-run resumes after an interrupted step. QEMU is
# only ever STARTED here (the last step, once); this script never stops a VM.
set -Eeuo pipefail
# shellcheck disable=SC1091  # this checkout's own lib/common.sh, resolved at run time
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

DEVICE=${DEVICE:-} IOS=${IOS:-} CLOUDOS_PICK=${CLOUDOS_PICK:-}
SCALE=${SCALE:-1} NAME=${NAME:-} DRY=0 LIST=0 CID=${CID:-3}
while [ $# -gt 0 ]; do
  case $1 in
    --device)  DEVICE=$2; shift ;;
    --ios)     IOS=$2; shift ;;
    --cloudos) CLOUDOS_PICK=$2; shift ;;
    --name)    NAME=$2; shift ;;
    --scale)   SCALE=$2; shift ;;   # display scale: 1 (default; 2 on iOS 27) | 2 | 3
    --cid)     CID=$2; shift ;;     # the VM's vsock CID (default 3; another VM may hold it)
    --dry-run) DRY=1 ;;
    --list)    LIST=1 ;;
    -y)        export VSETUP_ASSUME_YES=1 ;;
    *) die "unknown option: $1" ;;
  esac; shift
done

J="$VSETUP_ROOT/lib/json_query.py"

if [ "$LIST" = 1 ]; then
  echo "Available devices (tested pairings, from vphone-cli's compatibility list):"
  while IFS=$'\t' read -r id nm; do
    printf '  %-20s %s\n' "$id" "$nm"
    while IFS=$'\t' read -r v b c pr flags; do
      printf '      iOS %-10s build %-9s cloudOS %-14s preset %-12s %s\n' \
        "$v" "$b" "$c" "$pr" "$flags"
    done < <(python3 "$J" choices "$id")
  done < <(python3 "$J" devices)
  exit 0
fi

# ------------------------------------------------------------- pick device --
device_menu() {
  local i choice
  mapfile -t devs < <(python3 "$J" devices)
  echo >&2; echo "Choose the device:" >&2
  for ((i = 0; i < ${#devs[@]}; i++)); do
    printf ' %2d) %s\n' $((i + 1)) "${devs[$i]//$'\t'/' — '}" >&2
  done
  read -rp "Choice: " choice
  [[ $choice =~ ^[0-9]+$ ]] || die "not a number"
  if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#devs[@]}" ]; then die "no such choice"; fi
  printf '%s\n' "${devs[choice - 1]%%	*}"
}
[ -n "$DEVICE" ] || DEVICE=$(device_menu)
python3 "$J" devices | grep -q "^$DEVICE"$'\t' || die "unknown device: $DEVICE"

# ------------------------------------------------------------ pick iOS ver --
choices() { python3 "$J" choices "$DEVICE"; }
ios_menu() {
  local i choice
  mapfile -t opts < <(choices)
  echo >&2; echo "Choose the iOS version for $DEVICE:" >&2
  for ((i = 0; i < ${#opts[@]}; i++)); do
    printf '  %2d) %s\n' $((i + 1)) "${opts[$i]//$'\t'/'  |  '}" >&2
  done
  read -rp "Choice: " choice
  [[ $choice =~ ^[0-9]+$ ]] || die "not a number"
  if [ "$choice" -lt 1 ] || [ "$choice" -gt "${#opts[@]}" ]; then die "no such choice"; fi
  printf '%s\n' "${opts[choice - 1]%%	*}"
}
[ -n "$IOS" ] || IOS=$(ios_menu)

PAIR_JSON=$(python3 "$J" find "$DEVICE" "$IOS") ||
  die "no tested pairing for $DEVICE + $IOS — try --list (source: Lakr233/vphone-cli compatibility.md)"

DEVICE_NAME=$(python3 "$J" devname "$DEVICE")
IFS=$'\t' read -r PAIR_IPSW PAIR_CLOUDOS PAIR_PRESET PAIR_BUILD PAIR_LINUX \
  PAIR_MAC PAIR_MACBUILDER PAIR_NOTE <<< "$PAIR_JSON"
export PAIR_IPSW PAIR_MAC   # both flags render in the menus

if [ "$PAIR_MACBUILDER" = 1 ]; then
  die "$DEVICE $IOS (cloudOS $PAIR_CLOUDOS) is kernel-first iOS 18: the kernelcache mix
     must be linked by a macOS kmutil (VPHONE_KMUTIL_SSH) before Linux can boot it.
     Run that step on a macOS host per vphone-cli's create-and-run.md."
fi
if [ "$PAIR_LINUX" = 0 ] && [ "$DRY" = 0 ]; then
  warn "This pairing is macOS-tested but NOT yet verified on Linux: it is under test."
  warn "The Linux-verified pairings are the TESTED-ON-LINUX ones in --list."
  warn "Expect a first run to need manual attention (extra patches, CPU/RAM, restore retries)."
  confirm "Continue anyway?" || { echo "aborted."; exit 1; }
fi
[ -n "$CLOUDOS_PICK" ] && PAIR_CLOUDOS=$CLOUDOS_PICK

# ------------------------------------------------------------ the pipeline --
NAME=${NAME:-vphone-${DEVICE//,/-}-${IOS//./}}
VM=$VSETUP_DEVICES/$NAME
STATE=$VM/.create-state
[ "$DRY" = 1 ] || mkdir -p "$VM"

# iOS 27 does not go below 2x (docs/ADVANCED.md "Display scale").
case $IOS in
  27.*) if [ "$SCALE" = 1 ]; then warn "iOS 27 does not go below 2x: using --scale 2"; SCALE=2; fi ;;
esac

done_step() { grep -qxs "$1" "$STATE"; }
# Run a command, or only print it in a dry run.
dry() {
  if [ "$DRY" = 1 ]; then printf '   \033[2m[dry-run]\033[0m %s\n' "$*"
  else printf '\033[2m+ %s\033[0m\n' "$*" >&2; "$@"; fi
}
mark() { [ "$DRY" = 1 ] || printf '%s\n' "$1" >> "$STATE"; }
# step KEY FUNCTION: run FUNCTION unless KEY is recorded, then record KEY. Not run as an `if`
# condition, so `set -e` stays in force inside FUNCTION: a failing command ends the run before
# the step is recorded, and the ERR trap names the step to resume from.
CURRENT_STEP=
trap '[ -n "$CURRENT_STEP" ] && printf "\033[1;31mERROR\033[0m step %s failed (fix it, then re-run to resume)\n" "$CURRENT_STEP" >&2' ERR
step() {
  local key=$1; shift
  if done_step "$key"; then log "  • $key  (already done)"; return 0; fi
  log "▶ $key"
  CURRENT_STEP=$key
  "$@"
  CURRENT_STEP=
  mark "$key"
}

log "Device:  $DEVICE ($DEVICE_NAME)"
log "iOS:     $IOS (build $PAIR_BUILD)   cloudOS: $PAIR_CLOUDOS   preset: $PAIR_PRESET"
[ -n "${PAIR_NOTE:-}" ] && log "Note:    $PAIR_NOTE"
log "VM:      $VM   (scale ${SCALE}x, vsock CID $CID)"
[ "$DRY" = 1 ] && log "DRY RUN: nothing below executes."

VC=$VSETUP_SRC/linux-create/.build/out/out/Products/Debug-linux-x86_64/vphone-cli
QEMU_RUN=$VSETUP_SRC/run-vphone.sh
T=$VSETUP_SRC/tools
ECID=$(cat "$VM/ecid" 2>/dev/null || echo 0x0)
CACHE=$HOME/.cache/vphone

do_sanity() {
  if [ "$DRY" = 1 ]; then
    log "   (dry-run: binaries appear when ./setup.sh has run — skipping checks)"; return 0
  fi
  local one missing=0
  for one in "$VC" "$QEMU_RUN" "$VSETUP_SRC/OpenAVB/OpenAVB.bin" "$VSETUP_SRC/OpenSEP/OpenSEP.bin"; do
    [ -e "$one" ] || { warn "missing: $one — run ./setup.sh first"; missing=1; }
  done
  [ "$missing" = 0 ]
}

do_bundle() {
  dry python3 "$VSETUP_ROOT/lib/make-bundle.py" "$VM" "$DEVICE" "$SCALE"
  dry cp "$VSETUP_SRC/OpenAVB/OpenAVB.bin" "$VM/OpenAVB.bin"
  dry cp "$VSETUP_SRC/OpenSEP/OpenSEP.bin" "$VM/OpenSEP.bin"
  ECID=$(cat "$VM/ecid" 2>/dev/null || echo 0x0)
}

# The firmware the pairing names: the iOS restore and the cloudOS image, resolved by
# vphone-cli's fw catalog (IPSW_URL=/CLOUDOS_IPSW_URL= override it). Files land in
# ~/.cache/vphone and are reused. Resolved on every run (prepare needs the paths); a download
# happens only for a file that is not there yet.
resolve_firmware() {
  IOS_LOCAL='' CLOUDOS_LOCAL=''
  local ios_file='' ios_url='' cloud_file='' cloud_url='' resolved
  if [ -n "${IPSW_URL:-}" ]; then
    ios_url=$IPSW_URL ios_file=$(basename "$IPSW_URL")
  elif [ -x "$VC" ]; then
    resolved=$(python3 "$VSETUP_ROOT/lib/get-firmware.py" "$VC" "$DEVICE" "$IOS" "$PAIR_CLOUDOS") ||
      die "fw catalog has no pairing for $DEVICE $IOS — pass IPSW_URL= and CLOUDOS_IPSW_URL="
    IFS=$'\t' read -r ios_file ios_url <<< "$(printf '%s\n' "$resolved" | sed -n 1p)"
    IFS=$'\t' read -r cloud_file cloud_url <<< "$(printf '%s\n' "$resolved" | sed -n 2p)"
  else
    log "  (vphone-cli not built: firmware resolution skipped)"
    ios_file=$PAIR_IPSW
  fi
  if [ -n "${CLOUDOS_IPSW_URL:-}" ]; then
    cloud_url=$CLOUDOS_IPSW_URL cloud_file=$(basename "$CLOUDOS_IPSW_URL")
  fi
  IOS_LOCAL=${IPSW_PATH:-$CACHE/$ios_file}
  CLOUDOS_LOCAL=${cloud_file:+$CACHE/$cloud_file}
  IOS_URL=$ios_url CLOUD_URL=$cloud_url
}
resolve_firmware

do_firmware() {
  [ "$DRY" = 1 ] || mkdir -p "$CACHE"
  if [ -n "$CLOUD_URL" ] && [ ! -s "$CLOUDOS_LOCAL" ]; then
    dry curl -L --retry 3 -o "$CLOUDOS_LOCAL" "$CLOUD_URL"
  fi
  if [ -n "$IOS_URL" ] && [ ! -s "$IOS_LOCAL" ]; then
    dry curl -L --retry 3 -o "$IOS_LOCAL" "$IOS_URL"
  fi
  log "  firmware: $IOS_LOCAL + ${CLOUDOS_LOCAL:-cloudOS $PAIR_CLOUDOS}"
}

# The GPU driver's cryptex keys are not public (Apple answers 403 for the 23E5207q), so it
# comes from a stock cloudOS restore. Look in the usual places; GPU_DRIVER_BUNDLE= wins.
find_gpu_bundle() {
  local cand
  for cand in "${GPU_DRIVER_BUNDLE:-}" "$VSETUP_RELEASE/AppleParavirtGPUMetalIOGPUFamily.bundle" \
              "$CACHE/AppleParavirtGPUMetalIOGPUFamily.bundle"; do
    [ -n "$cand" ] && [ -d "$cand" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

# Extract the GPU driver once (shared by every VM): tools/gpu-driver-from-cloudos.sh restores
# the stock cloudOS just downloaded into a temporary VM (~20-30 min) and keeps only the driver,
# in $VSETUP_RELEASE. It needs the same USB helpers as the restore below.
do_gpu_driver() {
  if find_gpu_bundle >/dev/null; then log "  GPU driver: $(find_gpu_bundle)"; return 0; fi
  [ "$DRY" = 1 ] || [ -s "$CLOUDOS_LOCAL" ] ||
    die "the cloudOS IPSW is missing ($CLOUDOS_LOCAL); pass CLOUDOS_IPSW_URL= or GPU_DRIVER_BUNDLE="
  log "  Extracting the GPU driver from a stock cloudOS restore (once; about 20-30 minutes)"
  usb_helpers
  dry env VC="$VC" "$T/gpu-driver-from-cloudos.sh" "$CLOUDOS_LOCAL" "$VSETUP_RELEASE"
}

do_prepare() {
  local gpu_bundle
  gpu_bundle=$(find_gpu_bundle) || gpu_bundle=${GPU_DRIVER_BUNDLE:-$VSETUP_RELEASE/AppleParavirtGPUMetalIOGPUFamily.bundle}
  [ "$DRY" = 1 ] || [ -d "$gpu_bundle" ] || die "GPU driver bundle not found. Re-run ./setup/create-vm.sh (its gpu-driver step extracts it), or
     • copy one to $VSETUP_RELEASE/AppleParavirtGPUMetalIOGPUFamily.bundle,
     • or set GPU_DRIVER_BUNDLE=/path/to/AppleParavirtGPUMetalIOGPUFamily.bundle"
  # An existing restore tree is a prepare that did not finish (or a patch that failed part way,
  # which leaves files patched in place with no originals kept): fw prepare refuses to overwrite
  # it, so it goes, and the firmware is prepared again from the IPSWs.
  local tree
  for tree in "$VM"/*_Restore "$VM/FirmwareOriginals"; do
    [ -e "$tree" ] || continue
    log "  removing the unfinished $(basename "$tree") of an earlier run"
    dry rm -rf "$tree"
  done
  dry "$VC" fw prepare -l "$VSETUP_DEVICES" "$NAME" \
      -i "${IPSW_URL:-$IOS_LOCAL}" -c "${CLOUDOS_LOCAL:-$PAIR_CLOUDOS}" \
      --gpu-driver-bundle "$gpu_bundle"
}

do_patch() {
  # iOS 27 pairings need the seal patcher, which mounts the restore ramdisk read-write through
  # linux-apfs-rw (root). A 26.x pairing patches as the user. (The restore TXM's pre-check for
  # the SSH ramdisk is not this step: restore-tree-mode.sh ssh applies it in the cfw step.)
  case $IOS in
    27.*)
      # This checkout's patched module (./setup.sh build), not a distro apfs that refuses iOS 27.
      if [ "$DRY" = 1 ] || ! grep -q '^apfs ' /proc/modules; then
        dry sudo insmod "$VSETUP_SRC/.build/linux-apfs-rw/apfs.ko"
      fi
      dry sudo "$VC" fw patch -l "$VSETUP_DEVICES" "$NAME" ;;
    *)
      dry "$VC" fw patch -l "$VSETUP_DEVICES" "$NAME" ;;
  esac
}

# The restore's root helpers: the 32 KiB usbmuxd (stops the system one) and the USB/IP attach
# loop, which runs until the host reboots; started once, in the background, its pid kept in
# /run so a re-run does not start a second one.
AUTOATTACH_PID=/run/vphone-usbip-autoattach.pid
usb_helpers() {
  # `sudo true`, not `sudo -v`: -v asks for a password unless every sudoers entry is NOPASSWD
  # (verifypw=all), so a NOPASSWD rule next to the usual wheel one would still prompt.
  dry sudo true
  dry sudo "$T/usbmuxd-32k.sh"
  if [ "$DRY" = 0 ] && sudo test -s "$AUTOATTACH_PID" &&
     sudo test -d "/proc/$(sudo cat "$AUTOATTACH_PID")"; then
    log "  (the USB/IP attach loop is already running)"
  else
    dry sudo sh -c "nohup '$T/usbip-autoattach.sh' > /tmp/vphone-usbip-autoattach.log 2>&1 & echo \$! > $AUTOATTACH_PID"
  fi
}

do_restore() {
  usb_helpers
  dry "$T/dfu-up.sh" "$VM" "$VM/.runs-dfu"
  dry "$VC" recovery-probe --ecid "$ECID" --timeout 180 || { "$T/dfu-diagnose.sh" "$VM/.runs-dfu"; return 1; }
  dry env VPHONE_RESTORE_TIMEOUT_SCALE=10 "$VC" restore -l "$VSETUP_DEVICES" "$NAME" --ecid "$ECID" -v
  dry "$T/dfu-stop.sh" "$VM"     # this VM's QEMU only, matched by its Disk.img
}

# In the SSH ramdisk: mount xART, and where an earlier install renamed the gigalocker to AA.gl,
# give it back the name the ramdisk's seputil asks for (it reads it from its own refusal);
# without it mount_filesystems panics the guest. A fresh restore has no gigalocker yet: nothing
# to do, seputil makes it. The single quotes are the point: this runs in the guest.
# shellcheck disable=SC2016
GIGALOCKER_SH='x=; for n in 1 2 3 4 5 6 7; do t=$(/System/Library/Filesystems/apfs.fs/apfs.util -p /dev/disk1s$n 2>/dev/null); [ "$t" = xART ] && x=/dev/disk1s$n; done
[ -n "$x" ] || x=/dev/disk1s3
/sbin/mount_apfs "$x" /mnt7 2>/dev/null
if [ -f /mnt7/AA.gl ]; then
  out=$(/usr/libexec/seputil --gigalocker-init /mnt7 2>&1)
  case $out in *"doesn'"'"'t exist"*) want=${out#*Gigalocker file (}; want=${want%%)*}; mv /mnt7/AA.gl "$want" && echo "gigalocker: AA.gl -> $want";; esac
fi
true'

do_cfw() {
  usb_helpers
  # The SSH tools the ramdisk gets (dropbear, bash, sftp-server, ...): fetched once, pinned and
  # checksummed (tools/ssh-ramdisk-stage.sh).
  if [ "$DRY" = 1 ] || [ ! -e "$VSETUP_SRC/runs/sshramdisk/ssh-root/usr/local/bin/dropbear" ]; then
    dry "$T/ssh-ramdisk-stage.sh"
  fi
  dry bash "$T/ssh-ramdisk-rebuild-signed.sh" "$VSETUP_DEVICES" "$NAME"
  dry "$T/restore-tree-mode.sh" "$VSETUP_DEVICES" "$NAME" ssh
  dry python3 "$T/nvram-autoboot.py" "$VM/nvram.bin" --auto-boot false
  dry "$T/dfu-up.sh" "$VM" "$VM/.runs-sshrd"
  dry "$VC" recovery-probe --ecid "$ECID" --timeout 180 || { "$T/dfu-diagnose.sh" "$VM/.runs-sshrd"; return 1; }
  # --boot-ramdisk ends by waiting for restore mode, which the SSH ramdisk never enters: it runs
  # in the background under a time limit, and the step goes on once SSH answers.
  if [ "$DRY" = 1 ]; then
    dry env VPHONE_RESTORE_TIMEOUT_SCALE=10 VPHONE_RESTORE_BOOT_ARGS_EXTRA=serial=3 \
        "$VC" restore -l "$VSETUP_DEVICES" "$NAME" --ecid "$ECID" --boot-ramdisk -v
  else
    timeout 1800 env VPHONE_RESTORE_TIMEOUT_SCALE=10 VPHONE_RESTORE_BOOT_ARGS_EXTRA=serial=3 \
      "$VC" restore -l "$VSETUP_DEVICES" "$NAME" --ecid "$ECID" --boot-ramdisk -v \
      > "$VM/.runs-sshrd/boot-ramdisk.log" 2>&1 &
    log "  waiting for the SSH ramdisk (log: $VM/.runs-sshrd/boot-ramdisk.log)"
    local tries=0
    until timeout 60 "$T/ssh-ramdisk.sh" id >/dev/null 2>&1; do
      tries=$((tries + 1)); [ "$tries" -lt 60 ] || die "the SSH ramdisk did not answer in 30 min"
      sleep 30
    done
  fi
  dry "$T/ssh-ramdisk.sh" "$GIGALOCKER_SH"
  dry timeout 1800 "$T/ssh-ramdisk.sh" '/usr/bin/mount_filesystems; /sbin/mount'
  dry sudo "$VC" cfw install -l "$VSETUP_DEVICES" "$NAME" --work-parent /var/tmp --keep-artifacts
  dry "$T/ssh-ramdisk.sh" 'sync; /sbin/umount /mnt2; /sbin/umount /mnt6; /sbin/umount /mnt1; sync'
  dry "$T/dfu-stop.sh" "$VM"     # the flip below edits Disk.img: no VM may have it open
  dry "$VC" cfw flip-snapshot "$VM/Disk.img"
  dry python3 "$T/nvram-autoboot.py" "$VM/nvram.bin" --auto-boot true
  dry "$T/restore-tree-mode.sh" "$VSETUP_DEVICES" "$NAME" full
  # LLB's half of the scale; the guest device tree's half needs the running guest (first boot).
  dry python3 "$T/display-scale.py" "$VM/nvram.bin" "$([ "$SCALE" = 3 ] && echo 0 || echo "$SCALE")"
}

step sanity   do_sanity
step bundle   do_bundle
step firmware do_firmware
step gpu-driver do_gpu_driver
step prepare  do_prepare
# A failed patch leaves the tree part patched: prepare runs again before the next patch.
if ! done_step patch && done_step prepare && [ -e "$VM/.patch-started" ]; then
  log "  an earlier fw patch did not finish: preparing the firmware again first"
  [ "$DRY" = 1 ] || { grep -vx prepare "$STATE" > "$STATE.new" || true; mv "$STATE.new" "$STATE"; }
  step prepare do_prepare
fi
[ "$DRY" = 1 ] || : > "$VM/.patch-started"
step patch    do_patch
step restore  do_restore
step cfw      do_cfw

# ------------------------------------------------------------- first boot --
# The only place a VM is started: once (twice when the scale needs the guest's device tree
# changed, after vphoned has shut the guest down), in the background, for THIS VM alone.
# vphoned answers slowly while the first boot migrates (30 s and more): long timeouts throughout.
vrpc() { CID=$CID VPHONED_TIMEOUT=120 "$T/vphoned.sh" POST /v1/rpc "$1"; }
vphoned_up() {
  CID=$CID VPHONED_TIMEOUT=120 timeout 150 "$T/vphoned.sh" GET /v1/health 2>/dev/null | grep -q '"status":"ok"'
}
# The VM this script started, by the pid it recorded: still this VM's QEMU (it has this VM's
# Disk.img open) after a re-run. One known pid is checked; no process is searched for.
QEMU_PIDFILE=$VM/.qemu.pid
running_vm() {
  local pid
  pid=$(cat "$QEMU_PIDFILE" 2>/dev/null) || return 1
  [ -n "$pid" ] && [ -r "/proc/$pid/cmdline" ] &&
    tr '\0' '\n' < "/proc/$pid/cmdline" | grep -q "file=$VM/Disk.img" &&
    QEMU_PID=$pid
}
boot_vm() {
  if running_vm; then
    log "  this VM is already running (QEMU pid $QEMU_PID): waiting for vphoned"
  else
    GFX=${GFX:-1} WINDOW=${WINDOW:-1} CID=$CID "$QEMU_RUN" "$VM" > "$VM/serial.log" 2>&1 &
    QEMU_PID=$!
    printf '%s\n' "$QEMU_PID" > "$QEMU_PIDFILE"
    log "  QEMU output → $VM/serial.log; waiting for vphoned"
  fi
  until vphoned_up; do
    [ -d "/proc/$QEMU_PID" ] || die "QEMU exited; see $VM/serial.log"
    sleep 10; printf '.' >&2
  done
  echo >&2
}
# Waits for the VM's QEMU to exit (after vphoned shut the guest down); it need not be this
# shell's child, so its /proc entry is watched.
wait_vm_exit() {
  while [ -d "/proc/$QEMU_PID" ]; do sleep 2; done
}
unlock_vm() {
  local i
  for i in $(seq 1 40); do
    vrpc '{"method":"screen.unlock","params":{},"id":1}' 2>/dev/null | grep -q '"locked":false' && return 0
    sleep 15
  done
  warn "the screen did not unlock; try: CID=$CID $T/vphoned.sh POST /v1/rpc '{\"method\":\"screen.unlock\",\"params\":{},\"id\":1}'"
}

do_first_boot() {
  if [ "$DRY" = 1 ]; then
    dry env GFX="${GFX:-1}" WINDOW="${WINDOW:-1}" CID="$CID" "$QEMU_RUN" "$VM"
    dry "$T/vphoned.sh" POST /v1/rpc '{"method":"setup.status",...}'   # until data_migration_done
    dry "$T/vphoned.sh" POST /v1/rpc '{"method":"setup.skip","params":{"force":true},"id":1}'
    dry python3 "$T/auto-lock-never.py" "$VM" "$CID"
    [ "$SCALE" = 3 ] || dry python3 "$T/guest-dt-scale.py" "$CID" "$SCALE"
    return 0
  fi
  log "  the first boot migrates iOS's data behind an Apple logo and progress bar (20+ min)"
  boot_vm
  until vrpc '{"method":"setup.status","params":{},"id":1}' 2>/dev/null |
      grep -q '"data_migration_done":true'; do
    sleep 30; printf '.' >&2
  done
  echo >&2
  vrpc '{"method":"setup.skip","params":{"force":true},"id":1}'; echo
  unlock_vm
  python3 "$T/auto-lock-never.py" "$VM" "$CID"
  if [ "$SCALE" != 3 ]; then
    # iOS 27 also takes the scale from the guest's device tree: set it, then restart the guest
    # (vphoned shuts it down; QEMU exits by itself) so the new scale applies.
    python3 "$T/guest-dt-scale.py" "$CID" "$SCALE"
    log "  restarting the guest for the ${SCALE}x screen"
    vrpc '{"method":"system.shutdown","params":{"force":true},"id":1}'; echo
    wait_vm_exit
    boot_vm
    unlock_vm
    if [ "$SCALE" = 1 ]; then python3 "$T/guest-1x-logo.py" "$CID"; fi
  fi
}
step booted do_first_boot

if [ "$DRY" = 1 ]; then
  log "Dry run complete — no command executed."
else
  log "VM '$NAME' is up and unlocked (Auto-Lock: Never). Later:"
  log "  start:  GFX=1 WINDOW=1 CID=$CID $QEMU_RUN $VM"
  log "  stop:   CID=$CID $T/vphoned.sh POST /v1/rpc '{\"method\":\"system.shutdown\",\"params\":{\"force\":true},\"id\":1}'"
fi
