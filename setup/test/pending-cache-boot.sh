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

run_vm() {
  QEMU="$tmp/qemu" QEMU_MARKER="$tmp/qemu-ran" GFX=0 CID=0 \
    bash "$root/run-vphone.sh" "$vm" > /dev/null 2>"$tmp/stderr"
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
done

rm -rf "$pending" "$tmp/qemu-ran"
run_vm
test -e "$tmp/qemu-ran"
echo 'ok: pending cache entries block boot before QEMU'
