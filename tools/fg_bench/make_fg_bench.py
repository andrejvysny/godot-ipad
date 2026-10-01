#!/usr/bin/env python3
"""Build the terrain-only fantasy-game valley bench project (no character, no game logic).

Copies ../fantasy-game into build/fg_ipad (gitignored), adds the bench scene and root script,
patches project settings for iOS (Vulkan, ETC2/ASTC, no mouse-from-touch emulation) and writes an
iOS export preset whose signing team comes from the ignored config/local.signing.json.
The fantasy-game repository itself is never modified.

    python3 tools/fg_bench/make_fg_bench.py [--renderer mobile|forward_plus]
    godot --headless --path build/fg_ipad --import
    godot --headless --path build/fg_ipad --export-release iOS ../fg_ios/FGBench.ipa
    xcodebuild -project build/fg_ios/FGBench.xcodeproj -scheme FGBench -configuration Release \\
      -sdk iphoneos -destination generic/platform=iOS -derivedDataPath build/fg_ios/dd \\
      CODE_SIGN_STYLE=Automatic CODE_SIGN_IDENTITY="Apple Development" -allowProvisioningUpdates build
"""
from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = ROOT.parent / "fantasy-game"
DEST = ROOT / "build" / "fg_ipad"
HERE = Path(__file__).resolve().parent
COPY_EXCLUDES = [".git", ".godot", ".claude", ".ruff_cache", "screenshots", "tools", "docs", "TODO.md", ".DS_Store"]
# Character and game-logic files never enter the exported pack.
EXPORT_EXCLUDES = ("scenes/*,scripts/main.gd,scripts/player.gd,scripts/camera_rig.gd,scripts/tree_occluder.gd,"
	"scripts/showroom.gd,scripts/campfire_fx.gd,scripts/camp_props.gd,character*,campfire*,wooden_lodge*,tree_stump*")
BUNDLE_ID = "sk.andrejvysny.fgbench"


def copy_project() -> None:
	DEST.mkdir(parents=True, exist_ok=True)
	cmd = ["rsync", "-a"] + [f"--exclude={e}" for e in COPY_EXCLUDES] + [f"{SOURCE}/", f"{DEST}/"]
	subprocess.run(cmd, check=True, stdin=subprocess.DEVNULL)
	bench = DEST / "bench"
	bench.mkdir(exist_ok=True)
	for name in ("bench_root.gd", "valley_bench.tscn"):
		shutil.copy2(HERE / name, bench / name)
	shutil.copy2(ROOT / "app" / "assets" / "thumbnails" / "app_icon.png", bench / "app_icon.png")


def patch_project(renderer: str) -> None:
	p = DEST / "project.godot"
	s = p.read_text()
	s = s.replace('run/main_scene="res://scenes/valley.tscn"', 'run/main_scene="res://bench/valley_bench.tscn"')
	s = s.replace('config/features=PackedStringArray("4.7", "Forward Plus")',
		'config/features=PackedStringArray("4.7", "Forward Plus")\nconfig/icon="res://bench/app_icon.png"', 1)
	s = s.replace("[physics]\n", "[input_devices]\n\npointing/emulate_mouse_from_touch=false\n\n[physics]\n", 1)
	# On iOS devicectl launch arguments reach the game as user args, so the renderer is a project setting.
	s = s.replace("[rendering]\n", "[rendering]\n\n"
		f'renderer/rendering_method.mobile="{renderer}"\n'
		'rendering_device/driver.ios="vulkan"\n'
		"textures/vram_compression/import_etc2_astc=true\n", 1)
	p.write_text(s)


def write_preset() -> None:
	team = json.loads((ROOT / "config" / "local.signing.json").read_text())["team_id"]
	preset = (ROOT / "app" / "export_presets.cfg").read_text().split("[preset.1]")[0]
	preset = preset.replace('iOS="iOS"\nmacOS="macOS"', 'iOS="iOS"')
	preset = re.sub(r'include_filter="[^"]*"', 'include_filter="*.json"', preset)
	preset = re.sub(r'exclude_filter="[^"]*"', f'exclude_filter="{EXPORT_EXCLUDES}"', preset)
	preset = preset.replace('export_path="../build/ios/WorldPainter.ipa"', 'export_path="../fg_ios/FGBench.ipa"')
	preset = preset.replace('application/app_store_team_id=""', f'application/app_store_team_id="{team}"')
	preset = re.sub(r'application/bundle_identifier="[^"]*"', f'application/bundle_identifier="{BUNDLE_ID}"', preset)
	preset = preset.replace("application/export_project_only=false", "application/export_project_only=true")
	preset = preset.replace('icons/icon_1024x1024="res://assets/thumbnails/app_icon.png"',
		'icons/icon_1024x1024="res://bench/app_icon.png"')
	(DEST / "export_presets.cfg").write_text(preset)


def main() -> None:
	ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
	ap.add_argument("--renderer", choices=["mobile", "forward_plus"], default="mobile")
	a = ap.parse_args()
	if not (SOURCE / "project.godot").exists():
		raise SystemExit(f"fantasy-game project not found at {SOURCE}")
	copy_project()
	patch_project(a.renderer)
	write_preset()
	print(f"bench project ready: {DEST} (renderer {a.renderer})")


if __name__ == "__main__":
	main()
