#!/bin/bash
# Build on Linux with xtool's Darwin SDK bundle, clang, ld64.lld and rcodesign.
# An explicit prebuilt bootstrap can instead be passed to staging through
# VPHONE_SSHRD_BOOTSTRAP. It undergoes the same code-signature validation.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")" && pwd)
OUT=${1:?usage: build.sh OUT|--check}
BUNDLE=${DARWIN_SDK_BUNDLE:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}
SDK=${SDKROOT:-$BUNDLE/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk}
CC=${CC:-clang}
LINKER=${LD64_LLD:-$BUNDLE/toolset/bin/ld64.lld}
SIGNER=${RCODESIGN:-${VPHONE_RCODESIGN:-rcodesign}}
for tool in "$CC" "$LINKER" "$SIGNER"; do
    command -v "$tool" >/dev/null || { echo "missing bootstrap build tool: $tool (or set VPHONE_SSHRD_BOOTSTRAP to a validated prebuilt)" >&2; exit 1; }
done
[ -d "$SDK" ] || { echo "missing iPhoneOS SDK: $SDK (set DARWIN_SDK_BUNDLE or SDKROOT)" >&2; exit 1; }
[ "$OUT" != --check ] || exit 0
mkdir -p "$(dirname "$OUT")"
WORK=$(mktemp -d "$(dirname "$OUT")/.sshrd-build.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
"$CC" --target=arm64-apple-ios16.0 -isysroot "$SDK" -std=c11 -O2 -Wall -Wextra -Werror \
    -Wno-deprecated-declarations -c "$ROOT/main.c" -o "$WORK/bootstrap.o"
"$LINKER" -arch arm64 -platform_version ios 16.0 16.0 -syslibroot "$SDK" \
    -lSystem -framework CoreFoundation -framework IOKit -o "$WORK/bootstrap" "$WORK/bootstrap.o"
"$SIGNER" sign --binary-identifier org.vphone.sshramdisk-bootstrap \
    --entitlements-xml-file "$ROOT/entitlements.plist" "$WORK/bootstrap"
python3 "$ROOT/check.py" "$WORK/bootstrap"
chmod 755 "$WORK/bootstrap"
mv "$WORK/bootstrap" "$OUT"
