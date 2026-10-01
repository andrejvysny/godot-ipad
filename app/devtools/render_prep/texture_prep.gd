extends RefCounted
## Texture staging for render derivatives: copies the prepared PNG, writes its .png.import
## (VRAM compressed, mipmaps, no normal-map detection), reports cutout coverage per mip and
## verifies the imported texture. The tool never resamples: inputs are already the tier sizes.

const MAX_DIM := {"low": 512, "preview": 2048}
const MIN_COVERAGE_MIP := 32
const MIN_COVERAGE_RATIO := 0.8
const REQUIRED_PARAMS: Array[String] = ["compress/mode=2", "mipmaps/generate=true", "compress/normal_map=2",
	"detect_3d/compress_to=0", "process/fix_alpha_border=true"]
const IMPORT_TEXT := """[remap]

importer="texture"
type="CompressedTexture2D"

[params]

compress/mode=2
compress/high_quality=false
compress/lossy_quality=0.7
compress/uastc_level=0
compress/rdo_quality_loss=0.0
compress/hdr_compression=1
compress/normal_map=2
compress/channel_pack=0
mipmaps/generate=true
mipmaps/limit=-1
roughness/mode=0
roughness/src_normal=""
process/channel_remap/red=0
process/channel_remap/green=1
process/channel_remap/blue=2
process/channel_remap/alpha=3
process/fix_alpha_border=true
process/premult_alpha=false
process/normal_map_invert_y=false
process/hdr_as_srgb=false
process/hdr_clamp_exposure=false
process/size_limit=0
detect_3d/compress_to=0
"""


## Returns {"error", "pending_import", "width", "height", "bytes", "sha256", "gpu_bytes",
## "staging_bytes", "coverage"}. `tier` is "low" or "preview".
static func stage(src_path: String, dest_res: String, tier: String, cutout: bool, label: String) -> Dictionary:
	var data := FileAccess.get_file_as_bytes(src_path)
	if data.is_empty():
		return {"error": "%s: cannot read texture %s" % [label, src_path]}
	var img := Image.new()
	if img.load_png_from_buffer(data) != OK:
		return {"error": "%s: %s is not a decodable PNG" % [label, src_path]}
	var w := img.get_width()
	var h := img.get_height()
	if w & (w - 1) != 0 or h & (h - 1) != 0:
		return {"error": "%s: %s is %dx%d, not a power of two" % [label, src_path, w, h]}
	if maxi(w, h) > int(MAX_DIM[tier]):
		return {"error": "%s: %s is %dx%d, over the %s limit %d" % [label, src_path, w, h, tier, MAX_DIM[tier]]}
	var out := {"error": "", "pending_import": false, "width": w, "height": h, "coverage": [],
		"gpu_bytes": _mip_bytes(w, h), "staging_bytes": w * h * 4}
	if cutout:
		var cov := coverage(img)
		out.coverage = cov.levels
		if cov.error != "":
			out.error = "%s: %s %s" % [label, dest_res.get_file(), cov.error]
			return out
	var f := FileAccess.open(dest_res, FileAccess.WRITE)
	if f == null:
		out.error = "%s: cannot write %s" % [label, dest_res]
		return out
	f.store_buffer(data)
	f.close()
	out.bytes = data.size()
	out.sha256 = _sha256_hex(data)
	_write_import(dest_res)
	return out


## Cutout coverage: fraction of texels with alpha >= 0.5 per mip level, relative to mip 0.
## Returns {"levels": [{"mip", "width", "height", "coverage", "ratio"}], "error"}.
static func coverage(source: Image) -> Dictionary:
	var img := source.duplicate() as Image
	img.convert(Image.FORMAT_RGBA8)
	img.generate_mipmaps()
	var data := img.get_data()
	var levels: Array = []
	var base := 0.0
	var error := ""
	for k in img.get_mipmap_count() + 1:
		var w := maxi(1, img.get_width() >> k)
		var h := maxi(1, img.get_height() >> k)
		var off := img.get_mipmap_offset(k)
		var hit := 0
		for i in w * h:
			if data[off + i * 4 + 3] >= 128:
				hit += 1
		var frac := float(hit) / float(w * h)
		if k == 0:
			base = frac
			if base <= 0.0:
				return {"levels": levels, "error": "has no alpha coverage at mip 0"}
		var ratio := frac / base
		levels.append({"mip": k, "width": w, "height": h, "coverage": snappedf(frac, 0.0001), "ratio": snappedf(ratio, 0.0001)})
		if minf(w, h) >= MIN_COVERAGE_MIP and ratio < MIN_COVERAGE_RATIO and error == "":
			error = "loses cutout coverage at mip %d (%dx%d): %.3f of mip 0 (minimum %.1f)" % [k, w, h, ratio, MIN_COVERAGE_RATIO]
	return {"levels": levels, "error": error}


static func _mip_bytes(w: int, h: int) -> int:
	var total := 0
	while true:
		total += w * h
		if w == 1 and h == 1:
			break
		w = maxi(1, w >> 1)
		h = maxi(1, h >> 1)
	return total


static func _write_import(res_png: String) -> void:
	var path := res_png + ".import"
	if FileAccess.file_exists(path):
		var text := FileAccess.get_file_as_string(path)
		var ok := true
		for line in REQUIRED_PARAMS:
			ok = ok and text.contains("\n" + line + "\n")
		if ok:
			return
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(IMPORT_TEXT)
	f.close()


## Returns "" when imported with mipmaps, "pending" while the importer has not run, else an error.
static func verify_import(res_png: String, w: int, h: int) -> String:
	var imp := FileAccess.get_file_as_string(res_png + ".import")
	if not (imp.contains("\npath=") or imp.contains("\npath.")):
		return "pending"
	var tex := ResourceLoader.load(res_png, "Texture2D", ResourceLoader.CACHE_MODE_IGNORE) as Texture2D
	if tex == null:
		return "%s did not load after import" % res_png
	if tex.get_width() != w or tex.get_height() != h:
		return "%s imported as %dx%d, expected %dx%d" % [res_png, tex.get_width(), tex.get_height(), w, h]
	var img := tex.get_image()
	if img == null or not img.has_mipmaps():
		return "%s imported without mipmaps" % res_png
	return ""


static func _sha256_hex(data: PackedByteArray) -> String:
	var ctx := HashingContext.new()
	ctx.start(HashingContext.HASH_SHA256)
	ctx.update(data)
	return ctx.finish().hex_encode()
