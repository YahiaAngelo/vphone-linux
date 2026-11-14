#!/usr/bin/env python3
# busy-split.py TRACE...: kvm-split's time split with idle (WFI/WFE exits, in the kernel or QEMU) set apart.
import re,sys
pat=re.compile(r'-(\d+)\s+\[\d+\].*?\s(\d+\.\d+): (kvm_\w+): (.*)')
for path in sys.argv[1:]:
    gs={};st={};g=u=k=idle=0
    for l in open(path):
        m=pat.search(l)
        if not m: continue
        tid,t,ev,rest=m.group(1),float(m.group(2)),m.group(3),m.group(4)
        if ev=='kvm_entry':
            if tid in st:
                kind,t0=st.pop(tid)
                if kind=='u': u+=t-t0
                elif kind=='w': idle+=t-t0
                else: k+=t-t0
            gs[tid]=t
        elif ev=='kvm_exit':
            if tid in gs: g+=t-gs.pop(tid)
            st[tid]=('w' if 'WFx' in rest else 'k',t)
        elif ev=='kvm_userspace_exit' and tid in st and st[tid][0]!='w': st[tid]=('u',st[tid][1])
    busy=(g+u+k) or 1
    print(f"{path}: idle {idle/(busy+idle):.0%} | of busy time: guest {g/busy:.0%} qemu {u/busy:.0%} kernel {k/busy:.0%}")
