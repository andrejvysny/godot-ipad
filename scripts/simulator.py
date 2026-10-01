#!/usr/bin/env python3
"""Build an isolated x86_64 iPad Simulator app using the pinned engine template."""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import tarfile
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
TERRAIN_COMMIT = "0077405b52e353c5e5dc3a094e7ede49833ba6fe"
CPP_COMMIT = "6388e26dd8a42071f65f764a3ef3d9523dda3d6e"
SOURCE = REPO / "build/simulator-source" / ("Terrain3D-" + TERRAIN_COMMIT)
PROJECT = REPO / "build/ios-simulator"
FRAMEWORK = Path("WorldPainter/dylibs/addons/terrain_3d/bin/libterrain.ios.debug.universal.framework")
BINARY = "libterrain.ios.debug.universal"


def fetch_archive(repository: str, commit: str, directory: Path) -> None:
    archive = REPO / "build/simulator-source" / (repository.rsplit("/", 1)[-1] + ".tar.gz")
    archive.parent.mkdir(parents=True, exist_ok=True)
    url = f"https://github.com/{repository}/archive/{commit}.tar.gz"
    with urllib.request.urlopen(url, timeout=60) as response, archive.open("wb") as output:
        shutil.copyfileobj(response, output)
    directory.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as contents:
        contents.extractall(directory, filter="data")


def fetch_sources() -> None:
    if not (SOURCE / "SConstruct").is_file():
        fetch_archive("TokisanGames/Terrain3D", TERRAIN_COMMIT, SOURCE.parent)
    cpp = SOURCE / "godot-cpp"
    if not (cpp / "SConstruct").is_file():
        staging = SOURCE.parent / "cpp-staging"
        fetch_archive("godotengine/godot-cpp", CPP_COMMIT, staging)
        shutil.copytree(staging / ("godot-cpp-" + CPP_COMMIT), cpp, dirs_exist_ok=True)


def run(command: list[str], log: Path, cwd: Path = REPO, timeout: int = 600) -> None:
    with log.open("w") as output:
        result = subprocess.run(command, cwd=cwd, stdin=subprocess.DEVNULL,
                                stdout=output, stderr=subprocess.STDOUT, timeout=timeout)
    if result.returncode:
        raise RuntimeError(f"Command failed ({result.returncode}); see {log}")


def prepare(build_terrain: bool) -> None:
    library = SOURCE / "project/addons/terrain_3d/bin/libterrain.ios.debug.x86_64.dylib"
    if build_terrain:
        run(["uvx", "--from", "scons==4.10.1", "scons", "platform=ios", "arch=x86_64",
             "ios_simulator=yes", "target=template_debug", "ios_min_version=18.5", "-j8"],
            REPO / "build/simulator-terrain.log", SOURCE)
    if not library.is_file():
        raise RuntimeError("Pinned Terrain3D simulator build missing; see README simulator setup")
    original = REPO / "build/ios"
    if not (original / "WorldPainter.xcodeproj").is_dir():
        raise RuntimeError("Run scripts/dev.py export-ios --project-only first")
    shutil.copytree(original, PROJECT, dirs_exist_ok=True,
                    ignore=shutil.ignore_patterns("DerivedData", "SimulatorDerivedData", "DerivedDataX86"))
    destination = PROJECT / FRAMEWORK / BINARY
    shutil.copy2(library, destination)
    subprocess.run(["install_name_tool", "-id", f"@rpath/{FRAMEWORK.name}/{BINARY}",
                    str(destination)], check=True, stdin=subprocess.DEVNULL)
    identity = {"terrain_commit": TERRAIN_COMMIT, "godot_cpp_commit": CPP_COMMIT,
                "simulator_arch": "x86_64",
                "terrain_simulator_sha256": hashlib.sha256(destination.read_bytes()).hexdigest(),
                "development_preview": True, "hardware_gate": "NOT RUN"}
    (PROJECT / "simulator-build.json").write_text(json.dumps(identity, indent=2) + "\n")


def build() -> None:
    run(["xcodebuild", "-project", str(PROJECT / "WorldPainter.xcodeproj"),
         "-scheme", "WorldPainter", "-configuration", "Debug",
         "-destination", "generic/platform=iOS Simulator", "-derivedDataPath",
         str(PROJECT / "DerivedDataX86"), "ARCHS=x86_64", "ONLY_ACTIVE_ARCH=YES",
         "CODE_SIGNING_ALLOWED=NO", "build"], PROJECT / "build.log")


def launch(device: str) -> None:
    app = PROJECT / "DerivedDataX86/Build/Products/Debug-iphonesimulator/WorldPainter.app"
    run(["xcrun", "simctl", "install", device, str(app)], PROJECT / "install.log")
    run(["xcrun", "simctl", "launch", "--terminate-running-process", device,
         "sk.andrejvysny.worldpainterpoc"], PROJECT / "launch.log")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-terrain", action="store_true")
    parser.add_argument("--fetch-sources", action="store_true")
    parser.add_argument("--device", help="Booted iOS 18.5 simulator UUID; install and launch after build")
    args = parser.parse_args()
    try:
        if args.fetch_sources:
            fetch_sources()
        prepare(args.build_terrain)
        build()
        if args.device:
            launch(args.device)
    except (OSError, RuntimeError, subprocess.SubprocessError) as error:
        print(error)
        return 1
    print(f"Simulator build ready: {PROJECT}; development preview, G1 NOT RUN")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
