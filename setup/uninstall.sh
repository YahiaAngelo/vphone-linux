#!/usr/bin/env bash
# Undo setup.sh: remove what it installed and built, and nothing you had before.
#
#   ./setup/uninstall.sh             # asks before each part
#   ./setup/uninstall.sh --dry-run   # only prints what it would do
#   ./setup/uninstall.sh -y          # no questions (VMs are still kept)
#   ./setup/uninstall.sh --vms       # also delete your VMs (~/vphone-setup-work/devices)
#   ./setup/uninstall.sh --downloads # also delete what create-vm.sh and setup.sh downloaded:
#                                    #   iOS/cloudOS IPSWs (~/.cache/vphone), the extracted GPU
#                                    #   driver and the vphone-cli release (~/vphone-setup-work)
#   ./setup/uninstall.sh --all       # everything above: --vms --downloads, one question, then -y
#
# Removed:
#   - the system packages setup.sh recorded installing (~/.local/state/vphone-linux/packages.txt),
#     except those another installed package still needs; packages only vphone-linux uses
#     (lzfse, libxml2-legacy, libimobiledevice...) that were not recorded (a setup.sh older than
#     the record, or your own) are offered separately, asked even with -y;
#   - Swift and swiftly, and the swift/swiftc/swiftly commands in ~/.local/bin (a swiftly
#     setup.sh did not record installing is asked about even with -y, as it may be yours);
#   - rcodesign, and rustup only if setup.sh installed it;
#   - this checkout's build output (QEMU, reims-vgpu, linux-create, apfs.ko, usbmuxd);
#   - swiftly's lines in your shell profiles, when swiftly is removed (a .bak copy is kept);
#   - the vphone sysctl / vhost-vsock config files from docs/SETUP.md, if present.
# Kept: the checkout's sources; your VMs unless --vms; downloads unless --downloads.
# Even --all keeps packages other apps need, and a rustup you installed yourself.
set -Eeuo pipefail
# shellcheck disable=SC1091  # this checkout's own lib files, resolved at run time
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"
# shellcheck disable=SC1091
source "$VSETUP_ROOT/lib/swift.sh"

DRY=0; VMS=0; DL=0; ALL=0
while [ $# -gt 0 ]; do
  case $1 in
    -y|--yes)  VSETUP_ASSUME_YES=1 ;;
    --dry-run) DRY=1 ;;
    --vms)     VMS=1 ;;
    --downloads) DL=1 ;;
    --all)     ALL=1; VMS=1; DL=1 ;;
    -h|--help) sed -n '2,23p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
if [ "$ALL" = 1 ] && [ "$DRY" = 0 ]; then
  warn "--all deletes vphone-linux's build output, Swift, its packages, your VMs and every download."
  # Asked even with -y; after this, nothing else is asked (the package manager may still confirm).
  VSETUP_ASSUME_YES=0 confirm "Delete everything?" || die "nothing was changed"
  export VSETUP_ASSUME_YES=1
