#!/usr/bin/env python3
"""Behavioral regressions for USB/IP unlink and guest-owned bulk waits."""

import asyncio
import errno
import importlib.util
import json
import os
import struct
import tempfile
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
