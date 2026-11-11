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
scale and restart_required; an unchanged tree also needs display.metrics to confirm the running
scale before the cache and running guest can be left alone. Older workers can use device.screen
only after the exact unsupported-method response. A stale running scale invalidates
the cache and still requires a restart. Existing positional calls print human-readable output.
--wait-screen SECONDS optionally waits for FrontBoard's layout after a SpringBoard restart;
only the legacy missing-layout error is retried, and running scale must be proven before a no-op.
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
HTTP_TOKEN = b"!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"


class ScreenGeometryUnavailable(Exception):
    pass


class DisplayMetricsUnsupported(Exception):
    pass


def socket_deadline(s, deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("guest RPC deadline expired")
    s.settimeout(remaining)


def response(s, deadline):
    """Read vphoned's fixed-length response without waiting for it to close."""
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
    status = head.split(b"\r\n", 1)[0].split(b" ", 2)
    if (len(status) != 3 or status[0] != b"HTTP/1.1" or len(status[1]) != 3 or not status[1].isdigit()
            or not status[2] or any(c < 32 or c == 127 for c in status[2])):
        raise ValueError("guest RPC response has an invalid HTTP status")
    length = None
    for line in head.split(b"\r\n")[1:]:
        name, separator, value = line.partition(b":")
        if (not separator or not name or any(c not in HTTP_TOKEN for c in name)
                or any((c < 32 and c != 9) or c == 127 for c in value)):
            raise ValueError("guest RPC response has a malformed header")
        name = name.lower()
        if name == b"transfer-encoding":
            raise ValueError("guest RPC response uses unsupported Transfer-Encoding")
        if name == b"content-length":
            value = value.strip(b" \t")
            if (length is not None or not value.isdigit() or len(value) > len(str(MAX_RESPONSE))
                    or (len(value) > 1 and value.startswith(b"0"))):
                raise ValueError("guest RPC response has an invalid Content-Length")
            length = int(value)
            if length > MAX_RESPONSE:
                raise ValueError("guest RPC response exceeds 4 MiB")
    if length is None:
        raise ValueError("guest RPC response requires one Content-Length")
    if len(body) > length:
        raise ValueError("guest RPC response exceeds its Content-Length")
    while len(body) < length:
        socket_deadline(s, deadline)
        chunk = s.recv(min(1 << 16, length - len(body)))
        if not chunk:
            break
        body += chunk
        if len(body) > MAX_RESPONSE:
            raise ValueError("guest RPC response exceeds 4 MiB")
    if len(body) < length:
        raise ValueError("guest RPC response body is incomplete")
    return int(status[1]), body


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("guest RPC response contains duplicate fields")
        result[key] = value
    return result


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
        status, reply = response(s, deadline)
        r = json.loads(reply, object_pairs_hook=unique_fields)
    finally:
        s.close()
    if (not isinstance(r, dict) or r.get("type") != "response"
            or type(r.get("id")) is not int or r["id"] != 1
            or ("error" in r) == ("result" in r)):
        raise ValueError("guest RPC response has an invalid envelope")
    if "error" in r:
        error = r["error"]
        if not isinstance(error, dict) or not isinstance(error.get("message"), str):
            raise ValueError("guest RPC response has an invalid error")
        if (method == "display.metrics" and status == 400
                and error.get("code") == "invalid_operation"
                and error["message"] == "Unknown method: display.metrics"):
            raise DisplayMetricsUnsupported()
        if (method == "device.screen" and status == 400 and error.get("code") == "unavailable"
                and error["message"] == MISSING_LAYOUT):
            raise ScreenGeometryUnavailable(MISSING_LAYOUT)
        sys.exit(f"{method}: {error['message']}")
    if status != 200 or not isinstance(r["result"], dict):
        raise ValueError("guest RPC response has an invalid success result")
    return r["result"]


def positive_number(value):
    return type(value) in (int, float) and math.isfinite(value) and value > 0


def metrics_scale(result):
    if (set(result) != {"available", "source", "reason", "display_id", "bounds", "reference_bounds", "point_scale"}
            or result.get("available") is not True or result.get("source") != "frontboard_default_main"
            or result.get("reason") != ""):
        sys.exit("display.metrics: no verified default-main display configuration")
    identity = result.get("display_id")
    if type(identity) is not int or not 0 < identity <= 0xFFFFFFFF:
        sys.exit("display.metrics: expected a positive 32-bit display identity")
    for field in ("bounds", "reference_bounds"):
        rect = result.get(field)
        if (not isinstance(rect, dict)
                or any(type(rect.get(key)) not in (int, float) or not math.isfinite(rect[key])
                       or rect[key] != 0 for key in ("x", "y"))
                or not all(positive_number(rect.get(key)) for key in ("width", "height"))):
            sys.exit("display.metrics: expected finite zero-origin display bounds")
    scale = result.get("point_scale")
    if not positive_number(scale):
        sys.exit("display.metrics: expected a positive numeric point scale")
    return scale


def running_scale():
    deadline = time.monotonic() + (args.wait_screen or 300)
    method = "display.metrics"
    waiting = False
    while True:
        if time.monotonic() >= deadline:
            sys.exit(f"{method}: no verified running scale before the wait expired")
        try:
            result = rpc(method, _deadline=deadline)
        except DisplayMetricsUnsupported:
            method = "device.screen"
            continue
        except ScreenGeometryUnavailable as error:
            remaining = deadline - time.monotonic() if args.wait_screen else 0
            if remaining <= 0:
                sys.exit(f"device.screen: {error}; no verified running scale before the wait expired")
            if not waiting:
                print("waiting for FrontBoard's active screen layout", file=output)
                waiting = True
            time.sleep(min(2, remaining))
            continue
        if time.monotonic() >= deadline:
            sys.exit(f"{method}: running-scale proof arrived after the wait deadline")
        if method == "display.metrics":
            return metrics_scale(result)
        running = result.get("scale")
        if not positive_number(running):
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
        print(
            f"the device tree already requests {scale}x; no device-tree update was needed."
        )
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
