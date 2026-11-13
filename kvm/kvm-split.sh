#!/bin/bash
# Time split of the vCPU threads over 0.5 s: guest, in-kernel exits, round trips to QEMU; exits a second.
# Needs sudo (tracefs). kvm-split.sh OUT-TRACE-FILE
T=/sys/kernel/tracing; O=${1:-/dev/null}
sudo -n sh -c "echo 0 > $T/tracing_on; echo > $T/trace; echo 16384 > $T/buffer_size_kb; echo 1 > $T/events/kvm/kvm_exit/enable; echo 1 > $T/events/kvm/kvm_entry/enable; echo 1 > $T/events/kvm/kvm_userspace_exit/enable; echo 1 > $T/tracing_on; sleep 0.5; echo 0 > $T/tracing_on; echo 0 > $T/events/kvm/enable"
sudo -n cat $T/trace > "$O"
python3 - "$O" <<'PY'
import re,sys
pat=re.compile(r'-(\d+)\s+\[\d+\].*?\s(\d+\.\d+): (kvm_\w+):')
gs={};st={};g=u=k=0;n=0;nu=0
for l in open(sys.argv[1]):
    m=pat.search(l)
    if not m: continue
    tid,t,ev=m.group(1),float(m.group(2)),m.group(3)
    if ev=='kvm_entry':
        if tid in st:
            kind,t0=st.pop(tid)
            if kind=='u': u+=t-t0
            else: k+=t-t0
        gs[tid]=t
    elif ev=='kvm_exit':
        if tid in gs: g+=t-gs.pop(tid)
        st[tid]=('k',t); n+=1
    elif ev=='kvm_userspace_exit':
        if tid in st: st[tid]=('u',st[tid][1]); nu+=1
tot=(g+u+k) or 1
print(f"guest {g/tot:.0%}  qemu-roundtrips {u/tot:.0%}  in-kernel {k/tot:.0%}  exits/s {n*2}  to-qemu/s {nu*2}  per-roundtrip {u/max(nu,1)*1e6:.1f}us")
PY
