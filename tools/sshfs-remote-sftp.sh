#!/bin/bash
# sshfs's ssh_command for the SSH ramdisk: its dropbear has no SFTP subsystem, so drop sshfs's
# "-s sftp" and run sftp-server as a command, through usbmuxd (usbmux-connect.py).
set -euo pipefail
proxy="$(cd "$(dirname "$0")" && printf '%s/usbmux-connect.py' "$PWD")"
# OpenSSH expands percent tokens before handing ProxyCommand to a shell.
proxy=${proxy//%/%%}
proxy=${proxy//\'/\'\\\'\'}
args=()
for a in "$@"; do
  [ "$a" = "-s" ] && continue
  [ "$a" = "sftp" ] && continue
  args+=("$a")
done
exec /usr/bin/ssh \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  -o "ProxyCommand=/usr/bin/python3 '$proxy' proxy 22" \
  -o PreferredAuthentications=password \
  -o NumberOfPasswordPrompts=1 \
  "${args[@]}" /usr/libexec/sftp-server
