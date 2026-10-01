#!/usr/bin/env python3
"""World Painter PoC developer wrapper (spec §5). Every command exits nonzero on failure.

  doctor [--strict]          environment, pinned hashes, fixtures, config sync, secrets
  test                       Godot import + GDScript suites, then Python unittest
  run-mac                    launch the app windowed on this Mac
  export-ios                 iOS export (needs config/local.signing.json)
  validate-world PATH        validate a .worldpoc or generation directory
  open-consumer PATH         validate, then open in res://scenes/mac_consumer.tscn
  build-native               build the native input bridge (native/ios_input/build.sh)
  fixtures [--check]         regenerate or byte-check bundled fixtures
  catalog-hash               print the trusted catalog content hash
  sync-config                copy config/poc_defaults.json to app/config/
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPTS))
import generate_fixtures  # noqa: E402
import godot_test  # noqa: E402
import validate_world  # noqa: E402
import worldpoc_format as wf  # noqa: E402
from dev_export import SIGNING_HELP, cmd_export_ios, load_signing, patch_ios_preset

REPO = SCRIPTS.parent
APP = REPO / "app"
LOCK_PATH = REPO / "config" / "toolchain.lock.json"
ENV_PATH = REPO / "docs" / "evidence" / "environment.json"
SIGNING_PATH = REPO / "config" / "local.signing.json"
GODOT = godot_test.GODOT
TEMPLATES_ROOT = Path.home() / "Library" / "Application Support" / "Godot" / "export_templates"
IOS_EXPORT_PATH = REPO / "build" / "ios" / "WorldPainter.ipa"
EXPORT_TIMEOUT_S = 3600
SECRET_PATTERNS = re.compile(r"(\.mobileprovision|\.p12|\.cer|(^|/)local\.signing\.json|(^|/)export_credentials\.cfg)$")
REQUIRED_FILES = [
	".gitignore", "CLAUDE.md", "config/toolchain.lock.json", "config/poc_defaults.json", "app/project.godot",
	"app/export_presets.cfg", "app/scenes/editor_main.tscn", "app/assets/catalog.json", "app/tests/run_tests.gd",
	"app/addons/terrain_3d/terrain.gdextension", "scripts/dev.py", "scripts/validate_world.py",
	"scripts/generate_fixtures.py", "docs/world-format.md", "docs/evidence/environment.json",
	"app/fixtures/flat/manifest.json", "app/fixtures/gentle_hills/manifest.json",
]
# Deliverables of work packages still in progress: missing -> PENDING, not a host failure.
PENDING_FILES = [
	"README.md", "app/scenes/input_lab.tscn", "app/scenes/mac_consumer.tscn", "docs/device-test-checklist.md",
	"docs/input-contract.md", "docs/decisions/0001-platform-baseline.md", "native/ios_input",
]
# Spec §2.2 G0 fields every lock/evidence file must fill. The spec's single rendering_driver may be
# split into the configured driver and the driver measured active on a device.
REQUIRED_EVIDENCE_KEYS = (
	"godot_version", "godot_commit", "export_template_sha256", "terrain3d_revision", "terrain3d_binary_sha256",
	"native_bridge_revision", "xcode_version", "ios_sdk_version", "ipados_version", "ipad_model", "pencil_model",
	"rendering_method",
)
RENDERING_DRIVER_KEYS = (("rendering_driver",), ("rendering_driver_configured", "rendering_driver_active"))
NATIVE_GDEXTENSION = APP / "addons" / "wp_native_input" / "wp_native_input.gdextension"



def run(args: list[str], timeout: int = 60, cwd: Path | None = None) -> tuple[int, str]:
	try:
		r = subprocess.run(args, capture_output=True, text=True, timeout=timeout, stdin=subprocess.DEVNULL, cwd=cwd)
		return r.returncode, (r.stdout + r.stderr).strip()
	except FileNotFoundError:
		return 127, "not found: %s" % args[0]
	except subprocess.TimeoutExpired:
		return 124, "TIMEOUT after %ds: %s" % (timeout, " ".join(args))


def load_json(path: Path) -> dict:
	try:
		return json.loads(path.read_text())
	except (OSError, ValueError):
		return {}


# --- doctor ----------------------------------------------------------------------------
class Report:
	FAILING = {"FAIL"}
	STRICT_FAILING = {"FAIL", "NOT_RUN", "PENDING"}

	def __init__(self) -> None:
		self.rows: list[tuple[str, str, str]] = []

	def add(self, status: str, name: str, detail: str) -> None:
		self.rows.append((status, name, detail))
		print("[%-7s] %-24s %s" % (status, name, detail))

	def exit_code(self, strict: bool) -> int:
		bad = self.STRICT_FAILING if strict else self.FAILING
		return 1 if any(s in bad for s, _, _ in self.rows) else 0


def _doctor_godot(r: Report, lock: dict) -> None:
	rc, out = run([GODOT, "--version"], timeout=60)
	version = out.splitlines()[-1].strip() if out else ""
	want = lock.get("godot_version", "")
	commit = lock.get("godot_commit", "")
	if rc != 0:
		r.add("FAIL", "godot", "%s: %s" % (GODOT, out))
	elif not want or not re.fullmatch(r"[0-9a-f]{40}", str(commit)):
		r.add("FAIL", "godot", "lock godot_version %r / godot_commit %r not recorded" % (want, commit))
	elif not version.startswith(want) or commit[:9] not in version:
		r.add("FAIL", "godot", "%s reports %s; lock wants %s @ %s" % (GODOT, version, want, commit[:9]))
	else:
		r.add("OK", "godot", "%s %s" % (GODOT, version))


def _doctor_templates(r: Report, lock: dict) -> None:
	tdir = TEMPLATES_ROOT / lock.get("export_templates", {}).get("version_dir", "?")
	for name, want in sorted(lock.get("export_template_sha256", {}).items()):
		path = tdir / name
		if not path.is_file():
			r.add("FAIL", "template " + name, "missing: %s" % path)
			continue
		got = wf.sha256_file(path)
		r.add("OK" if got == want else "FAIL", "template " + name, "sha256 %s%s" % (got, "" if got == want else " != lock " + want))


def _doctor_xcode(r: Report, lock: dict) -> None:
	rc, out = run(["xcodebuild", "-version"])
	m = re.search(r"Xcode (\S+)\s+Build version (\S+)", out)
	if rc != 0 or not m:
		r.add("FAIL", "xcode", out or "xcodebuild unavailable")
	else:
		got = "%s (%s)" % m.groups()
		r.add("OK" if got == lock.get("xcode_version") else "WARN", "xcode", "%s (lock %s)" % (got, lock.get("xcode_version")))
	rc, out = run(["xcrun", "--show-sdk-version", "--sdk", "iphoneos"])
	if rc != 0:
		r.add("FAIL", "ios sdk", out)
	else:
		r.add("OK" if out == lock.get("ios_sdk_version") else "WARN", "ios sdk", "%s (lock %s)" % (out, lock.get("ios_sdk_version")))


def _connected_ipads() -> tuple[list[str], str]:
	fd, name = tempfile.mkstemp(suffix=".json")
	os.close(fd)
	tmp = Path(name)
	rc, out = run(["xcrun", "devicectl", "list", "devices", "--json-output", str(tmp)], timeout=90)
	data = load_json(tmp)
	tmp.unlink(missing_ok=True)
	if rc != 0 or not data:
		return [], "devicectl failed: %s" % out[-200:]
	ipads = []
	for d in data.get("result", {}).get("devices", []):
		hp = d.get("hardwareProperties", {})
		if hp.get("deviceType") == "iPad" or str(hp.get("productType", "")).startswith("iPad"):
			ipads.append("%s %s iPadOS %s" % (hp.get("marketingName"), hp.get("productType"),
				d.get("deviceProperties", {}).get("osVersionNumber")))
	return ipads, ""


def _doctor_devices(r: Report) -> None:
	ipads, err = _connected_ipads()
	if err:
		r.add("NOT_RUN", "ipad", err)
	elif not ipads:
		r.add("NOT_RUN", "ipad", "no iPad paired/connected; device gates stay NOT RUN")
	else:
		r.add("OK", "ipad", "; ".join(ipads))
	rc, out = run(["security", "find-identity", "-v", "-p", "codesigning"])
	m = re.search(r"(\d+) valid identities found", out)
	count = int(m.group(1)) if m else 0
	r.add("OK" if count > 0 else "PENDING", "codesign identities", "%d valid identities" % count)
	if SIGNING_PATH.is_file():
		r.add("OK", "signing config", str(SIGNING_PATH.relative_to(REPO)))
	else:
		r.add("PENDING", "signing config", "config/local.signing.json missing (export-ios will refuse)")


def _doctor_binaries(r: Report, lock: dict) -> None:
	for rel, want in sorted(lock.get("terrain3d_binary_sha256", {}).items()):
		path = APP / rel
		if not path.is_file():
			r.add("FAIL", "terrain3d binary", "missing: %s" % rel)
			continue
		got = wf.sha256_file(path)
		r.add("OK" if got == want else "FAIL", "terrain3d binary", "%s %s" % (Path(rel).name, "ok" if got == want else "sha256 %s != lock" % got))
	_doctor_native_bridge(r)
	for tool in ("uvx", "scons"):
		path = shutil.which(tool)
		r.add("OK" if path else "WARN", tool, path or "not on PATH")
	ok = sys.version_info >= (3, 10)
	r.add("OK" if ok else "FAIL", "python", "%s (need >= 3.10)" % sys.version.split()[0])


def native_bridge_artifacts(gdextension: Path = NATIVE_GDEXTENSION) -> list[str]:
	"""Every res:// library and dependency the bridge .gdextension references (all platforms, both builds)."""
	text = gdextension.read_text()
	return sorted(set(re.findall(r'"(res://[^"]+)"', text)))


