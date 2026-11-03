#!/usr/bin/env bash
# restore-wait.sh LOG COMMAND...: run a restore (vphone-cli restore ...) with its output in LOG
# (and on stderr too with SHOW=1), and return when it is done.
#
# The restore tool reports the device's "Status: restore finished" and then waits for the device
# to reboot and come back over USB. An emulated device can fail to (a crash on the way up, the
# USB/IP link dropping), and the tool then waits forever although the disk is written (issue #19).
# So once the device has said the restore finished, the tool gets RESTORE_EXIT_GRACE seconds
# (default 120) to exit by itself; then it is stopped and the restore counts as done.
# Exit status: the tool's own when it exits; 0 when it was stopped after a finished restore.
set -uo pipefail
LOG=$1; shift
GRACE=${RESTORE_EXIT_GRACE:-120}

: > "$LOG"
# Its own process group, so that stopping it stops what it started too.
setsid "$@" > "$LOG" 2>&1 < /dev/null &
pid=$!
tailer=
if [ "${SHOW:-0}" = 1 ]; then
  tail -n +1 --pid="$pid" -f "$LOG" >&2 &
  tailer=$!
fi
finished_at=
while kill -0 "$pid" 2>/dev/null; do
  if [ -z "$finished_at" ] && grep -q -i -E 'status: restore finished|restore finished' "$LOG"; then
    finished_at=$SECONDS
    echo "restore-wait: the device reports the restore finished; waiting up to ${GRACE} s for the tool" >&2
  fi
  if [ -n "$finished_at" ] && [ $((SECONDS - finished_at)) -ge "$GRACE" ]; then
    echo "restore-wait: the tool is still waiting for the device to come back; stopping it" \
         "(the restore itself finished)" >&2
    kill -- -"$pid" 2>/dev/null
    for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$pid" 2>/dev/null || break; sleep 1; done
    kill -9 -- -"$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    [ -n "$tailer" ] && kill "$tailer" 2>/dev/null
    exit 0
  fi
  sleep 5
done
wait "$pid"
rc=$?
[ -n "$tailer" ] && { sleep 1; kill "$tailer" 2>/dev/null; }
exit "$rc"
