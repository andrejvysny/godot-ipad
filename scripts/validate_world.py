#!/usr/bin/env python3
"""Validate a .worldpoc package or a generation directory (docs/world-format.md).

Usage: python3 scripts/validate_world.py PATH [--json] [--app-dir DIR]
       python3 scripts/validate_world.py migrate SRC DEST [--package OUT.worldpoc] [--app-dir DIR]
Schemas 2, 3 and 4 are accepted. `migrate` converts a schema 2/3 generation directory or .worldpoc package SRC
into the new schema 4 generation directory DEST (ADR 0014 D9); DEST must not exist.
Exit codes: 0 valid, 1 invalid (or source not migratable), 2 usage, I/O or internal validator error.
"""
from __future__ import annotations

import argparse
import json
import sys
import traceback
from typing import TextIO
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import worldpoc_format as wf  # noqa: E402
import worldpoc_migrate as wm  # noqa: E402
import shutil  # noqa: E402


def format_report(r: dict) -> str:
	lines = [
		"World: %s (%s)" % (r["path"], r["kind"]),
		"Result: %s" % ("VALID" if r["valid"] else "INVALID"),
		"Objects: %d" % r["object_count"],
		"Authored content hash: %s" % (r["authored_content_hash"] or "(not computed)"),
	]
	if r.get("availability"):
		lines.append("Availability (%d unavailable, not an error):" % len(r["availability"]))
		lines += ["  - " + a for a in r["availability"]]
	if r["errors"]:
		lines.append("Errors (%d):" % len(r["errors"]))
		lines += ["  - " + e for e in r["errors"]]
	if r["warnings"]:
		lines.append("Warnings (%d):" % len(r["warnings"]))
		lines += ["  - " + w for w in r["warnings"]]
	return "\n".join(lines)


def emit(text: str, stream: TextIO | None = None) -> None:
	"""Print so that no path or message can raise UnicodeEncodeError (e.g. undecodable file names)."""
	stream = stream or sys.stdout
	enc = getattr(stream, "encoding", None) or "utf-8"
	print(text.encode(enc, "backslashreplace").decode(enc), file=stream)


def migrate_main(argv: list[str]) -> int:
	p = argparse.ArgumentParser(prog="validate_world.py migrate", description="Migrate a schema 2/3 world to schema 4.")
	p.add_argument("src", type=Path, help="schema 2/3 generation directory or .worldpoc file")
	p.add_argument("dest", type=Path, help="new schema 4 generation directory (must not exist)")
	p.add_argument("--package", type=Path, help="also write the result as a .worldpoc package")
	p.add_argument("--app-dir", type=Path, default=wf.APP_DIR, help="project providing the trusted catalog")
	a = p.parse_args(argv)
	if not a.src.exists():
		emit("error: '%s' does not exist" % a.src, sys.stderr)
		return 2
	if a.dest.exists() or (a.package is not None and a.package.exists()):
		emit("error: destination already exists", sys.stderr)
		return 2
	tmp: Path | None = None
	try:
		src = a.src
		if not a.src.is_dir():
			tmp, errors = wf.safe_extract(a.src)
			if tmp is None:
				emit("error: '%s' is not a valid package: %s" % (a.src, "; ".join(errors[:3])), sys.stderr)
				return 1
			src = tmp
		manifest = wm.migrate(src, a.dest, a.app_dir)
		if a.package is not None:
			wf.write_package(a.dest, a.package)
	except wm.MigrationError as e:
		emit("error: %s" % e, sys.stderr)
		return 1
	except (OSError, KeyError, wf.FormatError) as e:
		emit("error: cannot migrate '%s': %s" % (a.src, e), sys.stderr)
		return 2
	finally:
		if tmp is not None:
			shutil.rmtree(tmp, ignore_errors=True)
	emit("Migrated %s -> %s (schema 4)\nAuthored content hash: %s" % (a.src, a.dest, manifest["authored_content_hash"]))
	return 0


def main(argv: list[str] | None = None) -> int:
	argv = sys.argv[1:] if argv is None else argv
	if argv and argv[0] == "migrate":
		return migrate_main(argv[1:])
	p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	p.add_argument("path", type=Path, help=".worldpoc file or generation directory")
	p.add_argument("--json", action="store_true", help="print a JSON report")
	p.add_argument("--app-dir", type=Path, default=wf.APP_DIR, help="project providing the trusted catalog")
	a = p.parse_args(argv)
	if not a.path.exists():
		emit("error: '%s' does not exist" % a.path, sys.stderr)
		return 2
	try:
		result = wf.validate_path(a.path, a.app_dir)
	except (OSError, wf.FormatError, KeyError) as e:
		emit("error: cannot validate '%s': %s" % (a.path, e), sys.stderr)
		return 2
	except Exception:  # a validator bug must never look like an ordinary INVALID (exit 1)
		emit("error: internal validator failure on '%s':\n%s" % (a.path, traceback.format_exc()), sys.stderr)
		return 2
	emit(json.dumps(result, indent=2) if a.json else format_report(result))
	return 0 if result["valid"] else 1


if __name__ == "__main__":
	sys.exit(main())