def _doctor_native_bridge(r: Report, gdextension: Path = NATIVE_GDEXTENSION) -> None:
	if not gdextension.is_file():
		r.add("PENDING", "native bridge", "missing %s" % gdextension.relative_to(REPO))
		return
	for res in native_bridge_artifacts(gdextension):
		present = (APP / res[len("res://"):]).exists()
		r.add("OK" if present else "PENDING", "native bridge", "%s %s" % ("present" if present else "MISSING", Path(res).name))


def _doctor_repo(r: Report, lock: dict) -> None:
	bad = generate_fixtures.check()
	r.add("FAIL" if bad else "OK", "fixtures --check", "differ: " + ", ".join(bad) if bad else "byte-identical")
	for name, info in sorted(lock.get("fixtures", {}).items()):
		m = load_json(APP / "fixtures" / name / "manifest.json")
		ok = m.get("authored_content_hash") == info.get("authored_content_hash")
		r.add("OK" if ok else "FAIL", "fixture " + name, "authored hash %s" % m.get("authored_content_hash"))
	a, b = REPO / "config" / "poc_defaults.json", APP / "config" / "poc_defaults.json"
	same = a.is_file() and b.is_file() and a.read_bytes() == b.read_bytes()
	r.add("OK" if same else "FAIL", "config sync", "identical" if same else "differs; run: python3 scripts/dev.py sync-config")
	missing = [f for f in REQUIRED_FILES if not (REPO / f).exists()]
	r.add("FAIL" if missing else "OK", "required files", "missing: " + ", ".join(missing) if missing else "%d present" % len(REQUIRED_FILES))
	pending = [f for f in PENDING_FILES if not (REPO / f).exists()]
	r.add("PENDING" if pending else "OK", "deliverables", "not yet present: " + ", ".join(pending) if pending else "all present")
	rc, out = run(["git", "-C", str(REPO), "ls-files", "--cached", "--others", "--exclude-standard"], timeout=120)
	if rc != 0:
		r.add("FAIL", "secrets scan", "git ls-files failed: %s" % out[-200:])
	else:
		exposed = [f for f in out.splitlines() if SECRET_PATTERNS.search(f)]
		r.add("FAIL" if exposed else "OK", "secrets scan", "NOT gitignored: " + ", ".join(exposed) if exposed else "no unignored signing files")


