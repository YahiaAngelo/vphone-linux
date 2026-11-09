#!/usr/bin/env python3
"""Export QEMU's vresearch-vusb chardev as a USB/IP device.

Example:

  run-vphone.sh <vm> -chardev socket,id=vusb,path=/tmp/vusb.sock,server=on,wait=off \\
      -global vresearch-vusb.chardev=vusb
  tools/vusb-usbip.py /tmp/vusb.sock
  usbip list -r 127.0.0.1
  sudo usbip attach -r 127.0.0.1 -b 1-1

Initial discovery waits at most five minutes for the guest's USB descriptors,
including retries after a guest-driver reset on the same chardev connection.
A closed chardev or invalid protocol response stops the exporter. USB/IP listens
on 127.0.0.1:3240 by default.
"""

import argparse
import asyncio
import collections
import datetime
import errno
import json
import os
import struct
import sys
import time

USBIP_VERSION = 0x0111
OP_REQ_IMPORT = 0x8003
OP_REP_IMPORT = 0x0003
OP_REQ_DEVLIST = 0x8005
OP_REP_DEVLIST = 0x0005
CMD_SUBMIT, CMD_UNLINK = 1, 2
RET_SUBMIT, RET_UNLINK = 3, 4
USB_SPEED_HIGH = 3
BUSID = b"1-1"
DEVICE_PATH = b"/sys/devices/platform/vusb/usb1/1-1"

MSG_DATA, MSG_RESET, MSG_ABORT = 1, 2, 3
CODE_DATA, CODE_STALL, CODE_RESET, CODE_ABORT = 1, 2, 4, 5
# The PCI restore controller reports a USB NAK while an IN endpoint has no
# data yet. USB/IP models this by keeping the URB pending and polling again.
CODE_NAK = 3
# The guest re-initialised the controller (a new boot stage): the device it presented is gone.
CODE_DRIVER_RESET = 6
REDISCOVER_DELAY = 0.2
STAGE_TIMEOUT = 300.0
DEBUG = bool(os.environ.get("VUSB_DEBUG"))
# GET_DESCRIPTOR(DEVICE), wLength 64: the first request of Linux's enumeration after a port reset.
ENUMERATION_START = bytes.fromhex("8006000100004000")
# QEMU accepts a total vusb chardev message of VUSB_MSG_MAX: a 4-byte length,
# then ep/type and the payload.  The PCI restore controller's guest buffers are
# large, so allow a whole USB transfer in one message.
VUSB_MSG_MAX = 0x10000
MSG_PAYLOAD_MAX = VUSB_MSG_MAX - 6
# The RestoreOS device mux (AppleUSBDeviceMux) allocates 32 KiB read/write
# buffers and requires one complete mux packet per USB transfer: its
# handleMuxInput() drops any transfer shorter than the packet length field.
# The host usbmuxd must therefore send mux packets of at most 32 KiB; the
# stock build's 48 KiB packets cannot fit the device buffers and reset the
# RestoreOS during NORData.  Host URBs are forwarded whole.
CTRL_TIMEOUT = 5.0
URB_TIMEOUT = float(os.environ.get("VUSB_URB_TIMEOUT", "30"))
USB_TRACE = os.environ.get("VPHONE_USB_TRACE") == "1"
USB_TRACE_FILE = os.environ.get("VPHONE_USB_TRACE_FILE")
USB_TRACE_WRITE_FAILED = False


def log(*args):
    print(*args, file=sys.stderr, flush=True)


