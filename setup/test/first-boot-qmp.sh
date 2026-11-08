#!/usr/bin/env bash
# Exercise the real first-boot function with a fake launcher, without starting a VM.
# shellcheck disable=SC2317,SC2329  # mock callbacks are invoked by the sourced boot_vm
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT

sed -n '/^boot_vm() {$/,/^}$/p' "${1:-$root/create-vm.sh}" > "$temporary/boot-vm.sh"
cat > "$temporary/fake launcher.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\0' "$@" > "$ARG_LOG"
EOF
chmod 700 "$temporary/fake launcher.sh"

run_case() {
  local name=$1 socket=$2 running=$3 selected=$4
  local directory=$temporary/$name
  mkdir -p "$directory/VM with spaces"
  printf 'not launched' > "$directory/arguments"
  printf 'existing pid\n' > "$directory/VM with spaces/.qemu.pid"
  (
    export VM="$directory/VM with spaces" QEMU_RUN="$temporary/fake launcher.sh"
    export QEMU_PIDFILE="$VM/.qemu.pid" ARG_LOG="$directory/arguments"
    export GFX=1 WINDOW=0 CID=41 VPHONE_FIRST_BOOT_TIMEOUT=600
    unset VPHONE_FIRST_BOOT_QMP
    [ -z "$socket" ] || export VPHONE_FIRST_BOOT_QMP=$socket
    log() { :; }
    vphoned_up() { return 0; }
    running_vm() { QEMU_PID=987654; [ "$running" = yes ]; }
    # shellcheck disable=SC1091  # extracted from the actual source under test
    source "$temporary/boot-vm.sh"
    boot_vm
    [ "$running" = yes ] || wait "$QEMU_PID"
  )
  if [ "$running" = yes ]; then
    [ "$(cat "$directory/arguments")" = 'not launched' ]
    [ "$(cat "$directory/VM with spaces/.qemu.pid")" = 'existing pid' ]
    [ ! -e "$directory/VM with spaces/serial.log" ]
  else
    local -a actual expected=("$directory/VM with spaces")
    mapfile -d '' -t actual < "$directory/arguments"
    [ -z "$selected" ] || expected+=(-qmp "unix:$selected,server=on,wait=off")
    [ "${#actual[@]}" = "${#expected[@]}" ] || {
      printf 'FAIL %s: unexpected launcher argument count\n' "$name" >&2
      return 1
    }
    local index
    for index in "${!expected[@]}"; do
      [ "${actual[index]}" = "${expected[index]}" ] || {
        printf 'FAIL %s: launcher argument %s changed\n' "$name" "$index" >&2
        return 1
      }
    done
  fi
}

socket="$temporary/private run \"quoted\" \$(literal); path/qmp.sock"
run_case unset '' no ''
run_case opt-in "$socket" no "$socket"
run_case already-running "$socket" yes ''
printf 'OK: first-boot QMP stays optional and never relaunches a running VM\n'
