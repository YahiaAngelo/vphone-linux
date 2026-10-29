#!/bin/bash
# Check this PC against vphone-linux's requirements (docs/SETUP.md). Changes nothing.
ok=0; warn() { echo "  ! $*"; ok=1; }; pass() { echo "  ok $*"; }
echo "vphone-linux host check"
[ "$(uname -m)" = x86_64 ] && pass "x86_64" || warn "not x86_64 ($(uname -m)); only x86_64 hosts are supported"
n=$(nproc); [ "$n" -ge 12 ] && pass "$n CPU threads" || warn "$n CPU threads; 12 or more recommended (the guest has 8 vCPUs, SMP= lowers it)"
mem=$(awk '/MemTotal/{print int($2/1048576)}' /proc/meminfo)
[ "$mem" -ge 15 ] && pass "${mem} GB RAM" || warn "${mem} GB RAM; 16 GB minimum"
shm=$(df -BG --output=avail /dev/shm | tail -1 | tr -dc 0-9)
[ "$shm" -ge 9 ] && pass "/dev/shm has ${shm} GB free" || warn "/dev/shm has ${shm} GB free; the guest's RAM (MEM, default 8G) lives there"
if command -v vulkaninfo >/dev/null; then
  g=$(vulkaninfo --summary 2>/dev/null | awk -F= '/deviceName/{print $2; exit}')
  [ -n "$g" ] && pass "Vulkan GPU:$g" || warn "vulkaninfo found no Vulkan GPU"
else warn "vulkaninfo not installed (package vulkan-tools); can't check the GPU"; fi
[ -r /dev/vhost-vsock ] && [ -w /dev/vhost-vsock ] && pass "/dev/vhost-vsock usable" \
  || warn "/dev/vhost-vsock missing or not read/write for you (sudo modprobe vhost_vsock; see docs/SETUP.md)"
m=$(cat /proc/sys/vm/max_map_count)
[ "$m" -ge 1048576 ] && pass "vm.max_map_count = $m" || warn "vm.max_map_count = $m; set 1048576 or more (docs/SETUP.md)"
command -v cargo >/dev/null && pass "Rust (cargo)" || warn "Rust not installed (https://rustup.rs)"
command -v ninja >/dev/null && command -v meson >/dev/null && pass "meson and ninja" || warn "meson or ninja missing"
[ -e /usr/include/lzfse.h ] || [ -e /usr/local/include/lzfse.h ] && pass "lzfse" \
  || warn "lzfse missing (Fedora: lzfse-devel, Debian: liblzfse-dev, Arch: AUR lzfse)"
if [ -e /usr/lib/liblzfse.a ] && objdump -h /usr/lib/liblzfse.a 2>/dev/null | grep '\.gnu\.lto_' >/dev/null; then
  warn "liblzfse.a was built with LTO; Swift cannot link it (re-run ./setup/setup.sh deps to rebuild it)"
fi
ldconfig -p | grep 'libxml2\.so\.2 ' >/dev/null && pass "libxml2.so.2 (for the Swift toolchain)" \
  || warn "libxml2.so.2 missing; the Swift toolchain needs it (Arch: libxml2-legacy)"
[ $ok = 0 ] && echo "All checks passed." || echo "Fix the items marked ! before building or booting."
exit $ok
