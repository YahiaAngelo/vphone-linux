#!/usr/bin/env bash
# Exercise the real launcher's argv without starting QEMU or allocating guest RAM.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
python3 - "$root/run-vphone.sh" <<'PY'
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile

launcher = sys.argv[1]
with tempfile.TemporaryDirectory(prefix="vphone-display-density-") as directory:
    root = Path(directory)
    vm = root / "vm with spaces"
    vm.mkdir()
    (vm / "ecid").write_text("0x1234\n")
    (vm / "gfx-res").write_text("744x1133\n")
    qemu = root / "qemu"
    qemu.write_text('#!/usr/bin/env python3\nimport json, os, sys\n'
                    'with open(os.environ["QEMU_ARGV"], "w") as out:\n'
                    '    json.dump(sys.argv[1:], out)\n')
    qemu.chmod(0o755)
    output = root / "argv.json"
    env = dict(os.environ, QEMU=str(qemu), QEMU_ARGV=str(output), GFX="1",
               GFX_RES="744x1133", GFX_MODES="1488x2266@60/744x1133@60",
               MEM="1M", WINDOW="0", CID="0", VPHONE_CPUS="",
               REIMS_VGPU_CENSUS_DIR="", VK_DRIVER_FILES="unused-test-driver")
    env.pop("GFX_PPI", None)
    absent = object()

    def run(value=absent, override=absent, gfx="1"):
        screen = {} if value is absent else {"pixelsPerInch": value}
        with (vm / "config.plist").open("wb") as config:
            plistlib.dump({"screenConfig": screen}, config)
        output.unlink(missing_ok=True)
        current = dict(env, GFX=gfx)
        if override is not absent:
            current["GFX_PPI"] = override
        result = subprocess.run(["bash", launcher, str(vm), "-no-reboot"],
                                env=current, capture_output=True, text=True)
        args = json.loads(output.read_text()) if output.exists() else None
        return result, args

    def density(args):
        return [args[i + 1] for i, arg in enumerate(args[:-1])
                if arg == "-global" and
                args[i + 1].startswith("apple-gfx-mmio.pixels-per-inch=")]

    def success(value=absent, override=absent, expected=None):
        result, args = run(value, override)
        assert result.returncode == 0, result.stderr
        assert density(args) == ([] if expected is None else
                                 [f"apple-gfx-mmio.pixels-per-inch={expected}"]), args
        machine = args[args.index("-M") + 1]
        assert "gfx-modes=1488x2266@60/744x1133@60" in machine, machine
        assert "apple-gfx-mmio.resolution=744x1133" in args, args
        assert args[-1] == "-no-reboot", args

    success(326, expected=326)
    success(460, expected=460)
    success(326, "264", expected=264)
    success(True, "326", expected=326)  # override takes precedence
    success(326, "", expected=326)
    success(1, expected=1)
    success(65535, expected=65535)
    success()
    success(override="326", expected=326)

    for value in (True, 0, -1, 65536, 326.5, "326", "invalid"):
        result, args = run(value)
        assert result.returncode != 0 and args is None, (value, result, args)
        assert "screenConfig.pixelsPerInch must be an integer from 1 to 65535" in result.stderr
    for override in ("0", "-1", "65536", "326.5", "invalid", " 326", "٣٢٦"):
        result, args = run(326, override)
        assert result.returncode != 0 and args is None, (override, result, args)
        assert "GFX_PPI must be an integer from 1 to 65535" in result.stderr

    result, args = run(True, "invalid", gfx="0")
    assert result.returncode == 0, result.stderr
    assert density(args) == [], args
    assert "gfx-device=" not in args[args.index("-M") + 1], args

print("ok: display density follows the profile or explicit override; invalid values stop before QEMU")
PY
