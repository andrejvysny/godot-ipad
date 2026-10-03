class_name SessionStub
extends Node
## Minimal duck-typed editor session for LiveSessionBinding / PreviewLink tests: a document, the three live signals
## and an optional open transaction. commit() does what EditorSession.commit does for the live sender.

signal world_committed(change: WorldChange, revision: int, forward: bool)
signal world_replaced()
signal scatter_touched(rect: Rect2)

var document: WorldDocument
var history := CommandHistory.new()
var tx_open: EditTransaction = null


func open_transaction() -> EditTransaction:
	return tx_open


func commit(change: WorldChange) -> void:
	document.bump_revision()
	history.push_already_applied(change)
	world_committed.emit(change, document.document_revision, true)


func replace(doc: WorldDocument) -> void:
	document = doc
	world_replaced.emit()
