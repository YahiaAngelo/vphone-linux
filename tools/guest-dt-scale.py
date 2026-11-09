#!/usr/bin/env python3
"""guest-dt-scale.py CID [SCALE]: set the screen scale in a running guest's own device tree.

tools/display-scale.py sets LLB's /chosen/display-scale, which is all iOS 26 reads for the screen
scale (MobileGestalt's main-screen-scale). On iOS 27 (seen on the iPhone Duo, 27.1) the guest
tree's /product artwork-scale-factor, which `cfw install` copies from the board, decides it too:
with only LLB patched, a 1x VM still reports UIScreen.scale 3 and draws 3x content on a 1x
screen (everything looks zoomed in). Boards that describe their panels (/product/display0..N)
carry a display-scale there as well; any the guest tree has are set too.

This patches the guest's Preboot device tree (the devicetree.img4 `cfw install` writes) in place:
every display-scale and artwork-scale-factor under /product gets SCALE. The values are 4-byte
integers, so nothing moves. Without SCALE it prints what the tree holds. It keeps the original
next to it in the guest (devicetree.img4.before-scale, once) and on the host
(runs/guest-dt-scale/), and removes MobileGestalt's cache, which keeps the first boot's answers.
Unchanged trees are not rewritten or backed up again. With --json, stdout contains changed,
scale and restart_required; an unchanged tree also needs device.screen to confirm the running
scale before the cache and running guest can be left alone. A stale running scale invalidates
the cache and still requires a restart. Existing positional calls print human-readable output.
--wait-screen SECONDS optionally waits for FrontBoard's layout after a SpringBoard restart;
only the missing-layout error is retried, and geometry must still be proven before a no-op.
The new scale shows from the next boot. Use it together with display-scale.py and the VM's
gfx-res (docs/ADVANCED.md, "Display scale"); tools/set-scale.sh runs it."""
import argparse, base64, json, math, os, socket, struct, sys, time

CACHE = ("/private/var/containers/Shared/SystemGroup/systemgroup.com.apple.mobilegestaltcache"
         "/Library/Caches/com.apple.MobileGestalt.plist")
parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
parser.add_argument("cid", type=int)
parser.add_argument("scale", type=int, choices=(1, 2, 3), nargs="?")
parser.add_argument("--json", action="store_true", help="report the change and restart requirement as JSON")
parser.add_argument("--wait-screen", type=float, default=0,
                    help="wait up to 300 seconds for missing FrontBoard layout (requires --json)")
args = parser.parse_args()
if args.json and args.scale is None:
    parser.error("--json requires SCALE")
if not math.isfinite(args.wait_screen) or not 0 <= args.wait_screen <= 300:
    parser.error("--wait-screen must be a finite number from 0 to 300")
if args.wait_screen and not args.json:
    parser.error("--wait-screen requires --json")
cid, scale = args.cid, args.scale
output = sys.stderr if args.json else sys.stdout


MISSING_LAYOUT = "Active interface geometry is unavailable: FrontBoard returned no usable layout"
MAX_RESPONSE = 4 << 20


class ScreenGeometryUnavailable(Exception):
    pass


