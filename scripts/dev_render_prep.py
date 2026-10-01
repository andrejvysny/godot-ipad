"""`dev.py prepare-render-assets`: bench generator, render-asset preparation tool, texture import.

Every Godot run is bounded (godot_test.run: hard timeout, stdin=/dev/null). `--check` repeats the
whole pipeline in a temporary copy of app/ and compares every committed output byte-for-byte.
"""
from __future__ import annotations

import filecmp
import shutil
import sys
from pathlib import Path

import godot_test

REPO = Path(__file__).resolve().parent.parent
APP = REPO / "app"
CHECK_DIR = REPO / "build" / "render_prep_check"
GODOT = godot_test.GODOT
STEP_TIMEOUT_S = 900
MANIFESTS = {
    "poc": "res://devtools/render_prep/poc_nature.json",
    "bench": "res://devtools/render_prep/bench_nature.json",
}
# Committed outputs compared by --check (relative to app/).
OUTPUT_DIRS = {
    "poc": ["assets/render_assets"],
    "bench": ["assets/bench"],
}


def selected(catalog: str) -> list[str]:
    return ["poc", "bench"] if catalog == "all" else [catalog]


def _godot_script(app_dir: Path, script: str, args: list[str]) -> tuple[int, str]:
    cmd = [GODOT, "--headless", "--path", str(app_dir), "--script", script]
    if args:
        cmd += ["--"] + args
    return godot_test.run(cmd, STEP_TIMEOUT_S)


def _step(title: str, rc: int, out: str, show: bool = False) -> bool:
    ok = rc == 0 and "SCRIPT ERROR" not in out
    print("[%s] %s" % ("ok" if ok else "FAIL", title))
    if not ok or show:
        print(out.strip())
    return ok


def run_pipeline(app_dir: Path, names: list[str]) -> bool:
    if "bench" in names:
        rc, out = _godot_script(app_dir, "res://devtools/generate_bench_assets.gd", [])
        if not _step("generate bench assets", rc, out):
            return False
    for name in names:
        rc, out = _godot_script(app_dir, "res://devtools/prepare_render_assets.gd", [MANIFESTS[name]])
        if not _step("prepare %s (pass 1)" % name, rc, out, show=True):
            return False
    rc, out = godot_test.godot_import(app_dir)
    errors = godot_test.import_errors(out)
    if rc != 0 or errors:
        print("[FAIL] godot --import rc=%d" % rc)
        print("\n".join(errors[:40]))
        return False
    print("[ok] godot --import")
    for name in names:
        rc, out = _godot_script(app_dir, "res://devtools/prepare_render_assets.gd", [MANIFESTS[name], "--require-import"])
        if not _step("verify %s (pass 2, textures imported)" % name, rc, out):
            return False
    return True


def _files(root: Path) -> dict[str, Path]:
    return {str(p.relative_to(root)): p for p in sorted(root.rglob("*")) if p.is_file()}


def compare_trees(committed: Path, regenerated: Path) -> list[str]:
    """Differences between two directories (missing, extra, changed bytes)."""
    a, b = _files(committed), _files(regenerated)
    diffs = ["missing after regeneration: %s" % k for k in sorted(a.keys() - b.keys())]
    diffs += ["not committed: %s" % k for k in sorted(b.keys() - a.keys())]
    diffs += ["differs: %s" % k for k in sorted(a.keys() & b.keys()) if not filecmp.cmp(a[k], b[k], shallow=False)]
    return diffs


def _copy_app(dest: Path) -> None:
    shutil.rmtree(dest.parent, ignore_errors=True)
    dest.parent.mkdir(parents=True, exist_ok=True)
    rsync = shutil.which("rsync")
    if rsync:
        rc, out = godot_test.run([rsync, "-a", f"{APP}/", f"{dest}/"], 600)
        if rc != 0:
            raise RuntimeError("copy failed: " + out)
    else:
        shutil.copytree(APP, dest)


def check(names: list[str]) -> int:
    dest = CHECK_DIR / "app"
    _copy_app(dest)
    # The generator reads/writes ../build/render_prep_inputs relative to the project: inside the copy
    # that is build/render_prep_check/build/, never the repository's own build directory.
    if not run_pipeline(dest, names):
        return 1
    bad: list[str] = []
    for name in names:
        for rel in OUTPUT_DIRS[name]:
            bad += ["%s/%s" % (rel, d) for d in compare_trees(APP / rel, dest / rel)]
    if bad:
        print("render-assets --check: committed outputs differ from a fresh regeneration:")
        print("\n".join("  " + d for d in bad[:60]))
        return 1
    print("render-assets --check: no differences")
    return 0


def main(catalog: str, do_check: bool) -> int:
    names = selected(catalog)
    if do_check:
        return check(names)
    return 0 if run_pipeline(APP, names) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "all", "--check" in sys.argv))
