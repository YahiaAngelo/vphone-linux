#!/usr/bin/env bash
set -euo pipefail

VSETUP_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

make_fixture_zip() {
  local archive=$1 include_worker=$2 fixture resources
  fixture=$(mktemp -d "$tmp/archive.XXXXXXXX")
  resources="$fixture/app/app/VPhone.bundle/Contents/Resources"
  mkdir -p "$resources/OpenAVB" "$resources/OpenSEP" "$resources/guest-resources"
  printf 'fixture OpenAVB ROM\n' >"$resources/OpenAVB/OpenAVB.bin"
  printf 'fixture OpenSEP ROM\n' >"$resources/OpenSEP/OpenSEP.bin"
  printf '<plist/>\n' >"$resources/guest-resources/vphoned.plist"
  if [ "$include_worker" = yes ]; then
    printf 'fixture guest worker\n' >"$resources/guest-resources/vphoned"
    chmod +x "$resources/guest-resources/vphoned"
  fi
  ( cd "$fixture" && zip -qr "$archive" app )
}

run_release() {
  local source=$1 release=$2 devices=$3 log=$4
  VSETUP_SRC=$source VSETUP_RELEASE=$release VSETUP_DEVICES=$devices \
    VPHONE_CLI_PUBLIC=fixture "$VSETUP_ROOT/setup.sh" release >"$log" 2>&1
}

repair_release=$tmp/repair-release
repair_source=$tmp/repair-source
mkdir -p \
  "$repair_release/app/VPhone.bundle/Contents/Resources/OpenAVB" \
  "$repair_release/app/VPhone.bundle/Contents/Resources/OpenSEP" \
  "$repair_source"
printf 'old ROM\n' >"$repair_release/app/VPhone.bundle/Contents/Resources/OpenAVB/OpenAVB.bin"
printf 'old SEP\n' >"$repair_release/app/VPhone.bundle/Contents/Resources/OpenSEP/OpenSEP.bin"
printf 'preserve this interrupted bundle\n' >"$repair_release/app/VPhone.bundle/inspection-sentinel"
make_fixture_zip "$repair_release/VPhone-fixture.zip" yes
run_release "$repair_source" "$repair_release" "$tmp/repair-devices" "$tmp/repair.log" || {
  cat "$tmp/repair.log" >&2
  exit 1
}

repaired_bundle=$repair_release/app/VPhone.bundle
if [ ! -x "$repaired_bundle/Contents/Resources/guest-resources/vphoned" ]; then
  echo "FAIL: release setup succeeded without restoring the missing guest worker" >&2
  exit 1
fi
[ -f "$repaired_bundle/Contents/Resources/guest-resources/vphoned.plist" ] || {
  echo "FAIL: the completed release bundle is missing vphoned.plist" >&2
  exit 1
}
[ -f "$repair_source/guest-resources/vphoned" ] || {
  echo "FAIL: guest-resources does not resolve to the repaired bundle" >&2
  exit 1
}
saved_incomplete=
for candidate in "$repair_release"/app/VPhone.bundle.incomplete.*; do
  if [ -d "$candidate" ]; then saved_incomplete=$candidate; break; fi
done
if [ -z "$saved_incomplete" ] || [ ! -f "$saved_incomplete/inspection-sentinel" ]; then
  echo "FAIL: release setup did not preserve the interrupted bundle for inspection" >&2
  exit 1
fi

invalid_release=$tmp/invalid-release
invalid_source=$tmp/invalid-source
invalid_bundle=$invalid_release/app/VPhone.bundle
mkdir -p \
  "$invalid_bundle/Contents/Resources/OpenAVB" \
  "$invalid_bundle/Contents/Resources/OpenSEP"
printf 'keep old bundle\n' >"$invalid_bundle/inspection-sentinel"
make_fixture_zip "$invalid_release/VPhone-fixture.zip" no
if run_release "$invalid_source" "$invalid_release" "$tmp/invalid-devices" "$tmp/invalid.log"; then
  echo "FAIL: release setup accepted an archive without the guest worker" >&2
  exit 1
fi
grep -qi 'incomplete' "$tmp/invalid.log" || {
  cat "$tmp/invalid.log" >&2
  echo "FAIL: release setup did not identify the incomplete archive" >&2
  exit 1
}
[ -f "$invalid_bundle/inspection-sentinel" ] || {
  echo "FAIL: invalid archive replaced the existing bundle" >&2
  exit 1
}

echo "OK: release setup repairs incomplete bundles and preserves the old copy"
