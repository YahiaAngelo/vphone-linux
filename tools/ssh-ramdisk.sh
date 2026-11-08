#!/bin/bash
# SSH into the booted SSH ramdisk over usbmuxd (dropbear, root/alpine).
#   tools/ssh-ramdisk.sh 'id; mount'
# Optional env: VPHONE_ECID pins the VM identity; USBMUX_DEVICE must agree. VPHONE_SSH_ASKPASS
# names a password helper; a desktop-wide SSH_ASKPASS (ksshaskpass, openssh-askpass) is ignored,
# as it would prompt on screen instead of logging in.
set -euo pipefail

proxy="$(cd "$(dirname "$0")" && printf '%s/usbmux-connect.py' "$PWD")"
ASKPASS="${VPHONE_SSH_ASKPASS:-}"
if [[ -n "$ASKPASS" ]]; then
    [[ -f "$ASKPASS" && -x "$ASKPASS" ]] || { echo "error: VPHONE_SSH_ASKPASS must name an executable helper" >&2; exit 1; }
else
    ASKPASS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/vphone-askpass.XXXXXXXX")
    trap 'rm -rf -- "$ASKPASS_DIR"' EXIT
    ASKPASS="$ASKPASS_DIR/askpass.sh"
    (umask 077; printf '#!/bin/sh\necho alpine\n' > "$ASKPASS")
    chmod 700 "$ASKPASS"
fi
proxy=${proxy//%/%%}
proxy=${proxy//\'/\'\\\'\'}

export DISPLAY="${DISPLAY:-:0}"
export SSH_ASKPASS="$ASKPASS"
export SSH_ASKPASS_REQUIRE=force

setsid -w ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o "ProxyCommand=/usr/bin/python3 '$proxy' proxy 22" \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=15 \
    -o PreferredAuthentications=password,keyboard-interactive \
    root@vphone "$@"
