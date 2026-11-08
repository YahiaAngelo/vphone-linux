#!/usr/bin/env bash
# Exercise the actual CFW step without invoking USB tools or creating a VM.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
create_vm=${VPHONE_TEST_CREATE_VM:-$root/create-vm.sh}
sed -n '/^do_cfw() {$/,/^}$/p' "$create_vm" > "$temporary/do-cfw.sh"
test -s "$temporary/do-cfw.sh"

usb_helpers() { :; }
dry() {
  if [ "$#" -ge 4 ] && [ "$3" = cfw ] && [ "$4" = install ]; then
    printf '%s\0' "$@" > "$ARG_LOG"
  fi
}

check_parent() (
  local expected=$1 configured=$2
  export DRY=1
  export T="$temporary" VSETUP_SRC="$temporary/source" VSETUP_DEVICES="$temporary/devices"
  export VM="$temporary/vm with spaces" NAME=cfw-test VC=/test/vphone-cli GIGALOCKER_SH=/test/gigalocker.sh
  export ECID=0x12345 CID=46 SCALE=2 ARG_LOG="$temporary/arguments"
  if [ "$configured" = __unset__ ]; then
    unset VPHONE_CFW_WORK_PARENT
  else
    export VPHONE_CFW_WORK_PARENT="$configured"
  fi
  # shellcheck disable=SC1091  # the function is extracted from this checkout above
  source "$temporary/do-cfw.sh"
  do_cfw
  local -a args=()
  mapfile -d '' -t args < "$ARG_LOG"
  local index=0
  for ((index = 0; index < ${#args[@]}; index++)); do
    if [ "${args[index]}" = --work-parent ]; then
      [ "$((index + 1))" -lt "${#args[@]}" ] || return 1
      if [ "${args[index + 1]}" != "$expected" ]; then
        printf 'FAIL: expected work parent <%s>, got <%s>\n' "$expected" "${args[index + 1]}" >&2
        return 1
      fi
      return
    fi
  done
  printf 'FAIL: no --work-parent argument was passed\n' >&2
  return 1
)

check_parent /var/tmp __unset__
check_parent /var/tmp ''
check_parent "$temporary/private CFW work" "$temporary/private CFW work"
printf 'OK: CFW work parent defaults and preserves literal paths\n'
