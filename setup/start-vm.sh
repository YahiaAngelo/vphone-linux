#!/usr/bin/env bash
# vphone-setup: start a VM that create-vm.sh made, in its window, and unlock it.
#
#   ./start-vm.sh                 # the only VM, or a menu of them
#   ./start-vm.sh NAME            # one of ~/vphone-setup-work/devices/NAME (or a VM folder path)
#   ./start-vm.sh --list          # the VMs and whether each is running
#   ./start-vm.sh --stop [NAME]   # shut the guest down (iOS's own shutdown, as on a phone)
#
# The VM runs in the background, its log in VM/serial.log; closing its window powers it off.
# Options: --cid N (the vsock CID; default: the one create-vm.sh recorded, else 3),
# --no-window (headless), --no-unlock. Extra environment reaches run-vphone.sh (TOOLBAR=0, MEM=...).
set -Eeuo pipefail
# shellcheck disable=SC1091  # this checkout's own lib/common.sh, resolved at run time
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

T=$VSETUP_SRC/tools
QEMU_RUN=$VSETUP_SRC/run-vphone.sh
NAME='' CID_OPT='' WINDOW_OPT=1 UNLOCK=1 MODE=start
while [ $# -gt 0 ]; do
  case $1 in
    --list)      MODE=list ;;
    --stop)      MODE=stop ;;
    --cid)       CID_OPT=$2; shift ;;
    --no-window) WINDOW_OPT=0 ;;
    --no-unlock) UNLOCK=0 ;;
    -h|--help)   sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    -*)          die "unknown option $1 (see --help)" ;;
    *)           NAME=$1 ;;
  esac
  shift
done

# A VM is a folder with a Disk.img and its ROMs; create-vm.sh's are complete once "booted" is
# in their state file.
vms() {
  local d
  for d in "$VSETUP_DEVICES"/*/; do
    d=${d%/}
    [ -e "$d/Disk.img" ] && grep -qxs booted "$d/.create-state" && basename "$d"
  done
  return 0
}
# The QEMU running this VM's disk, if any (by the disk's path on its command line).
qemu_of() {
  local p
  for p in $(pgrep -x qemu-system-aar || true); do
    tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | grep -q "file=$1/Disk.img" && { echo "$p"; return 0; }
  done
  return 1
}
cid_of() { [ -n "$CID_OPT" ] && echo "$CID_OPT" || cat "$1/cid" 2>/dev/null || echo 3; }
vphoned() { CID=$1 VPHONED_TIMEOUT=${3:-30} "$T/vphoned.sh" POST /v1/rpc "$2"; }

if [ "$MODE" = list ]; then
  mapfile -t all < <(vms)
  [ ${#all[@]} -gt 0 ] || { log "no VMs in $VSETUP_DEVICES yet: make one with ./setup/create-vm.sh"; exit 0; }
  for n in "${all[@]}"; do
    if p=$(qemu_of "$VSETUP_DEVICES/$n"); then s="running (QEMU pid $p)"; else s="stopped"; fi
    printf '  %-32s %s, vsock CID %s\n' "$n" "$s" "$(cid_of "$VSETUP_DEVICES/$n")"
  done
  exit 0
fi

# Which VM.
if [ -n "$NAME" ]; then
  if [ -d "$NAME" ]; then VM=$(cd "$NAME" && pwd); else VM=$VSETUP_DEVICES/$NAME; fi
  [ -e "$VM/Disk.img" ] || die "no VM at $VM (./setup/start-vm.sh --list shows them)"
else
  mapfile -t all < <(vms)
  case ${#all[@]} in
    0) die "no VMs in $VSETUP_DEVICES yet: make one with ./setup/create-vm.sh" ;;
    1) VM=$VSETUP_DEVICES/${all[0]} ;;
    *)
      echo "Choose the VM:" >&2
      for ((i = 0; i < ${#all[@]}; i++)); do printf ' %2d) %s\n' $((i + 1)) "${all[$i]}" >&2; done
      read -rp "Choice: " choice
      if ! [[ $choice =~ ^[0-9]+$ ]] || [ "$choice" -lt 1 ] || [ "$choice" -gt ${#all[@]} ]; then
        die "no such choice"
      fi
      VM=$VSETUP_DEVICES/${all[choice - 1]} ;;
  esac
fi
CID=$(cid_of "$VM")

if [ "$MODE" = stop ]; then
  p=$(qemu_of "$VM") || { log "$(basename "$VM") is not running"; exit 0; }
  log "shutting $(basename "$VM") down (QEMU pid $p)"
  vphoned "$CID" '{"method":"system.shutdown","params":{"force":true},"id":1}' >/dev/null ||
    die "vphoned did not answer on CID $CID: close the VM's window to power it off"
  for _ in $(seq 1 60); do [ -d "/proc/$p" ] || { log "stopped"; exit 0; }; sleep 2; done
  die "QEMU $p is still running after 2 minutes: close its window to power it off"
fi

# Start.
[ -x "$QEMU_RUN" ] || die "missing $QEMU_RUN: run ./setup/setup.sh first"
if p=$(qemu_of "$VM"); then
  log "$(basename "$VM") is already running (QEMU pid $p)"
  exit 0
fi
# Another VM on the same vsock CID would take vphoned's channel.
for p in $(pgrep -x qemu-system-aar || true); do
  tr '\0' '\n' < "/proc/$p/cmdline" 2>/dev/null | grep -q -E "guest-cid=$CID(,|\$)" &&
    die "vsock CID $CID is taken by QEMU pid $p: pass --cid N (another number from 3)"
done
log "starting $(basename "$VM") (vsock CID $CID); its log: $VM/serial.log"
# Its own session: a Ctrl+C here, or closing this terminal, leaves the VM running.
GFX=1 WINDOW=$WINDOW_OPT CID=$CID setsid "$QEMU_RUN" "$VM" > "$VM/serial.log" 2>&1 < /dev/null &
qpid=
for _ in $(seq 1 60); do qpid=$(qemu_of "$VM") && break; sleep 1; done
[ -n "$qpid" ] || die "QEMU did not start; see $VM/serial.log"
[ "$UNLOCK" = 1 ] || { log "started (QEMU pid $qpid)"; exit 0; }

log "waiting for iOS (1-3 minutes)"
for i in $(seq 1 90); do
  CID=$CID VPHONED_TIMEOUT=10 timeout 15 "$T/vphoned.sh" GET /v1/health 2>/dev/null | grep -q '"status":"ok"' && break
  [ -d "/proc/$qpid" ] || die "QEMU exited; see $VM/serial.log"
  [ "$i" = 90 ] && die "iOS did not answer in 15 minutes; see $VM/serial.log"
  sleep 10
done
for i in $(seq 1 20); do
  vphoned "$CID" '{"method":"screen.unlock","params":{},"id":1}' 120 2>/dev/null | grep -q '"locked":false' && {
    log "$(basename "$VM") is up and unlocked."
    log "  stop it:  ./setup/start-vm.sh --stop ${NAME:-$(basename "$VM")}   (or close its window)"
    exit 0
  }
  sleep 15
done
warn "iOS is up but the screen did not unlock; swipe up in the window"
