#!/usr/bin/env python3
"""run.py [--cid CID] [--runs N] [--settle S]: run guestbench in the running guest, N times.

Uploads tools/guestbench/guestbench to /var/root/guestbench through vphoned, waits S seconds
(default 0) for the system to settle, runs it once uncounted, then N times (default 3) as
launchd jobs and prints each result line and the median of each phase. Each run line ends with
busy=, the guest CPUs the other processes used meanwhile: a run beside a busy process is slower
(broadcast TLB flushes stop every vCPU). Build guestbench with build.sh first.
"""
import argparse
import base64
import json
import os
import socket
import statistics
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 1339
DEST = "/var/root/guestbench"


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


def rpc(cid, method, timeout=600, **params):
    """One RPC; a reply cut short (vsock now and then closes a large one early) is asked again."""
    body = json.dumps({"method": method, "params": params, "id": 1}).encode()
    for attempt in range(5):
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
        s.settimeout(timeout)
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


ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
ap.add_argument("--cid", type=int, default=int(os.environ.get("CID", 3)))
ap.add_argument("--runs", type=int, default=3)
ap.add_argument("--settle", type=float, default=0)
ap.add_argument("--no-warmup", dest="warmup", action="store_false")
a = ap.parse_args()

with open(os.path.join(HERE, "guestbench"), "rb") as f:
    rpc(a.cid, "files.write", path=DEST, content=base64.b64encode(f.read()).decode(),
        encoding="base64")
rpc(a.cid, "files.chmod", path=DEST, mode="755")
time.sleep(a.settle)

def cpu_by_pid():
    """Each guest process's CPU seconds so far, guestbench's left out."""
    procs = rpc(a.cid, "processes.list")["processes"]
    return {p["pid"]: p.get("cpu_seconds", 0.0) for p in procs
            if "guestbench" not in p.get("name", "")}


def run_once(i):
    """One run as a one-shot launchd job (vphoned's process.spawn runs only launchctl, log and
    ps, and iOS 27 ships no launchctl): its stdout goes to a file, read once it holds the
    result line."""
    label = f"vphone.guestbench.{os.getpid()}.{i}"
    outp = f"/var/root/guestbench.{i}.out"
    job = f"/var/root/Library/Caches/{label}.plist"
    plist = f"""<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>{label}</string>
<key>ProgramArguments</key><array><string>{DEST}</string><string>/var/root</string></array>
<key>StandardOutPath</key><string>{outp}</string>
<key>StandardErrorPath</key><string>{outp}</string>
<key>RunAtLoad</key><true/><key>LaunchOnlyOnce</key><true/>
</dict></plist>
"""
    rpc(a.cid, "files.write", path=job, content=plist)
    out = ""
    global busy
    before, t0 = cpu_by_pid(), time.time()
    # The first job after a fresh boot sometimes starts but never writes: when a run has no
    # output after 2 minutes (it takes ~6 s), it is unloaded and started again.
    for attempt in range(3):
        rpc(a.cid, "files.write", path=outp, content="")
        rpc(a.cid, "services.load", paths=[job])
        deadline = time.time() + 120
        try:
            while time.time() < deadline:
                time.sleep(3)
                out = rpc(a.cid, "files.read", path=outp).get("content", "")
                if "total=" in out:
                    # the other processes' load meanwhile, in guest CPUs (a process that
                    # started meanwhile counts from zero, one that ended is not seen)
                    after, t1 = cpu_by_pid(), time.time()
                    used = sum(max(0.0, c - before.get(pid, 0.0)) for pid, c in after.items())
                    busy = used / max(t1 - t0, 1e-9)
                    return out.strip().splitlines()[-1]
        finally:
            rpc(a.cid, "services.unload", paths=[job], force=True)
        print(f"run {i + 1}: no output after 2 minutes ({out[:200]!r}), retrying", file=sys.stderr)
    return out.strip().splitlines()[-1] if out.strip() else ""

busy = None
phases = {}
if a.warmup:
    run_once(-1)   # not counted: the first run after boot pays for paging the binary in
for i in range(a.runs):
    busy = None
    out = run_once(i)
    if not out.startswith("guestbench"):
        sys.exit(f"run {i + 1}: unexpected output: {out[:600]!r}")
    if busy is not None:
        out += f" busy={busy:.2f}"
    print(out, flush=True)
    for kv in out.split()[1:]:
        k, _, v = kv.partition("=")
        if k != "check":
            phases.setdefault(k, []).append(float(v))
print("median " + " ".join(f"{k}={statistics.median(v):.3f}" for k, v in phases.items()))
