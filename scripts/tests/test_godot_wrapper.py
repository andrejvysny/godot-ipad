"""Import failures and per-invocation isolation must survive zero Godot exit codes."""
from __future__ import annotations

import io
import tempfile
import unittest
from contextlib import redirect_stdout, redirect_stderr
from pathlib import Path
from unittest import mock

from wp_test_support import SCRIPTS  # noqa: F401
import godot_test


class GodotWrapperTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.app = self.root / "app"
        self.app.mkdir()
        (self.app / "project.godot").write_text("config_version=5\n")
        (self.app / ".godot").mkdir()

    def tearDown(self) -> None:
        self.directory.cleanup()

    def invoke(self, args: list[str]) -> int:
        with mock.patch.object(godot_test, "REPO", self.root), \
                mock.patch.object(godot_test, "APP", self.app), \
                mock.patch("sys.argv", ["godot_test.py", *args]), \
                redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
            return godot_test.main()

    def test_import_error_with_zero_exit_never_runs_tests(self) -> None:
        with mock.patch.object(godot_test, "godot_import", return_value=(0, "SCRIPT ERROR: Parse Error")), \
                mock.patch.object(godot_test, "godot_tests") as tests:
            self.assertEqual(self.invoke(["--sandbox", "same"]), 1)
            tests.assert_not_called()

    def test_same_label_gets_distinct_project_and_user_directories(self) -> None:
        with mock.patch.object(godot_test, "godot_tests", return_value=(0, "OK")) as tests:
            self.assertEqual(self.invoke(["--sandbox", "same", "--no-import"]), 0)
            self.assertEqual(self.invoke(["--sandbox", "same", "--no-import"]), 0)
        paths = [call.args[0] for call in tests.call_args_list]
        self.assertNotEqual(paths[0], paths[1])
        overrides = [(path / "override.cfg").read_text() for path in paths]
        self.assertNotEqual(overrides[0], overrides[1])
        self.assertTrue(all("config/custom_user_dir_name=" in text for text in overrides))

    def test_invalid_sandbox_does_not_copy_or_delete(self) -> None:
        with mock.patch.object(godot_test, "prepare_sandbox") as copy:
            with self.assertRaises(SystemExit):
                self.invoke(["--sandbox", "../outside"])
            copy.assert_not_called()

    def test_rendered_command_omits_headless_and_selects_driver(self) -> None:
        with mock.patch.object(godot_test, "run", return_value=(0, "")) as run:
            godot_test.godot_tests(self.app, "", "gpu", rendered=True, driver="vulkan")
            godot_test.godot_tests(self.app, "", "gpu", rendered=True)
            godot_test.godot_tests(self.app, "unit", "")
        vulkan, mobile, headless = (c.args[0] for c in run.call_args_list)
        self.assertNotIn("--headless", vulkan)
        self.assertEqual(vulkan[vulkan.index("--rendering-method") + 1:][:3], ["mobile", "--rendering-driver", "vulkan"])
        self.assertNotIn("--headless", mobile)
        self.assertNotIn("--rendering-driver", mobile)
        self.assertIn("--rendering-method", mobile)
        self.assertIn("--headless", headless)
        self.assertNotIn("--rendering-method", headless)

    def test_rendered_defaults_filter_and_fails_on_not_run(self) -> None:
        with mock.patch.object(godot_test, "godot_tests", return_value=(0, "GPU: NOT RUN")) as tests:
            self.assertEqual(self.invoke(["--no-import", "--rendered"]), 1)
            self.assertEqual(tests.call_args.args[2], "gpu")
        with mock.patch.object(godot_test, "godot_tests", return_value=(0, "ok")) as tests:
            self.assertEqual(self.invoke(["--no-import", "--rendered", "--filter", "x"]), 0)
            self.assertEqual(tests.call_args.args[2], "x")
