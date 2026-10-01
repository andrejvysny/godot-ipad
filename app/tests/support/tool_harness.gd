class_name ToolHarness
extends RefCounted
## Shared fixture for tool-layer integration tests: real document, presenter, camera and
## ToolController wired like a session, with a recording terrain view and history.

const BOULDER := "nature.rock.boulder_a"
const LODGE := "built.lodge.cabin_a"
const SPRUCE := "nature.tree.spruce_a"
const FAR_OUTSIDE := Vector3(400.0, 0.0, 0.0)


class FakeTerrain extends TerrainView:
	var marks: Array = []

	func mark_dirty(kind: int, loc: Vector2i) -> String:
		marks.append([kind, loc])
		return ""

	func marked(kind: int) -> Array:
		var out: Array = []
		for m: Array in marks:
			if m[0] == kind and not out.has(m[1]):
				out.append(m[1])
		return out


var doc: WorldDocument
var catalog: AssetCatalog
var presenter: ObjectPresenter
var camera: Camera3D
var terrain := FakeTerrain.new()
var history := CommandHistory.new()
var ctrl := ToolController.new()
var ctx := ToolContext.new()
var diagnostics: Array[String] = []
var commits: Array[WorldChange] = []
var cancels: Array[String] = []
var finished: Array[WorldChange] = []
var _tree: SceneTree


func setup(tree: SceneTree, fixture: String = "res://fixtures/gentle_hills") -> String:
	_tree = tree
	catalog = AssetCatalog.load_from()[0]
	var loaded := WorldCodec.read_generation(fixture, catalog)
	if loaded[1] != "":
		return loaded[1]
	doc = loaded[0]
	presenter = ObjectPresenter.new()
	presenter.setup(catalog)
	camera = Camera3D.new()
	tree.root.add_child(presenter)
	tree.root.add_child(camera)
	camera.look_at_from_position(Vector3(0, 60, 25), Vector3.ZERO)
	var defaults_file := FileAccess.open("res://config/poc_defaults.json", FileAccess.READ)
	ctx.defaults = JSON.parse_string(defaults_file.get_as_text())
	ctx.document = doc
	ctx.catalog = catalog
	ctx.render_ready = presenter.is_asset_ready
	ctx.camera = camera
	ctx.terrain = terrain
	ctx.presenter = presenter
	ctx.commit = func(c: WorldChange) -> void:
		doc.bump_revision()
		history.push_already_applied(c)
		commits.append(c)
	ctx.request_cancel = func(reason: String) -> void:
		cancels.append(reason)
		ctrl.handle_tool_action({"type": "tool_cancel", "reason": reason})
	ctx.diagnostic = func(m: String) -> void: diagnostics.append(m)
	ctx.units_per_point = func() -> float: return 1.0
	tree.root.add_child(ctrl)
	ctrl.setup(ctx)
	ctrl.operation_finished.connect(func(c: WorldChange) -> void: finished.append(c))
	return ""


func teardown() -> void:
	for n: Node in [ctrl, presenter, camera, terrain]:
		if is_instance_valid(n):
			if n.get_parent() != null:
				n.get_parent().remove_child(n)
			n.free()


func add_object(asset_id: String, x: float, z: float, offset: float = 0.0) -> ObjectRecord:
	var asset := catalog.get_asset(asset_id)
	var r := ObjectRecord.new()
	r.object_id = ObjectRecord.new_uuid_v4()
	r.asset_id = asset_id
	r.asset_version = asset.version
	r.grounding = asset.default_grounding
	r.height_offset_m = offset
	r.set_position(x, doc.sample_height(x, z) + offset, z)
	doc.put_object(r)
	presenter.sync_object(doc, r.object_id)
	return r


## Pencil sample aimed at the terrain surface above world (x, z).
func at(x: float, z: float, t: float) -> PointerSample:
	return aim(Vector3(x, doc.sample_height(x, z), z), t)


func aim(world: Vector3, t: float) -> PointerSample:
	var s := PointerSample.new()
	s.source = PointerSample.Source.PENCIL
	s.timestamp_s = t
	s.position_viewport = camera.unproject_position(world)
	return s


func sky(t: float) -> PointerSample:
	return aim(FAR_OUTSIDE, t)


func act(type: String, sample: PointerSample, over_ui: bool = false) -> void:
	ctrl.handle_tool_action({"type": type, "sample": sample, "over_ui": over_ui})


func control_snapshot() -> Dictionary:
	var out := {}
	for loc: Vector2i in doc.regions:
		out[loc] = doc.get_region(loc).control.duplicate()
	return out


func height_snapshot() -> Dictionary:
	var out := {}
	for loc: Vector2i in doc.regions:
		out[loc] = doc.get_region(loc).heights.duplicate()
	return out
