class_name ScatterTestCase
extends TestCase
## Shared fixture of the scatter renderer tests: catalog, gentle_hills document, a renderer set up with a
## no-thinning profile, and an optional camera. Decorative assets use 16 m cells, the others 32 m cells.

const PEBBLES := "nature.rock.pebbles_a"
const GRASS := "nature.cover.grass_tuft_a"
const FERN := "nature.cover.fern_a"
const WILD := "nature.cover.wildflowers_a"
const SPRUCE := "nature.tree.spruce_a"
const BOULDER := "nature.rock.boulder_a"

var catalog: AssetCatalog
var renderer: ScatterRenderer
var doc: WorldDocument
var camera: Camera3D


func before_each() -> void:
	catalog = AssetCatalog.load_from()[0]
	doc = WorldCodec.read_generation("res://fixtures/gentle_hills", catalog)[0]
	renderer = ScatterRenderer.new()
	renderer.setup(catalog)
	renderer.set_lod_profile(full_profile())


func after_each() -> void:
	renderer.free()
	if camera != null:
		camera.get_parent().remove_child(camera)
		camera.free()
		camera = null


## No thinning and no ground-cover radius: every instance of every cell is drawn.
static func full_profile(outside: float = 1.0, active: float = 1.0, radius: float = 100000.0) -> Dictionary:
	var p := RenderConfig.load_from().profile("performance")
	p.size_policy_enabled = false
	p.decorative_density_outside = outside
	p.decorative_density_active = active
	p.ground_cover_radius_m = radius
	return p


func _build() -> void:
	renderer.rebuild_all(doc)
	assert_true(renderer.settle_now(), "scatter settles")


func _camera_at(pos: Vector3, target: Vector3) -> Camera3D:
	if camera == null:
		camera = Camera3D.new()
		tree.root.add_child(camera)
	camera.look_at_from_position(pos, target)
	return camera


## Catalog asset id of scatter instance `i` (through the document's asset lock).
func _asset_of(layer: ScatterLayer, i: int) -> String:
	return doc.assets.definition(layer.binding_of(i)).asset_id


func _layer_of(ids: Array, x: float = 10.0, z: float = 10.0) -> ScatterLayer:
	var layer := ScatterLayer.new()
	for id: String in ids:
		layer.add(doc.assets.bundled_binding_for(id), x, z, 0.0, 1.0, 0)
	return layer
