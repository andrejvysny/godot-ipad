#!/usr/bin/env python3
"""Validate a .worldpoc package or a generation directory (docs/world-format.md).

Usage: python3 scripts/validate_world.py PATH [--json] [--app-dir DIR]
Exit codes: 0 valid, 1 invalid, 2 usage, I/O or internal validator error.
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


def format_report(r: dict) -> str:
	lines = [
		"World: %s (%s)" % (r["path"], r["kind"]),
		"Result: %s" % ("VALID" if r["valid"] else "INVALID"),
		"Objects: %d" % r["object_count"],
		"Authored content hash: %s" % (r["authored_content_hash"] or "(not computed)"),
	]
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


def main(argv: list[str] | None = None) -> int:
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
