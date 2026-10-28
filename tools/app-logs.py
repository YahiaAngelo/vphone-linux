#!/usr/bin/env python3
"""Print an app's log lines from the running guest, through vphoned (logs.syslog).

    tools/app-logs.py PROCESS [--subsystem SUBSYSTEM] [--seconds N] [--cid CID] [--json]

Collects the guest's unified log for N seconds (default 10) and prints the entries of the process
named PROCESS (the app's executable name, e.g. HelloVPhone), one per line:

    13:27:12 notice com.example.HelloVPhone/ui: tapped 4 times

--subsystem keeps only the entries the app logged itself through os.Logger / os_log with that
subsystem (UIKit's own lines are dropped). Messages an app logs with `privacy: .public` (or that
hold no dynamic values) arrive readable; other dynamic values show as <private>, as on a phone.
Use it while you interact with the app: the collection runs while the command waits.
CID defaults to $CID or 3 (run-vphone.sh's default).
"""
import argparse
import json
import os
import socket
import sys

PORT = 1339


def response(s):
    """One HTTP response's body, up to its Content-Length (vphoned can keep the connection open)."""
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


def rpc(cid, method, timeout, **params):
    body = json.dumps({"method": method, "params": params, "id": 1}).encode()
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.settimeout(timeout)
    s.connect((cid, PORT))
    # vphoned refuses requests whose Host is not localhost ("Requests from web pages ...").
    s.sendall(b"POST /v1/rpc HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
              b"Connection: close\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
    r = json.loads(response(s))
    if "error" in r:
        sys.exit(f"{method}: {r['error']['message']}")
    return r["result"]


ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
ap.add_argument("process", help="the app's executable name, e.g. HelloVPhone")
ap.add_argument("--subsystem", help="only the app's own os.Logger lines with this subsystem")
ap.add_argument("--seconds", type=float, default=10, help="how long to collect (default 10)")
ap.add_argument("--cid", type=int, default=int(os.environ.get("CID", 3)))
ap.add_argument("--json", action="store_true", help="print the raw entries as JSON lines")
a = ap.parse_args()

print(f"collecting {a.process}'s log for {a.seconds:g} s ...", file=sys.stderr)
result = rpc(a.cid, "logs.syslog", a.seconds + 60, seconds=a.seconds, process=a.process,
             max_lines=5000)
entries = result.get("entries") or []
if a.subsystem:
    entries = [e for e in entries if e.get("subsystem") == a.subsystem]
for e in entries:
    if a.json:
        print(json.dumps(e))
        continue
    when = (e.get("date") or "")[11:19]
    where = "/".join(x for x in (e.get("subsystem"), e.get("category")) if x)
    print(f"{when} {e.get('level', '')} {where}: {e.get('message', '')}")
if result.get("truncated"):
    print("(truncated: shorten --seconds or narrow with --subsystem)", file=sys.stderr)
