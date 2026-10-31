#!/usr/bin/env python3
"""The VM window's companion: its button bar, and its rotation on a foldable guest.

    tools/window/vphone-window.py SOCKET [--cid CID] [--px 48]

run-vphone.sh starts it next to QEMU when the window is on (WINDOW=1), with SOCKET the window's
control socket (REIMS_VGPU_WINDOW_CONTROL). It ends when QEMU does.

- Sends the window its button bar (`toolbar ATLAS PX ids`): Home, Lock, Volume up, Volume down,
  Screenshot, and Fold on a foldable guest (an iPhone Duo).
- Turns each `button ID` the window sends into a vphoned call over vsock (CID, port 1339):
  `input.button` for the hardware buttons, `screen.screenshot` saved to ~/Pictures/vphone/, and
  `display.posture` for the fold.
- On a foldable guest, follows the hinge (`display.orientation`'s `fold_angle`, four times a
  second, a change taken once two reads agree) and rotates the window: open, the guest draws the
  inner display a quarter turn round on the panel, so the window turns it a quarter clockwise and
  goes landscape; closed, the cover is upright.

Closing goes open → book → closed: from open flat straight to closed, SpringBoard on this guest
takes the hinge (its pose reads closed) but never resolves the display mode, and stays on the
inner display; through book it folds every time (measured 2026-10-31, iPhone19,4 27.1).
"""
import argparse
import base64
import datetime
import json
import os
import select
import shutil
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 1339
BASE_BUTTONS = ["home", "lock", "volume-up", "volume-down", "screenshot"]
ATLAS_ORDER = BASE_BUTTONS + ["fold"]   # the rows of tools/window/toolbar-<px>.rgba
POLL = 0.25


def log(*a):
    print("vphone-window:", *a, file=sys.stderr, flush=True)


# ------------------------------------------------------------------ vphoned
def _response(s):
    """One HTTP response's body, up to its Content-Length (vphoned can keep the connection open)."""
    raw = b""
    while b"\r\n\r\n" not in raw:
        chunk = s.recv(1 << 16)
        if not chunk:
            break
        raw += chunk
    head, _, body = raw.partition(b"\r\n\r\n")
    length = next((int(line.split(b":", 1)[1]) for line in head.split(b"\r\n")
                   if line.lower().startswith(b"content-length:")), None)
    while length is None or len(body) < length:
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        body += chunk
    return body if length is None else body[:length]


