#!/usr/bin/env bash
# Exercise Swiftly init and its HOME_DIR/BIN_DIR contract in isolated locations.
set -Eeuo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
readonly swiftly_cli_path=${1:?pass a verified Swiftly 1.2.0 binary}
[[ -x $swiftly_cli_path ]] || { echo "not an executable Swiftly binary: $swiftly_cli_path" >&2; exit 2; }
swiftly_version=$("$swiftly_cli_path" init --version)
[[ $swiftly_version == 1.2.0 ]] || {
  echo "expected Swiftly 1.2.0, found $swiftly_version" >&2
  exit 2
}

test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT
stub_binary=$test_root/swiftly-stub
cat > "$stub_binary" <<'STUB'
#!/usr/bin/env bash
set -Eeuo pipefail
[[ ${1:-} == init ]] || { echo "unexpected command: ${1:-}" >&2; exit 2; }
shift
skip_install=0
no_modify_profile=0
for option in "$@"; do
  [[ $option == --skip-install ]] && skip_install=1
  [[ $option == --no-modify-profile ]] && no_modify_profile=1
done
[[ $skip_install == 1 && $no_modify_profile == 1 ]] || {
  echo 'init is missing --skip-install or --no-modify-profile' >&2
  exit 2
}
[[ ${SWIFTLY_HOME_DIR:-} == "${TMPDIR%/tmp}/private-home" ]] || {
  echo "wrong Swiftly home: ${SWIFTLY_HOME_DIR:-unset}" >&2
  exit 2
}
[[ ${SWIFTLY_BIN_DIR:-} == "$SWIFTLY_HOME_DIR/bin" ]] || {
  echo "wrong Swiftly bin: ${SWIFTLY_BIN_DIR:-unset}" >&2
  exit 2
}
case $0 in "$TMPDIR"/*) ;; *) echo "unexpected installer caller: $0" >&2; exit 2 ;; esac
mkdir -p "$SWIFTLY_HOME_DIR" "$SWIFTLY_BIN_DIR"
printf '{"home":"%s","bin":"%s"}\n' "$SWIFTLY_HOME_DIR" "$SWIFTLY_BIN_DIR" > "$SWIFTLY_HOME_DIR/config.json"
cp -- "$0" "$SWIFTLY_BIN_DIR/swiftly"
printf '%s\n' "$0" > "$SWIFTLY_HOME_DIR/caller-path"
STUB
chmod 700 "$stub_binary"

run_private_init() (
  set -Eeuo pipefail
  local kind=$1 binary=$2 base="$test_root/$1"
  export XDG_DATA_HOME="$base/xdg-data" XDG_CONFIG_HOME="$base/xdg-config" TMPDIR="$base/tmp"
  export SWIFTLY_HOME_DIR="$base/private-home"
  # A developer shell may export the real install's toolchain directory; keep it out.
  unset SWIFTLY_TOOLCHAINS_DIR
  if [[ $kind == stub ]]; then
    unset SWIFTLY_BIN_DIR
  else
    export SWIFTLY_BIN_DIR="$base/private-bin"
  fi
  mkdir -p "$XDG_DATA_HOME" "$XDG_CONFIG_HOME" "$TMPDIR"

  # shellcheck disable=SC1091
  source "$repo/setup/lib/swift.sh"
  expected_bin_dir=$SWIFTLY_HOME_DIR/bin
  [[ $kind == stub ]] || expected_bin_dir="$base/private-bin"
  [[ ${SWIFTLY_BIN_DIR:-} == "$expected_bin_dir" ]] || {
    echo "expected SWIFTLY_BIN_DIR=$expected_bin_dir, found ${SWIFTLY_BIN_DIR:-unset}" >&2
    exit 1
  }

  cp -- "$binary" "$TMPDIR/swiftly"
  chmod 700 "$TMPDIR/swiftly"
  swiftly_init "$TMPDIR/swiftly" ubuntu24.04
  [[ -f $SWIFTLY_HOME_DIR/config.json && -x $SWIFTLY_BIN_DIR/swiftly ]] || {
    echo 'Swiftly did not create config and binary in the configured private directories' >&2
    exit 1
  }
  [[ ! -x $SWIFTLY_TOOLCHAINS_DIR/6.4.1/usr/bin/swift ]] || {
    echo 'Swiftly installed a toolchain despite --skip-install' >&2
    exit 1
  }
  if [[ $kind == stub ]]; then
    caller_path=$(<"$SWIFTLY_HOME_DIR/caller-path")
    case $caller_path in "$TMPDIR"/*) ;; *) echo "unexpected installer caller path: $caller_path" >&2; exit 1 ;; esac
  fi
)

run_private_init stub "$stub_binary"
run_private_init real "$swiftly_cli_path"
echo 'OK: Swiftly init used the configured private home and bin directories'
