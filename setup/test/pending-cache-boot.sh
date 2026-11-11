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
: "${QEMU_MARKER:?}"
: > "$QEMU_MARKER"
QEMU
chmod +x "$tmp/qemu"
real_python=$(command -v python3)
mkdir -p "$tmp/bin"
cat > "$tmp/bin/python3" <<'PYTHON'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  */tools/nvram-autoboot.py)
    test "$2" = "$EXPECTED_NVRAM"
    test "$3" = --auto-boot
    test "$4" = false
    test "$5" = --require-auto-boot
    [ "${NVRAM_FAIL:-0}" = 0 ] || exit 7
    : > "$NVRAM_MARKER"
    exit 0
    ;;
esac
exec "$REAL_PYTHON" "$@"
PYTHON
chmod +x "$tmp/bin/python3"

run_vm() {
  PATH="$tmp/bin:$PATH" REAL_PYTHON="$real_python" EXPECTED_NVRAM="$vm/nvram.bin" \
    NVRAM_MARKER="$tmp/nvram-forced-dfu" QEMU="$tmp/qemu" QEMU_MARKER="$tmp/qemu-ran" GFX=0 CID=0 \
    bash "$root/run-vphone.sh" "$@" "$vm" > /dev/null 2>"$tmp/stderr"
}

pending=$vm/.vphone-dsc-pending.json
for kind in regular symlink directory; do
  rm -rf "$pending" "$tmp/qemu-ran"
  case $kind in
    regular) : > "$pending" ;;
    symlink) ln -s "$tmp/absent" "$pending" ;;
    directory) mkdir "$pending" ;;
  esac
  if run_vm; then
    echo "FAIL: boot accepted a $kind pending-cache entry" >&2
    exit 1
  fi
  if [ -e "$tmp/qemu-ran" ]; then
    echo "FAIL: QEMU started with a $kind pending-cache entry" >&2
    exit 1
  fi
  grep -q 'unresolved dyld cache publication' "$tmp/stderr"
  run_vm --dfu
  test -e "$tmp/qemu-ran"
  test -e "$tmp/nvram-forced-dfu"
  [ -e "$pending" ] || [ -L "$pending" ]
  rm -f "$tmp/qemu-ran" "$tmp/nvram-forced-dfu"
  if NVRAM_FAIL=1 run_vm --dfu; then
    echo 'FAIL: DFU boot ignored NVRAM preparation failure' >&2
    exit 1
  fi
  test ! -e "$tmp/qemu-ran"
done

rm -rf "$pending" "$tmp/qemu-ran"
run_vm
test -e "$tmp/qemu-ran"
rm -f "$tmp/qemu-ran"
# A fresh VM has zeroed NVRAM and no journal. Preserve its existing DFU path.
NVRAM_FAIL=1 run_vm --dfu
test -e "$tmp/qemu-ran"
echo 'ok: pending cache entries fence normal boot and allow only prepared DFU recovery'
