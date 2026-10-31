# vphone-setup shared helpers. Sourced by setup.sh and create-vm.sh.
# All paths live under this checkout; nothing outside it is touched, and no
# script here ever sends signals to QEMU (booting and stopping VMs is left to
# the run tool the user drives).
# shellcheck shell=bash disable=SC2034

set -Eeuo pipefail

VSETUP_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# This setup lives IN the vphone-linux checkout it builds: the sources are
# this repo, unless a second checkout is asked for with --src.
VSETUP_SRC=${VSETUP_SRC:-$VSETUP_ROOT/..}                      # git checkout + submodules
VSETUP_RELEASE=${VSETUP_RELEASE:-$HOME/vphone-setup-work/vphone-release}  # vphone-cli release zip tree
VSETUP_DEVICES=${VSETUP_DEVICES:-$HOME/vphone-setup-work/devices}         # created VM bundles ("library")
VSETUP_DATA=${VSETUP_DATA:-$VSETUP_ROOT/data}
VPHONE_CLI_VERSION=${VPHONE_CLI_VERSION:-2.14.2}
VPHONE_CLI_PUBLIC=${VPHONE_CLI_PUBLIC:-2.14.2}                 # the pairing linux-create is synced against
VPHONE_CLI_REPO=https://github.com/Lakr233/vphone-cli.git
VPHONE_LINUX_BRANCH=${VPHONE_LINUX_BRANCH:-development}        # the branch the sources clone checks out

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

confirm() { # confirm <prompt>
  [ "${VSETUP_ASSUME_YES:-0}" = 1 ] && return 0
  local a
  printf '\033[1;34m?>\033[0m %s [y/N] ' "$*" >&2
  read -rn 1 a || a=n; printf '\n' >&2
  [ "$a" = Y ] || [ "$a" = y ]
}

# ---- jq-free JSON helpers (python3 is a base dependency anyway) ----------

_json() { python3 "$VSETUP_ROOT/lib/json_query.py" "$1" "$2"; }

# list devices:      json devices          -> id=name lines
pair_json() { _json "$1" "$2"; }

# Prettier alias so call sites read well:
pick_json() { _json "$@"; }

 detect_distro() {
  if [ -r /etc/os-release ]; then
    # shellcheck disable=SC1091  # the distro's own file, not in this checkout
    . /etc/os-release
    printf '%s\n' "${ID:-unknown}:${VERSION_ID:-}"
  else
    echo unknown:0
  fi
}

# The package family: fedora, debian or arch (derivatives such as CachyOS,
# EndeavourOS, Manjaro or Garuda map to arch through ID_LIKE).
# os_release <KEY>: one /etc/os-release field, unquoted (read, not sourced: the file sets NAME,
# VERSION... which scripts here use for their own things).
os_release() { sed -n "s/^$1=//p" /etc/os-release 2>/dev/null | tr -d "\"'" | head -1; }

distro_family() {
  local id like
  id=$(os_release ID); id=${id:-unknown}
  like=$(os_release ID_LIKE)
  case " $id $like " in
    *" arch "*|*" cachyos "*|*" manjaro "*|*" endeavouros "*) echo arch ;;
    *" fedora "*|*" rhel "*) echo fedora ;;
    *" debian "*|*" ubuntu "*|*" linuxmint "*) echo debian ;;
    *) echo "$id" ;;
  esac
}

have() { command -v "$1" >/dev/null 2>&1; }

# Omarchy (Arch + Hyprland, omarchy.org) says ID=arch; it is recognised by its own files.
is_omarchy() { have omarchy-version || [ -d /usr/share/omarchy ]; }

# WSL2 (Windows Subsystem for Linux): a Microsoft kernel with no distro headers package,
# the GPU reached through /dev/dxg (Mesa's dzn Vulkan driver) and Windows drives on /mnt.
is_wsl() { [ -n "${WSL_DISTRO_NAME:-}" ] || grep -qi microsoft /proc/sys/kernel/osrelease 2>/dev/null; }

require_root() {
  [ "$(id -u)" = 0 ] || die "this step needs root (built-in steps tell you when)"
}
