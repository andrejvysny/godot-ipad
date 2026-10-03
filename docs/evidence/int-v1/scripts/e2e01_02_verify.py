import hashlib, io, json, struct, sys, zipfile
sys.path.insert(0, __import__("os").environ["A"]); from api import req
import os
S = os.environ["S"]
def glb_json(b):
    l = struct.unpack_from("<I", b, 12)[0]; return json.loads(b[20:20+l])
out = {}
st, items = req("GET", f"/libraries/{S}/assets"); assert st == 200
for it in items["items"]:
    a, v = it["asset_id"], it["current_version_id"]
    st, ver = req("GET", f"/libraries/{S}/assets/{a}/versions/{v}")
    desc = json.loads(ver["descriptor"]["json"])
    r = {"name": it["display_name"], "asset_id": a, "version_id": v, "reps": {}, "anchor": desc["placement_anchor"],
         "slots": [s["slot_id"] for s in desc["material_slots"]], "preview_warnings": desc["preview_warnings"],
         "provenance": desc["source_provenance"], "collision": desc["collision"]}
    for d in ver["deliveries"]:
        st, man = req("GET", f"/libraries/{S}/deliveries/{d['delivery_id']}/manifest")
        for f in man["files"]:
            st, body = req("GET", f"/libraries/{S}/artifacts/{f['artifact_id']}/content", raw=True)
            ok = hashlib.sha256(body).hexdigest() == f["sha256"] and len(body) == f["size"]
            rep = {"sha256": f["sha256"], "size": f["size"], "hash_ok": ok}
            if d["representation"] == "portable_glb_v1":
                j = glb_json(body); prims = [p for m in j["meshes"] for p in m["primitives"]]
                rep.update(meshes=len(j["meshes"]), has_uv=all("TEXCOORD_0" in p["attributes"] for p in prims),
                           has_color=any("COLOR_0" in p["attributes"] for p in prims), images=len(j.get("images", [])),
                           materials=[{"name": m.get("name"), "alphaMode": m.get("alphaMode", "OPAQUE"), "doubleSided": m.get("doubleSided", False),
                                       "baseColorTexture": "baseColorTexture" in m.get("pbrMetallicRoughness", {}), "metallic": m.get("pbrMetallicRoughness", {}).get("metallicFactor"),
                                       "roughness": m.get("pbrMetallicRoughness", {}).get("roughnessFactor")} for m in j.get("materials", [])],
                           extensions=j.get("extensionsUsed", []), skins="skins" in j, animations="animations" in j)
            else:
                z = zipfile.ZipFile(io.BytesIO(body)); names = z.namelist(); mf = json.loads(z.read("source_manifest.json"))
                rep.update(members=names, capabilities=mf["capabilities"], conversion=mf["conversion_report"])
            r["reps"][d["representation"]] = rep
    out[it["display_name"]] = r
print(json.dumps(out, indent=1))
