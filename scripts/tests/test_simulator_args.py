"""simulator.py launch-argument parsing; never runs simctl."""
from __future__ import annotations

import unittest
from pathlib import Path
from unittest import mock

from wp_test_support import SCRIPTS  # noqa: F401
import simulator


class SimulatorArgsTests(unittest.TestCase):
    def test_app_args_are_split_like_a_shell(self) -> None:
        args = simulator.parse_args(["--device", "UDID", "--app-args",
                                     "-- --editor-selftest --selftest-quit --storage-root=user://selftest_worlds"])
        self.assertEqual(args.app_args, ["--", "--editor-selftest", "--selftest-quit",
                                         "--storage-root=user://selftest_worlds"])

    def test_defaults_are_empty(self) -> None:
        args = simulator.parse_args([])
        self.assertEqual(args.app_args, [])
        self.assertIsNone(args.fetch_selftest)

    def test_fetch_and_app_args_need_a_device(self) -> None:
        for argv in (["--fetch-selftest", "out"], ["--app-args", "-- --x"]):
            with self.subTest(argv=argv), self.assertRaises(SystemExit):
                with mock.patch("sys.stderr"):
                    simulator.parse_args(argv)

    def test_launch_passes_args_after_bundle_id(self) -> None:
        with mock.patch.object(simulator, "run") as run:
            simulator.launch("UDID", ["--", "--editor-selftest"])
        command = run.call_args_list[-1].args[0]
        self.assertEqual(command[-3:], [simulator.BUNDLE_ID, "--", "--editor-selftest"])
        self.assertIn("--terminate-running-process", command)

    def test_fetch_selftest_copies_report_folder(self) -> None:
        import tempfile
        with tempfile.TemporaryDirectory() as tmp:
            container = Path(tmp) / "container"
            (container / "Documents" / "selftest").mkdir(parents=True)
            (container / "Documents" / "selftest" / "report.json").write_text("{}")
            destination = Path(tmp) / "out"
            done = mock.Mock(returncode=0, stdout=str(container) + "\n", stderr="")
            with mock.patch.object(simulator.subprocess, "run", return_value=done):
                report = simulator.fetch_selftest("UDID", destination)
            self.assertEqual(report, destination / "report.json")
            self.assertTrue(report.is_file())


if __name__ == "__main__":
    unittest.main()