def _placeholders(obj: object, prefix: str = "") -> list[tuple[str, str]]:
	if isinstance(obj, dict):
		return [x for k, v in obj.items() for x in _placeholders(v, prefix + "." + k if prefix else k)]
	if isinstance(obj, list):
		return [x for i, v in enumerate(obj) for x in _placeholders(v, "%s[%d]" % (prefix, i))]
	return [(prefix, obj)] if isinstance(obj, str) and obj.startswith(("RECORD_", "NOT_RUN")) else []


def _is_blank(v: object) -> bool:
	if isinstance(v, str):
		return v.strip() == ""
	if isinstance(v, (dict, list)):
		return not v or any(_is_blank(x) for x in (v.values() if isinstance(v, dict) else v))
	return v is None


def missing_evidence_fields(data: dict) -> list[str]:
	"""Required §2.2 fields that are absent or empty (a NOT_RUN or RECORD_ value is reported separately)."""
	missing = [k for k in REQUIRED_EVIDENCE_KEYS if _is_blank(data.get(k))]
	if not any(all(not _is_blank(data.get(k)) for k in group) for group in RENDERING_DRIVER_KEYS):
		missing.append("rendering_driver (or rendering_driver_configured + rendering_driver_active)")
	return missing


def _doctor_evidence(r: Report) -> None:
	for path in (LOCK_PATH, ENV_PATH):
		data = load_json(path)
		rel = str(path.relative_to(REPO)) if path.is_relative_to(REPO) else str(path)
		if not isinstance(data, dict) or not data:
			r.add("FAIL", rel, "missing or invalid JSON")
			continue
		missing = missing_evidence_fields(data)
		if missing:
			r.add("FAIL", rel, "required fields missing or empty: " + ", ".join(missing))
		marks = _placeholders(data)
		unfilled = [k for k, v in marks if v.startswith("RECORD_")]
		not_run = [k for k, v in marks if v.startswith("NOT_RUN")]
		if unfilled:
			r.add("FAIL", rel, "unfilled placeholders: " + ", ".join(unfilled))
		if not_run:
			r.add("NOT_RUN", rel, "device fields: " + ", ".join(not_run))
		if not unfilled and not not_run and not missing:
			r.add("OK", rel, "all fields recorded")


