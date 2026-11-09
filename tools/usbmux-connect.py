#!/usr/bin/env python3
"""Minimal iproxy replacement over usbmuxd.

  usbmux-connect.py list
  usbmux-connect.py proxy <port>        # ssh ProxyCommand (stdin/stdout <-> device)
  usbmux-connect.py banner <port>       # print the first bytes from <port>

Uses libusbmuxd-2.0 when available (the stock usbmuxd 1.1.1 speaks its newer
MESSAGE_RESULT=1 / MESSAGE_LISTEN=3 protocol), with a legacy fallback for the
32 KiB RestoreOS daemon.
"""

import ctypes
import os
import re
import select
import socket
import struct
import sys
import time

SOCKET_PATH = os.environ.get("USBMUXD_SOCKET", "/var/run/usbmuxd")
_NO_ECID = object()

MSG_LISTEN = 3
MSG_CONNECT = 2
MSG_RESULT = 1
MSG_DEVICE_ADD = 4


class _DeviceInfo(ctypes.Structure):
    _fields_ = [
        ("handle", ctypes.c_uint32),
        ("product_id", ctypes.c_uint32),
        ("udid", ctypes.c_char * 44),
        ("conn_type", ctypes.c_int),
        ("conn_data", ctypes.c_uint8 * 200),
    ]


def _load_libusbmuxd():
    for name in ("libusbmuxd-2.0.so.7", "libusbmuxd-2.0.so",
                 "libusbmuxd.so.6", "libusbmuxd.so"):
        try:
            library = ctypes.CDLL(name)
        except OSError:
            continue
        try:
            library.usbmuxd_connect.argtypes = [ctypes.c_uint32, ctypes.c_uint16]
            library.usbmuxd_connect.restype = ctypes.c_int
        except AttributeError:
            continue
        return library
    return None


LIB = _load_libusbmuxd()


def _list_with_library():
    if LIB is None or not hasattr(LIB, "usbmuxd_get_device_list"):
        return None
    LIB.usbmuxd_get_device_list.argtypes = [ctypes.POINTER(ctypes.POINTER(_DeviceInfo))]
    LIB.usbmuxd_get_device_list.restype = ctypes.c_int
    LIB.usbmuxd_device_list_free.argtypes = [ctypes.POINTER(ctypes.POINTER(_DeviceInfo))]
    LIB.usbmuxd_device_list_free.restype = ctypes.c_int
    array = ctypes.POINTER(_DeviceInfo)()
    count = LIB.usbmuxd_get_device_list(ctypes.byref(array))
    devices = []
    if count > 0 and array:
        for index in range(count):
            device = array[index]
            devices.append((
                device.handle,
                device.product_id,
                device.udid.decode("utf-8", "replace").rstrip("\0"),
            ))
    if array:
        LIB.usbmuxd_device_list_free(ctypes.byref(array))
    return devices


def _send(sock, message, tag, payload=b""):
    header = struct.pack("<IIII", 16 + len(payload), 0, message, tag)
    sock.sendall(header + payload)


def _recv_exact(sock, count):
    data = b""
    while len(data) < count:
        chunk = sock.recv(count - len(data))
        if not chunk:
            raise EOFError("usbmuxd closed the socket")
        data += chunk
    return data


def _recv_message(sock):
    length, _version, message, tag = struct.unpack("<IIII", _recv_exact(sock, 16))
    if length < 16:
        raise ValueError(f"bad usbmuxd length {length}")
    payload = _recv_exact(sock, length - 16) if length > 16 else b""
    return message, tag, payload


def _parse_device_add(payload):
    if len(payload) < 6:
        return None
    device_id, product_id = struct.unpack("<IH", payload[:6])
    serial = payload[6:6 + 256].split(b"\0", 1)[0].decode("utf-8", "replace")
    return device_id, product_id, serial


def _list_legacy(timeout=1.0):
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(timeout)
    sock.connect(SOCKET_PATH)
    _send(sock, MSG_LISTEN, 1)
    devices = []
    deadline = time.monotonic() + timeout
    try:
        while time.monotonic() < deadline:
            try:
                message, _tag, payload = _recv_message(sock)
            except (socket.timeout, EOFError):
                break
            if message == MSG_DEVICE_ADD:
                device = _parse_device_add(payload)
                if device:
                    devices.append(device)
    finally:
        sock.close()
    return devices


def list_devices(timeout=1.0):
    devices = _list_with_library()
    if devices is not None:
        return devices
    return _list_legacy(timeout)


def connect(device_id, port):
    if LIB is not None:
        fd = LIB.usbmuxd_connect(device_id, port)
        if fd < 0:
            raise RuntimeError(f"usbmuxd_connect({device_id}, {port}) failed")
        return socket.socket(fileno=fd)

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.connect(SOCKET_PATH)
    payload = struct.pack("<I", device_id) + struct.pack(">H", port) + struct.pack("<H", 0)
    _send(sock, MSG_CONNECT, 1, payload)
    message, _tag, result_payload = _recv_message(sock)
    if message != MSG_RESULT or len(result_payload) < 4:
        sock.close()
        raise RuntimeError(f"unexpected usbmux reply message={message} payload={result_payload!r}")
    result = struct.unpack("<I", result_payload[:4])[0]
    if result != 0:
        sock.close()
        raise RuntimeError(f"usbmux connect to device {device_id} port {port} failed: {result}")
    return sock


