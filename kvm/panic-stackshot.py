#!/usr/bin/env python3
# panic-stackshot.py QEMU_PID OUT_DIR: after the iOS guest panicked, find its embedded panic header
# (xnu osfmk/kern/debug.h, EMBEDDED_PANIC_MAGIC 'FUNK') in the guest RAM QEMU maps, and write the panic
# log (panic.txt) and the stackshot (stackshot.kcdata, for xnu tools/lldbmacros/kcdata.py) to OUT_DIR.
# The guest's NVRAM doesn't keep panic logs across boots here, so this reads them from memory.
import os
import re
import struct
import sys

MAGIC = struct.pack('<I', 0x46554E4B)
# magic, crc, version, flags (64-bit, packed), log offset/len, stackshot offset/len, other log offset/len
HDR = struct.Struct('<3IQ6I')


def ram_mappings(pid):
    """QEMU's mappings of 1 MiB and up (guest RAM among them), biggest first."""
    maps = []
    for line in open(f'/proc/{pid}/maps'):
        m = re.match(r'([0-9a-f]+)-([0-9a-f]+) (\S+) \S+ \S+ \S+\s*(.*)', line)
        lo, hi = int(m.group(1), 16), int(m.group(2), 16)
        if 'r' in m.group(3) and hi - lo >= 1 << 20 and 'vvar' not in line:
            maps.append((hi - lo, lo, hi, m.group(4)))
    return sorted(maps, reverse=True)


def main():
    pid, out = int(sys.argv[1]), sys.argv[2]
    os.makedirs(out, exist_ok=True)
    mem = open(f'/proc/{pid}/mem', 'rb', buffering=0)
    chunk = 64 << 20
    found = []
    for size, lo, hi, name in ram_mappings(pid):
        for base in range(lo, hi, chunk):
            try:
                mem.seek(base)
                data = mem.read(min(chunk + 4096, hi - base))
            except OSError:
                continue
            i = data.find(MAGIC)
            while i >= 0 and i < chunk:
                if i % 4 == 0 and i + HDR.size <= len(data):
                    f = HDR.unpack_from(data, i)
                    # eph_version small, the log right after the header, lengths sane
                    if 0 < f[2] < 16 and 0 < f[4] < 0x1000 and 0 < f[5] < (8 << 20) and f[7] < (64 << 20) and f[1] != 0:
                        found.append((base + i, f, name))
                i = data.find(MAGIC, i + 1)
    if not found:
        sys.exit('no embedded panic header in guest RAM')
    for n, (addr, f, name) in enumerate(found):
        _, crc, ver, flags, log_off, log_len, ss_off, ss_len, oth_off, oth_len = f
        print(f'header {n} at host 0x{addr:x} ({name}): version {ver} flags 0x{flags:x} '
              f'log {log_len} stackshot {ss_len} other {oth_len}')
        mem.seek(addr)
        blob = mem.read(max(log_off + log_len, ss_off + ss_len, oth_off + oth_len))
        sfx = '' if n == 0 else f'.{n}'
        open(f'{out}/panic{sfx}.txt', 'wb').write(blob[log_off:log_off + log_len] + b'\n--- other log ---\n' +
                                                  blob[oth_off:oth_off + oth_len])
        if ss_len:
            open(f'{out}/stackshot{sfx}.kcdata', 'wb').write(blob[ss_off:ss_off + ss_len])


main()