def cmd_doctor(a: argparse.Namespace) -> int:
	lock = load_json(LOCK_PATH)
	r = Report()
	_doctor_godot(r, lock)
	_doctor_templates(r, lock)
	_doctor_xcode(r, lock)
	_doctor_devices(r)
	_doctor_binaries(r, lock)
	_doctor_repo(r, lock)
	_doctor_evidence(r)
	code = r.exit_code(a.strict)
	counts = {s: sum(1 for x, _, _ in r.rows if x == s) for s in ("OK", "WARN", "PENDING", "NOT_RUN", "FAIL")}
	print("\ndoctor: " + ", ".join("%s=%d" % kv for kv in counts.items()) + (" (strict)" if a.strict else ""))
	print("doctor: %s" % ("FAILED" if code else "OK"))
	return code


# --- test ------------------------------------------------------------------------------
def cmd_test(a: argparse.Namespace) -> int:
	summary = []
	rc_godot = rc_py = 0
	if not a.python_only:
		args = [sys.executable, str(SCRIPTS / "godot_test.py")]
		for flag, val in (("--sandbox", a.sandbox), ("--suite", a.suite), ("--filter", a.filter)):
			if val:
				args += [flag, val]
		rc_godot, out = run(args, timeout=godot_test.IMPORT_TIMEOUT_S * 2 + godot_test.TEST_TIMEOUT_S + 60, cwd=REPO)
		print(out)
		m = re.findall(r"^(\d+) tests, (\d+) failures.*$", out, re.M)
		summary.append("Godot:  rc=%d, %s" % (rc_godot, "%s tests, %s failures" % m[-1] if m else "no summary line"))
	if not a.godot_only:
		rc_py, out = run([sys.executable, "-m", "unittest", "discover", "-s", str(SCRIPTS / "tests")], timeout=1800, cwd=REPO)
		print(out)
		m = re.findall(r"^Ran (\d+) tests?.*$", out, re.M)
		status = out.strip().splitlines()[-1] if out.strip() else ""
		summary.append("Python: rc=%d, %s tests, %s" % (rc_py, m[-1] if m else "?", status))
	print("\n== test summary ==\n" + "\n".join(summary))
	return 1 if (rc_godot or rc_py) else 0


