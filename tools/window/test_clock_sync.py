import importlib.util
import threading
import unittest
from pathlib import Path
from unittest import mock


SPEC = importlib.util.spec_from_file_location("vphone_clock_sync", Path(__file__).with_name("vphone-window.py"))
window = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(window)


class ClockSyncTests(unittest.TestCase):
    def setUp(self):
        self.report = {"name": "vphoned", "status": "ok", "capabilities": ["clock"]}
        self.clock = window.ClockSync(7)
        patches = (
            mock.patch.object(window, "health", return_value=self.report),
            mock.patch.object(window, "rpc", return_value={"automatic": True, "changed": False}),
            mock.patch.object(window, "log"),
            mock.patch.object(window.time, "time", return_value=1_800_000_000.0),
        )
        self.health, self.rpc, self.log, self.wall = [patch.start() for patch in patches]
        for patch in patches:
            self.addCleanup(patch.stop)

    def test_offers_only_host_time_after_capability_check(self):
        self.assertTrue(self.clock._send())
        self.health.assert_called_once_with(7, timeout=5)
        self.rpc.assert_called_once_with(7, "time.clock", timeout=30, time=1_800_000_000.0)

    def test_manual_clock_is_left_to_daemon_semantics_without_preference_writes(self):
        self.rpc.return_value = {"automatic": False, "changed": False}
        self.assertTrue(self.clock._send())
        self.assertTrue(self.clock._send())
        self.assertTrue(all(call.args == (7, "time.clock") and set(call.kwargs) == {"timeout", "time"}
                            for call in self.rpc.call_args_list))
        self.log.assert_called_once()
        self.assertIn("Settings", self.log.call_args.args[0])

    def test_unsupported_or_unready_guests_are_not_offered_time(self):
        for report, success in (({**self.report, "capabilities": ["touch"]}, True),
                                ({"error": "health_check_busy"}, False),
                                ({**self.report, "capabilities": "clock"}, False)):
            with self.subTest(report=report):
                self.health.return_value = report
                self.assertEqual(self.clock._send(), success)
        self.rpc.assert_not_called()

    def test_stop_after_health_prevents_the_clock_request(self):
        def health(*args, **kwargs):
            self.clock.stopping.set()
            return self.report

        self.health.side_effect = health
        self.assertTrue(self.clock._send())
        self.rpc.assert_not_called()

    def test_parent_exit_prevents_guest_calls(self):
        with mock.patch.object(window.os, "getppid", return_value=self.clock.owner + 1):
            self.assertTrue(self.clock._send())
            self.clock._run()
        self.health.assert_not_called()
        self.rpc.assert_not_called()

    def run_schedule(self, until, jump_at=None, jump=0):
        state = {"tick": 0.0, "wall": 1_800_000_000.0, "stopped": False}
        offers, probes = [], []

        class Stopping:
            def is_set(self):
                return state["stopped"]

            def wait(self, seconds):
                self.assert_wait(seconds)
                state["tick"] += seconds
                state["wall"] += seconds
                if jump_at is not None and state["tick"] == jump_at:
                    state["wall"] += jump
                state["stopped"] = state["tick"] >= until

            @staticmethod
            def assert_wait(seconds):
                if not 0 < seconds <= 1:
                    raise AssertionError("clock worker busy-spun or used an unbounded wait")

        self.clock.stopping = Stopping()
        old_health = self.health.side_effect

        def health(*args, **kwargs):
            probes.append(state["tick"])
            if old_health:
                return old_health(*args, **kwargs)
            return self.health.return_value

        def rpc(*args, **kwargs):
            offers.append((state["tick"], kwargs))
            return self.rpc.return_value

        self.health.side_effect = health
        self.rpc.side_effect = rpc
        with mock.patch.object(window.time, "monotonic", side_effect=lambda: state["tick"]):
            self.wall.side_effect = lambda: state["wall"]
            self.clock._run()
        return offers, probes

    def test_a_refusal_waits_for_the_next_interval(self):
        self.rpc.side_effect = RuntimeError("time.clock: timed kept its own time")
        self.assertTrue(self.clock._send())
        self.assertIn("refused", self.log.call_args.args[0])

    def test_invalid_clock_state_retries_soon(self):
        self.rpc.return_value = {"automatic": "yes", "changed": False}
        self.assertFalse(self.clock._send())

    def test_connect_and_minute_schedule(self):
        offers, probes = self.run_schedule(61)
        self.assertEqual([tick for tick, _ in offers], [0, 60])
        self.assertEqual(probes, [0, 60])

    def test_unknown_automatic_state_keeps_minute_cadence(self):
        self.rpc.return_value = {"automatic": None, "changed": False}
        offers, _ = self.run_schedule(61)
        self.assertEqual([tick for tick, _ in offers], [0, 60])
        self.log.assert_called_once()
        self.assertIn("unavailable", self.log.call_args.args[0])

    def test_clock_changes_or_suspend_trigger_an_early_offer(self):
        for jump in (-120, 120):
            with self.subTest(jump=jump):
                self.clock = window.ClockSync(7)
                self.health.side_effect = None
                self.rpc.side_effect = None
                offers, _ = self.run_schedule(11, jump_at=10, jump=jump)
                self.assertEqual([tick for tick, _ in offers], [0, 10])
                self.assertEqual(offers[-1][1]["time"], 1_800_000_010.0 + jump)

    def test_errors_retry_sequentially_without_clock_jump_bypassing_backoff(self):
        self.health.side_effect = OSError("not connected")
        offers, probes = self.run_schedule(6, jump_at=1, jump=120)
        self.assertEqual(probes, [0, 5])
        self.assertEqual(offers, [])

    def test_start_does_not_wait_for_health_and_stop_prevents_followup(self):
        entered, release = threading.Event(), threading.Event()

        def health(*args, **kwargs):
            entered.set()
            release.wait(1)
            return self.report

        self.health.side_effect = health
        try:
            self.clock.start()
            self.clock.start()
            self.assertTrue(entered.wait(1))
            self.clock.stopping.set()
        finally:
            release.set()
            self.clock.stop()
        self.assertFalse(self.clock.thread.is_alive())
        self.health.assert_called_once()
        self.rpc.assert_not_called()

    def test_shutdown_join_has_a_fixed_request_bound(self):
        thread = mock.Mock(ident=123)
        self.clock.thread = thread
        self.clock.stop()
        self.assertTrue(self.clock.stopping.is_set())
        thread.join.assert_called_once_with(5.1)


if __name__ == "__main__":
    unittest.main()