def usb_trace(event, **fields):
    """Append one opt-in event without USB transfer or descriptor contents."""
    global USB_TRACE_WRITE_FAILED
    if not USB_TRACE:
        return
    if not USB_TRACE_FILE:
        if not USB_TRACE_WRITE_FAILED:
            log("USB transport trace could not be written: trace path is unset")
            USB_TRACE_WRITE_FAILED = True
        return
    record = {
        "utc": datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="microseconds").replace(
            "+00:00", "Z"
        ),
        "monotonic_ns": time.monotonic_ns(),
        "source": "exporter",
        "event": event,
        **fields,
    }
    data = (json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n").encode()
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(USB_TRACE_FILE, flags, 0o600)
        try:
            os.fchmod(descriptor, 0o600)
            if os.write(descriptor, data) != len(data):
                raise OSError("short trace write")
        finally:
            os.close(descriptor)
    except Exception:
        if not USB_TRACE_WRITE_FAILED:
            USB_TRACE_WRITE_FAILED = True
            try:
                log("USB transport trace could not be written")
            except Exception:
                pass


class Stall(Exception):
    """The guest USB device returned a STALL response."""


class VUSB:
    """Framed chardev client and response queues for one guest USB device."""

    def __init__(self, reader, writer):
        self.reader = reader
        self.writer = writer
        self.ctrl = asyncio.Queue()
        self.reset_responses = asyncio.Queue()
        self.reset_pending = False
        self.aborts = collections.defaultdict(asyncio.Queue)
        self.out_acks = collections.defaultdict(asyncio.Queue)
        self.in_data = collections.defaultdict(asyncio.Queue)
        self.ctrl_lock = asyncio.Lock()
        self.endpoint_locks = collections.defaultdict(asyncio.Lock)
        # Data a guest returned beyond the current URB's length.  The guest does
        # not know the host's URB size, so keep the surplus for the next URB
        # rather than dropping it (which would stall usbmuxd's stream).
        self.in_remainder = collections.defaultdict(bytearray)
        self.detached = asyncio.Event()

    def _unplug(self):
        """Fail every request still waiting on the old device, and start fresh queues."""
        if self.reset_pending:
            self.reset_responses.put_nowait(CODE_DRIVER_RESET)
        for queue in [self.ctrl, *self.in_data.values(), *self.out_acks.values(), *self.aborts.values()]:
            queue.put_nowait((CODE_DRIVER_RESET, b""))
        self.ctrl = asyncio.Queue()
        self.aborts = collections.defaultdict(asyncio.Queue)
        self.out_acks = collections.defaultdict(asyncio.Queue)
        self.in_data = collections.defaultdict(asyncio.Queue)
        self.in_remainder = collections.defaultdict(bytearray)
        self.detached.set()

    async def send(self, ep, typ, payload=b""):
        if len(payload) > MSG_PAYLOAD_MAX:
            raise ValueError(f"vusb payload too large: {len(payload)}")
        self.writer.write(struct.pack("<IBB", len(payload), ep, typ) + payload)
        await self.writer.drain()

    async def run(self):
        try:
            while True:
                hdr = await self.reader.readexactly(4)
                (length,) = struct.unpack("<I", hdr)
                if length == 0:
                    continue  # an empty send (OpenAVB answers a malformed event so)
                if length < 2 or length > VUSB_MSG_MAX:
                    raise ValueError(f"invalid vusb response length {length}")
                msg = await self.reader.readexactly(length)
                code, ep, data = msg[0], msg[1], msg[2:]
                if code == CODE_DRIVER_RESET:
                    log("guest re-initialised its USB controller: device unplugged")
                    self._unplug()
                elif code == CODE_RESET:
                    if self.reset_pending:
                        await self.reset_responses.put(code)
                elif code == CODE_NAK and ep == 0 and self.reset_pending:
                    await self.reset_responses.put(code)
                elif code == CODE_ABORT:
                    await self.aborts[ep].put((code, data))
                elif ep == 0:
                    await self.ctrl.put((code, data))
                elif ep & 0x80:
                    await self.in_data[ep].put((code, data))
                else:
                    await self.out_acks[ep].put((code, data))
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        finally:
            self._unplug()

    async def _next(self, queue, timeout=URB_TIMEOUT, retry=None):
        loop = asyncio.get_running_loop()
        deadline = loop.time() + timeout if timeout is not None else None
        while True:
            remaining = deadline - loop.time() if deadline is not None else None
            if remaining is not None and remaining <= 0:
                raise asyncio.TimeoutError
            code, data = await asyncio.wait_for(queue.get(), remaining)
            if code == CODE_DRIVER_RESET:
                raise OSError(errno.ENODEV, "device unplugged (guest driver reset)")
            if code == CODE_STALL:
                raise Stall()
            if code == CODE_NAK:
                if retry is None:
                    raise OSError(errno.EPROTO, "unexpected NAK without retry callback")
                await asyncio.sleep(0.001)
                await retry()
                continue
            if code != CODE_DATA:
                raise OSError(errno.EPROTO, f"unexpected vusb response code {code}")
            return data

    async def reset(self, timeout=CTRL_TIMEOUT, *, attempt_id=None):
        deadline = asyncio.get_running_loop().time() + timeout
        while not self.reset_responses.empty():
            self.reset_responses.get_nowait()
        self.reset_pending = True
        started = time.monotonic_ns()
        send_count = 0
        pending_responses = 0
        usb_trace("usb.reset.begin", attempt_id=attempt_id, timeout_seconds=timeout)
        try:
            while True:
                remaining = deadline - asyncio.get_running_loop().time()
                if remaining <= 0:
                    usb_trace(
                        "usb.reset.timeout",
                        attempt_id=attempt_id,
                        send_count=send_count,
                        pending_responses=pending_responses,
                        elapsed_ns=time.monotonic_ns() - started,
                    )
                    raise asyncio.TimeoutError
                send_count += 1
                await self.send(0, MSG_RESET)
                if send_count == 1:
                    usb_trace("usb.reset.send", attempt_id=attempt_id, send_count=send_count)
                try:
                    code = await asyncio.wait_for(self.reset_responses.get(), remaining)
                except asyncio.TimeoutError:
                    usb_trace(
                        "usb.reset.timeout",
                        attempt_id=attempt_id,
                        send_count=send_count,
                        pending_responses=pending_responses,
                        elapsed_ns=time.monotonic_ns() - started,
                    )
                    raise
                if code == CODE_RESET:
                    usb_trace(
                        "usb.reset.response",
                        attempt_id=attempt_id,
                        response="reset",
                        send_count=send_count,
                        pending_responses=pending_responses,
                        elapsed_ns=time.monotonic_ns() - started,
                    )
                    return
                if code == CODE_DRIVER_RESET:
                    usb_trace(
                        "usb.reset.response",
                        attempt_id=attempt_id,
                        response="driver_reset",
                        send_count=send_count,
                        pending_responses=pending_responses,
                        elapsed_ns=time.monotonic_ns() - started,
                    )
                    raise OSError(errno.ENODEV, "device unplugged (guest driver reset)")
                if code == CODE_NAK:
                    pending_responses += 1
                    if pending_responses == 1:
                        usb_trace(
                            "usb.reset.pending",
                            attempt_id=attempt_id,
                            response="nak",
                            send_count=send_count,
                        )
                    await asyncio.sleep(0.001)
        finally:
            self.reset_pending = False

    async def control(self, setup, out_data=b"", *, trace_attempt=None, descriptor=None):
        if len(setup) != 8:
            raise ValueError("USB SETUP packet must be 8 bytes")
        started = time.monotonic_ns()
        trace_control = trace_attempt is not None and descriptor is not None
        if trace_control:
            usb_trace(
                "usb.control.begin",
                attempt_id=trace_attempt,
                descriptor=descriptor,
            )
        async with self.ctrl_lock:
            async def retry():
                await self.send(0, MSG_DATA, setup + out_data)

            try:
                await retry()
                result = await self._next(self.ctrl, CTRL_TIMEOUT, retry)
            except Exception as error:
                if trace_control:
                    usb_trace(
                        "usb.control.complete",
                        attempt_id=trace_attempt,
                        descriptor=descriptor,
                        result="error",
                        error_type=type(error).__name__,
                        elapsed_ns=time.monotonic_ns() - started,
                    )
                raise
            if trace_control:
                usb_trace(
                    "usb.control.complete",
                    attempt_id=trace_attempt,
                    descriptor=descriptor,
                    result="ok",
                    response_length=len(result),
                    elapsed_ns=time.monotonic_ns() - started,
                )
            return result

    async def transfer(self, ep, direction_in, payload=b"", max_length=None):
        address = ep | (0x80 if direction_in else 0)
        async with self.endpoint_locks[address]:
            if direction_in and self.in_remainder[address]:
                # Finish the transfer the guest already handed us.
                chunk = bytes(self.in_remainder[address][:max_length])
                del self.in_remainder[address][:max_length]
                return chunk
            queue = self.in_data[address] if direction_in else self.out_acks[address]

            async def retry():
                await self.send(address, MSG_DATA, payload if not direction_in else b"")

            await retry()
            # The host owns bulk-IN deadlines and cancels with USB/IP UNLINK.
            # A quiet RestoreOS may still be working on metadata for minutes.
            result = await self._next(queue, timeout=None if direction_in else URB_TIMEOUT, retry=retry)
            if not direction_in:
                return b""
            if max_length is not None and len(result) > max_length:
                self.in_remainder[address] = bytearray(result[max_length:])
                result = result[:max_length]
            return result

    async def abort(self, ep, direction_in):
        address = ep | (0x80 if direction_in else 0)
        await self.send(address, MSG_ABORT)
        try:
            await asyncio.wait_for(self.aborts[address].get(), CTRL_TIMEOUT)
        except asyncio.TimeoutError:
            pass


def get_device_record(device, config):
    """Return the USB/IP fixed-size device record and interface records."""
    if len(device) < 18 or device[1] != 1:
        raise ValueError("guest returned an invalid USB device descriptor")
    if len(config) < 9 or config[1] != 2:
        raise ValueError("guest returned an invalid USB configuration descriptor")

    interfaces_by_number = {}
    endpoint_sizes = {}
    offset = 0
    while offset + 2 <= len(config):
        size, dtype = config[offset], config[offset + 1]
        if size < 2 or offset + size > len(config):
            raise ValueError("malformed USB configuration descriptor")
        if dtype == 4 and size >= 9:
            number = config[offset + 2]
            alternate = config[offset + 3]
            interface = config[offset + 5:offset + 8]
            if number not in interfaces_by_number or alternate == 0:
                interfaces_by_number[number] = interface
        elif dtype == 5 and size >= 7:
            address = config[offset + 2]
            endpoint_sizes[address] = int.from_bytes(config[offset + 4:offset + 6], "little") & 0x7ff
        offset += size

    interfaces = [interfaces_by_number[n] for n in sorted(interfaces_by_number)]
    if len(interfaces) != config[4]:
        raise ValueError(
            f"USB configuration declares {config[4]} interfaces, "
            f"but has {len(interfaces)} unique interface numbers")

    record = struct.pack(
        "!256s32sIIIHHHBBBBBB",
        DEVICE_PATH, BUSID, 1, 1, USB_SPEED_HIGH,
        int.from_bytes(device[8:10], "little"),
        int.from_bytes(device[10:12], "little"),
        int.from_bytes(device[12:14], "little"),
        device[4], device[5], device[6], config[5], device[17], config[4],
    )
    if len(record) != 312:
        raise AssertionError(f"USB/IP device record is {len(record)} bytes")
    return record, interfaces, endpoint_sizes


class USBIPBridge:
    def __init__(self, usb):
        self.usb = usb
        self.device_record = None
        self.interfaces = []
        self.endpoint_sizes = {}
        # 0x12ac is RestoreOS: it uses the Apple VirtIO USB PCI controller, which
        # transfers a whole bulk URB at once.  DFU/recovery use the MMIO
        # controller, whose transfer size is capped, so keep splitting there.
        self.pid = None
        self.pci_stage = False
        self.write_lock = asyncio.Lock()
        # URBs on one endpoint complete in submission order.  Keep one URB
        # whole on the wire; the device mux rejects a mux packet split across
        # several USB transfers.
        self.urb_locks = collections.defaultdict(asyncio.Lock)
        self.pending = {}
        self.clients = set()
        self.stage_id = 0
        self.discover_attempt = 0
        self.attempt_id = None
        self.last_devlist_state = object()

    def interface_records(self):
        return b"".join(bytes((i[0], i[1], i[2], 0)) for i in self.interfaces)

    async def discover(self, reset_timeout=CTRL_TIMEOUT):
        """Read the descriptors needed by OP_REP_DEVLIST and OP_REP_IMPORT."""
        self.discover_attempt += 1
        attempt_id = f"s{self.stage_id}-a{self.discover_attempt}"
        self.attempt_id = attempt_id
        started = time.monotonic_ns()
        usb_trace("usb.discover.begin", stage_id=self.stage_id, attempt_id=attempt_id)
        self.guest_config = None   # a reset forgets the guest's configuration (#36)
        setup = lambda value, length: struct.pack("<BBHHH", 0x80, 6, value, 0, length)
        try:
            await self.usb.reset(reset_timeout, attempt_id=attempt_id)
            device = await self.usb.control(
                setup(0x0100, 18), trace_attempt=attempt_id, descriptor="device"
            )
            device = device[:18]
            config_head = await self.usb.control(
                setup(0x0200, 9), trace_attempt=attempt_id, descriptor="config_header"
            )
            if len(config_head) < 9:
                raise ValueError("short USB configuration descriptor")
            total = int.from_bytes(config_head[2:4], "little")
            if not 9 <= total <= 4096:
                raise ValueError(f"invalid USB configuration length {total}")
            config = await self.usb.control(
                setup(0x0200, total), trace_attempt=attempt_id, descriptor="config_full"
            )
            if len(config) < total:
                raise ValueError(f"short USB configuration: got {len(config)}, expected {total}")
            self.device_record, self.interfaces, self.endpoint_sizes = get_device_record(
                device, config[:total]
            )
            vendor_id = int.from_bytes(device[8:10], "little")
            self.pid = int.from_bytes(device[10:12], "little")
            # Both the RestoreOS (12ac) and the SSH ramdisk (12a8) use
            # AppleUSBDeviceMux with 32 KiB buffers: one whole mux packet per
            # USB transfer.  Only the DFU/recovery MMIO controller needs splitting.
            self.pci_stage = self.pid in (0x12ac, 0x12a8)
            log("USB device discovered: %04x:%04x, %d interface(s)" % (
                vendor_id, self.pid, len(self.interfaces)
            ))
            if DEBUG:
                interfaces = ", ".join("%02x/%02x/%02x" % tuple(i)
                                        for i in self.interfaces)
                endpoints = ", ".join("%02x:%d" % item
                                       for item in sorted(self.endpoint_sizes.items()))
                log(f"USB interfaces: {interfaces}; endpoints: {endpoints}")
                log(f"USB configuration descriptor: {config[:total].hex()}")
            usb_trace(
                "usb.discover.complete",
                stage_id=self.stage_id,
                attempt_id=attempt_id,
                vendor_id=f"{vendor_id:04x}",
                product_id=f"{self.pid:04x}",
                interface_count=len(self.interfaces),
                elapsed_ns=time.monotonic_ns() - started,
            )
        except Exception as error:
            usb_trace(
                "usb.discover.failed",
                stage_id=self.stage_id,
                attempt_id=attempt_id,
                error_type=type(error).__name__,
                elapsed_ns=time.monotonic_ns() - started,
            )
            raise

    async def write(self, writer, data):
        async with self.write_lock:
            writer.write(data)
            await writer.drain()

    async def send_op_header(self, writer, code, status=0):
        await self.write(writer, struct.pack("!HHI", USBIP_VERSION, code, status))

    async def handle_devlist(self, writer):
        state = (0, None) if self.device_record is None else (1, self.pid)
        if state != self.last_devlist_state:
            self.last_devlist_state = state
            usb_trace(
                "usbip.devlist_state",
                stage_id=self.stage_id,
                attempt_id=self.attempt_id,
                device_count=state[0],
                product_id=f"{state[1]:04x}" if state[1] is not None else None,
            )
        await self.send_op_header(writer, OP_REP_DEVLIST)
        if self.device_record is None:  # between boot stages: nothing to attach yet
            await self.write(writer, struct.pack("!I", 0))
            return
        await self.write(writer, struct.pack("!I", 1) + self.device_record)
        if self.interfaces:
            await self.write(writer, self.interface_records())

    async def handle_import(self, reader, writer):
        busid = (await reader.readexactly(32)).split(b"\0", 1)[0]
        # One client at a time: a second import would share the device's endpoints.
        reason = (
            "wrong_busid" if busid != BUSID else
            "device_unavailable" if self.device_record is None else
            "client_busy" if self.clients else None
        )
        if reason:
            await self.send_op_header(writer, OP_REP_IMPORT, 1)
            usb_trace(
                "usbip.import_result",
                stage_id=self.stage_id,
                attempt_id=self.attempt_id,
                result="refused",
                reason=reason,
            )
            return False
        await self.send_op_header(writer, OP_REP_IMPORT)
        await self.write(writer, self.device_record)
        usb_trace(
            "usbip.import_result",
            stage_id=self.stage_id,
            attempt_id=self.attempt_id,
            result="accepted",
            product_id=f"{self.pid:04x}" if self.pid is not None else None,
        )
        return True

    async def handle_connection(self, reader, writer):
        tasks = set()
        imported = False
        try:
            header = await reader.readexactly(8)
            version, code, status = struct.unpack("!HHI", header)
            if version != USBIP_VERSION or status:
                raise ValueError(f"bad USB/IP operation header: {version:#x}/{status}")
            if code == OP_REQ_DEVLIST:
                await self.handle_devlist(writer)
                return
            if code == OP_REQ_IMPORT:
                if not await self.handle_import(reader, writer):
                    return
                self.clients.add(writer)
                imported = True
            else:
                raise ValueError(f"unsupported USB/IP operation {code:#x}")

            while True:
                command = struct.unpack("!I", await reader.readexactly(4))[0]
                if command == CMD_SUBMIT:
                    rest = await reader.readexactly(44)
                    fields = struct.unpack("!IIIIIIiiii8s", struct.pack("!I", command) + rest)
                    _, seqnum, _, direction, _, _, length, _, _, _, _ = fields
                    if length < 0 or length > 16 * 1024 * 1024:
                        raise ValueError(f"invalid USB/IP transfer length {length}")
                    payload = await reader.readexactly(length) if direction == 0 else b""
                    task = asyncio.create_task(self.handle_submit(fields, payload, writer))
                    self.pending[seqnum] = (task, fields[4], direction)
                    tasks.add(task)
                    task.add_done_callback(lambda done, seq=seqnum:
                                           self._submit_done(done, seq, tasks))
                elif command == CMD_UNLINK:
                    rest = await reader.readexactly(44)
                    await self.handle_unlink(rest, writer)
                else:
                    raise ValueError(f"unsupported USB/IP command {command}")
        except (asyncio.IncompleteReadError, ConnectionError):
            pass
        except Exception as e:
            log(f"USB/IP client error: {e}")
        finally:
            if imported:
                usb_trace(
                    "usbip.disconnect",
                    stage_id=self.stage_id,
                    attempt_id=self.attempt_id,
                    client_count=max(0, len(self.clients) - 1),
                )
            self.clients.discard(writer)
            for task in tasks:
                task.cancel()
            if tasks:
                await asyncio.gather(*tasks, return_exceptions=True)
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionError, OSError):
                pass

    async def handle_submit(self, fields, payload, writer):
        # URBs on one endpoint are queued and completed in order.  Keep a whole
        # URB (one mux packet) together on the wire.
        direction = fields[3]
        ep = fields[4]
        address = ep | (0x80 if direction else 0)
        async with self.urb_locks[address]:
            await self._handle_submit(fields, payload, writer)

    async def _handle_submit(self, fields, payload, writer):
        (_, seqnum, devid, direction, ep, _flags, length, start_frame,
         packets, _interval, setup) = fields
        status, data, actual = 0, b"", 0
        if DEBUG:
            log(f"URB {seqnum}: ep {ep} dir {'in' if direction else 'out'} len {length}"
                + (f" setup {setup.hex()}" if ep == 0 else ""))
            if ep == 1 and direction == 0 and payload:
                log(f"URB {seqnum}: bulk OUT prefix {payload[:16].hex()}")
        try:
            if ep == 0 and setup == ENUMERATION_START:
                # USB/IP carries no port reset: vhci resets the port locally, then Linux re-enumerates
                # starting with this 64-byte device descriptor read. Pass the reset on first, as
                # DFU's manifestation (the boot ROM starting the uploaded image) waits for it.
                await self.usb.reset()
                self.guest_config = None
            if ep == 0:
                if direction != (1 if setup[0] & 0x80 else 0):
                    raise OSError(errno.EINVAL, "URB direction disagrees with SETUP packet")
                if setup[:2] == b"\x00\x09" and setup[2] in (0, self.guest_config):
                    # SET_CONFIGURATION to 0, or to the configuration the guest already has:
                    # opening the device cycles 0 -> 1, and recovery-mode iBoot panics on that
                    # cycle. The guest keeps its configuration, so answer it here.
                    data = b""
                else:
                    data = await self.usb.control(setup, payload if direction == 0 else b"")
                    if setup[:2] == b"\x00\x09":
                        self.guest_config = setup[2]
                data = data[:length] if direction == 1 else b""
                actual = len(data) if direction == 1 else len(payload)
            elif direction == 1:
                # One USB/IP URB is one USB transfer, so ask the guest for exactly
                # one transfer.  Looping here merged several mux packets into one
                # URB, which usbmuxd discards as a size mismatch.
                data = await self.usb.transfer(ep, True, max_length=length)
                actual = len(data)
                if DEBUG and ep == 1 and data:
                    self._log_mux(seqnum, "in", data)
            else:
                if length == 0:
                    # A zero-length transfer is the ZLP used as the USB transfer
                    # delimiter for a preceding URB whose length is a multiple of
                    # wMaxPacketSize.  It must reach the device: without it the
                    # controller coalesces consecutive 32 KiB mux packets into a
                    # 65536-byte read, which the device mux rejects as too large.
                    await self.usb.transfer(ep, False)
                elif self.pci_stage:
                    # RestoreOS: the device mux (AppleUSBDeviceMux) requires one
                    # complete mux packet per USB transfer and drops short ones.
                    # The host usbmuxd is built with a 32 KiB MTU to match the
                    # device's 32 KiB mux buffers, so pass each URB whole.
                    await self.usb.transfer(ep, False, payload)
                else:
                    # DFU/recovery MMIO controller: its receive buffer is small.
                    packet_size = self.endpoint_sizes.get(ep, 512)
                    for offset in range(0, length, packet_size):
                        await self.usb.transfer(ep, False, payload[offset:offset + packet_size])
                actual = length
                if DEBUG and ep == 1 and payload:
                    self._log_mux(seqnum, "out", payload)
        except asyncio.TimeoutError:
            if DEBUG:
                log(f"USB/IP URB {seqnum} timed out after {URB_TIMEOUT:g}s")
            status = -errno.ETIMEDOUT
        except OSError as e:
            status = -(e.errno or errno.EIO)
        except Stall:
            status = -errno.EPIPE
        except asyncio.CancelledError:
            # A successful RET_UNLINK completes the canceled URB by itself.
            return
        except Exception as e:
            log(f"USB/IP URB {seqnum} failed: {e}")
            status = -errno.EIO
        await self._send_submit_reply(writer, seqnum, devid, direction, ep,
                                      status, data, actual if status == 0 else 0,
                                      start_frame, packets)

    @staticmethod
    def _log_mux(seqnum, tag, data):
        """Log the 16-byte usbmux header so sequence gaps are visible."""
        if len(data) < 16:
            return
        proto = int.from_bytes(data[0:4], "big")
        plen = int.from_bytes(data[4:8], "big")
        magic = data[8:12].hex()
        tx = int.from_bytes(data[12:14], "big")
        rx = int.from_bytes(data[14:16], "big")
        if magic not in ("feedface", "faceface", "deadbeef"):
            return
        log(f"URB {seqnum}: mux {tag} proto {proto} len {plen} "
            f"tx {tx} rx {rx} (transfer {len(data)})")

    async def _send_submit_reply(self, writer, seqnum, devid, direction, ep,
                                 status, data, actual, start_frame, packets):
        # actual_length: bytes received for IN, bytes sent for OUT (libusb checks it).
        hdr = struct.pack("!IIIIIiiiii8s", RET_SUBMIT, seqnum, devid,
                          direction, ep, status, actual, start_frame,
                          packets, 0, b"\0" * 8)
        await self.write(writer, hdr + (data if direction == 1 else b""))

    async def handle_unlink(self, rest, writer):
        seqnum, _devid, _direction, _ep, target = struct.unpack("!IIIII24x", rest)
        pending = self.pending.get(target)
        task = pending[0] if pending else None
        active = task is not None and not task.done()
        if active:
            task.cancel()
        status = -errno.ECONNRESET if active else 0
        await self.write(writer, struct.pack("!IIIIIi24x", RET_UNLINK, seqnum,
                                            0, 0, 0, status))
        if active:
            _, target_ep, target_direction = pending
            await self.usb.abort(target_ep, target_direction == 1)

    async def follow_stages(self):
        """Each guest boot stage presents a new device: on every driver reset, end the USB/IP
        sessions (the client sees an unplug) and enumerate the new device. A root helper such
        as tools/usbip-autoattach.sh then attaches it again."""
        while True:
            await self.usb.detached.wait()
            self.usb.detached.clear()
            self.stage_id += 1
            self.device_record = None
            for writer in list(self.clients):
                writer.close()
            while True:
                await asyncio.sleep(REDISCOVER_DELAY)
                self.usb.detached.clear()
                try:
                    # QEMU holds the reset until the new stage's driver posts its first receive
                    # buffer, so wait for that one rather than queueing more behind it.
                    await self.discover(reset_timeout=STAGE_TIMEOUT)
                except (OSError, asyncio.TimeoutError, ValueError, Stall) as e:
                    log(f"waiting for the next stage's device ({e or type(e).__name__})")
                    self.device_record = None
                    continue
                if self.usb.detached.is_set():  # the guest moved on again mid-discovery
                    self.device_record = None
                    continue
                break

    def _submit_done(self, task, seqnum, tasks):
        tasks.discard(task)
        pending = self.pending.get(seqnum)
        if pending and pending[0] is task:
            self.pending.pop(seqnum, None)


