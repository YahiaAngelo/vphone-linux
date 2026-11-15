#!/bin/bash
# bench-config.sh NAME RUNS [ENV=VAL...]: boot the overlay VM with the given environment, wait for vphoned,
# run guestbench RUNS times (tools/guestbench/run.py, one warm-up first) and append the median line to
# ~/Work/runs/bench/results.txt. Leaves the VM running.
set -u
NAME=$1; RUNS=$2; shift 2
OUT=~/Work/runs/bench/$NAME; mkdir -p $OUT
cd ~/Work/vphone-linux
pkill -x qemu-system-aar; sleep 3
(env "$@" VSOCK=vhost REIMS_VGPU_LOG=warn MEM=6G GFX=1 WINDOW=1 ACCEL=kvm SMP=6 CID=3 TMPDIR=~/Work/tmp \
   QEMU=$PWD/qemu/build-kvm/qemu-system-aarch64 LOG=$OUT/qemu.log timeout 10800 setsid \
   ./run-vphone.sh $HOME/Work/tmp/vphone-ovl -gdb tcp:127.0.0.1:1234 </dev/null > $OUT/serial.log 2>&1 &)
S0=$SECONDS; sleep 30
until timeout 120 tools/vphoned.sh -c 3 GET /v1/health 2>/dev/null | grep -q '"setup_pending":false'; do
  if [ $((SECONDS - S0)) -ge 400 ] || grep -aq "panic(cpu" $OUT/serial.log; then
    echo "$(date +%T) $NAME: no vphoned after $((SECONDS - S0)) s $*" | tee -a ~/Work/runs/bench/results.txt; exit 1
  fi
  sleep 5
done
boot=$((SECONDS - S0))
sleep 60    # let the boot's background work settle
timeout 1800 python3 tools/guestbench/run.py --cid 3 --runs $RUNS > $OUT/bench.txt 2>&1
echo "$(date +%T) $NAME boot ${boot}s $(grep median $OUT/bench.txt) | $*" | tee -a ~/Work/runs/bench/results.txt
