#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.12"
# dependencies = []
# ///
"""Run SSH wrappers against local stubs, never a USB or network connection."""

import json
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]

SSH = r'''
import json, os, pathlib, stat, subprocess, sys
args = sys.argv[1:]
proxy = next(value.split('=', 1)[1] for value in args if value.startswith('ProxyCommand='))
# OpenSSH adds exec before percent expansion and shell parsing. Only %% may appear
# in this literal path; any accidentally unescaped %h would change it.
expanded = 'exec '
i = 0
while i < len(proxy):
    if proxy[i] == '%':
        token = proxy[i + 1]
        expanded += '%' if token == '%' else {'h': 'vphone', 'p': '22', 'r': 'root'}[token]
        i += 2
    else:
        expanded += proxy[i]
        i += 1
result = subprocess.run(['/bin/sh', '-c', expanded], capture_output=True, text=True, check=True)
record = dict(args=args, proxy=json.loads(result.stdout), ecid=os.environ['VPHONE_ECID'])
if os.environ.get('SSH_ASKPASS'):
    helper = pathlib.Path(os.environ['SSH_ASKPASS'])
    record.update(askpass=str(helper), mode=stat.S_IMODE(helper.stat().st_mode),
                  parent_mode=stat.S_IMODE(helper.parent.stat().st_mode),
                  password=subprocess.check_output([str(helper)], text=True))
pathlib.Path(os.environ['CAPTURE']).write_text(json.dumps(record))
raise SystemExit(int(os.environ.get('SSH_STATUS', '0')))
'''


class SSHWrapperTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="vphone-ssh-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.checkout = self.root / 'checkout \'" back\\slash ; touch PWNED; # %h,$(id)\t\n'
        tools = self.checkout / "tools"
        tools.mkdir(parents=True)
        for name in ("ssh-ramdisk.sh", "sshfs-remote-sftp.sh"):
            shutil.copy2(ROOT / "tools" / name, tools / name)
        connector = tools / "usbmux-connect.py"
        connector.write_text("import json, os, sys\nprint(json.dumps(dict(args=sys.argv[1:], ecid=os.environ['VPHONE_ECID'])))\n")
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.executable("ssh", SSH)
        self.executable("setsid", "import os, sys\nos.execvp(sys.argv[2], sys.argv[2:])\n")
        # Substitute only the copied wrapper's absolute SSH executable.
        # Production keeps /usr/bin/ssh and does not search PATH.
        wrapper = tools / "sshfs-remote-sftp.sh"
        wrapper.write_text(wrapper.read_text().replace(
            "exec /usr/bin/ssh ", f"exec {shlex.quote(str(self.bin / 'ssh'))} ", 1))
        self.capture = self.root / "capture.json"
        self.tmp = self.root / "private-temp"
        self.tmp.mkdir(mode=0o700)
        self.env = os.environ | {"PATH": f"{self.bin}:{os.environ['PATH']}",
                                 "CAPTURE": str(self.capture), "TMPDIR": str(self.tmp),
                                 "VPHONE_ECID": "0000000000001234"}
        self.env.pop("SSH_ASKPASS", None)
        self.env.pop("VPHONE_SSH_ASKPASS", None)

    def executable(self, name, source):
        path = self.bin / name
        path.write_text(f"#!{sys.executable}\n{source}")
        path.chmod(0o700)

    def run_wrapper(self, name, *args, **environment):
        return subprocess.run(["bash", str(self.checkout / "tools" / name), *args],
                              cwd=self.root, env=self.env | environment,
                              capture_output=True, text=True, timeout=5)

    def record(self):
        record = json.loads(self.capture.read_text())
        self.assertEqual(record["proxy"], {"args": ["proxy", "22"], "ecid": self.env["VPHONE_ECID"]})
        self.assertEqual(record["ecid"], self.env["VPHONE_ECID"])
        self.assertFalse((self.root / "PWNED").exists())
        return record

    def test_sshfs_wrapper_preserves_arguments_and_literal_proxy_path(self):
        remote = "root@vphone"
        option = "IdentityAgent=/path's;$(id) %h socket"
        result = self.run_wrapper("sshfs-remote-sftp.sh", "-o", option, "-s", "--", remote, "sftp")
        self.assertEqual(result.returncode, 0, result.stderr)
        args = self.record()["args"]
        self.assertEqual(args[-5:], ["-o", option, "--", remote, "/usr/libexec/sftp-server"])

    def test_ramdisk_uses_private_helper_and_preserves_remote_command(self):
        remote = "printf '%s' 'literal;$(touch PWNED)'"
        result = self.run_wrapper("ssh-ramdisk.sh", remote)
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.record()
        self.assertEqual(record["args"][-2:], ["root@vphone", remote])
        self.assertEqual(record["password"], "alpine\n")
        self.assertEqual(record["mode"], 0o700)
        self.assertEqual(record["parent_mode"], 0o700)
        helper = Path(record["askpass"])
        self.assertEqual(helper.parent.parent, self.tmp)
        self.assertFalse(helper.parent.exists())

    def test_ramdisk_ignores_a_desktop_askpass(self):
        # Fedora's openssh-askpass and KDE export SSH_ASKPASS system-wide; it would prompt on
        # screen instead of logging in to the ramdisk.
        desktop = self.tmp / "ksshaskpass"
        desktop.write_text("#!/bin/sh\nprintf 'desktop\\n'\n")
        desktop.chmod(0o700)
        result = self.run_wrapper("ssh-ramdisk.sh", "id", SSH_ASKPASS=str(desktop))
        self.assertEqual(result.returncode, 0, result.stderr)
        record = self.record()
        self.assertEqual(record["password"], "alpine\n")
        self.assertNotEqual(record["askpass"], str(desktop))

    def test_ramdisk_retains_explicit_per_run_helper_and_child_failure(self):
        helper = self.tmp / "bound-helper"
        helper.write_text("#!/bin/sh\nprintf 'bound\\n'\n")
        helper.chmod(0o700)
        result = self.run_wrapper("ssh-ramdisk.sh", "sync", VPHONE_SSH_ASKPASS=str(helper), SSH_STATUS="19")
        self.assertEqual(result.returncode, 19, result.stderr)
        record = self.record()
        self.assertEqual(record["password"], "bound\n")
        self.assertEqual(record["askpass"], str(helper))
        self.assertTrue(helper.is_file())

    def test_ramdisk_rejects_unavailable_explicit_helper_before_ssh(self):
        result = self.run_wrapper("ssh-ramdisk.sh", "sync", VPHONE_SSH_ASKPASS=str(self.tmp / "missing"))
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.capture.exists())


if __name__ == "__main__":
    unittest.main()
