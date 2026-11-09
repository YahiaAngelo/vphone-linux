#!/usr/bin/env python3
"""Guest-free coverage of the toolbar's native and fallback VSOCK connections."""
import ctypes
import errno
import importlib.util
import json
from pathlib import Path
import select
import socket
import struct
import sys
import threading
from types import SimpleNamespace
import unittest
from unittest import mock


SPEC = importlib.util.spec_from_file_location(
    "vphone_window_vsock", Path(__file__).with_name("vphone-window.py"))
window = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(window)


def socket_api(factory, native=False):
    api = SimpleNamespace(socket=factory, SOCK_STREAM=socket.SOCK_STREAM,
                          SOL_SOCKET=socket.SOL_SOCKET, SO_ERROR=socket.SO_ERROR)
    if native:
        api.AF_VSOCK = 40
    return api


class RpcTests(unittest.TestCase):
    def setUp(self):
        self.now = 100.0
        self.connect_error = errno.EINPROGRESS
        self.socket_errors = [0]
        self.ready = True
        self.interrupted = False
        self.waits = []
        self.addresses = []
        self.native_addresses = []
        self.sent = []
        self.closed = False
        result = json.dumps({"result": {"width": 430, "height": 932}}).encode()
        self.response = b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(result) + result
        owner = self

        class Socket:
            timeout = None

            def settimeout(self, value):
                self.timeout = value

            def setblocking(self, value):
                owner.assertFalse(value)

            def fileno(self):
                return 42

            def connect(self, address):
                owner.native_addresses.append(address)

            def getsockopt(self, level, option):
                owner.assertEqual((level, option), (socket.SOL_SOCKET, socket.SO_ERROR))
                return owner.socket_errors.pop(0)

            def sendall(self, data):
                owner.sent.append(data)

            def recv(self, size):
                data, owner.response = owner.response[:size], owner.response[size:]
                return data

            def close(self):
                owner.closed = True

        self.sock = Socket()

        def factory(family, kind):
            self.assertEqual((family, kind), (40, socket.SOCK_STREAM))
            return self.sock

        def connect(fd, address, length):
            self.assertEqual(fd, 42)
            self.addresses.append(struct.unpack("@HHIIB3s", ctypes.string_at(address, length)))
            ctypes.set_errno(self.connect_error)
            return -1 if self.connect_error else 0

        def writable(read, write, errors, timeout):
            self.assertEqual((read, write, errors), ([], [self.sock], []))
            self.waits.append(timeout)
            self.now += min(timeout, .04)
            self.assertLess(self.now, 101, "connect extended its deadline")
            if self.interrupted:
                raise InterruptedError
            return [], [self.sock] if self.ready else [], []

        patches = [
            mock.patch.object(window, "socket", socket_api(factory)),
            mock.patch.object(ctypes, "CDLL", return_value=SimpleNamespace(connect=connect)),
            mock.patch.object(window.select, "select", side_effect=writable),
            mock.patch.object(window.time, "monotonic", side_effect=lambda: self.now),
        ]
        for patch in patches:
            patch.start()
            self.addCleanup(patch.stop)

    def test_missing_af_vsock_still_calls_read_only_rpc(self):
        result = window.rpc(45, "device.screen", timeout=.1)
        self.assertEqual(result, {"width": 430, "height": 932})
        self.assertEqual(self.addresses, [(40, 0, 1339, 45, 0, b"\0\0\0")])
        self.assertIn(b"Host: localhost\r\n", self.sent[0])
        payload = json.loads(self.sent[0].split(b"\r\n\r\n", 1)[1])
        self.assertEqual(payload, {"method": "device.screen", "params": {}, "id": 1})
        self.assertGreater(self.sock.timeout, 0)
        self.assertLess(self.sock.timeout, .1)
        self.assertTrue(self.closed)

    def test_native_python_keeps_its_address_tuple(self):
        window.socket.AF_VSOCK = 40
        window.rpc(45, "device.screen", timeout=3)
        self.assertEqual(self.native_addresses, [(45, 1339)])
        self.assertEqual(self.addresses, [])
        self.assertEqual(self.sock.timeout, 3)
        self.assertTrue(self.closed)

    def test_health_uses_the_shared_bounded_transport(self):
        report = {"name": "vphoned", "status": "ok", "capabilities": ["clock"]}
        body = json.dumps(report).encode()
        self.response = b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body) + body

        self.assertEqual(window.health(7, timeout=.1), report)
        self.assertTrue(self.sent[0].startswith(b"GET /v1/health HTTP/1.1\r\nHost: localhost\r\n"))
        self.assertGreater(self.sock.timeout, 0)
        self.assertLess(self.sock.timeout, .1)
        self.assertTrue(self.closed)

    def test_rpc_error_envelopes_raise_runtime_errors_and_close(self):
        for error, message in ((None, "invalid RPC error response"),
                               ("busy", "invalid RPC error response"),
                               ({"message": "guest refused"}, "guest refused")):
            with self.subTest(error=error):
                self.socket_errors = [0]
                self.closed = False
                body = json.dumps({"error": error}).encode()
                self.response = b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body) + body
                with self.assertRaisesRegex(RuntimeError, message):
                    window.rpc(7, "time.clock", timeout=5, time=1_800_000_000.0)
                self.assertTrue(self.closed)

    def test_immediate_connect_does_not_wait(self):
        self.connect_error = 0
        window.rpc(45, "device.screen", timeout=.1)
        self.assertEqual(self.waits, [])
        self.assertTrue(self.closed)

    def test_connect_syscall_errors_propagate_and_close_socket(self):
        self.connect_error = errno.EACCES
        with self.assertRaises(OSError) as raised:
            window.rpc(45, "device.screen")
        self.assertEqual(raised.exception.errno, errno.EACCES)
        self.assertEqual(self.waits, [])
        self.assertTrue(self.closed)

    def test_pending_connect_reports_socket_error(self):
        self.socket_errors = [errno.ECONNREFUSED]
        with self.assertRaises(OSError) as raised:
            window.rpc(45, "device.screen")
        self.assertEqual(raised.exception.errno, errno.ECONNREFUSED)
        self.assertEqual(self.sent, [])
        self.assertTrue(self.closed)

    def test_pending_status_is_not_mistaken_for_completion(self):
        self.socket_errors = [errno.EINPROGRESS, 0]
        window.rpc(45, "device.screen", timeout=.1)
        self.assertEqual(self.socket_errors, [])
        self.assertTrue(self.closed)

    def test_pending_connect_expires_at_one_deadline(self):
        self.ready = False
        with self.assertRaises(TimeoutError):
            window.rpc(45, "device.screen", timeout=.1)
        self.assertAlmostEqual(self.now, 100.1)
        self.assertTrue(all(0 < wait <= .1 + 1e-9 for wait in self.waits))
        self.assertEqual(self.sent, [])
        self.assertTrue(self.closed)

    def test_interrupted_waits_do_not_reset_the_deadline(self):
        self.interrupted = True
        self.test_pending_connect_expires_at_one_deadline()

    def test_response_trickle_cannot_extend_the_request_deadline(self):
        for phase in ("headers", "body"):
            with self.subTest(phase=phase):
                self.now = 100.0
                self.closed = False
                self.socket_errors = [0]
                self.response = b'HTTP/1.1 200 OK\r\nContent-Length: 13\r\n\r\n{"result":{}}'
                first = True

                def recv(size):
                    nonlocal first
                    if first and phase == "body":
                        first = False
                        head, _, self.response = self.response.partition(b"\r\n\r\n")
                        return head + b"\r\n\r\n"
                    elapsed = min(.04, self.sock.timeout)
                    self.now += elapsed
                    if elapsed < .04:
                        raise TimeoutError("fake recv reached its socket deadline")
                    data, self.response = self.response[:1], self.response[1:]
                    return data

                with mock.patch.object(self.sock, "recv", side_effect=recv):
                    with self.assertRaises(TimeoutError):
                        window.rpc(45, "device.screen", timeout=.1)

                self.assertAlmostEqual(self.now, 100.1)
                self.assertTrue(self.closed)

    def test_send_uses_only_the_budget_left_after_connect(self):
        def send(data):
            self.assertAlmostEqual(self.sock.timeout, .06)
            self.sent.append(data)
            self.now += .02

        with mock.patch.object(self.sock, "sendall", side_effect=send):
            window.rpc(45, "device.screen", timeout=.1)

        self.assertAlmostEqual(self.sock.timeout, .04)
        self.assertTrue(self.closed)

    def test_no_request_is_sent_after_connect_exhausts_the_deadline(self):
        window.socket.AF_VSOCK = 40

        def connect(address):
            self.now += .1

        with mock.patch.object(self.sock, "connect", side_effect=connect):
            with self.assertRaises(TimeoutError):
                window.rpc(45, "device.screen", timeout=.1)

        self.assertEqual(self.sent, [])
        self.assertTrue(self.closed)


