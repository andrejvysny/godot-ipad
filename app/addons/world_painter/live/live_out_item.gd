class_name LiveOutItem
extends RefCounted
## One entry of the sender's FIFO outgoing queue: either a control message, or a blob transfer made of
## blob_begin, binary frames (read lazily from the framer, so a 264 MiB snapshot is never resident), blob_end.
## kind: control | snapshot | commit | preview. A snapshot item is not `ready` until its worker has written the
## archive; a preview item is a placeholder until the sender materializes it from the sampler's latest values.

const STAGE_BEGIN := 0
const STAGE_FRAMES := 1
const STAGE_END := 2

var kind := "control"
var ready := true
var stage := STAGE_BEGIN
var next_frame := 0
var begin_text := ""  # control items carry their message here
var end_text := ""
var abort_text := ""
var framer: LiveBlobFramer = null
var operation_id := ""
var revision := 0
## Archive to delete once the item is done (preview/snapshot temp files).
var temp_path := ""


static func control(text: String) -> LiveOutItem:
	var item := LiveOutItem.new()
	item.begin_text = text
	return item


func is_control() -> bool:
	return kind == "control"


func started() -> bool:
	return not is_control() and (stage > STAGE_BEGIN or next_frame > 0)


func cleanup() -> void:
	if temp_path != "" and FileAccess.file_exists(temp_path):
		DirAccess.remove_absolute(temp_path)
	temp_path = ""
