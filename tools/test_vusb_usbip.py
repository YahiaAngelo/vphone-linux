#!/usr/bin/env python3
"""Behavioral regressions for USB/IP unlink and guest-owned bulk waits."""

import asyncio
import errno
import importlib.util
import json
import os
import struct
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch


SOURCE = Path(__file__).with_name("vusb-usbip.py")
SPEC = importlib.util.spec_from_file_location("vusb_usbip", SOURCE)
assert SPEC is not None and SPEC.loader is not None
vusb_usbip = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(vusb_usbip)


class FakeWriter:
    def __init__(self):
        self.data = bytearray()
        self.closed = False

    def write(self, data):
        self.data.extend(data)

    async def drain(self):
        pass

    def close(self):
        self.closed = True

    async def wait_closed(self):
        pass


class BlockingUSB:
    def __init__(self):
        self.aborts = []

    async def transfer(self, *_args, **_kwargs):
        await asyncio.Future()

    async def abort(self, endpoint, direction_in):
        self.aborts.append((endpoint, direction_in))


class DiscoveryWire(FakeWriter):
    """Answer the production chardev protocol without opening a socket."""

    def __init__(self, reader, fault):
        super().__init__()
        self.reader = reader
        self.fault = fault
        self.resets = 0

    def response(self, code, payload=b""):
        self.reader.feed_data(struct.pack("<I", len(payload) + 2) + bytes((code, 0)) + payload)

    def write(self, data):
        super().write(data)
        length, endpoint, kind = struct.unpack("<IBB", data[:6])
        assert len(data) == length + 6 and endpoint == 0
        if kind == vusb_usbip.MSG_RESET:
            self.resets += 1
            if self.fault == "reset_forever" or self.fault == "reset" and self.resets == 1:
                self.response(vusb_usbip.CODE_DRIVER_RESET)
            elif self.fault == "eof":
                self.reader.feed_eof()
            elif self.fault == "framing":
                self.reader.feed_data(struct.pack("<I", 1) + b"\x04")
            elif self.fault == "late_reset":
                if self.resets > 1:
                    asyncio.get_running_loop().call_later(0.03, self.response, vusb_usbip.CODE_RESET)
            elif self.fault != "absent":
                self.response(vusb_usbip.CODE_RESET)
            return

        assert kind == vusb_usbip.MSG_DATA
        if self.fault == "control_absent":
            return
        _, request, value, _, wanted = struct.unpack("<BBHHH", data[6:14])
        assert request == 6
        if self.fault == "config_header" and self.resets == 1 and value == 0x0200:
            self.response(vusb_usbip.CODE_DRIVER_RESET)
            return
        if self.fault == "protocol":
            self.response(7)
            return
        old_device = self.resets == 1 and self.fault in ("config_header", "after_config")
        device = struct.pack(
            "<BBHBBBBHHHBBBB", 18, 1, 0x0200, 0, 0, 0, 64,
            0x05AC, 0x1111 if old_device else 0x12A8, 0x0100, 0, 0, 0, 1,
        )
        config = struct.pack("<BBHBBBBB", 9, 2, 25, 1, 1, 0, 0x80, 50)
        config += bytes((9, 4, 0, 0, 1, 0xFF, 0x42, 0, 0))
        config += struct.pack("<BBBBHB", 7, 5, 0x82 if old_device else 0x81, 2, 512, 0)
        self.response(vusb_usbip.CODE_DATA, (device if value == 0x0100 else config)[:wanted])
        if self.fault == "after_config" and self.resets == 1 and wanted == len(config):
            self.response(vusb_usbip.CODE_DRIVER_RESET)


