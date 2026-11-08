#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Exercise the prebuilt artifact's architecture and code-signing contract."""

import hashlib
import importlib.util
import os
import plistlib
import struct
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "bootstrap_check", ROOT / "tools/sshramdisk-bootstrap/check.py"
)
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def signed_fixture(*, flags=2, cpu=0x100000C, entitlements=None, der_values=None):
    """An independently signed Mach-O envelope, with a single executable page."""
    values = (
        {name: True for name in CHECK.ENTITLEMENTS}
        if entitlements is None
        else entitlements
    )
    xml = plistlib.dumps(values)
    entitlement_blob = struct.pack(">II", 0xFADE7171, len(xml) + 8) + xml

    def der(tag, value):
        length = (
            bytes([len(value)]) if len(value) < 128 else b"\x81" + bytes([len(value)])
        )
        return bytes([tag]) + length + value

    dictionary = b"".join(
        der(0x30, der(0x0C, key.encode()) + der(1, b"\xff" if value else b"\0"))
        for key, value in sorted((values if der_values is None else der_values).items())
    )
    encoded = der(0x70, der(2, b"\x01") + der(0xB0, dictionary))
    der_blob = struct.pack(">II", 0xFADE7172, len(encoded) + 8) + encoded
    requirements = struct.pack(">III", 0xFADE0C01, 12, 0)
    identifier = CHECK.IDENTIFIER + b"\0"
    hash_offset = 44 + len(identifier) + 7 * 32
    directory_size = hash_offset + 32
    signature_size = (
        44 + directory_size + len(requirements) + len(entitlement_blob) + len(der_blob)
    )
    commands = struct.pack("<6I", 0x32, 24, 2, 16 << 16, 16 << 16, 0)
    commands += struct.pack("<4I", 0x1D, 16, 4096, signature_size)
    header = struct.pack("<8I", 0xFEEDFACF, cpu, 0, 2, 2, len(commands), 0, 0)
    page = (header + commands).ljust(4096, b"\0")
    directory = struct.pack(
        ">9I4B I",
        0xFADE0C02,
        directory_size,
        0x20001,
        flags,
        hash_offset,
        44,
        7,
        1,
        4096,
        32,
        2,
        0,
        12,
        0,
    )
    directory += identifier + hashlib.sha256(der_blob).digest() + bytes(32)
    directory += hashlib.sha256(entitlement_blob).digest() + bytes(2 * 32)
    directory += hashlib.sha256(requirements).digest() + bytes(32)
    directory += hashlib.sha256(page).digest()
    start = 44 + directory_size
    signature = struct.pack(
        ">3I8I",
        0xFADE0CC0,
        signature_size,
        4,
        0,
        44,
        2,
        start,
        5,
        start + len(requirements),
        7,
        start + len(requirements) + len(entitlement_blob),
    )
    return bytearray(
        page + signature + directory + requirements + entitlement_blob + der_blob
    )


