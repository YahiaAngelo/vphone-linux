#!/usr/bin/env python3
"""guest-top.py [SECONDS] [--cid CID] [--top N]: which guest processes use the CPU.

Reads vphoned's processes.list twice, SECONDS apart (default 60), and prints the processes whose
CPU time grew the most in between, with their share of one guest CPU and of all CPU the guest used.
Processes that started in between count from zero; ones that ended are not seen.
"""
import argparse
import json
import os
import socket
import sys
import time

PORT = 1339


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
    return body if n is None else body[:n]


def rpc(cid, method, **params):
    body = json.dumps({"method": method, "params": params, "id": 1}).encode()
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.settimeout(120)
    s.connect((cid, PORT))
    s.sendall(b"POST /v1/rpc HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
              b"Connection: close\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
    r = json.loads(response(s))
    s.close()
    if "error" in r:
        sys.exit(f"{method}: {r['error']['message']}")
    return r["result"]


def snapshot(cid):
    procs = rpc(cid, "processes.list")["processes"]
    return {(p["pid"], p.get("name", "?")): p.get("cpu_seconds", 0.0) for p in procs}


ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
ap.add_argument("seconds", nargs="?", type=float, default=60)
ap.add_argument("--cid", type=int, default=int(os.environ.get("CID", 3)))
ap.add_argument("--top", type=int, default=25)
a = ap.parse_args()

t0, s0 = time.time(), snapshot(a.cid)
time.sleep(a.seconds)
t1, s1 = time.time(), snapshot(a.cid)
wall = t1 - t0
rows = sorted(((cpu - s0.get(key, 0.0), key) for key, cpu in s1.items()), reverse=True)
total = sum(d for d, _ in rows if d > 0)
print(f"guest CPU over {wall:.0f} s: {total:.1f} CPU-s ({total / wall:.2f} guest CPUs busy), "
      f"{len(s1)} processes")
for d, (pid, name) in rows[:a.top]:
    if d <= 0:
        break
    print(f"  {d:8.1f} s  {100 * d / wall:5.1f}% of a CPU  {100 * d / max(total, 1e-9):5.1f}%  "
          f"{pid:6d} {name}")
