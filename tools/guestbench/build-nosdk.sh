#!/bin/sh
# Build guestbench for the iOS guest without the Darwin SDK: the few declarations it uses (nosdk/prelude.h)
# and text stubs of libSystem and CoreFoundation (nosdk/*.tbd) stand in for the SDK's headers and
# libraries, and ld64.lld signs it ad hoc. Same work as build.sh's build, phase by phase; only `CFSTR`
# differs (a CFString made once from the C string, where the SDK's is a constant).
set -eu
cd "$(dirname "$0")"
N=nosdk
sed '/^#include/d' guestbench.c > $N/guestbench.c
clang --target=arm64-apple-ios16.0 -nostdinc -ffreestanding -fno-builtin-printf -O2 -include $N/prelude.h \
  -c -o $N/guestbench.o $N/guestbench.c
ld64.lld -arch arm64 -platform_version ios 16.0 26.0 -adhoc_codesign -o guestbench $N/guestbench.o \
  $N/libSystem.tbd $N/CoreFoundation.tbd
rm -f $N/guestbench.o $N/guestbench.c
echo "built $(pwd)/guestbench"
