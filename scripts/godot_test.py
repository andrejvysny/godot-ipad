#!/usr/bin/env python3
"""Run the Godot test suite with a hard timeout, optionally in an isolated copy of app/.

Every invocation copies app/ to a unique build/test_sandboxes/NAME-<suffix>/app and uses
a unique WorldPainterTests/NAME-<suffix> user directory, even with the same sandbox label. Godot hangs forever if a script errors before
quit(), so every invocation is bounded and stdin is /dev/null.

Usage: python3 scripts/godot_test.py [--sandbox NAME] [--suite unit|integration] [--filter TEXT]
       [--rendered [--driver metal|vulkan|...]]

--rendered runs the tests in a window (real renderer, not --headless) so GPU readback tests run;
the filter defaults to "gpu" and the run fails if any test printed "NOT RUN".
"""
from __future__ import annotations

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
APP = REPO / "app"
GODOT = shutil.which("godot") or "/Applications/Godot.app/Contents/MacOS/Godot"
IMPORT_TIMEOUT_S = 300
TEST_TIMEOUT_S = 900


def run(args: list[str], timeout: int, cwd: Path | None = None) -> tuple[int, str]:
    try:
        r = subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                           stdin=subprocess.DEVNULL, cwd=cwd)
        return r.returncode, r.stdout + r.stderr
    except subprocess.TimeoutExpired as e:
        out = (e.stdout or b"").decode(errors="replace") + (e.stderr or b"").decode(errors="replace")
        return 124, out + f"\nTIMEOUT after {timeout}s: {' '.join(args)}\n"


def prepare_sandbox(name: str) -> Path:
    dest = REPO / "build" / "test_sandboxes" / name / "app"
    dest.parent.mkdir(parents=True, exist_ok=True)
    rsync = shutil.which("rsync")
    if rsync:
        rc, out = run([rsync, "-a", "--delete", "--exclude", ".godot/", f"{APP}/", f"{dest}/"], 300)
        if rc != 0:
            raise RuntimeError("sandbox copy failed: " + out)
    else:
        if dest.exists():
            shutil.rmtree(dest)
        shutil.copytree(APP, dest, ignore=shutil.ignore_patterns(".godot"))
    return dest


def godot_import(app_dir: Path) -> tuple[int, str]:
    # Godot 4.7.2 headless --import on a fresh .godot/ finishes importing, then segfaults
    # (signal 11) during editor shutdown. A second pass is clean; a second failure is real.
    rc, out = run([GODOT, "--headless", "--path", str(app_dir), "--import"], IMPORT_TIMEOUT_S)
    if rc in (-11, 139) and not import_errors(out):
        rc, out = run([GODOT, "--headless", "--path", str(app_dir), "--import"], IMPORT_TIMEOUT_S)
    return rc, out


def import_errors(output: str) -> list[str]:
    return [line for line in output.splitlines()
            if "ERROR" in line or "Parse Error" in line]


def godot_tests(app_dir: Path, suite: str = "", filt: str = "", rendered: bool = False,
                driver: str = "") -> tuple[int, str]:
    args = [GODOT] + ([] if rendered else ["--headless"]) + ["--path", str(app_dir)]
    if driver:
        args += ["--rendering-method", "mobile", "--rendering-driver", driver]
    elif rendered:
        args += ["--rendering-method", "mobile"]
    args += ["--script", "res://tests/run_tests.gd", "--"]
    if suite:
        args.append(f"--suite={suite}")
    if filt:
        args.append(f"--filter={filt}")
    return run(args, TEST_TIMEOUT_S)


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--sandbox", default="")
    p.add_argument("--suite", default="")
    p.add_argument("--filter", default="")
    p.add_argument("--no-import", action="store_true")
    p.add_argument("--rendered", action="store_true", help="windowed run (GPU tests); fails on NOT RUN")
    p.add_argument("--driver", default="", help="rendering driver, e.g. metal or vulkan")
    a = p.parse_args()
    # Each invocation owns both its import cache and writable user://, including same-name runs.
    if a.sandbox and (Path(a.sandbox).name != a.sandbox or a.sandbox in (".", "..")):
        p.error("sandbox must be a plain name")
    base = REPO / "build" / "test_sandboxes"
    base.mkdir(parents=True, exist_ok=True)
    invocation = Path(tempfile.mkdtemp(prefix=(a.sandbox or "tests") + "-", dir=base))
    app_dir = prepare_sandbox(invocation.name)
    if a.no_import:
        cache = APP / ".godot"
        if not cache.is_dir():
            p.error("--no-import requires an existing app/.godot import cache")
        shutil.copytree(cache, app_dir / ".godot", dirs_exist_ok=True)
    (app_dir / "override.cfg").write_text(
        '[application]\nconfig/use_custom_user_dir=true\n'
        f'config/custom_user_dir_name="WorldPainterTests/{invocation.name}"\n')
    if not a.no_import:
        rc, out = godot_import(app_dir)
        errors = import_errors(out)
        if rc != 0 or errors:
            print(f"godot --import rc={rc}")
            print("\n".join(errors[:80]))
            return rc or 1
    filt = a.filter or ("gpu" if a.rendered else "")
    if a.rendered or a.driver:
        rc, out = godot_tests(app_dir, a.suite, filt, True, a.driver)
    else:
        rc, out = godot_tests(app_dir, a.suite, filt)
    print(out)
    if a.rendered and "NOT RUN" in out:
        print("rendered run: output contains NOT RUN")
        return rc or 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
