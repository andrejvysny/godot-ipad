extends TestCase
## An unprepared AssetStudio object is drawn as the placeholder box fitted to its frozen descriptor bounds (IP-04
## closes the IP-03 gap where it was a unit box); once prepared the real tiers replace it.

var catalog: AssetCatalog
var registry: RenderAssetRegistry
var cache: RenderAssetCache
var doc: WorldDocument
var presenter: ObjectPresenter


func before_each() -> void:
	catalog = AssetCatalog.load_from()[0]
	registry = RenderAssetRegistry.load_from(ObjectPresenter.REGISTRY_INDEX, catalog)
	cache = RenderAssetCache.new(RenderConfig.load_from().section("budgets"))
	doc = WorldDocument.new()
	doc.assets.catalog = catalog


func after_each() -> void:
	if presenter != null and is_instance_valid(presenter):
		tree.root.remove_child(presenter)
		presenter.free()
	presenter = null


func test_placeholder_box_uses_the_descriptor_bounds() -> void:
	var item := AssetTestKit.remote("primitive_prop.json", AssetTestKit.V1_ID, AssetTestKit.glb(AssetTestKit.GLB_V1))
	var binding: AssetBinding = item.binding
	doc.assets.add(binding)
	var rec := ObjectRecord.new()
	rec.object_id = ObjectRecord.new_uuid_v4()
	rec.binding_id = binding.binding_id
	rec.uniform_scale = 2.0
	rec.set_position(10.0, 0.0, 10.0)
	doc.put_object(rec)
	presenter = ObjectPresenter.new()
	presenter.setup(catalog, registry, cache)
	tree.root.add_child(presenter)
	presenter.rebuild(doc)
	presenter.settle_now()
	var world := presenter.render_world()
	var batch := world.batch_of(rec.object_id)
	assert_true(batch.multimesh().mesh == world.placeholder_mesh(), "unprepared: the placeholder box")
	var scale := batch.local_transform(int(batch.slot_of[rec.object_id])).basis.get_scale()
	var bounds := doc.assets.definition(binding.binding_id).bounds.size  # (1, 0.5, 2) in the fixture descriptor
	assert_true(bounds.is_equal_approx(Vector3(1.0, 0.5, 2.0)), str(bounds))
	assert_true(scale.is_equal_approx(bounds * 2.0), "box fitted to the frozen bounds x record scale, got %s" % str(scale))
