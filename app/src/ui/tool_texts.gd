class_name ToolTexts
extends RefCounted
## Texts, icons and section tables of the Editor v2 tool interface (docs/editor-v2.md §1, §9). Pure
## data and string formatting over ToolController state, so the chip and the popover agree.

const MODE_LABELS := {"sculpt": "Sculpt", "paint": "Paint", "place": "Place"}
const MODE_ICONS := {"sculpt": "height_add", "paint": "texture_paint", "place": "multimesh"}
const TOOL_ICONS := {"raise": "height_add", "flatten": "height_flat", "noise": "height_mul",
		"paint": "texture_paint", "spray": "texture_spray", "tint": "color_paint", "pick": "picker_checked",
		"select": "picker_checked", "scatter": "multimesh", "erase": "holes", "fill": "layers", "path": "navigation"}
const LAYER_NAMES: Array[String] = ["Grass", "Dirt", "Rock", "Sand"]
const LAYER_COLORS: Array[Color] = [Color("56aa3e"), Color("a8744c"), Color("8c8a85"), Color("dcc98c")]
const TINT_NAMES: Array[String] = ["Dry", "Lush", "Autumn"]
const TINT_COLORS: Array[Color] = [Color8(200, 180, 84), Color8(38, 108, 40), Color8(192, 110, 48)]
const HINTS := {
	"raise": "Draw to raise. Invert to lower.",
	"flatten": "Pulls terrain toward the target height. Pick samples it from the terrain.",
	"noise": "Roughens the surface. Inverted, it smooths.",
	"paint": "Replaces the layer under the brush. Inverted, it erases manual paint and reveals the rule layer.",
	"spray": "Builds up a soft, broken blend.",
	"tint": "Colour variation on top of the textures.",
	"pick": "Tap the terrain to pick its texture layer.",
	"select": "Drag from the Library to place one item. Tap an object to select it, drag to move.",
	"scatter": "Paints instances from the active set, within its slope range.",
	"erase": "Removes scattered instances under the brush.",
	"fill": "Draw a closed loop to fill it. Inverted, it clears the loop.",
	"path": "Draw freehand. On lift it becomes a spline; drag its points to edit.",
}
const ALPHA_HINTS := {"circle": "Alpha centred on the Pencil tip.",
		"stamp": "Alpha rotates to follow the stroke direction.",
		"pattern": "Alpha tiles in world space; the stroke reveals it."}
const BRUSH_TOOLS: Array[String] = ["raise", "flatten", "noise", "paint", "spray", "tint", "scatter", "erase"]
## Section ids of the popover per tool, in display order. "delete_path" additionally needs a selected
## path, "rules" appears in paint mode only.
const SECTIONS := {
	"raise": ["size", "strength", "alpha", "pressure"],
	"flatten": ["height", "size", "strength", "alpha", "pressure"],
	"noise": ["size", "strength", "alpha", "pressure"],
	"paint": ["swatches", "size", "strength", "alpha", "pressure", "rules"],
	"spray": ["swatches", "size", "strength", "alpha", "pressure", "rules"],
	"tint": ["tints", "size", "strength", "alpha", "pressure", "rules"],
	"pick": ["swatches", "rules"],
	"select": ["snap"],
	"scatter": ["source", "size", "strength", "alpha", "pressure", "avoid"],
	"erase": ["size", "strength", "alpha"],
	"fill": ["source", "avoid"],
	"path": ["width", "delete_path"],
}
const ALL_SECTIONS: Array[String] = ["swatches", "tints", "height", "source", "size", "strength", "width", "alpha",
		"pressure", "avoid", "snap", "delete_path", "rules"]


static func is_brush(tool_id: String) -> bool:
	return tool_id in BRUSH_TOOLS


static func tool_label(tool_id: String) -> String:
	return ToolModel.TOOL_LABELS.get(tool_id, tool_id)


## Chip label: the invert label when inverted, "<Tool> <Layer>" for paint and spray, else the tool label.
static func chip_label(tools: ToolController) -> String:
	var id := tools.active_tool()
	if tools.inverted():
		return ToolModel.INVERT_LABELS[id]
	if id == "paint" or id == "spray":
		return "%s %s" % [tool_label(id), LAYER_NAMES[int(tools.settings("paint").layer)]]
	return tool_label(id)


## Chip sub text: brush "[<set> · ]7.0 m · 50%", path "width 2.4 m", fill, pick and select texts.
static func chip_sub(tools: ToolController) -> String:
	var id := tools.active_tool()
	if is_brush(id):
		var s := tools.settings(tools.mode())
		var text := "%.1f m · %d%%" % [float(s.radius), roundi(float(s.strength) * 100.0)]
		if id == "scatter" and not tools.inverted():
			text = "%s · %s" % [str(tools.scatter_config().name), text]
		return text
	match id:
		"path":
			return "width %.1f m" % float(tools.settings("path").width)
		"fill":
			return "clear loop" if tools.inverted() else str(tools.scatter_config().name)
		"pick":
			return "tap terrain"
	return "drag from Library"


static func format_density(density: float) -> String:
	var text := "%.2f" % density
	while text.contains(".") and (text.ends_with("0") or text.ends_with(".")):
		text = text.left(text.length() - 1)
	return text
