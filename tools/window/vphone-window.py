#!/usr/bin/env python3
"""The VM window's companion: its button bar, and its rotation on a foldable guest.

    tools/window/vphone-window.py SOCKET [--cid CID] [--px 48] [--config CONFIG]

run-vphone.sh starts it next to QEMU when the window is on (WINDOW=1), with SOCKET the window's
control socket (REIMS_VGPU_WINDOW_CONTROL). It ends when QEMU does.

- Sends the window its button bar (`toolbar ATLAS PX ids`): Home, Lock, Volume up, Volume down,
  Screenshot, and Fold on a foldable guest (an iPhone Duo).
- Turns each `button ID` the window sends into a vphoned call over vsock (CID, port 1339): Home
  returns to SpringBoard or wakes and swipes up from a locked screen; Lock powers down an awake
  screen or wakes a blanked one; volume uses `input.button`, screenshots go to ~/Pictures/vphone/,
  and Fold uses `display.posture`.
- On a foldable guest, follows the hinge (`display.orientation`'s `fold_angle`, four times a
  second, a change taken once two reads agree) and rotates the window: open, the guest draws the
  inner display a quarter turn round on the panel, so the window turns it a quarter clockwise and
  goes landscape; closed, the cover is upright.
- Offers the host's clock to guests with the `clock` capability, once connected, every minute,
  and after host clock changes or suspend. vphoned preserves manually set guest clocks.

Closing goes open → book → closed: from open flat straight to closed, SpringBoard on this guest
takes the hinge (its pose reads closed) but never resolves the display mode, and stays on the
inner display; through book it folds every time (measured 2026-10-31, iPhone19,4 27.1).
"""
import argparse
import base64
import ctypes
import datetime
import errno
import json
import math
import os
import plistlib
import select
import shutil
import socket
import struct
import subprocess
import sys
import threading
import time
from xml.parsers.expat import ExpatError

HERE = os.path.dirname(os.path.abspath(__file__))
PORT = 1339
BASE_BUTTONS = ["home", "lock", "volume-up", "volume-down", "screenshot"]
ATLAS_ORDER = BASE_BUTTONS + ["fold"]   # the rows of tools/window/toolbar-<px>.rgba
POLL = 0.25


def log(*a):
    print("vphone-window:", *a, file=sys.stderr, flush=True)


# ------------------------------------------------------------------ vphoned
def _remaining(deadline):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("vphoned request timed out")
    return remaining


def _connect_vsock(s, cid, deadline):
    s.settimeout(_remaining(deadline))
    if hasattr(socket, "AF_VSOCK"):
        s.connect((cid, PORT))
        return
    # A Python build without AF_VSOCK cannot pack its address tuple either.
    # Linux sockaddr_vm: family, reserved, port, CID, flags, reserved bytes.
    address = ctypes.create_string_buffer(struct.pack("@HHIIB3x", 40, 0, PORT, cid, 0))
    connect = ctypes.CDLL(None, use_errno=True).connect
    connect.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint]
    connect.restype = ctypes.c_int
    s.setblocking(False)
    result = connect(s.fileno(), address, 16)
    error = ctypes.get_errno() if result != 0 else 0
    pending = (errno.EINPROGRESS, errno.EALREADY, errno.EINTR)
    while error not in (0, errno.EISCONN):
        if error not in pending:
            raise OSError(error, os.strerror(error))
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("timed out connecting to vphoned")
        try:
            _, writable, _ = select.select([], [s], [], remaining)
        except InterruptedError:
            continue
        if writable:
            error = s.getsockopt(socket.SOL_SOCKET, socket.SO_ERROR)
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("timed out connecting to vphoned")
    s.settimeout(remaining)


def _response(s, deadline):
    """One HTTP response's body, up to its Content-Length (vphoned can keep the connection open)."""
    raw = b""
    while b"\r\n\r\n" not in raw:
        s.settimeout(_remaining(deadline))
        chunk = s.recv(1 << 16)
        if not chunk:
            break
        raw += chunk
    head, _, body = raw.partition(b"\r\n\r\n")
    length = next((int(line.split(b":", 1)[1]) for line in head.split(b"\r\n")
                   if line.lower().startswith(b"content-length:")), None)
    while length is None or len(body) < length:
        s.settimeout(_remaining(deadline))
        chunk = s.recv(1 << 20)
        if not chunk:
            break
        body += chunk
    return body if length is None else body[:length]