# --- run / open ------------------------------------------------------------------------
def _launch(extra_engine: list[str], user_args: list[str], timeout: int) -> int:
	rc, output = godot_test.godot_import(APP)
	if rc != 0 or godot_test.import_errors(output):
		print(output, file=sys.stderr)
		return rc or 1
	cmd = [GODOT, "--path", str(APP)] + extra_engine + (["--"] + user_args if user_args else [])
	print("$ " + " ".join(cmd))
	try:
		return subprocess.run(cmd, stdin=subprocess.DEVNULL, timeout=timeout or 3600).returncode
	except subprocess.TimeoutExpired:
		print("error: Godot still running after %ds; killed" % timeout)
		return 124


def cmd_run_mac(a: argparse.Namespace) -> int:
	engine = list(a.passthrough)
	user: list[str] = []
	if a.consumer:
		if a.input_lab:
			print("error: --input-lab and --consumer are exclusive", file=sys.stderr)
			return 2
		return _open_consumer(a.consumer, a.passthrough, a.timeout)
	if a.input_lab:
		engine = ["--scene", "res://scenes/input_lab.tscn"] + engine
	return _launch(engine, user, a.timeout)


def _open_consumer(path: Path, passthrough: list[str], timeout: int) -> int:
	if not (APP / "scenes" / "mac_consumer.tscn").is_file():
		print("error: app/scenes/mac_consumer.tscn does not exist yet", file=sys.stderr)
		return 2
	if validate_world.main([str(path)]) != 0:
		print("error: world failed Python validation; not opening", file=sys.stderr)
		return 1
	return _launch(["--scene", "res://scenes/mac_consumer.tscn"] + passthrough, ["--world=%s" % path.resolve()], timeout)


def cmd_open_consumer(a: argparse.Namespace) -> int:
	return _open_consumer(a.path, a.passthrough, a.timeout)


# --- small commands --------------------------------------------------------------------
def cmd_validate_world(a: argparse.Namespace) -> int:
	return validate_world.main([str(a.path)] + (["--json"] if a.json else []))


def cmd_build_native(a: argparse.Namespace) -> int:
	script = REPO / "native" / "ios_input" / "build.sh"
	if not script.is_file():
		print("error: %s does not exist" % script, file=sys.stderr)
		return 2
	return subprocess.run(["bash", str(script)] + a.passthrough, cwd=script.parent, stdin=subprocess.DEVNULL).returncode


def cmd_fixtures(a: argparse.Namespace) -> int:
	return generate_fixtures.main(["--check"] if a.check else [])


