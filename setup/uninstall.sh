#!/usr/bin/env bash
# Undo setup.sh: remove what it installed and built, and nothing you had before.
#
#   ./setup/uninstall.sh             # asks before each part
#   ./setup/uninstall.sh --dry-run   # only prints what it would do
#   ./setup/uninstall.sh -y          # no questions (VMs are still kept)
#   ./setup/uninstall.sh --vms       # also delete the VMs and downloads (~/vphone-setup-work)
#
# Removed:
#   - system packages setup.sh installed (recorded in ~/.local/state/vphone-linux/packages.txt),
#     except any another installed package still needs (pacman -Rsu on Arch);
#   - Swift and swiftly, and the swift/swiftc/swiftly commands in ~/.local/bin;
#   - rcodesign, and rustup only if setup.sh installed it;
#   - this checkout's build output (QEMU, reims-vgpu, linux-create, apfs.ko, usbmuxd);
#   - swiftly's lines in your shell profiles (a .bak copy is kept);
#   - the vphone sysctl / vhost-vsock config files from docs/SETUP.md, if present.
# Kept: the checkout's sources, and your VMs unless --vms is given.
set -Eeuo pipefail
# shellcheck disable=SC1091  # this checkout's own lib files, resolved at run time
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck disable=SC1091
source "$VSETUP_ROOT/lib/swift.sh"

DRY=0; VMS=0
while [ $# -gt 0 ]; do
  case $1 in
    -y|--yes)  VSETUP_ASSUME_YES=1 ;;
    --dry-run) DRY=1 ;;
    --vms)     VMS=1 ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac; shift
done
[ "$(id -u)" != 0 ] || die "run this as your user (it uses sudo itself where needed)"

run() { # print, then run unless --dry-run
  printf '   %s\n' "$*"
  [ "$DRY" = 1 ] || "$@"
}
ask() { [ "$DRY" = 1 ] || confirm "$@"; }
existing() { local p; for p in "$@"; do [ -e "$p" ] || [ -L "$p" ] && echo "$p"; done; return 0; }
[ "$DRY" = 1 ] && log "DRY RUN: nothing is changed."

SRC=$(cd "$VSETUP_SRC" && pwd)

# ------------------------------------------------------------ build output ---
mapfile -t built < <(existing "$SRC/qemu/build" "$SRC/reims-vgpu/target" "$SRC/metal2vulkan/target" \
  "$SRC/linux-create/.build" "$SRC/linux-create/Sources" "$SRC/cpu-tree" "$SRC/.build" \
  "$SRC/OpenAVB" "$SRC/OpenSEP" "$SRC/guest-resources")
