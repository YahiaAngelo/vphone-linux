import importlib.util
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import Mock, call, patch


SCRIPT = Path(__file__).resolve().parents[1] / "tools" / "usbmux-connect.py"
SPEC = importlib.util.spec_from_file_location("usbmux_connect", SCRIPT)
usbmux_connect = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = usbmux_connect
SPEC.loader.exec_module(usbmux_connect)


class USBMuxECIDSelectionTests(unittest.TestCase):
    ecid = "00123456789ABCDE"
    compact_serial = "8010ABCD00123456789ABCDE"
    udid = "8010ABCD-00123456789ABCDE"

    def setUp(self):
        self.environment = patch.dict(os.environ, {}, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def test_matches_vphone_usb_serial_and_predicted_udid_formats(self):
        for serial in (self.compact_serial, self.udid, self.ecid.lower()):
            for requested in (self.ecid, "0x" + self.ecid.lower(), "0X" + self.ecid):
                with self.subTest(serial=serial, requested=requested):
                    os.environ["VPHONE_ECID"] = requested
                    self.assertEqual(
                        usbmux_connect.candidate_ids([(7, 0x1227, serial)]),
                        [7],
                    )

    def test_malformed_ecid_fails_closed(self):
        devices = [(1, 0x1227, self.compact_serial)]
        for requested in ("", "0x", "0x123g", "10000000000000000", "+1234"):
            with self.subTest(requested=requested):
                os.environ["VPHONE_ECID"] = requested
                with self.assertRaisesRegex(ValueError, "VPHONE_ECID must be"):
                    usbmux_connect.candidate_ids(devices)

    def test_substring_and_malformed_serials_do_not_match(self):
        os.environ["VPHONE_ECID"] = self.ecid
        devices = [
            (1, 0x1227, "prefix" + self.ecid),
            (2, 0x1227, "8010ABCD-100123456789ABCDE"),
            (3, 0x1227, "8010ABCD00123456789ABCDEF"),
        ]
        with self.assertRaisesRegex(ValueError, "did not match"):
            usbmux_connect.candidate_ids(devices)

    def test_missing_or_ambiguous_match_fails_even_with_override(self):
        os.environ["VPHONE_ECID"] = self.ecid
        os.environ["USBMUX_DEVICE"] = "9"
        with self.assertRaisesRegex(ValueError, "did not match"):
            usbmux_connect.candidate_ids([(9, 0x1227, "FFFFFFFFFFFFFFFF")])
        with self.assertRaisesRegex(ValueError, "matched multiple"):
            usbmux_connect.candidate_ids([
                (1, 0x1227, self.compact_serial),
                (2, 0x1227, self.udid),
            ])

    def test_sole_device_without_an_ecid_serial_is_accepted(self):
        os.environ["VPHONE_ECID"] = self.ecid
        stock = (7, 0x12a8, "SSHRD_Script Sep 22 2022 18:56:50")
        self.assertEqual(usbmux_connect.candidate_ids([stock]), [7])
        # Never next to another device, and never in place of a device with another ECID.
        with self.assertRaisesRegex(ValueError, "did not match"):
            usbmux_connect.candidate_ids([stock, (8, 0x1227, "FFFFFFFFFFFFFFFF")])
        with self.assertRaisesRegex(ValueError, "did not match"):
            usbmux_connect.candidate_ids([(8, 0x1227, "FFFFFFFFFFFFFFFF")])

    def test_usb_device_override_must_match_the_ecid_device(self):
        devices = [(7, 0x1227, self.compact_serial), (8, 0x1227, "FFFFFFFFFFFFFFFF")]
        os.environ["VPHONE_ECID"] = self.ecid
        os.environ["USBMUX_DEVICE"] = "7"
        self.assertEqual(usbmux_connect.candidate_ids(devices), [7])
        os.environ["USBMUX_DEVICE"] = "8"
        with self.assertRaisesRegex(ValueError, "does not match"):
            usbmux_connect.candidate_ids(devices)
        os.environ["USBMUX_DEVICE"] = "not-a-handle"
        with self.assertRaisesRegex(ValueError, "numeric usbmux handle"):
            usbmux_connect.candidate_ids(devices)

    def test_ecid_connection_failure_never_falls_back_to_another_device(self):
        os.environ["VPHONE_ECID"] = self.ecid
        unrelated = (8, 0x1227, "FFFFFFFFFFFFFFFF")
        selected = (7, 0x1227, self.compact_serial)
        connect = Mock(side_effect=RuntimeError("selected endpoint unavailable"))
        with patch.object(usbmux_connect, "list_devices", return_value=[unrelated, selected]), \
             patch.object(usbmux_connect, "connect", connect):
            with self.assertRaisesRegex(SystemExit, "no reachable usbmux device"):
                usbmux_connect.open_port(22)
        connect.assert_called_once_with(7, 22)

    def test_ecid_miss_does_not_fall_back_to_usb_device_override(self):
        os.environ["VPHONE_ECID"] = self.ecid
        os.environ["USBMUX_DEVICE"] = "8"
        connect = Mock()
        with patch.object(usbmux_connect, "list_devices", return_value=[
            (8, 0x1227, "FFFFFFFFFFFFFFFF"),
        ]), patch.object(usbmux_connect, "connect", connect):
            with self.assertRaisesRegex(SystemExit, "did not match"):
                usbmux_connect.open_port(22)
        connect.assert_not_called()

    def test_malformed_ecid_fails_before_device_discovery(self):
        os.environ["VPHONE_ECID"] = "0xnot-hex"
        with patch.object(usbmux_connect, "list_devices") as list_devices:
            with self.assertRaisesRegex(SystemExit, "VPHONE_ECID must be"):
                usbmux_connect.open_port(22)
        list_devices.assert_not_called()

    def test_no_ecid_preserves_generic_candidate_and_override_behavior(self):
        devices = [(4, 0x1227, "FFFFFFFFFFFFFFFF"), (8, 0x1227, self.compact_serial)]
        self.assertEqual(usbmux_connect.candidate_ids(devices), [4, 8])
        os.environ["USBMUX_DEVICE"] = "6"
        connect = Mock(return_value="socket")
        with patch.object(usbmux_connect, "list_devices") as list_devices, \
             patch.object(usbmux_connect, "connect", connect):
            self.assertEqual(usbmux_connect.open_port(22), "socket")
        list_devices.assert_not_called()
        connect.assert_called_once_with(6, 22)

    def test_no_ecid_preserves_generic_connection_fallback(self):
        devices = [(4, 0x1227, "FFFFFFFFFFFFFFFF"), (8, 0x1227, self.compact_serial)]
        connect = Mock(side_effect=[OSError("first device unavailable"), "socket"])
        with patch.object(usbmux_connect, "list_devices", return_value=devices), \
             patch.object(usbmux_connect, "connect", connect):
            self.assertEqual(usbmux_connect.open_port(22), "socket")
        self.assertEqual(connect.call_args_list, [
            call(4, 22),
            call(8, 22),
        ])


if __name__ == "__main__":
    unittest.main()
