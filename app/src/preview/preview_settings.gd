class_name PreviewSettings
extends RefCounted
## Device-local settings of the desktop preview link (ADR 0016 P5). Host, port and the insecure-LAN switch live in
## user://world_painter/preview.json; the pairing token and the session credential are never written.

const PATH := "user://world_painter/preview.json"
const KEYS := ["host", "port", "allow_insecure_lan"]
const MAX_HOST := 253

var host := ""
var port := LiveWsTransport.DEFAULT_PORT
var allow_insecure_lan := false


## Missing or invalid files give the defaults (invalid values are never partially applied).
static func load_from(path: String = PATH) -> PreviewSettings:
	var s := PreviewSettings.new()
	if not FileAccess.file_exists(path):
		return s
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return s
	var d: Dictionary = parsed
	for k: Variant in d:
		if not KEYS.has(k):
			return PreviewSettings.new()
	var h: Variant = d.get("host", "")
	var p: Variant = d.get("port", LiveWsTransport.DEFAULT_PORT)
	var l: Variant = d.get("allow_insecure_lan", false)
	if typeof(h) != TYPE_STRING or (h as String).length() > MAX_HOST or typeof(l) != TYPE_BOOL \
			or typeof(p) not in [TYPE_INT, TYPE_FLOAT] or float(p) != floorf(float(p)) or float(p) < 1.0 or float(p) > 65535.0:
		return PreviewSettings.new()
	s.host = h
	s.port = int(p)
	s.allow_insecure_lan = l
	return s


## "" or an error.
func save(path: String = PATH) -> String:
	var err := StorageFs.make_dir(path.get_base_dir())
	if err != "":
		return err
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return "cannot write the preview settings"
	f.store_string(JSON.stringify({"host": host, "port": port, "allow_insecure_lan": allow_insecure_lan}))
	return ""
