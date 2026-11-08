#!/usr/bin/env bash
# Exercise the native caller controls with extracted functions and fake helpers.
# shellcheck disable=SC1091,SC2034,SC2317,SC2329  # functions and variables are consumed by extracted callbacks
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT

sed -n '/^usb_helpers() {$/,/^}$/p' "$root/create-vm.sh" > "$temporary/usb-helpers.sh"
sed -n '/^boot_vm() {$/,/^}$/p' "$root/create-vm.sh" > "$temporary/boot-vm.sh"
sed -n '/^wait_vm_exit() {$/,/^}$/p' "$root/create-vm.sh" > "$temporary/wait-vm-exit.sh"
sed -n '/^do_first_boot() {$/,/^}$/p' "$root/create-vm.sh" > "$temporary/first-boot.sh"

cat > "$temporary/fake-launcher.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$ARG_LOG"
EOF
chmod 700 "$temporary/fake-launcher.sh"

die() { printf '%s\n' "$*" >&2; exit 1; }
log() { :; }

run_creator_ready() (
  export VPHONE_CREATOR_USB_READY=1 USBMUXD_SOCKET_ADDRESS=UNIX:/unused/socket
  DRY=1 T="$temporary"
  dry() { die "creator-ready path unexpectedly ran a fallback helper"; }
  source "$temporary/usb-helpers.sh"
  usb_helpers
)

run_first_boot_timeout() {
  local directory=$temporary/boot
  mkdir -p "$directory/VM with spaces"
  if (
    export VPHONE_FIRST_BOOT_TIMEOUT=0
    export VM="$directory/VM with spaces" QEMU_RUN="$temporary/fake-launcher.sh"
    export QEMU_PIDFILE="$VM/.qemu.pid" ARG_LOG="$directory/arguments"
    export GFX=1 WINDOW=0 CID=41
    log() { :; }
    die() { printf '%s\n' "$*" >&2; exit 1; }
    vphoned_up() { return 0; }
    running_vm() { return 1; }
    source "$temporary/boot-vm.sh"
    boot_vm
  ); then
    return 0
  else
    return 1
  fi
}

run_shutdown_timeout() (
  VM=/unused VPHONE_SHUTDOWN_TIMEOUT=0
  calls=0
  qemu_alive() { calls=$((calls + 1)); [ "$calls" = 1 ]; }
  sleep() { :; }
  die() { printf '%s\n' "$*" >&2; exit 1; }
  source "$temporary/wait-vm-exit.sh"
  wait_vm_exit
)

run_migration_timeout() (
  # 0 means no limit, so give it one second and let the first poll take two.
  DRY=0 VPHONE_MIGRATION_TIMEOUT=1
  VM=/unused DEVICE=iPhone17,3 IOS=27.1 PAIR_BUILD=22C T=/unused
  log() { :; }
  die() { printf '%s\n' "$*" >&2; exit 1; }
  boot_vm() { :; }
  vrpc() { SECONDS=$((SECONDS + 2)); return 0; }
  qemu_alive() { return 0; }
  qemu_exit_report() { :; }
  sleep() { :; }
  python3() {
    [ "${2:-}" = expected-build ] && { printf '22C\n'; return 0; }
    return 1
  }
  source "$temporary/first-boot.sh"
  do_first_boot
)

expect_failure() {
  local label=$1 expected=$2 output
  shift 2
  if output=$("$@" 2>&1); then
    printf 'FAIL %s: expected failure\n' "$label" >&2
    return 1
  fi
  case $output in
    *"$expected"*) ;;
    *) printf 'FAIL %s: unexpected failure: %s\n' "$label" "$output" >&2; return 1 ;;
  esac
}

run_creator_ready
expect_failure first-boot 'boot timeout' run_first_boot_timeout
expect_failure shutdown 'shutdown timeout' run_shutdown_timeout
expect_failure migration 'first-boot migration timed out' run_migration_timeout
printf 'OK: VPHONE readiness and timeout controls are honored\n'
