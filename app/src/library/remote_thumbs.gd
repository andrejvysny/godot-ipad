class_name RemoteThumbs
extends RefCounted
## Thumbnails of exact AssetStudio versions: a small in-memory cache backed by files below the connection's
## directory (versions are immutable, so a cached image never goes stale). A miss with the server unreachable
## stays a miss; nothing here blocks browsing.

signal ready(key: String)

const MEMORY_MAX := 160
const MAX_BYTES := 2097152
const MAX_DIM := 1024

var dir := ""

var _memory: Dictionary = {}  # key -> Texture2D
var _order: Array[String] = []
var _pending: Dictionary = {}
var _missing: Dictionary = {}  # key -> true: the server has no usable thumbnail (no retry this session)


func _init(p_dir: String = "") -> void:
	dir = p_dir


func texture(key: String) -> Texture2D:
	return _memory.get(key)


## Coroutine: loads the thumbnail of `key` from disk or `client` (a library client; null = disk only).
func request(client: Object, key: String, library_id: String, asset_id: String, version_id: String) -> void:
	if _memory.has(key) or _pending.has(key) or _missing.has(key):
		return
	_pending[key] = true
	var bytes := _read_disk(key)
	if bytes.is_empty() and client != null:
		var r: RefCounted = await client.call("thumbnail_bytes", library_id, asset_id, version_id)
		if r.get("ok"):
			bytes = (r.get("value") as Dictionary).get("bytes", PackedByteArray())
			if bytes.size() <= MAX_BYTES and _decode(bytes) != null:
				_write_disk(key, bytes)
		else:
			_missing[key] = true
	_pending.erase(key)
	var tex := _decode(bytes) if bytes.size() <= MAX_BYTES else null
	if tex != null:
		_remember(key, tex)
		ready.emit(key)


func _remember(key: String, tex: Texture2D) -> void:
	_memory[key] = tex
	_order.append(key)
	while _order.size() > MEMORY_MAX:
		_memory.erase(_order.pop_front())


static func _decode(bytes: PackedByteArray) -> Texture2D:
	if bytes.is_empty():
		return null
	var img := Image.new()
	if img.load_png_from_buffer(bytes) != OK and img.load_jpg_from_buffer(bytes) != OK \
			and img.load_webp_from_buffer(bytes) != OK:
		return null
	if img.get_width() > MAX_DIM or img.get_height() > MAX_DIM or img.is_empty():
		return null
	return ImageTexture.create_from_image(img)


func _path(key: String) -> String:
	return dir.path_join("thumbs").path_join(key + ".img")


func _read_disk(key: String) -> PackedByteArray:
	return FileAccess.get_file_as_bytes(_path(key)) if dir != "" and FileAccess.file_exists(_path(key)) else PackedByteArray()


func _write_disk(key: String, bytes: PackedByteArray) -> void:
	if dir == "":
		return
	DirAccess.make_dir_recursive_absolute(dir.path_join("thumbs"))
	var f := FileAccess.open(_path(key), FileAccess.WRITE)
	if f != null:
		f.store_buffer(bytes)