class BootstrapArtifactTests(unittest.TestCase):
    def check(self, data):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder) / "bootstrap"
            path.write_bytes(data)
            return CHECK.check(path)

    def test_signed_arm64_ios(self):
        data = signed_fixture()
        self.assertEqual(self.check(data), hashlib.sha256(data).hexdigest())

    def test_executable_mutation_is_rejected(self):
        data = signed_fixture()
        data[1024] ^= 1
        with self.assertRaisesRegex(ValueError, "page hash mismatch"):
            self.check(data)

    def test_entitlement_mutation_is_rejected(self):
        data = signed_fixture()
        # Preserve valid XML and all required keys while changing the signed bytes.
        xml_end = data.find(b"</plist>\n") + len(b"</plist>")
        data[xml_end] = ord(" ")
        with self.assertRaisesRegex(ValueError, "special-slot 5 signature mismatch"):
            self.check(data)

    def test_der_entitlements_must_agree_with_xml(self):
        values = {name: True for name in CHECK.ENTITLEMENTS}
        values["com.apple.private.usbdevice.setdescription"] = False
        with self.assertRaisesRegex(ValueError, "DER and XML entitlements disagree"):
            self.check(signed_fixture(der_values=values))

    def test_der_and_requirement_blob_corruption_is_rejected(self):
        for slot in (2, 7):
            data = signed_fixture()
            for index in range(4):
                current, offset = struct.unpack_from(">II", data, 4096 + 12 + index * 8)
                if current == slot:
                    data[4096 + offset + 8] ^= 1
                    break
            with self.subTest(slot=slot), self.assertRaises(ValueError):
                self.check(data)

    def test_wrong_architecture_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "thin arm64"):
            self.check(signed_fixture(cpu=0x1000007))

    def test_non_adhoc_artifact_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "ad-hoc CodeDirectory"):
            self.check(signed_fixture(flags=0))

    def test_missing_usb_entitlement_is_rejected(self):
        entitlements = {
            name: True
            for name in CHECK.ENTITLEMENTS
            if name != "com.apple.private.usbdevice.setdescription"
        }
        with self.assertRaisesRegex(ValueError, "missing bootstrap"):
            self.check(signed_fixture(entitlements=entitlements))

    def test_unsigned_and_truncated_artifacts_are_rejected(self):
        data = signed_fixture()
        for length in (0, 16, 70, 4096, len(data) - 1):
            with self.subTest(length=length), self.assertRaises(ValueError):
                self.check(data[:length])

    def test_malformed_code_directory_bounds_are_rejected(self):
        data = signed_fixture()
        struct.pack_into(">I", data, 4096 + 44 + 16, 1)
        with self.assertRaisesRegex(ValueError, "hash bounds"):
            self.check(data)

    def test_atomic_prebuilt_upgrade(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            binary = root / "prebuilt"
            binary.write_bytes(signed_fixture())
            tree = root / "stage/usr/local/bin"
            tree.mkdir(parents=True)
            (tree / "dropbear").write_bytes(b"existing Dropbear")
            (tree / "restored_external").write_bytes(b"old generic bootstrap")
            environment = {**os.environ, "VPHONE_SSHRD_BOOTSTRAP": str(binary)}
            result = subprocess.run(
                [
                    str(ROOT / "tools/ssh-ramdisk-stage.sh"),
                    "--bootstrap-only",
                    str(root / "stage"),
                ],
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                (tree / "restored_external").read_bytes(), binary.read_bytes()
            )
            self.assertEqual((tree / "dropbear").read_bytes(), b"existing Dropbear")
            self.assertEqual((tree / "restored_external").stat().st_mode & 0o777, 0o755)

    def test_invalid_prebuilt_preserves_existing_tree(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            binary = root / "prebuilt"
            data = signed_fixture()
            data[1024] ^= 1
            binary.write_bytes(data)
            tree = root / "stage/usr/local/bin"
            tree.mkdir(parents=True)
            (tree / "dropbear").touch()
            (tree / "restored_external").write_bytes(b"previous bootstrap")
            environment = {**os.environ, "VPHONE_SSHRD_BOOTSTRAP": str(binary)}
            result = subprocess.run(
                [
                    str(ROOT / "tools/ssh-ramdisk-stage.sh"),
                    "--bootstrap-only",
                    str(root / "stage"),
                ],
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("page hash mismatch", result.stderr)
            self.assertEqual(
                (tree / "restored_external").read_bytes(), b"previous bootstrap"
            )
            self.assertEqual(list(root.glob(".sshrd-stage.*")), [])

    def test_source_build_failure_does_not_leave_partial_staging(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            environment = {
                **os.environ,
                "CC": "false",
                "LD64_LLD": "false",
                "RCODESIGN": "false",
                "SDKROOT": str(root),
            }
            environment.pop("VPHONE_SSHRD_BOOTSTRAP", None)
            result = subprocess.run(
                [str(ROOT / "tools/ssh-ramdisk-stage.sh"), str(root / "stage")],
                env=environment,
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((root / "stage").exists())
            self.assertEqual(list(root.glob(".sshrd-stage.*")), [])


if __name__ == "__main__":
    unittest.main()
