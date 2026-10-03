class_name ApplyProjectCase
extends ApplyTestCase
## Base of the Apply tests that write into the test project (a throw-away sandbox copy under scripts/godot_test.py):
## a unique accepted_world_root per test, a fresh ApplyContext, and cleanup of everything an Apply leaves behind.

const Coordinator := preload("res://addons/assetstudio/project/as_mutation_coordinator.gd")

var catalog: AssetCatalog
var ctx: ApplyContext
var root_res := ""
var project := ""
var installed_keys: Array[String] = []
var _frozen_count := 0


func before_each() -> void:
	super()
	catalog = AssetCatalog.load_from()[0]
	root_res = "res://wp_test_" + StorageFs.random_hex(4)
	ProjectSettings.set_setting(ApplyLayout.SETTING_ROOT, root_res)
	project = ApplyLayout.project_root()
	_clean_project()
	refresh_ctx()


func after_each() -> void:
	Coordinator.fail_after_step = -1
	_clean_project()
	StorageFs.remove_tree(project.path_join(ApplyLayout.rel_of(root_res)))
	ProjectSettings.set_setting(ApplyLayout.SETTING_ROOT, ApplyLayout.DEFAULT_ROOT)
	super()


func _clean_project() -> void:
	for rel in [".world_painter", ".assetstudio", "assetstudio.lock.json"]:
		StorageFs.remove_tree(project.path_join(rel))
	for key in installed_keys:
		StorageFs.remove_tree(project.path_join("assets/library").path_join(key))
	if FileAccess.file_exists(project.path_join("assetstudio.lock.json")):
		DirAccess.remove_absolute(project.path_join("assetstudio.lock.json"))
	installed_keys.clear()


func refresh_ctx() -> void:
	ctx = ApplyContext.for_project(tree)


## Writes `doc` as a frozen generation and returns its absolute directory.
func frozen(doc: WorldDocument) -> String:
	_frozen_count += 1
	var dir := ProjectSettings.globalize_path(scratch_dir()).path_join("frozen_%d" % _frozen_count)
	assert_true(ApplyTestKit.write_frozen(doc, dir) != "", "frozen snapshot written")
	return dir


func review_of(doc: WorldDocument) -> ApplyReview:
	return ApplyReview.build(frozen(doc), {}, ctx)


func apply_review(review: ApplyReview, discard: bool = false) -> Dictionary:
	return await ApplyTransaction.new(ctx).apply(review, discard)


func world_dir() -> String:
	return project.path_join(ApplyLayout.rel_of(root_res))


func binding_of(world_id: String) -> Dictionary:
	return ApplyBindingFile.read(ApplyLayout.abs_of(ApplyLayout.binding_res(world_id)))