def socket_deadline(s, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("guest RPC deadline expired")
    s.settimeout(remaining)


def response(s, deadline):
    """One HTTP response's body: up to its Content-Length, since vphoned can keep the
    connection open after replying (tools/vphoned-update.sh)."""
    raw = b""
    while b"\r\n\r\n" not in raw:
        socket_deadline(s, deadline)
        chunk = s.recv(1 << 16)
        if not chunk:
            break
        raw += chunk
        if b"\r\n\r\n" not in raw and len(raw) > 65536:
            raise ValueError("guest RPC response header exceeds 64 KiB")
    head, _, body = raw.partition(b"\r\n\r\n")
    if not _ or len(head) > 65536:
        raise ValueError("guest RPC response header is incomplete or too large")
    lengths = [int(l.split(b":", 1)[1]) for l in head.split(b"\r\n")
               if l.lower().startswith(b"content-length:")]
    if len(lengths) > 1 or any(n < 0 or n > MAX_RESPONSE for n in lengths):
        raise ValueError("guest RPC response has an invalid Content-Length")
    length = lengths[0] if lengths else None
    if len(body) > MAX_RESPONSE:
        raise ValueError("guest RPC response exceeds 4 MiB")
    while length is None or len(body) < length:
        socket_deadline(s, deadline)
        chunk = s.recv(min(1 << 16, MAX_RESPONSE + 1 - len(body)))
        if not chunk:
            break
        body += chunk
        if len(body) > MAX_RESPONSE:
            raise ValueError("guest RPC response exceeds 4 MiB")
    if length is not None and len(body) < length:
        raise ValueError("guest RPC response body is incomplete")
    return body if length is None else body[:length]


def rpc(method, *, _deadline=None, **params):
    body = json.dumps({"method": method, "params": params, "id": 1}).encode()
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    deadline = time.monotonic() + 300 if _deadline is None else _deadline
    try:
        # Linux caps a vsock socket's send credit at its buffer; iOS needs 512 KiB (docs/TROUBLESHOOTING.md).
        for opt in (socket.SO_VM_SOCKETS_BUFFER_MAX_SIZE, socket.SO_VM_SOCKETS_BUFFER_SIZE):
            s.setsockopt(socket.AF_VSOCK, opt, 4 << 20)
        socket_deadline(s, deadline)
        s.connect((cid, 1339))
        socket_deadline(s, deadline)
        s.sendall(b"POST /v1/rpc HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
                  b"Connection: close\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        r = json.loads(response(s, deadline))
    finally:
        s.close()
    if "error" in r:
        if (method == "device.screen" and r["error"].get("code") == "unavailable"
                and r["error"].get("message") == MISSING_LAYOUT):
            raise ScreenGeometryUnavailable(MISSING_LAYOUT)
        sys.exit(f"{method}: {r['error']['message']}")
    return r["result"]


def running_scale():
    deadline = time.monotonic() + args.wait_screen if args.wait_screen else None
    waiting = False
    while True:
        if deadline is not None and time.monotonic() >= deadline:
            sys.exit("device.screen: no verified running scale before the wait expired")
        try:
            result = rpc("device.screen", _deadline=deadline)
        except ScreenGeometryUnavailable as error:
            remaining = 0 if deadline is None else deadline - time.monotonic()
            if remaining <= 0:
                sys.exit(f"device.screen: {error}; no verified running scale before the wait expired")
            if not waiting:
                print("waiting for FrontBoard's active screen layout", file=output)
                waiting = True
            time.sleep(min(2, remaining))
            continue
        if deadline is not None and time.monotonic() >= deadline:
            sys.exit("device.screen: running-scale proof arrived after the wait deadline")
        running = result.get("scale")
        if type(running) not in (int, float) or not math.isfinite(running) or running <= 0:
            sys.exit("device.screen: expected a positive numeric scale")
        return running


def der(buf, off):
    """(tag, content start, content end) of the DER element at off."""
    tag, n = buf[off], buf[off + 1]
    off += 2
    if n & 0x80:
        k = n & 0x7F
        n = int.from_bytes(buf[off:off + k], "big")
        off += k
    return tag, off, off + n


def payload(img4):
    """The offset and length of the device tree inside an IMG4 (or a bare IM4P)."""
    tag, start, end = der(img4, 0)
    _, s, e = der(img4, start)  # the "IMG4" or "IM4P" string
    if img4[s:e] == b"IMG4":
        _, start, end = der(img4, e)  # the IM4P sequence
        _, s, e = der(img4, start)
    for _ in range(2):  # type, description
        _, s, e = der(img4, e)
    tag, s, e = der(img4, e)
    if tag != 0x04:
        sys.exit("unexpected IM4P layout: no payload")
    if img4[s:s + 4] in (b"bvx2", b"bvx1", b"bvxn"):
        sys.exit("the tree is LZFSE-compressed; this tool patches only an uncompressed one")
    return s, e


def walk(dt, off, path, hits):
    nprops, nchild = struct.unpack_from("<II", dt, off)
    off += 8
    name, props = "", []
    for _ in range(nprops):
        key = dt[off:off + 32].split(b"\0")[0].decode(errors="replace")
        n = struct.unpack_from("<I", dt, off + 32)[0] & 0x7FFFFFFF
        if key == "name":
            name = dt[off + 36:off + 36 + n].split(b"\0")[0].decode(errors="replace")
        props.append((key, off + 36, n))
        off += 36 + ((n + 3) & ~3)
    here = f"{path}/{name}" if path else name
    for key, at, n in props:
        if key in ("display-scale", "artwork-scale-factor") and "/product" in here and n == 4:
            hits.append((f"{here}:{key}", at))
    for _ in range(nchild):
        off = walk(dt, off, here, hits)
    return off


def read_tree(path):
    result = rpc("files.read", path=path, binary=True, limit=2 << 20)
    data = base64.b64decode(result["content"], validate=True)
    if result.get("truncated") is not False or result.get("size") != len(data):
        sys.exit("files.read: expected the complete device tree")
    return data


boot = [e["name"] for e in rpc("files.list", path="/private/preboot")["entries"]
        if e["type"] == "dir" and len(e["name"]) == 96]
if len(boot) != 1:
    sys.exit(f"expected one boot manifest directory in /private/preboot, found {boot}")
path = f"/private/preboot/{boot[0]}/usr/standalone/firmware/devicetree.img4"
original = read_tree(path)
img4 = bytearray(original)
start, end = payload(img4)
hits = []
walk(img4, start, "", hits)
if not hits:
    sys.exit("no display-scale or artwork-scale-factor under /product: the LLB patch alone sets this guest's scale")
for where, at in hits:
    print(f"{where} = {struct.unpack_from('<I', img4, at)[0]}", file=output)
if scale is None:
    sys.exit()

for _, at in hits:
    struct.pack_into("<I", img4, at, scale)
if bytes(img4) == original:
    restart = False
    if args.json:
        running = running_scale()
        restart = running != scale
        if restart:
            rpc("files.remove", path=CACHE)
        print(json.dumps({"changed": False, "scale": scale, "restart_required": restart}))
    else:
        print(f"the device tree already requests {scale}x; no files or cache changed.")
    sys.exit()

host_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "runs", "guest-dt-scale")
os.makedirs(host_dir, exist_ok=True)
backup = os.path.join(host_dir, f"devicetree-cid{cid}-{time.strftime('%Y%m%d-%H%M%S')}.img4")
open(backup, "wb").write(original)
names = [e["name"] for e in rpc("files.list", path=os.path.dirname(path))["entries"]]
if "devicetree.img4.before-scale" not in names:
    rpc("files.write", path=path + ".before-scale", content=base64.b64encode(original).decode(),
        encoding="base64")
rpc("files.write", path=path, content=base64.b64encode(bytes(img4)).decode(), encoding="base64")
check = read_tree(path)
if check != bytes(img4):
    sys.exit(f"the tree read back differs from what was written; the original is in {backup}")
rpc("files.remove", path=CACHE)
print(f"set {len(hits)} value(s) to {scale}; original kept in {backup} and next to it in the guest.", file=output)
print("Reboot the VM (with display-scale.py and gfx-res at the same scale) to see it.", file=output)
if args.json:
    print(json.dumps({"changed": True, "scale": scale, "restart_required": True}))
