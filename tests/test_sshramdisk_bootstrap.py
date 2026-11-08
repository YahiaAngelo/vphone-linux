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
import re
import shutil
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
                "VPHONE_SSHRD_BOOTSTRAP_BUILD": "1",
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


class BootstrapSelectionTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.environment = dict(os.environ)
        for key in (
            "VPHONE_ECID",
            "VPHONE_SSHRD_BOOTSTRAP",
            "VPHONE_SSHRD_BOOTSTRAP_BUILD",
        ):
            self.environment.pop(key, None)
        self.environment.update(
            CC="missing-bootstrap-compiler", SDKROOT=str(self.root / "absent-sdk")
        )

    def test_default_cached_stage_keeps_stock_bootstrap_without_sdk(self):
        tree = self.root / "stage/usr/local/bin"
        tree.mkdir(parents=True)
        (tree / "dropbear").write_bytes(b"existing Dropbear")
        (tree / "restored_external").write_bytes(b"stock bootstrap")
        result = subprocess.run(
            [
                str(ROOT / "tools/ssh-ramdisk-stage.sh"),
                "--bootstrap-only",
                str(self.root / "stage"),
            ],
            env=self.environment,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((tree / "restored_external").read_bytes(), b"stock bootstrap")
        self.assertEqual(list(self.root.glob(".sshrd-stage.*")), [])

    def test_invalid_rebuild_mode_fails_before_cache_preparation(self):
        tools = self.root / "tools"
        (tools / "sshramdisk-bootstrap").mkdir(parents=True)
        script = tools / "ssh-ramdisk-rebuild-signed.sh"
        shutil.copy2(ROOT / "tools/ssh-ramdisk-rebuild-signed.sh", script)
        shutil.copy2(
            ROOT / "tools/sshramdisk-bootstrap/build.sh",
            tools / "sshramdisk-bootstrap/build.sh",
        )
        for requested, expected in (
            ({"VPHONE_SSHRD_BOOTSTRAP_BUILD": "invalid"}, "must be 0 or 1"),
            (
                {
                    "VPHONE_SSHRD_BOOTSTRAP_BUILD": "1",
                    "VPHONE_SSHRD_BOOTSTRAP": "/unused/prebuilt",
                },
                "not both",
            ),
        ):
            with self.subTest(requested=requested):
                result = subprocess.run(
                    ["bash", str(script), str(self.root / "library"), "unused-vm"],
                    env={**self.environment, **requested},
                    capture_output=True,
                    text=True,
                    check=False,
                )
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)
                self.assertFalse((self.root / "runs").exists())

    def run_setup(
        self,
        *,
        ecid="0x000000000000cafe",
        selector=None,
        prebuilt=False,
        build=None,
        skip_sanity=False,
    ):
        vm = self.root / "vm"
        vm.mkdir(exist_ok=True)
        if ecid is not None:
            (vm / "ecid").write_text(ecid + "\n")
        source = self.root / "source"
        for name in ("OpenAVB/OpenAVB.bin", "OpenSEP/OpenSEP.bin", "cli", "run"):
            path = source / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.touch()
        environment = {
            **self.environment,
            "VM": str(vm),
            "T": str(ROOT / "tools"),
            "VSETUP_SRC": str(source),
            "VC": str(source / "cli"),
            "QEMU_RUN": str(source / "run"),
            "ARG_LOG": str(self.root / "firmware-ecid"),
        }
        if selector is not None:
            environment["VPHONE_ECID"] = selector
        if prebuilt:
            binary = self.root / "prebuilt"
            binary.write_bytes(signed_fixture())
            environment["VPHONE_SSHRD_BOOTSTRAP"] = str(binary)
        if build is not None:
            environment["VPHONE_SSHRD_BOOTSTRAP_BUILD"] = build
        if skip_sanity:
            environment["SKIP_SANITY"] = "1"
        production = (ROOT / "setup/create-vm.sh").read_text()
        functions = []
        for name in ("check_sshrd_bootstrap", "do_sanity", "bind_vm_ecid"):
            match = re.search(
                rf"^{name}\(\) \{{\n.*?^\}}$", production, re.MULTILINE | re.DOTALL
            )
            if match:
                functions.append(match[0])
        stages = re.search(
            r"^step sanity   do_sanity\n.*?^step gpu-driver do_gpu_driver$",
            production,
            re.MULTILINE | re.DOTALL,
        )[0]
        script = (
            """set -euo pipefail
DRY=0
die() { printf '%s\\n' "$*" >&2; exit 1; }
warn() { printf '%s\\n' "$*" >&2; }
check_vm_disk_space() { :; }
step() { if [ "$1" = sanity ] && [ "${SKIP_SANITY:-0}" = 1 ]; then return 0; fi; shift; "$@"; }
do_bundle() { ECID=$(cat "$VM/ecid" 2>/dev/null || true); }
do_firmware() { printf '%s\\n' "${VPHONE_ECID-__UNSET__}" > "$ARG_LOG"; }
do_gpu_driver() { :; }
"""
            + "\n".join(functions)
            + "\n"
            + stages
        )
        return subprocess.run(
            ["bash", "-c", script],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
        )

    def test_default_setup_needs_no_sdk_or_ecid_selector(self):
        result = self.run_setup()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual((self.root / "firmware-ecid").read_text(), "__UNSET__\n")

    def test_valid_prebuilt_binds_equivalent_explicit_ecid(self):
        for selector in (None, "0xCAFE"):
            with self.subTest(selector=selector):
                result = self.run_setup(prebuilt=True, selector=selector)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    (self.root / "firmware-ecid").read_text(), "0x000000000000cafe\n"
                )

    def test_requested_source_build_fails_before_firmware_without_compiler(self):
        for skip_sanity in (False, True):
            with self.subTest(skip_sanity=skip_sanity):
                result = self.run_setup(build="1", skip_sanity=skip_sanity)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(
                    "missing bootstrap build tool: missing-bootstrap-compiler",
                    result.stderr,
                )
                self.assertFalse((self.root / "firmware-ecid").exists())

    def test_explicit_ecid_requires_an_ecid_aware_bootstrap(self):
        result = self.run_setup(selector="0xCAFE")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("VPHONE_ECID requires", result.stderr)
        self.assertFalse((self.root / "firmware-ecid").exists())

    def test_missing_bundle_ecid_fails_before_firmware(self):
        result = self.run_setup(ecid=None)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("missing ECID in VM bundle:", result.stderr)
        self.assertFalse((self.root / "firmware-ecid").exists())

    def test_zero_bundle_ecid_fails_before_firmware(self):
        result = self.run_setup(ecid="0x0000")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("zero ECID in VM bundle:", result.stderr)
        self.assertFalse((self.root / "firmware-ecid").exists())

    def test_conflicting_or_empty_explicit_ecid_is_not_replaced(self):
        for selector in ("0xdead", ""):
            with self.subTest(selector=selector):
                result = self.run_setup(prebuilt=True, selector=selector)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse((self.root / "firmware-ecid").exists())

    def test_conflicting_bootstrap_modes_fail_before_firmware(self):
        result = self.run_setup(prebuilt=True, build="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("not both", result.stderr)
        self.assertFalse((self.root / "firmware-ecid").exists())


if __name__ == "__main__":
    unittest.main()
