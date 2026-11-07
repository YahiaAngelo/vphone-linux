#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
machine=$(uname -m)
tmp=$(mktemp -d "${TMPDIR:-/tmp}/linux-create-release-cli.XXXXXX")
trap 'rm -rf -- "$tmp"' EXIT

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

make_executable() {
  local path=$1
  mkdir -p "$(dirname "$path")"
  cat >"$path"
  chmod +x "$path"
}

# A Debug product must not take precedence over the Release product.
wrapper_root=$tmp/wrapper
release_dir=$wrapper_root/linux-create/.build/out/out/Products/Release-linux-$machine
debug_dir=$wrapper_root/linux-create/.build/out/out/Products/Debug-linux-$machine
mkdir -p "$release_dir" "$debug_dir"
cp "$repo/linux-create/vphone-cli" "$wrapper_root/linux-create/vphone-cli"
make_executable "$release_dir/vphone-cli" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf 'release-product\n'
printf '<%s>\n' "$@"
SCRIPT
make_executable "$debug_dir/vphone-cli" <<'SCRIPT'
#!/usr/bin/env bash
printf 'debug-product\n'
SCRIPT
actual=$("$wrapper_root/linux-create/vphone-cli" --probe 'two words')
expected=$(printf 'release-product\n<--probe>\n<two words>')
[[ "$actual" == "$expected" ]] || fail "wrapper did not exec the Release product with unchanged arguments"
printf 'ok: wrapper selects Release and preserves arguments\n'

# A Debug fallback or implicit build would hide a missing Release build.
missing_root=$tmp/missing
missing_dir=$missing_root/linux-create/.build/out/out/Products/Debug-linux-$machine
mkdir -p "$missing_dir"
cp "$repo/linux-create/vphone-cli" "$missing_root/linux-create/vphone-cli"
make_executable "$missing_dir/vphone-cli" <<'SCRIPT'
#!/usr/bin/env bash
printf 'debug-product\n'
SCRIPT
build_marker=$tmp/build-ran
make_executable "$missing_root/linux-create/build.sh" <<'SCRIPT'
#!/usr/bin/env bash
set -euo pipefail
printf called > "$VPHONE_TEST_BUILD_MARKER"
SCRIPT
if VPHONE_TEST_BUILD_MARKER=$build_marker "$missing_root/linux-create/vphone-cli" --probe >"$tmp/missing.stdout" 2>"$tmp/missing.stderr"; then
  fail "wrapper unexpectedly succeeded without the Release product"
else
  result=$?
fi
[[ $result == 127 ]] || fail "missing Release product returned $result instead of 127"
grep -Fq 'Release vphone-cli is not built:' "$tmp/missing.stderr" || fail "missing Release message was not printed"
grep -Fq 'uv run limulator bootstrap cli' "$tmp/missing.stderr" || fail "bootstrap guidance was not printed"
[[ ! -e "$build_marker" ]] || fail "wrapper tried to build the product on invocation"
printf 'ok: missing Release product fails without building or falling back to Debug\n'

# Exercise build.sh with fake dependencies so configuration selection is tested without a Swift build.
build_root=$tmp/build
build_script=$build_root/linux-create/build.sh
fakebin=$tmp/bin
source_tree=$build_root/cpu-tree/vphone-cli-test
libdir=$tmp/lib
mkdir -p "$build_root/linux-create" "$build_root/setup/lib" "$source_tree/.git" "$fakebin" "$libdir"
cp "$repo/linux-create/build.sh" "$build_script"
make_executable "$build_root/linux-create/sync-sources.sh" <<'SCRIPT'
#!/usr/bin/env bash
[[ -d "$VPHONE_CLI/.git" ]]
SCRIPT
cat >"$build_root/setup/lib/common.sh" <<'SCRIPT'
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
log() { printf '%s\n' "$*"; }
distro_family() { printf 'debian'; }
SCRIPT
cat >"$build_root/setup/lib/swift.sh" <<'SCRIPT'
VPHONE_SWIFT_VERSION=6.4.1
ensure_swift() { :; }
swift_check_libs() { :; }
swift_bin() { printf 'swift-test-double'; }
SCRIPT
make_executable "$fakebin/pkg-config" <<'SCRIPT'
#!/usr/bin/env bash
[[ "$#" == 2 && "$1" == --variable=libdir && "$2" == libarchive ]] || exit 2
printf '%s\n' "$VPHONE_TEST_LIBDIR"
SCRIPT
make_executable "$fakebin/objdump" <<'SCRIPT'
#!/usr/bin/env bash
printf 'no LTO sections\n'
SCRIPT
make_executable "$fakebin/swift" <<'SCRIPT'
#!/usr/bin/env bash
[[ "${1:-}" == build ]] || exit 2
printf '%s\n' "$@" >"$VPHONE_TEST_SWIFT_ARGS"
SCRIPT
: >"$libdir/libarchive.so.13"

run_build() {
  local arguments_file=$1
  local output_file=$2
  shift 2
  env PATH="$fakebin:$PATH" \
    VPHONE_CLI="$source_tree" \
    VPHONE_TEST_LIBDIR="$libdir" \
    VPHONE_TEST_SWIFT_ARGS="$arguments_file" \
    "$build_script" "$@" >"$output_file" 2>&1
}

default_args=$tmp/default.args
default_output=$tmp/default.output
run_build "$default_args" "$default_output"
grep -Fxq -- --configuration "$default_args" || fail "default build did not request a configuration"
[[ $(tail -n 2 "$default_args") == $'--configuration\nrelease' ]] || fail "default build did not select Release"
grep -Fq "Release-linux-$machine/vphone-cli" "$default_output" || fail "default build logged the wrong product path"

explicit_args=$tmp/explicit.args
explicit_output=$tmp/explicit.output
run_build "$explicit_args" "$explicit_output" -c debug
grep -Fxq -- -c "$explicit_args" || fail "explicit -c debug was not passed to Swift"
grep -Fxq -- debug "$explicit_args" || fail "explicit Debug configuration was not passed to Swift"
[[ $(grep -Fxc -- --configuration "$explicit_args") == 0 ]] || fail "explicit Debug build also appended the Release default"
grep -Fq "Debug-linux-$machine/vphone-cli" "$explicit_output" || fail "explicit Debug build logged the wrong product path"
printf 'ok: build defaults to Release and honors explicit Debug configuration\n'
