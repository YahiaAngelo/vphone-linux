#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Exercise the production scale helper and first-boot caller without a guest."""

import base64
import contextlib
import io
import json
import os
import re
import runpy
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "tools/guest-dt-scale.py"
SETUP_SOURCE = ROOT / "setup/create-vm.sh"


def der(tag, content):
    size = len(content)
    length = bytes([size]) if size < 128 else b"\x82" + size.to_bytes(2, "big")
    return bytes([tag]) + length + content


def tree_fixture(scale, display_scale=None):
    def node(name, properties=(), children=()):
        properties = [("name", name.encode() + b"\0"), *properties]
        data = struct.pack("<II", len(properties), len(children))
        for key, value in properties:
            data += key.encode().ljust(32, b"\0") + struct.pack("<I", len(value))
            data += value + bytes(-len(value) % 4)
        return data + b"".join(children)

    display = node(
        "display0", [("display-scale", struct.pack("<I", display_scale or scale))]
    )
    product = node(
        "product", [("artwork-scale-factor", struct.pack("<I", scale))], [display]
    )
    tree = node("/", children=[product])
    return der(
        0x30,
        der(0x16, b"IM4P") + der(0x16, b"dtre") + der(0x16, b"fixture") + der(4, tree),
    )


class Guest:
    def __init__(self, tree, running=2):
        self.tree = tree
        self.running = running
        self.calls = []
        self.writes = {}
        self.truncated = False
        self.corrupt_readback = False
        self.fail_remove = False

    def request(self, method, params):
        self.calls.append((method, params))
        if method == "files.list":
            name = "a" * 96 if params["path"] == "/private/preboot" else "other-file"
            return {"entries": [{"name": name, "type": "dir"}]}
        if method == "files.read":
            data = self.tree
            if self.corrupt_readback and self.writes:
                data = data[:-1] + bytes([data[-1] ^ 1])
            return {
                "content": base64.b64encode(data).decode(),
                "size": len(data),
                "truncated": self.truncated,
            }
        if method == "files.write":
            data = base64.b64decode(params["content"])
            self.writes[params["path"]] = data
            if params["path"].endswith("/devicetree.img4"):
                self.tree = data
            return {}
        if method == "files.remove":
            if self.fail_remove:
                raise ValueError("cache removal failed")
            return {}
        if method == "device.screen":
            return {"scale": self.running}
        raise AssertionError(method)

    def connection(self, *_args):
        guest = self

        class Connection:
            def setsockopt(self, *_args):
                pass

            def connect(self, *_args):
                pass

            def settimeout(self, *_args):
                pass

            def sendall(self, data):
                request = json.loads(data.partition(b"\r\n\r\n")[2])
                try:
                    reply = {
                        "result": guest.request(request["method"], request["params"])
                    }
                except ValueError as error:
                    reply = {"error": {"message": str(error)}}
                body = json.dumps(reply).encode()
                self.data = (
                    b"HTTP/1.1 200 OK\r\nContent-Length: %d\r\n\r\n" % len(body) + body
                )

            def recv(self, count):
                data, self.data = self.data[:count], self.data[count:]
                return data

        return Connection()


class GuestScaleTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.tool = self.root / "tools/guest-dt-scale.py"
        self.tool.parent.mkdir()
        shutil.copy2(SOURCE, self.tool)

    def run_helper(self, guest, *, machine=True):
        stdout, stderr = io.StringIO(), io.StringIO()
        argv = [str(self.tool), "46", "2", *(["--json"] if machine else [])]
        status = 0
        with contextlib.ExitStack() as stack:
            stack.enter_context(patch.object(sys, "argv", argv))
            stack.enter_context(patch.object(socket, "socket", guest.connection))
            for name in (
                "AF_VSOCK",
                "SO_VM_SOCKETS_BUFFER_MAX_SIZE",
                "SO_VM_SOCKETS_BUFFER_SIZE",
            ):
                stack.enter_context(patch.object(socket, name, 0, create=True))
            stack.enter_context(contextlib.redirect_stdout(stdout))
            stack.enter_context(contextlib.redirect_stderr(stderr))
            try:
                runpy.run_path(str(self.tool), run_name="__main__")
            except SystemExit as error:
                status = 0 if error.code is None else error.code
        return status, stdout.getvalue(), stderr.getvalue()

    def test_matching_tree_and_running_scale_preserve_everything(self):
        guest = Guest(tree_fixture(2))
        status, output, _ = self.run_helper(guest)
        self.assertEqual(status, 0)
        self.assertEqual(
            json.loads(output),
            {"changed": False, "scale": 2, "restart_required": False},
        )
        self.assertEqual(guest.writes, {})
        self.assertFalse(any(method == "files.remove" for method, _ in guest.calls))
        self.assertFalse((self.root / "runs").exists())

    def test_changed_tree_keeps_originals_invalidates_cache_and_requires_restart(self):
        original = tree_fixture(2, display_scale=3)
        guest = Guest(original)
        status, output, _ = self.run_helper(guest)
        self.assertEqual(status, 0)
        self.assertEqual(
            json.loads(output), {"changed": True, "scale": 2, "restart_required": True}
        )
        self.assertEqual(guest.tree, tree_fixture(2))
        backup = next(self.root.glob("runs/guest-dt-scale/*.img4"))
        self.assertEqual(backup.read_bytes(), original)
        self.assertEqual(
            next(
                data
                for name, data in guest.writes.items()
                if name.endswith(".before-scale")
            ),
            original,
        )
        self.assertEqual(sum(method == "files.remove" for method, _ in guest.calls), 1)

    def test_stale_running_scale_invalidates_cache_without_tree_write(self):
        guest = Guest(tree_fixture(2), running=3)
        status, output, _ = self.run_helper(guest)
        self.assertEqual(status, 0)
        self.assertEqual(
            json.loads(output), {"changed": False, "scale": 2, "restart_required": True}
        )
        self.assertEqual(guest.writes, {})
        self.assertEqual(sum(method == "files.remove" for method, _ in guest.calls), 1)
        self.assertFalse((self.root / "runs").exists())

    def test_malformed_running_proof_is_fatal_without_mutation(self):
        for value in (None, True, "2", 0, float("nan")):
            with self.subTest(value=value):
                guest = Guest(tree_fixture(2), running=value)
                status, output, _ = self.run_helper(guest)
                self.assertNotEqual(status, 0)
                self.assertNotIn("restart_required", output)
                self.assertEqual(guest.writes, {})
                self.assertFalse(
                    any(method == "files.remove" for method, _ in guest.calls)
                )

    def test_truncated_tree_is_not_accepted_as_unchanged(self):
        guest = Guest(tree_fixture(2))
        guest.truncated = True
        status, _, _ = self.run_helper(guest)
        self.assertNotEqual(status, 0)
        self.assertEqual(guest.writes, {})

    def test_failed_readback_or_cache_invalidation_is_fatal(self):
        for failure in ("corrupt_readback", "fail_remove"):
            with self.subTest(failure=failure):
                guest = Guest(tree_fixture(3))
                setattr(guest, failure, True)
                status, output, _ = self.run_helper(guest)
                self.assertNotEqual(status, 0)
                self.assertNotIn("restart_required", output)

    def test_legacy_positional_success_stays_human_readable(self):
        guest = Guest(tree_fixture(2))
        status, output, _ = self.run_helper(guest, machine=False)
        self.assertEqual(status, 0)
        self.assertIn("already requests 2x", output)
        self.assertEqual(guest.writes, {})


class FirstBootScaleTests(unittest.TestCase):
    def run_first_boot(self, result, status=0):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "auto-lock-never.py").touch()
            (root / "guest-dt-scale.py").write_text(
                "import os, sys\nprint(os.environ['SCALE_RESULT'])\nsys.exit(int(os.environ['SCALE_STATUS']))\n"
            )
            source = SETUP_SOURCE.read_text()
            function = re.search(
                r"^do_first_boot\(\) \{\n.*?^\}$", source, re.MULTILINE | re.DOTALL
            )[0]
            script = (
                """set -euo pipefail
DRY=0 SCALE=2 TRIM=0 CID=46 VM=/unused QEMU_RUN=/unused
VPHONE_MIGRATION_TIMEOUT=10
log() { :; }
warn() { :; }
die() { printf '%s\\n' "$*" >&2; exit 1; }
boot_vm() { printf 'boot\\n' >> "$EVENTS"; }
unlock_vm() { :; }
qemu_alive() { return 0; }
wait_vm_exit() { :; }
vrpc() {
  case "$1" in
    *setup.status*) printf '{"data_migration_done":true}\\n' ;;
    *system.shutdown*) printf 'shutdown\\n' >> "$EVENTS" ;;
    *) printf '{}\\n' ;;
  esac
}
"""
                + function
                + "\ndo_first_boot\n"
            )
            completed = subprocess.run(
                ["bash", "-c", script],
                env={
                    **os.environ,
                    "T": str(root),
                    "EVENTS": str(root / "events"),
                    "SCALE_RESULT": result,
                    "SCALE_STATUS": str(status),
                },
                capture_output=True,
                text=True,
                check=False,
                timeout=10,
            )
            return completed, (root / "events").read_text().splitlines()

    def test_only_verified_noop_skips_restart(self):
        for changed, restart in ((False, False), (True, True), (False, True)):
            with self.subTest(changed=changed, restart=restart):
                result = json.dumps(
                    {"changed": changed, "scale": 2, "restart_required": restart}
                )
                completed, events = self.run_first_boot(result)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(
                    events, ["boot", "shutdown", "boot"] if restart else ["boot"]
                )

    def test_bad_result_or_helper_failure_does_not_shutdown(self):
        for result, status in (
            ("not JSON", 0),
            ('{"changed":false}', 0),
            ('{"changed":true,"scale":2,"restart_required":false}', 0),
            ('{"changed":false,"scale":2,"restart_required":false}', 1),
        ):
            with self.subTest(result=result, status=status):
                completed, events = self.run_first_boot(result, status)
                self.assertNotEqual(completed.returncode, 0)
                self.assertEqual(events, ["boot"])


if __name__ == "__main__":
    if len(sys.argv) > 1:
        SOURCE = Path(sys.argv.pop(1)).resolve(strict=True)
    if len(sys.argv) > 1:
        SETUP_SOURCE = Path(sys.argv.pop(1)).resolve(strict=True)
    unittest.main()
