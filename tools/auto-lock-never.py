#!/usr/bin/env python3
"""auto-lock-never.py VM-DIR [CID]: set the running guest's Auto-Lock to Never.

A new VM locks after a minute and turns the screen off, and iOS then drops every touch, so it
looks as if touch is broken. Settings sets Auto-Lock through ManagedConfiguration
(MCProfileConnection setValue:forSetting: "maxInactivity"), and profiled ignores the call from a
process without ManagedConfiguration's write entitlements (com.apple.managedconfiguration.
profiled-access and .profiled.set). The vphoned of the vphone-cli release has neither, so
`display.auto_lock.set` changed nothing; `cfw install` now merges them in.

This makes the same call through vphoned (`script.eval`). Where it does not take, the VM's vphoned
predates that: the tool re-signs the bundle's copy (VM-DIR/.vphoned.signed) with the two
entitlements merged in (vphone-cli sign --merge; the old copy is kept as .vphoned.signed.before-mc),
installs it in the guest (tools/vphoned-update.sh) and tries again. Env: VC (vphone-cli)."""
import base64, hashlib, json, os, plistlib, shutil, socket, subprocess, sys, tempfile, time

NEVER = 2**31 - 1
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VC = os.environ.get("VC", f"{ROOT}/linux-create/vphone-cli")
ENTITLEMENTS = {"com.apple.managedconfiguration.profiled-access": True,
                "com.apple.managedconfiguration.profiled.set": True}
SCRIPT = f"""
ObjC.use("NSBundle").bundleWithPath_("/System/Library/PrivateFrameworks/ManagedConfiguration.framework").load();
var c = ObjC.use("MCProfileConnection").sharedConnection();
c.setValue_forSetting_(ObjC.use("NSNumber").numberWithInt_({NEVER}), "maxInactivity");
sleep(2);
print(c.effectiveValueForSetting_("maxInactivity"));
"""

vm = sys.argv[1]
cid = int(sys.argv[2]) if len(sys.argv) > 2 else int(os.environ.get("CID", 3))


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


def rpc(method, timeout=120, **params):
    body = json.dumps({"method": method, "params": params, "id": 1}).encode()
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((cid, 1339))
    s.sendall(b"POST /v1/rpc HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
              b"Connection: close\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
    r = json.loads(response(s))
    if "error" in r:
        sys.exit(f"{method}: {r['error']['message']}")
    return r["result"]


def set_never():
    r = rpc("script.eval", source=SCRIPT, timeout=60)
    if not r.get("ok"):
        sys.exit(f"the script failed: {r.get('error')} {r.get('output', '')}")
    return int(r["output"].strip().splitlines()[-1]) == NEVER


def health(timeout=10):
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((cid, 1339))
    s.sendall(b"GET /v1/health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    return json.loads(response(s))


def wait_for_vphoned(binary_hash):
    for _ in range(60):
        try:
            if health().get("binary_hash") == binary_hash:
                return
        except (OSError, ValueError):
            pass
        time.sleep(3)
    sys.exit("the guest's vphoned did not come back as the re-signed binary")


if set_never():
    print("Auto-Lock is Never")
    sys.exit()

print("profiled ignored the call: this VM's vphoned lacks ManagedConfiguration's entitlements")
bundle_copy = os.path.join(vm, ".vphoned.signed")
if not os.path.isfile(bundle_copy):
    sys.exit(f"{bundle_copy} not found: is {vm} the VM's folder?")
if not os.access(VC, os.X_OK):
    sys.exit(f"vphone-cli not found at {VC} (set VC)")
with tempfile.TemporaryDirectory() as tmp:
    ents = os.path.join(tmp, "entitlements.plist")
    with open(ents, "wb") as f:
        plistlib.dump(ENTITLEMENTS, f)
    signed = os.path.join(tmp, "vphoned")
    shutil.copy2(bundle_copy, signed)
    subprocess.run([VC, "sign", signed, "--entitlements", ents, "--merge", "--identifier", "vphoned"],
                   check=True)
    backup = bundle_copy + ".before-mc"
    if not os.path.exists(backup):
        shutil.copy2(bundle_copy, backup)
    print("installing the re-signed vphoned in the guest")
    with open(signed, "rb") as f:
        want = hashlib.sha256(f.read()).hexdigest()
    # The update's own request can stay open while vphoned restarts: its result is the binary
    # vphoned reports afterwards, not that request's answer.
    try:
        subprocess.run([f"{ROOT}/tools/vphoned-update.sh", "-c", str(cid), signed], timeout=90)
    except subprocess.TimeoutExpired:
        pass
    wait_for_vphoned(want)
    shutil.copy2(signed, bundle_copy)
if not set_never():
    sys.exit("profiled still ignores the call; Auto-Lock is unchanged (set it in Settings)")
print("Auto-Lock is Never")
