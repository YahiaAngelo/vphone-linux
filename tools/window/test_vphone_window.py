import importlib.util
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[2]
MODULE_PATH = Path(__file__).with_name("vphone-window.py")
SPEC = importlib.util.spec_from_file_location("vphone_window", MODULE_PATH)
window = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(window)


class GuestButtonTests(unittest.TestCase):
    def test_home_uses_home_button_when_springboard_is_unlocked(self):
        calls = []

        def rpc(cid, method, timeout=30, **params):
            calls.append((method, params))
            return {"state": 0} if method == "notify.state" else {}

        with mock.patch.object(window, "rpc", side_effect=rpc):
            window.Guest(3).button("home")

        self.assertEqual(calls, [
            ("notify.state", {"name": "com.apple.springboard.lockstate"}),
            ("input.button", {"name": "home"}),
        ])

    def test_home_wakes_locked_screen_then_sends_one_geometry_based_swipe(self):
        replies = iter([
            {"state": 1}, {}, {"state": 1}, {"state": 0},
            {"width": 440, "height": 956}, {},
        ])
        calls = []

        def rpc(cid, method, timeout=30, **params):
            calls.append((method, params, timeout))
            return next(replies)

        with mock.patch.object(window, "rpc", side_effect=rpc), \
                mock.patch.object(window.time, "sleep") as sleep:
            window.Guest(3).button("home")

        self.assertEqual([method for method, _, _ in calls], [
            "notify.state", "input.button", "notify.state", "notify.state",
            "device.screen", "input.swipe",
        ])
        self.assertEqual(calls[1][1], {"name": "wake"})
        self.assertEqual(calls[-1][1], {
            "x1": 220.0, "y1": 917.76, "x2": 220.0, "y2": 286.8,
            "seconds": 0.7, "steps": 20,
        })
        self.assertEqual(sum(method == "input.swipe" for method, _, _ in calls), 1)
        self.assertTrue(all(0 < timeout <= 5 for _, _, timeout in calls))
        sleep.assert_called_once()

    def test_locked_home_times_out_without_swiping(self):
        calls = []

        def rpc(cid, method, timeout=30, **params):
            calls.append(method)
            return {"state": 1} if method == "notify.state" else {}

        clock = mock.Mock(side_effect=[0, 0, 1, 2, 16])
        with mock.patch.object(window, "rpc", side_effect=rpc), \
                mock.patch.object(window.time, "monotonic", clock), \
                mock.patch.object(window.time, "sleep") as sleep:
            with self.assertRaisesRegex(RuntimeError, "button action timed out"):
                window.Guest(3).button("home")

        self.assertEqual(calls, ["notify.state", "input.button", "notify.state"])
        sleep.assert_not_called()

    def test_lock_wakes_a_blanked_screen_and_powers_down_a_lit_screen(self):
        for blanked, expected in ((0, "power"), (1, "wake")):
            with self.subTest(blanked=blanked):
                calls = []

                def rpc(cid, method, timeout=30, **params):
                    calls.append((method, params))
                    return {"state": blanked} if method == "notify.state" else {}

                with mock.patch.object(window, "rpc", side_effect=rpc):
                    window.Guest(3).button("lock")

                self.assertEqual(calls, [
                    ("notify.state", {"name": "com.apple.springboard.hasBlankedScreen"}),
                    ("input.button", {"name": expected}),
                ])

    def test_invalid_guest_state_fails_closed(self):
        calls = []

        def rpc(cid, method, timeout=30, **params):
            calls.append(method)
            return {"state": True}

        with mock.patch.object(window, "rpc", side_effect=rpc):
            with self.assertRaisesRegex(RuntimeError, "invalid button state"):
                window.Guest(3).button("home")

        self.assertEqual(calls, ["notify.state"])

    def test_home_and_lock_dispatch_to_stateful_mapping(self):
        for button in ("home", "lock"):
            with self.subTest(button=button):
                guest = window.Guest(3)
                guest.busy.acquire()
                guest.button = mock.Mock()
                with mock.patch.object(window, "rpc") as rpc:
                    guest._act(button)
                guest.button.assert_called_once_with(button)
                rpc.assert_not_called()


