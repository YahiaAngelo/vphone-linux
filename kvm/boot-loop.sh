#!/bin/bash
# boot-loop.sh NAME COUNT [ENV=VAL...]: boot the overlay VM COUNT times with the given environment, each
# until vphoned reports setup done (ok), a panic, or LOOP_HANG_S (default 1200) seconds (hang: vCPU registers saved), and append
# one line per boot to ~/Work/runs/loop-NAME/results.txt. A hang also gets hang-trace.txt (KVM events) and,
# with VR_HANG_DUMP=1, the GIC dumps in serial.log (VR-DUMP).
set -u
NAME=$1; COUNT=$2; shift 2
OUT=~/Work/runs/loop-$NAME; mkdir -p $OUT
cd ~/Work/vphone-linux
for i in $(seq 1 $COUNT); do
  pkill -x qemu-system-aar; sleep 3
  R=$OUT/boot$i; mkdir -p $R
  (env "$@" VSOCK=vhost REIMS_VGPU_LOG=warn MEM=6G GFX=1 WINDOW=1 ACCEL=kvm SMP=6 CID=3 TMPDIR=~/Work/tmp \
     QEMU=$PWD/qemu/build-kvm/qemu-system-aarch64 LOG=$R/qemu.log timeout 3600 setsid \
     ./run-vphone.sh $HOME/Work/tmp/vphone-ovl -gdb tcp:127.0.0.1:1234 </dev/null > $R/serial.log 2>&1 &)
  S0=$SECONDS; result=hang
  while [ $((SECONDS - S0)) -lt ${LOOP_HANG_S:-1200} ]; do
    sleep 10
    if ! pgrep -x qemu-system-aar >/dev/null; then result=exited; break; fi
    if grep -aq "panic(cpu" $R/serial.log; then result=panic; break; fi
    if timeout 120 tools/vphoned.sh -c 3 GET /v1/health 2>/dev/null | grep -q '"setup_pending":false'; then
      result=ok; break
    fi
  done
  t=$((SECONDS - S0))
  if [ $result = hang ]; then
    # VR_HANG_DUMP=1 QEMU: two dumps of the vCPUs' lines and the GICs, 10 s apart, and 2 s of every KVM event.
    touch ~/Work/tmp/vr-dump; sleep 4; touch ~/Work/tmp/vr-dump; sleep 10
    # The guest's vsock transport: an unused port answers with a reset while it runs; a timeout means it stopped.
    for port in 9999 1339; do
      python3 -c "import socket,sys
s=socket.socket(socket.AF_VSOCK,socket.SOCK_STREAM); s.settimeout(10)
try: s.connect((3,$port)); print('port $port: connected')
except Exception as e: print('port $port:', repr(e))" >> $R/vsock-probe.txt 2>&1
    done
    T=/sys/kernel/tracing
    sudo -n sh -c "echo 0 > $T/tracing_on; echo > $T/trace; echo 16384 > $T/buffer_size_kb; echo 1 > $T/events/kvm/enable; echo 1 > $T/tracing_on; sleep 2; echo 0 > $T/tracing_on; echo 0 > $T/events/kvm/enable"
    sudo -n cat $T/trace > $R/hang-trace.txt
    printf 'target remote 127.0.0.1:1234\nset pagination off\ninfo threads\nthread apply all info registers pc cpsr sp lr x0 x1 x2 x3\nthread apply all x/6i $pc-12\ndetach\n' > $R/regs.gdb
    timeout 120 gdb -q -batch -x $R/regs.gdb > $R/regs.txt 2>&1
    top -b -H -n1 -p $(pgrep -x qemu-system-aar) | sed -n 8,14p > $R/cpu.txt
  fi
  echo "$(date +%T) boot$i $result ${t}s lines=$(wc -l < $R/serial.log) $(grep -a 'panic(cpu' $R/serial.log | head -1 | cut -c1-120)" | tee -a $OUT/results.txt
done
pkill -x qemu-system-aar
