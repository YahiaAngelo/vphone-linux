#!/usr/bin/env bash
# Tests for the ./vphone launcher CLI: discovery, argument forwarding and
# selection. Uses a fake VM library and a stub start-vm.sh, so it never boots
# QEMU and is safe next to a running VM.
set -Eeuo pipefail
cd "$(dirname "$0")/../.."
repo_root=$(pwd -P)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/devices/alpha" "$tmp/bin"
: > "$tmp/devices/alpha/Disk.img"
printf 'prepare\nbooted\n' > "$tmp/devices/alpha/.create-state"
printf '7\n' > "$tmp/devices/alpha/cid"
printf 'fake boot line\n' > "$tmp/devices/alpha/serial.log"
# A folder create-vm.sh has only prepared: Disk.img exists, but the final
# "booted" step has not run. It must not be auto-selected or listed.
mkdir -p "$tmp/devices/half"
: > "$tmp/devices/half/Disk.img"
printf 'prepare\n' > "$tmp/devices/half/.create-state"
cat > "$tmp/bin/start-vm.sh" <<'STUB'
#!/usr/bin/env bash
printf 'STUB'
printf ' [%s]' "$@"
printf '\n'
STUB
chmod +x "$tmp/bin/start-vm.sh"

export VSETUP_DEVICES="$tmp/devices" VPHONE_START="$tmp/bin/start-vm.sh"
export PATH="$tmp/bin:$PATH"
unset VPHONE_VM || true

./vphone --help | grep -q '^Usage: vphone'
./vphone help | grep -q '^Usage: vphone'

# install puts a working symlink on PATH; it refuses to replace a real file.
mkdir -p "$tmp/bin2" "$tmp/bin3"
VPHONE_BIN_DIR="$tmp/bin2" ./vphone install | grep -q 'linked'
[ -L "$tmp/bin2/vphone" ]
"$tmp/bin2/vphone" --help | grep -q '^Usage: vphone'
printf '#!/usr/bin/env bash\n' > "$tmp/bin3/vphone"
if VPHONE_BIN_DIR="$tmp/bin3" ./vphone install > "$tmp/out" 2>&1; then
  echo "FAIL: install should not replace a real file" >&2
  exit 1
fi
# A trailing slash on either the bin dir or the PATH entry is still on PATH.
mkdir -p "$tmp/bin4"
PATH="$tmp/bin4/:$PATH" VPHONE_BIN_DIR="$tmp/bin4/" ./vphone install > "$tmp/out"
grep -q 'linked' "$tmp/out"
if grep -q 'not on PATH' "$tmp/out"; then
  echo "FAIL: install warned about a trailing slash on PATH" >&2
  cat "$tmp/out" >&2
  exit 1
fi
# Replacing a symlink from another checkout prints where it used to point.
mkdir -p "$tmp/bin5"
ln -s /tmp/another-checkout/vphone "$tmp/bin5/vphone"
VPHONE_BIN_DIR="$tmp/bin5" ./vphone install > "$tmp/out"
grep -q 'another-checkout' "$tmp/out"
[ "$(readlink "$tmp/bin5/vphone")" = "$repo_root/vphone" ] || {
  echo "FAIL: install did not relink to this checkout" >&2
  exit 1
}

# Only completed VMs are discovered; a half-made one can still be named.
./vphone list | grep -q 'alpha'
./vphone list | grep -q 'CID 7'
if ./vphone list | grep -q 'half'; then
  echo "FAIL: list showed a half-created VM" >&2
  exit 1
fi
./vphone status | grep -q 'stopped'
out=$(./vphone start --fast)
grep -q -- '--no-unlock' <<<"$out"
if grep -q 'half' <<<"$out"; then echo "FAIL: auto-start picked a half-created VM" >&2; exit 1; fi
out=$(./vphone --fast)
grep -q -- '--no-unlock' <<<"$out"
if grep -q 'half' <<<"$out"; then echo "FAIL: --fast picked a half-created VM" >&2; exit 1; fi
./vphone start half | grep -q '/half'
./vphone start "$tmp/devices/half" | grep -q '/half'
./vphone half | grep -q '/half'
./vphone stop alpha | grep -q -- '--stop'

