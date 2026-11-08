#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
vm=$tmp/vm
mkdir -p "$vm"
printf '0x1234\n' > "$vm/ecid"
printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict/></plist>' > "$vm/config.plist"
: > "$vm/nvram.bin"
: > "$vm/Disk.img"
: > "$vm/AVPBooter.vresearch1.bin"
: > "$vm/AVPSEPBooter.vresearch1.bin"

cat > "$tmp/qemu" <<'QEMU'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$QEMU_ARGS_FILE"
QEMU
chmod +x "$tmp/qemu"

QEMU="$tmp/qemu" QEMU_ARGS_FILE="$tmp/qemu-args" GFX=0 CID=0 GDB=12345 \
  bash "$root/run-vphone.sh" "$vm" > /dev/null
grep -Fxq 'tcp:127.0.0.1:12345' "$tmp/qemu-args"
if grep -Fxq 'tcp::12345' "$tmp/qemu-args"; then
  echo 'FAIL: GDB endpoint is not restricted to loopback' >&2
  exit 1
fi
echo 'ok: GDB endpoint binds to loopback'
