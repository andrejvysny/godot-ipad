extends TestCase
## RemoteLibrary browse model (IP-04): paging, filters, cursor resets, per-library failures, thumbnails and the
## change feed, against FakeLibraryClient (no network).

const LIB := FakeLibraryClient.LIBRARY
const OTHER := FakeLibraryClient.OTHER_LIBRARY
const SERVER := AssetTestKit.SERVER

var lib: RemoteLibrary
var client: FakeLibraryClient


func before_each() -> void:
	client = FakeLibraryClient.new()
	client.items[LIB] = []
	for i in 130:
		client.items[LIB].append(FakeLibraryClient.row(i + 1, "Rock %d" % (i + 1), "rocks" if i % 2 == 0 else "trees"))
	lib = RemoteLibrary.new()
	tree.root.add_child(lib)
	lib.set_clients({SERVER: client}, false)


func after_each() -> void:
	if is_instance_valid(lib):
		tree.root.remove_child(lib)
		lib.free()


func _key(library: String = LIB) -> String:
	return RemoteLibrary.key_of(SERVER, library)


func test_libraries_are_listed_and_browse_pages_60_then_more() -> void:
	await lib.refresh_libraries()
	assert_eq(lib.libraries().size(), 1)
	assert_eq(lib.libraries()[0].name, "Fake")
	assert_eq(lib.connectivity().state, "online")
	await lib.browse(_key())
	assert_eq(lib.items(_key()).size(), 60, "first page is 60")
	assert_true(lib.has_more(_key()))
	assert_eq(client.limits, [60])
	await lib.browse(_key(), true)
	assert_eq(lib.items(_key()).size(), 120)
	await lib.browse(_key(), true)
	assert_eq(lib.items(_key()).size(), 130, "no duplicates, last page short")
	assert_false(lib.has_more(_key()))
	var first: Dictionary = lib.items(_key())[0]
	assert_eq(first.asset_key, AssetBinding.Canonical.asset_key(SERVER, LIB, first.asset_id, first.version_id))
	assert_eq(first.ref.version_id, first.version_id, "an item names the exact listed version")


func test_page_size_is_clamped_to_200() -> void:
	await lib.refresh_libraries()
	lib.page_size = 999
	await lib.browse(_key())
	assert_eq(client.limits, [200])
	assert_eq(lib.items(_key()).size(), 130)
	assert_false(lib.has_more(_key()))


func test_text_and_category_filters_reach_the_server() -> void:
	await lib.refresh_libraries()
	lib.select(_key())
	await lib.browse(_key())
	lib.set_query("Rock 12", "")
	await lib.browse(_key())
	var names: Array = lib.items(_key()).map(func(it: Dictionary) -> String: return str(it.name))
	assert_true("Rock 12" in names and "Rock 120" in names and not ("Rock 13" in names))
	assert_true(names.all(func(n: String) -> bool: return n.contains("Rock 12")), "only matches reach the client")
	lib.set_query("", "trees")
	await lib.browse(_key())
	assert_true(lib.items(_key()).all(func(it: Dictionary) -> bool: return it.category == "trees"))
	assert_eq(lib.categories(_key()), PackedStringArray(["trees"]))


func test_cursor_reset_keeps_the_old_items_until_the_replacement_page_arrives() -> void:
	await lib.refresh_libraries()
	await lib.browse(_key())
	assert_eq(lib.items(_key()).size(), 60)
	client.reset_next = true
	client.gate_first_page = true
	lib.browse(_key(), true)  # the server resets the cursor; the replacement first page is held back
	await tree.process_frame
	assert_eq(lib.items(_key()).size(), 60, "prior items stay visible while the replacement is pending")
	assert_eq(lib.library_error(_key()), "")
	client.items[LIB] = [FakeLibraryClient.row(900, "Fresh")]
	client.released.emit()
	await tree.process_frame
	assert_eq(lib.items(_key()).size(), 1, "replaced as one page")
	assert_eq(lib.items(_key())[0].name, "Fresh")


