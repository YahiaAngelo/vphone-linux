#!/usr/bin/env python3
"""service-profile.py CID trimmed|none [--allow LABEL ...]: apply vphoned's service profile.

`trimmed` disables the background daemons a VM has no use for (iOS 26 and 27: about 137 of
them, Siri and intelligence, Find My, Wallet, Watch, Home, health coaching, telemetry, ads,
the App Store and sign-in follow-ups; see vphone-cli's Research/Guest/service_trimming.md);
`none` enables again every daemon the profile disabled. Either takes effect when the guest
next boots. com.apple.generativeexperiencesd is always kept: vphoned builds before list
version 4 disable it, and without it an idle iOS 27 guest spins launchd. --allow keeps
more (for example com.apple.weatherd for the Weather widget).

The first boot after `trimmed` is busy for about ten minutes while widgets and extensions
settle; after that the guest idles with fewer processes, less memory and fewer disk writes.
"""
import argparse
import json
import socket
import sys

PORT = 1339
KEEP = ["com.apple.generativeexperiencesd"]


def response(s):
    raw = b""
    while b"\r\n\r\n" not in raw:
        chunk = s.recv(1 << 16)
        if not chunk:
            break
        raw += chunk
    head, _, body = raw.partition(b"\r\n\r\n")
    n = next((int(l.split(b":", 1)[1]) for l in head.split(b"\r\n")
              if l.lower().startswith(b"content-length:")), None)
    while n is None or len(body) < n:
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        body += chunk
    if n is not None and len(body) < n:
        raise ValueError("reply cut short")
    return body if n is None else body[:n]


def rpc(cid, method, **params):
    body = json.dumps({"method": method, "params": params, "id": 1}).encode()
    for _ in range(5):
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        s.settimeout(180)
        s.connect((cid, PORT))
        s.sendall(b"POST /v1/rpc HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
                  b"Connection: close\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        try:
            r = json.loads(response(s))
        except ValueError:
            continue
        finally:
            s.close()
        if "error" in r:
            sys.exit(f"{method}: {r['error']['message']}")
        return r["result"]
    sys.exit(f"{method}: no whole reply in 5 tries")


def count(v):
    """A count, where vphoned answers a list of labels or a number."""
    return len(v) if isinstance(v, (list, dict)) else (v or 0)


ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
ap.add_argument("cid", type=int)
ap.add_argument("profile", choices=["trimmed", "none"])
ap.add_argument("--allow", nargs="*", default=[], metavar="LABEL")
a = ap.parse_args()

r = rpc(a.cid, "services.profile.apply", profile=a.profile, allow=KEEP + a.allow, force=True)

failed = r.get("failed") or []
if a.profile == "trimmed":
    print(f"service profile trimmed: {count(r.get('disabled'))} daemons disabled, "
          f"{count(r.get('allowed'))} kept, list version {r.get('list_version')}")
else:
    print(f"service profile none: {count(r.get('enabled'))} daemons enabled again")
for f in failed:
    print(f"  failed: {f.get('label')} ({f.get('action')}): {f.get('error')}", file=sys.stderr)
if r.get("reboot_required"):
    print("  takes effect at the guest's next boot")
sys.exit(1 if failed else 0)
