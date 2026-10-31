#!/usr/bin/env python3
"""Clear the restore NVRAM state so the installed OS boots.

`restore --boot-ramdisk` stops before the phase that clears the persistent
boot-args, so the VM is left with

    auto-boot=false
    boot-args=rd=md0 nand-enable-reformat=1 -progress

and a normal boot just sits on a black screen: iBoot waits, or tries to boot a
RAM disk that no longer exists.

This edits the guest's NVRAM banks in place: `auto-boot` becomes `true` and the
env list ends before `boot-args`, which drops it. `boot-args` is *not* rewritten
in place because a NUL just after it would be an empty entry, and the parser
stops at the first empty entry anyway — which is exactly the behaviour wanted
here (nothing follows `boot-args`).

Format (qemu/hw/nvram/apple_nvram.c, qemu/include/hw/nvram/chrp_nvram.h):

    bank  = AppleNvramPartHdr at some offset in nvram.bin
            { ChrpNvramPartHdr chrp; u32 adler; u32 generation; u8 pad[8] }
    chrp  = { u8 signature; u8 checksum; u16 len_be/16; char name[12] }  (name at +4)
    parts = CHRP partitions starting at bank+0x20, name "common" holds
            NUL-separated NAME=VALUE strings
    adler = adler32(1, bank+0x14, bank_length-0x14)

Usage:
    tools/nvram-autoboot.py vms/myphone/nvram.bin [--auto-boot true|false] [--drop NAME]... [--dry-run]

--drop removes a variable, e.g. after iOS rebooted itself into recovery ("rebooting due to
critical process crashes"), which leaves one-time-boot-command=device-recovery and
device-recovery-boot-reason behind and sends every later boot back to recovery.
"""

import argparse
import struct
import sys
import zlib

SIGNATURE = 0x5A
COMMON = b"common"
HEADER = 16
BANK_HEADER = 32
# Observed bank sizes, largest first: the guest writes 512 KiB banks.
BANK_SIZES = (0x80000, 0x100000, 0x40000, 0x10000, 0x2000)


def chrp_checksum(header: bytes) -> int:
    total = header[0]
    for i in range(14):
        total += header[2 + i]
        total = (total + ((total & 0xFF00) >> 8)) & 0xFF
    return total & 0xFF


def find_banks(data: bytes):
    """Yield (base, length) for every bank whose header and adler32 verify."""
    seen = []
    for base in range(0, max(0, len(data) - BANK_HEADER), 16):
        header = data[base:base + BANK_HEADER]
        if header[0] != SIGNATURE or header[4:16].split(b"\0")[0] != b"nvram":
            continue
        if chrp_checksum(header[:HEADER]) != header[1]:
            continue
        adler = struct.unpack_from("<I", data, base + 16)[0]
        for length in BANK_SIZES:
            if base + length > len(data):
                continue
            if zlib.adler32(data[base + 0x14:base + length]) & 0xFFFFFFFF == adler:
                if all(abs(base - other) >= 0x2000 for other in seen):
                    seen.append(base)
                    yield base, length
                break