if [ ${#built[@]} -gt 0 ]; then
  log "Build output in $SRC:"; printf '   %s\n' "${built[@]}"
  if lsmod 2>/dev/null | grep -q '^apfs '; then
    warn "the apfs module is loaded; unload it later with: sudo rmmod apfs"
  fi
  if ask "Delete the build output?"; then run rm -rf "${built[@]}"; fi
fi

# --------------------------------------------------------- Swift + swiftly ---
mapfile -t swiftfiles < <(existing "$SWIFTLY_HOME_DIR" \
  "$( [ "$SWIFTLY_TOOLCHAINS_DIR" != "$SWIFTLY_HOME_DIR/toolchains" ] && echo "$SWIFTLY_TOOLCHAINS_DIR")")
links=()
for cmd in swift swiftc; do  # only the wrappers setup wrote, never a swift you installed
  f=$HOME/.local/bin/$cmd
  [ -f "$f" ] && grep -q 'Written by vphone-linux setup' "$f" && links+=("$f")
done
f=$HOME/.local/bin/swiftly
[ -L "$f" ] && case $(readlink "$f") in */swiftly/bin/swiftly) links+=("$f") ;; esac
if [ ${#swiftfiles[@]} -gt 0 ] || [ ${#links[@]} -gt 0 ]; then
  log "Swift and swiftly:"; printf '   %s\n' "${swiftfiles[@]}" "${links[@]}"
  if ask "Remove Swift and swiftly (every installed toolchain)?"; then
    run rm -rf "${swiftfiles[@]}" "${links[@]}"
  fi
fi

# swiftly's lines in shell profiles (they source an env.sh that is now gone)
for prof in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" \
            "$HOME/.config/fish/conf.d/swiftly.fish" "$HOME/.config/fish/config.fish"; do
  [ -f "$prof" ] && grep -qE 'swiftly/env\.(sh|fish)|# Added by swiftly' "$prof" || continue
  log "swiftly lines in $prof:"; grep -nE 'swiftly/env\.(sh|fish)|# Added by swiftly' "$prof" | sed 's/^/   /'
  if ask "Remove them (a copy is kept as $prof.bak)?"; then
    run cp "$prof" "$prof.bak"
    run sed -i -E '/swiftly\/env\.(sh|fish)|# Added by swiftly/d' "$prof"
  fi
done

# ------------------------------------------------------------- Rust tools ---
tools=$(cat "$VSETUP_STATE/tools.txt" 2>/dev/null || true)
if have cargo && cargo install --list 2>/dev/null | grep -q '^apple-codesign '; then
  if grep -qx rcodesign <<<"$tools"; then
    log "rcodesign was installed by setup.sh"
  else
    log "rcodesign (apple-codesign) is installed; setup.sh uses it to sign apps for the VM"
  fi
  if ask "Uninstall rcodesign?"; then run cargo uninstall apple-codesign; fi
fi
if grep -qx rustup <<<"$tools" && have rustup; then
  log "rustup was installed by setup.sh (you had no Rust before)"
  if ask "Uninstall rustup and every Rust toolchain?"; then run rustup self uninstall -y; fi
elif have rustup; then
  log "Rust (rustup) was not installed by setup.sh; keeping it"
fi

# --------------------------------------------------------- system packages ---
pkgs=()
if [ -s "$VSETUP_STATE/packages.txt" ]; then
  current=$(installed_pkgs)
  while read -r p; do
    [ -n "$p" ] && grep -qx "$p" <<<"$current" && pkgs+=("$p")
  done < "$VSETUP_STATE/packages.txt"
fi
if [ ${#pkgs[@]} -gt 0 ]; then
  log "System packages setup.sh installed (${#pkgs[@]}):"; printf '%s\n' "${pkgs[@]}" | paste -sd' ' | fold -s -w 96 | sed 's/^/   /'
  if ask "Remove the ones no other installed package needs?"; then
    case $(distro_family) in
      # -u skips any target another package still needs; -s takes along
      # dependencies nothing else uses. pacman shows the final list and asks.
      arch)   run sudo pacman -Rsu "${pkgs[@]}" ;;
      fedora) run sudo dnf remove "${pkgs[@]}" ;;   # dnf lists everything it would remove, and asks
      debian) run sudo apt-get remove --autoremove "${pkgs[@]}" ;;
      *) warn "unknown distro: remove these yourself" ;;
    esac
  fi
elif [ ! -f "$VSETUP_STATE/packages.txt" ]; then
  warn "No record of the packages setup.sh installed ($VSETUP_STATE/packages.txt)."
  warn "It is written by setup.sh since this uninstaller was added; earlier runs left none, so"
  warn "no system packages are removed. The vphone-only ones on Arch, if you want them gone:"
  warn "  sudo pacman -Rsu lzfse libxml2-legacy libtatsu libimobiledevice libusbmuxd libimobiledevice-glue usbip"
fi

# ---------------------------------------------------- system config files ---
mapfile -t etc < <(existing /etc/sysctl.d/vphone.conf /etc/sysctl.d/90-vphone.conf \
  /etc/modules-load.d/vhost-vsock.conf /etc/udev/rules.d/90-vhost-vsock.rules)
if [ ${#etc[@]} -gt 0 ]; then
  log "vphone system settings (docs/SETUP.md):"; printf '   %s\n' "${etc[@]}"
  if ask "Delete them (they take effect again only after a reboot)?"; then run sudo rm -f "${etc[@]}"; fi
fi

# ------------------------------------------------------------ VMs, release ---
work=$HOME/vphone-setup-work
if [ -d "$work" ]; then
  if [ "$VMS" = 1 ]; then
    log "VMs, firmware downloads and the vphone-cli release: $work ($(du -sh "$work" 2>/dev/null | cut -f1))"
    # Asked even with -y: this deletes the VMs themselves.
    if [ "$DRY" = 1 ] || { VSETUP_ASSUME_YES=0 confirm "Delete $work and every VM in it?"; }; then
      run rm -rf "$work"
    fi
  else
    log "Kept your VMs and downloads in $work (delete them with --vms)"
  fi
fi
[ -d "$HOME/.cache/vphone" ] && log "Firmware cache kept: $HOME/.cache/vphone (rm -rf it to free space)"

# Keep the record of anything still installed (declined, or still needed), so a
# later run can offer it again.
if [ "$DRY" = 0 ] && [ -f "$VSETUP_STATE/packages.txt" ]; then
  current=$(installed_pkgs)
  grep -xF -f <(printf '%s\n' "$current") "$VSETUP_STATE/packages.txt" > "$VSETUP_STATE/packages.txt.new" || true
  mv "$VSETUP_STATE/packages.txt.new" "$VSETUP_STATE/packages.txt"
  [ -s "$VSETUP_STATE/packages.txt" ] || rm -f "$VSETUP_STATE/packages.txt"
  have rustup || sed -i '/^rustup$/d' "$VSETUP_STATE/tools.txt" 2>/dev/null || true
  rmdir "$VSETUP_STATE" 2>/dev/null || true
fi
log "Done. The sources in $SRC are untouched; delete the folder to remove them too."
