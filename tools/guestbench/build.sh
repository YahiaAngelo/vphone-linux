#!/bin/sh
# Build guestbench for the iOS guest: clang + the Darwin SDK and ld64.lld that xtool installs
# (`xtool sdk install`), then an ad-hoc signature (rcodesign), as iOS kills unsigned code.
set -eu
cd "$(dirname "$0")"
B=${DARWIN_SDK_BUNDLE:-$HOME/.swiftpm/swift-sdks/darwin.artifactbundle}
SDK=$B/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk
clang --target=arm64-apple-ios16.0 -isysroot "$SDK" -O2 -c -o guestbench.o guestbench.c
"$B/toolset/bin/ld64.lld" -arch arm64 -platform_version ios 16.0 26.0 -syslibroot "$SDK" \
  -lSystem -framework CoreFoundation -o guestbench guestbench.o 2>&1 | grep -v "does not support linking for platform iOS" || true
rcodesign sign --code-signature-flags runtime guestbench >/dev/null
rm -f guestbench.o
echo "built $(pwd)/guestbench"
