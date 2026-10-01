"""`dev.py render-bench`: host wrapper of the in-app representative render bench (spec §22.3).

Mac runs open the app WITH a real renderer (not headless) and are labeled HOST: they are never device evidence.
`--device` only prepares (prints) the devicectl launch and pull commands for an already-installed build; with
`--run` it launches and polls for the report, and claims a result only when a report file was actually pulled.
"""
from __future__ import annotations

import json
import re
import shutil
import sys
import time
from pathlib import Path
from typing import Callable

REPO = Path(__file__).resolve().parent.parent
BENCH_SCENARIOS_GD = REPO / "app" / "src" / "diagnostics" / "bench_scenarios.gd"
REPORT_RE = re.compile(r"render-bench-(\d+)\.json$")
SCENARIOS = ["terrain_only_legacy", "terrain_only_1km", "primitive_1k", "primitive_5k", "geometry_forest_10k",
             "card_forest_10k", "mixed_world_10k", "mixed_world_50k", "grass_50k", "asset_diversity"]
REAL_PROFILES = ["performance", "balanced", "detailed"]
LEGACY_PROFILES = ["scale_100", "scale_075", "scale_065", "scale_050", "legacy_shadows_diagnostic",
                   "terrain_mesh_24", "terrain_mesh_32"]
STORAGE_ARG = "--storage-root=user://render_bench_worlds"  # never the user's worlds
DEFAULT_TIMEOUT_S = 3600
POLL_S = 30
PULL_DIR = REPO / "build" / "from-ipad"


def split_names(value: str, allowed: list[str], what: str) -> list[str]:
    names = [part for part in value.split(",") if part]
    if not names:
        raise ValueError("no %s given" % what)
    for name in names:
        if name not in allowed:
            raise ValueError("unknown %s '%s' (expected one of: %s)" % (what, name, ", ".join(allowed)))
    return names


def build_user_args(scenarios: list[str], profiles: list[str], seconds: float | None, warmup: float | None,
                    sustained_minutes: float | None, screenshots: bool = False) -> list[str]:
    """App user args (after `--`). Sustained mode and scenarios are exclusive (the app enforces it too)."""
    args = ["--render-bench"]
    if sustained_minutes is not None:
        args.append("--bench-sustained-minutes=%g" % sustained_minutes)
    else:
        args.append("--bench-scenarios=" + ",".join(scenarios))
    if profiles:
        args.append("--bench-profiles=" + ",".join(profiles))
    if seconds is not None:
        args.append("--bench-seconds=%g" % seconds)
    if warmup is not None:
        args.append("--bench-warmup-seconds=%g" % warmup)
    if screenshots:
        args.append("--bench-screenshots")  # one PNG per step after its timed window (visual checks)
    # Host-only: a shared desktop steals focus; the app ignores this flag on iOS.
    return args + [STORAGE_ARG, "--bench-quit", "--bench-ignore-focus"]


def validate(a) -> tuple[list[str], list[str]]:
    scenarios = split_names(a.scenario, SCENARIOS, "scenario") if a.scenario else []
    profiles = split_names(a.profile, REAL_PROFILES + LEGACY_PROFILES, "profile") if a.profile else []
    if a.sustained_minutes is not None and scenarios:
        raise ValueError("--scenario and --sustained-minutes are exclusive")
    if a.sustained_minutes is None and not scenarios:
        raise ValueError("give --scenario NAME[,NAME] or --sustained-minutes N")
    for flag, value in (("--seconds", a.seconds), ("--warmup-seconds", a.warmup_seconds),
                        ("--sustained-minutes", a.sustained_minutes)):
        if value is not None and value < 0:
            raise ValueError("%s must not be negative" % flag)
    return scenarios, profiles


def report_timestamp(path: Path) -> int:
    m = REPORT_RE.search(path.name)
    return int(m.group(1)) if m else -1


def new_reports(directory: Path, since_unix: int) -> list[Path]:
    """Reports in `directory` written at or after `since_unix` (seconds), oldest first."""
    if not directory.is_dir():
        return []
    found = [p for p in directory.rglob("render-bench-*.json") if report_timestamp(p) >= since_unix]
    return sorted(found, key=report_timestamp)


def load_report(path: Path) -> dict:
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return {}


def evidence_label(report: dict, host_run: bool) -> tuple[str, str]:
    """(evidence_class, note). A host run is HOST whatever the report says; a report that claims DEVICE on a
    Mac run is inconsistent and never relabeled as device evidence."""
    claimed = str(report.get("evidence", {}).get("platform_class", report.get("evidence_class", "UNKNOWN")))
    if host_run:
        note = "HOST run on the Mac: NOT device evidence"
        if claimed == "DEVICE":
            note += " (report claims DEVICE; inconsistent, ignore)"
        return "HOST", note
    ev = report.get("evidence", {})
    return claimed, "device report: build=%s target_device=%s acceptance=%s" % (
        ev.get("build"), ev.get("is_target_device"), ev.get("acceptance"))


