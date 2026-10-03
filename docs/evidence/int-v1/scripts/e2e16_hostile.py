import json, os, sys, hashlib
from pathlib import Path
import httpx
sys.path.insert(0, "/Users/andrejvysny/workspace/godot/asset-studio"); sys.path.insert(0, "/Users/andrejvysny/workspace/godot/asset-studio/scripts")
from tests.integration_publication_support import source_parts, files_of
A = os.environ["A"]; URL = os.environ["URL"] + "/api/integration/v1"; S = os.environ["S"]
H = {"Authorization": "Bearer " + open(A + "/tok/desktop.token").read().strip()}
FIX = Path("/Users/andrejvysny/workspace/godot/asset-studio/contracts/godot-integration/v1/fixtures")
index = json.load(open(FIX / "INDEX.json"))["fixtures"]
hostile = [e for e in index if e["path"].startswith("source_packages/hostile/")]
c = httpx.Client(timeout=120)
import subprocess
staging0 = sorted(os.listdir(A+'/inst/staging/integration')) if os.path.isdir(A+'/inst/staging/integration') else []
before = c.get(f"{URL}/libraries/{S}/assets", headers=H).json()["items"]
rows = []
for e in hostile:
    z = (FIX / e["path"]).read_bytes()
    assert hashlib.sha256(z).hexdigest() == e["sha256"]
    r = c.post(f"{URL}/libraries/{S}/publications:preview", headers=H, files=files_of({**source_parts("primitive_prop"), "source": z}))
    body = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
    err = body.get("error", {})
    probs = err.get("details", {}).get("problems", [])
    detail = (probs[0].get("detail") if probs and isinstance(probs[0], dict) else None)
    rows.append((Path(e["path"]).stem, e["sha256"][:12], e["expected"], r.status_code, err.get("code"), detail, e.get("detail")))
# extra case without a fixture: a PNG whose IHDR claims 60000x60000 (huge decoded image), header only
import struct
from assetstudio_core.delivery import AssetDescriptorV1
from assetstudio_core.source_manifest import SourcePackageManifestV1, source_manifest_bytes
from integration_fixture_packages import BASE, EXACT, build_package_doc, zip_of
from integration_fixture_sources import _chunk, prop_files
from make_integration_fixtures import descriptor_docs
files = {**prop_files(), "textures/huge.png": b"\x89PNG\r\n\x1a\n" + _chunk(b"IHDR", struct.pack(">IIBBBBB", 60000, 60000, 8, 6, 0, 0, 0))}
desc = AssetDescriptorV1.model_validate(descriptor_docs()["primitive_prop"])
doc = build_package_doc(files, "scenes/prop.tscn", desc, BASE, EXACT)
zbytes = zip_of(source_manifest_bytes(SourcePackageManifestV1.model_validate(doc)), files)
r = c.post(f"{URL}/libraries/{S}/publications:preview", headers=H, files=files_of({**source_parts("primitive_prop"), "source": zbytes}))
err = r.json().get("error", {}); probs = err.get("details", {}).get("problems", [])
rows.append(("huge_decoded_image(generated)", hashlib.sha256(zbytes).hexdigest()[:12], "resource_limit", r.status_code, err.get("code"), probs[0].get("detail") if probs else None, "image_dimensions"))
after = c.get(f"{URL}/libraries/{S}/assets", headers=H).json()["items"]
ok = True
print(f"{'fixture':28} {'sha256[:12]':13} {'expected':16} {'http':5} {'got':16} detail(got/expected)")
for n, sh, exp, st, got, d, ed in rows:
    good = st in (413, 422) and got == exp
    ok &= good
    print(f"{n:28} {sh:13} {exp:16} {st:<5} {str(got):16} {d}/{ed} {'OK' if good else 'MISMATCH'}")
staging1 = sorted(os.listdir(A+"/inst/staging/integration")) if os.path.isdir(A+"/inst/staging/integration") else []
print("staging previews unchanged by hostile uploads:", staging0 == staging1)
print("library asset list unchanged:", before == after, "| all refused:", ok)
