class_name PreviewBrokerClient
extends Node
## Preview child's end of the loopback broker (ADR 0016 P3): connects to the editor with the one-time credential from
## the private config, then sends `status`, `assets_needed` and `snapshot_frozen` frames and receives `asset_status`,
## `new_pairing` and `freeze_snapshot`.
## When the connection ends or never authenticates within CONNECT_DEADLINE_MSEC, `lost` is emitted once and the
## owner exits (the child must not outlive its editor).

signal ready_changed(ready: bool)
signal new_pairing_requested()
## The editor asked for the committed document to be frozen (ADR 0017 A1); answer with send_message(snapshot_frozen).
signal freeze_requested(request_id: int)
signal lost(reason: String)

const CONNECT_DEADLINE_MSEC := 5000
const REQUEST_TIMEOUT_MSEC := 30000

var requests_sent := 0

var _channel: BrokerChannel
var _credential := ""
var _started_msec := 0
var _ready := false
var _lost := false
var _next_id := 1
var _replies: Dictionary = {}  # request id -> reply Dictionary


## "" or an error.
func connect_to(port: int, credential: String) -> String:
	var stream := StreamPeerTCP.new()
	if stream.connect_to_host("127.0.0.1", port) != OK:
		return "cannot connect to the editor broker"
	_channel = BrokerChannel.new(stream)
	_credential = credential
	_started_msec = Time.get_ticks_msec()
	return ""


func is_ready() -> bool:
	return _ready


func _process(_delta: float) -> void:
	if _channel == null or _lost:
		return
	var messages := _channel.poll()
	if not _ready and _channel.is_connected_now() and _credential != "":
		_channel.send({"type": "hello", "credential": _credential})
		_credential = ""
	for message in messages:
		_handle(message)
	var timed_out := not _ready and Time.get_ticks_msec() - _started_msec > CONNECT_DEADLINE_MSEC
	if _channel.error != "" or not _channel.is_alive() or timed_out:
		_lose("broker connection ended" if _ready else "broker did not authenticate")


func _handle(message: Dictionary) -> void:
	match message.type:
		"hello_result":
			if typeof(message.get("accepted")) == TYPE_BOOL and message.accepted and not _ready:
				_ready = true
				_channel.authenticated = true
				ready_changed.emit(true)
			else:
				_lose("broker refused the credential")
		"asset_status":
			_replies[int(message.get("id", 0))] = message
		"new_pairing":
			new_pairing_requested.emit()
		"freeze_snapshot":
			freeze_requested.emit(int(message.get("id", 0)))
		"error":
			_lose("broker error: %s" % str(message.get("code", "")).left(40))


func _lose(reason: String) -> void:
	if _lost:
		return
	_lost = true
	var was_ready := _ready
	_ready = false
	if _channel != null:
		_channel.close()
	if was_ready:
		ready_changed.emit(false)
	lost.emit(reason)


func send_status(status: Dictionary) -> bool:
	return _ready and _channel.send(status)


## Any other allowlisted child -> editor message (`snapshot_frozen`).
func send_message(message: Dictionary) -> bool:
	return _ready and _channel.send(message)


## Coroutine: one binding row -> the editor's {state, files, manifest_sha256, manifest, error} for it.
func request_assets(row: Dictionary) -> Dictionary:
	if not _ready:
		return {"state": "error", "error": "the editor broker is not connected"}
	var id := _next_id
	_next_id += 1
	requests_sent += 1
	if not _channel.send({"type": "assets_needed", "id": id, "bindings": [row]}):
		return {"state": "error", "error": "the request is too large for the broker"}
	var tree := Engine.get_main_loop() as SceneTree
	var t0 := Time.get_ticks_msec()
	while not _replies.has(id) and not _lost and Time.get_ticks_msec() - t0 < REQUEST_TIMEOUT_MSEC:
		await tree.process_frame
	var reply: Dictionary = _replies.get(id, {})
	_replies.erase(id)
	var results: Variant = reply.get("bindings")
	if typeof(results) != TYPE_DICTIONARY or not (results as Dictionary).has(str(row.get("binding_id", ""))):
		return {"state": "error", "error": str(reply.get("error", "no answer from the editor broker"))}
	return (results as Dictionary)[str(row.binding_id)]
