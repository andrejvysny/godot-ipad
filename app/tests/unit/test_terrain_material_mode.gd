extends TestCase


func test_material_experiment_is_opt_in_and_invalid_mode_preserves_state() -> void:
	var adapter := TerrainAdapter.new()
	assert_eq(adapter.material_mode(), "full")
	assert_eq(adapter.material_uniforms(), {"terrain_overview_experiment": false})
	assert_empty_string(adapter.set_material_mode("overview_experiment"))
	assert_eq(adapter.material_mode(), "overview_experiment")
	assert_eq(adapter.material_uniforms(), {"terrain_overview_experiment": true})
	assert_eq(adapter.set_material_mode("cheap"), "unknown terrain material mode 'cheap'")
	assert_eq(adapter.material_mode(), "overview_experiment")
	assert_empty_string(adapter.set_material_mode("full"))
	assert_eq(adapter.material_uniforms(), {"terrain_overview_experiment": false})
	adapter.free()


func test_unsupported_terrain_view_refuses_experiment() -> void:
	var view := TerrainView.new()
	assert_eq(view.set_material_mode("overview_experiment"), "material tuning is not supported by this terrain view")
	assert_eq(view.material_mode(), "full")
	assert_eq(view.material_uniforms(), {})
	view.free()