async def main_async(args):
    reader, writer = await asyncio.open_unix_connection(args.chardev)
    usb = VUSB(reader, writer)
    pump = asyncio.create_task(usb.run())
    try:
        bridge = USBIPBridge(usb)

        def ensure_transport():
            if pump.done():
                log(f"USB chardev stopped during initial discovery: {pump.exception() or 'connection closed'}")
                pump.result()
                raise ConnectionError("USB chardev closed during initial discovery")

        # OpenAVB's DFU answers the control reset late (SEP bootstrap first):
        # let later resets use the remaining startup budget, including descriptor reads.
        loop = asyncio.get_running_loop()
        deadline = loop.time() + STAGE_TIMEOUT
        for attempt in range(60):
            ensure_transport()
            remaining = deadline - loop.time()
            if remaining <= 0:
                raise asyncio.TimeoutError("USB device never became ready during initial discovery")
            usb.detached.clear()
            try:
                await asyncio.wait_for(bridge.discover(
                    reset_timeout=min(remaining, STAGE_TIMEOUT if attempt else CTRL_TIMEOUT)
                ), remaining)
                if usb.detached.is_set():
                    raise OSError(errno.ENODEV, "guest driver reset during discovery")
                ensure_transport()
                break
            except (asyncio.TimeoutError, OSError) as error:
                if not isinstance(error, asyncio.TimeoutError) and error.errno != errno.ENODEV:
                    raise
                ensure_transport()
                bridge.device_record = None
                bridge.interfaces = []
                bridge.endpoint_sizes = {}
                bridge.pid = None
                bridge.pci_stage = False
                reason = "guest driver reset" if error.errno == errno.ENODEV else "device not ready"
                log(f"USB {reason} during initial discovery (attempt {attempt + 1}); retrying")
                await asyncio.sleep(min(1, max(0, deadline - loop.time())))
        else:
            raise asyncio.TimeoutError("USB device never became ready during initial discovery")
        follower = asyncio.create_task(bridge.follow_stages())
        server = await asyncio.start_server(bridge.handle_connection,
                                            args.host, args.port)
        log(f"USB/IP listening on {args.host}:{args.port} (busid {BUSID.decode()})")
        async with server:
            await server.serve_forever()
    finally:
        pump.cancel()
        writer.close()
        await writer.wait_closed()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("chardev", help="QEMU vusb Unix socket")
    parser.add_argument("--host", default="127.0.0.1", help="listen address (default: localhost)")
    parser.add_argument("--port", type=int, default=3240)
    args = parser.parse_args()
    try:
        asyncio.run(main_async(args))
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
