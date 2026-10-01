extends TestCase
## ScatterSetStore (docs/editor-v2.md §6): defaults, persistence, corrupt files, validation.


func _path() -> String:
	return scratch_dir() + "/scatter_sets.json"


func _write(text: String) -> void:
	var f := FileAccess.open(_path(), FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _mk(id: String = "mine") -> Dictionary:
	return {"id": id, "name": "Mine", "items": [{"asset_id": "nature.rock.boulder_a", "weight": 2.0}],
			"density": 1.0, "spacing": 1.0, "slope_min": 0.0, "slope_max": 40.0, "align": false}


func test_missing_file_gives_the_default_table() -> void:
	var store := ScatterSetStore.new(_path())
	var ids: Array[String] = []
	for s in store.sets():
		ids.append(s.id)
	assert_eq(ids, ["forest", "meadow", "scree"] as Array[String])
	var forest := store.get_set("forest")
	assert_eq(forest.name, "Spruce forest")
	assert_eq(forest.items, [{"asset_id": "nature.tree.spruce_a", "weight": 6.0},
			{"asset_id": "nature.cover.fern_a", "weight": 3.0}, {"asset_id": "nature.rock.boulder_a", "weight": 1.0}])
	assert_eq([forest.density, forest.spacing, forest.slope_min, forest.slope_max, forest.align], [0.6, 1.4, 0.0, 35.0, false])
	var meadow := store.get_set("meadow")
	assert_eq([meadow.density, meadow.spacing, meadow.slope_min, meadow.slope_max, meadow.align], [3.0, 0.35, 0.0, 25.0, true])
	assert_eq(meadow.items[0], {"asset_id": "nature.cover.grass_tuft_a", "weight": 7.0})
	var scree := store.get_set("scree")
	assert_eq([scree.density, scree.spacing, scree.slope_min, scree.slope_max, scree.align], [1.4, 0.5, 12.0, 70.0, true])
	assert_eq(scree.items.size(), 2)
	assert_true(store.get_set("nope").is_empty())


func test_put_save_load_round_trip_and_remove() -> void:
	var store := ScatterSetStore.new(_path())
	assert_empty_string(store.put_set(_mk()))
	var forest := store.get_set("forest")
	forest.name = "Renamed"
	assert_empty_string(store.put_set(forest))
	assert_empty_string(store.remove_set("scree"))
	assert_ne(store.remove_set("scree"), "")
	var reloaded := ScatterSetStore.new(_path())
	assert_eq(reloaded.sets(), store.sets())
	assert_eq(reloaded.get_set("forest").name, "Renamed")
	assert_eq(reloaded.get_set("mine").items[0].weight, 2.0)
	assert_true(reloaded.get_set("scree").is_empty())


func test_corrupt_or_wrong_shaped_files_fall_back_to_defaults() -> void:
	for text in ["{not json", "[]", "{\"sets\": 4}", "{\"sets\": [{\"id\": \"x\"}]}", ""]:
		_write(text)
		var store := ScatterSetStore.new(_path())
		assert_eq(store.sets(), ScatterSetStore.default_sets(), "file: " + text)


func test_valid_file_keeps_good_sets_and_drops_bad_ones() -> void:
	_write(JSON.stringify({"version": 1, "sets": [_mk("a"), {"id": "bad"}, _mk("a"), _mk("b")]}))
	var store := ScatterSetStore.new(_path())
	var ids: Array[String] = []
	for s in store.sets():
		ids.append(s.id)
	assert_eq(ids, ["a", "b"] as Array[String], "bad and duplicate entries dropped")


func test_validation_clamps_fields() -> void:
	var store := ScatterSetStore.new("")
	var wild := _mk("wild")
	wild.items = [{"asset_id": "a", "weight": 99}, {"asset_id": "b", "weight": 0.0}, {"asset_id": "a", "weight": 1.0},
			{"asset_id": "", "weight": 1.0}, {"asset_id": "c", "weight": "heavy"}]
	wild.density = 50
	wild.spacing = 0.0
	wild.slope_min = 80
	wild.slope_max = 10
	assert_empty_string(store.put_set(wild))
	var got := store.get_set("wild")
	assert_eq(got.items, [{"asset_id": "a", "weight": 10.0}, {"asset_id": "b", "weight": 0.5}])
	assert_eq([got.density, got.spacing, got.slope_min, got.slope_max], [5.0, 0.2, 80.0, 80.0])
	wild.slope_min = -5
	wild.slope_max = 500
	store.put_set(wild)
	got = store.get_set("wild")
	assert_eq([got.slope_min, got.slope_max], [0.0, 90.0])


func test_validation_rejects_bad_sets() -> void:
	var store := ScatterSetStore.new("")
	var empty := _mk()
	empty.items = []
	assert_error_contains(store.put_set(empty), "at least one asset")
	for key in ["id", "name"]:
		var bad := _mk()
		bad[key] = ""
		assert_ne(store.put_set(bad), "", key)
	var colon := _mk("set:x")
	assert_ne(store.put_set(colon), "", "ids never contain ':'")
	for key in ["density", "spacing", "slope_min", "slope_max", "align"]:
		var bad := _mk()
		bad[key] = "x"
		assert_error_contains(store.put_set(bad), key)
	var nan_density := _mk()
	nan_density.density = NAN
	assert_error_contains(store.put_set(nan_density), "density")
	assert_ne(store.put_set({} as Dictionary), "")
	assert_eq(store.sets().size(), 3, "nothing stored")


func test_new_set_id_is_unique_and_set_copies_are_detached() -> void:
	var store := ScatterSetStore.new("")
	var a := store.new_set_id()
	assert_true(a.begins_with("set_") and a != store.new_set_id())
	var copy := store.get_set("forest")
	copy.items.clear()
	copy.name = "x"
	assert_eq(store.get_set("forest").items.size(), 3, "get_set returns a deep copy")
	store.sets()[0].name = "x"
	assert_eq(store.get_set("forest").name, "Spruce forest")