def _request(cid, request, deadline):
    s = socket.socket(getattr(socket, "AF_VSOCK", 40), socket.SOCK_STREAM)
    try:
        _connect_vsock(s, cid, deadline)
        s.settimeout(_remaining(deadline))
        s.sendall(request)
        return json.loads(_response(s, deadline))
    finally:
        s.close()


def health(cid, timeout=5):
    return _request(cid, b"GET /v1/health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
                    time.monotonic() + timeout)


def rpc(cid, method, timeout=30, **params):
    """A vphoned RPC; the result, or raises RuntimeError with vphoned's message."""
    deadline = time.monotonic() + timeout
    body = json.dumps({"method": method, "params": params, "id": 1}).encode()
    # vphoned refuses requests whose Host is not localhost.
    r = _request(cid, b"POST /v1/rpc HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\n"
                 b"Connection: close\r\nContent-Length: %d\r\n\r\n" % len(body) + body, deadline)
    if "error" in r:
        error = r["error"]
        message = error.get("message") if isinstance(error, dict) else "invalid RPC error response"
        raise RuntimeError(f"{method}: {message}")
    return r["result"]


# ------------------------------------------------------------------ host clock
class ClockSync:
    INTERVAL = 60
    RETRY = 5
    TIMEOUT = 5
    # vphoned's time.clock can take ~23 s when timed is slow (a few offers of up to 3.3 s each):
    # a shorter timeout abandons requests that keep running in the guest and piles them up.
    CLOCK_TIMEOUT = 30

    def __init__(self, cid):
        self.cid = cid
        self.owner = os.getppid()
        self.stopping = threading.Event()
        self.thread = None
        self.last_outcome = None

    def start(self):
        if self.thread is None:
            self.thread = threading.Thread(target=self._run, daemon=True)
            self.thread.start()

    def stop(self):
        self.stopping.set()
        if self.thread is not None and self.thread.ident is not None:
            self.thread.join(self.TIMEOUT + .1)

    def _active(self):
        return not self.stopping.is_set() and os.getppid() == self.owner

    def _run(self):
        previous_wall, previous_tick = time.time(), time.monotonic()
        next_send, retrying = 0, False
        while self._active():
            now, wall = time.monotonic(), time.time()
            # CLOCK_MONOTONIC excludes suspend on Linux; wall time also catches clock changes.
            if not retrying and abs((wall - previous_wall) - (now - previous_tick)) >= 1:
                next_send = now
            previous_wall, previous_tick = wall, now
            if now >= next_send:
                retrying = not self._send()
                next_send = time.monotonic() + (self.RETRY if retrying else self.INTERVAL)
            self.stopping.wait(min(1, max(0, next_send - time.monotonic())))

    def _send(self):
        if not self._active():
            return True
        moved = False
        try:
            report = health(self.cid, timeout=self.TIMEOUT)
            if (not isinstance(report, dict) or report.get("name") != "vphoned"
                    or report.get("status") != "ok" or not isinstance(report.get("capabilities"), list)):
                raise RuntimeError("vphoned is not ready for clock sync")
            if "clock" not in report["capabilities"]:
                outcome = "guest has no clock capability"
            elif not self._active():
                return True
            else:
                outcome, moved = self._offer()
        except (OSError, RuntimeError, ValueError, KeyError, TypeError) as error:
            outcome = f"could not relay the host clock: {error}"
            succeeded = False
        else:
            succeeded = True
        if self._active():
            if moved or outcome != self.last_outcome:
                log(f"clock: {outcome}")
            self.last_outcome = outcome
        return succeeded

    def _offer(self):
        """Offer the host time: (outcome, moved). Raises only when the guest could not be asked."""
        try:
            answer = rpc(self.cid, "time.clock", timeout=self.CLOCK_TIMEOUT, time=time.time())
        except RuntimeError as error:
            # vphoned answered and refused (timed kept its own time, say): asking again in
            # RETRY seconds would only repeat it, so this counts as done until the next interval.
            return f"guest refused the host clock: {error}", False
        if (not isinstance(answer, dict) or "automatic" not in answer
                or (answer["automatic"] is not None and type(answer["automatic"]) is not bool)
                or type(answer.get("changed")) is not bool):
            raise ValueError("guest returned invalid clock state")
        if answer["automatic"] is None:
            return "guest automatic-clock state is unavailable", answer["changed"]
        if not answer["automatic"]:
            return "guest keeps the time set in its Settings", answer["changed"]
        if answer["changed"]:
            return "guest clock moved to the host's time", True
        return "guest clock is on the host's time", False


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
            elif button in ("home", "lock"):
                self.button(button)
            else:
                rpc(self.cid, "input.button", name=button)
        except (OSError, RuntimeError, ValueError) as e:
            log(f"{button}: {e}")
        finally:
            self.busy.release()

    def button(self, button):
        deadline = time.monotonic() + 15

        def call(method, **params):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise RuntimeError("button action timed out")
            return rpc(self.cid, method, timeout=min(5, remaining), **params)

        name = ("com.apple.springboard.lockstate" if button == "home"
                else "com.apple.springboard.hasBlankedScreen")
        try:
            state = call("notify.state", name=name)
        except (OSError, RuntimeError):
            if button != "home":
                raise
            state = None
        if (not isinstance(state, dict) or type(state.get("state")) is not int
                or state["state"] not in (0, 1)):
            if button == "home":
                # No usable lock state (an older vphoned, a slow guest): a plain Home press, as
                # before this button was state-aware. Lock still fails closed.
                log("home: no lock state from the guest; sending the plain button")
                call("input.button", name="home")
                return
            raise RuntimeError("guest returned invalid button state")
        if button == "lock":
            call("input.button", name="wake" if state["state"] else "power")
        elif not state["state"]:
            call("input.button", name="home")
        else:
            call("input.button", name="wake")
            while True:
                blanked = call("notify.state", name="com.apple.springboard.hasBlankedScreen")
                if (not isinstance(blanked, dict) or type(blanked.get("state")) is not int
                        or blanked["state"] not in (0, 1)):
                    raise RuntimeError("guest returned invalid screen state")
                if not blanked["state"]:
                    break
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError("button action timed out")
                time.sleep(min(.15, remaining))
            screen = call("device.screen")
            if not isinstance(screen, dict):
                raise RuntimeError("guest returned invalid screen geometry")
            width, height = screen.get("width"), screen.get("height")
            if any(isinstance(value, bool) or not isinstance(value, (int, float))
                   or not 0 < value <= 16384 or not math.isfinite(value) for value in (width, height)):
                raise RuntimeError("guest returned invalid screen geometry")
            call("input.swipe", x1=width * .5, y1=height * .96,
                 x2=width * .5, y2=height * .30, seconds=.7, steps=20)

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
    ap.add_argument("--config", help="VM config.plist, for its guest product type")
    a = ap.parse_args()

    owner = os.getppid()   # run-vphone.sh, which execs QEMU: the same pid
    guest, win = Guest(a.cid), Window(a.socket)
    foldable = None
    if a.config:
        try:
            with open(a.config, "rb") as stream:
                config = plistlib.load(stream)
            product = config.get("guestProductType") if isinstance(config, dict) else None
            if isinstance(product, str) and product:
                foldable = product == "iPhone19,4"
        except (OSError, ValueError, plistlib.InvalidFileException, ExpatError) as e:
            log(f"could not read guest product type: {e}")
    sent_buttons, rotation, pending = None, None, None

    # VPHONE_CLOCK_SYNC=0 leaves the guest clock alone (for a guest run at a deliberate offset).
    clock = ClockSync(a.cid) if os.environ.get("VPHONE_CLOCK_SYNC", "1") != "0" else None
    try:
        while os.getppid() == owner:
            if not win.sock and win.connect():
                log(f"connected to {a.socket}")
                sent_buttons, rotation = None, None
                if clock:
                    clock.start()

            buttons = BASE_BUTTONS + (["fold"] if foldable else [])
            if win.sock and buttons != sent_buttons:
                win.send(f"toolbar {atlas_for(buttons, a.px)} {a.px} {','.join(buttons)}")
                sent_buttons = buttons

            o = guest.orientation() if foldable is not False else None
            # The angle is absent until the hinge is first configured, even on a Duo.
            if o is not None and foldable is None and "fold_angle" in o:
                foldable = True
                log("foldable guest")
                buttons = BASE_BUTTONS + ["fold"]
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
    finally:
        if clock:
            clock.stop()
        win.drop()


if __name__ == "__main__":
    main()