class USBStartupTests(unittest.TestCase):
    def startup(self, fault=None, timeout=5):
        async def exercise():
            reader = asyncio.StreamReader()
            self.wire = DiscoveryWire(reader, fault)
            self.connections = 0
            self.server_calls = 0
            snapshot = {}
            test = self

            async def connect(_path):
                self.connections += 1
                return reader, self.wire

            class Server:
                async def __aenter__(self):
                    return self

                async def __aexit__(self, *_args):
                    return False

                async def serve_forever(self):
                    await asyncio.sleep(0)
                    test.assertIsNotNone(self.bridge.device_record)
                    snapshot.update(
                        pid=self.bridge.pid,
                        interfaces=self.bridge.interfaces[:],
                        endpoints=dict(self.bridge.endpoint_sizes),
                        pci_stage=self.bridge.pci_stage,
                        detached=self.bridge.usb.detached.is_set(),
                    )

            async def start_server(handler, *_args):
                self.server_calls += 1
                server = Server()
                server.bridge = handler.__self__
                return server

            args = types.SimpleNamespace(chardev="unused", host="127.0.0.1", port=0)
            with patch.object(vusb_usbip.asyncio, "open_unix_connection", connect), \
                 patch.object(vusb_usbip.asyncio, "start_server", start_server), \
                 patch.object(vusb_usbip, "USB_TRACE", False), \
                 patch.object(vusb_usbip, "log") as messages:
                try:
                    await asyncio.wait_for(vusb_usbip.main_async(args), timeout)
                finally:
                    self.messages = [" ".join(map(str, call.args)) for call in messages.call_args_list]
            return snapshot

        return asyncio.run(exercise())

    def test_initial_driver_reset_reuses_live_transport(self):
        for fault in ("reset", "config_header", "after_config"):
            with self.subTest(fault=fault):
                snapshot = self.startup(fault)
                self.assertEqual(self.connections, 1)
                self.assertEqual(self.wire.resets, 2)
                self.assertTrue(self.wire.closed)
                self.assertEqual(snapshot, {
                    "pid": 0x12A8,
                    "interfaces": [bytes((0xFF, 0x42, 0))],
                    "endpoints": {0x81: 512},
                    "pci_stage": True,
                    "detached": False,
                })
                self.assertTrue(any("guest driver reset" in message for message in self.messages))

    def test_normal_initial_discovery_still_succeeds(self):
        self.assertEqual(self.startup()["pid"], 0x12A8)
        self.assertEqual(self.wire.resets, 1)
        self.assertEqual(self.connections, 1)

    def test_late_dfu_reset_uses_the_remaining_startup_budget(self):
        with patch.object(vusb_usbip, "CTRL_TIMEOUT", 0.01), \
             patch.object(vusb_usbip, "STAGE_TIMEOUT", 2):
            self.assertEqual(self.startup("late_reset")["pid"], 0x12A8)
        self.assertEqual(self.wire.resets, 2)
        self.assertEqual(self.connections, 1)

    def test_closed_transport_is_fatal_without_retry(self):
        with self.assertRaisesRegex(ConnectionError, "chardev closed"):
            self.startup("eof")
        self.assertEqual(self.wire.resets, 1)
        self.assertEqual(self.server_calls, 0)
        self.assertTrue(self.wire.closed)
        self.assertTrue(any("chardev stopped" in message for message in self.messages))

    def test_framing_error_is_not_reclassified_as_driver_reset(self):
        with self.assertRaisesRegex(ValueError, "invalid vusb response length 1"):
            self.startup("framing")
        self.assertEqual(self.wire.resets, 1)
        self.assertEqual(self.server_calls, 0)

    def test_control_protocol_error_remains_fatal(self):
        with self.assertRaises(OSError) as error:
            self.startup("protocol")
        self.assertEqual(error.exception.errno, errno.EPROTO)
        self.assertEqual(self.wire.resets, 1)
        self.assertEqual(self.server_calls, 0)

    def test_absence_and_repeated_resets_have_a_total_startup_deadline(self):
        for fault in ("absent", "reset_forever", "control_absent"):
            with self.subTest(fault=fault), \
                 patch.object(vusb_usbip, "STAGE_TIMEOUT", 0.04), \
                 patch.object(vusb_usbip, "CTRL_TIMEOUT", 0.5 if fault == "control_absent" else 0.01):
                with self.assertRaisesRegex(asyncio.TimeoutError, "initial discovery"):
                    self.startup(fault, timeout=0.5)
                self.assertEqual(self.server_calls, 0)
                self.assertTrue(self.wire.closed)


