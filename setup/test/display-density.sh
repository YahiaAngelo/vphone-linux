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
                    'args = sys.argv[1:]\n'
                    'with open(os.environ["QEMU_ARGV"], "w") as out:\n'
                    '    json.dump(args, out)\n'
                    'supported = {"apple-gfx-mmio.resolution", '
                    '"apple-gfx-mmio.process-isolation"}\n'
                    'if os.environ.get("QEMU_TEST_PPI_PROPERTY") == "1":\n'
                    '    supported.add("apple-gfx-mmio.pixels-per-inch")\n'
                    'for i, arg in enumerate(args[:-1]):\n'
                    '    if arg == "-global":\n'
                    '        name = args[i + 1].split("=", 1)[0]\n'
                    '        if name not in supported:\n'
                    '            sys.exit(f"Property {name!r} not found")\n')
    qemu.chmod(0o755)
    output = root / "argv.json"
    env = dict(os.environ, QEMU=str(qemu), QEMU_ARGV=str(output), GFX="1",
               GFX_RES="744x1133", GFX_MODES="1488x2266@60/744x1133@60",
               MEM="1M", WINDOW="0", CID="0", VPHONE_CPUS="",
               REIMS_VGPU_CENSUS_DIR="", VK_DRIVER_FILES="unused-test-driver")
    env.pop("GFX_PPI", None)
    absent = object()

    def run(value=absent, override=absent, gfx="1", qemu_supports_ppi=False):
        screen = {} if value is absent else {"pixelsPerInch": value}
        with (vm / "config.plist").open("wb") as config:
            plistlib.dump({"screenConfig": screen}, config)
        output.unlink(missing_ok=True)
        current = dict(env, GFX=gfx)
        if override is not absent:
            current["GFX_PPI"] = override
        if qemu_supports_ppi:
            current["QEMU_TEST_PPI_PROPERTY"] = "1"
        else:
            current.pop("QEMU_TEST_PPI_PROPERTY", None)
        result = subprocess.run(["bash", launcher, str(vm), "-no-reboot"],
                                env=current, capture_output=True, text=True)
        args = json.loads(output.read_text()) if output.exists() else None
        return result, args

    def density(args):
        return [args[i + 1] for i, arg in enumerate(args[:-1])
                if arg == "-global" and
                args[i + 1].startswith("apple-gfx-mmio.pixels-per-inch=")]

    def success(value=absent, override=absent, expected=None, qemu_supports_ppi=False):
        result, args = run(value, override, qemu_supports_ppi=qemu_supports_ppi)
        assert result.returncode == 0, result.stderr
        assert density(args) == ([] if expected is None else
                                 [f"apple-gfx-mmio.pixels-per-inch={expected}"]), args
        machine = args[args.index("-M") + 1]
        assert "gfx-modes=1488x2266@60/744x1133@60" in machine, machine
        assert "apple-gfx-mmio.resolution=744x1133" in args, args
        assert args[-1] == "-no-reboot", args

    # Every VM profile has a density, but legacy QEMU must still start because
    # the launcher does not send a property it does not support.
    success(326)
    success(460)
    success(True)  # profile density is ignored without an explicit override
    success(326, "")
    success(326, "264", expected=264, qemu_supports_ppi=True)
    success(True, "326", expected=326, qemu_supports_ppi=True)  # explicit override takes precedence
    success(326, "1", expected=1, qemu_supports_ppi=True)
    success(326, "65535", expected=65535, qemu_supports_ppi=True)
    success(326, "00001", expected=1, qemu_supports_ppi=True)
    success()
    success(override="326", expected=326, qemu_supports_ppi=True)

    for value in (False, 0, -1, 65536, 326.5, "326", "invalid"):
        success(value)  # profile metadata is not used by this opt-in setting
    for override in ("0", "-1", "65536", "326.5", "invalid", " 326", "٣٢٦"):
        result, args = run(326, override)
        assert result.returncode != 0 and args is None, (override, result, args)
        assert "GFX_PPI must be an integer from 1 to 65535" in result.stderr

    result, args = run(True, "invalid", gfx="0")
    assert result.returncode == 0, result.stderr
    assert density(args) == [], args
    assert "gfx-device=" not in args[args.index("-M") + 1], args

print("ok: legacy QEMU ignores profile density; explicit density is validated and opt-in")
PY
