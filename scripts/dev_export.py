"""Development signing and bounded iOS Xcode-project export."""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

import build_fingerprint
import godot_test

REPO = Path(__file__).resolve().parent.parent
APP = REPO / "app"
SIGNING_PATH = REPO / "config" / "local.signing.json"
IOS_EXPORT_PATH = REPO / "build" / "ios" / "WorldPainter.ipa"
EXPORT_TIMEOUT_S = 3600
GODOT = godot_test.GODOT

SIGNING_HELP = """config/local.signing.json (gitignored, never commit) format:
  {
    "team_id": "ABCDE12345",                        # required: 10-character Apple team ID
    "bundle_id": "com.example.worldpainterpoc"      # optional: overrides the preset bundle id
  }"""

# --- export-ios ------------------------------------------------------------------------
def load_signing(path: Path) -> tuple[dict, str]:
	if not path.is_file():
		return {}, "signing not configured: %s not found.\n%s" % (path, SIGNING_HELP)
	try:
		data = json.loads(path.read_text())
	except (OSError, ValueError):
		return {}, "invalid signing configuration: %s" % path
	if not isinstance(data, dict):
		return {}, "signing configuration must be an object"
	team = data.get("team_id", "")
	if not isinstance(team, str) or not re.fullmatch(r"[A-Z0-9]{10}", team):
		return {}, "signing not configured: team_id in %s must be a 10-character Apple team ID" % path
	bundle = data.get("bundle_id")
	if bundle is not None and not re.fullmatch(r"[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)+", str(bundle)):
		return {}, "invalid bundle_id %r in %s" % (bundle, path)
	return data, ""


def patch_ios_preset(text: str, values: dict[str, str]) -> str:
	"""Replaces `key=...` lines inside [preset.0.options]; every key must exist exactly once."""
	m = re.search(r"^\[preset\.0\.options\]\n(.*?)(?=^\[|\Z)", text, re.M | re.S)
	if not m:
		raise ValueError("export_presets.cfg has no [preset.0.options] section")
	section = m.group(1)
	for key, val in values.items():
		pat = re.compile(r"^%s=.*$" % re.escape(key), re.M)
		if len(pat.findall(section)) != 1:
			raise ValueError("preset option %s not found exactly once" % key)
		section = pat.sub(lambda _m: "%s=%s" % (key, val), section)
	return text[:m.start(1)] + section + text[m.end(1):]


def cmd_export_ios(a: argparse.Namespace) -> int:
	signing, err = load_signing(a.signing_config)
	if err:
		print("error: " + err, file=sys.stderr)
		return 2
	build_fingerprint.record()
	app_dir = godot_test.prepare_sandbox(a.sandbox) if a.sandbox else APP
	rc, output = godot_test.godot_import(app_dir)
	if rc != 0 or godot_test.import_errors(output):
		print(output, file=sys.stderr)
		return rc or 1
	preset = app_dir / "export_presets.cfg"
	original = preset.read_bytes()
	values = {
		"application/app_store_team_id": json.dumps(signing["team_id"]),
		"application/export_project_only": "true" if a.project_only else "false",
	}
	if signing.get("bundle_id"):
		values["application/bundle_identifier"] = json.dumps(signing["bundle_id"])
	try:
		patched = patch_ios_preset(original.decode("utf-8"), values)
	except ValueError as e:
		print("error: %s" % e, file=sys.stderr)
		return 2
	IOS_EXPORT_PATH.parent.mkdir(parents=True, exist_ok=True)
	mode = "--export-release" if a.release else "--export-debug"
	cmd = [GODOT, "--headless", "--path", str(app_dir), mode, "iOS", str(IOS_EXPORT_PATH)]
	rc = _run_export(preset, original, patched, cmd)
	artifact = IOS_EXPORT_PATH.with_suffix(".xcodeproj") if a.project_only else IOS_EXPORT_PATH
	if rc == 0 and not artifact.exists():
		print("error: Godot returned 0 but %s does not exist" % artifact, file=sys.stderr)
		rc = 1
	print("export-ios: %s (godot rc=%d, artifact %s)" % ("OK" if rc == 0 else "FAILED", rc, artifact))
	return rc




def _run_export(preset: Path, original: bytes, patched: str, cmd: list[str]) -> int:
	original_hash = hashlib.sha256(original).hexdigest()
	rc = 1
	try:
		preset.write_bytes(patched.encode("utf-8"))
		print("$ " + " ".join(cmd))
		try:
			rc = subprocess.run(cmd, stdin=subprocess.DEVNULL, timeout=EXPORT_TIMEOUT_S).returncode
		except subprocess.TimeoutExpired:
			print("error: export timed out after %ds" % EXPORT_TIMEOUT_S, file=sys.stderr)
			rc = 124
	finally:
		preset.write_bytes(original)
		restored = hashlib.sha256(preset.read_bytes()).hexdigest()
		if restored != original_hash:
			print("error: %s was NOT restored (sha256 %s != %s)" % (preset, restored, original_hash), file=sys.stderr)
			rc = rc or 3
		else:
			print("export_presets.cfg restored (sha256 %s)" % restored)
	return rc
