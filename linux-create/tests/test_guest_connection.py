#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Compile the installer's connection helper and exercise it without a guest."""

import base64
import ctypes
import ctypes.util
import json
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SOURCE = Path(__file__).resolve().parents[1] / "overlay/VPhoneCommand/Firmware/VPhoneCustomFirmwareInstallerLinux.swift"


class GuestConnectionTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="vphone-guest-connection-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.directory = Path(cls.temporary.name)
        # Compile the actual Foundation-only prefix, without the installer's
        # firmware modules. The diagnostic error has no runtime dependency.
        prefix = SOURCE.read_text().split("extension VPhoneCustomFirmwareInstaller {", 1)[0]
        imports = {"import ArgumentParser", "import FirmwarePatcher", "import VPhoneArchiveKit",
                   "import VPhoneCoreKit", "import VPhonePatchKit", "import VPhoneSign"}
        prefix = "\n".join(line for line in prefix.splitlines() if line not in imports)
        helper = cls.directory / "Connection.swift"
        helper.write_text(prefix + "\n#endif\n")
        main = cls.directory / "main.swift"
        main.write_text('''import Foundation
struct ValidationError: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}
let input = try JSONSerialization.jsonObject(with: FileHandle.standardInput.readDataToEndOfFile()) as! [String: Any]
do {
    let connection = try VPhoneLinuxGuestConnection(
        bundleConfiguration: Data(base64Encoded: input["config"] as! String)!,
        environment: input["environment"] as! [String: String])
    let result: [String: Any] = [
        "ecid": connection.ecid, "paths": [connection.system, connection.xart, connection.preboot],
        "environment": connection.environment(input["environment"] as! [String: String], askpass: input["askpass"] as! String),
        "arguments": VPhoneLinuxGuestConnection.mountArguments(
            hostPath: input["host"] as! String, guestPath: connection.system,
            connector: input["connector"] as! String, executable: input["executable"] as! String),
    ]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
} catch {
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: ["error": String(describing: error)]))
}
''')
        cls.binary = cls.directory / "connection"
        subprocess.run([os.environ.get("SWIFTC", shutil.which("swiftc") or "swiftc"),
                        str(helper), str(main), "-o", str(cls.binary)], check=True)

    def connection(self, identity=None, environment=None, **overrides):
        config = {"machineIdentifier": plistlib.dumps(identity if identity is not None else {"ECID": 0x1234}, fmt=plistlib.FMT_BINARY)}
        request = {
            "config": base64.b64encode(plistlib.dumps(config)).decode(),
            "environment": environment or {}, "askpass": "/private/work/ssh-askpass.sh",
            "host": "/private/work/system", "connector": "/repo/tools/usbmux-connect.py",
            "executable": "/usr/bin/sshfs",
        } | overrides
        result = subprocess.run([str(self.binary)], input=json.dumps(request), capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def test_bundle_identity_binds_child_environment_and_normalizes_matching_override(self):
        for override in (None, "1234", "0x0000000000001234", "0X1234"):
            with self.subTest(override=override):
                inherited = {"KEEP": "unchanged", "SSH_ASKPASS": "/tmp/foreign-helper"}
                if override is not None:
                    inherited["VPHONE_ECID"] = override
                result = self.connection(environment=inherited)
                self.assertEqual(result["ecid"], "0000000000001234")
                self.assertEqual(result["environment"]["VPHONE_ECID"], result["ecid"])
                self.assertEqual(result["environment"]["SSH_ASKPASS"], "/private/work/ssh-askpass.sh")
                self.assertEqual(result["environment"]["SSH_ASKPASS_REQUIRE"], "force")
                self.assertEqual(result["environment"]["KEEP"], "unchanged")

    def test_missing_or_invalid_identity_and_conflicting_override_fail_closed(self):
        for identity in ({}, {"ECID": 0}, {"ECID": -1}, {"ECID": True}, {"ECID": "1234"},
                         {"ECID": 12.0}, {"ECID": 12.5}, {"ECID": float(2**64 - 1)}):
            with self.subTest(identity=identity):
                self.assertIn("error", self.connection(identity))
        for override in ("", "1235", " 1234", "1234\n", "0x", "1" * 17, "$(id)"):
            with self.subTest(override=override):
                self.assertIn("error", self.connection(environment={"VPHONE_ECID": override}))
        self.assertEqual(self.connection({"ECID": 2**64 - 1})["ecid"], "FFFFFFFFFFFFFFFF")
        self.assertIn("error", self.connection(config=base64.b64encode(plistlib.dumps({})).decode()))

    def test_guest_paths_must_be_absolute_and_cannot_contain_nul(self):
        for key in ("VPHONE_GUEST_SYSTEM", "VPHONE_GUEST_XART", "VPHONE_GUEST_PREBOOT"):
            for value in ("", "relative", "/mnt\0suffix"):
                with self.subTest(key=key, value=value):
                    self.assertIn("error", self.connection(environment={key: value}))

    def test_shell_receives_quoted_paths_as_data_and_bound_target(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / "injected"
            path = f"/mnt' ; touch {marker}; printf '$(id) `id`\nnext"
            executable = root / "sshfs stub"
            capture = root / "captured.json"
            executable.write_text(f"#!{sys.executable}\n"
                                  "import json, os, pathlib, sys\n"
                                  "record = dict(args=sys.argv[1:], password=sys.stdin.read(), ecid=os.environ['VPHONE_ECID'], askpass=os.environ['SSH_ASKPASS'])\n"
                                  "pathlib.Path(os.environ['CAPTURE']).write_text(json.dumps(record))\n")
            executable.chmod(0o700)
            result = self.connection(environment={"VPHONE_GUEST_SYSTEM": path, "CAPTURE": str(capture)},
                                     host=str(root / "host's volume"), connector="/repo's path,%h/back\\slash/tools/connector.py", executable=str(executable))
            subprocess.run(["/bin/sh", *result["arguments"]], env=os.environ | result["environment"],
                           capture_output=True, check=True, timeout=5)
            record = json.loads(capture.read_text())
            self.assertEqual(record["args"][:3], ["-f", "root@vphone:" + path, str(root / "host's volume")])
            self.assertIn("ssh_command=/usr/bin/ssh", record["args"])
            self.assertIn("sftp_server=/usr/libexec/sftp-server", record["args"])
            self.assertEqual(record["password"], "alpine\n")
            self.assertEqual(record["ecid"], "0000000000001234")
            self.assertEqual(record["askpass"], "/private/work/ssh-askpass.sh")
            self.assertFalse(marker.exists())

    def test_real_fuse_and_openssh_keep_connector_path_literal(self):
        class Args(ctypes.Structure):
            _fields_ = [("argc", ctypes.c_int), ("argv", ctypes.POINTER(ctypes.c_char_p)), ("allocated", ctypes.c_int)]

        class Option(ctypes.Structure):
            _fields_ = [("template", ctypes.c_char_p), ("offset", ctypes.c_ulong), ("value", ctypes.c_int)]

        class Config(ctypes.Structure):
            _fields_ = [("proxy", ctypes.c_char_p)]

        fuse = ctypes.CDLL(ctypes.util.find_library("fuse3") or "libfuse3.so.3")
        fuse.fuse_opt_parse.argtypes = [ctypes.POINTER(Args), ctypes.c_void_p, ctypes.POINTER(Option), ctypes.c_void_p]
        fuse.fuse_opt_parse.restype = ctypes.c_int
        fuse.fuse_opt_free_args.argtypes = [ctypes.POINTER(Args)]
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory = root / 'space quote\'" back\\slash,%h tab\tline\n$(touch PWNED)'
            directory.mkdir()
            connector = directory / "connector.py"
            capture = root / "capture.json"
            connector.write_text("import json, os, pathlib, sys\n"
                                 "pathlib.Path(os.environ['CAPTURE']).write_text(json.dumps(dict(args=sys.argv[1:], ecid=os.environ['VPHONE_ECID'])))\n")
            result = self.connection(connector=str(connector))
            option = result["arguments"][-1].encode()
            values = (ctypes.c_char_p * 4)(b"sshfs", b"-o", option, None)
            arguments = Args(3, values, 0)
            config = Config()
            options = (Option * 2)(Option(b"ProxyCommand=%s", 0, 0), Option(None, 0, 0))
            try:
                self.assertEqual(fuse.fuse_opt_parse(ctypes.byref(arguments), ctypes.byref(config), options, None), 0)
                # SSHFS 3.7.3 forwards recognized SSH options as -o plus the
                # decoded value. This connector stub performs no network or USB I/O.
                proxy = config.proxy.decode()
                self.assertTrue(proxy.startswith("/usr/bin/python3 '"),
                                "Refusing to launch OpenSSH without the local connector stub")
                for shell in ("/bin/bash", "/bin/sh"):
                    with self.subTest(shell=shell):
                        capture.unlink(missing_ok=True)
                        completed = subprocess.run([
                            "/usr/bin/ssh", "-F", "/dev/null", "-o", "IdentityAgent=none",
                            "-o", "IdentityFile=/dev/null", "-o", "UserKnownHostsFile=/dev/null",
                            "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ProxyCommand=" + proxy,
                            "-o", "ConnectTimeout=2", "root@guest-free.invalid", "sync",
                        ], cwd=root, env=os.environ | result["environment"] | {"CAPTURE": str(capture), "SHELL": shell},
                           capture_output=True, text=True, timeout=5)
                        self.assertNotEqual(completed.returncode, 0)
                        self.assertTrue(capture.exists(),
                                        f"Local connector did not run (shell {shell}, ssh exit {completed.returncode}).\n"
                                        f"stdout: {completed.stdout}\nstderr: {completed.stderr}")
                        self.assertEqual(json.loads(capture.read_text()), {"args": ["proxy", "22"], "ecid": "0000000000001234"})
                        self.assertFalse((root / "PWNED").exists())
            finally:
                fuse.fuse_opt_free_args(ctypes.byref(arguments))


if __name__ == "__main__":
    unittest.main()
