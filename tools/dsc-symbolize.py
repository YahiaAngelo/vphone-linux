#!/usr/bin/env python3
"""dsc-symbolize.py SAMPLES SLIDE_BASE [TOP]: attribute user-mode samples to iOS shared-cache
images and functions, using the cache copied to dsc/ (the main file and its subcaches; for
function names also its .symbols file).

SAMPLES has one sample per token of the form U<hex pc> (tools/cpu-sample.py's format; any other
token is ignored). SLIDE_BASE is the cache's load address this boot (a crash report's
sharedCache.base). A function is the nearest preceding symbol among the image's exported
symbols (its LC_SYMTAB) and its local symbols, which Apple strips from the images and keeps in
the .symbols subcache (dyld_cache_local_symbols_info)."""
import bisect, collections, mmap, os, struct, sys

D = os.environ.get("DSC_DIR") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "dsc")

files = sorted(f for f in os.listdir(D) if f.startswith("dyld_shared_cache_arm64e")
               and not f.endswith(".symbols") and not os.path.islink(os.path.join(D, f)))
maps = []  # (addr, size, fileoff, file)
main_name = None
for f in files:
    with open(os.path.join(D, f), "rb") as fh:
        h = fh.read(0x4000)
    if h[:4] != b"dyld":
        continue
    mo, mc = struct.unpack_from("<II", h, 16)
    for i in range(mc):
        a, sz, fo, _, _ = struct.unpack_from("<QQQII", h, mo + i * 32)
        maps.append((a, sz, fo, f))
    if main_name is None or len(f) < len(main_name):
        main_name = f   # the main file has the shortest name (no subcache suffix)
maps.sort()
mfh = {}


def read(addr, n):
    for a, sz, fo, f in maps:
        if a <= addr < a + sz:
            if f not in mfh:
                mfh[f] = open(os.path.join(D, f), "rb")
            fh = mfh[f]
            fh.seek(fo + addr - a)
            return fh.read(n)
    return None


main = open(os.path.join(D, main_name), "rb").read(0x8000)
mo = struct.unpack_from("<I", main, 16)[0]
unslid = struct.unpack_from("<Q", main, mo)[0]
io, ic = struct.unpack_from("<II", main, 0x1C0)
with open(os.path.join(D, main_name), "rb") as fh:
    fh.seek(io)
    itab = fh.read(ic * 32)
    imgs = []
    for i in range(ic):
        a, _, _, po, _ = struct.unpack_from("<QQQII", itab, i * 32)
        fh.seek(po)
        name = fh.read(512).split(b"\0", 1)[0].decode()
        imgs.append((a, name))
imgs.sort()
starts = [a for a, _ in imgs]

# Local symbols: the .symbols subcache's dyld_cache_local_symbols_info, entries keyed by the
# image's offset from the unslid cache base.
local = {}
symf = [f for f in os.listdir(D) if f.endswith(".symbols")]
if symf:
    sf = open(os.path.join(D, symf[0]), "rb")
    sm = mmap.mmap(sf.fileno(), 0, access=mmap.ACCESS_READ)
    lo = struct.unpack_from("<Q", sm, 0x48)[0]
    nlo, nlc, sto, sts, eno, enc = struct.unpack_from("<6I", sm, lo)
    for i in range(enc):
        dyoff, start, count = struct.unpack_from("<QII", sm, lo + eno + i * 16)
        local[unslid + dyoff] = (start, count)


def local_symbols(img_addr):
    if img_addr not in local:
        return []
    start, count = local[img_addr]
    out = []
    for i in range(start, start + count):
        sx, ty, sect, desc, val = struct.unpack_from("<IBBHQ", sm, lo + nlo + i * 16)
        if ty & 0x0E == 0x0E and val:   # N_SECT
            s = lo + sto + sx
            e = sm.find(b"\0", s)
            out.append((val, sm[s:e].decode(errors="replace")))
    return out


symcache = {}


def symbols(img_addr):
    if img_addr in symcache:
        return symcache[img_addr]
    hdr = read(img_addr, 0x8000) or b""
    out = []
    try:
        ncmds = struct.unpack_from("<I", hdr, 16)[0]
        off = 32
        link = symtab = None
        for _ in range(ncmds):
            cmd, size = struct.unpack_from("<II", hdr, off)
            if cmd == 0x19:  # LC_SEGMENT_64
                name = hdr[off + 8:off + 24].rstrip(b"\0")
                vm, vs, fo = struct.unpack_from("<QQQ", hdr, off + 24)
                if name == b"__LINKEDIT":
                    link = (vm, fo)
            elif cmd == 2:  # LC_SYMTAB
                symtab = struct.unpack_from("<IIII", hdr, off + 8)
            off += size
        if link and symtab:
            symoff, nsyms, stroff, strsize = symtab
            lv, lf = link
            syms = read(lv + symoff - lf, nsyms * 16) or b""
            strs = read(lv + stroff - lf, strsize) or b""
            for i in range(len(syms) // 16):
                sx, ty, sect, desc, val = struct.unpack_from("<IBBHQ", syms, i * 16)
                if ty & 0x0E == 0x0E and val:  # N_SECT
                    e = strs.find(b"\0", sx)
                    out.append((val, strs[sx:e].decode(errors="replace")))
    except struct.error:
        pass
    out += local_symbols(img_addr)
    out = sorted((v, n) for v, n in out if n != "<redacted>")
    symcache[img_addr] = (out, [v for v, _ in out])
    return symcache[img_addr]


def lookup(pc):
    """(image name, function name) for an unslid shared-cache address, or None outside it."""
    i = bisect.bisect_right(starts, pc) - 1
    if i < 0 or pc - starts[i] > 0x10000000:
        return None
    name = imgs[i][1].split("/")[-1]
    s, vals = symbols(starts[i])
    j = bisect.bisect_right(vals, pc) - 1
    return name, s[j][1] if j >= 0 else "?"


if __name__ == "__main__":
    samples, base = sys.argv[1], int(sys.argv[2], 0)
    top = int(sys.argv[3]) if len(sys.argv) > 3 else 30
    slide = base - unslid
    img_c = collections.Counter()
    fn_c = collections.Counter()
    n = 0
    for line in open(samples):
        for x in line.split():
            if x[0] != "U":
                continue
            n += 1
            pc = int(x[1:], 16) - slide
            hit = lookup(pc)
            if hit is None:
                img_c["(not in cache)"] += 1
                continue
            img_c[hit[0]] += 1
            fn_c[f"{hit[0]}`{hit[1]}"] += 1
    print(f"user samples {n}, slide {slide:#x}")
    print("-- images")
    for k, v in img_c.most_common(top // 2):
        print(f"{100 * v / max(n, 1):5.1f}% {k}")
    print("-- functions")
    for k, v in fn_c.most_common(top):
        print(f"{100 * v / max(n, 1):5.1f}% {k}")
