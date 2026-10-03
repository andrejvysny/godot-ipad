import hashlib, json, os, subprocess, sys, tempfile
from pathlib import Path
A = Path(os.environ["A"]); REPO = Path("/Users/andrejvysny/workspace/godot/godot-ipad")
V4 = REPO / "contracts/world-painter/world-v4"
idx = {f["name"]: f for f in json.loads((V4 / "fixtures/INDEX.json").read_text())["fixtures"]}
proj = A / "mc" / "project"
def tree_hash(p: Path) -> str:
    h = hashlib.sha256()
    if p.is_file():
        return hashlib.sha256(p.read_bytes()).hexdigest()
    for f in sorted(x for x in p.rglob("*") if x.is_file()):
        h.update(str(f.relative_to(p)).encode()); h.update(hashlib.sha256(f.read_bytes()).digest())
    return h.hexdigest()
def cli(*args):
    r = subprocess.run(["godot", "--headless", "--path", str(proj), "--script", "res://addons/world_painter/cli.gd", "--", *args], capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=300)
    line = next((l for l in r.stdout.splitlines() if l.startswith("{")), "{}")
    return r.returncode, json.loads(line)
ok_all = True
print(f"{'fixture':30} {'src':6} {'src intact':11} {'migrate rc':10} {'out schema':10} {'out hash == INDEX':18} {'validate(out) hash == INDEX':28}")
for name in ("migrate_v2", "migrate_v3", "migrate_v2_app_flat", "migrate_v2_app_gentle_hills"):
    f = idx[name]
    src = (V4 / "fixtures" / f["source"]) if (V4 / "fixtures" / f["source"]).exists() else REPO / f["source"]
    before = tree_hash(src)
    dest = Path(tempfile.mkdtemp(prefix="mig_")) / "out"
    rc, out = cli("migrate", "--world", str(src), "--out", str(dest))
    after = tree_hash(src)
    vrc, v = cli("validate", "--world", str(dest))
    want = f.get("authored_hash")
    row_ok = rc == 0 and before == after and out.get("ok") and v.get("ok") and v.get("authored_hash") == want and out.get("authored_hash", want) == want
    ok_all &= bool(row_ok)
    print(f"{name:30} {str(out.get('source_schema', out.get('schema','?'))):6} {str(before == after):11} {rc:<10} {str(v.get('schema')):10} {str(out.get('authored_hash', '-') == want):18} {str(v.get('authored_hash') == want):28}")
print("ALL_OK" if ok_all else "MISMATCH")
