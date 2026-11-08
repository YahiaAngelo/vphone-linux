#!/usr/bin/env bash
set -Eeuo pipefail

repo=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin"

env -u VSETUP_CACHE \
  VSETUP_SRC="$repo" VSETUP_RELEASE="$tmp/release" VSETUP_DEVICES="$tmp/devices" \
  "$repo/setup/create-vm.sh" --dry-run -y --device 'iPhone17,3' --ios 26.6.2 \
  --name cache-default-check > "$tmp/default.log" 2>&1
grep -Fq "firmware: $HOME/.cache/vphone/" "$tmp/default.log" || {
  echo 'FAIL: default firmware cache path changed' >&2
  exit 1
}

cache="$tmp/firmware cache"
VSETUP_CACHE="$cache" VSETUP_SRC="$repo" VSETUP_RELEASE="$tmp/release" \
  VSETUP_DEVICES="$tmp/devices" "$repo/setup/create-vm.sh" --dry-run -y \
  --device 'iPhone17,3' --ios 26.6.2 --name cache-override-check \
  > "$tmp/override.log" 2>&1
grep -Fq "firmware: $cache/" "$tmp/override.log" || {
  echo 'FAIL: create-vm.sh ignored VSETUP_CACHE' >&2
  exit 1
}

cat > "$tmp/bin/df" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
directory=
for argument; do directory=$argument; done
printf '%s\n' "$directory" >> "$DF_CAPTURE"
available=80
if [[ "$directory" == "${DF_LOW_SPACE_PATH:-}" ]]; then available=10; fi
printf 'Filesystem 1G-blocks Used Available Use%% Mounted on\nmock 100G 1G %sG 1%% /\n' "$available"
EOF
chmod +x "$tmp/bin/df"

# The child Bash expands its positional path after this shell passes it.
# shellcheck disable=SC2016
env -u VSETUP_CACHE VSETUP_DEVICES="$tmp/default devices" \
  DF_CAPTURE="$tmp/default-paths" PATH="$tmp/bin:$PATH" \
  bash -c 'source "$1/setup/lib/common.sh"; mkdir() { :; }; check_vm_disk_space' \
  bash "$repo"
grep -Fxq "$HOME/.cache/vphone" "$tmp/default-paths" || {
  echo 'FAIL: disk-space check did not use the default firmware cache' >&2
  exit 1
}

# shellcheck disable=SC2016
DF_CAPTURE="$tmp/override-paths" PATH="$tmp/bin:$PATH" \
  VSETUP_CACHE="$cache" VSETUP_DEVICES="$tmp/device bundles" \
  bash -c 'source "$1/setup/lib/common.sh"; check_vm_disk_space' bash "$repo"
grep -Fxq "$cache" "$tmp/override-paths" || {
  echo 'FAIL: disk-space check did not use the configured firmware cache' >&2
  exit 1
}
grep -Fxq "$tmp/device bundles" "$tmp/override-paths" || {
  echo 'FAIL: disk-space check did not use the configured VM library' >&2
  exit 1
}
if grep -Fxq "$HOME/.cache" "$tmp/override-paths"; then
  echo 'FAIL: disk-space check used the default cache filesystem after an override' >&2
  exit 1
fi

# shellcheck disable=SC2016
if output=$(DF_CAPTURE="$tmp/low-space-paths" DF_LOW_SPACE_PATH="$cache" \
  PATH="$tmp/bin:$PATH" VSETUP_CACHE="$cache" \
  VSETUP_DEVICES="$tmp/device bundles" \
  bash -c 'source "$1/setup/lib/common.sh"; check_vm_disk_space' bash "$repo" 2>&1); then
  echo 'FAIL: low free space on the configured cache filesystem was accepted' >&2
  exit 1
fi
grep -Fq "only 10 GB free under $cache" <<< "$output" || {
  echo 'FAIL: low-space diagnostic did not name the configured cache path' >&2
  exit 1
}

echo 'OK'
