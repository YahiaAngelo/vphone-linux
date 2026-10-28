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
if grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; then
  pass "WSL2 ($(uname -r)); the GPU path uses lavapipe (CPU), see docs/WSL.md"
  ls /usr/share/vulkan/icd.d/lvp_icd*.json >/dev/null 2>&1 && pass "lavapipe ICD installed" \
    || warn "lavapipe ICD missing (package mesa-vulkan-drivers)"
  [ -n "${WAYLAND_DISPLAY:-}${DISPLAY:-}" ] && pass "WSLg display" \
    || warn "no WSLg display (WINDOW=1 needs WSLg: wsl --update, guiApplications=true)"
  usbip version >/dev/null 2>&1 && pass "usbip" || warn "usbip not runnable (./setup/setup.sh deps links it)"
elif command -v vulkaninfo >/dev/null; then
  g=$(vulkaninfo --summary 2>/dev/null | awk -F= '/deviceName/{print $2; exit}')
  [ -n "$g" ] && pass "Vulkan GPU:$g" || warn "vulkaninfo found no Vulkan GPU"
else warn "vulkaninfo not installed (package vulkan-tools); can't check the GPU"; fi
[ -r /dev/vhost-vsock ] && [ -w /dev/vhost-vsock ] && pass "/dev/vhost-vsock usable" \
  || warn "/dev/vhost-vsock missing or not read/write for you (sudo modprobe vhost_vsock; see docs/SETUP.md)"
m=$(cat /proc/sys/vm/max_map_count)
[ "$m" -ge 1048576 ] && pass "vm.max_map_count = $m" || warn "vm.max_map_count = $m; set 1048576 or more (docs/SETUP.md)"
command -v cargo >/dev/null && pass "Rust (cargo)" || warn "Rust not installed (https://rustup.rs)"
command -v ninja >/dev/null && command -v meson >/dev/null && pass "meson and ninja" || warn "meson or ninja missing"
[ $ok = 0 ] && echo "All checks passed." || echo "Fix the items marked ! before building or booting."
exit $ok