def common_data(data: bytes, base: int, length: int):
    """The env string area of the bank's `common` partition."""
    offset = 0x20
    while offset + HEADER <= length:
        header = data[base + offset:base + offset + HEADER]
        signature = header[0]
        if signature in (0x00, 0x7F):  # free / end of partition table
            break
        size = struct.unpack(">H", header[2:4])[0] * 16
        # `common` is written with a length larger than the bank it lives in
        # (observed: 0xFE7F0 in a 0x80000 bank). Clamp it to the bank instead of
        # rejecting it, which is what the guest's reader must be doing too.
        if header[4:16].split(b"\0")[0] == COMMON:
            return base + offset + HEADER, min(base + offset + size, base + length)
        if size < HEADER or offset + size > length:
            break
        offset += size
    return None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("nvram", help="the VM bundle's nvram.bin")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--auto-boot", choices=["true", "false"], default="true",
                        help="value for auto-boot (default true; use false to let the ROM stop in DFU)")
    parser.add_argument("--boot-args", metavar="TEXT",
                        help="set boot-args to TEXT (empty string removes it); for diagnostics, "
                             "e.g. --boot-args '-v serial=3', which makes iBoot and the kernel print "
                             "to the VM serial console")
    parser.add_argument("--drop", metavar="NAME", action="append", default=[],
                        help="remove the variable NAME (repeatable), e.g. --drop one-time-boot-command")
    args = parser.parse_args()
    drop = {name.encode() for name in args.drop}

    with open(args.nvram, "rb") as handle:
        data = bytearray(handle.read())

    banks = list(find_banks(bytes(data)))
    if not banks:
        print(f"{args.nvram}: no NVRAM bank with a valid adler32", file=sys.stderr)
        return 1

    changed = False
    for base, length in banks:
        region = common_data(data, base, length)
        if region is None:
            print(f"bank 0x{base:x}: no 'common' partition", file=sys.stderr)
            continue
        start, end = region
        block = bytes(data[start:end])

        entries = []
        cursor = 0
        while cursor < len(block) and block[cursor] != 0:
            stop = block.find(b"\0", cursor)
            if stop < 0:
                break
            entries.append(block[cursor:stop])
            cursor = stop + 1

        kept, dropped = [], []
        for entry in entries:
            name = entry.split(b"=", 1)[0]
            # A truncated earlier write (observed: "-enable-reformat=1
            # -progress", the tail of a dropped boot-args) is not a variable.
            if b"=" not in entry or not name or name.startswith(b"-") or b" " in name:
                dropped.append(entry.decode("utf-8", "replace"))
                continue
            if name == b"auto-boot":
                kept.append(b"auto-boot=" + args.auto_boot.encode())
            elif name == b"boot-args" or name in drop:
                dropped.append(entry.decode("utf-8", "replace"))
            else:
                kept.append(entry)
        if args.boot_args:
            # Insert right after auto-boot, where the list was just shortened.
            index = next((i + 1 for i, e in enumerate(kept) if e.startswith(b"auto-boot=")), len(kept))
            kept.insert(index, b"boot-args=" + args.boot_args.encode())

        before = b"".join(e + b"\0" for e in entries)
        after = b"".join(e + b"\0" for e in kept)
        # Rewrite the parsed list in place, NUL-padded. The entries that were
        # dropped are still NUL space behind it, so the capacity is the region
        # (capped: the clamped `common` region can reach into the next bank).
        # Write the list, then zero the dead space behind it: a truncated old
        # entry would otherwise still parse as a nameless string (observed: a
        # leftover "-enable-reformat=1 -progress" after boot-args). The `common`
        # region can be clamped across banks, so the clear is capped.
        clear = min(0x1000, end - start)
        if len(after) > clear:
            print(f"bank 0x{base:x}: env list does not fit, refusing", file=sys.stderr)
            return 1
        desired = after.ljust(clear, b"\0")

        if bytes(data[start:start + clear]) == desired:
            print(f"bank 0x{base:x}: already auto-boot={args.auto_boot}"
                  + (f" with boot-args={args.boot_args!r}" if args.boot_args else " with no boot-args"))
            continue

        data[start:start + clear] = desired
        struct.pack_into("<I", data, base + 16,
                         zlib.adler32(bytes(data[base + 0x14:base + length])) & 0xFFFFFFFF)
        changed = True
        print(f"bank 0x{base:x}: auto-boot={args.auto_boot}"
              + (f", dropped {', '.join(repr(d[:60]) for d in dropped)}" if dropped else ""))

    if not changed:
        return 0
    if args.dry_run:
        print("dry run: not written")
        return 0
    with open(args.nvram, "wb") as handle:
        handle.write(bytes(data))
    print(f"wrote {args.nvram}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
