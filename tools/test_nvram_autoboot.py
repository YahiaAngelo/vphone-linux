#!/usr/bin/env python3
"""Exercise the recovery boot precondition with checksum-valid NVRAM banks."""

import importlib.util
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


ROOT = Path(__file__).resolve().parents[1]
HELPER = ROOT / "tools/nvram-autoboot.py"
SPEC = importlib.util.spec_from_file_location("nvram_autoboot", HELPER)
NVRAM = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NVRAM)


def bank(entries=None):
    data = bytearray(0x2000)
    data[0] = NVRAM.SIGNATURE
    struct.pack_into(">H", data, 2, len(data) // 16)
    data[4:9] = b"nvram"
    data[1] = NVRAM.chrp_checksum(data[:16])
    if entries is not None:
        data[0x20] = 0x70
        struct.pack_into(">H", data, 0x22, (len(data) - 0x20) // 16)
        data[0x24:0x2a] = b"common"
        data[0x21] = NVRAM.chrp_checksum(data[0x20:0x30])
        values = b"\0".join(entries) + b"\0\0"
        data[0x30:0x30 + len(values)] = values
    struct.pack_into("<I", data, 16, zlib.adler32(data[0x14:]) & 0xFFFFFFFF)
    return bytes(data)


class RecoveryNVRAMTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.vm = Path(self.temporary.name)
        self.path = self.vm / "nvram.bin"

    def prepare(self):
        return subprocess.run(
            [sys.executable, str(HELPER), str(self.path), "--auto-boot", "false", "--require-auto-boot"],
            capture_output=True, text=True, check=False,
        )

    def test_missing_variable_is_inserted_and_banks_remain_valid(self):
        self.path.write_bytes(bank([b"other=value"]) + bank([b"auto-boot=true", b"boot-args=rd=md0"]))
        self.assertEqual(self.prepare().returncode, 0)
        written = self.path.read_bytes()
        banks = list(NVRAM.find_banks(written))
        self.assertEqual(len(banks), 2)
        for base, length in banks:
            start, end = NVRAM.common_data(written, base, length)
            entries = written[start:end].split(b"\0\0", 1)[0].split(b"\0")
            self.assertIn(b"auto-boot=false", entries)
            self.assertFalse(any(entry.startswith(b"boot-args=") for entry in entries))
        before = self.path.read_bytes()
        self.assertEqual(self.prepare().returncode, 0)
        self.assertEqual(self.path.read_bytes(), before)

    def test_missing_common_partition_refuses_without_writing_any_bank(self):
        for content in [bank(), bank([b"auto-boot=true"]) + bank()]:
            with self.subTest(banks=len(content) // 0x2000):
                self.path.write_bytes(content)
                result = self.prepare()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("no 'common' partition", result.stderr)
                self.assertEqual(self.path.read_bytes(), content)

    def test_launcher_requires_actual_false_setting_before_pending_dfu_boot(self):
        for name in ["Disk.img", "AVPBooter.vresearch1.bin", "AVPSEPBooter.vresearch1.bin", ".vphone-dsc-pending.json"]:
            (self.vm / name).touch()
        (self.vm / "ecid").write_text("0x1234\n")
        (self.vm / "config.plist").write_text('<plist version="1.0"><dict/></plist>')
        marker = self.vm / "qemu-ran"
        qemu = self.vm / "qemu"
        qemu.write_text('#!/bin/sh\n: > "$QEMU_MARKER"\n')
        qemu.chmod(0o700)
        environment = dict(os.environ, QEMU=str(qemu), QEMU_MARKER=str(marker), GFX="0", CID="0")
        for content, accepted in [(bank(), False), (bank([b"other=value"]), True)]:
            self.path.write_bytes(content)
            result = subprocess.run(
                ["bash", str(ROOT / "run-vphone.sh"), "--dfu", str(self.vm)],
                env=environment, capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode == 0, accepted, result.stderr)
            self.assertEqual(marker.exists(), accepted)
            self.assertTrue((self.vm / ".vphone-dsc-pending.json").exists())


if __name__ == "__main__":
    unittest.main()
