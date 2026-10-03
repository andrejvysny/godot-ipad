class_name LiveSessionBinding
extends RefCounted
## Connects a LiveSender to an editor session without importing it (live/ never references res://src/): the
## session is duck-typed on `document`, `open_transaction()` and the signals world_committed, world_replaced and
## scatter_touched (EditorSession). The owner still calls sender.tick() each frame and sender.pump(transport).


static func bind(session: Object, sender: LiveSender) -> void:
	sender.tx_provider = Callable(session, "open_transaction")
	session.connect("world_committed", sender.on_committed)
	session.connect("scatter_touched", sender.mark_scatter_rect)
	session.connect("world_replaced", func() -> void: sender.set_document(session.get("document")))
	sender.set_document(session.get("document"))