fi

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
tools=$(cat "$VSETUP_STATE/tools.txt" 2>/dev/null || true)
swift_removed=0
if [ ${#swiftfiles[@]} -gt 0 ] || [ ${#links[@]} -gt 0 ]; then
  log "Swift and swiftly:"; printf '   %s\n' "${swiftfiles[@]}" "${links[@]}"
  if grep -qx swiftly <<<"$tools"; then
    if ask "Remove Swift and swiftly (every installed toolchain)?"; then
      run rm -rf "${swiftfiles[@]}" "${links[@]}"; swift_removed=1
    fi
  else
    warn "setup.sh has no record of installing swiftly: it may be yours (or from a setup.sh older than the record)"
    if [ "$DRY" = 0 ] && VSETUP_ASSUME_YES=0 confirm "Remove Swift and swiftly anyway (every installed toolchain)?"; then
      run rm -rf "${swiftfiles[@]}" "${links[@]}"; swift_removed=1
    elif [ ${#links[@]} -gt 0 ] && ask "Remove only the swift/swiftc/swiftly commands setup put in ~/.local/bin?"; then
      run rm -f "${links[@]}"
    fi
  fi
fi

# swiftly's lines in shell profiles (they source an env.sh that is now gone)
for prof in "$HOME/.zprofile" "$HOME/.zshrc" "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bashrc" \
            "$HOME/.config/fish/conf.d/swiftly.fish" "$HOME/.config/fish/config.fish"; do
  [ "$swift_removed" = 1 ] || [ "$DRY" = 1 ] || break
  if ! { [ -f "$prof" ] && grep -qE 'swiftly/env\.(sh|fish)|# Added by swiftly' "$prof"; }; then continue; fi
  log "swiftly lines in $prof:"; grep -nE 'swiftly/env\.(sh|fish)|# Added by swiftly' "$prof" | sed 's/^/   /'
  if ask "Remove them (a copy is kept as $prof.bak)?"; then
    run cp "$prof" "$prof.bak"
    run sed -i -E '/swiftly\/env\.(sh|fish)|# Added by swiftly/d' "$prof"
  fi
done

# ------------------------------------------------------------- Rust tools ---
# rustup's tools are on PATH only in shells that sourced its env file (setup.sh sources it itself).
# shellcheck disable=SC1091  # rustup's env file, outside this checkout
if ! have cargo && [ -r "$HOME/.cargo/env" ]; then . "$HOME/.cargo/env"; fi
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
# Candidates: what setup.sh recorded installing, plus the packages only vphone-linux
# uses (removed even without a record, e.g. after a setup.sh that predates it).
# General tools (git, gcc, python, meson...) are only removed when recorded.
vphone_only_pkgs() {
  case $(distro_family) in
    arch)   echo lzfse libxml2-legacy libtatsu libimobiledevice libusbmuxd libimobiledevice-glue usbip ;;
    fedora) echo lzfse-devel libtatsu-devel libimobiledevice-devel libusbmuxd-devel libimobiledevice-glue-devel usbip ;;
    debian) echo liblzfse-dev libtatsu-dev libimobiledevice-dev libusbmuxd-dev libimobiledevice-glue-dev usbip ;;
  esac
}
# The installed packages that depend on $1 (one per line).
required_by() {
  case $(distro_family) in
    arch)   LC_ALL=C pacman -Qi "$1" 2>/dev/null | awk -F': *' '/^Required By/{print $2}' |
              tr -s ' ' '\n' | grep -vx -e None -e '' || true ;;
    fedora) dnf repoquery --installed --whatrequires "$1" --qf '%{name}\n' 2>/dev/null | grep -vx "$1" || true ;;
    debian) apt-cache rdepends --installed --no-recommends --no-suggests "$1" 2>/dev/null |
              tail -n +3 | sed 's/^[ |]*//' | grep -vx "$1" || true ;;
  esac
}

current=$(installed_pkgs)
recorded=$(cat "$VSETUP_STATE/packages.txt" 2>/dev/null || true)
cands=()
for p in $( { printf '%s\n' "$recorded"; vphone_only_pkgs | tr ' ' '\n'; } | grep -v '^$' | sort -u); do
  grep -x "$p" <<<"$current" >/dev/null && cands+=("$p")
done
# Keep any candidate another installed package needs; a candidate needed only by
# other candidates that are going too can go. Repeat until nothing changes.
declare -A keep_why=()
changed=1
while [ "$changed" = 1 ]; do
  changed=0
  for p in "${cands[@]}"; do
    [ -n "${keep_why[$p]:-}" ] && continue
    for r in $(required_by "$p"); do
      if ! printf '%s\n' "${cands[@]}" | grep -x "$r" >/dev/null || [ -n "${keep_why[$r]:-}" ]; then
        keep_why[$p]=$r; changed=1; break
      fi
    done
  done
done
pkgs=(); unrecorded=(); kept=()
for p in "${cands[@]}"; do
  if [ -n "${keep_why[$p]:-}" ]; then kept+=("$p (needed by ${keep_why[$p]})")
  elif grep -qx "$p" <<<"$recorded"; then pkgs+=("$p")
  else unrecorded+=("$p"); fi
