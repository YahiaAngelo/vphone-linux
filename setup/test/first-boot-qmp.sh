#!/usr/bin/env bash
# Exercise the real first-boot function with a fake launcher, without starting a VM.
# shellcheck disable=SC2317,SC2329  # mock callbacks are invoked by the sourced boot_vm
# shellcheck disable=SC2030,SC2031  # each fixture sets an independent subshell environment
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source_file=${1:-$root/create-vm.sh}
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT

sed -n '/^boot_vm() {$/,/^}$/p' "$source_file" > "$temporary/boot-vm.sh"
sed -n '/^do_first_boot() {$/,/^}$/p' "$source_file" > "$temporary/first-boot.sh"
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

check="$temporary/caller \"\$(literal)\"; check.sh"
cat > "$check" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' check >> "$EVENT_LOG"
printf '%s\0' "$@" > "$CHECK_ARGS"
exit "$CHECK_STATUS"
EOF
chmod 700 "$check"

run_first_boot() {
  local directory=$temporary/$1 selected=$2 check_status=$3 dry_run=$4
  mkdir -p "$directory/VM with spaces"
  (
    export VM="$directory/VM with spaces" CID=41 T=/unused/tools QEMU_RUN=/unused/run GFX=1 WINDOW=1
    export CHECK_STATUS=$check_status
    if [ "$selected" = unset ]; then unset VPHONE_FIRST_BOOT_CHECK
    else export VPHONE_FIRST_BOOT_CHECK="$selected"; fi
    export EVENT_LOG="$directory/events" CHECK_ARGS="$directory/check-arguments"
    export DRY=$dry_run SCALE=2 TRIM=1 VPHONE_MIGRATION_TIMEOUT=60
    [ "$DRY" = 0 ] || SCALE=3
    record() { printf '%s\n' "$*" >> "$EVENT_LOG"; }
    log() { :; }
    warn() { printf '%s\n' "$*" >&2; }
    die() { printf '%s\n' "$*" >&2; exit 1; }
    boot_vm() { record boot; }
    unlock_vm() { record unlock; }
    wait_vm_exit() { record exited; }
    python3() { case $1 in /*) record "${1##*/}" ;; esac; }
    dry() { record "dry:$*"; }
    vrpc() {
      case $1 in
        *setup.status*) record ready; printf '{"data_migration_done":true}\n' ;;
        *setup.skip*) record skip ;;
        *system.shutdown*) record shutdown ;;
        *) exit 2 ;;
      esac
    }
    # shellcheck disable=SC1091  # extracted from the actual source under test
    source "$temporary/first-boot.sh"
    do_first_boot
  ) > "$directory/stdout" 2> "$directory/stderr"
}

assert_events() {
  local name=$1 expected_events=$2
  diff -u <(printf '%s\n' "$expected_events") "$temporary/$name/events"
}

after=$'skip\nunlock\nauto-lock-never.py\nguest-dt-scale.py\nservice-profile.py\nshutdown\nexited\nboot\nunlock'
run_first_boot default unset 0 0
assert_events default $'boot\nready\n'"$after"
[ ! -e "$temporary/default/check-arguments" ]
run_first_boot empty '' 0 0
assert_events empty $'boot\nready\n'"$after"

run_first_boot accepted "$check" 0 0
assert_events accepted $'boot\nready\ncheck\n'"$after"
mapfile -d '' -t check_args < "$temporary/accepted/check-arguments"
[ "${#check_args[@]}" = 2 ]
[ "${check_args[0]}" = "$temporary/accepted/VM with spaces" ]
[ "${check_args[1]}" = 41 ]

if run_first_boot refused "$check" 7 0; then
  echo 'FAIL: rejected caller check did not stop first boot' >&2
  exit 1
fi
assert_events refused $'boot\nready\ncheck'
grep -Fq 'first-boot caller check failed; setup changes were not applied' "$temporary/refused/stderr"

run_first_boot dry "$check" 7 1
assert_events dry "dry:env GFX=1 WINDOW=1 CID=41 /unused/run $temporary/dry/VM with spaces
dry:/unused/tools/vphoned.sh POST /v1/rpc {\"method\":\"setup.status\",...}
dry:$check $temporary/dry/VM with spaces 41
dry:/unused/tools/vphoned.sh POST /v1/rpc {\"method\":\"setup.skip\",\"params\":{\"force\":true},\"id\":1}
dry:python3 /unused/tools/auto-lock-never.py $temporary/dry/VM with spaces 41
dry:python3 /unused/tools/service-profile.py 41 trimmed"
[ ! -e "$temporary/dry/check-arguments" ]

# Use the full entry point to prove refusal precedes creating a VM or preparing firmware.
touch "$temporary/not executable"
for invalid in setup/test/first-boot-qmp.sh "$temporary/missing" "$temporary" "$temporary/not executable"; do
  if VPHONE_FIRST_BOOT_CHECK="$invalid" VSETUP_DEVICES="$temporary/uncreated" \
    bash "$source_file" --device iPhone17,3 --ios 26.6.2 --name invalid -y \
    > "$temporary/invalid.stdout" 2> "$temporary/invalid.stderr"; then
    echo 'FAIL: invalid first-boot caller check was accepted' >&2
    exit 1
  fi
  grep -Fq 'VPHONE_FIRST_BOOT_CHECK must name an absolute executable regular file' "$temporary/invalid.stderr"
  [ ! -e "$temporary/uncreated" ]
done
printf 'OK: caller checks gate setup changes, preserve literal arguments, and stay optional\n'
