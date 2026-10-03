@tool
class_name PreviewBroker
extends Node
## Editor side of the loopback broker (ADR 0016 P3): a TCP server on 127.0.0.1 that accepts exactly one preview child.
## The child authenticates with its one-time credential (from the private config file) within 5 s; afterwards only
## the allowlisted requests `status`, `assets_needed` and `snapshot_frozen` are served. Anything else, a second hello,
## a malformed frame or a wrong credential closes the connection. The editor never passes paths or URLs on behalf
## of the iPad: assets are resolved by `asset_resolver` from the binding rows the child extracted from the world lock.

signal status_received(status: Dictionary)
signal child_changed(connected: bool)
signal snapshot_frozen(info: Dictionary)

const ALLOWED := ["hello", "status", "assets_needed", "snapshot_frozen"]
const MAX_PENDING := 4
const MAX_BINDINGS_PER_REQUEST := 4

var auth_deadline_msec := 5000
## `resolve(row: Dictionary) -> Dictionary` coroutine of PreviewAssetResolver (or a test double).
var asset_resolver: Object
var rejected := 0

var _server := TCPServer.new()
var _credential := ""
var _pending: Array[Dictionary] = []  # {channel, born}
var _child: BrokerChannel
var _last_status := {}


## "" or an error; the credential is then available through credential() until the child used it.
func start() -> String:
	var err := _server.listen(0, "127.0.0.1")
	if err != OK:
		return "cannot open the broker socket (error %d)" % err
	_credential = LiveIds.new_secret()
	return ""


func port() -> int:
	return _server.get_local_port() if _server.is_listening() else 0


func credential() -> String:
	return _credential


func child_connected() -> bool:
	return _child != null


func last_status() -> Dictionary:
	return _last_status


func stop() -> void:
	for entry in _pending:
		(entry.channel as BrokerChannel).close()
	_pending.clear()
	if _child != null:
		_child.close()
		_child = null
		child_changed.emit(false)
	_server.stop()
	_credential = ""
	_last_status = {}


## Editor -> child push: `new_pairing` and `freeze_snapshot`. False when no child is connected.
func send_to_child(message: Dictionary) -> bool:
	return _child != null and _child.send(message)


func _process(_delta: float) -> void:
	if _server.is_listening():
		while _server.is_connection_available():
			var stream := _server.take_connection()
			if _pending.size() >= MAX_PENDING:
				stream.disconnect_from_host()
				continue
			_pending.append({"channel": BrokerChannel.new(stream), "born": Time.get_ticks_msec()})
	_poll_pending()
	_poll_child()


func _poll_pending() -> void:
	var keep: Array[Dictionary] = []
	var now := Time.get_ticks_msec()
	for entry in _pending:
		var channel: BrokerChannel = entry.channel
		var messages := channel.poll()
		if channel.error != "" or not channel.is_alive() or now - int(entry.born) >= auth_deadline_msec:
			rejected += 1
			channel.close()
		elif messages.is_empty():
			keep.append(entry)
		else:
			_first_frame(channel, messages[0])
	_pending = keep


func _first_frame(channel: BrokerChannel, message: Dictionary) -> void:
	var supplied: Variant = message.get("credential")
	var ok: bool = message.type == "hello" and typeof(supplied) == TYPE_STRING and _credential != "" \
			and _child == null and LiveListener._equal_secret(supplied, _credential)
	if not ok:
		rejected += 1
		channel.send({"type": "hello_result", "accepted": false})
		channel.close()
		return
	_credential = ""  # one-time
	channel.authenticated = true
	_child = channel
	channel.send({"type": "hello_result", "accepted": true})
	child_changed.emit(true)


func _poll_child() -> void:
	if _child == null:
		return
	var messages := _child.poll()
	for message in messages:
		if _child == null:
			return
		_dispatch(message)
	if _child != null and (_child.error != "" or not _child.is_alive()):
		_drop_child()


func _drop_child() -> void:
	_child.close()
	_child = null
	_last_status = {}
	child_changed.emit(false)


func _dispatch(message: Dictionary) -> void:
	var type: String = message.type
	if not ALLOWED.has(type) or type == "hello":
		rejected += 1
		_child.send({"type": "error", "code": "not_allowed"})
		_drop_child()
		return
	match type:
		"status":
			_last_status = PreviewStatus.sanitize(message)
			status_received.emit(_last_status)
		"snapshot_frozen":
			snapshot_frozen.emit(PreviewStatus.sanitize_frozen(message))
		"assets_needed":
			_serve_assets(message)


func _serve_assets(message: Dictionary) -> void:
	var channel := _child
	var request_id := int(message.get("id", 0))
	var rows: Variant = message.get("bindings")
	var results := {}
	if typeof(rows) != TYPE_ARRAY or (rows as Array).size() > MAX_BINDINGS_PER_REQUEST or asset_resolver == null:
		channel.send({"type": "asset_status", "id": request_id, "bindings": {}, "error": "bad request"})
		return
	for row: Variant in rows:
		if typeof(row) != TYPE_DICTIONARY:
			continue
		var res: Dictionary = await asset_resolver.call("resolve", row)
		results[str((row as Dictionary).get("binding_id", ""))] = res
	if _child == channel and channel != null:
		channel.send({"type": "asset_status", "id": request_id, "bindings": results})


func _exit_tree() -> void:
	if _server.is_listening():
		stop()
