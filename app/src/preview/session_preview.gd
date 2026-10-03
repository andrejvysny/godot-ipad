class_name SessionPreview
extends Node
## Owns the desktop-preview link and its settings panel for one EditorSession (ADR 0016 P5). Created on first use
## from the world menu; until then nothing of the preview exists in the editor.

var link := PreviewLink.new()
var panel := PreviewPanel.new()
var settings: PreviewSettings

var _layer := CanvasLayer.new()


func setup(session: EditorSession) -> void:
	settings = PreviewSettings.load_from()
	add_child(link)
	link.setup(session)
	_layer.layer = 11
	add_child(_layer)
	panel.theme = UiKit.make_theme()
	_layer.add_child(panel)
	panel.setup(link, settings)
	panel.position = Vector2(12, 120)
	session.input.ui_hits.register(panel)


func toggle_panel() -> void:
	panel.visible = not panel.visible
	panel.refresh()
