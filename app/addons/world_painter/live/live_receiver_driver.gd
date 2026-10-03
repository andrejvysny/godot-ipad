class_name LiveReceiverDriver
extends Node
## Glue between a LiveListener and the LiveReplica of the running preview (ADR 0016 P1): creates the replica when a
## session is paired (a resume keeps it), feeds it the writer's messages, ticks it every frame and sends its replies
## (acks, resync requests, pong) back. A malformed message only ever produces an error reply; the replica's document
## changes solely through its own validation.

signal replica_created(replica: LiveReplica)

var listener: LiveListener
var replica: LiveReplica
var visual_probe := Callable()

var _catalog: AssetCatalog
var _root: String


func setup(p_listener: LiveListener, p_catalog: AssetCatalog, p_root: String) -> void:
	listener = p_listener
	_catalog = p_catalog
	_root = p_root
	listener.peer_authenticated.connect(_on_authenticated)
	listener.text_received.connect(_on_text)
	listener.binary_received.connect(_on_binary)
	listener.peer_closed.connect(_on_closed)


func _on_authenticated(session_id: String, _resumed: bool) -> void:
	if replica == null or replica.session_id != session_id:
		replica = LiveReplica.new(session_id, _catalog, _root.path_join("replica_" + session_id.left(8)))
		replica.visual_probe = visual_probe
		replica_created.emit(replica)
	replica.reset_connection()


func _on_closed(_reason: String) -> void:
	if replica != null:
		replica.reset_connection()


func _on_text(text: String) -> void:
	if replica != null:
		replica.on_text(text, Time.get_ticks_msec())
		_flush()


func _on_binary(data: PackedByteArray) -> void:
	if replica != null:
		replica.on_binary(data)
		_flush()


func _process(_delta: float) -> void:
	if replica != null:
		replica.tick(Time.get_ticks_msec())
		_flush()


func _flush() -> void:
	for text in replica.take_outgoing():
		listener.send_text(text)
