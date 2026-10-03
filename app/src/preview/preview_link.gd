class_name PreviewLink
extends Node
## iPad-side live link to the desktop preview (ADR 0016 P5): a LivePeerSocket plus the LiveSender of the open world,
## driven once per frame. The sender is bound to the session on the first connect only, so an editor that never
## uses the preview pays nothing. World switches and revision gaps are handled by the sender's stream logic; the
## session's disconnect/reconnect (resume or a fresh snapshot) by LiveSender.start_session/end_session.
## The session is duck-typed (see LiveSessionBinding): `document`, `open_transaction()` and its three signals.

var socket := LivePeerSocket.new()
var sender := LiveSender.new()

var _session: Object
var _bound := false


func setup(session: Object) -> void:
	_session = session
	add_child(socket)
	socket.session_ready.connect(_on_session_ready)
	socket.session_lost.connect(_on_session_lost)
	socket.text_received.connect(sender.on_text)


## "" or an error. `token` empty resumes with the in-memory session credential.
func connect_to(host: String, port: int, allow_insecure_lan: bool, token: String = "") -> String:
	var err := socket.connect_to(host, port, allow_insecure_lan, token)
	if err == "" and not _bound:
		_bind()
	return err


func disconnect_link(forget: bool = false) -> void:
	socket.disconnect_link(forget)


func is_ready() -> bool:
	return socket.is_ready()


func _bind() -> void:
	_bound = true
	sender.created_with = WorldCodec.default_created_with()
	LiveSessionBinding.bind(_session, sender)


func _process(_delta: float) -> void:
	if not _bound:
		return
	sender.tick(Time.get_ticks_msec())
	if socket.is_ready():
		sender.pump(socket.transport)


func _on_session_ready(session_id: String, _resumed: bool) -> void:
	sender.start_session(session_id)


func _on_session_lost(_reason: String) -> void:
	sender.end_session()


## For the panel: {state, text, ready, unresponsive, rtt_msec, revision, acked_revision, visual_ready, snapshot_pending}.
func status() -> Dictionary:
	return {"state": socket.state, "text": socket.status_text, "ready": socket.is_ready(),
		"unresponsive": socket.is_unresponsive(), "rtt_msec": socket.rtt_msec, "revision": sender.revision(),
		"acked_revision": int(sender.stats.acked_revision), "visual_ready": bool(sender.stats.visual_ready),
		"snapshot_pending": sender.snapshot_pending(), "resyncs": int(sender.stats.resyncs),
		"last_error": str(sender.stats.last_error)}
