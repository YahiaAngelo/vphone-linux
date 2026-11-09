import importlib.util
import json
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

    def test_invalid_guest_state_fails_closed_for_lock(self):
        calls = []

        def rpc(cid, method, timeout=30, **params):
            calls.append(method)
            return {"state": True}

        with mock.patch.object(window, "rpc", side_effect=rpc):
            with self.assertRaisesRegex(RuntimeError, "invalid button state"):
                window.Guest(3).button("lock")

        self.assertEqual(calls, ["notify.state"])

    def test_home_without_a_usable_state_sends_the_plain_button(self):
        for answer in ({"state": True}, OSError("vphoned down")):
            with self.subTest(answer=answer):
                calls = []

                def rpc(cid, method, timeout=30, **params):
                    calls.append((method, params))
                    if method == "notify.state":
                        if isinstance(answer, Exception):
                            raise answer
                        return answer
                    return {}

                with mock.patch.object(window, "rpc", side_effect=rpc):
                    window.Guest(3).button("home")

                self.assertEqual(calls[-1], ("input.button", {"name": "home"}))

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
    def run_loop(self, orientations, parent_ids, config=None, connected=True, clock_sync=None):
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
                self.sock = object() if connected else None
                return connected

            def send(self, line):
                events.append(line)

            def lines(self, timeout):
                self.timeouts.append(timeout)
                return []

            def drop(self):
                self.sock = None

        parent_ids = iter(parent_ids)
        with tempfile.TemporaryDirectory() as tmp:
            argv = [str(MODULE_PATH), "/tmp/control.sock"]
            if config is not None:
                config_path = Path(tmp) / "config.plist"
                if isinstance(config, bytes):
                    config_path.write_bytes(config)
                else:
                    with config_path.open("wb") as stream:
                        plistlib.dump(config, stream)
                argv += ["--config", str(config_path)]
            with mock.patch.object(window, "Guest", FakeGuest), \
                mock.patch.object(window, "Window", FakeWindow), \
                mock.patch.object(window, "ClockSync") as clock, \
                mock.patch.object(window, "atlas_for", return_value="mock-atlas.rgba"), \
                mock.patch.object(window, "log"), \
                mock.patch.object(window.os, "getppid", side_effect=lambda: next(parent_ids)), \
                mock.patch.object(window.sys, "argv", argv), \
                mock.patch.dict(window.os.environ, {} if clock_sync is None
                                else {"VPHONE_CLOCK_SYNC": clock_sync}):
                if clock_sync is None:
                    window.os.environ.pop("VPHONE_CLOCK_SYNC", None)
                window.main()
                if clock_sync == "0":
                    clock.assert_not_called()
                    return events, windows[0], guests[0]
                clock.assert_called_once_with(3)
                if connected:
                    clock.return_value.start.assert_called_once_with()
                else:
                    clock.return_value.start.assert_not_called()
                clock.return_value.stop.assert_called_once_with()

        return events, windows[0], guests[0]

    def test_clock_sync_can_be_turned_off(self):
        self.run_loop(orientations=[], parent_ids=[77, 77, 0],
                      config={"guestProductType": "iPhone17,3"}, clock_sync="0")

    def test_known_phone_shows_toolbar_without_orientation_polling(self):
        events, fake_window, guest = self.run_loop(
            orientations=[], parent_ids=[77, 77, 77, 0],
            config={"guestProductType": "iPhone17,3"},
        )

        toolbar = next(i for i, event in enumerate(events) if event.startswith("toolbar "))
        self.assertEqual(guest.reads, 0)
        self.assertEqual(fake_window.timeouts, [window.POLL, window.POLL])
        self.assertNotIn("fold", events[toolbar])

    def test_clock_does_not_start_until_the_window_connects(self):
        self.run_loop(orientations=[], parent_ids=[77, 77, 77, 0],
                      config={"guestProductType": "iPhone17,3"}, connected=False)

    def test_cold_duo_shows_fold_before_hinge_is_configured_and_keeps_polling(self):
        events, _, guest = self.run_loop(
            orientations=[{"degrees": 0}, {"fold_angle": 90}, {"fold_angle": 90}],
            parent_ids=[77, 77, 77, 77, 0],
            config={"guestProductType": "iPhone19,4"},
        )

        first_toolbar = next(i for i, event in enumerate(events) if event.startswith("toolbar "))
        self.assertIn(",fold", events[first_toolbar])
        self.assertLess(first_toolbar, events.index("orientation"))
        self.assertEqual(guest.reads, 3)
        self.assertIn("rotate 90", events)

    def test_unknown_product_can_discover_hinge_after_initial_angle_is_absent(self):
        for config in (None, {}, {"guestProductType": ""},
                       b'<?xml version="1.0"?><plist><dict>'):
            with self.subTest(config=config):
                events, _, guest = self.run_loop(
                    orientations=[{"degrees": 0}, {"fold_angle": 90}, {"fold_angle": 90}],
                    parent_ids=[77, 77, 77, 77, 0], config=config,
                )

                toolbars = [event for event in events if event.startswith("toolbar ")]
                self.assertNotIn(",fold", toolbars[0])
                self.assertIn(",fold", toolbars[-1])
                self.assertEqual(guest.reads, 3)
                self.assertIn("rotate 90", events)

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
    def test_launcher_passes_product_metadata_and_preserves_control_socket(self):
        for override, product in (("/tmp/custom-window-control.sock", "iPhone19,4"),
                                  (None, "iPhone17,3"), (None, None)):
            with self.subTest(override=override, product=product), tempfile.TemporaryDirectory() as tmp:
                temp = Path(tmp)
                vm = temp / "vm"
                vm.mkdir()
                (vm / "ecid").write_text("0x1234\n")
                with (vm / "config.plist").open("wb") as stream:
                    plistlib.dump({"guestProductType": product} if product else {}, stream)

                bin_dir = temp / "bin"
                bin_dir.mkdir()
                window_capture = temp / "window-control.txt"
                qemu_capture = temp / "qemu-control.txt"
                fake_python = bin_dir / "python3"
                fake_python.write_text(
                    f"#!{sys.executable}\n"
                    "import argparse, json, os, pathlib, plistlib, sys\n"
                    "if sys.argv[1].endswith('/tools/window/vphone-window.py'):\n"
                    "    parser = argparse.ArgumentParser()\n"
                    "    parser.add_argument('socket')\n"
                    "    parser.add_argument('--cid', type=int)\n"
                    "    parser.add_argument('--config')\n"
                    "    args = parser.parse_args(sys.argv[2:])\n"
                    "    with open(args.config, 'rb') as stream:\n"
                    "        product = plistlib.load(stream).get('guestProductType')\n"
                    "    record = dict(control=os.environ['REIMS_VGPU_WINDOW_CONTROL'],\n"
                    "                  socket=args.socket, cid=args.cid, product=product)\n"
                    "    pathlib.Path(os.environ['WINDOW_CAPTURE']).write_text(json.dumps(record))\n"
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
                    "VSOCK": "vhost",
                    "VSOCK_DIR": str(temp / "vsock"),
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
                self.assertEqual(json.loads(window_capture.read_text()), {
                    "control": expected, "socket": expected, "cid": 314, "product": product,
                })
                self.assertEqual(qemu_capture.read_text(), expected)


if __name__ == "__main__":
    unittest.main()