def parse_ecid(value):
    """Parse a project ECID: one to sixteen hex digits, with optional 0x."""
    value = value.strip()
    if value[:2].lower() == "0x":
        value = value[2:]
    if not re.fullmatch(r"[0-9a-fA-F]{1,16}", value):
        raise ValueError("VPHONE_ECID must be 1-16 hexadecimal digits, optionally prefixed with 0x")
    return int(value, 16)


def _requested_ecid():
    if "VPHONE_ECID" not in os.environ:
        return _NO_ECID
    return parse_ecid(os.environ["VPHONE_ECID"])


def _serial_ecid(serial):
    """Read ECID from vphone's USB serial or predicted UDID formats."""
    serial = serial.strip().upper()
    if serial.startswith("0X"):
        ecid = serial[2:]
        return int(ecid, 16) if re.fullmatch(r"[0-9A-F]{16}", ecid) else None
    if re.fullmatch(r"[0-9A-F]{16}", serial):
        return int(serial, 16)
    if re.fullmatch(r"[0-9A-F]{8}[0-9A-F]{16}", serial):
        return int(serial[-16:], 16)
    if re.fullmatch(r"[0-9A-F]{8}-[0-9A-F]{16}", serial):
        return int(serial[-16:], 16)
    return None


def candidate_ids(devices, requested_ecid=_NO_ECID):
    if requested_ecid is _NO_ECID:
        requested_ecid = _requested_ecid()
    if requested_ecid is not _NO_ECID:
        matches = [d[0] for d in devices if _serial_ecid(d[2]) == requested_ecid]
        label = f"0x{requested_ecid:016X}"
        if not matches and len(devices) == 1 and _serial_ecid(devices[0][2]) is None:
            # The stock SSH ramdisk advertises a build-date serial with no ECID in it, and
            # `cfw install` always sets VPHONE_ECID: take it, but only as the sole device.
            matches = [devices[0][0]]
        if not matches:
            raise ValueError(f"VPHONE_ECID {label} did not match any listed usbmux device")
        if len(matches) != 1:
            raise ValueError(f"VPHONE_ECID {label} matched multiple listed usbmux devices")
        override = os.environ.get("USBMUX_DEVICE")
        if override is not None:
            if not re.fullmatch(r"[0-9]+", override):
                raise ValueError("USBMUX_DEVICE must be a numeric usbmux handle when VPHONE_ECID is set")
            if int(override, 10) != matches[0]:
                raise ValueError(
                    f"USBMUX_DEVICE {override} does not match the device selected by VPHONE_ECID {label}",
                )
        return matches
    if devices:
        return [d[0] for d in devices]
    override = os.environ.get("USBMUX_DEVICE")
    if override:
        return [int(override)]
    return [1, 2, 3, 4]


def open_port(port, devices=None):
    try:
        requested_ecid = _requested_ecid()
    except ValueError as error:
        raise SystemExit(str(error)) from None
    if devices is None and os.environ.get("USBMUX_DEVICE") and requested_ecid is _NO_ECID:
        devices = []
    elif devices is None:
        devices = list_devices()
    last_error = None
    try:
        ids = candidate_ids(devices, requested_ecid)
    except ValueError as error:
        raise SystemExit(str(error)) from None
    for device_id in ids:
        try:
            if os.environ.get("USBMUX_VERBOSE"):
                print(f"usbmux: connect device {device_id} -> port {port}", file=sys.stderr)
            return connect(device_id, port)
        except (RuntimeError, OSError) as error:
            last_error = error
    raise SystemExit(f"no reachable usbmux device on port {port}: {last_error}")


def proxy(port):
    sock = open_port(port)

    stdin_open = True
    while True:
        readable = [sock]
        if stdin_open:
            readable.append(0)
        readable, _, _ = select.select(readable, [], [])
        if 0 in readable:
            data = os.read(0, 65536)
            if data:
                sock.sendall(data)
            else:
                stdin_open = False
                try:
                    sock.shutdown(socket.SHUT_WR)
                except OSError:
                    pass
        if sock in readable:
            data = sock.recv(65536)
            if not data:
                break
            os.write(1, data)


def banner(port):
    devices = list_devices()
    if devices:
        print(f"devices: {devices}", file=sys.stderr)
    sock = open_port(port, devices)
    sock.settimeout(3.0)
    try:
        data = sock.recv(256)
    except socket.timeout:
        print("(timeout waiting for banner)", file=sys.stderr)
        data = b""
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()
    sock.close()


def main(argv):
    if len(argv) >= 2 and argv[1] == "list":
        for device_id, product_id, serial in list_devices():
            print(f"{device_id}\t{product_id:04x}\t{serial}")
        return 0
    if len(argv) >= 3 and argv[1] == "proxy":
        proxy(int(argv[2]))
        return 0
    if len(argv) >= 3 and argv[1] == "banner":
        banner(int(argv[2]))
        return 0
    print(__doc__.strip(), file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
