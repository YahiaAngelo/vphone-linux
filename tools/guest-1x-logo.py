#!/usr/bin/env python3
"""guest-1x-logo.py CID: give a 1x guest its boot Apple logo.

iOS draws the boot logo from ProgressUI.framework's apple-logo*@2x/@3x~iphone.png. With the
display at 1x (tools/display-scale.py) it looks for 1x images, finds none, and the screen stays
black until the lock screen. This reads each of the guest's own @2x logos through vphoned,
halves it, and writes it back next to it as the 1x image (NAME~iphone.png). Nothing is copied
from outside the guest. Run it once with the VM up; the logo shows from the next boot.

The system volume is mounted read-only, and vphoned has no command runner, so a one-shot
launchd job runs iOS's own `/sbin/mount -u -w /` first (vphoned's environment install does the
same). The job is removed afterwards; the volume goes back to read-only at the next boot."""
import base64, io, json, socket, struct, sys, time, zlib
from PIL import Image

DIR = "/System/Library/PrivateFrameworks/ProgressUI.framework"
cid = int(sys.argv[1])


def response(s):
    """One HTTP response's body: up to its Content-Length, since vphoned can keep the
    connection open after replying (tools/vphoned-update.sh)."""
    raw = b""
    while b"\r\n\r\n" not in raw:
        chunk = s.recv(1 << 16)
        if not chunk:
            break
        raw += chunk
    head, _, body = raw.partition(b"\r\n\r\n")
    length = next((int(l.split(b":", 1)[1]) for l in head.split(b"\r\n")
                   if l.lower().startswith(b"content-length:")), None)
    while length is None or len(body) < length:
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        body += chunk
    return body if length is None else body[:length]


def rpc(method, **params):
    body = json.dumps({"method": method, "params": params, "id": 1}).encode()
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    # Linux caps a vsock socket's send credit at its buffer; iOS needs 512 KiB (docs/TROUBLESHOOTING.md).
    for opt in (socket.SO_VM_SOCKETS_BUFFER_MAX_SIZE, socket.SO_VM_SOCKETS_BUFFER_SIZE):
        s.setsockopt(socket.AF_VSOCK, opt, 4 << 20)
    s.connect((cid, 1339))
    s.settimeout(120)
    s.sendall(b"POST /v1/rpc HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
              b"Connection: close\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
    r = json.loads(response(s))
    if "error" in r:
        sys.exit(f"{method}: {r['error']['message']}")
    return r["result"]


def decode_png(data):
    """Open a PNG, including iOS's CgBI variant (Xcode's optimized PNGs: raw deflate data, BGRA
    pixels, premultiplied alpha), which Pillow cannot read."""
    if data[12:16] != b"CgBI":
        return Image.open(io.BytesIO(data))
    pos, idat = 8, b""
    while pos < len(data):
        n = struct.unpack(">I", data[pos:pos + 4])[0]
        typ, body = data[pos + 4:pos + 8], data[pos + 8:pos + 8 + n]
        if typ == b"IHDR":
            w, h, depth, ctype, _, _, interlace = struct.unpack(">IIBBBBB", body)
        elif typ == b"IDAT":
            idat += body
        pos += 12 + n
    if (depth, ctype, interlace) != (8, 6, 0):
        sys.exit(f"unsupported CgBI PNG (depth {depth}, color type {ctype}, interlace {interlace})")
    raw = zlib.decompress(idat, -15)
    stride, out, prev = w * 4, bytearray(), bytearray(w * 4)
    for y in range(h):  # undo the PNG row filters
        f, row = raw[y * (stride + 1)], bytearray(raw[y * (stride + 1) + 1:(y + 1) * (stride + 1)])
        for i in range(stride):
            a = row[i - 4] if i >= 4 else 0
            b, c = prev[i], prev[i - 4] if i >= 4 else 0
            if f == 1: row[i] = (row[i] + a) & 255
            elif f == 2: row[i] = (row[i] + b) & 255
            elif f == 3: row[i] = (row[i] + (a + b) // 2) & 255
            elif f == 4:
                p = a + b - c; pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
        out += row
        prev = row
    for i in range(0, len(out), 4):  # BGRA premultiplied -> RGBA straight
        bl, g, r, al = out[i:i + 4]
        if al:
            r, g, bl = (min(255, v * 255 // al) for v in (r, g, bl))
        out[i:i + 4] = bytes((r, g, bl, al))
    return Image.frombytes("RGBA", (w, h), bytes(out))


JOB = "/var/root/Library/Caches/vphone-linux-remount-rw.plist"
JOB_PLIST = """<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>vphone-linux.remount-rw</string>
<key>ProgramArguments</key><array><string>/sbin/mount</string><string>-u</string><string>-w</string><string>/</string></array>
<key>RunAtLoad</key><true/><key>LaunchOnlyOnce</key><true/>
</dict></plist>
"""


def make_root_writable():
    """True once / takes a write."""
    rpc("files.write", path=JOB, content=JOB_PLIST)
    try:
        rpc("services.load", paths=[JOB])
        # Wait until / takes a write: launchd runs the job when it gets to it, which took longer
        # than a fixed 10 s under slow emulation (the logo write then failed: read-only).
        probe = f"{DIR}/.vphone-linux-rw-probe"
        for _ in range(60):
            time.sleep(2)
            try:
                rpc("files.write", path=probe, content="")
            except SystemExit:
                continue
            rpc("files.remove", path=probe)
            return True
        return False
    finally:
        rpc("services.unload", paths=[JOB], force=True)
        rpc("files.remove", path=JOB)


names = [e["name"] for e in rpc("files.list", path=DIR)["entries"]]
todo = [n for n in names if n.startswith("apple-logo") and n.endswith("@2x~iphone.png")
        and n.replace("@2x~iphone.png", "~iphone.png") not in names]
if todo and not make_root_writable():
    # Cosmetic: without the 1x images the boot screen stays black until the lock screen.
    print("warning: / stayed read-only, so no 1x boot logo was written")
    sys.exit(0)
done = 0
for name in names:
    if not (name.startswith("apple-logo") and name.endswith("@2x~iphone.png")):
        continue
    out = name.replace("@2x~iphone.png", "~iphone.png")
    if out in names:
        print(f"{out}: already there")
        continue
    data = base64.b64decode(rpc("files.read", path=f"{DIR}/{name}", binary=True)["content"])
    im = decode_png(data)
    small = im.resize((max(1, im.width // 2), max(1, im.height // 2)), Image.LANCZOS)
    buf = io.BytesIO()
    small.save(buf, "PNG")
    rpc("files.write", path=f"{DIR}/{out}", content=base64.b64encode(buf.getvalue()).decode(),
        encoding="base64")
    print(f"{out}: {small.width}x{small.height} from {name}")
    done += 1
print(f"wrote {done} 1x logo(s); reboot the VM to see the logo")