def rpc(cid, method, timeout=30, **params):
    """A vphoned RPC; the result, or raises RuntimeError with vphoned's message."""
    body = json.dumps({"method": method, "params": params, "id": 1}).encode()
    s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    s.settimeout(timeout)
    try:
        s.connect((cid, PORT))
        # vphoned refuses requests whose Host is not localhost.
        s.sendall(b"POST /v1/rpc HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
                  b"Connection: close\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
        r = json.loads(_response(s))
    finally:
        s.close()
    if "error" in r:
        raise RuntimeError(f"{method}: {r['error'].get('message')}")
    return r["result"]


# ------------------------------------------------------------------ actions
class Guest:
    def __init__(self, cid):
        self.cid = cid
        self.busy = threading.Lock()   # one action at a time; clicks meanwhile are dropped
        self.fold_angle = None         # the last agreed hinge angle (None: not foldable/unknown)

    def orientation(self):
        try:
            return rpc(self.cid, "display.orientation", timeout=5)
        except (OSError, RuntimeError, ValueError):
            return None

    def act(self, button):
        if not self.busy.acquire(blocking=False):
            log(f"{button}: still busy with the last button")
            return
        threading.Thread(target=self._act, args=(button,), daemon=True).start()

    def _act(self, button):
        try:
            if button == "screenshot":
                self.screenshot()
            elif button == "fold":
                self.fold()
            else:
                rpc(self.cid, "input.button", name=button)
        except (OSError, RuntimeError, ValueError) as e:
            log(f"{button}: {e}")
        finally:
            self.busy.release()

    def screenshot(self):
        r = rpc(self.cid, "screen.screenshot", timeout=60)
        folder = os.path.join(os.path.expanduser("~"), "Pictures", "vphone")
        os.makedirs(folder, exist_ok=True)
        path = os.path.join(folder, datetime.datetime.now().strftime("vphone-%Y%m%d-%H%M%S.jpg"))
        with open(path, "wb") as f:
            f.write(base64.b64decode(r["data"]))
        log(f"screenshot saved: {path}")
        if shutil.which("notify-send"):
            subprocess.run(["notify-send", "-a", "vphone", "-i", path, "Screenshot saved", path],
                           check=False)

    def fold(self):
        o = self.orientation() or {}
        if (o.get("fold_angle") or 0) >= 90:
            # See the module doc: closing goes through book.
            rpc(self.cid, "display.posture", timeout=40, position="book")
            time.sleep(1.5)
            rpc(self.cid, "display.posture", timeout=40, position="closed")
        else:
            rpc(self.cid, "display.posture", timeout=40, position="open")


# ------------------------------------------------------------------ the window
class Window:
    def __init__(self, path):
        self.path = path
        self.sock = None
        self.buf = b""

    def connect(self):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(self.path)
        except OSError:
            s.close()
            return False
        self.sock, self.buf = s, b""
        return True

    def send(self, line):
        if not self.sock:
            return
        try:
            self.sock.sendall(line.encode() + b"\n")
        except OSError:
            self.drop()

    def drop(self):
        if self.sock:
            self.sock.close()
        self.sock = None

    def lines(self, timeout):
        """The lines the window sent within `timeout` (empty when none, or when it went away)."""
        if not self.sock:
            time.sleep(timeout)
            return []
        r, _, _ = select.select([self.sock], [], [], timeout)
        if not r:
            return []
        try:
            data = self.sock.recv(4096)
        except OSError:
            data = b""
        if not data:
            log("window closed the control socket")
            self.drop()
            return []
        self.buf += data
        *done, self.buf = self.buf.split(b"\n")
        return [d.decode(errors="replace").strip() for d in done if d.strip()]


def atlas_for(buttons, px):
    """The atlas holding exactly `buttons`' rows, in that order (the committed one has them all)."""
    src = os.path.join(HERE, f"toolbar-{px}.rgba")
    with open(src, "rb") as f:
        data = f.read()
    row = 2 * px * px * 4
    if buttons == ATLAS_ORDER:
        return src
    out = os.path.join(os.environ.get("XDG_RUNTIME_DIR", "/tmp"), f"vphone-toolbar-{os.getpid()}.rgba")
    with open(out, "wb") as f:
        for b in buttons:
            i = ATLAS_ORDER.index(b)
            f.write(data[i * row:(i + 1) * row])
    return out


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("socket")
    ap.add_argument("--cid", type=int, default=int(os.environ.get("CID", 3)))
    ap.add_argument("--px", type=int, default=48)
    a = ap.parse_args()

    owner = os.getppid()   # run-vphone.sh, which execs QEMU: the same pid
    guest, win = Guest(a.cid), Window(a.socket)
    foldable = None        # unknown until vphoned answers
    sent_buttons, rotation, pending = None, None, None

    while os.getppid() == owner:
        if not win.sock and win.connect():
            log(f"connected to {a.socket}")
            sent_buttons, rotation = None, None

        o = guest.orientation()
        if o is not None and foldable is None:
            foldable = "fold_angle" in o
            log("foldable guest" if foldable else "guest is not foldable")

        buttons = BASE_BUTTONS + (["fold"] if foldable else [])
        if win.sock and buttons != sent_buttons:
            win.send(f"toolbar {atlas_for(buttons, a.px)} {a.px} {','.join(buttons)}")
            sent_buttons = buttons

        if foldable and o is not None and o.get("fold_angle") is not None:
            want = 90 if o["fold_angle"] >= 90 else 0
            # A change is taken once two reads agree: the hinge sweeps through angles on its way.
            if want != rotation and want == pending and win.sock:
                win.send(f"rotate {want}")
                rotation = want
                log(f"hinge {o['fold_angle']}°: window rotated {want}°")
            pending = want

        for line in win.lines(POLL):
            parts = line.split()
            if len(parts) == 2 and parts[0] == "button":
                guest.act(parts[1])
            else:
                log(f"unexpected from the window: {line!r}")


if __name__ == "__main__":
    main()