func test_one_library_failing_never_erases_another() -> void:
	client.library_rows.append({"library_id": OTHER, "name": "Second", "state": "available"})
	client.items[OTHER] = [FakeLibraryClient.row(500, "Other asset")]
	await lib.refresh_libraries()
	await lib.browse(_key())
	await lib.browse(_key(OTHER))
	assert_eq(lib.items(_key()).size(), 60)
	assert_eq(lib.items(_key(OTHER)).size(), 1)
	client.fail_list[LIB] = true
	await lib.browse(_key())
	assert_eq(lib.items(_key()).size(), 60, "a failed refresh keeps what was loaded")
	assert_error_contains(lib.library_error(_key()), "library unavailable")
	assert_eq(lib.items(_key(OTHER)).size(), 1)
	assert_eq(lib.library_error(_key(OTHER)), "")


func test_server_failure_marks_offline_and_keeps_libraries() -> void:
	await lib.refresh_libraries()
	client.fail_libraries = true
	await lib.refresh_libraries()
	assert_eq(lib.libraries().size(), 1, "the earlier libraries stay listed")
	assert_eq(lib.connectivity().state, "offline")
	assert_error_contains(str(lib.connectivity().text), "server unreachable")
	client.fail_libraries = false
	await lib.refresh_libraries()
	assert_eq(lib.connectivity().state, "online")


func test_a_library_that_disappears_from_the_listing_is_dropped() -> void:
	await lib.refresh_libraries()
	lib.select(_key())
	client.library_rows = []
	await lib.refresh_libraries()
	assert_eq(lib.libraries().size(), 0)
	assert_eq(lib.selected(), "", "falls back to the bundled catalog")


func test_thumbnails_are_cached_in_memory_and_on_disk() -> void:
	var dir := scratch_dir() + "/thumbs"
	lib.thumbs.dir = dir
	var row := FakeLibraryClient.row(7, "Pic")
	row.has_thumbnail = true
	client.items[LIB] = [row]
	client.thumbnails[row.current_version_id] = FakeLibraryClient.png()
	await lib.refresh_libraries()
	await lib.browse(_key())
	await tree.process_frame
	var item: Dictionary = lib.items(_key())[0]
	assert_true(lib.thumbs.texture(item.asset_key) != null, "decoded and cached")
	await lib.thumbs.request(client, str(item.asset_key), LIB, str(item.asset_id), str(item.version_id))
	assert_eq(client.calls.filter(func(c: String) -> bool: return c.begins_with("thumb:")).size(), 1, "a second request does not refetch")
	var other := RemoteThumbs.new(dir)
	await other.request(null, str(item.asset_key), LIB, str(item.asset_id), str(item.version_id))
	assert_true(other.texture(item.asset_key) != null, "served from the disk cache with no server")


func test_change_feed_events_refresh_the_selected_library_only() -> void:
	client.library_rows.append({"library_id": OTHER, "name": "Second", "state": "available"})
	client.items[OTHER] = [FakeLibraryClient.row(500, "Other asset")]
	await lib.refresh_libraries()
	lib.select(_key())
	await tree.process_frame
	var before := client.calls.size()
	lib.on_events([{"type": "library_changed", "library_id": OTHER}])
	await tree.process_frame
	assert_eq(client.calls.size(), before, "an event of a library that is not on screen only marks it stale")
	lib.on_events([{"type": "asset_metadata_changed", "library_id": LIB, "asset_id": "ast_%016d" % 1}])
	await tree.process_frame
	assert_true(client.calls.size() > before, "the selected library is browsed again")
	lib.select(_key(OTHER))
	await tree.process_frame
	assert_eq(lib.items(_key(OTHER)).size(), 1, "the stale library loads when it is selected")


func test_reset_required_rereads_libraries_and_the_selected_listing() -> void:
	await lib.refresh_libraries()
	lib.select(_key())
	await tree.process_frame
	var before := client.calls.size()
	await lib.on_reset()
	await tree.process_frame
	assert_true(client.calls.slice(before).has("libraries"))
	assert_true(client.calls.slice(before).any(func(c: String) -> bool: return c.begins_with("list:")))