class USBIPTests(unittest.TestCase):
    def test_vphone_trace_settings_are_loaded_from_environment(self):
        with tempfile.TemporaryDirectory() as temporary:
            trace_path = str(Path(temporary) / "usb-trace.jsonl")
            try:
                with patch.dict(os.environ, {
                    "VPHONE_USB_TRACE": "1",
                    "VPHONE_USB_TRACE_FILE": trace_path,
                }):
                    SPEC.loader.exec_module(vusb_usbip)
                    self.assertTrue(vusb_usbip.USB_TRACE)
                    self.assertEqual(vusb_usbip.USB_TRACE_FILE, trace_path)
            finally:
                SPEC.loader.exec_module(vusb_usbip)

    def test_restore_trace_is_opt_in_and_private(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "usb-trace.jsonl"
            previous = (
                vusb_usbip.USB_TRACE,
                vusb_usbip.USB_TRACE_FILE,
                vusb_usbip.USB_TRACE_WRITE_FAILED,
            )
            try:
                vusb_usbip.USB_TRACE_FILE = str(path)
                vusb_usbip.USB_TRACE_WRITE_FAILED = False
                vusb_usbip.USB_TRACE = False
                vusb_usbip.usb_trace("usb.discover.complete", product_id="12ac")
                self.assertFalse(path.exists())

                vusb_usbip.USB_TRACE = True
                vusb_usbip.usb_trace("usb.discover.complete", product_id="12ac", interface_count=1)
                record = json.loads(path.read_text().strip())
                self.assertEqual(record["event"], "usb.discover.complete")
                self.assertEqual(record["product_id"], "12ac")
                self.assertNotIn("payload", record)
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)

                path.chmod(0o644)
                vusb_usbip.usb_trace("usb.detach.complete", reason="test")
                self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            finally:
                (vusb_usbip.USB_TRACE,
                 vusb_usbip.USB_TRACE_FILE,
                 vusb_usbip.USB_TRACE_WRITE_FAILED) = previous

    def test_unlink_consumes_full_request_and_cancels_target_urb(self):
        async def exercise():
            reader = asyncio.StreamReader()
            writer = FakeWriter()
            usb = BlockingUSB()
            bridge = vusb_usbip.USBIPBridge(usb)
            bridge.device_record = bytes(312)
            bridge.pid = 0x12AC

            import_request = struct.pack(
                "!HHI", vusb_usbip.USBIP_VERSION, vusb_usbip.OP_REQ_IMPORT, 0,
            ) + vusb_usbip.BUSID.ljust(32, b"\0")
            submit = struct.pack(
                "!IIIIIIiiii8s", vusb_usbip.CMD_SUBMIT, 2, 0, 1, 1, 0,
                16, 0, 0, 0, b"\0" * 8,
            )
            unlink = struct.pack("!I", vusb_usbip.CMD_UNLINK) + struct.pack(
                "!IIIII24x", 3, 0, 1, 1, 2,
            )
            reader.feed_data(import_request + submit + unlink)
            reader.feed_eof()

            await bridge.handle_connection(reader, writer)

            import_reply_length = 8 + 312
            reply = struct.unpack(
                "!IIIIIi24x", writer.data[import_reply_length:import_reply_length + 48],
            )
            self.assertEqual(reply, (
                vusb_usbip.RET_UNLINK, 3, 0, 0, 0, -errno.ECONNRESET,
            ))
            self.assertEqual(usb.aborts, [(1, True)])

        asyncio.run(exercise())

    def test_bulk_in_waits_for_guest_without_an_internal_timeout(self):
        async def exercise():
            previous_timeout = vusb_usbip.URB_TIMEOUT
            previous_defaults = vusb_usbip.VUSB._next.__defaults__
            vusb_usbip.URB_TIMEOUT = 0.01
            vusb_usbip.VUSB._next.__defaults__ = (0.01, None)
            try:
                usb = vusb_usbip.VUSB(None, FakeWriter())
                task = asyncio.create_task(usb.transfer(1, True, max_length=32))
                await asyncio.sleep(0.03)
                if task.done():
                    try:
                        await task
                    except asyncio.TimeoutError:
                        pass
                    self.fail("bulk-IN expired before the host canceled it")
                usb.in_data[0x81].put_nowait((vusb_usbip.CODE_DATA, b"guest data"))
                self.assertEqual(await asyncio.wait_for(task, 0.1), b"guest data")
            finally:
                vusb_usbip.URB_TIMEOUT = previous_timeout
                vusb_usbip.VUSB._next.__defaults__ = previous_defaults

        asyncio.run(exercise())

    def test_bulk_out_still_uses_the_bounded_timeout(self):
        async def exercise():
            previous_timeout = vusb_usbip.URB_TIMEOUT
            previous_defaults = vusb_usbip.VUSB._next.__defaults__
            vusb_usbip.URB_TIMEOUT = 0.01
            vusb_usbip.VUSB._next.__defaults__ = (0.01, None)
            try:
                usb = vusb_usbip.VUSB(None, FakeWriter())
                with self.assertRaises(asyncio.TimeoutError):
                    await usb.transfer(1, False, b"host data")
            finally:
                vusb_usbip.URB_TIMEOUT = previous_timeout
                vusb_usbip.VUSB._next.__defaults__ = previous_defaults

        asyncio.run(exercise())


if __name__ == "__main__":
    unittest.main()
