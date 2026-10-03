extends RemoteUiCase
## The remote half of the floating Library (IP-04): source chips, filter, connectivity text, bundled Library
## unchanged, the Server tab with its connection panel and the persistent cleartext warning.


func test_without_a_server_the_library_is_unchanged_and_remote_part_hidden() -> void:
	var s := await _start()
	var lib := _ui(s).library()
	assert_false(lib.remote_view().is_visible_in_tree(), "no server: no remote controls")
	assert_true(lib.tile(BOULDER).is_visible_in_tree())
	assert_eq(lib.size.x, 240.0)
	assert_true(lib.tab_button("server") != null)
	lib.show_tab("server")
	await _frames(2)
	assert_true(lib.connection_panel().is_visible_in_tree())
	assert_false(lib.tile(BOULDER).is_visible_in_tree())
	lib.show_tab("objects")
	assert_true(lib.tile(BOULDER).is_visible_in_tree())


func test_source_chips_switch_between_bundled_and_a_library() -> void:
	var s := await _remote_session()
	var lib := _ui(s).library()
	var view := lib.remote_view()
	var key := RemoteLibrary.key_of(SERVER, LIB)
	assert_true(view.is_visible_in_tree())
	assert_true(view.source_button("") != null and view.source_button(key) != null)
	assert_eq(view.source_button(key).text, "Fake")
	assert_true(view.source_button(key).button_pressed, "the test selected the library")
	assert_false(lib.tile(BOULDER).is_visible_in_tree(), "the bundled grid is hidden while a library is shown")
	assert_false(lib.quick_mix_button().is_visible_in_tree())
	assert_true(view.tile(_key()).is_visible_in_tree())
	assert_eq(view.tile(_key()).item.name, "Crate")
	await _pencil_click(s, view.source_button(""))
	assert_eq(s.assets().remote.selected(), "")
	assert_true(lib.tile(BOULDER).is_visible_in_tree(), "bundled behaviour is back")
	assert_false(view.tile(_key()).is_visible_in_tree())
	await _pencil_click(s, view.source_button(key))
	assert_true(view.tile(_key()).is_visible_in_tree())
	assert_eq(lib.size.x, 240.0)


func test_filter_and_category_chips_query_the_server() -> void:
	var s := await _remote_session()
	var view := _ui(s).library().remote_view()
	client.items[LIB].append(FakeLibraryClient.row(2, "Fir", "trees"))
	await s.assets().remote.browse(RemoteLibrary.key_of(SERVER, LIB))
	await _frames(2)
	assert_eq(view.tile_keys().size(), 2)
	var categories: Array = view.category_buttons().map(func(b: Button) -> String: return b.text)
	assert_eq(categories, ["All", "props", "trees"])
	await _pencil_click(s, view.category_buttons()[2])
	await _frames(3)
	assert_eq(view.tile_keys().size(), 1, "category filter reaches the server")
	await _pencil_click(s, view.category_buttons()[0])
	await _frames(3)
	view.filter_edit().text = "Cra"
	view.filter_edit().text_submitted.emit("Cra")
	await _frames(3)
	assert_eq(view.tile_keys(), [_key()], "text filter reaches the server")
	assert_eq(s.assets().remote.query.q, "Cra")


func test_connectivity_and_per_library_errors_are_shown() -> void:
	var s := await _remote_session()
	var view := _ui(s).library().remote_view()
	var remote := s.assets().remote
	client.fail_libraries = true
	await remote.refresh_libraries()
	await _frames(2)
	assert_true(view.status_text().contains("Offline"), view.status_text())
	assert_true(view.status_text().contains("server unreachable"))
	assert_true(view.tile(_key()).is_visible_in_tree(), "the loaded tiles stay")
	client.fail_libraries = false
	client.fail_list[LIB] = true
	await remote.refresh_libraries()
	await remote.browse(RemoteLibrary.key_of(SERVER, LIB))
	await _frames(2)
	assert_true(view.status_text().contains("Could not load"), view.status_text())
	assert_true(view.tile(_key()).is_visible_in_tree(), "a failed refresh keeps the items")


func test_connection_panel_stores_endpoint_and_token_and_never_shows_the_token() -> void:
	var s := await _start()
	s.assets().remote.watch_enabled = false
	var panel := _ui(s).library().connection_panel()
	var conn := s.assets().connection
	var token := "tok-secret-1234567890"
	panel.url_edit().text = "http://127.0.0.1:1"
	panel.server_id_edit().text = AssetTestKit.SERVER
	panel.token_edit().text = token
	assert_true(panel.token_edit().secret, "the token field is masked")
	await panel.connect_server()
	assert_eq(conn.server_ids(), PackedStringArray([AssetTestKit.SERVER]))
	assert_eq(panel.token_edit().text, "", "the token is cleared after saving")
	assert_false(panel.result_text().contains(token))
	assert_true(FileAccess.get_file_as_string(SessionAssets.storage_dir.path_join("credentials.json")).contains(token))
	assert_false(FileAccess.get_file_as_string(SessionAssets.storage_dir.path_join("connections.json")).contains(token))
	assert_true(s.assets().remote.has_servers())
	assert_eq(panel.warning_text(), "", "loopback needs no warning")
	await panel.remove_server()
	assert_false(conn.has_connection())
	assert_false(s.assets().remote.has_servers())
	await _frames(2)  # leave the HTTPRequest signal emission that resumed this coroutine before the session is freed


func test_cleartext_lan_needs_the_switch_and_keeps_a_persistent_warning() -> void:
	allow_logged_errors()  # the vendored registry push_warning()s when a cleartext LAN endpoint is stored
	var s := await _start()
	var panel := _ui(s).library().connection_panel()
	panel.url_edit().text = "http://192.168.1.20:8192"
	panel.server_id_edit().text = AssetTestKit.SERVER
	panel.token_edit().text = "tok-secret-1234567890"
	await panel.connect_server()
	assert_error_contains(panel.result_text(), "allow_insecure_lan")
	assert_false(panel.result_text().contains("tok-secret"))
	assert_false(s.assets().connection.has_connection(), "refused without the switch")
	await _pencil_click(s, _ui(s).library().tab_button("server"))
	panel.insecure_switch().button_pressed = true
	assert_error_contains(panel.warning_text(), "192.168.1.20")
	assert_empty_string(s.assets().connection.configure(AssetTestKit.SERVER, "http://192.168.1.20:8192", "", true))
	panel.url_edit().text = ""
	panel.load_stored()
	assert_error_contains(panel.warning_text(), "192.168.1.20", "the stored cleartext server keeps its warning")
	assert_true(panel.insecure_switch().button_pressed)
	log_filter.unexpected.clear()  # the registry's own cleartext push_warning, asserted through the visible warning