# With a half-created VM and no completed one, auto-selection fails; explicit
# selection still works (e.g. to finish the first boot yourself).
mkdir -p "$tmp/halfonly/half"
: > "$tmp/halfonly/half/Disk.img"
printf 'prepare\n' > "$tmp/halfonly/half/.create-state"
if VSETUP_DEVICES="$tmp/halfonly" ./vphone start > "$tmp/out" 2>&1; then
  echo "FAIL: auto-start should reject a half-created VM" >&2
  cat "$tmp/out" >&2
  exit 1
fi
grep -q 'no completed VMs' "$tmp/out"
VSETUP_DEVICES="$tmp/halfonly" ./vphone start half | grep -q '/half'
VSETUP_DEVICES="$tmp/halfonly" ./vphone half | grep -q '/half'
[ -z "$(VSETUP_DEVICES="$tmp/halfonly" ./vphone list)" ] || {
  echo "FAIL: list showed a half-created VM" >&2
  exit 1
}

# start-vm.sh options pass through (--cid with its value, --trim, headless).
./vphone start --no-window alpha | grep -q -- '--no-window'
./vphone start --trim alpha | grep -q -- '--trim'
out=$(./vphone start --cid 9 alpha)
grep -q -- '--cid' <<<"$out"
grep -q -- '[9]' <<<"$out"
grep -q -- '/alpha' <<<"$out"
./vphone --no-window alpha | grep -q -- '--no-window'
./vphone --cid 4 alpha | grep -q -- '--cid'
if ./vphone start --cid > "$tmp/out" 2>&1; then
  echo "FAIL: --cid without a value should fail" >&2
  exit 1
fi
grep -q 'needs a value' "$tmp/out"

timeout 2 ./vphone logs > "$tmp/log" 2>/dev/null || true
grep -q 'fake boot line' "$tmp/log"

# Exercise the "running" branch with a live PID and stubbed pgrep/tr output.
# tr reports the absolute disk path start-vm.sh hands to QEMU, not the value of
# VSETUP_DEVICES (which may be relative).
export FAKE_PID=$$ QEMU_DISK="$tmp/devices/alpha/Disk.img"
cat > "$tmp/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_PID"
STUB
cat > "$tmp/bin/tr" <<'STUB'
#!/usr/bin/env bash
printf 'file=%s\n' "$QEMU_DISK"
STUB
chmod +x "$tmp/bin/pgrep" "$tmp/bin/tr"
./vphone status | grep -q 'running (QEMU pid'
./vphone list | grep -q 'running (QEMU pid'
# A relative VSETUP_DEVICES must still match that absolute QEMU path.
rel=$(realpath --relative-to="$PWD" "$tmp/devices")
if [[ $rel == /* ]]; then echo "FAIL: could not build a relative devices path" >&2; exit 1; fi
VSETUP_DEVICES="$rel" ./vphone status | grep -q 'running (QEMU pid'
VSETUP_DEVICES="$rel" ./vphone list | grep -q 'running (QEMU pid'
rm -f "$tmp/bin/pgrep" "$tmp/bin/tr"

# A second completed VM needs a name for status/stop/logs; leaving 'start'
# without a VM execs start-vm.sh, which shows its own menu.
mkdir -p "$tmp/devices/beta"
: > "$tmp/devices/beta/Disk.img"
printf 'booted\n' > "$tmp/devices/beta/.create-state"
printf '8\n' > "$tmp/devices/beta/cid"
if ./vphone status > "$tmp/out" 2>&1; then
  echo "FAIL: expected an ambiguous-VM error" >&2
  cat "$tmp/out" >&2
  exit 1
fi
out=$(./vphone </dev/null)
grep -q '^STUB \[\]$' <<<"$out" || {
  echo "FAIL: expected start-vm.sh to show its menu, got: $out" >&2
  exit 1
}
VPHONE_VM=alpha ./vphone status | grep -q 'alpha'
VPHONE_VM="$tmp/devices/beta" ./vphone status | grep -q 'beta'
./vphone start beta | grep -q '/beta'
./vphone status half | grep -q 'half'

echo 'OK vphone CLI'