def cmd_catalog_hash(a: argparse.Namespace) -> int:
	print(wf.catalog_sha256())
	return 0


def cmd_sync_config(a: argparse.Namespace) -> int:
	src, dst = REPO / "config" / "poc_defaults.json", APP / "config" / "poc_defaults.json"
	if dst.is_file() and dst.read_bytes() == src.read_bytes():
		print("already in sync")
		return 0
	dst.parent.mkdir(parents=True, exist_ok=True)
	shutil.copyfile(src, dst)
	print("copied %s -> %s" % (src.relative_to(REPO), dst.relative_to(REPO)))
	return 0


def build_parser() -> argparse.ArgumentParser:
	p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
	sub = p.add_subparsers(dest="command", required=True)
	s = sub.add_parser("doctor", help="report toolchain, hashes, devices and repo health")
	s.add_argument("--strict", action="store_true", help="also fail on NOT_RUN / PENDING items")
	s.set_defaults(fn=cmd_doctor)
	s = sub.add_parser("test", help="Godot + Python tests")
	s.add_argument("--sandbox", default="", help="isolated copy of app/ (see scripts/godot_test.py)")
	s.add_argument("--suite", default="", choices=["", "unit", "integration"])
	s.add_argument("--filter", default="")
	g = s.add_mutually_exclusive_group()
	g.add_argument("--python-only", action="store_true")
	g.add_argument("--godot-only", action="store_true")
	s.set_defaults(fn=cmd_test)
	s = sub.add_parser("run-mac", help="launch the app windowed (extra Godot args after --)")
	s.add_argument("--input-lab", action="store_true", help="start in res://scenes/input_lab.tscn")
	s.add_argument("--consumer", type=Path, default=None, help="open a world in the Mac consumer")
	s.add_argument("--timeout", type=int, default=0, help="kill Godot after N seconds (0 = 3600-second limit)")
	s.set_defaults(fn=cmd_run_mac)
	s = sub.add_parser("export-ios", help="export the iOS app", description=SIGNING_HELP,
		formatter_class=argparse.RawDescriptionHelpFormatter)
	s.add_argument("--project-only", action="store_true", help="generate the Xcode project only (no .ipa)")
	s.add_argument("--release", action="store_true", help="release instead of debug export")
	s.add_argument("--signing-config", type=Path, default=SIGNING_PATH)
	s.add_argument("--sandbox", default="", help="export from an isolated copy of app/")
	s.set_defaults(fn=cmd_export_ios)
	s = sub.add_parser("validate-world", help="validate a .worldpoc or generation directory")
	s.add_argument("path", type=Path)
	s.add_argument("--json", action="store_true")
	s.set_defaults(fn=cmd_validate_world)
	s = sub.add_parser("open-consumer", help="validate, then open in the Mac consumer")
	s.add_argument("path", type=Path)
	s.add_argument("--timeout", type=int, default=0)
	s.set_defaults(fn=cmd_open_consumer)
	sub.add_parser("build-native", help="run native/ios_input/build.sh").set_defaults(fn=cmd_build_native)
	s = sub.add_parser("fixtures", help="regenerate fixtures, or --check them")
	s.add_argument("--check", action="store_true")
	s.set_defaults(fn=cmd_fixtures)
	sub.add_parser("catalog-hash", help="print the catalog content hash").set_defaults(fn=cmd_catalog_hash)
	sub.add_parser("sync-config", help="copy config/poc_defaults.json into app/config").set_defaults(fn=cmd_sync_config)
	return p


def main(argv: list[str] | None = None) -> int:
	argv = list(sys.argv[1:] if argv is None else argv)
	passthrough: list[str] = []
	if "--" in argv:
		i = argv.index("--")
		argv, passthrough = argv[:i], argv[i + 1:]
	a = build_parser().parse_args(argv)
	a.passthrough = passthrough
	return a.fn(a)


if __name__ == "__main__":
	sys.exit(main())
