class_name LiveOutbox
extends RefCounted
## The sender's FIFO queue of control messages and blob transfers, and the pump that feeds a LiveTransport
## (ADR 0015 L1). Writing stops while the transport's backlog is at or above `high_water`, and each pump call moves
## at most `max_messages`, so neither a stalled peer nor a large snapshot can cost an unbounded frame.
## Order matters (commits follow the snapshot they continue), so everything shares one queue; previews are
## placeholders materialized from the sampler's latest values only when they reach the head.

var session_id := ""
var stream_id := ""
var high_water := 1024 * 1024
var max_messages := 256
## Binary bytes written per pump() call: bounds the file reads a large snapshot costs one frame.
var max_bytes := 2 * 1024 * 1024
var queue: Array[LiveOutItem] = []
## `materialize(item: LiveOutItem) -> bool`: fills a preview placeholder, false to drop it.
var materialize := Callable()
## Items whose archive vanished while being sent (a frame could not be read); the owner reacts after pump().
var failed_items: Array[LiveOutItem] = []
var control_cap := 64

var _written := 0


func control(type: String, payload: Dictionary) -> bool:
	var built := LiveEnvelope.build(type, session_id, stream_id, payload)
	if not built.ok:
		return false
	var controls := 0
	for item in queue:
		controls += 1 if item.is_control() else 0
	if controls >= control_cap:
		for i in queue.size():
			if queue[i].is_control():
				queue.remove_at(i)  # the oldest control message is the least useful
				break
	queue.append(LiveOutItem.control(built.text))
	return true


## Queues a blob transfer whose archive is described by `framer`. `extra` holds the kind-specific blob_begin keys.
func blob(kind: String, framer: LiveBlobFramer, extra: Dictionary, operation_id: String = "", revision: int = 0,
		ready: bool = true) -> LiveOutItem:
	var item := LiveOutItem.new()
	item.kind = kind
	item.operation_id = operation_id
	item.revision = revision
	item.ready = ready
	queue.append(item)
	if framer != null:
		fill(item, framer, extra)
	return item


## Builds the begin/end/abort messages of `item` from `framer`.
func fill(item: LiveOutItem, framer: LiveBlobFramer, extra: Dictionary) -> bool:
	var format := "worldpoc-v4" if item.kind == "snapshot" else "world-delta-v1"
	var payload := framer.begin_payload(item.kind, format)
	payload.merge(extra)
	var begin := LiveEnvelope.build("blob_begin", session_id, stream_id, payload)
	var end := LiveEnvelope.build("blob_end", session_id, stream_id, {"transfer_id": framer.transfer_id})
	var abort := LiveEnvelope.build("blob_abort", session_id, stream_id,
		{"transfer_id": framer.transfer_id, "reason": "sender aborted"})
	if not (begin.ok and end.ok and abort.ok):
		return false
	item.framer = framer
	item.begin_text = begin.text
	item.end_text = end.text
	item.abort_text = abort.text
	return true


func has_kind(kind: String) -> bool:
	for item in queue:
		if item.kind == kind:
			return true
	return false


## Removes unstarted items of `kind` (previews of a finished operation).
func drop_unstarted(kind: String) -> void:
	for i in range(queue.size() - 1, -1, -1):
		if queue[i].kind == kind and not queue[i].started():
			queue[i].cleanup()
			queue.remove_at(i)


## Empties the queue. Started blobs get a blob_abort first when `abort_started`; those texts are returned
## (built with the stream that was current, so call before changing stream_id) for the caller to queue again.
func purge(abort_started: bool) -> Array[String]:
	var aborts: Array[String] = []
	for item in queue:
		if abort_started and item.started() and item.abort_text != "":
			aborts.append(item.abort_text)
		item.cleanup()
	queue.clear()
	return aborts


func push_front_texts(texts: Array[String]) -> void:
	for i in range(texts.size() - 1, -1, -1):
		queue.push_front(LiveOutItem.control(texts[i]))


func pending_blobs() -> int:
	var n := 0
	for item in queue:
		n += 0 if item.is_control() else 1
	return n


## Sends what the transport accepts now. Returns the number of messages written.
func pump(transport: LiveTransport) -> int:
	var sent := 0
	_written = 0
	while sent < max_messages and _written < max_bytes and transport.is_open() and not queue.is_empty():
		if transport.backlog_bytes() >= high_water:
			break
		var item := queue[0]
		if not item.ready:
			break
		var step := _step(item, transport)
		if step == 0:
			break
		sent += maxi(step, 0)
		if step < 0 or item.stage > LiveOutItem.STAGE_END:
			queue.pop_front()
			item.cleanup()
	return sent


## 1 = one message written, 0 = blocked, -1 = item dropped without writing.
func _step(item: LiveOutItem, transport: LiveTransport) -> int:
	if item.is_control():
		item.stage = LiveOutItem.STAGE_END + 1
		return 1 if transport.send_text(item.begin_text) else _retry(item)
	if item.kind == "preview" and item.framer == null:
		if not materialize.is_valid() or not bool(materialize.call(item)):
			return -1
	match item.stage:
		LiveOutItem.STAGE_BEGIN:
			if not transport.send_text(item.begin_text):
				return 0
			item.stage = LiveOutItem.STAGE_FRAMES
			return 1
		LiveOutItem.STAGE_FRAMES:
			return _send_frame(item, transport)
	if not transport.send_text(item.end_text):
		return 0
	item.stage = LiveOutItem.STAGE_END + 1
	return 1


func _retry(item: LiveOutItem) -> int:
	item.stage = LiveOutItem.STAGE_BEGIN
	return 0


func _send_frame(item: LiveOutItem, transport: LiveTransport) -> int:
	var frame := item.framer.frame(item.next_frame)
	if frame.is_empty():
		transport.send_text(item.abort_text)
		failed_items.append(item)
		return -1
	if not transport.send_binary(frame):
		return 0
	item.next_frame += 1
	_written += frame.size()
	if item.next_frame >= item.framer.chunk_count:
		item.stage = LiveOutItem.STAGE_END
	return 1