class WindowLoopTests(unittest.TestCase):
    def run_loop(self, orientations, parent_ids):
        events = []
        windows = []
        guests = []

        class FakeGuest:
            def __init__(self, cid):
                self.replies = iter(orientations)
                self.reads = 0
                guests.append(self)

            def orientation(self):
                self.reads += 1
                events.append("orientation")
                return next(self.replies)

        class FakeWindow:
            def __init__(self, path):
                self.sock = None
                self.timeouts = []
                windows.append(self)

            def connect(self):
                self.sock = object()
                return True

            def send(self, line):
                events.append(line)

            def lines(self, timeout):
                self.timeouts.append(timeout)
                return []

        parent_ids = iter(parent_ids)
        with mock.patch.object(window, "Guest", FakeGuest), \
                mock.patch.object(window, "Window", FakeWindow), \
                mock.patch.object(window, "atlas_for", return_value="mock-atlas.rgba"), \
                mock.patch.object(window, "log"), \
                mock.patch.object(window.os, "getppid", side_effect=lambda: next(parent_ids)), \
                mock.patch.object(window.sys, "argv", [str(MODULE_PATH), "/tmp/control.sock"]):
            window.main()

        return events, windows[0], guests[0]

    def test_phone_shows_toolbar_before_one_orientation_read_then_stops_polling(self):
        events, fake_window, guest = self.run_loop(
            orientations=[{}], parent_ids=[77, 77, 77, 0]
        )

        toolbar = next(i for i, event in enumerate(events) if event.startswith("toolbar "))
        orientation = events.index("orientation")
        self.assertLess(toolbar, orientation)
        self.assertEqual(guest.reads, 1)
        self.assertEqual(fake_window.timeouts, [window.POLL, window.POLL])
        self.assertNotIn("fold", events[toolbar])

    def test_duo_keeps_polling_and_adds_fold_after_orientation_is_known(self):
        events, _, guest = self.run_loop(
            orientations=[{"fold_angle": 0}, {"fold_angle": 90}, {"fold_angle": 90}],
            parent_ids=[77, 77, 77, 77, 0],
        )

        first_toolbar = next(i for i, event in enumerate(events) if event.startswith("toolbar "))
        first_orientation = events.index("orientation")
        fold_toolbar = next(i for i, event in enumerate(events) if event.startswith("toolbar ") and ",fold" in event)
        self.assertLess(first_toolbar, first_orientation)
        self.assertLess(first_orientation, fold_toolbar)
        self.assertEqual(guest.reads, 3)
        self.assertIn("rotate 90", events)


class LauncherSocketTests(unittest.TestCase):
    def test_launcher_preserves_control_socket_override_and_uses_default_when_absent(self):
        for override in ("/tmp/custom-window-control.sock", None):
            with self.subTest(override=override), tempfile.TemporaryDirectory() as tmp:
                temp = Path(tmp)
                vm = temp / "vm"
                vm.mkdir()
                (vm / "ecid").write_text("0x1234\n")
                with (vm / "config.plist").open("wb") as stream:
                    plistlib.dump({}, stream)

                bin_dir = temp / "bin"
                bin_dir.mkdir()
                window_capture = temp / "window-control.txt"
                qemu_capture = temp / "qemu-control.txt"
                fake_python = bin_dir / "python3"
                fake_python.write_text(
                    f"#!{sys.executable}\n"
                    "import os, pathlib, sys\n"
                    "if sys.argv[1].endswith('/tools/window/vphone-window.py'):\n"
                    "    control = os.environ['REIMS_VGPU_WINDOW_CONTROL']\n"
                    "    pathlib.Path(os.environ['WINDOW_CAPTURE']).write_text(control)\n"
                    "else:\n"
                    f"    os.execv({sys.executable!r}, [{sys.executable!r}, *sys.argv[1:]])\n"
                )
                fake_python.chmod(0o755)

                fake_qemu = bin_dir / "qemu"
                fake_qemu.write_text(
                    f"#!{sys.executable}\n"
                    "import os, pathlib, time\n"
                    "capture = pathlib.Path(os.environ['WINDOW_CAPTURE'])\n"
                    "deadline = time.monotonic() + 2\n"
                    "while not capture.exists() and time.monotonic() < deadline:\n"
                    "    time.sleep(.01)\n"
                    "if not capture.exists():\n"
                    "    raise SystemExit('window companion did not start')\n"
                    "pathlib.Path(os.environ['QEMU_CAPTURE']).write_text(os.environ['REIMS_VGPU_WINDOW_CONTROL'])\n"
                )
                fake_qemu.chmod(0o755)

                env = os.environ.copy()
                env.update({
                    "PATH": f"{bin_dir}:{env['PATH']}",
                    "QEMU": str(fake_qemu),
                    "GFX": "1",
                    "WINDOW": "1",
                    "TOOLBAR": "1",
                    "CID": "314",
                    "MEM": "1M",
                    "VPHONE_CPUS": "",
                    "REIMS_VGPU_CENSUS_DIR": "",
                    "XDG_RUNTIME_DIR": str(temp),
                    "WINDOW_CAPTURE": str(window_capture),
                    "QEMU_CAPTURE": str(qemu_capture),
                })
                if override is None:
                    env.pop("REIMS_VGPU_WINDOW_CONTROL", None)
                else:
                    env["REIMS_VGPU_WINDOW_CONTROL"] = override

                result = subprocess.run(
                    ["bash", str(ROOT / "run-vphone.sh"), str(vm)],
                    cwd=ROOT, env=env, capture_output=True, text=True, timeout=10,
                )
                self.assertEqual(result.returncode, 0, result.stderr)

                expected = override or str(temp / "vphone-window-314.sock")
                self.assertEqual(window_capture.read_text(), expected)
                self.assertEqual(qemu_capture.read_text(), expected)


if __name__ == "__main__":
    unittest.main()
