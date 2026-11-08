#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
"${CC:-cc}" -std=c11 -Wall -Wextra -Werror -I "$ROOT/tests/sshramdisk-bootstrap" \
    "$ROOT/tests/sshramdisk-bootstrap/identity.c" -o "$WORK/identity"
"$WORK/identity"
