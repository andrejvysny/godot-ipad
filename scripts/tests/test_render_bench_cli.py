"""`dev.py render-bench` host wrapper: argument validation, HOST labeling, device commands without a claimed run."""
from __future__ import annotations

import argparse
import io
import json
import re
import tempfile
import time
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from unittest import mock

from wp_test_support import SCRIPTS  # noqa: F401
import dev
import dev_render_bench as bench


def args(**kw) -> argparse.Namespace:
    base = dict(scenario="mixed_world_10k", profile="performance", seconds=None, warmup_seconds=None,
                sustained_minutes=None, output=Path("out.json"), timeout=0, device=False, run=False,
                device_id="", bundle_id="")
    base.update(kw)
    return argparse.Namespace(**base)


def report(platform_class: str, status: str = "COMPLETED") -> dict:
    return {"status": status, "evidence": {"platform_class": platform_class, "build": "release",
            "is_target_device": platform_class == "DEVICE", "acceptance": "NOT_ACCEPTANCE_RUN"},
            "steps": [{"id": "a"}]}


class RenderBenchCliTests(unittest.TestCase):
    def setUp(self) -> None:
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        patcher = mock.patch.object(bench, "PULL_DIR", self.root / "from-ipad")
        patcher.start()
        self.addCleanup(patcher.stop)
        poll = mock.patch.object(bench, "POLL_S", 0)
        poll.start()
        self.addCleanup(poll.stop)

    def tearDown(self) -> None:
        self.directory.cleanup()

    def invoke(self, fn, *a):
        out, err = io.StringIO(), io.StringIO()
        with redirect_stdout(out), redirect_stderr(err):
            rc = fn(*a)
        return rc, out.getvalue(), err.getvalue()

    def test_names_match_the_gdscript_tables(self) -> None:
        source = bench.BENCH_SCENARIOS_GD.read_text()
        for name in bench.SCENARIOS:
            self.assertIn('"%s"' % name, source, name)
        profiles = (bench.REPO / "config" / "rendering_profiles.json").read_text()
        for name in bench.REAL_PROFILES:
            self.assertIn('"%s"' % name, profiles)
        plan = (bench.REPO / "app" / "src" / "diagnostics" / "bench_plan.gd").read_text()
        for name in bench.LEGACY_PROFILES:
            self.assertIn('"%s"' % name, plan, name)
        for name in bench.COMPARISON_PROFILES:
            self.assertIn('"%s"' % name, plan, name)
        for name in bench.CAMERAS:
            self.assertIn('"%s"' % name, source, name)

    def test_comparison_and_camera_reach_the_app(self) -> None:
        captured: list[str] = []

        def launch(engine: list[str], user_args: list[str], timeout: int) -> int:
            captured.extend(user_args)
            return 1

        rc, _out, _err = self.invoke(bench.cmd_render_bench,
                                   args(profile="comparison_combined", camera="zoom_transition,rotation"),
                                   launch, self.root, None)
        self.assertEqual(rc, 1)
        self.assertIn("--bench-profiles=comparison_combined", captured)
        self.assertIn("--bench-cameras=zoom_transition,rotation", captured)

    def test_user_args(self) -> None:
        self.assertEqual(bench.build_user_args(["mixed_world_10k", "grass_50k"], ["performance", "detailed"], 60, 5, None),
                         ["--render-bench", "--bench-scenarios=mixed_world_10k,grass_50k",
                          "--bench-profiles=performance,detailed", "--bench-seconds=60", "--bench-warmup-seconds=5",
                          bench.STORAGE_ARG, "--bench-quit", "--bench-ignore-focus"])
        sustained = bench.build_user_args([], [], None, None, 30)
        self.assertIn("--bench-sustained-minutes=30", sustained)
        self.assertFalse(any(a.startswith("--bench-scenarios") for a in sustained))
        self.assertTrue(bench.STORAGE_ARG.startswith("--storage-root=user://"))

    def test_validation_errors_exit_2_without_launching(self) -> None:
        def never(*_a):
            raise AssertionError("must not launch")
        for bad in (args(scenario="nope"), args(profile="turbo"), args(scenario=""),
                    args(sustained_minutes=5), args(seconds=-1), args(camera="unknown")):
            rc, _out, err = self.invoke(bench.cmd_render_bench, bad, never, self.root, never)
            self.assertEqual(rc, 2, err)
            self.assertIn("error:", err)

    def test_host_run_copies_the_report_and_labels_it_host(self) -> None:
        user = self.root / "user"
        output = self.root / "copy" / "host.json"
        calls = []

        def launch(engine, user_args, timeout):
            calls.append((engine, user_args, timeout))
            (user / "traces").mkdir(parents=True)
            stamp = int(time.time())
            (user / "traces" / ("render-bench-%d.json" % stamp)).write_text(json.dumps(report("HOST")))
            (user / "traces" / "render-bench-1000.json").write_text(json.dumps(report("DEVICE")))  # stale
            return 0

        rc, out, _err = self.invoke(bench.cmd_render_bench, args(output=output), launch, user, None)
        self.assertEqual(rc, 0, out)
        self.assertIn("evidence_class: HOST", out)
        self.assertIn("NOT device evidence", out)
        self.assertEqual(json.loads(output.read_text())["evidence"]["platform_class"], "HOST",
                         "the stale report is ignored")
        engine, user_args, timeout = calls[0]
        self.assertNotIn("--headless", engine)
        self.assertIn("--render-bench", user_args)
        self.assertEqual(timeout, bench.DEFAULT_TIMEOUT_S)

    def test_host_run_without_a_report_fails(self) -> None:
        rc, _out, err = self.invoke(bench.cmd_render_bench, args(output=self.root / "o.json"),
                                    lambda *_a: 0, self.root / "empty", None)
        self.assertEqual(rc, 1)
        self.assertIn("no render-bench report", err)
        self.assertFalse((self.root / "o.json").exists())

    def test_a_report_claiming_device_on_a_host_run_is_not_relabeled(self) -> None:
        label, note = bench.evidence_label(report("DEVICE"), host_run=True)
        self.assertEqual(label, "HOST")
        self.assertIn("inconsistent", note)

    def test_sustained_timeout_is_derived(self) -> None:
        seen = []

        def launch(_e, _u, timeout):
            seen.append(timeout)
            return 1
        self.invoke(bench.cmd_render_bench, args(scenario="", sustained_minutes=30), launch, self.root, None)
        self.assertEqual(seen, [30 * 60 + 900])

    def test_device_prints_commands_and_claims_nothing(self) -> None:
        def never(*_a):
            raise AssertionError("must not execute")
        rc, out, _err = self.invoke(bench.cmd_render_bench, args(device=True, device_id="D1", bundle_id="com.x.y"),
                                    never, self.root, never)
        self.assertEqual(rc, 0)
        self.assertIn("devicectl device process launch --device D1 --terminate-existing com.x.y -- -- --render-bench", out)
        self.assertIn("--source Documents/traces", out)
        self.assertIn("NOT RUN", out)
        self.assertFalse(re.search(r"evidence_class", out))

    def test_device_run_requires_ids(self) -> None:
        rc, _out, _err = self.invoke(bench.cmd_render_bench, args(device=True, run=True), None, self.root, None)
        self.assertEqual(rc, 2)

    def test_device_run_claims_a_result_only_after_a_report_was_pulled(self) -> None:
        output = self.root / "dev.json"
        pulled = {"count": 0}

        def run(cmd, _timeout):
            if "copy" in cmd:
                pulled["count"] += 1
                bench.PULL_DIR.mkdir(parents=True, exist_ok=True)
                name = "render-bench-%d.json" % (int(time.time()) + 1)
                (bench.PULL_DIR / name).write_text(json.dumps(report("DEVICE")))
            return 0, "ok"
        rc, out, _err = self.invoke(bench.cmd_render_bench, args(device=True, run=True, device_id="D1",
                                    bundle_id="com.x.y", output=output), None, self.root, run)
        self.assertEqual(rc, 0, out)
        self.assertEqual(pulled["count"], 1)
        self.assertIn("evidence_class: DEVICE", out)
        self.assertTrue(output.is_file())

    def test_device_run_without_a_pulled_report_claims_nothing(self) -> None:
        def run(_cmd, _timeout):
            return 0, "ok"
        real_sleep = time.sleep
        with mock.patch.object(bench.time, "sleep", lambda _s: real_sleep(0.6)):
            rc, out, err = self.invoke(bench.cmd_render_bench, args(device=True, run=True, device_id="D1",
                                       bundle_id="com.x.y", timeout=1, output=self.root / "none.json"),
                                       None, self.root, run)
        self.assertEqual(rc, 1)
        self.assertIn("NO report was pulled", err)
        self.assertNotIn("evidence_class", out)
        self.assertFalse((self.root / "none.json").exists())

    def test_device_sustained_run_can_collect_after_sixty_minutes(self) -> None:
        output = self.root / "sustained.json"

        def run(cmd: list[str], _timeout: int) -> tuple[int, str]:
            if "copy" in cmd:
                bench.PULL_DIR.mkdir(parents=True, exist_ok=True)
                (bench.PULL_DIR / "render-bench-3601.json").write_text(json.dumps(report("DEVICE")))
            return 0, "ok"

        with mock.patch.object(bench.time, "time", side_effect=[0, 0, 3601]), \
                mock.patch.object(bench.time, "sleep"):
            rc, out, _err = self.invoke(bench.cmd_render_bench,
                                       args(scenario="", sustained_minutes=60, device=True, run=True,
                                            device_id="D1", bundle_id="com.x.y", output=output),
                                       None, self.root, run)
        self.assertEqual(rc, 0, out)
        self.assertTrue(output.is_file())

    def test_dev_parser_registers_the_command(self) -> None:
        parsed = dev.build_parser().parse_args(["render-bench", "--scenario", "grass_50k", "--output", "x.json",
                                                 "--seconds", "5"])
        self.assertEqual(parsed.scenario, "grass_50k")
        self.assertEqual(parsed.seconds, 5.0)


if __name__ == "__main__":
    unittest.main()
