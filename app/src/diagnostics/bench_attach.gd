class_name BenchAttach
extends RefCounted
## Re-points the session's object presenter and scatter layer at the benchmark catalog and registry (bench
## assets are a separate logical catalog, docs/render-assets.md §1) and back at the editor's. The shared render
## cache stays the same instance. The presenter has no swap API, so its render world is freed and setup() is
## called again; the caller rebuilds the documents afterwards.

const BENCH_CATALOG_DIR := "res://assets/bench"
const BENCH_REGISTRY_INDEX := "res://assets/bench/render_assets/index.json"

var bench_catalog: AssetCatalog
var bench_registry: RenderAssetRegistry

var _session: EditorSession
var _kind := "editor"


func _init(session: EditorSession) -> void:
	_session = session


## "" or why the bench catalog/registry could not be loaded.
func load_bench() -> String:
	if bench_catalog != null:
		return ""
	var loaded := AssetCatalog.load_from(BENCH_CATALOG_DIR)
	if loaded[1] != "":
		return str(loaded[1])
	var catalog: AssetCatalog = loaded[0]
	var registry := RenderAssetRegistry.load_from(BENCH_REGISTRY_INDEX, catalog)
	if registry.error() != "":
		return "Bench render registry: " + registry.error()
	bench_catalog = catalog
	bench_registry = registry
	return ""


func kind() -> String:
	return _kind


## kind: "editor" or "bench". Returns "" or an error; a no-op when already attached that way.
func attach(kind_name: String) -> String:
	if kind_name == _kind:
		return ""
	if kind_name == "bench":
		var error := load_bench()
		if error != "":
			return error
		_swap(bench_catalog, bench_registry)
	else:
		_swap(_session.catalog, _session.render_state().registry())
	_kind = kind_name
	return ""


func restore() -> void:
	attach("editor")


## Attachment identity compared by RenderBench before and after a run: catalog ids of the presenter and the
## scatter layer, and whether the presenter still shares the session cache.
static func state(session: EditorSession) -> Dictionary:
	var catalog: Variant = session.presenter.get("_catalog")
	return {"presenter_catalog": (catalog as AssetCatalog).catalog_id if catalog != null else "",
		"scatter_catalog": session.layers.scatter.catalog_id(),
		"presenter_cache_shared": session.presenter.get("_cache") == session.render_cache()}


## setup() runs again on a fresh render world; the presenter re-applies its profile and pin check, the overview is
## rebound to the new world and the scatter renderer replaces its engine (re-applying camera, area, profile).
func _swap(catalog: AssetCatalog, registry: RenderAssetRegistry) -> void:
	var presenter := _session.presenter
	presenter.set_selected("")
	presenter.hide_ghost()
	var ghost_node := presenter.ghost().node
	if ghost_node != null:
		ghost_node.free()
	var world := presenter.render_world()
	world.clear()
	presenter.remove_child(world)
	world.free()
	presenter.setup(catalog, registry, _session.render_cache())
	presenter.set_camera(_session.rig.get_camera())
	_setup_layers(catalog, registry)
	_session.render_state().rebind_overview(registry)
	_session.render_state().reapply_profile()


func _setup_layers(catalog: AssetCatalog, registry: RenderAssetRegistry) -> void:
	_session.layers.setup(catalog, registry, _session.render_cache(), _session.render_config)
