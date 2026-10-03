@tool
class_name ApplyController
extends Node
## Editor side of "Apply world snapshot" (ADR 0017 A1-A5): asks the preview child to freeze its committed document,
## accepts the answer only from the session's own directory, builds the review in editor staging and runs the
## Apply / Rollback transactions. The dock shows what this controller reports; the live receiver never writes files.

signal review_ready(review: ApplyReview)
signal progress(label: String)
signal finished(result: Dictionary)
signal failed(message: String)

const FREEZE_TIMEOUT_MSEC := 60000

var launcher: PreviewLauncher
## `() -> ApplyContext`; replaced by tests.
var context_factory := Callable()
var review: ApplyReview
var busy := false

var _pending_id := 0
var _pending_msec := 0


func setup(p_launcher: PreviewLauncher) -> void:
	launcher = p_launcher
	launcher.broker.snapshot_frozen.connect(_on_frozen)


func _process(_delta: float) -> void:
	if _pending_id != 0 and Time.get_ticks_msec() - _pending_msec > FREEZE_TIMEOUT_MSEC:
		_pending_id = 0
		busy = false
		failed.emit("the preview did not answer the freeze request")


## Sends `freeze_snapshot` to the child. "" or why it was not sent.
func request_freeze() -> String:
	if busy:
		return "an Apply is already in progress"
	if not launcher.broker.child_connected():
		return "the preview is not running"
	_discard_review()
	_pending_id = randi() % 1000000 + 1
	_pending_msec = Time.get_ticks_msec()
	busy = true
	if not launcher.broker.send_to_child({"type": "freeze_snapshot", "id": _pending_id}):
		_pending_id = 0
		busy = false
		return "the freeze request could not be sent"
	progress.emit("Freezing the committed revision")
	return ""


func _on_frozen(info: Dictionary) -> void:
	if _pending_id == 0 or int(info.id) != _pending_id:
		return
	_pending_id = 0
	if info.error != "":
		_end_with_failure("The preview could not freeze its world: " + str(info.error))
		return
	var path := str(info.path)
	if not _is_session_snapshot(path):
		_end_with_failure("The preview announced a snapshot outside its session directory; ignored.")
		return
	progress.emit("Staging and reviewing the snapshot")
	await get_tree().process_frame
	var ctx := _context()
	review = ApplyReview.build(path, info, ctx)
	busy = false
	review_ready.emit(review)


## The snapshot must be a directory directly below <this session's directory>/frozen.
func _is_session_snapshot(path: String) -> bool:
	if launcher.session_id == "" or path.contains("..") or path.contains("\\"):
		return false
	var allowed := ProjectSettings.globalize_path(PreviewSession.session_dir(launcher.session_id)).path_join(FrozenSnapshot.DIR)
	return path.begins_with(allowed + "/") and not path.trim_prefix(allowed + "/").contains("/")


## Applies the reviewed candidate. A coroutine; emits progress and finished.
func confirm(discard_modified: bool = false) -> void:
	if review == null or busy:
		return
	busy = true
	var tx := ApplyTransaction.new(_context())
	tx.yield_frames = true
	tx.progress = func(label: String) -> void: progress.emit(label)
	var result: Dictionary = await tx.apply(review, discard_modified)
	busy = false
	_rescan()
	if result.ok:
		review = null
	finished.emit(result)


func rollback(world_id: String, dir_name: String, discard_modified: bool = false) -> void:
	if busy:
		return
	busy = true
	progress.emit("Rolling back")
	await get_tree().process_frame
	var result := ApplyTransaction.new(_context()).rollback(world_id, dir_name, discard_modified)
	busy = false
	_rescan()
	finished.emit(result)


## Listing needs no context (no catalog, no lock): it only reads receipts.
func generations(world_id: String) -> Array[Dictionary]:
	return ApplyTransaction.new(null).list_generations(world_id)


func cancel_review() -> void:
	_discard_review()


func _end_with_failure(message: String) -> void:
	busy = false
	failed.emit(message)


func _discard_review() -> void:
	if review != null:
		review.discard_staging()
		review = null


func _context() -> ApplyContext:
	if context_factory.is_valid():
		return context_factory.call()
	var ctx := ApplyContext.for_project(get_tree())
	if _in_editor():
		var editor := Engine.get_singleton("EditorInterface")
		ctx.unsaved_scenes = func() -> PackedStringArray: return editor.get_unsaved_scenes()
		ctx.import_busy = func() -> bool:
			var fs := editor.get_resource_filesystem() as EditorFileSystem
			return fs != null and (fs.is_scanning() or fs.is_importing())
	return ctx


## EditorInterface exists only inside the running editor (it is not usable under `--script`).
static func _in_editor() -> bool:
	return Engine.is_editor_hint() and Engine.has_singleton("EditorInterface")


func _rescan() -> void:
	if _in_editor():
		var fs := Engine.get_singleton("EditorInterface").get_resource_filesystem() as EditorFileSystem
		if fs != null:
			fs.scan()


func _exit_tree() -> void:
	_discard_review()
