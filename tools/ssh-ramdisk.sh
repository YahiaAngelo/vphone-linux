#!/bin/bash
# SSH into the booted SSH ramdisk over usbmuxd (dropbear, root/alpine).
#   tools/ssh-ramdisk.sh 'id; mount'
# Optional env: VPHONE_ECID pins the VM identity; USBMUX_DEVICE must agree.
set -euo pipefail

proxy="$(cd "$(dirname "$0")" && printf '%s/usbmux-connect.py' "$PWD")"
ASKPASS="${SSH_ASKPASS:-}"
if [[ -n "$ASKPASS" ]]; then
    [[ -f "$ASKPASS" && -x "$ASKPASS" ]] || { echo "error: SSH_ASKPASS must name an executable helper" >&2; exit 1; }
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
    -o "ProxyCommand=exec /usr/bin/python3 '$proxy' proxy 22" \
    -o NumberOfPasswordPrompts=1 \
    -o ConnectTimeout=15 \
    -o PreferredAuthentications=password,keyboard-interactive \
    root@vphone "$@"
