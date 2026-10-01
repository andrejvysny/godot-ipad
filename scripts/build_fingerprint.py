#!/usr/bin/env python3
"""Record source and native artifact hashes for an uncommitted development build."""
from __future__ import annotations

import hashlib
import json
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent


def digest_files(paths: list[Path]) -> tuple[str, dict[str, str]]:
    stream = hashlib.sha256()
    files: dict[str, str] = {}
    for path in sorted(paths):
        name = path.relative_to(REPO).as_posix()
        digest = hashlib.sha256(path.read_bytes()).hexdigest()
        files[name] = digest
        stream.update(name.encode() + b"\0" + bytes.fromhex(digest))
    return stream.hexdigest(), files


def record() -> dict[str, object]:
    sources: list[Path] = []
    for folder in ("app/src", "app/scenes", "app/assets", "native/ios_input/src", "scripts", "config"):
        sources.extend(path for path in (REPO / folder).rglob("*") if path.is_file()
                       and "__pycache__" not in path.parts and path.name != "local.signing.json"
                       and path.suffix not in (".uid", ".pyc"))
    sources.extend(REPO / name for name in ("app/project.godot", "app/export_presets.cfg"))
    source_digest, source_files = digest_files(sources)
    artifacts = [path for path in (REPO / "app/addons/wp_native_input/bin").rglob("*")
                 if path.is_file()]
    artifact_digest, artifact_files = digest_files(artifacts)
    result: dict[str, object] = {"source_sha256": source_digest,
                               "native_artifacts_sha256": artifact_digest}
    (REPO / "app/config/build_fingerprint.json").write_text(json.dumps(result, indent=2) + "\n")
    directory = REPO / "build"
    directory.mkdir(exist_ok=True)
    (directory / "build_fingerprint.json").write_text(json.dumps(
        {**result, "source_files": source_files, "native_artifacts": artifact_files}, indent=2) + "\n")
    return result


if __name__ == "__main__":
    print(json.dumps(record(), indent=2))