def finish(report_path: Path, output: Path, host_run: bool) -> int:
    report = load_report(report_path)
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(report_path, output)
    evidence_class, note = evidence_label(report, host_run)
    print("report: %s -> %s" % (report_path, output))
    print("status: %s" % report.get("status"))
    print("evidence_class: %s (%s)" % (evidence_class, note))
    steps = report.get("steps", [])
    sustained = report.get("sustained")
    print("steps: %d%s" % (len(steps), ", sustained minutes: %d" % len(sustained.get("minutes", [])) if sustained else ""))
    return 0 if report.get("status") == "COMPLETED" else 1


def run_host(a, user_args: list[str], launch: Callable[[list[str], list[str], int], int],
             user_dir: Path) -> int:
    traces = user_dir / "traces"
    started = int(time.time()) - 1
    timeout = a.timeout or (int(a.sustained_minutes * 60) + 900 if a.sustained_minutes else DEFAULT_TIMEOUT_S)
    rc = launch([], user_args, timeout)
    found = new_reports(traces, started)
    if not found:
        print("error: Godot rc=%d and no render-bench report under %s" % (rc, traces), file=sys.stderr)
        return rc or 1
    return finish(found[-1], a.output, host_run=True)


def device_commands(device_id: str, bundle_id: str, user_args: list[str]) -> tuple[list[str], list[str]]:
    launch = ["xcrun", "devicectl", "device", "process", "launch", "--device", device_id, "--terminate-existing",
              bundle_id, "--"] + user_args
    pull = ["xcrun", "devicectl", "device", "copy", "from", "--device", device_id, "--domain-type",
            "appDataContainer", "--domain-identifier", bundle_id, "--source", "Documents/traces",
            "--destination", str(PULL_DIR)]
    return launch, pull


def run_device(a, user_args: list[str], run: Callable[[list[str], int], tuple[int, str]]) -> int:
    device_id = a.device_id or "<device-id>"
    bundle_id = a.bundle_id or "<bundle id>"
    launch, pull = device_commands(device_id, bundle_id, user_args)
    print("launch (installed Release build): " + " ".join(launch))
    print("pull   (Documents/traces):        " + " ".join(pull))
    if not a.run:
        print("NOT RUN: commands printed only. No device result exists until a report file is pulled.")
        return 0
    if not a.device_id or not a.bundle_id:
        print("error: --run needs --device-id and --bundle-id", file=sys.stderr)
        return 2
    started = int(time.time()) - 5
    rc, out = run(launch, 120)
    print(out)
    if rc != 0:
        print("error: launch failed (rc=%d); no report pulled" % rc, file=sys.stderr)
        return rc
    deadline = time.time() + (a.timeout or DEFAULT_TIMEOUT_S)
    while time.time() < deadline:
        time.sleep(POLL_S)
        run(pull, 180)
        found = new_reports(PULL_DIR, started)
        if found:
            return finish(found[-1], a.output, host_run=False)
        print("waiting for the report on the device ...")
    print("error: timed out; NO report was pulled, so no device run is claimed", file=sys.stderr)
    return 1


def cmd_render_bench(a, launch: Callable[[list[str], list[str], int], int], user_dir: Path,
                     run: Callable[[list[str], int], tuple[int, str]]) -> int:
    try:
        scenarios, profiles = validate(a)
    except ValueError as error:
        print("error: %s" % error, file=sys.stderr)
        return 2
    user_args = build_user_args(scenarios, profiles, a.seconds, a.warmup_seconds, a.sustained_minutes,
                                getattr(a, "screenshots", False))
    if a.device:
        return run_device(a, user_args, run)
    return run_host(a, user_args, launch, user_dir)


def add_parser(sub, handler) -> None:
    s = sub.add_parser("render-bench", help="representative render bench on the Mac (HOST evidence only) or device commands")
    s.add_argument("--scenario", default="", help="comma list: " + ", ".join(SCENARIOS))
    s.add_argument("--profile", default="", help="comma list of performance|balanced|detailed (or legacy scale_* / terrain_mesh_24|32 ablation names)")
    s.add_argument("--seconds", type=float, default=None, help="measure window per step in seconds (app default 10)")
    s.add_argument("--warmup-seconds", type=float, default=None, dest="warmup_seconds")
    s.add_argument("--sustained-minutes", type=float, default=None, dest="sustained_minutes",
                   help="sustained mode (mixed_world_10k x performance) instead of --scenario")
    s.add_argument("--output", type=Path, required=True, help="where the report JSON is copied")
    s.add_argument("--screenshots", action="store_true", help="save one PNG per step (user://traces/bench-shots)")
    s.add_argument("--timeout", type=int, default=0, help="hard limit in seconds (0 = derived default)")
    s.add_argument("--device", action="store_true", help="print the devicectl launch/pull commands (installed build)")
    s.add_argument("--run", action="store_true", help="with --device: execute them and poll for the report")
    s.add_argument("--device-id", default="", dest="device_id")
    s.add_argument("--bundle-id", default="", dest="bundle_id")
    s.set_defaults(fn=handler)