done
# Packages only vphone-linux uses that setup.sh did not record installing: offered, asked even
# with -y, since they may be yours (setup.sh before the record installed them unrecorded).
if [ ${#unrecorded[@]} -gt 0 ]; then
  log "Packages only vphone-linux uses, with no record of setup.sh installing them (they may be yours):"
  printf '%s\n' "${unrecorded[@]}" | paste -sd' ' | fold -s -w 96 | sed 's/^/   /'
  if [ "$DRY" = 1 ] || VSETUP_ASSUME_YES=0 confirm "Remove these too?"; then pkgs+=("${unrecorded[@]}"); fi
fi

[ ${#kept[@]} -gt 0 ] && { log "Kept, other installed packages need them:"; printf '   %s\n' "${kept[@]}"; }
if [ ${#pkgs[@]} -gt 0 ]; then
  log "System packages to remove (${#pkgs[@]}):"
  printf '%s\n' "${pkgs[@]}" | paste -sd' ' | fold -s -w 96 | sed 's/^/   /'
  if ask "Remove them? (the package manager lists everything and asks again)"; then
    case $(distro_family) in
      # -u is a second guard against removing anything still needed; -s also takes
      # their own dependencies that nothing else uses.
      arch)   run sudo pacman -Rsu "${pkgs[@]}" || warn "pacman removed nothing" ;;
      fedora) run sudo dnf remove "${pkgs[@]}" || warn "dnf removed nothing" ;;
      debian) run sudo apt-get remove --autoremove "${pkgs[@]}" || warn "apt removed nothing" ;;
      *) warn "unknown distro: remove these yourself" ;;
    esac
  fi
elif [ ${#cands[@]} -eq 0 ]; then
  log "No vphone-linux system packages are installed"
fi

# ---------------------------------------------------- system config files ---
mapfile -t etc < <(existing /etc/sysctl.d/vphone.conf /etc/sysctl.d/90-vphone.conf \
  /etc/modules-load.d/vhost-vsock.conf /etc/udev/rules.d/90-vhost-vsock.rules)
if [ ${#etc[@]} -gt 0 ]; then
  log "vphone system settings (docs/SETUP.md):"; printf '   %s\n' "${etc[@]}"
  if ask "Delete them (they take effect again only after a reboot)?"; then run sudo rm -f "${etc[@]}"; fi
fi

# ------------------------------------------------------------------- VMs ---
if [ -d "$VSETUP_DEVICES" ]; then
  if [ "$VMS" = 1 ]; then
    log "VMs: $VSETUP_DEVICES ($(du -sh "$VSETUP_DEVICES" 2>/dev/null | cut -f1))"
    find "$VSETUP_DEVICES" -mindepth 1 -maxdepth 1 -printf '   %f\n' 2>/dev/null
    # Asked even with -y (but not after --all's question): this deletes the VMs themselves.
    if [ "$DRY" = 1 ] || [ "$ALL" = 1 ] || { VSETUP_ASSUME_YES=0 confirm "Delete every VM in $VSETUP_DEVICES?"; }; then
      run rm -rf "$VSETUP_DEVICES"
    fi
  else
    log "Kept your VMs in $VSETUP_DEVICES (delete them with --vms)"
  fi
fi

# -------------------------------------------------------------- downloads ---
# create-vm.sh: IPSWs and maybe the GPU driver in ~/.cache/vphone, the GPU driver it
# extracts into the release folder; setup.sh release: the vphone-cli release zip and app.
mapfile -t dls < <(existing "$HOME/.cache/vphone" "$VSETUP_RELEASE")
if [ ${#dls[@]} -gt 0 ]; then
  if [ "$DL" = 1 ]; then
    log "Downloads ($(du -shc "${dls[@]}" 2>/dev/null | tail -1 | cut -f1)):"
    for d in "${dls[@]}"; do printf '   %s\n' "$d"; find "$d" -mindepth 1 -maxdepth 1 -printf '     %f\n' 2>/dev/null; done
    if ask "Delete the downloads (create-vm.sh fetches them again next time)?"; then run rm -rf "${dls[@]}"; fi
  else
    log "Kept the downloads (delete them with --downloads):"; printf '   %s\n' "${dls[@]}"
  fi
fi
# Remove the work folder once nothing is left in it.
work=$HOME/vphone-setup-work
[ "$DRY" = 0 ] && [ -d "$work" ] && rmdir "$work" 2>/dev/null || true

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
