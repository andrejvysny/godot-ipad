extends TestCase


func _write(path: String, bytes: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(bytes)
	file.close()


func test_live_identity_changes_with_source_and_config_but_not_stale_fingerprint() -> void:
	var root := scratch_dir()
	for folder in BenchSourceIdentity.ROOTS:
		DirAccess.make_dir_recursive_absolute(root.path_join(folder))
	_write(root.path_join("project.godot"), "test project")
	_write(root.path_join("src/test.gd"), "source v1")
	_write(root.path_join("config/rendering_profiles.json"), "profile v1")
	var first := BenchSourceIdentity.capture(root, true)
	assert_eq(first.live_source_validity, "AVAILABLE_LOCAL_SOURCE")
	assert_eq(first.git_validity, "UNAVAILABLE")
	_write(root.path_join("config/build_fingerprint.json"), "stale")
	_write(root.path_join("src/test.gd.uid"), "uid://test")
	assert_eq(BenchSourceIdentity.capture(root, true).live_source_sha256, first.live_source_sha256)
	_write(root.path_join("src/test.gd"), "source v2")
	var second := BenchSourceIdentity.capture(root, true)
	assert_ne(second.live_source_sha256, first.live_source_sha256)
	_write(root.path_join("config/rendering_profiles.json"), "profile v2")
	assert_ne(BenchSourceIdentity.capture(root, true).live_source_sha256, second.live_source_sha256)


func test_exports_never_claim_local_source_or_git_identity() -> void:
	var exported := BenchSourceIdentity.capture("res://", false)
	assert_eq(exported.live_source_sha256, null)
	assert_eq(exported.live_source_validity, "UNAVAILABLE_EXPORTED_BUILD")
	assert_eq(exported.source_commit, null)
	assert_eq(exported.source_dirty, null)


func test_digest_order_is_canonical_and_missing_input_is_unavailable() -> void:
	var root := scratch_dir()
	_write(root.path_join("a"), "same")
	_write(root.path_join("b"), "bytes")
	var paths: Array[String] = [root.path_join("a"), root.path_join("b")]
	var first := BenchSourceIdentity.digest_files(root, paths)
	paths.reverse()
	assert_eq(BenchSourceIdentity.digest_files(root, paths), first)
	paths.append(root.path_join("missing"))
	var missing := BenchSourceIdentity.digest_files(root, paths)
	assert_eq(missing.sha256, null)
	assert_eq(missing.validity, "UNAVAILABLE_SOURCE_READ")
