# Swift toolchain helpers for the linux-create build. Sourced by setup.sh
# and linux-create/build.sh.
#
# The toolchain is installed with swiftly but called by its full path: nothing
# here needs swiftly's env.sh on PATH, and nothing puts the toolchain's own
# clang/lld ahead of the system ones (that would also be picked up by the
# QEMU and reims-vgpu builds).
# shellcheck shell=bash

_swift_here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# The one place the Swift version is pinned.
VPHONE_SWIFT_VERSION=${VPHONE_SWIFT_VERSION:-$(tr -d '[:space:]' < "$_swift_here/../../linux-create/.swift-version")}
SWIFTLY_HOME_DIR=${SWIFTLY_HOME_DIR:-$HOME/.local/share/swiftly}
SWIFTLY_TOOLCHAINS_DIR=${SWIFTLY_TOOLCHAINS_DIR:-$SWIFTLY_HOME_DIR/toolchains}
export SWIFTLY_HOME_DIR SWIFTLY_TOOLCHAINS_DIR

# The platform swiftly installs the toolchain for, always named: swiftly's own detection accepts
# only the exact releases it lists (Fedora 44 is "Unsupported Linux platform"), and swift.org
# builds each Swift release for a few of them (6.4.1: Ubuntu 22.04/24.04/26.04, Debian 12/13,
# Fedora 41, UBI 9). A newer release of a family takes its newest build, an Ubuntu between LTSes
# (25.10, Mint) the LTS below it. Arch and other rolling distros use the RHEL UBI 9 build: it
# needs only an old glibc plus libxml2.so.2 (Arch: libxml2-legacy).
swiftly_platform() {
  local id like ver major
  id=$(os_release ID); like=$(os_release ID_LIKE); ver=$(os_release VERSION_ID)
  major=${ver%%.*}
  case " $id " in
    *" ubuntu "*)
      case $ver in
        2[6-9].*|[3-9]?.*) echo ubuntu26.04 ;;
        24.*|25.*) echo ubuntu24.04 ;;
        *) echo ubuntu22.04 ;;
      esac; return ;;
    *" debian "*)
      if [ "${major:-13}" -le 12 ] 2>/dev/null; then echo debian12; else echo debian13; fi; return ;;
    *" fedora "*) echo fedora41; return ;;
  esac
  case " $like " in
    *" ubuntu "*) echo ubuntu24.04 ;;    # Mint, Pop!_OS...: their VERSION_ID is not Ubuntu's
    *" debian "*) echo debian13 ;;
    *" rhel "*|*" centos "*) echo ubi9 ;;   # RHEL 9's glibc is too old for the Fedora build
    *" fedora "*) echo fedora41 ;;
    *) echo ubi9 ;;
  esac
}

swift_bin() { echo "$SWIFTLY_TOOLCHAINS_DIR/$VPHONE_SWIFT_VERSION/usr/bin/swift"; }

# The toolchain links the narrow libncurses.so.6 (and lldb libform/libpanel);
# Arch ships only the wide-char builds, which export the same API (Arch's own
# libncurses.so points at libncursesw too). The links go inside each installed
# toolchain, in the folders its binaries search on their own (RUNPATH
# $ORIGIN/../lib/swift/linux and $ORIGIN/../lib): Swift's build system starts
# swiftc with a clean environment, so LD_LIBRARY_PATH alone does not reach it.
# The private folder below is for the few binaries with no RUNPATH
# (swift-build-tool), through the swift() wrapper.
swift_compat_dir() { echo "$SWIFTLY_HOME_DIR/vphone-compat"; }
swift_make_compat() {
  local lib dir
  for lib in ncurses form panel; do
    # the system has it (ldconfig is in /sbin, off a user's PATH on Debian)
    "$(command -v ldconfig || echo /sbin/ldconfig)" -p 2>/dev/null | grep "lib$lib\.so\.6 " >/dev/null && continue
    [ -e "/usr/lib/lib${lib}w.so.6" ] || continue
    for dir in "$(swift_compat_dir)" "$SWIFTLY_TOOLCHAINS_DIR"/*/usr/lib "$SWIFTLY_TOOLCHAINS_DIR"/*/usr/lib/swift/linux; do
      case $dir in *'*'*) continue ;; esac                         # no toolchain installed
      mkdir -p "$dir"
      [ -e "$dir/lib$lib.so.6" ] || ln -sfn "/usr/lib/lib${lib}w.so.6" "$dir/lib$lib.so.6"
    done
  done
}

# Run the pinned swift with the compat folder visible.
swift() {
  LD_LIBRARY_PATH="$(swift_compat_dir)${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "$(swift_bin)" "$@"
}

# Install swiftly (if missing) and the pinned toolchain (if missing).
ensure_swift() {
  local swiftly=$SWIFTLY_HOME_DIR/bin/swiftly plat arch tmp
  if [ -x "$(swift_bin)" ]; then swift_make_compat; return 0; fi
  plat=$(swiftly_platform); arch=$(uname -m)
  if [ ! -x "$swiftly" ]; then
    printf '==> Installing swiftly into %s\n' "$SWIFTLY_HOME_DIR"
    tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/swiftly.tar.gz" "https://download.swift.org/swiftly/linux/swiftly-$arch.tar.gz"
    tar -xzf "$tmp/swiftly.tar.gz" -C "$tmp"
    # --no-modify-profile: keep the toolchain's clang/lld off the login PATH.
    "$tmp/swiftly" init --assume-yes --skip-install --no-modify-profile --quiet-shell-followup \
      ${plat:+--platform "$plat"}
    rm -rf "$tmp"
  fi
  printf '==> Installing Swift %s with swiftly%s\n' "$VPHONE_SWIFT_VERSION" "${plat:+ (platform $plat)}"
  tmp=$(mktemp)
  # swiftly writes the distro packages it thinks are missing to $tmp. setup.sh's lists
  # (setup/lib/packages.sh) carry what the build needs, so this is only shown.
  PATH="$SWIFTLY_HOME_DIR/bin:$PATH" "$swiftly" install "$VPHONE_SWIFT_VERSION" \
    --assume-yes --post-install-file "$tmp"
  if [ -s "$tmp" ]; then
    printf 'WARN swiftly suggests these system packages (the vphone-cli build does not need them):\n' >&2
    sed 's/^/    /' "$tmp" >&2; echo >&2
  fi
  rm -f "$tmp"
  [ -x "$(swift_bin)" ] || { printf 'ERROR Swift %s did not install\n' "$VPHONE_SWIFT_VERSION" >&2; return 1; }
  swift_make_compat
  swift_check_libs
}

# The toolchain is built for other distros; make sure its libraries resolve.
swift_check_libs() {
  local dir missing
  dir=$(dirname "$(swift_bin)")
  # No LD_LIBRARY_PATH here: the build system runs these with a clean environment.
  missing=$(ldd "$dir/swift-package" "$dir/swift-frontend" "$dir/swift-driver" \
    2>/dev/null | awk '/not found/{print $1}' | sort -u)
  if [ -n "$missing" ]; then
    printf 'ERROR the Swift toolchain is missing libraries: %s\n' "$(echo "$missing" | tr '\n' ' ')" >&2
    case "$missing" in *libxml2.so.2*) printf '      on Arch: sudo pacman -S libxml2-legacy\n' >&2 ;; esac
    return 1
  fi
}

# Print PATH without swiftly's bin dir, so C builds use the system clang/lld.
path_without_swiftly() {
  printf '%s' "$PATH" | tr ':' '\n' | grep -v -e '/swiftly/bin$' -e '/swiftly/toolchains/' | paste -sd:
}
