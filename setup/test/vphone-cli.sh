#!/usr/bin/env bash
# Tests for the ./vphone launcher CLI: discovery, argument forwarding and
# selection. Uses a fake VM library and a stub start-vm.sh, so it never boots
# QEMU and is safe next to a running VM.
set -Eeuo pipefail
cd "$(dirname "$0")/../.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/devices/alpha" "$tmp/bin"
: > "$tmp/devices/alpha/Disk.img"
printf '7\n' > "$tmp/devices/alpha/cid"
printf 'fake boot line\n' > "$tmp/devices/alpha/serial.log"
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

./vphone list | grep -q 'alpha'
./vphone list | grep -q 'CID 7'
./vphone status | grep -q 'stopped'
./vphone start --fast | grep -q -- '--no-unlock'
./vphone --fast | grep -q -- '--no-unlock'
./vphone stop alpha | grep -q -- '--stop'

timeout 2 ./vphone logs > "$tmp/log" 2>/dev/null || true
grep -q 'fake boot line' "$tmp/log"

# Exercise the "running" branch with a live PID and stubbed pgrep/tr output.
export FAKE_PID=$$
cat > "$tmp/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_PID"
STUB
cat > "$tmp/bin/tr" <<'STUB'
#!/usr/bin/env bash
printf 'file=%s/alpha/Disk.img\n' "$VSETUP_DEVICES"
STUB
chmod +x "$tmp/bin/pgrep" "$tmp/bin/tr"
./vphone status | grep -q 'running (QEMU pid'
./vphone list | grep -q 'running (QEMU pid'
rm -f "$tmp/bin/pgrep" "$tmp/bin/tr"

# A second VM makes selection ambiguous unless one is named.
mkdir -p "$tmp/devices/beta"
: > "$tmp/devices/beta/Disk.img"
printf '8\n' > "$tmp/devices/beta/cid"
if ./vphone status > "$tmp/out" 2>&1; then
  echo "FAIL: expected an ambiguous-VM error" >&2
  cat "$tmp/out" >&2
  exit 1
fi
VPHONE_VM=alpha ./vphone status | grep -q 'alpha'
VPHONE_VM="$tmp/devices/beta" ./vphone status | grep -q 'beta'
./vphone start beta | grep -q '/beta'

echo 'OK vphone CLI'