@unittest.skipUnless(sys.platform.startswith("linux"), "VSOCK uses Linux's socket ABI")
class KernelLoopbackTests(unittest.TestCase):
    def test_fallback_packs_a_real_kernel_connection_without_a_guest(self):
        try:
            listener = socket.socket(getattr(socket, "AF_VSOCK", 40), socket.SOCK_STREAM)
        except OSError as error:
            self.skipTest(f"host VSOCK unavailable: {error}")
        with listener:
            libc = ctypes.CDLL(None, use_errno=True)
            libc.bind.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_uint]
            libc.bind.restype = ctypes.c_int
            libc.getsockname.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.POINTER(ctypes.c_uint)]
            libc.getsockname.restype = ctypes.c_int
            libc.accept4.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int]
            libc.accept4.restype = ctypes.c_int
            address = ctypes.create_string_buffer(struct.pack("@HHIIB3x", 40, 0, 0xFFFFFFFF, 1, 0))
            if libc.bind(listener.fileno(), address, 16) != 0:
                self.skipTest(f"host VSOCK loopback unavailable: errno {ctypes.get_errno()}")
            length = ctypes.c_uint(16)
            self.assertEqual(libc.getsockname(listener.fileno(), address, ctypes.byref(length)), 0)
            _, _, port, cid, _ = struct.unpack("@HHIIB3x", address.raw[:16])
            self.assertEqual(cid, 1)
            listener.listen(1)
            errors = []

            def serve():
                try:
                    if not select.select([listener], [], [], 2)[0]:
                        raise TimeoutError("no loopback connection")
                    fd = libc.accept4(listener.fileno(), None, None, socket.SOCK_CLOEXEC)
                    if fd < 0:
                        raise OSError(ctypes.get_errno(), "accept4")
                    with socket.socket(40, socket.SOCK_STREAM, fileno=fd) as peer:
                        peer.settimeout(2)
                        request = b""
                        while b"\r\n\r\n" not in request:
                            request += peer.recv(4096)
                        body = b'{"result":{"width":430,"height":932}}'
                        peer.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body) + body)
                except Exception as error:
                    errors.append(error)

            server = threading.Thread(target=serve, daemon=True)
            server.start()
            try:
                with mock.patch.object(window, "PORT", port), mock.patch.object(
                        window, "socket", socket_api(socket.socket)):
                    self.assertEqual(window.rpc(1, "device.screen", timeout=2), {"width": 430, "height": 932})
            finally:
                server.join(3)
            self.assertFalse(server.is_alive())
            self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main()
